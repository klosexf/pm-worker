//
//  InspectorPanel.swift
//  pm_worker
//
//  右栏四 Tab 面板（design.md §6.4 v0.9.2）：产物 / 决策日志 / 漏项雷达 / 知识点。
//  方案 A 分区台账容器：「产物」台账（01~07 编号目录内的 .md/.html/.mmd
//  按类归档 + 筛选 chips + 点击整行预览）与「工作空间文件」档案树
//  （版本目录全量内容，含产物目录与产物文件，面包屑标注磁盘目录，
//  文件夹可展开折叠）上下双区布局，中间可拖分隔条调整高度占比（比例持久化，
//  双击复位）。
//  决策日志 / 风险读 decisions.jsonl / risks.jsonl 真实数据
//  （DecisionLogTab / RiskRadarTab 风险台账）；知识点为检索 + 命中卡 + 主动推荐完整版
//  （Task 4.6，KnowledgeTab）。底部常驻 ⌘D 入口打开开发者检查器窗口。
//

import SwiftUI
import Combine

struct InspectorPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    // 知识点 Tab 已移除（2026-09-17 钦定）：语义检索收口到左栏知识库整页，
    // 右栏回归「会话伴随上下文」三 Tab（文件 / 决策日志 / 风险）
    enum InspectorTab: String, CaseIterable, Identifiable {
        case artifacts = "文件"
        case decisions = "决策日志"
        case radar = "风险"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 原型 .seg 胶囊分段（激活段白底浮起），替换系统 segmented Picker；
            // 右缘折叠钮（Trae 惯例位置：面板头部右上角，不占内容区）
            HStack(spacing: DS.Spacing.s8) {
                DSTabs(
                    items: [
                        DSTabItem(InspectorTab.artifacts, InspectorTab.artifacts.rawValue),
                        DSTabItem(InspectorTab.decisions, InspectorTab.decisions.rawValue),
                        DSTabItem(InspectorTab.radar, InspectorTab.radar.rawValue),
                    ],
                    selection: $model.inspectorTab
                )

                TopBarIconButton(name: .panelRight, flipX: false) {
                    withAnimation(DS.Motion.spring) { model.inspectorCollapsed = true }
                }
                .help("收起右侧面板")
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.top, DS.Spacing.s10)
            .padding(.bottom, DS.Spacing.s8)

            // 每个 Tab 内容统一撑满剩余高度（空态 DSEmptyState 居中不塌缩，
            // 底部工具条恒定贴底——消除切换 Tab 时面板高度跳动）。
            Group {
                switch model.inspectorTab {
                case .artifacts:
                    artifactsTab
                case .decisions:
                    DecisionLogTab()
                case .radar:
                    RiskLedgerTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DSDivider()

            // 底部常驻入口（Task 4.6）：⌘D 打开开发者检查器（Token 构成 / 检索 trace）
            HStack {
                Text(model.pipeline.project)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                    .lineLimit(1)
                Spacer()
                Button {
                    openWindow(id: "developer-inspector")
                } label: {
                    Label {
                        Text("开发者检查器 ⌘D")
                    } icon: {
                        DSIcon(.flask, size: 14)
                    }
                    .font(DS.Font.bodySM)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink500)
                .help("打开开发者检查器：Token 构成 / 检索 trace / 分支触发 / 记忆校准注入 / 风险工程口径")
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s6)
        }
        .frame(minWidth: 240)
    }

    // MARK: - 产物 Tab（方案 A 分区台账：产物在上 / 工作空间文件在下）

    private var artifactsTab: some View {
        Group {
            if let ctx = model.selection.inspectorProject {
                // 「默认」兜底容器同样可浏览：产物落了盘就该能看（文件树只读
                // 该项目自己的目录，不回退显示其他项目，无 scope 串味）。
                ArtifactsPanelView(project: ctx.project, version: ctx.version)
            } else {
                // 未定位到任何项目上下文（新任务页等）：空态。
                DSEmptyState(
                    icon: .folder,
                    title: "产物 · 0",
                    description: "开始任务并产生落盘产物后，在此预览该容器的文件树。"
                )
                .padding(.horizontal, DS.Spacing.s16)
                .padding(.vertical, DS.Spacing.s12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 右栏收起态的悬浮展开钮（不占布局宽度，由 ContentView 以 overlay 挂在中栏
/// 右上角）：28pt 圆角方块浮起（surface 底 + hairline 描边 + 双层阴影），
/// hover 底色升阶 + 阴影抬升，图标与面板头部收起钮同形制。
struct InspectorExpandButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(DS.Motion.spring) { model.inspectorCollapsed = false }
        } label: {
            DSIcon(.panelRight, size: 15)
                .foregroundStyle(hovered ? Color.ink700 : Color.ink500)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(hovered ? Color.overlayL2 : Color.surfaceSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .strokeBorder(Color.borderL1)
                )
                .dsShadow(hovered ? .floating : .card)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(DS.Motion.springFast) { self.hovered = hovered }
        }
        .help("展开右侧面板")
    }
}

/// 文件树节点（只读投影；nonisolated 纯数据，供扫描纯函数与测试共用）。
nonisolated struct FileNode: Identifiable, Hashable {
    var name: String
    var url: URL
    var isDirectory: Bool
    var children: [FileNode]?
    /// 文件体量（目录为 nil），工作空间行 hover 元信息用。
    var sizeBytes: Int?

    var id: String { url.path }

    init(
        name: String, url: URL, isDirectory: Bool,
        children: [FileNode]? = nil, sizeBytes: Int? = nil
    ) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.sizeBytes = sizeBytes
    }
}

// MARK: - 产物面板（双分区容器）

/// 方案 A 分区台账容器：「产物」台账与「工作空间文件」档案树上下双区布局，
/// 中间夹一条可拖分隔条（拖动实时调整两区高度占比，双击复位，比例持久化）。
/// 预览 sheet（html → HTMLPreview，其余 → Mermaid）由本视图持有。
struct ArtifactsPanelView: View {

    @EnvironmentObject private var model: AppModel

    let project: String
    let version: String

    private static let ratioKey = "pm.worker.inspector.ledgerRatio"
    private static let minRatio: CGFloat = 0.15
    private static let maxRatio: CGFloat = 0.85
    private static let defaultRatio: CGFloat = 0.55
    /// 分隔条抓取条带高度：肉眼可瞄准的宽度（1pt 发丝线居中，整条可按）。
    private static let handleHeight: CGFloat = 22

    @State private var entries: [ArtifactEntry] = []
    @State private var workspace: FileNode?
    @State private var selectedID: String?
    @State private var previewTarget: FileNode?
    @State private var reloadToken = 0
    /// 台账区占可用高度的比例（拖动 1:1 跟踪，不参与动画，避免拖拽闪烁）。
    @State private var ratio: CGFloat = {
        let stored = UserDefaults.standard.object(
            forKey: "pm.worker.inspector.ledgerRatio"
        ) as? Double ?? 0.55
        return CGFloat(min(max(stored, 0.15), 0.85))
    }()
    @State private var dragStartRatio: CGFloat = 0
    @State private var isDragging = false
    @State private var handleHovered = false

    private var clampedRatio: CGFloat {
        min(max(ratio, Self.minRatio), Self.maxRatio)
    }

    var body: some View {
        Group {
            if entries.isEmpty && workspace == nil {
                // 版本目录尚不存在（新容器未落盘）：空态。
                DSEmptyState(
                    icon: .folder,
                    title: "产物 · 0",
                    description: "开始任务并产生落盘产物后，在此预览该容器的文件树。"
                )
                .padding(.horizontal, DS.Spacing.s16)
                .padding(.vertical, DS.Spacing.s12)
            } else {
                splitLayout
            }
        }
        .onAppear { reloadToken += 1 }
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name("pm.worker.artifacts.changed")
            // 发帖侧可能是后台线程（MCP 无头写入等），归位主线程再改 @State
        ).receive(on: DispatchQueue.main)) { _ in reloadToken += 1 }
        // 重载 id 必须绑定 project/version：切换会话/项目时视图结构身份不变、
        // @State 残留，只盯 reloadToken 会把上一个项目的台账原样显示给新项目
        // （真实事故：右栏显示「默认」的产物，聊天却已切到别的项目）。名称经
        // validateNodeName 禁「/」，用 / 分隔无碰撞。
        .task(id: "\(project)/\(version)#\(reloadToken)") { reload() }
        .sheet(item: $previewTarget) { node in
            if node.url.pathExtension.lowercased() == "html" {
                HTMLPreviewSheet(title: node.name, fileURL: node.url)
            } else {
                MermaidPreviewSheet(title: node.name, fileURL: node.url)
            }
        }
    }

    // MARK: 双区布局（上：产物台账 · 下：工作空间文件 · 中：可拖分隔条）

    private var splitLayout: some View {
        GeometryReader { geo in
            let available = max(geo.size.height - Self.handleHeight, 0)
            let topHeight = available * clampedRatio
            VStack(spacing: 0) {
                DSScroll {
                    ArtifactsLedgerView(
                        entries: entries,
                        selectedID: selectedID,
                        onSelect: { selectedID = $0.id },
                        onOpen: { openPreview($0) },
                        onAddToConversation: { entry in
                            // 「添加到对话」：把引用排队给输入坞（ConversationView 消费）
                            model.requestAddFileReference(relativePath: entry.relativePath)
                        },
                        canPromoteToMaster: { entry in
                            // 阶段 4 台账选主：非主槽位原型槽位文件才显示；
                            // 版本 busy（流/待回复进行中）时隐藏——流完成会写原型
                            // 槽位，此刻选主会与落盘竞态（AppModel 侧另有兜底拦截）。
                            AppModel.isPromotablePrototypePath(entry.relativePath)
                                && !model.sessionStore.isVersionBusy(
                                    project: project, version: version
                                )
                        },
                        onSelectAsMaster: { entry in
                            model.setAsMasterPrototype(relativePath: entry.relativePath)
                        }
                    )
                }
                .frame(height: topHeight)

                splitHandle(availableHeight: available)

                DSScroll {
                    workspaceSection
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// 可拖分隔条：22pt 可抓取条带（1pt 发丝线居中）。视觉由 SwiftUI 绘制，
    /// 鼠标跟踪下沉 AppKit（DividerHandle）——SwiftUI DragGesture 在 macOS 上
    /// 与鼠标配合不可靠（按下偶发丢失、hover 动画期间 hit-test miss、布局
    /// 重建打断手势），AppKit mouseDown/mouseDragged 跟踪独立于 SwiftUI
    /// 渲染，按下即抓、1:1 跟踪不丢事件；双击复位由 clickCount 原生判定
    /// （跟随系统双击速度），光标由 resetCursorRects 提供。
    /// 高度变化 1:1 跟踪不参与动画（防闪烁），视觉态变化走 spring。
    private func splitHandle(availableHeight: CGFloat) -> some View {
        ZStack {
            // 可抓取区域可视化：常态透明，hover 微亮，拖动品牌色水洗
            Rectangle()
                .fill(isDragging ? Color.brand100.opacity(0.6) : Color.surfaceSecondary)
                .opacity(handleHovered || isDragging ? 1 : 0)
            Rectangle()
                .fill(lineColor)
                .frame(height: 1)
            Capsule()
                .fill(isDragging ? Color.brandAccent : Color.ink300)
                .frame(width: 32, height: 4)
                .scaleEffect(isDragging ? 1.2 : 1)
                .opacity(handleHovered || isDragging ? 1 : 0)
        }
        .frame(height: Self.handleHeight)
        .contentShape(Rectangle())
        .overlay {
            DividerHandle(
                onStart: {
                    isDragging = true
                    dragStartRatio = ratio
                },
                onDrag: { translationY in
                    // translationY：相对按下点的纵向位移，向下为正（窗口坐标取反）
                    let delta = translationY / max(availableHeight, 1)
                    ratio = min(max(dragStartRatio + delta, Self.minRatio), Self.maxRatio)
                },
                onEnd: { moved, doubleClicked in
                    isDragging = false
                    if doubleClicked {
                        // 双击复位：程序化变化走 spring
                        withAnimation(DS.Motion.spring) {
                            ratio = Self.defaultRatio
                            UserDefaults.standard.set(
                                Double(Self.defaultRatio), forKey: Self.ratioKey
                            )
                        }
                    } else if moved {
                        UserDefaults.standard.set(Double(clampedRatio), forKey: Self.ratioKey)
                    }
                },
                onHover: { inside in handleHovered = inside }
            )
        }
        .animation(DS.Motion.springFast, value: isDragging)
        .animation(DS.Motion.springFast, value: handleHovered)
        .onDisappear { handleHovered = false }
        .help("上下拖动调整分区高度 · 双击复位")
    }

    /// 分隔条发丝线颜色：常态 borderL1（与 DSDivider 同视觉），hover 提阶，拖动中品牌色。
    private var lineColor: Color {
        isDragging ? Color.brandAccent : (handleHovered ? Color.ink300 : Color.borderL1)
    }

    private func reload() {
        let root = PMAgentStore.versionURL(project: project, version: version)
        entries = ArtifactCatalog.scanArtifacts(in: root)
        workspace = ArtifactCatalog.workspaceTree(in: root)
    }

    private func openPreview(_ entry: ArtifactEntry) {
        previewTarget = FileNode(
            name: entry.name, url: entry.url, isDirectory: false, children: nil
        )
    }

    // MARK: 工作空间文件分区

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 节头：只留衬线标题（计数与口径提示按评审结论移除）
            // 分区与上方台账的间隔由可拖分隔条承担，此处不再放 DSDivider。
            Text("工作空间文件")
                .font(DS.Font.display2XS)
                .foregroundStyle(Color.ink900)
                .padding(.horizontal, DS.Spacing.s16)
                .padding(.top, DS.Spacing.s12)
                .padding(.bottom, DS.Spacing.s8)

            // 面包屑紧贴节头之下：先声明磁盘目录，再列目录内容
            DSBreadcrumb(segments: Self.pathSegments(project: project, version: version))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.s16)
                .padding(.bottom, DS.Spacing.s6)

            if let workspace {
                FileOutlineNodes(
                    nodes: workspace.children ?? [],
                    depth: 0,
                    selectedID: selectedID,
                    onSelect: { selectedID = $0.id },
                    onOpenFile: { previewTarget = $0 }
                )
                .padding(.horizontal, DS.Spacing.s8)
                .padding(.bottom, DS.Spacing.s12)
            } else {
                // 目录树加载占位（原型 .ds-skeleton）
                VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                    DSSkeletonLine(width: 140)
                    DSSkeletonLine(width: 200)
                    DSSkeletonLine(width: 180)
                    DSSkeletonLine(width: 160)
                }
                .padding(DS.Spacing.s16)
            }
        }
    }

    /// 面包屑分段：PMAgent / Projects / 项目 / 版本（前段可点，末段高亮）。
    private static func pathSegments(
        project: String, version: String
    ) -> [DSBreadcrumb.Segment] {
        [
            DSBreadcrumb.Segment(title: "PMAgent") {
                NSWorkspace.shared.open(PMAgentStore.root)
            },
            DSBreadcrumb.Segment(title: "Projects") {
                NSWorkspace.shared.open(PMAgentStore.projectsDir)
            },
            DSBreadcrumb.Segment(title: project) {
                NSWorkspace.shared.open(PMAgentStore.projectURL(project))
            },
            DSBreadcrumb.Segment(title: version),
        ]
    }
}

