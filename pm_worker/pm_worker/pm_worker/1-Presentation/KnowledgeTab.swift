//
//  KnowledgeTab.swift
//  pm_worker
//
//  右栏「知识点」Tab 完整版（Task 4.6）：query 检索（Retriever，scope 隔离 +
//  trace）+ 命中卡列表（scope 徽章 / 相关度 / 注记条数；点击展开注记时间线）
//  + 主动推荐（采纳 / 跳过，已拒折叠保留）+ 跨项目过滤说明行。
//

import SwiftUI
import GRDB
import Combine

// MARK: - 手动检索 trace 共享（知识点 Tab 产出 → 开发者检查器 ⌘D 展示）

/// 知识点 Tab 最近一次手动检索 trace（AppModel 禁改，轻量单例跨窗口共享）。
/// 进程级存活；开发者检查器「检索 trace」区实时联动读取。
@MainActor
final class SearchTraceLog: ObservableObject {
    @Published private(set) var last: RetrievalTrace?

    static let shared = SearchTraceLog()

    /// Xcode 26 默认 MainActor：ObservableObject 若被销毁须显式退出隔离路径
    ///（单例实际不销毁，防御性声明）。
    nonisolated deinit {}

    private init() {}

    func record(_ trace: RetrievalTrace) {
        last = trace
    }
}

// MARK: - 共享小组件

/// scope 徽章：project=品牌紫 global=绿（E12 命中来源可观测；原型 .ds-tag 变体）。
struct ScopeBadge: View {
    let scope: String

    var body: some View {
        DSTag(
            title: scope == "global" ? "全局" : "项目",
            variant: scope == "global" ? .success : .brand
        )
    }
}

/// 实战注记时间线（读卡片 .md → MethodologyCard.parse → annotations
/// 逐条「日期 · 项目：注记」；知识点 Tab 与卡片库共用）。
struct AnnotationTimeline: View {
    let card: MethodologyCard?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Text("实战注记时间线（append-only · 只增不覆盖）")
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
            if let card, !card.annotations.isEmpty {
                ForEach(Array(card.annotations.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: DS.Spacing.s6) {
                        Circle()
                            .fill(Color.brand600)
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        Text("\(note.date) · \(note.project)：\(note.note)")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if card != nil {
                Text("暂无实战注记（方法论被采纳 / 合并时自动追加，越用越厚）")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
            } else {
                Text("卡片文件读取失败或已被移除（索引行仍在）")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.statusWarning)
            }
        }
        .padding(.top, DS.Spacing.s2)
    }
}

// MARK: - 知识点 Tab

struct KnowledgeTab: View {
    @EnvironmentObject private var model: AppModel

