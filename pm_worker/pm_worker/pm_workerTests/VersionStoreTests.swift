//
//  VersionStoreTests.swift
//  pm_workerTests
//
//  Task 3.7 版本管理：封板落盘（version.json + release-notes）、目录只读
//  （immutable / 解保护）、Git 快照队列（首次 commit / 无变更 nil / 文件逐字一致）。
//

import XCTest
@testable import pm_worker

@MainActor
final class VersionStoreTests: XCTestCase {
    var tempRoot: URL!
    var store: VersionStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-release-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        store = VersionStore()
    }

    override func tearDown() {
        // 封板使版本目录 immutable（只读），删除前必须先解保护
        if let root = tempRoot { try? VersionStore.unprotect(root) }
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    /// Xcode 26 isolated-deinit malloc 崩溃规避（本类持有 @MainActor ObservableObject）。
    nonisolated deinit {}

    private func makeWorkspace(
        project: String = "封板项目", version: String = "v1.0"
    ) throws -> (project: String, version: String) {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: project)
        try PMAgentStore.createVersion(version, in: project)
        let dir = PMAgentStore.versionURL(project: project, version: version)
        try PMAgentStore.writeVerified(
            "# 澄清要点",
            to: dir.appendingPathComponent("01-requirements/clarification.md")
        )
        return (project, version)
    }

    // MARK: - 封板落盘

    func testReleaseWritesVersionJSONAndReleaseNotes() throws {
        let ctx = try makeWorkspace()

        var settled = false
        try store.release(
            project: ctx.project,
            version: ctx.version,
            notes: "# v1.0 发布说明\n\n- 完成：澄清与结构",
            settleRisks: { settled = true }
        )

        // 风险结算挂载点（AppModel 接 RiskStore.settleAllForRelease 的回调槽）被调用
        XCTAssertTrue(settled, "settleRisks 回调应在目录冻结前调用")

        // version.json：status = released，其余字段保持
        let doc = try XCTUnwrap(
            try PMAgentStore.readVersion(project: ctx.project, version: ctx.version)
        )
        XCTAssertEqual(doc.status, .released)
        XCTAssertEqual(doc.releasedAt, ISO8601.dayString())
        XCTAssertEqual(doc.version, "v1.0")

        // release-notes.md 落盘且可逐字回读
        let notesURL = PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
            .appendingPathComponent("07-reports/release-notes.md")
        XCTAssertEqual(
            try String(contentsOf: notesURL, encoding: .utf8),
            "# v1.0 发布说明\n\n- 完成：澄清与结构"
        )

        // 重复封板被拒
        XCTAssertThrowsError(
            try store.release(project: ctx.project, version: ctx.version, notes: "x")
        )
    }

    // MARK: - 封板后目录只读

    func testReleasedDirectoryIsImmutable() throws {
        let ctx = try makeWorkspace()
        let dir = PMAgentStore.versionURL(project: ctx.project, version: ctx.version)

        try store.release(project: ctx.project, version: ctx.version, notes: "n")

        // 版本目录本身 + 子目录 + 文件全部 immutable
        XCTAssertTrue(VersionStore.isImmutable(at: dir))
        XCTAssertTrue(VersionStore.isImmutable(at: dir.appendingPathComponent("01-requirements")))
        XCTAssertTrue(VersionStore.isImmutable(at: dir.appendingPathComponent("version.json")))
        XCTAssertTrue(
            VersionStore.isImmutable(at: dir.appendingPathComponent("07-reports/release-notes.md"))
        )

        // 写文件抛错：覆盖既有文件（write-then-verify）与新建文件均被拦截
        XCTAssertThrowsError(try PMAgentStore.writeVerified(
            "x",
            to: dir.appendingPathComponent("01-requirements/clarification.md")
        ))
        XCTAssertThrowsError(try "y".write(
            to: dir.appendingPathComponent("01-requirements/new.md"),
            atomically: true, encoding: .utf8
        ))

        // unversioned 不是发布单元，不可封板
        XCTAssertThrowsError(try store.release(project: ctx.project, version: "unversioned", notes: "n"))
    }

    // MARK: - 解保护后可写可删

    func testUnprotectRestoresWritability() throws {
        let ctx = try makeWorkspace()
        let dir = PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
        try store.release(project: ctx.project, version: ctx.version, notes: "n")
        XCTAssertTrue(VersionStore.isImmutable(at: dir))

        try VersionStore.unprotect(dir)
        XCTAssertFalse(VersionStore.isImmutable(at: dir))
        XCTAssertFalse(VersionStore.isImmutable(at: dir.appendingPathComponent("01-requirements")))
        XCTAssertFalse(
            VersionStore.isImmutable(at: dir.appendingPathComponent("version.json")),
            "递归解保护应覆盖到文件"
        )

        // 解保护后可写
        let probe = dir.appendingPathComponent("01-requirements/probe.md")
        try PMAgentStore.writeVerified("probe", to: probe)
        XCTAssertEqual(try String(contentsOf: probe, encoding: .utf8), "probe")
        // 可删
        try FileManager.default.removeItem(at: probe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.path))
    }

    // MARK: - Git 快照队列

    func testGitSnapshotFirstCommitThenNoChangeReturnsNil() async throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "快照项目")
        let projectDir = PMAgentStore.projectURL("快照项目")

        let queue = GitSnapshotQueue()
        let first = try await queue.snapshot(projectDir: projectDir, message: "闸口确认：初始快照")
        let hash = try XCTUnwrap(first, "首次快照应产生 commit")
        XCTAssertGreaterThanOrEqual(hash.count, 7, "commit hash 应非空")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(".git").path),
            "缺 .git 时应自动 git init"
        )

        let second = try await queue.snapshot(projectDir: projectDir, message: "无变更快照")
        XCTAssertNil(second, "无变更（nothing to commit）应静默返回 nil")
    }

    func testGitSnapshotPreservesFilesVerbatim() async throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "快照校验项目")
        try PMAgentStore.createVersion("v1.0", in: "快照校验项目")

        let projectDir = PMAgentStore.projectURL("快照校验项目")
        let target = PMAgentStore.versionURL(project: "快照校验项目", version: "v1.0")
            .appendingPathComponent("01-requirements/clarification.md")
        try PMAgentStore.writeVerified("# 要点\n- 用户：健身小白", to: target)
        let before = try String(contentsOf: target, encoding: .utf8)

        let queue = GitSnapshotQueue()
        let hash = try await queue.snapshot(projectDir: projectDir, message: "快照一")
        XCTAssertNotNil(hash)

        // 快照（git add -A + commit）不改动工作区文件：逐字一致
        XCTAssertEqual(
            try String(contentsOf: target, encoding: .utf8), before,
            "Git 快照后文件应逐字一致"
        )
    }

    // MARK: - release-notes prompt（生成辅助）

    func testReleaseNotesPromptEmbedsSummaryAndRules() {
        let prompt = VersionStore.releaseNotesPrompt(
            artifactsSummary: "01-requirements/clarification.md：要点表；02-structure/architecture.md：功能架构图"
        )
        XCTAssertTrue(prompt.contains("01-requirements/clarification.md"), "应内嵌产物摘要")
        XCTAssertTrue(prompt.contains("Markdown"))
        XCTAssertTrue(prompt.contains("禁止虚构"), "应明确不虚构要求")
        XCTAssertTrue(prompt.contains("完成阶段"))
        XCTAssertTrue(prompt.contains("产物清单"))
    }
}