// MARK: - 分隔条鼠标跟踪层（AppKit）

/// 透明 NSView，只做分隔条的鼠标事件捕获：mouseDown 即抓取、mouseDragged
/// 1:1 回传相对按下点的位移、mouseUp 结算；hover 光标由 resetCursorRects
/// 原生提供，拖动全程 push resize 光标（甩出条带不丢）。视图自身零绘制，
/// 视觉由 SwiftUI 层（splitHandle 的 ZStack）负责。
/// 位移用 event.locationInWindow 窗口坐标做差——拖动中布局变化（上区变高、
/// 分隔条自身下移）不影响窗口坐标基准，1:1 跟手不粘滞；勿用 convert 到
/// 视图自身坐标（视图在动，反馈回路会让位移只跟一半）。
private struct DividerHandle: NSViewRepresentable {
    var onStart: () -> Void
    var onDrag: (_ translationY: CGFloat) -> Void
    var onEnd: (_ moved: Bool, _ doubleClicked: Bool) -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onStart = onStart
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        // 每次 SwiftUI 渲染刷新闭包，捕获的 available/ratio 保持最新
        nsView.onStart = onStart
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
        nsView.onHover = onHover
    }

    final class HandleView: NSView {
        var onStart: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: ((Bool, Bool) -> Void)?
        var onHover: ((Bool) -> Void)?

        /// 按下点的窗口坐标 y（窗口原点在左下、y 向上，鼠标下移差值为负）。
        private var startLocationY: CGFloat = 0
        private var dragMoved = false
        private var trackingArea: NSTrackingArea?
        private var dragCursorPushed = false

        /// 关键：hiddenTitleBar（全尺寸内容区）下，透明视图默认允许把按下
        /// 事件让给窗口拖动——不显式拒绝，按下分隔条会变成拖动整个窗口。
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            startLocationY = event.locationInWindow.y
            dragMoved = false
            if !dragCursorPushed { NSCursor.resizeUpDown.push(); dragCursorPushed = true }
            if event.clickCount == 2 {
                // 双击第二击：clickCount 原生判定（跟随系统双击速度），立即结算复位
                onEnd?(false, true)
                // 复位后重抓基底——双击后不松手继续拖，以默认档为起点
                onStart?()
            } else {
                onStart?()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            // 窗口坐标差取反：鼠标下移 → y 减小 → translation 为正（向下分给上区）
            let translation = startLocationY - event.locationInWindow.y
            if abs(translation) > 2 { dragMoved = true }
            onDrag?(translation)
        }

        override func mouseUp(with event: NSEvent) {
            if dragCursorPushed { NSCursor.pop(); dragCursorPushed = false }
            // 双击已在 mouseDown 结算复位；此处再结算一次无害（moved=false 不持久化）
            onEnd?(dragMoved, false)
        }
    }
}

