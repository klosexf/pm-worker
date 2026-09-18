//
//  DecisionLogPage.swift
//  pm_worker
//
//  中栏「决策日志」独立页面（对齐交互原型 v4.4，左栏功能导航四页之一）：
//  项目（含「全部」）/ 版本筛选 + 分段（决策 / 变更池）；
//  决策分段 = 决策档案生成区（DecisionArchiveSection，2026-09-16），
//  原始 jsonl 记录不再在 UI 投影（2026-09-16），消费统一走生成的 HTML 档案；
//  变更池分段 = 池内提案毕业仪式处置现场。
//

import SwiftUI

struct DecisionLogPage: View {
    @EnvironmentObject var model: AppModel

    /// 页面分段：决策台账 / 变更池（同源不同表：decisions.jsonl / changes.jsonl）。
    private enum PageSegment: Hashable {
        case decisions
        case pool
    }

    /// 变更池行：池内提案 + 归属（毕业动作要写回对应版本的 changes.jsonl）。
    private struct PoolRow: Identifiable {
        let item: ChangeItem
        let project: String
        let version: String
        var id: String { item.id }
    }

    /// decisions.jsonl 文件序条目（选中项目 × 版本；喂给档案生成区）。
    @State private var entries: [DecisionLogEntry] = []
    @State private var poolRows: [PoolRow] = []
    /// nil = 全部项目（默认）。
    @State private var selectedProject: String?
    @State private var selectedVersion = "unversioned"
    @State private var pageSegment: PageSegment = .decisions

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                Text("决策日志")
                    .font(DS.Font.headingMD)
                    .foregroundStyle(Color.ink900)

                // 页面分段：决策 / 变更池
                DSTabs(
                    items: [
                        DSTabItem(.decisions, "决策"),
                        DSTabItem(.pool, "变更池"),
                    ],
                    selection: $pageSegment
                )

                // 项目（全部）/ 版本（选中项目后可选，默认 unversioned）
                // 档案按项目 × 版本生成，范围选择保留；原始记录的搜索/状态筛选随投影一并移除
                HStack(spacing: DS.Spacing.s8) {
                    DSSelect(
                        options: [DSSelectOption<String?>(nil, "全部")]
                            + model.projects.map {
                                DSSelectOption<String?>($0.name, $0.name)
                            },
                        selection: $selectedProject
                    )
                    .frame(width: 160)

                    DSSelect(
                        options: versionOptions.map {
                            DSSelectOption($0, $0 == "unversioned" ? "默认无版本号" : $0)
                        },
                        selection: $selectedVersion
                    )
                    .frame(width: 160)
                    .disabled(selectedProject == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(
                top: DS.Spacing.s24, leading: DS.Spacing.s24,
                bottom: DS.Spacing.s12, trailing: DS.Spacing.s24
            ))

            DSDivider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.surfaceBase)
        .onAppear(perform: reload)
        .onChange(of: selectedProject) { _, _ in
            resetVersion()
            reload()
        }
        .onChange(of: selectedVersion) { _, _ in reload() }
        .onChange(of: model.projects) { _, _ in reload() }
    }

    // MARK: - 内容区（卡片）

    @ViewBuilder
    private var content: some View {
        switch pageSegment {
        case .decisions:
            cardsView
                // 空态居中撑满（与技能库/卡片库页面同规格），防内容塌缩贴顶
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pool:
            poolView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 变更池（封板毕业仪式的处置现场）

    private var poolView: some View {
        Group {
            if poolRows.isEmpty {
                DSEmptyState(
                    icon: .bookmark,
                    title: "候选池为空",
                    description: "对话中出现新想法时，AI 提案、你选「放入候选池」的条目会登记到这里；版本封板前需逐条处置。"
                )
            } else {
                DSScroll {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.s8) {
                        Text("池内 \(poolRows.count) 条 · 封板前需逐条处置（纳入 / 放弃 / 顺延），不许默认沉淀")
                            .font(DS.Font.bodyXS)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink500)
                        ForEach(poolRows) { row in
                            if row.item.proposal.isStageDraft {
                                DraftMergeCard(
                                    item: row.item, project: row.project, version: row.version
                                ) { reload() }
                            } else {
                                ChangePoolCard(
                                    item: row.item, project: row.project, version: row.version
                                ) { reload() }
                            }
                        }
                    }
                    .padding(DS.Spacing.s24)
                }
            }
        }
    }

    /// 决策分段 = 档案生成区（原始 jsonl 记录不再投影，消费统一走生成的 HTML 档案）。
    @ViewBuilder
    private var cardsView: some View {
        if let project = selectedProject {
            DSScroll {
                DecisionArchiveSection(
                    project: project,
                    version: selectedVersion,
                    entries: entries
                )
                .padding(DS.Spacing.s24)
            }
        } else {
            // 「全部」无对应档案目录：先选项目
            DSEmptyState(
                icon: .doc,
                title: "选择项目查看决策档案",
                description: "决策日志档案按项目 × 版本生成；上方选择项目即可生成 / 打开。"
            )
        }
    }

    // MARK: - 范围

    /// 选中项目的版本列表（未选项目 → 空）。
    private var versionOptions: [String] {
        guard let project = selectedProject,
              let node = model.projects.first(where: { $0.name == project })
        else { return [] }
        return node.versions.map(\.name)
    }

    // MARK: - 数据（decisions.jsonl / changes.jsonl 只读）

    private func reload() {
        // 决策条目：档案按项目 × 版本生成，仅单项目范围加载；「全部」→ 空。
        if let project = selectedProject {
            entries = PMAgentStore.readLines(
                DecisionLogEntry.self,
                from: PMAgentStore.jsonlURL(
                    project: project, version: selectedVersion, file: "decisions.jsonl"
                )
            )
        } else {
            entries = []
        }

        // 变更池：范围读 changes.jsonl 折叠取 pooled（倒读 = 登记倒序）。
        // 「全部」→ 所有项目 × 所有版本（池卡仍按各自归属写回）。
        var scopes: [(project: String, version: String)] = []
        if let project = selectedProject {
            scopes = [(project: project, version: selectedVersion)]
        } else {
            for node in model.projects {
                for version in node.versions {
                    scopes.append((project: node.name, version: version.name))
                }
            }
        }
        poolRows = scopes.flatMap { scope in
            ChangeLedger.load(project: scope.project, version: scope.version)
                .filter { $0.isPooled || ($0.proposal.isStageDraft && $0.isPending) }
                .reversed()
                .map { PoolRow(item: $0, project: scope.project, version: scope.version) }
        }
    }

    /// 项目切换后版本回默认（目标项目无当前版本时：unversioned 优先，否则取首个）。
    private func resetVersion() {
        let names = versionOptions
        guard !names.contains(selectedVersion) else { return }
        selectedVersion = names.contains("unversioned")
            ? "unversioned"
            : (names.first ?? "unversioned")
    }
}

