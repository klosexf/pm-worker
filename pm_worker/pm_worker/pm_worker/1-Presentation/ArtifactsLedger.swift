//
//  ArtifactsLedger.swift
//  pm_worker
//
//  产物面板改版（方案 A · 分区台账）：
//  - 产物区：扫 01~07 编号目录内的实质产物（.md/.html/.mmd），按扩展名 + 目录
//    映射四类（文档/原型/图表/报告），行式台账 + 类型筛选 chips（左键点击
//    选中并打开预览 sheet，右键上下文菜单：预览 / 添加到对话——引用插入
//    输入坞草稿）；
//  - 工作空间文件区：版本目录全量内容的档案树（含编号产物目录与产物文件，
//    与 Finder 口径一致），面包屑标注磁盘目录；
//  - 产物台账是白名单摘要视图，工作空间文件是全量磁盘投影，两者并存。
//  扫描为纯函数（nonisolated），UI 与测试共用同一口径。
//

import SwiftUI

// MARK: - 产物类型

/// 四类产物徽标（方案 A：doc 蓝 / proto 琥珀 / chart 绿 / report 橙）。
nonisolated enum ArtifactKind: String, CaseIterable, Identifiable {
    case doc
    case proto
    case chart
    case report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doc: "文档"
        case .proto: "原型"
        case .chart: "图表"
        case .report: "报告"
        }
    }
}

/// 徽标视觉映射（引用 DSIcon/Color 的 MainActor 静态成员，随 UI 隔离）。
extension ArtifactKind {
    var icon: DSIcon.Name {
        switch self {
        case .doc: .markdown
        case .proto: .browser
        case .chart: .connector
        case .report: .barList
        }
    }

    var tint: Color {
        switch self {
        case .doc: .statusPrimary
        case .proto: .statusAlert
        case .chart: .statusSuccess
        case .report: .statusWarning
        }
    }

    var surface: Color {
        switch self {
        case .doc: .statusPrimarySurface1
        case .proto: .statusAlertSurface1
        case .chart: .statusSuccessSurface1
        case .report: .statusWarningSurface1
        }
    }
}

// MARK: - 产物条目

/// 台账一行（nonisolated：扫描纯函数产出，测试直读）。
nonisolated struct ArtifactEntry: Identifiable, Equatable {
    let name: String
    let url: URL
    let kind: ArtifactKind
    let sizeBytes: Int
    /// 相对版本目录的路径（如 04-prd/PRD-v2.md），副行展示用。
    let relativePath: String
    let modifiedAt: Date?

    var id: String { url.path }

    /// 副行：相对路径 · 人类可读体量。
    var subtitle: String {
        "\(relativePath) · \(Self.byteCount(sizeBytes))"
    }

    static func byteCount(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_024: "\(bytes) B"
        case ..<1_048_576: String(format: "%.1f KB", Double(bytes) / 1_024)
        default: String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
    }
}

// MARK: - 扫描（纯函数）

