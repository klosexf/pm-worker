//
//  DSComponents.swift
//  pm_worker
//
//  TraeWork 组件库（视觉还原 Wave 1）：原型 .ds-* 类的 SwiftUI 等价物。
//  按钮（DSButtonStyle 多变体多尺寸）/ 输入框 / 卡片 / 胶囊分段 / 空态 /
//  开关 / 侧栏 vibrancy / 分隔线。
//
//  策略：优先 ButtonStyle / ViewModifier（调用点只改一个词）。AppKit 桥接仅
//  限侧栏真材质（NSVisualEffectView）——深度来自折射，叠色伪造不出。
//

import SwiftUI
import AppKit

// MARK: - 按钮（.ds-btn）

/// 原型 .ds-btn：sm 28h / md 32h / lg 36h（高级感升级：随字体抬升加高一档），
/// radius 8，spring 反馈。变体：primary（深反色底）/ brand（品牌紫）/
/// secondary（overlay-l1 底 + 边框）/ ghost（透明）/ dangerSubtle。
/// hover：底色升一阶；pressed：active 色即时切换（Xcode 纪律：Mac 控件
/// 不缩放，反馈靠即时变色——缩放是 iOS / web 语义，桌面上显「玩具感」）。
struct DSButtonStyle: ButtonStyle {
    enum Variant { case primary, brand, secondary, ghost, dangerSubtle }
    enum Size { case xs, sm, md, lg }

    var variant: Variant = .primary
    var size: Size = .md

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, variant: variant, size: size)
    }
}

/// 按钮实体视图：承载 hover 态（ButtonStyle 结构体无法持有 @State）。
private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: DSButtonStyle.Variant
    let size: DSButtonStyle.Size

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var height: CGFloat {
        switch size {
        case .xs: 24
        case .sm: 28
        case .md: 32
        case .lg: 36
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .xs: DS.Spacing.s8
        case .sm: DS.Spacing.s10
        case .md: DS.Spacing.s12
        case .lg: DS.Spacing.s16
        }
    }

    private var font: SwiftUI.Font {
        switch size {
        case .xs: DS.Font.bodyXSStrong
        case .sm: DS.Font.bodySMStrong
        default: DS.Font.bodyBaseStrong
        }
    }

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(font)
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
            .foregroundStyle(foreground())
            .background(background(pressed), in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(border(pressed), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .onHover { hovered = $0 }
            .animation(DS.Motion.springFast, value: hovered)
    }

    private func foreground() -> Color {
        switch variant {
        case .primary:
            // invert 底在深色是亮底 → 前景成对换深字（onInvert）
            isEnabled ? Color.onInvert : Color.ink300
        case .brand:
            // brand600 填充双模式同值，白字恒成立
            isEnabled ? Color.white : Color.ink300
        case .secondary, .ghost:
            isEnabled ? Color.ink900 : Color.ink300
        case .dangerSubtle:
            Color.statusError
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch variant {
        case .primary:
            isEnabled
                ? (pressed ? Color.invertActive : (hovered ? Color.invertHover : Color.invert))
                // disabled 底：原型 Light tintGray@0.20 / Dark --bg-invert-disabled 白@0.12
                : Color.dynamic(0x555463, 0.20, 0xFFFFFF, 0.12)
        case .brand:
            isEnabled
                ? (pressed ? Color.brand700 : (hovered ? Color.brand500 : Color.brand600))
                // disabled 底：Dark --bg-brand-disabled rgba(122,117,255,0.25)
                : Color.dynamic(0x4B3FE3, 0.22, 0x7A75FF, 0.25)
        case .secondary:
            pressed ? Color.overlayL3 : (hovered ? Color.overlayL2 : Color.overlayL1)
        case .ghost:
            pressed ? Color.overlayL2 : (hovered ? Color.overlayL1 : Color.clear)
        case .dangerSubtle:
            pressed ? Color.statusError.opacity(0.18) : Color.statusError.opacity(0.12)
        }
    }

    private func border(_ pressed: Bool) -> Color {
        switch variant {
        case .primary, .brand: Color.clear
        case .secondary: pressed ? Color.borderL2 : Color.borderL1
        case .ghost: Color.clear
        case .dangerSubtle: Color.statusError.opacity(0.16)
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    /// `.buttonStyle(.ds(.primary))`——原型 .ds-btn 系。
    static func ds(
        _ variant: DSButtonStyle.Variant, size: DSButtonStyle.Size = .md
    ) -> DSButtonStyle {
        DSButtonStyle(variant: variant, size: size)
    }
}

// MARK: - 输入框（.ds-input / .ds-textarea）

/// 原型 .ds-input：白底 + neutral-l1 边框 radius 8；focus 内层黑边（--border-contrast，
/// 深色为白边——contrastBorder 令牌）+ 外圈 brandAccent 焦点环（dsFocusRing，
/// Xcode 语义）。focused 由调用点传 FocusState 派生值（修饰符内拿不到泛型焦点）。
extension View {
    func dsInput(focused: Bool = false, minHeight: CGFloat = 32) -> some View {
        self
            .padding(.horizontal, DS.Spacing.s12)
            .frame(minHeight: minHeight, alignment: .center)
            .background(Color.surfaceBase, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(focused ? Color.contrastBorder : Color.borderL1, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .dsFocusRing(focused: focused, radius: DS.Radius.lg)
    }

    /// 多行输入（.ds-textarea：min-height 96，上下 padding 8）。
    func dsTextarea(focused: Bool = false, minHeight: CGFloat = 96) -> some View {
        self
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Color.surfaceBase, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(focused ? Color.contrastBorder : Color.borderL1, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .dsFocusRing(focused: focused, radius: DS.Radius.lg)
    }
}

// MARK: - 焦点环（Xcode 语义：accent 环绕，非描边式焦点）

extension View {
    /// accent 焦点环：3pt 外环贴边环绕（零间隙），未聚焦时全透明且不参与命中。
    /// 内层描边由调用点各自保留——「描边变色 → 环绕 accent 光环」是原生输入
    /// 与 web 式焦点的关键分野（2026-09-12 Xcode 质感 P0-①）。
    /// 半径参数 = 宿主圆角：环体按 radius+3 同心外扩（strokeBorder + 负 padding）。
    func dsFocusRing(focused: Bool, radius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius + 3)
                .strokeBorder(Color.brandAccent, lineWidth: 3)
                .opacity(focused ? 0.32 : 0)
                .padding(-3)
                .allowsHitTesting(false)
        )
        .animation(DS.Motion.springFast, value: focused)
    }
}

// MARK: - 卡片（.ds-card）

/// 原型 .ds-card：#F5F5F5 底 + neutral-l1 边框 + radius 12 + padding 20。
extension View {
    func dsCard(
        padding: CGFloat = DS.Spacing.s20,
        background: Color = .surfaceSecondary
    ) -> some View {
        self
            .padding(padding)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.xxl))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xxl)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
            // 高级感升级：贴地层微阴影——从「平面描边」走向「分层浮动」
            .dsShadow(.card)
    }

    /// 白底浮起卡（.ds-dialog 质感：白底 radius 12 + 双层大软阴影）。
    func dsFloatingCard(padding: CGFloat = DS.Spacing.s20) -> some View {
        self
            .padding(padding)
            .background(
                Color.surfaceBase,
                in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xxl)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
            .dsShadow(.overlay)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
    }
}

// MARK: - 分隔线（1px neutral-l1）

/// 原型 border-bottom：1px rgba(115,115,115,.12)。
struct DSDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.borderL1)
            .frame(height: 1)
    }
}

