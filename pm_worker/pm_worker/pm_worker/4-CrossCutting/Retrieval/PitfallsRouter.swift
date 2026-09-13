//
//  PitfallsRouter.swift
//  pm_worker
//
//  pitfalls 确定性路由（design.md v0.9.11 §6.2）：按「当前阶段」关键词规则
//  读取该阶段相关技能的全部 pitfalls。不依赖语义命中——pitfalls 是雷达信号源，
//  走确定性路由（关键词硬编码表，中英不区分大小写）。
//

import Foundation
import GRDB

nonisolated enum PitfallsRouter {

    /// Codable：随 ContextAssembly 持久化（检查器 trace 读取）。
    struct Entry: Codable, Equatable {
        /// 技能名（skills 表 id = name）
        var skill: String
        /// 单条 pitfall 文本
        var pitfall: String
        /// 恒为 "pitfalls确定性路由"（可观测性：区分于语义检索来源）
        var source: String
    }

    /// 命中来源标签（雷达信号的确定性路由证明）
    static let sourceLabel = "pitfalls确定性路由"

    /// 阶段 → 关键词硬编码表（中英不区分大小写）。
    /// 其余阶段（classify / research / analysis / review / embedding）无映射 → 返回 []。
    static let stageKeywords: [LLMStage: [String]] = [
        .clarify: ["澄清", "需求挖掘", "调研", "kano", "访谈", "clarify"],
        .structure: ["结构", "信息架构", "流程", "structure", "流程图", "sitemap"],
        .prototype: ["原型", "交互", "prototype", "wireframe", "线框"],
        .prd: ["prd", "需求文档", "验收", "文档", "模板"],
    ]

    /// 确定性路由：按「当前阶段」关键词规则读取该阶段相关技能的全部 pitfalls。
    /// 匹配文本 = name + when_to_use + best_for + tags 拼接后
    /// localizedCaseInsensitiveContains 任一关键词；pitfalls JSON 数组逐条展开。
    static func pitfalls(for stage: LLMStage, database: AppDatabase) throws -> [Entry] {
        guard let keywords = stageKeywords[stage] else { return [] }

        let rows = try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT name, when_to_use, best_for, tags, pitfalls FROM skills WHERE enabled = 1"
            )
        }

        var entries: [Entry] = []
        for row in rows {
            let name: String = row["name"]
            let whenToUse: String = row["when_to_use"]
            let bestFor = strings(row["best_for"] as String?)
            let tags = strings(row["tags"] as String?)

            // 四字段拼接（与 SkillLoader.fourFieldText 同口径；type / pitfalls 不参与匹配）
            let matchText = ([name, whenToUse] + bestFor + tags).joined(separator: "\n")
            guard keywords.contains(where: { matchText.localizedCaseInsensitiveContains($0) }) else {
                continue
            }

            for pitfall in strings(row["pitfalls"] as String?) {
                entries.append(Entry(skill: name, pitfall: pitfall, source: sourceLabel))
            }
        }
        return entries
    }

    // MARK: - Private

    /// JSON 数组字符串 → [String]（NULL / 空 / 解析失败回空数组）。
    private static func strings(_ json: String?) -> [String] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}
