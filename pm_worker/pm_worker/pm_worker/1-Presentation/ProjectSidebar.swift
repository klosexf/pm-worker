//
//  ProjectSidebar.swift
//  pm_worker
//
//  左栏（Task 1.1，design.md §5.1.1 · 对齐 Trae 参考图顶栏结构）：
//  首行贴顶 = 自绘红绿灯 + 搜索图标；其下模式胶囊（PM 激活，数据/复盘
//  V2 占位）→ 功能导航（新建任务/技能库/知识库/决策日志）→ 任务列表
//  （项目→版本→会话三级树，支持搜索过滤）。系统标题栏与红绿灯已隐藏
//  （WindowChromeConfigurator），窗口控制由本栏首行自绘按钮接管。
//

import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var model: AppModel

    /// 任务列表搜索词（非空 → 过滤会话命中项）。
    @State private var search = ""
    /// 搜索行是否展开（搜索图标点击展开；清空并失焦后收起）。
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        expandedSidebar
    }

    // MARK: - 展开态完整侧栏

    private var expandedSidebar: some View {
        VStack(spacing: 0) {
            // 首行贴顶：自绘红绿灯 + 搜索（对齐参考图）
            WindowControlButtons {
                TopBarIconButton(name: .search) {
                    // 搜索行随状态出现，下一轮布局后再抢焦点
                    withAnimation(DS.Motion.springFast) { searchVisible = true }
                    DispatchQueue.main.async { searchFocused = true }
                }
                .help("搜索任务")
            }

            // 模式胶囊（参考图：Work / Code / Design 形制；PM 激活白底浮起）
            modeCapsule
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.top, DS.Spacing.s8)
                .padding(.bottom, DS.Spacing.s6)

            // 搜索行（红绿灯搜索图标点击展开）
            if searchVisible {
                searchField
                    .padding(.horizontal, DS.Spacing.s8)
                    .padding(.bottom, DS.Spacing.s4)
            }

            // 功能导航（原型 NAV）
            navSection

            DSDivider()
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s8)

            // 任务列表（原型 v4.6：新建入口统一走导航「新建任务」）
            Text("任务列表")
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink500)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.bottom, DS.Spacing.s4)

            List {
                ForEach(filteredProjects) { project in
                    projectSection(project)
                }
            }
            .listStyle(.sidebar)
            // 隐藏 List 默认底色，透出外层 vibrancy
            .scrollContentBackground(.hidden)

            // 底部账户区（原型 Sidebar 底部：ds-avatar 形制 + 本地优先 + MIT 开源）
            accountSection
        }
    }

    // MARK: - 搜索

    private var searchField: some View {
        HStack(spacing: DS.Spacing.s6) {
            DSIcon(.search, size: 13)
                .foregroundStyle(Color.ink300)
            TextField("搜索任务…", text: $search)
                .textFieldStyle(.plain)
                .font(DS.Font.bodyMD)
                .focused($searchFocused)
                .onExitCommand {
                    search = ""
                    searchFocused = false
                    withAnimation(DS.Motion.springFast) { searchVisible = false }
                }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    DSIcon(.close, size: 11)
                        .foregroundStyle(Color.ink300)
                }
                .buttonStyle(.plain)
            }
        }
        .dsInput(focused: searchFocused, minHeight: 28)
    }

    /// 搜索过滤：命中项目名保留全部；否则按会话标题过滤，空版本隐藏。
    private var filteredProjects: [ProjectNode] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.projects }
        return model.projects.compactMap { project in
            if project.name.lowercased().contains(q) { return project }
            let versions = project.versions.compactMap { version -> VersionNode? in
                let sessions = version.sessions.filter {
                    $0.title.lowercased().contains(q)
                }
                return sessions.isEmpty ? nil : VersionNode(
                    name: version.name, isReleased: version.isReleased, sessions: sessions
                )
            }
            return versions.isEmpty ? nil : ProjectNode(name: project.name, versions: versions)
        }
    }

    // MARK: - 模式胶囊（PM / 数据 V2 / 复盘 V2）

    private var modeCapsule: some View {
        HStack(spacing: DS.Spacing.s2) {
            // PM 激活段：白底浮起（Seg 同规格：28 高 · medium）
            Text("PM")
                .font(DS.Font.bodySM)
                .fontWeight(.medium)
                .foregroundStyle(Color.ink900)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(Color.surfaceBase)
                        .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1)
                )

            // 数据 / 复盘：V2 占位（未实装，不响应点击）
            ForEach(["数据", "复盘"], id: \.self) { title in
                HStack(spacing: DS.Spacing.s3) {
                    Text(title)
                        .font(DS.Font.bodySM)
                        .foregroundStyle(Color.ink300)
                    Text("V2")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.ink300)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
        }
        .padding(DS.Spacing.s2)
        .background(Color.overlayL1, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    // MARK: - 底部账户区（本地优先声明 + 设置入口；原型「本地 Agent」）

    /// 设置入口按钮（左下角齿轮，参考图 Trae 设置入口形制：hover 浮起）。
    @State private var settingsHovered = false

    private var accountSection: some View {
        HStack(spacing: DS.Spacing.s8) {
            DSAvatar(label: "本地 Agent", size: .sm, icon: DSIcon.Name.agent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Spacing.s6) {
                    Text("本地优先")
                        .font(DS.Font.bodySMStrong)
                        .foregroundStyle(Color.ink900)
                    DSTag(title: "MIT 开源", variant: .neutral)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.settingsPage = .model
                model.settingsPresented = true
            } label: {
                DSIcon(.gear, size: 14)
                    .foregroundStyle(
                        settingsHovered ? Color.ink700 : Color.ink500
                    )
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(settingsHovered ? Color.overlayL2 : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            .buttonStyle(.plain)
            .onHover { settingsHovered = $0 }
            .help("设置（⌘,）")
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .overlay(alignment: .top) { DSDivider() }
    }

    // MARK: - 功能导航（原型 NAV 六入口）

    /// 导航行右缘徽章：快捷键走 .ds-kbd，文字标签走 .ds-tag。
    private enum NavBadge {
        case kbd(String)
        case tag(String)
    }

    private var navSection: some View {
        VStack(spacing: 0) {
            navRow(
                icon: .newTask,
                label: "新建任务",
                badge: .kbd("⌘⇧N"),
                active: model.selection == .newTask
            ) {
                model.selection = .newTask
            }

            navRow(
                icon: .puzzle,
                label: "技能库",
                badge: nil,
                active: model.selection == .skillLibrary
            ) {
                model.selection = .skillLibrary
            }

            navRow(
                icon: .books,
                label: "知识库",
                badge: nil,
                active: model.selection == .knowledgeHub
            ) {
                model.selection = .knowledgeHub
            }

            navRow(
                icon: .barList,
                label: "决策日志",
                badge: nil,
                active: model.selection == .decisionsPage
            ) {
                model.selection = .decisionsPage
            }
        }
        .padding(.horizontal, DS.Spacing.s8)
    }

    private func navRow(
        icon: DSIcon.Name,
        label: String,
        badge: NavBadge?,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s10) {
                DSIcon(icon, size: 14)
                    .foregroundStyle(active ? Color.ink700 : Color.ink500)
                Text(label)
                    .font(DS.Font.bodyMD)
                    .foregroundStyle(active ? Color.ink900 : Color.ink700)
                Spacer(minLength: 0)
                if let badge {
                    switch badge {
                    case .kbd(let key):
                        DSKbd(key: key)
                    case .tag(let text):
                        DSTag(title: text, variant: .neutral)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(active ? Color.overlayL2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 第一层：项目

    @ViewBuilder
    private func projectSection(_ project: ProjectNode) -> some View {
        DisclosureGroup(isExpanded: bindingFor(project.name)) {
            ForEach(project.versions) { version in
                versionSection(project: project, version: version)
            }
        } label: {
            ProjectHeaderRow(
                name: project.name,
                onTap: {
                    model.activeProject = project.name
                    model.reloadTree()
                    toggleProject(project.name)
                },
                onHome: {
                    model.activeProject = project.name
                    model.selection = .projectHome(project.name)
                    model.reloadTree()
                }
            )
        }
    }

    // MARK: - 第二层：版本 + 第三层：会话

    @ViewBuilder
    private func versionSection(project: ProjectNode, version: VersionNode) -> some View {
        DisclosureGroup(
            isExpanded: versionBinding(project: project.name, version: version.name)
        ) {
            ForEach(version.sessions) { session in
                sessionRow(project: project, version: version, session: session)
            }
            if version.sessions.isEmpty {
                Text("暂无会话")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                    .padding(.leading, 28)
            }
        } label: {
            VersionHeaderRow(
                icon: version.isReleased ? .lock : .layers,
                title: version.displayName,
                isReleased: version.isReleased
            ) {
                toggleVersion(project.name, version.name)
            }
        }
    }

    private func sessionRow(
        project: ProjectNode, version: VersionNode, session: SessionSummary
    ) -> some View {
        let isSelected = model.selection
            == .session(project: project.name, version: version.name, sessionId: session.id)

        return SessionRowButton(
            title: session.title,
            isSelected: isSelected
        ) {
            model.activeProject = project.name
            model.selection = .session(
                project: project.name, version: version.name, sessionId: session.id
            )
            model.reloadTree()
        }
        .padding(.leading, DS.Spacing.s8)
    }

    // MARK: - 展开状态

    @State private var expandedProjects: Set<String> = []
    /// 版本层展开状态（key = "项目/版本"，支撑整行点击切换展开）。
    @State private var expandedVersions: Set<String> = []

    private func bindingFor(_ project: String) -> Binding<Bool> {
        Binding(
            get: { expandedProjects.contains(project) },
            set: { newValue in
                if newValue { expandedProjects.insert(project) }
                else { expandedProjects.remove(project) }
                model.activeProject = project
            }
        )
    }

    private func versionBinding(project: String, version: String) -> Binding<Bool> {
        let key = "\(project)/\(version)"
        return Binding(
            get: { expandedVersions.contains(key) },
            set: { newValue in
                if newValue { expandedVersions.insert(key) }
                else { expandedVersions.remove(key) }
            }
        )
    }

    private func toggleProject(_ project: String) {
        if expandedProjects.contains(project) {
            expandedProjects.remove(project)
        } else {
            expandedProjects.insert(project)
        }
    }

    private func toggleVersion(_ project: String, _ version: String) {
        let key = "\(project)/\(version)"
        if expandedVersions.contains(key) {
            expandedVersions.remove(key)
        } else {
            expandedVersions.insert(key)
        }
    }
}

// MARK: - 任务树行（整行矩形可点 + hover/按下反馈）

/// 行按钮样式：hover 轻底（overlayL1）、按下深一档（overlayL2），
/// 选中态为中性灰高亮（overlayL2，对齐 Trae 参考图）、按下叠 8% 压暗反馈。
/// ButtonStyle 持不了 @State，hover 态由各行视图持有后以 Binding 传入。
private struct SidebarTaskRowStyle: ButtonStyle {
    var isSelected = false
    @Binding var hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(rowFill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(
                        Color.black.opacity(
                            configuration.isPressed && isSelected ? 0.08 : 0
                        )
                    )
            )
            .animation(DS.Motion.springFast, value: hovered)
    }

    private func rowFill(pressed: Bool) -> Color {
        if isSelected { return Color.overlayL2 }
        if pressed { return Color.overlayL2 }
        if hovered { return Color.overlayL1 }
        return .clear
    }
}

/// 项目行：图标 + 名称 + 空白区整块可点（切换展开并激活项目）；
/// 右上 home 钮嵌套在内、独立响应打开项目主页。
private struct ProjectHeaderRow: View {
    let name: String
    let onTap: () -> Void
    let onHome: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.folder, size: 13)
                    .foregroundStyle(Color.ink500)
                Text(name)
                    .font(DS.Font.heading2XS)
                    .foregroundStyle(Color.ink500)
                Spacer()
                Button(action: onHome) {
                    DSIcon(.home, size: 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink500)
                .help("打开项目主页")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarTaskRowStyle(hovered: $hovered))
        .onHover { hovered = $0 }
    }
}

/// 版本行：原先仅折叠箭头可点，现整行（含「封板 · 只读」文案）可点切换展开。
private struct VersionHeaderRow: View {
    let icon: DSIcon.Name
    let title: String
    let isReleased: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(icon, size: 13)
                    .foregroundStyle(Color.ink500)
                Text(title)
                    .font(DS.Font.heading2XS)
                    .foregroundStyle(Color.ink500)
                if isReleased {
                    Text("封板 · 只读")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarTaskRowStyle(hovered: $hovered))
        .onHover { hovered = $0 }
    }
}

/// 会话行：对齐 Trae 参考图——仅单行标题、无时间戳，行高舒展（≈32pt），
/// 选中态 = 中性灰圆角高亮 + 文字提亮（不加粗）。
private struct SessionRowButton: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(title)
                    .font(DS.Font.bodySM)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.ink900 : Color.ink500)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarTaskRowStyle(isSelected: isSelected, hovered: $hovered))
        .onHover { hovered = $0 }
    }
}
