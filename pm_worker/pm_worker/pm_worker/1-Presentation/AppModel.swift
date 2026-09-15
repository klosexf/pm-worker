//
//  AppModel.swift
//  pm_worker
//
//  全局应用状态与主线编排（M2）：阶段路由（AgentPrompts）、确认闸口推进、
//  产物解析落盘、记忆层注入/沉淀。文件系统是唯一事实源，阶段从磁盘推导。
//

import Foundation
import SwiftUI
import Combine
import GRDB

/// 左栏三级树节点（项目 → 版本 → 会话），磁盘目录的只读投影。
struct ProjectNode: Identifiable, Equatable {
    var name: String
    var versions: [VersionNode]

    var id: String { name }
}

struct VersionNode: Identifiable, Equatable {
    /// 磁盘目录名（v1.0 / unversioned）。
    var name: String
    var isReleased: Bool
    var sessions: [SessionSummary]

    var id: String { name }

    /// UI 显示名：unversioned → 「默认无版本号」。
    var displayName: String { name == "unversioned" ? "默认无版本号" : name }
}

/// 侧栏展开联动信号（在哪个会话窗口发送消息 → ProjectSidebar 自动展开
/// 对应项目/版本节点）。id 每次发送换新：同上下文连续发送也能再次触发
/// onChange（用户折叠后重发可再展开）。
struct SidebarReveal: Equatable {
    let project: String
    let version: String
    let id = UUID()
}

/// 中栏工作区。
enum Workspace: Equatable {
    case newTask
    case projectHome(String)
    case session(project: String, version: String, sessionId: String)
    // 左栏功能导航（原型 v4 Sidebar NAV：技能库/知识库/决策日志；
    // 模型配置与 MCP 设置已收进设置弹框，不再占导航位）
    case skillLibrary
    case knowledgeHub
    case decisionsPage

    /// 右栏面板的上下文（项目/版本）；nil → 四 Tab 空态。
    var inspectorProject: (project: String, version: String)? {
        switch self {
        case .newTask, .skillLibrary, .knowledgeHub, .decisionsPage: nil
        case .projectHome(let project): (project, "unversioned")
        case .session(let project, let version, _): (project, version)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: LLMSettings
    @Published var projects: [ProjectNode] = []
    /// 选中态变化 → didSet 同步切换会话运行时（见 syncSessionRuntime）。
    /// 赋值都发生在按钮动作 / Task 上下文，先于 body 重算，保证首帧数据，
    /// 且避免在 view update 中改 @Published（ConversationView.init 不再驱动数据源）。
    @Published var selection: Workspace = .newTask {
        didSet { syncInspectorDefault(); syncSessionRuntime() }
    }
    /// 用户已交互选中的项目（默认置顶规则：未选中时「默认」置顶）。
    @Published var activeProject: String?
    /// 最近一次发送的会话上下文（ProjectSidebar onChange 消费 → 自动展开
    /// 对应项目/版本节点；nil = 尚未发送过）。
    @Published var sidebarReveal: SidebarReveal?

    /// 设置弹框（Trae 风格模态）：侧栏左下角齿轮 / ⌘, / MCP 导航深链三入口共用。
    @Published var settingsPresented = false
    /// 窗口级瞬态通知（顶部居中 toast）：侧栏等局部视图发起操作反馈，
    /// 由 ContentView 根部统一挂载展示（局部 pane 内弹会偏居一侧）。
    @Published var notif: DSNotifMessage?
    /// 弹框当前页（深链用：MCP Server 导航 → .mcp）。
    @Published var settingsPage: SettingsDialogPage = .model

    /// 右栏 Inspector 面板是否折叠（面板头部按钮切换；折叠后仅保留中栏悬浮展开钮）。
    /// 默认态随页面类型归位（syncInspectorDefault）：新建对话页无上下文
    /// （四 Tab 空态无可看）→ 默认收起；会话/项目主页有上下文 → 默认展开。
    @Published var inspectorCollapsed = true

    /// 右栏选中 Tab（InspectorPanel 绑定；对话页里程碑行点击直达对应 Tab）。
    @Published var inspectorTab: InspectorPanel.InspectorTab = .artifacts

    /// 会话运行时（中栏对话视图的数据源）。
    let sessionStore = SessionStore()
    /// 当前会话的流水线状态机（阶段从磁盘产物推导）。
    @Published private(set) var pipeline: PipelineEngine
    /// 当前会话的记忆层（注入 + 沉淀）。
    @Published private(set) var memory: MemoryStore
    /// 当前会话的 💀 风险登记册（M3：radar fatal 落盘 + 状态机事件结算）。
    @Published private(set) var risks: RiskStore
    /// 版本封板运行时（Task 3.7）。
    private let versionStore = VersionStore()
    /// 当前会话版本是否已封板（ConversationView 黄条依据）。
    @Published private(set) var currentVersionReleased = false
    /// 封板记忆交接弹窗（releaseVersion 成功且该版本有版本记忆时弹出；
    /// 确认 → 勾选条目升项目记忆，跳过 → 原条目随封板版本归档）。
    // （方案 A：封板交接机制已移除——版本不再是记忆作用域，无交接需求）

    // MARK: 知识层状态（Task 4.4 / 4.5）

    /// 「这条记下来」草稿（非 nil → KnowledgeCaptureSheet 弹出；E10 归属分流入口）。
    @Published var bookmarkDraft: String?
    /// 当前阶段主动推荐（1-3 个，含理由、可拒绝；E23）。
    @Published private(set) var recommendations: [Recommender.Recommendation] = []
    /// 本阶段已拒绝的推荐卡片 id（同阶段不重复被拒项；阶段切换时清空）。
    @Published private(set) var rejectedCards: Set<String> = []
    /// 推荐阶段标记（检测阶段切换 → 清空上一阶段拒绝记录）。
    private var recommendationStage: PipelineRun.Stage?

    /// 本会话已采纳的方法论标题（记忆校准注入数据源：Agent 使用该方法论时
    /// 同步注入该用户的历史使用倾向；上下文切换时清空）。
    private var adoptedMethodologies: [String] = []

    // MARK: 上下文组装可观测性（Task 4.1 / 4.6：ContextBuilder 填充，检查器 ⌘D 读取）

    /// 最近一次 Context Builder 组装 trace（nil = 尚未组装）。
    @Published var lastAssembly: ContextAssembly?
    /// 分支触发记录（竞品分析等，runCompetitiveAnalysis 等处追加；检查器展示）。
    @Published var branchTriggers: [BranchTriggerRecord] = []

    /// 索引库（internal：右栏知识点 Tab / 卡片库 / 技能库 UI 直接查询）。
    let database: AppDatabase?

    init() {
        // Preview 环境守卫：Xcode Preview 宿主（XCODE_RUNNING_FOR_PREVIEWS=1）的
        // 沙盒/XPC 环境特殊，初始化副作用（bootstrap 建目录、GRDB 开库）会阻塞，
        // 导致画布 30 秒启动等待超时（Failed to launch in reasonable time）。
        // Preview 不跑副作用——跳过磁盘写入，返回空状态。
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        self.settings = isPreview ? .default : LLMSettings.load()
        if isPreview {
            self.database = nil
        } else {
            self.database = try? AppDatabase()
            try? PMAgentStore.bootstrap()
            Self.reindexStaleSkills()
        }
        self.pipeline = PipelineEngine(project: "默认", version: "unversioned", database: database)
        self.memory = MemoryStore(project: "默认", version: "unversioned")
        self.risks = RiskStore(project: "默认", version: "unversioned")
        if !isPreview { reloadTree() }
        refreshReleasedState()
    }

    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避（同 PipelineEngine
    /// 惯例）：显式退出隔离销毁路径。App 运行时本实例常驻不销毁，此声明
    /// 主要保障测试等局部实例的析构安全（默认隔离 deinit 触发 malloc 崩溃）。
    nonisolated deinit {}

    // MARK: - 三级树（磁盘 → 投影）

    /// 出厂首启 / 升级补偿（Task 4.7 → 技能追加批 v1.2）：skills/ 磁盘技能数与
    /// 索引 skills 行数不一致时（空表、升级播种新技能、用户增删文件），后台全量
    /// 重建一次，避免「技能库为空 / 追加技能不显示」。与设置页手动重建同口径
    /// （零 embedding 占位路径）。自开 AppDatabase（同 SettingsDialog.rebuildIndex
    /// 惯例），不捕获 self；一致时仅一次开库 + COUNT，零额外开销。
    private nonisolated static func reindexStaleSkills() {
        Task.detached(priority: .utility) {
            let dbURL = PMAgentStore.root.appendingPathComponent("index.sqlite")
            guard let db = try? AppDatabase(indexURL: dbURL) else { return }
            let indexed = (try? await db.dbQueue.read { database in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM skills")
            }) ?? 0
            let onDisk = countParseableSkillFiles()
            guard indexed != onDisk else { return }
            _ = try? IndexRebuilder.rebuild(database: db)
        }
    }

    /// skills/ 内可解析技能数（与 IndexRebuilder.scanSkills 同口径：
    /// .md + front-matter 可解析即计数，模板等不数——避免坏文件导致每启必重建）。
    private nonisolated static func countParseableSkillFiles() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: PMAgentStore.skillsDir, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .filter { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      SkillFrontMatterParser.parse(text) != nil else { return false }
                return true
            }
            .count
    }

    func reloadTree() {
        var nodes: [(node: ProjectNode, createdAt: Date)] = []
        for projectName in PMAgentStore.listProjects() {
            var versionNodes: [VersionNode] = []
            for versionName in PMAgentStore.listVersions(in: projectName) {
                guard versionName != "knowledge" else { continue }
                let doc = try? PMAgentStore.readVersion(project: projectName, version: versionName)
                versionNodes.append(
                    VersionNode(
                        name: versionName,
                        isReleased: doc?.status == .released,
                        sessions: SessionStore.sessions(in: projectName, version: versionName)
                    )
                )
            }
            // unversioned 恒置顶，语义化版本升序
            versionNodes.sort { a, b in
                if a.name == "unversioned" { return true }
                if b.name == "unversioned" { return false }
                return a.name < b.name
            }
            nodes.append(
                (ProjectNode(name: projectName, versions: versionNodes),
                 PMAgentStore.projectCreatedAt(projectName) ?? .distantPast)
            )
        }

        // 项目排序（2026-09-13 用户决策）：创建时间倒序（新的在前），「默认」恒沉底；
        // 创建时间缺失/相等按名称升序兜底——顺序永远稳定，不随交互翻转。
        let defaultName = PMAgentStore.defaultProjectName
        nodes.sort { a, b in
            let aDefault = a.node.name == defaultName
            let bDefault = b.node.name == defaultName
            if aDefault != bDefault { return !aDefault }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.node.name < b.node.name
        }
        projects = nodes.map(\.node)
    }

    // MARK: - 会话创建（导航不落盘，首条消息才写盘）

    /// 「＋ 新建会话」：当前项目/版本下建新会话（Task 1.1 规则）。
    /// 未选项目 → 默认/unversioned；封版 → 首个活跃版本；无版本 → unversioned。
    func newSession() {
        let project = activeProject ?? PMAgentStore.defaultProjectName
        var version = "unversioned"
        // 当前正在看的版本若未封板，直接在其中建
        if case .session(let p, let v, _) = selection, p == project, !isReleased(v, in: project) {
            version = v
        } else if let firstActive = PMAgentStore.listVersions(in: project)
            .filter({ $0 != "knowledge" && $0 != "unversioned" })
            .first(where: { !isReleased($0, in: project) }) {
            version = firstActive
        }
        selection = .session(project: project, version: version, sessionId: UUID().uuidString)
    }

    private func isReleased(_ version: String, in project: String) -> Bool {
        let doc = try? PMAgentStore.readVersion(project: project, version: version)
        return doc?.status == .released
    }

    /// 新建任务页发送：首条消息落盘后跳转对话（① 澄清起步）。
    /// version 为 nil 落「默认无版本号」（unversioned）；显式选择版本则
    /// 作为本次对话的迭代基底（新建任务页「关联版本」chip，方案 A）。
    func startTask(message: String, associatedProject: String?, version: String? = nil) async {
        let project = associatedProject ?? PMAgentStore.defaultProjectName
        let sessionId = UUID().uuidString
        // selection didSet 同步完成 sessionStore.open + switchContext
        selection = .session(project: project, version: version ?? "unversioned", sessionId: sessionId)
        await sendMessage(message)
        reloadTree()
    }

    /// selection 进入会话 → 同步切换会话数据源与状态机/记忆层上下文。
    /// 在赋值动作上下文执行（非 view update），此时发布 @Published 是安全的。
    private func syncSessionRuntime() {
        guard case .session(let project, let version, let sessionId) = selection else { return }
        sessionStore.open(project: project, version: version, sessionId: sessionId)
        switchContext(project: project, version: version)
    }

    // MARK: - 会话管理（侧栏行「更多」菜单：重命名 / 删除）

    /// 重命名会话（session-meta.json 标题覆盖）。返回错误文案，nil = 成功。
    func renameSession(
        project: String, version: String, sessionId: String, title: String
    ) -> String? {
        do {
            try SessionStore.renameSession(
                project: project, version: version, sessionId: sessionId, title: title
            )
        } catch {
            return error.localizedDescription
        }
        reloadTree()
        return nil
    }

    /// 删除会话（discussions.jsonl 移除该会话全部行）。返回错误文案，nil = 成功。
    func deleteSession(project: String, version: String, sessionId: String) -> String? {
        // 流式期间全局禁删：流式回复与删除都走 discussions.jsonl 整文件重写/追加，
        // 并发写同一文件有丢行风险（输入栏已全局串行化，这里同口径收紧）。
        if sessionStore.isStreaming {
            return "正在生成回答，请等待生成完成后再删除"
        }
        do {
            try SessionStore.deleteSession(
                project: project, version: version, sessionId: sessionId
            )
        } catch {
            return error.localizedDescription
        }
        // 删的是当前打开会话 → 清运行时投影并导航到项目主页
        if case .session(let p, let v, let sid) = selection,
           p == project, v == version, sid == sessionId {
            sessionStore.closeIfCurrent(project: project, version: version, sessionId: sessionId)
            selection = .projectHome(project)
        }
        // 该会话的确认坞静默记忆随会话销毁
        deferredConfirmGates[sessionId] = nil
        reloadTree()
        // 删的可能是闸口归属会话 → 锚点随条目移除，重推归属
        refreshGateOwner()
        return nil
    }

    /// 任务 → 空间转化（任务区会话行菜单「转为项目」）：把任务区（默认/
    /// unversioned）的轻会话整体迁为独立项目下的 unversioned 会话——对话行、
    /// 标题覆盖、附图随迁；决策/风险/产物是版本级共享文件留在任务区（弹窗
    /// 文案已说明）。返回错误文案，nil = 成功。
    /// 迁移顺序 = 先建目标追加、后删源（moveSession 内部保证任何失败点位
    /// 源数据都在）；建壳后失败则删壳回滚，回到操作前状态。
    func promoteTaskToProject(sessionId: String, projectName: String) -> String? {
        // 流式期间禁改：与删除/重命名同口径（discussions.jsonl 并发写丢行风险）
        if sessionStore.isStreaming {
            return "正在生成回答，请等待生成完成后再操作"
        }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "项目名称不能为空" }
        // 未落盘会话（导航建立但从未发送）无可迁移内容，拒绝而不是造空项目
        guard SessionStore.sessions(in: PMAgentStore.defaultProjectName, version: "unversioned")
            .contains(where: { $0.id == sessionId }) else {
            return "该任务还没有任何对话内容，无需转为项目"
        }

        let shellCreated: Bool
        do {
            shellCreated = FileManager.default.fileExists(
                atPath: PMAgentStore.projectURL(name).path
            )
            _ = try PMAgentStore.createProject(named: name)
            try SessionStore.moveSession(
                sessionId: sessionId,
                from: PMAgentStore.defaultProjectName, sourceVersion: "unversioned",
                to: name, targetVersion: "unversioned"
            )
        } catch {
            // 回滚：本操作新建的项目壳 → 整体移除（既有项目同名冲突时不动）
            if !shellCreated {
                try? PMAgentStore.deleteProject(name)
            }
            return error.localizedDescription
        }

        // 迁移的是当前打开会话 → 重定向到新位置（selection didSet 重开运行时）
        if case .session(let p, let v, let sid) = selection,
           p == PMAgentStore.defaultProjectName, v == "unversioned", sid == sessionId {
            sessionStore.closeIfCurrent(project: p, version: v, sessionId: sid)
            selection = .session(project: name, version: "unversioned", sessionId: sessionId)
        }
        activeProject = name
        reloadTree()
        // 任务区是闸口归属候选 → 会话迁走后锚点可能悬空，重推归属
        refreshGateOwner()
        return nil
    }

