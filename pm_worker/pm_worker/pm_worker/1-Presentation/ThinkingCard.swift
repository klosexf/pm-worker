//
//  ThinkingCard.swift
//  pm_worker
//
//  思考过程两态展示（Task 2.7，design.md §6.4.1；2026-09-12 起纯文字化——
//  去掉胶囊底/步骤区底框，对齐 Trae 对话「思考过程 ›」样式）：
//  - 思考中：品牌色 pulse 圆点 + 「正在思考…」think-sweep 流光扫字（2.4s 循环，
//    原型 .think-live/.run-dot，长静默期防假死感；减弱动态时降级纯文本）；
//    确认链多跳阶段时间线（2026-09-18，DSH 左脊时间线轻量版）——已完成跳打勾、
//    当前跳流光，长等待显性化为可见进度
//  - 已完成：折叠摘要行「思考了 Ns · <技能> · 工具 ×N」，有结构化行时可点展开
//
//  **本视图不渲染模型原始思维链**（2026-09-22 收口，恢复 design.md v0.9.6 口径：
//  推理步骤是面向用户可读的摘要，不是 CoT 本身）。曾经的 09-18 改版把 reasoning
//  原文接进了流式展开区、完成态全文区和折叠摘要行的「收束句」，实测漏出的是
//  「memory injection already gives me what I need」这类内部机制自述——违反
//  AGENTS.md「用户信息展示规范」。原文只落盘（DeepSeek reasoning_content 回放依赖），
//  回看入口在开发者模式 ⌘D（DeveloperInspector）。这里刻意**不留**任何
//  「显示原始 CoT」的开关：留一个能打开的参数等于给下次复发留门。
//

import SwiftUI

struct ThinkingCard: View {
    /// nil → 思考中态；有值 → 完成态。
    let data: ThinkData?
    /// 思考中态展示的引用技能 id（本轮 Context Builder 注入的技能；
    /// 完成态由 data.steps 的技能步骤承载，此参数忽略）。
    var skills: [String] = []
    /// 思考中态的阶段时间线（确认链多跳：已完成跳打勾、当前跳呼吸点 + 流光文案，
    /// 如「正在抽取澄清要点表…」→「正在沉淀记忆…」）。空 = 通用「正在思考…」。
    /// 数据源 StreamState.phaseTrail（AppModel 确认链经 setStreamPhase 逐跳入轨）。
    var phases: [PhaseStep] = []
    /// 思考中态已执行的工具调用行（Function Calling；SessionStore 执行后经
    /// mutateStream 实时入轨，完成态由 data.steps 的工具步骤承载）。
    var toolSteps: [ThinkData.Step] = []

    @State private var expanded = false

    var body: some View {
        if let data {
            completedCard(data)
        } else {
            streamingCard
        }
    }

    // MARK: - 思考中（pulse 圆点 + 流光扫字，纯文字无底）

    /// 当前跳（最后一个未完成）的阶段文案；trail 为空 → 通用「正在思考…」。
    private var currentPhaseLabel: String {
        phases.last(where: { !$0.done })?.label ?? "正在思考…"
    }

    /// 已完成跳的文案列表（时间线回顾行数据源）。
    private var donePhases: [String] {
        phases.filter(\.done).map(\.label)
    }

