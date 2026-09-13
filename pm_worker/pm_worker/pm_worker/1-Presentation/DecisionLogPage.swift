//
//  DecisionLogPage.swift
//  pm_worker
//
//  中栏「决策日志」独立页面（对齐交互原型 v4.4，左栏功能导航四页之一）：
//  项目（含「全部」）/ 版本 / 状态筛选 + 搜索 + 卡片视图。
//  decisions.jsonl 只读投影（design.md §5.2 / §6.4）；卡片复刻右栏
//  DecisionLogTab 的 DecisionCard / RiskHitCard（原实现 private，本文件重写）。
//

import SwiftUI

struct DecisionLogPage: View {
    @EnvironmentObject var model: AppModel

    /// 状态筛选（原型 v4.4）：待验证未闭环 = warning；已闭环 = success。
    /// risk_hit 无闭环状态，仅「全部」下显示。
    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case pending = "待验证"
        case closed = "已闭环"

        var id: String { rawValue }
    }

    /// 展示行：加载时一次性构建（UUID 稳定标识 ForEach）。
    private struct Row: Identifiable {
        let id = UUID()
        let entry: DecisionLogEntry
        /// 归属项目（跨项目「全部」视图的卡片归属提示）。
        let project: String

        /// 跨项目归并排序键：决策用 createdAt（ISO8601 字典序即时间序）；
        /// risk_hit 无时间字段 → 空串置尾。
        var sortKey: String {
            if case .decision(let record) = entry { return record.createdAt }
            return ""
        }
    }

    @State private var rows: [Row] = []
    /// nil = 全部项目（默认）。
    @State private var selectedProject: String?
    @State private var selectedVersion = "unversioned"
    @State private var statusFilter: StatusFilter = .all
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                Text("决策日志")
                    .font(DS.Font.headingMD)
                    .foregroundStyle(Color.ink900)

                // 项目（全部）/ 版本（选中项目后可选，默认 unversioned）
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

                    Spacer(minLength: DS.Spacing.s8)

                    // 搜索（决策 / 理由 / 排除方案 / 💀 命中）
                    HStack(spacing: DS.Spacing.s6) {
                        DSIcon(.search, size: 13)
                            .foregroundStyle(Color.ink300)
                        TextField("搜索决策 / 理由", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(DS.Font.bodySM)
                    }
                    .dsInput(minHeight: 28)
                    .frame(width: 200)
                }

                // 状态筛选
                DSSelect(
                    options: StatusFilter.allCases.map {
                        DSSelectOption($0, $0.rawValue)
                    },
                    selection: $statusFilter
                )
                .frame(width: 120)
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

    private var content: some View {
        cardsView
            // 空态居中撑满（与技能库/卡片库页面同规格），防内容塌缩贴顶
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardsView: some View {
        Group {
            if rows.isEmpty {
                DSEmptyState(
                    icon: .barList,
                    title: "尚无决策记录",
                    description: "决策记录在任务执行中写入 decisions.jsonl——尚无记录，不是缺失。"
                )
            } else if visibleRows.isEmpty {
                DSEmptyState(
                    icon: .search,
                    title: "无匹配记录",
                    description: "换个筛选条件或关键词试试。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.s8) {
                        Text(
                            visibleRows.count == rows.count
                                ? "共 \(rows.count) 条"
                                : "已筛 \(visibleRows.count) / \(rows.count) 条"
                        )
                        .font(DS.Font.bodyXS)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink500)
                        ForEach(visibleRows) { row in
                            switch row.entry {
                            case .decision(let record):
                                // 跨项目视图才显示归属（单项目下项目名冗余）
                                DecisionCard(
                                    record: record,
                                    project: selectedProject == nil ? row.project : nil
                                )
                            case .riskHit(let record):
                                RiskHitCard(
                                    record: record,
                                    project: selectedProject == nil ? row.project : nil
                                )
                            }
                        }
                    }
                    .padding(DS.Spacing.s24)
                }
            }
        }
    }

    // MARK: - 筛选

    private var visibleRows: [Row] {
        var result = rows
        switch statusFilter {
        case .all:
            break
        case .pending, .closed:
            // risk_hit 无闭环状态，仅在「全部」下出现
            result = result.filter { row in
                if case .decision(let record) = row.entry {
                    return statusFilter == .pending
                        ? record.toBeVerified
                        : !record.toBeVerified
                }
                return false
            }
        }

        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            result = result.filter { row in
                switch row.entry {
                case .decision(let record):
                    return record.decision.localizedCaseInsensitiveContains(keyword)
                        || record.why.localizedCaseInsensitiveContains(keyword)
                        || record.rejectedAlternatives.contains {
                            $0.option.localizedCaseInsensitiveContains(keyword)
                                || $0.reason.localizedCaseInsensitiveContains(keyword)
                        }
                case .riskHit(let record):
                    return record.predicted.localizedCaseInsensitiveContains(keyword)
                        || record.actual.localizedCaseInsensitiveContains(keyword)
                }
            }
        }
        return result
    }

    /// 选中项目的版本列表（未选项目 → 空）。
    private var versionOptions: [String] {
        guard let project = selectedProject,
              let node = model.projects.first(where: { $0.name == project })
        else { return [] }
        return node.versions.map(\.name)
    }

    // MARK: - 数据（decisions.jsonl 只读）

    private func reload() {
        // 范围：选中项目 × 选中版本；「全部」→ 所有项目 × 所有版本
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
        let singleScope = scopes.count == 1

        var loaded: [Row] = []
        for scope in scopes {
            let url = PMAgentStore.jsonlURL(
                project: scope.project, version: scope.version, file: "decisions.jsonl"
            )
            // append-only：文件序即时间序，倒读即 createdAt 倒序
            //（risk_hit 无 createdAt，单范围内保持与决策的穿插时序）。
            loaded.append(
                contentsOf: PMAgentStore.readLines(DecisionLogEntry.self, from: url)
                    .reversed()
                    .map { Row(entry: $0, project: scope.project) }
            )
        }

        if !singleScope {
            // 跨项目归并：决策按 createdAt 倒序；💀 命中无时间 → 置尾。
            let decisions = loaded.filter { $0.sortKey != "" }
                .sorted { $0.sortKey > $1.sortKey }
            let riskHits = loaded.filter { $0.sortKey == "" }
            loaded = decisions + riskHits
        }

        rows = loaded
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

// MARK: - 决策卡（层级化排版：结论 14 semibold 主导 + 元信息行 + 展开分节详情）
// 复刻自右栏 DecisionLogTab（原实现 private 无法复用，本文件重写，双份同步维护）。
// 设计纪律：卡片中性底色（状态色只留在徽章这一小块），结论与论据拉开两级字重。

private struct DecisionCard: View {
    let record: DecisionRecord
    /// 跨项目「全部」视图的归属提示；单项目上下文传 nil 不显示。
    var project: String? = nil
    @State private var expanded = false

    private var confidencePercent: Int {
        Int((record.confidence * 100).rounded())
    }

    /// createdAt → 「yyyy-MM-dd HH:mm」（解析失败不显示）。
    private static let parser = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var timeText: String? {
        guard let date = Self.parser.date(from: record.createdAt) else { return nil }
        return Self.displayFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            // 结论区：决策一句话 = 卡片唯一主角
            HStack(alignment: .top, spacing: DS.Spacing.s12) {
                Text(record.decision)
                    .font(DS.Font.headingXS)
                    .foregroundStyle(Color.ink900)
                    .dsBodyType(size: 14)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                confidenceMeter
            }

            // 元信息区：状态徽章 + 归属/时间（扫读上下文）+ 展开指示
            HStack(spacing: DS.Spacing.s8) {
                statusBadge
                if let project, !project.isEmpty {
                    Text(project)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .lineLimit(1)
                }
                if let time = timeText {
                    Text(time)
                        .font(DS.Font.bodyXS)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink300)
                }
                Spacer(minLength: 0)
                DSIcon(.chevronUp, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : 180))
                    .foregroundStyle(Color.ink300)
            }

            if expanded {
                DSDivider()
                detail
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
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(DS.Motion.springFast) { expanded.toggle() } }
    }

    /// 置信度 = 数字 + 微条双编码（中性色；状态语义全部收敛到徽章）。
    private var confidenceMeter: some View {
        VStack(alignment: .trailing, spacing: DS.Spacing.s4) {
            Text("\(confidencePercent)%")
                .font(DS.Font.monoSM)
                .foregroundStyle(Color.ink700)
            Capsule()
                .fill(Color.overlayL3)
                .frame(width: 44, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.ink800)
                        .frame(width: max(0, 44 * record.confidence), height: 3)
                }
        }
        .padding(.top, DS.Spacing.s2)
    }

    /// 状态徽章：待验证 = warning（唯一需要行动的状态才有颜色）；
    /// 已闭环 = 中性稳态，列表里橙色因此更醒目。
    private var statusBadge: some View {
        Text(record.toBeVerified ? "待验证" : "已闭环")
            .font(DS.Font.bodyXSStrong)
            .foregroundStyle(record.toBeVerified ? Color.statusWarning : Color.ink500)
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s2)
            .background(
                Capsule().fill(
                    record.toBeVerified ? Color.statusWarningSurface1 : Color.overlayL2
                )
            )
    }

    /// 展开详情：分节标签退后（淡色小字锚点），内容深色站前排；
    /// 置信度/状态已在元信息行，不再重复。
    private var detail: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s12) {
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                sectionLabel("决策理由")
                Text(record.why)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                    .dsBodyType(size: 13)
            }

            if !record.rejectedAlternatives.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                    sectionLabel("排除方案")
                    ForEach(
                        Array(record.rejectedAlternatives.enumerated()),
                        id: \.offset
                    ) { _, alt in
                        // 方案名（medium 深色）+ 排除理由（小一号浅色）配对，
                        // ✕ 前缀标记「被否决的分支」。
                        HStack(alignment: .top, spacing: DS.Spacing.s8) {
                            DSIcon(.close, size: 10)
                                .foregroundStyle(Color.ink300)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                                Text(alt.option)
                                    .font(DS.Font.bodySMStrong)
                                    .foregroundStyle(Color.ink800)
                                Text(alt.reason)
                                    .font(DS.Font.bodyXS)
                                    .foregroundStyle(Color.ink500)
                                    .dsCaptionType(size: 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.bodyXSStrong)
            .foregroundStyle(Color.ink300)
    }
}

// MARK: - 💀 命中回写卡（事件卡：预测/实际 结构化对读；红色调只压标题不压正文）

private struct RiskHitCard: View {
    let record: RiskHitRecord
    /// 跨项目「全部」视图的归属提示；单项目上下文传 nil 不显示。
    var project: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s8) {
                Text("💀 预测命中")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.statusError)
                Spacer(minLength: 0)
                if let project, !project.isEmpty {
                    Text(project)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                hitRow("预测", record.predicted)
                hitRow("实际", record.actual)
            }
        }
        .padding(DS.Spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.statusErrorSurface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.statusError.opacity(0.16), lineWidth: 1)
        )
    }

    private func hitRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s8) {
            Text(label)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .frame(width: 28, alignment: .leading)
                .padding(.top, 1)
            Text(text)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink800)
                .dsBodyType(size: 13)
        }
    }
}
