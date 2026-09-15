//
//  ArtifactCatalogTests.swift
//  pm_workerTests
//
//  产物面板改版（方案 A 分区台账）扫描层离线单测：
//  - scanArtifacts：编号目录内 .md/.html/.mmd 白名单收集 + 四类映射
//    （html→proto / mmd→chart / md→doc，07- 目录 md→report）
//  - 工作空间文件（根散置 jsonl/json）与非白名单文件不进产物
//  - mtime 倒序排序
//  - workspaceTree：全量目录投影（含编号产物目录），散文件保留 + 树计数
//  全离线：纯临时目录构造版本目录，不碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class ArtifactCatalogTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-artifacts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 辅助

    /// 在版本目录下落一个文件（自动建父目录），返回其 URL。
    @discardableResult
    private func put(_ relative: String, content: String = "# demo\n") throws -> URL {
        let target = tempRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// 显式设置 mtime（排序断言需要可控时间戳）。
    private func touch(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
    }

    private func kindOf(_ entries: [ArtifactEntry], _ name: String) -> ArtifactKind? {
        entries.first { $0.name == name }?.kind
    }

    // MARK: - 四类映射

    func testKindMappingByExtensionAndDirectory() throws {
        try put("01-requirements/notes.md")
        try put("03-prototypes/proto.html")
        try put("05-analysis/arch.mmd")
        try put("07-reports/scan.md")

        let entries = ArtifactCatalog.scanArtifacts(in: tempRoot)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(kindOf(entries, "notes.md"), .doc)
        XCTAssertEqual(kindOf(entries, "proto.html"), .proto)
        XCTAssertEqual(kindOf(entries, "arch.mmd"), .chart)
        XCTAssertEqual(kindOf(entries, "scan.md"), .report)
    }

    // MARK: - 工作空间/非白名单隔离

    func testWorkspaceFilesAndNonWhitelistExcluded() throws {
        try put("01-requirements/notes.md")
        try put("events.jsonl")                 // 根散置工作文件 → 工作空间
        try put("session-meta.json")
        try put("01-requirements/data.json")    // 非白名单扩展名 → 忽略
        try put("draft.txt")                    // 根部白名单外文件 → 忽略

        let entries = ArtifactCatalog.scanArtifacts(in: tempRoot)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "notes.md")
        XCTAssertEqual(entries.first?.relativePath, "01-requirements/notes.md")
    }

    // MARK: - mtime 倒序

    func testSortedByModificationDateDescending() throws {
        let old = try put("01-requirements/old.md")
        let mid = try put("03-prototypes/mid.html")
        let new = try put("07-reports/new.md")
        touch(old, Date(timeIntervalSince1970: 1_000))
        touch(mid, Date(timeIntervalSince1970: 2_000))
        touch(new, Date(timeIntervalSince1970: 3_000))

        let entries = ArtifactCatalog.scanArtifacts(in: tempRoot)
        XCTAssertEqual(entries.map(\.name), ["new.md", "mid.html", "old.md"])
    }

    // MARK: - 计数

    func testCountsGroupedByKind() throws {
        try put("01-requirements/a.md")
        try put("02-structure/b.md")
        try put("03-prototypes/c.html")
        try put("05-analysis/d.mmd")
        try put("07-reports/e.md")

        let counts = ArtifactCatalog.counts(for: ArtifactCatalog.scanArtifacts(in: tempRoot))
        XCTAssertEqual(counts[.doc], 2)
        XCTAssertEqual(counts[.proto], 1)
        XCTAssertEqual(counts[.chart], 1)
        XCTAssertEqual(counts[.report], 1)
    }

    // MARK: - 工作空间树（全量口径）

    func testWorkspaceTreeIncludesNumberedDirsAndRootFiles() throws {
        try put("01-requirements/notes.md")
        try put("04-prd/PRD.md")
        try put("events.jsonl")
        try put("knowledge/prompts.md")
        try put("archive/logs/pipeline.log")

        guard let tree = ArtifactCatalog.workspaceTree(in: tempRoot) else {
            return XCTFail("工作空间树不应为 nil")
        }
        let names = (tree.children ?? []).map(\.name)
        // 全量口径：编号产物目录与产物文件一并进树，与 Finder 一致
        XCTAssertTrue(names.contains("01-requirements"))
        XCTAssertTrue(names.contains("04-prd"))
        XCTAssertTrue(names.contains("events.jsonl"))
        XCTAssertTrue(names.contains("knowledge"))

        // 编号目录子级可见（产物文件在树内）
        let prd = (tree.children ?? []).first { $0.name == "04-prd" }
        XCTAssertEqual(prd?.children?.map(\.name), ["PRD.md"])

        let counts = ArtifactCatalog.treeCounts(tree)
        // 文件：notes.md + PRD.md + events.jsonl + prompts.md + pipeline.log = 5
        // 文件夹：01-requirements + 04-prd + knowledge + archive + logs = 5（根不计）
        XCTAssertEqual(counts.files, 5)
        XCTAssertEqual(counts.folders, 5)
    }

    // MARK: - 空态

    func testEmptyAndMissingDirectories() throws {
        XCTAssertTrue(ArtifactCatalog.scanArtifacts(in: tempRoot).isEmpty)

        let counts = ArtifactCatalog.treeCounts(nil)
        XCTAssertEqual(counts.files, 0)
        XCTAssertEqual(counts.folders, 0)

        // 目录不存在：workspaceTree 返回 nil，扫描返回空
        let missing = tempRoot.appendingPathComponent("not-created")
        XCTAssertNil(ArtifactCatalog.workspaceTree(in: missing))
        XCTAssertTrue(ArtifactCatalog.scanArtifacts(in: missing).isEmpty)
    }
}
