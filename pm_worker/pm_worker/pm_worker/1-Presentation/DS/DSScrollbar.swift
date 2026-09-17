import SwiftUI

// MARK: - 细滚动条

/// 系统滚动条在鼠标「始终显示」模式下是 ~15px 的粗轨道，视觉过重。
/// 全项目滚动容器统一走 `DSScroll`（ScrollView 的替代写法）或 `.dsScrollbar()`
/// （List 等自滚容器）：隐藏原生指示器，改由 DS 渲染 4px 胶囊——
/// 滚动时淡入，静止 0.9s 后淡出；胶囊不做命中测试，不挡内容交互。
///
/// 几何观察用 `onScrollGeometryChange`（已实测：直接挂在 ScrollView 本体
/// 上即可随动，无需放内容层内部）。
nonisolated struct DSScrollSnapshot: Equatable, Sendable {
    /// 滚动进度 0...1（胶囊顶点比例）。
    var progress: CGFloat
    /// 视口占内容长度的比例；>= 1 说明无溢出，不显示。
    var fraction: CGFloat

    static let hidden = DSScrollSnapshot(progress: 0, fraction: 1)

    var isHidden: Bool { fraction >= 0.999 }
}

struct DSScrollbarModifier: ViewModifier {
    var axis: Axis = .vertical

    @State private var snapshot = DSScrollSnapshot.hidden
    @State private var visible = false
    @State private var fadeTask: Task<Void, Never>?

    private var overlayAlignment: Alignment {
        axis == .vertical ? Alignment.trailing : Alignment.bottom
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .overlay(alignment: overlayAlignment) {
                knob
                    .opacity(visible && !snapshot.isHidden ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onScrollGeometryChange(for: DSScrollSnapshot.self) { geo in
                Self.snapshot(from: geo, axis: axis)
            } action: { _, new in
                show(new)
            }
    }

    /// 4px 胶囊：贴滚动容器内缘留 2px 边距，最短 24px 可点区视觉长度。
    private var knob: some View {
        GeometryReader { gp in
            let trackLen = max(0, (axis == .vertical ? gp.size.height : gp.size.width) - DS.Spacing.s4)
            let knobLen = min(max(24, trackLen * snapshot.fraction), trackLen)
            let travel = max(0, trackLen - knobLen)
            let offset = DS.Spacing.s2 + snapshot.progress * travel
            Capsule()
                .fill(Color.ink500.opacity(0.9))
                .frame(
                    width: axis == .vertical ? DS.Spacing.s4 : knobLen,
                    height: axis == .vertical ? knobLen : DS.Spacing.s4
                )
                .position(
                    x: axis == .vertical ? gp.size.width - DS.Spacing.s2 - DS.Spacing.s2 : offset + knobLen / 2,
                    y: axis == .vertical ? offset + knobLen / 2 : gp.size.height - DS.Spacing.s2 - DS.Spacing.s2
                )
        }
    }

    @MainActor
    private func show(_ new: DSScrollSnapshot) {
        snapshot = new
        fadeTask?.cancel()
        guard !new.isHidden else {
            if visible {
                withAnimation(DS.Motion.springFast) { visible = false }
            }
            return
        }
        if !visible {
            withAnimation(DS.Motion.springFast) { visible = true }
        }
        // 静止 0.9s 后淡出；持续滚动时几何持续变化，会不断重置本计时。
        fadeTask = Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.springFast) { visible = false }
        }
    }

    nonisolated private static func snapshot(from geo: ScrollGeometry, axis: Axis) -> DSScrollSnapshot {
        let contentLen = axis == .vertical ? geo.contentSize.height : geo.contentSize.width
        let visibleLen = axis == .vertical ? geo.visibleRect.height : geo.visibleRect.width
        let pos = axis == .vertical ? geo.visibleRect.minY : geo.visibleRect.minX
        guard contentLen > 0, contentLen - visibleLen > 1 else { return .hidden }
        return DSScrollSnapshot(
            progress: min(max(pos / (contentLen - visibleLen), 0), 1),
            fraction: min(visibleLen / contentLen, 1)
        )
    }
}

/// ScrollView 的 DS 版本：细滚动条统一入口。
/// 调用点写法与 ScrollView 一致，仅换名字：`DSScroll { … }` / `DSScroll(.horizontal) { … }`。
struct DSScroll<Content: View>: View {
    var axis: Axis
    @ViewBuilder var content: () -> Content

    init(_ axis: Axis = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.axis = axis
        self.content = content
    }

    private var scrollAxes: Axis.Set {
        axis == .vertical ? Axis.Set.vertical : Axis.Set.horizontal
    }

    var body: some View {
        // showsIndicators: false 必须传 init 参数（老 API 走底层关闭路径）：
        // macOS 上 .scrollIndicators(.hidden) 对 LazyVStack 等内容压不住自绘
        // overlay 指示器，会与细胶囊并存成「两条」（实测踩坑）。
        ScrollView(scrollAxes, showsIndicators: false) {
            content()
        }
        .modifier(DSScrollbarModifier(axis: axis))
    }
}

extension View {
    /// 给非 ScrollView 的滚动容器（List 等）加细滚动条。
    func dsScrollbar(axis: Axis = .vertical) -> some View {
        modifier(DSScrollbarModifier(axis: axis))
    }
}
