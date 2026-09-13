//
//  CardLibraryView.swift
//  pm_worker
//
//  卡片库（Task 4.7）：knowledge_points 全表浏览 + 搜索 + 详情弹窗
//  （正文 / 注记时间线 / 来源 source_ref 跳转）。原型 v4：知识库为独立
//  整页单栏——卡片点击以 Modal 展示详情（无分栏、不挂右栏 Inspector）。
//  索引库是投影，文件系统是唯一事实源——注记时间线按需读卡片 .md。
//

import SwiftUI
import GRDB

/// knowledge_points 行投影（跨异步边界 → nonisolated + Sendable）。
nonisolated struct CardLibraryRow: Identifiable, Equatable, Sendable {
    let id: String
    /// 归属项目（空 = 全局）
    let projectId: String
    let title: String
    let content: String
    let annotationCount: Int
    let confidence: Double
    let supersededBy: String?
    let createdAt: String
}

struct CardLibraryView: View {
    @EnvironmentObject private var model: AppModel

    @State private var rows: [CardLibraryRow] = []
    @State private var searchText = ""
    /// 详情弹窗目标卡片 id（nil = 未打开）。
    @State private var selectedId: String?
    /// 弹窗卡片详情（读 .md 文件解析；nil = 加载中或读取失败）。
    @State private var detail: MethodologyCard?
    @State private var detailURL: URL?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(.search, size: 13)
                    .foregroundStyle(Color.ink300)
                TextField("搜索标题 / 正文 / 项目", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodySM)
            }
            .dsInput()
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s10)
            .background(Color.surfaceSecondary)
            DSDivider()
            if loading && rows.isEmpty {
                // 原型 .ds-skeleton：标题行 + 疏密行占位（1.6s 流光）
                VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                    DSSkeletonTitle()
                    DSSkeletonLine()
                    DSSkeletonLine(width: 220)
                    DSSkeletonLine()
                    DSSkeletonLine(width: 160)
                    DSSkeletonLine()
                }
                .padding(DS.Spacing.s16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if filteredRows.isEmpty {
                DSEmptyState(
                    icon: .document,
                    title: rows.isEmpty ? "卡片库为空" : "无匹配卡片",
                    description: rows.isEmpty
                        ? "「这条记下来」沉淀方法论后在此管理"
                        : "换个关键词试试"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRows) { row in
                        Button {
                            selectedId = row.id
                        } label: {
                            CardRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color.surfaceSecondary)
            }
        }
        .background(Color.surfaceSecondary)
        .frame(minWidth: 480, minHeight: 480)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Label { Text("重新加载") } icon: { DSIcon(.refresh, size: 14) }
            }
            .buttonStyle(.ds(.secondary, size: .sm))
            .help("从索引库重新读取全部卡片")
        }
        .task { await load() }
        .task(id: selectedId) { await loadDetail() }
        .sheet(isPresented: Binding(
            get: { selectedId != nil },
            set: { if !$0 { selectedId = nil } }
        )) {
            if let row = selectedRow {
                CardDetailSheet(
                    row: row,
                    detail: detail,
                    detailURL: detailURL,
                    onClose: { selectedId = nil }
                )
            }
        }
    }

    // MARK: - 卡片列表（搜索 + 全表）

    private var filteredRows: [CardLibraryRow] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.content.localizedCaseInsensitiveContains(keyword)
                || $0.projectId.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var selectedRow: CardLibraryRow? {
        rows.first { $0.id == selectedId }
    }

    // MARK: - 数据（knowledge_points 全表，异步读 + Sendable 投影）

    private func load() async {
        guard let database = model.database else { return }
        loading = true
        let fetched: [CardLibraryRow] = (try? await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, project_id, content, annotation_count, confidence,
                           superseded_by, created_at
                    FROM knowledge_points
                    ORDER BY created_at DESC
                    """
            )
            .map { row in
                CardLibraryRow(
                    id: row["id"],
                    projectId: row["project_id"],
                    title: Recommender.title(of: row["content"]),
                    content: row["content"],
                    annotationCount: row["annotation_count"],
                    confidence: row["confidence"],
                    supersededBy: row["superseded_by"] as String?,
                    createdAt: row["created_at"]
                )
            }
        }) ?? []
        rows = fetched
        loading = false
    }

    /// 按需读卡片 .md（MethodologyCard.parse：正文 + 注记 + 来源）。
    private func loadDetail() async {
        guard let id = selectedId, let row = rows.first(where: { $0.id == id }) else {
            detail = nil
            detailURL = nil
            return
        }
        detail = nil
        detailURL = nil
        if let url = Self.locateCardFile(id: id, projectId: row.projectId),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let card = MethodologyCard.parse(markdown: text) {
            detail = card
            detailURL = url
        }
    }

    /// 卡片文件定位：全局 cards/ → 项目 knowledge/（索引 project_id 即归属项目）。
    nonisolated private static func locateCardFile(id: String, projectId: String) -> URL? {
        let fm = FileManager.default
        let global = PMAgentStore.cardsDir.appendingPathComponent("\(id).md")
        if fm.fileExists(atPath: global.path) { return global }
        guard !projectId.isEmpty else { return nil }
        let local = PMAgentStore.projectURL(projectId)
            .appendingPathComponent("knowledge/\(id).md")
        return fm.fileExists(atPath: local.path) ? local : nil
    }
}

// MARK: - 卡片行（标题 + scope + 注记数 + 置信度 + id）

private struct CardRowView: View {
    let row: CardLibraryRow

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s3) {
            HStack(spacing: DS.Spacing.s6) {
                Text(row.title)
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
                if row.supersededBy != nil {
                    SupersededBadge()
                }
            }
            HStack(spacing: DS.Spacing.s8) {
                Text(row.projectId.isEmpty ? "全局" : row.projectId)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(
                        row.projectId.isEmpty ? Color.ink500 : Color.statusPrimary
                    )
                Text("注记 \(row.annotationCount)")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Text("置信度 \(Int((row.confidence * 100).rounded()))%")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Spacer()
                Text(row.id)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
            }
        }
        .padding(.vertical, DS.Spacing.s2)
        .contentShape(Rectangle())
    }
}

// MARK: - 卡片详情弹窗（原型 Modal：元信息 + 正文 + 注记时间线 + 来源跳转）

private struct CardDetailSheet: View {
    let row: CardLibraryRow
    let detail: MethodologyCard?
    let detailURL: URL?
    let onClose: () -> Void

    var body: some View {
        DSDialog(
            title: row.title,
            icon: DSIcon.Name.books,
            onClose: onClose,
            width: 560
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.s16) {
                    HStack(spacing: DS.Spacing.s10) {
                        if row.supersededBy != nil {
                            SupersededBadge()
                        }
                        Text(row.projectId.isEmpty ? "全局" : "项目 · \(row.projectId)")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(
                                row.projectId.isEmpty ? Color.ink500 : Color.statusPrimary
                            )
                        Text("注记 \(row.annotationCount) 条")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        Text("置信度 \(Int((row.confidence * 100).rounded()))%")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        Spacer()
                        Text(row.id)
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink300)
                    }
                    if let detail {
                        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                            Text("正文")
                                .font(DS.Font.bodyXSStrong)
                                .foregroundStyle(Color.ink500)
                            Text(detail.content)
                                .font(DS.Font.bodyMD)
                                .foregroundStyle(Color.ink700)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        AnnotationTimeline(card: detail)
                    } else {
                        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                            DSSkeletonTitle()
                            DSSkeletonLine()
                            DSSkeletonLine(width: 240)
                            DSSkeletonLine()
                        }
                        .padding(.top, DS.Spacing.s8)
                    }
                    // 来源 source_ref + 文件跳转（NSWorkspace.open 打开卡片 .md）
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                            Text("来源 source_ref")
                                .font(DS.Font.bodyXSStrong)
                                .foregroundStyle(Color.ink500)
                            let sourceRef = detail?.sourceRef ?? ""
                            Text(sourceRef.isEmpty ? "（无出处记录）" : sourceRef)
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink500)
                        }
                        Spacer()
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
                        Label { Text("打开卡片文件") } icon: { DSIcon(.arrowUpRight, size: 14) }
                    }
                    .buttonStyle(.ds(.secondary))
                    .help(detailURL.path)
                }
            }
        }
        .padding(DS.Spacing.s16)
        .presentationBackground(Color.overlayL4)
    }
}

// MARK: - 「已让位」胶囊（superseded：ink300 弱化）

private struct SupersededBadge: View {
    var body: some View {
        Text("已让位")
            .font(DS.Font.bodyXS)
            .foregroundStyle(Color.ink300)
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s2)
            .background(Capsule().fill(Color.overlayL1))
    }
}