nonisolated enum ArtifactCatalog {

    /// 产物白名单扩展名（方案口径：实质内容 .md/.html/.mmd）。
    private static let artifactExtensions: Set<String> = ["md", "html", "mmd"]
    /// 工作空间行内文件视为「机器文件」的扩展名（徽标琥珀 code 之外的展示不影响结构）。
    private static let reportDirPrefix = "07-"
    /// 编号目录 = 两位数字前缀（01-… ~ 07-…），归产物；其余归工作空间。
    private static let numberedDirPattern = "^\\d{2}-"

    /// 产物台账：编号目录内的白名单产物文件，mtime 倒序。
    static func scanArtifacts(in versionURL: URL) -> [ArtifactEntry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: versionURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var entries: [ArtifactEntry] = []
        for dir in dirs where isNumberedDir(dir.lastPathComponent) {
            collectArtifacts(
                in: dir,
                root: versionURL,
                into: &entries,
                depth: 0
            )
        }
        return entries.sorted { lhs, rhs in
            let l = lhs.modifiedAt ?? .distantPast
            let r = rhs.modifiedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.name < rhs.name
        }
    }

    /// 各类型计数（chips 徽标用，保持全量口径，不受当前筛选影响）。
    static func counts(for entries: [ArtifactEntry]) -> [ArtifactKind: Int] {
        Dictionary(grouping: entries, by: \.kind)
            .mapValues(\.count)
    }

    /// 工作空间树：版本目录全量内容的只读投影（含编号产物目录及其中的
    /// 产物文件，与 Finder 口径一致）。返回 nil 表示目录尚不存在。
    static func workspaceTree(in versionURL: URL) -> FileNode? {
        guard FileManager.default.fileExists(atPath: versionURL.path) else { return nil }
        return buildTree(at: versionURL, depth: 0)
    }

    /// 树计数（节头 N FILES · M FOLDERS）。
    static func treeCounts(_ node: FileNode?) -> (files: Int, folders: Int) {
        guard let node else { return (0, 0) }
        var files = 0, folders = 0
        walk(node) { n in
            if n.isDirectory { folders += 1 } else { files += 1 }
        }
        return (files, max(folders - 1, 0))   // 减去根自身
    }

    // MARK: Private

    private static func walk(_ node: FileNode, _ visit: (FileNode) -> Void) {
        visit(node)
        for child in node.children ?? [] { walk(child, visit) }
    }

    private static func isNumberedDir(_ name: String) -> Bool {
        name.range(of: numberedDirPattern, options: .regularExpression) != nil
    }

    private static func collectArtifacts(
        in dir: URL, root: URL, into entries: inout [ArtifactEntry], depth: Int
    ) {
        let fm = FileManager.default
        let dirKeys: [URLResourceKey] = [.isDirectoryKey]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard depth < 3, let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: dirKeys
        ) else { return }

        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? item.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory == true
            if isDir {
                collectArtifacts(in: item, root: root, into: &entries, depth: depth + 1)
                continue
            }
            let ext = item.pathExtension.lowercased()
            guard artifactExtensions.contains(ext) else { continue }
            let parentName = dir.lastPathComponent
            let kind: ArtifactKind
            if ext == "html" {
                kind = .proto
            } else if ext == "mmd" {
                kind = .chart
            } else if parentName.hasPrefix(reportDirPrefix) {
                kind = .report
            } else {
                kind = .doc
            }
            // 相对路径：双方 standardized，规避 /var ↔ /private/var 符号链接差异
            let rootPrefix = root.standardizedFileURL.path + "/"
            let itemPath = item.standardizedFileURL.path
            let relative = itemPath.hasPrefix(rootPrefix)
                ? String(itemPath.dropFirst(rootPrefix.count))
                : item.lastPathComponent
            entries.append(ArtifactEntry(
                name: item.lastPathComponent,
                url: item,
                kind: kind,
                sizeBytes: values?.fileSize ?? 0,
                relativePath: relative,
                modifiedAt: values?.contentModificationDate
            ))
        }
    }

    /// 与 ArtifactTreeView.buildTree 同口径的递归树（供工作空间区复用）。
    private static func buildTree(at url: URL, depth: Int) -> FileNode {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ))?
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(200)
            .map { child -> FileNode in
                let isDir =
                    (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return FileNode(
                    name: child.lastPathComponent,
                    url: child,
                    isDirectory: isDir,
                    children: (isDir && depth < 4)
                        ? buildTree(at: child, depth: depth + 1).children : []
                )
            }
        return FileNode(
            name: url.lastPathComponent,
            url: url,
            isDirectory: true,
            children: Array(children ?? [])
        )
    }
}

// MARK: - 产物台账视图

struct ArtifactsLedgerView: View {

