//
//  RecentFolderStoreTests.swift
//  pm_workerTests
//
//  关联项目 chip 的最近文件夹历史：UserDefaults 持久化、同名 upsert、
//  容量淘汰、menuEntries 与既有项目合并（「默认」排除）。
//

import XCTest
@testable import pm_worker

@MainActor
final class RecentFolderStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "test.pm.worker.recentFolders"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 记录与排序

    func testRecordPersistsAndSortsByRecency() {
        let old = Date(timeIntervalSinceNow: -3_600)
        RecentFolderStore.record(name: "pm worker", path: "/Users/x/pm worker", at: old, defaults: defaults)
        RecentFolderStore.record(name: "MindMap", path: "/Users/x/MindMap", defaults: defaults)

        let records = RecentFolderStore.records(defaults: defaults)
        XCTAssertEqual(records.map(\.name), ["MindMap", "pm worker"], "最近使用的在前")

        // 持久化：新实例（同 suite）读回一致
        let reread = UserDefaults(suiteName: suiteName).flatMap {
            RecentFolderStore.records(defaults: $0)
        }
        XCTAssertEqual(reread, records)
    }

    func testRecordUpsertsByNameAndUpdatesPath() {
        RecentFolderStore.record(name: "Repaste", path: "/old/Repaste", defaults: defaults)
        RecentFolderStore.record(name: "Repaste", path: "/new/Repaste", defaults: defaults)

        let records = RecentFolderStore.records(defaults: defaults)
        XCTAssertEqual(records.count, 1, "同名记录不重复")
        XCTAssertEqual(records.first?.path, "/new/Repaste", "路径以最近一次为准")
    }

    func testRecordEvictsOldestBeyondCapacity() {
        for index in 0..<RecentFolderStore.capacity {
            RecentFolderStore.record(
                name: "项目\(index)", path: "/p/\(index)",
                at: Date(timeIntervalSinceNow: Double(index)), defaults: defaults
            )
        }
        // 再塞一条最新的 → 最旧的「项目0」被淘汰
        RecentFolderStore.record(name: "新项目", path: "/p/new", defaults: defaults)

        let names = RecentFolderStore.records(defaults: defaults).map(\.name)
        XCTAssertEqual(names.count, RecentFolderStore.capacity)
        XCTAssertFalse(names.contains("项目0"), "最旧记录被淘汰")
        XCTAssertTrue(names.contains("新项目"))
    }

    // MARK: - 菜单合并

    func testMenuEntriesMergesProjectsWithoutShadowingRecords() {
        PMAgentStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-folders-\(UUID().uuidString)", isDirectory: true)
        defer { PMAgentStore.rootOverride = nil }

        RecentFolderStore.record(name: "pm worker", path: "/Users/x/pm worker", defaults: defaults)

        let entries = RecentFolderStore.menuEntries(
            projects: ["默认", "pm worker", "MindMap", "Repaste"], defaults: defaults
        )

        XCTAssertEqual(entries.first?.name, "pm worker", "有记录的排最前")
        XCTAssertNotEqual(entries.first?.lastUsedAt, RecentFolder.neverUsed, "记录项带真实使用时间")

        let fallback = entries.dropFirst()
        XCTAssertEqual(fallback.map(\.name), ["MindMap", "Repaste"], "未记录项目按名续后，「默认」不进菜单")
        for entry in fallback {
            XCTAssertEqual(
                entry.path, PMAgentStore.projectURL(entry.name).path,
                "未记录项目路径 = 项目目录"
            )
            XCTAssertEqual(entry.lastUsedAt, RecentFolder.neverUsed)
        }
    }

    func testRelativeTimeNilForNeverUsed() {
        XCTAssertNil(RecentFolderStore.relativeTime(RecentFolder.neverUsed))
        XCTAssertNotNil(RecentFolderStore.relativeTime(Date()))
    }
}
