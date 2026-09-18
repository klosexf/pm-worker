//
//  StorageWriteLockTests.swift
//  pm_workerTests
//
//  阶段 0 基座（存储层写锁 + 产物冲突检测）：
//  ① 进程级 ioLock：并发 appendLine 不丢行不损行
//  ② writeMeasured 乐观校验：expectedSHA 失配抛 ArtifactConflict 且文件未动，命中正常写
//  ③ writePrototypeArtifact 透传：slotOverrides 改落 / expectedSnapshot 冲突 /
//    默认参数行为不变
//

import XCTest
@testable import pm_worker

final class StorageWriteLockTests: XCTestCase {

    private let project = "写锁测试项目"
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
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - ① 并发 appendLine（ioLock 串行化）

    func testConcurrentAppendLineKeepsAllLinesIntact() throws {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "decisions.jsonl"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let total = 100
        let failLock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: total) { i in
            do {
                try PMAgentStore.appendLine("line-\(i)", to: url)
            } catch {
                failLock.lock()
                failures.append("\(i): \(error)")
                failLock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, "并发追加出现失败：\(failures.prefix(3))")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, total, "100 行不丢不重")
        // 不损行：每行都是完整 JSON 字符串
        let decoded = lines.compactMap {
            try? JSONDecoder().decode(String.self, from: Data($0.utf8))
        }
        XCTAssertEqual(decoded.count, total)
        XCTAssertEqual(Set(decoded), Set((0..<total).map { "line-\($0)" }), "不重不漏")
    }

    // MARK: - ② writeMeasured 乐观校验（经 writePrototypeArtifact 透传）

    private func block(_ name: String, _ html: String) -> ArtifactParser.ArtifactBlock {
        .init(name: name, content: html)
    }

    private func prototypeURL() -> URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(ArtifactPath.prototype)
    }

    func testWriteMeasuredSHAHitWritesNormally() throws {
        let first = "<html>\n<body>v1</body>\n</html>"
        _ = try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", first)], project: project, version: version
        )
        // 期望 SHA 与磁盘现状一致 → 命中，正常写入新内容
        let snapshot = [ArtifactPath.prototype: ArtifactParser.sha256Hex(first)]
        let second = "<html>\n<body>v2</body>\n</html>"
        let result = try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", second)],
            project: project, version: version,
            expectedSnapshot: snapshot
        )
        let written = try XCTUnwrap(result)
        let change = try XCTUnwrap(written.changes.first)
        XCTAssertEqual(change.path, ArtifactPath.prototype)
        XCTAssertFalse(change.isNew)
        XCTAssertEqual(try String(contentsOf: prototypeURL(), encoding: .utf8), second)
    }

    func testWriteMeasuredSHAMismatchThrowsConflictAndKeepsFileUntouched() throws {
        let original = "<html>\n<body>untouched</body>\n</html>"
        _ = try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", original)], project: project, version: version
        )
        XCTAssertThrowsError(try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", "<html>new</html>")],
            project: project, version: version,
            expectedSnapshot: [ArtifactPath.prototype: String(repeating: "0", count: 64)]
        )) { error in
            guard let conflict = error as? ArtifactParser.ArtifactConflict else {
                return XCTFail("期望 ArtifactConflict，实际 \(error)")
            }
            XCTAssertEqual(conflict.path, ArtifactPath.prototype)
            XCTAssertEqual(conflict.actualSHA, ArtifactParser.sha256Hex(original))
        }
        // 文件未被修改
        XCTAssertEqual(try String(contentsOf: prototypeURL(), encoding: .utf8), original)
    }

    func testWriteMeasuredMissingFileWithExpectedSHAThrowsConflict() throws {
        // 期望有存量（expectedSHA 非 nil）而磁盘没有 → 失配，actualSHA 为 nil，
        // 且目标文件不因本次调用而创建
        XCTAssertThrowsError(try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", "<html>new</html>")],
            project: project, version: version,
            expectedSnapshot: [ArtifactPath.prototype: String(repeating: "a", count: 64)]
        )) { error in
            guard let conflict = error as? ArtifactParser.ArtifactConflict else {
                return XCTFail("期望 ArtifactConflict，实际 \(error)")
            }
            XCTAssertEqual(conflict.path, ArtifactPath.prototype)
            XCTAssertNil(conflict.actualSHA)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prototypeURL().path))
    }

    // MARK: - ③ writePrototypeArtifact 透传

    func testSlotOverrideRedirectsBlockToOverridePath() throws {
        let overrideRel = "03-prototypes/原型-override.html"
        let result = try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", "<html>redirect</html>")],
            project: project, version: version,
            slotOverrides: ["prototype": overrideRel]
        )
        let written = try XCTUnwrap(result)
        XCTAssertEqual(written.slots.first?.relPath, overrideRel)
        XCTAssertEqual(
            try String(contentsOf: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(overrideRel), encoding: .utf8),
            "<html>redirect</html>"
        )
        // 默认槽位文件不应被创建
        XCTAssertFalse(FileManager.default.fileExists(atPath: prototypeURL().path))
    }

    func testSlotOverrideConflictCheckedAgainstOverridePath() throws {
        let overrideRel = "03-prototypes/原型-override.html"
        let existing = "<html>existing</html>"
        let dir = PMAgentStore.versionURL(project: project, version: version)
        try PMAgentStore.writeVerified(existing, to: dir.appendingPathComponent(overrideRel))
        // expectedSnapshot 以改落后的 override 路径为键
        XCTAssertThrowsError(try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", "<html>new</html>")],
            project: project, version: version,
            expectedSnapshot: [overrideRel: String(repeating: "f", count: 64)],
            slotOverrides: ["prototype": overrideRel]
        )) { error in
            guard let conflict = error as? ArtifactParser.ArtifactConflict else {
                return XCTFail("期望 ArtifactConflict，实际 \(error)")
            }
            XCTAssertEqual(conflict.path, overrideRel)
            XCTAssertEqual(conflict.actualSHA, ArtifactParser.sha256Hex(existing))
        }
        // 文件未被修改
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent(overrideRel), encoding: .utf8),
            existing
        )
    }

    func testDefaultParametersPreserveLegacyBehavior() throws {
        // 默认参数（expectedSnapshot / slotOverrides 均为 nil）：与既有口径一致
        let result = try ArtifactParser.writePrototypeArtifact(
            blocks: [block("prototype", "<html>plain</html>")],
            project: project, version: version
        )
        let written = try XCTUnwrap(result)
        XCTAssertEqual(written.slots.map(\.relPath), [ArtifactPath.prototype])
        XCTAssertEqual(
            try String(contentsOf: prototypeURL(), encoding: .utf8),
            "<html>plain</html>"
        )
    }
}
