//
//  ContextBuilderTests.swift
//  pm_workerTests
//
//  M4 Task 4.1 + 4.8：Context Builder 唯一注入收口 + pitfalls 确定性路由进自检清单。
//  - 规则层常驻注入（预算极小也不裁）
//  - 记忆段注入 + 假设态校准文本排段尾（预算压力下最先被裁的位置语义）
//  - token 预算裁剪优先级（history → retrieval → skillBodies → memory；rules 永不裁）
//  - 技能正文渐进式披露（命中才注入正文，未命中不注入）
//  - 技能路由「语义为准 + 判定兜底」（2026-09-14 意图优先 → 2026-09-15 混合路由）：
//    语义命中按 skillQuery 注入；本地零命中时判定通道（skillJudge 闭包，测试用假实现）
//    接住——判空即不注入；锚点兜底仅限「判定不可用 + 技能表无可用向量」的链路全断态，
//    命中计数收口为「正文实际进上下文才算」
//  - pitfalls 确定性路由进 system prompt 尾部自检清单
//  - 空段省略 + ContextAssembly Codable 往返
//  - SessionStore.trimmedHistory 成对丢最旧整轮
//  不依赖网络：DeterministicHashEmbedder + 临时 AppDatabase，直接 INSERT 测试行。
//

import XCTest
import GRDB
@testable import pm_worker

/// 判定通道探针（测试假实现）：记录调用与入参，返回预设结果——
/// 判定通道是「本地零命中才调用」的可注入闭包，测试由此免网络断言调用时机与结果。
private final class JudgeProbe {
    var result: [String]?
    var calls = 0
    var lastQuery: String?
    var lastCandidateIDs: [String] = []

    init(result: [String]?) {
        self.result = result
    }
}

