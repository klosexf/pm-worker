//
//  DSComponents2.swift
//  pm_worker
//
//  TraeWork 组件库 II（组件层补全 Wave A）：原型缺失 .ds-* 类的 SwiftUI 等价物。
//  DSTag 标签徽章 / DSAlert 内联警示条 / DSNotif 通知条 / DSSkeleton 骨架屏 /
//  DSProgress 进度条 / DSAvatar 首字头像 / DSKbd 快捷键标注。
//
//  规格来源：交互原型 v4 <style> 块逐条翻译，与 DS.swift 令牌一一对应。
//

import SwiftUI

// MARK: - 标签徽章（.ds-tag）

/// 原型 .ds-tag：高 22 · r8 · 内边距 0/8 · body-sm · L1 边框；
/// neutral = overlay-l2 底 + secondary 文字；
/// brand/success/warning/danger = 对应 surface 底 + 状态色文字（无边框差异化）。
struct DSTag: View {
    enum Variant { case neutral, brand, success, warning, danger, info, alert }

    let title: String
    var variant: Variant = .neutral
    var icon: DSIcon.Name? = nil

    private var foreground: Color {
        switch variant {
        case .neutral: Color.ink700
        case .brand: Color.brandAccent
        case .success: Color.statusSuccess
        case .warning: Color.statusWarning
        case .danger: Color.statusError
        case .info: Color.statusPrimary
        case .alert: Color.statusAlert
        }
    }

    private var background: Color {
        switch variant {
        case .neutral: Color.overlayL2
        case .brand: Color.brandPopup
        case .success: Color.statusSuccessSurface1
        case .warning: Color.statusWarningSurface1
        case .danger: Color.statusErrorSurface1
        case .info: Color.statusPrimarySurface1
        case .alert: Color.statusAlertSurface1
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s4) {
            if let icon {
                DSIcon(icon, size: 12)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(DS.Font.bodySM)
        .foregroundStyle(foreground)
        .padding(.horizontal, DS.Spacing.s8)
        .frame(height: 22)
        .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}

/// 原型 .ds-tag.num：18 高胶囊计数（min-width 18 · tabular-nums · overlay-l2 底 · tertiary 文字）。
struct DSTagCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(DS.Font.bodyXS)
            .monospacedDigit()
            .foregroundStyle(Color.ink500)
            .padding(.horizontal, DS.Spacing.s6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Color.overlayL2))
    }
}

// MARK: - 内联警示条（.ds-alert）

/// 原型 .ds-alert：padding 12/16 · secondary 底 · L1 边框 · r8 ·
/// 16px 图标按变体着色 · 标题（body-md-strong）+ 描述（secondary）。
struct DSAlert: View {
    enum Variant { case info, success, warning, danger }

    let variant: Variant
    var title: String
    var description: String? = nil
    /// 可选动作（ghost sm 按钮，右缘对齐）。
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    private var icon: DSIcon.Name {
        switch variant {
        case .info: .notification
        case .success: .circleCheck
        case .warning: .warningFill
        case .danger: .circleX
        }
    }

