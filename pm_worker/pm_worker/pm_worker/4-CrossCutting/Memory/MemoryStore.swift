//
//  MemoryStore.swift
//  pm_worker
//
//  记忆层（方案 A 台账式 · 两档作用域定稿）：
//  - 两池完全分离：全局记忆池 ~/PMAgent/memory.jsonl（跨项目）
//    与项目记忆池 <项目>/memory.jsonl + 历史版本 discussions.jsonl（本项目）
//  - 版本不是作用域：条目带 versions 溯源标签；旧 version 条目读时投影（MemoryModels）
//  - 注入优先级：项目 > 全局（具体性优先）；同池新覆盖旧（supersededBy 回链）
//  - ⚑ 硬边界（constraint/rejection）注入裁剪时永不丢；假设（experience）最先裁
//  - append-only + 碑文协议：失效条目不物理删除，留痕可追溯
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

    // MARK: - 存储位置

    /// 项目级记忆文件（跨版本长效条目 + 碑文兜底落点）。
    nonisolated static func projectMemoryURL(project: String) -> URL {
        PMAgentStore.projectURL(project).appendingPathComponent("memory.jsonl")
    }

    /// JSONL 文件不存在则建空文件（appendLine 要求文件已存在）。
    nonisolated static func ensureJSONLFile(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// 池数据源：project 非空 = 该项目（全部版本 discussions.jsonl + 项目级 memory.jsonl）；
    /// nil = 全局池 memory.jsonl。读序即 applySupersede 优先序（同 id 最后一行为准）。
    nonisolated private static func poolSources(project: String?) -> [URL] {
        guard let project else { return [PMAgentStore.globalMemoryURL] }
        var urls = [PMAgentStore.jsonlURL(
            project: project, version: "unversioned", file: "discussions.jsonl"
        )]
        for versionName in PMAgentStore.listVersions(in: project)
        where versionName != "knowledge" {
            let url = PMAgentStore.jsonlURL(
                project: project, version: versionName, file: "discussions.jsonl"
            )
            if !urls.contains(url) { urls.append(url) }
        }
        urls.append(projectMemoryURL(project: project))
        return urls
    }

    /// 指定池的全部记忆行（nonisolated：纯磁盘读取）。
    nonisolated static func readPoolLines(project: String?) -> [MemoryEntry] {
        poolSources(project: project).flatMap {
            PMAgentStore.readLines(DiscussionEntry.self, from: $0).compactMap(\.memory)
        }
    }

    /// 全部记忆行（当前项目全版本 + 项目级 + 全局池；读序 = 优先序，碑文兜底必胜）。
    nonisolated static func readAllMemoryLines(project: String, version: String) -> [MemoryEntry] {
        readPoolLines(project: project) + readPoolLines(project: nil)
    }

    // MARK: - 读取（discussions.jsonl + memory.jsonl 投影）

    func reload() {
        effective = Self.applySupersede(
            Self.readAllMemoryLines(project: project, version: version)
        )
    }

    /// 覆盖语义：同 id 条目以最后一行为准（失效标记行追加在原行之后），
    /// 再剔除失效条目——旧结论不再注入。
    nonisolated static func applySupersede(_ entries: [MemoryEntry]) -> [MemoryEntry] {
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

    /// 落盘记忆条目（覆盖语义）：新条目 append（项目池语义，带当前版本溯源标签），
    /// 被推翻旧条目补一条失效标记。返回给 UI 展示的系统行文本。
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
                scope: .project, scopeId: project, kind: kind,
                content: item.content, versions: version
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

    /// 找到内容精确匹配的活跃条目（全文件检索：当前版本 / 其他版本 / 项目级）→
    /// 落碑文失效并回链。跨版本覆盖从此闭环（旧版文件只读时碑文兜底项目级）。
    private func markSuperseded(matching content: String, by newId: String) {
        if let located = Self.locateEffectiveLine(
            project: project, version: version
        , where: { $0.memory?.content == content }) {
            appendTombstone(
                for: located.line, in: located.url, by: newId,
                note: "「\(content.prefix(40))」被新结论取代（旧值不再注入）"
            )
        }
    }

    // MARK: - 碑文（supersede / invalidate 统一机制）

    /// 在全部记忆文件里找 memoryId 的有效行（读序取最后一处命中；含全局池）。
    static func locateEffectiveLine(
        project: String, version: String, memoryId: String
    ) -> (url: URL, line: DiscussionEntry)? {
        locateEffectiveLine(project: project, version: version) {
            $0.memory?.id == memoryId
        }
    }

    /// 同上，谓词自定（在 DiscussionEntry 上匹配；扫描序含全局池——条目提升
    /// 全局后碑文写在全局池，此处必须覆盖）。
    static func locateEffectiveLine(
        project: String, version: String,
        where predicate: (DiscussionEntry) -> Bool
    ) -> (url: URL, line: DiscussionEntry)? {
        var files: [URL] = [
            PMAgentStore.jsonlURL(
                project: project, version: version, file: "discussions.jsonl"
            )
        ]
        for otherVersion in PMAgentStore.listVersions(in: project)
        where otherVersion != version && otherVersion != "knowledge" {
            files.append(
                PMAgentStore.jsonlURL(
                    project: project, version: otherVersion, file: "discussions.jsonl"
                )
            )
        }
        files.append(projectMemoryURL(project: project))
        files.append(PMAgentStore.globalMemoryURL)

        var hit: (url: URL, line: DiscussionEntry)?
        for url in files {
            for line in PMAgentStore.readLines(DiscussionEntry.self, from: url)
            where predicate(line) && line.memory?.invalidated != true {
                hit = (url, line)   // 读序靠后者胜（与 applySupersede 口径一致）
            }
        }
        return hit
    }

    /// 落碑文：原行复制置 invalidated + supersededBy 后 append 到原文件；
    /// 写失败（封板只读目录）→ 兜底写项目级记忆文件——读序保证碑文必胜。
    @discardableResult
    static func appendTombstone(
        for line: DiscussionEntry, in locatedURL: URL, by newId: String?,
        project: String, note: String
    ) -> Bool {
        var tombstone = line
        tombstone.id = UUID().uuidString
        tombstone.memory?.invalidated = true
        tombstone.memory?.supersededBy = newId
        tombstone.content = "📝 记忆失效：\(note)"

        if (try? PMAgentStore.appendLine(tombstone, to: locatedURL)) != nil {
            return true
        }
        let fallback = projectMemoryURL(project: project)
        ensureJSONLFile(at: fallback)
        return ((try? PMAgentStore.appendLine(tombstone, to: fallback)) != nil)
    }

    private func appendTombstone(
        for line: DiscussionEntry, in url: URL, by newId: String?, note: String
    ) {
        Self.appendTombstone(
            for: line, in: url, by: newId, project: project, note: note
        )
        reload()
    }

    // MARK: - 池管理（静态通用：project nil = 全局池；设置页两池共用）

    /// 单池定位有效行（project 非空时附加全局池——条目提升全局后碑文在全局池）。
    nonisolated private static func locatePoolLine(
        project: String?, where predicate: (DiscussionEntry) -> Bool
    ) -> (url: URL, line: DiscussionEntry)? {
        var files = poolSources(project: project)
        if project != nil { files.append(PMAgentStore.globalMemoryURL) }
        var hit: (url: URL, line: DiscussionEntry)?
        for url in files {
            for line in PMAgentStore.readLines(DiscussionEntry.self, from: url)
            where predicate(line) && line.memory?.invalidated != true {
                hit = (url, line)   // 读序靠后者胜（与 applySupersede 口径一致）
            }
        }
        return hit
    }

    /// 新增条目：项目池落项目级 memory.jsonl（versions 溯源标签可选），
    /// 全局池落 ~/PMAgent/memory.jsonl。返回错误文案，nil = 成功。
    nonisolated static func addEntry(
        project: String?, kind: MemoryEntry.Kind, versions: String?, content: String
    ) -> String? {
        let text = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "内容为空" }
        let entry = MemoryEntry(
            scope: project == nil ? .global : .project,
            scopeId: project ?? "",
            kind: kind, content: text,
            versions: (versions ?? "").isEmpty ? nil : versions
        )
        let target = project == nil
            ? PMAgentStore.globalMemoryURL
            : projectMemoryURL(project: project!)
        ensureJSONLFile(at: target)
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "manual", role: .system,
            content: "📝 记忆已添加：[\(kind.rawValue)] \(text)",
            think: nil, memory: entry, createdAt: ISO8601.timestamp()
        )
        guard (try? PMAgentStore.appendLine(line, to: target)) != nil else {
            return "写入失败（\(target.lastPathComponent)）"
        }
        return nil
    }

    /// 修订（supersede 协议）：新条目落同池文件，旧条目落碑文回链。
    /// newVersions / newSourceRef / newKind 传 nil = 继承原值。
    nonisolated static func supersedeEntry(
        project: String?, entry: MemoryEntry, newContent: String,
        newVersions: String?? = nil, newSourceRef: String?? = nil,
        newKind: MemoryEntry.Kind? = nil
    ) -> String? {
        let text = newContent
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "内容为空" }
        guard text != entry.content
            || (newVersions != nil && newVersions! != entry.versions)
            || (newSourceRef != nil && newSourceRef! != entry.sourceRef)
            || (newKind != nil && newKind! != entry.kind)
        else { return nil }

        let replacement = MemoryEntry(
            scope: entry.scope, scopeId: entry.scopeId,
            kind: newKind ?? entry.kind,
            content: text,
            versions: newVersions ?? entry.versions,
            sourceRef: newSourceRef ?? entry.sourceRef,
            confidence: entry.confidence
        )
        let target = project == nil
            ? PMAgentStore.globalMemoryURL
            : projectMemoryURL(project: project!)
        ensureJSONLFile(at: target)
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "manual", role: .system,
            content: "📝 记忆已修订：\(text)",
            think: nil, memory: replacement, createdAt: ISO8601.timestamp()
        )
        guard (try? PMAgentStore.appendLine(line, to: target)) != nil else {
            return "写入失败（\(target.lastPathComponent)）"
        }
        _ = invalidateEntry(
            project: project, entry: entry,
            note: "被修订版取代", supersededBy: replacement.id
        )
        return nil
    }

    /// 失效条目（碑文协议）：定位有效行 → 碑文回链。project nil = 全局池条目。
    nonisolated static func invalidateEntry(
        project: String?, entry: MemoryEntry, note: String, supersededBy: String? = nil
    ) -> String? {
        guard let located = locatePoolLine(
            project: project, where: { $0.memory?.id == entry.id }
        ) else { return "找不到该条目的原始记录行" }
        var tombstone = located.line
        tombstone.id = UUID().uuidString
        tombstone.memory?.invalidated = true
        tombstone.memory?.supersededBy = supersededBy
        tombstone.content = "📝 记忆失效：\(note.isEmpty ? "手动失效" : note)"

        if (try? PMAgentStore.appendLine(tombstone, to: located.url)) != nil { return nil }
        // 兜底：项目条目写项目级 memory.jsonl（读序在版本文件后，碑文必胜）；全局池无兜底
        guard let project else { return "写入失败（memory.jsonl）" }
        let fallback = projectMemoryURL(project: project)
        ensureJSONLFile(at: fallback)
        return ((try? PMAgentStore.appendLine(tombstone, to: fallback)) != nil)
            ? nil : "写入失败（memory.jsonl）"
    }

    // MARK: - 手动管理（实例包装：当前项目上下文 + reload）

    /// 手动新增（当前项目池 / 全局池）。返回错误文案，nil = 成功。
    func addManualEntry(
        kind: MemoryEntry.Kind, scope: MemoryEntry.Scope, content: String,
        versions: String? = nil
    ) -> String? {
        let result = Self.addEntry(
            project: scope == .global ? nil : project,
            kind: kind, versions: versions, content: content
        )
        if result == nil { reload() }
        return result
    }

    /// 编辑条目（supersede 协议）。返回错误文案，nil = 成功。
    func supersedeEntry(_ entry: MemoryEntry, newContent: String) -> String? {
        let result = Self.supersedeEntry(
            project: entry.scope == .global ? nil : project,
            entry: entry, newContent: newContent
        )
        if result == nil { reload() }
        return result
    }

    /// 失效条目（碑文协议）。返回错误文案，nil = 成功。
    func invalidateEntry(_ entry: MemoryEntry, note: String, supersededBy: String? = nil) -> String? {
        let result = Self.invalidateEntry(
            project: entry.scope == .global ? nil : project,
            entry: entry, note: note, supersededBy: supersededBy
        )
        if result == nil { reload() }
        return result
    }

    // MARK: - 整理记忆（LLM 出计划 → 白名单校验 → 落碑文）

    /// LLM 整理动作（schema 约束）。
    struct ConsolidationAction: Codable, Equatable {
        var action: String    // supersede | invalidate
        var id: String
        var keepId: String?
        var reason: String?
    }

    /// 宽松解析 + 结构校验（非法动作 / 自合并 / 缺 id 的条目丢弃）。
    nonisolated static func parseConsolidation(_ reply: String) -> [ConsolidationAction] {
        guard let actions = LenientJSON.decode([ConsolidationAction].self, from: reply)
        else { return [] }
        return actions.filter { item in
            switch item.action {
            case "invalidate":
                return !item.id.isEmpty
            case "supersede":
                guard let keep = item.keepId, !keep.isEmpty else { return false }
                return !item.id.isEmpty && item.id != keep
            default:
                return false
            }
        }
    }

    /// 应用整理计划：id 白名单校验（只认当前有效池），supersede 回链 keepId，
    /// invalidate 直接收殓。返回给 UI 的报告文本。
    func applyConsolidation(_ actions: [ConsolidationAction]) -> String {
        guard !actions.isEmpty else { return "" }
        let byId = Dictionary(uniqueKeysWithValues: effective.map { ($0.id, $0) })
        var report: [String] = []

        for item in actions {
            let reason = (item.reason ?? "").trimmingCharacters(in: .whitespaces)
            switch item.action {
            case "invalidate":
                guard let entry = byId[item.id] else { continue }
                if invalidateEntry(entry, note: reason.isEmpty ? "整理收纳（已过时/重复）" : reason) == nil {
                    report.append("🗑 已失效：\(entry.content.prefix(40))")
                }
            case "supersede":
                guard let drop = byId[item.id], let keep = byId[item.keepId ?? ""]
                else { continue }
                if invalidateEntry(drop, note: "并入「\(keep.content.prefix(30))」", supersededBy: keep.id) == nil {
                    report.append("🔗 合并：\(drop.content.prefix(30)) → \(keep.content.prefix(30))")
                }
            default:
                continue
            }
        }
        reload()
        return report.joined(separator: "\n")
    }

    // MARK: - 提升为全局（项目经验 → 全局记忆；两池唯一通道）

    /// 项目条目提升全局：副本落全局池（sourceRef 标注来源项目），原条目落碑文回链
    /// （建议仅在多个项目反复验证为普适方法论时调用——方案 A「升级路径」）。
    /// 返回错误文案，nil = 成功。
    nonisolated static func promoteEntryToGlobal(
        project: String, entry: MemoryEntry
    ) -> String? {
        let promoted = MemoryEntry(
            scope: .global, scopeId: "", kind: entry.kind, content: entry.content,
            sourceRef: "提升自项目「\(project)」" + (entry.sourceRef.map { " · \($0)" } ?? "")
        )
        let target = PMAgentStore.globalMemoryURL
        ensureJSONLFile(at: target)
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "promote", role: .system,
            content: "⬆️ 记忆已提升为全局：\(entry.content)",
            think: nil, memory: promoted, createdAt: ISO8601.timestamp()
        )
        guard (try? PMAgentStore.appendLine(line, to: target)) != nil else {
            return "写入失败（全局 memory.jsonl）"
        }
        // 原条目碑文回链（locate 含全局池，防重复提升出双副本）
        if let located = locatePoolLine(
            project: project, where: { $0.memory?.id == entry.id }
        ) {
            var tombstone = located.line
            tombstone.id = UUID().uuidString
            tombstone.memory?.invalidated = true
            tombstone.memory?.supersededBy = promoted.id
            tombstone.content = "📝 记忆失效：已提升为全局记忆（原项目条目不再注入）"
            if (try? PMAgentStore.appendLine(tombstone, to: located.url)) == nil {
                let fallback = projectMemoryURL(project: project)
                ensureJSONLFile(at: fallback)
                try? PMAgentStore.appendLine(tombstone, to: fallback)
            }
        }
        return nil
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
    /// 全部记忆文件 + 全局池，覆盖语义去重后只留有效经验）。
    nonisolated static func allExperiences() -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        for projectName in PMAgentStore.listProjects() {
            entries += readPoolLines(project: projectName)
        }
        entries += readPoolLines(project: nil)
        return applySupersede(entries).filter { $0.kind == .experience }
    }

    // MARK: - 经验校准（注入 → 待确认 → 确认/否定，置信度自动升降）

    /// 假设态初始置信度（「这条记下来」经验路线固定值，不暴露手动滑杆）。
    nonisolated static let experienceHypothesisConfidence: Double = 0.7
    /// 校准步长：确认有效 +0.1（多次使用逐轮趋近 1）；确认不符 −0.2（负证据降得快）。
    nonisolated static let calibrationConfirmStep: Double = 0.1
    nonisolated static let calibrationRejectStep: Double = 0.2

    /// 在全部项目文件 + 全局池中定位记忆 id 的有效行（与 allExperiences 同扫描序：
    /// 各项目 全部记忆文件 → 全局池，同 id 后命中者胜）。校准是跨项目回写，
    /// 本实例的 locateEffectiveLine 只扫当前项目，不够用。
    /// project = nil 表示命中在全局池。
    nonisolated static func locateEffectiveLineAcrossProjects(
        memoryId: String
    ) -> (url: URL, line: DiscussionEntry, project: String?)? {
        var hit: (url: URL, line: DiscussionEntry, project: String?)?
        for projectName in PMAgentStore.listProjects() {
            if let found = locatePoolLine(
                project: projectName, where: { $0.memory?.id == memoryId }
            ) {
                hit = (found.url, found.line, projectName)
            }
        }
        // 全局池最后扫（同 id 全局副本必胜）；project = nil 标识全局
        for line in PMAgentStore.readLines(DiscussionEntry.self, from: PMAgentStore.globalMemoryURL)
        where line.memory?.id == memoryId && line.memory?.invalidated != true {
            hit = (PMAgentStore.globalMemoryURL, line, nil)
        }
        return hit
    }

    /// 校准回写核心：跨项目定位 id 有效行 → transform 变换（返回 false = 无需变更，
    /// 不落盘）→ 更新副本 append 回原文件（同 id 最后一行为准，applySupersede 取新值）；
    /// 原文件写失败（封板只读）→ 兜底该项目级 memory.jsonl（读序保证必胜）；
    /// 全局池行无兜底。返回更新后的条目；找不到有效行 / 无变更返回 nil。
    @discardableResult
    nonisolated static func updateExperience(
        id: String,
        note: (MemoryEntry) -> String,
        transform: (inout MemoryEntry) -> Bool
    ) -> MemoryEntry? {
        guard let located = locateEffectiveLineAcrossProjects(memoryId: id),
              var memory = located.line.memory,
              transform(&memory) else { return nil }

        var updated = located.line
        updated.id = UUID().uuidString
        updated.sessionId = "calibration"
        updated.content = note(memory)
        updated.memory = memory
        updated.createdAt = ISO8601.timestamp()
        if (try? PMAgentStore.appendLine(updated, to: located.url)) != nil {
            return memory
        }
        guard let project = located.project else { return nil }
        let fallback = projectMemoryURL(project: project)
        ensureJSONLFile(at: fallback)
        return ((try? PMAgentStore.appendLine(updated, to: fallback)) != nil) ? memory : nil
    }

    /// 注入标记：本次方法论使用实际注入了这批经验 → 置待校准并记注入时间
    /// （已 pending 的不重复标记，避免每次发送重复落行）。返回实际标记数。
    @discardableResult
    nonisolated static func markExperiencesPendingCalibration(ids: [String]) -> Int {
        var marked = 0
        for id in ids {
            let now = ISO8601.timestamp()
            let updated = updateExperience(
                id: id,
                note: { "📈 经验注入待校准（使用方法论时已按假设态注入）：\($0.content.prefix(40))" }
            ) { memory in
                guard memory.kind == .experience, memory.calibrationPending != true else {
                    return false
                }
                memory.calibrationPending = true
                memory.lastInjectedAt = now
                return true
            }
            if updated != nil { marked += 1 }
        }
        return marked
    }

    /// 校准回写：confirmed=true 置信度 +0.1（上限 1）；false −0.2（下限 0），并清除待校准。
    /// 返回更新后的条目；非经验 / 无待校准标记 / 找不到条目返回 nil。
    @discardableResult
    nonisolated static func applyExperienceCalibration(
        id: String, confirmed: Bool
    ) -> MemoryEntry? {
        var previousConfidence: Double?
        let updated = updateExperience(
            id: id,
            note: { memory in
                let from = previousConfidence.map { String(format: "%.1f", $0) } ?? "—"
                let to = String(format: "%.1f", memory.confidence ?? 0)
                let verdict = confirmed ? "确认有效" : "确认不符"
                return "📈 经验校准（\(verdict)）：置信度 \(from) → \(to)——\(memory.content.prefix(40))"
            }
        ) { memory in
            guard memory.kind == .experience, memory.calibrationPending == true else {
                return false
            }
            previousConfidence = memory.confidence
            let step = confirmed ? calibrationConfirmStep : -calibrationRejectStep
            memory.confidence = min(
                max((memory.confidence ?? experienceHypothesisConfidence) + step, 0), 1
            )
            memory.calibrationPending = false
            return true
        }
        return updated
    }

    // MARK: - 注入格式

    /// 词面相关度评分（CJK/拉丁 2-gram 重叠，零网络零依赖）：0 = 无交集。
    /// 记忆注入排序（injectionContext(rankedFor:)）与 recall_memory 工具共用。
    /// 纯函数，测试直测。
    nonisolated static func relevanceScore(content: String, query: String) -> Int {
        let q = query.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let c = content.lowercased()
        guard q.count >= 2 else { return 0 }
        var score = 0
        // 整串字面命中 = 强信号（短查询才有意义，长串几乎不会整体出现）
        if q.count <= 16, c.contains(q) { score += 8 }
        var seen = Set<String>()
        let chars = Array(q)
        for i in 0..<(chars.count - 1) {
            let gram = String(chars[i...(i + 1)])
            if !seen.insert(gram).inserted { continue }
            if c.contains(gram) { score += 3 }
        }
        return score
    }

    /// 硬边界条目（⚑ 约束/否决项）——注入排序时恒前置，裁剪时永不丢。
    nonisolated static func isHardBoundary(_ entry: MemoryEntry) -> Bool {
        entry.kind == .constraint || entry.kind == .rejection
    }

    /// Agent 注入用上下文（优先级链：项目 > 全局——具体性优先，非时长优先；
    /// 会话上下文天然最优先，不在此列）。项目池内版本标签匹配当前版本的条目
    /// 再前置；同层新条目在前（降序）——超预算从尾部逐行丢。
    /// rankedFor 非空时启用相关性排序（P0：预算裁行先丢「最不相关」而非「最旧」）：
    /// 硬边界条目全池最前（保护层不为相关性让位），其余同层按评分降序、新在前。
    func injectionContext(rankedFor query: String?) -> String {
        let useRanking = !(query ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let score: (MemoryEntry) -> Int = { entry in
            guard useRanking else { return 0 }
            return Self.relevanceScore(content: entry.content, query: query!)
        }
        let sorted = effective.sorted { a, b in
            if useRanking {
                let hardA = Self.isHardBoundary(a)
                let hardB = Self.isHardBoundary(b)
                if hardA != hardB { return hardA }
            }
            let tierA = a.scope == .global ? 1 : 0
            let tierB = b.scope == .global ? 1 : 0
            if tierA != tierB { return tierA < tierB }          // 项目 > 全局
            if tierA == 0 {
                // 项目池内：versions 匹配当前版本（含空 = 跨版本通用）在前
                let am = (a.versions ?? "").isEmpty || a.versions?.contains(version) == true
                let bm = (b.versions ?? "").isEmpty || b.versions?.contains(version) == true
                if am != bm { return am }
            }
            if useRanking {
                let sa = score(a)
                let sb = score(b)
                if sa != sb { return sa > sb }
            }
            return a.createdAt > b.createdAt
        }
        return AgentPrompts.formatMemory(sorted)
    }

    /// 无排序注入（碑文序语义：版本 scope 前置 + 新条目在前）。
    var injectionContext: String { injectionContext(rankedFor: nil) }

    // MARK: - 工具通道（save_memory / recall_memory，P0）

    /// 词面检索（当前项目全版本 + 项目级 + 全局池）：评分降序 top-limit，
    /// 零分不返。recall_memory 工具数据源。
    nonisolated static func searchEntries(
        project: String, version: String, query: String, limit: Int = 8
    ) -> [MemoryEntry] {
        let entries = applySupersede(readAllMemoryLines(project: project, version: version))
        return entries
            .map { (entry: $0, score: relevanceScore(content: $0.content, query: query)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entry)
    }

    /// 模型主动记忆写入（save_memory）：kind 只放行 结论/经验——
    /// ⚑ 硬边界（约束/否决项）必须来自用户裁决事件，模型不能自封约束。
    /// 经验落假设态（confidence 0.7），进既有校准回路等待用户确认。
    /// 返回错误文案，nil = 成功。
    nonisolated static func addToolEntry(
        project: String, version: String, kind: MemoryEntry.Kind, content: String
    ) -> String? {
        guard kind == .conclusion || kind == .experience else {
            return "save_memory 只支持 kind=conclusion（结论）或 kind=experience（经验）；约束与否决项须由用户确认沉淀。"
        }
        let text = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "内容为空" }
        let entry = MemoryEntry(
            scope: .project, scopeId: project, kind: kind, content: text,
            versions: version.isEmpty ? nil : version,
            sourceRef: "模型主动记录",
            confidence: kind == .experience ? experienceHypothesisConfidence : nil
        )
        let target = projectMemoryURL(project: project)
        ensureJSONLFile(at: target)
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "agent", role: .system,
            content: "🧠 模型主动记下一笔：[\(kind.rawValue)] \(text)",
            think: nil, memory: entry, createdAt: ISO8601.timestamp()
        )
        guard (try? PMAgentStore.appendLine(line, to: target)) != nil else {
            return "写入失败（版本可能已封板只读）"
        }
        return nil
    }
}