    /// 时间线单行（✓ + 跳标签）：流式回顾与完成态历史共用。
    private func phaseDoneRow(_ label: String) -> some View {
        HStack(spacing: DS.Spacing.s6) {
            DSIcon(.check, size: 10)
                .foregroundStyle(Color.ink300)
            Text(label)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink300)
                .lineLimit(1)
        }
    }

    /// 展开态跳转历史是否可见（决定后续内容块的顶距补偿）。
    private func trailVisible(_ data: ThinkData) -> Bool {
        data.phaseTrail?.isEmpty == false
    }

    private var streamingCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            // 阶段时间线回顾：已完成跳打勾（确认链多跳时可见进度痕迹；常规单跳
            // 轮 trail 单元素无 done → 不渲染，与旧单行文案观感一致）
            ForEach(Array(donePhases.enumerated()), id: \.offset) { _, label in
                phaseDoneRow(label)
            }
            // 头行不可展开：流式期能见的过程只有阶段时间线 / 技能行 / 工具行这三类
            // 产品自己生成的文案（原始 CoT 曾在此实时尾随，2026-09-22 收口移除）
            streamingHeader
            if !skills.isEmpty {
                // 引用技能行：技能在组装期已确定注入，思考中即时可见（与完成态技能行同款图标）；
                // 置于过程内容上方（与完成态「技能行在全文前」同序）
                HStack(alignment: .top, spacing: DS.Spacing.s6) {
                    DSIcon(.aiStars, size: 11)
                        .foregroundStyle(Color.statusPrimary)
                    Text("引用技能：" + skills.joined(separator: " · "))
                        .font(DS.Font.bodyXS)
                        .dsCaptionType(size: 12)
                        .foregroundStyle(Color.ink500)
                }
            }
            // 工具调用行（Function Calling）：执行即入轨，流式期实时可见
            ForEach(Array(toolSteps.enumerated()), id: \.offset) { _, step in
                if let tool = step.tool {
                    VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                        HStack(alignment: .top, spacing: DS.Spacing.s6) {
                            Text("⚙")
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.statusPrimary)
                            Text(tool)
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink700)
                        }
                        if let detail = step.detail {
                            Text(detail)
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink500)
                                .padding(.leading, DS.Spacing.s16)
                        }
                    }
                }
            }
        }
    }

    /// 头行：pulse 圆点 + 流光扫字当前跳（无 chevron——流式态已无可展开内容）
    private var streamingHeader: some View {
        HStack(spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s8) {
                DSPulseDot()
                ThinkSweepText(currentPhaseLabel)
            }
        }
    }

    // MARK: - 已完成（折叠一行摘要；只有结构化行才可展开）

    /// 可展开 = 有工具/技能行，或有阶段时间线。原始 CoT 全文（`data.full`）不再是
    /// 展开内容，所以「想过但没有任何结构化行」的轮次不出 Button、不出 chevron——
    /// 也不新造一句「无内容可看」的提示文案占位。
    private func isExpandable(_ data: ThinkData) -> Bool {
        data.steps.contains { $0.skill != nil || $0.tool != nil }
            || data.phaseTrail?.isEmpty == false
    }

    private func completedCard(_ data: ThinkData) -> some View {
        let expandable = isExpandable(data)
        return VStack(alignment: .leading, spacing: 0) {
            if expandable {
                Button {
                    withAnimation(DS.Motion.springFast) { expanded.toggle() }
                } label: {
                    summaryLine(data, chevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                summaryLine(data, chevron: false)
            }

            if expandable && expanded {
                // 确认链跳转历史（2026-09-18 持久化）：链式回合全程打勾回顾——
                // 流式期时间线随流收起，这里恒可见（单跳/双跳链流式期无打勾行的兜底）
                if let trail = data.phaseTrail, !trail.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                        ForEach(Array(trail.enumerated()), id: \.offset) { _, label in
                            phaseDoneRow(label)
                        }
                    }
                    .padding(.top, DS.Spacing.s8)
                }
                // 工具行 + 技能行是唯一可展示的过程内容，直接铺在页面上（无背景框），
                // 与正文左缘对齐。必须合并为单个 Text：SwiftUI textSelection 只在单个
                // Text 内生效，逐条独立 Text 时 macOS 拖选跨行即断（只能一行一行选）。
                Text(Self.stepsAttributedString(data))
                    .dsCaptionType(size: 13)
                    .textSelection(.enabled)
                    .padding(.top, trailVisible(data) ? 0 : DS.Spacing.s8)
                    .transition(.opacity)
            }
        }
    }

    /// 摘要行：文字在前 + 可选尾部 chevron（折叠右指 / 展开转下），无底无框。
    private func summaryLine(_ data: ThinkData, chevron: Bool) -> some View {
        HStack(spacing: DS.Spacing.s4) {
            Text(data.summary)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
            if chevron {
                DSIcon(.down, size: 11)
                    .foregroundStyle(Color.ink300)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
        }
    }

    // MARK: - 步骤合并文本（跨行连续选取的关键）

    /// 步骤合并为单段 AttributedString：工具行（⚙ + 工具名 + 结果摘要）与技能行
    /// （✦ + 名称 + 注入说明）分 run 控制字号/颜色，视觉对齐原逐条渲染。
    /// 内部测试可见：「旧存量行不得被渲染上屏」这条不变量需要一个纯函数断言点。
    static func stepsAttributedString(_ data: ThinkData) -> AttributedString {
        var result = AttributedString()
        // 只渲染工具/技能行。`step.text` 分支刻意整个删掉（不是留个开关传 false）：
        // 2026-09-18~09-22 之间落盘的旧存量行里存的就是模型原始思维链，
        // 保留该分支等于让历史消息继续漏 CoT，且没有任何路径能关掉它。
        let visibleSteps = data.steps.filter { $0.skill != nil || $0.tool != nil }
        for (index, step) in visibleSteps.enumerated() {
            if let tool = step.tool {
                // 工具调用行（Function Calling）：工具名 + 人话结果摘要
                var gear = AttributedString("⚙ ")
                gear.font = DS.Font.bodyXS
                gear.foregroundColor = Color.statusPrimary
                result += gear

                var name = AttributedString(tool)
                name.font = DS.Font.bodyXS
                name.foregroundColor = Color.ink700
                result += name

                if let detail = step.detail {
                    var br = AttributedString("\n")
                    br.font = DS.Font.bodyXS
                    result += br
                    var d = AttributedString("  " + detail)
                    d.font = DS.Font.bodyXS
                    d.foregroundColor = Color.ink500
                    result += d
                }
            } else if let skill = step.skill {
                // 技能调用行：命中了哪个技能 / 注入了什么 / 耗时
                var star = AttributedString("✦ ")
                star.font = DS.Font.bodyXS
                star.foregroundColor = Color.statusPrimary
                result += star

                var name = AttributedString(skill)
                name.font = DS.Font.bodyXS
                name.foregroundColor = Color.ink700
                result += name

                if let dur = step.dur {
                    var d = AttributedString("  " + dur)
                    d.font = DS.Font.monoSM
                    d.foregroundColor = Color.ink500
                    result += d
                }
                if let detail = step.detail {
                    var br = AttributedString("\n")
                    br.font = DS.Font.bodyXS
                    result += br
                    var d = AttributedString("  " + detail)
                    d.font = DS.Font.bodyXS
                    d.foregroundColor = Color.ink500
                    result += d
                }
            }
            if index < visibleSteps.count - 1 {
                var br = AttributedString("\n")
                br.font = DS.Font.bodySM
                result += br
            }
        }
        return result
    }
}

// MARK: - pulse 圆点（原型 .run-dot：品牌实心 + 1.5s 呼吸）

/// 品牌色呼吸点（本文件思考中态、侧栏会话生成指示共用；tint 可覆盖默认色）。
struct DSPulseDot: View {
    var tint: Color = .brand600
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

// MARK: - think-sweep 流光扫字（原型 .think-live：2.4s 线性循环）

/// 底层 ink500 文字 + ink900 高亮层叠放，高亮层用水平平移的
/// LinearGradient（25% 透明 / 50% 实 / 75% 透明，宽 200%）做 mask——
/// 高亮带每 2.4s 从左缘扫到右缘；reduced-motion 降级纯 ink500。
private struct ThinkSweepText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(DS.Font.bodySM)
            .foregroundStyle(Color.ink500)
            .overlay {
                Text(text)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink900)
                    .mask {
                        GeometryReader { geo in
                            let width = geo.size.width
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.25),
                                    .init(color: .black, location: 0.5),
                                    .init(color: .clear, location: 0.75),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: width * 2)
                            .offset(x: -width * 2 + phase * width * 4)
                        }
                    }
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
