//
//  InspectorPanel.swift
//  pm_worker
//
//  右栏四 Tab 面板（design.md §6.4 v0.9.2）：产物 / 决策日志 / 漏项雷达 / 知识点。
//  产物 Tab 预览项目文件树，点击 .html 用 HTMLPreviewView 预搭组件打开（E21）；
//  决策日志 / 漏项雷达读 decisions.jsonl / risks.jsonl 真实数据
//  （DecisionLogTab / RiskRadarTab）；知识点为检索 + 命中卡 + 主动推荐完整版
//  （Task 4.6，KnowledgeTab）。底部常驻 ⌘D 入口打开开发者检查器窗口。
//

import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var tab: InspectorTab = .artifacts
    @State private var previewTarget: FileNode?

    enum InspectorTab: String, CaseIterable, Identifiable {
        case artifacts = "产物"
        case decisions = "决策日志"
        case radar = "漏项雷达"
        case knowledge = "知识点"

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
                        DSTabItem(InspectorTab.knowledge, InspectorTab.knowledge.rawValue),
                    ],
                    selection: $tab
                )

                TopBarIconButton(name: .panelRight, flipX: false) {
                    withAnimation(DS.Motion.spring) { model.inspectorCollapsed = true }
                }
                .help("收起右侧面板")
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.top, DS.Spacing.s10)
            .padding(.bottom, DS.Spacing.s8)

            DSDivider()

            // 每个 Tab 内容统一撑满剩余高度（空态 DSEmptyState 居中不塌缩，
            // 底部工具条恒定贴底——消除切换 Tab 时面板高度跳动）。
            Group {
                switch tab {
                case .artifacts:
                    artifactsTab
                case .decisions:
                    DecisionLogTab()
                case .radar:
                    RiskRadarTab()
                case .knowledge:
                    KnowledgeTab()
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
        .sheet(item: $previewTarget) { node in
            if node.url.pathExtension.lowercased() == "html" {
                HTMLPreviewSheet(title: node.name, fileURL: node.url)
            } else {
                MermaidPreviewSheet(title: node.name, fileURL: node.url)
            }
        }
    }

    // MARK: - 产物 Tab（项目文件树只读预览）

    private var artifactsTab: some View {
        Group {
            if let ctx = model.selection.inspectorProject {
                // 「默认」兜底容器同样可浏览：产物落了盘就该能看（文件树只读
                // 该项目自己的目录，不回退显示其他项目，无 scope 串味）。
                ArtifactTreeView(
                    project: ctx.project,
                    version: ctx.version,
                    onOpenFile: { previewTarget = $0 }
                )
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

/// 文件树节点（只读投影）。
struct FileNode: Identifiable, Hashable {
    var name: String
    var url: URL
    var isDirectory: Bool
    var children: [FileNode]?

    var id: String { url.path }
}

// MARK: - 文件树

struct ArtifactTreeView: View {
    let project: String
    let version: String
    let onOpenFile: (FileNode) -> Void

    @State private var root: FileNode?
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            // 项目路径面包屑（原型 .ds-breadcrumb：段可点 → Finder · 末段 current 高亮）
            DSBreadcrumb(segments: Self.pathSegments(project: project, version: version))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.top, DS.Spacing.s3)
                .padding(.bottom, DS.Spacing.s6)

            Group {
                if let root {
                    ScrollView {
                        FileOutlineNodes(
                            nodes: root.children ?? [],
                            depth: 0,
                            selectedID: selectedID,
                            onSelect: { selectedID = $0.id },
                            onOpenFile: onOpenFile
                        )
                        .padding(.horizontal, DS.Spacing.s8)
                        .padding(.vertical, DS.Spacing.s8)
                    }
                } else {
                    // 目录树加载占位（原型 .ds-skeleton）
                    VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                        DSSkeletonLine(width: 140)
                        DSSkeletonLine(width: 200)
                        DSSkeletonLine(width: 180)
                        DSSkeletonLine(width: 160)
                    }
                    .padding(DS.Spacing.s16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear {
            root = Self.buildTree(
                at: PMAgentStore.versionURL(project: project, version: version)
            )
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

    /// 深度与数量上限，防超大目录卡 UI。
    private static func buildTree(at url: URL, depth: Int = 0) -> FileNode {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ))?
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(200)
            .map { child in
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
        case "html", "md": true
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
            isExpanded: false
        ) {
            onSelect(node)
            if previewable { onOpenFile(node) }
        }
    }
}

/// Trae 式资源管理器行：箭头/圆点槽 + 类型彩色图标 + 文件名，
/// 整行 hover / 选中圆角高亮，逐层缩进 16pt。
private struct FileTreeRow: View {
    let name: String
    let depth: Int
    let isSelected: Bool
    let icon: DSIcon.Name
    let iconColor: Color
    let isFolder: Bool
    let isExpanded: Bool
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
