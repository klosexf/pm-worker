//
//  PrototypeCarryInTests.swift
//  pm_workerTests
//
//  ② 阶段越界产出 ③ 原型的顺收与兜底回归锚点（2026-09-21 静默丢弃事故）：
//  用户在 ② 闸口待确认期间连说「继续」，模型把它读成推进指令、直接在结构阶段的
//  回复里写出完整原型 HTML。落盘分派按 origin.stage 走，② 分支只认结构三件，
//  原型块既不被消费也不留痕——AI 正文宣称「原型你上手玩一圈」，用户什么文件都拿不到。
//
//  ① 顺收：② 阶段 + 盘上结构三件齐全 + 回复含完整可落盘原型块 → 收束 ② 闸口、
//    按 ③ 协议落盘、引擎阶段推进到 ③、事件留痕阶段记 prototype、说明系统行可见。
//  ② 兜底：顺收前置不满足（无结构三件 / 发起阶段是 ①）→ 不落盘也不凭空确认闸口，
//    但必须落 ⚠️ 留痕并指向快速通道恢复路径（不许静默）。
//  ③ 谓词：hasWritablePrototypeBlock（顺收判据）与 hasStrayPrototypeBlock（兜底判据）
//    的四象限——闭合 HTML 块 / 未闭合截断 / 非 HTML 空块 / 无关块。
//
//  手法沿用 PrototypeConflictTests：PMAgentStore.rootOverride 指向临时目录做磁盘隔离，
//  死端点设置让机器门 Tier2 走「评审模型不可用，降级放行」，零真实网络。
//

import XCTest
@testable import pm_worker

final class PrototypeCarryInTests: XCTestCase {

