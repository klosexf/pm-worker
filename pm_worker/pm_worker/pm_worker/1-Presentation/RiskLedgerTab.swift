//
//  RiskLedgerTab.swift → 风险台账（方案 A 四态 · 版式 B 静音卡片）
//  pm_worker
//
//  右栏「风险」Tab：risks.jsonl 台账投影（append-only 读侧折叠）。
//  版式 B（2026-09-15 呼吸感改版钦定）：每条风险一张零描边明度差卡
//  （surfaceSecondary + hover 微抬亮），状态收为色点（不再用四色 tag），
//  「后果」升为警示色微标签 + 独立文本块，分区头两行（标题+计数 / 说明）。
//  来源标签（AI 自查 · 阶段）不显示——当前全员相同、信息量为零；
//  RiskRecord.originRef 数据字段保留，未来出现差异来源再按需显示。
//
//  三分区：待处理（各有方案，等决定）/ 已挂方案·等验证（跨确认门时批量核）/
//  已处理·留痕（解除 / 接受 / 旧版终态）。
//  动作：采纳方案 → 采纳落实闭环（AppModel.implementRiskAdoption：代发受理注记
//  → AI 生成实施交付物 → 流完成后 mitigating + 带证据指针的决策日志；中断保持
//  待处理可重试）或回退普通 adopt（仅记账；降级必须显式告知，2026-09-16 零反馈
//  事故口径）；接受 → accepted；已解除 → resolved；没解决 → 重开回待处理。
//  所有动作出口不许无声：失败落「⚠️ 操作失败」反馈行，反馈自身写盘失败走系统日志。
//

import SwiftUI

struct RiskLedgerTab: View {
    @EnvironmentObject private var model: AppModel

    @State private var records: [RiskRecord] = []
    /// 自评审对账 trace（self-review.jsonl 投影——B3 事件驱动改版后 covered 等
    /// 全量声明的审计归宿；对话流只报新增，此处承载「每轮都在自检」的可见性）。
    @State private var reviews: [ArtifactParser.SelfReviewEntry] = []

