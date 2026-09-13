//
//  ContextBuilder.swift
//  pm_worker
//
//  Context Builder——唯一注入收口（M4 Task 4.1，design.md §6.3/§6.4）：
//  五段组装（规则 / 记忆 / 技能正文 / 检索 / 历史）+ token 预算分配 +
//  超预算按优先级裁剪；Task 4.8：pitfalls 确定性路由进自检清单，拼到
//  system prompt 尾部。AppModel 是唯一调用方（组装结果写回 lastAssembly，
//  检查器 ⌘D 读取）。
//

import Foundation
import Combine
import GRDB

@MainActor
final class ContextBuilder: ObservableObject {
    nonisolated deinit {}

    // MARK: - 常量

    /// design.md §6.4 token 预算一档比例（五段配额；超预算按优先级从低到高裁剪）。
    /// rules 永不裁；history 只分配预算值，由 SessionStore 成对丢最旧整轮。
    nonisolated static let defaultBudgets: [ContextSegment: Int] = [
        .rules: 500,        // 规则层（rules/global.md 常驻）
        .memory: 2000,     // 记忆（含假设态校准文本）
        .skillBodies: 4000, // 命中技能正文（渐进式披露）
        .retrieval: 1500,   // 方法论卡片 top-k
        .history: 6000,    // 对话历史
    ]

    /// 规则层兜底文本（Bundle 读不到 rules/global.md 时使用——保活不崩）。
    nonisolated private static let fallbackRules = """
    - 不确认不推进：结构、原型、PRD 依次过用户确认闸口，上游未确认不生成下游产物。
    - 不凭空编造：结论、数据、事实须有对话或上游产物依据，调研事实带出处。
    - 中文输出、务实克制：不输出英文占位文本。
    """

    /// 检索 top-k。
    private static let retrievalTopK = 5

    /// 检索摘要行截断长度（字符）。
    private static let retrievalBriefLength = 100

    // MARK: - 状态

    private let database: AppDatabase?
    private let retriever: Retriever?
    private let budgets: [ContextSegment: Int]

    init(
        database: AppDatabase?,
        embedder: EmbeddingProviding,
        budgets: [ContextSegment: Int] = ContextBuilder.defaultBudgets
    ) {
        self.database = database
        self.retriever = database.map { Retriever(database: $0, embedder: embedder) }
        self.budgets = budgets
    }

    // MARK: - 唯一注入收口（design.md §6.3）

