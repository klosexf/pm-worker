//
//  DraftFeatureTests.swift
//  pm_workerTests
//
//  草稿预演（B1/B2）回归锚点：
//  ① 会话标记：session-flags.json 读写 roundtrip；取消草稿连带清推进位置
//  ② 提案模型兼容：旧行（无草稿扩展字段）可解码；stageDraft 判定
//  ③ 产物镜像：proposalSessionId 命中时结构/PRD 草稿落提案目录，主线目录零写入
//  ④ 合并入主线：镜像文件对拷 + 主线状态机推进 + 提案毕业 adopted + 退出草稿
//  ⑤ 草稿原型槽位扫描：prototypeSlotFiles(root:) 读提案目录
//

import XCTest
@testable import pm_worker

final class DraftFeatureTests: XCTestCase {
    var tempRoot: URL!
    private let project = "默认"
    private let version = "unversioned"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-draft-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.ensureWorkspace(project: project, version: version)
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private var mainlineRoot: URL {
        PMAgentStore.versionURL(project: project, version: version)
    }

    private func draftRoot(sid: String) -> URL {
        PMAgentStore.artifactRoot(
            project: project, version: version, proposalSessionId: sid
        )
    }

    // MARK: ① 会话标记

    @MainActor
    func testSessionFlagsRoundTripAndDraftExitClearsStage() {
        XCTAssertFalse(
            SessionStore.isDraftSession(project: project, version: version, sessionId: "s1"),
            "未标记会话非草稿"
        )
        XCTAssertNil(SessionStore.draftStage(project: project, version: version, sessionId: "s1"))

        XCTAssertNil(SessionStore.setDraft(
            project: project, version: version, sessionId: "s1", isDraft: true
        ))
        XCTAssertTrue(SessionStore.isDraftSession(project: project, version: version, sessionId: "s1"))
        XCTAssertEqual(
            SessionStore.draftStage(project: project, version: version, sessionId: "s1"),
            .clarify,
            "进入草稿默认从澄清起跑"
        )

        SessionStore.advanceDraftStage(
            project: project, version: version, sessionId: "s1", to: .prototype
        )
        XCTAssertEqual(
            SessionStore.draftStage(project: project, version: version, sessionId: "s1"),
            .prototype
        )

        // 退出草稿：draft 与推进位置一并清（空标记不留键）
        XCTAssertNil(SessionStore.setDraft(
            project: project, version: version, sessionId: "s1", isDraft: false
        ))
        XCTAssertFalse(SessionStore.isDraftSession(project: project, version: version, sessionId: "s1"))
        XCTAssertNil(SessionStore.draftStage(project: project, version: version, sessionId: "s1"))
        XCTAssertTrue(
            SessionStore.sessionFlags(project: project, version: version).isEmpty,
            "空标记不留键"
        )
    }

    // MARK: ② 提案模型兼容

    func testLegacyProposalRecordDecodesWithoutDraftFields() throws {
        let legacy = """
        {"id":"chg_legacy","idea":"新增导出功能","checkpointStage":"structure","createdAt":"2026-09-17T00:00:00Z"}
        """
        let entry = try JSONDecoder().decode(ChangeLogEntry.self, from: Data(legacy.utf8))
        guard case .proposal(let record) = entry else {
            return XCTFail("应解码为提案行")
        }
        XCTAssertFalse(record.isStageDraft, "旧行无 kind → 普通提案")
        XCTAssertNil(record.draftSessionId)

        let draft = ChangeProposalRecord(
            id: "draft-s1", idea: "草稿预演：② 结构产物已就绪",
            checkpointStage: "structure", kind: "stage_draft",
            draftSessionId: "s1", draftStage: "structure"
        )
        XCTAssertTrue(draft.isStageDraft)
    }

    // MARK: ③ 产物镜像（写提案目录，主线零写入）

    @MainActor
    func testStructureArtifactsMirrorToProposalDirectory() throws {
        let blocks: [ArtifactParser.ArtifactBlock] = [
            .init(name: "architecture", content: "graph TD; A-->B"),
            .init(name: "core-flows", content: "flowchart LR; C-->D"),
            .init(name: "module-page-map", content: "| 模块 | 页面 |\n|---|---|\n| 支付 | 收银台 |"),
        ]
        let structure = try ArtifactParser.writeStructureArtifacts(
            blocks: blocks, project: project, version: version, proposalSessionId: "s1"
        )
        XCTAssertEqual(structure.changes.count, 3)
        // 草稿落提案目录
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: draftRoot(sid: "s1").appendingPathComponent(ArtifactPath.architecture).path
            )
        )
        // 主线零写入
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: mainlineRoot.appendingPathComponent(ArtifactPath.architecture).path
            ),
            "草稿产物不得触碰主线目录"
        )
    }

    @MainActor
    func testPRDArtifactMirrorsToProposalDirectory() throws {
        let body = String(repeating: "# PRD\n\n正文内容。\n\n", count: 40)
        let blocks: [ArtifactParser.ArtifactBlock] = [.init(name: "prd", content: body)]
        let result = try ArtifactParser.writePRDArtifact(
            blocks: blocks, tier: "standard", project: project, version: version,
            proposalSessionId: "s2"
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: draftRoot(sid: "s2").appendingPathComponent(ArtifactPath.prd).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: mainlineRoot.appendingPathComponent(ArtifactPath.prd).path
            ),
            "草稿 PRD 不得触碰主线目录"
        )
    }

    // MARK: ⑤ 草稿原型槽位扫描

    @MainActor
    func testPrototypeSlotFilesReadsProposalRoot() throws {
        try PMAgentStore.writeVerified(
            "<html>草稿原型</html>",
            to: draftRoot(sid: "s3").appendingPathComponent("03-prototypes/可点击原型.html")
        )
        let slots = ArtifactPath.prototypeSlotFiles(
            project: project, version: version, root: draftRoot(sid: "s3")
        )
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.blockName, "prototype")
        // 主线槽位为空
        XCTAssertTrue(
            ArtifactPath.prototypeSlotFiles(project: project, version: version).isEmpty
        )
    }
}

