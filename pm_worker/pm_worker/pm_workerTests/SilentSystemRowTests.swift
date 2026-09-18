//
//  SilentSystemRowTests.swift
//  pm_workerTests
//
//  系统行「静默化 + 开场承接」（2026-09-17 钦定：⚡ 快速通道受理 / ⏳ 跨门风险提醒 /
//  ✅ 阶段推进确认三类系统行融合进 AI 回答开头，UI 不再渲染）：
//  ① DiscussionEntry.silent 编解码与旧格式兼容（decodeIfPresent）
//  ② 合并行走（mergeableNotes / mergedSystemIndices / streamingAbsorbedIndices）排除静默行
//  ③ 链判定行走（isFastForwardChainedBefore / dutyHandover）不跳过静默行——⚡ 静默行仍是链标记
//  ④ gateRiskNudge：落静默审计行 + 返回开场承接事实文本
//  ⑤ openingHandoverSection / openingTail：事实注入与链首单注规则
//  ⑥ 四阶段 prompt 含开场承接排版规则
//
//  核心不变量（实现禁忌的防回归锚点）：
//  - 合并行走必须跳过 silent 行（否则静默 ✅ 注记以 TurnNote 形态漏进气泡）
//  - 链判定行走不得跳过 silent 行（否则静默 ⚡ 行断链，值班单丢失多跳叙事）
//

import XCTest
@testable import pm_worker

final class SilentSystemRowTests: XCTestCase {

    // MARK: - ① 编解码与旧格式兼容

    func testLegacyEntryWithoutSilentDecodesNil() throws {
        // 旧存量行（无 silent 字段）必须照常解码 → 一切按旧判据渲染
        let json = #"{"id":"e1","sessionId":"s1","role":"system","content":"✅ 澄清要点表已确认——进入 ② 结构设计","createdAt":"2026-09-01T00:00:00Z"}"#
        let decoded = try JSONDecoder().decode(
            DiscussionEntry.self, from: Data(json.utf8)
        )
        XCTAssertNil(decoded.silent)
        XCTAssertFalse(decoded.isSilent, "旧行不得被静默")
    }

    func testSilentCodableRoundTrip() throws {
        let entry = DiscussionEntry(
            id: "s1", sessionId: "s1", role: .system,
            content: "⚡ 快速通道：已按你的要求跳过逐步确认，直接撰写 PRD。",
            silent: true, createdAt: "2026-09-17T00:00:00Z"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiscussionEntry.self, from: data)
        XCTAssertEqual(decoded.silent, true)
        XCTAssertTrue(decoded.isSilent)

        // silent 缺省 nil 的行 round-trip 不引入 false（区分「未标注」与「标注过」）
        let plain = DiscussionEntry(
            id: "s2", sessionId: "s1", role: .system, content: "📦 普通落盘行",
            createdAt: "2026-09-17T00:00:01Z"
        )
        let plainBack = try JSONDecoder().decode(
            DiscussionEntry.self, from: JSONEncoder().encode(plain)
        )
        XCTAssertNil(plainBack.silent)
    }

    // MARK: - ② 合并行走排除静默行

