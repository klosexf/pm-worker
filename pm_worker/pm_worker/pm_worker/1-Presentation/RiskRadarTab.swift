//
//  RiskRadarTab.swift
//  pm_worker
//
//  右栏「漏项雷达」Tab：risks.jsonl 风险登记册只读投影（design.md §5.2 / §6.4）。
//  人话状态徽章：还盯着（open）/ 被说中了（triggered，predicted vs actual 对照）/
//  安全落地（closed_unfired）/ 已证伪关闭 / 已合并；
//  同 id 多行折叠取末行，默认只展开在盯卡，活跃 open > 3 顶部黄条提示收敛。
//

import SwiftUI

struct RiskRadarTab: View {
    @EnvironmentObject private var model: AppModel

    /// 活跃风险软上限（design.md §5.2：open 上限软性 3 条，超限先收敛）。
    private static let softLimit = 3

    @State private var risks: [RiskRecord] = []

    var body: some View {
        Group {
            if risks.isEmpty {
                DSEmptyState(
                    icon: .skull,
                    title: "尚未开始",
                    description: "漏项雷达四档声明在会话自评审时生成。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.s8) {
                        statsLine
                        if openCount > Self.softLimit {
                            softLimitBanner
                        }
                        ForEach(risks, id: \.id) { record in
                            RiskCard(record: record, defaultExpanded: record.status == .open)
                        }
                    }
                    .padding(DS.Spacing.s12)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.selection) { _, _ in reload() }
    }

    // MARK: - 顶部统计与软上限提示

    private var openCount: Int {
        risks.filter { $0.status == .open }.count
    }

    private var triggeredCount: Int {
        risks.filter { $0.status == .triggered }.count
    }

    private var closedCount: Int {
        risks.filter {
            $0.status == .closedUnfired || $0.status == .closedFalsified || $0.status == .merged
        }.count
    }

    private var statsLine: some View {
        Text("在盯 \(openCount) · 命中 \(triggeredCount) · 关闭 \(closedCount)")
            .font(DS.Font.bodyXS)
            .foregroundStyle(Color.ink500)
    }

    private var softLimitBanner: some View {
        Text(
            "💀 活跃风险超软上限（\(Self.softLimit)），建议收敛：关闭已证伪 / 降级为待定问题 / 合并同源"
        )
        .font(DS.Font.bodyXS)
        .foregroundStyle(Color.statusWarning)
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.statusWarningSurface1)
        )
    }

    // MARK: - 数据（risks.jsonl 折叠 + 排序）

    private func reload() {
        guard let ctx = model.selection.inspectorProject else {
            risks = []
            return
        }
        risks = Self.sortedForDisplay(
            Self.collapseLatest(
                PMAgentStore.readLines(
                    RiskRecord.self,
                    from: PMAgentStore.jsonlURL(
                        project: ctx.project, version: ctx.version, file: "risks.jsonl"
                    )
                )
            )
        )
    }

    /// 同 id 多行取最后一行（append-only 状态机回放，末行即最新态）。
    private static func collapseLatest(_ records: [RiskRecord]) -> [RiskRecord] {
        var latest: [String: RiskRecord] = [:]
        var firstSeen: [String] = []
        for record in records {
            if latest[record.id] == nil { firstSeen.append(record.id) }
            latest[record.id] = record
        }
        return firstSeen.compactMap { latest[$0] }
    }

    /// 展示序：在盯 → 命中 → 终态；组内按 createdAt 倒序。
    private static func sortedForDisplay(_ records: [RiskRecord]) -> [RiskRecord] {
        func rank(_ status: RiskRecord.Status) -> Int {
            switch status {
            case .open: 0
            case .triggered: 1
            case .closedUnfired, .closedFalsified, .merged: 2
            }
        }
        return records.sorted { a, b in
            let ra = rank(a.status)
            let rb = rank(b.status)
            return ra == rb ? a.createdAt > b.createdAt : ra < rb
        }
    }

    // MARK: - 空态（DSEmptyState：虚线框 + 40px 图标盒）
}

// MARK: - 风险登记册卡（open 默认展开；其余折叠成一行摘要，点击切换）

private struct RiskCard: View {
    let record: RiskRecord
    @State private var expanded: Bool

    init(record: RiskRecord, defaultExpanded: Bool) {
        self.record = record
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s6) {
                Text(record.hypothesis)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(expanded ? nil : 1)
                Spacer(minLength: DS.Spacing.s6)
                statusBadge
            }
            if expanded {
                detail
            }
        }
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    // MARK: 状态徽章（人话三态 + 终态）
    // 配色：open=warning 在盯 · triggered=error 命中 · 终态=success 已结算 · merged=ink300 已合并

    private var badgeText: String {
        switch record.status {
        case .open: "还盯着"
        case .triggered: "被说中了"
        case .closedUnfired: "安全落地"
        case .closedFalsified: "已证伪关闭"
        case .merged: "已合并"
        }
    }

    private var badgeVariant: DSTag.Variant {
        switch record.status {
        case .open: .warning
        case .triggered: .danger
        case .closedUnfired, .closedFalsified: .success
        case .merged: .neutral
        }
    }

    private var statusBadge: some View {
        DSTag(title: badgeText, variant: badgeVariant)
    }

    private var cardFill: Color {
        switch record.status {
        case .open: Color.statusWarningSurface1
        case .triggered: Color.statusErrorSurface1
        case .closedUnfired, .closedFalsified: Color.statusSuccessSurface1
        case .merged: Color.overlayL1
        }
    }

    private var cardBorder: Color {
        switch record.status {
        case .open: Color.statusWarning.opacity(0.28)
        case .triggered: Color.statusError.opacity(0.28)
        case .closedUnfired, .closedFalsified: Color.statusSuccess.opacity(0.28)
        case .merged: Color.borderL1
        }
    }

    // MARK: 展开详情（按状态分形态）

    @ViewBuilder
    private var detail: some View {
        switch record.status {
        case .open:
            // 触发信号人话：什么时候回来核这条 💀
            HStack(spacing: DS.Spacing.s4) {
                DSIcon(.clock, size: 11)
                Text(signalText)
                    .font(DS.Font.bodyXS)
            }
            .foregroundStyle(Color.statusWarning)
        case .triggered:
            // 对照式：当初预测 vs 实际发生（resolution 缺失则提示人工回填）
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                comparisonRow(label: "当初预测", text: record.hypothesis)
                DSIcon(.down, size: 12)
                    .foregroundStyle(Color.statusError)
                comparisonRow(
                    label: "实际发生",
                    text: record.resolution ?? "需人工回填",
                    missing: record.resolution == nil
                )
            }
        case .closedUnfired, .closedFalsified, .merged:
            // 终态：结算说明（resolution 缺省回退产生来源 originRef）
            Text(record.resolution ?? record.originRef)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
        }
    }

    /// 触发信号枚举的人话（右栏展示文案）。
    private var signalText: String {
        switch record.triggerSignal {
        case .structureRegen: "结构重做时核"
        case .prototypeRegen: "原型重做时核"
        case .prdStale: "PRD 过期时核"
        case .decisionOverturned: "决策被推翻时核"
        case .release: "封板时核"
        }
    }

    private func comparisonRow(label: String, text: String, missing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
            Text(label)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
            Text(text)
                .font(DS.Font.bodyXS)
                .foregroundStyle(missing ? Color.statusAlert : Color.ink900)
        }
    }
}
