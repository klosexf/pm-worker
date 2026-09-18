//
//  SessionStreamFanoutTests.swift
//  pm_workerTests
//
//  阶段 1 流态扇出（全局单流 → 多会话并行流）状态机层回归锚点：
//  ① 双会话扇出：A 开流态下 B 置位不被拒；两 key 流态互不污染
//  ② stopGeneration(sessionID:) 只影响目标会话（task 取消 + 流态/队列清除）
//  ③ streamReply 收尾 defer 只移除本会话 key（死端点 sendSystemTurn 驱动真实路径）
//  ④ 兼容属性口径：isStreaming = 任意 key 流式；currentStream = 当前打开会话键
//  ⑤ 队列字典：enqueueSteering 进当前会话队列，他会话队列为空
//  ⑥ mutateStream 空态剪枝 + setStreamPhase 当前会话/显式会话写入
//
//  说明：项目无 mock 流先例，text/think/skills 的流中写入统一经 origin.sessionId
//  单通道（by-construction 隔离），此处以 mutateStream 直驱状态机 + 死端点真实
//  收尾路径组合覆盖。
//

import XCTest
@testable import pm_worker

final class SessionStreamFanoutTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-worker-stream-fanout-\(UUID().uuidString)")
        PMAgentStore.rootOverride = tempRoot
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

    // MARK: - ① 双会话扇出

    @MainActor
    func testTwoSessionsFanOutWithoutCrossPollution() {
        let store = SessionStore()
        // A 占位 → 开流态（含增量/技能/阶段文案），B 随后置位
        store.beginPreparingReply(sessionID: "A")
        store.mutateStream("A") {
            $0.isStreaming = true
            $0.isPreparing = false
            $0.text = "A 的增量"
            $0.skills = ["poc-probe-selection"]
            $0.phaseTrail = [PhaseStep(label: "正在生成结构产物…", done: false)]
        }
        store.beginPreparingReply(sessionID: "B")

        XCTAssertEqual(
            store.streams["B"]?.isPreparing, true,
            "B 的占位置位不得被 A 的流态拒绝（旧全局互斥已按会话键拆分）"
        )
        // 两 key 各归各
        XCTAssertEqual(store.streams["A"]?.text, "A 的增量")
        XCTAssertEqual(store.streams["A"]?.skills, ["poc-probe-selection"])
        XCTAssertEqual(store.streams["A"]?.phaseTrail, [PhaseStep(label: "正在生成结构产物…", done: false)])
        XCTAssertEqual(store.streams["B"]?.text ?? "", "", "B 键不得串入 A 的增量")
        XCTAssertTrue(store.streams["B"]?.phaseTrail.isEmpty ?? true)
        XCTAssertTrue(store.streams["B"]?.skills.isEmpty ?? true, "B 键不得串入 A 的技能")
        XCTAssertFalse(store.streams["B"]?.isStreaming ?? true)

        // 清 A 占位不动 B（A 已开流占位本为 false，直接以 B 验证隔离）
        store.endPreparingReply(sessionID: "A")
        XCTAssertEqual(store.streams["B"]?.isPreparing, true, "endPreparingReply 只动本会话键")
    }

    // MARK: - ② stopGeneration per-session

    @MainActor
    func testStopGenerationOnlyAffectsTargetSession() async throws {
        let store = SessionStore()
        store.mutateStream("A") { $0.isStreaming = true; $0.text = "A 的增量" }
        store.beginPreparingReply(sessionID: "B")
        store.mutateStream("B") { $0.phaseTrail = [PhaseStep(label: "正在抽取澄清要点表…", done: false)] }

        let generation = Task {
            await store.trackGeneration(sessionID: "A") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // 100ms：确保 A 的句柄已登记（正停在 sleep 的取消点上）
        try await Task.sleep(nanoseconds: 100_000_000)

        let stopAt = Date()
        store.stopGeneration(sessionID: "A")
        await generation.value
        XCTAssertLessThan(
            Date().timeIntervalSince(stopAt), 0.3,
            "目标会话任务必须被取消（≤300ms 返回，同全局停止时延口径）"
        )

        XCTAssertNil(store.streams["A"], "A 的流态整体收起")
        XCTAssertNil(store.steeringQueues["A"])
        XCTAssertNil(store.followUpQueues["A"])
        XCTAssertEqual(store.streams["B"]?.isPreparing, true, "B 的占位不受 A 停止影响")
        XCTAssertEqual(store.streams["B"]?.phaseTrail.map(\.label), ["正在抽取澄清要点表…"], "B 的阶段文案不受影响")
        XCTAssertFalse(store.isStreaming, "全局流式口径随 A 清除翻 false")
        XCTAssertTrue(store.isPreparingReply, "全局待回复口径仍反映 B 的占位")
    }

    // MARK: - ③ streamReply 收尾只移除本会话 key

    /// 死端点 sendSystemTurn 驱动真实开流 → 抛错 → defer 收尾全路径：
    /// 本会话键必须移除，邻会话键毫发无损。
    @MainActor
    func testStreamReplyTeardownRemovesOnlyOwnKey() async throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")
        store.beginPreparingReply(sessionID: "s2")  // 邻会话流态哨兵

        let outcome = await store.sendSystemTurn(
            note: "📝 系统轮", userPrompt: "继续",
            settings: makeDeadEndpointSettings(), stage: .clarify,
            systemPrompt: "测试系统提示"
        )

        XCTAssertEqual(outcome, .interrupted)
        XCTAssertNil(store.streams["s1"], "s1 流态键随流收尾移除（defer + 错误兜底清态）")
        XCTAssertEqual(store.streams["s2"]?.isPreparing, true, "收尾不得波及邻会话 key")
        XCTAssertTrue(store.steeringQueues.isEmpty)
    }

    // MARK: - ④ 兼容属性口径

    @MainActor
    func testCompatPropertiesReflectAnySessionAndCurrentSession() throws {
        try? PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "cur")
        XCTAssertFalse(store.isStreaming)
        XCTAssertFalse(store.isPreparingReply)
        XCTAssertNil(store.currentStream)

        // 邻会话开流：全局口径亮、当前会话键不亮
        store.mutateStream("other") { $0.isStreaming = true }
        XCTAssertTrue(store.isStreaming, "isStreaming = 任意会话有流（全局资源闸口径）")
        XCTAssertNil(store.currentStream, "currentStream 只反映当前打开会话")
        XCTAssertFalse(store.isSessionBusy("cur"))

        // 当前会话开流：两个口径都亮
        store.mutateStream("cur") { $0.isStreaming = true; $0.text = "本会话增量" }
        XCTAssertTrue(store.isSessionBusy("cur"))
        XCTAssertEqual(store.currentStream?.text, "本会话增量", "currentStream = streams[sessionId]")

        // 当前会话只剩占位（无流）：isStreaming 熄、isPreparingReply 亮
        // （先剪掉邻会话的流，隔离「全局口径由谁点亮」）
        store.mutateStream("other") { $0.isStreaming = false }
        XCTAssertNil(store.streams["other"], "邻会话空态剪枝")
        store.mutateStream("cur") { $0.isStreaming = false; $0.isPreparing = true; $0.text = "" }
        XCTAssertFalse(store.isStreaming, "占位不计入全局流式口径")
        XCTAssertTrue(store.isPreparingReply)
        XCTAssertTrue(store.isSessionBusy("cur"))
    }

    // MARK: - ⑤ 队列字典

    @MainActor
    func testEnqueueSteeringRoutesToCurrentSessionQueueOnly() throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "sA")
        store.mutateStream("sA") { $0.isStreaming = true }

        store.enqueueSteering("插话一")
        store.enqueueSteering("插话二")

        XCTAssertEqual(store.steeringQueues["sA"]?.count, 2, "插话进当前会话队列")
        XCTAssertEqual(store.currentSteeringQueue.count, 2, "currentSteeringQueue 为本会话口径")
        XCTAssertNil(store.steeringQueues["sB"], "他会话队列为空")
        XCTAssertTrue(store.followUpQueues.isEmpty)
    }

    // MARK: - ⑥ 空态剪枝 + setStreamPhase

    @MainActor
    func testMutateStreamPrunesEmptyStateAndSetStreamPhaseTargetsCurrentSession() throws {
        try? PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        store.mutateStream("s1") { $0.text = "增量" }
        XCTAssertNotNil(store.streams["s1"])
        store.mutateStream("s1") { $0.text = "" }
        XCTAssertNil(store.streams["s1"], "全空状态剪枝（空态不留键）")

        store.setStreamPhase("正在生成原型…")
        XCTAssertEqual(store.streams["s1"]?.phaseTrail.map(\.label), ["正在生成原型…"], "缺省写当前会话")
        // nil = 链尾收尾：全部标 done，key 存活（此刻完成卡即将接管，无僵尸态）；
        // trail 显式清空后才回到空态剪枝
        store.setStreamPhase(nil)
        XCTAssertEqual(store.streams["s1"]?.phaseTrail.map(\.done), [true], "nil 收尾标 done")
        store.mutateStream("s1") { $0.phaseTrail = [] }
        XCTAssertNil(store.streams["s1"], "trail 清空后空态剪枝")

        store.setStreamPhase("正在沉淀记忆…", for: "s2")
        XCTAssertEqual(store.streams["s2"]?.phaseTrail.map(\.label), ["正在沉淀记忆…"], "显式会话键写入")
    }

    // MARK: - ⑦ 流式盒成员语义（2026-09-18 吞吐修复）

    @MainActor
    func testStreamBoxMembershipAndBoxIdentity() throws {
        try? PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        // 建键：成员进表（盒创建）
        store.mutateStream("s1") { $0.isStreaming = true }
        let box = store.streamBoxes["s1"]
        XCTAssertNotNil(box, "增量写入应创建流盒")
        XCTAssertEqual(store.streams["s1"]?.isStreaming, true, "快照读点反映盒内状态")

        // 流中增量：只触碰盒（盒实例不变 = 成员无增删，整页不再连坐重渲染）
        store.mutateStream("s1") { $0.think = "思考增量" }
        XCTAssertTrue(box === store.streamBoxes["s1"], "流中增量不得重建盒（成员稳定）")
        XCTAssertEqual(store.streams["s1"]?.think, "思考增量")

        // 清空：成员出表（盒移除）+ 快照同步
        store.mutateStream("s1") { $0.isStreaming = false; $0.think = "" }
        XCTAssertNil(store.streamBoxes["s1"], "全空状态移除流盒（空态不留键）")
        XCTAssertNil(store.streams["s1"])
    }

    // MARK: - ⑧ 流式发布尾窗

    @MainActor
    func testStreamPublishTailClip() {
        // 未超限：原样返回
        XCTAssertEqual(StreamPublishTail.clip("短文本", limit: 10), "短文本")
        // 超限：只留尾部 limit 字符
        let long = String(repeating: "甲", count: 30) + String(repeating: "乙", count: 5)
        let clipped = StreamPublishTail.clip(long, limit: 10)
        XCTAssertEqual(clipped.count, 10)
        XCTAssertEqual(clipped, String(repeating: "甲", count: 5) + String(repeating: "乙", count: 5),
                       "尾窗必须保留字符串末尾（源串以乙结尾，suffix 应含全部乙）")
        // 恰好等于 limit：原样
        let exact = String(repeating: "字", count: 10)
        XCTAssertEqual(StreamPublishTail.clip(exact, limit: 10), exact)
    }

    // MARK: - ⑨ 流式展示载荷（进度卡回归修复：识别事实与展示文本解耦）

    @MainActor
    func testStreamDisplayPayloadRecoversProgressCardFromFullText() {
        // 无块纯文本：display 全文，无进行中块
        let plain = StreamDisplayPayload.make(full: "普通正文")
        XCTAssertEqual(plain.display, "普通正文")
        XCTAssertEqual(plain.inProgressName, "")
        XCTAssertTrue(plain.blocks.isEmpty)

        // 三反引号块进行中：display 空（裁到开栏前）、识别出进行中 prd、行数全量口径
        let body3 = "行一\n行二\n行三"
        let p3 = StreamDisplayPayload.make(full: "前言\n```artifact:prd\n" + body3)
        XCTAssertEqual(p3.display, "前言")
        XCTAssertEqual(p3.inProgressName, "prd")
        XCTAssertEqual(p3.inProgressLines, 3)

        // 关键回归锚（2026-09-18 实测打穿场景）：四反引号 prd 块 + 内嵌 ``` 围栏
        // ——内嵌围栏是正文不是闭栏，进行中判定不得误翻转（旧「拼回三反引号
        // 开栏」方案正是死于此）；prd 闭栏后接未闭合 radar 块 → 完整块列表 + radar 进行中
        let prdBody = "PRD 内文\n```ascii\n+----+\n| 布局 |\n+----+\n```\n更多内文"
        let prdFenced = "前言\n````artifact:prd\n" + prdBody + "\n````\n收尾正文\n```artifact:radar\n雷达草稿"
        let p4 = StreamDisplayPayload.make(full: prdFenced)
        XCTAssertEqual(p4.blocks.map(\.name), ["prd"], "四反引号块闭合后应进完整块列表")
        XCTAssertEqual(p4.inProgressName, "radar", "闭栏后的未闭合 radar 块是进行中块")
        XCTAssertEqual(p4.display, "前言\n\n收尾正文", "块源码剥离（残留块位空行）、块间正文保留")

        // display 兜底裁尾：无块超长正文仍保尾（防无协议裸输出撑爆布局）
        let huge = String(repeating: "文", count: 30_000)
        let p5 = StreamDisplayPayload.make(full: huge)
        XCTAssertEqual(p5.display.count, StreamPublishTail.textChars)
        XCTAssertEqual(p5.display, String(huge.suffix(StreamPublishTail.textChars)))
    }

    @MainActor
    func testStreamStateArtifactProgressParticipatesInEmptyPruning() throws {
        try? PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        // 产物事实非空 → 键存活（不触发空态剪枝）
        store.mutateStream("s1") {
            $0.artifactBlocks = [ArtifactParser.ArtifactBlock(name: "prd", content: "")]
            $0.inProgressName = "prd"
            $0.inProgressLines = 5
        }
        XCTAssertNotNil(store.streamBoxes["s1"], "产物事实非空不得被空态剪枝")
        XCTAssertEqual(store.streams["s1"]?.inProgressLines, 5)

        // 全部清空 → 键移除（新字段参与 Equatable 空态判定）
        store.mutateStream("s1") {
            $0.artifactBlocks = []
            $0.inProgressName = ""
            $0.inProgressLines = 0
        }
        XCTAssertNil(store.streamBoxes["s1"])
    }
}
