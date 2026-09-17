//
//  ThinkingCard.swift
//  pm_worker
//
//  思考过程两态展示（Task 2.7，design.md §6.4.1；2026-09-12 起纯文字化——
//  去掉胶囊底/步骤区底框，对齐 Trae 对话「思考过程 ›」样式）：
//  - 思考中：品牌色 pulse 圆点 + 「正在思考…」think-sweep 流光扫字（2.4s 循环，
//    原型 .think-live/.run-dot，长静默期防假死感；减弱动态时降级纯文本）；
//    reasoning 原文开始流入后头行可点击展开，实时尾随模型思考内容（bottom 锚定）
//  - 已完成：默认折叠摘要行「思考了 Ns · M 步 · <技能名|技能 ×K> ›」，点击展开步骤
//    （技能 ≤2 个摘要直接点名，≥3 显示计数；技能行带 ✦ 与推理行区分）
//

import SwiftUI

struct ThinkingCard: View {
    /// nil → 思考中态；有值 → 完成态。
    let data: ThinkData?
    /// 思考中态的模型 reasoning 原文（流式增量累积，SessionStore 节流发布）；
    /// 非空时头行可展开，实时看到模型在想什么。完成态忽略此参数。
    var reasoning: String = ""
    /// 思考中态展示的引用技能 id（本轮 Context Builder 注入的技能；
    /// 完成态由 data.steps 的技能步骤承载，此参数忽略）。
    var skills: [String] = []
    /// 思考中态的阶段文案（如「正在抽取澄清要点表…」）；nil = 通用「正在思考…」。
    /// 确认链多跳 LLM 往返期间逐步更新，让慢等待显性化为可见进度。
    var phase: String? = nil

    @State private var expanded = false

    var body: some View {
        if let data {
            completedCard(data)
        } else {
            streamingCard
        }
    }

    // MARK: - 思考中（pulse 圆点 + 流光扫字，纯文字无底）

    private var streamingCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            // reasoning 已开始流入 → 头行可点击展开实时思考内容（chevron 与完成态同款）
            if reasoning.isEmpty {
                streamingHeader
            } else {
                Button {
                    withAnimation(DS.Motion.springFast) { expanded.toggle() }
                } label: {
                    streamingHeader
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if expanded && !reasoning.isEmpty {
                liveReasoning
            }
            if !skills.isEmpty {
                // 引用技能行：技能在组装期已确定注入，思考中即时可见（与完成态技能行同款图标）
                HStack(alignment: .top, spacing: DS.Spacing.s6) {
                    DSIcon(.aiStars, size: 11)
                        .foregroundStyle(Color.statusPrimary)
                    Text("引用技能：" + skills.joined(separator: " · "))
                        .font(DS.Font.bodyXS)
                        .dsCaptionType(size: 12)
                        .foregroundStyle(Color.ink500)
                }
            }
        }
    }

    /// 头行：pulse 圆点 + 流光扫字（reasoning 非空时带尾部 chevron，折叠右指 / 展开转下）
    private var streamingHeader: some View {
        HStack(spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s8) {
                DSPulseDot()
                ThinkSweepText(phase ?? "正在思考…")
            }
            if !reasoning.isEmpty {
                DSIcon(.down, size: 11)
                    .foregroundStyle(Color.ink300)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
        }
    }

    /// 展开态：reasoning 原文实时流出。限高滚动 + bottom 锚定贴底跟随新 delta，
    /// 用户上滚阅读时不被拽回；限高避免长思考把对话流顶走。
    private var liveReasoning: some View {
        DSScroll {
            Text(reasoning)
                .dsCaptionType(size: 13)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 280)
        .padding(.top, DS.Spacing.s4)
        .transition(.opacity)
    }

    // MARK: - 已完成（默认折叠一行摘要，纯文字 + 尾部箭头，参考图「思考过程 ›」式）

    private func completedCard(_ data: ThinkData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.Motion.springFast) { expanded.toggle() }
            } label: {
                // 文字在前 + 尾部 chevron（折叠右指 / 展开转下），无底无框
                HStack(spacing: DS.Spacing.s4) {
                    Text(data.summary)
                        .font(DS.Font.bodySM)
                        .foregroundStyle(Color.ink500)
                    DSIcon(.down, size: 11)
                        .foregroundStyle(Color.ink300)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // 步骤直接铺在页面上（无背景框），与正文左缘对齐。
                // 必须合并为单个 Text：SwiftUI textSelection 只在单个 Text 内生效，
                // 逐条独立 Text 时 macOS 拖选跨行即断（只能一行一行选）。
                Text(Self.stepsAttributedString(data))
                    .dsCaptionType(size: 13)
                    .textSelection(.enabled)
                    .padding(.top, DS.Spacing.s8)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 步骤合并文本（跨行连续选取的关键）

    /// 全部步骤合并为单段 AttributedString：技能行（✦ + 名称 + 注入说明）与
    /// 推理行（· + 要点）分 run 控制字号/颜色，视觉对齐原逐条渲染。
    private static func stepsAttributedString(_ data: ThinkData) -> AttributedString {
        var result = AttributedString()
        for (index, step) in data.steps.enumerated() {
            if let skill = step.skill {
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
            } else if let text = step.text {
                var dot = AttributedString("· ")
                dot.font = DS.Font.bodySM
                dot.foregroundColor = Color.ink300
                result += dot

                var body = AttributedString(text)
                body.font = DS.Font.bodySM
                body.foregroundColor = Color.ink500
                result += body
            }
            if index < data.steps.count - 1 {
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
