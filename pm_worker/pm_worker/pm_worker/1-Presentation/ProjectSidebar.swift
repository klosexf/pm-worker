//
//  ProjectSidebar.swift
//  pm_worker
//
//  左栏（Task 1.1，design.md §5.1.1 · 对齐 Trae 参考图顶栏结构）：
//  首行贴顶 = 自绘红绿灯 + 搜索图标；其下模式胶囊（PM 激活，数据/复盘
//  V2 占位）→ 功能导航（新建任务/技能库/知识库/决策日志）→ 任务/空间
//  双模块（方案 B：列表区顶部分段胶囊切换，单区视口只显示当前模块；
//  任务 = 默认/unversioned 轻会话平铺，空间 = 项目-版本-会话三级档案树，
//  选中驱动自动落段）。系统标题栏与红绿灯已隐藏（WindowChromeConfigurator），
//  窗口控制由本栏首行自绘按钮接管。
//

import SwiftUI

/// 会话操作目标（行「更多」菜单 → 重命名/删除弹窗的数据源）。
private struct SessionActionTarget: Identifiable {
    let project: String
    let version: String
    let sessionId: String
    /// 发起操作时的会话标题（弹窗展示/输入框初值）。
    let title: String
    var id: String { sessionId }
}

/// 项目操作目标（项目行「更多」菜单 → 新建版本/重命名/删除弹窗的数据源）。
private struct ProjectActionTarget: Identifiable {
    let name: String
    var id: String { name }
}

/// 版本操作目标（版本行「更多」菜单 → 重命名/删除弹窗的数据源）。
private struct VersionActionTarget: Identifiable {
    let project: String
    let version: String
    /// 发起操作时的显示名（弹窗展示/输入框初值，unversioned → 默认无版本号）。
    let displayName: String
    var id: String { "\(project)/\(version)" }
}

/// 侧栏列表模块（方案 B：任务/空间分段切换，单区视口）。
private enum SidebarModule {
    case tasks
    case spaces
}

struct ProjectSidebar: View {
    @ObservedObject var model: AppModel
    /// 会话流状态观察源：会话行右缘的生成指示点需要订阅 isStreaming /
    /// streamingSessionID——SessionStore 是独立 ObservableObject 且被 AppModel
    /// 以 let 持有，仅观察 model 收不到其 @Published 变化。
    @ObservedObject private var store: SessionStore

    init(model: AppModel) {
        self.model = model
        self.store = model.sessionStore
    }

    /// 重命名弹窗目标（nil = 关闭）。
    @State private var renameTarget: SessionActionTarget?
    /// 删除确认弹窗目标（nil = 关闭）。
    @State private var deleteTarget: SessionActionTarget?
    /// 项目/版本操作弹窗目标（nil = 关闭）：新建版本 / 项目重命名 / 项目删除。
    @State private var newVersionTarget: ProjectActionTarget?
    @State private var renameProjectTarget: ProjectActionTarget?
    @State private var deleteProjectTarget: ProjectActionTarget?
    /// 版本重命名 / 版本删除弹窗目标。
    @State private var renameVersionTarget: VersionActionTarget?
    @State private var deleteVersionTarget: VersionActionTarget?
    /// 「转为项目」弹窗目标（任务区会话行菜单）。
    @State private var promoteTarget: SessionActionTarget?

    // MARK: - 任务/空间双模块（方案 B）

    /// 当前列表模块：任务（默认/unversioned 轻会话平铺）| 空间（项目档案树）。
    /// 默认落「任务」；选中驱动自动跟随——选中任务区会话落任务段、选中
    /// 项目/版本会话落空间段（用户浏览另一段不受影响，仅选中态切换时跟随）。
    @State private var activeModule: SidebarModule = .tasks

