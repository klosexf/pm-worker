//
//  DeveloperInspector.swift
//  pm_worker
//
//  开发者模式检查器（Task 4.6，⌘D 独立窗口）：token 构成条（五段比例 + 裁剪红标）、
//  检索 trace（命中 / 未命中技能 / 跨项目过滤 / 耗时）、分支触发记录、
//  主动推荐 trace、记忆校准注入（假设态）、风险登记册工程口径、注入技能正文。
//  全部真实数据（AppModel 可观测状态），空态如实标注。
//  视觉还原 Wave 3-B：区头 + 卡片分组；比例条用品牌/状态色系；数据行 mono。
//

import SwiftUI

struct DeveloperInspector: View {
    @EnvironmentObject private var model: AppModel
    /// 知识点 Tab 最近一次手动检索（跨窗口共享，实时联动）。
    @ObservedObject private var searchLog = SearchTraceLog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s20) {
                tokenSection
                retrievalSection
                branchSection
                recommendationSection
                calibrationSection
                riskSection
                skillBodySection
            }
            .padding(DS.Spacing.s20)
        }
        .frame(minWidth: 600, minHeight: 520)
    }

    // MARK: - a. token 构成条（五段横向比例 + 裁剪红标 + 总量/预算）

    private var tokenSection: some View {
        section("Token 构成（最近一次组装）") {
            if let breakdown = model.lastAssembly?.breakdown {
                TokenBarView(breakdown: breakdown)
                    .frame(height: 22)
                ForEach(ContextSegment.allCases, id: \.rawValue) { segment in
                    segmentLegendRow(breakdown, segment)
                }
                HStack {
                    Text(
                        "总量 \(breakdown.total) / 预算 \(breakdown.budget) token"
                            + "（\(Self.usagePercent(breakdown))%）"
                    )
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink700)
                    Spacer()
                    if !breakdown.trimmed.isEmpty {
                        Text("已裁剪：\(breakdown.trimmed.map(\.rawValue).joined(separator: "、"))")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.statusError)
                    }
                }
            } else {
                emptyRow("尚未组装——发送首条消息后由 Context Builder 填充")
            }
        }
    }

    private func segmentLegendRow(
        _ breakdown: TokenBreakdown, _ segment: ContextSegment
    ) -> some View {
        let count = breakdown.segments[segment] ?? 0
        let trimmed = breakdown.trimmed.contains(segment)
        return HStack(spacing: DS.Spacing.s6) {
            RoundedRectangle(cornerRadius: DS.Radius.xs)
                .fill(Self.segmentColor(segment))
                .frame(width: 10, height: 10)
            Text(Self.segmentName(segment))
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink700)
            Spacer()
            if trimmed {
                Text("已裁剪")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.statusError)
                    .padding(.horizontal, DS.Spacing.s6)
                    .padding(.vertical, DS.Spacing.s2)
                    .background(Capsule().fill(Color.statusErrorSurface1))
            }
            Text("\(count) token")
                .font(DS.Font.monoSM)
                .foregroundStyle(trimmed ? Color.statusError : Color.ink500)
        }
    }

    // MARK: - b. 检索 trace

    private var retrievalSection: some View {
        section("检索 trace") {
            if let retrieval = model.lastAssembly?.retrieval {
                TraceDetailView(trace: retrieval)
            } else {
                emptyRow("最近一次组装未携带检索 trace")
            }
            if let manual = searchLog.last {
                DSDivider()
                Text("知识点 Tab 最近手动检索")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink300)
                TraceDetailView(trace: manual)
            }
        }
    }

    // MARK: - c. 分支触发记录

    private var branchSection: some View {
        section("分支触发记录") {
            if model.branchTriggers.isEmpty {
                emptyRow("暂无分支触发记录（竞品分析等分支启动时追加）")
            } else {
                ForEach(model.branchTriggers) { record in
                    VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                        HStack {
                            Text(record.kind)
                                .font(DS.Font.bodySMStrong)
                                .foregroundStyle(Color.ink900)
                            Spacer()
                            Text(record.createdAt)
                                .font(DS.Font.monoSM)
                                .foregroundStyle(Color.ink300)
                        }
                        Text(record.detail)
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                    }
                }
            }
        }
    }

    // MARK: - d1. 主动推荐 trace（当前推荐 + 已拒 + 理由）

    private var recommendationSection: some View {
        section("主动推荐 trace（阶段 \(model.pipeline.stage.rawValue)）") {
            if model.recommendations.isEmpty {
                emptyRow("当前阶段无推荐")
            } else {
                ForEach(model.recommendations) { rec in
                    VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                        HStack(spacing: DS.Spacing.s6) {
                            Text(rec.title)
                                .font(DS.Font.bodySMStrong)
                                .foregroundStyle(Color.ink900)
                            ScopeBadge(scope: rec.scope)
                            Spacer()
                            Text("相关度 \(Int((rec.score * 100).rounded()))%")
                                .font(DS.Font.monoSM)
                                .foregroundStyle(Color.ink500)
                        }
                        Text(rec.reason)
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                    }
                }
            }
            if !model.rejectedCards.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text("本阶段已拒 \(model.rejectedCards.count) 个（同阶段不重复推荐）")
                        .font(DS.Font.bodyXSStrong)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink300)
                    ForEach(model.rejectedCards.sorted(), id: \.self) { id in
                        Text("· \(id)")
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink300)
                    }
                }
            }
        }
    }

    // MARK: - d2. 记忆校准注入 trace（假设态标签）

    private var calibrationSection: some View {
        section("记忆校准注入 trace（假设态）") {
            if let calibration = model.lastAssembly?.calibration, !calibration.isEmpty {
                ForEach(calibration, id: \.self) { line in
                    Label {
                        Text(line)
                    } icon: {
                        DSIcon(.flask, size: 14)
                    }
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                }
            } else {
                emptyRow("本次组装未注入记忆校准（无相关经验或未采纳推荐）")
            }
        }
    }

    // MARK: - e. 风险登记册工程口径（原始枚举值，非人话版）

    private var riskSection: some View {
        section("风险登记册（工程口径 · \(model.risks.project)/\(model.risks.version)）") {
            let records = model.risks.risks
            if records.isEmpty {
                emptyRow("risks.jsonl 无记录")
            } else {
                HStack(alignment: .top, spacing: DS.Spacing.s6) {
                    Text("status：")
                        .font(DS.Font.bodyXSStrong)
                        .foregroundStyle(Color.ink300)
                    Text(Self.countLine(records) { $0.status.rawValue })
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink700)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: DS.Spacing.s6) {
                    Text("trigger_signal：")
                        .font(DS.Font.bodyXSStrong)
                        .foregroundStyle(Color.ink300)
                    Text(Self.countLine(records) { $0.triggerSignal?.rawValue ?? "none" })
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink700)
                        .textSelection(.enabled)
                }
                ForEach(records, id: \.id) { record in
                    VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                        Text(record.hypothesis)
                            .font(DS.Font.bodySM)
                            .foregroundStyle(Color.ink900)
                        Text("\(record.triggerSignal?.rawValue ?? "none") · \(record.status.rawValue)")
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink300)
                    }
                }
            }
        }
    }

    // MARK: - f. 注入技能正文（渐进式披露证明）

    private var skillBodySection: some View {
        section("注入技能正文（渐进式披露）") {
            if let bodies = model.lastAssembly?.injectedSkillBodies, !bodies.isEmpty {
                ForEach(bodies, id: \.self) { body in
                    Text(body)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink700)
                        .lineLimit(4)
                        .help(body)
                }
                Text("共 \(bodies.count) 段正文注入——未命中技能不注入（见检索 trace 的未命中列表）")
                    .font(DS.Font.bodyXS)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink300)
            } else {
                emptyRow("本次组装未注入技能正文")
            }
        }
    }

    // MARK: - 私有工具

    /// 区头（headingXS + ink500）+ 卡片分组。
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            Text(title)
                .font(DS.Font.headingXS)
                .foregroundStyle(Color.ink500)
            VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(padding: DS.Spacing.s16)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            DSIcon(.clock, size: 14)
        }
        .font(DS.Font.bodyXS)
        .foregroundStyle(Color.ink500)
    }

    private static func usagePercent(_ breakdown: TokenBreakdown) -> Int {
        Int((Double(breakdown.total) / Double(max(breakdown.budget, 1)) * 100).rounded())
    }

    /// 枚举原值计数行（key 升序保证稳定输出）。
    private static func countLine(
        _ records: [RiskRecord], _ key: (RiskRecord) -> String
    ) -> String {
        Dictionary(grouping: records, by: key)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " · ")
    }

    /// 五段色（品牌/状态色系）：规则=primary / 记忆=success / 技能正文=brand /
    /// 检索=alert / 历史=ink。
    static func segmentColor(_ segment: ContextSegment) -> Color {
        switch segment {
        case .rules: Color.statusPrimary
        case .memory: Color.statusSuccess
        case .skillBodies: Color.brand600
        case .retrieval: Color.statusAlert
        case .history: Color.ink300
        }
    }

    static func segmentName(_ segment: ContextSegment) -> String {
        switch segment {
        case .rules: "规则"
        case .memory: "记忆"
        case .skillBodies: "技能正文"
        case .retrieval: "检索"
        case .history: "历史"
        }
    }
}

