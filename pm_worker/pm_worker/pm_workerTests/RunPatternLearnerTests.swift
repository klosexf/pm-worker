//
//  RunPatternLearnerTests.swift
//  pm_workerTests
//
//  跨会话策略学习：纯函数统计规则（澄清深度 / 机器门失败率 / 风险复发）
//  + IO 采集（pipeline_runs / risks 索引表 / events.jsonl 跨版本扫描）。
//

import XCTest
import GRDB
@testable import pm_worker

final class RunPatternLearnerTests: XCTestCase {

    // MARK: - 澄清深度倾向（项目历史优先 → 全局回退；阈值内不打扰）

    func testClarifyLineProjectTriggered() {
        // 项目历史 2 版本、平均 4.5 轮 → 项目级触发
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "A", version: "v2", clarifyRounds: 4),
            RunPatternLearner.RunStat(project: "B", version: "b1", clarifyRounds: 1),
        ]
        let lines = RunPatternLearner.clarifyLine(project: "A", currentVersion: "v3", runs: runs)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("平均 4.5 轮"))
        XCTAssertTrue(lines[0].contains("触及 5 轮上限"), "耗尽版本应入行")
    }

    func testClarifyLineBelowThresholdStaysSilent() {
        // 样本够但轮次浅且无耗尽 → 不打扰
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 2),
            RunPatternLearner.RunStat(project: "A", version: "v2", clarifyRounds: 3),
        ]
        XCTAssertTrue(RunPatternLearner.clarifyLine(project: "A", currentVersion: "v3", runs: runs).isEmpty)
    }

    func testClarifyLineFallsBackToGlobalPool() {
        // 项目历史不足 2 → 回退全局池（跨项目 ≥3）
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "B", version: "b1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "C", version: "c1", clarifyRounds: 4),
        ]
        let lines = RunPatternLearner.clarifyLine(project: "A", currentVersion: "v2", runs: runs)
        XCTAssertEqual(lines.count, 1, "全局池 ≥3 样本应触发")
    }

    func testClarifyLineInsufficientSampleStaysSilent() {
        // 全局也不足 3 → 不注入
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "B", version: "b1", clarifyRounds: 5),
        ]
        XCTAssertTrue(RunPatternLearner.clarifyLine(project: "A", currentVersion: "v2", runs: runs).isEmpty)
    }

    func testClarifyLineExhaustedRatioTriggersEvenWithLowerAverage() {
        // 平均 3.0 低于 3.5，但 2/3 版本轮次耗尽 ≥ 1/3 → 仍触发
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "A", version: "v2", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "A", version: "v3", clarifyRounds: 1),
        ]
        let lines = RunPatternLearner.clarifyLine(project: "A", currentVersion: "v4", runs: runs)
        XCTAssertEqual(lines.count, 1)
    }

    func testClarifyLineExcludesCurrentVersion() {
        // 当前版本未跑完，不计入历史
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 1),
            RunPatternLearner.RunStat(project: "A", version: "v2", clarifyRounds: 1),
        ]
        // 排除当前 v1 后只剩 1 个历史版本 → 项目级不足；全局也不足 → 静默
        XCTAssertTrue(RunPatternLearner.clarifyLine(project: "A", currentVersion: "v1", runs: runs).isEmpty)
    }

    // MARK: - 机器门失败率（样本与阈值双门槛）

    func testGateLineTriggeredAboveThreshold() {
        let events = (0..<3).map { _ in
            RunPatternLearner.GateEventHit(stage: "structure", passed: false)
        } + [RunPatternLearner.GateEventHit(stage: "structure", passed: true)]
        let lines = RunPatternLearner.gateLine(stage: "structure", gateEvents: events)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("75%"))
        XCTAssertTrue(lines[0].contains("3/4"))
    }

    func testGateLineSilentBelowSampleFloor() {
        let events = [
            RunPatternLearner.GateEventHit(stage: "structure", passed: false),
            RunPatternLearner.GateEventHit(stage: "structure", passed: false),
        ]
        XCTAssertTrue(RunPatternLearner.gateLine(stage: "structure", gateEvents: events).isEmpty)
    }

    func testGateLineSilentBelowFailRatio() {
        // 样本 4 但失败率 25% < 40% → 静默
        let events = [
            RunPatternLearner.GateEventHit(stage: "structure", passed: false)
        ] + (0..<3).map { _ in RunPatternLearner.GateEventHit(stage: "structure", passed: true) }
        XCTAssertTrue(RunPatternLearner.gateLine(stage: "structure", gateEvents: events).isEmpty)
    }

    func testGateLineFiltersByStage() {
        // 其他阶段的评审不计入本阶段样本
        let events = (0..<5).map { _ in
            RunPatternLearner.GateEventHit(stage: "prototype", passed: false)
        }
        XCTAssertTrue(RunPatternLearner.gateLine(stage: "structure", gateEvents: events).isEmpty)
    }

    // MARK: - 风险跨版本复发（hypothesis 归一化分组）

    func testRecurringRiskTriggeredAcrossVersions() {
        let risks = [
            RunPatternLearner.RiskHit(hypothesis: "用户愿意为打卡功能付费", version: "v1"),
            RunPatternLearner.RiskHit(hypothesis: "用户愿意为打卡功能付费 ", version: "v2"),
            RunPatternLearner.RiskHit(hypothesis: "无关单版本风险", version: "v1"),
        ]
        let lines = RunPatternLearner.recurringRiskLine(risks: risks)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("2 个版本复现"))
    }

    func testRecurringRiskIgnoresSingleVersionAndShortHypothesis() {
        let risks = [
            RunPatternLearner.RiskHit(hypothesis: "用户愿意为打卡功能付费", version: "v1"),
            RunPatternLearner.RiskHit(hypothesis: "太短", version: "v1"),
            RunPatternLearner.RiskHit(hypothesis: "太短", version: "v2"),
        ]
        XCTAssertTrue(RunPatternLearner.recurringRiskLine(risks: risks).isEmpty)
    }

    // MARK: - 主入口（阶段分流 + 行数上限）

    func testBriefStageRouting() {
        // clarify 只出澄清统计，不消费 gate 事件
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "A", version: "v2", clarifyRounds: 5),
        ]
        let gateEvents = (0..<5).map { _ in
            RunPatternLearner.GateEventHit(stage: "structure", passed: false)
        }
        let lines = RunPatternLearner.brief(
            stage: "clarify", project: "A", currentVersion: "v3",
            runs: runs, gateEvents: gateEvents, risks: []
        )
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("澄清"))

        // structure 只出门失败率
        let gateLines = RunPatternLearner.brief(
            stage: "structure", project: "A", currentVersion: "v3",
            runs: runs, gateEvents: gateEvents, risks: []
        )
        XCTAssertEqual(gateLines.count, 1)
        XCTAssertTrue(gateLines[0].contains("机器门"))
    }

    func testBriefNonMainlineStageIsEmpty() {
        let lines = RunPatternLearner.brief(
            stage: "classify", project: "A", currentVersion: "v1",
            runs: [], gateEvents: [], risks: []
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testBriefCapsLineCount() {
        let runs = [
            RunPatternLearner.RunStat(project: "A", version: "v1", clarifyRounds: 5),
            RunPatternLearner.RunStat(project: "A", version: "v2", clarifyRounds: 5),
        ]
        let gateEvents = (0..<4).map { _ in
            RunPatternLearner.GateEventHit(stage: "structure", passed: false)
        }
        let risks = [
            RunPatternLearner.RiskHit(hypothesis: "假设甲一旦不成立结论崩塌需要重点核对", version: "v1"),
            RunPatternLearner.RiskHit(hypothesis: "假设甲一旦不成立结论崩塌需要重点核对", version: "v2"),
            RunPatternLearner.RiskHit(hypothesis: "假设乙一旦不成立结论崩塌需要重点核对", version: "v1"),
            RunPatternLearner.RiskHit(hypothesis: "假设乙一旦不成立结论崩塌需要重点核对", version: "v2"),
        ]
        // structure 不出澄清行；门 1 行 + 复发风险 2 行 = 3 行（≤ maxLines）
        let lines = RunPatternLearner.brief(
            stage: "structure", project: "A", currentVersion: "v3",
            runs: runs, gateEvents: gateEvents, risks: risks
        )
        XCTAssertEqual(lines.count, 3)
    }

    // MARK: - IO 采集（临时索引库 + 临时根目录）

    func testRunStatsAndRiskHitsFromDatabase() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)/index.sqlite")
        let database = try AppDatabase(indexURL: dbURL)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        try database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO pipeline_runs (id, project_id, version, current_stage, status) VALUES (?, ?, ?, ?, ?)",
                arguments: ["r1", "项目A", "v1", "prd", "running"]
            )
            try db.execute(
                sql: "UPDATE pipeline_runs SET clarify_rounds = 4 WHERE id = 'r1'"
            )
            try db.execute(
                sql: "INSERT INTO risks (id, project_id, version, stage, hypothesis, trigger_signal, status, origin_ref) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: ["k1", "项目A", "v1", "structure", "假设甲", "structure_regen", "open", "自评审"]
            )
        }

        let runs = RunPatternLearner.runStats(database: database)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].project, "项目A")
        XCTAssertEqual(runs[0].clarifyRounds, 4)

        let risks = RunPatternLearner.riskHits(project: "项目A", database: database)
        XCTAssertEqual(risks.count, 1)
        XCTAssertEqual(risks[0].version, "v1")
        XCTAssertTrue(RunPatternLearner.riskHits(project: "别的项目", database: database).isEmpty)
    }

    func testGateEventsScanAcrossVersions() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
            PMAgentStore.rootOverride = nil
        }
        try PMAgentStore.bootstrap()
        _ = try PMAgentStore.createProject(named: "门统计项目")
        _ = try PMAgentStore.createVersion("v1", in: "门统计项目")
        _ = try PMAgentStore.createVersion("v2", in: "门统计项目")

        PipelineEventLog.append(
            kind: .gateEvaluated, stage: "structure", detail: "d", reason: "pass",
            project: "门统计项目", version: "v1"
        )
        PipelineEventLog.append(
            kind: .gateEvaluated, stage: "structure", detail: "d", reason: "tier2_fail",
            project: "门统计项目", version: "v2"
        )
        PipelineEventLog.append(
            kind: .stageAdvance, stage: "structure", detail: "d",
            project: "门统计项目", version: "v1"
        )

        let hits = RunPatternLearner.gateEvents(project: "门统计项目")
        XCTAssertEqual(hits.count, 2, "仅 gateEvaluated 计入")
        XCTAssertEqual(hits.filter { !$0.passed }.count, 1)
    }
}
