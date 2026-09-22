//
//  DutyHandoverTests.swift
//  pm_workerTests
//
//  系统代答链交接条（方案 C「值班单」）数据推导：链回溯 / 段序号 / 耗时步数 / 明细时间轴。
//  判据与「续段不出独立回答头」（isFastForwardChainedBefore）严格同集——
//  有交接条的必是续段，反之亦然。
//

import XCTest
@testable import pm_worker

final class DutyHandoverTests: XCTestCase {

    /// 条目时钟：每秒 +1，保证排序与 HH:mm:ss 断言稳定（同秒时间戳会让顺序不稳）。
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func entry(
        _ role: DiscussionEntry.Role,
        _ content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil
    ) -> DiscussionEntry {
        clock.addTimeInterval(1)
        return DiscussionEntry(
            id: UUID().uuidString, sessionId: "s1", role: role, content: content,
            think: think, memory: memory,
            createdAt: ISO8601DateFormatter().string(from: clock)
        )
    }

    /// 三段思考步（步数 3）。
    private var threeSteps: ThinkData {
        ThinkData(dur: 22, steps: [
            .init(text: "步骤一", skill: nil, detail: nil, dur: nil),
            .init(text: "步骤二", skill: nil, detail: nil, dur: nil),
            .init(text: "步骤三", skill: nil, detail: nil, dur: nil),
        ])
    }

    /// 回退重做链（两段）：判断段 → 🔄 已回到 → 重做段。
    private func backtrackChain(secondSegmentThink: ThinkData?) -> [DiscussionEntry] {
        [
            entry(.user, "原型样式整体往苹果质感靠一点，其他都别动"),
            entry(.assistant, "本轮判断：上游原型样式修订，走回退\n```artifact:backtrack```"),
            entry(.system, "🔄 已回到 ③ 原型（PRD 标记过期：局部）——马上重做。"),
            entry(.system, "🎨 按你的要求重做原型"),
            entry(.assistant, "已承接上一段判断——开始样式修订……", think: secondSegmentThink),
        ]
    }

    /// 2026-09-22 思考链收口后 `ThinkData.steps` 只剩工具/技能行（原始 CoT 不再入内），
    /// 常规轮常为 0 项。0 的含义是「没有可数的过程行」，不是「走了 0 步」——
    /// 按本组件既有「缺失项整段省略，不伪造」口径省略，不得显示「0 步」。
    func testEmptyStructuredStepsYieldNilStepCount() {
        let entries = backtrackChain(
            secondSegmentThink: ThinkData(dur: 22, steps: [], full: "一段原始思维链")
        )
        XCTAssertNil(MessageBubble.dutyHandover(for: 4, in: entries)?.stepCount)
    }

    // MARK: - 回退链（两段）

    func testBacktrackChainTwoSegmentsDerivesIndexDurationAndNodes() {
        let entries = backtrackChain(secondSegmentThink: threeSteps)
        let handover = MessageBubble.dutyHandover(for: 4, in: entries)

        XCTAssertNotNil(handover, "续段应产出交接条数据")
        XCTAssertEqual(handover?.segmentIndex, 2, "链内第二段")
        XCTAssertEqual(handover?.durationSeconds, 22, "耗时取本段 think.dur")
        XCTAssertEqual(handover?.stepCount, 3, "步数取本段 think.steps.count")
        XCTAssertEqual(handover?.stageLabel, "③ 原型", "阶段徽标取链内「③ 原型」行")
        XCTAssertEqual(handover?.nodes.count, 4, "段1完成 + 🔄 行 + 🎨 行 + 段2完成")
        XCTAssertEqual(handover?.nodes.first?.text, "第 1 段回答完成")
        XCTAssertEqual(handover?.nodes.last?.text, "第 2 段回答完成")
        XCTAssertEqual(
            handover?.nodes[1].text, "已回到 ③ 原型（PRD 标记过期：局部）——马上重做。",
            "链内系统行原文入轴（🔄 已由 stripEventEmoji 剥离）"
        )
    }

