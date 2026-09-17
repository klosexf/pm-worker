//
//  SkillLibraryView.swift
//  pm_worker
//
//  技能库（Task 4.7）：skills 表浏览 + 搜索 + 详情弹窗 + enabled 开关直写表。
//  布局 v2（参考图转译）：hero 头部（衬线大字 + 统计）+ 行卡片列表——
//  标题 + 场景两行 / 开关（命中徽章只在详情弹窗展示），hover 反馈。
//  原型 v4：技能库为独立整页单栏——技能点击以 Modal 展示详情
//  （无详情分栏、不挂右栏 Inspector）。索引库是投影，文件系统是
//  唯一事实源——详情正文按需读 skills/*.md。
//

import SwiftUI
import GRDB

/// skills 行投影（JSON 数组字段已展开；跨异步边界 → nonisolated + Sendable）。
nonisolated struct SkillLibraryRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let whenToUse: String
    let bestFor: [String]
    let tags: [String]
    let pitfalls: [String]
    let docPath: String
    var hitCount: Int
    var enabled: Bool
}

struct SkillLibraryView: View {
    @EnvironmentObject private var model: AppModel

    @State private var rows: [SkillLibraryRow] = []
    @State private var searchText = ""
    @State private var loading = false
    /// 详情弹窗目标技能 id（nil = 未打开）。
    @State private var selectedId: String?
    /// 弹窗技能正文（读 .md 解析；nil = 加载中或读取失败）。
    @State private var detailBody: String?
    @State private var detailURL: URL?

    var body: some View {
        scrollPane
            .frame(minWidth: 480, minHeight: 480)
            .task { await load() }
            .task(id: selectedId) { await loadDetail() }
            .sheet(isPresented: Binding(
                get: { selectedId != nil },
                set: { if !$0 { selectedId = nil } }
            )) {
                if let row = selectedRow {
                    SkillDetailSheet(
                        row: row,
                        detailBody: detailBody,
                        detailURL: detailURL,
                        onClose: { selectedId = nil }
                    )
                }
            }
    }

    // MARK: - 统计（副标题：总数 / 已启用）

    private var enabledCount: Int { rows.filter(\.enabled).count }

    // MARK: - 页面（hero 头部 + 行卡片列表，内容区 max 920 居中）

