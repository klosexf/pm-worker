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
    @State private var loading = false
    /// 聚光灯处置统计（结算条用；推荐列表清空后仍有「都看完了」可看）。
    @State private var hasTriaged = false
    @State private var adoptedCount = 0
    @State private var skippedCount = 0
    /// 语义检索（2026-09-17 钦定：Retriever 自右栏知识点 Tab 收口至此）。
    @State private var searchTrace: RetrievalTrace?
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        VStack(spacing: 0) {
            searchField
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
            } else if let searchTrace {
                searchResultSection(searchTrace)
            } else if searching {
                VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                    DSSkeletonTitle()
                    DSSkeletonLine()
                    DSSkeletonLine(width: 220)
                    DSSkeletonLine()
                }
                .padding(DS.Spacing.s16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if searchError != nil {
                DSEmptyState(
                    icon: .warningFill,
                    title: "检索失败",
                    description: searchError ?? ""
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRows.isEmpty && model.recommendations.isEmpty {
                DSEmptyState(
                    icon: .document,
                    title: rows.isEmpty ? "卡片库为空" : "无匹配卡片",
                    description: rows.isEmpty
                        ? "「这条记下来」沉淀方法论后在此管理"
                        : "换个关键词试试"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // DSScroll + LazyVStack（2026-09-17 由 List 迁移）：List 的原生
                // 玻璃轨道滚动条压不住，换 DSScroll 统一细胶囊
                DSScroll {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.s8) {
                        // 聚光灯推荐区（2026-09-17 钦定方案 B：推荐收口到知识库整页）
                        if !model.recommendations.isEmpty {
                            SpotlightSection(
                                recommendations: model.recommendations,
                                project: model.pipeline.project,
                                onAdopt: { id in
                                    adoptedCount += 1
                                    hasTriaged = true
                                    model.adoptRecommendation(id)
                                },
                                onReject: { id in
                                    skippedCount += 1
                                    hasTriaged = true
                                    model.rejectRecommendation(id)
                                },
                                onOpenDetail: { selectedId = $0 }
                            )
                        } else if hasTriaged {
                            SettlementBanner(adopted: adoptedCount, skipped: skippedCount)
                        }

                        // 节标签：聚光灯与全表之间立一堵语义墙（hero 也是卡，
                        // 不标注会误读成同一堆）
                        if !filteredRows.isEmpty {
                            Text("全部卡片 · \(filteredRows.count)")
                                .font(DS.Font.bodyXSStrong)
                                .foregroundStyle(Color.ink500)
                                .padding(.top, DS.Spacing.s8)
                        }

                        ForEach(filteredRows) { row in
                            Button {
                                selectedId = row.id
                            } label: {
                                CardRowView(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // List 侧栏样式默认 ~10pt 行内衬，此处显式补回
                    // （2026-09-17 呼吸感改版：页边距 12→16，上下留白加厚）
                    .padding(.horizontal, DS.Spacing.s16)
                    .padding(.top, DS.Spacing.s12)
                    .padding(.bottom, DS.Spacing.s20)
                }
            }
        }
        .background(Color.surfaceSecondary)
        .frame(minWidth: 480, minHeight: 480)
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
                    recommendation: model.recommendations.first { $0.id == row.id },
                    onClose: { selectedId = nil }
                )
            }
        }
    }

    // MARK: - 搜索框（语义检索入口；Enter 触发，清空回全表）

    private var searchField: some View {
        HStack(spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.search, size: 13)
                    .foregroundStyle(Color.ink300)
                TextField("语义检索：用一句自然话找方法论…（回车检索）", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodySM)
                    .onSubmit(runSearch)
                if searching {
                    DSSpinner()
                } else if !searchText.isEmpty || searchTrace != nil {
                    Button {
                        searchText = ""
                        searchTrace = nil
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
            Button("检索") { runSearch() }
                .buttonStyle(.ds(.primary, size: .sm))
                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .background(Color.surfaceSecondary)
    }

    // MARK: - 语义检索结果（卡命中 + 技能命中 + 耗时；scope 隔离说明）

    private func searchResultSection(_ trace: RetrievalTrace) -> some View {
        let cardHits = trace.hits.filter { $0.library == .cards }
        let skillHits = trace.hits.filter { $0.library == .skills }
        return DSScroll {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.s8) {
                if trace.filteredCrossProject > 0 {
                    Label {
                        Text("已过滤 \(trace.filteredCrossProject) 条跨项目内容（scope 隔离：只检索全局与当前项目卡片）")
                    } icon: {
                        DSIcon(.barList, size: 14)
                    }
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.statusWarning)
                }

                if cardHits.isEmpty && skillHits.isEmpty {
                    Text("无命中（相关度阈值：卡 > 30% · 技能 > 35%）——也可以按关键词看下方全表")
                        .font(DS.Font.bodySM)
                        .foregroundStyle(Color.ink500)
                }

                ForEach(cardHits) { hit in
                    Button {
                        selectedId = hit.id
                    } label: {
                        HStack(spacing: DS.Spacing.s8) {
                            CardRowView(
                                row: CardLibraryRow(
                                    id: hit.id,
                                    projectId: hit.scopeId,
                                    title: Recommender.title(of: hit.content),
                                    content: hit.content,
                                    annotationCount: 0,
                                    confidence: 0,
                                    supersededBy: nil,
                                    createdAt: ""
                                )
                            )
                            Text("\(Int((hit.score * 100).rounded()))%")
                                .font(DS.Font.monoSM)
                                .foregroundStyle(Color.statusSuccess)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if !skillHits.isEmpty {
                    Text("技能命中（仅 when_to_use 摘要）")
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
            .padding(DS.Spacing.s12)
        }
    }

    /// 语义检索（Retriever：scope 隔离 + 近重复去重 + 技能渐进披露；trace 记入共享日志）。
    private func runSearch() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let database = model.database else { return }
        let retriever = Retriever(
            database: database,
            embedder: SettingsBackedEmbedder(settings: model.settings)
        )
        searching = true
        searchError = nil
        Task {
            do {
                let result = try await retriever.search(query: text, project: model.pipeline.project)
                SearchTraceLog.shared.record(result)
                searchTrace = result
                searching = false
            } catch {
                // 检索层不可用 → 字符串兜底（本地过滤在 filteredRows 既有逻辑）
                searchError = nil
                searchTrace = nil
                searching = false
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
            return
        }
        detail = nil
        if let url = Self.locateCardFile(id: id, projectId: row.projectId),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let card = MethodologyCard.parse(markdown: text) {
            detail = card
        }
    }

    /// 卡片文件定位：全局 cards/ → 项目 knowledge/（索引 project_id 即归属项目）。
    /// 对话区引用条 chip 点击按 id 开卡复用（internal）。
    nonisolated static func locateCardFile(id: String, projectId: String) -> URL? {
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
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
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
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.overlayL1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 卡片详情弹层（方案 B 卡面板：渐变 hero 面板 + 衬线标题 + 案例）

/// 卡片详情弹层（对话区「参考知识卡」chip 点击复用同一弹层）。
struct CardDetailSheet: View {
    let row: CardLibraryRow
    let detail: MethodologyCard?
    /// 聚光灯「看全文」打开时携带的推荐上下文（匹配度 / 为什么现在）；列表打开为 nil。
    let recommendation: Recommender.Recommendation?
    let onClose: () -> Void

    /// 固定高度视口（560×440）+ 内容内滚。
    /// 2026-09-17 二次修复：弃用「测量驱动高度」（视口 = min(自然高, 440)）——
    /// 该机制依赖测量反馈环，在真实 sheet 宿主环境里两次实测被锁死在压缩高
    /// （内容截断、无溢出、滚不了）；独立复现却正常，干扰因素无法观测，
    /// 故整体拆除测量机制改固定视口，结构上排除锁死可能。
    /// 代价：内容少时弹层不再贴合收缩（底部留白），换取确定性可滚。
    private let maxHeight: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            DSScroll {
                panel
            }
        }
        .frame(width: 560, height: maxHeight)
        .background(heroBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.brand600.opacity(0.30), lineWidth: 1)
        )
    }

    /// 方案 B 卡面板（档案分区块版）：hero 渐变壳不变，正文拆四类语义块——
    /// 是什么=brand 紫 / 为什么有效=success 绿 / 怎么用=info 蓝（适用边界并入
    /// 块内虚线脚注）/ 实战案例=alert 橙（来源同行）。信息类型靠「色签 + 语义
    /// 竖线」区分，不再共用一条灰阶文字墙（2026-09-17 排版三案 · 方案 B 钦定）。
    private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            HStack(spacing: DS.Spacing.s8) {
                ScopeBadge(scope: row.projectId.isEmpty ? "global" : "project")
                Text(row.projectId.isEmpty ? "通用 · 所有项目可用" : "本项目沉淀")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Spacer()
                if let recommendation {
                    MatchIndicator(score: recommendation.score)
                }
                DSDialogCloseButton(action: onClose)
            }

            Text(Recommender.title(of: detail?.content ?? row.content))
                .font(DS.Font.displayMD)
                .foregroundStyle(Color.ink900)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Spacing.s8) {
                if row.supersededBy != nil {
                    SupersededBadge()
                }
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

            let segments = Recommender.contentSegments(of: detail?.content ?? row.content)
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                if let definition = segments.definition, !definition.isEmpty {
                    DetailBlock(chipTitle: "是什么", variant: .brand) {
                        Text(definition)
                            .font(DS.Font.bodyMDStrong)
                            .foregroundStyle(Color.ink900)
                            .dsBodyType(size: 14)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let principle = detail?.principle, !principle.isEmpty {
                    DetailBlock(chipTitle: "为什么有效", variant: .success) {
                        blockBody(principle)
                    }
                }

                if segments.how != nil || segments.boundary != nil {
                    DetailBlock(chipTitle: "怎么用", variant: .info) {
                        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                            if let how = segments.how, !how.isEmpty {
                                blockBody(how)
                            }
                            if let boundary = segments.boundary, !boundary.isEmpty {
                                boundaryFootnote(boundary, showsRule: segments.how != nil && !segments.how!.isEmpty)
                            }
                        }
                    }
                }

                DetailBlock(chipTitle: "实战案例", variant: .alert, chipNote: "append-only · 只增不覆盖") {
                    VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                        AnnotationTimeline(card: detail, showsHeader: false)
                        HStack(alignment: .top, spacing: DS.Spacing.s10) {
                            Text("来源")
                                .font(DS.Font.bodyXSStrong)
                                .foregroundStyle(Color.ink300)
                            Text(detail?.sourceRef.isEmpty == false ? (detail?.sourceRef ?? "") : "（无出处记录）")
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink500)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.top, DS.Spacing.s12)
        .padding(.bottom, DS.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分区块正文：bodyMD 14 灰阶主文（层级由色签与竖线承担，正文统一灰防彩色疲劳）。
    private func blockBody(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.bodyMD)
            .foregroundStyle(Color.ink700)
            .dsBodyType(size: 14)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「怎么用」块内的边界脚注：虚线 hairline（有做法正文时才画）+ 描边小签 + 弱化文字。
    private func boundaryFootnote(_ text: String, showsRule: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            if showsRule {
                DashedRule()
                    .stroke(Color.borderL2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(height: 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s6) {
                Text("边界")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .padding(.horizontal, DS.Spacing.s4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .strokeBorder(Color.borderL2, lineWidth: 1)
                    )
                Text(text)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .dsBodyType(size: 12)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// hero 背景（方案 B）：深浅双档渐变（浅色=纸面白 / 深色=原深色壳）+ 顶部 1.5px 品牌高光线。
    private var heroBackground: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(
                    LinearGradient(
                        colors: [
                            // 深浅双档（2026-09-17 修复浅色模式文字隐形：壳原为写死深色渐变，
                            // 而壳内文字用 ink 系动态令牌，浅色下近黑字压深底=看不见）。
                            // 深色档数值与原写死值逐通道一致，浅色档走 surface 纸面。
                            Color.dynamic(0xFFFFFF, 0x1A1922),
                            Color.dynamic(0xF5F5F8, 0x141318),
                        ],
                        startPoint: .topLeading, endPoint: .bottom
                    )
                )
            LinearGradient(
                colors: [.clear, Color.brandAccent.opacity(0.65), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1.5)
        }
    }
}

// MARK: - 方案 B 卡共用小组件（聚光灯 hero 与详情弹层共用）

/// 匹配度指示：56px 细条 + mono 百分比。
struct MatchIndicator: View {
    let score: Double

    var body: some View {
        HStack(spacing: DS.Spacing.s6) {
            Capsule()
                .fill(Color.overlayL2)
                .frame(width: 56, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.statusSuccess)
                        .frame(width: 56 * min(score, 1.0))
                }
            Text("匹配 \(Int((score * 100).rounded()))%")
                .font(DS.Font.mono2XS)
                .foregroundStyle(Color.ink500)
        }
    }
}

/// 右对齐标签 + 正文的一行（是什么 / 为什么有效…）。
/// 正文限宽 640 阅读栏（DS.Typography.chatMeasure，CJK ≈42 字/行）——
/// 通栏长行是「文字墙」观感的直接来源。
struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s10) {
            Text(label)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
                .frame(width: 62, alignment: .trailing)
            Text(value)
                .font(DS.Font.bodyMD)
                .foregroundStyle(Color.ink700)
                .dsBodyType(size: 14)
                .frame(maxWidth: DS.Typography.chatMeasure, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 详情弹层方案 B 分区块：overlayL1 容器 + 左缘 2.5pt 语义竖线 + 顶部语义色签。
/// 语义映射：是什么=brand 紫 / 为什么有效=success 绿 / 怎么用=info 蓝 / 实战案例=alert 橙；
/// 正文统一灰阶（层级由色签与竖线承担，四色同屏不疲劳）。
private struct DetailBlock<Content: View>: View {
    let chipTitle: String
    let variant: DSTag.Variant
    var chipNote: String? = nil
    @ViewBuilder let content: Content

    private var barColor: Color {
        switch variant {
        case .brand: Color.brandAccent
        case .success: Color.statusSuccess
        case .info: Color.statusPrimary
        case .alert: Color.statusAlert
        default: Color.borderL3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s8) {
                DSTag(title: chipTitle, variant: variant)
                if let chipNote {
                    Text(chipNote)
                        .font(DS.Font.mono2XS)
                        .foregroundStyle(Color.ink300)
                }
            }
            content
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.xl).fill(Color.overlayL1))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(barColor)
                .frame(width: 2.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl))
    }
}

/// 1pt 虚线 hairline（「怎么用」块内边界脚注的顶部分隔）。
private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// 线索引用块（方案 B quote：左 2px 品牌竖线 + 浅底，悬挂对齐正文列；
/// 底随内容收宽不全幅铺——灰板通栏会压住主卡的呼吸感）。
struct QuoteBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Color.brand600.opacity(0.5))
                .frame(width: 2)
            Text(text)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .dsBodyType(size: 13)
                .padding(.horizontal, DS.Spacing.s10)
        }
        .padding(.vertical, DS.Spacing.s6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.overlayL1))
        .frame(maxWidth: DS.Typography.chatMeasure + DS.Spacing.s12, alignment: .leading)
        .padding(.leading, 72)
    }
}

// MARK: - 技能命中行（when_to_use 摘要；正文渐进式披露，自知识点 Tab 收口迁入）

struct SkillHitRow: View {
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

// MARK: - 聚光灯推荐区（2026-09-17 钦定方案 B：一次主推一张，处置完翻下一张）
//
// 阶段边界由 AppModel.refreshRecommendations 扫库生成 1-3 张（触发纪律不变：
// 对话中途不打扰）。主卡全量五段展示（是什么 / 为什么现在 / 怎么用 / 案例），
// 待看卡收在下方堆叠行可切换；处置动作走 AppModel 同一链路（注记 + 校准 + 倾向）。

private struct SpotlightSection: View {
    let recommendations: [Recommender.Recommendation]
    /// 当前项目名（读主卡 .md 定位项目 knowledge/ 用）。
    let project: String
    let onAdopt: (String) -> Void
    let onReject: (String) -> Void
    /// 打开卡片详情弹层（复用知识库页现有 sheet）。
    let onOpenDetail: (String) -> Void

    @State private var spotIndex = 0
    @State private var showTriggerNote = false
    @State private var toast: String?
    /// 主卡的实战案例（读卡 .md 解析注记时间线，方案 B 案例区数据源）。
    @State private var heroDetail: MethodologyCard?

    /// 主卡（越界保护：处置后数组缩短，index 钳到有效范围）。
    private var hero: Recommender.Recommendation? {
        guard !recommendations.isEmpty else { return nil }
        return recommendations[min(spotIndex, recommendations.count - 1)]
    }

    var body: some View {
        // 方案 B 布局：hero 主卡占左侧主列，待看堆叠竖排在右缘（172px）
        HStack(alignment: .top, spacing: DS.Spacing.s12) {
            VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                spotlightHeader
                triggerNote

                if let hero {
                    heroCard(hero)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if recommendations.count > 1 {
                pendingStack
                    .frame(width: 172)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            if let toast {
                ToastPill(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: hero?.id) { await loadHeroDetail() }
    }

    /// 读主卡 .md：实战案例时间线数据源（append-only 注记）。
    private func loadHeroDetail() async {
        guard let hero else {
            heroDetail = nil
            return
        }
        let fm = FileManager.default
        let globalURL = PMAgentStore.cardsDir.appendingPathComponent("\(hero.id).md")
        var url: URL? = nil
        if fm.fileExists(atPath: globalURL.path) {
            url = globalURL
        } else if !project.isEmpty {
            let local = PMAgentStore.projectURL(project)
                .appendingPathComponent("knowledge/\(hero.id).md")
            if fm.fileExists(atPath: local.path) { url = local }
        }
        guard let url,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let card = MethodologyCard.parse(markdown: text) else {
            heroDetail = nil
            return
        }
        heroDetail = card
    }

    private var spotlightHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s8) {
            Text("本阶段聚光灯")
                .font(DS.Font.displaySM)
                .foregroundStyle(Color.ink900)
            Text("一张一张看，用不上就翻过去")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
            Spacer()
        }
    }

    /// 待看堆叠（方案 B：右缘竖排小卡，点击切换主卡）。
    private var pendingStack: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            Text("待看 · \(recommendations.count - 1)")
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
            ForEach(pendingOthers) { rec in
                pendingChip(rec)
            }
        }
    }

    private func pendingChip(_ rec: Recommender.Recommendation) -> some View {
        Button {
            withAnimation(DS.Motion.springFast) {
                spotIndex = recommendations.firstIndex(where: { $0.id == rec.id }) ?? 0
            }
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                Text(rec.title)
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink700)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("匹配 \(Int((rec.score * 100).rounded()))%")
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(Color.ink500)
            }
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s8)
            .frame(width: 168, alignment: .leading)
            .background(pendingChipBackground)
            .overlay(pendingChipBorder)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
    }

    private var pendingChipBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.md)
            .fill(Color.overlayL1)
    }

    private var pendingChipBorder: some View {
        RoundedRectangle(cornerRadius: DS.Radius.md)
            .strokeBorder(Color.borderL2, lineWidth: 1)
    }

    /// 待看 = 除当前主卡外的其余推荐。
    private var pendingOthers: [Recommender.Recommendation] {
        guard let hero, let heroIdx = recommendations.firstIndex(where: { $0.id == hero.id }) else {
            return recommendations
        }
        return recommendations.enumerated()
            .filter { $0.offset != heroIdx }
            .map(\.element)
    }

    /// ⓘ 触发说明条（透明度钦定：什么时候推 / 凭什么推 / 不打扰边界）。
    /// 收起态不带灰底——常驻说明不该是一块压在标题与主卡之间的板子。
    private var triggerNote: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s6) {
                Text("推荐只在阶段边界出现")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Text(showTriggerNote ? "收起" : "ⓘ 什么时机推？")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.brandAccent)
                    .onTapGesture { withAnimation(DS.Motion.springFast) { showTriggerNote.toggle() } }
            }
            if showTriggerNote {
                Text("进入或切换阶段时自动扫一次知识库——拿当前阶段的关键产物（澄清要点表 / 功能清单）加上你最近说的话，与每张卡算语义匹配，只把对得上的前 \(Recommender.maxRecommendations) 张放这里。跳过的不重复推；对话中途不打扰。")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .dsCaptionType(size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(showTriggerNote ? DS.Spacing.s8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showTriggerNote {
                RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.overlayL1)
            }
        }
    }

    /// 主卡（方案 B 聚光灯 hero）：深色渐变 + 顶部高光线 + 衬线大标题 +
    /// 右对齐标签列 + quote 线索 + 品牌晕双层阴影。正文全文不重复内联——
    /// 「看全文」进详情弹层（是什么摘要 + 为什么现在 + 案例数已构成主卡信息面）。
    /// 2026-09-17 呼吸感改版：四组节奏（组内 8-10、组间 16），内容收 640
    /// 阅读栏，动作区以发丝线与内容分家，案例注记拆 meta/正文两行。
    private func heroCard(_ rec: Recommender.Recommendation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s16) {
            // 身份组：scope 元信息 + 衬线大标题
            VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                HStack(spacing: DS.Spacing.s8) {
                    ScopeBadge(scope: rec.scope)
                    Text(rec.scope == "global" ? "通用 · 所有项目可用" : "本项目沉淀")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                    Spacer()
                    matchIndicator(rec.score)
                }

                Text(Recommender.title(of: rec.content))
                    .font(DS.Font.displayMD)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 内容组：是什么 + 线索引用（同一语义块，组内更紧）
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                LabeledRow(label: "是什么", value: rec.what)
                quoteBlock(rec.whyNow)
            }

            // 案例组
            caseTimeline(rec)

            // 动作组：发丝线把操作区从内容里剥出来
            VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                DSDivider()
                HStack(spacing: DS.Spacing.s10) {
                    Text("采纳 = 记一条实际案例：这次在哪个项目、怎么用的")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                    Spacer()
                    Button("看全文") { onOpenDetail(rec.id) }
                        .buttonStyle(.ds(.ghost, size: .sm))
                        .help("打开卡片全文与案例时间线")
                    Button("不适用") {
                        reject(rec)
                    }
                    .buttonStyle(.ds(.secondary, size: .sm))
                    .help("本阶段不再重复推荐该方法论")
                    Button("采纳，看下一张") {
                        adopt(rec)
                    }
                    .buttonStyle(.ds(.brand, size: .sm))
                    .help("采纳：记一条实战案例 + 注入你的历史使用倾向")
                }
            }
        }
        .padding(.horizontal, DS.Spacing.s20)
        .padding(.vertical, DS.Spacing.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.brand600.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        .shadow(color: .black.opacity(0.40), radius: 1, x: 0, y: 1)
        .shadow(color: Color.brand600.opacity(0.13), radius: 22, x: 0, y: 14)
        .id(rec.id)  // 翻卡动画：卡 id 变化即淡入
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    /// hero 背景（方案 B）：深浅双档渐变（浅色=纸面白 / 深色=原深色壳）+ 顶部 1.5px 品牌高光线。
    private var heroBackground: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(
                    LinearGradient(
                        colors: [
                            // 深浅双档（2026-09-17 修复浅色模式文字隐形：壳原为写死深色渐变，
                            // 而壳内文字用 ink 系动态令牌，浅色下近黑字压深底=看不见）。
                            // 深色档数值与原写死值逐通道一致，浅色档走 surface 纸面。
                            Color.dynamic(0xFFFFFF, 0x1A1922),
                            Color.dynamic(0xF5F5F8, 0x141318),
                        ],
                        startPoint: .topLeading, endPoint: .bottom
                    )
                )
            LinearGradient(
                colors: [.clear, Color.brandAccent.opacity(0.65), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1.5)
        }
    }

    /// 匹配度指示：56px 细条 + mono 百分比（方案 B hero 右上角）。
    private func matchIndicator(_ score: Double) -> some View {
        MatchIndicator(score: score)
    }

    /// 实战案例时间线（读卡 .md 的 append-only 注记）：日期/项目升为 meta 行、
    /// 案例正文另起一行收 640 阅读栏——原先「日期·项目：正文」连排一行，
    /// 长注记读不成句。
    private func caseTimeline(_ rec: Recommender.Recommendation) -> some View {
        let notes = heroDetail?.id == rec.id ? (heroDetail?.annotations ?? []) : []
        return VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            Text("实际案例 · 用过 \(rec.annotationCount) 次")
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
            if notes.isEmpty {
                Text("还没在产品里用过——第一次采纳时记下这次的项目和过程")
                    .font(DS.Font.bodyMD)
                    .foregroundStyle(Color.ink300)
            } else {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: DS.Spacing.s8) {
                        Circle()
                            .fill(Color.brand600)
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                            Text("\(note.date) · \(note.project)")
                                .font(DS.Font.bodyXSStrong)
                                .foregroundStyle(Color.ink500)
                            Text(note.note)
                                .font(DS.Font.bodyMD)
                                .foregroundStyle(Color.ink700)
                                .dsBodyType(size: 14)
                                .frame(maxWidth: DS.Typography.chatMeasure, alignment: .leading)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// 线索引用块（方案 B quote：左 2px 品牌竖线 + 浅底，悬挂对齐正文列）。
    private func quoteBlock(_ text: String) -> some View {
        QuoteBlock(text: text)
    }

    private func adopt(_ rec: Recommender.Recommendation) {
        withAnimation(DS.Motion.springFast) { spotIndex = 0 }
        onAdopt(rec.id)
        showToast("已采纳——记了一条实战案例，卡片存回下方「全部卡片」，点开看全文")
    }

    private func reject(_ rec: Recommender.Recommendation) {
        withAnimation(DS.Motion.springFast) { spotIndex = 0 }
        onReject(rec.id)
        showToast("已跳过——本阶段不再推荐这张卡")
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(DS.Motion.springFast) { toast = nil }
        }
    }
}

// MARK: - 处置结算条（聚光灯清空后的一句收尾）

private struct SettlementBanner: View {
    let adopted: Int
    let skipped: Int

    var body: some View {
        HStack(spacing: DS.Spacing.s8) {
            DSIcon(.circleCheck, size: 14)
                .foregroundStyle(Color.statusSuccess)
            Text("本阶段聚光灯都看完了——采纳 \(adopted) 张 · 跳过 \(skipped) 张，案例已记进各自卡片")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
            Spacer()
        }
        .padding(DS.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.statusSuccessSurface1))
    }
}

// MARK: - 就地反馈胶囊（聚光灯 toast）

private struct ToastPill: View {
    let text: String

    var body: some View {
        HStack(spacing: DS.Spacing.s6) {
            DSIcon(.circleCheck, size: 13)
                .foregroundStyle(Color.statusSuccess)
            Text(text)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink700)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s8)
        .background(
            Capsule()
                .fill(Color.surfaceBase)
                .shadow(color: Color.shadowInk, radius: 8, y: 2)
        )
        .overlay(Capsule().strokeBorder(Color.borderL2, lineWidth: 1))
    }
}
