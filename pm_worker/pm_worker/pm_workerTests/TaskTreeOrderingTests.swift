//
//  TaskTreeOrderingTests.swift
//  pm_workerTests
//
//  任务列表排序稳定性（2026-09-13 用户决策）：
//  - 会话固定按创建顺序（首条 entry 时间升序），不随最近活跃跳位
//  - 项目/版本列表过滤隐藏目录（.git 不再显示为版本）
//  全离线：临时目录（rootOverride）直接写 discussions.jsonl。
//

import XCTest
@testable import pm_worker

final class TaskTreeOrderingTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tree-order-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        PMAgentStore.rootOverride = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 会话：固定按创建顺序

    func testSessionsFixedByCreationOrder() throws {
        // 会话「late」首条 11:00 / 末条 12:00；会话「early」首条 10:00 / 末条 11:30。
        // 旧「最近活跃倒序」返回 [late, early]；新「创建顺序」恒返回 [early, late]。
        let url = PMAgentStore.jsonlURL(
            project: PMAgentStore.defaultProjectName, version: "unversioned", file: "discussions.jsonl"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // appendLine 前置要求：jsonl 文件已存在（真实路径由 SessionStore.open 创建）
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let entries: [DiscussionEntry] = [
            DiscussionEntry(
                id: "b1", sessionId: "late", role: .user,
                content: "late 首条", createdAt: "2026-09-13T11:00:00Z"
            ),
            DiscussionEntry(
                id: "b2", sessionId: "late", role: .assistant,
                content: "late 回复", createdAt: "2026-09-13T12:00:00Z"
            ),
            DiscussionEntry(
                id: "a1", sessionId: "early", role: .user,
                content: "early 首条", createdAt: "2026-09-13T10:00:00Z"
            ),
            DiscussionEntry(
                id: "a2", sessionId: "early", role: .assistant,
                content: "early 回复", createdAt: "2026-09-13T11:30:00Z"
            ),
        ]
        for entry in entries { try PMAgentStore.appendLine(entry, to: url) }

        let sessions = SessionStore.sessions(
            in: PMAgentStore.defaultProjectName, version: "unversioned"
        )
        XCTAssertEqual(sessions.map(\.id), ["early", "late"])
    }

    // MARK: - 隐藏目录过滤（.git 等不是项目/版本）

    func testListVersionsAndProjectsFilterHiddenDirectories() throws {
        try FileManager.default.createDirectory(
            at: PMAgentStore.projectURL("演示项目"), withIntermediateDirectories: true
        )
        for name in ["unversioned", "v1.0", ".git", ".trash"] {
            try FileManager.default.createDirectory(
                at: PMAgentStore.versionURL(project: "演示项目", version: name),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: PMAgentStore.projectsDir.appendingPathComponent(".hidden", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(PMAgentStore.listVersions(in: "演示项目"), ["unversioned", "v1.0"])
        XCTAssertEqual(PMAgentStore.listProjects(), ["演示项目"])
    }
}
