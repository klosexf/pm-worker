import SwiftUI

// MARK: - 细滚动条

/// 系统滚动条在鼠标「始终显示」模式下是 ~15px 的粗轨道，视觉过重；
/// macOS 26 起玻璃样式的轨道底与两侧边更明显。全项目滚动容器统一走
/// `DSScroll`（ScrollView 的替代写法，init 参数关闭原生指示器）：
/// 隐藏原生指示器，改由 DS 渲染 4px 胶囊——滚动时淡入，静止 0.9s 后淡出；
/// 胶囊本身不做命中测试，但 DSScroll 路径在其上加了一圈 12px 隐形热区，
/// 支持鼠标按住拖动（ScrollPosition 回写）；热区只随胶囊出现、不铺全高
/// 轨道，右缘内容点击不被吞。贴 HSplitView 分割条的 pane（左栏 / 中栏各页）
/// 传 `dsScrollDividerEdgeClearance` 让胶囊与热区内收 6px——分割条调栏宽的
/// 拖拽不被滚动条截胡，两者操作区域明确分离。外挂 WKWebView 版
/// （dsExternalScrollbar）无 SwiftUI 几何回调，只读不可拖。
/// List 一律改写为 `DSScroll { LazyVStack { … } }`（List 的原生滚动条
/// `.scrollIndicators(.hidden)` 压不住且无 init 兜底，2026-09-17 三个 List
/// 全部迁移后 `.dsScrollbar()` 已无调用点，随之移除）。
/// WKWebView（mermaid/原型预览）走 CSS scrollbar-width/scrollbar-color 降噪。
///
/// 几何观察用 `onScrollGeometryChange`（已实测：直接挂在 ScrollView 本体
/// 上即可随动，无需放内容层内部）。
nonisolated struct DSScrollSnapshot: Equatable, Sendable {
    /// 滚动进度 0...1（胶囊顶点比例）。
    var progress: CGFloat
    /// 视口占内容长度的比例；>= 1 说明无溢出，不显示。
    var fraction: CGFloat
    /// 视口容器沿滚动轴的长度（拖动换算用；外挂 WKWebView 路径不填）。
    var containerLen: CGFloat = 0
    /// 内容可滚动余量 contentLen - visibleLen（拖动换算用；外挂路径不填）。
    var maxOffset: CGFloat = 0

    static let hidden = DSScrollSnapshot(progress: 0, fraction: 1)

    var isHidden: Bool { fraction >= 0.999 }
}

struct DSScrollbarModifier: ViewModifier {
    var axis: Axis = .vertical
    /// DSScroll 传入：拖动胶囊时把进度映射回滚动位置。外挂版不传 → 不可拖。
    var position: Binding<ScrollPosition>? = nil
    /// 胶囊与拖动热区距容器滚动轴内缘的让位距离（贴 HSplitView 分割条的
    /// pane 传 `dsScrollDividerEdgeClearance`，把分割条抓取区完整让出）。
    var edgeClearance: CGFloat = DS.Spacing.s2

    /// 拖动热区宽度：4px 胶囊外扩到 12px 的隐形命中面（贴边可抓）。
    nonisolated private static let hitWidth: CGFloat = 12

    @State private var snapshot = DSScrollSnapshot.hidden
    @State private var visible = false
    @State private var fadeTask: Task<Void, Never>?
    @State private var dragging = false
    /// 抓取锚点：按下时的指尖位置与胶囊进度，拖动期间按「位移差」换算，
    /// 拇指跟手不跳变（点在胶囊边缘不会把拇指中心拉到指尖）。
    @State private var dragStartLocation: CGFloat?
    @State private var dragStartProgress: CGFloat = 0
    /// 抓取时冻结的可滚动余量：拖动换算只用抓取瞬间的几何，不受逐帧
    /// 几何回放扰动（常规拖动中内容几何不变，与 snapshot.maxOffset 同值）。
    @State private var dragStartMaxOffset: CGFloat = 0

    private var overlayAlignment: Alignment {
        axis == .vertical ? Alignment.trailing : Alignment.bottom
    }

