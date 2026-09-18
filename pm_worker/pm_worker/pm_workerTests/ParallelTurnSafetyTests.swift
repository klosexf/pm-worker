//
//  ParallelTurnSafetyTests.swift
//  pm_workerTests
//
//  同版本/跨版本多会话并行回合（M1-M5 + B 后放宽）回归锚点：
//  ① 并行落实：他会话生成中，采纳仍立即落实（不排队）——排队只剩
//    「发起会话自己 busy」与「同版本落实在途」两种场景
//  ② 发起会话 busy → 排队挂起；空闲后自动冲洗（与 UI 选中解耦）
//  ③ 逃生门「只记账」坐标钉排队条目（M1）：排队后切走，记账落排队时版本
//  ④ 任意会话只读投影（M1）：entries(project:version:sessionId:) 按会话过滤读盘
//  ⑤ 同版本双会话 busy 矩阵（M2 语义补充）：流会话 busy、同版本他会话不 busy、版本 busy 亮
//  ⑥ 引擎重建即弃（M3）：新实例从磁盘标记恢复推进后的阶段（确认链异上下文推进的根基）
//

import XCTest
@testable import pm_worker

final class AdoptFlushCrossContextTests: XCTestCase {
    var tempRoot: URL!
    private let project = "并行项目"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-adoptflush-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion("v1", in: project)
        try? PMAgentStore.createVersion("v2", in: project)
        try? PMAgentStore.ensureWorkspace(project: project, version: "v1")
        try? PMAgentStore.ensureWorkspace(project: project, version: "v2")
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func makeRecord() -> RiskRecord {
        RiskRecord(
            version: "v1", stage: .clarify,
            hypothesis: "学生手机装不进第三方 App",
            plan: "开工前先执行已交付的访谈脚本",
            originRef: "测试登记"
        )
    }

