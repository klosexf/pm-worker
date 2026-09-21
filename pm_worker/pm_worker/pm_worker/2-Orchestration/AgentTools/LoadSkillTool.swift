//
//  LoadSkillTool.swift
//  pm_worker
//
//  load_skill：模型按需加载技能正文（渐进式披露的工具侧入口）。
//  与系统侧语义命中注入互补：模型判断需要某方法论全文时主动拉取。
//  纯本地只读，零外部依赖。
//

import Foundation

struct LoadSkillTool: AgentTool {
    let name = "load_skill"
    let description =
        "按需加载一个 PM 方法论技能的完整正文（该方法论的详细执行指引）。"
        + "当本轮上下文中的技能摘要不足以支撑回答、或用户明确要求展开某方法论时调用。"
        + "query 用技能名称或主题描述（如：KANO、用户故事地图、RICE）。"

    var parameters: JSONValue {
        agentToolStringProperty("技能名称或主题关键词")
    }

    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        struct Args: Codable {
            var query: String?
        }
        let query = (decodeToolArgs(Args.self, from: argumentsJSON)?.query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("参数缺失：请提供 query（技能名称或主题关键词）。")
        }
        let hits = await ctx.skillSearch(query)
        guard let hit = hits.first else {
            return AgentToolResult(
                ok: false,
                forLLM: "未找到与「\(query)」相关的技能。请基于已有上下文继续回答，不要用相同查询重复调用。",
                forHuman: "未命中技能「\(query)」"
            )
        }
        guard let body = SkillLoader.loadBody(docPath: hit.docPath), !body.isEmpty else {
            return AgentToolResult(
                ok: false,
                forLLM: "技能「\(hit.id)」的正文读取失败。请基于已有上下文继续回答。",
                forHuman: "技能「\(hit.id)」正文读取失败"
            )
        }
        let clipped = body.count > agentToolResultBudget
            ? String(body.prefix(agentToolResultBudget)) + "\n…（正文过长已截断）"
            : body
        return AgentToolResult(
            ok: true,
            forLLM: "技能「\(hit.id)」正文：\n\(clipped)",
            forHuman: "加载技能「\(hit.id)」"
        )
    }
}
