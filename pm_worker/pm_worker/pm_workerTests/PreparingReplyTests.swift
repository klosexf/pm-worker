//
//  PreparingReplyTests.swift
//  pm_workerTests
//
//  待回复态（StreamState.isPreparing，per-session 键）回归锚点：用户消息乐观上屏到
//  回复流开启之间存在提示词组装 / 历史压缩等前置网络往返，思考占位卡必须在该空窗
//  即时显示——
//  ① 置位 / 清除（per-session 键，空态不留键）
//  ② 多会话占位互不拒绝（流态扇出）；同会话重复置位幂等
//  ③ 待回复期插话入队放行（enqueueSteering 本会话守卫）
//  ④ stopGeneration 清除本会话待回复态
//  ⑤ performSend 错误路径清空本会话流态键（死端点 send 走 ⚠️ 收尾后不得残留占位）
//  ⑥ 系统轮错误路径不残留待回复态
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

    // MARK: - ① 置位 / 清除（per-session 键）

    @MainActor
    func testBeginPinsSessionAndEndClears() {
        let store = SessionStore()

        XCTAssertNil(store.streams["s1"], "空闲态不得自带待回复占位（无键）")

        store.beginPreparingReply(sessionID: "s1")
        XCTAssertEqual(
            store.streams["s1"]?.isPreparing, true,
            "置位后占位必须立即可见（发送即显示正在思考的依据）"
        )

        store.endPreparingReply(sessionID: "s1")
        XCTAssertNil(store.streams["s1"], "清除后空态不留键")
        XCTAssertFalse(store.isPreparingReply, "全局待回复口径随之翻 false")
    }

    // MARK: - ② 多会话占位互不拒绝（流态扇出）

    @MainActor
    func testBeginPreparingReplyPerSessionIndependent() {
        let store = SessionStore()
        store.beginPreparingReply(sessionID: "s1")
        store.beginPreparingReply(sessionID: "s2")

        XCTAssertEqual(store.streams["s1"]?.isPreparing, true)
        XCTAssertEqual(
            store.streams["s2"]?.isPreparing, true,
            "他会话占位置位不得被拒（多会话并行，旧全局互斥语义已按会话键拆分）"
        )

        // 同会话重复置位幂等（无副作用）
        store.beginPreparingReply(sessionID: "s1")
        XCTAssertEqual(store.streams["s1"]?.isPreparing, true)
    }

    // MARK: - ③ 待回复期插话入队放行（本会话守卫）

    @MainActor
    func testEnqueueSteeringAcceptedDuringPreparingReply() throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")
        store.beginPreparingReply(sessionID: "s1")
        store.enqueueSteering("补一句：目标用户是独立开发者")

        XCTAssertEqual(
            store.steeringQueues["s1"]?.count, 1,
            "待回复期插话必须入本会话队列（流开启的首个边界统一注入，不得因未开流被吞）"
        )
        XCTAssertTrue(store.followUpQueues.isEmpty)
    }

    // MARK: - ④ stopGeneration 清除本会话

    @MainActor
    func testStopGenerationClearsPreparingReply() {
        let store = SessionStore()
        store.beginPreparingReply(sessionID: "s1")

        store.stopGeneration(sessionID: "s1")

        XCTAssertNil(store.streams["s1"], "停止必须连带收起待回复占位（整键移除）")
        XCTAssertFalse(store.isPreparingReply)
    }

    // MARK: - ⑤ performSend 错误路径清除

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
        XCTAssertTrue(store.streams.isEmpty, "错误收尾后本会话流态键必须整体移除（空态不留键）")
        XCTAssertEqual(
            store.entries.last?.role, .system,
            "死端点错误必须落 ⚠️ 系统行（用户可见的失败反馈）"
        )
        XCTAssertEqual(store.entries.last?.content.first.map(String.init), "⚠️")
    }

    // MARK: - ⑥ 系统轮错误路径不残留

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
        XCTAssertTrue(store.streams.isEmpty, "系统轮失败路径不得残留本会话流态键")
    }
}