    func testStreamingSegmentIndexCountsUnsettledTarget() {
        // 流式期：第二段尚未落盘，index = entries.count（4）
        let entries = Array(backtrackChain(secondSegmentThink: nil).prefix(4))
        let handover = MessageBubble.dutyHandover(for: entries.count, in: entries)

        XCTAssertEqual(handover?.segmentIndex, 2, "未落盘段序号 = 已落盘段数 + 1")
        XCTAssertNil(handover?.durationSeconds, "进行态无耗时（think 未产生）")
        XCTAssertNil(handover?.stepCount, "进行态无步数（think 未产生）")
        XCTAssertEqual(handover?.nodes.count, 3, "段1完成 + 🔄 行 +  行（段2尚未完成）")
    }

    // MARK: - 快速通道链（三段）

    func testFastForwardChainThreeSegmentsUsesChainOrdinal() {
        let think3 = ThinkData(dur: 30, steps: [
            .init(text: "步骤一", skill: nil, detail: nil, dur: nil),
            .init(text: "步骤二", skill: nil, detail: nil, dur: nil),
        ])
        let entries = [
            entry(.user, "直接出原型"),
            entry(.assistant, "明白了，不再追问。"),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，直接生成原型。"),
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计"),
            entry(.assistant, "② 结构产物说明"),
            entry(.system, "📦 结构产物已生成（快速通道：自动确认，继续生成 ③ 原型）"),
            entry(.assistant, "③ 原型产物说明", think: think3),
        ]

        let second = MessageBubble.dutyHandover(for: 4, in: entries)
        XCTAssertEqual(second?.segmentIndex, 2, "第二段按链内序号编号")
        XCTAssertEqual(second?.stageLabel, "② 结构", "取链内最近一次阶段标记")

        let third = MessageBubble.dutyHandover(for: 6, in: entries)
        XCTAssertEqual(third?.segmentIndex, 3, "快速通道链可到第三段")
        XCTAssertEqual(third?.durationSeconds, 30)
        XCTAssertEqual(third?.stepCount, 2)
        XCTAssertEqual(third?.stageLabel, "③ 原型", "近→远扫描取最近的 ③ 原型")
    }

    // MARK: - 非链 / 断链

    func testChainHeadReturnsNil() {
        let entries = backtrackChain(secondSegmentThink: threeSteps)
        XCTAssertNil(MessageBubble.dutyHandover(for: 1, in: entries), "链首段（第 1 段）不出交接条")
    }

    func testSingleTurnReturnsNil() {
        let entries = [entry(.user, "问题"), entry(.assistant, "回答")]
        XCTAssertNil(MessageBubble.dutyHandover(for: 1, in: entries), "单段直答不出交接条")
    }

    func testMemoryRowBreaksChain() {
        // 记忆行（memory != nil）夹在链中：跨行回溯被打断（与链判据同口径）
        let memory = MemoryEntry(scope: .project, kind: .conclusion, content: "已沉淀的结论")
        let entries = [
            entry(.assistant, "前一答"),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认。"),
            entry(.system, "🧠 记忆沉淀行", memory: memory),
            entry(.assistant, "后一答"),
        ]
        XCTAssertNil(MessageBubble.dutyHandover(for: 3, in: entries), "记忆行隔断 → 非链")
    }

    func testUserMessageBreaksChain() {
        let entries = [
            entry(.assistant, "前一答"),
            entry(.system, "🔄 已回到 ③ 原型（PRD 标记过期：局部）——马上重做。"),
            entry(.user, "新的一轮消息"),
            entry(.assistant, "新回答"),
        ]
        XCTAssertNil(MessageBubble.dutyHandover(for: 3, in: entries), "用户消息隔断 → 非链")
    }

    // MARK: - 明细时间轴

