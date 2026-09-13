//
//  MemoryDrawerView.swift
//  pm_worker
//
//  记忆抽屉（Task 4.7，ConversationView 头部 brain 按钮 → 右缘滑出 .ds-drawer 浮动卡）：
//  当前上下文有效记忆按 scope 分组（版本 > 项目 > 全局，注入优先级序）+
//  类型徽章 + 经验条目（假设态 · 置信度 / 出处）；失效记忆折叠区
//  （覆盖链历史，不注入）+「被谁覆盖」跳转（滚动到取代条目并高亮）。
//

import SwiftUI

struct MemoryDrawerView: View {
    @EnvironmentObject private var model: AppModel
    /// 关闭回调（右缘滑出浮动卡形态，开合动画由宿主 overlay 驱动）。
    var onClose: () -> Void

    /// 失效条目（discussions.jsonl 原始行投影：同 id 最后一行为准，invalidated）。
    @State private var invalidated: [MemoryEntry] = []
    @State private var showInvalidated = false
    /// 「被谁覆盖」跳转高亮 id（短暂高亮后清除）。
    @State private var highlightId: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            DSDivider()
            ScrollViewReader { proxy in
                List {
                    effectiveSections
                    invalidatedSection(proxy: proxy)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.surfaceBase)
                .padding(.horizontal, DS.Spacing.s8)
            }
        }
        // 原型 .ds-drawer：bg-base · neutral-l1 边 · r12 · max-w 360 ·
        // 双层大软影（0 24/64 14% + 0 4/16 8%）
        .frame(maxWidth: 360, maxHeight: .infinity)
        .background(Color.surfaceBase, in: RoundedRectangle(cornerRadius: DS.Radius.xxl))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.overlayBorder, lineWidth: 1)
        )
        .shadow(color: Color.shadowInk.opacity(0.14), radius: 32, y: 12)
        .shadow(color: Color.shadowInk.opacity(0.08), radius: 16, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
        .task { loadInvalidated() }
    }

    // MARK: - 头部（.ds-drawer__head：16/20 · 标题 + 统计 + 关闭钮）

    private var headerBar: some View {
        HStack(spacing: DS.Spacing.s8) {
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Label { Text("记忆抽屉") } icon: { DSIcon(.mem, size: 16) }
                    .font(DS.Font.headingSM)
                    .foregroundStyle(Color.ink900)
                Text(
                    "\(model.memory.effective.count) 条有效 · \(invalidated.count) 条已失效（不注入）"
                )
                .font(DS.Font.bodyXS)
                .monospacedDigit()
                .foregroundStyle(Color.ink500)
            }
            Spacer(minLength: 0)
            DSDialogCloseButton(action: onClose)
        }
        .padding(.horizontal, DS.Spacing.s20)
        .padding(.vertical, DS.Spacing.s16)
    }

    // MARK: - 有效条目（scope 分组：版本 > 项目 > 全局）

    private var effectiveSections: some View {
        ForEach(Array(Self.grouped(model.memory.effective).enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(group.entries, id: \.id) { entry in
                    MemoryEntryRow(entry: entry, highlighted: highlightId == entry.id)
                }
            } header: {
                MemoryScopeHeader(
                    title: scopeTitle(group.scope),
                    scope: group.scope
                )
            }
        }
    }

    private func scopeTitle(_ scope: MemoryEntry.Scope) -> String {
        switch scope {
        case .version: "版本记忆（\(model.pipeline.version)）——随版本演进，注入当前对话"
        case .project: "项目记忆（跨版本共享）"
        case .global: "全局记忆（跨项目）"
        }
    }

    /// scope 分组（注入优先级序），组内按沉淀时间升序（新覆盖旧语义下时间序即演化序）。
    nonisolated private static func grouped(
        _ entries: [MemoryEntry]
    ) -> [(scope: MemoryEntry.Scope, entries: [MemoryEntry])] {
        let order: [MemoryEntry.Scope] = [.version, .project, .global]
        return order
            .map { scope in
                (
                    scope,
                    entries
                        .filter { $0.scope == scope }
                        .sorted { $0.createdAt < $1.createdAt }
                )
            }
            .filter { !$0.entries.isEmpty }
    }

    // MARK: - 失效折叠区（覆盖链历史 + 「被谁覆盖」跳转）

    private func invalidatedSection(proxy: ScrollViewProxy) -> some View {
        Group {
            if !invalidated.isEmpty {
                Section {
                    if showInvalidated {
                        ForEach(invalidated, id: \.id) { entry in
                            InvalidatedEntryRow(entry: entry) {
                                jump(to: entry, proxy: proxy)
                            }
                        }
                    }
                } header: {
                    Button {
                        withAnimation { showInvalidated.toggle() }
                    } label: {
                        HStack(spacing: DS.Spacing.s4) {
                            Text("已失效")
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.statusAlert)
                                .padding(.horizontal, DS.Spacing.s6)
                                .padding(.vertical, DS.Spacing.s2)
                                .background(Capsule().fill(Color.statusAlertSurface1))
                            Label {
                                Text(
                                    showInvalidated
                                        ? "收起（\(invalidated.count) 条）"
                                        : "被新结论覆盖（\(invalidated.count) 条）"
                                )
                                .monospacedDigit()
                            } icon: {
                                DSIcon(showInvalidated ? .down : .collapseTriangle, size: 14)
                            }
                            .font(DS.Font.bodyXSStrong)
                            .foregroundStyle(Color.ink500)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Section {
                    Label {
                        Text("无失效记忆——覆盖发生时旧结论会在此留痕（新结论覆盖旧结论，旧值不再注入）")
                    } icon: {
                        DSIcon(.circleCheck, size: 14)
                    }
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                }
            }
        }
    }

    /// 跳转到取代条目：滚动 + 高亮；取代者不在有效集（也已失效 / 跨上下文）时提示。
    private func jump(to entry: MemoryEntry, proxy: ScrollViewProxy) {
        guard let successorId = entry.supersededBy else { return }
        guard model.memory.effective.contains(where: { $0.id == successorId }) else {
            highlightId = nil
            return
        }
        withAnimation {
            proxy.scrollTo(successorId, anchor: .center)
        }
        highlightId = successorId
        Task {
            try? await Task.sleep(for: .seconds(2))
            if highlightId == successorId { highlightId = nil }
        }
    }

    // MARK: - 失效数据（discussions.jsonl 投影，与 MemoryStore.reload 同口径）

    private func loadInvalidated() {
        let project = model.pipeline.project
        let version = model.pipeline.version
        invalidated = Self.readInvalidated(project: project, version: version)
    }

    /// 同 id 最后一行为准（失效标记行追加在原行之后），取 invalidated == true 的条目。
    nonisolated private static func readInvalidated(
        project: String, version: String
    ) -> [MemoryEntry] {
        var entries = PMAgentStore.readLines(
            DiscussionEntry.self,
            from: PMAgentStore.jsonlURL(
                project: project, version: version, file: "discussions.jsonl"
            )
        )
        .compactMap(\.memory)

        for otherVersion in PMAgentStore.listVersions(in: project)
        where otherVersion != version && otherVersion != "knowledge" {
            entries += PMAgentStore.readLines(
                DiscussionEntry.self,
                from: PMAgentStore.jsonlURL(
                    project: project, version: otherVersion, file: "discussions.jsonl"
                )
            )
            .compactMap(\.memory)
        }

        var latest: [String: MemoryEntry] = [:]
        var order: [String] = []
        for entry in entries {
            if latest[entry.id] == nil { order.append(entry.id) }
            latest[entry.id] = entry
        }
        return order.compactMap { id in
            guard let entry = latest[id], entry.invalidated else { return nil }
            return entry
        }
    }
}

// MARK: - 有效条目行（kind 徽章 + 内容 + 经验元数据）

private struct MemoryEntryRow: View {
    let entry: MemoryEntry
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s6) {
                MemoryKindBadge(kind: entry.kind)
                if entry.kind == .experience {
                    Text("假设态")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .help("经验以假设态注入，随使用校准置信度")
                }
                Spacer()
                Text(entry.createdAt)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
            }
            Text(entry.content)
                .font(DS.Font.bodyMD)
                .foregroundStyle(Color.ink900)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if entry.kind == .experience {
                HStack(spacing: DS.Spacing.s12) {
                    if let ref = entry.sourceRef, !ref.isEmpty {
                        Label { Text(ref) } icon: { DSIcon(.link, size: 14) }
                            .help("出处 source_ref：\(ref)")
                    }
                    if let confidence = entry.confidence {
                        Text("置信度 \(Int((confidence * 100).rounded()))%")
                    }
                }
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
            }
        }
        .padding(.vertical, DS.Spacing.s2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(
                    highlighted
                        ? AnyShapeStyle(Color.brandPopup)
                        : AnyShapeStyle(.clear)
                )
        )
        .id(entry.id)
    }
}

