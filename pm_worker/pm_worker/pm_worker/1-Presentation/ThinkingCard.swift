//
//  ThinkingCard.swift
//  pm_worker
//
//  思考过程两态展示（Task 2.7，design.md §6.4.1；2026-09-12 起纯文字化——
//  去掉胶囊底/步骤区底框，对齐 Trae 对话「思考过程 ›」样式）：
//  - 思考中：品牌色 pulse 圆点 + 「正在思考…」think-sweep 流光扫字（2.4s 循环，
//    原型 .think-live/.run-dot，长静默期防假死感；减弱动态时降级纯文本）
//  - 已完成：默认折叠摘要行「思考了 Ns · M 步 · 技能 ×K ›」，点击展开步骤
//

import SwiftUI

struct ThinkingCard: View {
    /// nil → 思考中态；有值 → 完成态。
    let data: ThinkData?

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
        HStack(spacing: DS.Spacing.s8) {
            DSPulseDot()
            ThinkSweepText("正在思考…")
        }
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
                // 步骤直接铺在页面上（无背景框），与正文左缘对齐
                VStack(alignment: .leading, spacing: DS.Typography.listRowSpacing) {
                    ForEach(Array(data.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                .padding(.top, DS.Spacing.s8)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: ThinkData.Step) -> some View {
        if let skill = step.skill {
            // 技能调用行：命中了哪个技能 / 注入了什么 / 耗时
            HStack(alignment: .top, spacing: DS.Spacing.s6) {
                DSIcon(.aiStars, size: 11)
                    .foregroundStyle(Color.statusPrimary)
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(skill)
                        .font(DS.Font.bodyXS)
                        .dsCaptionType(size: 12)
                        .foregroundStyle(Color.ink700)
                    if let detail = step.detail {
                        Text(detail)
                            .font(DS.Font.bodyXS)
                            .dsCaptionType(size: 12)
                            .foregroundStyle(Color.ink500)
                    }
                }
                if let dur = step.dur {
                    Text(dur)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink500)
                }
            }
        } else if let text = step.text {
            HStack(alignment: .top, spacing: DS.Spacing.s6) {
                Text("·")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink300)
                Text(text)
                    .font(DS.Font.bodySM)
                    .dsCaptionType(size: 13)
                    .foregroundStyle(Color.ink500)
            }
        }
    }
}

// MARK: - pulse 圆点（原型 .run-dot：品牌实心 + 1.5s 呼吸）

/// 品牌色呼吸点（本文件思考中态与产物进度卡共用）。
struct DSPulseDot: View {
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.brand600)
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
