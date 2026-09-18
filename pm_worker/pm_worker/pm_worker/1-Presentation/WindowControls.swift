//
//  WindowControls.swift
//  pm_worker
//
//  自绘窗口顶栏（对齐 Trae 参考图）：隐藏 macOS 系统红绿灯（连同其顶部安全区
//  占位），侧栏首行自绘「关闭 / 最小化 / 全屏」三色圆 + 侧栏折叠 + 搜索图标，
//  贴顶排列；行为直连 NSWindow（performClose / Miniaturize / toggleFullScreen）。
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
        // 每次 SwiftUI 更新都会回调（窗口 resize 时即每帧一次）：configure 内部
        // 先读后写恒等，值已正确时零副作用；frame 记忆只在窗口挂载时接线一次。
        (nsView as? WindowChromeView)?.attachIfNeeded()
    }

    final class WindowChromeView: NSView {
        private weak var attachedWindow: NSWindow?
        private var frameObservers: [NSObjectProtocol] = []
        private var pendingFrameSave: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            WindowChromeConfigurator.configure(window)
            guard let window, attachedWindow !== window else { return }
            attachedWindow = window
            // 首击直达：pane 宿主视图随布局懒挂载——挂窗时扫一遍 + 两次延迟补扫
            // （configure 每帧回调，扫树不能放那里，是性能陷阱）。
            FirstMouseDelivery.enable(in: window)
            for delay in [0.5, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    if let window { FirstMouseDelivery.enable(in: window) }
                }
            }
            WindowFrameMemory.restore(into: window)
            observeFrameChanges(of: window)
        }

        /// 拖动边框（live resize）与移动窗口结束时落盘 frame——拖动过程零写入
        /// （SwiftUI 的逐帧自动保存已在 configure 里关闭），0.6s 去抖合并连续事件
        ///（移动窗口时 didMove 密集触发）。
        private func observeFrameChanges(of window: NSWindow) {
            guard frameObservers.isEmpty else { return }
            let names: [Notification.Name] = [
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
            ]
            frameObservers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.scheduleFrameSave()
                }
            }
        }

        private func scheduleFrameSave() {
            pendingFrameSave?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let window = self?.window else { return }
                WindowFrameMemory.save(window)
            }
            pendingFrameSave = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }

        deinit {
            pendingFrameSave?.cancel()
            frameObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    /// 先读后写（幂等）：updateNSView 在 SwiftUI 每次更新都会回调，窗口 resize
    /// 时即每帧一次。set styleMask / titlebar 属性都会让 AppKit 重新布局标题栏
    /// 与内容视图（窗口服务器层失效），逐帧重复 set 是拖拽边框卡顿的来源之一；
    /// 值已正确时只做读取，零副作用（同时保留自愈能力：被外部改回去下一帧修正）。
    /// internal（非 private）供 WindowChromeTests 做防回归断言。
    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        // 后台窗口第一击直达控件：见 FirstMouseDelivery（挂窗时扫树补丁，
        // 不在此每帧路径——configure 逐帧回调，扫树是性能陷阱）。
        // 窗口背景不整体可拖（否则对话区等正文区域长按会拖动整个窗口）；
        // 移动窗口改由顶栏行的 WindowDragArea 接管。
        // 隐藏系统红绿灯（关闭 / 最小化 / 缩放）——顶部安全区随之不再预留
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)
            if button?.isHidden == false { button?.isHidden = true }
        }
        // 关键性能开关：关掉 SwiftUI（WindowGroup 自动挂的）窗口 frame 自动保存。
        // SwiftUI 在每次 setFrame 里都会 _persistFrame → saveFrame → 写 UserDefaults
        // → cfprefsd IPC 往返——拖动边框/窗口移动期间即每帧一次，实测占每帧成本
        // 一半以上（15.9ms → 8.2ms）。frame 记忆改由 WindowFrameMemory 在
        // resize/移动**结束后**存一次（成本与手感无关）。
        if !window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("")
        }
    }
}

// MARK: - 后台窗口第一击直达（acceptsFirstMouse）

/// macOS 默认：点击非前台窗口的第一击只激活窗口、不送达控件（NSHostingView
/// 未覆写 acceptsFirstMouse，走 NSView 默认 = 不接受）。本 App 是多窗口工作流
/// 里的常驻工具——用户从 IDE / 镜像 / 笔记切回来点台账、确认坞，第一击必须
/// 生效，否则永远「点了没反应」。
/// 实现：遍历窗口视图树，给每个 **NSHostingView 系类**（根 + HSplitView 各
/// pane 的宿主视图是不同泛型实例，2026-09-17 修正：只补根类不生效——真正
/// 的命中目标是 pane 宿主视图）补 acceptsFirstMouse override——class_addMethod
/// 只挂命中的类，不改 NSView 全局默认；幂等（每类只装一次）。
@MainActor
enum FirstMouseDelivery {
    private static var enabledClasses: Set<ObjectIdentifier> = []

    static func enable(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        patchTree(contentView)
    }

    private static func patchTree(_ view: NSView) {
        patch(view)
        view.subviews.forEach(patchTree)
    }