    func body(content: Content) -> some View {
        content
            // 必须 .never（2026-09-17 探针实证）：macOS 26 上 .hidden 语义 =
            // 「平时隐藏、滚动时仍显示」——原生玻璃条照画；.never 才强制永不绘制。
            // init 参数 showsIndicators:false 同样压不住（同 .hidden 语义）。
            .scrollIndicators(.never)
            .overlay(alignment: overlayAlignment) {
                knob
                    .opacity((visible || dragging) && !snapshot.isHidden ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: overlayAlignment) {
                dragSurface
            }
            .onScrollGeometryChange(for: DSScrollSnapshot.self) { geo in
                Self.snapshot(from: geo, axis: axis)
            } action: { _, new in
                show(new)
            }
    }

    /// 4px 胶囊：距滚动容器内缘 `edgeClearance`，最短 24px 可点区视觉长度。
    private var knob: some View {
        dsScrollKnob(axis: axis, snapshot: snapshot, clearance: edgeClearance)
    }

    /// 拖动热区：盖在胶囊上的隐形矩形（宽 hitWidth、长 = 胶囊长 + hitWidth），
    /// 仅在「可拖（position 非空）且有溢出」时存在。不铺全高轨道热区，
    /// 右缘内容点击不被吞；胶囊淡出后热区仍留在最后位置，可直接抓取。
    @ViewBuilder
    private var dragSurface: some View {
        if let position, !snapshot.isHidden {
            GeometryReader { gp in
                let trackLen = max(0, (axis == .vertical ? gp.size.height : gp.size.width) - edgeClearance * 2)
                let knobLen = min(max(24, trackLen * snapshot.fraction), trackLen)
                let travel = max(0, trackLen - knobLen)
                if travel > 0, snapshot.maxOffset > 0 {
                    // 热区钉在抓取瞬间的胶囊位置（拖动中不随拇指移动）：
                    // 热区视图自身移动会带着手势坐标系一起动——location 反馈给
                    // 进度、进度又反推热区位置，形成反馈回路，拖动出现迟滞抖动
                    // （2026-09-17 弹框拖滚动条卡顿根因）。冻结后 location 的
                    // 位移差就是纯指尖位移；视觉胶囊由 snapshot 驱动照常跟手。
                    let anchorProgress = dragging ? dragStartProgress : snapshot.progress
                    let center = edgeClearance + anchorProgress * travel + knobLen / 2
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(
                            width: axis == .vertical ? Self.hitWidth : knobLen + Self.hitWidth,
                            height: axis == .vertical ? knobLen + Self.hitWidth : Self.hitWidth
                        )
                        .position(
                            x: axis == .vertical
                                ? gp.size.width - Self.hitWidth / 2 - edgeClearance
                                : center,
                            y: axis == .vertical
                                ? center
                                : gp.size.height - Self.hitWidth / 2 - edgeClearance
                        )
                        .gesture(dragGesture(position, travel: travel))
                }
            }
        }
    }

    private func dragGesture(_ position: Binding<ScrollPosition>, travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = axis == .vertical ? value.location.y : value.location.x
                if !dragging {
                    dragging = true
                    dragStartLocation = location
                    dragStartProgress = snapshot.progress
                    dragStartMaxOffset = snapshot.maxOffset
                }
                fadeTask?.cancel()
                let start = dragStartLocation ?? location
                let progress = min(max(dragStartProgress + (location - start) / travel, 0), 1)
                let target = progress * dragStartMaxOffset
                switch axis {
                case .vertical: position.wrappedValue.scrollTo(y: target)
                case .horizontal: position.wrappedValue.scrollTo(x: target)
                }
            }
            .onEnded { _ in
                dragging = false
                dragStartLocation = nil
                scheduleFade()
            }
    }

    @MainActor
    private func show(_ new: DSScrollSnapshot) {
        snapshot = new
        fadeTask?.cancel()
        guard !new.isHidden else {
            // 拖动中内容收缩到无溢出：热区随之消失，手势终止态兜底复位。
            dragging = false
            dragStartLocation = nil
            if visible {
                withAnimation(DS.Motion.springFast) { visible = false }
            }
            return
        }
        // 拖动中只跟进几何（拇指随 scrollTo 回写移动），淡出留给 onEnded。
        guard !dragging else { return }
        if !visible {
            withAnimation(DS.Motion.springFast) { visible = true }
        }
        scheduleFade()
    }

    /// 静止 0.9s 后淡出；持续滚动时几何持续变化，会不断重置本计时。
    @MainActor
    private func scheduleFade() {
        fadeTask?.cancel()
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
        let containerLen = axis == .vertical ? geo.containerSize.height : geo.containerSize.width
        guard contentLen > 0, contentLen - visibleLen > 1 else { return .hidden }
        return DSScrollSnapshot(
            progress: min(max(pos / (contentLen - visibleLen), 0), 1),
            fraction: min(visibleLen / contentLen, 1),
            containerLen: containerLen,
            maxOffset: contentLen - visibleLen
        )
    }
}

/// ScrollView 的 DS 版本：细滚动条统一入口。
/// 调用点写法与 ScrollView 一致，仅换名字：`DSScroll { … }` / `DSScroll(.horizontal) { … }`。
struct DSScroll<Content: View>: View {
    var axis: Axis
    /// 胶囊与拖动热区距容器滚动轴内缘的让位距离；默认 2px（窗口边缘等
    /// 无冲突场景），贴 HSplitView 分割条的 pane 传 `dsScrollDividerEdgeClearance`。
    var edgeClearance: CGFloat = DS.Spacing.s2
    @ViewBuilder var content: () -> Content
    /// 拖动细胶囊时的滚动位置回写（scrollTo(x/y)）。空闲态是无控制位置，
    /// 不影响常规滚轮/触板滚动与 ScrollViewReader 锚定（最后写入者胜）。
    @State private var position = ScrollPosition()

