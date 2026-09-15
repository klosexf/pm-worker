//
//  PipelineEventTests.swift
//  pm_workerTests
//
//  事件流（events.jsonl append-only）+ 产物骨架折叠（condensed）
//  + 稳定前缀（缓存命中契约）三项的单元测试。
//

import XCTest
@testable import pm_worker

final class PipelineEventTests: XCTestCase {

    private let project = "事件流测试项目"
    private let version = "v1.0"
    /// 磁盘隔离：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/。
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
        // 每次测试前清掉事件文件（append-only 语义在单次测试内验证）
        try? FileManager.default.removeItem(
            at: PipelineEventLog.url(project: project, version: version)
        )
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - ① 事件流读写

    func testAppendCreatesFileAndReadsBackInOrder() {
        // 未 ensureWorkspace 的目录也能写（append 自动补建文件）
        PipelineEventLog.append(
            kind: .stageAdvance, stage: "structure",
            detail: "① 澄清 → ② 结构", project: project, version: version
        )
        PipelineEventLog.append(
            kind: .stageConfirm, stage: "prototype",
            detail: "② 结构产物确认", reason: nil,
            project: project, version: version
        )
        PipelineEventLog.append(
            kind: .stageInvalidate, stage: "structure",
            detail: "② 回退：结构重生成", reason: "structure_regen",
            project: project, version: version
        )

        let events = PipelineEventLog.events(project: project, version: version)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.kind), [.stageAdvance, .stageConfirm, .stageInvalidate])
        XCTAssertEqual(events[0].stage, "structure")
        XCTAssertEqual(events[1].stage, "prototype")
        XCTAssertEqual(events[2].reason, "structure_regen")
        // 每条有独立 id 与时间戳
        XCTAssertEqual(Set(events.map(\.id)).count, 3)
    }

    func testEngineEmitsEventsOnStageTransitions() throws {
        let engine = PipelineEngine(project: project, version: version, database: nil)
        engine.bumpClarifyRound()
        engine.advanceFromClarify()
        try engine.confirmStructure()

        let events = PipelineEventLog.events(project: project, version: version)
        let kinds = events.map(\.kind)
        XCTAssertTrue(kinds.contains(.clarifyRound))
        XCTAssertTrue(kinds.contains(.stageAdvance))
        XCTAssertTrue(kinds.contains(.stageConfirm))
        // 确认事件记录推进后的阶段
        let confirm = events.first { $0.kind == .stageConfirm }
        XCTAssertEqual(confirm?.stage, "prototype")
    }

    func testEventsSurviveWorkspaceBootstrap() throws {
        // ensureWorkspace 含 events.jsonl（新工作区直接建好）
        try PMAgentStore.ensureWorkspace(project: project, version: version)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PipelineEventLog.url(project: project, version: version).path
        ))
    }

    // MARK: - ② 产物骨架折叠（condensed）

    func testCondensedUnderBudgetReturnsOriginal() {
        let text = "# 澄清要点表\n- 目标用户：独立开发者\n- 核心场景：本地笔记"
        XCTAssertEqual(AgentPrompts.condensed(text, budget: 100), text)
    }

    func testCondensedOverBudgetKeepsSkeleton() {
        // 构造病态长产物：多节标题 + 15 行表格 + 长段落
        var table = "| 模块 | 原型页面 | 页面说明 |\n| --- | --- | --- |"
        for i in 1...15 {
            table += "\n| 模块\(i) | 页面\(i) | 说明文字占位占位占位占位占位\(i) |"
        }
        let paragraphs = (1...30).map { "第\($0)段的正文内容，占位文字占位文字占位文字占位文字。" }
            .joined(separator: "\n")
        let text = "# 澄清要点表\n\(table)\n\n## 备注节\n\(paragraphs)"

        let condensed = AgentPrompts.condensed(text, budget: 300)

        // 标题全保留
        XCTAssertTrue(condensed.contains("# 澄清要点表"))
        XCTAssertTrue(condensed.contains("## 备注节"))
        // 表格截断：前 8 数据行保留，后面的丢弃
        XCTAssertTrue(condensed.contains("模块1"))
        XCTAssertFalse(condensed.contains("模块15"))
        // 尾注说明折叠
        XCTAssertTrue(condensed.contains("已折叠为骨架"))
        // 折叠后估算进入预算邻域（尾注 ~30 token 容差）
        XCTAssertLessThanOrEqual(TokenBreakdown.estimate(condensed), 300 + 60)
    }

    // MARK: - ③ 稳定前缀（缓存命中契约）

    func testClarifyPrefixStableAcrossRounds() {
        let p1 = AgentPrompts.clarify(rounds: 1, limit: 5, injection: "")
        let p4 = AgentPrompts.clarify(rounds: 4, limit: 5, injection: "")
        let prefix = commonPrefix(p1, p4)
        // 冻结段完整落在公共前缀里（角色/约束/自评审起点）
        XCTAssertTrue(prefix.contains("角色：资深产品顾问"))
        XCTAssertTrue(prefix.contains("轮次耗尽仍有必填项缺失"))
        // 轮次是易变段：不在公共前缀（1 轮 vs 4 轮首个差异即轮次行）
        XCTAssertFalse(prefix.contains("已问 1 轮"))
        XCTAssertFalse(prefix.contains("已问 4 轮"))
        // 轮次行在尾部（注入区之后）
        let p = AgentPrompts.clarify(rounds: 2, limit: 5, injection: "### 规则层")
        XCTAssertGreaterThan(p.range(of: "## 当前轮次")!.lowerBound, p.range(of: "注入区")!.lowerBound)
    }

    func testInjectionSectionAtTail() {
        // 四阶段 prompt 的注入区（易变段）统一在自评审（冻结段末尾）之后
        let structurePrompt = AgentPrompts.structure(
            clarification: "要点", injection: "### 规则层\n- 规则"
        )
        XCTAssertGreaterThan(
            structurePrompt.range(of: "## 注入区")!.lowerBound,
            structurePrompt.range(of: "内建自评审")!.lowerBound
        )

        let prototypePrompt = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "A --> B", injection: "- 记忆"
        )
        XCTAssertGreaterThan(
            prototypePrompt.range(of: "## 注入区")!.lowerBound,
            prototypePrompt.range(of: "内建自评审")!.lowerBound
        )

        let prdPrompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            prototypePages: ["首页"], analysisNotes: "", injection: "- 记忆"
        )
        XCTAssertGreaterThan(
            prdPrompt.range(of: "## 注入区")!.lowerBound,
            prdPrompt.range(of: "内建自评审")!.lowerBound
        )
    }

    // MARK: - 歧义处理段（②③④ 注入；① 澄清自身即提问阶段不重复注入）

    func testAmbiguitySectionInjectedInLaterStages() {
        let structurePrompt = AgentPrompts.structure(clarification: "要点", injection: "")
        XCTAssertTrue(structurePrompt.contains("歧义处理"))
        XCTAssertTrue(structurePrompt.contains("「A) 选项文本」"))

        let prototypePrompt = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "A --> B", injection: ""
        )
        XCTAssertTrue(prototypePrompt.contains("歧义处理"))

        let prdPrompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        XCTAssertTrue(prdPrompt.contains("歧义处理"))

        let clarifyPrompt = AgentPrompts.clarify(rounds: 1, limit: 5, injection: "")
        XCTAssertFalse(clarifyPrompt.contains("歧义处理"))
    }

    // MARK: - Private

    private func commonPrefix(_ a: String, _ b: String) -> String {
        var common = ""
        for (ca, cb) in zip(a, b) where ca == cb {
            common.append(ca)
        }
        // 截到最后一个完整行，避免半行噪声
        if let lastNewline = common.lastIndex(of: "\n") {
            return String(common[...lastNewline])
        }
        return common
    }
}
