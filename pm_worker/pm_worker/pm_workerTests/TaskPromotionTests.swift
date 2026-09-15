//
//  TaskPromotionTests.swift
//  pm_workerTests
//
//  任务 → 空间转化（任务行菜单「转为项目」）离线单测：
//  - SessionStore.moveSession：对话行迁移（目标先追加、源后移除）、
//    标题覆盖随迁、附图 copy 不 move（源保留）、兄弟会话不受扰、
//    未命中会话 no-op（目标不建文件）
//  - AppModel.promoteTaskToProject：空名 / 未落盘会话守卫、成功转化
//    （建项目 + 迁移 + selection 重定向 + activeProject 跟随）、
//    同名冲突报错且不误删既有项目
//  全离线：rootOverride 临时目录隔离，不碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class TaskPromotionTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-promote-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        // bootstrap 只建默认/unversioned 目录；appendLine 前置要求 jsonl 存在
        try? PMAgentStore.ensureWorkspace(
            project: PMAgentStore.defaultProjectName, version: "unversioned"
        )
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private var sourceURL: URL {
        PMAgentStore.jsonlURL(
            project: PMAgentStore.defaultProjectName, version: "unversioned",
            file: "discussions.jsonl"
        )
    }

    private func targetURL(_ project: String) -> URL {
        PMAgentStore.jsonlURL(
            project: project, version: "unversioned", file: "discussions.jsonl"
        )
    }

    /// 在默认/unversioned 追加一条会话行（可选附图），返回所用附图文件名。
    /// at：显式 ISO 时间（同秒时间戳会让「创建顺序」排序不稳定，须互异）。
    @discardableResult
    private func seedTaskLine(
        id: String, sessionId: String, content: String, image: Bool = false,
        at: String = "2026-09-14T10:00:00Z"
    ) throws -> String? {
        var imageName: String? = nil
        if image {
            imageName = try PMAgentStore.saveAttachment(
                data: Data("fake-png".utf8), fileExtension: "png",
                project: PMAgentStore.defaultProjectName, version: "unversioned"
            )
        }
        try PMAgentStore.appendLine(
            DiscussionEntry(
                id: id, sessionId: sessionId, role: .user, content: content,
                images: imageName.map { [$0] },
                createdAt: at
            ),
            to: sourceURL
        )
        return imageName
    }

    private func sourceSessions() -> [SessionSummary] {
        SessionStore.sessions(
            in: PMAgentStore.defaultProjectName, version: "unversioned"
        )
    }

    // MARK: - moveSession：行迁移 / 标题 / 附图

    func testMoveSessionMigratesLinesTitleAndImages() throws {
        let imageName = try seedTaskLine(id: "a1", sessionId: "task-a", content: "A 首条", image: true)
        try seedTaskLine(id: "a2", sessionId: "task-a", content: "A 回复")
        try seedTaskLine(id: "b1", sessionId: "task-b", content: "B 首条")
        // task-a 有标题覆盖（走生产 API 落 session-meta.json）
        try SessionStore.renameSession(
            project: PMAgentStore.defaultProjectName, version: "unversioned",
            sessionId: "task-a", title: "宠物寄养平台"
        )

        try SessionStore.moveSession(
            sessionId: "task-a",
            from: PMAgentStore.defaultProjectName, sourceVersion: "unversioned",
            to: "新项目", targetVersion: "unversioned"
        )

        // 目标：只有 task-a，行数 2，标题覆盖随迁
        let targetSessions = SessionStore.sessions(in: "新项目", version: "unversioned")
        XCTAssertEqual(targetSessions.map(\.id), ["task-a"])
        XCTAssertEqual(targetSessions.first?.messageCount, 2)
        XCTAssertEqual(targetSessions.first?.title, "宠物寄养平台")

        // 源：只剩 task-b，标题覆盖已清
        XCTAssertEqual(sourceSessions().map(\.id), ["task-b"])
        XCTAssertNil(
            SessionStore.sessionTitles(
                project: PMAgentStore.defaultProjectName, version: "unversioned"
            )["task-a"]
        )

        // 附图：copy 不 move——目标有、源也还在
        let imageName2 = try XCTUnwrap(imageName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetURL("新项目")
                .deletingLastPathComponent()
                .appendingPathComponent("attachments/\(imageName2)").path),
            "附图应复制到目标 attachments/"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent("attachments/\(imageName2)").path),
            "源附图应保留（其他会话可能共享）"
        )
    }

    func testMoveSessionAppendsAfterExistingTargetSessions() throws {
        // 目标已有自己的会话（迁移是追加，不是覆盖）
        _ = try PMAgentStore.createProject(named: "已有项目")
        try PMAgentStore.ensureWorkspace(project: "已有项目", version: "unversioned")
        try PMAgentStore.appendLine(
            DiscussionEntry(
                id: "e1", sessionId: "existing", role: .user, content: "目标存量",
                createdAt: "2026-09-14T09:00:00Z"
            ),
            to: targetURL("已有项目")
        )
        try seedTaskLine(id: "a1", sessionId: "task-a", content: "A 首条", at: "2026-09-14T10:00:00Z")

        try SessionStore.moveSession(
            sessionId: "task-a",
            from: PMAgentStore.defaultProjectName, sourceVersion: "unversioned",
            to: "已有项目", targetVersion: "unversioned"
        )

        XCTAssertEqual(
            SessionStore.sessions(in: "已有项目", version: "unversioned").map(\.id),
            ["existing", "task-a"],
            "目标存量在前、迁移行追加在后"
        )
    }

    func testMoveSessionUnknownSessionIsNoOp() throws {
        try seedTaskLine(id: "b1", sessionId: "task-b", content: "B 首条")
        let before = try String(contentsOf: sourceURL, encoding: .utf8)

        try SessionStore.moveSession(
            sessionId: "不存在的会话",
            from: PMAgentStore.defaultProjectName, sourceVersion: "unversioned",
            to: "幽灵项目", targetVersion: "unversioned"
        )

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), before, "源文件应原封不动")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetURL("幽灵项目").path),
            "未命中会话应提前返回，目标不建文件"
        )
    }

    // MARK: - AppModel.promoteTaskToProject：守卫 + 成功 + 同名冲突

    /// 单实例串行跑完三幕（AppModel 构建含索引后台任务，控制实例数）。
    @MainActor
    func testPromoteTaskGuardsHappyPathAndNameConflict() throws {
        let model = AppModel()

        // 幕一：守卫——空名 / 未落盘会话
        try seedTaskLine(id: "a1", sessionId: "task-a", content: "A 首条")
        XCTAssertNotNil(
            model.promoteTaskToProject(sessionId: "task-a", projectName: "   "),
            "空名应报错"
        )
        XCTAssertNotNil(
            model.promoteTaskToProject(sessionId: "从未发送的会话", projectName: "幽灵项目"),
            "未落盘会话应报错"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: PMAgentStore.projectURL("幽灵项目").path),
            "守卫拒绝时不应建项目"
        )

        // 幕二：成功转化——先选中该任务（模拟用户正在看的任务行），再转
        model.selection = .session(
            project: PMAgentStore.defaultProjectName, version: "unversioned", sessionId: "task-a"
        )
        XCTAssertNil(model.promoteTaskToProject(sessionId: "task-a", projectName: "宠物寄养平台"))

        XCTAssertEqual(sourceSessions().map(\.id), [], "任务区应已无该会话")
        XCTAssertEqual(
            SessionStore.sessions(in: "宠物寄养平台", version: "unversioned").map(\.id),
            ["task-a"],
            "新项目 unversioned 下应找到迁入会话"
        )
        guard case .session(let p, let v, let sid) = model.selection else {
            return XCTFail("转化后应重定向到新项目的会话")
        }
        XCTAssertEqual(p, "宠物寄养平台")
        XCTAssertEqual(v, "unversioned")
        XCTAssertEqual(sid, "task-a")
        XCTAssertEqual(model.activeProject, "宠物寄养平台")
        XCTAssertTrue(
            model.projects.contains { $0.name == "宠物寄养平台" },
            "侧栏树应包含新项目"
        )

        // 幕三：同名冲突——既有项目不被误删、源任务不丢
        try seedTaskLine(id: "c1", sessionId: "task-c", content: "C 首条")
        _ = try PMAgentStore.createProject(named: "撞名项目")
        let sentinel = PMAgentStore.versionURL(project: "撞名项目", version: "unversioned")
            .appendingPathComponent("discussions.jsonl")
        try PMAgentStore.writeVerified("sentinel\n", to: sentinel)

        XCTAssertNotNil(
            model.promoteTaskToProject(sessionId: "task-c", projectName: "撞名项目"),
            "同名冲突应报错"
        )
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8), "sentinel\n",
            "既有项目内容不应被误删"
        )
        XCTAssertEqual(
            sourceSessions().map(\.id), ["task-c"],
            "冲突失败时源任务应保留在任务区"
        )
    }
}