    init(
        _ axis: Axis = .vertical,
        edgeClearance: CGFloat = DS.Spacing.s2,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.axis = axis
        self.edgeClearance = edgeClearance
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
        .scrollPosition($position)
        .modifier(DSScrollbarModifier(axis: axis, position: $position, edgeClearance: edgeClearance))
    }
}

// MARK: - 外挂细胶囊（WKWebView 等无 SwiftUI 几何回调的容器）

/// 贴 HSplitView 分割条 pane 的滚动条让位（`DSScroll(edgeClearance:)` 实参）：
/// 胶囊与热区内收 6px，把分割条的窄抓取区完整让出——调栏宽的拖拽不再被
/// 滚动条截胡，胶囊与分割线之间也留出清晰视觉边界。放在文件级是因为
/// 泛型类型（DSScroll<Content>）不支持 static stored property。
nonisolated let dsScrollDividerEdgeClearance: CGFloat = 6

/// 细胶囊几何（DSScroll 内置版与外挂版共用）：4px 宽、最短 24、
/// 距容器内缘 `clearance`（默认 2px；贴分割条的 pane 加大让位）。
func dsScrollKnob(axis: Axis, snapshot: DSScrollSnapshot, clearance: CGFloat = DS.Spacing.s2) -> some View {
    GeometryReader { gp in
        let trackLen = max(0, (axis == .vertical ? gp.size.height : gp.size.width) - clearance * 2)
        let knobLen = min(max(24, trackLen * snapshot.fraction), trackLen)
        let travel = max(0, trackLen - knobLen)
        let offset = clearance + snapshot.progress * travel
        Capsule()
            .fill(Color.ink500.opacity(0.9))
            .frame(
                width: axis == .vertical ? DS.Spacing.s4 : knobLen,
                height: axis == .vertical ? knobLen : DS.Spacing.s4
            )
            .position(
                x: axis == .vertical ? gp.size.width - clearance - DS.Spacing.s2 : offset + knobLen / 2,
                y: axis == .vertical ? offset + knobLen / 2 : gp.size.height - clearance - DS.Spacing.s2
            )
    }
}

/// 给无法走 `onScrollGeometryChange` 的容器（WKWebView 等）外挂同款细胶囊：
/// 滚动几何由容器侧喂进来（snapshot Binding），淡入淡出与 DSScroll 同参。
/// 背景：macOS 26 玻璃滚动条带轨道底与两侧边且 CSS 无法定制
/// （scrollbar-color 要 Safari 26.2+；::-webkit-scrollbar 全系不支持），
/// WKWebView 侧一律 `scrollbar-width: none` 隐藏原生条，改挂本胶囊。
struct DSExternalScrollbarModifier: ViewModifier {
    var axis: Axis = .vertical
    @Binding var snapshot: DSScrollSnapshot
    @State private var visible = false
    @State private var fadeTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: axis == .vertical ? .trailing : .bottom) {
                dsScrollKnob(axis: axis, snapshot: snapshot)
                    .opacity(visible && !snapshot.isHidden ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onChange(of: snapshot) { _, new in
                show(new)
            }
    }

    @MainActor
    private func show(_ new: DSScrollSnapshot) {
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
}

extension View {
    /// 外挂细胶囊（配合 WKWebView 的 pmScroll 进度回报使用）。
    func dsExternalScrollbar(axis: Axis = .vertical, snapshot: Binding<DSScrollSnapshot>) -> some View {
        modifier(DSExternalScrollbarModifier(axis: axis, snapshot: snapshot))
    }
}

/// WKWebView 注入用：文档滚动进度回报（rAF 节流），配合 pmScroll
/// script message handler + `scrollbar-width: none`（隐藏原生条）一起用。
let webViewScrollReporterJS = """
(function () {
  var pending = false;
  function report() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () {
      pending = false;
      var d = document.scrollingElement || document.documentElement;
      if (!d) return;
      var vMax = d.scrollHeight - d.clientHeight;
      var hMax = d.scrollWidth - d.clientWidth;
      try {
        window.webkit.messageHandlers.pmScroll.postMessage({
          vProgress: vMax > 1 ? d.scrollTop / vMax : 0,
          vFraction: d.scrollHeight > 0 ? Math.min(d.clientHeight / d.scrollHeight, 1) : 1,
          hProgress: hMax > 1 ? d.scrollLeft / hMax : 0,
          hFraction: d.scrollWidth > 0 ? Math.min(d.clientWidth / d.scrollWidth, 1) : 1
        });
      } catch (e) {}
    });
  }
  window.addEventListener('scroll', report, { passive: true, capture: true });
  window.addEventListener('resize', report);
  report();
})();
"""