    /// 五段组装 + token 预算 + 超预算优先级裁剪。
    /// - promptBuilder: 注入区文本 → 该阶段完整 system prompt（AgentPrompts.xxx 的闭包形态）
    /// - memoryContext: MemoryStore.injectionContext（记忆段原文）
    /// - calibration: 记忆校准注入文本（假设态经验条目）
    /// - returns: systemPrompt 已含规则/记忆/技能正文/检索四段 + 自检清单 pitfalls；历史段预算见 breakdown
    func assemble(
        stage: LLMStage,
        project: String,
        stageQuery: String,
        memoryContext: String,
        calibration: [String],
        promptBuilder: (String) -> String
    ) async -> ContextAssembly {
        // ── ① 规则层（Bundle rules/global.md；读不到走内置兜底；常驻永不裁）
        let rulesText = Self.loadGlobalRules()

        // ── ② 检索（embedder 抛错不阻塞：trace 仍产出，hits 为空）
        var trace = RetrievalTrace(
            query: stageQuery, hits: [],
            filteredCrossProject: 0, unmatchedSkills: [], durationMs: 0
        )
        if let retriever {
            trace = (try? await retriever.search(
                query: stageQuery, project: project, topK: Self.retrievalTopK
            )) ?? trace
        }

        // ── ③ 技能正文（渐进式披露：命中才 loadSkillBody，读不到正文的不注入）
        //    Retriever 命中只带 when_to_use 摘要，doc_path 在此按命中 id 补查
        let skillHits = trace.hits.filter { $0.library == .skills }  // 已按相似度降序
        let docPaths = await Self.skillDocPaths(database: database)
        var skillBlocks: [(id: String, body: String)] = []
        for hit in skillHits {
            guard let path = docPaths[hit.id],
                  let body = Retriever.loadSkillBody(docPath: path),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            skillBlocks.append((id: hit.id, body: body))
        }

        // ── ④ 检索段（卡片命中 top-k，[卡名/scope] 摘要格式；技能命中已在③，不重复）
        let cardHits = trace.hits.filter { $0.library == .cards }  // 已按相似度降序
        var retrievalLines = cardHits.map { hit -> String in
            let title = Recommender.title(of: hit.content)
            let brief = String(
                hit.content.replacingOccurrences(of: "\n", with: " ")
                    .prefix(Self.retrievalBriefLength)
            )
            return "- [\(title)/\(hit.scope)] \(brief)"
        }

        // ── ⑤ 记忆段（原文 + 假设态校准文本；校准排段尾——预算压力下最先被裁）
        let calibrationText = calibration
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var memoryText = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !calibrationText.isEmpty {
            memoryText = memoryText.isEmpty ? calibrationText : memoryText + "\n\n" + calibrationText
        }

        // ── ⑥ token 预算裁剪（ContextSegment 数组序从尾部——低优先级——向前；
        //     skillBodies 丢整块技能、retrieval 丢相似度最低的、memory 截最旧的、rules 永不裁）
        var trimmed: [ContextSegment] = []

        // 记忆：MemoryStore 排序保证版本 scope 前置受保护，从尾部逐行丢
        let memoryBudget = budgets[.memory] ?? Self.defaultBudgets[.memory]!
        memoryText = Self.trimMemory(memoryText, budget: memoryBudget, trimmed: &trimmed)

        // 技能正文：丢相关度最低的整块（不截断正文，保持技能完整性）
        let skillBudget = budgets[.skillBodies] ?? Self.defaultBudgets[.skillBodies]!
        while TokenBreakdown.estimate(skillBlocks.map(\.body).joined(separator: "\n")) > skillBudget,
              !skillBlocks.isEmpty {
            skillBlocks.removeLast()
            if !trimmed.contains(.skillBodies) { trimmed.append(.skillBodies) }
        }

        // 检索：丢相似度最低的（尾部）
        let retrievalBudget = budgets[.retrieval] ?? Self.defaultBudgets[.retrieval]!
        while TokenBreakdown.estimate(retrievalLines.joined(separator: "\n")) > retrievalBudget,
              !retrievalLines.isEmpty {
            retrievalLines.removeLast()
            if !trimmed.contains(.retrieval) { trimmed.append(.retrieval) }
        }

        // 历史：本组装不含正文——只分配预算值（SessionStore 按它成对丢最旧整轮）；
        // 预算归零 = 历史段整体让位，记入 trimmed
        let historyBudget = budgets[.history] ?? Self.defaultBudgets[.history]!
        if historyBudget <= 0 { trimmed.append(.history) }

        // trimmed 按优先级从低到高记录（ContextModels 契约）
        let order: [ContextSegment] = [.history, .retrieval, .skillBodies, .memory]
        trimmed = order.filter { trimmed.contains($0) }

        // ── ⑦ 注入区文本（空段省略；整体为空 → promptBuilder 收到 ""，记忆区整段不出现）
        var sections = ["### 规则层（全局产品约束，常驻）\n\(rulesText)"]
        if !memoryText.isEmpty {
            sections.append("### 记忆（版本 > 项目，新覆盖旧，不得矛盾）\n\(memoryText)")
        }
        if !skillBlocks.isEmpty {
            let blocks = skillBlocks.map { "#### 技能：\($0.id)\n\($0.body)" }
                .joined(separator: "\n\n")
            sections.append("### 技能正文（命中技能，按相关度降序）\n\(blocks)")
        }
        if !retrievalLines.isEmpty {
            sections.append("### 检索参考（方法论卡片）\n" + retrievalLines.joined(separator: "\n"))
        }
        let injection = sections.joined(separator: "\n\n")

        // ── ⑧ 完整 system prompt（promptBuilder 骨架 + 注入区）
        //     + pitfalls 自检清单（Task 4.8：确定性路由，拼到尾部）
        var systemPrompt = promptBuilder(injection)
        let pitfalls = Self.stagePitfalls(stage: stage, database: database)
        if !pitfalls.isEmpty {
            let lines = pitfalls.map { "- [\($0.skill)] \($0.pitfall)" }
            systemPrompt += "\n\n## 自检清单（pitfalls 确定性路由）\n" + lines.joined(separator: "\n")
        }

        // ── ⑨ 组装产物（AppModel 自己写 lastAssembly；本方法只返回）
        let segments: [ContextSegment: Int] = [
            .rules: TokenBreakdown.estimate(rulesText),
            .memory: TokenBreakdown.estimate(memoryText),
            .skillBodies: TokenBreakdown.estimate(skillBlocks.map { $0.body }.joined(separator: "\n")),
            .retrieval: TokenBreakdown.estimate(retrievalLines.joined(separator: "\n")),
            .history: historyBudget,
        ]
        return ContextAssembly(
            systemPrompt: systemPrompt,
            query: stageQuery,
            stage: stage.rawValue,
            breakdown: TokenBreakdown(
                segments: segments,
                budget: budgets.values.reduce(0, +),
                trimmed: trimmed
            ),
            retrieval: retriever == nil ? nil : trace,
            injectedSkillBodies: skillBlocks.map { "\($0.id)：\n\($0.body)" },
            calibration: calibration,
            pitfalls: pitfalls,
            createdAt: ISO8601.timestamp()
        )
    }