    private var scrollPane: some View {
        DSScroll {
            VStack(spacing: DS.Spacing.s16) {
                hero
                searchField
                contentArea
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.top, DS.Spacing.s24)
            .padding(.bottom, DS.Spacing.s32)
            .frame(maxWidth: 920, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfaceSecondary)
    }

    /// hero：衬线大字标题 + 统计副标题（左）· 重新加载（右）。
    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s12) {
            VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                Text("技能库")
                    .font(DS.Font.displayMD)
                    .foregroundStyle(Color.ink900)
                Text(rows.isEmpty
                    ? "skills/ 目录扫描后在此管理"
                    : "\(rows.count) 个技能 · \(enabledCount) 个已启用")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
            }
            Spacer(minLength: 0)
            Button {
                Task { await load() }
            } label: {
                Label { Text("重新加载") } icon: { DSIcon(.refresh, size: 14) }
            }
            .buttonStyle(.ds(.secondary, size: .sm))
            .help("从索引库重新读取全部技能")
        }
    }

    private var searchField: some View {
        HStack(spacing: DS.Spacing.s8) {
            DSIcon(.search, size: 13)
                .foregroundStyle(Color.ink300)
            TextField("搜索名称 / 场景 / 标签", text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Font.bodySM)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    DSIcon(.close, size: 11)
                        .foregroundStyle(Color.ink300)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .dsInput()
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    @ViewBuilder
    private var contentArea: some View {
        if loading && rows.isEmpty {
            // 原型 .ds-skeleton：行卡片占位（1.6s 流光）
            VStack(spacing: DS.Spacing.s8) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: DS.Spacing.s12) {
                        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                            DSSkeletonLine(width: 160)
                            DSSkeletonLine(width: 280)
                        }
                        Spacer()
                        DSSkeletonLine(width: 32)
                    }
                    .padding(DS.Spacing.s16)
                    .background(
                        Color.surfaceBase,
                        in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
                    )
                }
            }
        } else if rows.isEmpty {
            DSEmptyState(
                icon: .puzzle,
                title: "技能库为空",
                description: "skills/ 目录扫描后在此管理"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.s64)
        } else if filteredRows.isEmpty {
            DSEmptyState(
                icon: .search,
                title: "无匹配技能",
                description: "换个关键词试试"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.s64)
        } else {
            LazyVStack(spacing: DS.Spacing.s8) {
                ForEach(filteredRows) { row in
                    SkillCardRow(row: row) { enabled in
                        setEnabled(row.id, enabled)
                    } onOpen: {
                        selectedId = row.id
                    }
                }
            }
        }
    }

    // MARK: - 技能列表（搜索 + enabled 开关）

    private var filteredRows: [SkillLibraryRow] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.whenToUse.localizedCaseInsensitiveContains(keyword)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }

    private var selectedRow: SkillLibraryRow? {
        rows.first { $0.id == selectedId }
    }

    // MARK: - 行为（enabled 开关直写 skills 表）

    /// 乐观更新 UI；写库失败回滚（skills 表只是索引投影，事实源在 skills/*.md）。
    private func setEnabled(_ id: String, _ enabled: Bool) {
        guard let database = model.database else { return }
        let original = rows
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].enabled = enabled
        }
        Task {
            do {
                try await database.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE skills SET enabled = ? WHERE id = ?",
                        arguments: [enabled, id]
                    )
                }
            } catch {
                rows = original
            }
        }
    }

    // MARK: - 数据（skills 全表，异步读 + Sendable 投影）

    private func load() async {
        guard let database = model.database else { return }
        loading = true
        let fetched: [SkillLibraryRow] = (try? await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, type, when_to_use, best_for, tags,
                           pitfalls, doc_path, hit_count, enabled
                    FROM skills
                    ORDER BY hit_count DESC, name
                    """
            )
            .map { row in
                SkillLibraryRow(
                    id: row["id"],
                    name: row["name"],
                    type: row["type"],
                    whenToUse: row["when_to_use"],
                    bestFor: Self.strings(row["best_for"] as String?),
                    tags: Self.strings(row["tags"] as String?),
                    pitfalls: Self.strings(row["pitfalls"] as String?),
                    docPath: row["doc_path"],
                    hitCount: row["hit_count"],
                    enabled: row["enabled"]
                )
            }
        }) ?? []
        rows = fetched
        loading = false
    }

    /// 按需读技能 .md 正文（SkillFrontMatterParser：front-matter + 正文）。
    private func loadDetail() async {
        guard let id = selectedId, let row = rows.first(where: { $0.id == id }) else {
            detailBody = nil
            detailURL = nil
            return
        }
        detailBody = nil
        detailURL = nil
        // doc_path 优先（索引记录的文件位置）；缺失回退 skills/{id}.md
        let fm = FileManager.default
        var url = URL(fileURLWithPath: row.docPath)
        if !fm.fileExists(atPath: url.path) {
            url = PMAgentStore.skillsDir.appendingPathComponent("\(row.id).md")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let skill = SkillFrontMatterParser.parse(text)
        else { return }
        detailBody = skill.body
        detailURL = url
    }

    /// JSON 数组列 → [String]（NULL / 解析失败回空数组——与 PitfallsRouter 同口径）。
    nonisolated private static func strings(_ json: String?) -> [String] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }
}

// MARK: - 技能行卡片（标题/场景 + 开关；点击开详情；命中数只在详情弹窗展示）

private struct SkillCardRow: View {
    let row: SkillLibraryRow
    let onToggleEnabled: (Bool) -> Void
    let onOpen: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.s12) {
            // 标题 + 场景两行（窄窗自适应：文本区可无限收缩）
            VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                Text(row.name)
                    .font(DS.Font.bodyBaseStrong)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
                Text(row.whenToUse)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .dsCaptionType(size: 13)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !row.tags.isEmpty {
                    Text(row.tags.prefix(3).joined(separator: " · "))
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            // 右侧操作组：开关（命中徽章只在详情弹窗展示）
            DSSwitch(isOn: Binding(get: { row.enabled }, set: onToggleEnabled))
                .help(row.enabled ? "已启用（参与检索）" : "已停用（不参与检索）")

            DSIcon(.arrowRight, size: 13)
                .foregroundStyle(hovered ? Color.ink500 : Color.ink300)
        }
        .padding(DS.Spacing.s16)
        .background(
            Color.surfaceBase,
            in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(hovered ? Color.borderL2 : Color.borderL1, lineWidth: 1)
        )
        .opacity(row.enabled ? 1 : 0.62)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
        .onHover { hovered = $0 }
        .onTapGesture { onOpen() }
        .animation(DS.Motion.springFast, value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("打开技能详情"))
    }
}

// MARK: - 技能详情弹窗（原型 Modal：元信息 + 四字段 + 正文 Markdown）

private struct SkillDetailSheet: View {
    let row: SkillLibraryRow
    let detailBody: String?
    let detailURL: URL?
    let onClose: () -> Void

    var body: some View {
        DSDialog(
            title: row.name,
            icon: DSIcon.Name.puzzle,
            onClose: onClose,
            width: 560
        ) {
            DSScroll {
                VStack(alignment: .leading, spacing: DS.Spacing.s16) {
                    // 元信息：type 徽章 + 命中计数
                    HStack(spacing: DS.Spacing.s10) {
                        TypeBadge(type: row.type)
                        Label { Text("命中 \(row.hitCount)") } icon: { DSIcon(.bolt, size: 14) }
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        Spacer()
                        Text(row.id)
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink300)
                    }
                    // 四字段：when_to_use / best_for / tags / pitfalls
                    VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                        fieldBlock("何时使用") {
                            Text(row.whenToUse)
                                .font(DS.Font.bodyMD)
                                .foregroundStyle(Color.ink700)
                        }
                        if !row.bestFor.isEmpty {
                            fieldBlock("典型场景") {
                                bulletList(row.bestFor)
                            }
                        }
                        if !row.tags.isEmpty {
                            fieldBlock("标签") {
                                Text(row.tags.joined(separator: " · "))
                                    .font(DS.Font.bodySM)
                                    .foregroundStyle(Color.ink500)
                            }
                        }
                        if !row.pitfalls.isEmpty {
                            fieldBlock("反模式（漏项雷达信号）") {
                                bulletList(row.pitfalls)
                            }
                        }
                    }
                    // 正文（Markdown 渲染；读取失败给出行内说明）
                    VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                        Text("正文")
                            .font(DS.Font.bodyXSStrong)
                            .foregroundStyle(Color.ink500)
                        if let detailBody {
                            MarkdownText(detailBody, bodySize: 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("正文文件缺失或不可读（可在 skills/ 目录检查技能文件）")
                                .font(DS.Font.bodySM)
                                .foregroundStyle(Color.ink300)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 440)
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("关闭") {
                    onClose()
                }
                .buttonStyle(.ds(.ghost))
                .keyboardShortcut(.cancelAction)

                if let detailURL {
                    Button {
                        NSWorkspace.shared.open(detailURL)
                    } label: {
                        Label { Text("打开技能文件") } icon: { DSIcon(.arrowUpRight, size: 14) }
                    }
                    .buttonStyle(.ds(.secondary))
                    .help(detailURL.path)
                }
            }
        }
        .dsDismissOnOutsideTap { onClose() }  // 点击面板外关闭（与关闭钮同动作）
    }

    /// 字段区块：小标签 + 内容（对齐卡片详情「正文」块的排版）。
    private func fieldBlock(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            Text(title)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
            content()
        }
    }

    /// 条目列表（best_for / pitfalls：短横列表，正文档字号）。
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: DS.Spacing.s6) {
                    Text("·")
                        .font(DS.Font.bodyMD)
                        .foregroundStyle(Color.ink500)
                    Text(item)
                        .font(DS.Font.bodyMD)
                        .foregroundStyle(Color.ink700)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - type 徽章（component=蓝 interactive=紫）

private struct TypeBadge: View {
    let type: String

    private var color: Color {
        type == "interactive" ? Color.brand600 : Color.statusPrimary
    }

    private var surface: Color {
        type == "interactive" ? Color.brandPopup : Color.statusPrimarySurface1
    }

    var body: some View {
        Text(type == "interactive" ? "interactive" : "component")
            .font(DS.Font.bodyXS)
            .foregroundStyle(color)
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s2)
            .background(Capsule().fill(surface))
    }
}