final class DraftMergeTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-draftmerge-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.ensureWorkspace(project: "默认", version: "unversioned")
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    /// ④ 合并入主线：草稿文件对拷 + 主线引擎从 clarify 推进到 structure +
    /// 提案毕业 adopted + 会话退出草稿。合并要求当前选中即目标版本——
    /// AppModel() 初始 pipeline 即（默认, unversioned），天然满足。
    @MainActor
    func testMergeDraftCopiesFilesAdvancesEngineAndGraduatesProposal() throws {
        let model = AppModel()
        let sid = "s1"

        // 造草稿：要点表 + 结构三产物镜像落提案目录
        let draftRoot = PMAgentStore.artifactRoot(
            project: "默认", version: "unversioned", proposalSessionId: sid
        )
        try PMAgentStore.writeVerified(
            "# 草稿要点表", to: draftRoot.appendingPathComponent(ArtifactPath.clarification)
        )
        try PMAgentStore.writeVerified(
            "# 草稿架构", to: draftRoot.appendingPathComponent(ArtifactPath.architecture)
        )
        XCTAssertNil(SessionStore.setDraft(
            project: "默认", version: "unversioned", sessionId: sid, isDraft: true
        ))

        // 登记 stageDraft 提案（pending）
        let proposal = ChangeProposalRecord(
            id: "draft-\(sid)", idea: "草稿预演：② 结构产物已就绪",
            checkpointStage: "structure", kind: "stage_draft",
            draftSessionId: sid, draftStage: "structure"
        )
        ChangeLedger.append(.proposal(proposal), project: "默认", version: "unversioned")

        // 合并
        let item = ChangeLedger.load(project: "默认", version: "unversioned").first
        XCTAssertNotNil(item)
        XCTAssertNil(model.mergeDraftProposal(item!, project: "默认", version: "unversioned"))

        // 主线文件落地（内容 = 草稿）
        let merged = try? String(
            contentsOf: PMAgentStore.versionURL(project: "默认", version: "unversioned")
                .appendingPathComponent(ArtifactPath.architecture), encoding: .utf8
        )
        XCTAssertEqual(merged, "# 草稿架构", "草稿文件对拷入主线")

        // 主线引擎推进：clarify → structure（合并后有表 → deriveStage 前移）
        XCTAssertEqual(model.pipeline.stage, .structure, "合并推进主线状态机")

        // 提案毕业 + 退出草稿
        let items = ChangeLedger.load(project: "默认", version: "unversioned")
        XCTAssertEqual(items.first?.resolution, .adopted)
        XCTAssertFalse(
            SessionStore.isDraftSession(project: "默认", version: "unversioned", sessionId: sid),
            "合并后退出草稿预演"
        )

        // 决策留痕（decisions.jsonl 在版本根）
        XCTAssertTrue(
            (try? String(
                contentsOf: PMAgentStore.versionURL(project: "默认", version: "unversioned")
                    .appendingPathComponent("decisions.jsonl"),
                encoding: .utf8
            ))?.contains("合并草稿预演") ?? false,
            "合并动作落决策日志"
        )
    }

    /// 放弃草稿：提案毕业 dropped + 退出草稿（主线无写入）。
    @MainActor
    func testAbandonDraftGraduatesAsDroppedAndExitsDraft() throws {
        let model = AppModel()
        let sid = "s2"
        XCTAssertNil(SessionStore.setDraft(
            project: "默认", version: "unversioned", sessionId: sid, isDraft: true
        ))
        let proposal = ChangeProposalRecord(
            id: "draft-\(sid)", idea: "草稿预演：② 结构产物已就绪",
            checkpointStage: "structure", kind: "stage_draft",
            draftSessionId: sid, draftStage: "structure"
        )
        ChangeLedger.append(.proposal(proposal), project: "默认", version: "unversioned")

        let item = ChangeLedger.load(project: "默认", version: "unversioned").first!
        model.abandonDraftProposal(item, project: "默认", version: "unversioned")

        let items = ChangeLedger.load(project: "默认", version: "unversioned")
        XCTAssertEqual(items.first?.resolution, .dropped)
        XCTAssertFalse(
            SessionStore.isDraftSession(project: "默认", version: "unversioned", sessionId: sid)
        )
    }
}
