//
//  DSComponents3.swift
//  pm_worker
//
//  TraeWork 组件库 III（组件层补全 Wave B）：原型缺失 .ds-* 类的 SwiftUI 等价物。
//  DSDialog 对话框外壳 / DSMenu 毛玻璃下拉菜单 / DSTable 数据表 / DSBreadcrumb 面包屑。
//
//  规格来源：交互原型 v4 <style> 块逐条翻译 + 正文实际用点：
//  ds-dialog = 通用弹窗外壳（Modal）；ds-menu = 输入栏「自动流水线」下拉（v4.17）；
//  ds-breadcrumb = 右栏文件树顶部项目路径（段可点 · 末段 current）。
//

import SwiftUI

// MARK: - 对话框外壳（.ds-dialog）

/// 原型 .ds-dialog：白底 r12 · max-w 520（此处按调用点钉宽）· 双层大软阴影 ·
/// head（图标 + heading-sm 标题 + 32×32 关闭钮，hover 灰）+ body + foot。
/// 用法：sheet 内容根部包一层，外层 `.presentationBackground(Color.overlayL4)`。
struct DSDialog<Content: View, Footer: View>: View {
    let title: String
    var icon: DSIcon.Name? = nil
    /// 关闭动作（nil → 不显示关闭钮；通常传 { isPresented = false }）。
    var onClose: (() -> Void)? = nil
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(
        title: String,
        icon: DSIcon.Name? = nil,
        onClose: (() -> Void)? = nil,
        width: CGFloat = 520,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.onClose = onClose
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            // head：padding 16/20（垂直 16 · 水平 20）
            HStack(spacing: DS.Spacing.s8) {
                if let icon {
                    DSIcon(icon, size: 16)
                        .foregroundStyle(Color.brandAccent)
                }
                Text(title)
                    .font(DS.Font.headingSM)
                    .foregroundStyle(Color.ink900)
                Spacer(minLength: 0)
                if let onClose {
                    DSDialogCloseButton(action: onClose)
                }
            }
            .padding(.horizontal, DS.Spacing.s20)
            .padding(.vertical, DS.Spacing.s16)

            content
                .padding(.horizontal, DS.Spacing.s20)
                .padding(.bottom, DS.Spacing.s16)

            footer
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, DS.Spacing.s20)
                .padding(.bottom, DS.Spacing.s16)
        }
        .frame(width: width)
        .background(
            Color.surfaceBase,
            in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.borderL2, lineWidth: 1)
        )
        // 原型对话框阴影：0 24/64 14% + 0 4/16 8%（高度令牌 .overlay）
        .dsShadow(.overlay)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
    }
}

/// 原型 .ds-dialog__close：32×32 · 透明底 · r8 · hover overlay-l2。
/// （设置弹框等大对话框复用：internal）
struct DSDialogCloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(.close, size: 13)
                .foregroundStyle(hovered ? Color.ink700 : Color.ink500)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .fill(hovered ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help("关闭")
    }
}

// MARK: - 毛玻璃下拉菜单（.ds-menu）

/// 原型 .ds-menu：rgba(250,250,252,.86) + blur 28 毛玻璃 · r12 · padding 8 ·
/// min-w 180 · 双层投影。菜单容器——条目用 DSMenuItem / 分隔用 DSMenuDivider。
/// 定位由调用点决定（overlay / popover 锚定触发器下方）。
struct DSMenu<Content: View>: View {
    var minWidth: CGFloat = 180
    @ViewBuilder var content: Content

    init(minWidth: CGFloat = 180, @ViewBuilder content: () -> Content) {
        self.minWidth = minWidth
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
            content
        }
        .padding(DS.Spacing.s8)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(
            // 毛玻璃近似：材质打底 + 原型叠色；深色 = 原型 Dark --bg-menu #1E1E22。
            // 原型网页靠 backdrop-filter blur(28px) 保证背后文字不可辨，SwiftUI
            // 材质模糊弱得多——叠色须提到 0.95，否则背后大号文字会透出、
            // 呈现「文字盖住菜单」的观感（NewTaskView 关联项目下拉实测）。
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
        )
        .background(
            Color.dynamic(0xFAFAFC, 0.95, 0x1E1E22, 0.95),
            in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.overlayBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
        // 原型投影：0 12/32 12% + 0 2/8 8%
        .shadow(color: Color.shadowInk.opacity(0.12), radius: 32, y: 12)
        .shadow(color: Color.shadowInk.opacity(0.08), radius: 8, y: 2)
    }
}

