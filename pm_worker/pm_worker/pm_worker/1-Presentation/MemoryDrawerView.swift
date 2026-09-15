//
//  MemoryDrawerView.swift
//  pm_worker
//
//  记忆抽屉（ConversationView 头部 brain 按钮 → 右缘滑出 .ds-drawer 浮动卡）：
//  方案 A 两档作用域（项目 > 全局，注入优先级序）；类型不显示——只留两个
//  行为标记（⚑ 硬边界永不裁剪 / 假设未验证可裁剪）+ 版本溯源标签；注入后
//  待校准条目带符合/不符确认；失效记忆折叠区（覆盖链历史，不注入）+
//  「被谁覆盖」跳转（滚动到取代条目并高亮）。
//

import SwiftUI

struct MemoryDrawerView: View {
    @EnvironmentObject private var model: AppModel
    /// 关闭回调（右缘滑出浮动卡形态，开合动画由宿主 overlay 驱动）。
    var onClose: () -> Void

    /// 失效条目（原始行投影：同 id 最后一行为准，invalidated）。
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

    // MARK: - 有效条目（两档分组：项目 > 全局）

    private var effectiveSections: some View {
        ForEach(Array(Self.grouped(model.memory.effective).enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(group.entries, id: \.id) { entry in
                    MemoryEntryRow(
                        entry: entry,
                        highlighted: highlightId == entry.id,
                        onCalibrate: { confirmed in
                            model.confirmExperienceCalibration(id: entry.id, confirmed: confirmed)
                        }
                    )
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
        case .project: "项目记忆（跨版本共享 · 版本只是溯源标签）"
        case .global: "全局记忆（跨项目）"
        }
    }

    /// 两档分组（注入优先级序：项目 > 全局），组内按沉淀时间升序（演化序）。
    nonisolated private static func grouped(
        _ entries: [MemoryEntry]
    ) -> [(scope: MemoryEntry.Scope, entries: [MemoryEntry])] {
        let order: [MemoryEntry.Scope] = [.project, .global]
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
    /// 与 MemoryStore.reload 同一数据源（含项目级 memory.jsonl，碑文兜底行也在内）。
    nonisolated private static func readInvalidated(
        project: String, version: String
    ) -> [MemoryEntry] {
        var latest: [String: MemoryEntry] = [:]
        var order: [String] = []
        for entry in MemoryStore.readAllMemoryLines(project: project, version: version) {
            if latest[entry.id] == nil { order.append(entry.id) }
            latest[entry.id] = entry
        }
        return order.compactMap { id in
            guard let entry = latest[id], entry.invalidated else { return nil }
            return entry
        }
    }
}

// MARK: - 有效条目行（行为标记 + 版本标签 + 内容 + 经验元数据）

private struct MemoryEntryRow: View {
    let entry: MemoryEntry
    let highlighted: Bool
    /// 校准确认回调（confirmed：true = 符合实际 +0.1 / false = 不符 −0.2）。
    var onCalibrate: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            Text(entry.content)
                .font(DS.Font.bodyMD)
                .foregroundStyle(Color.ink900)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.s6) {
                MemoryNatureMark(kind: entry.kind)
                if let versions = entry.versions, !versions.isEmpty {
                    Text(versions)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink300)
                        .padding(.horizontal, DS.Spacing.s4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm)
                                .strokeBorder(Color.overlayBorder, lineWidth: 1)
                        )
                        .help("版本溯源标签：此条经验/结论沉淀并适用于该版本区间")
                }
                Spacer()
                Text(entry.createdAt)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
            }
            if entry.kind == .experience {
                if let ref = entry.sourceRef, !ref.isEmpty {
                    Label { Text(ref) } icon: { DSIcon(.link, size: 14) }
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .help("出处 source_ref：\(ref)")
                }
                if entry.calibrationPending == true {
                    calibrationPrompt
                }
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

    /// 校准确认条（E23「随使用校准」落地 UI）：注入后用户判定经验是否符合实际，
    /// 确认/否定即自动调整内部置信度（不显示百分比），清除待校准标记。
    private var calibrationPrompt: some View {
        HStack(spacing: DS.Spacing.s8) {
            Text("上次使用时已注入——这条假设符合实际吗？")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink700)
            Spacer(minLength: 0)
            Button {
                onCalibrate(true)
            } label: {
                Label { Text("符合") } icon: { DSIcon(.thumbsUp, size: 12) }
            }
            .buttonStyle(.ds(.secondary, size: .xs))
            .help("确认有效：内部置信度上调（假设更接近定论）")
            Button {
                onCalibrate(false)
            } label: {
                Label { Text("不符") } icon: { DSIcon(.unlike, size: 12) }
            }
            .buttonStyle(.ds(.ghost, size: .xs))
            .help("确认不符：内部置信度下调（负证据降得快）")
        }
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
                MemoryNatureMark(kind: entry.kind)
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

// MARK: - 行为标记（⚑ 硬边界=橙 / 假设=紫 / 普通结论不显示）
// kind 为 AI 内部字段，界面不展示类型名——只暴露注入行为差异

struct MemoryNatureMark: View {
    let kind: MemoryEntry.Kind

    private var title: String {
        switch kind {
        case .constraint, .rejection: "⚑ 硬边界"
        case .experience: "假设"
        case .conclusion: ""
        }
    }

    private var color: Color {
        switch kind {
        case .constraint, .rejection: Color.statusWarning
        case .experience: Color.brand600
        case .conclusion: .clear
        }
    }

    private var surface: Color {
        switch kind {
        case .constraint, .rejection: Color.statusWarningSurface1
        case .experience: Color.brandPopup
        case .conclusion: .clear
        }
    }

    var body: some View {
        if kind != .conclusion {
            Text(title)
                .font(DS.Font.bodyXS)
                .foregroundStyle(color)
                .padding(.horizontal, DS.Spacing.s6)
                .padding(.vertical, DS.Spacing.s2)
                .background(Capsule().fill(surface))
                .help(
                    kind == .experience
                        ? "假设：尚未验证的经验，注入时可被裁剪，验证后可提升为全局"
                        : "硬边界：注入时永不裁剪，回答不得与之矛盾"
                )
        }
    }
}

// MARK: - scope 分组头（项目=primary 全局=success）
// internal：设置弹框「记忆」页复用

struct MemoryScopeHeader: View {
    let title: String
    let scope: MemoryEntry.Scope

    private var badgeText: String {
        switch scope {
        case .project: "项目"
        case .global: "全局"
        }
    }

    private var color: Color {
        switch scope {
        case .project: Color.statusPrimary
        case .global: Color.statusSuccess
        }
    }

    private var surface: Color {
        switch scope {
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
