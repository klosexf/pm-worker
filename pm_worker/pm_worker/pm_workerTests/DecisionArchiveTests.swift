//
//  DecisionArchiveTests.swift
//  pm_workerTests
//
//  决策档案（2026-09-16）单测：
//  - 旧格式 jsonl 行向后兼容解码（富化字段 / risk_hit createdAt 缺失 → nil）；
//  - 按天归组：risk_hit 历史行回退文件序归日；
//  - generate 幂等：二次生成内容相同全跳过（mtime 不动）；
//  - 渲染降级：历史简单卡 vs 富话题卡。
//

import XCTest
@testable import pm_worker

final class DecisionArchiveTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - 向后兼容解码

    func testLegacyLineDecodeCompat() throws {
        // 富化前的旧 schema 决策行（无 topic / user_ask / turning_points / owner）
        let legacyDecision = """
        {"id":"d_001","version":"v1.0","decision":"锁定健身小白","why":"专业人群已有成熟方案",\
        "rejectedAlternatives":[{"option":"覆盖全人群","reason":"资源撑不起"}],\
        "confidence":0.8,"toBeVerified":true,"createdAt":"2026-09-15T10:00:00+08:00"}
        """
        // 富化前的旧 schema risk_hit 行（无 createdAt）
        let legacyHit = """
        {"type":"risk_hit","riskId":"r_001","predicted":"原型超 5 页难维护","actual":"第 3 轮即超"}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).jsonl")
        try (legacyDecision + "\n" + legacyHit + "\n").write(to: url, atomically: true, encoding: .utf8)

        let entries = PMAgentStore.readLines(DecisionLogEntry.self, from: url)
        XCTAssertEqual(entries.count, 2)
        guard case .decision(let decision)? = entries.first,
              case .riskHit(let hit)? = entries.last else {
            return XCTFail("旧格式行解码失败")
        }
        XCTAssertNil(decision.topic)
        XCTAssertNil(decision.userAsk)
        XCTAssertNil(decision.turningPoints)
        XCTAssertFalse(decision.isTopicEnriched)
        XCTAssertNil(decision.rejectedAlternatives.first?.owner)
        XCTAssertNil(hit.createdAt)
    }

    func testEnrichedRecordRoundtrip() throws {
        let record = DecisionRecord(
            version: "v1.0",
            decision: "按天生成 HTML 档案",
            why: "确定性渲染零 token",
            rejectedAlternatives: [
                RejectedAlternative(option: "LLM 每日生成", reason: "非确定性", owner: "original"),
                RejectedAlternative(option: "神秘值", reason: "未知标签容忍", owner: "weird"),
            ],
            confidence: 0.9,
            toBeVerified: true,
            topic: "决策档案形态",
            userAsk: "决策日志转成每天的日记",
            turningPoints: [TurningPoint(text: "按版本单文件 → 按天", owner: "original")]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enriched-\(UUID().uuidString).jsonl")
        try PMAgentStore.appendLine(
            DecisionLogEntry.decision(record),
            to: FileManager.default.createEmpty(url)
        )

        let entries = PMAgentStore.readLines(DecisionLogEntry.self, from: url)
        guard case .decision(let decoded)? = entries.first else {
            return XCTFail("富化记录解码失败")
        }
        XCTAssertEqual(decoded, record)
        // 已知标签映射；未知标签容忍（不炸解码、映射为 nil）
        XCTAssertEqual(decoded.rejectedAlternatives[0].ownership, .original)
        XCTAssertNil(decoded.rejectedAlternatives[1].ownership)
    }

    // MARK: - 按天归组

    func testGroupByDayRiskHitFallback() {
        let day1 = "2026-09-15T10:00:00+08:00"
        let day2 = "2026-09-16T11:00:00+08:00"
        let entries: [DecisionLogEntry] = [
            .decision(DecisionRecord(version: "v1.0", decision: "A", why: "w", createdAt: day1)),
            // 历史 risk_hit：无 createdAt → 回退上方最近决策的天
            .riskHit(RiskHitRecord(riskId: "r1", predicted: "p", actual: "a")),
            .decision(DecisionRecord(version: "v1.0", decision: "B", why: "w", createdAt: day2)),
            // 新 risk_hit：自带 createdAt → 直接归日
            .riskHit(RiskHitRecord(riskId: "r2", predicted: "p", actual: "a", createdAt: day2)),
            // 置顶历史 risk_hit（无前驱）→ 回退最近后继 day1
            .riskHit(RiskHitRecord(riskId: "r0", predicted: "p", actual: "a")),
        ]
        // 重排：置顶 hit 放最前
        let ordered = [entries[4], entries[0], entries[1], entries[2], entries[3]]

        let grouped = DecisionArchive.groupByDay(ordered)
        XCTAssertEqual(grouped[0].day, "2026-09-15")  // r0 回退后继
        XCTAssertEqual(grouped[1].day, "2026-09-15")
        XCTAssertEqual(grouped[2].day, "2026-09-15")  // r1 回退前驱
        XCTAssertEqual(grouped[3].day, "2026-09-16")
        XCTAssertEqual(grouped[4].day, "2026-09-16")

        let summaries = DecisionArchive.summarize(grouped)
        XCTAssertEqual(summaries.map(\.day), ["2026-09-16", "2026-09-15"])  // 倒序
        XCTAssertEqual(summaries[0].decisions, 1)
        XCTAssertEqual(summaries[0].hits, 1)
        XCTAssertEqual(summaries[1].decisions, 1)
        XCTAssertEqual(summaries[1].hits, 2)
    }

    // MARK: - 生成幂等

    func testGenerateIdempotent() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "档案项目")
        try PMAgentStore.createVersion("v1.0", in: "档案项目")

        let url = PMAgentStore.jsonlURL(project: "档案项目", version: "v1.0", file: "decisions.jsonl")
        try PMAgentStore.appendLine(
            DecisionLogEntry.decision(DecisionRecord(
                version: "v1.0",
                decision: "决策 A",
                why: "依据",
                rejectedAlternatives: [RejectedAlternative(option: "B 方案", reason: "撑不起", owner: "adopted")],
                confidence: 0.8,
                toBeVerified: true,
                topic: "话题一",
                userAsk: "怎么选",
                turningPoints: [TurningPoint(text: "先按天 → 又按版本 → 回按天", owner: "original")],
                createdAt: "2026-09-15T10:00:00+08:00"
            )),
            to: url
        )
        try PMAgentStore.appendLine(
            DecisionLogEntry.decision(DecisionRecord(
                version: "v1.0", decision: "决策 C", why: "依据",
                createdAt: "2026-09-16T11:00:00+08:00"
            )),
            to: url
        )
        try PMAgentStore.appendLine(
            DecisionLogEntry.riskHit(RiskHitRecord(riskId: "r1", predicted: "p", actual: "a")),
            to: url
        )

        // 首次生成：2 个日档 + overview
        let first = try DecisionArchive.generate(project: "档案项目", version: "v1.0")
        XCTAssertEqual(first.days, ["2026-09-16", "2026-09-15"])
        XCTAssertEqual(Set(first.written), ["2026-09-15.html", "2026-09-16.html", "版本总览.html"])
        let dir = DecisionArchive.archiveDir(project: "档案项目", version: "v1.0")
        for name in first.written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }

        // 二次生成：内容相同 → 全部跳过（幂等，mtime 不动）
        let second = try DecisionArchive.generate(project: "档案项目", version: "v1.0")
        XCTAssertTrue(second.written.isEmpty)
        XCTAssertEqual(second.skipped, 3)

        // 修改 jsonl 后再生 → 仅变化文件重写
        try PMAgentStore.appendLine(
            DecisionLogEntry.decision(DecisionRecord(
                version: "v1.0", decision: "决策 D", why: "w",
                createdAt: "2026-09-16T12:00:00+08:00"
            )),
            to: url
        )
        let third = try DecisionArchive.generate(project: "档案项目", version: "v1.0")
        XCTAssertEqual(third.written, ["2026-09-16.html", "版本总览.html"])
        XCTAssertEqual(third.skipped, 1)

        XCTAssertEqual(
            DecisionArchive.generatedDays(project: "档案项目", version: "v1.0"),
            ["2026-09-15", "2026-09-16"]
        )
        XCTAssertTrue(DecisionArchive.hasOverview(project: "档案项目", version: "v1.0"))
    }

    // MARK: - 渲染降级

    func testRenderDegradation() throws {
        let rich = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "结论 X",
            why: "依据链",
            rejectedAlternatives: [RejectedAlternative(option: "Y", reason: "否", owner: "rejected")],
            confidence: 0.9,
            toBeVerified: true,
            topic: "话题标题",
            userAsk: "最初诉求",
            turningPoints: [TurningPoint(text: "一次推翻", owner: "modified")],
            createdAt: "2026-09-16T10:00:00+08:00"
        ))
        let legacy = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "历史决策", why: "历史依据",
            createdAt: "2026-09-16T11:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([rich, legacy])
        let summary = DecisionArchive.summarize(grouped)[0]
        let html = DecisionArchive.renderDay(
            project: "渲染项目", version: "v1.0", summary: summary,
            entries: grouped.map(\.entry)
        )

        // 富话题卡：诉求 / 所有权 / 转折点齐全
        XCTAssertTrue(html.contains("话题标题"))
        XCTAssertTrue(html.contains("最初诉求"))
        XCTAssertTrue(html.contains("AI建议-未采纳"))
        XCTAssertTrue(html.contains("AI建议-修改"))
        XCTAssertTrue(html.contains("一次推翻"))
        XCTAssertTrue(html.contains("待验证"))
        // 历史简单卡 + 降级说明
        XCTAssertTrue(html.contains("历史决策"))
        XCTAssertTrue(html.contains("历史格式"))

        let overview = DecisionArchive.renderOverview(
            project: "渲染项目", version: "v1.0",
            summaries: [summary], grouped: grouped
        )
        XCTAssertTrue(overview.contains("版本决策总览"))
        XCTAssertTrue(overview.contains("备选否决率"))
        XCTAssertTrue(overview.contains("AI 方案落地率"))
        XCTAssertTrue(overview.contains("待验证闭环率"))
        XCTAssertTrue(overview.contains("href=\"2026-09-16.html\""))
        // 用户内容转义
        let xss = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "<script>alert(1)</script>", why: "w",
            createdAt: "2026-09-16T12:00:00+08:00"
        ))
        let escapedHTML = DecisionArchive.renderDay(
            project: "渲染项目", version: "v1.0",
            summary: summary, entries: grouped.map(\.entry) + [xss]
        )
        XCTAssertFalse(escapedHTML.contains("<script>alert(1)</script>"))
        XCTAssertTrue(escapedHTML.contains("&lt;script&gt;"))
    }
}

/// 测试辅助：在指定 URL 造一个空文件（appendLine 要求目标已存在）。
private extension FileManager {
    func createEmpty(_ url: URL) -> URL {
        try? Data().write(to: url)
        return url
    }
}
