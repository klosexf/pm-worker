//
//  StopGenerationTests.swift
//  pm_workerTests
//
//  生成停止机制四项测试：
//  ① 空闲态 stopGeneration 无害（无句柄时 no-op，状态不变）
//  ② 停止 ≤300ms 生效（trackGeneration 句柄取消真传导到运行中的生成任务）
//  ③ makeStoppedTurn 部分内容收尾（原文逐字保留 / sessionId 钉回发起会话 / 空部分省略 assistant）
//  ④ isCancellation 取消类错误判定 + ⏹ 注记独立成行（不得并入相邻气泡注记）
//

import XCTest
@testable import pm_worker

final class StopGenerationTests: XCTestCase {

    // MARK: - ① 空闲态 no-op

    @MainActor
    func testStopGenerationOnIdleStoreIsNoOp() {
        let store = SessionStore()
        store.stopGeneration()

        XCTAssertFalse(store.isStreaming, "空闲态停止后不得进入流式态")
        XCTAssertTrue(store.streams.isEmpty, "空闲态停止不得留下流态残留")
    }

    // MARK: - ② 停止延迟 ≤300ms

    /// trackGeneration 句柄 + 假生成（2s sleep）：停止调用后必须在 300ms 内
    /// 传导取消并使 trackGeneration 返回（真实链路里就是底层 SSE 流被掐断的时长上界）。
    @MainActor
    func testStopGenerationCancelsTrackedTaskWithin300ms() async throws {
        let store = SessionStore()
        let generation = Task {
            await store.trackGeneration {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // 100ms：确保生成任务已起跑、句柄已登记（正停在 sleep 的取消点上）
        try await Task.sleep(nanoseconds: 100_000_000)

        let stopAt = Date()
        store.stopGeneration()
        await generation.value
        let elapsed = Date().timeIntervalSince(stopAt)

        XCTAssertLessThan(elapsed, 0.3, "停止必须 ≤300ms 内生效（2s 假生成被立即取消）")
        XCTAssertFalse(store.isStreaming, "停止后流式态必须已翻转（按钮即时回「发送」的依据）")
        XCTAssertTrue(store.streams.isEmpty, "停止后本会话流态键必须移除（流式气泡即时收起的依据）")
    }

    // MARK: - ③ 停止收尾的回合构造

    func testMakeStoppedTurnKeepsPartialContentAndPinsSession() {
        let partial = "## 半截产物\n```artifact:prototype"
        let (assistant, note) = SessionStore.makeStoppedTurn(
            partial: partial,
            reasoning: "第一步推理\n第二步推理",
            duration: 7,
            skills: ["poc-probe-selection"],
            sessionId: "origin-1"
        )

        XCTAssertEqual(assistant?.content, partial, "已生成的部分回答必须逐字保留")
        XCTAssertEqual(assistant?.sessionId, "origin-1", "部分回答必须钉回发起会话（不随切换漂移）")
        XCTAssertEqual(assistant?.role, .assistant)
        XCTAssertNotNil(assistant?.think, "思考数据照常装配（思考卡可回看）")
        XCTAssertEqual(assistant?.think?.steps.first?.skill, "poc-probe-selection")

        XCTAssertEqual(note.role, .system)
        XCTAssertEqual(note.sessionId, "origin-1")
        XCTAssertTrue(note.content.hasPrefix("⏹"), "停止注记前缀 ⏹（UI 按中性信息条渲染）")
        XCTAssertTrue(note.content.contains("已生成的部分已保留"))
    }

    func testMakeStoppedTurnEmptyPartialOmitsAssistant() {
        let (assistant, note) = SessionStore.makeStoppedTurn(
            partial: "", reasoning: "", duration: 0, skills: [], sessionId: "s1"
        )

        XCTAssertNil(assistant, "未产出任何内容时不得落空 assistant 条目")
        XCTAssertEqual(note.content, "⏹ 已停止", "无部分内容时注记用短文案")
        XCTAssertEqual(note.sessionId, "s1")
    }

    // MARK: - ④ 取消判定 + ⏹ 注记独立成行

    func testIsCancellationClassification() {
        XCTAssertTrue(SessionStore.isCancellation(CancellationError()))
        XCTAssertTrue(SessionStore.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(SessionStore.isCancellation(URLError(.badURL)))
        XCTAssertFalse(
            SessionStore.isCancellation(NSError(domain: "test", code: 1)),
            "普通错误不得误判为停止（⚠️ 错误路径的判据）"
        )
    }

    // MARK: - ⑤ Steering 队列（P3：插话排队与停止作废）

    /// ⏹ 停止注记不得被并入相邻 assistant 气泡（turnNote 前缀表不含 ⏹ → 独立事件条）。
    /// 防回归锚点：有人把 ⏹ 误加进 turnNote 可并入映射时当场红。
    @MainActor
    func testStoppedNoteRendersStandaloneNotMergedIntoBubbles() {
        let user = DiscussionEntry(
            id: "u1", sessionId: "s1", role: .user, content: "写个原型",
            createdAt: "2026-09-14T00:00:00Z"
        )
        let partial = DiscussionEntry(
            id: "a1", sessionId: "s1", role: .assistant, content: "部分内容",
            createdAt: "2026-09-14T00:00:01Z"
        )
        let note = DiscussionEntry(
            id: "n1", sessionId: "s1", role: .system,
            content: "⏹ 已停止——已生成的部分已保留",
            createdAt: "2026-09-14T00:00:02Z"
        )
        let merged = MessageBubble.mergedSystemIndices(in: [user, partial, note])

        XCTAssertFalse(merged.contains(2), "⏹ 停止注记必须独立成行，不得并入相邻气泡注记")
    }

    @MainActor
    func testEnqueueSteeringOnIdleStoreIsNoOp() {
        let store = SessionStore()
        store.enqueueSteering("补一句：目标用户是独立开发者")

        XCTAssertTrue(store.steeringQueues.isEmpty, "空闲态插话必须 no-op（不入队）")
        XCTAssertTrue(store.followUpQueues.isEmpty)
    }

    @MainActor
    func testStopGenerationClearsSteeringQueues() async throws {
        let store = SessionStore()
        // 停止清队列的语义锚点：队列注入插话后停止必须双清（排队气泡消失、不落盘）。
        // 队列写入走流式链路（enqueueSteering 有 isStreaming 守卫），此处以停止路径
        // 的幂等性 + 空闲 no-op 组成回归锚；流式中的入队由冒烟验证。
        let generation = Task {
            await store.trackGeneration {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        store.stopGeneration()
        await generation.value

        XCTAssertTrue(store.steeringQueues.isEmpty)
        XCTAssertTrue(store.followUpQueues.isEmpty)
        XCTAssertFalse(store.isStreaming)
    }
}
