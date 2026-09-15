//
//  FileChangeTests.swift
//  pm_workerTests
//
//  文件变更卡数据链路三项测试：
//  ① FileLineDiff 行级统计（LCS / 末尾空行归一 / 超限退化）
//  ② DiscussionEntry.fileChanges 编解码与旧格式兼容
//  ③ 落盘测量（writeMeasured 经 write*Artifact 的首写 isNew / 覆写 diff）
//

import XCTest
@testable import pm_worker

final class FileChangeTests: XCTestCase {

    private let project = "变更卡测试项目"
    private let version = "v1.0"
    /// 磁盘隔离：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/。
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
        // 产物文件清零，保证「首写 isNew」断言不受历史状态污染
        let dir = PMAgentStore.versionURL(project: project, version: version)
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(ArtifactPath.prototype)
        )
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("02-structure"))
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - ① FileLineDiff

    func testNilOrEmptyOldCountsAllAsAdded() {
        let diff = FileLineDiff.changedLines(old: nil, new: "a\nb\n")
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 0)

        let emptyOld = FileLineDiff.changedLines(old: "", new: "a\nb\n")
        XCTAssertEqual(emptyOld.added, 2)
        XCTAssertEqual(emptyOld.removed, 0)
    }

    func testIdenticalContentIsZeroDiff() {
        // 末尾空行归一：old 无换尾 / new 有换尾，视为相同
        let diff = FileLineDiff.changedLines(old: "a\nb\nc", new: "a\nb\nc\n")
        XCTAssertEqual(diff.added, 0)
        XCTAssertEqual(diff.removed, 0)
    }

    func testPureInsertionAndDeletion() {
        let insertion = FileLineDiff.changedLines(old: "a\nc", new: "a\nb\nc")
        XCTAssertEqual(insertion.added, 1)
        XCTAssertEqual(insertion.removed, 0)

        let deletion = FileLineDiff.changedLines(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(deletion.added, 0)
        XCTAssertEqual(deletion.removed, 1)
    }

    func testMixedChangeCountsBothDirections() {
        // LCS（"a","c"）= 2 → 新增 x/e 两行，删除 b/d 两行
        let diff = FileLineDiff.changedLines(old: "a\nb\nc\nd", new: "a\nx\nc\ne")
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 2)
    }

    func testRepeatedLinesUseLongestCommonSubsequence() {
        // 重复行不能按集合去重：old 两个 a，new 三个 a → 仅新增 1 行
        let diff = FileLineDiff.changedLines(old: "a\na\nb", new: "a\na\na\nb")
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 0)
    }

    func testOversizeInputFallsBackToBagDiffEstimate() {
        // 2100 × 2100 > 400 万 cell → 走多重集估算路径；替换单行结果应与 LCS 一致
        var oldLines = (0..<2100).map { "line-\($0)" }
        let newLines = oldLines
        oldLines[1500] = "old-unique"
        var replaced = newLines
        replaced[1500] = "new-unique"
        let diff = FileLineDiff.changedLines(
            old: oldLines.joined(separator: "\n"),
            new: replaced.joined(separator: "\n")
        )
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
    }

    // MARK: - ② DiscussionEntry 编解码

    func testFileChangesRoundtrip() throws {
        let entry = DiscussionEntry(
            id: "e1", sessionId: "s1", role: .system,
            content: "📦 交互原型已生成",
            fileChanges: [
                FileChangeSummary(
                    path: "03-prototypes/prototype-v1.html",
                    added: 12, removed: 3, isNew: false
                )
            ],
            createdAt: "2026-09-13T12:00:00Z"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiscussionEntry.self, from: data)
        XCTAssertEqual(decoded.fileChanges, entry.fileChanges)
        XCTAssertEqual(decoded.fileChanges?.first?.path, "03-prototypes/prototype-v1.html")
    }

    func testLegacyJSONWithoutFileChangesDecodesNil() throws {
        // 旧存量行（无 fileChanges 字段）必须照常解码
        let legacy = """
        {"id":"e2","sessionId":"s1","role":"system","content":"📦 旧格式行","createdAt":"2026-09-01T00:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(
            DiscussionEntry.self, from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.fileChanges)
        XCTAssertEqual(decoded.content, "📦 旧格式行")
    }

    // MARK: - ③ 落盘测量

    private func prototypeBlocks(_ html: String) -> [ArtifactParser.ArtifactBlock] {
        [ArtifactParser.ArtifactBlock(name: "prototype", content: html)]
    }

    func testFirstPrototypeWriteIsNewWithAllLinesAdded() throws {
        let result = try ArtifactParser.writePrototypeArtifact(
            blocks: prototypeBlocks("<html>\n<body>a</body>\n</html>"),
            project: project, version: version
        )
        let written = try XCTUnwrap(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.url.path))
        let change = try XCTUnwrap(written.changes.first)
        XCTAssertEqual(change.path, ArtifactPath.prototype)
        XCTAssertTrue(change.isNew)
        XCTAssertEqual(change.added, 3)
        XCTAssertEqual(change.removed, 0)
    }

    func testOverwritePrototypeReportsLineDiff() throws {
        _ = try ArtifactParser.writePrototypeArtifact(
            blocks: prototypeBlocks("<html>\n<body>a</body>\n</html>"),
            project: project, version: version
        )
        let result = try ArtifactParser.writePrototypeArtifact(
            blocks: prototypeBlocks(
                "<html>\n<body>b</body>\n<footer>x</footer>\n</html>"
            ),
            project: project, version: version
        )
        let change = try XCTUnwrap(try XCTUnwrap(result).changes.first)
        XCTAssertFalse(change.isNew)
        // LCS（"<html>","</html>"）= 2 → 新增 2 行、删除 1 行
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
    }

    func testStructureWriteReturnsThreeChangeSummaries() throws {
        let blocks = [
            ArtifactParser.ArtifactBlock(name: "architecture", content: "graph TD\nA-->B"),
            ArtifactParser.ArtifactBlock(name: "core-flows", content: "graph LR\nA-->B"),
            ArtifactParser.ArtifactBlock(name: "module-page-map", content: "| 模块 |\n|---|"),
        ]
        let artifacts = try ArtifactParser.writeStructureArtifacts(
            blocks: blocks, project: project, version: version
        )
        XCTAssertEqual(artifacts.changes.count, 3)
        XCTAssertEqual(
            Set(artifacts.changes.map(\.path)),
            [
                ArtifactPath.architecture,
                ArtifactPath.coreFlows,
                ArtifactPath.modulePageMap,
            ]
        )
        XCTAssertTrue(artifacts.changes.allSatisfy { $0.isNew && $0.added > 0 })
    }

    // MARK: - ④ 落盘广播

    /// writeVerified 落盘成功必须广播 pm.worker.artifacts.changed——右栏「文件」
    /// 台账实时刷新的挂钩；漏发会导致产物生成后面板不刷新、需切 Tab 才可见。
    func testWriteVerifiedPostsArtifactsChangedNotification() throws {
        let exp = expectation(description: "artifacts.changed 已广播")
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: Notification.Name("pm.worker.artifacts.changed"),
            object: nil, queue: nil
        ) { _ in exp.fulfill() }
        defer { center.removeObserver(observer) }

        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("01-requirements")
            .appendingPathComponent("澄清要点表.md")
        try PMAgentStore.writeVerified("# 澄清要点\n", to: url)
        wait(for: [exp], timeout: 2)
    }
}