/// 原型 .ds-menu__item：高 ≥32 · r8 · gap 8 · hover overlay-l2；
/// danger 红字；shortcut 右缘 kbd 标注；radio 场景用 isSelected 勾选态。
struct DSMenuItem: View {
    let title: String
    var icon: DSIcon.Name? = nil
    var shortcut: String? = nil
    /// 描述行（原型自动流水线菜单的次行说明，body-xs tertiary）。
    var description: String? = nil
    var isDestructive = false
    /// menuitemradio 勾选态（选中时左缘勾号 + 500 字重）。
    var isSelected = false
    /// 标题字号覆盖（缺省 bodyBase 15；与 chip 同框的紧凑菜单传 bodySM 13）。
    var titleFont: Font? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s8) {
                Group {
                    if isSelected {
                        DSIcon(.check, size: 14)
                    } else if let icon {
                        DSIcon(icon, size: 14)
                    }
                }
                    .foregroundStyle(iconColor)
                    .opacity(icon != nil || isSelected ? 1 : 0)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(title)
                        .font(titleFont ?? DS.Font.bodyBase)
                        .fontWeight(isSelected ? .medium : .regular)
                        .foregroundStyle(
                            isDestructive ? Color.statusError : Color.ink900
                        )
                    if let description {
                        Text(description)
                            .font(DS.Font.bodyXS)
                            .dsCaptionType(size: 12)
                            .foregroundStyle(Color.ink500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: DS.Spacing.s8)

                if let shortcut {
                    Text(shortcut)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink300)
                }
            }
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.vertical, DS.Spacing.s6)
            .frame(minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(hovered ? Color.overlayL2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
    }

    private var iconColor: Color {
        if isSelected { return Color.brand600 }
        if isDestructive { return Color.statusError }
        return Color.ink500
    }
}

/// 原型 .ds-menu__divider：1px L1 · 上下 margin 4。
struct DSMenuDivider: View {
    var body: some View {
        DSDivider()
            .padding(.vertical, DS.Spacing.s4)
    }
}

// MARK: - 数据表（.ds-table）

/// 原型 .ds-table 列定义（标题全大写 tertiary medium；width 为 nil 弹性列）。
struct DSTableColumn: Identifiable {
    let id: String
    var width: CGFloat? = nil

    init(_ title: String, width: CGFloat? = nil) {
        self.id = title
        self.width = width
    }
}

/// 原型 .ds-table：th 上 8 下 12 · 全大写 tertiary medium；
/// td 垂直 12 · 行间 L1 下边框 · 首列 ink900 其余 secondary；
/// 外层可横滚（minWidth 由调用点按列宽和钉）。
/// 行内单元格包 DSTableCell（或直接 DSTableText）。
struct DSTable<Rows: View>: View {
    let columns: [DSTableColumn]
    @ViewBuilder var rows: Rows

    init(columns: [DSTableColumn], @ViewBuilder rows: () -> Rows) {
        self.columns = columns
        self.rows = rows()
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(
                alignment: .topLeading,
                horizontalSpacing: DS.Spacing.s8,
                verticalSpacing: 0
            ) {
                GridRow {
                    ForEach(columns) { column in
                        Text(column.id.uppercased())
                            .font(DS.Font.bodyXSStrong)
                            .foregroundStyle(Color.ink500)
                            .padding(.top, DS.Spacing.s8)
                            .padding(.bottom, DS.Spacing.s12)
                            .frame(
                                minWidth: column.width,
                                maxWidth: column.width == nil ? .infinity : column.width,
                                alignment: .leading
                            )
                    }
                }
                rows
            }
            .padding(.horizontal, DS.Spacing.s2)
            .frame(minWidth: 560)
        }
    }
}