    private static func patch(_ view: NSView) {
        let cls: AnyClass = type(of: view)
        let key = ObjectIdentifier(cls)
        guard !enabledClasses.contains(key) else { return }
        guard isHostingView(cls) else { return }
        let sel = #selector(NSView.acceptsFirstMouse(for:))
        // 判断 cls 是否**直接**定义了该方法（class_getInstanceMethod 会命中
        // 继承链上的 NSView 实现，不能用它判重）——直接定义才允许改写，否则新增。
        var definedMethod: Method?
        var count: UInt32 = 0
        if let methods = class_copyMethodList(cls, &count) {
            for i in 0..<Int(count) where method_getName(methods[i]) == sel {
                definedMethod = methods[i]
            }
        }
        guard let stubMethod = class_getInstanceMethod(FirstMouseStub.self, sel),
              let types = method_getTypeEncoding(stubMethod) else { return }
        let imp = method_getImplementation(stubMethod)
        if let definedMethod {
            method_setImplementation(definedMethod, imp)
        } else if class_addMethod(cls, sel, imp, types) {
            // 新增 override 成功
        } else {
            return // 竞态兜底：加挂失败不重复标记，下次扫描重试
        }
        enabledClasses.insert(key)
    }

    /// 宿主视图判定：类或其任意祖先的运行时名含 NSHostingView
    /// （覆盖泛型特化与 SwiftUI 内部 ViewHost 等子类命名）。
    private static func isHostingView(_ cls: AnyClass) -> Bool {
        var c: AnyClass? = cls
        while let current = c, current as AnyObject !== NSView.self {
            if NSStringFromClass(current).contains("NSHostingView") { return true }
            c = class_getSuperclass(current)
        }
        return false
    }

    /// 只为借 IMP 的空壳视图：语义 = 第一击一律送达（与 DividerHandle 同签名，
    /// 本项目 SDK 里返回 Bool）。
    private final class FirstMouseStub: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - 窗口 frame 记忆（自管，替代 SwiftUI 逐帧自动保存）

/// 主窗口位置/尺寸记忆：保存走「拖拽结束 / 移动结束」的去抖写入，还原只做一次。
/// 为什么不让 SwiftUI 自动保存：WindowGroup 在每次 setFrame 里都会 saveFrame →
/// 写 UserDefaults → cfprefsd IPC，拖动边框的每一帧都吃一次往返（实测占每帧成本
/// 一半以上，是拖拽卡顿主因）。自管后拖动过程零写入，手感与持久化兼得。
private enum WindowFrameMemory {
    private static let key = "pm.worker.window.mainFrame"

    static func save(_ window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }

    /// 还原：仅当保存的 frame 仍与某块屏幕的可见区域相交时应用——
    /// 换显示器 / 拔掉外接屏后不把窗口还原到屏幕外（那种情况退回默认尺寸）。
    static func restore(into window: NSWindow) {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return }
        let frame = NSRectFromString(raw)
        guard frame.width >= 200, frame.height >= 200 else { return }
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
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

/// 侧栏首行：自绘「关闭 / 最小化 / 全屏」三圆 + 可选 trailing 图标（折叠 / 搜索），
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
        .background(WindowDragArea { targetWindow = $0 })
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
            // 对角双三角（macOS Big Sur+ 原生全屏符号形制）：
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
        case .zoom: return isFullScreen ? "退出全屏" : "进入全屏"
        }
    }

    /// 当前是否已处于全屏（决定绿钮提示文案与点击语义）。
    private var isFullScreen: Bool {
        targetWindow?.styleMask.contains(.fullScreen) == true
    }

    /// 对捕获的所在窗口执行对应操作（与系统按钮行为一致）。
    /// 绿钮 = 全屏切换（对齐 macOS 原生绿钮语义；缩放/最大化仍可拖拽窗口边缘达成）。
    private func perform(_ kind: Kind) {
        guard let window = targetWindow else { return }
        switch kind {
        case .close: window.performClose(nil)
        case .minimize: window.performMiniaturize(nil)
        case .zoom: window.toggleFullScreen(nil)
        }
    }
}

/// 顶栏拖拽区：捕获所在 NSWindow 引用，并接管窗口移动——mouseDown 时进入
/// 系统拖拽循环（与原生标题栏同机制）。仅覆盖顶栏行下层，正文区域不触发。
private struct WindowDragArea: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DragAreaView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragAreaView else { return }
        view.onResolve = onResolve
        // 回写窗口引用会改 @State（WindowControlButtons.targetWindow），进而让
        // 本视图再更新一次。旧实现在每次 SwiftUI 更新都派发一次主队列回写，
        // 窗口 resize 的每一帧都会走这个「更新 → 回写 → 再更新」循环，白吃一次
        // 全树失效 + 布局 pass。窗口身份不会变，解析一次即够；仅挂载瞬间
        // window 尚未就绪（viewDidMoveToWindow 早于挂载完成）时兜底补一次。
        guard view.resolvedWindow == nil else { return }
        DispatchQueue.main.async { view.resolveIfNeeded() }
    }

    private final class DragAreaView: NSView {
        var onResolve: ((NSWindow) -> Void)?
        private(set) weak var resolvedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfNeeded()
        }

        func resolveIfNeeded() {
            guard let window, resolvedWindow !== window else { return }
            resolvedWindow = window
            onResolve?(window)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// 全屏符号用的小三角：尖朝左上（直角边贴右上与左下）。
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

/// 全屏符号用的小三角：尖朝右下（直角边贴右上与左下）。
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
