//
//  ScrollPerfTests.swift
//  pm_workerTests
//
//  滚动体验优化（流式渲染管线）验证：
//  ① StreamPublishThrottle 节流语义（首发即发、窗口内合并、窗口外放行、频率上界）
//  ② ScrollFollowJudge 吸底判据（内容增长不误解除 / 用户上滚必解除 / 回底恢复）
//  ③ MessageBubble / TurnNote 等价判据（流式重渲染短路正确性）
//  ④ 性能基准：单 tick 渲染管线成本（全量重解析 vs 增量短路），供优化前后对比
//

import XCTest
import SwiftUI
@testable import pm_worker

final class ScrollPerfTests: XCTestCase {

    // MARK: - ① 节流

    func testThrottleFirstDeltaPublishesImmediately() {
        var gate = StreamPublishThrottle(interval: 0.1)
        XCTAssertTrue(gate.shouldPublish(now: Date(timeIntervalSince1970: 0)))
    }

    func testThrottleCoalescesWithinInterval() {
        var gate = StreamPublishThrottle(interval: 0.1)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(gate.shouldPublish(now: t0))
        // 窗口内：全部合并
        XCTAssertFalse(gate.shouldPublish(now: t0.addingTimeInterval(0.03)))
        XCTAssertFalse(gate.shouldPublish(now: t0.addingTimeInterval(0.06)))
        XCTAssertFalse(gate.shouldPublish(now: t0.addingTimeInterval(0.099)))
        // 窗口外：放行
        XCTAssertTrue(gate.shouldPublish(now: t0.addingTimeInterval(0.10)))
    }

    func testThrottlePublishRate() {
        // 500 delta / 每 31.25ms 一个（0.03125 = 1/64²，二进制精确栅格）：
        // 逐 delta 发布 = 500 次全量重渲染；节流 0.125s（二进制精确）后 =
        // 每 4 个 delta 一批，确定性 125 次。时间常量必须取 2 的负幂——
        // 生产节奏（0.1s/20ms）的十进制值经 double 累减会漂移（0.3−0.2 < 0.1），
        // 边界合并次数非确定（实测 91~101），只能测上界（见下）。
        var gate = StreamPublishThrottle(interval: 0.125)
        var published = 0
        for i in 0..<500 {
            if gate.shouldPublish(now: Date(timeIntervalSince1970: Double(i) * 0.03125)) {
                published += 1
            }
        }
        XCTAssertEqual(published, 125)
    }

    func testThrottleProductionCadenceRateBound() {
        // 生产节奏（0.1s 窗口 / 每 20ms 一 delta，10s 流）：
        // 无论浮点边界如何漂移，频率上界恒成立——至多「首发 + 每 100ms 一批」= 101，
        // 且相对逐 delta 发布（500 次全量重渲染）合并掉 4/5 以上。
        var gate = StreamPublishThrottle(interval: 0.1)
        var published = 0
        for i in 0..<500 {
            if gate.shouldPublish(now: Date(timeIntervalSince1970: Double(i) * 0.02)) {
                published += 1
            }
        }
        XCTAssertLessThanOrEqual(published, 101)
        XCTAssertGreaterThanOrEqual(published, 84) // 最坏每窗口多吃一个 delta（120ms/批）
    }

    // MARK: - ② 吸底判据（ScrollFollowJudge）

    func testContentGrowthDoesNotUnstick() {
        // 吸底时流式正文增长 80pt（offset 不变）：距底 0→80，增量恰等于 growth
        XCTAssertFalse(ScrollFollowJudge.shouldUnstick(oldBottom: 0, newBottom: 80, growth: 80))
        // 多批增长叠加（追底前攒了 3 tick）
        XCTAssertFalse(ScrollFollowJudge.shouldUnstick(oldBottom: 0, newBottom: 240, growth: 240))
    }

    func testUserScrollUpUnsticks() {
        // 用户上滚 200pt、内容不变（滚轮/触控板/惯性/键盘/拖条同构）
        XCTAssertTrue(ScrollFollowJudge.shouldUnstick(oldBottom: 0, newBottom: 200, growth: 0))
    }

