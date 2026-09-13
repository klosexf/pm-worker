//
//  UsagePanel.swift
//  pm_worker
//
//  成本统计面板（M5 Task 5.4）：本次会话 / 本月 token 用量与费用（¥）。
//  数据源 CostTracker（内存 session + JSONL month 聚合），onAppear + 5s 定时刷新。
//  视觉还原 Wave 3-B：金额主数字（headingLG / ink900）。
//  2026-09-12 Xcode 质感对齐：弃统计卡容器——扁平行列表 + hairline 分隔，
//  与设置弹框偏好面板形制统一（仅设置弹框「用量」页使用）。
//

import Combine
import SwiftUI

struct UsagePanel: View {
    @State private var session = Aggregation()
    @State private var month = Aggregation()
    @State private var stageUsages: [StageUsage] = []

    /// 打开期间定时刷新（月聚合读 JSONL，代价低；数据非关键可容忍 5s 滞后）。
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s20) {
            sessionGroup
            monthGroup
        }
        .onAppear(perform: reload)
        .onReceive(refreshTimer) { _ in reload() }
    }

    // MARK: - 本次会话

    private var sessionGroup: some View {
        usageGroup("本次会话（App 启动至今）") {
            usageAmountRow("费用估算", costText(session.costCNY))

            usageDivider()

            usageRow("调用次数", "\(session.calls)")
            usageDivider()
            usageRow("输入 tokens", "\(session.promptTokens)")
            usageDivider()
            usageRow("输出 tokens", "\(session.completionTokens)")
            usageDivider()
            usageRow("估算占比", estimatedShare(session))
        }
    }

    // MARK: - 本月

    private var monthGroup: some View {
        usageGroup("本月（\(currentMonthTitle)）") {
            usageAmountRow("费用估算", costText(month.costCNY))

            usageDivider()

            usageRow("调用次数", "\(month.calls)")
            usageDivider()
            usageRow("输入 tokens", "\(month.promptTokens)")
            usageDivider()
            usageRow("输出 tokens", "\(month.completionTokens)")

            if !stageUsages.isEmpty {
                usageDivider()

                ForEach(stageUsages) { stage in
                    usageRow(
                        stageDisplayName(stage.stage),
                        "\(stage.calls) 次 · "
                            + "\(stage.promptTokens + stage.completionTokens) tokens · "
                            + costText(stage.costCNY),
                        secondary: true
                    )
                }
            }

            if !month.unknownPriceModels.isEmpty {
                DSAlert(
                    variant: .warning,
                    title: "无法计价：\(month.unknownPriceModels.sorted().joined(separator: "、"))",
                    description: "以上模型未收录单价，费用统计不含这些模型的调用"
                )
                .padding(.vertical, DS.Spacing.s10)
            }

            Text("金额按官方牌价估算（DeepSeek 分峰谷 / 缓存档；第三方网关实价可能不同），以供应商账单为准")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, DS.Spacing.s10)
        }
    }

    // MARK: - 行组件（Xcode 偏好面板行范式）

    /// 行组：小灰组头 + 行列表（行间距 0，分隔线由行间显式放置）。
    private func usageGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Text(title)
                .font(DS.Font.bodySMStrong)
                .monospacedDigit()
                .foregroundStyle(Color.ink500)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 金额主数字行：label 左、headingLG 大数字右（面板唯一的「大字时刻」）。
    private func usageAmountRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s16) {
            Text(title)
                .font(DS.Font.bodyMD)
                .foregroundStyle(Color.ink900)
            Spacer(minLength: DS.Spacing.s16)
            Text(value)
                .font(DS.Font.headingLG)
                .dsTight()
                .monospacedDigit()
                .foregroundStyle(Color.ink900)
        }
        .padding(.vertical, DS.Spacing.s10)
    }

    /// 统计行：label 左、数值右（secondary = 分阶段明细等次级行，用 SM 档）。
    private func usageRow(_ title: String, _ value: String, secondary: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s16) {
            Text(title)
                .font(secondary ? DS.Font.bodySM : DS.Font.bodyMD)
                .foregroundStyle(secondary ? Color.ink700 : Color.ink900)
            Spacer(minLength: DS.Spacing.s16)
            Text(value)
                .font(secondary ? DS.Font.bodySM : DS.Font.bodyMD)
                .monospacedDigit()
                .foregroundStyle(secondary ? Color.ink500 : Color.ink900)
        }
        .padding(.vertical, DS.Spacing.s10)
    }

    private func usageDivider() -> some View {
        DSDivider()
    }

    // MARK: - 工具

    private func reload() {
        session = CostTracker.shared.session
        let (year, monthNumber) = Self.currentYearMonth()
        month = CostTracker.shared.month(year: year, month: monthNumber)
        stageUsages = CostTracker.shared.monthStages(year: year, month: monthNumber)
    }

    private var currentMonthTitle: String {
        let (year, monthNumber) = Self.currentYearMonth()
        return "\(year) 年 \(monthNumber) 月"
    }

    nonisolated private static func currentYearMonth() -> (Int, Int) {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        return (components.year ?? 0, components.month ?? 0)
    }

    /// 估算占比（estimated 调用 / 总调用）。
    private func estimatedShare(_ agg: Aggregation) -> String {
        guard agg.calls > 0 else { return "—" }
        return "\(Int((Double(agg.estimatedCalls) / Double(agg.calls) * 100).rounded()))%"
    }

    /// 费用显示：¥x.xx（人民币元）。
    private func costText(_ value: Double) -> String {
        "¥\(String(format: "%.2f", value))"
    }

    private func stageDisplayName(_ raw: String) -> String {
        LLMStage(rawValue: raw)?.displayName ?? raw
    }
}
