//
//  MemoryStore.swift
//  pm_worker
//
//  记忆层最小版（Task 2.6，design.md §5.2 记忆条目 / §6.3 沉淀）：
//  - 持久化：记忆条目随 discussions.jsonl 落盘（system 行携带 memory 载荷）
//  - 核心语义：新结论覆盖旧结论（supersededBy 回链），失效条目不注入
//  - 注入：Agent 工作前按 scope（版本 > 项目）取有效条目
//

import Foundation
import Combine

@MainActor
final class MemoryStore: ObservableObject {
    /// 有效条目（未失效；覆盖链头），注入用。
    @Published private(set) var effective: [MemoryEntry] = []

    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避：显式退出隔离销毁路径
    /// （本实例会在 switchContext 中被替换销毁）。
    nonisolated deinit {}

    private let project: String
    private let version: String

    init(project: String, version: String) {
        self.project = project
        self.version = version
        reload()
    }

    // MARK: - 读取（discussions.jsonl 投影）

    func reload() {
        // 版本 scope：当前版本目录
        var entries = PMAgentStore.readLines(
            DiscussionEntry.self,
            from: PMAgentStore.jsonlURL(
                project: project, version: version, file: "discussions.jsonl"
            )
        )
        .compactMap(\.memory)

        // 项目 scope：该项目全部版本的 discussions.jsonl（当前版本已含）
        for otherVersion in PMAgentStore.listVersions(in: project)
        where otherVersion != version && otherVersion != "knowledge" {
            let url = PMAgentStore.jsonlURL(
                project: project, version: otherVersion, file: "discussions.jsonl"
            )
            entries += PMAgentStore.readLines(DiscussionEntry.self, from: url)
                .compactMap(\.memory)
        }

        effective = Self.applySupersede(entries)
    }

    /// 覆盖语义：同 id 条目以最后一行为准（失效标记行追加在原行之后），
    /// 再剔除失效条目——旧结论不再注入。
    static func applySupersede(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        var latest: [String: MemoryEntry] = [:]
        var order: [String] = []
        for entry in entries {
            if latest[entry.id] == nil { order.append(entry.id) }
            latest[entry.id] = entry
        }
        return order.compactMap { id in
            guard let entry = latest[id], !entry.invalidated else { return nil }
            return entry
        }
    }

    // MARK: - 沉淀（写入端）

    /// 记忆抽取结果的条目载荷。
    struct ExtractionItem: Codable, Equatable {
        var kind: String      // conclusion | constraint | rejection
        var content: String
        var overrides: String?
    }

    /// 落盘记忆条目（覆盖语义）：新条目 append，被推翻旧条目补一条失效标记。
    /// 返回给 UI 展示的系统行文本。
    @discardableResult
    func record(
        _ items: [ExtractionItem],
        sessionId: String,
        appendLine: (DiscussionEntry) throws -> Void
    ) -> String {
        var reportLines: [String] = []
        for item in items {
            let kind: MemoryEntry.Kind
            switch item.kind {
            case "constraint": kind = .constraint
            case "rejection": kind = .rejection
            case "experience": kind = .experience
            default: kind = .conclusion
            }
            let entry = MemoryEntry(
                scope: .version, scopeId: version, kind: kind, content: item.content
            )

            // 覆盖语义：overrides 指向被推翻的旧条目 → 旧条目失效并回链
            if let overridden = item.overrides, !overridden.isEmpty {
                markSuperseded(matching: overridden, by: entry.id)
            }

            let line = DiscussionEntry(
                id: UUID().uuidString, sessionId: sessionId, role: .system,
                content: "📝 记忆已沉淀：[\(item.kind)] \(item.content)",
                think: nil, memory: entry,
                createdAt: ISO8601.timestamp()
            )
            if (try? appendLine(line)) != nil {
                reportLines.append("• [\(item.kind)] \(item.content)")
            }
        }
        reload()
        return reportLines.joined(separator: "\n")
    }

    /// 找到内容精确匹配的活跃条目 → append 一条失效标记（覆盖回链）。
    private func markSuperseded(matching content: String, by newId: String) {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        let all = PMAgentStore.readLines(DiscussionEntry.self, from: url)
        guard let target = all.first(where: {
            $0.memory?.content == content && $0.memory?.invalidated != true
        }), var oldMemory = target.memory else { return }

        oldMemory.invalidated = true
        oldMemory.supersededBy = newId

        let marker = DiscussionEntry(
            id: UUID().uuidString, sessionId: target.sessionId, role: .system,
            content: "📝 记忆覆盖：「\(content.prefix(40))」被新结论取代（旧值不再注入）",
            think: nil, memory: oldMemory,
            createdAt: ISO8601.timestamp()
        )
        try? PMAgentStore.appendLine(marker, to: url)
    }

    // MARK: - 经验沉淀（Task 4.4 归属分流 · 经验路线）

    /// 经验记忆沉淀：「经验」带 source_ref 与 confidence，跨项目按假设态注入
    /// （记忆校准用——design.md「经验」类型语义）。落盘后 reload。
    /// 返回给 UI 展示的系统行文本（写入失败返回空串）。
    @discardableResult
    func recordExperience(
        content: String,
        sourceRef: String,
        confidence: Double,
        sessionId: String,
        appendLine: (DiscussionEntry) throws -> Void
    ) -> String {
        let entry = MemoryEntry(
            scope: .project, scopeId: project, kind: .experience, content: content,
            sourceRef: sourceRef, confidence: min(max(confidence, 0), 1)
        )
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: sessionId, role: .system,
            content: "📝 经验已沉淀（假设态 · 跨项目可复用）：\(content)",
            think: nil, memory: entry,
            createdAt: ISO8601.timestamp()
        )
        guard (try? appendLine(line)) != nil else { return "" }
        reload()
        return line.content
    }

    /// 全项目「经验」条目（记忆校准的跨项目数据源——扫描所有项目的
    /// discussions.jsonl 记忆载荷，覆盖语义去重后只留有效经验）。
    static func allExperiences() -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        for projectName in PMAgentStore.listProjects() {
            for versionName in PMAgentStore.listVersions(in: projectName)
            where versionName != "knowledge" {
                let url = PMAgentStore.jsonlURL(
                    project: projectName, version: versionName, file: "discussions.jsonl"
                )
                entries += PMAgentStore.readLines(DiscussionEntry.self, from: url)
                    .compactMap(\.memory)
            }
        }
        return applySupersede(entries).filter { $0.kind == .experience }
    }

    // MARK: - 注入格式

    /// Agent 注入用上下文（版本 > 项目，新覆盖旧）。
    var injectionContext: String {
        // 版本 scope 优先排序
        let sorted = effective.sorted { a, b in
            if (a.scope == .version) != (b.scope == .version) {
                return a.scope == .version
            }
            return a.createdAt < b.createdAt
        }
        return AgentPrompts.formatMemory(sorted)
    }
}
