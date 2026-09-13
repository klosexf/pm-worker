//
//  DecisionLogTab.swift
//  pm_worker
//
//  右栏「决策日志」Tab：decisions.jsonl 只读投影（design.md §5.2 / §6.4）。
//  决策与 💀 命中回写混排（DecisionLogEntry 判别解码）；决策卡点击展开
//  详情（决策理由 / 排除方案），状态色收敛到元信息行徽章（待验证=warning）；
//  risk_hit 条目为红色调事件卡。
//

import SwiftUI

struct DecisionLogTab: View {
    @EnvironmentObject private var model: AppModel

    /// 展示行：加载时一次性构建（UUID 稳定标识 ForEach）。
    private struct Row: Identifiable {
        let id = UUID()
        let entry: DecisionLogEntry
    }

    @State private var rows: [Row] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                DSEmptyState(
                    icon: .barList,
                    title: "尚无决策记录",
                    description: "决策记录在任务执行中写入 decisions.jsonl——尚无记录，不是缺失。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.s8) {
                        Text("共 \(rows.count) 条")
                            .font(DS.Font.bodyXS)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink500)
                        ForEach(rows) { row in
                            switch row.entry {
                            case .decision(let record):
                                DecisionCard(record: record)
                            case .riskHit(let record):
                                RiskHitCard(record: record)
                            }
                        }
                    }
                    .padding(DS.Spacing.s12)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.selection) { _, _ in reload() }
    }

    // MARK: - 数据（decisions.jsonl 只读）

    private func reload() {
        guard let ctx = model.selection.inspectorProject else {
            rows = []
            return
        }
        rows = PMAgentStore.readLines(
            DecisionLogEntry.self,
            from: PMAgentStore.jsonlURL(
                project: ctx.project, version: ctx.version, file: "decisions.jsonl"
            )
        )
        // append-only：文件序即时间序，倒读即 createdAt 倒序
        //（risk_hit 无 createdAt，保持与决策的穿插时序）。
        .reversed()
        .map { Row(entry: $0) }
    }

    // MARK: - 空态（DSEmptyState：虚线框 + 40px 图标盒）
}

// MARK: - 决策卡（层级化排版：结论 14 semibold 主导 + 元信息行 + 展开分节详情）
// 与中栏 DecisionLogPage 的卡片同构双份（改一处同步另一处）。
// 设计纪律：卡片中性底色（状态色只留在徽章这一小块），结论与论据拉开两级字重。

private struct DecisionCard: View {
    let record: DecisionRecord
    /// 跨项目「全部」视图的归属提示；本 Tab 单项目上下文恒为 nil。
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

            // 元信息区：状态徽章 + 时间（扫读上下文）+ 展开指示
            HStack(spacing: DS.Spacing.s8) {
                statusBadge
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
    /// 跨项目「全部」视图的归属提示；本 Tab 单项目上下文恒为 nil。
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