    @State private var query = ""
    @State private var searching = false
    @State private var trace: RetrievalTrace?
    @State private var searchError: String?
    /// 命中卡的注记条数（knowledge_points.annotation_count，检索后一次性回查）。
    @State private var annotationCounts: [String: Int] = [:]
    /// 展开的命中卡 id + 按需读 .md 解析出的卡片（注记时间线数据源）。
    @State private var expandedHitId: String?
    @State private var hitCards: [String: MethodologyCard] = [:]
    /// 已拒推荐标题缓存（id → title；model.rejectedCards 只存 id）。
    @State private var rejectedTitles: [String: String] = [:]
    @State private var showRejected = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            DSDivider()
            content
        }
        .onAppear {
            syncRejectedTitles(model.rejectedCards)
        }
        .onChange(of: model.rejectedCards) { _, rejected in
            syncRejectedTitles(rejected)
        }
    }

    // MARK: 检索框（Enter / 按钮双入口）

    private var searchField: some View {
        HStack(spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.search, size: 13)
                    .foregroundStyle(Color.ink300)
                TextField("检索方法论卡与技能…", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodySM)
                    .onSubmit(runSearch)
                if searching {
                    DSSpinner()
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        trace = nil
                        searchError = nil
                    } label: {
                        DSIcon(.close, size: 16)
                            .foregroundStyle(Color.ink300)
                    }
                    .buttonStyle(.plain)
                    .help("清空检索结果")
                }
            }
            .dsInput()
            Button("检索", action: runSearch)
                .buttonStyle(.ds(.primary, size: .sm))
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s8)
    }

    // MARK: 主体（主动推荐区常驻 + 检索结果区）

    @ViewBuilder
    private var content: some View {
        if searching {
            VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                DSSkeletonTitle()
                DSSkeletonLine()
                DSSkeletonLine(width: 220)
                DSSkeletonLine()
                DSSkeletonLine(width: 160)
            }
            .padding(DS.Spacing.s16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.s10) {
                    // 主动推荐（阶段开始扫描卡片库；与检索结果独立展示）
                    if !model.recommendations.isEmpty || !model.rejectedCards.isEmpty {
                        recommendationSection
                    }

                    if let searchError {
                        DSEmptyState(
                            icon: .warningFill,
                            title: "检索失败",
                            description: searchError
                        )
                    } else if let trace {
                        resultSection(trace: trace)
                    } else {
                        DSEmptyState(
                            icon: .mem,
                            title: "检索后显示命中卡",
                            description: "输入关键词检索方法论卡与技能（scope 隔离：全局 + 当前项目）。"
                        )
                    }
                }
                .padding(DS.Spacing.s12)
            }
        }
    }

    // MARK: 检索结果（命中卡 + 技能命中摘要 + 过滤说明 + 耗时）

    private func resultSection(trace: RetrievalTrace) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            let cardHits = trace.hits.filter { $0.library == .cards }
            let skillHits = trace.hits.filter { $0.library == .skills }

            // scope 隔离说明行（E12：跨项目内容被检索层过滤）
            if trace.filteredCrossProject > 0 {
                Label {
                    Text("已过滤 \(trace.filteredCrossProject) 条跨项目内容（scope 隔离：只检索全局与当前项目卡片）")
                } icon: {
                    DSIcon(.barList, size: 14)
                }
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.statusWarning)
                .padding(DS.Spacing.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .fill(Color.statusWarningSurface1)
                )
            }

            if cardHits.isEmpty && skillHits.isEmpty {
                Text("无命中（相关度阈值：卡 > 30% · 技能 > 35%）")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .padding(.vertical, DS.Spacing.s16)
                    .frame(maxWidth: .infinity)
            }

            ForEach(cardHits) { hit in
                HitCardRow(
                    hit: hit,
                    annotationCount: annotationCounts[hit.id] ?? 0,
                    expanded: expandedHitId == hit.id,
                    card: hitCards[hit.id],
                    onToggle: { toggleHit(hit) }
                )
            }

            if !skillHits.isEmpty {
                Text("技能命中（仅 when_to_use 摘要，正文按需加载）")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink500)
                    .padding(.top, DS.Spacing.s4)
                ForEach(skillHits) { hit in
                    SkillHitRow(hit: hit)
                }
            }

            Text("检索耗时 \(trace.durationMs)ms · 命中 \(trace.hits.count) 条")
                .font(DS.Font.bodyXS)
                .monospacedDigit()
                .foregroundStyle(Color.ink300)
        }
    }

    // MARK: 主动推荐区（理由 + 采纳/跳过；已拒折叠保留）

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.aiStars, size: 11)
                    .foregroundStyle(Color.ink700)
                Text("主动推荐 · \(model.recommendations.count) 个（本阶段可能用得上）")
                    .font(DS.Font.headingXS)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink900)
                Spacer()
                if !model.rejectedCards.isEmpty {
                    Button {
                        withAnimation { showRejected.toggle() }
                    } label: {
                        Text(showRejected ? "收起已跳过" : "已跳过 \(model.rejectedCards.count) 个")
                            .font(DS.Font.bodyXS)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink500)
                    }
                    .buttonStyle(.borderless)
                }
            }

            ForEach(model.recommendations) { rec in
                recommendationRow(rec)
            }

            if showRejected {
                ForEach(model.rejectedCards.sorted(), id: \.self) { id in
                    HStack(spacing: DS.Spacing.s6) {
                        DSIcon(.circleX, size: 11)
                            .foregroundStyle(Color.ink300)
                        Text(rejectedTitles[id] ?? id)
                            .font(DS.Font.bodyXS)
                            .strikethrough()
                            .foregroundStyle(Color.ink500)
                            .lineLimit(1)
                        Spacer()
                        Text("本阶段不再推荐")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink300)
                    }
                    .padding(.horizontal, DS.Spacing.s8)
                    .padding(.vertical, DS.Spacing.s4)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.overlayL1)
                    )
                }
            }
        }
    }

    private func recommendationRow(_ rec: Recommender.Recommendation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s6) {
                ScopeBadge(scope: rec.scope)
                Text(rec.title)
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
            }
            Text(rec.reason)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("实战注记 \(rec.annotationCount) 条")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                Spacer()
                Button("采纳") {
                    model.adoptRecommendation(rec.id)
                }
                .buttonStyle(.ds(.brand, size: .sm))
                .help("采纳：卡片实战注记 +1（带项目出处与日期），并注入你的历史使用倾向")
                Button("跳过") {
                    // 先缓存标题再拒绝（rejectRecommendation 会把它移出推荐列表）
                    rejectedTitles[rec.id] = rec.title
                    model.rejectRecommendation(rec.id)
                }
                .buttonStyle(.ds(.ghost, size: .sm))
                .help("本阶段不再重复推荐该方法论")
            }
        }
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.brandPopup)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.brand600.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: 行为

    /// 检索（Retriever：scope 隔离 + 近重复去重 + 技能渐进披露；trace 记入共享日志）。
    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let database = model.database else { return }
        let retriever = Retriever(
            database: database,
            embedder: SettingsBackedEmbedder(settings: model.settings)
        )
        let project = model.pipeline.project
        searching = true
        searchError = nil
        Task {
            do {
                let result = try await retriever.search(query: text, project: project)
                SearchTraceLog.shared.record(result)
                trace = result
                loadAnnotationCounts(for: result)
                searching = false
            } catch {
                searchError = error.localizedDescription
                searching = false
            }
        }
    }

    /// 展开 / 收起命中卡；展开时按需读卡片 .md（MethodologyCard.parse）。
    private func toggleHit(_ hit: RetrievalHit) {
        if expandedHitId == hit.id {
            expandedHitId = nil
        } else {
            expandedHitId = hit.id
            loadCardFile(hit)
        }
    }

    private func loadCardFile(_ hit: RetrievalHit) {
        guard hitCards[hit.id] == nil,
              let url = Self.locateCardFile(
                  id: hit.id, scopeId: hit.scopeId, project: model.pipeline.project
              ),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let card = MethodologyCard.parse(markdown: text)
        else { return }
        hitCards[hit.id] = card
    }

    /// 命中卡注记条数回查（knowledge_points.annotation_count；同步小查询，
    /// 与 AppModel.cardCandidates 同模式）。
    private func loadAnnotationCounts(for trace: RetrievalTrace) {
        let cardIds = trace.hits.filter { $0.library == .cards }.map(\.id)
        guard !cardIds.isEmpty, let database = model.database else { return }
        let placeholders = cardIds.map { _ in "?" }.joined(separator: ",")
        let counts: [String: Int] = (try? database.dbQueue.read { db in
            var result: [String: Int] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT id, annotation_count FROM knowledge_points WHERE id IN (\(placeholders))",
                arguments: StatementArguments(cardIds)
            ) {
                result[row["id"]] = row["annotation_count"]
            }
            return result
        }) ?? [:]
        annotationCounts = counts
    }

    /// 已拒标题同步：本 Tab 跳过的已缓存；其余（对话视图跳过的）从索引库回查；
    /// 阶段切换清空拒绝记录时同步清缓存。
    private func syncRejectedTitles(_ rejected: Set<String>) {
        rejectedTitles = rejectedTitles.filter { rejected.contains($0.key) }
        let missing = rejected.filter { rejectedTitles[$0] == nil }
        guard !missing.isEmpty, let database = model.database else { return }
        let ids = Array(missing)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let titles: [String: String] = (try? database.dbQueue.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT id, content FROM knowledge_points WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            ) {
                result[row["id"]] = Recommender.title(of: row["content"])
            }
            return result
        }) ?? [:]
        for (id, title) in titles {
            rejectedTitles[id] = title
        }
    }

    /// 卡片文件定位：全局 cards/ → 项目 knowledge/（与 AppModel.locateCard 同规则）。
    nonisolated private static func locateCardFile(
        id: String, scopeId: String, project: String
    ) -> URL? {
        let fm = FileManager.default
        let global = PMAgentStore.cardsDir.appendingPathComponent("\(id).md")
        if fm.fileExists(atPath: global.path) { return global }
        let localProject = scopeId.isEmpty ? project : scopeId
        guard !localProject.isEmpty else { return nil }
        let local = PMAgentStore.projectURL(localProject)
            .appendingPathComponent("knowledge/\(id).md")
        return fm.fileExists(atPath: local.path) ? local : nil
    }

}

