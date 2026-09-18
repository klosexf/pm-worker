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
        XCTAssertNil(decision.basis)
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
            turningPoints: [TurningPoint(text: "按版本单文件 → 按天", owner: "original")],
            basis: DecisionBasis(
                data: "23 天记录回看耗时实测",
                logic: "派生产物可重建 → 渲染零成本",
                facts: "上一版按版本单文件翻不动"
            )
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
            basis: DecisionBasis(
                data: "调研 5 例", logic: "痛点真实 → 最短路径", facts: "竞品同类做法"
            ),
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

        // 富话题卡：诉求 / 所有权 / 转折点 / 结论依据齐全
        XCTAssertTrue(html.contains("话题标题"))
        XCTAssertTrue(html.contains("最初诉求"))
        XCTAssertTrue(html.contains("AI建议-未采纳"))
        XCTAssertTrue(html.contains("AI建议-修改"))
        XCTAssertTrue(html.contains("一次推翻"))
        XCTAssertTrue(html.contains("结论依据"))
        XCTAssertTrue(html.contains("调研 5 例"))
        XCTAssertTrue(html.contains("痛点真实 → 最短路径"))
        XCTAssertTrue(html.contains("竞品同类做法"))
        XCTAssertTrue(html.contains("待验证"))
        // 历史简单卡进折叠区 + 区内挂历史格式说明（默认收起，无 open 属性）
        XCTAssertTrue(html.contains("历史决策"))
        XCTAssertTrue(html.contains("<details class=\"atomic\">"))
        XCTAssertTrue(html.contains("原子决策 · 1 条"))
        XCTAssertTrue(html.contains("历史格式"))
        XCTAssertFalse(html.contains("details class=\"atomic\" open"))
        // 纯话题日不出折叠区；无 basis 的卡不出现结论依据小节
        let pureTopicHTML = DecisionArchive.renderDay(
            project: "渲染项目", version: "v1.0", summary: summary, entries: [rich]
        )
        XCTAssertTrue(pureTopicHTML.contains("话题标题"))
        XCTAssertFalse(pureTopicHTML.contains("details class=\"atomic\""))
        let legacyOnlyHTML = DecisionArchive.renderDay(
            project: "渲染项目", version: "v1.0", summary: summary, entries: [legacy]
        )
        XCTAssertFalse(legacyOnlyHTML.contains("结论依据"))

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

    // MARK: - 系统记账卡

    func testLedgerKindDetection() {
        // 与 RiskStore / AppModel 确定性写入前缀严格一致
        XCTAssertEqual(
            DecisionRecord(
                version: "v1.0", decision: "【风险应对】执行访谈", why: "风险：装不进"
            ).ledgerKind, .riskMitigation
        )
        XCTAssertEqual(
            DecisionRecord(
                version: "v1.0", decision: "【风险解除】已验证", why: "w"
            ).ledgerKind, .riskResolution
        )
        XCTAssertEqual(
            DecisionRecord(
                version: "v1.0", decision: "纳入后续版本：深色模式", why: "w"
            ).ledgerKind, .toNextVersion
        )
        XCTAssertEqual(
            DecisionRecord(
                version: "v1.0",
                decision: "【路径选择】澄清确认：跳过中间阶段，直出 PRD",
                why: "小需求优化"
            ).ledgerKind, .routeSelection
        )
        // 普通决策不误判；富话题决策判别只看前缀（渲染侧 isTopicEnriched 优先，
        // 话题卡先于记账卡，语义不冲突）
        XCTAssertNil(
            DecisionRecord(version: "v1.0", decision: "锁定人群", why: "w").ledgerKind
        )
        XCTAssertEqual(
            DecisionRecord(
                version: "v1.0", decision: "【风险应对】讨论得出", why: "w", topic: "风险话题"
            ).ledgerKind, .riskMitigation
        )
    }

    func testLedgerCardRendering() {
        let mitigation = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "【风险应对】编码开工前执行 R2 访谈",
            why: "风险：原生 App 装不进管控手机（后果：路线需整体迁移为小程序）",
            confidence: 1.0,
            toBeVerified: true,
            evidence: "对话留痕 · 会话 7B32CA2D-6B5A-48E3-94A9-2447C7C431A7 · "
                + "回合 6F1C756D-A658-4DF3-87A8-54AA70096E9A · 执行包 05-artifacts/risk-plans/r_1ec0.md",
            createdAt: "2026-09-17T12:58:00+08:00"
        ))
        let resolution = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "【风险解除】R2 访谈过线——方案验证通过",
            why: "方案「R2 访谈」落地后确认风险未发生",
            createdAt: "2026-09-17T13:00:00+08:00"
        ))
        let pooled = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "纳入后续版本：深色模式",
            why: "变更池毕业裁决（封板前显式处置，不默认沉淀）",
            createdAt: "2026-09-17T14:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([mitigation, resolution, pooled])
        let summary = DecisionArchive.summarize(grouped)[0]
        let html = DecisionArchive.renderDay(
            project: "记账项目", version: "v1.0", summary: summary,
            entries: grouped.map(\.entry)
        )

        // 风险应对卡：方案标题 + 风险/后果/证据拆行
        XCTAssertTrue(html.contains("编码开工前执行 R2 访谈"))
        XCTAssertTrue(html.contains("<span class=\"hl\">风险</span>"))
        XCTAssertTrue(html.contains("原生 App 装不进管控手机"))
        XCTAssertTrue(html.contains("<span class=\"hl\">后果</span>"))
        XCTAssertTrue(html.contains("路线需整体迁移为小程序"))
        XCTAssertTrue(html.contains("<span class=\"hl\">证据</span>"))
        // 证据行人话化：机器标识（会话/回合 UUID）不外露，执行包出相对链接
        XCTAssertTrue(html.contains("采纳回合的对话留痕"))
        XCTAssertTrue(html.contains(
            "<a class=\"evi-link\" href=\"../05-artifacts/risk-plans/r_1ec0.md\">查看执行包</a>"
        ))
        XCTAssertFalse(html.contains("7B32CA2D"))
        XCTAssertFalse(html.contains("6F1C756D"))
        // 风险解除卡：假设为标题 + 验证行
        XCTAssertTrue(html.contains("R2 访谈过线"))
        XCTAssertTrue(html.contains("方案「R2 访谈」落地后确认风险未发生"))
        // 池毕业卡：提案为标题
        XCTAssertTrue(html.contains("深色模式"))
        // 全原子日：整体折叠收纳（默认收起）
        XCTAssertTrue(html.contains("<details class=\"atomic\">"))
        XCTAssertTrue(html.contains("原子决策 · 3 条"))
        // 全记账日不挂「历史格式」误标
        XCTAssertFalse(html.contains("历史格式"))

        // 混合日：真·历史记录才触发降级说明
        let legacy = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "历史决策", why: "历史依据",
            createdAt: "2026-09-17T15:00:00+08:00"
        ))
        let mixedGrouped = DecisionArchive.groupByDay([mitigation, legacy])
        let mixedSummary = DecisionArchive.summarize(mixedGrouped)[0]
        let mixedHTML = DecisionArchive.renderDay(
            project: "记账项目", version: "v1.0", summary: mixedSummary,
            entries: mixedGrouped.map(\.entry)
        )
        XCTAssertTrue(mixedHTML.contains("历史格式"))
    }

    // MARK: - 路径还原聚合区

    func testPathSectionAggregation() {
        let topic = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "结论 X",
            why: "w",
            rejectedAlternatives: [RejectedAlternative(
                option: "方案 A", reason: "用户明确排除控制权", owner: "adopted"
            )],
            topic: "课件功能形态",
            turningPoints: [TurningPoint(text: "从库形态推翻为任务挂载", owner: "adopted")],
            createdAt: "2026-09-17T10:00:00+08:00"
        ))
        let atomic = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "锁定移动优先",
            why: "w",
            rejectedAlternatives: [RejectedAlternative(option: "桌面做透", reason: "火力必须单点集中")],
            createdAt: "2026-09-17T11:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([topic, atomic])
        let summary = DecisionArchive.summarize(grouped)[0]
        let overview = DecisionArchive.renderOverview(
            project: "路径项目", version: "v1.0", summaries: [summary], grouped: grouped
        )
        // 聚合区：转折点 + 被否备选（原因与所有权随行），来源决策题回链
        XCTAssertTrue(overview.contains("路径还原"))
        XCTAssertTrue(overview.contains("中途推翻 · 1"))
        XCTAssertTrue(overview.contains("从库形态推翻为任务挂载"))
        XCTAssertTrue(overview.contains("被否备选 · 2"))
        XCTAssertTrue(overview.contains("方案 A"))
        XCTAssertTrue(overview.contains("用户明确排除控制权"))
        XCTAssertTrue(overview.contains("桌面做透"))
        XCTAssertTrue(overview.contains("火力必须单点集中"))
        XCTAssertTrue(overview.contains("《课件功能形态》"))
        XCTAssertTrue(overview.contains("《锁定移动优先》"))
        // 无路径信息时整段省略
        let bare = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "无路径决策", why: "w",
            createdAt: "2026-09-17T12:00:00+08:00"
        ))
        let bareGrouped = DecisionArchive.groupByDay([bare])
        let bareSummary = DecisionArchive.summarize(bareGrouped)[0]
        let bareOverview = DecisionArchive.renderOverview(
            project: "路径项目", version: "v1.0", summaries: [bareSummary], grouped: bareGrouped
        )
        XCTAssertFalse(bareOverview.contains("路径还原"))
    }

    // MARK: - 汇总表：分层 / 状态列 / 重复聚合（2026-09-17 重做）

    func testOverviewSummaryLayeringAndStatus() {
        // 话题决策（主表）+ 原子 + 记账（折叠速览）
        let topic = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "锁定桌面端为首要落点", why: "w",
            topic: "平台选择", createdAt: "2026-09-17T10:00:00+08:00"
        ))
        let atomic = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "笔记与记忆合并为同页双标签", why: "w",
            createdAt: "2026-09-17T11:00:00+08:00"
        ))
        let ledger = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "【风险应对】开工前 5 人访谈", why: "风险：假设未验证",
            toBeVerified: true, createdAt: "2026-09-17T12:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([topic, atomic, ledger])
        let summary = DecisionArchive.summarize(grouped)[0]
        let html = DecisionArchive.renderOverview(
            project: "汇总项目", version: "v1.0", summaries: [summary], grouped: grouped
        )
        // 主表只有话题决策；原子/记账收默认收起的折叠速览
        XCTAssertTrue(html.contains("锁定桌面端为首要落点"))
        XCTAssertTrue(html.contains("原子与记账速览 · 2 条"))
        XCTAssertTrue(html.contains("<details class=\"atomic\">"))
        XCTAssertFalse(html.contains("details class=\"atomic\" open"))
        // 状态列不复读原文：「验证：结论」旧口径退场，改为徽章 + 日期
        XCTAssertTrue(html.contains("<th>状态</th>"))
        XCTAssertFalse(html.contains("<th>待跟进</th>"))
        XCTAssertFalse(html.contains("验证："))
        XCTAssertTrue(html.contains("<span class=\"badge warn\">待验证</span>"))
        XCTAssertTrue(html.contains("09-17"))
    }

    func testSummaryDuplicateFold() {
        // 同结论两轮复述（措辞微调）→ 合并一行「2 次确认 · 首见 MM-DD」，代表 = 最新口径
        let first = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "规划决策权归学生自主，工具只做排清楚+盯进度，家长只读不干预",
            why: "w", topic: "产品定位", createdAt: "2026-09-16T10:00:00+08:00"
        ))
        let second = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0",
            decision: "v1 定位为「学生自我管理工具」，规划决策权归学生，家长只读不控制",
            why: "w", topic: "产品定位", createdAt: "2026-09-17T10:00:00+08:00"
        ))
        let other = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "平台锁定桌面端作为首要落点", why: "w",
            topic: "平台选择", createdAt: "2026-09-17T11:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([first, second, other])
        let summary = DecisionArchive.summarize(grouped)[0]
        let html = DecisionArchive.renderOverview(
            project: "聚合项目", version: "v1.0", summaries: [summary], grouped: grouped
        )
        XCTAssertTrue(html.contains("2 次确认 · 首见 09-16"))
        // 代表 = 最新口径；总览无卡片区，旧表述被合并后整页 0 次出现
        XCTAssertTrue(html.contains("家长只读不控制"))
        XCTAssertEqual(
            html.components(separatedBy: "家长只读不干预").count - 1, 0,
            "旧表述已被聚合进最新口径，不再逐条重复"
        )
        // 低相似条目不受聚合影响
        XCTAssertTrue(html.contains("平台锁定桌面端作为首要落点"))
        XCTAssertFalse(html.contains("3 次确认"))
    }

    func testLedgerEntriesNotFolded() {
        // 同主题两条风险应对记账：绑定各自风险上下文，不参与合并、各自成行
        let m1 = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "【风险应对】用验证脚本做 5 人访谈", why: "风险：假设未验证",
            toBeVerified: true, createdAt: "2026-09-16T10:00:00+08:00"
        ))
        let m2 = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "【风险应对】一周内访谈 5 名学生验证假设", why: "风险：假设未验证",
            toBeVerified: true, createdAt: "2026-09-17T10:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([m1, m2])
        let summary = DecisionArchive.summarize(grouped)[0]
        let html = DecisionArchive.renderOverview(
            project: "记账汇总项目", version: "v1.0", summaries: [summary], grouped: grouped
        )
        XCTAssertTrue(html.contains("原子与记账速览 · 2 条"))
        XCTAssertTrue(html.contains("【风险应对】用验证脚本做 5 人访谈"))
        XCTAssertTrue(html.contains("【风险应对】一周内访谈 5 名学生验证假设"))
        XCTAssertFalse(html.contains("次确认"))
    }

    func testSummaryStatusEvidenceLink() {
        // 风险应对已闭环 + 执行包证据：状态格出「查看执行包」链接；无证据不出链接
        let mitigation = DecisionLogEntry.decision(DecisionRecord(
            version: "v1.0", decision: "【风险应对】执行 R2 访谈", why: "风险：假设未验证",
            evidence: "对话留痕 · 会_session · 回合 m_1 · 执行包 05-artifacts/risk-plans/r_x.md",
            createdAt: "2026-09-17T10:00:00+08:00"
        ))
        let grouped = DecisionArchive.groupByDay([mitigation])
        let summary = DecisionArchive.summarize(grouped)[0]
        let html = DecisionArchive.renderOverview(
            project: "证据项目", version: "v1.0", summaries: [summary], grouped: grouped
        )
        XCTAssertTrue(html.contains(
            "<a class=\"evi-link\" href=\"../05-artifacts/risk-plans/r_x.md\">查看执行包</a>"
        ))
        XCTAssertTrue(html.contains("<span class=\"badge ok\">已闭环</span>"))
    }
}

/// 测试辅助：在指定 URL 造一个空文件（appendLine 要求目标已存在）。
private extension FileManager {
    func createEmpty(_ url: URL) -> URL {
        try? Data().write(to: url)
        return url
    }
}