// MARK: - 五段横向比例条（系统 Rectangle 原生实现；被裁剪段红框标）

private struct TokenBarView: View {
    let breakdown: TokenBreakdown

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(ContextSegment.allCases, id: \.rawValue) { segment in
                    let count = breakdown.segments[segment] ?? 0
                    if count > 0, breakdown.total > 0 {
                        Rectangle()
                            .fill(DeveloperInspector.segmentColor(segment))
                            .frame(
                                width: max(
                                    proxy.size.width * CGFloat(count) / CGFloat(breakdown.total),
                                    2
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 1)
                                    .strokeBorder(
                                        breakdown.trimmed.contains(segment)
                                            ? Color.statusError : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                }
            }
        }
    }
}

// MARK: - 检索 trace 详情（query / 命中 / 未命中技能 / 跨项目过滤 / 耗时）

private struct TraceDetailView: View {
    let trace: RetrievalTrace

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s6) {
                Text("query")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink300)
                Text(String(trace.query.prefix(80)))
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
                    .help(trace.query)
                Spacer()
                Text("\(trace.durationMs)ms")
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
            }
            ForEach(trace.hits) { hit in
                HStack(spacing: DS.Spacing.s6) {
                    DSIcon(hit.library == .cards ? .document : .automation, size: 12)
                        .foregroundStyle(Color.ink500)
                    Text(hit.id)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink900)
                        .lineLimit(1)
                    ScopeBadge(scope: hit.scope)
                    Spacer()
                    Text("\(Int((hit.score * 100).rounded()))%")
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink500)
                }
            }
            if !trace.unmatchedSkills.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s3) {
                    Text("未命中技能（未注入正文）")
                        .font(DS.Font.bodyXSStrong)
                        .foregroundStyle(Color.ink300)
                    ForEach(trace.unmatchedSkills, id: \.self) { id in
                        Text("· \(id)")
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink300)
                    }
                }
            }
            Text("已过滤 \(trace.filteredCrossProject) 条跨项目内容")
                .font(DS.Font.bodyXS)
                .foregroundStyle(
                    trace.filteredCrossProject > 0
                        ? AnyShapeStyle(Color.statusAlert) : AnyShapeStyle(Color.ink300)
                )
        }
    }
}