// MARK: - 失效条目行（删除线 + 被谁覆盖跳转）

private struct InvalidatedEntryRow: View {
    let entry: MemoryEntry
    let onJump: () -> Void

    private var successorId: String? {
        guard let id = entry.supersededBy, !id.isEmpty else { return nil }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s6) {
                MemoryKindBadge(kind: entry.kind)
                Spacer()
                Text(entry.createdAt)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
            }
            Text(entry.content)
                .font(DS.Font.bodyMD)
                .strikethrough()
                .foregroundStyle(Color.ink500)
                .lineLimit(2)
            if let successorId {
                Button {
                    onJump()
                } label: {
                    Label { Text("被覆盖 → 查看取代条目（\(successorId)）") } icon: { DSIcon(.arrowUpRight, size: 14) }
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.brandAccent)
                }
                .buttonStyle(.borderless)
                .help("跳转到覆盖此结论的新条目（覆盖链回链）")
            }
        }
        .padding(.vertical, DS.Spacing.s2)
    }
}

// MARK: - kind 徽章（结论=蓝 约束=橙 否决=红 经验=紫）

struct MemoryKindBadge: View {
    let kind: MemoryEntry.Kind

    private var title: String {
        switch kind {
        case .conclusion: "结论"
        case .constraint: "约束"
        case .rejection: "否决"
        case .experience: "经验"
        }
    }