    var body: some View {
        expandedSidebar
            // 发送联动：在哪个会话窗口发送消息 → 自动展开对应项目/版本节点
            // （新建任务首条消息落盘的会话同样生效，随 reloadTree 后可见）
            .onChange(of: model.sidebarReveal) { _, reveal in
                guard let reveal else { return }
                withAnimation(DS.Motion.springFast) {
                    expandedProjects.insert(reveal.project)
                    expandedVersions.insert("\(reveal.project)/\(reveal.version)")
                }
                followModule(project: reveal.project, version: reveal.version)
            }
            // 选中驱动：会话/项目主页选中态变化 → 模块自动落段（方案 B 拍板）
            .onChange(of: model.selection) { _, selection in
                switch selection {
                case .session(let p, let v, _):
                    followModule(project: p, version: v)
                case .projectHome(let p):
                    followModule(project: p, version: "unversioned")
                case .newTask, .skillLibrary, .knowledgeHub, .decisionsPage:
                    break  // 功能导航页不改变列表模块
                }
            }
            .sheet(item: $renameTarget) { target in
                RenameSessionSheet(target: target) { newTitle in
                    saveRename(target: target, newTitle: newTitle)
                }
            }
            .sheet(item: $deleteTarget) { target in
                DeleteSessionSheet(target: target) {
                    delete(target: target)
                }
            }
            .sheet(item: $newVersionTarget) { target in
                NewVersionSheet(
                    projectName: target.name,
                    suggestedName: suggestedVersionName(
                        for: model.projects.first { $0.name == target.name }
                            ?? ProjectNode(name: target.name, versions: [])
                    )
                ) { name in
                    createVersion(target: target, name: name)
                }
            }
            .sheet(item: $renameProjectTarget) { target in
                RenameNodeSheet(
                    title: "重命名项目", fieldLabel: "项目名称", initialName: target.name
                ) { newName in
                    saveProjectRename(target: target, newName: newName)
                }
            }
            .sheet(item: $deleteProjectTarget) { target in
                DeleteProjectSheet(target: target) {
                    deleteProject(target: target)
                }
            }
            .sheet(item: $renameVersionTarget) { target in
                RenameNodeSheet(
                    title: "重命名版本", fieldLabel: "版本名称", initialName: target.displayName
                ) { newName in
                    saveVersionRename(target: target, newName: newName)
                }
            }
            .sheet(item: $deleteVersionTarget) { target in
                DeleteVersionSheet(target: target) {
                    deleteVersion(target: target)
                }
            }
            .sheet(item: $promoteTarget) { target in
                PromoteTaskSheet(target: target) { name in
                    promote(target: target, name: name)
                }
            }
    }

    /// 任务列表搜索词（非空 → 过滤会话命中项）。
    @State private var search = ""
    /// 搜索行是否展开（搜索图标点击展开；清空并失焦后收起）。
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool

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

