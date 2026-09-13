//
//  RecentFolderStore.swift
//  pm_worker
//
//  关联项目 chip 的「最近文件夹」历史（用户偏好持久化）：
//  记录 = 文件夹名 + 路径 + 最近使用时间，存 UserDefaults（pm.worker.recentFolders）。
//  与 ~/PMAgent 项目目录的关系：外部文件夹首次关联时由 UI 落同名项目，
//  本存储只管历史记录本身——删除偏好不影响事实源，删除项目后菜单条目仍在
//  （再次选中时 UI 重建项目目录）。
//

import Foundation

/// 最近文件夹记录（名称即关联身份，path 供菜单展示与回溯）。
nonisolated struct RecentFolder: Codable, Equatable, Identifiable {
    var name: String
    var path: String
    var lastUsedAt: Date

    var id: String { name }

    init(name: String, path: String, lastUsedAt: Date = Date()) {
        self.name = name
        self.path = path
        self.lastUsedAt = lastUsedAt
    }

    /// 从未使用过的既有项目（菜单合并段，不显示相对时间）。
    static let neverUsed = Date.distantPast
}

nonisolated enum RecentFolderStore {
    static let storageKey = "pm.worker.recentFolders"
    /// 记录容量上限（菜单只展示前 4 条，存储多留余量防误删）。
    static let capacity = 8

    /// 全部记录（最近使用时间倒序）。defaults 可注入（测试隔离）。
    static func records(defaults: UserDefaults = .standard) -> [RecentFolder] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([RecentFolder].self, from: data)
        else { return [] }
        return records.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// 记录一次使用：同名 upsert（更新路径 + 时间置顶），超容量淘汰最旧。
    static func record(
        name: String, path: String, at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var records = records(defaults: defaults).filter { $0.name != name }
        records.insert(RecentFolder(name: name, path: path, lastUsedAt: date), at: 0)
        if records.count > capacity {
            records = Array(records.prefix(capacity))
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// 菜单条目（最近记录在前 + 既有项目续后）：
    /// 未被记录过的 pm 项目并入菜单尾段（路径 = 项目目录，neverUsed），
    /// 「默认」不进菜单（关联它与不关联同义）。
    static func menuEntries(
        projects: [String], defaults: UserDefaults = .standard
    ) -> [RecentFolder] {
        let records = records(defaults: defaults)
        let recorded = Set(records.map(\.name))
        let fallback = projects
            .filter { $0 != PMAgentStore.defaultProjectName && !recorded.contains($0) }
            .sorted()
            .map {
                RecentFolder(
                    name: $0, path: PMAgentStore.projectURL($0).path,
                    lastUsedAt: RecentFolder.neverUsed
                )
            }
        return records + fallback
    }

    /// 最近使用时间的相对展示（「5 分钟前」；neverUsed 返回 nil 不显示）。
    static func relativeTime(_ date: Date) -> String? {
        guard date != RecentFolder.neverUsed else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