// MARK: - 档案树（工作空间文件区递归视图）

/// 文件树递归节点视图（View 结构体递归，规避 opaque 类型自引用）。
private struct FileOutlineNodes: View {
    let nodes: [FileNode]
    let depth: Int
    let selectedID: String?
    let onSelect: (FileNode) -> Void
    let onOpenFile: (FileNode) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                FileOutlineFolderRow(
                    node: node,
                    depth: depth,
                    selectedID: selectedID,
                    onSelect: onSelect,
                    onOpenFile: onOpenFile
                )
            } else {
                FileOutlineLeaf(
                    node: node,
                    depth: depth,
                    isSelected: selectedID == node.id,
                    onSelect: onSelect,
                    onOpenFile: onOpenFile
                )
            }
        }
    }
}

/// 文件夹行（展开态由行自身持有，折叠/展开时箭头 spring 旋转）。
private struct FileOutlineFolderRow: View {
    let node: FileNode
    let depth: Int
    let selectedID: String?
    let onSelect: (FileNode) -> Void
    let onOpenFile: (FileNode) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileTreeRow(
                name: node.name,
                depth: depth,
                isSelected: false,
                icon: .folder,
                iconColor: .ink700,
                isFolder: true,
                isExpanded: expanded
            ) {
                withAnimation(DS.Motion.springFast) { expanded.toggle() }
            }

