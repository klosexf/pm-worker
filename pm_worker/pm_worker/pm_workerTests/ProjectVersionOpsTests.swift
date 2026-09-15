//
//  ProjectVersionOpsTests.swift
//  pm_workerTests
//
//  项目/版本结构操作（侧栏行「更多」菜单的存储层）离线单测：
//  - renameProject：目录 move + project.json name 回写；「默认」/ 非法名 / 同名冲突拒绝
//  - deleteProject：整目录移除；「默认」拒绝
//  - renameVersion：目录 move + version.json version 字段 + project.json
//    versions/currentVersion 回写；unversioned / 已封板拒绝
//  - deleteVersion：整目录移除 + versions 清单回写；unversioned / 已封板拒绝
//  全离线：rootOverride 临时目录隔离，不碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class ProjectVersionOpsTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-structops-\(UUID().uuidString)", isDirectory: true)
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

    /// 建一个带版本的项目（createProject + createVersion，均走真实落盘）。
    private func makeProject(_ name: String, versions: [String]) throws {
        _ = try PMAgentStore.createProject(named: name)
        for version in versions {
            _ = try PMAgentStore.createVersion(version, in: name)
        }
    }

    /// 把某版本标记为已封板（version.json status=released 直接落盘）。
    private func seal(project: String, version: String) throws {
        let doc = VersionDocument(version: version, status: .released)
        let data = try JSONEncoder().encode(doc)
        try data.write(
            to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent("version.json"),
            options: .atomic
        )
    }

    // MARK: - 项目重命名

    func testRenameProjectMovesDirectoryAndRewritesManifest() throws {
        try makeProject("老项目", versions: ["v1.0"])
        // 版本目录里塞一个文件，验证整体迁移
        let oldVersionDir = PMAgentStore.versionURL(project: "老项目", version: "v1.0")
        try PMAgentStore.writeVerified("hello", to: oldVersionDir.appendingPathComponent("discussions.jsonl"))

        try PMAgentStore.renameProject(from: "老项目", to: "新项目")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: PMAgentStore.projectURL("老项目").path),
            "旧目录应已不存在"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: PMAgentStore.versionURL(project: "新项目", version: "v1.0")
                    .appendingPathComponent("discussions.jsonl").path
            ),
            "版本内容应随目录整体迁移"
        )
        let project = try XCTUnwrap(PMAgentStore.readProject("新项目"), "project.json 应可读")
        XCTAssertEqual(project.name, "新项目", "清单 name 字段应回写为新名")
        XCTAssertEqual(PMAgentStore.listVersions(in: "新项目"), ["knowledge", "unversioned", "v1.0"])
    }

    func testRenameProjectRejectsDefaultProjectAndBadNames() throws {
        try makeProject("普通项目", versions: ["v1.0"])

        // 系统预建「默认」不可重命名
        XCTAssertThrowsError(try PMAgentStore.renameProject(from: "默认", to: "别的名字"))
        // 磁盘上「默认」目录应原封不动
        XCTAssertTrue(FileManager.default.fileExists(atPath: PMAgentStore.projectURL("默认").path))

        // 非法名：空 / 路径分隔符 / 已存在
        XCTAssertThrowsError(try PMAgentStore.renameProject(from: "普通项目", to: "  "))
        XCTAssertThrowsError(try PMAgentStore.renameProject(from: "普通项目", to: "a/b"))
        XCTAssertThrowsError(try PMAgentStore.renameProject(from: "普通项目", to: "默认"))
        // 项目不存在
        XCTAssertThrowsError(try PMAgentStore.renameProject(from: "不存在", to: "x"))
        // 源目录未被误动
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: PMAgentStore.projectURL("普通项目").path)
        )
    }

    // MARK: - 项目删除

    func testDeleteProjectRemovesDirectoryAndRejectsDefault() throws {
        try makeProject("待删项目", versions: ["v1.0", "v2.0"])

        XCTAssertThrowsError(try PMAgentStore.deleteProject("默认"), "「默认」不可删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: PMAgentStore.projectURL("默认").path))

        try PMAgentStore.deleteProject("待删项目")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: PMAgentStore.projectURL("待删项目").path)
        )
        XCTAssertNil(try PMAgentStore.readProject("待删项目"))
        // 不存在的项目报错而非静默
        XCTAssertThrowsError(try PMAgentStore.deleteProject("待删项目"))
    }

    // MARK: - 版本重命名

    func testRenameVersionMovesDirectoryAndRewritesDocs() throws {
        try makeProject("档案项目", versions: ["v1.0", "v2.0"])
        // currentVersion 指向 v1.0，重命名后应跟随
        if var project = try PMAgentStore.readProject("档案项目") {
            project.currentVersion = "v1.0"
            try PMAgentStore.writeProject(project, to: PMAgentStore.projectURL("档案项目"))
        }
        let oldDir = PMAgentStore.versionURL(project: "档案项目", version: "v1.0")
        try PMAgentStore.writeVerified("entry", to: oldDir.appendingPathComponent("decisions.jsonl"))

        try PMAgentStore.renameVersion(project: "档案项目", from: "v1.0", to: "v1.5")

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path), "旧版本目录应已不存在")
        let newDir = PMAgentStore.versionURL(project: "档案项目", version: "v1.5")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newDir.appendingPathComponent("decisions.jsonl").path),
            "版本内容应随目录整体迁移"
        )
        let doc = try XCTUnwrap(PMAgentStore.readVersion(project: "档案项目", version: "v1.5"))
        XCTAssertEqual(doc.version, "v1.5", "version.json version 字段应回写")
        let project = try XCTUnwrap(PMAgentStore.readProject("档案项目"))
        XCTAssertEqual(project.versions, ["v1.5", "v2.0"], "versions 清单应替换旧名")
        XCTAssertEqual(project.currentVersion, "v1.5", "currentVersion 应跟随更名")
    }

    func testRenameVersionRejectsUnversionedSealedAndCollisions() throws {
        try makeProject("守卫项目", versions: ["v1.0", "v2.0"])
        try seal(project: "守卫项目", version: "v2.0")

        // 系统保留版本不可重命名
        XCTAssertThrowsError(
            try PMAgentStore.renameVersion(project: "守卫项目", from: "unversioned", to: "v9")
        )
        // 已封板版本是只读快照
        XCTAssertThrowsError(
            try PMAgentStore.renameVersion(project: "守卫项目", from: "v2.0", to: "v2.1")
        )
        // 非法名 / 同名冲突 / 不存在
        XCTAssertThrowsError(
            try PMAgentStore.renameVersion(project: "守卫项目", from: "v1.0", to: "v2.0")
        )
        XCTAssertThrowsError(
            try PMAgentStore.renameVersion(project: "守卫项目", from: "v1.0", to: "含/斜杠")
        )
        XCTAssertThrowsError(
            try PMAgentStore.renameVersion(project: "守卫项目", from: "v404", to: "v9")
        )
        // 守卫失败不落盘：v2.0 仍是封板原名，v9 未出现
        XCTAssertEqual(PMAgentStore.listVersions(in: "守卫项目"), ["knowledge", "unversioned", "v1.0", "v2.0"])
        let doc = try XCTUnwrap(PMAgentStore.readVersion(project: "守卫项目", version: "v2.0"))
        XCTAssertEqual(doc.status, .released)
    }

    // MARK: - 版本删除

    func testDeleteVersionRemovesDirectoryAndRewritesManifest() throws {
        try makeProject("清理项目", versions: ["v1.0", "v2.0"])
        if var project = try PMAgentStore.readProject("清理项目") {
            project.currentVersion = "v1.0"
            try PMAgentStore.writeProject(project, to: PMAgentStore.projectURL("清理项目"))
        }

        try PMAgentStore.deleteVersion(project: "清理项目", version: "v1.0")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: PMAgentStore.versionURL(project: "清理项目", version: "v1.0").path
            )
        )
        let project = try XCTUnwrap(PMAgentStore.readProject("清理项目"))
        XCTAssertEqual(project.versions, ["v2.0"], "versions 清单应移除被删版本")
    }

    func testDeleteVersionRejectsUnversionedAndSealed() throws {
        try makeProject("快照项目", versions: ["v1.0"])
        try seal(project: "快照项目", version: "v1.0")

        XCTAssertThrowsError(
            try PMAgentStore.deleteVersion(project: "快照项目", version: "unversioned")
        )
        XCTAssertThrowsError(
            try PMAgentStore.deleteVersion(project: "快照项目", version: "v1.0")
        )
        // 守卫失败不落盘
        XCTAssertEqual(PMAgentStore.listVersions(in: "快照项目"), ["knowledge", "unversioned", "v1.0"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: PMAgentStore.versionURL(project: "快照项目", version: "v1.0").path
            )
        )
    }
}