// MARK: - 变更池卡（毕业仪式处置行：纳入后续版本 / 放弃 / 顺延；点击即生效——用户明确动作）

private struct ChangePoolCard: View {
    @EnvironmentObject private var model: AppModel
    let item: ChangeItem
    let project: String
    let version: String
    let onResolved: () -> Void

    private var proposal: ChangeProposalRecord { item.proposal }

    /// 登记时的检查点阶段（提案从哪个阶段的对话中来）。
    private var stageLabel: String {
        switch proposal.checkpointStage {
        case "clarify": "① 澄清"
        case "structure": "② 结构"
        case "prototype": "③ 原型"
        case "prd": "④ PRD"
        default: proposal.checkpointStage
        }
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var timeText: String? {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: proposal.createdAt) else { return nil }
        return Self.displayFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            // 结论区：决策一句话 = 卡片唯一主角
            Text(proposal.idea)
                .font(DS.Font.headingXS)
                .foregroundStyle(Color.ink900)
                .dsBodyType(size: 14)
                .lineLimit(3)

            // 影响清单（有则展示；进池条目常无）
            if let impacts = proposal.impacts, !impacts.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                    ForEach(impacts, id: \.self) { impact in
                        HStack(alignment: .top, spacing: DS.Spacing.s6) {
                            DSIcon(.dot, size: 5)
                                .foregroundStyle(Color.ink300)
                                .padding(.top, 6)
                            Text(impact)
                                .font(DS.Font.bodySM)
                                .foregroundStyle(Color.ink700)
                                .dsBodyType(size: 13)
                        }
                    }
                }
            }

            // 元信息 + 毕业动作
            HStack(spacing: DS.Spacing.s8) {
                if let category = proposal.category, !category.isEmpty {
                    DSTag(title: category, variant: .neutral)
                }
                Text("来自 \(stageLabel)")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                if let time = timeText {
                    Text(time)
                        .font(DS.Font.bodyXS)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink300)
                }
                Spacer(minLength: 0)
                Button("纳入后续版本") {
                    model.graduatePoolItem(item, project: project, version: version, to: .adopted)
                    onResolved()
                }
                .buttonStyle(.ds(.primary, size: .sm))
                Button("放弃") {
                    model.graduatePoolItem(item, project: project, version: version, to: .dropped)
                    onResolved()
                }
                .buttonStyle(.ds(.secondary, size: .sm))
                Button("顺延") {
                    model.graduatePoolItem(item, project: project, version: version, to: .deferred)
                    onResolved()
                }
                .buttonStyle(.ds(.ghost, size: .sm))
            }
        }
        .padding(DS.Spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }
}
