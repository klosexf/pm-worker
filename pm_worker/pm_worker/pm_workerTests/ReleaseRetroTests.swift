//
//  ReleaseRetroTests.swift
//  pm_workerTests
//
//  封板复盘（ReleaseRetro）+ 闸口确认 outcome 留痕的单元测试：
//  - ①②③ 确认漏斗 outcome 写入 events.jsonl（approved / approved_after_revision / fast_track）
//  - 历史事件行无 outcome 键 → 解码 nil（向后兼容）
//  - changes.jsonl + events.jsonl + decisions.jsonl 三源确定性 fold
//

import XCTest
@testable import pm_worker

final class ReleaseRetroTests: XCTestCase {

    private let project = "封板复盘测试项目"
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
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 闸口确认 outcome 留痕

    func testOutcomeRecordedOnGateConfirm() throws {
        let engine = PipelineEngine(project: project, version: version, database: nil)
        engine.advanceFromClarify(outcome: "fast_track")
        try engine.confirmStructure(outcome: "approved_after_revision")
        try engine.confirmPrototype()  // 默认 approved

        let events = PipelineEventLog.events(project: project, version: version)
        let advance = events.first { $0.kind == .stageAdvance }
        XCTAssertEqual(advance?.outcome, "fast_track")
        let confirms = events.filter { $0.kind == .stageConfirm }
        XCTAssertEqual(confirms.map(\.outcome), ["approved_after_revision", "approved"])
    }

    func testLegacyEventLineWithoutOutcomeDecodesNil() throws {
        // 历史行（无 outcome 键）解码不炸，outcome = nil
        let legacy = """
        {"id":"e_legacy","kind":"stageConfirm","stage":"prototype",\
        "detail":"② 结构产物确认，进入 ③ 原型","createdAt":"2026-01-01T00:00:00Z"}
        """
        try legacy.write(
            to: PipelineEventLog.url(project: project, version: version),
            atomically: true, encoding: .utf8
        )
        let events = PipelineEventLog.events(project: project, version: version)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].outcome)
    }

    // MARK: - ReleaseRetro fold

    func testEmptyVersionYieldsNilSections() {
        let retro = ReleaseRetro.load(project: project, version: version)
        XCTAssertTrue(retro.isEmpty)
        XCTAssertNil(retro.oneLiner)
        XCTAssertNil(retro.markdownSection)
    }

    func testFoldAggregatesThreeSources() throws {
        // 1. changes.jsonl：2 提案——1 纳入 + 1 顺延 + 1 pending
        ChangeLedger.append(
            .proposal(ChangeProposalRecord(
                id: "chg_a", idea: "支持导出 PDF", target: "prototype",
                checkpointStage: "structure"
            )),
            project: project, version: version
        )
        ChangeLedger.append(
            .resolution(ChangeResolutionRecord(id: "chg_a", resolution: .adopted)),
            project: project, version: version
        )
        ChangeLedger.append(
            .proposal(ChangeProposalRecord(
                id: "chg_b", idea: "加深色模式", checkpointStage: "prototype"
            )),
            project: project, version: version
        )
        ChangeLedger.append(
            .resolution(ChangeResolutionRecord(id: "chg_b", resolution: .deferred)),
            project: project, version: version
        )
        ChangeLedger.append(
            .proposal(ChangeProposalRecord(
                id: "chg_c", idea: "未处置提案", checkpointStage: "structure"
            )),
            project: project, version: version
        )

        // 2. events.jsonl：回退 2 次（structure 1 + prototype 1）+ 确认 outcome
        PipelineEventLog.append(
            kind: .stageInvalidate, stage: "structure",
            detail: "② 回退", reason: "structure_regen",
            project: project, version: version
        )
        PipelineEventLog.append(
            kind: .stageInvalidate, stage: "prototype",
            detail: "③ 回退", reason: "prototype_regen",
            project: project, version: version
        )
        PipelineEventLog.append(
            kind: .stageAdvance, stage: "structure",
            detail: "① 澄清 → ② 结构", outcome: "approved",
            project: project, version: version
        )
        PipelineEventLog.append(
            kind: .stageConfirm, stage: "prototype",
            detail: "② 结构产物确认，进入 ③ 原型", outcome: "fast_track",
            project: project, version: version
        )

        // 3. decisions.jsonl：1 条决策
        try PMAgentStore.appendLine(
            DecisionRecord(
                version: version, decision: "采用本地优先",
                why: "零遥测", confidence: 1.0, toBeVerified: false
            ),
            to: PMAgentStore.jsonlURL(
                project: project, version: version, file: "decisions.jsonl"
            )
        )

        let retro = ReleaseRetro.load(project: project, version: version)
        XCTAssertFalse(retro.isEmpty)
        // 变更处置分布
        XCTAssertEqual(retro.proposals, 3)
        XCTAssertEqual(retro.adopted, 1)
        XCTAssertEqual(retro.deferred, 1)
        XCTAssertEqual(retro.pending, 1)
        // 回退分布（次数降序，此处各 1 按阶段名稳定排序）
        XCTAssertEqual(retro.invalidations.map(\.stage), ["prototype", "structure"])
        // outcome 分布
        XCTAssertEqual(retro.confirmOutcomes["approved"], 1)
        XCTAssertEqual(retro.confirmOutcomes["fast_track"], 1)
        XCTAssertEqual(retro.decisions, 1)

        // 渲染内容抽查
        let oneLiner = try XCTUnwrap(retro.oneLiner)
        XCTAssertTrue(oneLiner.contains("变更提案 3 条"))
        XCTAssertTrue(oneLiner.contains("纳入 1"))
        XCTAssertTrue(oneLiner.contains("未处置 1"))
        XCTAssertTrue(oneLiner.contains("回退 2 次"))
        XCTAssertTrue(oneLiner.contains("闸口确认：批准 1 · 快速通道 1"))

        let section = try XCTUnwrap(retro.markdownSection)
        XCTAssertTrue(section.contains("## 本版复盘（决策稳定性）"))
        XCTAssertTrue(section.contains("② 结构 1 次"))
        XCTAssertTrue(section.contains("③ 原型 1 次"))
        XCTAssertFalse(section.contains("改后批准"))  // 未发生改后批准，不出现
        XCTAssertTrue(section.contains("决策留痕 1 条"))
    }

    func testInvalidationDominatesOneLinerFocus() {
        // 回退集中度：structure 3 次 > prototype 1 次 → oneLiner 指向 ② 结构
        for _ in 0..<3 {
            PipelineEventLog.append(
                kind: .stageInvalidate, stage: "structure",
                detail: "② 回退", reason: "structure_regen",
                project: project, version: version
            )
        }
        PipelineEventLog.append(
            kind: .stageInvalidate, stage: "prototype",
            detail: "③ 回退", reason: "prototype_regen",
            project: project, version: version
        )
        let retro = ReleaseRetro.load(project: project, version: version)
        XCTAssertEqual(retro.invalidations.first?.stage, "structure")
        XCTAssertTrue(retro.oneLiner?.contains("集中在 ② 结构") ?? false)
    }
}
