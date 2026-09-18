//
//  VersionBusyScopeTests.swift
//  pm_workerTests
//
//  阶段 3 判据迁移（全局单流闸 → 版本级/会话级 busy）回归锚点：
//  ① isVersionBusy 判据矩阵：A 流（P1/V1）只点亮 (P1,V1)，(P1,V2)/(P2,V1) 不受牵连
//  ② 流结束（空态剪枝 / stopGeneration）→ 登记一并注销，版本/项目判据全灭（无泄漏）
//  ③ 占位态（isPreparing）计入版本 busy（乐观置位即登记，防「占位期版本判空闲」竞态）
//  ④ 无 origin 的 beginPreparingReply 不登记（兼容测试入口语义不变）
//  ⑤ 真实流路径（死端点 sendSystemTurn → 错误收尾）后版本判据归零
//  ⑥ 结构锁口径抽查：AppModel.deleteSession 只被目标版本自身的流拦截
//
//  登记通道 = beginPreparingReply(origin:) / performSendSystemTurn 内部登记，
//  与 streams 键同生命周期（mutateStream 空态剪枝 / defer / stopGeneration 一并注销）。
//

import XCTest
@testable import pm_worker

final class VersionBusyScopeTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-versionbusy-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    /// 死端点（端口 9 discard）：连接即时拒绝——sendSystemTurn 必走错误收尾（含 defer）。
    private func makeDeadEndpointSettings() -> LLMSettings {
        LLMSettings(
            stages: [.clarify: StageModelConfig(
                provider: "openai", model: "stub", baseURL: "http://127.0.0.1:9/v1"
            )],
            maxTokensPerRun: 1000
        )
    }

    // MARK: - ① 判据矩阵

    @MainActor
    func testIsVersionBusyMatchesOnlyOriginVersion() {
        let store = SessionStore()
        // A 流在 P1/V1 进行中（登记 + 开流，同 performSend 真实路径）
        store.beginPreparingReply(
            sessionID: "A",
            origin: SessionStore.StreamOrigin(project: "P1", version: "V1", sessionId: "A")
        )
        store.mutateStream("A") { $0.isStreaming = true; $0.text = "A 的增量" }

        XCTAssertTrue(store.isVersionBusy(project: "P1", version: "V1"), "发起版本的 busy 判据亮")
        XCTAssertFalse(
            store.isVersionBusy(project: "P1", version: "V2"),
            "同项目他版本不被 A 的流牵连"
        )
        XCTAssertFalse(
            store.isVersionBusy(project: "P2", version: "V1"),
            "他项目同名版本不被 A 的流牵连"
        )
        XCTAssertTrue(store.isProjectBusy(project: "P1"), "项目级判据随版本登记点亮")
        XCTAssertFalse(store.isProjectBusy(project: "P2"), "其他项目不受牵连")
    }

    // MARK: - ② 流结束注销（泄漏回归）

    @MainActor
    func testVersionBusyClearsAfterStreamEndsByPrune() {
        let store = SessionStore()
        store.beginPreparingReply(
            sessionID: "A",
            origin: SessionStore.StreamOrigin(project: "P1", version: "V1", sessionId: "A")
        )
        // 开流转正（同 streamReply）：占位熄、流式亮
        store.mutateStream("A") {
            $0.isStreaming = true
            $0.isPreparing = false
            $0.text = "增量"
        }
        XCTAssertTrue(store.isVersionBusy(project: "P1", version: "V1"))

        // 流自然收尾：清增量 + 关流 → 全空态剪枝（streams 键与登记一并移除）
        store.mutateStream("A") { $0.isStreaming = false; $0.text = "" }
        XCTAssertNil(store.streams["A"], "流态键随收尾移除")
        XCTAssertFalse(
            store.isVersionBusy(project: "P1", version: "V1"),
            "流结束后版本判据必须归零（登记不得残留）"
        )
        XCTAssertFalse(store.isProjectBusy(project: "P1"), "项目级判据同步归零")
    }

    @MainActor
    func testVersionBusyClearsAfterStopGeneration() {
        let store = SessionStore()
        store.beginPreparingReply(
            sessionID: "A",
            origin: SessionStore.StreamOrigin(project: "P1", version: "V1", sessionId: "A")
        )
        store.mutateStream("A") { $0.isStreaming = true; $0.text = "增量" }
        XCTAssertTrue(store.isVersionBusy(project: "P1", version: "V1"))

        store.stopGeneration(sessionID: "A")
        XCTAssertFalse(
            store.isVersionBusy(project: "P1", version: "V1"),
            "stopGeneration 后版本判据必须归零（登记与流态键同生命周期）"
        )
        XCTAssertFalse(store.isProjectBusy(project: "P1"))
        // 他会话新流不受残留影响（此处以同键重登记验证幂等）
        store.beginPreparingReply(
            sessionID: "A",
            origin: SessionStore.StreamOrigin(project: "P1", version: "V1", sessionId: "A")
        )
        XCTAssertTrue(store.isVersionBusy(project: "P1", version: "V1"), "重登记后判据恢复")
    }

    // MARK: - ③ 占位态计入 busy

    @MainActor
    func testPreparingStateCountsAsVersionBusy() {
        let store = SessionStore()
        // 乐观置位（带 origin 登记）后、开流转正前：提示词组装的待回复窗口
        store.beginPreparingReply(
            sessionID: "A",
            origin: SessionStore.StreamOrigin(project: "P1", version: "V1", sessionId: "A")
        )
        XCTAssertEqual(store.streams["A"]?.isPreparing, true)
        XCTAssertFalse(store.streams["A"]?.isStreaming ?? true, "尚未开流")
        XCTAssertTrue(
            store.isVersionBusy(project: "P1", version: "V1"),
            "占位态必须计入版本 busy（漏判会与紧随开流的主回合竞态）"
        )
        XCTAssertFalse(store.isVersionBusy(project: "P1", version: "V2"))
    }

    // MARK: - ④ 无 origin 的置位不登记

    @MainActor
    func testBeginPreparingReplyWithoutOriginDoesNotRegisterContext() {
        let store = SessionStore()
        store.beginPreparingReply(sessionID: "A")  // 兼容入口（测试直驱语义）
        XCTAssertEqual(store.streams["A"]?.isPreparing, true, "占位本身照常置位")
        XCTAssertFalse(
            store.isVersionBusy(project: "P1", version: "V1"),
            "无 origin 上下文信息时不登记（版本判据无从归属，保持 false）"
        )
    }

    // MARK: - ⑤ 真实流收尾路径

    /// 死端点 sendSystemTurn 驱动真实登记 → 抛错 → defer/兜底收尾全路径：
    /// 流态键与发起上下文登记必须双双归零。
    @MainActor
    func testRealStreamTeardownClearsVersionBusy() async throws {
        try PMAgentStore.ensureWorkspace(project: "默认", version: "unversioned")
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        let outcome = await store.sendSystemTurn(
            note: "📝 系统轮", userPrompt: "继续",
            settings: makeDeadEndpointSettings(), stage: .clarify,
            systemPrompt: "测试系统提示"
        )

        XCTAssertEqual(outcome, .interrupted)
        XCTAssertNil(store.streams["s1"], "流态键随收尾移除")
        XCTAssertFalse(
            store.isVersionBusy(project: "默认", version: "unversioned"),
            "真实流收尾后版本判据归零（登记不得残留）"
        )
        XCTAssertFalse(store.isProjectBusy(project: "默认"))
    }

    // MARK: - ⑥ 结构锁口径抽查（AppModel.deleteSession）

    @MainActor
    func testDeleteSessionBlockedOnlyByTargetVersionStream() throws {
        try PMAgentStore.createProject(named: "门闸项目")
        try PMAgentStore.createVersion("v1", in: "门闸项目")
        try PMAgentStore.createVersion("v2", in: "门闸项目")
        try PMAgentStore.ensureWorkspace(project: "门闸项目", version: "v1")
        try PMAgentStore.ensureWorkspace(project: "门闸项目", version: "v2")

        let model = AppModel()
        // 他会话 sB 的流在 v1 进行中（登记 origin 上下文）
        model.sessionStore.beginPreparingReply(
            sessionID: "sB",
            origin: SessionStore.StreamOrigin(project: "门闸项目", version: "v1", sessionId: "sB")
        )
        model.sessionStore.mutateStream("sB") { $0.isStreaming = true; $0.text = "v1 的流" }

        XCTAssertEqual(
            model.deleteSession(project: "门闸项目", version: "v1", sessionId: "sB"),
            "正在生成回答，请等待生成完成后再删除",
            "目标版本自身的流必须拦删除"
        )

        // 停掉 v1 自身的流后，只剩他版本 v2 的流——不得再拦 v1 的删除（旧全局闸会误拦）
        model.sessionStore.stopGeneration(sessionID: "sB")
        XCTAssertFalse(
            model.sessionStore.isVersionBusy(project: "门闸项目", version: "v1"),
            "v1 自身的流停止后判据归零（登记无残留）"
        )

        model.sessionStore.beginPreparingReply(
            sessionID: "sC",
            origin: SessionStore.StreamOrigin(project: "门闸项目", version: "v2", sessionId: "sC")
        )
        model.sessionStore.mutateStream("sC") { $0.isStreaming = true; $0.text = "v2 的流" }
        XCTAssertNil(
            model.deleteSession(project: "门闸项目", version: "v1", sessionId: "unrelated"),
            "他版本（v2）的流不再拦截 v1 的删除"
        )
    }
}