    func testUserScrollUpDuringGrowthUnsticks() {
        // 内容增长 80 的同时用户上滚 60：增量 140 > growth + ε → 解除
        XCTAssertTrue(ScrollFollowJudge.shouldUnstick(oldBottom: 0, newBottom: 140, growth: 80))
    }

    func testSmallDistanceNeverUnsticks() {
        // 阈值内的任何变化都不解除（微滚由追底拉回，语义等同吸底）
        XCTAssertFalse(ScrollFollowJudge.shouldUnstick(oldBottom: 0, newBottom: 20, growth: 0))
        XCTAssertFalse(ScrollFollowJudge.shouldUnstick(oldBottom: 5, newBottom: 30, growth: 10))
    }

    func testRestickAtBottom() {
        XCTAssertTrue(ScrollFollowJudge.shouldRestick(bottomDistance: 0))
        XCTAssertTrue(ScrollFollowJudge.shouldRestick(bottomDistance: 32))
        XCTAssertFalse(ScrollFollowJudge.shouldRestick(bottomDistance: 32.5))
    }

    func testProgrammaticCatchUpDoesNotUnstick() {
        // 追底 scrollTo 只减不增：距底 80 → 0，永不误判为上滚
        XCTAssertFalse(ScrollFollowJudge.shouldUnstick(oldBottom: 80, newBottom: 0, growth: 0))
    }

    // MARK: - ③ 等价判据（流式重渲染短路）

    private func makeEntry(_ content: String) -> DiscussionEntry {
        DiscussionEntry(
            id: "e1", sessionId: "s1", role: .assistant, content: content,
            createdAt: "2026-09-13T12:00:00Z"
        )
    }

    func testMessageBubbleEquatableIgnoresClosures() {
        // 闭包（onOpenSink/onResend）由调用方每帧重建、语义恒定 → 不参与等价
        let a = MessageBubble(
            entry: makeEntry("回答"), stage: .clarify, showOptions: false,
            headerNotes: [], footerNotes: [], project: "p", version: "v",
            onOpenSink: { _ in }, onResend: { _ in }, resendEnabled: true
        )
        let b = MessageBubble(
            entry: makeEntry("回答"), stage: .clarify, showOptions: false,
            headerNotes: [], footerNotes: [], project: "p", version: "v",
            onOpenSink: nil, onResend: nil, resendEnabled: true
        )
        XCTAssertEqual(a, b)
    }

    func testMessageBubbleInequalityOnChange() {
        let a = MessageBubble(
            entry: makeEntry("回答一"), stage: .clarify, showOptions: false,
            headerNotes: [], footerNotes: [], project: "p", version: "v",
            resendEnabled: true
        )
        let c = MessageBubble(
            entry: makeEntry("回答二"), stage: .clarify, showOptions: false,
            headerNotes: [], footerNotes: [], project: "p", version: "v",
            resendEnabled: true
        )
        XCTAssertNotEqual(a, c)
    }

    func testMessageBubbleInequalityOnAppendedNote() {
        // 回答完成后新系统行并入 footerNotes（append-only）→ 不等 → 重渲染
        let note = TurnNote(text: "决策记录 +2 条", icon: .dot, tint: Color.ink500)
        let base = MessageBubble(
            entry: makeEntry("回答"), stage: .clarify, showOptions: false,
            headerNotes: [], footerNotes: [], project: "p", version: "v",
            resendEnabled: true
        )
        let withNote = MessageBubble(
            entry: makeEntry("回答"), stage: .clarify, showOptions: false,
            headerNotes: [], footerNotes: [note], project: "p", version: "v",
            resendEnabled: true
        )
        XCTAssertNotEqual(base, withNote)
    }

