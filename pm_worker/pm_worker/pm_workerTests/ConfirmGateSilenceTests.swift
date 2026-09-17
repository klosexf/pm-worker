//
//  ConfirmGateSilenceTests.swift
//  pm_workerTests
//
//  确认坞「稍后再说」版本级持久静默（2026-09-15 钦定口径：每版本每阶段只弹一次）：
//  - confirm-silence.json 读写 roundtrip + 缺失/损坏容错（空集，不抛）
//  - deferConfirmGate：静默生效 + 写透磁盘 + 💬 安静留痕恰好一条；
//    已静默时重复调用是 no-op（防「每次弹坞→稍后再说→提示行叠加」回归）
//  - 重启模拟（全新 AppModel 重进会话）：静默仍生效，不再弹坞；版本间互相隔离
//  全离线：rootOverride 临时目录隔离，不碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class ConfirmGateSilenceTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-silence-\(UUID().uuidString)", isDirectory: true)
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

    private func makeWorkspace() throws {
        try PMAgentStore.createProject(named: "静默项目")
        try PMAgentStore.createVersion("v1.0", in: "静默项目")
    }

    private var silenceURL: URL {
        PMAgentStore.confirmSilenceURL(project: "静默项目", version: "v1.0")
    }

    /// discussions.jsonl 里的 💬 已收起确认 行数（留痕防叠加锚点）。
    private func quietNoticeRowCount() -> Int {
        let url = PMAgentStore.jsonlURL(
            project: "静默项目", version: "v1.0", file: "discussions.jsonl"
        )
        return PMAgentStore.readLines(DiscussionEntry.self, from: url)
            .filter { $0.content.hasPrefix("💬 已收起确认") }
            .count
    }

    // MARK: - 存储层：roundtrip + 容错

    func testConfirmSilenceRoundTripAndTolerance() throws {
        try makeWorkspace()

        // 缺失 = 空集
        XCTAssertTrue(
            PMAgentStore.readConfirmSilence(project: "静默项目", version: "v1.0").isEmpty,
            "无静默文件应读出空集"
        )

        // 写入 → 读出
        try PMAgentStore.writeConfirmSilence(
            ["structure", "prototype"], project: "静默项目", version: "v1.0"
        )
        XCTAssertEqual(
            PMAgentStore.readConfirmSilence(project: "静默项目", version: "v1.0"),
            ["structure", "prototype"]
        )

        // 损坏 = 空集（不抛：静默丢失只是坞多弹一次，不致命）
        try "{} 不是合法结构".write(to: silenceURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            PMAgentStore.readConfirmSilence(project: "静默项目", version: "v1.0").isEmpty,
            "损坏文件应容错为空集"
        )
    }

    // MARK: - AppModel：静默生效 + 留痕不叠加

    @MainActor
    func testDeferPersistsAndQuietNoticeEmittedOnce() throws {
        try makeWorkspace()
        let model = AppModel()
        model.selection = .session(project: "静默项目", version: "v1.0", sessionId: "s1")

        XCTAssertFalse(model.isConfirmGateDeferred(.prototype))

        // 首次「稍后再说」：静默生效 + 写透磁盘 + 💬 留痕一条
        model.deferConfirmGate(.prototype)
        XCTAssertTrue(model.isConfirmGateDeferred(.prototype))
        XCTAssertEqual(
            PMAgentStore.readConfirmSilence(project: "静默项目", version: "v1.0"),
            ["prototype"],
            "静默应写透 confirm-silence.json"
        )
        XCTAssertEqual(quietNoticeRowCount(), 1, "首次静默应恰好落一条安静留痕")

        // 重复 defer（模拟弹坞后再次点击的极端时序）：no-op，不留第二条 💬
        model.deferConfirmGate(.prototype)
        XCTAssertEqual(quietNoticeRowCount(), 1, "已静默再调用不得重复留痕")
        XCTAssertEqual(
            PMAgentStore.readConfirmSilence(project: "静默项目", version: "v1.0"),
            ["prototype"]
        )

        // 其他阶段不受影响
        XCTAssertFalse(model.isConfirmGateDeferred(.structure))
        XCTAssertFalse(model.isConfirmGateDeferred(.clarify))
    }

    // MARK: - 重启模拟：静默跨启动生效 + 版本隔离

    @MainActor
    func testSilenceSurvivesRestartAndIsolatesByVersion() throws {
        try makeWorkspace()
        try PMAgentStore.createVersion("v2.0", in: "静默项目")

        // 第一次运行：静默原型闸口
        let first = AppModel()
        first.selection = .session(project: "静默项目", version: "v1.0", sessionId: "s1")
        first.deferConfirmGate(.prototype)

        // 模拟重启：全新 AppModel 重进同一会话——静默仍生效（坞不再挂载）
        let second = AppModel()
        second.selection = .session(project: "静默项目", version: "v1.0", sessionId: "s1")
        XCTAssertTrue(
            second.isConfirmGateDeferred(.prototype),
            "重启后静默必须仍在（每版本只弹一次的核心契约）"
        )

        // 版本隔离：v2.0 是全新提醒
        second.selection = .session(project: "静默项目", version: "v2.0", sessionId: "s2")
        XCTAssertFalse(
            second.isConfirmGateDeferred(.prototype),
            "静默按版本隔离，v2.0 不应被 v1.0 波及"
        )
    }
}