    private var iconColor: Color {
        switch variant {
        case .info: Color.ink500
        case .success: Color.statusSuccess
        case .warning: Color.statusWarning
        case .danger: Color.statusError
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s12) {
            DSIcon(icon, size: 16)
                .foregroundStyle(iconColor)
                .padding(.top, DS.Spacing.s2)
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text(title)
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
                if let description {
                    Text(description)
                        .font(DS.Font.bodySM)
                        .dsCaptionType(size: 13)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.s8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(.ghost, size: .sm))
            }
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.vertical, DS.Spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.surfaceSecondary,
            in: RoundedRectangle(cornerRadius: DS.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}

// MARK: - 通知条（.ds-notif）

/// 原型 .ds-notif：max-w 560 · padding 8/12 · secondary 底 · L1 边框 · r8 ·
/// 16px 图标 + 标题（strong）+ 描述（secondary）+ 关闭钮；用于瞬态消息。
struct DSNotif: View {
    enum Variant { case info, success, warning, error }

    let variant: Variant
    let title: String
    var description: String? = nil
    var onClose: (() -> Void)? = nil

    private var icon: DSIcon.Name {
        switch variant {
        case .info: .notification
        case .success: .circleCheck
        case .warning: .warningFill
        case .error: .circleX
        }
    }

    private var iconColor: Color {
        switch variant {
        case .info: Color.ink500
        case .success: Color.statusSuccess
        case .warning: Color.statusWarning
        case .error: Color.statusError
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s8) {
            DSIcon(icon, size: 16)
                .foregroundStyle(iconColor)
                .padding(.top, DS.Spacing.s2)
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text(title)
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                if let description {
                    Text(description)
                        .font(DS.Font.bodySM)
                        .dsCaptionType(size: 13)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.s8)
            Button {
                onClose?()
            } label: {
                DSIcon(.close, size: 12)
                    .foregroundStyle(Color.ink300)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s8)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            Color.surfaceSecondary,
            in: RoundedRectangle(cornerRadius: DS.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        .dsShadow(.floating)
    }
}

/// 瞬态通知消息（供 .dsNotifCenter 挂载）。
struct DSNotifMessage: Equatable, Identifiable {
    let id = UUID()
    var variant: DSNotif.Variant
    var title: String
    var description: String? = nil
}

extension View {
    /// 瞬态通知浮现层（原型 .ds-notif 的容器行为）：
    /// 滑入 → 2.4s 自动消失；手动关闭即时收起。
    /// 默认 `.topTrailing`（pane 内右上角）；`.top` 用于窗口级顶部居中
    /// （ContentView 根部挂载），滑入方向随对齐边切换（顶入 vs 右入）。
    func dsNotifCenter(
        _ message: Binding<DSNotifMessage?>,
        alignment: Alignment = .topTrailing
    ) -> some View {
        overlay(alignment: alignment) {
            if let msg = message.wrappedValue {
                DSNotif(
                    variant: msg.variant,
                    title: msg.title,
                    description: msg.description
                ) {
                    withAnimation(DS.Motion.springFast) {
                        message.wrappedValue = nil
                    }
                }
                .padding(DS.Spacing.s16)
                .transition(alignment == .top
                    ? .move(edge: .top).combined(with: .opacity)
                    : .move(edge: .trailing).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                        withAnimation(DS.Motion.springFast) {
                            if message.wrappedValue?.id == msg.id {
                                message.wrappedValue = nil
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 骨架屏（.ds-skeleton）

// MARK: - 等待指示器（spinner）

/// 不定时长等待指示器：ink 圆弧匀速旋转，替代系统 ProgressView 菊花
///（KnowledgeTab 检索中 / NewTaskView 建会话中）。reduced-motion 时静止。
struct DSSpinner: View {
    var size: CGFloat = 14
    var tint: Color = Color.ink500

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                tint,
                style: StrokeStyle(
                    lineWidth: max(size * 0.11, 1.5),
                    lineCap: .round
                )
            )
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .frame(width: size, height: size)
            .animation(
                reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
    }
}

/// 原型 .ds-skeleton：overlay-l2 底 r8 + 1.6s 流光扫过
///（90° 渐变 transparent→overlay-l3→transparent，ease-in-out）；
/// reduced-motion 降级为 45% 透明度静止条。
struct DSSkeletonShape: View {
    var cornerRadius: CGFloat = DS.Radius.lg

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.overlayL2)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.overlayL3, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.6)
                }
            )
            .clipped()
            .opacity(reduceMotion ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
    }
}

/// 原型 .ds-skeleton--line：高 12；width 为 nil 时占满可用宽。
struct DSSkeletonLine: View {
    var width: CGFloat? = nil

    var body: some View {
        DSSkeletonShape()
            .frame(width: width, height: 12)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// 原型 .ds-skeleton--title：高 18 · 宽 50%（GeometryReader 取容器半宽）。
struct DSSkeletonTitle: View {
    var body: some View {
        GeometryReader { geo in
            DSSkeletonShape()
                .frame(width: geo.size.width * 0.5, height: 18)
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity)
    }
}

/// 原型 .ds-skeleton--circle：32 圆。
struct DSSkeletonCircle: View {
    var body: some View {
        DSSkeletonShape(cornerRadius: DS.Radius.full)
            .frame(width: 32, height: 32)
    }
}

// MARK: - 进度条（.ds-progress）

/// 原型 .ds-progress：6px 高胶囊 · overlay-l2 轨道 · bar 默认墨色
///（--brand 变体品牌紫：tint 传 Color.brand600）。
struct DSProgress: View {
    /// 进度 0…1（越界值会被钳制）。
    var value: Double
    var tint: Color = Color.ink900

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.overlayL2)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 首字头像（.ds-avatar）

/// 原型 .ds-avatar：32 圆 · overlay-l3 底 · 首字 body-base-strong；
/// sm 24（body-sm-strong）/ lg 40。icon 模式：图标替代首字
///（原型底部账户区「ds-avatar 形制」）。
struct DSAvatar: View {
    enum Size { case sm, md, lg }

    let label: String
    var size: Size = .md
    var icon: DSIcon.Name? = nil

    private var dimension: CGFloat {
        switch size {
        case .sm: 24
        case .md: 32
        case .lg: 40
        }
    }

    private var font: SwiftUI.Font {
        switch size {
        case .sm: DS.Font.bodySMStrong
        case .md, .lg: DS.Font.bodyBaseStrong
        }
    }

    var body: some View {
        Circle()
            .fill(Color.overlayL3)
            .frame(width: dimension, height: dimension)
            .overlay(
                Group {
                    if let icon {
                        DSIcon(icon, size: dimension * 0.5)
                            .foregroundStyle(Color.ink700)
                    } else {
                        Text(displayInitial)
                            .font(font)
                            .foregroundStyle(Color.ink900)
                    }
                }
            )
    }

    private var displayInitial: String {
        String(label.trimmingCharacters(in: .whitespaces).prefix(1))
    }
}

// MARK: - 快捷键标注（.ds-kbd）

/// 原型 .ds-kbd：高 20 · 透明底 · L1 边框 · r8 · body-md · secondary 文字。
struct DSKbd: View {
    let key: String

    var body: some View {
        Text(key)
            .font(DS.Font.bodySM)
            .foregroundStyle(Color.ink500)
            .padding(.horizontal, DS.Spacing.s6)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}

// MARK: - 预览

#Preview("Wave A 组件总览") {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.s16) {
            HStack(spacing: DS.Spacing.s8) {
                DSTag(title: "默认", variant: .neutral)
                DSTag(title: "品牌", variant: .brand)
                DSTag(title: "成功", variant: .success)
                DSTag(title: "警示", variant: .warning)
                DSTag(title: "危险", variant: .danger)
                DSTagCount(count: 12)
                DSKbd(key: "⌘D")
            }
            DSAlert(variant: .warning, title: "此版本已封板（目录只读）")
            DSAlert(
                variant: .danger, title: "无法计价",
                description: "未收录单价的模型费用未计入统计"
            )
            DSAvatar(label: "我")
            DSAvatar(label: "PM", size: .sm)
            DSAvatar(label: "P", size: .lg)
            DSSkeletonTitle()
            DSSkeletonLine()
            DSSkeletonLine(width: 220)
            DSProgress(value: 0.62)
            DSProgress(value: 0.42, tint: Color.brand600)
        }
        .padding(DS.Spacing.s24)
        .frame(width: 480)
    }
}