    let entries: [ArtifactEntry]
    /// 选中行 id（url.path；左键点选与右键联动，选中态由父级持有跨滚动保持）。
    var selectedID: String?
    /// 左键点选回调。
    var onSelect: (ArtifactEntry) -> Void
    /// 点击整行预览（md/html/mmd 走 sheet）；无法预览的走系统打开。
    let onOpen: (ArtifactEntry) -> Void
    /// 右键菜单「添加到对话」回调。
    var onAddToConversation: (ArtifactEntry) -> Void
    /// 右键菜单「设为主原型」可见性判定（阶段 4 台账选主：非主槽位原型槽位文件
    /// 且当前版本非 busy）；nil = 该项整体隐藏（宿主未接线时不显示）。
    var canPromoteToMaster: ((ArtifactEntry) -> Bool)? = nil
    /// 右键菜单「设为主原型」回调。
    var onSelectAsMaster: ((ArtifactEntry) -> Void)? = nil

    @State private var filter: ArtifactKind?

    private var counts: [ArtifactKind: Int] { ArtifactCatalog.counts(for: entries) }

    private var filtered: [ArtifactEntry] {
        guard let filter else { return entries }
        return entries.filter { $0.kind == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            zoneHead
            if !entries.isEmpty {
                filterChips
                ledger
            }
        }
    }

    // 节头：只留衬线标题（计数与口径提示按评审结论移除）
    private var zoneHead: some View {
        Text("产物")
            .font(DS.Font.display2XS)
            .foregroundStyle(Color.ink900)
            .padding(.horizontal, DS.Spacing.s16)
            .padding(.top, DS.Spacing.s12)
            .padding(.bottom, DS.Spacing.s8)
    }