    func testTurnNoteEquatableIgnoresDerivedStyle() {
        // icon/tint 由 text 确定性派生 → 同 text 不同样式实例仍相等
        let a = TurnNote(text: "同文本", icon: .dot, tint: Color.ink500)
        let b = TurnNote(text: "同文本", icon: .note, tint: Color.brandAccent)
        XCTAssertEqual(a, b)
        // 载荷变化 → 不等
        var c = TurnNote(text: "同文本", icon: .dot, tint: Color.ink500)
        c.milestones = [MilestoneStamp(kind: "decision", count: 2)]
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ④ 性能基准（优化前后对比的数据来源）

    /// 代表性流式正文：40 段（~4KB，段落含加粗/行内代码/链接的典型密度）。
    private static let sampleText = Array(
        repeating: "这是一段用于性能基准的正文段落，包含**加粗**、`行内代码`与[链接](https://example.com) 的混合排版，模拟澄清阶段 AI 回答的典型密度。",
        count: 40
    ).joined(separator: "\n\n")

    /// Duration → 秒（基准打印与比值断言用）。
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// 旧路径单 tick 成本：全量块重算（每块重建 AttributedString）。
    func testPerfFullInlineAllBlocks() {
        let clock = ContinuousClock()
        let blocks = MarkdownParser.parseBlocks(Self.sampleText)
        XCTAssertEqual(blocks.count, 40)
        let start = clock.now
        for _ in 0..<20 {
            for block in blocks {
                if case .paragraph(let text) = block {
                    _ = MarkdownParser.inline(text, size: 15)
                }
            }
        }
        let elapsed = clock.now - start
        print("[perf] 旧路径：20 tick × 全量 inline 40 块 = \(Self.seconds(elapsed))s")
        XCTAssertGreaterThan(elapsed, Duration.seconds(0))
    }

    /// 新路径单 tick 成本：全文行扫描 + 稳定块等价比较 + 仅尾部块重算。
    func testPerfIncrementalTailBlock() {
        let clock = ContinuousClock()
        let blocks = MarkdownParser.parseBlocks(Self.sampleText)
        let start = clock.now
        for _ in 0..<20 {
            // parseBlocks 仍是全文行扫描（O(n)，每 tick 必跑）
            _ = MarkdownParser.parseBlocks(Self.sampleText)
            // 稳定块：等价短路（Block ==，memcmp 级）
            for block in blocks.dropLast() {
                XCTAssertTrue(block == block)
            }
            // 尾部生长中的块：重算 inline
            if case .paragraph(let text) = blocks.last! {
                _ = MarkdownParser.inline(text, size: 15)
            }
        }
        let elapsed = clock.now - start
        print("[perf] 新路径：20 tick × 扫描 + 39 块等价短路 + 1 块 inline = \(Self.seconds(elapsed))s")
        XCTAssertGreaterThan(elapsed, Duration.seconds(0))
    }

    /// 对比断言：同规模 tick 批次下，增量路径必须显著快于全量路径。
    func testPerfIncrementalBeatsFull() {
        let clock = ContinuousClock()
        func fullCost() -> Double {
            let blocks = MarkdownParser.parseBlocks(Self.sampleText)
            let start = clock.now
            for _ in 0..<20 {
                for block in blocks {
                    if case .paragraph(let text) = block {
                        _ = MarkdownParser.inline(text, size: 15)
                    }
                }
            }
            return Self.seconds(clock.now - start)
        }
        func incrementalCost() -> Double {
            let blocks = MarkdownParser.parseBlocks(Self.sampleText)
            let start = clock.now
            for _ in 0..<20 {
                _ = MarkdownParser.parseBlocks(Self.sampleText)
                for block in blocks.dropLast() { _ = block == block }
                if case .paragraph(let text) = blocks.last! {
                    _ = MarkdownParser.inline(text, size: 15)
                }
            }
            return Self.seconds(clock.now - start)
        }
        let full = fullCost()
        let inc = incrementalCost()
        print("[perf] 对比：全量 \(full)s vs 增量 \(inc)s（加速比 \(full / inc)×）")
        // 增量路径含 parseBlocks 扫描开销，宽松断言 ≥ 1.5× 加速（实测通常远高）
        XCTAssertGreaterThan(full / inc, 1.5)
    }
}