/// 原型 .ds-table td：垂直 padding + 行底 L1 分隔线。
struct DSTableCell<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, DS.Spacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { DSDivider() }
    }
}

/// 文本单元格：首列 ink900，其余 ink700（mono 变体等宽小号）。
struct DSTableText: View {
    let text: String
    var first = false
    var mono = false

    init(_ text: String, first: Bool = false, mono: Bool = false) {
        self.text = text
        self.first = first
        self.mono = mono
    }

    var body: some View {
        DSTableCell {
            Text(text)
                .font(mono ? DS.Font.monoSM : DS.Font.bodyBase)
                .foregroundStyle(first ? Color.ink900 : Color.ink700)
        }
    }
}

// MARK: - 面包屑（.ds-breadcrumb）

/// 原型 .ds-breadcrumb（右栏路径用法）：body-xs · tertiary · / 分隔 ·
/// 末段 current 高亮（500 字重）· 段可点（action 非空）。
struct DSBreadcrumb: View {
    struct Segment: Identifiable {
        let id = UUID()
        let title: String
        /// 点击动作（nil → 纯展示，不可点）。
        var action: (() -> Void)? = nil
    }

    let segments: [Segment]

    var body: some View {
        HStack(spacing: DS.Spacing.s2) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Text("/")
                        .foregroundStyle(Color.ink300)
                        .padding(.horizontal, DS.Spacing.s2)
                }
                if index == segments.count - 1 {
                    Text(segment.title)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.ink900)
                        .lineLimit(1)
                } else if let action = segment.action {
                    Button(action: action) {
                        Text(segment.title)
                            .foregroundStyle(Color.ink500)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(segment.title)
                        .foregroundStyle(Color.ink300)
                        .lineLimit(1)
                }
            }
        }
        .font(DS.Font.bodyXS)
    }
}

// MARK: - 预览

#Preview("Wave B 组件总览") {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.s24) {
            DSBreadcrumb(segments: [
                DSBreadcrumb.Segment(title: "PMAgent") {},
                DSBreadcrumb.Segment(title: "projects") {},
                DSBreadcrumb.Segment(title: "我的健身App", action: {}),
                DSBreadcrumb.Segment(title: "v1"),
            ])

            DSTable(columns: [
                DSTableColumn("工具", width: 200),
                DSTableColumn("状态"),
                DSTableColumn("时间"),
            ]) {
                GridRow {
                    DSTableText("generate_prd", first: true, mono: true)
                    DSTableCell { DSTag(title: "完成", variant: .success) }
                    DSTableText("09-11 19:20")
                }
                GridRow {
                    DSTableText("generate_prototype", first: true, mono: true)
                    DSTableCell { DSTag(title: "失败", variant: .danger) }
                    DSTableText("09-11 19:22")
                }
            }

            DSMenu(minWidth: 288) {
                DSMenuItem(
                    title: "每阶段确认（默认）",
                    description: "闸口停下等你确认再推进",
                    isSelected: true,
                    action: {}
                )
                DSMenuItem(
                    title: "全自动推进",
                    description: "闸口自动通过 · 一路跑完四阶段",
                    action: {}
                )
                DSMenuDivider()
                DSMenuItem(
                    title: "危险操作",
                    icon: DSIcon.Name.delete,
                    shortcut: "⌫",
                    isDestructive: true,
                    action: {}
                )
            }

            DSDialog(
                title: "这条记下来", icon: .bookmark,
                onClose: {}, width: 460
            ) {
                Text("对话框内容区（body）")
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink700)
            } footer: {
                HStack(spacing: DS.Spacing.s8) {
                    Button("取消") {}
                        .buttonStyle(.ds(.ghost))
                    Button("记下来") {}
                        .buttonStyle(.ds(.primary))
                }
            }
        }
        .padding(DS.Spacing.s24)
    }
    .frame(width: 560, height: 900)
}
