//
//  ProjectDocument.swift
//  pm_worker
//
//  project.json 的 Codable 模型（design.md §5.2）。
//

import Foundation

nonisolated struct ProjectDocument: Codable, Equatable {
    var id: String
    var name: String
    /// 目标收敛句
    var goalStatement: String?
    /// 长期约束
    var constraints: [String]
    /// 否决项
    var rejections: [String]
    var createdAt: String
    var currentVersion: String?
    var versions: [String]

    init(
        id: String = IDGenerator.next("proj"),
        name: String,
        goalStatement: String? = nil,
        constraints: [String] = [],
        rejections: [String] = [],
        createdAt: String = ISO8601.dayString(),
        currentVersion: String? = nil,
        versions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.goalStatement = goalStatement
        self.constraints = constraints
        self.rejections = rejections
        self.createdAt = createdAt
        self.currentVersion = currentVersion
        self.versions = versions
    }
}

/// version.json 的 Codable 模型（design.md §5.2）。
nonisolated struct VersionDocument: Codable, Equatable {
    enum Status: String, Codable {
        case planning
        case inProgress = "in-progress"
        case released
    }

    var version: String
    var status: Status
    /// 本版需求清单
    var scope: [String]
    var createdAt: String
    var releasedAt: String?
    var gitTag: String?
    var inheritedFrom: String?

    init(
        version: String,
        status: Status = .planning,
        scope: [String] = [],
        createdAt: String = ISO8601.dayString(),
        releasedAt: String? = nil,
        gitTag: String? = nil,
        inheritedFrom: String? = nil
    ) {
        self.version = version
        self.status = status
        self.scope = scope
        self.createdAt = createdAt
        self.releasedAt = releasedAt
        self.gitTag = gitTag
        self.inheritedFrom = inheritedFrom
    }
}

/// nonisolated + NSLock：GUI 主线程与 MCP 无头实例的 Task 均会生成 id，须线程安全。
nonisolated enum IDGenerator {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counter: UInt64 = 0
    /// 进程内已发 id（防「时间低位 ^ 计数」碰撞——同前缀连续生成时
    /// 毫秒位翻转可恰好抵消计数变化，导致同 id 串档，risks.jsonl 折叠丢数据）。
    private nonisolated(unsafe) static var used: Set<String> = []

    /// 生成形如 `proj_8f3k` 的短 id（前缀 + 时间低位 + 计数，进程内唯一）。
    static func next(_ prefix: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        repeat {
            counter &+= 1
            let time = UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF
            let tail = String(format: "%04x", UInt16(truncatingIfNeeded: time ^ counter))
            if used.insert("\(prefix)_\(tail)").inserted {
                return "\(prefix)_\(tail)"
            }
        } while true
    }
}

nonisolated enum ISO8601 {
    /// `2026-09-10`（日期，project/version 用）
    static func dayString(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `2026-09-10T14:30:00+08:00`（时刻，decisions/risks 用）
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// 解析 timestamp(_:) 产物（含时区偏移）；格式不符返回 nil。
    static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.date(from: string)
    }
}