    var body: some View {
        Group {
            if records.isEmpty && reviews.isEmpty {
                DSEmptyState(
                    icon: .warningFill,
                    title: "暂无风险",
                    description: "自评审发现致命假设后自动登记于此，每条附「后果」与应对方案。"
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
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("pm.worker.selfreview.changed")
        )) { _ in reload() }
    }

    // MARK: - 台账（对账 trace + 三分区 · 静音卡片）

    private var ledger: some View {
        DSScroll {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.s10) {
                reviewTrace

                if !records.isEmpty {
                    statsLine
                        .padding(.bottom, DS.Spacing.s2)
                }

                let pending = records.filter { $0.status == .open }
                let hanging = records.filter { $0.status == .mitigating }
                let settled = records.filter { Self.isSettled($0) }

                if !pending.isEmpty {
                    sectionHeader("待处理", count: pending.count, tip: "各有方案，等你决定 · 采纳 ≠ 解除")
                    ForEach(pending, id: \.id) { record in
                        RiskCard(
                            record: record,
                            isGenerating: model.riskImplementationInFlightID == record.id,
                            onAction: { action, record in perform(action, record) }
                        )
                    }
                }
                if !hanging.isEmpty {
                    sectionHeader("已挂方案 · 等验证", count: hanging.count, tip: "跨确认门时批量核 · 采纳 ≠ 解除")
                    ForEach(hanging, id: \.id) { record in
                        RiskCard(
                            record: record,
                            isGenerating: model.riskImplementationInFlightID == record.id,
                            onAction: { action, record in perform(action, record) }
                        )
                    }
                }
                if !settled.isEmpty {
                    sectionHeader("已处理 · 留痕", count: settled.count, tip: nil)
                    ForEach(settled, id: \.id) { record in
                        RiskCard(
                            record: record,
                            isGenerating: false,
                            onAction: { action, record in perform(action, record) }
                        )
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.bottom, DS.Spacing.s16)
        }
    }

    private static func isSettled(_ record: RiskRecord) -> Bool {
        switch record.status {
        case .open, .mitigating: false
        default: true
        }
    }

    // MARK: - 自评审对账 trace（B3 事件驱动：计数器替代对话流仪式感）

    /// 「N 轮对账 · 累计修正 M 处」计数器 + 各轮明细（最新在前，点开看
    /// ✅ covered 清单的对账凭据；❓ 缺项 / ⏭️ 边界 / 💀 风险随行计数）。
    @ViewBuilder
    private var reviewTrace: some View {
        if !reviews.isEmpty {
            let totalFixed = reviews.reduce(0) { $0 + ($1.radar.fixed?.count ?? 0) }
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                sectionHeader(
                    "自评审对账",
                    count: reviews.count,
                    tip: "累计修正 \(totalFixed) 处 · 各轮明细可展开审计"
                )
                ForEach(
                    Array(reviews.reversed().enumerated()), id: \.offset
                ) { index, entry in
                    ReviewTraceRow(entry: entry, round: reviews.count - index)
                }
            }
        }
    }

    // MARK: - 顶部统计（四态计数）

    // 整条目换行：侧栏宽度不足时四个统计项以完整单元（数字+标签）落到下一行，
    // 不拆散条目内部文字（复用 ConversationView 的 FlowLayout 流式布局）。
    private var statsLine: some View {
        FlowLayout(spacing: DS.Spacing.s12) {
            stat("待处理", records.filter { $0.status == .open }.count, Color.statusWarning)
            stat("已挂方案", records.filter { $0.status == .mitigating }.count, Color.ink500)
            stat("已解除", records.filter { $0.status == .resolved }.count, Color.statusSuccess)
            stat("已接受", records.filter { $0.status == .accepted }.count, Color.statusPrimary)
        }
        .padding(.top, DS.Spacing.s12)
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

    // MARK: - 分区头（两行：标题+计数 / 说明——2026-09-15 钦定）

    private func sectionHeader(_ title: String, count: Int, tip: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s8) {
                Text(title)
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink500)
                Text("\(count)")
                    .font(DS.Font.bodyXSStrong)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink300)
            }
            if let tip {
                Text(tip)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                    .lineLimit(1)
            }
        }
        .padding(.top, DS.Spacing.s8)
    }

    // MARK: - 动作（文件是事实源：经 RiskStore append 新行，再整表重读；
    // 动作反馈走对话系统行——与登记 / 命中 / 跨门同款惯例，对话流可见）

    private func perform(_ action: RiskRowAction, _ record: RiskRecord) {
        NSLog("PMDBG perform entry action=\(action) id=\(record.id)") // PMDBG-TEMP
        guard let ctx = model.selection.inspectorProject else {
            // 无声出口清零（2026-09-16 零反馈事故）：上下文缺失也不许静默吞动作
            notify("⚠️ 风险台账上下文缺失，操作未执行——请切回对应项目会话后重试。")
            return
        }
        let store = RiskStore(project: ctx.project, version: ctx.version)
        // 成功反馈行只进同上下文会话（跨项目上下文时静默，台账行移位即反馈）；
        // 失败行不受此限——动作没生效必须留痕，不许 try? 静默吞掉
        let sameContext = ctx.project == model.pipeline.project
            && ctx.version == model.pipeline.version
        func fail(_ error: Error) {
            notify(
                "⚠️ 操作失败：\(error.localizedDescription)——"
                    + "「\(Self.summary(record.hypothesis))」保持原状态，可重试。"
            )
        }
        switch action {
        case .adopt:
            // 采纳落实闭环（会话上下文一致且空闲时）：代发生成实施交付物，
            // 流完成后才转「已挂方案」——状态流转由闭环收口，此处不落账
            if model.canImplementRisk(ctx) {
                Task { await model.implementRiskAdoption(record) }
                return
            }
            // 回退普通采纳（项目首页 / 封板 / 生成中）：仅记账 + 决策日志 + 反馈行。
            // 降级必须显式告知（2026-09-16 零反馈事故：静默降级 = 预期落空）
            do {
                _ = try store.adopt(id: record.id)
                if sameContext {
                    let busy = model.sessionStore.isStreaming || model.sessionStore.isPreparingReply
                    notify(
                        busy
                            ? "✅ 已采纳应对方案（生成中，按普通采纳记账，未走 AI 落实闭环）——"
                                + "「\(Self.summary(record.hypothesis))」风险挂起等验证，决策已记入日志"
                            : "✅ 已采纳应对方案——「\(Self.summary(record.hypothesis))」"
                                + "风险挂起等验证，决策已记入日志"
                    )
                }
            } catch { fail(error) }
        case .accept:
            do {
                try store.accept(id: record.id)
                if sameContext {
                    notify(
                        "📌 已接受风险——「\(Self.summary(record.hypothesis))」风险自留，"
                            + "封板时带入 PRD 已知风险"
                    )
                }
            } catch { fail(error) }
        case .resolve:
            do {
                _ = try store.resolve(id: record.id)
                if sameContext {
                    notify(
                        "✅ 风险已解除（验证通过）——「\(Self.summary(record.hypothesis))」，"
                            + "决策日志已闭环"
                    )
                }
            } catch { fail(error) }
        case .reopen:
            do {
                try store.reopen(id: record.id)
                if sameContext {
                    notify(
                        "⚠️ 风险验证未过，已重开为待处理——"
                            + "「\(Self.summary(record.hypothesis))」，方案需升级"
                    )
                }
            } catch { fail(error) }
        }
        reload()
    }

    /// 动作反馈系统行（追加进当前打开的会话流）。写盘失败不许无声
    /// （2026-09-16 零反馈事故口径）：降级走系统日志留痕。
    private func notify(_ content: String) {
        do {
            try model.sessionStore.append(
                model.sessionStore.makeEntry(role: .system, content: content)
            )
        } catch {
            NSLog("pm_worker 风险台账反馈行落盘失败：\(error.localizedDescription)")
        }
    }

    /// 系统行内文案截断（风险假设可能很长）；AppModel 落实未启动行复用同一规则。
    nonisolated static func summary(_ text: String) -> String {
        text.count <= 28 ? text : String(text.prefix(28)) + "…"
    }

    private func reload() {
        guard let ctx = model.selection.inspectorProject else {
            records = []
            reviews = []
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
        reviews = ArtifactParser.readSelfReviews(project: ctx.project, version: ctx.version)
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
    case adopt     // 采纳方案（落实闭环或普通记账 → mitigating + 决策日志）
    case accept    // 接受风险（open → accepted 自留）
    case resolve   // 已解除（mitigating → resolved + 决策日志）
    case reopen    // 没解决（mitigating → open 重开）
}

// MARK: - 对账轮行（B3 事件驱动：covered 全量声明的审计明细）

/// 一轮自评审的对账行：主行（轮序 · 阶段 · 覆盖/修正计数）可展开 ✅ covered
/// 清单 + ❓/⏭️/💀 计数行——对话流砍掉常驻声明后，每轮对账凭据的落点。
private struct ReviewTraceRow: View {
    let entry: ArtifactParser.SelfReviewEntry
    /// 全局轮序（1 起，正序编号；倒序展示由父视图换算）。
    let round: Int

    @State private var expanded = false
    @State private var hovering = false

    private var covered: [String] { entry.radar.covered ?? [] }
    private var missingCount: Int { entry.radar.missing?.count ?? 0 }
    private var skippedCount: Int { entry.radar.skipped?.count ?? 0 }
    private var fatalCount: Int { entry.radar.fatal?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Button {
                withAnimation(DS.Motion.springFast) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.s8) {
                    DSIcon(.down, size: 12)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .foregroundStyle(Color.ink300)
                    Text("第 \(round) 轮 · \(stageName)")
                        .font(DS.Font.bodySMStrong)
                        .foregroundStyle(Color.ink800)
                    Spacer(minLength: 0)
                    Text("覆盖 \(covered.count) · 修正 \(entry.radar.fixed?.count ?? 0)")
                        .font(DS.Font.mono2XS)
                        .foregroundStyle(Color.ink500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                    Text("已覆盖")
                        .font(DS.Font.bodyXSStrong)
                        .foregroundStyle(Color.ink500)
                    if covered.isEmpty {
                        Text("（本轮未列具体覆盖项）")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink300)
                    } else {
                        ForEach(Array(covered.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: DS.Spacing.s6) {
                                DSIcon(.circleCheck, size: 12)
                                    .foregroundStyle(Color.statusSuccess)
                                    .padding(.top, 2)
                                Text(item)
                                    .font(DS.Font.bodyXS)
                                    .foregroundStyle(Color.ink700)
                            }
                        }
                    }
                    Text(
                        "缺项 \(missingCount) · 边界 \(skippedCount) · 风险 \(fatalCount)"
                    )
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(Color.ink500)
                }
                .padding(DS.Spacing.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .fill(Color.overlayL1)
                )
            }
        }
        .padding(.horizontal, DS.Spacing.s4)
        .padding(.vertical, DS.Spacing.s6)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(hovering ? Color.overlayL1 : Color.surfaceSecondary)
        )
        .onHover { hovering = $0 }
    }

    /// 阶段 key → 人话（对账行头用）。
    private var stageName: String {
        switch entry.stage {
        case "clarify": "澄清"
        case "structure": "结构"
        case "prototype": "原型"
        default: "PRD"
        }
    }
}