    // MARK: - 项目/版本管理（侧栏行「更多」菜单：新建版本/新建对话/重命名/删除）

    /// 在项目下新建版本文件（01-07 阶段目录 + version.json + jsonl 三件套）。
    /// 返回错误文案，nil = 成功。
    func createVersion(in project: String, name: String) -> String? {
        do {
            _ = try PMAgentStore.createVersion(
                name.trimmingCharacters(in: .whitespacesAndNewlines), in: project
            )
        } catch {
            return error.localizedDescription
        }
        reloadTree()
        return nil
    }

    /// 在指定项目/版本下新建对话（版本行菜单）：与导航「新建任务」同机制
    /// （selection 指向未落盘会话，首条消息才写盘），只是版本被行锚定。
    /// 已封板版本是只读快照，拒绝发起。返回错误文案，nil = 成功。
    func newSession(inProject project: String, version: String) -> String? {
        if isReleased(version, in: project) {
            return "已封板版本为只读快照，请先新建版本文件再发起对话"
        }
        activeProject = project
        selection = .session(project: project, version: version, sessionId: UUID().uuidString)
        return nil
    }

    /// 重命名项目（目录 move + 清单回写，磁盘先行）。返回错误文案，nil = 成功。
    func renameProject(_ oldName: String, to newName: String) -> String? {
        if sessionStore.isStreaming {
            return "正在生成回答，请等待生成完成后再重命名"
        }
        do {
            try PMAgentStore.renameProject(from: oldName, to: newName)
        } catch {
            return error.localizedDescription
        }
        // 运行时引用更名：选中态变化 → didSet 重开会话/切上下文（读新路径）
        if activeProject == oldName { activeProject = newName }
        switch selection {
        case .projectHome(let p) where p == oldName:
            selection = .projectHome(newName)
        case .session(let p, let v, let sid) where p == oldName:
            selection = .session(project: newName, version: v, sessionId: sid)
        default:
            break
        }
        reloadTree()
        return nil
    }

    /// 删除项目（整目录移除，磁盘先行）。返回错误文案，nil = 成功。
    func deleteProject(_ name: String) -> String? {
        if sessionStore.isStreaming {
            return "正在生成回答，请等待生成完成后再删除"
        }
        do {
            try PMAgentStore.deleteProject(name)
        } catch {
            return error.localizedDescription
        }
        // 删的是选中上下文 → 清运行时投影并回到新建对话页
        if case .session(let p, let v, let sid) = selection, p == name {
            sessionStore.closeIfCurrent(project: p, version: v, sessionId: sid)
            selection = .newTask
        } else if case .projectHome(let p) = selection, p == name {
            selection = .newTask
        }
        if activeProject == name { activeProject = nil }
        reloadTree()
        return nil
    }

    /// 重命名版本（目录 move + 清单回写，磁盘先行）。返回错误文案，nil = 成功。
    func renameVersion(project: String, version: String, to newName: String) -> String? {
        if sessionStore.isStreaming {
            return "正在生成回答，请等待生成完成后再重命名"
        }
        do {
            try PMAgentStore.renameVersion(project: project, from: version, to: newName)
        } catch {
            return error.localizedDescription
        }
        // 打开中的会话随版本更名换路径 → didSet 重开会话并重建 pipeline/memory 上下文
        if case .session(let p, let v, let sid) = selection, p == project, v == version {
            selection = .session(project: p, version: newName, sessionId: sid)
        }
        reloadTree()
        return nil
    }

    /// 删除版本（整目录移除 + 清单回写，磁盘先行）。返回错误文案，nil = 成功。
    func deleteVersion(project: String, version: String) -> String? {
        if sessionStore.isStreaming {
            return "正在生成回答，请等待生成完成后再删除"
        }
        do {
            try PMAgentStore.deleteVersion(project: project, version: version)
        } catch {
            return error.localizedDescription
        }
        // 删的是打开中会话所在版本 → 清运行时投影并回到项目主页
        if case .session(let p, let v, let sid) = selection, p == project, v == version {
            sessionStore.closeIfCurrent(project: p, version: v, sessionId: sid)
            selection = .projectHome(project)
        }
        reloadTree()
        return nil
    }

    /// 右栏面板默认态归位（见 inspectorCollapsed 注释）：进入不同类型页面时
    /// 应用该页默认开合；同类型页面间切换（会话↔会话）不重置手动开合。
    /// 功能导航三页整页无右栏，不参与归位。启动即 newTask（didSet 不触发），
    /// 由 inspectorCollapsed 初始值 true 兜住首帧收起态。
    private var inspectorDefaultedKind: String?

    private func syncInspectorDefault() {
        let kind: String
        switch selection {
        case .newTask: kind = "newTask"
        case .projectHome: kind = "projectHome"
        case .session: kind = "session"
        case .skillLibrary, .knowledgeHub, .decisionsPage: return
        }
        guard kind != inspectorDefaultedKind else { return }
        inspectorDefaultedKind = kind
        inspectorCollapsed = kind == "newTask"
    }

    /// 会话上下文切换（状态机 + 记忆层跟随）。
    /// 幂等：同上下文不重建（selection didSet 会随重复赋值多次触发）。
    func switchContext(project: String, version: String) {
        guard pipeline.project != project || pipeline.version != version else { return }
        pipeline = PipelineEngine(project: project, version: version, database: database)
        memory = MemoryStore(project: project, version: version)
        risks = RiskStore(project: project, version: version)
        // 上下文切换 → 已采纳方法论清零（校准注入随会话走，不跨上下文）
        adoptedMethodologies = []
        // 确认坞「稍后再说」静默按会话键控（deferredConfirmGates），跨上下文天然隔离——
        // 切回原会话静默仍保留；新会话的闸口是全新提醒
        refreshReleasedState()
        refreshGateOwner()
    }

    /// 当前版本封板状态（磁盘对账）。
    private func refreshReleasedState() {
        currentVersionReleased = (try? PMAgentStore.readVersion(
            project: pipeline.project, version: pipeline.version
        ))?.status == .released
    }

    // MARK: - 设置

    func saveSettings() {
        try? settings.save()
    }

    /// 切换「使用中」对话模型（对话输入栏切换器 / 设置页列表共用入口）：
    /// 写透 stages 即时生效（下一次请求即用新模型），落盘保证重启后恢复。
    func switchChatModel(to id: String) {
        guard settings.activeModelID != id else { return }
        settings.setActiveModel(id: id)
        saveSettings()
    }

    // MARK: - 主线对话路由（阶段 → Agent prompt）

    /// 用户输入是否表达「进入下一个阶段」（自由作答等价选①，design.md §6.1）。
    static func isAdvanceIntent(_ text: String) -> Bool {
        let pattern = "进入(下一|下个|下?一个)阶段|确认(并)?进入|可以进入"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Context Builder 唯一注入收口（Task 4.1 + 4.8）

    /// 组装器按当前设置实例化（embedder 随 BYOK 设置走，设置变更即时生效）。
    private func makeContextBuilder() -> ContextBuilder {
        ContextBuilder(database: database, embedder: SettingsBackedEmbedder(settings: settings))
    }

    /// 阶段化 system prompt 组装（所有主线 prompt 的唯一入口）：
    /// 规则/记忆/技能正文/检索四段 + pitfalls 自检清单过预算裁剪后拼装，
    /// 组装结果写 lastAssembly（开发者检查器 ⌘D 读取）。
    /// 返回 prompt + 本轮实际注入的技能 id（随 send 下传，思考卡「引用技能」展示）。
    /// - Parameter userMessage: 本轮用户消息（技能意图路由的主信号）。用户发送轮必传；
    ///   系统轮（闸口推进/机器门修正）传 nil，回退到历史用户消息。
    private func assembleSystemPrompt(
        stage: LLMStage,
        userMessage: String? = nil,
        promptBuilder: @escaping (String) -> String
    ) async -> (prompt: String, skills: [String]) {
        let calibration = calibrationMatches()
        let assembly = await makeContextBuilder().assemble(
            stage: stage,
            project: pipeline.project,
            stageQuery: stageQueryText(stage: pipeline.stage),
            skillQuery: skillQueryText(userMessage: userMessage),
            memoryContext: memory.injectionContext,
            calibration: calibration.lines
        ) { injection in
            promptBuilder(injection)
        }
        lastAssembly = assembly
        markCalibrationPending(for: calibration.entries)
        return (assembly.systemPrompt, assembly.skillIds)
    }

    /// 技能路由意图查询（意图优先，2026-09-14）：技能正文注入跟消息语义走、不跟阶段走。
    /// 本轮用户消息为主（send 时序上尚未落盘，须显式传入）+ 最近 2 条历史用户消息
    /// 兜短消息语义；系统轮（无新消息）用最近 3 条历史；再兜底 stageQueryText。
    private func skillQueryText(userMessage: String?) -> String {
        let history = sessionStore.entries.filter { $0.role == .user }.suffix(3).map(\.content)
        var parts: [String] = []
        if let message = userMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            parts.append(message)
            parts.append(contentsOf: history.suffix(2))
        } else {
            parts.append(contentsOf: history.suffix(3))
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? stageQueryText(stage: pipeline.stage) : joined
    }

    /// 记忆校准注入（E23）：已采纳方法论 → 该用户历史使用倾向（假设态经验条目）。
    /// 同时返回命中的经验条目——注入后置待校准（随使用校准置信度）。
    private func calibrationMatches() -> (lines: [String], entries: [MemoryEntry]) {
        guard !adoptedMethodologies.isEmpty else { return ([], []) }
        let experiences = MemoryStore.allExperiences()
        var lines: [String] = []
        var matched: [MemoryEntry] = []
        for title in adoptedMethodologies {
            matched += KnowledgeCalibration.matchingExperiences(
                cardTitle: title, memories: experiences
            )
            let line = KnowledgeCalibration.calibrationContext(
                cardTitle: title, memories: experiences
            )
            if !line.isEmpty { lines.append(line) }
        }
        return (lines, matched)
    }

    /// 注入即使用：被注入的经验置待校准（确认/否定在记忆抽屉，随使用校准置信度）。
    /// 有实际标记才 reload（每条消息都会走到这里，空标记不刷盘）。
    private func markCalibrationPending(for entries: [MemoryEntry]) {
        guard !entries.isEmpty else { return }
        if MemoryStore.markExperiencesPendingCalibration(ids: entries.map(\.id)) > 0 {
            memory.reload()
        }
    }

    /// 阶段化发送入口（ConversationView 调用）。
    /// - Parameter imageFiles: 用户附图（attachments/ 文件名引用，可为空）。
    func sendMessage(_ text: String, imageFiles: [String] = []) async {
        let project = pipeline.project
        let version = pipeline.version
        // 侧栏联动：本次发送发生在哪个项目/版本 → 侧栏自动展开到该会话可见
        sidebarReveal = SidebarReveal(project: project, version: version)
        // 封板版本目录只读（黄条已提示）——静默拦截写入，回看走快照/release-notes
        guard !currentVersionReleased else { return }
        try? PMAgentStore.ensureWorkspace(project: project, version: version)

        // 竞品分析分支（Task 3.8）：意图命中即分流——后台执行（s11 借鉴），
        // 主线立即可继续对话；完成后通知注入回本会话（会话已切换则只落盘不注入）。
        if AnalysisRunner.isAnalysisIntent(text) {
            Task { await runCompetitiveAnalysis(topic: text) }
            return
        }

        let stage = pipeline.stage
        let roundLimit = PipelineEngine.clarifyRoundLimit

        switch stage {
        case .clarify:
            let rounds = pipeline.clarifyRounds
            // 澄清基底（新功能判断的上下文来源）：
            // - 增补模式（amend 标记在，从②③④回①）：当前版本表 = 修订基底，判断先行只问增量；
            // - 常规澄清：项目内最近有表的其他版本 = 背景参考（跨版本轻改并入点）。
            let amending = pipeline.isAmendingClarify
            let previousTable = amending
                ? Self.readArtifact(project: project, version: version, rel: ArtifactPath.clarification)
                : Self.readPreviousVersionClarification(project: project, version: version)
            let clarifyPrompt = await assembleSystemPrompt(stage: .clarify, userMessage: text) { injection in
                AgentPrompts.clarify(
                    rounds: rounds, limit: roundLimit,
                    previousTable: previousTable, amending: amending, injection: injection
                )
            }
            await sessionStore.send(
                text, settings: settings, stage: .clarify,
                systemPrompt: clarifyPrompt.prompt, imageFiles: imageFiles,
                skills: clarifyPrompt.skills
            ) { [weak self] reply in
                self?.handleClarifyTurn(reply)
            }

        case .structure:
            let clarification = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.clarification
            ) ?? "（要点表缺失）"
            let structurePrompt = await assembleSystemPrompt(stage: .structure, userMessage: text) { injection in
                AgentPrompts.structure(
                    clarification: clarification,
                    previousArtifacts: Self.readStructureArtifactsBundle(
                        project: project, version: version
                    ),
                    injection: injection
                )
            }
            await sessionStore.send(
                text, settings: settings, stage: .structure,
                systemPrompt: structurePrompt.prompt, maxTokens: 32768,
                imageFiles: imageFiles, skills: structurePrompt.skills
            ) { [weak self] reply in
                self?.handleAssistantReply(reply)
            }

        case .prototype:
            // E17a：未确认结构不得生成原型（闸口拦截）
            guard pipeline.canGeneratePrototype else {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "🔒 结构产物还没有确认——确认后才能生成原型。"
                    )
                )
                return
            }
            let prompt = await prototypePrompt(userMessage: text)
            await sessionStore.send(
                text, settings: settings, stage: .prototype,
                systemPrompt: prompt.prompt, maxTokens: 32768,
                imageFiles: imageFiles, skills: prompt.skills
            ) { [weak self] reply in
                self?.handleAssistantReply(reply)
            }

