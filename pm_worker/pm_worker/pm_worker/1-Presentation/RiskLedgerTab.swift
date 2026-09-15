//
//  RiskRadarTab.swift → 风险台账（方案 A 四态版）
//  pm_worker
//
//  右栏「风险」Tab：risks.jsonl 台账投影（append-only 读侧折叠）。
//  三分区：待处理（各有方案，等决定）/ 已挂方案·等验证（跨确认门时批量核）/
//  已处理·留痕（解除 / 接受 / 旧版终态）。
//  行内两层：风险 + 「炸了会怎样」常显；方案卡展开；动作直连 RiskStore
//  （采纳方案 → mitigating + 决策日志；接受 → accepted；已解除 → resolved；
//  没解决 → 重开回待处理）。状态以行尾徽标区分（四色 tag）。
//

import SwiftUI

struct RiskLedgerTab: View {
    @EnvironmentObject private var model: AppModel

    @State private var records: [RiskRecord] = []

    var body: some View {
        Group {
            if records.isEmpty {
                DSEmptyState(
                    icon: .warningFill,
                    title: "暂无风险",
                    description: "自评审发现致命假设后自动登记于此，每条附「炸了会怎样」与应对方案。"
                )
            } else {
                ledger
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.selection) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("pm.worker.risks.changed")
        )) { _ in reload() }
    }

    // MARK: - 台账（三分区）

    private var ledger: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                statsLine

                let pending = records.filter { $0.status == .open }
                let hanging = records.filter { $0.status == .mitigating }
                let settled = records.filter { Self.isSettled($0) }

                if !pending.isEmpty {
                    sectionHeader("待处理", tip: "各有方案，等你决定")
                    ForEach(pending, id: \.id) { record in
                        RiskRow(record: record, onAction: { action, record in
                            perform(action, record)
                        })
                    }
                }
                if !hanging.isEmpty {
                    sectionHeader("已挂方案 · 等验证", tip: "采纳 ≠ 解除 · 跨确认门时批量核")
                    ForEach(hanging, id: \.id) { record in
                        RiskRow(record: record, onAction: { action, record in
                            perform(action, record)
                        })
                    }
                }
                if !settled.isEmpty {
                    sectionHeader("已处理 · 留痕", tip: nil)
                    ForEach(settled, id: \.id) { record in
                        RiskRow(record: record, onAction: { action, record in
                            perform(action, record)
                        })
                    }
                }
            }
            .padding(.bottom, DS.Spacing.s16)
        }
    }

    private static func isSettled(_ record: RiskRecord) -> Bool {
        switch record.status {
        case .open, .mitigating: false
        default: true
        }
    }

    // MARK: - 顶部统计（四态计数）

    private var statsLine: some View {
        HStack(spacing: DS.Spacing.s12) {
            stat("待处理", records.filter { $0.status == .open }.count, Color.statusWarning)
            stat("已挂方案", records.filter { $0.status == .mitigating }.count, Color.ink500)
            stat("已解除", records.filter { $0.status == .resolved }.count, Color.statusSuccess)
            stat("已接受", records.filter { $0.status == .accepted }.count, Color.statusPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.top, DS.Spacing.s12)
        .padding(.bottom, DS.Spacing.s8)
    }

    private func stat(_ label: String, _ count: Int, _ tint: Color) -> some View {
        HStack(spacing: DS.Spacing.s4) {
            Text("\(count)")
                .font(DS.Font.bodySMStrong)
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
        }
    }

    // MARK: - 分区头（mono 小字 + hairline）

    private func sectionHeader(_ title: String, tip: String?) -> some View {
        HStack(spacing: DS.Spacing.s8) {
            Text(title)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.ink500)
            if let tip {
                Text(tip)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                    .lineLimit(1)
            }
            Rectangle()
                .fill(Color.borderL1)
                .frame(height: 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.top, DS.Spacing.s10)
        .padding(.bottom, DS.Spacing.s4)
    }

    // MARK: - 动作（文件是事实源：经 RiskStore append 新行，再整表重读）

    private func perform(_ action: RiskRowAction, _ record: RiskRecord) {
        let ctx = model.selection.inspectorProject
        guard let ctx else { return }
        let store = RiskStore(project: ctx.project, version: ctx.version)
        do {
            switch action {
            case .adopt:
                _ = try store.adopt(id: record.id)
            case .accept:
                try store.accept(id: record.id)
            case .resolve:
                _ = try store.resolve(id: record.id)
            case .reopen:
                try store.reopen(id: record.id)
            }
        } catch {
            // 状态已被其他入口流转：静默重读对齐磁盘口径
        }
        reload()
    }

    private func reload() {
        guard let ctx = model.selection.inspectorProject else {
            records = []
            return
        }
        records = RiskStore.collapse(
            PMAgentStore.readLines(
                RiskRecord.self,
                from: PMAgentStore.jsonlURL(
                    project: ctx.project, version: ctx.version, file: "risks.jsonl"
                )
            )
        )
        .sorted { a, b in
            let ra = Self.displayRank(a.status)
            let rb = Self.displayRank(b.status)
            return ra == rb ? a.createdAt > b.createdAt : ra < rb
        }
    }

    /// 展示序：待处理 → 已挂 → 已处理；组内按时间倒序。
    nonisolated private static func displayRank(_ status: RiskRecord.Status) -> Int {
        switch status {
        case .open: 0
        case .mitigating: 1
        default: 2
        }
    }
}

