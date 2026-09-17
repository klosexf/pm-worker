//
//  PreparingReplyTests.swift
//  pm_workerTests
//
//  待回复态（isPreparingReply）回归锚点：用户消息乐观上屏到回复流开启之间存在
//  提示词组装 / 历史压缩等前置网络往返，思考占位卡必须在该空窗即时显示——
//  ① 置位 / 清除 / 幂等（归属会话防覆盖）
//  ② 待回复期插话入队放行（enqueueSteering 守卫扩展）
//  ③ stopGeneration 清除待回复态
//  ④ performSend 错误路径清除（死端点 send 走 ⚠️ 收尾后不得残留占位）
//  ⑤ 系统轮错误路径不残留待回复态
//

import XCTest
@testable import pm_worker

final class PreparingReplyTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-worker-preparing-reply-\(UUID().uuidString)")
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    /// 死端点（端口 9 discard）：连接即时拒绝 / 缺 Key 即抛——performSend 必走错误收尾。
    private func makeDeadEndpointSettings() -> LLMSettings {
        LLMSettings(
            stages: [.clarify: StageModelConfig(
                provider: "openai", model: "stub", baseURL: "http://127.0.0.1:9/v1"
            )],
            maxTokensPerRun: 1000
        )
    }

    // MARK: - ① 置位 / 清除 / 幂等

    @MainActor
    func testBeginPinsSessionAndEndClears() {
        let store = SessionStore()

        XCTAssertFalse(store.isPreparingReply, "空闲态不得自带待回复占位")
        XCTAssertNil(store.preparingSessionID)

        store.beginPreparingReply(sessionID: "s1")
        XCTAssertTrue(store.isPreparingReply, "置位后占位必须立即可见（发送即显示正在思考的依据）")
        XCTAssertEqual(store.preparingSessionID, "s1", "占位必须钉在发起会话（切会话不串显）")

        store.endPreparingReply()
        XCTAssertFalse(store.isPreparingReply)
        XCTAssertNil(store.preparingSessionID)
    }

    @MainActor
    func testBeginIsIdempotentAndKeepsFirstOwner() {
        let store = SessionStore()
        store.beginPreparingReply(sessionID: "s1")
        store.beginPreparingReply(sessionID: "s2")

        XCTAssertEqual(
            store.preparingSessionID, "s1",
            "待回复进行中重复置位必须 no-op（防后来者覆盖归属会话）"
        )
    }

    // MARK: - ② 待回复期插话入队放行

    @MainActor
    func testEnqueueSteeringAcceptedDuringPreparingReply() {
        let store = SessionStore()
        store.beginPreparingReply(sessionID: "s1")
        store.enqueueSteering("补一句：目标用户是独立开发者")

        XCTAssertEqual(
            store.steeringQueue.count, 1,
            "待回复期插话必须入队（流开启的首个边界统一注入，不得因未开流被吞）"
        )
    }

    // MARK: - ③ stopGeneration 清除

    @MainActor
    func testStopGenerationClearsPreparingReply() {
        let store = SessionStore()
        store.beginPreparingReply(sessionID: "s1")

        store.stopGeneration()

        XCTAssertFalse(store.isPreparingReply, "停止必须连带收起待回复占位")
        XCTAssertNil(store.preparingSessionID)
    }

    // MARK: - ④ performSend 错误路径清除

    /// 死端点 send：占位随 performSend 入口置位，⚠️ 错误收尾后必须清零——
    /// 防回归锚：错误路径漏清会让「正在思考」占位永久挂在会话尾部。
    @MainActor
    func testSendErrorPathClearsPreparingReply() async throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        await store.send(
            "你好", settings: makeDeadEndpointSettings(), stage: .clarify,
            systemPrompt: "测试系统提示"
        )

        XCTAssertFalse(store.isStreaming)
        XCTAssertFalse(store.isPreparingReply, "send 错误收尾后待回复占位必须已清除")
        XCTAssertNil(store.preparingSessionID)
        XCTAssertEqual(
            store.entries.last?.role, .system,
            "死端点错误必须落 ⚠️ 系统行（用户可见的失败反馈）"
        )
        XCTAssertEqual(store.entries.last?.content.first.map(String.init), "⚠️")
    }

    // MARK: - ⑤ 系统轮错误路径不残留

    @MainActor
    func testSystemTurnErrorPathLeavesNoPreparingReply() async throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        let outcome = await store.sendSystemTurn(
            note: "📝 系统轮", userPrompt: "继续",
            settings: makeDeadEndpointSettings(), stage: .clarify,
            systemPrompt: "测试系统提示"
        )

        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(store.isStreaming)
        XCTAssertFalse(store.isPreparingReply, "系统轮失败路径不得残留待回复占位")
        XCTAssertNil(store.preparingSessionID)
    }
}