    private let project = "原型顺收项目"
    private let version = "v1"
    /// 磁盘隔离：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/。
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-worker-proto-carryin-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
        try? PMAgentStore.ensureWorkspace(project: project, version: version)
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func versionURL(_ rel: String) -> URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(rel)
    }

    private func exists(_ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: versionURL(rel).path)
    }

    private func write(_ content: String, to rel: String) throws {
        try PMAgentStore.writeVerified(content, to: versionURL(rel))
    }

    private func discussionsURL() -> URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
    }

    private func systemRows() -> [DiscussionEntry] {
        PMAgentStore.readLines(DiscussionEntry.self, from: discussionsURL())
            .filter { $0.role == .system }
    }

    private func makeReply(_ sessionID: String, content: String) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionID,
            role: .assistant,
            content: content,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// 盘上结构三件齐全（顺收的前置：无闸可收则不顺收）。
    private func layStructureArtifacts() throws {
        try write("# 澄清要点表\n- 场景：收藏吃灰", to: ArtifactPath.clarification)
        try write("graph TD\n  A-->B", to: ArtifactPath.architecture)
        try write("flowchart\n  A-->B", to: ArtifactPath.coreFlows)
        try write("| 模块 | 原型页面 | 页面说明 |\n|---|---|---|\n| M1 | P1 | 存入 |",
                  to: ArtifactPath.modulePageMap)
    }

    /// 大于 2KB 的正文（Tier1 原型空壳检查阈值），零外部资源引用。
    private static func bigHTML(_ marker: String) -> String {
        "<html>\n<head><title>\(marker)</title></head>\n<body>\n"
            + String(repeating: "<p>\(marker)页面内容段落，用于撑过空壳阈值。</p>\n", count: 120)
            + "</body>\n</html>"
    }

    /// 事故现场的真实回复形态：plan + prototype + radar，一个结构块都没有。
    private static func carryInReply(_ html: String) -> String {
        """
        结构三件你已连续推进确认，这轮进入交互原型。

        ```artifact:plan
        {"mission": "产出 v1 交互原型：单文件 HTML 高保真可交互",
         "steps": [{"do": "按映射表画 4 页 + 设置弹层"}]}
        ```

        ```artifact:prototype
        \(html)
        ```

        ```artifact:radar
        {"fixed": ["死按钮清零"], "remaining": []}
        ```
        """
    }

    /// 死端点设置（机器门 Tier2 走降级放行，零真实网络）。
    private func makeDeadEndpointSettings() -> LLMSettings {
        LLMSettings(
            stages: [.prototype: StageModelConfig(
                provider: "openai", model: "stub", baseURL: "http://127.0.0.1:9/v1"
            )],
            maxTokensPerRun: 1000
        )
    }

    private func makeModel() -> AppModel {
        let model = AppModel()
        model.settings = makeDeadEndpointSettings()
        model.selection = .session(project: project, version: version, sessionId: "cur")
        return model
    }

    // MARK: - ① 顺收

    @MainActor
    func testPrototypeBlockAtStructureStageIsCarriedInAndConfirmsStructure() async throws {
        try layStructureArtifacts()
        let model = makeModel()
        XCTAssertEqual(
            model.pipeline.stage, .structure,
            "前置：② 闸口未确认，引擎必须停在结构阶段"
        )

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .structure
        )
        let html = Self.bigHTML("越界产出")
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.carryInReply(html)), origin: origin
        )

        // 原型必须落盘，内容就是本轮回复里的 HTML
        XCTAssertTrue(
            exists(ArtifactPath.prototype),
            "② 阶段回复携带完整原型块必须顺收落盘 03-prototypes/可点击原型.html"
        )
        XCTAssertEqual(
            try String(contentsOf: versionURL(ArtifactPath.prototype), encoding: .utf8), html
        )
        // 闸口事实源同步收束，引擎阶段随之推进
        XCTAssertTrue(
            exists("02-structure/confirmed.json"),
            "顺收必须收束 ② 闸口（confirmed.json 是阶段推导的事实源）"
        )
        XCTAssertEqual(
            model.pipeline.stage, .prototype,
            "顺收后引擎必须推进到 ③，否则确认坞仍停在 ②（第二种「说了没做」）"
        )

        // 用户可见：📦 落盘行 + 顺收说明行（② 被随之确认，不能悄悄发生）
        let rows = systemRows()
        XCTAssertTrue(
            rows.contains { $0.sessionId == "sOrigin" && $0.content.hasPrefix("📦 交互原型已生成") },
            "顺收必须落 📦 落盘系统行（含 fileChanges 才能出原型结果卡）"
        )
        XCTAssertTrue(
            rows.contains { $0.content.contains("⚡") && $0.content.contains("② 结构") },
            "闸口被代替用户收束，必须落一条用户可见的说明行"
        )

        // 事件留痕的阶段字段记 prototype，不是发起时的 structure
        let events = PipelineEventLog.events(project: project, version: version)
        XCTAssertTrue(
            events.contains {
                $0.kind == .artifactGenerated && $0.stage == "prototype"
                    && $0.detail.contains("原型")
            },
            "原型落盘事件的 stage 必须是 prototype，实际 \(events.map(\.stage))"
        )
        XCTAssertTrue(
            events.contains { $0.kind == .stageConfirm && $0.stage == "prototype" },
            "② 闸口收束必须落 stageConfirm 留痕"
        )

        // 异步机器门收尾（死端点降级放行）落定后再拆除临时目录
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - ② 兜底：顺收前置不满足

    @MainActor
    func testCarryInDoesNotOverwriteExistingPrototype() async throws {
        // ③ 槽位已有产物：顺收轮没有冲突快照（快照只在 ③ 阶段发送链采集），
        // 直接覆盖等于无提示地吃掉用户手上已有的原型——不顺收，改留痕。
        try layStructureArtifacts()
        let existing = Self.bigHTML("既有原型")
        try write(existing, to: ArtifactPath.prototype)
        let model = makeModel()

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .structure
        )
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.carryInReply(Self.bigHTML("越界产出"))),
            origin: origin
        )

        XCTAssertEqual(
            try String(contentsOf: versionURL(ArtifactPath.prototype), encoding: .utf8), existing,
            "无冲突快照时顺收不得覆盖盘上既有原型"
        )
        XCTAssertFalse(exists("02-structure/confirmed.json"), "不顺收就不该收束 ② 闸口")
        XCTAssertTrue(
            systemRows().contains {
                $0.content.contains("⚠️") && $0.content.contains("原型") && $0.content.contains("快速通道")
            },
            "放弃顺收必须落可见留痕"
        )
    }

    @MainActor
    func testPrototypeBlockWithoutStructureArtifactsOnDiskWarnsWithoutWriting() async throws {
        // 只有澄清要点表：② 三件缺失 → 无闸可收，不得顺收
        try write("# 澄清要点表\n- 场景：收藏吃灰", to: ArtifactPath.clarification)
        let model = makeModel()
        XCTAssertEqual(model.pipeline.stage, .structure)

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .structure
        )
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.carryInReply(Self.bigHTML("越界产出"))),
            origin: origin
        )

        XCTAssertFalse(exists(ArtifactPath.prototype), "无结构三件可收束时不得落原型")
        XCTAssertFalse(exists("02-structure/confirmed.json"), "不得凭空确认 ② 闸口")
        XCTAssertTrue(
            systemRows().contains {
                $0.content.contains("⚠️") && $0.content.contains("原型")
                    && $0.content.contains("快速通道")
            },
            "顺收不成必须落 ⚠️ 留痕并指向恢复路径——静默即本次事故本身"
        )

        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor
    func testPrototypeBlockAtClarifyStageIsNotCarriedIn() async throws {
        // ① 阶段本就没有 ② 闸口可收：不顺收，只留痕
        let model = makeModel()
        XCTAssertEqual(model.pipeline.stage, .clarify)

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .clarify
        )
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.carryInReply(Self.bigHTML("越界产出"))),
            origin: origin
        )

        XCTAssertFalse(exists(ArtifactPath.prototype), "① 阶段的原型块不得顺收落盘")
        XCTAssertFalse(exists("02-structure/confirmed.json"), "① 阶段不得写 ② 确认记录")
        XCTAssertTrue(
            systemRows().contains {
                $0.content.contains("⚠️") && $0.content.contains("原型")
            },
            "① 阶段的 stray 原型块同样不许静默"
        )
    }

    // MARK: - ③ 谓词四象限

    func testPrototypeBlockPredicates() {
        // 闭合 + HTML：顺收判据与兜底判据同时成立
        let closed = "说明。\n\n```artifact:prototype\n<html><body>x</body></html>\n```\n"
        let closedBlocks = ArtifactParser.parseArtifactBlocks(in: closed)
        XCTAssertTrue(ArtifactParser.hasWritablePrototypeBlock(closedBlocks))
        XCTAssertTrue(ArtifactParser.hasStrayPrototypeBlock(blocks: closedBlocks, text: closed))

        // 分端槽位块同属原型类
        let mobile = "```artifact:prototype-mobile\n<html><body>m</body></html>\n```"
        let mobileBlocks = ArtifactParser.parseArtifactBlocks(in: mobile)
        XCTAssertTrue(
            ArtifactParser.hasWritablePrototypeBlock(mobileBlocks),
            "prototype-<slug> 分端槽位也必须被顺收"
        )

        // 未闭合截断（blocks 为空）：只能留痕，不能顺收
        let truncated = "这就出原型：\n```artifact:prototype\n<!DOCTYPE html>\n<html>"
        XCTAssertFalse(ArtifactParser.hasWritablePrototypeBlock([]))
        XCTAssertTrue(
            ArtifactParser.hasStrayPrototypeBlock(blocks: [], text: truncated),
            "截断的原型围栏必须留痕——否则又是「说了没做」"
        )

        // 闭合但正文不含 HTML：留痕，不顺收
        let notHTML = "```artifact:prototype\n还没画，先占个块名\n```"
        let notHTMLBlocks = ArtifactParser.parseArtifactBlocks(in: notHTML)
        XCTAssertFalse(
            ArtifactParser.hasWritablePrototypeBlock(notHTMLBlocks),
            "无 HTML 标记的原型块不可落盘（与 writePrototypeArtifact 收块口径一致）"
        )
        XCTAssertTrue(ArtifactParser.hasStrayPrototypeBlock(blocks: notHTMLBlocks, text: notHTML))

        // 无关块（radar / prd / 结构三件）：两者皆 false，不得误报
        for text in [
            "```artifact:radar\n{\"fixed\": [], \"remaining\": []}\n```",
            "```artifact:prd\n# PRD 全文\n正文……\n```",
            "```artifact:architecture\ngraph TD\n  A-->B\n```",
            "普通讨论回复，没有任何产物块",
        ] {
            XCTAssertFalse(
                ArtifactParser.hasWritablePrototypeBlock(ArtifactParser.parseArtifactBlocks(in: text)),
                "无关块不得触发顺收：\(text.prefix(24))"
            )
            XCTAssertFalse(
                ArtifactParser.hasStrayPrototypeBlock(
                    blocks: ArtifactParser.parseArtifactBlocks(in: text), text: text
                ),
                "无关块不得触发兜底留痕：\(text.prefix(24))"
            )
        }
    }
}