        case .prd:
            // E15a：未确认原型不得生成 PRD（闸口拦截）
            guard pipeline.canGeneratePRD else {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "🔒 原型还没有确认——确认后才能撰写 PRD。"
                    )
                )
                return
            }
            // 回退改走 LLM 回退块协议（handleAssistantReply 解析 artifact:backtrack）：
            // 任意自然说法都能命中，且一步到位（回退 + 诉求透传自动重生成），不再依赖固定话术正则。
            if prdOnDisk {
                if let tier = Self.tierFromText(text), tier != currentPRDTier {
                    // 档位切换作为回合注记并入重新生成的 AI 回答
                    await generatePRD(
                        tierOverride: tier,
                        note: "🎚️ 已切换 \(tier) 档，重新生成 PRD"
                    )
                } else {
                    // 对话式迭代：反馈驱动修订，重新输出完整 artifact:prd 块；
                    // 旧 PRD 全文注入作修订基底（否则模型看不到上一版，「原样保留」无从谈起）
                    let prdIterationPrompt = await prdSystemPrompt(
                        tier: currentPRDTier ?? "standard",
                        userMessage: text
                    )
                    let previousPRD = Self.readArtifact(
                        project: project, version: version, rel: ArtifactPath.prd
                    )
                    await sessionStore.send(
                        text, settings: settings, stage: .prd,
                        systemPrompt: prdIterationPrompt.prompt
                            + "\n\n当前模式：迭代——用户消息是对现有 PRD 的修改反馈；"
                            + "按反馈修订后重新输出完整 artifact:prd 块（未改动章节原样保留）。"
                            + AgentPrompts.revisionBaseSection(title: "PRD", previous: previousPRD)
                            + "\n反馈本身存在歧义时优先按上方歧义处理规则暂停确认，本轮不修订；"
                            + "若反馈针对上游产物（原型/结构）而非 PRD 本身，"
                            + "按回退请求协议输出 artifact:backtrack 块，不修订 PRD。",
                        maxTokens: 32768,
                        imageFiles: imageFiles, skills: prdIterationPrompt.skills
                    ) { [weak self] reply in
                        self?.handleAssistantReply(reply)
                    }
                }
            } else {
                // 首次进入 ④：评分卡选档 + 模板路由生成
                await generatePRD(tierOverride: nil)
            }
        }

        reloadTree()
    }

    /// assistant 回复的产物解析与落盘（②③④ 阶段）+ 横切处理（雷达/决策，全阶段）。
    private func handleAssistantReply(_ reply: DiscussionEntry) {
        processCrossCutting(reply)
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)

        // 快速通道进行中：忽略链中误发的协议块（防 backtrack 回滚状态机 / fast-forward 自触发回环）。
        if !fastForwardActive {
            // 回退请求块（回退回路）：LLM 识别新需求/要重做上游 → 回退状态机 + 诉求透传自动接续。
            // 只接受「向上游回退」的合法目标——target = 当前阶段的块属模型误判，忽略走正常产物流程。
            // ②③④ 受理（target=clarify 即增补澄清：新功能先回①判断可行性，不静默并入下游产物）。
            // mode 透传：revise（默认）= 重生成注入上一版作修订基底；redo = 不带旧版从零重画；
            // clarify 目标忽略 mode（要点表始终保留作增补基底）。
            if let request = ArtifactParser.parseBacktrack(blocks: blocks),
               let target = Self.backtrackStage(request.target),
               target != pipeline.stage,
               pipeline.stage != .clarify {
                executeBacktrack(to: target)
                if target == .clarify {
                    Task { await self.regenAfterBacktrack(
                        to: target, instruction: request.instruction, mode: "revise") }
                } else {
                    let mode = request.mode?.trimmingCharacters(in: .whitespacesAndNewlines) == "redo"
                        ? "redo" : "revise"
                    Task { await self.regenAfterBacktrack(to: target, instruction: request.instruction, mode: mode) }
                }
                return
            }

            // 快速通道块（跳步回路，②③ 单跳）：前置产物已就绪时直接确认并生成下游。
            // 目标合法但前置产物不在盘 → 说明原因后忽略，继续正常产物处理（不 return，防死轮）。
            if let request = ArtifactParser.parseFastForward(blocks: blocks),
               let target = Self.fastForwardTarget(request.target, from: pipeline.stage) {
                let preconditionMet: Bool
                switch pipeline.stage {
                case .structure where structureArtifactsOnDisk: preconditionMet = true
                case .prototype where prototypeOnDisk: preconditionMet = true
                default: preconditionMet = false
                }
                if preconditionMet {
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: "⚡ 快速通道：已按你的要求跳过逐步确认，直接\(target == .prototype ? "生成原型" : "撰写 PRD")（产物落盘，可事后修改）。"
                        )
                    )
                    Task { await self.runFastForward(to: target, instruction: request.instruction) }
                    return
                }
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚡ 快速通道暂不可用：跳步所需的当前阶段产物还没生成——先按常规流程生成，稍后再说。"
                    )
                )
            }
        }

        // PRD 截断兜底：无完整 artifact:prd 块但存在未闭合 prd 块（思考 token 吃掉
        // max_tokens 池撞线）→ 落盘截断草稿。须在 blocks 空判之前——纯截断场景
        // radar/decision 也不会有，整个回复会在这里被提前 return 掉。
        if pipeline.stage == .prd, !blocks.contains(where: { $0.name == "prd" }),
           let draft = ArtifactParser.prdTruncatedDraft(from: reply.content) {
            writePRDTruncatedDraft(draft)
        }
        guard !blocks.isEmpty else { return }
        let project = pipeline.project
        let version = pipeline.version

        do {
            switch pipeline.stage {
            case .structure:
                if ArtifactParser.structureArtifactsComplete(blocks) {
                    let structure = try ArtifactParser.writeStructureArtifacts(
                        blocks: blocks, project: project, version: version
                    )
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: pipeline.stage.rawValue,
                        detail: "结构产物落盘（功能架构图 / 核心流程图 / 模块-页面映射表）",
                        project: project, version: version
                    )
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: fastForwardActive
                                ? "📦 结构产物已生成（快速通道：自动确认，继续生成 ③ 原型）"
                                : "📦 结构产物已生成——机器初审中……",
                            fileChanges: structure.changes,
                            milestones: [MilestoneStamp(
                                kind: "stage",
                                label: "结构产物",
                                nextAction: "确认后 AI 随即生成 ③ 原型"
                            )]
                        )
                    )
                    // 快速通道中间产物跳过机器门（最终产物放行，由 runFastForward 链尾评审）
                    if !fastForwardActive || pipeline.stage == fastForwardFinalStage {
                        scheduleStageGate(.structure)
                    }
                }
            case .prototype:
                if let prototype = try ArtifactParser.writePrototypeArtifact(
                    blocks: blocks, project: project, version: version
                ) {
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: pipeline.stage.rawValue,
                        detail: "交互原型落盘（单文件 HTML）",
                        project: project, version: version
                    )
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: fastForwardActive && pipeline.stage != fastForwardFinalStage
                                ? "📦 交互原型已生成（快速通道：自动确认，继续撰写 ④ PRD）"
                                : "📦 交互原型已生成——机器初审中……",
                            fileChanges: prototype.changes,
                            milestones: [MilestoneStamp(
                                kind: "stage",
                                label: "原型",
                                nextAction: "确认后 AI 随即撰写 ④ PRD"
                            )]
                        )
                    )
                    // 快速通道中间产物跳过机器门（target=prd 时）；target=prototype 时放行
                    if !fastForwardActive || pipeline.stage == fastForwardFinalStage {
                        scheduleStageGate(.prototype)
                    }
                } else if ArtifactParser.parseIncompleteArtifact(in: reply.content)?.name == "prototype" {
                    // 截断兜底诊断：回复里有未闭合的 prototype 围栏（续写 2 轮后仍未闭合）
                    // → 块解析不到、落盘被跳过——静默会让用户以为「没生成」，留一条可行动的提示。
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: "⚠️ 原型 HTML 输出被截断（未闭合）——本次未落盘。可回复「继续出原型」重试；反复截断时建议换更轻量的模型或缩小页面范围。"
                        )
                    )
                }
            case .prd:
                if let prd = try ArtifactParser.writePRDArtifact(
                    blocks: blocks, tier: currentPRDTier ?? "standard",
                    project: project, version: version
                ) {
                    pipeline.clearPRDStale()
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: pipeline.stage.rawValue,
                        detail: "PRD 落盘（\(currentPRDTier ?? "standard") 档）",
                        project: project, version: version
                    )
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: "📦 产品需求文档已生成——数据指标与验收用例见文内。",
                            fileChanges: prd.changes,
                            milestones: [MilestoneStamp(
                                kind: "stage",
                                label: "产品需求文档",
                                nextAction: "审阅后可在项目页封板版本"
                            )]
                        )
                    )
                }
            default:
                break
            }
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(role: .system, content: "⚠️ 产物保存失败：\(error.localizedDescription)")
            )
        }
        pipeline.syncFromDisk()
        refreshGateOwner()
        // PRD 落盘成功后的 Git 快照（非闸口，但属重要产物节点）
        if pipeline.stage == .prd && prdOnDisk { snapshotProject(message: "prd: PRD 生成") }
    }

    // MARK: - 机器门（s17 独立评估器 · 两道门：Tier1 确定性 + Tier2 独立 LLM 评审）

    /// 自动重生成计数（stage rawValue → 已用次数，上限 2）；
    /// 阶段切换或用户驱动的新一轮生成时清零。
    private var gateAttempts: [String: Int] = [:]
    private var lastGateStage: PipelineRun.Stage?
    /// 机器门自动重生成进行中（区分用户驱动的新一轮生成，控制计数清零）。
    private var autoRegenActive = false
    /// 快速通道进行中（跳步串链：收束当前阶段 → 生成中间产物并确认 → 目标产物落盘）。
    /// 链中忽略 backtrack / fast-forward 协议块防自触发回环；机器门只对 fastForwardFinalStage 放行。
    private var fastForwardActive = false
    private var fastForwardFinalStage: PipelineRun.Stage?

    /// 澄清质量门（s17）：雷达无缺项且 covered 非空（防懒惰空评），且已问满 2 轮——
    /// 质量收束优先于 5 轮兜底。
    private func clarifyQualityGatePassed(reply: DiscussionEntry) -> Bool {
        guard pipeline.clarifyRounds >= 2 else { return false }
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)
        guard let radar = ArtifactParser.parseRadar(blocks: blocks) else { return false }
        return (radar.missing ?? []).isEmpty && !(radar.covered ?? []).isEmpty
    }

    /// 澄清轮回复处理（sendMessage ① 与增补澄清 regenAfterBacktrack 共用）：
    /// 横切处理 + 计轮 + 质量门/轮次耗尽收束（增补轮同语义：新功能问完自动收束更新要点表）。
    private func handleClarifyTurn(_ reply: DiscussionEntry) {
        processCrossCutting(reply)
        // 快速通道（跳步）：LLM 识别「直接出原型/PRD」→ 解析协议块，串链自动收束 + 生成。
        // 在计轮之前拦截：不计轮、不触发质量门/耗尽收束；白名单外（如 target=structure）
        // 视为模型误判，忽略块照常走澄清。
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)
        if let request = ArtifactParser.parseFastForward(blocks: blocks),
           let target = Self.fastForwardTarget(request.target, from: pipeline.stage) {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚡ 快速通道：已按你的要求跳过逐步确认，自动收束要点表、补结构映射后直接\(target == .prototype ? "生成原型" : "撰写 PRD")（所有产物落盘，均可事后修改）。"
                )
            )
            PipelineEventLog.append(
                kind: .stageAdvance, stage: pipeline.stage.rawValue,
                detail: "快速通道受理：跳步至 \(target.rawValue)",
                reason: "fast_forward", project: pipeline.project, version: pipeline.version
            )
            Task { await self.runFastForward(to: target, instruction: request.instruction) }
            return
        }
        pipeline.bumpClarifyRound()
        // 最新 assistant 回合落在本会话 → 澄清闸口归属随之迁移（两个收束路径共用）
        refreshGateOwner()
        // 质量门优先（s17 借鉴）：雷达无缺项 + 覆盖充分 → 质量收束，省空转轮次
        if clarifyQualityGatePassed(reply: reply) {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "✅ 质量门通过：漏项雷达无缺项、自检覆盖充分——澄清自动收束，生成要点表并进入 ② 结构。"
                )
            )
            Task { await confirmCurrentStage() }
            return
        }
        // 5 轮耗尽 → 强制收束（缺失项入 open_questions，不阻塞流水线）
        if pipeline.clarifyExhausted {
            Task { await confirmCurrentStage() }
        }
    }

    /// 产物落盘后启动机器门评审（异步，不阻塞聊天流）。
    private func scheduleStageGate(_ stage: PipelineRun.Stage) {
        let freshRound = !autoRegenActive
        autoRegenActive = false
        if pipeline.stage != lastGateStage {
            lastGateStage = pipeline.stage
            gateAttempts = [:]
        }
        Task { await evaluateStageGate(stage, freshRound: freshRound) }
    }

    /// 机器门主体：Tier1 确定性检查（零成本）→ Tier2 独立 LLM 评审。
    /// 不过 → 自动重生成（带修正指令，上限 2 次）→ 仍不过 → 附机器发现交人工裁决；
    /// 人工确认闸口全程可用——机器门只过滤垃圾，最终裁决权在人。
    private func evaluateStageGate(_ stage: PipelineRun.Stage, freshRound: Bool) async {
        if freshRound { gateAttempts[stage.rawValue] = 0 }
        let project = pipeline.project
        let version = pipeline.version

        // Tier 1：确定性检查（纯代码，零成本，永远开）
        var issues = Self.tier1Issues(stage: stage, project: project, version: version)
        let tier1Pass = issues.isEmpty

        // Tier 2：独立评审（Tier 1 失败不需要 LLM——机械问题直接修）
        var verdict: AgentPrompts.GateVerdict?
        if tier1Pass {
            verdict = await judgeStage(stage, project: project, version: version)
            guard let v = verdict else {
                // 评审模型不可用：降级放行（机器门是旁路，不阻塞人工门）
                PipelineEventLog.append(
                    kind: .gateEvaluated, stage: stage.rawValue,
                    detail: "Tier1 通过；Tier2 评审模型不可用，降级放行至人工确认",
                    reason: "tier2_skipped", project: project, version: version
                )
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "ℹ️ 机器初审跳过（评审模型不可用）——直接进入人工确认。"
                    )
                )
                return
            }
            if !v.pass {
                issues = v.issues ?? ["评审未通过（未给出具体问题）"]
            }
        }

        let pass = issues.isEmpty
        PipelineEventLog.append(
            kind: .gateEvaluated, stage: stage.rawValue,
            detail: pass
                ? "机器初审通过（Tier1 ✓ Tier2 ✓）：\(verdict?.verdict ?? "确定性检查全部通过")"
                : "机器初审未过（\(tier1Pass ? "Tier2" : "Tier1")）：\(issues.prefix(3).joined(separator: "；"))",
            reason: pass ? "pass" : (tier1Pass ? "tier2_fail" : "tier1_fail"),
            project: project, version: version
        )

        if pass {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "✅ 机器初审通过——\(verdict?.verdict ?? "确定性检查全部通过")。确认后进入 \(stage == .structure ? "③ 原型" : "④ PRD")。"
                )
            )
            return
        }

        let attempts = gateAttempts[stage.rawValue] ?? 0
        let issueList = issues.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        guard attempts < 2 else {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚠️ 机器初审未过（已自动修正 \(attempts) 次）：\n\(issueList)\n——已达自动修正上限，请人工裁决（确认闸口照常可用）。"
                )
            )
            return
        }
        gateAttempts[stage.rawValue] = attempts + 1
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "🔄 机器初审未过，自动修正（第 \(attempts + 1)/2 次）：\n\(issueList)"
            )
        )
        await regenForGate(stage: stage, issues: issues)
    }

    /// Tier 2 独立评审：读盘上最新产物 → stageJudge prompt → oneShot JSON 解析。
    private func judgeStage(
        _ stage: PipelineRun.Stage, project: String, version: String
    ) async -> AgentPrompts.GateVerdict? {
        let artifacts: String
        switch stage {
        case .structure:
            let arch = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.architecture
            ) ?? "（缺失）"
            let flows = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.coreFlows
            ) ?? "（缺失）"
            let map = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.modulePageMap
            ) ?? "（缺失）"
            artifacts = "### 功能架构图\n\(arch)\n\n### 核心流程图\n\(flows)\n\n### 模块-页面映射表\n\(map)"
        case .prototype:
            // HTML 评审用可见正文（WebTool.extractText）+ 上游映射表对照页面名——
            // 源码细节交给 Tier 1 机械检查，评审焦点放在页面覆盖与一致性
            let map = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.modulePageMap
            ) ?? "（缺失）"
            let html = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.prototype
            ) ?? "（缺失）"
            let visible = String(WebTool.extractText(fromHTML: html).prefix(6000))
            artifacts = "### 模块-页面映射表（上游锚点）\n\(map)\n\n### 原型可见内容（HTML 正文提取）\n\(visible)"
        default:
            return nil
        }
        return await extract(
            AgentPrompts.GateVerdict.self,
            prompt: AgentPrompts.stageJudge(stage: stage.rawValue, artifacts: artifacts)
        )
    }

    /// Tier 1 确定性检查（纯代码零成本）：产物存在性 / 结构要件 / 零外部依赖。
    /// internal：测试直调（AppModel 其余为 @MainActor，此静态函数 nonisolated 无状态）。
    nonisolated static func tier1Issues(
        stage: PipelineRun.Stage, project: String, version: String
    ) -> [String] {
        func read(_ rel: String) -> String {
            (try? String(
                contentsOf: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(rel), encoding: .utf8
            )) ?? ""
        }
        var issues: [String] = []
        switch stage {
        case .structure:
            for (rel, name) in [
                (ArtifactPath.architecture, "功能架构图"),
                (ArtifactPath.coreFlows, "核心流程图"),
                (ArtifactPath.modulePageMap, "模块-页面映射表"),
            ] {
                let text = read(rel).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    issues.append("\(name)缺失或为空")
                    continue
                }
                if rel != ArtifactPath.modulePageMap,
                   !text.contains("graph"), !text.contains("flowchart") {
                    issues.append("\(name)缺少 Mermaid graph/flowchart 声明")
                }
            }
            let map = read(ArtifactPath.modulePageMap)
            let tableRows = map.split(separator: "\n").filter { $0.hasPrefix("|") }
            if !map.isEmpty && tableRows.count < 3 {
                issues.append("模块-页面映射表表格行不足（表头 + 分隔行 + 至少 1 行数据）")
            }
        case .prototype:
            let html = read(ArtifactPath.prototype)
            if html.isEmpty {
                issues.append("原型 HTML 缺失或为空")
            } else {
                if html.utf8.count < 2048 {
                    issues.append("原型 HTML 过小（< 2KB），疑似空壳")
                }
                // 外部资源引用检查（script/link/img 的 http(s) src/href）
                if let regex = try? NSRegularExpression(
                    pattern: #"(?:<script[^>]+src|<link[^>]+href|<img[^>]+src)\s*=\s*["']https?://"#,
                    options: [.caseInsensitive]
                ) {
                    let range = NSRange(html.startIndex..<html.endIndex, in: html)
                    if regex.firstMatch(in: html, options: [], range: range) != nil {
                        issues.append("原型含外部资源引用（CDN/外链），违反零外部依赖硬约束")
                    }
                }
            }
        default:
            break
        }
        return issues
    }

    /// 机器门打回：带修正指令自动重生成（修正指令并入 AI 回合，不占用户气泡；
    /// 新产物落盘后会再次过门，直至通过或达上限）。
    private func regenForGate(stage: PipelineRun.Stage, issues: [String]) async {
        autoRegenActive = true
        let correction = issues.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        switch stage {
        case .structure:
            let clarification = Self.readArtifact(
                project: pipeline.project, version: pipeline.version,
                rel: ArtifactPath.clarification
            ) ?? "（缺失）"
            let systemPrompt = await assembleSystemPrompt(stage: .structure) { injection in
                AgentPrompts.structure(clarification: clarification, injection: injection)
            }
            await sessionStore.sendSystemTurn(
                note: nil,
                userPrompt: "机器初审发现以下问题，请修正后重新输出全部三项结构产物（完整产物块）：\n\(correction)"
                    + gateInviteSuffix(for: .structure),
                settings: settings, stage: .structure,
                systemPrompt: systemPrompt.prompt, maxTokens: 32768,
                skills: systemPrompt.skills
            ) { [weak self] reply in
                self?.handleAssistantReply(reply)
            }
        case .prototype:
            let systemPrompt = await prototypePrompt()
            await sessionStore.sendSystemTurn(
                note: nil,
                userPrompt: "机器初审发现以下问题，请修正后重新输出完整原型产物块（单文件 HTML）：\n\(correction)"
                    + gateInviteSuffix(for: .prototype),
                settings: settings, stage: .prototype,
                systemPrompt: systemPrompt.prompt, maxTokens: 32768,
                skills: systemPrompt.skills
            ) { [weak self] reply in
                self?.handleAssistantReply(reply)
            }
        default:
            break
        }
    }

    // MARK: - 横切处理（M3：漏项雷达 / 决策 WHY / 💀 风险登记）

    /// 每轮 assistant 回复统一处理：radar 落盘 + 失效告警 + fatal 登记风险、
    /// decision 落 decisions.jsonl。任何一步失败不阻塞主流程。
    private func processCrossCutting(_ reply: DiscussionEntry) {
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)
        guard !blocks.isEmpty else { return }
        let project = pipeline.project
        let version = pipeline.version
        let stageKey = pipeline.stage.rawValue

        // 漏项雷达：自评摘要落盘 + 连续 3 轮零修正告警（E16）+ 💀 登记（E16a）
        if let radar = ArtifactParser.parseRadar(blocks: blocks) {
            try? ArtifactParser.writeSelfReview(
                radar, stage: stageKey, project: project, version: version
            )
            if pipeline.recordRadar(fixedCount: radar.fixed?.count ?? 0) {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚠️ 自评审失效告警：连续 3 轮零修正——自评审可能流于形式，请人工核查本阶段产物。"
                    )
                )
            }
            registerFatalRisks(radar.fatal ?? [], stageKey: stageKey)

            // 里程碑：雷达入账行（发现数 = 缺项 + 修正 + 风险；明细进次行补注）
            let missing = radar.missing?.count ?? 0
            let fixed = radar.fixed?.count ?? 0
            let fatal = radar.fatal?.count ?? 0
            let issueCount = missing + fixed + fatal
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: issueCount > 0
                        ? "🔍 自评审发现 \(issueCount) 项——风险已入右栏「风险」台账。"
                        : "🔍 自评审零缺项——自评覆盖充分。",
                    milestones: [MilestoneStamp(
                        kind: "radar",
                        count: issueCount,
                        detail: issueCount > 0
                            ? "缺项 \(missing) · 修正 \(fixed) · 风险 \(fatal)"
                            : nil
                    )]
                )
            )
        }

        // 决策 WHY：三判据关键决策 append-only 落盘（E14）
        let drafts = ArtifactParser.parseDecisions(blocks: blocks)
        if !drafts.isEmpty {
            let records = drafts.map { $0.record(version: version) }
            do {
                try ArtifactParser.writeDecisions(records, project: project, version: version)
                let pending = records.filter(\.toBeVerified).count
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "📝 决策记录 +\(records.count) 条——右栏「决策日志」可查。",
                        milestones: [MilestoneStamp(
                            kind: "decision",
                            count: records.count,
                            detail: pending > 0 ? "待验证 \(pending) 条，日志中已标出" : nil
                        )]
                    )
                )
            } catch {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system, content: "⚠️ 决策记录保存失败：\(error.localizedDescription)"
                    )
                )
            }
        }
    }

    /// 💀 风险登记：radar fatal → risks.jsonl（带影响与建议方案；登记后发一条轻系统行，
    /// 台账承载逐条决定——采纳 / 接受；登记不设上限，封板兜底统一收口）。
    private func registerFatalRisks(
        _ fatals: [ArtifactParser.RadarReport.Fatal], stageKey: String
    ) {
        guard !fatals.isEmpty else { return }
        let version = pipeline.version
        let stage = RiskRecord.Stage(rawValue: stageKey) ?? .prd
        var registered = 0
        for fatal in fatals {
            let record = RiskRecord(
                version: version, stage: stage,
                hypothesis: fatal.hypothesis,
                impact: fatal.impact,
                plan: fatal.plan,
                triggerSignal: fatal.signal,
                originRef: "自评审（\(stageKey)）"
            )
            do {
                try risks.append(record)
                registered += 1
            } catch {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system, content: "⚠️ 风险登记失败：\(error.localizedDescription)"
                    )
                )
            }
        }
        guard registered > 0 else { return }
        // 广播刷新（右栏风险台账实时跟随自评审登记）
        NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "⚠️ 自评审新增 \(registered) 个风险（各带应对方案）——右栏「风险」台账逐条决定：采纳方案 / 接受风险。",
                milestones: [MilestoneStamp(
                    kind: "risk",
                    count: registered,
                    detail: "待处理 \(risks.pendingRisks.count) 条 · 采纳 ≠ 解除，方案落地验证通过后才算数"
                )]
            )
        )
    }

    /// ③ 阶段 system prompt（读已确认结构产物 + 既有原型作迭代基底 + Context Builder 组装）。
    /// - Parameter userMessage: 本轮用户消息（技能意图路由；系统轮闸口生成传 nil）。
    private func prototypePrompt(userMessage: String? = nil) async -> (prompt: String, skills: [String]) {
        let project = pipeline.project
        let version = pipeline.version
        let map = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.modulePageMap
        ) ?? "（缺失）"
        let flows = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.coreFlows
        ) ?? "（缺失）"
        let previousPrototype = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.prototype
        )
        return await assembleSystemPrompt(stage: .prototype, userMessage: userMessage) { injection in
            AgentPrompts.prototype(
                modulePageMap: map, coreFlows: flows,
                previousPrototype: previousPrototype, injection: injection
            )
        }
    }

    // MARK: - 确认闸口推进（ConfirmDock ① 触发）

    /// 闸口归属会话（当前阶段闸口锚点条目所在的会话 id；nil = 版本内未定位到）。
    /// 询问卡（确认坞 / 回退坞）只在归属会话渲染——同版本的其他会话不受打扰。
    /// 锚点从版本 discussions.jsonl 推导（文件是事实源，重启可重推导）：
    /// ① 取最新 assistant 回合；②③④ 取最新 stage 里程碑（📦 产物落盘行）。
    @Published private(set) var gateOwnerSessionId: String?

    /// 当前打开会话是否为闸口归属会话（询问卡渲染前置条件）。
    var isGateOwnerSession: Bool {
        !sessionStore.sessionId.isEmpty && gateOwnerSessionId == sessionStore.sessionId
    }

    /// 重推闸口归属会话（上下文切换 / 回合落盘 / 阶段推进 / 会话删除后调用）。
    private func refreshGateOwner() {
        gateOwnerSessionId = Self.gateOwnerSession(
            project: pipeline.project, version: pipeline.version, stage: pipeline.stage
        )
    }

    /// 当前阶段闸口锚点所在会话（从版本 discussions.jsonl 推导，append 序即时间序）。
    nonisolated static func gateOwnerSession(
        project: String, version: String, stage: PipelineRun.Stage
    ) -> String? {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
        let all = PMAgentStore.readLines(DiscussionEntry.self, from: url)
        switch stage {
        case .clarify:
            // ① 无产物落盘行：最新 assistant 回合所在会话即澄清对话
            return all.last(where: { $0.role == .assistant })?.sessionId
        case .structure, .prototype, .prd:
            let label: String
            switch stage {
            case .structure: label = "结构产物"
            case .prototype: label = "原型"
            default: label = "产品需求文档"
            }
            return all.last(where: { entry in
                entry.milestones?.contains {
                    $0.kind == "stage" && $0.label == label
                } == true
            })?.sessionId
        }
    }

    /// 确认坞三档状态（UI 渲染依据）。
    enum ConfirmTarget: Hashable {
        case clarify          // ① 要点表
        case structure        // ② 结构产物
        case prototype        // ③ 原型

        var title: String {
            switch self {
            case .clarify: "确认澄清要点表"
            case .structure: "确认结构产物"
            case .prototype: "确认原型"
            }
        }

        var nextStage: String {
            switch self {
            case .clarify: "② 结构设计"
            case .structure: "③ 原型"
            case .prototype: "④ PRD"
            }
        }

        /// 产物短名（时间线留痕 / 邀请句共用）。
        var name: String {
            switch self {
            case .clarify: "澄清要点表"
            case .structure: "结构产物"
            case .prototype: "原型"
            }
        }
    }

    /// 当前是否停在确认闸口（产物就绪 + 阶段未推进 + 当前会话即闸口归属会话）。
    var confirmTarget: ConfirmTarget? {
        guard isGateOwnerSession else { return nil }
        switch pipeline.stage {
        case .clarify:
            return pipeline.clarifyRounds >= 1 ? .clarify : nil
        case .structure:
            return structureArtifactsOnDisk ? .structure : nil
        case .prototype:
            return prototypeOnDisk ? .prototype : nil
        case .prd:
            return nil
        }
    }

    private var structureArtifactsOnDisk: Bool {
        let dir = PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
        let fm = FileManager.default
        return [ArtifactPath.architecture, ArtifactPath.coreFlows, ArtifactPath.modulePageMap]
            .allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private var prototypeOnDisk: Bool {
        FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
                .appendingPathComponent(ArtifactPath.prototype).path
        )
    }

    // MARK: 确认坞「稍后再说」记忆（每阶段弹一次：推迟后本阶段永久静默，design.md §6.1）

    /// 会话 → 已静默闸口集。静默 = 本阶段不再自动弹坞（修订落盘也不弹），
    /// 推进改由用户发起（自由作答「进入下一阶段」/ 摘要条兜底行）；
    /// 修订轮改为在 AI 回复末尾融一句推进邀请（gateInviteSuffix）。
    /// 确认推进后清除（回退重做到该阶段视为新一轮提醒）；按会话键控，
    /// 同版本其他会话互不影响，会话删除即随会话消失。
    @Published private(set) var deferredConfirmGates: [String: Set<ConfirmTarget>] = [:]

    /// 「稍后再说」/「继续修改」：本阶段进入永久静默（每阶段只弹一次）。
    /// 同时在时间线落一条安静留痕——静默反馈 + 推进指引融进对话
    /// （system 行不回灌模型、不弹卡，符合「提示进对话」语义）。
    func deferConfirmGate(_ target: ConfirmTarget) {
        deferredConfirmGates[sessionStore.sessionId, default: []].insert(target)
        try? sessionStore.append(sessionStore.makeEntry(
            role: .system,
            content: "💬 已收起确认——\(target.name)待确认期间不再弹出；想推进随时说「进入下一阶段」。"
        ))
    }

    /// 闸口是否已被本会话静默（静默阶段不挂载确认坞）。
    func isConfirmGateDeferred(_ target: ConfirmTarget) -> Bool {
        deferredConfirmGates[sessionStore.sessionId]?.contains(target) == true
    }

    /// 确认推进后清除该阶段静默：回退重做回到此阶段时，视为新一轮提醒重新弹坞。
    private func clearDeferredConfirmGate(_ target: ConfirmTarget) {
        for key in deferredConfirmGates.keys {
            deferredConfirmGates[key]?.remove(target)
        }
    }

    /// 静默中的修订生成轮：userPrompt 尾部追加推进邀请指令——AI 回复最末尾
    /// 融一句自然话（用户语义「提示融进 AI 回答，不再弹卡」）。
    /// 未静默轮次返回空串：坞本身就是邀请，保持单一声源，避免双份文案。
    private func gateInviteSuffix(for target: ConfirmTarget) -> String {
        guard isConfirmGateDeferred(target) else { return "" }
        return "\n\n（补充输出要求：全部产物输出完成后，在回复的最末尾另起一行，"
            + "用一句自然、不啰嗦的中文提示用户——「\(target.name)已更新落盘，没问题的话回复「进入下一阶段」，"
            + "我随即进入\(target.nextStage)；还要调整直接说。」。只此一句，不要展开、不要重复。）"
    }

    /// 阶段推进确认（ConfirmDock 提交 / 自由作答「进入下一个阶段」）。
    func confirmCurrentStage() async {
        guard let target = confirmTarget else { return }
        switch target {
        case .clarify: await confirmClarify()
        case .structure: await confirmStructure()
        case .prototype: await confirmPrototype()
        }
        // 确认推进后清该阶段静默：回退重做回到此阶段时视为新一轮提醒（重新弹坞一次）
        clearDeferredConfirmGate(target)
        reloadTree()
        refreshGateOwner()
    }

    /// ①→②：要点表生成 + 记忆沉淀 + 结构产物生成。
    /// 增补澄清收束（amend 标记在）时：以既有表为基底合并更新（仅改波及字段），
    /// 结构重生成注入旧结构产物作增量修订基底（新功能落入对应模块，不盲重画）。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规确认传 nil。
    private func confirmClarify(directive: String? = nil) async {
        let project = pipeline.project
        let version = pipeline.version
        let amending = pipeline.isAmendingClarify
        let fastTrackNote = directive.map { "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。" + $0 }

        // 1. 澄清要点表（JSON Schema 约束抽取）；增补轮注入既有表作合并基底。
        //    maxTokens 8192：思考型模型 reasoning 与正文共用输出池，transcript 长时
        //    2048 会在思考阶段撞线（正文为空抛空流）——咽喉路径预算给足。
        //    失败自动重试 1 次：空流/截断多为服务端抖动，一次重试可救回大半。
        let transcript = sessionStore.entries
            .filter { $0.role != .system }
            .map { "\($0.role == .user ? "用户" : "助手")：\($0.content)" }
            .joined(separator: "\n")
        let previousTable = amending
            ? Self.readArtifact(project: project, version: version, rel: ArtifactPath.clarification)
            : nil
        let tablePrompt = AgentPrompts.clarificationTable(
            transcript: transcript, previous: previousTable
        )
        var tableResult = await extractWithReason(
            ClarificationTable.self, prompt: tablePrompt, maxTokens: 8192
        )
        if tableResult.value == nil {
            tableResult = await extractWithReason(
                ClarificationTable.self, prompt: tablePrompt, maxTokens: 8192
            )
        }
        guard let table = tableResult.value else {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚠️ 澄清要点表生成失败（已自动重试 1 次仍未成功）："
                        + (tableResult.failureReason ?? "未知原因")
                        + "——稍后回复「进入下一阶段」重试确认。"
                )
            )
            return
        }

        do {
            try PMAgentStore.writeVerified(
                table.markdown,
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(ArtifactPath.clarification)
            )
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 澄清要点表保存失败：\(error.localizedDescription)"
                )
            )
            return
        }

        // 2. 记忆沉淀（结论/约束/否决项，覆盖语义；记忆行 UI 不渲染，默默记录）
        await sedimentMemory(transcript: transcript)

        // 3. 推进 + 生成回合（阶段推进信息作为回合注记并入 AI 回答顶部）；
        //    增补场景结构重生成带旧产物基底——新功能增量落入，未波及部分原样保留
        pipeline.advanceFromClarify()
        snapshotProject(message: amending ? "clarify: 增补澄清收束，要点表更新" : "clarify: 澄清要点表确认")
        gateRiskNudge(fromStage: .clarify, nextStageName: "结构")
        let previousArtifacts = amending
            ? Self.readStructureArtifactsBundle(project: project, version: version)
            : nil
        let structurePrompt = await assembleSystemPrompt(stage: .structure) { injection in
            AgentPrompts.structure(
                clarification: table.markdown,
                previousArtifacts: previousArtifacts, injection: injection
            )
        }
        await sessionStore.sendSystemTurn(
            note: amending
                ? "✅ 要点表已按新功能诉求更新——进入 ② 结构（增量修订）"
                : "✅ 澄清要点表已确认——进入 ② 结构设计",
            userPrompt: amending
                ? "澄清要点表已按新功能诉求更新。请在上一版结构产物基础上增量修订：新功能落入对应模块/页面，未波及的部分原样保留，重新输出全部结构产物（完整产物块）。"
                    + gateInviteSuffix(for: .structure)
                    + "\(fastTrackNote.map { "\n\($0)" } ?? "")"
                : "请基于已确认的澄清要点表生成结构产物（功能架构图、核心流程图、模块-页面映射表三项必出）。\(fastTrackNote.map { "\n\($0)" } ?? "")",
            settings: settings, stage: .structure,
            systemPrompt: structurePrompt.prompt,
            maxTokens: 32768, skills: structurePrompt.skills
        ) { [weak self] reply in
            self?.handleAssistantReply(reply)
        }
    }

    /// ②→③：确认闸口 + 原型生成。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规确认传 nil。
    private func confirmStructure(directive: String? = nil) async {
        do {
            try pipeline.confirmStructure()
            snapshotProject(message: "structure: 结构产物确认")
            gateRiskNudge(fromStage: .structure, nextStageName: "原型")
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 确认记录写入失败：\(error.localizedDescription)"
                )
            )
            return
        }
        let prototypeGenerationPrompt = await prototypePrompt()
        let fastTrackNote = directive.map { "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。" + $0 }
        await sessionStore.sendSystemTurn(
            note: "✅ 结构产物已确认——进入 ③ 原型",
            userPrompt: "请基于模块-页面映射表生成单文件 HTML 原型（P0 页面 3-5 个，页面跳转按核心流程图连通）。\(fastTrackNote.map { "\n\($0)" } ?? "")",
            settings: settings, stage: .prototype,
            systemPrompt: prototypeGenerationPrompt.prompt,
            maxTokens: 32768, skills: prototypeGenerationPrompt.skills
        ) { [weak self] reply in
            self?.handleAssistantReply(reply)
        }
    }

    /// ③→④：确认闸口 + 评分卡选档 + PRD 生成（Task 3.4）。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规确认传 nil。
    private func confirmPrototype(directive: String? = nil) async {
        do {
            try pipeline.confirmPrototype()
            snapshotProject(message: "prototype: 原型确认")
            gateRiskNudge(fromStage: .prototype, nextStageName: "PRD")
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 确认记录写入失败：\(error.localizedDescription)"
                )
            )
            return
        }
        // 阶段推进信息作为回合注记并入 PRD 生成回合的 AI 回答顶部
        // 原型重做后旧 PRD 过期 → 结算 prd_stale 💀（风险预测「PRD 会过期」命中）
        if pipeline.prdStale {
            settleRisks(.prdStale, note: "原型重新确认，旧 PRD 相对新原型过期")
        }
        await generatePRD(
            tierOverride: nil,
            note: "✅ 原型已确认——进入 ④ PRD 撰写",
            directive: directive
        )
    }

    // MARK: - ④ PRD Agent（Task 3.4：评分卡选档 + 三档模板路由 + 双重基准）

    /// PRD 是否已落盘。
    private var prdOnDisk: Bool {
        FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
                .appendingPathComponent(ArtifactPath.prd).path
        )
    }

    /// PRD 截断草稿落盘：04-prd/PRD截断草稿.md（write-then-verify）。
    /// 刻意不写 PRD文档.md——不触发 prdOnDisk / 确认闸口 / Git 快照；
    /// 内容加截断标注头，附 ⚠️ 系统行提示恢复方式。
    private func writePRDTruncatedDraft(_ body: String) {
        let banner = """
        > ⚠️ **截断草稿**：模型输出超长被截断，本文档**不完整**（未通过落盘校验，不进入确认闸口）。
        > 恢复方式：对话中回复「重新生成 PRD」重试（已自动续写仍未写完）。

        """
        do {
            try PMAgentStore.writeVerified(
                banner + body,
                to: PMAgentStore.versionURL(
                    project: pipeline.project, version: pipeline.version
                ).appendingPathComponent(ArtifactPath.prdTruncatedDraft)
            )
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚠️ PRD 输出超长被截断——已存截断草稿（\(ArtifactPath.prdTruncatedDraft)，不完整）。"
                        + "可回复「重新生成 PRD」重试。"
                )
            )
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚠️ 截断草稿保存失败：\(error.localizedDescription)"
                )
            )
        }
    }

    /// 当前档位（评分卡落盘值；缺失 → nil，调用侧回退 standard）。
    private var currentPRDTier: String? {
        guard let data = try? Data(
            contentsOf: PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
                .appendingPathComponent("04-prd/score-card.json")
        ), let card = try? JSONDecoder().decode(
            ArtifactParser.ScoreCard.self, from: data
        ) else { return nil }
        return card.validTier
    }

    /// 生成 PRD：评分卡选档（tierOverride 一键切换时跳过）→ 模板路由 → artifact:prd 落盘。
    /// note：回合注记（确认推进/档位切换），与 AI 回答合并展示；nil → 默认撰写提示。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规生成传 nil。
    private func generatePRD(tierOverride: String?, note: String? = nil, directive: String? = nil) async {
        let tier: String
        if let tierOverride {
            tier = tierOverride
        } else if let scored = await resolveScoreCard(), let valid = scored.card.validTier {
            tier = valid
            if scored.isNew {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        // 行文本只留事实载荷（审计用）；句子由 UI 里程碑清单组装（方案 B）
                        content: "📊 PRD 评分卡 → \(valid) 档",
                        milestones: [MilestoneStamp(
                            kind: "score",
                            label: valid,
                            dims: [
                                MilestoneDim(name: "复杂度", score: scored.card.complexity.score,
                                             reason: scored.card.complexity.reason),
                                MilestoneDim(name: "风险", score: scored.card.risk.score,
                                             reason: scored.card.risk.reason),
                                MilestoneDim(name: "范围", score: scored.card.scope.score,
                                             reason: scored.card.scope.reason),
                            ]
                        )]
                    )
                )
            }
        } else {
            tier = "standard"  // 评分卡失败兜底（不阻塞流水线）
        }
        let prdGenerationPrompt = await prdSystemPrompt(tier: tier)
        let fastTrackNote = directive.map { "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。" + $0 }
        await sessionStore.sendSystemTurn(
            note: note ?? "📝 开始撰写 \(tier) 档 PRD",
            userPrompt: "请按 \(tier) 档模板撰写 PRD（双重基准：功能需求与模块-页面映射表及原型页面一一对应）。\(fastTrackNote.map { "\n\($0)" } ?? "")",
            settings: settings, stage: .prd,
            systemPrompt: prdGenerationPrompt.prompt,
            maxTokens: 32768, skills: prdGenerationPrompt.skills
        ) { [weak self] reply in
            self?.handleAssistantReply(reply)
        }
    }

    /// 三维度评分选档（oneShot；锚定上游已确认产物的确定性数字）+ 落盘 score-card.json。
    /// 整个 PRD 流程只出一次卡：score-card.json 已在盘（中断重试 / 多次重新生成 / 重开 App）
    /// 直接复用返回 isNew=false——不重跑模型评分、不重复追加评分卡系统行；
    /// 档位仍可「用 lean/standard/full 档」一键切换覆盖。
    private func resolveScoreCard() async -> (card: ArtifactParser.ScoreCard, isNew: Bool)? {
        let project = pipeline.project
        let version = pipeline.version
        let cardURL = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("04-prd/score-card.json")
        if let data = try? Data(contentsOf: cardURL),
           let card = try? JSONDecoder().decode(ArtifactParser.ScoreCard.self, from: data) {
            return (card, false)
        }
        guard let clarification = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.clarification
        ) else { return nil }
        let map = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.modulePageMap
        ) ?? ""
        let rows = Self.mapRows(in: map)
        guard let card = await extract(
            ArtifactParser.ScoreCard.self,
            prompt: AgentPrompts.prdScoreCard(
                clarification: clarification,
                moduleCount: rows.modules,
                pageCount: rows.pages.count,
                constraintCount: Self.countConstraints(in: clarification)
            )
        ) else { return nil }
        // 落盘（write-then-verify；失败不阻塞，仅失去一键切换记忆与去重凭据）
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(card) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: cardURL
            )
        }
        return (card, true)
    }

    /// ④ system prompt（读已确认上游产物 + 竞品调研注记 + Context Builder 组装）。
    /// - Parameter userMessage: 本轮用户消息（技能意图路由；系统轮闸口生成传 nil）。
    private func prdSystemPrompt(tier: String, userMessage: String? = nil) async -> (prompt: String, skills: [String]) {
        let project = pipeline.project
        let version = pipeline.version
        let clarification = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.clarification
        ) ?? "（缺失）"
        let map = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.modulePageMap
        ) ?? "（缺失）"
        let analysis = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.competitiveAnalysis
        ) ?? ""
        return await assembleSystemPrompt(stage: .prd, userMessage: userMessage) { injection in
            AgentPrompts.prd(
                tier: tier,
                clarification: clarification,
                modulePageMap: map,
                prototypePages: Self.mapRows(in: map).pages,
                analysisNotes: analysis,
                injection: Self.openRisksInjection(self.risks.activeRisks) + injection
            )
        }
    }

    /// 未闭合风险注入（封板兜底：PRD「已知风险与未决事项」章节的数据源）。
    /// 空列表返回空串（不产生注入段）；nonisolated 供测试直测。
    nonisolated static func openRisksInjection(_ records: [RiskRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let lines = records.map { record -> String in
            var line = "- \(record.hypothesis)"
            if let plan = record.plan, !plan.isEmpty { line += " → 应对方案：\(plan)" }
            if record.status == .mitigating { line += "（方案已挂，验证中）" }
            return line
        }
        return "## 已登记风险（写入「已知风险与未决事项」章节，逐条列出）\n"
            + lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 回退回路（Task 3.5：E8 / 过期传播 + 💀 事件结算；LLM 回退块 + UI 快捷入口共用）

    /// 回退执行（LLM 回退块 / UI 快捷按钮触发）：状态机回退 + 💀 事件结算 +
    /// 分级过期传播。接续动作由 regenAfterBacktrack 完成（structure/prototype 自动重做；
    /// clarify 转入对话式增补澄清，AI 先判断新功能可行性再提问）。
    private func executeBacktrack(to target: PipelineRun.Stage) {
        let source = pipeline.stage
        switch target {
        case .clarify:
            pipeline.invalidateClarify()
            // 新需求回澄清不结算风险——不是「发现缺口」，是需求范围演进
        case .structure:
            pipeline.invalidateStructure()
            settleRisks(
                .structureRegen,
                note: source == .prd ? "用户在④发现结构缺口，回退重做结构" : "用户在③发现结构缺口，回退重做结构"
            )
        default:
            pipeline.invalidatePrototype()
            settleRisks(.prototypeRegen, note: "用户在④发现原型缺口，回退重做原型")
        }
        let targetName: String
        let tail: String
        switch target {
        case .clarify:
            targetName = "① 澄清（增补模式：要点表保留作基底）"
            tail = "——AI 将先判断新功能能不能做、适不适合做，再围绕缺口提问。"
        case .structure:
            targetName = source == .prd
                ? "② 结构（原型与 PRD 一并标记过期：全部下游失效）"
                : "② 结构（原型一并标记过期）"
            tail = "——马上重做。"
        default:
            targetName = "③ 原型（PRD 标记过期：局部）"
            tail = "——马上重做。"
        }
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "🔄 已回到 \(targetName)\(tail)"
            )
        )
        reloadTree()
        refreshGateOwner()
    }

    /// 回退后自动接续（诉求透传 + 迭代基底）：目标阶段 system prompt 照常走 Context Builder 组装，
    /// 用户诉求作为合成指令进模型上下文（与机器门自动修正同一 sendSystemTurn 模式）。
    /// mode：revise = 注入上一版产物作修订基底（只改用户说的部分，其余原样保留）；
    ///       redo = 推翻重来，不带旧版从零重画；clarify 目标忽略 mode（表始终保留作增补基底），
    ///       且不产产物——转入对话式增补澄清（AI 先判断再提问，用户作答推进，闸口语义不变）。
    /// 生成结果照常落盘 + 走确认闸口（自动化的是「重做」，不越过任何人工门）。
    private func regenAfterBacktrack(
        to target: PipelineRun.Stage, instruction: String?, mode: String
    ) async {
        let directive = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let revise = mode != "redo"
        switch target {
        case .clarify:
            // 增补澄清：既有表注入作基底，AI 先给可行性判断再围绕缺口提问（对话式，不生成产物块）
            let project = pipeline.project
            let version = pipeline.version
            let rounds = pipeline.clarifyRounds
            let previousTable = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.clarification
            )
            let systemPrompt = await assembleSystemPrompt(
                stage: .clarify, userMessage: directive.isEmpty ? nil : directive
            ) { injection in
                AgentPrompts.clarify(
                    rounds: rounds, limit: PipelineEngine.clarifyRoundLimit,
                    previousTable: previousTable, amending: true, injection: injection
                )
            }
            let userPrompt = directive.isEmpty
                ? "用户提出了新的产品诉求。请按增补澄清规则处理：先基于既有要点表判断可行性与优先级，再围绕新功能的关键缺口提问（每次一个问题）。"
                : "用户提出新诉求：\(directive)。请按增补澄清规则处理：先基于既有要点表判断这个诉求能不能做、适不适合做（给出依据与优先级建议），再围绕新功能的关键缺口提问（每次一个问题）。"
            await sessionStore.sendSystemTurn(
                note: "🔄 回到 ① 澄清——新功能先判断，再补问缺口",
                userPrompt: userPrompt,
                settings: settings, stage: .clarify,
                systemPrompt: systemPrompt.prompt,
                maxTokens: 16384, skills: systemPrompt.skills
            ) { [weak self] reply in
                self?.handleClarifyTurn(reply)
            }
        case .structure:
            let project = pipeline.project
            let version = pipeline.version
            let clarification = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.clarification
            ) ?? "（缺失）"
            let previousArtifacts = revise
                ? Self.readStructureArtifactsBundle(project: project, version: version)
                : nil
            let systemPrompt = await assembleSystemPrompt(
                stage: .structure, userMessage: directive.isEmpty ? nil : directive
            ) { injection in
                AgentPrompts.structure(
                    clarification: clarification,
                    previousArtifacts: previousArtifacts,
                    injection: injection
                )
            }
            await sessionStore.sendSystemTurn(
                note: revise ? "🏗️ 按你的要求重做结构" : "🏗️ 推翻重来：从零重做结构",
                userPrompt: {
                    switch (revise, directive.isEmpty) {
                    case (true, false):
                        return "用户要求修改结构，修改要求：\(directive)。"
                            + "请在上一版结构产物基础上修订：仅做修改要求的变化，其余原样保留，"
                            + "重新输出全部三项结构产物（完整产物块）。"
                    case (true, true):
                        return "用户要求重做结构：请重新审视上一版并输出全部三项结构产物（完整产物块）。"
                    case (false, _):
                        return directive.isEmpty
                            ? "用户要求完全推翻重做结构：不要参考上一版，重新设计并输出全部三项结构产物（完整产物块）。"
                            : "用户要求完全推翻重做结构，方向：\(directive)。"
                                + "不要参考上一版，重新设计并输出全部三项结构产物（完整产物块）。"
                    }
                }() + gateInviteSuffix(for: .structure),
                settings: settings, stage: .structure,
                systemPrompt: systemPrompt.prompt, maxTokens: 32768,
                skills: systemPrompt.skills
            ) { [weak self] reply in
                self?.handleAssistantReply(reply)
            }
        case .prototype:
            guard pipeline.canGeneratePrototype else { return }
            let project = pipeline.project
            let version = pipeline.version
            let previousPrototype = revise
                ? Self.readArtifact(
                    project: project, version: version, rel: ArtifactPath.prototype
                )
                : nil
            let map = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.modulePageMap
            ) ?? "（缺失）"
            let flows = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.coreFlows
            ) ?? "（缺失）"
            let prompt = await assembleSystemPrompt(
                stage: .prototype, userMessage: directive.isEmpty ? nil : directive
            ) { injection in
                AgentPrompts.prototype(
                    modulePageMap: map, coreFlows: flows,
                    previousPrototype: previousPrototype, injection: injection
                )
            }
            await sessionStore.sendSystemTurn(
                note: revise ? "🎨 按你的要求重做原型" : "🎨 推翻重来：从零重做原型",
                userPrompt: {
                    switch (revise, directive.isEmpty) {
                    case (true, false):
                        return "用户要求修改原型，修改要求：\(directive)。"
                            + "请在上一版原型基础上修订：仅做修改要求的变化，其余（页面、布局、文案、风格）原样保留，"
                            + "重新输出完整原型产物块（单文件 HTML）。"
                    case (true, true):
                        return "用户要求重做原型：请重新审视上一版并输出完整原型产物块（单文件 HTML）。"
                    case (false, _):
                        return directive.isEmpty
                            ? "用户要求完全推翻重做原型：不要参考上一版，重新设计并输出完整原型产物块（单文件 HTML）。"
                            : "用户要求完全推翻重做原型，方向：\(directive)。"
                                + "不要参考上一版，重新设计并输出完整原型产物块（单文件 HTML）。"
                    }
                }() + gateInviteSuffix(for: .prototype),
                settings: settings, stage: .prototype,
                systemPrompt: prompt.prompt, maxTokens: 32768,
                skills: prompt.skills
            ) { [weak self] reply in
                self?.handleAssistantReply(reply)
            }
        default:
            break
        }
    }

    /// 回退请求块目标字段 → 阶段（白名单，其余忽略防模型误判）。
    /// clarify = 新功能/范围变化回①做增补澄清（要点表保留作基底）。
    static func backtrackStage(_ raw: String) -> PipelineRun.Stage? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "clarify": return .clarify
        case "structure": return .structure
        case "prototype": return .prototype
        default: return nil
        }
    }

    /// 快速通道块目标字段 → 阶段（白名单 + 严格下游校验，其余忽略防模型误判）。
    /// 只认 prototype / prd——structure 是中间态，跳到中间态没有意义（那只是少点一次确认）。
    static func fastForwardTarget(
        _ raw: String, from current: PipelineRun.Stage
    ) -> PipelineRun.Stage? {
        let target: PipelineRun.Stage
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "prototype": target = .prototype
        case "prd": target = .prd
        default: return nil
        }
        let order: [PipelineRun.Stage] = [.clarify, .structure, .prototype, .prd]
        guard let from = order.firstIndex(of: current),
              let to = order.firstIndex(of: target), to > from else { return nil }
        return target
    }

    /// 快速通道执行（LLM fast-forward 块受理后）：从当前阶段一路自动「生成 + 确认」到
    /// target 产物落盘，跳过中间确认坞与中间产物机器门；最终产物照常走机器门 + 确认坞。
    /// 产物全程落盘，任一步失败即中止（系统行说明中止点），磁盘状态可从常规确认坞恢复。
    private func runFastForward(to target: PipelineRun.Stage, instruction: String?) async {
        fastForwardActive = true
        fastForwardFinalStage = target
        defer {
            fastForwardActive = false
            fastForwardFinalStage = nil
        }
        let directive = "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。"
            + (instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")

        // ① 收束：要点表 + 记忆沉淀 + 结构生成（sendSystemTurn await 到落盘，串行安全）
        if pipeline.stage == .clarify {
            await confirmClarify(directive: directive)
            guard structureArtifactsOnDisk else {
                // 恢复入口兜底：该阶段确认坞若被「稍后再说」静默，中止后将永远无处确认——
                // 清静默让坞重新弹出（确认本身就是重试），系统行不再只留一句干指引。
                clearDeferredConfirmGate(.clarify)
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚡ 快速通道中止：结构产物没有生成成功（原因见上）——已重新弹出 ① 确认坞，点击确认即可重试。"
                    )
                )
                return
            }
        }

        // ② 确认结构 + 生成原型（原型落盘由内部回调触发，机器门按 fastForwardFinalStage 放行）
        if pipeline.stage == .structure {
            await confirmStructure(directive: directive)
            guard prototypeOnDisk else {
                clearDeferredConfirmGate(.structure)
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚡ 快速通道中止：原型没有生成成功（原因见上）——已重新弹出 ② 确认坞，点击确认即可重试。"
                    )
                )
                return
            }
        }

        // ③ target=prd：确认原型 + 生成 PRD（与既有行为一致，PRD 无机器门）
        if target == .prd, pipeline.stage == .prototype {
            await confirmPrototype(directive: directive)
        }
        reloadTree()
        refreshGateOwner()
    }

    /// ④/③ 快捷回退入口（UI「重做原型 / 重做结构」按钮）：与 LLM 回退块同一执行路径。
    /// 裸点击不带修改要求 → redo（从零重画）；带明确诉求的修订走对话自然语言（LLM 判 revise）。
    func requestBacktrack(to target: PipelineRun.Stage) {
        guard !currentVersionReleased, !sessionStore.isStreaming,
              pipeline.stage == .prd || pipeline.stage == .prototype,
              target != pipeline.stage else { return }
        executeBacktrack(to: target)
        Task { await regenAfterBacktrack(to: target, instruction: nil, mode: "redo") }
    }

    /// ② 迭代基底：磁盘上的三项结构产物拼装（任一存在即返回，全部缺失 → nil）。
    static func readStructureArtifactsBundle(project: String, version: String) -> String? {
        let parts: [(label: String, rel: String)] = [
            ("功能架构图", ArtifactPath.architecture),
            ("核心流程图", ArtifactPath.coreFlows),
            ("模块-页面映射表", ArtifactPath.modulePageMap),
        ]
        var sections: [String] = []
        for part in parts {
            if let text = readArtifact(project: project, version: version, rel: part.rel),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("### \(part.label)\n\n\(text)")
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// 跨版本澄清基底（轻改并入点）：项目内最近一个有澄清要点表的其他版本。
    /// 版本按目录创建时间降序（纯数据键排序）；都不带表 → nil（首次澄清无基底，行为不变）。
    static func readPreviousVersionClarification(project: String, version: String) -> String? {
        let others = PMAgentStore.listVersions(in: project)
            .filter { $0 != version && $0 != "knowledge" }
            .compactMap { name -> (name: String, created: Date)? in
                let url = PMAgentStore.projectURL(project)
                    .appendingPathComponent(name, isDirectory: true)
                guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                else { return nil }
                return (name, created)
            }
            .sorted { $0.created > $1.created }
        for other in others {
            if let text = readArtifact(
                project: project, version: other.name, rel: ArtifactPath.clarification
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// 💀 状态机事件结算（事件驱动，非模型轮询；命中回写决策日志 risk_hit）。
    private func settleRisks(_ trigger: RiskRecord.TriggerSignal, note: String) {
        guard let settled = try? risks.settle(trigger: trigger, note: note), !settled.isEmpty
        else { return }
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "💀 风险命中 \(settled.count) 条（触发信号 \(trigger.rawValue)）——预测 vs 实际对照见右栏「风险」台账。"
            )
        )
    }

    /// 跨确认门核验提醒：上一阶段还有「已挂方案」未验证的风险时，轻提醒去台账核。
    /// 验证动作本身在台账行内（已解除 / 没解决），门只负责把人拉回来看一眼。
    private func gateRiskNudge(fromStage: RiskRecord.Stage, nextStageName: String) {
        let hanging = risks.mitigatingRisks.filter { $0.stage == fromStage }
        guard !hanging.isEmpty else { return }
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "⏳ 进入\(nextStageName)前——「\(Self.stageName(fromStage))」阶段还有 "
                    + "\(hanging.count) 个已挂方案的风险待验证：右栏「风险」台账逐条核（已解除 / 没解决）。",
                milestones: [MilestoneStamp(
                    kind: "risk",
                    count: hanging.count,
                    detail: "已挂方案 ≠ 解除 · 验证通过才算数"
                )]
            )
        )
    }

    /// 阶段枚举 → 人话（系统行文案用）。
    nonisolated static func stageName(_ stage: RiskRecord.Stage) -> String {
        switch stage {
        case .clarify: "澄清"
        case .structure: "结构"
        case .prototype: "原型"
        case .prd: "PRD"
        }
    }

    /// 用户消息中的档位切换意图（「用 lean 档」/「切换到 full」/「精简档」…）。
    static func tierFromText(_ text: String) -> String? {
        let lowered = text.lowercased()
        if lowered.contains("lean") || text.contains("精简档") { return "lean" }
        if lowered.contains("full") || text.contains("完整档") { return "full" }
        if lowered.contains("standard") || text.contains("标准档") { return "standard" }
        return nil
    }

    /// 澄清要点表「## 约束」小节的 `- ` 条目数（评分卡锚定数字）。
    static func countConstraints(in clarificationMarkdown: String) -> Int {
        guard let range = clarificationMarkdown.range(of: "## 约束") else { return 0 }
        var count = 0
        for line in clarificationMarkdown[range.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }  // 下一个小节
            if trimmed.hasPrefix("- ") { count += 1 }
        }
        return count
    }

    /// 模块-页面映射表表格解析：数据行数（模块数）+ 去重页面名（第 2 列）。
    static func mapRows(in markdown: String) -> (modules: Int, pages: [String]) {
        var modules = 0
        var pages: [String] = []
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }
            var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 剥掉行首行尾空单元格（「| a | b |」拆分后首尾为空串）
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            guard cells.count >= 2 else { continue }
            // 跳过表头（首列「模块」/次列「页面」）与分隔行（--- / :---:）
            if cells[0].contains("模块") || cells[1].contains("页面") { continue }
            if cells.contains(where: { $0.contains("---") }) { continue }
            modules += 1
            let page = cells[1]
            if !page.isEmpty && !pages.contains(page) { pages.append(page) }
        }
        return (modules, pages)
    }

    // MARK: - Git 快照（Task 3.7：闸口确认 / PRD / 封板后的后台自动快照）

    /// fire-and-forget：串行队列，不阻塞主线。
    private func snapshotProject(message: String) {
        let projectDir = PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
            .deletingLastPathComponent()
        Task.detached { [projectDir, message] in
            _ = try? await GitSnapshotQueue.shared.snapshot(projectDir: projectDir, message: message)
        }
    }

    // MARK: - 竞品分析分支（Task 3.8：意图命中分流，主线不阻塞）

    private func runCompetitiveAnalysis(topic: String) async {
        let project = pipeline.project
        let version = pipeline.version
        // 分支触发记录（开发者检查器「分支技能触发」展示，Task 4.1 可观测性）
        branchTriggers.append(
            BranchTriggerRecord(
                id: UUID().uuidString,
                kind: "competitive_analysis",
                detail: "竞品分析意图命中：「\(String(topic.prefix(40)))」",
                createdAt: ISO8601.timestamp()
            )
        )
        try? sessionStore.append(
            sessionStore.makeEntry(role: .system, content: "🔍 竞品分析分支后台运行中（主线可继续对话）……")
        )
        let runner = AnalysisRunner()
        do {
            let url = try await runner.run(
                topic: topic, project: project,
                version: version, settings: settings
            )
            // 会话守卫（s11 注入坑）：后台任务期间用户可能已切换会话——
            // 产物仍落盘原项目，通知只注入仍停留的会话
            guard pipeline.project == project, pipeline.version == version else { return }
            if url != nil {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "📦 竞品分析报告已生成——右栏「文件」可预览，撰写 PRD 时会参考（须标出处）。"
                    )
                )
            } else {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚠️ 竞品分析未产出（模型未按 artifact:analysis 协议返回），稍后重试。"
                    )
                )
            }
        } catch {
            guard pipeline.project == project, pipeline.version == version else { return }
            try? sessionStore.append(
                sessionStore.makeEntry(role: .system, content: "⚠️ 竞品分析失败：\(error.localizedDescription)")
            )
        }
        reloadTree()
    }

    // MARK: - 版本封板（Task 3.7：ProjectHomeView 两段确认后回调）

    func releaseVersion(project: String, version: String) async {
        guard version != "unversioned" else { return }  // 兜底容器不是发布单元（UI 侧已过滤）
        let summary = Self.artifactsSummary(project: project, version: version)
        // 版本不再是记忆作用域（方案 A）：封板只冻结产物，记忆条目带版本溯源标签留在项目池

        // 1. release-notes：LLM 基于产物摘要生成（失败兜底手写清单，不阻塞封板）
        let notes: String
        if let raw = try? await sessionStore.oneShot(
            VersionStore.releaseNotesPrompt(artifactsSummary: summary),
            settings: settings, stage: .classify, maxTokens: 2048
        ), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = raw
        } else {
            notes = "## 本版本概览\n\n（模型不可用，以下为产物清单摘要）\n\n\(summary)"
        }

        do {
            // 2. 封板：💀 终态结算 → release-notes → version.json → 目录冻结只读
            try versionStore.release(
                project: project, version: version, notes: notes,
                settleRisks: { [weak self] in try self?.risks.settleAllForRelease() }
            )
            // 3. Git 快照（封板终态）
            let projectDir = PMAgentStore.versionURL(project: project, version: version)
                .deletingLastPathComponent()
            _ = try? await GitSnapshotQueue.shared.snapshot(
                projectDir: projectDir, message: "release: \(version) 封板"
            )
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(role: .system, content: "⚠️ 封板失败：\(error.localizedDescription)")
            )
        }
        reloadTree()
        refreshReleasedState()
    }

    /// 版本产物摘要（release-notes 生成的输入，纯磁盘事实，不虚构）。
    static func artifactsSummary(project: String, version: String) -> String {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        var lines = ["项目：\(project)，版本：\(version)"]
        let items: [(String, String)] = [
            (ArtifactPath.clarification, "澄清要点表"),
            (ArtifactPath.architecture, "功能架构图"),
            (ArtifactPath.coreFlows, "核心流程图"),
            (ArtifactPath.modulePageMap, "模块-页面映射表"),
            (ArtifactPath.prototype, "可点击原型"),
            (ArtifactPath.prd, "PRD 文档"),
            (ArtifactPath.competitiveAnalysis, "竞品分析包"),
            (ArtifactPath.releaseNotes, "发布说明"),
        ]
        for (rel, name) in items
        where fm.fileExists(atPath: dir.appendingPathComponent(rel).path) {
            lines.append("- \(name)（\(rel)）")
        }
        let decisions = PMAgentStore.readLines(
            DecisionRecord.self,
            from: PMAgentStore.jsonlURL(project: project, version: version, file: "decisions.jsonl")
        ).count
        let risks = PMAgentStore.readLines(
            RiskRecord.self,
            from: PMAgentStore.jsonlURL(project: project, version: version, file: "risks.jsonl")
        ).count
        if decisions > 0 { lines.append("- 决策日志 \(decisions) 条（decisions.jsonl）") }
        if risks > 0 { lines.append("- 风险登记 \(risks) 条（risks.jsonl）") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 记忆沉淀（Task 2.6）

    /// 整理记忆（设置弹框）：LLM 出合并/失效计划 → 白名单校验落碑文。返回报告文本。
    func consolidateMemory() async -> String {
        guard !memory.effective.isEmpty else { return "暂无有效记忆条目，无需整理" }
        let pool = memory.effective.map { entry in
            (id: entry.id, kind: kindName(entry.kind), content: entry.content)
        }
        guard let raw = try? await sessionStore.oneShot(
            AgentPrompts.memoryConsolidation(entries: pool),
            settings: settings, stage: .classify
        ) else {
            return "⚠️ 模型不可用——整理需要对话模型在线，请检查模型配置后重试"
        }
        let plan = MemoryStore.parseConsolidation(raw)
        guard !plan.isEmpty else { return "模型未给出整理建议（当前记忆池没有明显的重复/过时条目）" }
        let report = memory.applyConsolidation(plan)
        return report.isEmpty ? "整理完成，无需变更" : report
    }

    private func kindName(_ kind: MemoryEntry.Kind) -> String {
        switch kind {
        case .conclusion: "结论"
        case .constraint: "约束"
        case .rejection: "否决项"
        case .experience: "经验"
        }
    }

    private func sedimentMemory(transcript: String) async {
        guard let items = await extract(
            [MemoryStore.ExtractionItem].self,
            prompt: AgentPrompts.memoryExtraction(transcript: transcript)
        ) else { return }
        guard !items.isEmpty else { return }

        let sessionId = sessionStore.sessionId
        _ = memory.record(items, sessionId: sessionId) { [weak self] line in
            guard let self else { return }
            try self.sessionStore.append(line)
        }
    }

    // MARK: - 「这条记下来」（Task 4.4：归属分流，默认判定可改；E10）

    /// 输入栏书签按钮：捕获草稿打开归属分流弹窗；
    /// 空草稿 → 最近一条助手回复（剥产物块，取可读正文）。
    func startBookmarkCapture(_ text: String) {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty,
           let last = sessionStore.entries.last(where: { $0.role == .assistant }) {
            let blocks = ArtifactParser.parseArtifactBlocks(in: last.content)
            source = blocks.isEmpty
                ? last.content
                : ArtifactParser.stripArtifactBlocks(in: last.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !source.isEmpty else { return }
        bookmarkDraft = source
    }

    func cancelBookmarkCapture() {
        bookmarkDraft = nil
    }

    /// 手动方法论卡固定置信度（归属分流不暴露滑杆；与 LLM 抽取默认值一致）。
    private static let manualCardConfidence: Double = 0.8

    /// 归属分流保存：经验路线 → 记忆层「经验」（假设态，固定初始置信度 0.7）；
    /// 卡片路线 → 抽取 + 去重合并 + 落卡。置信度不做手动输入——由使用校准自动升降。
    func saveBookmark(_ capture: BookmarkCapture) async {
        bookmarkDraft = nil
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch capture.destination {
        case .experience:
            let sourceRef = "\(pipeline.project)/\(pipeline.version)"
            let report = memory.recordExperience(
                content: text, sourceRef: sourceRef,
                confidence: MemoryStore.experienceHypothesisConfidence,
                sessionId: sessionStore.sessionId
            ) { [weak self] line in
                try self?.sessionStore.append(line)
            }
            if report.isEmpty {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚠️ 经验沉淀失败（discussions.jsonl 写入异常），请重试。"
                    )
                )
            }
        case .card:
            await saveMethodologyCard(
                content: text, confidence: Self.manualCardConfidence, sourceType: "manual"
            )
        }
        reloadTree()
    }

    /// 经验校准回写（记忆抽屉确认/否定）：置信度随使用自动升降，
    /// 并清除待校准标记。写入失败静默（下次注入会重新置待校准）。
    func confirmExperienceCalibration(id: String, confirmed: Bool) {
        _ = MemoryStore.applyExperienceCalibration(id: id, confirmed: confirmed)
        memory.reload()
    }

    /// 方法论卡保存（卡片路线）：LLM 抽取（失败回退原文）→ 去重合并判定
    /// （>0.92 合并 / 同主题冲突旧卡让位 / 新建）→ 落卡 + 增量索引。
    private func saveMethodologyCard(content: String, confidence: Double, sourceType: String) async {
        let project = pipeline.project
        let embedder = SettingsBackedEmbedder(settings: settings)
        let sourceRef = "\(project)/\(pipeline.version)"

        // 1. LLM 抽取（schema 约束；无 Key / 失败 → 回退原文单条）
        var items: [KnowledgeExtractor.ExtractedKnowledge] = []
        if let extracted = await extract(
            [KnowledgeExtractor.ExtractedKnowledge].self,
            prompt: KnowledgeExtractor.extractionPrompt(transcript: content)
        ) {
            items = extracted
        }
        if items.isEmpty {
            items = [
                KnowledgeExtractor.ExtractedKnowledge(
                    title: Recommender.title(of: content), content: content, confidence: confidence
                )
            ]
        }

        // 2. 既有卡候选（scope 隔离：全局 + 当前项目；已让位卡排除）
        let existing = Self.cardCandidates(database: database, project: project)

        for var item in items {
            // 手动卡片置信度固定值优先（归属分流不再暴露滑杆，覆盖抽取值）
            item.confidence = confidence
            let itemEmbedding = (try? await embedder.embed(texts: [item.content]))?.first
                ?? DeterministicHashEmbedder.vector(for: item.content)

            // 归属判定只要 4 字段（id/title/content/embedding），从候选投影
            switch KnowledgeExtractor.mergeDecision(
                for: item,
                existing: existing.map {
                    (id: $0.id, title: $0.title, content: $0.content, embedding: $0.embedding)
                },
                itemEmbedding: itemEmbedding
            ) {
            case .mergeInto(let existingId):
                // 同概念第二次触发 → 合并（E10）：旧卡注记区追加，不新建
                mergeIntoExisting(id: existingId, item: item)
            case .conflict(let existingId):
                // 同主题实质改良：新卡落盘 + 旧卡 supersededBy 让位
                await writeCard(item: item, sourceType: sourceType, sourceRef: sourceRef,
                                supersededId: existingId, embedder: embedder)
            case .newCard:
                await writeCard(item: item, sourceType: sourceType, sourceRef: sourceRef,
                                supersededId: nil, embedder: embedder)
            }
        }
    }

    /// 合并分支（E10）：旧卡实战注记区追加「同一概念二次沉淀」，不新建。
    private func mergeIntoExisting(id: String, item: KnowledgeExtractor.ExtractedKnowledge) {
        guard let located = Self.locateCard(id: id, project: pipeline.project) else { return }
        do {
            try AnnotationWriter.append(
                cardURL: located.url,
                note: "同一概念二次沉淀，已合并（出自 \(pipeline.project)/\(pipeline.version)）：\(item.content)",
                project: pipeline.project,
                date: ISO8601.dayString()
            )
            reindexCard(at: located.url, projectId: located.projectId)
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "🗃️ 与既有方法论卡近重复（相似度 > 0.92）——已合并进 \(id)，实战注记 +1（同一概念不新建）。"
                )
            )
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 合并注记追加失败：\(error.localizedDescription)"
                )
            )
        }
    }

    /// 落卡分支：新卡 write-then-verify 落盘 + 写完即建索引；
    /// supersededId 非空 → 旧卡同时让位（冲突消解链）。
    private func writeCard(
        item: KnowledgeExtractor.ExtractedKnowledge,
        sourceType: String,
        sourceRef: String,
        supersededId: String?,
        embedder: SettingsBackedEmbedder
    ) async {
        do {
            let card = try await KnowledgeExtractor.writeCard(
                content: item.content, confidence: item.confidence,
                sourceType: sourceType, sourceRef: sourceRef,
                database: database, embeddingProvider: embedder
            )
            if let supersededId,
               let old = Self.locateCard(id: supersededId, project: pipeline.project) {
                try KnowledgeExtractor.markSuperseded(cardURL: old.url, by: card.id)
                reindexCard(at: old.url, projectId: old.projectId)
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "🔀 方法论卡片已更新：同主题旧卡被改良版取代，新卡已存入卡片库。"
                    )
                )
            } else {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "🗃️ 方法论卡已沉淀：\(card.id)（全局卡片库，跨项目直接用不降级）——实战注记将随使用增厚。"
                    )
                )
            }
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 方法论卡片保存失败：\(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - 主动推荐（Task 4.5：阶段开始扫描卡片库 1-3 个；E23）

    /// 阶段开始 / 切换后刷新推荐（ConversationView 触发）。
    /// 阶段切换 → 清空拒绝记录（拒绝只在同阶段内持久——同阶段不重复被拒项）。
    func refreshRecommendations() async {
        let stage = pipeline.stage
        if recommendationStage != stage {
            recommendationStage = stage
            rejectedCards = []
        }
        guard let database else {
            recommendations = []
            return
        }
        let project = pipeline.project
        let query = stageQueryText(stage: stage)
        let cards = Self.cardCandidates(database: database, project: project)
        guard !cards.isEmpty else {
            recommendations = []
            return
        }
        // 查询向量化：真实端点优先，失败回退确定性哈希（保活不阻塞）
        let embedder = SettingsBackedEmbedder(settings: settings)
        let queryVector = (try? await embedder.embed(texts: [query]))?.first
            ?? DeterministicHashEmbedder.vector(for: query)
        recommendations = Recommender.recommend(
            stage: LLMStage(rawValue: stage.rawValue) ?? .clarify,
            project: project,
            cards: cards,
            stageSummary: query,
            queryEmbedding: queryVector,
            rejected: rejectedCards
        )
    }

    /// 采纳推荐：实战注记 append（方法论被使用 → 只增不覆盖，带项目出处与日期；E23）
    /// + 记忆校准注入（该用户历史使用倾向，经验按假设态标签注入）。
    func adoptRecommendation(_ id: String) {
        guard let rec = recommendations.first(where: { $0.id == id }) else { return }
        recommendations.removeAll { $0.id == id }
        guard let located = Self.locateCard(id: id, project: pipeline.project) else { return }
        // 已采纳 → 后续每次组装注入该用户历史使用倾向（记忆校准，E23）
        adoptedMethodologies.append(rec.title)
        do {
            try AnnotationWriter.append(
                cardURL: located.url,
                note: "\(pipeline.project) \(pipeline.version) \(stageDisplayName)阶段采纳本方法论（\(rec.title)）",
                project: pipeline.project,
                date: ISO8601.dayString()
            )
            reindexCard(at: located.url, projectId: located.projectId)

            // 记忆校准：跨项目经验按假设态注入（E23 trace 可证）
            let experiences = MemoryStore.allExperiences()
            let calibration = KnowledgeCalibration.calibrationContext(
                cardTitle: rec.title, memories: experiences
            )
            var line = "📌 已采纳方法论「\(rec.title)」——实战注记已追加（\(pipeline.project) · \(ISO8601.dayString())）。"
            if !calibration.isEmpty { line += "\n" + calibration }
            try? sessionStore.append(sessionStore.makeEntry(role: .system, content: line))
            // 采纳即使用：命中的经验置待校准（记忆抽屉确认/否定，随使用校准置信度）
            markCalibrationPending(for: KnowledgeCalibration.matchingExperiences(
                cardTitle: rec.title, memories: experiences
            ))
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 实战注记追加失败：\(error.localizedDescription)"
                )
            )
        }
    }

    /// 拒绝推荐：本阶段内不再重复推荐（同阶段不重复被拒项，E23）。
    func rejectRecommendation(_ id: String) {
        rejectedCards.insert(id)
        recommendations.removeAll { $0.id == id }
    }

    /// 当前阶段中文名（注记行文用）。
    private var stageDisplayName: String {
        switch pipeline.stage {
        case .clarify: "① 澄清"
        case .structure: "② 结构"
        case .prototype: "③ 原型"
        case .prd: "④ PRD"
        }
    }

    /// 阶段推荐查询文本（确定性路由：阶段关键产物 + 最近用户消息 → 最近用户消息 → 项目名兜底）。
    /// 产物锚定保证阶段连续性；混入最近 1 条用户消息让即时意图（如「重点考虑无障碍」）
    /// 也能命中检索（s07 借鉴：召回信号不只来自上游产物）。
    private func stageQueryText(stage: PipelineRun.Stage) -> String {
        let rel: String?
        switch stage {
        case .clarify: rel = nil
        case .structure: rel = ArtifactPath.clarification
        case .prototype, .prd: rel = ArtifactPath.modulePageMap
        }
        let lastUser = sessionStore.entries.last { $0.role == .user }?.content ?? ""
        if let rel,
           let text = Self.readArtifact(
               project: pipeline.project, version: pipeline.version, rel: rel
           ),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastUser.isEmpty ? text : text + "\n" + lastUser
        }
        // 兜底：最近 3 条用户消息（澄清阶段主查询源）
        let recent = sessionStore.entries.filter { $0.role == .user }
            .suffix(3).map(\.content)
        return recent.isEmpty ? pipeline.project : recent.joined(separator: "\n")
    }

    /// 卡片库候选（scope 隔离与检索层同规则：全局 + 当前项目；已让位卡与
    /// 零长度占位 blob 排除）——推荐与去重合并判定的共用数据源。
    nonisolated private static func cardCandidates(
        database: AppDatabase?, project: String
    ) -> [(id: String, title: String, content: String, annotationCount: Int, scope: String, embedding: [Float])] {
        guard let database else { return [] }
        // Row 非 Sendable：闭包内先投影成值元组再带出
        let tuples: [(id: String, projectId: String, content: String, annotationCount: Int, embedding: Data)] =
            (try? database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, project_id, content, annotation_count, embedding
                        FROM knowledge_points
                        WHERE (project_id = '' OR project_id = ?) AND superseded_by IS NULL
                        """,
                    arguments: [project]
                )
                .map { row in
                    (
                        id: row["id"], projectId: row["project_id"],
                        content: row["content"], annotationCount: row["annotation_count"],
                        embedding: row["embedding"]
                    )
                }
            }) ?? []
        return tuples.compactMap { row in
            guard let vector = VectorMath.decode(row.embedding), !vector.isEmpty else {
                return nil  // M0 零长度占位 blob：未建索引，跳过
            }
            return (
                id: row.id,
                title: Recommender.title(of: row.content),
                content: row.content,
                annotationCount: row.annotationCount,
                scope: row.projectId.isEmpty ? "global" : "project",
                embedding: vector
            )
        }
    }

    /// 卡片文件定位：全局 cards/ → 项目 knowledge/（含索引用 projectId）。
    nonisolated private static func locateCard(
        id: String, project: String
    ) -> (url: URL, projectId: String)? {
        let fm = FileManager.default
        let global = PMAgentStore.cardsDir.appendingPathComponent("\(id).md")
        if fm.fileExists(atPath: global.path) { return (global, "") }
        let local = PMAgentStore.projectURL(project)
            .appendingPathComponent("knowledge", isDirectory: true)
            .appendingPathComponent("\(id).md")
        if fm.fileExists(atPath: local.path) { return (local, project) }
        return nil
    }

    /// 注记 / 让位变更后重建单卡索引（annotation_count 与 superseded_by 同步；
    /// 失败静默——索引可随时全量重建，文件系统是唯一事实源）。
    private func reindexCard(at url: URL, projectId: String) {
        guard let database,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let card = MethodologyCard.parse(markdown: text) else { return }
        let embedder = SettingsBackedEmbedder(settings: settings)
        Task { [database, embedder, card, projectId] in
            try? await IndexRebuilder.indexCard(
                card, projectId: projectId, database: database, embeddingProvider: embedder
            )
        }
    }

    /// oneShot JSON 抽取的泛型便捷封装（静默降级场景用：失败返回 nil 即可）。
    private func extract<T: Decodable>(
        _ type: T.Type, prompt: String, maxTokens: Int = 2048
    ) async -> T? {
        await extractWithReason(type, prompt: prompt, maxTokens: maxTokens).value
    }

    /// 同上，但失败时透传真实原因（网络错误 / 空流 / JSON 不合法）——
    /// 供咽喉路径（澄清要点表等）如实报错，不再一律归为「未返回合法 JSON」。
    /// 思考型模型（reasoning 计入 max_tokens 池）预算撞线时正文为空抛空流，
    /// maxTokens 需按任务规模给足（要点表 8192）。
    private func extractWithReason<T: Decodable>(
        _ type: T.Type, prompt: String, maxTokens: Int = 2048
    ) async -> (value: T?, failureReason: String?) {
        let raw: String
        do {
            raw = try await sessionStore.oneShot(
                prompt, settings: settings, stage: .classify, maxTokens: maxTokens
            )
        } catch {
            return (nil, error.localizedDescription)
        }
        if let value = LenientJSON.decode(T.self, from: raw) {
            return (value, nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (nil, "模型未返回任何内容（思考占满输出预算或服务端瞬时故障）")
        }
        return (nil, "返回内容不是合法 JSON（开头：\(trimmed.prefix(60))…）")
    }

    private static func readArtifact(project: String, version: String, rel: String) -> String? {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(rel)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
