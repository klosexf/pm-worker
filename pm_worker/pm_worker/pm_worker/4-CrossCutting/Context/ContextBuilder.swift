//
//  ContextBuilder.swift
//  pm_worker
//
//  Context Builder——唯一注入收口（M4 Task 4.1，design.md §6.3/§6.4）：
//  五段组装（规则 / 记忆 / 技能正文 / 检索 / 历史）+ token 预算分配 +
//  超预算按优先级裁剪；Task 4.8：pitfalls 确定性路由进自检清单，拼到
//  system prompt 尾部。2026-09-14：技能路由改「意图优先、阶段兜底」——
//  技能语义命中走 skillQuery（发送轮 = 本轮用户消息），检索零命中才注入
//  阶段钦定锚点技能（每阶段 1 个，PitfallsRouter.stageAnchorSkills）；
//  旧「阶段关键词全量确定性注入」废弃（高频词滥匹配会压过消息意图）。
//  2026-09-15 修订（用户钦定「语义为准」+ 判定兜底）：技能正文 = 本地语义命中
//  （AppModel 发送轮只用本轮消息，不混历史）→ 零命中时由判定通道（classify 档小模型
//  读技能清单判「本轮真正需要哪些技能」，AppModel.judgeSkills 接线）接住——判空即
//  不注入（离题 / 闲聊不得被塞阶段技能）；阶段锚点仅在「判定不可用 + 索引无向量」
//  的链路全断态兜底。
//  命中计数收口为「正文实际进上下文才算」（语义 + 判定 + 锚点同口径，注入后统一计数）。
//  AppModel 是唯一调用方（组装结果写回 lastAssembly，检查器 ⌘D 读取）。
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
    /// - skillQuery: 技能检索意图查询（最近用户消息含本轮；nil 回退 stageQuery——
    ///   旧行为兼容，AppModel 主线恒传）
    /// - skillJudge: 技能判定兜底通道（混合路由，2026-09-15 用户钦定）——本地检索
    ///   零命中时调用，入参（判定查询, 技能清单[(id, when_to_use)]），返回判出的技能名
    ///   （[] = 判定为不需要技能；nil = 通道不可用）。nil = 未接线（旧行为：零命中退锚点）
    /// - returns: systemPrompt = 骨架 + 规则层冻结段 + 自检清单 pitfalls（易变的
    ///   记忆/技能正文/检索不在此，见 injectionText + ContextTail 尾条协议）；历史段预算见 breakdown
    func assemble(
        stage: LLMStage,
        project: String,
        stageQuery: String,
        skillQuery: String? = nil,
        memoryContext: String,
        calibration: [String],
        skillJudge: (@MainActor (String, [(id: String, whenToUse: String)]) async -> [String]?)? = nil,
        promptBuilder: (String) -> String
    ) async -> ContextAssembly {
        // ── ① 规则层（Bundle rules/global.md；读不到走内置兜底；常驻永不裁）
        let rulesText = Self.loadGlobalRules()

        // ── ② 检索（embedder 抛错不阻塞：trace 仍产出，hits 为空）。
        //    双查询分流：卡片走 stageQuery（阶段产物锚定，保连续性），
        //    技能走 skillQuery（消息意图，意图优先路由主通道）。
        var trace = RetrievalTrace(
            query: stageQuery, hits: [],
            filteredCrossProject: 0, unmatchedSkills: [], durationMs: 0
        )
        if let retriever {
            trace = (try? await retriever.search(
                query: stageQuery, project: project, topK: Self.retrievalTopK,
                skillQuery: skillQuery, countsSkillHits: false
            )) ?? trace
        }

        // ── ③ 技能正文（语义为准 + 判定兜底，2026-09-15）：
        //    a) 本地检索命中注入（零额外开销）：skillQuery 与技能四字段向量的相关度降序，
        //       命中才 loadSkillBody（渐进式披露；Retriever 命中只带 when_to_use 摘要，
        //       doc_path 在此按命中 id 补查）——技能跟消息语义走，不跟阶段走。
        //    b) 判定兜底通道：本地零命中时让 classify 档小模型读技能清单判「本轮真正需要
        //       哪些技能」——口语化说法（「这个按钮放哪」）本地词面兜不住时由它接住；
        //       判空 = 本轮不需要技能，不注入（离题提问 / 闲聊即此路径，用户钦定）。
        //    c) 阶段锚点兜底仅限「判定也不可用 + 技能索引无向量」的链路全断态——
        //       保「主干方法论不因检索失效而缺席」；索引可用或判定可用时都不再锚点。
        //       预算压力下锚点排最尾，最先让位。
        let catalog = await Self.skillCatalog(database: database)
        var skillBlocks: [(id: String, body: String)] = []

        let skillHits = trace.hits.filter { $0.library == .skills }  // 已按相似度降序
        for hit in skillHits {
            guard let entry = catalog[hit.id],
                  let body = Retriever.loadSkillBody(docPath: entry.docPath),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            skillBlocks.append((id: hit.id, body: body))
        }

        var judgeReport: SkillJudgeReport?
        if skillBlocks.isEmpty, let skillJudge {
            let judgeQuery = skillQuery ?? stageQuery
            let candidates = catalog
                .map { (id: $0.key, whenToUse: $0.value.whenToUse) }
                .sorted { $0.id < $1.id }
            let picked = await skillJudge(judgeQuery, candidates)
            judgeReport = SkillJudgeReport(
                query: judgeQuery, available: picked != nil, picked: picked ?? []
            )
            for id in picked ?? [] {
                guard let entry = catalog[id],
                      let body = Retriever.loadSkillBody(docPath: entry.docPath),
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                skillBlocks.append((id: id, body: body))
            }
        }
        if skillBlocks.isEmpty,
           judgeReport?.available != true,
           trace.skillIndexReady != true,
           let anchorId = PitfallsRouter.stageAnchorSkills[stage],
           let entry = catalog[anchorId],
           let body = Retriever.loadSkillBody(docPath: entry.docPath),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skillBlocks.append((id: anchorId, body: body))
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

        // 记忆：MemoryStore 排序保证版本 scope 前置 + 新条目在前，从尾部逐行丢；
        // 约束/否决项为保护层（对 PM 工具，约束被悄悄丢掉 = 回答跑偏），永不裁
        let memoryBudget = budgets[.memory] ?? Self.defaultBudgets[.memory]!
        memoryText = Self.trimMemory(memoryText, budget: memoryBudget, trimmed: &trimmed)

        // 技能正文：丢相关度最低的整块（不截断正文，保持技能完整性；
        // 语义命中在前，阶段锚点排最尾——预算压力下锚点最先让位）
        let skillBudget = budgets[.skillBodies] ?? Self.defaultBudgets[.skillBodies]!
        while TokenBreakdown.estimate(skillBlocks.map(\.body).joined(separator: "\n")) > skillBudget,
              !skillBlocks.isEmpty {
            skillBlocks.removeLast()
            if !trimmed.contains(.skillBodies) { trimmed.append(.skillBodies) }
        }

        // 命中计数收口：正文实际进了本轮上下文 = 实际应用（语义命中 + 锚点同口径，
        // 过预算裁剪后的最终注入集）。写失败静默：计数是观测数据，不阻塞组装。
        Self.bumpSkillHitCounts(ids: skillBlocks.map(\.id), database: database)

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

        // ── ⑦ 动态材料文本（空段省略；整体为空 → 无尾条）：
        //     记忆/技能正文/检索每轮随语义命中与记忆收纳变化——不嵌入 systemPrompt
        //     （否则其后全部对话历史的前缀缓存连坐失效），经 ContextTail 尾条协议
        //     由 SessionStore 追加在当前用户消息之后。规则层是冻结段，不在此（见 ⑧）。
        var sections: [String] = []
        if !memoryText.isEmpty {
            sections.append("### 记忆（版本 > 项目，新覆盖旧，不得矛盾）\n\(memoryText)")
        }
        if !skillBlocks.isEmpty {
            let blocks = skillBlocks.map { "#### 技能：\($0.id)\n\($0.body)" }
                .joined(separator: "\n\n")
            sections.append("### 技能正文（语义命中 / 判定兜底，命中才注入）\n\(blocks)")
        }
        if !retrievalLines.isEmpty {
            sections.append("### 检索参考（方法论卡片）\n" + retrievalLines.joined(separator: "\n"))
        }
        let injection = sections.joined(separator: "\n\n")

        // ── ⑧ 完整 system prompt（promptBuilder 骨架 + 规则层冻结段）
        //     + pitfalls 自检清单（Task 4.8：确定性路由，拼到尾部）。
        //     promptBuilder 恒收 ""——动态材料不再嵌入骨架注入位（AgentPrompts 的
        //     injection 参数保留作直调兼容，主线恒空）；规则层静态常驻，留冻结段
        //     （约束权威性 + 跨轮次字节级一致的可缓存前缀）。
        var systemPrompt = promptBuilder("")
        systemPrompt += "\n\n### 规则层（全局产品约束，常驻）\n\(rulesText)"
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
            injectionText: injection,
            injectedSkillBodies: skillBlocks.map { "\($0.id)：\n\($0.body)" },
            calibration: calibration,
            pitfalls: pitfalls,
            createdAt: ISO8601.timestamp(),
            skillIds: skillBlocks.map(\.id),
            skillJudgeReport: judgeReport
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

    /// 技能清单（一次读全量启用技能）：id →（doc_path, when_to_use）。
    /// doc_path 供命中 / 判定后加载正文；when_to_use 供判定通道组提示词。
    /// Row 非 Sendable：异步 read 闭包内投影成 Sendable 字典再带出。
    /// internal：AppModel 工具检索（load_skill）共用同一 catalog 口径。
    nonisolated static func skillCatalog(
        database: AppDatabase?
    ) async -> [String: (docPath: String, whenToUse: String)] {
        guard let database else { return [:] }
        return (try? await database.dbQueue.read { db -> [String: (docPath: String, whenToUse: String)] in
            var map: [String: (docPath: String, whenToUse: String)] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT id, doc_path, when_to_use FROM skills WHERE enabled = 1"
            ) {
                map[row["id"]] = (docPath: row["doc_path"], whenToUse: row["when_to_use"])
            }
            return map
        }) ?? [:]
    }

    /// 确定性注入技能的命中计数（技能库 UI 的 hit_count 数据源；口径同 Retriever 语义命中——
    /// 正文实际进了本轮上下文即算命中）。写失败静默：计数是观测数据，不阻塞组装。
    /// internal：load_skill 工具把正文拉进对话上下文，同样计数。
    nonisolated static func bumpSkillHitCounts(ids: [String], database: AppDatabase?) {
        guard let database, !ids.isEmpty else { return }
        try? database.dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE skills SET hit_count = hit_count + 1 WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// 阶段 pitfalls（Task 4.8：确定性路由）；数据库缺失 / 路由为空静默跳过。
    nonisolated private static func stagePitfalls(
        stage: LLMStage, database: AppDatabase?
    ) -> [PitfallsRouter.Entry] {
        guard let database else { return [] }
        return (try? PitfallsRouter.pitfalls(for: stage, database: database)) ?? []
    }

    /// 记忆段裁剪：超预算从尾部逐行丢（版本 scope 前置 + 新条目在前 ≈「截最旧」；
    /// 假设态校准文本排在段尾最先丢）。约束 / 否决项为保护层永不裁——
    /// 保护行占满预算时停止裁剪（宁超勿丢），不产生死循环。
    nonisolated private static func trimMemory(
        _ text: String, budget: Int, trimmed: inout [ContextSegment]
    ) -> String {
        // 与 AgentPrompts.formatMemory 的行格式耦合：约束 / 否决项为保护行
        // （含 [全局] 来源前缀的行同样命中——按标记子串匹配，不限前缀位置）
        let protectedMarkers = ["[约束]", "[否决项]"]
        func isProtected(_ line: String) -> Bool {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            return protectedMarkers.contains { trimmedLine.contains($0) }
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while TokenBreakdown.estimate(lines.joined(separator: "\n")) > budget {
            // 从尾部找最后一条「可丢」行（跳过保护行）；全是保护行 → 停止
            guard let last = lines.lastIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isProtected($0)
            }) else { break }
            lines.remove(at: last)
            if !trimmed.contains(.memory) { trimmed.append(.memory) }
        }
        return lines.joined(separator: "\n")
    }
}