// MARK: - 命中卡行（点击展开注记时间线）

private struct HitCardRow: View {
    let hit: RetrievalHit
    let annotationCount: Int
    let expanded: Bool
    let card: MethodologyCard?
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Button(action: onToggle) {
                HStack(spacing: DS.Spacing.s6) {
                    DSIcon(expanded ? .down : .collapseTriangle, size: 11)
                        .foregroundStyle(Color.ink300)
                    Text(Recommender.title(of: hit.content))
                        .font(DS.Font.bodyMDStrong)
                        .foregroundStyle(Color.ink900)
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.s6)
                    ScopeBadge(scope: hit.scope)
                    Text("\(Int((hit.score * 100).rounded()))%")
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.statusSuccess)
                    Label { Text("\(annotationCount)") } icon: { DSIcon(.note, size: 14) }
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .help("实战注记 \(annotationCount) 条")
                }
            }
            .buttonStyle(.plain)
            Text(hit.content)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .lineLimit(expanded ? nil : 2)
            if expanded {
                AnnotationTimeline(card: card)
            }
        }
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.overlayL1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }
}

// MARK: - 技能命中行（when_to_use 摘要；正文渐进式披露不在此展示）

private struct SkillHitRow: View {
    let hit: RetrievalHit

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.puzzle, size: 11)
                    .foregroundStyle(Color.brandAccent)
                Text(hit.id)
                    .font(DS.Font.bodyMD)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.s6)
                Text("\(Int((hit.score * 100).rounded()))%")
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.statusSuccess)
            }
            Text(hit.content)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .lineLimit(2)
        }
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.brandPopup.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }
}
