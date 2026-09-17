//
//  ChangeLedgerTests.swift
//  pm_workerTests
//
//  变更分诊台账（changes.jsonl）离线单测：
//  - fold：文件序折叠、最新回写行胜出、无回写行 = pending
//  - 磁盘往返：appendLine → load 与内存折叠一致（PMAgentStore 临时根隔离）
//  - 提案重复登记：同 id 后写覆盖内容，折叠顺序保持首见位置
//  全离线：rootOverride 临时目录隔离，不碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class ChangeLedgerTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-chgledger-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func makeProject(_ name: String, version: String) throws {
        _ = try PMAgentStore.createProject(named: name)
        _ = try PMAgentStore.createVersion(version, in: name)
    }

    private func proposal(
        _ id: String, idea: String, target: String? = "structure",
        impacts: [String]? = ["02-structure/核心流程图.md · 支付"]
    ) -> ChangeProposalRecord {
        ChangeProposalRecord(
            id: id, idea: idea, category: "模块核心", target: target,
            mode: "revise", instruction: nil, impacts: impacts,
            checkpointStage: "prototype"
        )
    }

    // MARK: - fold

    func testFoldPendingWithoutResolution() {
        let items = ChangeLedger.fold([.proposal(proposal("chg_1", idea: "加夜览模式"))])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isPending, "无回写行 = pending")
        XCTAssertNil(items[0].resolution)
    }

    func testFoldLatestResolutionWins() {
        let items = ChangeLedger.fold([
            .proposal(proposal("chg_1", idea: "加夜览模式")),
            .resolution(ChangeResolutionRecord(id: "chg_1", resolution: .pooled)),
            .resolution(ChangeResolutionRecord(id: "chg_1", resolution: .adopted, note: "毕业纳入")),
        ])
        XCTAssertEqual(items[0].resolution, .adopted, "同一提案最新回写行胜出")
        XCTAssertEqual(items[0].resolutionNote, "毕业纳入")
        XCTAssertFalse(items[0].isPooled)
    }

    func testFoldKeepsFirstSeenOrderAcrossDuplicates() {
        let items = ChangeLedger.fold([
            .proposal(proposal("chg_1", idea: "想法 A")),
            .proposal(proposal("chg_2", idea: "想法 B")),
            .proposal(proposal("chg_1", idea: "想法 A（补充影响）")),
        ])
        XCTAssertEqual(items.map(\.id), ["chg_1", "chg_2"], "折叠顺序 = 首见序")
        XCTAssertEqual(items[0].proposal.idea, "想法 A（补充影响）", "同 id 后写覆盖内容")
    }

    func testFoldPooledFilter() {
        let items = ChangeLedger.fold([
            .proposal(proposal("chg_1", idea: "进池的想法")),
            .resolution(ChangeResolutionRecord(id: "chg_1", resolution: .pooled)),
            .proposal(proposal("chg_2", idea: "待处置的想法")),
        ])
        XCTAssertEqual(items.filter(\.isPooled).map(\.id), ["chg_1"], "池 = pooled 处置的提案")
        XCTAssertEqual(items.filter(\.isPending).map(\.id), ["chg_2"])
    }

    // MARK: - 磁盘往返

    func testDiskRoundTripMatchesInMemoryFold() throws {
        try makeProject("台账项目", version: "v1.0")
        let project = "台账项目", version = "v1.0"

        ChangeLedger.append(.proposal(proposal("chg_1", idea: "支持多语言")), project: project, version: version)
        ChangeLedger.append(
            .resolution(ChangeResolutionRecord(id: "chg_1", resolution: .pooled, note: "先池内观察")),
            project: project, version: version
        )
        ChangeLedger.append(
            .proposal(proposal("chg_2", idea: "导出 PDF", target: nil, impacts: nil)),
            project: project, version: version
        )

        let items = ChangeLedger.load(project: project, version: version)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "chg_1")
        XCTAssertEqual(items[0].resolution, .pooled)
        XCTAssertEqual(items[0].resolutionNote, "先池内观察")
        XCTAssertTrue(items[1].isPending)

        // 建版本时 changes.jsonl 应已初始化（createVersion 清单）
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ChangeLedger.url(project: project, version: version).path
            ),
            "createVersion 应初始化 changes.jsonl"
        )
    }

    // MARK: - 协议编码

    func testEntryCodableTypeDiscriminator() throws {
        let encoder = JSONEncoder()
        let resolutionData = try encoder.encode(
            ChangeLogEntry.resolution(ChangeResolutionRecord(id: "chg_9", resolution: .dropped))
        )
        let text = String(decoding: resolutionData, as: UTF8.self)
        XCTAssertTrue(text.contains("\"type\":\"resolution\""), "回写行应携带 type 判别字段")

        let decoded = try JSONDecoder().decode(ChangeLogEntry.self, from: resolutionData)
        guard case .resolution(let record) = decoded else {
            return XCTFail("应解码为 resolution 行")
        }
        XCTAssertEqual(record.resolution, .dropped)

        // 无 type 的行按提案解码（兼容手写 / 外部工具追加）
        let bareProposal = Data("{\"id\":\"chg_8\",\"idea\":\"想法\",\"checkpointStage\":\"prd\",\"createdAt\":\"2026-09-16T00:00:00Z\"}".utf8)
        guard case .proposal(let p) = try JSONDecoder().decode(ChangeLogEntry.self, from: bareProposal) else {
            return XCTFail("无 type 行应解码为 proposal")
        }
        XCTAssertEqual(p.id, "chg_8")
    }
}
