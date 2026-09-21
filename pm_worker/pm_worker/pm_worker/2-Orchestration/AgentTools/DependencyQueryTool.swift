//
//  DependencyQueryTool.swift
//  pm_worker
//
//  query_impact：模型自主查询产物依赖图（Function Calling v1.1）。
//  影响分析从「App 算好喂给模型」翻转为「模型调用工具自己算」——
//  变更提案 impacts 编制、回退影响判断、影响面评估的确定性数据源
//  （ArtifactDependencyGraph 全纯函数：模型只负责提问，图负责计算，
//  「能从既有事实算出来的不交给 LLM」的设计立场不变，只是提问权交还模型）。
//  只读、零磁盘访问、不触碰确认 / 产物写入路径，闸口不变量无关。
//

import Foundation

struct DependencyQueryTool: AgentTool {
    let name = "query_impact"
    let description =
        "查询产物依赖关系：给定一个或多个产物，返回会受其变更影响的全部下游产物"
        + "（按建议的重做顺序）。编制变更提案的影响清单（impacts）、判断某次修改的影响面、"
        + "或用户询问「改 X 会牵连什么」时调用。"

    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "seeds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "产物引用列表（至少一项）：支持路径（02-structure/核心流程图.md）、"
                            + "中文名（核心流程图 / 原型 / PRD）或带部位的引用（PRD · 发布计划章节）"
                    ),
                ]),
            ]),
            "required": .strings(["seeds"]),
        ])
    }

    /// 下游产物的展示顺序（重做顺序口径：上游在前；与 ArtifactDependencyGraph
    /// 节点声明同源，仅排序用——图本体保持无序集合语义）。
    private static let displayOrder: [String] = [
        ArtifactDependencyGraph.clarification,
        ArtifactDependencyGraph.architecture,
        ArtifactDependencyGraph.coreFlows,
        ArtifactDependencyGraph.businessFlows,
        ArtifactDependencyGraph.modulePageMap,
        ArtifactDependencyGraph.prototypeFamily,
        ArtifactDependencyGraph.prd,
        ArtifactDependencyGraph.competitiveAnalysis,
    ]

    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        struct Args: Codable {
            var seeds: [String]?
        }
        let seeds = (decodeToolArgs(Args.self, from: argumentsJSON)?.seeds ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !seeds.isEmpty else {
            return .failure("参数缺失：请提供 seeds（产物引用数组，至少一项）。")
        }

        // 逐 seed 解析（识别 / 未识别分流），合并下游闭包
        var unrecognized: [String] = []
        for seed in seeds {
            let resolved = ArtifactDependencyGraph.resolveReference(seed)
            if resolved.isEmpty, ArtifactDependencyGraph.normalize(seed) == nil {
                unrecognized.append(seed)
            }
        }
        let downstream = ArtifactDependencyGraph.downstream(ofSeeds: seeds)
        let ordered = Self.displayOrder.filter { downstream.contains($0) }

        var lines: [String] = []
        if !unrecognized.isEmpty {
            lines.append(
                "未识别的引用：\(unrecognized.joined(separator: "、"))。"
                    + "可用产物名：\(Self.menuList)"
            )
        }
        if ordered.isEmpty {
            if unrecognized.count < seeds.count {
                lines.append(
                    "查询的产物在依赖图中没有下游依赖（信息性参考产物，变更不连带重做其他产物）。"
                )
            }
            lines.append(
                "编制 impacts 提示：引用需落到具体产物（如「04-prd/PRD文档.md · 发布计划章节」）；"
                    + "列不出具体影响说明不是回退级变更。"
            )
        } else {
            lines.append("影响分析（按建议的重做顺序）：")
            for (i, node) in ordered.enumerated() {
                let name = ArtifactDependencyGraph.displayNames[node] ?? node
                lines.append("\(i + 1). \(name)（\(node)）")
            }
            lines.append(
                "编制 impacts 提示：逐条写成「路径 · 部位」形态，"
                    + "如「04-prd/PRD文档.md · 核心流程章节」；上列产物即受影响全集。"
            )
        }
        let text = lines.joined(separator: "\n")
        let clipped = text.count > agentToolResultBudget
            ? String(text.prefix(agentToolResultBudget)) + "\n…（结果过长已截断）"
            : text

        let seedName = seeds.joined(separator: "、")
        let forHuman: String
        if ordered.isEmpty {
            forHuman = unrecognized.count == seeds.count
                ? "影响分析：引用未识别"
                : "影响分析：\(seedName) 无下游"
        } else {
            forHuman = "影响分析：\(seedName) → \(ordered.count) 个下游产物"
        }
        return AgentToolResult(ok: true, forLLM: clipped, forHuman: forHuman)
    }

    private static let menuList =
        "澄清要点表、功能架构图、核心流程图、业务流程图、模块-页面映射表、交互原型、产品需求文档、竞品分析报告"
}