            // 任务/空间模块分段胶囊（方案 B：复用顶部模式胶囊的分段语言，
            // 但更轻一档——无 V2 占位、计数徽章常驻，与模式胶囊拉开层级）
            moduleSegment
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.bottom, DS.Spacing.s6)

            // 单区视口：只显示当前模块（任务平铺 / 空间档案树）
            List {
                if activeModule == .tasks {
                    ForEach(taskSessions) { session in
                        taskRow(session: session)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    if taskSessions.isEmpty {
                        Text(search.isEmpty ? "暂无任务——新建任务未选项目时落在这里" : "没有匹配的任务")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink300)
                            .padding(.leading, DS.Spacing.s12)
                            .padding(.top, DS.Spacing.s2)
                    }
                } else {
                    ForEach(Array(spaceProjects.enumerated()), id: \.element.name) { index, project in
                        projectSection(project, index: index)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    if spaceProjects.isEmpty {
                        Text(
                            search.isEmpty
                                ? "暂无项目——新建任务时选择关联项目，即可沉淀为项目空间"
                                : "没有匹配的项目或会话"
                        )
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .padding(.leading, DS.Spacing.s12)
                        .padding(.top, DS.Spacing.s2)
                    }
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

    /// 任务区数据：默认/unversioned 的会话平铺（新建任务未选项目落这里）。
    /// 随搜索过滤标题（任务段无层级，纯标题匹配）。
    private var taskSessions: [SessionSummary] {
        guard
            let defaultProject = model.projects.first(where: {
                $0.name == PMAgentStore.defaultProjectName
            }),
            let unversioned = defaultProject.versions.first(where: { $0.name == "unversioned" })
        else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return unversioned.sessions }
        return unversioned.sessions.filter { $0.title.lowercased().contains(q) }
    }

    /// 空间区数据：档案树（排除默认项目的 unversioned——那是任务区；
    /// 默认项目若存在语义化版本仍保留展示，只滤掉 unversioned 节点）。
    private var spaceProjects: [ProjectNode] {
        let defaultName = PMAgentStore.defaultProjectName
        return filteredProjects.compactMap { project in
            guard project.name == defaultName else { return project }
            let versions = project.versions.filter { $0.name != "unversioned" }
            return versions.isEmpty ? nil : ProjectNode(name: project.name, versions: versions)
        }
    }

    /// 选中/发送联动 → 模块自动落段：任务区上下文落「任务」，其余落「空间」。
    private func followModule(project: String, version: String) {
        let isTaskArea = project == PMAgentStore.defaultProjectName && version == "unversioned"
        let target: SidebarModule = isTaskArea ? .tasks : .spaces
        if activeModule != target {
            withAnimation(DS.Motion.springFast) { activeModule = target }
        }
    }

    // MARK: - 模块分段胶囊（方案 B）

    private var moduleSegment: some View {
        HStack(spacing: DS.Spacing.s2) {
            segmentButton(title: "任务", count: taskSessions.count, module: .tasks) {
                withAnimation(DS.Motion.springFast) { activeModule = .tasks }
            }
            segmentButton(title: "空间", count: spaceProjects.count, module: .spaces) {
                withAnimation(DS.Motion.springFast) { activeModule = .spaces }
            }
        }
        .padding(DS.Spacing.s2)
        .background(Color.overlayL1, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    /// 分段按钮：激活段白底浮起（与顶部模式胶囊同语言但轻一档——无 V2
    /// 占位、26 高、计数徽章常驻；激活计数走 brand100/brandAccent）。
    private func segmentButton(
        title: String, count: Int, module: SidebarModule, action: @escaping () -> Void
    ) -> some View {
        let isOn = activeModule == module
        return Button(action: action) {
            HStack(spacing: DS.Spacing.s4) {
                Text(title)
                    .font(DS.Font.bodySM)
                    .fontWeight(isOn ? .medium : .regular)
                    .foregroundStyle(isOn ? Color.ink900 : Color.ink300)
                Text("\(count)")
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(isOn ? Color.brandAccent : Color.ink300)
                    .padding(.horizontal, DS.Spacing.s4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isOn ? Color.brand100 : Color.overlayL2))
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(isOn ? Color.surfaceBase : Color.clear)
                    .shadow(color: .black.opacity(isOn ? 0.16 : 0), radius: 2.5, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)模块")
        .accessibilityHint("切换到\(title)列表")
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

    // MARK: - 第一层：项目（档案块 = 分隔线 + 衬线标题行 + 子树）

    @ViewBuilder
    private func projectSection(_ project: ProjectNode, index: Int) -> some View {
        VStack(spacing: 0) {
            if index > 0 {
                DSDivider()
                    .padding(.horizontal, DS.Spacing.s12)
                    .padding(.vertical, DS.Spacing.s6)
            }
            ArchiveProjectRow(
                name: project.name,
                isExpanded: expandedProjects.contains(project.name),
                onTap: {
                    model.activeProject = project.name
                    model.reloadTree()
                    toggleProject(project.name)
                },
                onNewVersion: {
                    newVersionTarget = ProjectActionTarget(name: project.name)
                },
                onRename: {
                    renameProjectTarget = ProjectActionTarget(name: project.name)
                },
                onDelete: {
                    deleteProjectTarget = ProjectActionTarget(name: project.name)
                }
            )
            if expandedProjects.contains(project.name) {
                ForEach(project.versions) { version in
                    versionSection(project: project, version: version)
                }
            }
        }
    }

    // MARK: - 第二层：版本 + 第三层：会话

    @ViewBuilder
    private func versionSection(project: ProjectNode, version: VersionNode) -> some View {
        let key = "\(project.name)/\(version.name)"
        VStack(spacing: 0) {
            ArchiveVersionRow(
                name: version.displayName,
                isReleased: version.isReleased,
                isUnversioned: version.name == "unversioned",
                isExpanded: expandedVersions.contains(key),
                onTap: { toggleVersion(project.name, version.name) },
                onNewConversation: { newConversation(project: project, version: version) },
                onRename: {
                    renameVersionTarget = VersionActionTarget(
                        project: project.name, version: version.name,
                        displayName: version.displayName
                    )
                },
                onDelete: {
                    deleteVersionTarget = VersionActionTarget(
                        project: project.name, version: version.name,
                        displayName: version.displayName
                    )
                }
            )
            if expandedVersions.contains(key) {
                ForEach(version.sessions) { session in
                    sessionRow(project: project, version: version, session: session)
                }
                if version.sessions.isEmpty {
                    Text("暂无会话")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .padding(.leading, 18)
                        .padding(.top, DS.Spacing.s2)
                        .padding(.bottom, DS.Spacing.s6)
                }
            }
        }
    }

    private func sessionRow(
        project: ProjectNode, version: VersionNode, session: SessionSummary
    ) -> some View {
        let isSelected = model.selection
            == .session(project: project.name, version: version.name, sessionId: session.id)
        // 生成指示：流归属 = 该会话时行右缘亮呼吸点（流是全局单份的，
        // streamingSessionID 钉在发起会话上，切到别的会话也能看出谁在生成）
        let isGenerating = store.isStreaming && store.streamingSessionID == session.id

        return ArchiveSessionRow(
            title: session.title,
            isSelected: isSelected,
            isGenerating: isGenerating,
            onTap: {
                model.activeProject = project.name
                model.selection = .session(
                    project: project.name, version: version.name, sessionId: session.id
                )
                model.reloadTree()
            },
            onRename: {
                renameTarget = SessionActionTarget(
                    project: project.name, version: version.name,
                    sessionId: session.id, title: session.title
                )
            },
            onDelete: {
                deleteTarget = SessionActionTarget(
                    project: project.name, version: version.name,
                    sessionId: session.id, title: session.title
                )
            }
        )
    }

    // MARK: - 会话操作反馈（更多菜单 → 弹窗保存/确认）

    /// 任务区会话行（默认/unversioned 平铺视图）：与档案会话行同形制，
    /// 差异 = 右缘显示最近活跃时间（hover 让位「更多」按钮）+ 菜单多一项
    /// 「转为项目」（任务 → 空间转化路径）。
    private func taskRow(session: SessionSummary) -> some View {
        let isSelected = model.selection
            == .session(
                project: PMAgentStore.defaultProjectName, version: "unversioned",
                sessionId: session.id
            )
        let isGenerating = store.isStreaming && store.streamingSessionID == session.id

        return ArchiveSessionRow(
            title: session.title,
            isSelected: isSelected,
            isGenerating: isGenerating,
            time: Self.taskTime(session.lastActiveAt),
            onTap: {
                model.selection = .session(
                    project: PMAgentStore.defaultProjectName, version: "unversioned",
                    sessionId: session.id
                )
                model.reloadTree()
            },
            onRename: {
                renameTarget = SessionActionTarget(
                    project: PMAgentStore.defaultProjectName, version: "unversioned",
                    sessionId: session.id, title: session.title
                )
            },
            onDelete: {
                deleteTarget = SessionActionTarget(
                    project: PMAgentStore.defaultProjectName, version: "unversioned",
                    sessionId: session.id, title: session.title
                )
            },
            onPromote: {
                promoteTarget = SessionActionTarget(
                    project: PMAgentStore.defaultProjectName, version: "unversioned",
                    sessionId: session.id, title: session.title
                )
            }
        )
    }

    /// 任务行右缘时间：ISO8601 → 相对时间（「2 小时前」）；解析失败不显示。
    private static func taskTime(_ iso: String) -> String? {
        guard let date = isoParser.date(from: iso) else { return nil }
        return RecentFolderStore.relativeTime(date)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    /// 「转为项目」确认：成功 → 落空间段并展开新项目（selection 已由
    /// AppModel 重定向，onChange 联动也会落段，这里显式保证一致）。
    private func promote(target: SessionActionTarget, name: String) {
        if let error = model.promoteTaskToProject(sessionId: target.sessionId, projectName: name) {
            model.notif = DSNotifMessage(variant: .error, title: "转为项目失败", description: error)
        } else {
            withAnimation(DS.Motion.springFast) {
                expandedProjects.insert(name)
                expandedVersions.insert("\(name)/unversioned")
                activeModule = .spaces
            }
        }
    }

    private func saveRename(target: SessionActionTarget, newTitle: String) {
        if let error = model.renameSession(
            project: target.project, version: target.version,
            sessionId: target.sessionId, title: newTitle
        ) {
            model.notif = DSNotifMessage(variant: .error, title: "重命名失败", description: error)
        }
    }

    private func delete(target: SessionActionTarget) {
        if let error = model.deleteSession(
            project: target.project, version: target.version, sessionId: target.sessionId
        ) {
            model.notif = DSNotifMessage(variant: .error, title: "删除失败", description: error)
        }
    }

    // MARK: - 项目/版本操作反馈（更多菜单 → 弹窗创建/保存/确认）

    /// 新建版本默认名：扫描现有「vN」前缀取最大号 +1（v1.0 起步，自定义名不参与推导）。
    private func suggestedVersionName(for project: ProjectNode) -> String {
        let numbers = project.versions.compactMap { version -> Int? in
            guard version.name.hasPrefix("v") else { return nil }
            return Int(version.name.dropFirst().split(separator: ".").first ?? "")
        }
        guard let maxNumber = numbers.max() else { return "v1.0" }
        return "v\(maxNumber + 1).0"
    }

    private func createVersion(target: ProjectActionTarget, name: String) {
        if let error = model.createVersion(in: target.name, name: name) {
            model.notif = DSNotifMessage(variant: .error, title: "新建版本文件失败", description: error)
        } else {
            // 项目折叠时新版本行不可见 → 自动展开
            withAnimation(DS.Motion.springFast) { expandedProjects.insert(target.name) }
        }
    }

    private func newConversation(project: ProjectNode, version: VersionNode) {
        if let error = model.newSession(inProject: project.name, version: version.name) {
            model.notif = DSNotifMessage(variant: .error, title: "无法新建对话", description: error)
        }
    }

    private func saveProjectRename(target: ProjectActionTarget, newName: String) {
        if let error = model.renameProject(target.name, to: newName) {
            model.notif = DSNotifMessage(variant: .error, title: "重命名项目失败", description: error)
        } else {
            // 展开状态跟随更名，保持原视觉状态
            if expandedProjects.remove(target.name) != nil {
                expandedProjects.insert(newName)
            }
        }
    }

    private func deleteProject(target: ProjectActionTarget) {
        if let error = model.deleteProject(target.name) {
            model.notif = DSNotifMessage(variant: .error, title: "删除项目失败", description: error)
        } else {
            expandedProjects.remove(target.name)
        }
    }

    private func saveVersionRename(target: VersionActionTarget, newName: String) {
        if let error = model.renameVersion(
            project: target.project, version: target.version, to: newName
        ) {
            model.notif = DSNotifMessage(variant: .error, title: "重命名版本失败", description: error)
        } else {
            let oldKey = "\(target.project)/\(target.version)"
            let newKey = "\(target.project)/\(newName)"
            if expandedVersions.remove(oldKey) != nil { expandedVersions.insert(newKey) }
        }
    }

    private func deleteVersion(target: VersionActionTarget) {
        if let error = model.deleteVersion(
            project: target.project, version: target.version
        ) {
            model.notif = DSNotifMessage(variant: .error, title: "删除版本失败", description: error)
        } else {
            expandedVersions.remove("\(target.project)/\(target.version)")
        }
    }

    // MARK: - 展开状态

    @State private var expandedProjects: Set<String> = []
    /// 版本层展开状态（key = "项目/版本"，支撑整行点击切换展开）。
    @State private var expandedVersions: Set<String> = []

    private func toggleProject(_ project: String) {
        withAnimation(DS.Motion.springFast) {
            if expandedProjects.contains(project) {
                expandedProjects.remove(project)
            } else {
                expandedProjects.insert(project)
            }
        }
    }

    private func toggleVersion(_ project: String, _ version: String) {
        let key = "\(project)/\(version)"
        withAnimation(DS.Motion.springFast) {
            if expandedVersions.contains(key) {
                expandedVersions.remove(key)
            } else {
                expandedVersions.insert(key)
            }
        }
    }
}

// MARK: - 任务树行（档案索引方案 · 整行矩形可点 + hover/按下反馈）

/// 行按钮样式：hover 轻底（overlayL1）、按下深一档（overlayL2），
/// 选中底可配（档案方案会话行 = brandPopup 品牌紫，与全 app 选中语言统一）。
/// ButtonStyle 持不了 @State，hover 态由各行视图持有后以 Binding 传入。
private struct SidebarTaskRowStyle: ButtonStyle {
    var isSelected = false
    var selectionFill: Color = .overlayL2
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
        if isSelected { return selectionFill }
        if pressed { return Color.overlayL2 }
        if hovered { return Color.overlayL1 }
        return .clear
    }
}

/// 档案行右缘展开箭头：折叠朝右，展开转 90° 朝下（springFast）。
private struct ArchiveChevron: View {
    let isExpanded: Bool

    var body: some View {
        DSIcon(.chevronRight, size: 10)
            .foregroundStyle(Color.ink300)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(DS.Motion.springFast, value: isExpanded)
    }
}

/// 项目行（档案索引）：衬线项目名 + 右置箭头；整行可点 = 切换展开并激活项目。
/// hover / 菜单展开时「更多」按钮（⋮）在箭头左侧淡入，箭头常驻最右缘——
/// 展开与更多操作并存各占其位：新建版本文件 / 重命名 / 删除，菜单走 popover
/// （独立 NSWindow，空间不足自动翻转，同会话行方案）。
private struct ArchiveProjectRow: View {
    let name: String
    let isExpanded: Bool
    var onTap: () -> Void = {}
    var onNewVersion: () -> Void = {}
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var hovered = false
    @State private var moreHovered = false
    @State private var menuOpen = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.s10) {
                Text(name)
                    .font(DS.Font.display2XS)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // 箭头常驻最右缘：「更多」（⋮）淡入在其左侧，两按钮并存各占其位
                ArchiveChevron(isExpanded: isExpanded)
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarTaskRowStyle(hovered: $hovered))
        // 「更多」挂在 Button 外层 overlay（sibling 而非嵌套），点击不触发行选中；
        // 位于箭头左侧 = 行右 padding 12 + 箭头宽 10 + 间距 6
        .overlay(alignment: .trailing) {
            moreButton
                .padding(.trailing, DS.Spacing.s12 + DS.Spacing.s10 + DS.Spacing.s6)
        }
        .animation(DS.Motion.springFast, value: hovered)
        .animation(DS.Motion.springFast, value: menuOpen)
        .onHover { hovered = $0 }
    }

    /// 「更多」按钮（⋮）：22×22 命中区、hover 提亮；淡入于常驻最右缘的箭头左侧。
    private var moreButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            DSIcon(.moreVertical, size: 14)
                .foregroundStyle(moreHovered || menuOpen ? Color.ink900 : Color.ink500)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(moreHovered || menuOpen ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { moreHovered = $0 }
        .opacity(hovered || menuOpen ? 1 : 0)
        .accessibilityLabel("更多操作")
        .accessibilityHint("新建版本文件、重命名或删除该项目")
        .help("更多操作")
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            projectMenu
                .presentationBackground(.clear)  // 去系统底，露出 DSMenu 玻璃卡
        }
    }

    private var projectMenu: some View {
        DSMenu(minWidth: 148) {
            DSMenuItem(
                title: "新建版本文件", icon: .plus, titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onNewVersion()
            }
            DSMenuItem(
                title: "重命名", icon: .pencil, titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onRename()
            }
            DSMenuItem(
                title: "删除", icon: .delete, isDestructive: true,
                titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onDelete()
            }
        }
    }
}

/// 版本行（档案索引）：mono「VER」标签 + mono 版本名，封板挂锁 + SEALED；
/// 层级靠排版不靠图标（原 folder/layers 图标位由文字标签顶替），整行可点切换展开。
/// hover / 菜单展开时「更多」按钮（⋮）在箭头左侧淡入，箭头常驻最右缘（与项目行
/// 同规格）：新建对话 / 重命名 / 删除。unversioned（默认无版本号）是兜底容器，
/// 不渲染「重命名」项（store 层守卫本就拒绝）；已封板版本的守卫在 AppModel
/// 层以通知条报错。
private struct ArchiveVersionRow: View {
    let name: String
    let isReleased: Bool
    let isUnversioned: Bool
    let isExpanded: Bool
    var onTap: () -> Void = {}
    var onNewConversation: () -> Void = {}
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var hovered = false
    @State private var moreHovered = false
    @State private var menuOpen = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.s8) {
                Text("VER")
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(Color.ink300)
                Text(name)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
                if isReleased {
                    DSIcon(.lock, size: 10)
                        .foregroundStyle(Color.ink300)
                    Text("SEALED")
                        .font(DS.Font.mono2XS)
                        .foregroundStyle(Color.ink300)
                }
                Spacer(minLength: 0)
                // 箭头常驻最右缘：「更多」（⋮）淡入在其左侧（与项目行同规格）
                ArchiveChevron(isExpanded: isExpanded)
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarTaskRowStyle(hovered: $hovered))
        // 「更多」挂在 Button 外层 overlay（sibling 而非嵌套），点击不触发行选中；
        // 位于箭头左侧 = 行右 padding 12 + 箭头宽 10 + 间距 6
        .overlay(alignment: .trailing) {
            moreButton
                .padding(.trailing, DS.Spacing.s12 + DS.Spacing.s10 + DS.Spacing.s6)
        }
        .animation(DS.Motion.springFast, value: hovered)
        .animation(DS.Motion.springFast, value: menuOpen)
        .onHover { hovered = $0 }
    }

    /// 「更多」按钮（⋮）：与项目行同规格（22×22 命中区、hover 提亮、淡入于箭头左侧）。
    private var moreButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            DSIcon(.moreVertical, size: 14)
                .foregroundStyle(moreHovered || menuOpen ? Color.ink900 : Color.ink500)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(moreHovered || menuOpen ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { moreHovered = $0 }
        .opacity(hovered || menuOpen ? 1 : 0)
        .accessibilityLabel("更多操作")
        .accessibilityHint(isUnversioned ? "新建对话或删除该版本" : "新建对话、重命名或删除该版本")
        .help("更多操作")
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            versionMenu
                .presentationBackground(.clear)  // 去系统底，露出 DSMenu 玻璃卡
        }
    }

    private var versionMenu: some View {
        DSMenu(minWidth: 148) {
            DSMenuItem(
                title: "新建对话", icon: .newTask, titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onNewConversation()
            }
            if !isUnversioned {
                DSMenuItem(
                    title: "重命名", icon: .pencil, titleFont: DS.Font.bodySM
                ) {
                    menuOpen = false
                    onRename()
                }
            }
            DSMenuItem(
                title: "删除", icon: .delete, isDestructive: true,
                titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onDelete()
            }
        }
    }
}