// MARK: - 胶囊分段（macOS 分段控件：激活段白底浮起）

/// 原型 .seg：容器 overlay 底 + 激活段白底 + 双层投影（.seg-on）。
/// nonisolated：默认 MainActor 隔离下 Identifiable 的隔离 id 会让 ForEach
/// 重载解析失败（ Binding<C> 假命中），显式退出隔离。
nonisolated struct DSTabItem<Item: Hashable>: Identifiable {
    let item: Item
    let title: String

    var id: Item { item }

    init(_ item: Item, _ title: String) {
        self.item = item
        self.title = title
    }
}

struct DSTabs<Item: Hashable>: View {
    let items: [DSTabItem<Item>]
    @Binding var selection: Item
    /// 紧凑档（设置弹框等偏好面板）：高 22 / 12pt 字 / 小胶囊——对齐 Xcode
    /// 原生分段控件的密度；默认档保持原型 seg 形制。
    var compact: Bool = false
    @Namespace private var pillNS

    var body: some View {
        // 原型 Seg：容器 overlay-l1 · r8 · padding 2 · gap 2；每段 flex:1 均分
        //（等宽等高）、高 28（4+20+4）、激活 500/未激活 400、未激活 text-tertiary。
        // 高级感升级：选中胶囊 matchedGeometryEffect 滑动（spring 驱动）。
        let font = compact ? DS.Font.bodyXS : DS.Font.bodySM
        let segmentHeight: CGFloat = compact ? 22 : 28
        let pillRadius: CGFloat = compact ? DS.Radius.sm : DS.Radius.md

        return HStack(spacing: DS.Spacing.s2) {
            ForEach(items) { entry in
                let active = entry.item == selection
                Text(entry.title)
                    .font(font)
                    .fontWeight(active ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 注意：三元里的隐式成员语法（active ? .ink900 : .ink300）会让
                    // foregroundStyle 重载解析崩溃并连带 ForEach 推断失败，必须写全 Color.
                    .foregroundStyle(active ? Color.ink900 : Color.ink300)
                    .frame(maxWidth: .infinity)
                    .frame(height: segmentHeight)
                    .background {
                        if active {
                            // 选中胶囊：浅色白底浮起（原型 .seg-on）；
                            // 深色亮一档 #2E2E33（原型 Dark 激活段 overlay-l3 浮起语义，
                            // surfaceBase #0D0D0F 在 overlay 容器上会变暗凹槽，不可用）
                            RoundedRectangle(cornerRadius: pillRadius)
                                .fill(Color.dynamic(0xFFFFFF, 0x2E2E33))
                                .shadow(
                                    color: .black.opacity(compact ? 0.12 : 0.16),
                                    radius: compact ? 1.5 : 2.5,
                                    y: compact ? 0.5 : 1
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: pillRadius)
                                        .strokeBorder(Color.contrastBorder.opacity(0.06), lineWidth: 0.5)
                                )
                                .matchedGeometryEffect(id: "selection-pill", in: pillNS)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: pillRadius))
                    .onTapGesture {
                        withAnimation(DS.Motion.spring) { selection = entry.item }
                    }
            }
        }
        .padding(DS.Spacing.s2)
        .background(Color.overlayL1, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}

// MARK: - 空态（.ds-empty）

/// 原型 .ds-empty：图标盒 + 标题/描述。
/// 高级感升级：标题改编辑级衬线展示字（New York displayMD）+ 48px 图标盒，
/// 空态是天然的「杂志时刻」——排版对比在空屏上最出效果。
/// P1-⑤：去虚线外框——虚线是 web 表单占位语义，纯留白 + 图文更接近 Xcode 空态。
struct DSEmptyState: View {
    var icon: DSIcon.Name
    var title: String
    var description: String

    var body: some View {
        VStack(spacing: DS.Spacing.s16) {
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
                .frame(width: 48, height: 48)
                .overlay(
                    DSIcon(icon, size: 20)
                        .foregroundStyle(Color.ink700)
                )

            VStack(spacing: DS.Spacing.s6) {
                Text(title)
                    .font(DS.Font.displayMD)
                    .dsTight()
                    .foregroundStyle(Color.ink900)
                Text(description)
                    .font(DS.Font.bodyMD)
                    .dsCaptionType(size: 14)
                    .foregroundStyle(Color.ink500)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.s40)
        .padding(.horizontal, DS.Spacing.s24)
    }
}

// MARK: - 开关（.ds-switch：32×18，品牌色开态）

/// 原型 .ds-switch：off = overlay-l3 底 + neutral-l1 边；on = 品牌底；thumb 12px 白圆。
struct DSSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.brand600 : Color.overlayL3)
                .overlay(
                    Capsule().strokeBorder(isOn ? Color.brand600 : Color.borderL1, lineWidth: 1)
                )
            Circle()
                .fill(Color.surfaceBase)
                .frame(width: 12, height: 12)
                .padding(DS.Spacing.s2)
        }
        .frame(width: 32, height: 18)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(DS.Motion.springFast) { isOn.toggle() }
        }
        .accessibilityLabel(Text(isOn ? "开启" : "关闭"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 侧栏 vibrancy（真材质：NSVisualEffectView）

/// Xcode 同款侧栏材质：.sidebar material + behindWindow 混合——透出窗后内容
/// 的真实毛玻璃（深度来自折射，不是叠色）。材质随系统外观（浅 / 深）与窗口
/// 激活态自动变化（失活自动变暗），调用点无需感知。
/// 取代旧「纯色 + alpha」伪造材质——没有折射就没有深度（2026-09-12 Xcode 质感 P0-④）。
private struct SidebarVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SidebarVibrancyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            SidebarVibrancyBackground()
                // 降透明罩：behindWindow 会把窗后内容（浏览器 / 桌面）整片透进来，
                // 侧栏文字可读性差（用户实测反馈）。罩层压到 ≈85% 不透明——
                // 材质只剩隐约呼吸感，文字对比度回归实底水准。
                .overlay(
                    Color.dynamic(0xF2F2F5, 0.82, 0x161618, 0.88),
                    in: Rectangle()
                )
        }
    }
}

extension View {
    /// 侧栏真 vibrancy：NSVisualEffectView（.sidebar 材质，Xcode 同款）+
    /// 高不透明降透明罩（保可读性，材质仅余微弱透气感）。
    /// 窗口已配 fullSizeContentView + titlebarAppearsTransparent
    /// （WindowChromeConfigurator），behindWindow 混合可完整透出窗后内容。
    func sidebarVibrancy() -> some View {
        modifier(SidebarVibrancyModifier())
    }
}