    // MARK: - Private

    /// 规则层加载：同步组打包 Resources/rules/ 可能保持目录或被平铺，两种都试；
    /// 都读不到走内置兜底文本（保活不崩）。
    nonisolated private static func loadGlobalRules() -> String {
        for subdirectory: String? in ["rules", nil] {
            if let url = Bundle.main.url(
                forResource: "global", withExtension: "md", subdirectory: subdirectory
            ), let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return fallbackRules
    }

    /// 技能 doc_path 映射（一次读全量启用技能）。
    /// Row 非 Sendable：异步 read 闭包内投影成 Sendable 字典再带出。
    nonisolated private static func skillDocPaths(database: AppDatabase?) async -> [String: String] {
        guard let database else { return [:] }
        return (try? await database.dbQueue.read { db -> [String: String] in
            var map: [String: String] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT id, doc_path FROM skills WHERE enabled = 1"
            ) {
                map[row["id"]] = row["doc_path"]
            }
            return map
        }) ?? [:]
    }

    /// 阶段 pitfalls（Task 4.8：确定性路由）；数据库缺失 / 路由为空静默跳过。
    nonisolated private static func stagePitfalls(
        stage: LLMStage, database: AppDatabase?
    ) -> [PitfallsRouter.Entry] {
        guard let database else { return [] }
        return (try? PitfallsRouter.pitfalls(for: stage, database: database)) ?? []
    }

    /// 记忆段裁剪：超预算从尾部逐行丢（版本 scope 前置天然保留；
    /// 假设态校准文本排在段尾最先丢——近似「截最旧、保版本」）。
    nonisolated private static func trimMemory(
        _ text: String, budget: Int, trimmed: inout [ContextSegment]
    ) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while TokenBreakdown.estimate(lines.joined(separator: "\n")) > budget {
            guard let last = lines.lastIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) else { break }
            lines.remove(at: last)
            if !trimmed.contains(.memory) { trimmed.append(.memory) }
        }
        return lines.joined(separator: "\n")
    }
}