    func testNodesAreChronologicalWithHHmmss() {
        let entries = backtrackChain(secondSegmentThink: threeSteps)
        let nodes = MessageBubble.dutyHandover(for: 4, in: entries)?.nodes ?? []

        XCTAssertEqual(nodes.count, 4)
        for node in nodes {
            XCTAssertEqual(node.time.count, 8, "HH:mm:ss 固定 8 字符")
            XCTAssertEqual(node.time.filter { $0 == ":" }.count, 2)
        }
        let times = nodes.map(\.time)
        XCTAssertEqual(times, times.sorted(), "明细按时间升序")
    }

    // MARK: - 降级与判据

    func testSettledLineDegradesWithoutThink() {
        // 无思考模型（think == nil）：耗时 / 步数均缺省，不伪造
        let entries = backtrackChain(secondSegmentThink: nil)
        let handover = MessageBubble.dutyHandover(for: 4, in: entries)
        XCTAssertNotNil(handover)
        XCTAssertNil(handover?.durationSeconds)
        XCTAssertNil(handover?.stepCount)
    }

    func testStageLabelPrefersStrongPatternOverFallback() {
        // 「🔄 已回到 ③ 原型（PRD 标记过期：局部）」同时含 ③ 与 PRD，靠「③ 在前」取胜
        let entries = [
            entry(.assistant, "前一答"),
            entry(.system, "🔄 已回到 ③ 原型（PRD 标记过期：局部）——马上重做。"),
            entry(.assistant, "第二答"),
        ]
        XCTAssertEqual(
            MessageBubble.dutyHandover(for: 2, in: entries)?.stageLabel, "③ 原型"
        )
    }

    func testHandoverEquatableStableForSameInput() {
        // 同输入两次推导必须相等——否则 MessageBubble 的 Equatable 短路失效
        // （流式期间对话页每秒十次重渲染，历史气泡每帧都会重跑解析）
        let entries = backtrackChain(secondSegmentThink: threeSteps)
        XCTAssertEqual(
            MessageBubble.dutyHandover(for: 4, in: entries),
            MessageBubble.dutyHandover(for: 4, in: entries)
        )
    }

    // MARK: - 顶距口径（续段并入上一条回答，不吃 52 轮距）

    func testTopInsetKeepsContinuationInCluster() {
        // 链式续段是上一条回答的延续：与系统提示行同簇（16），不吃新回合的 52 轮距——
        // 否则「一条回答」中间会裂出一道大空白（用户实测报告的格式问题）。
        XCTAssertEqual(
            MessageBubble.topInset(
                for: .assistant, isFirst: false,
                previousWasSystem: true, isContinuation: true
            ),
            DS.Spacing.s16,
            "续段簇内 16（流式气泡与落盘续段共用此口径，保证落盘瞬间不跳开）"
        )
    }

    func testTopInsetKeepsRegularTurnRhythm() {
        // 常规 assistant 仍吃 52 轮距（对话页呼吸感钦定值，不得回退）
        XCTAssertEqual(
            MessageBubble.topInset(
                for: .assistant, isFirst: false,
                previousWasSystem: true, isContinuation: false
            ),
            DS.Spacing.s52
        )
        // 首项不吃顶距
        XCTAssertEqual(
            MessageBubble.topInset(
                for: .assistant, isFirst: true,
                previousWasSystem: false, isContinuation: false
            ),
            0
        )
        // 系统提示行簇内分档不变：提示→提示 12、消息→提示 16
        XCTAssertEqual(
            MessageBubble.topInset(
                for: .system, isFirst: false,
                previousWasSystem: true, isContinuation: false
            ),
            DS.Spacing.s12
        )
        XCTAssertEqual(
            MessageBubble.topInset(
                for: .system, isFirst: false,
                previousWasSystem: false, isContinuation: false
            ),
            DS.Spacing.s16
        )
    }
}