    private func entry(
        _ role: DiscussionEntry.Role, _ content: String, silent: Bool? = nil
    ) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString, sessionId: "s1", role: role, content: content,
            silent: silent, createdAt: "2026-09-17T00:00:00Z"
        )
    }

    func testMergeableNotesBeforeSkipsSilentPreamble() {
        // [assistant][✅ 推进(silent)][assistant]：静默 ✅ 不得以 TurnNote 漏进气泡头部
        let entries = [
            entry(.assistant, "上一轮回答"),
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计", silent: true),
            entry(.assistant, "结构产物说明"),
        ]
        XCTAssertTrue(
            MessageBubble.mergeableNotes(before: 2, in: entries).isEmpty,
            "静默推进行不得并入下一回合头部注记"
        )
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        XCTAssertFalse(merged.contains(1), "静默行不参与合并索引（displayItems 直接过滤）")
    }

    func testMergeableNotesAfterStopsAtSilentRow() {
        // [assistant][📦(可见)][⚡(silent)]：after 行走停在静默 ⚡——📦 照常并入尾部
        let entries = [
            entry(.assistant, "原型说明"),
            entry(.system, "📦 交互原型已生成——机器初审中……"),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，直接撰写 PRD。", silent: true),
        ]
        let notes = MessageBubble.mergeableNotes(after: 0, in: entries)
        XCTAssertEqual(notes.count, 1, "after 行走应在静默行处截断")
        XCTAssertTrue(notes[0].text.contains("📦") || notes[0].text.contains("原型"))
    }

    func testStreamingAbsorbedSkipsSilentRow() {
        // 流式头部吸收判据同口径：静默 ✅ 不被吸收为流式头部注记
        let entries = [
            entry(.assistant, "上一轮回答"),
            entry(.system, "✅ 原型已确认——进入 ④ PRD 撰写", silent: true),
        ]
        XCTAssertTrue(
            MessageBubble.streamingAbsorbedIndices(in: entries).isEmpty,
            "静默行不得进入流式头部吸收集"
        )
    }

    func testVisiblePreambleStillMerges() {
        // 对照组：非静默的 ✅ 推进行为不变（防「一刀切全静默」回归）
        let entries = [
            entry(.assistant, "上一轮回答"),
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计"),
            entry(.assistant, "结构产物说明"),
        ]
        XCTAssertEqual(MessageBubble.mergeableNotes(before: 2, in: entries).count, 1)
        XCTAssertTrue(MessageBubble.mergedSystemIndices(in: entries).contains(1))
    }

    // MARK: - ③ 链判定不跳过静默行（⚡ 静默行仍是链标记）

    func testSilentFastForwardRowStillChains() {
        // [user][assistant][⚡(silent)][assistant]：静默 ⚡ 行必须继续撑链——
        // 否则快速通道多跳续段会出独立回答头、值班单丢失
        let entries = [
            entry(.user, "直接出 PRD"),
            entry(.assistant, "明白，直接推进。"),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，直接撰写 PRD。", silent: true),
            entry(.assistant, "④ PRD 产物说明"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(3, in: entries),
            "静默 ⚡ 行不得断链"
        )
        let handover = MessageBubble.dutyHandover(for: 3, in: entries)
        XCTAssertEqual(handover?.segmentIndex, 2, "静默行入轴：链内第二段")
        XCTAssertEqual(handover?.nodes.count, 3, "段1完成 + ⚡ 受理行 + 段2完成")
    }

    func testSilentAdvanceNoteKeepsChainStageLabel() {
        // 值班单时间轴含静默 ✅ 推进/⏳ 提醒行（与今日 ✅ 注记入轴行为一致）
        let entries = [
            entry(.user, "直接出原型"),
            entry(.assistant, "明白了，不再追问。"),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，直接生成原型。", silent: true),
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计", silent: true),
            entry(.assistant, "② 结构产物说明"),
        ]
        let handover = MessageBubble.dutyHandover(for: 4, in: entries)
        XCTAssertEqual(handover?.segmentIndex, 2)
        XCTAssertEqual(handover?.stageLabel, "② 结构", "静默 ✅ 推进行仍提供阶段徽标")
    }

    // MARK: - ④ gateRiskNudge：静默审计行 + 承接事实文本

    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-silentrow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func makeWorkspace(named: String) throws {
        try PMAgentStore.createProject(named: named)
        try PMAgentStore.createVersion("v1.0", in: named)
    }

    private func discussionRows() -> [DiscussionEntry] {
        let url = PMAgentStore.jsonlURL(
            project: "融合项目", version: "v1.0", file: "discussions.jsonl"
        )
        return PMAgentStore.readLines(DiscussionEntry.self, from: url)
    }

    @MainActor
    func testGateRiskNudgeReturnsFactAndAppendsSilentRow() throws {
        try makeWorkspace(named: "融合项目")
        let model = AppModel()
        model.selection = .session(project: "融合项目", version: "v1.0", sessionId: "s1")

        var r1 = RiskRecord(
            version: "v1.0", stage: .prototype,
            hypothesis: "图片-only 命不住核心场景", impact: "文档预览返工",
            plan: "R2 加格式分布题", originRef: "自评审"
        )
        r1.status = .mitigating
        var r2 = RiskRecord(
            version: "v1.0", stage: .prototype,
            hypothesis: "列表层级过深", impact: "结构映射返工",
            plan: "拍平到两层", originRef: "自评审"
        )
        r2.status = .mitigating
        try model.risks.append(r1)
        try model.risks.append(r2)

        let fact = model.gateRiskNudge(fromStage: .prototype, nextStageName: "PRD")
        let text = try XCTUnwrap(fact, "有已挂方案风险必须返回承接事实")
        XCTAssertTrue(text.contains("2"), "承接事实应带风险数量")
        XCTAssertTrue(text.contains("风险"))
        XCTAssertTrue(text.contains("不阻塞本轮"))

        let rows = discussionRows().filter { $0.content.hasPrefix("⏳ 进入") }
        XCTAssertEqual(rows.count, 1, "跨门提醒恰好落一条审计行")
        XCTAssertEqual(rows[0].silent, true, "⏳ 行应为静默行（UI 不渲染）")
        XCTAssertEqual(rows[0].milestones?.first?.kind, "risk")
        XCTAssertEqual(rows[0].milestones?.first?.count, 2)
    }

    @MainActor
    func testGateRiskNudgeNoHangingReturnsNil() throws {
        try makeWorkspace(named: "融合项目")
        let model = AppModel()
        model.selection = .session(project: "融合项目", version: "v1.0", sessionId: "s1")

        var open = RiskRecord(
            version: "v1.0", stage: .prototype,
            hypothesis: "仅 open 态风险", impact: "影响", plan: nil, originRef: "自评审"
        )
        open.status = .open
        try model.risks.append(open)

        let fact = model.gateRiskNudge(fromStage: .prototype, nextStageName: "PRD")
        XCTAssertNil(fact, "无已挂方案风险不注入承接")
        XCTAssertTrue(
            discussionRows().filter { $0.content.hasPrefix("⏳ 进入") }.isEmpty,
            "无风险不落 ⏳ 行"
        )
    }

    // MARK: - ⑤ 开场承接注入段

    func testOpeningHandoverSectionContainsFactOnly() {
        let section = AppModel.openingHandoverSection(
            fact: "已确认原型，本轮开始撰写 PRD 文档", risk: nil
        )
        XCTAssertTrue(section.contains("【开场承接】"))
        XCTAssertTrue(section.contains("已确认原型，本轮开始撰写 PRD 文档"))
        XCTAssertFalse(section.contains("待核验事项"), "无风险时整条略去")
    }

    func testOpeningHandoverSectionWithRisk() {
        let section = AppModel.openingHandoverSection(
            fact: "已确认原型，本轮开始撰写 PRD 文档",
            risk: "「原型」阶段还有 2 个已挂方案的风险待验证"
        )
        XCTAssertTrue(section.contains("待核验事项"))
        XCTAssertTrue(section.contains("已挂方案的风险待验证"))
    }

    func testOpeningTailChainFirstOnlyRule() {
        // 常规确认：directive == nil → 用当跳默认事实
        let normal = AppModel.openingTail(
            directive: nil, injected: nil, defaultFact: "已确认结构产物", risk: nil
        )
        XCTAssertTrue(normal.contains("已确认结构产物"))

        // 快速通道链中段：directive != nil 且 injected == nil → 空串（防重复播报）
        let middle = AppModel.openingTail(
            directive: "用户要求快速出稿", injected: nil, defaultFact: "已确认结构产物", risk: nil
        )
        XCTAssertEqual(middle, "", "链中段不得注入开场承接")

        // 快速通道链首：injected 全链事实优先于默认事实
        let head = AppModel.openingTail(
            directive: "用户要求快速出稿", injected: "已按用户要求跳过确认，直接生成原型并撰写 PRD",
            defaultFact: "已确认结构产物", risk: nil
        )
        XCTAssertTrue(head.contains("直接生成原型并撰写 PRD"))
        XCTAssertFalse(head.contains("已确认结构产物"))
    }

    // MARK: - ⑥ 四阶段 prompt 含开场承接排版规则

    func testOpeningHandoverRuleInAllStagePrompts() {
        XCTAssertTrue(
            AgentPrompts.clarify(injection: "").contains("开场承接"),
            "① 提示词含开场承接规则"
        )
        XCTAssertTrue(
            AgentPrompts.structure(clarification: "要点", injection: "").contains("开场承接"),
            "② 提示词含开场承接规则"
        )
        XCTAssertTrue(
            AgentPrompts.prototype(
                modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD", injection: ""
            ).contains("开场承接"),
            "③ 提示词含开场承接规则"
        )
        XCTAssertTrue(
            AgentPrompts.prd(
                tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
                architecture: "", coreFlows: "", prototypePages: ["首页"],
                analysisNotes: "", injection: ""
            ).contains("开场承接"),
            "④ 提示词含开场承接规则"
        )
    }

    func testReplyFormatKeepsMetaBanAndSaveStatusRule() {
        // 元信息禁令保留；「产物保存状态」句改由开场承接承载（原「系统提示行承载」矛盾句退役）
        let section = AgentPrompts.replyFormatSection()
        XCTAssertTrue(section.contains("元信息禁令"))
        XCTAssertTrue(section.contains("产物保存状态只在【开场承接】句"))
        XCTAssertFalse(section.contains("由系统提示行承载"), "旧矛盾句必须移除")
    }
}