// MARK: - 行动作枚举

enum RiskRowAction {
    case adopt     // 采纳方案（open → mitigating + 决策日志）
    case accept    // 接受风险（open → accepted 自留）
    case resolve   // 已解除（mitigating → resolved + 决策日志）
    case reopen    // 没解决（mitigating → open 重开）
}

// MARK: - 风险行（两层：风险常显 · 方案卡展开）

private struct RiskRow: View {
    let record: RiskRecord
    let onAction: (RiskRowAction, RiskRecord) -> Void

    @State private var expanded: Bool

    init(record: RiskRecord, onAction: @escaping (RiskRowAction, RiskRecord) -> Void) {
        self.record = record
        self.onAction = onAction
        // 待处理默认展开方案卡（决策依据要一眼可见）；已挂 / 终态默认收起
        _expanded = State(initialValue: record.status == .open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            main
            if expanded, hasDetail {
                detail
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.borderL1)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isInteractive, hasDetail else { return }
            withAnimation(DS.Motion.springFast) { expanded.toggle() }
        }
    }

    // MARK: 主行（风险 + 炸了会怎样 + 状态）

    private var main: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s8) {
                Text(record.hypothesis)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(record.isActive ? Color.ink900 : Color.ink700)
                    .lineLimit(expanded ? nil : 2)
                Spacer(minLength: DS.Spacing.s8)
                statusTag
            }
            if let impact = record.impact, !impact.isEmpty {
                Text("炸了会怎样：\(impact)")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(2)
            }
            HStack(spacing: DS.Spacing.s8) {
                Text(record.originRef)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                if let resolution = record.resolution, !resolution.isEmpty,
                   record.status == .mitigating || Self.isSettled(record) {
                    Text(resolution)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isInteractive, hasDetail {
                    Text(expanded ? "收起" : "展开")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                }
            }
        }
        .padding(.leading, DS.Spacing.s12)
        .padding(.trailing, DS.Spacing.s10)
        .padding(.vertical, DS.Spacing.s8)
    }

    // MARK: 详情（按状态分形态）

    private var hasDetail: Bool {
        record.status == .open || record.status == .mitigating
    }

    @ViewBuilder
    private var detail: some View {
        switch record.status {
        case .open:
            // 方案卡 + 两动作：采纳（主，写决策日志）/ 接受（自留）
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                planCard(label: "建议方案")
                HStack(spacing: DS.Spacing.s6) {
                    Button {
                        onAction(.adopt, record)
                    } label: {
                        Text("采纳方案")
                    }
                    .buttonStyle(DSButtonStyle(variant: .brand, size: .xs))
                    .help("挂上方案等验证（≠ 解除），并写入决策日志")

                    Button {
                        onAction(.accept, record)
                    } label: {
                        Text("接受风险")
                    }
                    .buttonStyle(DSButtonStyle(variant: .secondary, size: .xs))
                    .help("风险自留——封板时写入 PRD 已知风险")

                    Text("采纳 ≠ 解除 · 先挂上等验证")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, DS.Spacing.s12)
            .padding(.trailing, DS.Spacing.s10)
            .padding(.bottom, DS.Spacing.s10)
        case .mitigating:
            // 已挂方案 + 验证动作：跨门核验或随手核
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                planCard(label: "已挂方案")
                HStack(spacing: DS.Spacing.s6) {
                    Button {
                        onAction(.resolve, record)
                    } label: {
                        Text("✓ 已解除")
                    }
                    .buttonStyle(DSButtonStyle(variant: .brand, size: .xs))
                    .help("方案落地后确认没出事——写入决策日志，风险关闭")

                    Button {
                        onAction(.reopen, record)
                    } label: {
                        Text("✕ 没解决")
                    }
                    .buttonStyle(DSButtonStyle(variant: .dangerSubtle, size: .xs))
                    .help("验证未过——重开回待处理，方案需升级")

                    Text("跨「\(Self.stageTitle(record.stage))」确认门时批量核")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, DS.Spacing.s12)
            .padding(.trailing, DS.Spacing.s10)
            .padding(.bottom, DS.Spacing.s10)
        default:
            EmptyView()
        }
    }

    private func planCard(label: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            Text(label)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(Color.statusWarning)
            Text(record.plan ?? "（未提供——与 AI 对话补充应对方案）")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink800)
        }
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.overlayL1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }

    // MARK: 状态口径

    private var isInteractive: Bool {
        record.status == .open || record.status == .mitigating
    }

    private var statusTag: some View {
        DSTag(title: RiskStatusPresentation.text(record.status), variant: tagVariant)
    }

    private var tagVariant: DSTag.Variant {
        switch record.status {
        case .open: .warning
        case .mitigating: .neutral
        case .resolved, .accepted: .success
        case .triggered: .danger
        case .closedUnfired, .closedFalsified, .merged: .neutral
        }
    }

    private static func isSettled(_ record: RiskRecord) -> Bool {
        switch record.status {
        case .open, .mitigating: false
        default: true
        }
    }

    /// 阶段 → 人话（跨门提示用）。
    nonisolated private static func stageTitle(_ stage: RiskRecord.Stage) -> String {
        switch stage {
        case .clarify: "澄清"
        case .structure: "结构"
        case .prototype: "原型"
        case .prd: "PRD"
        }
    }
}