            if expanded, let children = node.children {
                FileOutlineNodes(
                    nodes: children,
                    depth: depth + 1,
                    selectedID: selectedID,
                    onSelect: onSelect,
                    onOpenFile: onOpenFile
                )
            }
        }
    }
}

/// 文件叶子行（点击选中；md / html 可预览的再弹预览 sheet）。
private struct FileOutlineLeaf: View {
    let node: FileNode
    let depth: Int
    let isSelected: Bool
    let onSelect: (FileNode) -> Void
    let onOpenFile: (FileNode) -> Void

    private var ext: String { node.url.pathExtension.lowercased() }

    private var previewable: Bool {
        switch ext {
        case "html", "md", "mmd": true
        default: false
        }
    }

    var body: some View {
        FileTreeRow(
            name: node.name,
            depth: depth,
            isSelected: isSelected,
            icon: iconFor(ext),
            iconColor: iconColorFor(ext),
            isFolder: false,
            isExpanded: false,
            metaText: node.sizeBytes.map { ArtifactEntry.byteCount($0) }
        ) {
            onSelect(node)
            if previewable { onOpenFile(node) }
        }
    }
}

/// Trae 式资源管理器行：箭头/圆点槽 + 类型彩色图标 + 文件名，
/// 整行 hover / 选中圆角高亮，逐层缩进 16pt；hover 浮现右侧体量元信息。
private struct FileTreeRow: View {
    let name: String
    let depth: Int
    let isSelected: Bool
    let icon: DSIcon.Name
    let iconColor: Color
    let isFolder: Bool
    let isExpanded: Bool
    var metaText: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if isFolder {
                        DSIcon(.down, size: 12)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .foregroundStyle(Color.ink500)
                    } else {
                        DSIcon(.dot, size: 4.5)
                            .foregroundStyle(Color.ink300)
                    }
                }
                .frame(width: 14, height: 14)

                DSIcon(icon, size: 15)
                    .foregroundStyle(iconColor)

                Text(name)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(isSelected ? Color.ink900 : Color.ink800)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // hover 浮现体量（文件行）；文件夹行由树组件在 hover 时显示条目数
                if let metaText, !isFolder {
                    Text(metaText)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .lineLimit(1)
                        .opacity(hovered ? 1 : 0)
                }
            }
            .padding(.leading, CGFloat(depth) * 16 + 6)
            .padding(.trailing, DS.Spacing.s8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(
                        isSelected ? Color.overlayL2 : (hovered ? Color.overlayL1 : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(DS.Motion.springFast) { self.hovered = hovered }
        }
        .animation(DS.Motion.springFast, value: isSelected)
        .accessibilityLabel(Text(name))
    }
}

private func iconFor(_ ext: String) -> DSIcon.Name {
    switch ext {
    case "md": .markdown
    case "txt", "text": .doc
    case "html", "json", "jsonl", "swift", "py", "js": .code
    default: .document
    }
}

/// 类型彩色图标（对齐参考图文件树：md 蓝 / html 绿 / json 琥珀 / 其余中性）。
private func iconColorFor(_ ext: String) -> Color {
    switch ext {
    case "md": .statusPrimary
    case "html": .statusSuccess
    case "json", "jsonl": .statusAlert
    default: .ink500
    }
}