    private var filterChips: some View {
        HStack(spacing: DS.Spacing.s6) {
            chip(title: "全部 \(entries.count)", kind: nil)
            ForEach(ArtifactKind.allCases) { kind in
                let n = counts[kind] ?? 0
                if n > 0 {
                    chip(title: "\(kind.title) \(n)", kind: kind)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.bottom, DS.Spacing.s8)
    }

    private func chip(title: String, kind: ArtifactKind?) -> some View {
        let isOn = filter == kind
        return Button {
            withAnimation(DS.Motion.springFast) { filter = kind }
        } label: {
            Text(title)
                .font(DS.Font.bodyXSStrong)
                .foregroundStyle(isOn ? Color.brandAccent : Color.ink500)
                .padding(.horizontal, DS.Spacing.s10)
                .padding(.vertical, 3)
                .background(Capsule().fill(isOn ? Color.brand100 : Color.clear))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.borderL1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // 台账行列表
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSDivider()
            if filtered.isEmpty {
                HStack {
                    Text("该类型下暂无产物 — 产物由对话自动沉淀，去聊天里生成一份吧。")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.s16)
                .padding(.vertical, DS.Spacing.s12)
                DSDivider()
            } else {
                ForEach(filtered) { entry in
                    LedgerRow(
                        entry: entry,
                        isSelected: entry.id == selectedID,
                        onSelect: { onSelect(entry) },
                        onPreview: { onOpen(entry) },
                        onAddToConversation: { onAddToConversation(entry) },
                        canPromoteToMaster: canPromoteToMaster?(entry) ?? false,
                        onPromoteToMaster: { onSelectAsMaster?(entry) }
                    )
                    DSDivider()
                }
            }
        }
    }
}

/// 台账行：类型色块徽标 + 标题/副行。左键点击选中（选中态跨滚动保持）并打开
/// 预览 sheet（与工作空间文件树「点开即预览」惯例一致），右键在点击点弹出
/// 上下文菜单（预览 / 添加到对话）。行交互下沉 AppKit
/// （LedgerRowInteraction）：SwiftUI 手势在 macOS 无法区分左右键，视觉仍由
/// SwiftUI 绘制——DividerHandle 同款分工。
private struct LedgerRow: View {

    let entry: ArtifactEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onAddToConversation: () -> Void
    /// 「设为主原型」菜单项可见性（父级按路径 + 版本 busy 判定）。
    let canPromoteToMaster: Bool
    let onPromoteToMaster: () -> Void

    @State private var hovered = false
    @State private var menuPresented = false
    /// 右键点击点（行内 SwiftUI 坐标，y 向下）：菜单 popover 的 1pt 锚点。
    @State private var menuAnchor: CGPoint = .zero

    var body: some View {
        HStack(spacing: DS.Spacing.s12) {
            // 类型徽标：Surface1 色块 + 彩色图标
            DSIcon(entry.kind.icon, size: 15)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(entry.kind.surface)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.vertical, DS.Spacing.s10)
        .background(
            // 选中 brand100 实色（比 hover 水洗强一档）；hover 保持品牌色弱水洗
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(
                    isSelected
                        ? Color.brand100
                        : (hovered ? Color.brand100.opacity(0.75) : Color.clear)
                )
        )
        // 选中左缘 2pt 品牌条（RiskLedgerTab 状态条同形制）
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.brandAccent)
                    .frame(width: 2, height: 16)
                    .padding(.leading, 6)
            }
        }
        .overlay {
            LedgerRowInteraction(
                onSelect: {
                    onSelect()
                    onPreview()
                },
                onContext: { point in
                    // 右键联动选中（macOS 列表惯例），先落锚点再下一拍呈现——
                    // 确保 popover 锚定到本次点击点而非上一帧位置
                    onSelect()
                    menuAnchor = point
                    DispatchQueue.main.async { menuPresented = true }
                },
                onHover: { inside in
                    withAnimation(DS.Motion.springFast) { hovered = inside }
                }
            )
        }
        // 菜单锚点：行内 1pt 透明视图钉在右键点击点上（菜单跟随鼠标位置）。
        // popover 挂在 1×1 视图上、position 只负责移动——顺序反了锚点会退化
        // 成整行 frame；popover 独立窗口呈现，点外自动收起、空间不足自动翻转。
        .background {
            Color.clear
                .frame(width: 1, height: 1)
                .popover(isPresented: $menuPresented, arrowEdge: .trailing) {
                    contextMenu
                }
                .position(menuAnchor)
        }
        .animation(DS.Motion.springFast, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("左键打开预览，右键打开添加到对话菜单"))
    }

    /// 右键上下文菜单（DSMenu 毛玻璃卡 + DSMenuItem hover 升阶；presentation
    /// Background 去系统底露出玻璃卡——NewTaskView 下拉同款机制）。
    private var contextMenu: some View {
        DSMenu(minWidth: 172) {
            DSMenuItem(title: "预览", icon: .glasses, titleFont: DS.Font.bodySM) {
                menuPresented = false
                onPreview()
            }
            DSMenuItem(title: "添加到对话", icon: .chat, titleFont: DS.Font.bodySM) {
                menuPresented = false
                onAddToConversation()
            }
            if canPromoteToMaster {
                // 阶段 4 台账选主：非主槽位的原型槽位文件（修订/方案/未知 slug）
                // 可提升为主槽位；可见性含 busy 判定（防与流完成落盘竞态）。
                DSMenuItem(title: "设为主原型", icon: .star, titleFont: DS.Font.bodySM) {
                    menuPresented = false
                    onPromoteToMaster()
                }
            }
        }
        .presentationBackground(.clear)
    }
}

/// 台账行事件捕获层（AppKit）：透明 NSView 盖满整行，mouseDown（左键）回传
/// 选中、rightMouseDown 在点击点回传锚点（AppKit y 向上已翻转为 SwiftUI y
/// 向下，overlay 与行同框 1:1 映射）、hover 由 tracking area 回传。视图自身
/// 零绘制，scrollWheel 不拦截（沿响应链上抛给 ScrollView 正常滚动）。
private struct LedgerRowInteraction: NSViewRepresentable {
    var onSelect: () -> Void
    var onContext: (CGPoint) -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onSelect = onSelect
        view.onContext = onContext
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onContext = onContext
        nsView.onHover = onHover
    }

    final class InteractionView: NSView {
        var onSelect: (() -> Void)?
        var onContext: ((CGPoint) -> Void)?
        var onHover: ((Bool) -> Void)?

        private var trackingArea: NSTrackingArea?

        /// 全尺寸内容区下透明视图默认让按下事件给窗口拖动，须显式拒绝。
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

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) { onSelect?() }

        override func rightMouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onContext?(CGPoint(x: p.x, y: bounds.height - p.y))
        }
    }
}
