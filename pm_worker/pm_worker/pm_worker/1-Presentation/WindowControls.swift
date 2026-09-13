//
//  WindowControls.swift
//  pm_worker
//
//  自绘窗口顶栏（对齐 Trae 参考图）：隐藏 macOS 系统红绿灯（连同其顶部安全区
//  占位），侧栏首行自绘「关闭 / 最小化 / 缩放」三色圆 + 侧栏折叠 + 搜索图标，
//  贴顶排列；行为直连 NSWindow（performClose / Miniaturize / Zoom）。
//

import SwiftUI
import AppKit

// MARK: - 系统红绿灯隐藏 + 全尺寸内容

/// 挂载到视图树，拿到所在 NSWindow 后：隐藏三枚标准窗口按钮、标题栏透明、
/// 内容铺满整个窗口（顶部安全区随之消失，由自绘按钮接管窗口控制）。
/// 配置在 NSView 完成窗口挂载（viewDidMoveToWindow）后执行，规避时序风险。
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window)
    }

    final class WindowChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            WindowChromeConfigurator.configure(window)
        }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        // 隐藏系统红绿灯（关闭 / 最小化 / 缩放）——顶部安全区随之不再预留
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

// MARK: - 顶栏图标按钮（折叠 / 搜索等，hover 浮底）

/// 顶栏行内的 24×24 图标按钮：hover overlayL2 浮底（对齐参考图红绿灯右侧图标形制）。
struct TopBarIconButton: View {
    let name: DSIcon.Name
    var size: CGFloat = 14
    /// 水平镜像（panelRight → 左栏折叠形制）。
    var flipX = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(name, size: size)
                .scaleEffect(x: flipX ? -1 : 1, y: 1)
                .foregroundStyle(hovered ? Color.ink700 : Color.ink500)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(hovered ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - 自绘窗口控制按钮（左上角三色圆）

/// 侧栏首行：自绘「关闭 / 最小化 / 缩放」三圆 + 可选 trailing 图标（折叠 / 搜索），
/// 贴顶左对齐成组。hover 组内任一按钮时圆内浮现对应符号（对齐 macOS 交互习惯）。
/// 显示条件 = 整组悬停 或 该按钮独立悬停（双保险：整组 tracking 被 tooltip 等打断时，
/// 按钮自身的 hover 仍保证符号显示，按钮间移动不丢图形）。
struct WindowControlButtons<Trailing: View>: View {
    @State private var groupHovered = false
    /// 独立按钮悬停态（按钮各自的 onHover 维护，互不影响）。
    @State private var hoveredKind: Kind?
    /// 按钮所在窗口（经视图树捕获，多窗口下不误伤其它窗口）。
    @State private var targetWindow: NSWindow?
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s10) {
            circle(kind: .close)
            circle(kind: .minimize)
            circle(kind: .zoom)
            trailing()
            Spacer(minLength: 0)
        }
        .onHover { entering in
            groupHovered = entering
            if !entering { hoveredKind = nil }
        }
        .frame(height: 28)
        .padding(.leading, 8)
        .padding(.trailing, DS.Spacing.s12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowRef { targetWindow = $0 })
    }

    private enum Kind {
        case close, minimize, zoom

        var fill: Color {
            switch self {
            case .close: return Color(red: 0xFF / 255, green: 0x5F / 255, blue: 0x57 / 255)
            case .minimize: return Color(red: 0xFE / 255, green: 0xBC / 255, blue: 0x2E / 255)
            case .zoom: return Color(red: 0x28 / 255, green: 0xC8 / 255, blue: 0x41 / 255)
            }
        }
    }

    /// hover 时圆内浮现的符号（纯几何绘制，不依赖图标资源）。
    @ViewBuilder
    private func glyph(_ kind: Kind) -> some View {
        let stroke = Color.black.opacity(0.6)
        switch kind {
        case .close:
            // ×
            ZStack {
                Capsule().fill(stroke).frame(width: 8, height: 1.4).rotationEffect(.degrees(45))
                Capsule().fill(stroke).frame(width: 8, height: 1.4).rotationEffect(.degrees(-45))
            }
        case .minimize:
            // −
            Capsule().fill(stroke).frame(width: 8, height: 1.4)
        case .zoom:
            // 对角双三角（macOS Big Sur+ 原生缩放符号形制）：
            // 左上三角尖朝左上、右下三角尖朝右下——Shape 内直接按顶点坐标画，
            // 不做旋转（rotationEffect 在 y-down 坐标系下朝向易歧义）。
            ZStack {
                GlyphTriangleTL().fill(stroke).frame(width: 4.5, height: 4.5)
                    .offset(x: -0.8, y: -0.8)
                GlyphTriangleBR().fill(stroke).frame(width: 4.5, height: 4.5)
                    .offset(x: 0.8, y: 0.8)
            }
        }
    }

    private func circle(kind: Kind) -> some View {
        Button {
            perform(kind)
        } label: {
            ZStack {
                Circle().fill(kind.fill)
                // opacity 切换而非条件插入：视图树不增删，避免状态重算
                // 重置鼠标 tracking 导致按钮间移动时符号丢失
                glyph(kind)
                    .opacity(groupHovered || hoveredKind == kind ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { entering in
            hoveredKind = entering ? kind : (hoveredKind == kind ? nil : hoveredKind)
        }
        .help(tooltip(kind))
    }

    private func tooltip(_ kind: Kind) -> String {
        switch kind {
        case .close: return "关闭"
        case .minimize: return "最小化"
        case .zoom: return "缩放"
        }
    }

    /// 对捕获的所在窗口执行对应操作（与系统按钮行为一致）。
    private func perform(_ kind: Kind) {
        guard let window = targetWindow else { return }
        switch kind {
        case .close: window.performClose(nil)
        case .minimize: window.performMiniaturize(nil)
        case .zoom: window.performZoom(nil)
        }
    }
}

/// 拿到视图所在 NSWindow 引用的辅助 representable。
private struct WindowRef: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onResolve(window) }
        }
    }
}

/// 缩放符号用的小三角：尖朝左上（直角边贴右上与左下）。
private struct GlyphTriangleTL: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))   // 尖：左上
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 缩放符号用的小三角：尖朝右下（直角边贴右上与左下）。
private struct GlyphTriangleBR: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))   // 尖：右下
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