// MARK: - 风险卡（版式 B：零描边明度差卡 · 状态色点 · 后果微标签）

private struct RiskCard: View {
    let record: RiskRecord
    let isGenerating: Bool
    let onAction: (RiskRowAction, RiskRecord) -> Void

    @State private var expanded: Bool
    @State private var hovering = false

    init(
        record: RiskRecord,
        isGenerating: Bool,
        onAction: @escaping (RiskRowAction, RiskRecord) -> Void
    ) {
        self.record = record
        self.isGenerating = isGenerating
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
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .fill(Color.surfaceSecondary)
        )
        // hover 微抬亮（零描边零阴影，明度差即层级——弹框钦定模式）
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .fill(hovering && isInteractive ? Color.overlayL2 : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { NSLog("PMDBG RiskCard hover=\($0) id=\(record.id)"); hovering = $0 } // PMDBG-TEMP
        .onTapGesture {
            NSLog("PMDBG RiskCard tapGesture fired id=\(record.id)") // PMDBG-TEMP
            guard isInteractive, hasDetail else { return }
            withAnimation(DS.Motion.springFast) { expanded.toggle() }
        }
    }

    // MARK: 主行（色点 + 风险标题 + 展开提示）

    private var main: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s10) {
                statusDot
                    .padding(.top, 5)
                Text(record.hypothesis)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(record.isActive ? Color.ink900 : Color.ink700)
                    .lineLimit(expanded ? nil : 2)
                Spacer(minLength: DS.Spacing.s8)
                if isInteractive, hasDetail {
                    Text(expanded ? "收起" : "展开")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                }
            }
            if let impact = record.impact, !impact.isEmpty {
                HStack(alignment: .top, spacing: DS.Spacing.s8) {
                    Text("后果")
                        .font(DS.Font.bodyXS)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.statusWarning)
                        .padding(.horizontal, DS.Spacing.s6)
                        .padding(.vertical, DS.Spacing.s3)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm)
                                .fill(Color.statusWarningSurface1)
                        )
                    Text(impact)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink700)
                        .lineLimit(expanded ? nil : 2)
                }
                .padding(.leading, DS.Spacing.s16)
            }
        }
        .padding(.leading, DS.Spacing.s12)
        .padding(.trailing, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s12)
    }

    // MARK: 详情（按状态分形态）

    private var hasDetail: Bool {
        record.status == .open || record.status == .mitigating
    }

    @ViewBuilder
    private var detail: some View {
        switch record.status {
        case .open where isGenerating:
            // 落实生成中：方案与动作暂收，脉冲点 + 进度文案（状态未落，可停止）
            HStack(spacing: DS.Spacing.s8) {
                PulsingDot()
                Text("正在生成实施交付物…（完成后转「已挂方案」）")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.Spacing.s12)
            .padding(.trailing, DS.Spacing.s12)
            .padding(.bottom, DS.Spacing.s12)
        case .open:
            // 方案卡 + 两动作：采纳（主，走落实闭环）/ 接受（自留）
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                planCard(label: "建议方案", tint: Color.statusWarning)
                HStack(spacing: DS.Spacing.s6) {
                    Button {
                        NSLog("PMDBG adopt button FIRED id=\(record.id)") // PMDBG-TEMP
                        onAction(.adopt, record)
                    } label: {
                        Text("采纳方案")
                    }
                    .buttonStyle(DSButtonStyle(variant: .brand, size: .xs))
                    .help("AI 先把方案落实成执行包，完成后转「已挂方案」并写入决策日志")

                    Button {
                        NSLog("PMDBG accept button FIRED id=\(record.id)") // PMDBG-TEMP
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
            .padding(.trailing, DS.Spacing.s12)
            .padding(.bottom, DS.Spacing.s12)
        case .mitigating:
            // 已挂方案 + 证据留痕 + 验证动作：跨门核验或随手核
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                planCard(label: "已挂方案", tint: Color.statusPrimary)
                if record.resolution?.contains("实施证据") == true {
                    Text("实施证据 · 见采纳回合的对话留痕")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                }
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
            .padding(.trailing, DS.Spacing.s12)
            .padding(.bottom, DS.Spacing.s12)
        default:
            EmptyView()
        }
    }

    private func planCard(label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            Text(label)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(tint)
            Text(record.plan ?? "（未提供——与 AI 对话补充应对方案）")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink800)
        }
        .padding(DS.Spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.overlayL1)
        )
        // 零描边（弹框钦定模式）：明度差即容器
    }

    // MARK: 状态口径

    private var isInteractive: Bool {
        record.status == .open || record.status == .mitigating
    }

    /// 状态色点（tag 全撤——分区已表达状态，点只做扫读锚）
    private var statusDot: some View {
        Circle()
            .fill(dotTint)
            .frame(width: 7, height: 7)
    }

    private var dotTint: Color {
        switch record.status {
        case .open: Color.statusWarning
        case .mitigating: Color.statusPrimary
        case .resolved: Color.statusSuccess
        case .accepted: Color.statusPrimary
        case .triggered: Color.statusError
        case .closedUnfired, .closedFalsified, .merged: Color.ink300
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

// MARK: - 脉冲点（落实生成中）

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.statusWarning)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.35 : 1.0)
            .opacity(pulsing ? 0.5 : 1.0)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
