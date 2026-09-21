//
//  P0AgentCapabilityTests.swift
//  pm_workerTests
//
//  P0 三项能力升级的回归面：
//  - 记忆相关性注入（relevanceScore / injectionContext(rankedFor:)：硬边界前置、
//    同层相关性优先于时间序）
//  - 记忆工具通道（addToolEntry kind 白名单 + 假设态落库；searchEntries；
//    save_memory / recall_memory 执行器的 mock 路径）
//  - 计划提案协议（parsePlanProposal 与自宣 plan 块互不串台、归一化 clamp；
//    approvedPlanSection 注入段格式）
//  - LLMSettings.planProposalsEnabled 旧存量解码兼容
//  磁盘用 PMAgentStore.rootOverride 临时目录，不依赖网络。
//

import XCTest
@testable import pm_worker

final class P0AgentCapabilityTests: XCTestCase {
    var tempRoot: URL!
    let project = "测试项目"
    let version = "v1"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-p0-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        PMAgentStore.rootOverride = nil
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func seedMemoryLine(entry: MemoryEntry) throws {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "seed", role: .system,
            content: "seed", think: nil, memory: entry,
            createdAt: ISO8601.timestamp()
        )
        try PMAgentStore.appendLine(line, to: url)
    }

    private func makeEntry(
        kind: MemoryEntry.Kind, content: String, createdAt: String
    ) -> MemoryEntry {
        MemoryEntry(
            scope: .project, scopeId: project, kind: kind,
            content: content, createdAt: createdAt
        )
    }

    // MARK: - relevanceScore（词面 2-gram）

    func testRelevanceScoreBasic() {
        XCTAssertGreaterThan(
            MemoryStore.relevanceScore(content: "UI 全部走深色模式适配", query: "深色模式"), 0
        )
        XCTAssertEqual(
            MemoryStore.relevanceScore(content: "支付渠道只接微信", query: "深色模式"), 0
        )
        // 过短查询不计分（单字噪音大）
        XCTAssertEqual(MemoryStore.relevanceScore(content: "深色模式", query: "深"), 0)
    }

    func testRelevanceScoreWholePhraseBonus() {
        let phrase = MemoryStore.relevanceScore(content: "先做核心流程再做边缘页", query: "核心流程")
        let partial = MemoryStore.relevanceScore(content: "心流状态与业务边缘", query: "核心流程")
        XCTAssertGreaterThan(phrase, partial)
    }

    // MARK: - 相关性排序注入

    func testRankedInjectionPutsHardBoundaryFirstAndRelevantNext() throws {
        try seedMemoryLine(entry: makeEntry(
            kind: .constraint, content: "零外部依赖硬约束", createdAt: "2026-09-01T00:00:00Z"
        ))
        try seedMemoryLine(entry: makeEntry(
            kind: .conclusion, content: "首页改版重点在搜索入口", createdAt: "2026-09-02T00:00:00Z"
        ))
        try seedMemoryLine(entry: makeEntry(
            kind: .conclusion, content: "后台任务用静默通知", createdAt: "2026-09-30T00:00:00Z"
        ))
        let store = MemoryStore(project: project, version: version)
        let ranked = store.injectionContext(rankedFor: "首页 搜索入口")
        let lines = ranked.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("零外部依赖硬约束"), "硬边界恒前置：\(lines[0])")
        XCTAssertTrue(lines[1].contains("搜索入口"), "相关结论先于更新的无关结论：\(lines[1])")
        XCTAssertTrue(lines[2].contains("静默通知"))
        // 无查询时保持旧序（同层新在前，不参与相关性排序）
        let plain = store.injectionContext
        XCTAssertTrue(plain.split(separator: "\n")[0].contains("静默通知"))
    }

    // MARK: - addToolEntry / searchEntries

    func testAddToolEntryRejectsHardBoundaryKinds() {
        XCTAssertNotNil(MemoryStore.addToolEntry(
            project: project, version: version, kind: .constraint, content: "模型自封约束"
        ))
        XCTAssertNotNil(MemoryStore.addToolEntry(
            project: project, version: version, kind: .rejection, content: "模型自封否决"
        ))
    }

    func testAddToolEntryExperienceLandsAsHypothesis() throws {
        XCTAssertNil(MemoryStore.addToolEntry(
            project: project, version: version, kind: .experience, content: "PRD 只保留五章结构"
        ))
        let hits = MemoryStore.searchEntries(
            project: project, version: version, query: "PRD 五章"
        )
        XCTAssertEqual(hits.count, 1)
        let entry = try XCTUnwrap(hits.first)
        XCTAssertEqual(entry.confidence, MemoryStore.experienceHypothesisConfidence)
        XCTAssertEqual(entry.sourceRef, "模型主动记录")
        // 经验条目会进注入（项目级 memory.jsonl 在池读序内）
        let store = MemoryStore(project: project, version: version)
        XCTAssertTrue(store.injectionContext.contains("PRD 只保留五章结构"))
    }

    func testSearchEntriesRankedAndLimited() throws {
        for i in 0..<10 {
            XCTAssertNil(MemoryStore.addToolEntry(
                project: project, version: version, kind: .conclusion,
                content: "结论\(i)：性能预算是硬指标"
            ))
        }
        XCTAssertNil(MemoryStore.addToolEntry(
            project: project, version: version, kind: .conclusion, content: "无关事项"
        ))
        let hits = MemoryStore.searchEntries(
            project: project, version: version, query: "性能预算", limit: 3
        )
        XCTAssertEqual(hits.count, 3)
        XCTAssertTrue(hits.allSatisfy { $0.content.contains("性能预算") })
    }

    // MARK: - save_memory / recall_memory 执行器

    private func makeToolContext(
        memorySave: ((String, String) -> String?)? = nil,
        memorySearch: ((String) -> [String])? = nil
    ) -> AgentToolContext {
        AgentToolContext(
            settings: LLMSettings(stages: [:], maxTokensPerRun: 1000),
            project: project, version: version, sessionId: "s",
            isReleased: false,
            skillSearch: { _ in [] },
            submitAnalysis: { _ in },
            memorySave: memorySave,
            memorySearch: memorySearch
        )
    }

    func testSaveMemoryToolWritesViaContextClosure() async {
        var captured: (String, String)?
        let ctx = makeToolContext(memorySave: { kind, content in
            captured = (kind, content)
            return nil
        })
        let result = await SaveMemoryTool().execute(
            argumentsJSON: "{\"kind\":\"conclusion\",\"content\":\"只保留五章\"}", ctx: ctx
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(captured?.0, "conclusion")
        XCTAssertEqual(captured?.1, "只保留五章")
        XCTAssertTrue(result.forLLM.contains("结论态"))
    }

    func testSaveMemoryToolRejectsHardBoundaryKind() async {
        let ctx = makeToolContext(memorySave: { _, _ in nil })
        let result = await SaveMemoryTool().execute(
            argumentsJSON: "{\"kind\":\"constraint\",\"content\":\"想自封约束\"}", ctx: ctx
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("只支持"))
    }

    func testMemoryToolsUnavailableWithoutWiring() async {
        let ctx = makeToolContext()
        let save = await SaveMemoryTool().execute(
            argumentsJSON: "{\"content\":\"x\"}", ctx: ctx
        )
        XCTAssertFalse(save.ok)
        XCTAssertTrue(save.forLLM.contains("未启用"))
        let recall = await RecallMemoryTool().execute(
            argumentsJSON: "{\"query\":\"x\"}", ctx: ctx
        )
        XCTAssertFalse(recall.ok)
    }

    func testRecallMemoryToolReturnsFormattedHits() async {
        let ctx = makeToolContext(memorySearch: { _ in ["- [结论] 只保留五章"] })
        let result = await RecallMemoryTool().execute(
            argumentsJSON: "{\"query\":\"五章\"}", ctx: ctx
        )
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.forLLM.contains("只保留五章"))
        XCTAssertTrue(result.forHuman.contains("命中 1 条"))
    }

    // MARK: - 计划提案协议

    private func blocks(_ name: String, _ json: String) -> [ArtifactParser.ArtifactBlock] {
        [ArtifactParser.ArtifactBlock(name: name, content: json)]
    }

    func testParsePlanProposalParsesAndClamps() {
        let steps = (1...10).map { "{\"do\": \"步骤\($0)\"}" }.joined(separator: ",")
        let json = """
        {"mission": "先补齐缺口再成稿", "steps": [\(steps)]}
        """
        guard let plan = ArtifactParser.parsePlanProposal(
            blocks: blocks("plan-proposal", json)
        ) else {
            return XCTFail("提案应解析成功")
        }
        XCTAssertEqual(plan.mission, "先补齐缺口再成稿")
        XCTAssertEqual(plan.steps.count, ArtifactParser.planStepLimit)
    }

    func testPlanProposalAndSelfAnnouncedPlanDoNotCrossTalk() {
        let proposal = blocks("plan-proposal", "{\"steps\":[{\"do\":\"a\"}]}")
        XCTAssertNotNil(ArtifactParser.parsePlanProposal(blocks: proposal))
        XCTAssertNil(ArtifactParser.parsePlan(blocks: proposal), "自宣解析不吃提案块")

        let selfAnnounced = blocks("plan", "{\"steps\":[{\"do\":\"b\"}]}")
        XCTAssertNotNil(ArtifactParser.parsePlan(blocks: selfAnnounced))
        XCTAssertNil(ArtifactParser.parsePlanProposal(blocks: selfAnnounced), "提案解析不吃自宣块")
    }

    func testParsePlanProposalRejectsEmptySteps() {
        XCTAssertNil(ArtifactParser.parsePlanProposal(
            blocks: blocks("plan-proposal", "{\"mission\":\"空话\",\"steps\":[]}")
        ))
    }

    func testApprovedPlanSectionFormat() {
        let plan = ArtifactParser.PlanCard(
            mission: "双重基准成稿",
            steps: [
                .init(action: "第一步", basis: "依据映射表"),
                .init(action: "第二步", basis: nil),
            ]
        )
        let section = AgentPrompts.approvedPlanSection(plan, supplement: "  风险章节写透  ")
        XCTAssertTrue(section.contains("总体思路：双重基准成稿"))
        XCTAssertTrue(section.contains("1. 第一步——依据映射表"))
        XCTAssertTrue(section.contains("2. 第二步"))
        XCTAssertTrue(section.contains("用户补充要求（优先于计划原文）：风险章节写透"))

        let noSupplement = AgentPrompts.approvedPlanSection(plan, supplement: nil)
        XCTAssertFalse(noSupplement.contains("用户补充要求"))
    }

    // MARK: - 设置解码兼容

    func testPlanProposalsEnabledDecode() throws {
        // 旧存量（编码结果中剔除新键）→ 解码默认开
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(LLMSettings(stages: [:], maxTokensPerRun: 100))
            ) as? [String: Any]
        )
        object.removeValue(forKey: "planProposalsEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(
            try JSONDecoder().decode(LLMSettings.self, from: legacy).planProposalsEnabled
        )

        // 显式关闭经编码回环保留
        let off = LLMSettings(
            stages: [:], maxTokensPerRun: 100, planProposalsEnabled: false
        )
        XCTAssertFalse(
            try JSONDecoder().decode(
                LLMSettings.self, from: JSONEncoder().encode(off)
            ).planProposalsEnabled
        )
    }
}