    private func jsonlText(project: String, version: String) -> String {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 把版本 v1 置于 busy（发起会话占位 + 开流，同真实发送路径登记）
    private func busyVersion(_ model: AppModel, sessionId: String) {
        model.sessionStore.beginPreparingReply(
            sessionID: sessionId,
            origin: SessionStore.StreamOrigin(
                project: project, version: "v1", sessionId: sessionId
            )
        )
        model.sessionStore.mutateStream(sessionId) {
            $0.isStreaming = true; $0.isPreparing = false; $0.text = "增量"
        }
    }

    // MARK: ① 并行落实（B 后放宽）：他会话的流不拦采纳

    /// 用户原始场景终态：版本内会话 s1 生成中，用户在会话 s2 点击采纳 →
    /// **立即落实**（采纳消息落 s2、驱动 AI 回合），不等 s1、不排队。
    /// 旧口径（isVersionBusy）此处会排队——放宽后只有发起会话自己忙才排。
    @MainActor
    func testAdoptImplementsImmediatelyWhileAnotherSessionStreams() async throws {
        let model = AppModel()
        model.selection = .session(project: project, version: "v1", sessionId: "s2")
        let record = makeRecord()
        try RiskStore(project: project, version: "v1").append(record)

        // 他会话 s1 生成中（同版本）
        busyVersion(model, sessionId: "s1")
        XCTAssertTrue(model.sessionStore.isVersionBusy(project: project, version: "v1"))

        // s2 点击采纳 → 立即落实（乐观上屏 s2 + 消息落盘 s2）
        let staged = model.sessionStore.stageOutgoingUser(AppModel.adoptMessageText(record))
        Task {
            await model.implementRiskAdoption(
                record, stagedEntry: staged, project: project, version: "v1"
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if jsonlText(project: project, version: "v1").contains("⚡ 风险台账 · 采纳") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(
            jsonlText(project: project, version: "v1").contains("⚡ 风险台账 · 采纳"),
            "他会话生成中，采纳仍须立即落实（不排队）"
        )
        XCTAssertTrue(
            jsonlText(project: project, version: "v1").contains("\"sessionId\":\"s2\""),
            "采纳消息落点击会话 s2"
        )
        // 落实闭环的后续 LLM 往返（无 provider 快速失败）不等待——
        // 断言核心是「消息立即落盘不被拦」，已达成。
    }

    // MARK: ② 发起会话 busy → 排队，空闲后冲洗

    /// 只有发起会话自己在生成时才排队（每会话一条流铁律）；空闲后自动冲洗。
    @MainActor
    func testQueuedAdoptFlushesWhenOriginSessionIdle() async throws {
        let model = AppModel()
        model.selection = .session(project: project, version: "v1", sessionId: "s1")
        let record = makeRecord()
        try RiskStore(project: project, version: "v1").append(record)

        // s1 自己生成中点击采纳 → 排队（乐观上屏未落盘）
        busyVersion(model, sessionId: "s1")
        model.queueAdopt(record)
        XCTAssertEqual(model.queuedAdopts.count, 1)
        XCTAssertFalse(
            jsonlText(project: project, version: "v1").contains("⚡ 风险台账 · 采纳"),
            "排队期不落盘（仅内存乐观上屏）"
        )

        // s1 空闲（登记随空态剪枝注销）
        model.sessionStore.mutateStream("s1") { $0.isStreaming = false; $0.text = "" }
        // 任一上下文变化唤醒冲洗
        model.selection = .newTask
        model.selection = .session(project: project, version: "v1", sessionId: "s1")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if jsonlText(project: project, version: "v1").contains("⚡ 风险台账 · 采纳") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(
            jsonlText(project: project, version: "v1").contains("⚡ 风险台账 · 采纳"),
            "发起会话空闲后采纳自动冲洗发出"
        )
    }

    // MARK: ③ 逃生门「只记账」钉排队坐标

    @MainActor
    func testCancelQueuedAdoptWritesToQueuedVersionNotSelection() throws {
        let model = AppModel()
        model.selection = .session(project: project, version: "v1", sessionId: "s1")
        let record = makeRecord()
        try RiskStore(project: project, version: "v1").append(record)

        busyVersion(model, sessionId: "s1")
        model.queueAdopt(record)

        // 用户切到 v2 后点「不等了，只记账」
        model.selection = .session(project: project, version: "v2", sessionId: "s2")
        model.cancelQueuedAdopt(record)

        XCTAssertEqual(model.queuedAdopts.count, 0, "逃生门撤回排队条目")
        let risks = RiskStore(project: project, version: "v1").risks
        XCTAssertEqual(
            risks.first { $0.id == record.id }?.status, .mitigating,
            "记账落排队时版本 v1 的台账（采纳态），不落当前选中的 v2"
        )
        let text = jsonlText(project: project, version: "v1")
        XCTAssertTrue(text.contains("只记账"), "留痕行落 v1 的会话流")
        XCTAssertTrue(text.contains("\"sessionId\":\"s1\""), "留痕行钉排队会话 s1")
        XCTAssertFalse(
            jsonlText(project: project, version: "v2").contains("只记账"),
            "当前选中 v2 的会话流不受牵连"
        )
    }
}

final class SessionProjectionTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-projection-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.ensureWorkspace(project: "投影项目", version: "v1")
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: ④ 任意会话只读投影（M1 origin 化基建）

    /// 同版本双会话混居于版本级单 jsonl：投影按 sessionId 过滤，
    /// 链体（确认链 transcript / 技能历史兜底）据此读 origin 会话而不读错。
    @MainActor
    func testEntriesProjectionFiltersBySession() throws {
        let store = SessionStore()
        store.open(project: "投影项目", version: "v1", sessionId: "sA")
        let entryA = store.makeEntry(role: .user, content: "A 的消息")
        try store.append(entryA)

        // sB 的条目直接落同一版本 jsonl（appendPinned 的真实形态：跨会话钉定写入）
        let entryB = store.makeEntry(role: .user, content: "B 的消息", sessionID: "sB")
        try store.appendPinned(
            entryB,
            origin: SessionStore.StreamOrigin(project: "投影项目", version: "v1", sessionId: "sB")
        )

        XCTAssertEqual(
            store.entries(project: "投影项目", version: "v1", sessionId: "sA").map(\.id),
            [entryA.id],
            "投影只返回 origin 会话自己的条目"
        )
        XCTAssertEqual(
            store.entries(project: "投影项目", version: "v1", sessionId: "sB").map(\.id),
            [entryB.id]
        )
        XCTAssertTrue(
            store.entries(project: "投影项目", version: "v1", sessionId: "ghost").isEmpty,
            "不存在的会话投影为空"
        )
        XCTAssertEqual(
            store.entries(project: "投影项目", version: "不存在", sessionId: "sA"),
            [],
            "不存在的版本投影为空（读盘无文件）"
        )
    }

    // MARK: ⑤ 同版本双会话 busy 矩阵（发送闸口语义锚点）

    /// 发送闸口是 isSessionBusy 口径（阶段 3 + M2 保持）：同版本会话 B 的发送
    /// 不被会话 A 的流拦截（会话 B 不 busy）；版本级结构闸（isVersionBusy）仍亮。
    @MainActor
    func testSameVersionSecondSessionNotBusyWhileFirstStreams() {
        let store = SessionStore()
        store.beginPreparingReply(
            sessionID: "sA",
            origin: SessionStore.StreamOrigin(project: "P", version: "V", sessionId: "sA")
        )
        store.mutateStream("sA") { $0.isStreaming = true; $0.text = "A 流" }

        XCTAssertTrue(store.isSessionBusy("sA"), "流会话自身 busy（发送转插话排队）")
        XCTAssertFalse(
            store.isSessionBusy("sB"),
            "同版本他会话不 busy（B 可正常发送，双流并行）"
        )
        XCTAssertTrue(store.isVersionBusy(project: "P", version: "V"), "版本级结构闸亮（采纳/确认串行）")
        XCTAssertFalse(store.isVersionBusy(project: "P", version: "V2"), "他版本不受牵连")
    }
}

final class PipelineEngineRebuildTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-engine-rebuild-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.ensureWorkspace(project: "重建项目", version: "v1")
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: ⑥ 引擎重建即弃（M3 确认链异上下文推进的根基）

    /// 确认链中途切上下文时按 origin 重建引擎推进：新实例必须恢复到推进后的
    /// 阶段（写完即弃不回填 AppModel.pipeline，也无状态丢失）。
    /// 阶段以磁盘标记为唯一事实源（deriveStage，库只是加速）——与真实确认链
    /// 同序：先落澄清要点表（confirmClarify 的 writeVerified）→ 再推进。
    @MainActor
    func testRebuiltEngineRestoresAdvancedStage() throws {
        let dir = PMAgentStore.versionURL(project: "重建项目", version: "v1")
        let engine1 = PipelineEngine(project: "重建项目", version: "v1", database: nil)
        XCTAssertEqual(engine1.stage, .clarify, "新版本从澄清起步")

        // 要点表落盘（真实链中由 confirmClarify 先写表再推进）
        try PMAgentStore.writeVerified(
            "# 澄清要点表（测试）",
            to: dir.appendingPathComponent(ArtifactPath.clarification)
        )
        engine1.advanceFromClarify(outcome: "approved")
        XCTAssertEqual(engine1.stage, .structure, "推进后活实例阶段前移")

        let engine2 = PipelineEngine(project: "重建项目", version: "v1", database: nil)
        XCTAssertEqual(
            engine2.stage, .structure,
            "重建实例从磁盘标记恢复推进后的阶段（实例可随时重建，无状态丢失）"
        )
    }
}