    private var color: Color {
        switch kind {
        case .conclusion: Color.statusPrimary
        case .constraint: Color.statusWarning
        case .rejection: Color.statusError
        case .experience: Color.brand600
        }
    }

    private var surface: Color {
        switch kind {
        case .conclusion: Color.statusPrimarySurface1
        case .constraint: Color.statusWarningSurface1
        case .rejection: Color.statusErrorSurface1
        case .experience: Color.brandPopup
        }
    }

    var body: some View {
        Text(title)
            .font(DS.Font.bodyXS)
            .foregroundStyle(color)
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s2)
            .background(Capsule().fill(surface))
    }
}

// MARK: - scope 分组头（版本=brand 项目=primary 全局=success 四色区分）

private struct MemoryScopeHeader: View {
    let title: String
    let scope: MemoryEntry.Scope

    private var badgeText: String {
        switch scope {
        case .version: "版本"
        case .project: "项目"
        case .global: "全局"
        }
    }

    private var color: Color {
        switch scope {
        case .version: Color.brand600
        case .project: Color.statusPrimary
        case .global: Color.statusSuccess
        }
    }

    private var surface: Color {
        switch scope {
        case .version: Color.brandPopup
        case .project: Color.statusPrimarySurface1
        case .global: Color.statusSuccessSurface1
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s6) {
            Text(badgeText)
                .font(DS.Font.bodyXS)
                .foregroundStyle(color)
                .padding(.horizontal, DS.Spacing.s6)
                .padding(.vertical, DS.Spacing.s2)
                .background(Capsule().fill(surface))
            Text(title)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
        }
    }
}