final class ContextBuilderTests: XCTestCase {
    var tempRoot: URL!
    var database: AppDatabase!
    let embedder = DeterministicHashEmbedder()

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-context-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        do {
            database = try AppDatabase(indexURL: tempRoot.appendingPathComponent("index.sqlite"))
        } catch {
            XCTFail("AppDatabase 初始化失败: \(error)")
        }
    }

    override func tearDown() {
        // 先释放 AppDatabase（同步关闭 GRDB 连接）再删临时目录，
        // 避免 macOS sqlite 的「vnode unlinked while in use」API 告警。
        database = nil
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - 测试行插入（与 RetrievalTests 同口径）

    private func insertCard(id: String, projectId: String, content: String) throws {
        let vector = DeterministicHashEmbedder.vector(for: content)
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO knowledge_points
                        (id, project_id, content, source_type, source_ref, embedding,
                         annotation_count, confidence, superseded_by, created_at)
                    VALUES (?, ?, ?, 'methodology', '', ?, 0, 1.0, NULL, '2026-09-11')
                    """,
                arguments: [id, projectId, content, VectorMath.encode(vector)]
            )
        }
    }

    private func insertSkill(
        id: String,
        name: String,
        whenToUse: String,
        bestFor: [String] = [],
        tags: [String] = [],
        pitfalls: [String] = [],
        docPath: String = "/nonexistent/skill.md",
        withVector: Bool = true
    ) throws {
        // 与 IndexRebuilder 同口径：embedding 对 name + when_to_use + best_for + tags 编码；
        // withVector = false 复刻「零长度占位向量」索引失效态（旧重建路径遗留）
        let fourField = ([name, whenToUse] + bestFor + tags).joined(separator: "\n")
        let vector = withVector ? DeterministicHashEmbedder.vector(for: fourField) : []
        let encoder = JSONEncoder()
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO skills
                        (id, name, type, when_to_use, best_for, tags, pitfalls,
                         doc_path, embedding, hit_count, enabled)
                    VALUES (?, ?, 'component', ?, ?, ?, ?, ?, ?, 0, 1)
                    """,
                arguments: [
                    id, name, whenToUse,
                    String(decoding: try encoder.encode(bestFor), as: UTF8.self),
                    String(decoding: try encoder.encode(tags), as: UTF8.self),
                    String(decoding: try encoder.encode(pitfalls), as: UTF8.self),
                    docPath,
                    VectorMath.encode(vector),
                ]
            )
        }
    }

    /// 被测组装器（默认预算）。
    private func makeBuilder(
        budgets: [ContextSegment: Int] = ContextBuilder.defaultBudgets
    ) -> ContextBuilder {
        ContextBuilder(database: database, embedder: embedder, budgets: budgets)
    }

    // MARK: - 1. 规则层常驻注入（预算极小也不裁）

    func testRulesAlwaysInjectedAndNeverTrimmed() async {
        let builder = ContextBuilder(
            database: database, embedder: embedder,
            budgets: [.rules: 1]  // 规则预算压到 1——设计上规则层常驻永不裁
        )
        let assembly = await builder.assemble(
            stage: .clarify, project: "项目X", stageQuery: "一句话想法",
            memoryContext: "", calibration: []
        ) { injection in
            "骨架前缀。\n\(injection)\n骨架后缀。"
        }

        // 注入区必有规则段（测试环境 Bundle 无 rules/global.md → 走内置兜底文本）
        XCTAssertTrue(assembly.systemPrompt.contains("### 规则层（全局产品约束，常驻）"))
        // 兜底文本与 Bundle 文本均含该核心约束——两条路径都可断言
        XCTAssertTrue(assembly.systemPrompt.contains("不确认不推进"))
        // rules 永不记入 trimmed；实际 token 超出预算值也不裁
        XCTAssertFalse(assembly.breakdown.trimmed.contains(.rules))
        XCTAssertGreaterThan(assembly.breakdown.segments[.rules] ?? 0, 1)
    }

    // MARK: - 2. 记忆段注入 + 假设态校准文本排段尾

    func testMemoryInjectionWithCalibrationAtTail() async throws {
        let memoryText = "- [结论] 目标用户是独立开发者\n- [约束] 只做 macOS 桌面端"
        let calibration = [
            "📈 记忆校准（该方法论的历史使用倾向——假设态，未验证前不作硬约束）：\n"
                + "- [经验·假设态] 该用户偏好先看反例再定方案"
        ]
        let assembly = await makeBuilder().assemble(
            stage: .structure, project: "项目X", stageQuery: "结构设计",
            memoryContext: memoryText, calibration: calibration
        ) { "骨架。" + $0 }

        let prompt = assembly.systemPrompt
        XCTAssertTrue(prompt.contains("### 记忆（版本 > 项目，新覆盖旧，不得矛盾）"))
        XCTAssertTrue(prompt.contains("目标用户是独立开发者"))
        XCTAssertTrue(prompt.contains("[经验·假设态] 该用户偏好先看反例再定方案"))
        // 校准文本排记忆段尾（预算压力下最先被裁——design.md 校准注入语义）
        let memoryRange = try XCTUnwrap(prompt.range(of: "目标用户是独立开发者"))
        let calibrationRange = try XCTUnwrap(prompt.range(of: "[经验·假设态]"))
        XCTAssertLessThan(memoryRange.lowerBound, calibrationRange.lowerBound)
        // 组装产物回填校准原文（检查器展示）
        XCTAssertEqual(assembly.calibration, calibration)
        XCTAssertGreaterThan(assembly.breakdown.segments[.memory] ?? 0, 0)
    }

    // MARK: - 3. token 预算裁剪优先级（history → retrieval → skillBodies → memory）

    func testBudgetTrimmingPriority() async throws {
        // 技能正文 + 检索命中各一（预算压到极小 → 逐段让位）
        let skillBody = "BUDGET_SKILL_BODY_SENTINEL " + String(repeating: "很长的技能正文内容。", count: 200)
        let skillPath = tempRoot.appendingPathComponent("budget-skill.md").path
        try """
        ---
        name: 预算技能
        ---
        \(skillBody)
        """.write(to: URL(fileURLWithPath: skillPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "预算技能", name: "预算技能",
            whenToUse: "KANO 需求优先级排序时", docPath: skillPath
        )
        try insertCard(
            id: "kp-trim", projectId: "项目X",
            content: "KANO 模型将需求分为基本型、期望型、兴奋型三类，先分类再排优先级"
        )

        let builder = ContextBuilder(
            database: database, embedder: embedder,
            budgets: [.rules: 500, .memory: 5, .skillBodies: 5, .retrieval: 1, .history: 0]
        )
        let memoryText = (1...8)
            .map { "- [结论] 第\($0)条记忆结论，内容足够长以触发预算裁剪" }
            .joined(separator: "\n")
        let assembly = await builder.assemble(
            stage: .clarify, project: "项目X", stageQuery: "KANO 需求优先级排序",
            memoryContext: memoryText, calibration: []
        ) { $0 }

        // 历史预算 0 → 历史段整体让位（最低优先级，trimmed 首位）
        XCTAssertEqual(assembly.breakdown.trimmed.first, .history)
        XCTAssertEqual(assembly.breakdown.segments[.history], 0)
        // 检索预算 1 → 卡片行全裁（段省略）
        XCTAssertTrue(assembly.breakdown.trimmed.contains(.retrieval))
        XCTAssertFalse(assembly.systemPrompt.contains("### 检索参考"))
        // 技能正文预算 5 → 整块丢弃（不截断正文，保持技能完整性）
        XCTAssertTrue(assembly.breakdown.trimmed.contains(.skillBodies))
        XCTAssertFalse(assembly.systemPrompt.contains("BUDGET_SKILL_BODY_SENTINEL"))
        XCTAssertTrue(assembly.injectedSkillBodies.isEmpty)
        // 记忆预算 5 → 尾部逐行丢至空（段省略）
        XCTAssertTrue(assembly.breakdown.trimmed.contains(.memory))
        XCTAssertFalse(assembly.systemPrompt.contains("### 记忆"))
        XCTAssertLessThanOrEqual(assembly.breakdown.segments[.memory] ?? 99, 5)
        // rules 常驻不裁
        XCTAssertFalse(assembly.breakdown.trimmed.contains(.rules))
        XCTAssertTrue(assembly.systemPrompt.contains("### 规则层"))
        // trimmed 按优先级从低到高记录
        let expectedOrder: [ContextSegment] = [.history, .retrieval, .skillBodies, .memory]
        XCTAssertEqual(
            assembly.breakdown.trimmed,
            expectedOrder.filter { assembly.breakdown.trimmed.contains($0) }
        )
    }

    // MARK: - 4. 技能正文渐进式披露（命中才注入正文；意图 query 驱动技能命中）

    func testSkillBodyProgressiveDisclosureInAssembly() async throws {
        let xBody = "技能X正文：PROGRESSIVE_X_SENTINEL 先定访谈目标再列提纲"
        let yBody = "技能Y正文：PROGRESSIVE_Y_SENTINEL 摸清竞品格局"
        let xPath = tempRoot.appendingPathComponent("disclosure-x.md").path
        let yPath = tempRoot.appendingPathComponent("disclosure-y.md").path
        try """
        ---
        name: 技能X
        ---
        \(xBody)
        """.write(to: URL(fileURLWithPath: xPath), atomically: true, encoding: .utf8)
        try """
        ---
        name: 技能Y
        ---
        \(yBody)
        """.write(to: URL(fileURLWithPath: yPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "技能X", name: "技能X", whenToUse: "用户访谈前列提纲时", docPath: xPath
        )
        try insertSkill(
            id: "技能Y", name: "技能Y", whenToUse: "需要摸清竞品格局时", docPath: yPath
        )

        // 意图分流证明：stageQuery（卡片查询口径）与技能四字段零重合，
        // skillQuery（本轮用户消息）命中技能X——技能跟消息语义走、不跟阶段走
        let assembly = await makeBuilder().assemble(
            stage: .clarify, project: "项目X",
            stageQuery: "阶段产物锚定的卡片查询文本",
            skillQuery: "用户访谈前列提纲时",
            memoryContext: "", calibration: []
        ) { "骨架。" + $0 }

        // 命中技能正文注入（带 id 标头，按相关度降序）
        XCTAssertTrue(assembly.systemPrompt.contains("#### 技能：技能X"))
        XCTAssertTrue(assembly.systemPrompt.contains("PROGRESSIVE_X_SENTINEL"))
        // 未命中技能正文不注入——渐进式披露（E11 在组装层的证明）
        XCTAssertFalse(assembly.systemPrompt.contains("PROGRESSIVE_Y_SENTINEL"))
        XCTAssertEqual(assembly.injectedSkillBodies.count, 1)
        XCTAssertTrue(assembly.injectedSkillBodies[0].hasPrefix("技能X：\n"))
        // skillIds 与注入正文同口径（过预算裁剪后实际注入的技能 id）
        XCTAssertEqual(assembly.skillIds, ["技能X"])
        // 检索 trace 可观测（未命中技能进 unmatchedSkills；意图 query 留痕）
        let trace = try XCTUnwrap(assembly.retrieval)
        XCTAssertTrue(trace.unmatchedSkills.contains("技能Y"))
        XCTAssertFalse(trace.unmatchedSkills.contains("技能X"))
        XCTAssertEqual(trace.skillQuery, "用户访谈前列提纲时")
    }

    // MARK: - 4.5 意图优先 + 阶段锚点兜底（2026-09-14 技能路由改造）

    func testSkillInjectionFollowsIntentWithoutStageForcing() async throws {
        // 「语义技能」四字段与 stageQuery 重合（语义命中）；
        // 「高保真原型设计」是原型阶段钦定锚点——语义命中存在时不得注入（不再阶段强制）
        let semanticBody = "语义命中技能正文：SEMANTIC_ONLY_SENTINEL 摸清竞品格局"
        let semanticPath = tempRoot.appendingPathComponent("semantic-only.md").path
        try """
        ---
        name: 语义技能
        ---
        \(semanticBody)
        """.write(to: URL(fileURLWithPath: semanticPath), atomically: true, encoding: .utf8)
        let anchorBody = "锚点技能正文：STAGE_ANCHOR_SENTINEL 设计令牌先行再谈配色"
        let anchorPath = tempRoot.appendingPathComponent("stage-anchor.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        \(anchorBody)
        """.write(to: URL(fileURLWithPath: anchorPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "语义技能", name: "语义技能",
            whenToUse: "STAGE_QUERY_NEEDS_COMPETITIVE_LANDSCAPE", docPath: semanticPath
        )
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时", docPath: anchorPath
        )

        // skillQuery 缺省回退 stageQuery（旧行为兼容）：语义命中仅语义技能
        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "STAGE_QUERY_NEEDS_COMPETITIVE_LANDSCAPE",
            memoryContext: "", calibration: []
        ) { "骨架。" + $0 }

        XCTAssertTrue(assembly.systemPrompt.contains("#### 技能：语义技能"))
        // 锚点不注入：语义命中存在 = 意图已表达，阶段不再强制塞技能
        XCTAssertFalse(assembly.systemPrompt.contains("STAGE_ANCHOR_SENTINEL"))
        XCTAssertEqual(assembly.skillIds, ["语义技能"])
        // 计数收口：注入的语义技能 +1，未注入的锚点 0
        let counts = try await database.dbQueue.read { db -> [String: Int] in
            var map: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, hit_count FROM skills") {
                map[row["id"]] = row["hit_count"]
            }
            return map
        }
        XCTAssertEqual(counts["语义技能"], 1)
        XCTAssertEqual(counts["高保真原型设计"], 0)
    }

    func testSemanticMissInjectsNothingWhenSkillIndexReady() async throws {
        // 语义零命中（skillQuery 与技能四字段零重合）+ 索引可用（技能行带向量）
        // → 不注入任何技能正文（2026-09-15 定稿「语义为准」：离题提问 / 闲聊
        // 不得被塞阶段技能；旧口径在此会注入阶段锚点）
        let anchorPath = tempRoot.appendingPathComponent("stage-anchor.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        锚点技能正文：STAGE_ANCHOR_SENTINEL 设计令牌先行再谈配色
        """.write(to: URL(fileURLWithPath: anchorPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时", docPath: anchorPath
        )

        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "零命中查询墨水瓶",
            memoryContext: "", calibration: []
        ) { "骨架。" + $0 }

        // 技能段整段省略（零注入），锚点也不兜底
        XCTAssertFalse(assembly.systemPrompt.contains("### 技能正文"))
        XCTAssertFalse(assembly.systemPrompt.contains("STAGE_ANCHOR_SENTINEL"))
        XCTAssertTrue(assembly.skillIds.isEmpty)
        XCTAssertTrue(assembly.injectedSkillBodies.isEmpty)
        // 未注入不计命中数
        let anchorHits = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT hit_count FROM skills WHERE id = ?",
                arguments: ["高保真原型设计"]
            ) ?? 0
        }
        XCTAssertEqual(anchorHits, 0)
        // trace 可观测：索引可用（零命中 ≠ 通道失效）
        let trace = try XCTUnwrap(assembly.retrieval)
        XCTAssertEqual(trace.skillQuery, "零命中查询墨水瓶")
        XCTAssertEqual(trace.skillIndexReady, true)
    }

    func testStageAnchorFallsBackOnlyWhenSkillIndexHasNoVectors() async throws {
        // 索引失效态：技能行是零长度占位向量（旧同步重建路径遗留 / 未建索引）
        // → 检索通道等于不存在，阶段钦定锚点兜底注入（主干方法论不缺席）
        let anchorPath = tempRoot.appendingPathComponent("stage-anchor-no-vector.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        锚点技能正文：STAGE_ANCHOR_SENTINEL 设计令牌先行再谈配色
        """.write(to: URL(fileURLWithPath: anchorPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时",
            docPath: anchorPath, withVector: false
        )

        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "零命中查询墨水瓶",
            memoryContext: "", calibration: []
        ) { "骨架。" + $0 }

        XCTAssertTrue(assembly.systemPrompt.contains("#### 技能：高保真原型设计"))
        XCTAssertTrue(assembly.systemPrompt.contains("STAGE_ANCHOR_SENTINEL"))
        XCTAssertEqual(assembly.skillIds, ["高保真原型设计"])
        // 兜底注入计入命中数（正文实际进上下文 = 实际应用）
        let anchorHits = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT hit_count FROM skills WHERE id = ?",
                arguments: ["高保真原型设计"]
            ) ?? 0
        }
        XCTAssertEqual(anchorHits, 1)
        // trace 可观测：索引失效（无可用向量）
        let trace = try XCTUnwrap(assembly.retrieval)
        XCTAssertEqual(trace.skillIndexReady, false)
    }

    // MARK: - 4.6 判定兜底通道（混合路由，2026-09-15）

    func testJudgeChannelPicksSkillsWhenLocalMisses() async throws {
        // 本地零命中（口语化短句，词面兜不住）→ 判定通道接住：判出的技能正文注入
        let path = tempRoot.appendingPathComponent("judge-skill.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        判定命中技能正文：JUDGE_SENTINEL 按钮层级与点击反馈
        """.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时", docPath: path
        )

        let probe = JudgeProbe(result: ["高保真原型设计"])
        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "这个按钮应该放在哪里",  // 与技能四字段零重合（本地检索零命中）
            memoryContext: "", calibration: [],
            skillJudge: { query, candidates in
                probe.calls += 1
                probe.lastQuery = query
                probe.lastCandidateIDs = candidates.map(\.id)
                return probe.result
            }
        ) { "骨架。" + $0 }

        // 本地零命中才调用，判定查询 = 本轮消息（非 stageQuery），清单 = 启用技能
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(probe.lastQuery, "这个按钮应该放在哪里")
        XCTAssertEqual(probe.lastCandidateIDs, ["高保真原型设计"])
        XCTAssertTrue(assembly.systemPrompt.contains("#### 技能：高保真原型设计"))
        XCTAssertTrue(assembly.systemPrompt.contains("JUDGE_SENTINEL"))
        XCTAssertEqual(assembly.skillIds, ["高保真原型设计"])
        // 判定结果进检查器报告
        XCTAssertEqual(assembly.skillJudgeReport?.available, true)
        XCTAssertEqual(assembly.skillJudgeReport?.picked, ["高保真原型设计"])
        // 注入才算命中（与语义命中同口径）
        let hits = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT hit_count FROM skills WHERE id = ?",
                arguments: ["高保真原型设计"]
            ) ?? 0
        }
        XCTAssertEqual(hits, 1)
    }

    func testJudgeEmptyResultInjectsNothing() async throws {
        // 判定可用但判空（离题 / 闲聊 / 纯推进语）→ 不注入，且不再走锚点
        // （判定可用 = 已经问过模型，索引可用与否都不再兜底塞技能）
        let anchorPath = tempRoot.appendingPathComponent("judge-empty-anchor.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        锚点技能正文：STAGE_ANCHOR_SENTINEL
        """.write(to: URL(fileURLWithPath: anchorPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时",
            docPath: anchorPath, withVector: false  // 索引失效也不得掩盖判定结论
        )

        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "我想问一下马斯克是谁？",
            memoryContext: "", calibration: [],
            skillJudge: { _, _ in [] }
        ) { "骨架。" + $0 }

        XCTAssertFalse(assembly.systemPrompt.contains("### 技能正文"))
        XCTAssertFalse(assembly.systemPrompt.contains("STAGE_ANCHOR_SENTINEL"))
        XCTAssertTrue(assembly.skillIds.isEmpty)
        XCTAssertEqual(assembly.skillJudgeReport?.available, true)
        XCTAssertEqual(assembly.skillJudgeReport?.picked, [])
        let anchorHits = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT hit_count FROM skills WHERE id = ?",
                arguments: ["高保真原型设计"]
            ) ?? 0
        }
        XCTAssertEqual(anchorHits, 0)
    }

    func testJudgeSkippedWhenLocalHits() async throws {
        // 本地语义命中 → 判定通道零调用（混合路由的「本地先筛、模糊才判」）
        let xPath = tempRoot.appendingPathComponent("judge-skip-x.md").path
        try """
        ---
        name: 技能X
        ---
        技能X正文：LOCAL_HIT_SENTINEL
        """.write(to: URL(fileURLWithPath: xPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "技能X", name: "技能X", whenToUse: "用户访谈前列提纲时", docPath: xPath
        )

        let probe = JudgeProbe(result: ["技能X"])
        let assembly = await makeBuilder().assemble(
            stage: .clarify, project: "项目X",
            stageQuery: "阶段查询文本",
            skillQuery: "用户访谈前列提纲时",  // 与技能四字段重合 → 本地命中
            memoryContext: "", calibration: [],
            skillJudge: { query, candidates in
                probe.calls += 1
                return probe.result
            }
        ) { "骨架。" + $0 }

        XCTAssertEqual(probe.calls, 0)
        XCTAssertNil(assembly.skillJudgeReport)  // 未调用 → 无报告
        XCTAssertTrue(assembly.systemPrompt.contains("LOCAL_HIT_SENTINEL"))
        XCTAssertEqual(assembly.skillIds, ["技能X"])
    }

    func testJudgeUnavailableFallsBackToAnchorOnlyWhenIndexHasNoVectors() async throws {
        // 判定通道不可用（nil = 网络 / 解析失败）+ 索引失效（零向量）→ 锚点兜底（链路全断态）
        let anchorPath = tempRoot.appendingPathComponent("judge-nil-anchor.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        锚点技能正文：STAGE_ANCHOR_SENTINEL
        """.write(to: URL(fileURLWithPath: anchorPath), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时",
            docPath: anchorPath, withVector: false
        )

        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "零命中查询墨水瓶",
            memoryContext: "", calibration: [],
            skillJudge: { _, _ in nil }
        ) { "骨架。" + $0 }

        XCTAssertTrue(assembly.systemPrompt.contains("STAGE_ANCHOR_SENTINEL"))
        XCTAssertEqual(assembly.skillIds, ["高保真原型设计"])
        XCTAssertEqual(assembly.skillJudgeReport?.available, false)
    }

    func testJudgeUnavailableWithReadyIndexInjectsNothing() async throws {
        // 判定通道不可用 + 索引可用 → 保守不注入（零命中 = 没有依据，不塞阶段技能）
        let path = tempRoot.appendingPathComponent("judge-nil-ready.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        锚点技能正文：STAGE_ANCHOR_SENTINEL
        """.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时", docPath: path
        )

        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "零命中查询墨水瓶",
            memoryContext: "", calibration: [],
            skillJudge: { _, _ in nil }
        ) { "骨架。" + $0 }

        XCTAssertFalse(assembly.systemPrompt.contains("### 技能正文"))
        XCTAssertTrue(assembly.skillIds.isEmpty)
        XCTAssertEqual(assembly.skillJudgeReport?.available, false)
    }

    func testJudgeUnknownNamesIgnored() async throws {
        // 判定幻觉名（不在技能清单里）被忽略——只有清单内的技能能注入
        let path = tempRoot.appendingPathComponent("judge-hallucination.md").path
        try """
        ---
        name: 高保真原型设计
        ---
        判定命中技能正文：JUDGE_SENTINEL
        """.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try insertSkill(
            id: "高保真原型设计", name: "高保真原型设计",
            whenToUse: "原型阶段把页面转成高保真彩色 UI 效果图时", docPath: path
        )

        let assembly = await makeBuilder().assemble(
            stage: .prototype, project: "项目X",
            stageQuery: "蓝染工坊检测站",
            skillQuery: "这个按钮应该放在哪里",
            memoryContext: "", calibration: [],
            skillJudge: { _, _ in ["不存在的技能", "高保真原型设计"] }
        ) { "骨架。" + $0 }

        XCTAssertEqual(assembly.skillIds, ["高保真原型设计"])
        XCTAssertEqual(assembly.skillJudgeReport?.picked, ["不存在的技能", "高保真原型设计"])
    }

    // MARK: - 5. pitfalls 确定性路由进自检清单（Task 4.8）

    func testPitfallsRoutedIntoSelfChecklistTail() async throws {
        try insertSkill(
            id: "原型技能", name: "原型技能", whenToUse: "产出高保真原型时",
            tags: ["原型", "wireframe"], pitfalls: ["p1", "p2"]
        )
        try insertSkill(
            id: "竞品技能", name: "竞品技能", whenToUse: "摸清竞品格局",
            tags: ["竞品"], pitfalls: ["q1"]
        )

        let builder = makeBuilder()
        let assembly = await builder.assemble(
            stage: .prototype, project: "项目X", stageQuery: "原型页面",
            memoryContext: "", calibration: []
        ) { _ in "PROMPT_SKELETON_END" }

        // 自检清单 + 命中阶段技能的全部 pitfalls
        XCTAssertTrue(assembly.systemPrompt.contains("## 自检清单（pitfalls 确定性路由）"))
        XCTAssertTrue(assembly.systemPrompt.contains("- [原型技能] p1"))
        XCTAssertTrue(assembly.systemPrompt.contains("- [原型技能] p2"))
        // 无关阶段技能的 pitfalls 不进（确定性路由只按当前阶段关键词）
        XCTAssertFalse(assembly.systemPrompt.contains("q1"))
        XCTAssertEqual(assembly.pitfalls.count, 2)
        XCTAssertTrue(assembly.pitfalls.allSatisfy { $0.source == "pitfalls确定性路由" })
        // 拼到 system prompt 尾部：清单在 promptBuilder 骨架之后
        let skeleton = try XCTUnwrap(assembly.systemPrompt.range(of: "PROMPT_SKELETON_END"))
        let checklist = try XCTUnwrap(assembly.systemPrompt.range(of: "## 自检清单"))
        XCTAssertLessThan(skeleton.lowerBound, checklist.lowerBound)

        // 无关键词映射的阶段（classify）→ 不产自检清单
        let classifyAssembly = await builder.assemble(
            stage: .classify, project: "项目X", stageQuery: "任意",
            memoryContext: "", calibration: []
        ) { "骨架。" + $0 }
        XCTAssertFalse(classifyAssembly.systemPrompt.contains("自检清单（pitfalls"))
        XCTAssertTrue(classifyAssembly.pitfalls.isEmpty)
    }

    // MARK: - 6. 空段省略 + ContextAssembly Codable 往返

    func testEmptySectionsOmittedAndAssemblyCodable() async throws {
        var capturedInjection = ""
        let assembly = await makeBuilder().assemble(
            stage: .clarify, project: "项目X", stageQuery: "一句话想法",
            memoryContext: "   \n  ", calibration: ["  ", ""]
        ) { injection in
            capturedInjection = injection
            return "骨架。" + injection
        }

        // 空段省略：记忆/技能正文/检索段整段不出现
        let prompt = assembly.systemPrompt
        XCTAssertFalse(prompt.contains("### 记忆"))
        XCTAssertFalse(prompt.contains("### 技能正文"))
        XCTAssertFalse(prompt.contains("### 检索参考"))
        // 规则层常驻 → 注入区非空（promptBuilder 必拿到规则段）
        XCTAssertTrue(capturedInjection.contains("### 规则层"))
        // 空库无命中但 trace 仍可观测
        let trace = try XCTUnwrap(assembly.retrieval)
        XCTAssertTrue(trace.hits.isEmpty)
        XCTAssertTrue(assembly.pitfalls.isEmpty)
        XCTAssertTrue(assembly.breakdown.trimmed.isEmpty)
        XCTAssertEqual(assembly.stage, LLMStage.clarify.rawValue)
        XCTAssertEqual(assembly.query, "一句话想法")

        // ContextAssembly Codable 往返（检查器持久化契约）
        let data = try JSONEncoder().encode(assembly)
        let decoded = try JSONDecoder().decode(ContextAssembly.self, from: data)
        XCTAssertEqual(decoded, assembly)
    }

    // MARK: - 7. HistoryProjection.trimmedHistory：成对丢最旧整轮

    func testSessionStoreTrimmedHistoryRoundPairs() {
        let system = ChatMessage(role: .system, content: "系统提示词（组装后的阶段 prompt）")
        func round(_ n: Int, repeatCount: Int) -> [ChatMessage] {
            [
                ChatMessage(
                    role: .user,
                    content: "第\(n)轮提问：" + String(repeating: "细节", count: repeatCount)
                ),
                ChatMessage(
                    role: .assistant,
                    content: "第\(n)轮回答：" + String(repeating: "说明", count: repeatCount)
                ),
            ]
        }
        let messages = [system] + round(1, repeatCount: 30)
            + round(2, repeatCount: 30) + round(3, repeatCount: 30)

        // 预算充足 → 原样保留
        XCTAssertEqual(HistoryProjection.trimmedHistory(messages, budget: 10_000), messages)

        // 预算只装得下最新轮 → 从最旧起成对丢（user+assistant 不拆对）
        let trimmed = HistoryProjection.trimmedHistory(messages, budget: 200)
        XCTAssertEqual(trimmed.first, system)
        let rest = Array(trimmed.dropFirst())
        XCTAssertFalse(rest.isEmpty)
        XCTAssertTrue(rest.contains { $0.content.contains("第3轮") })    // 最新轮保住
        XCTAssertFalse(rest.contains { $0.content.contains("第1轮") })   // 最旧轮成对丢
        // 轮内成对：不出现连续两条 user 的断头轮
        var danglingUser = false
        var previous: ChatMessage?
        for message in rest {
            if previous?.role == .user && message.role == .user { danglingUser = true }
            previous = message
        }
        XCTAssertFalse(danglingUser)
        // 保留的历史总量 ≤ 预算
        XCTAssertLessThanOrEqual(
            TokenBreakdown.estimate(rest.map(\.content).joined(separator: "\n")),
            200
        )

        // 预算 ≤ 0 → 只剩 system（历史段整体让位）
        XCTAssertEqual(HistoryProjection.trimmedHistory(messages, budget: 0), [system])
        // 首条 system 不占历史预算：system 很长也不影响裁剪判定
        let longSystem = ChatMessage(
            role: .system, content: String(repeating: "很长的系统提示词。", count: 500)
        )
        let withLongSystem = [longSystem] + round(1, repeatCount: 5)
        XCTAssertEqual(HistoryProjection.trimmedHistory(withLongSystem, budget: 50), withLongSystem)
    }
}