/// 会话行（档案索引）：纯标题、行高 ≈32pt；
/// 选中态 = brandPopup 品牌紫 + 左缘 2px 品牌条 + 文字提亮（不加粗）。
/// 右缘三个互斥装饰：最近活跃时间（任务区行，hover 让位）· 生成指示呼吸点
/// （该会话正在生成时）·「更多」按钮（hover / 菜单展开时淡入，内含
/// 重命名/删除菜单；任务区行多一项「转为项目」）。
private struct ArchiveSessionRow: View {
    let title: String
    let isSelected: Bool
    var isGenerating = false
    /// 任务区行的右缘相对时间（「2 小时前」）；nil = 档案树行不显示。
    var time: String? = nil
    var onTap: () -> Void = {}
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    /// 任务区行专属：「转为项目」菜单项（nil = 档案树行不显示该项）。
    var onPromote: (() -> Void)? = nil
    @State private var hovered = false
    @State private var moreHovered = false
    @State private var menuOpen = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(title)
                    .font(DS.Font.bodySM)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.ink900 : Color.ink500)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.brandAccent)
                        .frame(width: 2)
                        .padding(.vertical, DS.Spacing.s8)
                }
            }
        }
        .buttonStyle(
            SidebarTaskRowStyle(
                isSelected: isSelected, selectionFill: .brandPopup, hovered: $hovered
            )
        )
        // 右缘装饰组挂在 Button 外层 overlay（sibling 而非嵌套），
        // 避免按钮套按钮的命中歧义；点击「更多」不会触发行选中。
        .overlay(alignment: .trailing) {
            HStack(spacing: DS.Spacing.s2) {
                // 时间与生成点、「更多」按钮互斥：hover 出现按钮时让位
                if let time, !hovered && !menuOpen {
                    Text(time)
                        .font(DS.Font.mono2XS)
                        .foregroundStyle(Color.ink300)
                        .transition(.opacity)
                }
                if isGenerating && !hovered && !menuOpen {
                    DSPulseDot(tint: isSelected ? Color.brandAccent : Color.brand600)
                        .help("正在生成回答…")
                        .transition(.opacity)
                }
                moreButton
            }
            .padding(.trailing, DS.Spacing.s6)
        }
        .animation(DS.Motion.springFast, value: isGenerating)
        .animation(DS.Motion.springFast, value: hovered)
        .animation(DS.Motion.springFast, value: menuOpen)
        .onHover { hovered = $0 }
    }

    /// 「更多」按钮（⋯）：22×22 命中区、hover 提亮；菜单走 popover（独立
    /// NSWindow，点外部自动收起、空间不足自动翻转，同 NewTaskView 下拉方案）。
    private var moreButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            DSIcon(.more, size: 14)
                .foregroundStyle(moreHovered || menuOpen ? Color.ink900 : Color.ink500)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(moreHovered || menuOpen ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { moreHovered = $0 }
        .opacity(hovered || menuOpen ? 1 : 0)
        .accessibilityLabel("更多操作")
        .accessibilityHint(
            onPromote == nil ? "重命名或删除该对话" : "转为项目、重命名或删除该任务"
        )
        .help("更多操作")
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            sessionMenu
                .presentationBackground(.clear)  // 去系统底，露出 DSMenu 玻璃卡
        }
    }

    private var sessionMenu: some View {
        DSMenu(minWidth: 148) {
            if let onPromote {
                DSMenuItem(
                    title: "转为项目", icon: .arrowUpRight, titleFont: DS.Font.bodySM
                ) {
                    menuOpen = false
                    onPromote()
                }
            }
            DSMenuItem(
                title: "重命名对话", icon: .pencil, titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onRename()
            }
            DSMenuItem(
                title: "删除对话", icon: .delete, isDestructive: true,
                titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                onDelete()
            }
        }
    }
}

/// 重命名对话弹窗：dsInput 单行输入，Enter 保存 / Esc 取消；空名禁存。
private struct RenameSessionSheet: View {
    let target: SessionActionTarget
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        DSDialog(
            title: "重命名对话", icon: .pencil,
            onClose: { dismiss() }, width: 420
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                Text("对话名称")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                TextField("输入新名称", text: $title)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .dsInput(focused: focused)
                    .focused($focused)
                    .accessibilityLabel("对话名称")
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(title)
                    dismiss()
                }
                .buttonStyle(.ds(.primary))
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
        .onAppear {
            title = target.title
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// 删除对话确认弹窗：防误删两步确认，明确不可撤销提示。
private struct DeleteSessionSheet: View {
    let target: SessionActionTarget
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSDialog(
            title: "删除对话", icon: .delete,
            onClose: { dismiss() }, width: 420
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                Text("确定要删除对话「\(target.title)」吗？")
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
                Text("该对话的全部消息将从记录中移除，操作不可撤销。")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("删除") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.ds(.dangerSubtle))
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
    }
}

/// 新建版本文件弹窗（项目行菜单）：版本名输入（预填 vN 最大号 +1），
/// Enter 创建 / Esc 取消；空名禁建。
private struct NewVersionSheet: View {
    let projectName: String
    let suggestedName: String
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        DSDialog(
            title: "新建版本文件", icon: .plus,
            onClose: { dismiss() }, width: 420
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                Text("项目「\(projectName)」下的新版本名称")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                TextField("输入版本名", text: $name)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .dsInput(focused: focused)
                    .focused($focused)
                    .accessibilityLabel("版本名称")
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    onCreate(name)
                    dismiss()
                }
                .buttonStyle(.ds(.primary))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
        .onAppear {
            name = suggestedName
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// 项目/版本重命名弹窗（与对话重命名同形制）：dsInput 单行输入，
/// Enter 保存 / Esc 取消；空名禁存。
private struct RenameNodeSheet: View {
    let title: String
    let fieldLabel: String
    let initialName: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        DSDialog(
            title: title, icon: .pencil,
            onClose: { dismiss() }, width: 420
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                Text(fieldLabel)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                TextField("输入新名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .dsInput(focused: focused)
                    .focused($focused)
                    .accessibilityLabel(fieldLabel)
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(name)
                    dismiss()
                }
                .buttonStyle(.ds(.primary))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
        .onAppear {
            name = initialName
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// 删除项目确认弹窗：整目录移除警示，明确不可撤销提示。
private struct DeleteProjectSheet: View {
    let target: ProjectActionTarget
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSDialog(
            title: "删除项目", icon: .delete,
            onClose: { dismiss() }, width: 420
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                Text("确定要删除项目「\(target.name)」吗？")
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
                Text("该项目下的全部版本、会话与产物将从磁盘移除，操作不可撤销。")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("删除") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.ds(.dangerSubtle))
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
    }
}

/// 删除版本确认弹窗：整目录移除警示，明确不可撤销提示。
private struct DeleteVersionSheet: View {
    let target: VersionActionTarget
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSDialog(
            title: "删除版本", icon: .delete,
            onClose: { dismiss() }, width: 420
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                Text("确定要删除版本「\(target.displayName)」吗？")
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
                Text("该版本下的全部会话与产物将从磁盘移除，操作不可撤销。")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("删除") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.ds(.dangerSubtle))
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
    }
}

/// 「转为项目」弹窗（任务区会话行菜单）：任务 → 空间转化路径。
/// 项目名预填任务标题前 12 字；文案如实说明迁移边界——对话内容、标题与
/// 附图随迁，决策/风险/产物是任务区版本级共享文件、保留在任务区不动。
private struct PromoteTaskSheet: View {
    let target: SessionActionTarget
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        DSDialog(
            title: "转为项目", icon: .arrowUpRight,
            onClose: { dismiss() }, width: 460
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                Text("任务「\(target.title)」将迁移为独立项目下的会话，对话内容、标题与图片一并随迁。")
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
                Text("决策日志、风险与已生成的产物属于任务区共享记录，将保留在任务区。")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                Text("项目名称")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                    .padding(.top, DS.Spacing.s2)
                TextField("输入项目名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .dsInput(focused: focused)
                    .focused($focused)
                    .accessibilityLabel("项目名称")
            }
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("创建并迁移") {
                    onCreate(name)
                    dismiss()
                }
                .buttonStyle(.ds(.primary))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与关闭钮/取消钮同动作）
        .onAppear {
            name = String(target.title.prefix(12))
            DispatchQueue.main.async { focused = true }
        }
    }
}
