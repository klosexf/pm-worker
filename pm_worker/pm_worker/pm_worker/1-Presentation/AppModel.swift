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

/// 「版本行菜单 → 新建对话」的预关联载荷（newSession(inProject:) 产生，
/// NewTaskView onAppear 消费后即清空）；version nil = 落「默认无版本号」。
struct NewTaskPrefill: Equatable {
    let project: String
    let version: String?
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
    /// 「版本行菜单 → 新建对话」待消费的预关联载荷（消费后即清空，
    /// 不污染后续手动进入的新建任务页）。
    @Published var newTaskPrefill: NewTaskPrefill?
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
    /// 变更分诊台账（changes.jsonl 折叠视图）：聊天流提案卡处置状态的依据；
    /// 变更池整页（DecisionLogPage）自行读盘，不依赖此发布态。
    @Published private(set) var changeLedger: [ChangeItem] = []
    /// 封板记忆交接弹窗（releaseVersion 成功且该版本有版本记忆时弹出；
    /// 确认 → 勾选条目升项目记忆，跳过 → 原条目随封板版本归档）。
    // （方案 A：封板交接机制已移除——版本不再是记忆作用域，无交接需求）

    // MARK: 知识层状态（Task 4.4 / 4.5）

    /// 「这条记下来」草稿（非 nil → KnowledgeCaptureSheet 弹出；E10 归属分流入口）。
    @Published var bookmarkDraft: String?
    /// 产物右键「添加到对话」待插入引用（相对版本目录的路径；ConversationView 消费后置回 nil）。
    @Published var pendingFileReference: String?

    // MARK: 会话输入坞状态（每会话独立：草稿 / 待发附图 / 待发引用文件只在所属对话页出现）

    /// 会话页视图身份在会话间被 SwiftUI 复用（ContentView switch 同分支），
    /// 视图 @State 会把 A 页草稿带到 B 页——输入坞状态收口到 AppModel 按会话键
    /// 隔离（deferredConfirmGates 同款口径）：切页不串显，切回本页草稿仍在。
    @Published var inputDrafts: [String: String] = [:]
    /// 各对话页独立的待发附图（key = inputDockKey）。
    @Published var inputPendingImages: [String: [PendingImage]] = [:]
    /// 各对话页独立的待发引用文件（key = inputDockKey）。
    @Published var inputPendingFileRefs: [String: [String]] = [:]

    /// 会话输入坞状态的存储键：project/version/sessionId 三元组唯一确定一个对话页。
    func inputDockKey(project: String, version: String, sessionId: String) -> String {
        "\(project)/\(version)/\(sessionId)"
    }

    /// 会话删除后清空其输入坞状态（草稿与待发附件随会话消亡，不留悬空键）。
    private func purgeInputDockState(project: String, version: String, sessionId: String) {
        let key = inputDockKey(project: project, version: version, sessionId: sessionId)
        inputDrafts.removeValue(forKey: key)
        inputPendingImages.removeValue(forKey: key)
        inputPendingFileRefs.removeValue(forKey: key)
    }

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

    /// 分支确认待决态（意图误触发防护，design.md §12）：非 nil = 停靠卡等待用户裁决，
    /// 确认前不联网不落产物。绑定发起会话——仅该会话的停靠卡挂载，切会话不串卡；
    /// 并携带发起时的 (project, version)：确认时用户可能已切版本，分支归属以发起上下文为准。
    struct PendingBranchConfirmation: Equatable {
        let sessionId: String
        let topic: String
        let project: String
        let version: String
    }
    @Published var pendingBranchConfirmation: PendingBranchConfirmation?

    /// 索引库（internal：右栏知识点 Tab / 卡片库 / 技能库 UI 直接查询）。
    let database: AppDatabase?

    init() {
        // Preview 环境守卫：Xcode Preview 宿主（XCODE_RUNNING_FOR_PREVIEWS=1）的
        // 沙盒/XPC 环境特殊，初始化副作用（bootstrap 建目录、GRDB 开库）会阻塞，
        // 导致画布 30 秒启动等待超时（Failed to launch in reasonable time）。
        // Preview 不跑副作用——跳过磁盘写入，返回空状态。
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let loadedSettings = isPreview ? LLMSettings.default : LLMSettings.load()
        self.settings = loadedSettings
        if isPreview {
            self.database = nil
        } else {
            self.database = try? AppDatabase()
            try? PMAgentStore.bootstrap()
            Self.reindexStaleSkills(settings: loadedSettings)
        }
        self.pipeline = PipelineEngine(project: "默认", version: "unversioned", database: database)
        self.memory = MemoryStore(project: "默认", version: "unversioned")
        self.risks = RiskStore(project: "默认", version: "unversioned")
        if !isPreview { reloadTree() }
        refreshReleasedState()
        if !isPreview { syncPRDTemplateStaleness() }
        // 采纳排队续跑（消息化模型）：任一会话流态**成员变化**即尝试冲洗——目标
        // 版本是否空闲由 flushQueuedAdoptsIfIdle 按版本口径裁决（阶段 3：他会话
        // 他版本的流不再推迟本版本排队采纳的发出），此处只做唤醒触发。订阅
        // streamBoxes（成员增删：开流/收流/占位起止）而非逐 delta——流中增量
        // 不改变任何版本的 busy 判据（2026-09-18 流式盒拆分）。
        queueCancellable = sessionStore.$streamBoxes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.flushQueuedAdoptsIfIdle()
            }
    }

    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避（同 PipelineEngine
    /// 惯例）：显式退出隔离销毁路径。App 运行时本实例常驻不销毁，此声明
    /// 主要保障测试等局部实例的析构安全（默认隔离 deinit 触发 malloc 崩溃）。
    nonisolated deinit {}

    // MARK: - 三级树（磁盘 → 投影）

    /// 出厂首启 / 升级补偿（Task 4.7 → 技能追加批 v1.2 → 2026-09-15 向量修复）：
    /// skills/ 磁盘技能数与索引 skills 行数不一致（空表、升级播种新技能、用户增删
    /// 文件）、或索引里存在零向量技能行（M0 占位 / 旧重建路径遗留）时，后台全量重建
    /// 一次。**必须走真实向量路径**（embeddingProvider）：旧实现调同步 rebuild 只写
    /// 零长度占位向量 → 技能语义检索恒零命中 → 路由退化为阶段锚点每轮兜底（用户实测
    /// 「离题提问也被注入高保真原型设计」的根因）。端点不可用时 SettingsBackedEmbedder
    /// 自带确定性哈希兜底，不阻塞。自开 AppDatabase（同 SettingsDialog.rebuildIndex
    /// 惯例），不捕获 self；一致时仅一次开库 + 两次 COUNT，零额外开销。
    private nonisolated static func reindexStaleSkills(settings: LLMSettings) {
        Task.detached(priority: .utility) { [settings] in
            let dbURL = PMAgentStore.root.appendingPathComponent("index.sqlite")
            guard let db = try? AppDatabase(indexURL: dbURL) else { return }
            let counts = try? await db.dbQueue.read { database -> (indexed: Int, missing: Int) in
                let indexed = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM skills") ?? 0
                let missing = try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM skills WHERE length(embedding) = 0"
                ) ?? 0
                return (indexed, missing)
            }
            let indexed = counts?.indexed ?? 0
            let onDisk = countParseableSkillFiles()
            guard indexed != onDisk || (counts?.missing ?? 0) > 0 else { return }
            _ = try? await IndexRebuilder.rebuild(
                database: db,
                embeddingProvider: SettingsBackedEmbedder(settings: settings)
            )
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

    // MARK: - Agent 工具（Function Calling v1，PRD §11 V2 路线首项）

    /// 组装本轮工具运行时。nil = 未启用（总开关关 / anthropic-compat 降级），
    /// SessionStore 工具循环整体旁路，行为与旧版完全一致。
    /// 封板判定按 origin 口径（链中途切走不误判当前版本）。
    private func agentToolRuntime(origin: ReplyOrigin) -> AgentToolRuntime? {
        guard settings.agentToolsEnabled else { return nil }
        // anthropic-compat 走 content blocks 协议（非 OpenAI tools 形态），v1 优雅降级
        guard settings.chatConfig.provider != "anthropic-compat" else { return nil }
        let context = AgentToolContext(
            settings: settings,
            project: origin.project, version: origin.version, sessionId: origin.sessionId,
            isReleased: isReleased(origin.version, in: origin.project),
            skillSearch: { [weak self] query in
                await self?.toolSkillSearch(query) ?? []
            },
            submitAnalysis: { [weak self] topic in
                self?.submitBranchConfirmation(
                    topic: topic, project: origin.project,
                    version: origin.version, sessionId: origin.sessionId
                )
            }
        )
        let registry = AgentToolRegistry(tools: [
            LoadSkillTool(), WebSearchTool(), ProposeAnalysisTool(), DependencyQueryTool(),
        ])
        return AgentToolRuntime(registry: registry, context: context)
    }

    /// load_skill 工具的技能检索：语义命中（与系统注入同源）→ (id, docPath)。
    /// scope：skills 表无项目维度（全局技能库），无跨项目泄漏面。
    private func toolSkillSearch(_ query: String) async -> [(id: String, docPath: String)] {
        guard let database else { return [] }
        let catalog = await ContextBuilder.skillCatalog(database: database)
        guard !catalog.isEmpty else { return [] }
        let retriever = Retriever(database: database, embedder: SettingsBackedEmbedder(settings: settings))
        guard let trace = try? await retriever.search(
            query: query, project: pipeline.project, topK: 3,
            skillQuery: query, countsSkillHits: true
        ) else { return [] }
        let hits = trace.hits.filter { $0.library == .skills }
        let loaded = hits.compactMap { hit -> (id: String, docPath: String)? in
            guard let entry = catalog[hit.id] else { return nil }
            return (id: hit.id, docPath: entry.docPath)
        }
        // 命中口径同注入：正文实际进本轮上下文（工具回流）即计数
        if !loaded.isEmpty {
            await ContextBuilder.bumpSkillHitCounts(ids: loaded.map(\.id), database: database)
        }
        return loaded
    }

    /// 发起竞品分析确认卡（既有分支通道的唯一提交口）：用户意图命中与模型
    /// 工具调用（propose_competitive_analysis）共用。设置关闸不影响工具提议——
    /// 模型提议必须经用户裁决，比用户自发意图更需确认。
    private func submitBranchConfirmation(topic: String, project: String, version: String, sessionId: String) {
        pendingBranchConfirmation = PendingBranchConfirmation(
            sessionId: sessionId, topic: topic,
            project: project, version: version
        )
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
        flushQueuedAdoptsIfIdle() // 切回上下文即续跑排队中的采纳
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
        // 流式期间禁删（版本级口径，阶段 3）：流式回复与删除都走 discussions.jsonl
        // 整文件重写/追加，并发写同一文件有丢行风险——只拦「目标版本自身的流」，
        // 他会话他版本的并发流不再挡删。
        if sessionStore.isVersionBusy(project: project, version: version) {
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
        // 输入坞状态随会话消亡：草稿 / 待发附件不留悬空键
        purgeInputDockState(project: project, version: version, sessionId: sessionId)
        // 确认坞静默是版本级（confirm-silence.json 随版本目录持久），
        // 删会话不复位——「每版本只弹一次」的纪律不因删会话被绕过
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
        // 流式期间禁改（版本级口径，阶段 3）：与删除/重命名同口径（discussions.jsonl
        // 并发写丢行风险）——迁移重写的是源版本（默认任务区）的 jsonl，只拦该版本自身的流
        if sessionStore.isVersionBusy(
            project: PMAgentStore.defaultProjectName, version: "unversioned"
        ) {
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

    /// 在指定项目/版本下新建对话（版本行菜单）：跳转新建任务页并预关联
    /// 该项目/版本（NewTaskView 消费 newTaskPrefill 回填两个 chip），首条
    /// 消息仍按 startTask 落盘，导航本身不落盘。已封板版本是只读快照，
    /// 拒绝发起。返回错误文案，nil = 成功。
    func newSession(inProject project: String, version: String) -> String? {
        if isReleased(version, in: project) {
            return "已封板版本为只读快照，请先新建版本文件再发起对话"
        }
        activeProject = project
        // unversioned/knowledge 是系统兜底容器，不作为可选版本预填（落「默认无版本号」）
        newTaskPrefill = NewTaskPrefill(
            project: project,
            version: (version == "unversioned" || version == "knowledge") ? nil : version
        )
        selection = .newTask
        return nil
    }

    /// 重命名项目（目录 move + 清单回写，磁盘先行）。返回错误文案，nil = 成功。
    func renameProject(_ oldName: String, to newName: String) -> String? {
        // 项目级口径（阶段 3）：目录改名影响该项目全部版本的 jsonl 路径，
        // 任一版本流中都要拦；其他项目的流不再挡。
        if sessionStore.isProjectBusy(project: oldName) {
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
        // 项目级口径（阶段 3）：整目录删除影响该项目全部版本，任一版本流中都要拦。
        if sessionStore.isProjectBusy(project: name) {
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
        // 版本级口径（阶段 3）：目录改名影响该版本的 jsonl 路径，只拦该版本自身的流。
        if sessionStore.isVersionBusy(project: project, version: version) {
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
        // 版本级口径（阶段 3）：整目录删除影响该版本全部会话，只拦该版本自身的流。
        if sessionStore.isVersionBusy(project: project, version: version) {
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
        // 确认坞「稍后再说」静默随版本走（confirm-silence.json，版本级跨启动）：
        // 进会话即重读磁盘——须放在幂等 guard 之前，init 同上下文（默认/unversioned）
        // 的首个会话不会触发重建，却同样要装载静默；顺带对账磁盘现值
        deferredConfirmGates = Set(
            PMAgentStore.readConfirmSilence(project: project, version: version)
                .compactMap(ConfirmTarget.init(storageKey:))
        )
        guard pipeline.project != project || pipeline.version != version else { return }
        pipeline = PipelineEngine(project: project, version: version, database: database)
        memory = MemoryStore(project: project, version: version)
        risks = RiskStore(project: project, version: version)
        syncPRDTemplateStaleness()
        // 上下文切换 → 已采纳方法论清零（校准注入随会话走，不跨上下文）
        adoptedMethodologies = []
        refreshReleasedState()
        refreshChangeLedger()
        refreshGateOwner()
    }

    /// 当前版本封板状态（磁盘对账）。
    private func refreshReleasedState() {
        currentVersionReleased = (try? PMAgentStore.readVersion(
            project: pipeline.project, version: pipeline.version
        ))?.status == .released
    }

    /// 模板升级失效检查（2026-09-17 钦定：产出必须按当前模板版本，存量不豁免）。
    /// init / switchContext 装配 pipeline 后调用；版本取该版本档位（缺省 standard），
    /// 三档同步升级，任一档即当前模板代次。
    func syncPRDTemplateStaleness() {
        let tier = Self.readPRDTier(project: pipeline.project, version: pipeline.version) ?? "standard"
        pipeline.markPRDStaleForTemplateUpgradeIfNeeded(
            currentVersion: AgentPrompts.prdTemplateVersion(tier: tier)
        )
    }

    /// PRD 模板版本戳（04-prd/prd-meta.json）：落盘时记录生成所用模板版本与档位。
    /// 写失败不阻塞——缺失会被启动检查判为旧版待重生成（失效方向安全）。
    nonisolated static func writePRDMeta(project: String, version: String, tier: String) {
        struct PRDMeta: Codable {
            var tier: String
            var templateVersion: String
            var writtenAt: String
        }
        let meta = PRDMeta(
            tier: tier,
            templateVersion: AgentPrompts.prdTemplateVersion(tier: tier),
            writtenAt: ISO8601.timestamp()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(ArtifactPath.prdMeta)
            )
        }
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

    /// 点选答案是否为收尾确认问的肯定项（一次确认，design.md §6.1 一次确认口径）：
    /// 答案与某选项全文一致，且该选项以「确认」开头（收尾确认问协议，AgentPrompts.clarify 约束 15）。
    /// 自由输入不触发——带补充说明的答案需 AI 判读，走常规 sendMessage。
    static func isGateConfirmSelection(_ text: String, options: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return options.contains {
            let option = $0.trimmingCharacters(in: .whitespaces)
            return option == trimmed && option.hasPrefix("确认")
        }
    }

    // MARK: - Context Builder 唯一注入收口（Task 4.1 + 4.8）

    /// 组装器按当前设置实例化（embedder 随 BYOK 设置走，设置变更即时生效）。
    private func makeContextBuilder() -> ContextBuilder {
        ContextBuilder(database: database, embedder: SettingsBackedEmbedder(settings: settings))
    }

    /// 阶段化 system prompt 组装（所有主线 prompt 的唯一入口）：
    /// 骨架 + 规则层冻结段 + pitfalls 自检清单拼为 systemPrompt；易变的记忆/
    /// 技能正文/检索参考走 ContextTail 尾条协议（见下）。组装结果写 lastAssembly
    /// （开发者检查器 ⌘D 读取）。
    /// 返回「冻结段 + marker + 动态材料」复合 prompt + 本轮实际注入的技能 id
    /// （随 send 下传，思考卡「引用技能」展示）；SessionStore 发送前拆分。
    /// - Parameter userMessage: 本轮用户消息（技能意图路由的主信号）。用户发送轮必传；
    ///   系统轮（闸口推进/机器门修正）传 nil，回退到历史用户消息。
    /// - Parameter origin: 发起上下文快照（M4 origin 化）。链体调用（确认链/机器门/
    ///   采纳落实）显式传——组装含检索与技能判定的网络往返，期间用户可能切走，
    ///   project/记忆池/技能历史按 origin 取；nil = 当前上下文（发送路径入口，行为不变）。
    private func assembleSystemPrompt(
        stage: LLMStage,
        userMessage: String? = nil,
        origin: ReplyOrigin? = nil,
        volatileTail: String = "",
        toolsSection: Bool = false,
        promptBuilder: @escaping (String) -> String
    ) async -> (prompt: String, skills: [String]) {
        let effectiveOrigin = origin ?? ReplyOrigin(
            project: pipeline.project, version: pipeline.version,
            sessionId: sessionStore.sessionId,
            stage: PipelineRun.Stage(rawValue: stage.rawValue) ?? .clarify
        )
        let sameContext = originIsCurrentContext(effectiveOrigin)
        // 记忆池按 origin 版本取：链中途切走时活 memory 已是别处上下文的池
        let memoryStore = sameContext
            ? memory
            : MemoryStore(project: effectiveOrigin.project, version: effectiveOrigin.version)
        // 技能查询的历史兜底读 origin 会话投影（内存 entries 只驻当前打开会话）
        let history: [String] = sameContext
            ? sessionStore.entries.filter { $0.role == .user }.suffix(3).map(\.content)
            : sessionStore.entries(
                project: effectiveOrigin.project,
                version: effectiveOrigin.version,
                sessionId: effectiveOrigin.sessionId
            ).filter { $0.role == .user }.suffix(3).map(\.content)
        let calibration = calibrationMatches()
        let assembly = await makeContextBuilder().assemble(
            stage: stage,
            project: effectiveOrigin.project,
            stageQuery: stageQueryText(
                stage: PipelineRun.Stage(rawValue: stage.rawValue) ?? effectiveOrigin.stage
            ),
            skillQuery: skillQueryText(userMessage: userMessage, history: history),
            memoryContext: memoryStore.injectionContext,
            calibration: calibration.lines,
            skillJudge: { [weak self] query, candidates in
                await self?.judgeSkills(query: query, candidates: candidates)
            }
        ) { injection in
            promptBuilder(injection)
        }
        lastAssembly = assembly
        markCalibrationPending(for: calibration.entries)
        // 前缀缓存改造（2026-09-17，ContextTail 协议）：prompt = 冻结 system +
        // marker + 动态材料复合体，沿既有 systemPrompt 参数链下传；发送前
        // SessionStore.split 拆开——动态材料以尾条消息追加，system 与历史成为
        // append-only 可缓存前缀。动态材料为空时 prompt 即冻结段本身（无标记）。
        // volatileTail（2026-09-18）：阶段易变状态（clarify 轮次/基底段）并入
        // 尾条头部，冻结段保持跨轮次字节级不变。
        // 历史否决引用键（决策 supersedes 协议注入侧，2026-09-18）：四个主线阶段
        // 随尾条下发，供话题闭合决策推翻旧否决时回填 supersedes 引用；其余阶段
        // （classify/research/analysis/review/artifact/embedding）不出 decision 块，
        // 不注入。无否决记录时为空串，尾条组装自动剔除。
        let supersedable: String
        switch stage {
        case .clarify, .structure, .prototype, .prd:
            supersedable = Self.supersedableRejections(
                Self.versionDecisions(
                    project: effectiveOrigin.project, version: effectiveOrigin.version
                )
            )
        default:
            supersedable = ""
        }
        var tailParts = [volatileTail, assembly.injectionText, supersedable]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Function Calling 工具说明（toolsSection = runtime 非空）：随尾条下发，
        // 与实际可调用性同真同假（runtime nil 时说明也不注入，防模型空转）。
        if toolsSection { tailParts.append(AgentPrompts.agentToolUsageSection) }
        return (
            ContextTail.compose(system: assembly.systemPrompt, tail: tailParts.joined(separator: "\n\n")),
            assembly.skillIds
        )
    }

    /// 系统层知识引用（2026-09-17 钦定）：本轮注入的卡命中（id→标题），
    /// 随 assistant 条目落盘、气泡底部渲染「参考知识卡」引用条——
    /// 让「卡片在反哺 AI 回答」从不可见变为可感知可核对。
    private func knowledgeRefsFromAssembly() -> [String: String]? {
        guard let hits = lastAssembly?.retrieval?.hits.filter({ $0.library == .cards }),
              !hits.isEmpty else { return nil }
        let refs = Dictionary(uniqueKeysWithValues: hits.prefix(4).map {
            ($0.id, Recommender.title(of: $0.content))
        })
        return refs.isEmpty ? nil : refs
    }

    /// 技能判定上限（判定通道单轮最多注入几个技能——宁少勿滥）。
    private static let skillJudgeLimit = 3

    /// 技能判定兜底通道（混合路由，2026-09-15 用户钦定）：本地检索零命中时才被
    /// Context Builder 调用——classify 档小模型读技能清单（id + when_to_use）判
    /// 「本轮消息真正需要哪些技能」。口语化说法（「这个按钮放哪」「这块体验不好」）
    /// 本地词面兜不住时由它接住；离题 / 闲聊 / 纯推进语判空 → 不注入。
    /// 返回 nil = 通道不可用（网络 / 解析失败），组装侧退「索引失效态才锚点」兜底。
    /// 判出的名字必须逐字来自清单（防幻觉），最多 skillJudgeLimit 个。
    private func judgeSkills(
        query: String, candidates: [(id: String, whenToUse: String)]
    ) async -> [String]? {
        guard !candidates.isEmpty else { return nil }
        let prompt = AgentPrompts.skillJudge(query: query, candidates: candidates)
        // 思考型模型 reasoning 计入 max_tokens：配额给小会思考撞线、正文为空（空流）——
        // 清单 + 消息的输入规模按 4096 给足（与澄清要点表同源教训）
        guard let names = await extract([String].self, prompt: prompt, maxTokens: 4096) else {
            return nil
        }
        let valid = Set(candidates.map(\.id))
        var picked: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard valid.contains(trimmed), !picked.contains(trimmed) else { continue }
            picked.append(trimmed)
        }
        return Array(picked.prefix(Self.skillJudgeLimit))
    }

    /// 技能路由意图查询（意图优先，2026-09-14；2026-09-15 收紧为「语义为准」）：
    /// 技能正文注入跟消息语义走、不跟阶段走。用户发送轮**只用本轮消息**——历史
    /// 消息曾混进查询，会把离题提问染上阶段气味（实测：马斯克+两条原型历史 →
    /// 高保真原型设计 0.41 > 阈值，离题问题照样命中原型技能）；系统轮（闸口推进 /
    /// 机器门修正，无新消息）才用最近 3 条历史兜底；再兜底 stageQueryText。
    /// history 由调用方传入（M4）：origin 链读 origin 会话投影，不读当前内存 entries。
    private func skillQueryText(userMessage: String?, history: [String]) -> String {
        var parts: [String] = []
        if let message = userMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            parts.append(message)
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
    /// - Parameter fileRefs: 用户引用的产物文件（相对版本目录路径，可为空）——
    ///   随条目落盘并在本轮 system prompt 注入原文（AI 真正读到内容）。
    func sendMessage(
        _ text: String, imageFiles: [String] = [], fileRefs: [String] = []
    ) async {
        let project = pipeline.project
        let version = pipeline.version
        // 侧栏联动：本次发送发生在哪个项目/版本 → 侧栏自动展开到该会话可见
        sidebarReveal = SidebarReveal(project: project, version: version)
        // 封板版本目录只读（黄条已提示）——静默拦截写入，回看走快照/release-notes
        guard !currentVersionReleased else { return }
        try? PMAgentStore.ensureWorkspace(project: project, version: version)

        // P3 Steering 分流：当前会话生成进行中（含回复流未开的待回复期）→
        // 插话入队（不打断生成）。仅发起会话可插话（排队气泡/注入都以发起会话
        // 为准）；附件/引用文件不支持插话携带（跨轮注入语义复杂，排队文本已覆盖主场景）。
        if sessionStore.isSessionBusy(sessionStore.sessionId),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionStore.enqueueSteering(text)
            return
        }

        // 竞品分析分支（Task 3.8）：意图命中即分流——消息先入流留痕（此前命中即
        // return，用户那句话不进对话流、凭空消失）；再按「分支执行前确认」设置走：
        // 开（默认）→ 停靠分支确认卡，确认后才后台执行（防误触发，design.md §12）；
        // 关 → 直接后台执行（s11 借鉴），主线立即可继续对话。完成后通知注入回
        // 本会话（会话已切换则只落盘不注入）。
        if AnalysisRunner.isAnalysisIntent(text) {
            let stagedBranch = sessionStore.stageOutgoingUser(text)
            try? sessionStore.append(stagedBranch)
            if AnalysisRunner.confirmBeforeRunEnabled {
                submitBranchConfirmation(
                    topic: text, project: project,
                    version: version, sessionId: sessionStore.sessionId
                )
            } else {
                // 分支入口快照 origin：后台 Task 起跑时用户可能已切走
                let branchOrigin = ReplyOrigin(
                    project: project, version: version,
                    sessionId: sessionStore.sessionId, stage: pipeline.stage
                )
                Task { await runCompetitiveAnalysis(topic: text, origin: branchOrigin) }
            }
            return
        }

        // 草稿预演会话（B1）：分派按草稿推进位置；推进意图指令 → draftAdvance
        //（指令照常落对话流留痕，但不进常规 LLM 回合）。
        let draftStage = SessionStore.draftStage(
            project: project, version: version, sessionId: sessionStore.sessionId
        )
        if let draftStage {
            if Self.isDraftAdvanceIntent(text) {
                let stagedInstruction = sessionStore.stageOutgoingUser(text)
                try? sessionStore.append(stagedInstruction)
                let origin = ReplyOrigin(
                    project: project, version: version,
                    sessionId: sessionStore.sessionId, stage: draftStage
                )
                await draftAdvance(origin: origin)
                reloadTree()
                return
            }
            if draftStage == .prd {
                // 草稿 PRD 不支持对话式迭代（合并入主线后才是活文档）；提示处置路径
                let stagedInstruction = sessionStore.stageOutgoingUser(text)
                try? sessionStore.append(stagedInstruction)
                let origin = ReplyOrigin(
                    project: project, version: version,
                    sessionId: sessionStore.sessionId, stage: draftStage
                )
                appendOriginSystem(
                    "📝 PRD 草稿已生成（不落主线）——到「决策日志 · 变更池」合并入主线，"
                        + "或放弃本次草稿后重新预演。",
                    origin: origin
                )
                reloadTree()
                return
            }
        }

        // 乐观上屏：用户消息立即入列显示，提示词组装（向量检索/技能判定的
        // 网络往返）不再挡在气泡出现之前；落盘由 performSend 的 append 补齐。
        // 待回复占位同步置位：「正在思考」卡与用户气泡同帧出现——
        // 组装/压缩期间不再有「发了消息却毫无反应」的空窗（开流即无缝转正）。
        // 占位置位连带登记发起上下文（origin.storeOrigin → streamContexts）：
        // 待回复窗口即计入 isVersionBusy（版本级 busy 判据），防「占位期版本判空闲」竞态。
        // 草稿预演会话：分派按草稿推进位置（非主线 pipeline.stage）。
        let stage = draftStage ?? pipeline.stage
        let roundLimit = PipelineEngine.clarifyRoundLimit
        // 发起上下文快照（阶段 2）：提示词组装与生成的多轮网络往返期间，用户可能
        // 切换会话/项目——回复落盘、完成回调与闸口决策都以发起上下文为准。
        let origin = ReplyOrigin(
            project: project, version: version,
            sessionId: sessionStore.sessionId, stage: stage
        )
        let stagedUser = sessionStore.stageOutgoingUser(
            text, imageFiles: imageFiles, fileRefs: fileRefs
        )
        // Agent 工具运行时（Function Calling v1）：总开关 / provider 降级在此收口；
        // nil = 本轮不带 tools（SessionStore 行为与旧版完全一致）。
        let agentRuntime = agentToolRuntime(origin: origin)
        sessionStore.beginPreparingReply(sessionID: sessionStore.sessionId, origin: origin.storeOrigin)

        switch stage {
        case .clarify:
            let rounds = draftStage != nil ? 0 : pipeline.clarifyRounds
            // 澄清基底（新功能判断的上下文来源）：
            // - 增补模式（amend 标记在，从②③④回①）：当前版本表 = 修订基底，判断先行只问增量；
            // - 常规澄清：项目内最近有表的其他版本 = 背景参考（跨版本轻改并入点）；
            // - 草稿预演：不带主线增补态与主线/历史表（草稿从干净澄清开始）。
            let amending = draftStage == nil && pipeline.isAmendingClarify
            let previousTable = draftStage != nil
                ? nil
                : (amending
                    ? Self.readArtifact(project: project, version: version, rel: ArtifactPath.clarification)
                    : Self.readPreviousVersionClarification(project: project, version: version))
            let clarifyPrompt = await assembleSystemPrompt(
                stage: .clarify, userMessage: text, origin: origin,
                volatileTail: AgentPrompts.clarifyStateSection(
                    rounds: rounds, limit: roundLimit,
                    previousTable: previousTable, amending: amending
                ),
                toolsSection: agentRuntime != nil
            ) { injection in
                AgentPrompts.clarify(injection: injection)
            }
            await sessionStore.send(
                text, settings: settings, stage: .clarify,
                systemPrompt: clarifyPrompt.prompt, imageFiles: imageFiles,
                fileRefs: fileRefs, skills: clarifyPrompt.skills,
                knowledgeRefs: knowledgeRefsFromAssembly(),
                stagedUserEntry: stagedUser, pinnedOrigin: origin.storeOrigin,
                tools: agentRuntime
            ) { [weak self] reply, _ in
                self?.handleClarifyTurn(reply, origin: origin)
            }

        case .structure:
            // 草稿预演：结构生成注入草稿要点表（提案目录镜像），非主线表
            let clarification: String
            if draftStage != nil {
                clarification = Self.readArtifact(
                    root: PMAgentStore.artifactRoot(
                        project: project, version: version, proposalSessionId: sessionStore.sessionId
                    ),
                    rel: ArtifactPath.clarification
                ) ?? "（草稿要点表缺失——回复「进入下一阶段」先生成）"
            } else {
                clarification = Self.readArtifact(
                    project: project, version: version, rel: ArtifactPath.clarification
                ) ?? "（要点表缺失）"
            }
            // 产物迭代轮阶段文案（2026-09-18）：长回合（提示词组装 + 产物全文重输出）
            // 等待显性化，头行不再只有通用「正在思考…」。措辞中性（「处理请求」
            // 不断言修改/讨论意图——消息类型判定交给模型）。streamReply 收尾统一清键，
            // 无需手动清理。
            sessionStore.setStreamPhase("正在处理结构产物请求…", for: origin.sessionId)
            let structurePrompt = await assembleSystemPrompt(
                stage: .structure, userMessage: text, origin: origin,
                toolsSection: agentRuntime != nil
            ) { injection in
                AgentPrompts.structure(
                    clarification: clarification,
                    previousArtifacts: draftStage != nil
                        ? nil  // 草稿预演：不注入主线旧结构产物（草稿独立演进）
                        : Self.readStructureArtifactsBundle(
                            project: project, version: version
                        ),
                    injection: injection
                )
            }
            await sessionStore.send(
                text, settings: settings, stage: .structure,
                systemPrompt: structurePrompt.prompt, maxTokens: LLMClient.artifactMaxTokens,
                imageFiles: imageFiles, fileRefs: fileRefs, skills: structurePrompt.skills,
                knowledgeRefs: knowledgeRefsFromAssembly(),
                stagedUserEntry: stagedUser, pinnedOrigin: origin.storeOrigin,
                tools: agentRuntime
            ) { [weak self] reply, _ in
                self?.handleAssistantReply(reply, origin: origin)
            }

        case .prototype:
            // E17a：未确认结构不得生成原型（闸口拦截）；草稿预演绕行主线闸口
            //（草稿推进位置即闸口——结构草稿在盘才可能推进到 .prototype）
            guard draftStage != nil || pipeline.canGeneratePrototype else {
                sessionStore.endPreparingReply(sessionID: origin.sessionId)  // 闸口早退不生成：占位气泡收起
                try? sessionStore.append(stagedUser)  // 早退路径补落盘（乐观上屏尚未持久化）
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "🔒 结构产物还没有确认——确认后才能生成原型。"
                    )
                )
                return
            }
            sessionStore.setStreamPhase("正在处理原型请求…", for: origin.sessionId)
            let prompt = await prototypePrompt(
                userMessage: text, origin: origin, toolsEnabled: agentRuntime != nil
            )
            await sessionStore.send(
                text, settings: settings, stage: .prototype,
                systemPrompt: prompt.prompt, maxTokens: LLMClient.artifactMaxTokens,
                imageFiles: imageFiles, fileRefs: fileRefs, skills: prompt.skills,
                knowledgeRefs: knowledgeRefsFromAssembly(),
                stagedUserEntry: stagedUser, pinnedOrigin: origin.storeOrigin,
                prototypeSnapshot: prompt.snapshot,
                tools: agentRuntime
            ) { [weak self] reply, prototypeSnapshot in
                self?.handleAssistantReply(reply, origin: origin, prototypeSnapshot: prototypeSnapshot)
            }

        case .prd:
            // E15a：未确认原型不得生成 PRD（闸口拦截）
            guard pipeline.canGeneratePRD else {
                sessionStore.endPreparingReply(sessionID: origin.sessionId)  // 闸口早退不生成：占位气泡收起
                try? sessionStore.append(stagedUser)  // 早退路径补落盘（乐观上屏尚未持久化）
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
                    try? sessionStore.append(stagedUser)  // 系统轮路径补落盘
                    await generatePRD(
                        tierOverride: tier,
                        note: "🎚️ 已切换 \(tier) 档，重新生成 PRD",
                        origin: origin
                    )
                } else {
                    // 对话式迭代：反馈驱动修订，重新输出完整 artifact:prd 块；
                    // 旧 PRD 全文注入作修订基底（否则模型看不到上一版，「原样保留」无从谈起）
                    sessionStore.setStreamPhase("正在处理 PRD 请求…", for: origin.sessionId)
                    let prdIterationPrompt = await prdSystemPrompt(
                        tier: currentPRDTier ?? "standard",
                        userMessage: text, origin: origin,
                        toolsEnabled: agentRuntime != nil
                    )
                    let previousPRD = Self.readArtifact(
                        project: project, version: version, rel: ArtifactPath.prd
                    )
                    let baseSection = AgentPrompts.revisionBaseSection(
                        title: "PRD", previous: previousPRD
                    )
                    // 模式头不武断断言「用户消息是修改反馈」（2026-09-18 思考空转个案
                    // 分析：生成类请求「帮我出PRD」同样进本分支）；无新修改点且基底
                    // 一致时不重排（2026-09-18 第五批：重复生成请求的全量重排是纯转抄，
                    // 单轮烧 30k 输出 + 长思考）。三类意图规则见 prdIterationModeHeader。
                    let modeHeader = Self.prdIterationModeHeader(hasBase: !baseSection.isEmpty)
                    await sessionStore.send(
                        text, settings: settings, stage: .prd,
                        systemPrompt: prdIterationPrompt.prompt + modeHeader + baseSection
                            + "\n反馈本身存在歧义时优先按上方歧义处理规则暂停确认，本轮不修订；"
                            + "若反馈针对上游产物（原型/结构）而非 PRD 本身，"
                            + "按回退请求协议输出 artifact:backtrack 块，不修订 PRD。",
                        maxTokens: LLMClient.artifactMaxTokens,
                        imageFiles: imageFiles, fileRefs: fileRefs,
                        skills: prdIterationPrompt.skills,
                        knowledgeRefs: knowledgeRefsFromAssembly(),
                        stagedUserEntry: stagedUser, pinnedOrigin: origin.storeOrigin,
                        tools: agentRuntime
                    ) { [weak self] reply, _ in
                        self?.handleAssistantReply(reply, origin: origin)
                    }
                }
            } else if pipeline.stoppedHere {
                // ③ 停驻态（到原型为止，2026-09-17 路径选择）：不自动出 PRD，
                // 转常规对话——用户明确要续出时，AI 按快速通道协议输出 fast-forward
                // 块（handleAssistantReply 受理续接，prd→prd 仅停驻态放行）。
                let prdChatPrompt = await prdSystemPrompt(
                    tier: currentPRDTier ?? "standard", userMessage: text, origin: origin
                )
                await sessionStore.send(
                    text, settings: settings, stage: .prd,
                    systemPrompt: prdChatPrompt.prompt
                        + "\n\n当前模式：停驻——本版到原型为止，暂不撰写 PRD。用户消息按对话处理："
                        + "回答问题、讨论原型均正常作答；用户明确要出 PRD（如「出 PRD」「现在写 PRD」）时，"
                        + "在正文用一句话确认后输出（不要直接撰写 PRD）：\n"
                        + "```artifact:fast-forward\n"
                        + "{\"target\": \"prd\", \"instruction\": \"用户对 PRD 的具体要求，没有则填空串\"}\n"
                        + "```\n",
                    maxTokens: LLMClient.artifactMaxTokens,
                    imageFiles: imageFiles, fileRefs: fileRefs,
                    skills: prdChatPrompt.skills,
                    knowledgeRefs: knowledgeRefsFromAssembly(),
                    stagedUserEntry: stagedUser, pinnedOrigin: origin.storeOrigin
                ) { [weak self] reply, _ in
                    self?.handleAssistantReply(reply, origin: origin)
                }
            } else {
                // 首次进入 ④：评分卡选档 + 模板路由生成
                try? sessionStore.append(stagedUser)  // 系统轮路径补落盘
                await generatePRD(tierOverride: nil, origin: origin)
            }
        }

        reloadTree()
    }

    // MARK: - 后台完成语义（阶段 2）：origin 快照与 origin 口径落盘

    /// 后台完成落盘的归属上下文快照：发送/确认链入口快照一次、全链显式传递——
    /// 落盘段、系统行归属与闸口触发决策都以发起上下文为准，不随用户中途
    /// 切换会话/项目漂移。internal 供单测驱动后台完成路径。
    struct ReplyOrigin {
        var project: String
        var version: String
        var sessionId: String
        /// 发起阶段：落盘段按发起阶段的产物协议解析（不读当前 pipeline——
        /// 跨上下文后台完成时那是另一个上下文的引擎）。
        var stage: PipelineRun.Stage

        /// SessionStore 落盘通道的 origin（appendPinned / makeEntry(sessionID:)）。
        var storeOrigin: SessionStore.StreamOrigin {
            SessionStore.StreamOrigin(project: project, version: version, sessionId: sessionId)
        }
        /// 派生：同源不同阶段的快照（确认链每一跳按该跳阶段解析产物）。
        func with(stage: PipelineRun.Stage) -> ReplyOrigin {
            var copy = self
            copy.stage = stage
            return copy
        }
    }

    /// origin 是否即当前 pipeline 上下文（同版本共享 PipelineEngine 实例：
    /// 闸口推进 / 引擎状态写对同版本安全；跨版本时引擎实例可能已被替换）。
    private func originIsCurrentContext(_ origin: ReplyOrigin) -> Bool {
        origin.project == pipeline.project && origin.version == pipeline.version
    }

    /// 链体对版本引擎的访问口（M3 确认链 origin 化）：origin 即当前上下文 →
    /// 活实例（推进/确认直接生效）；异上下文 → 按 origin 重建一次性实例——
    /// 闸口/阶段状态以磁盘标记为事实源、运行态在 pipeline_runs 表，重建推进
    /// 即持久化，无状态丢失（写完即弃，不回填 AppModel.pipeline）。
    private func pipelineEngine(for origin: ReplyOrigin) -> PipelineEngine {
        originIsCurrentContext(origin)
            ? pipeline
            : PipelineEngine(project: origin.project, version: origin.version, database: database)
    }

    /// 链体对版本风险台账的访问口（M3）：同上，异上下文自建 store 落 origin 版本。
    private func riskStore(for origin: ReplyOrigin) -> RiskStore {
        originIsCurrentContext(origin)
            ? risks
            : RiskStore(project: origin.project, version: origin.version)
    }

    /// 系统行落回 origin 会话（后台完成落盘段专用）：条目 sessionId 钉 origin、
    /// 落盘走 origin 的 jsonl——即使该会话不在前台；当前打开的恰是该会话时
    /// 照常并入内存消息流（appendPinned 自带收纳）。
    private func appendOriginSystem(
        _ content: String,
        origin: ReplyOrigin,
        fileChanges: [FileChangeSummary]? = nil,
        milestones: [MilestoneStamp]? = nil,
        silent: Bool? = nil
    ) {
        let entry = sessionStore.makeEntry(
            role: .system, content: content,
            fileChanges: fileChanges, milestones: milestones,
            silent: silent,
            sessionID: origin.sessionId
        )
        try? sessionStore.appendPinned(entry, origin: origin.storeOrigin)
    }

    /// 闸口推进触发（后台完成语义）：origin 与当前上下文同版本 → 照常启动机器门
    /// （共享 pipeline 实例，安全）；跨版本/项目后台完成**不触发**——自动重生成与
    /// 确认推进针对的是不可见引擎，落挂起提示行到 origin 会话，用户回到该会话
    /// 再处理（系统行走现有 ⚠️ 告警色通道）。
    private func scheduleStageGateIfCurrent(_ stage: PipelineRun.Stage, origin: ReplyOrigin) {
        guard originIsCurrentContext(origin) else {
            appendOriginSystem(
                "⚠️ 回复已完成，产物已更新——阶段推进（机器初审 / 确认）需回到发起会话处理。",
                origin: origin
            )
            return
        }
        scheduleStageGate(stage, origin: origin)
    }

    /// assistant 回复的产物解析与落盘（②③④ 阶段）+ 横切处理（雷达/决策，全阶段）。
    /// 阶段 2 后台完成语义：**以 origin 口径无条件执行**——产物写 origin 的版本目录、
    /// 系统行落回 origin 会话（appendPinned 钉 origin.sessionId，即使该会话不在前台）、
    /// 事件日志记 origin 版本。横切（雷达/决策）与协议块（backtrack / fast-forward）
    /// 绑定当前 pipeline 实例，跨上下文后台完成时跳过（回复本身已按 origin 落盘，
    /// 回到该上下文可从磁盘对账；横切的 origin 化留待后续阶段）。internal 供单测驱动。
    /// - Parameter prototypeSnapshot: 原型冲突检测快照（阶段 4，相对路径 → 发起时
    ///   槽位全文 SHA256，经发送链 onAssistant 回调透传而来）；nil = 不做乐观校验
    ///   （非原型阶段 / followUp 续发轮 / 直接调用）。
    func handleAssistantReply(
        _ reply: DiscussionEntry, origin: ReplyOrigin,
        prototypeSnapshot: [String: String]? = nil
    ) {
        // 草稿预演会话（B1）：产物镜像落提案目录，不进主线横切/闸口/变更分诊——
        // 预演链独立于主线状态机，合并入主线由变更池显式动作触发。
        if let sid = draftSessionId(of: origin) {
            handleDraftReply(
                reply, origin: origin,
                proposalSessionId: sid, prototypeSnapshot: prototypeSnapshot
            )
            return
        }
        let sameContext = originIsCurrentContext(origin)
        if sameContext {
            processCrossCutting(reply)
        }
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)

        // 快速通道进行中：忽略链中误发的协议块（防 backtrack 回滚状态机 / fast-forward 自触发回环）。
        // 运行态按 origin 版本键控（M2）：跨版本并行互不干扰。
        if sameContext, !fastForwardVersions.contains(VersionKey(origin)) {
            // 变更提案块（变更分诊回路）：LLM 识别新需求/要重做上游 → 只分诊提案，
            // 不再自动执行回退——提案落 changes.jsonl（pending）+ 聊天流变更提案卡，
            // 纳入 / 进池 / 继续讨论由用户裁决（「Agent 准备，用户改版」）。
            // 受理条件：pool 建议（target 可省略）或「向上游回退」的合法目标；
            // target 非法或 = 当前阶段 → 模型误判，忽略块走正常产物流程（不 return，防死轮）。
            // ②③④ 受理（target=clarify 即增补澄清：新功能先回①判断可行性，不静默并入下游产物）。
            if let request = ArtifactParser.parseBacktrack(blocks: blocks),
               pipeline.stage != .clarify {
                let wantsPool = request.suggestion?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "pool"
                let validatedTarget = request.target.flatMap { Self.backtrackStage($0) }
                if wantsPool || (validatedTarget != nil && validatedTarget != pipeline.stage) {
                    presentChangeProposal(request)
                    return
                }
            }

            // 快速通道块（skip 语义，2026-09-17 路径选择改义）：「直接出 X」= 直达 X，
            // 中间阶段跳过（写 skipped.json，不生成产物）。
            // 目标合法但前置产物不在盘 → 说明原因后忽略，继续正常产物处理（不 return，防死轮）。
            if let request = ArtifactParser.parseFastForward(blocks: blocks),
               let target = Self.fastForwardTarget(
                   request.target, from: pipeline.stage, prdOnDisk: prdOnDisk
               ) {
                let preconditionMet: Bool
                switch pipeline.stage {
                case .clarify:
                    preconditionMet = true  // ① 是起点：要点表由确认链收束，无前置产物
                case .structure where structureArtifactsOnDisk: preconditionMet = true
                case .prototype where prototypeOnDisk: preconditionMet = true
                case .prd: preconditionMet = !prdOnDisk  // 停驻续出：PRD 未落盘才需要
                default: preconditionMet = false
                }
                if preconditionMet {
                    // 静默行：受理语义由快速通道目标回合的 AI 开场承接句承载（UI 不渲染）
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: "⚡ 快速通道：已按你的要求直达\(target == .prototype ? "原型" : "PRD")（中间阶段按路径选择跳过、可事后补做，产物落盘）。",
                            silent: true
                        )
                    )
                    Task { await self.runFastForward(to: target, instruction: request.instruction, origin: origin) }
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
        // radar/decision 也不会有，整个回复会在这里被提前 return 掉。origin 口径：
        // 按发起阶段判定，草稿写 origin 版本目录。
        if origin.stage == .prd, !blocks.contains(where: { $0.name == "prd" }),
           let draft = ArtifactParser.prdTruncatedDraft(from: reply.content) {
            writePRDTruncatedDraft(draft, origin: origin)
        }
        // stray PRD 块兜底（2026-09-17 静默丢弃事故）：非 PRD 阶段的回复携带 prd 块
        // （闭合可解析 / 未闭合截断）在本阶段分派里没有消费者，会被静默丢弃——
        // AI 正文宣称「PRD 全文如下」而用户拿不到任何文档。落 ⚠️ 系统行留痕并指向
        // 快速通道恢复路径。须在 blocks 空判之前（纯截断场景 blocks 为空）。
        if origin.stage != .prd,
           ArtifactParser.hasStrayPRDBlock(blocks: blocks, text: reply.content) {
            appendOriginSystem(
                "⚠️ 本轮回复携带 PRD 内容块，但 PRD 只能在 ④ 阶段或快速通道生成——本次未落盘。可回复「直接出 PRD」走快速通道。",
                origin: origin
            )
        }
        guard !blocks.isEmpty else { return }
        let project = origin.project
        let version = origin.version

        do {
            switch origin.stage {
            case .structure:
                if ArtifactParser.structureArtifactsComplete(blocks) {
                    let structure = try ArtifactParser.writeStructureArtifacts(
                        blocks: blocks, project: project, version: version
                    )
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: origin.stage.rawValue,
                        detail: "结构产物落盘（功能架构图 / 核心流程图 / 模块-页面映射表）",
                        project: project, version: version
                    )
                    appendOriginSystem(
                        fastForwardVersions.contains(VersionKey(origin))
                            ? "📦 结构产物已生成（快速通道：自动确认，继续生成 ③ 原型）"
                            : "📦 结构产物已生成——机器初审中……",
                        origin: origin,
                        fileChanges: structure.changes,
                        milestones: [MilestoneStamp(
                            kind: "stage",
                            label: "结构产物",
                            nextAction: "确认后 AI 随即生成 ③ 原型"
                        )]
                    )
                    // 快速通道中间产物跳过机器门（最终产物放行，由 runFastForward 链尾评审）；
                    // 判定按 origin 口径：本产物阶段 == 该版本快速通道的最终目标才过门
                    let ffFinalStructure = fastForwardFinalStages[VersionKey(origin)]
                    if ffFinalStructure == nil || ffFinalStructure == origin.stage {
                        scheduleStageGateIfCurrent(.structure, origin: origin)
                    }
                }
            case .prototype:
                // 阶段 4 冲突分槽：expectedSnapshot 失配（原型已被另一对话/外部更新）
                // → 后写者分槽并立，冲突块改落修订文件，主槽位不被触碰（见
                // writePrototypeRevision）；其余错误照常走外层通用 ⚠️ 行。
                let prototype: ArtifactParser.PrototypeArtifacts?
                do {
                    prototype = try ArtifactParser.writePrototypeArtifact(
                        blocks: blocks, project: project, version: version,
                        expectedSnapshot: prototypeSnapshot
                    )
                } catch let conflict as ArtifactParser.ArtifactConflict {
                    prototype = try writePrototypeRevision(
                        after: conflict, blocks: blocks,
                        project: project, version: version, origin: origin
                    )
                }
                if let prototype {
                    // 端短名（display 去「交互原型 · 」前缀；默认槽位 / 混出兜底用 display 原文）
                    let shortName: (String) -> String = { display in
                        display.hasPrefix("交互原型 · ")
                            ? String(display.dropFirst("交互原型 · ".count))
                            : display
                    }
                    let displays = prototype.slots.map(\.display)
                    let isMulti = displays.count > 1
                    let endsText = displays.map(shortName).joined(separator: "、")
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: origin.stage.rawValue,
                        detail: isMulti ? "原型落盘（\(endsText)）" : "交互原型落盘（单文件 HTML）",
                        project: project, version: version
                    )
                    let head = isMulti
                        ? "📦 交互原型已生成（\(displays.map(shortName).joined(separator: " + "))）"
                        : "📦 交互原型已生成"
                    appendOriginSystem(
                        fastForwardVersions.contains(VersionKey(origin))
                            && fastForwardFinalStages[VersionKey(origin)] != origin.stage
                            ? "\(head)（快速通道：自动确认，继续撰写 ④ PRD）"
                            : "\(head)——机器初审中……",
                        origin: origin,
                        fileChanges: prototype.changes,
                        milestones: [MilestoneStamp(
                            kind: "stage",
                            label: "原型",
                            nextAction: "确认后 AI 随即撰写 ④ PRD"
                        )]
                    )
                    // 部分截断兜底：多端输出中某端围栏未闭合 → 该端未落盘（其余端已落盘），单独提示
                    let written = Set(prototype.slots.map(\.blockName))
                    if let incomplete = ArtifactParser.parseIncompleteArtifact(in: reply.content),
                       !incomplete.name.isEmpty,
                       ArtifactPath.isPrototypeBlock(incomplete.name),
                       !written.contains(incomplete.name) {
                        let label = ArtifactPath.prototypeSlot(forBlockName: incomplete.name)?.display ?? "原型"
                        appendOriginSystem(
                            "⚠️ \(label) HTML 输出被截断（未闭合）——该端本次未落盘。可回复「继续出原型」重试；反复截断时建议换更轻量的模型或缩小页面范围。",
                            origin: origin
                        )
                    }
                    // 快速通道中间产物跳过机器门（target=prd 时）；target=prototype 时放行
                    //（origin 口径：本产物阶段 == 该版本快速通道的最终目标才过门）
                    let ffFinalPrototype = fastForwardFinalStages[VersionKey(origin)]
                    if ffFinalPrototype == nil || ffFinalPrototype == origin.stage {
                        scheduleStageGateIfCurrent(.prototype, origin: origin)
                    }
                } else if let incomplete = ArtifactParser.parseIncompleteArtifact(in: reply.content),
                          !incomplete.name.isEmpty,
                          ArtifactPath.isPrototypeBlock(incomplete.name) {
                    // 截断兜底诊断：回复里有未闭合的原型类围栏（续写 2 轮后仍未闭合）
                    // → 块解析不到、落盘被跳过——静默会让用户以为「没生成」，留一条可行动的提示。
                    let label = incomplete.name == "prototype"
                        ? "原型"
                        : (ArtifactPath.prototypeSlot(forBlockName: incomplete.name)?.display ?? "原型")
                    appendOriginSystem(
                        "⚠️ \(label) HTML 输出被截断（未闭合）——本次未落盘。可回复「继续出原型」重试；反复截断时建议换更轻量的模型或缩小页面范围。",
                        origin: origin
                    )
                }
            case .prd:
                // 档位读 origin 的 score-card（跨上下文时 currentPRDTier 读的是当前上下文）
                let tier = Self.readPRDTier(project: project, version: version) ?? "standard"
                if let prd = try ArtifactParser.writePRDArtifact(
                    blocks: blocks, tier: tier,
                    project: project, version: version
                ) {
                    // 版本戳先于清过期：落盘即记录生成所用模板版本，重启检查才不会误标
                    Self.writePRDMeta(project: project, version: version, tier: tier)
                    if sameContext {
                        pipeline.clearPRDStale()
                    }
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: origin.stage.rawValue,
                        detail: "PRD 落盘（\(tier) 档）",
                        project: project, version: version
                    )
                    appendOriginSystem(
                        "📦 产品需求文档已生成——数据指标与验收用例见文内。",
                        origin: origin,
                        fileChanges: prd.changes,
                        milestones: [MilestoneStamp(
                            kind: "stage",
                            label: "产品需求文档",
                            nextAction: "审阅后可在项目页封板版本"
                        )]
                    )
                }
            default:
                break
            }
        } catch {
            appendOriginSystem(
                "⚠️ 产物保存失败：\(error.localizedDescription)", origin: origin
            )
        }
        // 引擎状态回读与闸口归属刷新：仅 origin == 当前上下文时执行——跨上下文
        // 后台完成时 engine 实例不在场，sync 不可见引擎还会误触发 UI 刷新；回到
        // 该上下文时 switchContext 重建实例，自然对账磁盘。
        if sameContext {
            pipeline.syncFromDisk()
            refreshGateOwner()
        }
        // PRD 落盘成功后的 Git 快照（非闸口，但属重要产物节点）——origin 口径
        if origin.stage == .prd && Self.prdOnDisk(project: project, version: version) {
            snapshotProject(message: "prd: PRD 生成", project: project, version: version)
        }
    }

    // MARK: - 原型冲突分槽与台账选主（阶段 4）

    /// 原型冲突降级（「后写者分槽并立」）：expectedSnapshot 失配说明原型已被
    /// 另一对话或外部更新——本次生成不覆盖任何现有槽位文件。冲突块改落
    /// 「原型-修订-<MMdd-HHmm>[-N].html」修订文件（新文件不做乐观校验），
    /// 未冲突块照常落原路径；修订成功后落 ⚠️ 人话系统行（appendOriginSystem）+
    /// 事件留痕（detail 注明冲突分槽），📦 fileChanges 系统行由调用方照常落
    ///（changes 已含修订路径）。主槽位文件全程不被触碰。
    private func writePrototypeRevision(
        after conflict: ArtifactParser.ArtifactConflict,
        blocks: [ArtifactParser.ArtifactBlock],
        project: String, version: String,
        origin: ReplyOrigin
    ) throws -> ArtifactParser.PrototypeArtifacts? {
        // 冲突路径反查块名（构造 slotOverrides 的键）；反查不到（非原型槽位路径，
        // 理论不可达）上抛走外层通用 ⚠️ 行，不许无声。
        guard let blockName = ArtifactPath.prototypeBlockName(forRelativePath: conflict.path) else {
            throw conflict
        }
        let revisionRel = Self.reserveRevisionPrototypePath(project: project, version: version)
        let result = try ArtifactParser.writePrototypeArtifact(
            blocks: blocks, project: project, version: version,
            expectedSnapshot: nil,  // 修订路径是新文件，不校验
            slotOverrides: [blockName: revisionRel]
        )
        PipelineEventLog.append(
            kind: .artifactGenerated, stage: origin.stage.rawValue,
            detail: "原型冲突分槽：\(conflict.path) 已被另一对话或外部更新，本次生成改落 \(revisionRel)",
            project: project, version: version
        )
        appendOriginSystem(
            "⚠️ 原型已被另一对话或外部更新，本次生成已存为"
                + "「\((revisionRel as NSString).lastPathComponent)」，未覆盖现有原型"
                + "——可在产物台账中对比后「设为主原型」。",
            origin: origin
        )
        return result
    }

    /// 修订原型落点：03-prototypes/原型-修订-<MMdd-HHmm>.html；目标已存在
    /// （同分钟多次冲突）→ 追加 -2/-3… 序号防覆盖（探测-递增）。nonisolated static
    /// 供单测注入固定 now 做确定性断言。
    nonisolated static func reserveRevisionPrototypePath(
        project: String, version: String, now: Date = Date()
    ) -> String {
        // 纯数字时间戳：固定 en_US_POSIX + 公历，防用户非公历日历（佛历/和历）
        // 混入非数字字符破坏文件名与 -N 序号口径。
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        let base = "03-prototypes/原型-修订-\(formatter.string(from: now))"
        var candidate = base + ".html"
        var seq = 2
        while FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(candidate).path
        ) {
            candidate = "\(base)-\(seq).html"
            seq += 1
        }
        return candidate
    }

    /// 台账「设为主原型」可见性：非主槽位的原型槽位文件（修订 / 方案 / 未知 slug，
    /// 03-prototypes/原型-*.html）才可设主；主槽位（可点击原型.html）、分端槽位
    /// （移动端/桌面端/平板端原型）与非原型文件不在列。nonisolated static 供单测。
    nonisolated static func isPromotablePrototypePath(_ relativePath: String) -> Bool {
        relativePath.hasPrefix("03-prototypes/原型-") && relativePath.hasSuffix(".html")
    }

    /// 产物台账「设为主原型」（阶段 4 选主）：把指定原型槽位文件全文写入主槽位
    /// 「可点击原型.html」（writeVerified 自带 ioLock 原子段与 artifacts.changed
    /// 广播）。读失败 / 版本 busy（防与流完成落盘竞态）即通知条报错返回、不写盘
    /// ——失败必须可见；成功后系统行留痕（落当前会话）+ 事件留痕。
    func setAsMasterPrototype(relativePath: String) {
        guard let ctx = selection.inspectorProject else {
            notif = DSNotifMessage(
                variant: .error, title: "设为主原型失败",
                description: "当前没有可操作的项目上下文"
            )
            return
        }
        let project = ctx.project
        let version = ctx.version
        // 该版本有流/待回复进行中时不执行：流完成会写原型槽位，交叉覆盖。
        guard !sessionStore.isVersionBusy(project: project, version: version) else {
            notif = DSNotifMessage(
                variant: .error, title: "设为主原型失败",
                description: "该版本正在生成中，请稍后再试"
            )
            return
        }
        let sourceURL = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            notif = DSNotifMessage(
                variant: .error, title: "设为主原型失败",
                description: "源文件读取失败：\(relativePath)"
            )
            return
        }
        do {
            try PMAgentStore.writeVerified(
                content,
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(ArtifactPath.prototype)
            )
        } catch {
            notif = DSNotifMessage(
                variant: .error, title: "设为主原型失败",
                description: error.localizedDescription
            )
            return
        }
        let sourceName = (relativePath as NSString).lastPathComponent
        try? sessionStore.append(sessionStore.makeEntry(
            role: .system,
            content: "📌 已将「\(sourceName)」设为主原型（可点击原型.html 已更新）。"
        ))
        PipelineEventLog.append(
            kind: .artifactGenerated, stage: pipeline.stage.rawValue,
            detail: "原型选主：\(sourceName) → 可点击原型.html",
            project: project, version: version
        )
    }

    // MARK: - 机器门（s17 独立评估器 · 两道门：Tier1 确定性 + Tier2 独立 LLM 评审）

    /// 版本级运行态键（M2 并行化）：机器门 / 快速通道 / 采纳落实的运行态按
    /// (project, version) 分片——跨版本并行互不干扰；同版本共享单飞语义
    /// （与 isVersionBusy 闸口口径一致：结构写单写者）。
    struct VersionKey: Hashable {
        let project: String
        let version: String
        init(_ project: String, _ version: String) {
            self.project = project
            self.version = version
        }
        init(_ origin: ReplyOrigin) {
            self.init(origin.project, origin.version)
        }
    }

    /// 自动重生成计数（stage rawValue → 已用次数，上限 2）；
    /// 阶段切换或用户驱动的新一轮生成时清零（按版本分片）。
    private var gateAttempts: [VersionKey: [String: Int]] = [:]
    private var lastGateStages: [VersionKey: PipelineRun.Stage] = [:]
    /// 机器门自动重生成进行中（区分用户驱动的新一轮生成，控制计数清零）。
    private var autoRegenVersions: Set<VersionKey> = []
    /// 快速通道进行中（跳步串链：收束当前阶段 → 生成中间产物并确认 → 目标产物落盘）。
    /// 链中忽略 backtrack / fast-forward 协议块防自触发回环；机器门只对 finalStage 放行。
    private var fastForwardVersions: Set<VersionKey> = []
    private var fastForwardFinalStages: [VersionKey: PipelineRun.Stage] = [:]

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
    /// 阶段 2 后台完成语义：计轮/收束/横切都绑定当前 pipeline 实例——跨上下文后台
    /// 完成时跳过（回复已按 origin 落盘；澄清收束需在发起上下文的引擎上推进，
    /// 用户回到该会话后可「进入下一阶段」手动收束，origin 化收束留后续阶段）。
    private func handleClarifyTurn(_ reply: DiscussionEntry, origin: ReplyOrigin) {
        // 草稿预演会话：澄清轮只落对话流，不计主线轮次/不触主线收束
        //（草稿推进由对话指令 draftAdvance 驱动）
        guard draftSessionId(of: origin) == nil else { return }
        guard originIsCurrentContext(origin) else { return }
        processCrossCutting(reply)
        // 快速通道（跳步）：LLM 识别「直接出原型/PRD」→ 解析协议块，串链自动收束 + 生成。
        // 在计轮之前拦截：不计轮、不触发质量门/耗尽收束；白名单外（如 target=structure）
        // 视为模型误判，忽略块照常走澄清。
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)
        if let request = ArtifactParser.parseFastForward(blocks: blocks),
           let target = Self.fastForwardTarget(
               request.target, from: pipeline.stage, prdOnDisk: prdOnDisk
           ) {
            // 静默行：受理语义由快速通道目标回合的 AI 开场承接句承载（UI 不渲染）
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚡ 快速通道：已按你的要求直达\(target == .prototype ? "原型" : "PRD")（中间阶段按路径选择跳过、可事后补做，产物落盘）。",
                    silent: true
                )
            )
            PipelineEventLog.append(
                kind: .stageAdvance, stage: pipeline.stage.rawValue,
                detail: "快速通道受理：跳步至 \(target.rawValue)",
                reason: "fast_forward", project: pipeline.project, version: pipeline.version
            )
            Task { await self.runFastForward(to: target, instruction: request.instruction, origin: origin) }
            return
        }
        pipeline.bumpClarifyRound()
        // 最新 assistant 回合落在本会话 → 澄清闸口归属随之迁移（两个收束路径共用）
        refreshGateOwner()
        // 质量门优先（s17 借鉴）：雷达无缺项 + 覆盖充分 → 质量收束，省空转轮次
        // 收束系统行钉 origin 会话（阶段 3：同版本跨会话场景不串归属）
        if clarifyQualityGatePassed(reply: reply) {
            appendOriginSystem(
                "✅ 质量门通过：漏项雷达无缺项、自检覆盖充分——澄清自动收束，生成要点表并进入 ② 结构。",
                origin: origin
            )
            Task { await confirmCurrentStage() }
            return
        }
        // 5 轮耗尽 → 强制收束（缺失项入 open_questions，不阻塞流水线）；
        // 受理行先行落盘：链式续段判定据此并入首回合回答头（与质量门收束同权）
        if pipeline.clarifyExhausted {
            appendOriginSystem(
                "⏳ 澄清轮次已达上限——澄清自动收束，缺失项记入要点表 open_questions，进入 ② 结构。",
                origin: origin
            )
            Task { await confirmCurrentStage() }
        }
    }

    /// 产物落盘后启动机器门评审（异步，不阻塞聊天流）。
    /// origin 快照下传（阶段 3）：评审链的系统行（ℹ️/✅/⚠️/🔄）与自动重生成回合
    /// 一律钉**发起会话**——同版本跨会话场景（A 发起、用户停在 B）不串行归属。
    /// 计数与重生成运行态按 origin 版本键控（M2）：跨版本并行评审互不踩计数。
    private func scheduleStageGate(_ stage: PipelineRun.Stage, origin: ReplyOrigin) {
        let key = VersionKey(origin)
        let freshRound = !autoRegenVersions.contains(key)
        autoRegenVersions.remove(key)
        if stage != lastGateStages[key] {
            lastGateStages[key] = stage
            gateAttempts[key] = [:]
        }
        Task { await evaluateStageGate(stage, freshRound: freshRound, origin: origin) }
    }

    /// 机器门主体：Tier1 确定性检查（零成本）→ Tier2 独立 LLM 评审。
    /// 不过 → 自动重生成（带修正指令，上限 2 次）→ 仍不过 → 附机器发现交人工裁决；
    /// 人工确认闸口全程可用——机器门只过滤垃圾，最终裁决权在人。
    /// 系统行归属钉 origin 会话（appendOriginSystem）：评审是异步链，期间用户
    /// 可能停在别的会话——评审结论必须落回发起它的会话。
    /// project/version 取 origin 快照（M3）：评审 Task 起跑晚于调度，期间用户
    /// 可能切换上下文——活 pipeline 已是别处引擎，读它必漂移。
    private func evaluateStageGate(_ stage: PipelineRun.Stage, freshRound: Bool, origin: ReplyOrigin) async {
        let key = VersionKey(origin)
        if freshRound { gateAttempts[key, default: [:]][stage.rawValue] = 0 }
        let project = origin.project
        let version = origin.version

        // Tier 1：确定性检查（纯代码，零成本，永远开）
        var issues = Self.tier1Issues(stage: stage, project: project, version: version)
        let tier1Pass = issues.isEmpty

        // Tier 2：独立评审（Tier 1 失败不需要 LLM——机械问题直接修）
        var verdict: AgentPrompts.GateVerdict?
        if tier1Pass {
            let judged = await judgeStage(stage, project: project, version: version)
            guard let v = judged.verdict else {
                // 评审模型不可用：降级放行（机器门是旁路，不阻塞人工门）。
                // 真实失败原因透传进事件日志与会话行，不再一律笼统「不可用」。
                let why = judged.failureReason ?? "未知原因"
                PipelineEventLog.append(
                    kind: .gateEvaluated, stage: stage.rawValue,
                    detail: "Tier1 通过；Tier2 评审模型不可用（\(why)），降级放行至人工确认",
                    reason: "tier2_skipped", project: project, version: version
                )
                appendOriginSystem(
                    "ℹ️ 机器初审跳过（评审模型不可用：\(why)）——直接进入人工确认。",
                    origin: origin
                )
                return
            }
            verdict = v
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
            appendOriginSystem(
                "✅ 机器初审通过——\(verdict?.verdict ?? "确定性检查全部通过")。确认后进入 \(stage == .structure ? "③ 原型" : "④ PRD")。",
                origin: origin
            )
            return
        }

        let attempts = gateAttempts[key]?[stage.rawValue] ?? 0
        let issueList = issues.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        guard attempts < 2 else {
            appendOriginSystem(
                "⚠️ 机器初审未过（已自动修正 \(attempts) 次）：\n\(issueList)\n——已达自动修正上限，请人工裁决（确认闸口照常可用）。",
                origin: origin
            )
            return
        }
        gateAttempts[key, default: [:]][stage.rawValue] = attempts + 1
        appendOriginSystem(
            "🔄 机器初审未过，自动修正（第 \(attempts + 1)/2 次）：\n\(issueList)",
            origin: origin
        )
        await regenForGate(stage: stage, issues: issues, origin: origin)
    }

    /// Tier 2 独立评审：读盘上最新产物 → stageJudge prompt → oneShot JSON 解析。
    private func judgeStage(
        _ stage: PipelineRun.Stage, project: String, version: String
    ) async -> (verdict: AgentPrompts.GateVerdict?, failureReason: String?) {
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
            // 源码细节交给 Tier 1 机械检查，评审焦点放在页面覆盖与一致性。
            // 多端槽位逐端成段（总量仍 6000 字：按端数均分预算）
            let map = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.modulePageMap
            ) ?? "（缺失）"
            let slots = ArtifactPath.prototypeSlotFiles(project: project, version: version)
            let perSlotBudget = max(1, 6000 / max(slots.count, 1))
            var sections = slots.map { slot -> String in
                let html = Self.readArtifact(project: project, version: version, rel: slot.relPath)
                    ?? "（缺失）"
                let visible = String(WebTool.extractText(fromHTML: html).prefix(perSlotBudget))
                let title = slots.count == 1
                    ? "原型可见内容（HTML 正文提取）"
                    : "原型可见内容（\(slot.display)，HTML 正文提取）"
                return "### \(title)\n\(visible)"
            }
            if sections.isEmpty {
                sections = ["### 原型可见内容（HTML 正文提取）\n（缺失）"]
            }
            artifacts = "### 模块-页面映射表（上游锚点）\n\(map)\n\n\(sections.joined(separator: "\n\n"))"
        default:
            return (nil, "阶段 \(stage.rawValue) 未配置 Tier 2 评审")
        }
        // 思考型模型 reasoning 计入 max_tokens 输出池：评审输入大（映射表 + HTML 正文
        // 提取 6000 字），默认 2048 思考撞线、正文为空必抛空流（同澄清要点表坑）——
        // 给足 8192 + 失败重试 1 次，并把真实失败原因透传给调用方落日志。
        let prompt = AgentPrompts.stageJudge(stage: stage.rawValue, artifacts: artifacts)
        var result = await extractWithReason(
            AgentPrompts.GateVerdict.self, prompt: prompt, maxTokens: 8192
        )
        if result.value == nil {
            result = await extractWithReason(
                AgentPrompts.GateVerdict.self, prompt: prompt, maxTokens: 8192
            )
        }
        return (result.value, result.failureReason)
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
            // 多端槽位逐端检查；单槽位保持原文案（测试断言「空壳 / 外部资源引用」不破），
            // 多槽位时 issue 带槽位显示名前缀定位到端
            let slots = ArtifactPath.prototypeSlotFiles(project: project, version: version)
            if slots.isEmpty {
                issues.append("原型 HTML 缺失或为空")
            } else {
                for slot in slots {
                    let html = read(slot.relPath)
                    let prefix = slots.count == 1 ? "" : "\(slot.display)："
                    if html.isEmpty {
                        issues.append("\(prefix)原型 HTML 缺失或为空")
                        continue
                    }
                    if html.utf8.count < 2048 {
                        issues.append("\(prefix)原型 HTML 过小（< 2KB），疑似空壳")
                    }
                    // 外部资源引用检查（script/link/img 的 http(s) src/href）
                    if let regex = try? NSRegularExpression(
                        pattern: #"(?:<script[^>]+src|<link[^>]+href|<img[^>]+src)\s*=\s*["']https?://"#,
                        options: [.caseInsensitive]
                    ) {
                        let range = NSRange(html.startIndex..<html.endIndex, in: html)
                        if regex.firstMatch(in: html, options: [], range: range) != nil {
                            issues.append("\(prefix)原型含外部资源引用（CDN/外链），违反零外部依赖硬约束")
                        }
                    }
                }
            }
        default:
            break
        }
        return issues
    }

    /// 机器门打回：带修正指令自动重生成（修正指令并入 AI 回合，不占用户气泡；
    /// 新产物落盘后会再次过门，直至通过或达上限）。origin 由评审链下传（阶段 3）：
    /// 重生成回合钉发起会话/上下文，评审期间用户切会话不串归属。
    private func regenForGate(stage: PipelineRun.Stage, issues: [String], origin: ReplyOrigin) async {
        autoRegenVersions.insert(VersionKey(origin))
        let correction = issues.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let gateOrigin = origin.with(stage: stage)
        switch stage {
        case .structure:
            let clarification = Self.readArtifact(
                project: origin.project, version: origin.version,
                rel: ArtifactPath.clarification
            ) ?? "（缺失）"
            let systemPrompt = await assembleSystemPrompt(stage: .structure, origin: origin) { injection in
                AgentPrompts.structure(clarification: clarification, injection: injection)
            }
            await sessionStore.sendSystemTurn(
                note: nil,
                userPrompt: "机器初审发现以下问题，请修正后重新输出全部三项结构产物（完整产物块）：\n\(correction)"
                    + gateInviteSuffix(for: .structure, origin: origin),
                settings: settings, stage: .structure,
                systemPrompt: systemPrompt.prompt, maxTokens: LLMClient.artifactMaxTokens,
                skills: systemPrompt.skills, pinnedOrigin: gateOrigin.storeOrigin
            ) { [weak self] reply, _ in
                self?.handleAssistantReply(reply, origin: gateOrigin)
            }
        case .prototype:
            let systemPrompt = await prototypePrompt(origin: origin)
            await sessionStore.sendSystemTurn(
                note: nil,
                userPrompt: "机器初审发现以下问题，请修正后重新输出完整原型产物块（单文件 HTML）：\n\(correction)"
                    + gateInviteSuffix(for: .prototype, origin: origin),
                settings: settings, stage: .prototype,
                systemPrompt: systemPrompt.prompt, maxTokens: LLMClient.artifactMaxTokens,
                skills: systemPrompt.skills, pinnedOrigin: gateOrigin.storeOrigin,
                prototypeSnapshot: systemPrompt.snapshot
            ) { [weak self] reply, prototypeSnapshot in
                self?.handleAssistantReply(reply, origin: gateOrigin, prototypeSnapshot: prototypeSnapshot)
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

        // 漏项雷达：自评摘要落盘 + 连续 3 轮零修正告警（E16）+ 💀 登记（E16a）。
        // B3 事件驱动（2026-09-16）：契约与落盘全量保留（covered 审计走
        // self-review.jsonl → 右栏对账区块），对话流只报新增——❓/⏭️ 与
        // 同阶段历史归一化 diff 后仅新增上雷达行；💀 与台账全量去重后仅
        // 新登记上风险行；fixed 修正计数静默（对账区块「累计修正」承载）。
        if let radar = ArtifactParser.parseRadar(blocks: blocks) {
            let stageHistory = ArtifactParser.readSelfReviews(project: project, version: version)
                .filter { $0.stage == stageKey }
            let newMissing = ArtifactParser.newItems(
                current: radar.missing ?? [],
                previous: stageHistory.flatMap { $0.radar.missing ?? [] }
            )
            let newSkipped = ArtifactParser.newSkipped(
                current: radar.skipped ?? [],
                previous: stageHistory.flatMap { $0.radar.skipped ?? [] }
            ).count

            try? ArtifactParser.writeSelfReview(
                radar, stage: stageKey, project: project, version: version
            )
            // 右栏对账 trace 跟随每轮落盘刷新（风险登记另有 risks.changed 广播）
            NotificationCenter.default.post(
                name: Notification.Name("pm.worker.selfreview.changed"), object: nil
            )
            if pipeline.recordRadar(fixedCount: radar.fixed?.count ?? 0) {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "⚠️ 自评审失效告警：连续 3 轮零修正——自评审可能流于形式，请人工核查本阶段产物。"
                    )
                )
            }
            let freshRisks = registerFatalRisks(radar.fatal ?? [], stageKey: stageKey)
            let registered = freshRisks.count

            // 里程碑：自评审入账行（2026-09-18 合并——💀 风险与 ❓/⏭️ 新增同轮同源、
            // 同落点右栏「风险」，拆两行读感重复）：有新登记走琥珀「风险 +N 条」行，
            // 缺项/边界并入 detail；零登记仍走 🔍 雷达行。零新增不发——「没新闻」
            // 播报零信息量。存量会话的旧两行仍照常解码渲染（turnNote 映射与装配不动）。
            let newCount = newMissing.count + newSkipped
            if registered > 0 {
                var text = "⚠️ 自评审新增 \(registered) 个风险（各带应对方案）"
                var segments: [String] = []
                if newCount > 0 {
                    text += " · 新增缺项 \(newMissing.count) · 新增边界 \(newSkipped)"
                    segments.append("新增缺项 \(newMissing.count) · 新增边界 \(newSkipped)")
                }
                segments.append("待处理 \(risks.pendingRisks.count) 条 · 采纳 ≠ 解除，方案落地验证通过后才算数")
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: text + "——右栏「风险」台账逐条决定：采纳方案 / 接受风险。",
                        milestones: [MilestoneStamp(
                            kind: "risk",
                            count: registered,
                            detail: segments.joined(separator: " · ")
                        )]
                    )
                )
            } else if newCount > 0 {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "🔍 自评审新增 \(newCount) 项——右栏「风险」可查对账记录与风险台账。",
                        milestones: [MilestoneStamp(
                            kind: "radar",
                            count: newCount,
                            detail: "新增缺项 \(newMissing.count) · 新增边界 \(newSkipped)"
                        )]
                    )
                )
            }
            // Agent 主动简报（三步走 ③）：新风险登记成功即发起主动回合——
            // 台账行只呈现事实，简报把「为什么值得关注 / 建议怎么处理」讲给人听。
            // 发起即忘（不排队不重试——简报是增值不是必需，闸门不满足即放弃防打扰）。
            if !freshRisks.isEmpty {
                scheduleProactiveRiskBriefing(
                    freshRisks, project: project, version: version
                )
            }
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

    /// 💀 风险登记：radar fatal → risks.jsonl（带影响与建议方案；台账承载逐条决定——
    /// 采纳 / 接受；登记不设上限，封板兜底统一收口）。登记成功后不再独立发系统行，
    /// 由调用方与雷达新增合并为单行注记（2026-09-18）。
    /// B3 事件驱动（2026-09-16）：与台账全量 hypothesis 归一化去重——模型每轮
    /// 重播的 💀 不再重复登记、不再重复占对话流（字面归一化挡重播；文本有变
    /// 的复发视作新致命假设照常登记）。
    /// - Returns: 实际新登记的记录（重播被去重后可为空；主动简报轮的数据源）。
    private func registerFatalRisks(
        _ fatals: [ArtifactParser.RadarReport.Fatal], stageKey: String
    ) -> [RiskRecord] {
        guard !fatals.isEmpty else { return [] }
        let fresh = ArtifactParser.newFatals(
            current: fatals, existingHypotheses: risks.risks.map(\.hypothesis)
        )
        guard !fresh.isEmpty else { return [] }
        let version = pipeline.version
        let stage = RiskRecord.Stage(rawValue: stageKey) ?? .prd
        var registered: [RiskRecord] = []
        for fatal in fresh {
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
                registered.append(record)
            } catch {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system, content: "⚠️ 风险登记失败：\(error.localizedDescription)"
                    )
                )
            }
        }
        guard !registered.isEmpty else { return [] }
        // 广播刷新（右栏风险台账实时跟随自评审登记；对话流行由调用方合并发射）
        NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
        return registered
    }

    // MARK: - Agent 主动简报（三步走 ③：风险登记 / 变更池催办）

    /// 已主动催办的变更池签名（project|version|池内提案 id 集）：同池不重复催办，
    /// 池内容变化（新提案进池 / 处置后再拦）才重新简报。
    private var poolBriefingSignatures: Set<String> = []

    /// 💀 新登记后的主动风险简报：登记成功即发起一轮 Agent 主动回合
    ///（sendSystemTurn 合成指令，不落盘为用户消息；不带工具不带原型快照）。
    /// 闸门：版本未封板、版本无在途流、非快速通道进行中、无采纳落实在途。
    /// 拦截即放弃——台账与雷达行已承载事实，简报是增值不是必需，不排队不重试防打扰。
    private func scheduleProactiveRiskBriefing(
        _ records: [RiskRecord], project: String, version: String
    ) {
        guard !records.isEmpty else { return }
        guard !isReleased(version, in: project) else { return }
        guard !sessionStore.isVersionBusy(project: project, version: version) else { return }
        let origin = ReplyOrigin(
            project: project, version: version, sessionId: sessionStore.sessionId,
            stage: pipeline.stage
        )
        guard !fastForwardVersions.contains(VersionKey(origin)),
              riskImplementationInFlight[VersionKey(origin)] == nil else { return }
        let task = AgentPrompts.riskBriefingTask(records: records)
        let stage = LLMStage(rawValue: origin.stage.rawValue) ?? .clarify
        Task { [weak self] in
            guard let self else { return }
            // 竞态兜底：登记与简报起跑间用户可能已发新消息——发起会话忙即放弃
            guard !self.sessionStore.isSessionBusy(origin.sessionId) else { return }
            let prompt = await self.assembleSystemPrompt(
                stage: stage, userMessage: task, origin: origin
            ) { injection in
                AgentPrompts.riskBriefingSystem(injection: injection)
            }
            await self.sessionStore.sendSystemTurn(
                note: nil, userPrompt: task,
                settings: self.settings, stage: stage,
                systemPrompt: prompt.prompt, skills: prompt.skills,
                pinnedOrigin: origin.storeOrigin
            ) { [weak self] reply, _ in
                self?.handleAssistantReply(reply, origin: origin)
            }
        }
    }

    /// 封板被池内未处置想法拦截时的主动催办（Agent 主动发起回合）：逐条给
    /// 处置建议（纳入后续 / 放弃 / 顺延），推动池子清零——封板闸的前置条件。
    /// 会话锚点 = 版本最近一条 assistant 回合所在会话（gateOwnerSession ① 口径）；
    /// 同池签名去重；拦截即放弃（不排队不重试）。
    func schedulePoolGraduationBriefing(project: String, version: String) {
        let items = ChangeLedger.load(project: project, version: version).filter(\.isPooled)
        guard !items.isEmpty else { return }
        let signature = "\(project)|\(version)|\(items.map(\.id).joined(separator: ","))"
        guard !poolBriefingSignatures.contains(signature) else { return }
        guard !isReleased(version, in: project) else { return }
        guard !sessionStore.isVersionBusy(project: project, version: version) else { return }
        guard let sessionId = Self.gateOwnerSession(
            project: project, version: version, stage: .clarify
        ) else { return }
        let originStage: PipelineRun.Stage
        if pipeline.project == project, pipeline.version == version {
            originStage = pipeline.stage
        } else {
            originStage = PipelineEngine(project: project, version: version, database: database).stage
        }
        let origin = ReplyOrigin(
            project: project, version: version, sessionId: sessionId, stage: originStage
        )
        poolBriefingSignatures.insert(signature)
        let task = AgentPrompts.poolGraduationTask(items: items)
        let stage = LLMStage(rawValue: origin.stage.rawValue) ?? .clarify
        Task { [weak self] in
            guard let self else { return }
            guard !self.sessionStore.isSessionBusy(origin.sessionId) else { return }
            let prompt = await self.assembleSystemPrompt(
                stage: stage, userMessage: task, origin: origin
            ) { injection in
                AgentPrompts.poolGraduationSystem(injection: injection)
            }
            await self.sessionStore.sendSystemTurn(
                note: nil, userPrompt: task,
                settings: self.settings, stage: stage,
                systemPrompt: prompt.prompt, skills: prompt.skills,
                pinnedOrigin: origin.storeOrigin
            ) { [weak self] reply, _ in
                self?.handleAssistantReply(reply, origin: origin)
            }
        }
    }

    // MARK: - 风险采纳落实（台账 → 对话闭环，2026-09-17 消息化模型）

    /// 采纳落实单飞（M2 版本键控）：(project, version) → 落实中的风险 id。
    /// 同版本单写者（与 isVersionBusy 口径一致）；跨版本并行落实互不阻塞。
    @Published private(set) var riskImplementationInFlight: [VersionKey: String] = [:]

    /// 台账行 isGenerating 查询口：风险 id 全局唯一，扫值即可。
    func isRiskImplementing(_ recordID: String) -> Bool {
        riskImplementationInFlight.values.contains(recordID)
    }

    /// 该版本是否有采纳落实在途（台账排队判定口：同版本落实串行，
    /// 在途时新采纳排队等冲洗，不静默降级）。
    func isVersionAdoptImplementing(project: String, version: String) -> Bool {
        riskImplementationInFlight[VersionKey(project, version)] != nil
    }

    // MARK: 采纳排队（回答中点击 → 回答结束自动落实）

    /// 排队中的采纳（运行时态；磁盘上风险保持 open——崩溃恢复即自然回到待处理）。
    struct QueuedAdopt: Identifiable, Equatable {
        let record: RiskRecord
        let entry: DiscussionEntry
        let project: String
        let version: String
        var id: String { record.id }
    }
    @Published private(set) var queuedAdopts: [QueuedAdopt] = []
    private var queueCancellable: AnyCancellable?

    /// 代发采纳消息文案（⚡ 来源标记，不伪装手打）。
    nonisolated static func adoptMessageText(_ record: RiskRecord) -> String {
        "⚡ 风险台账 · 采纳\n风险：\(record.hypothesis)\n方案：\(record.plan ?? "—")"
    }

    func isAdoptQueued(_ id: String) -> Bool {
        queuedAdopts.contains { $0.record.id == id }
    }

    /// 回答中点击采纳 → 代发消息**立即乐观上屏**（点击瞬间即见「已发出」），
    /// 落盘延后到消息真正发出（冲洗时 append 同一 entry 补齐）
    func queueAdopt(_ record: RiskRecord) {
        guard case .session(let project, let version, _) = selection else { return }
        guard !isAdoptQueued(record.id) else { return }
        let entry = sessionStore.stageOutgoingUser(Self.adoptMessageText(record))
        queuedAdopts.append(
            QueuedAdopt(record: record, entry: entry, project: project, version: version)
        )
        NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
    }

    /// 显式逃生门「不等了，只记账」：撤回待发送消息，原地普通记账。
    /// 记账坐标钉**排队条目自身**的 (project, version, sessionId)——用户排队后可能
    /// 已切走，逃生门必须落回排队时的版本与发起会话，不读当前选中上下文。
    func cancelQueuedAdopt(_ record: RiskRecord) {
        guard let queued = queuedAdopts.first(where: { $0.record.id == record.id }) else { return }
        queuedAdopts.removeAll { $0.record.id == record.id }
        sessionStore.discardStaged(queued.entry)
        let origin = ReplyOrigin(
            project: queued.project, version: queued.version,
            sessionId: queued.entry.sessionId, stage: pipeline.stage
        )
        _ = try? RiskStore(project: origin.project, version: origin.version).adopt(id: record.id)
        appendOriginSystem(
            "📌 已采纳应对方案——「只记账」路径：风险挂起等验证，决策已记入日志（未生成执行包）",
            origin: origin
        )
        NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
    }

    /// 空闲即冲洗队列：队首消息落盘发出并落实；其余等下一轮冲洗。
    /// 空闲判据为**队首条目的发起会话**口径（并行落实放宽）：冲洗只被发起会话
    /// 自身的流拦截（每会话一条流铁律）——他会话/他版本的流不影响；
    /// 冲洗与 UI 选中解耦（M5），后台排队的采纳自动落实。
    private func flushQueuedAdoptsIfIdle() {
        guard !queuedAdopts.isEmpty, let head = queuedAdopts.first else { return }
        guard !sessionStore.isSessionBusy(head.entry.sessionId) else { return }
        queuedAdopts.removeFirst()
        Task { [weak self] in
            await self?.implementRiskAdoption(
                head.record, stagedEntry: head.entry,
                project: head.project, version: head.version
            )
            self?.flushQueuedAdoptsIfIdle() // 队列其余条目链式续跑
        }
    }

    /// 台账「采纳方案」能否走落实闭环：当前会话上下文与台账一致、版本未封板、
    /// 该版本无采纳落实在途（并行落实放宽后不判会话/版本流——采纳与其他流
    /// 并发安全，见 implementRiskAdoption 竞态兜底注释）。
    /// 不满足（项目首页 / 封板 / 异上下文）则由台账回退普通采纳（仅记账，不生成）。
    func canImplementRisk(_ ctx: (project: String, version: String)?) -> Bool {
        guard let ctx, !currentVersionReleased else { return false }
        return ctx.project == pipeline.project
            && ctx.version == pipeline.version
            && riskImplementationInFlight[VersionKey(ctx.project, ctx.version)] == nil
        // 并行落实放宽（B 后）：不再判 isVersionBusy——采纳落实的版本级写点
        // 全 append-only + 执行包按风险 id 分文件，与他会话的流并发安全。
    }

    /// 采纳落实闭环（2026-09-17 消息化模型 · 方案 C）：
    /// 采纳消息已在点击瞬间乐观上屏（stagedEntry）→ 此处**先补落盘**（保证用户
    /// 第一眼看到「消息已发出」）→ AI 以回答呈现执行逻辑 → 回答完成后执行包落
    /// 产物 05-artifacts/risk-plans/<id>.md + 转「已挂方案」+ 带证据指针的决策日志；
    /// 中断/出错风险保持「待处理」可重试（状态翻转收口在流完成回调，杜绝
    /// 「状态已变但证据没生成」悬空态）。
    /// project/version：目标版本坐标（M5 解耦）——直接点击路径由台账传入 ctx，
    /// 冲洗路径由队首条目传入；落实全程不读活 pipeline，后台版本可自动落实。
    func implementRiskAdoption(
        _ record: RiskRecord, stagedEntry: DiscussionEntry? = nil,
        project: String, version: String
    ) async {
        // 发起上下文快照（origin 化，M1/M5）：提前到闸口前——竞态兜底说明行也必须
        // 落发起会话；其后所有写点 pinned、读点走快照，落实期间切会话不漂移。
        // 发起会话优先取 staged 条目自带 sessionId（= 用户点击采纳的会话，冲洗
        // 路径下与当前打开会话无关）；无 staged（兜底直调）才用当前会话。
        let origin = ReplyOrigin(
            project: project, version: version,
            sessionId: stagedEntry?.sessionId ?? sessionStore.sessionId,
            stage: pipeline.project == project && pipeline.version == version
                ? pipeline.stage
                : PipelineEngine(project: project, version: version, database: database).stage
        )
        // 竞态兜底：perform 检查通过后、本闭包起跑前状态可能翻转（用户抢发新回合等）。
        // 不许无声退出（2026-09-16 零反馈事故口径）——落一行说明再退，风险保持待处理可重试。
        // 空闲判据为**发起会话**口径（并行落实放宽）：采纳落实与他会话的流并发
        // 安全（写点 append-only / 执行包按风险 id 分文件）；只有发起会话自己
        // 在生成时拦截——每会话一条流是架构铁律（流态键 = sessionId）。
        guard riskImplementationInFlight[VersionKey(origin)] == nil,
              !sessionStore.isSessionBusy(origin.sessionId) else {
            do {
                let entry = sessionStore.makeEntry(
                    role: .system,
                    content: "💬 采纳落实未启动：当前有生成在进行或已有落实在途——"
                        + "「\(RiskLedgerTab.summary(record.hypothesis))」保持「待处理」，"
                        + "生成结束后可在台账重新采纳。",
                    sessionID: origin.sessionId
                )
                try sessionStore.appendPinned(entry, origin: origin.storeOrigin)
            } catch {
                // 反馈行自身写盘失败：唯一收窄到日志通道的兜底（不许无声）
                NSLog("pm_worker 风险采纳落实未启动：反馈行落盘失败 \(error.localizedDescription)")
            }
            return
        }
        riskImplementationInFlight[VersionKey(origin)] = record.id
        defer { riskImplementationInFlight[VersionKey(origin)] = nil }

        var replyEntryID: String?
        var replyText = ""
        // 采纳消息落盘（点击瞬间已乐观上屏——此处补磁盘写入，保证先「发出」后「思考」）。
        // 落盘钉 origin 的 jsonl（appendPinned）：落实期间切会话不写错版本。
        if let staged = stagedEntry {
            do {
                try sessionStore.appendPinned(staged, origin: origin.storeOrigin)
            } catch {
                NSLog("pm_worker 采纳消息落盘失败：\(error.localizedDescription)")
            }
        } else {
            // 兜底路径（无乐观上屏直接调用）：现组现发
            let msgEntry = sessionStore.makeEntry(
                role: .user, content: Self.adoptMessageText(record),
                sessionID: origin.sessionId
            )
            do {
                try sessionStore.appendPinned(msgEntry, origin: origin.storeOrigin)
            } catch {
                NSLog("pm_worker 采纳消息落盘失败：\(error.localizedDescription)")
            }
        }
        let task = AgentPrompts.riskImplementationTask(record: record)
        let stage = LLMStage(rawValue: origin.stage.rawValue) ?? .clarify
        let prompt = await assembleSystemPrompt(stage: stage, userMessage: task, origin: origin) { injection in
            AgentPrompts.riskImplementationSystem(injection: injection)
        }
        let outcome = await sessionStore.sendSystemTurn(
            note: nil,
            userPrompt: "请针对上方「⚡ 风险台账 · 采纳」消息，给出该方案可执行的执行逻辑：分步、可核查、含完成判据，作为执行包落盘依据。",
            settings: settings, stage: stage,
            systemPrompt: prompt.prompt,
            skills: prompt.skills, pinnedOrigin: origin.storeOrigin
        ) { [weak self] reply, _ in
            replyEntryID = reply.id
            replyText = replyText.isEmpty ? reply.content : replyText + "\n\n" + reply.content
            self?.handleAssistantReply(reply, origin: origin)
        }

        // 会话可能已切走：台账按 origin 版本取（M5：坐标自参数来，不读活 pipeline）
        let store = riskStore(for: origin)
        switch outcome {
        case .completed:
            do {
                // 执行包落成真产物（方案 C，2026-09-17）：执行逻辑不再只是聊天气泡，
                // 落盘为 05-artifacts/risk-plans/<id>.md——台账可预览、可注入下一轮
                let planArtifact = RiskStore.writePlanArtifact(
                    project: project, version: version, record: record, reply: replyText
                )
                if planArtifact != nil {
                    NotificationCenter.default.post(
                        name: Notification.Name("pm.worker.artifacts.changed"), object: nil
                    )
                }
                let evidence = "对话留痕 · 会话 \(origin.sessionId)"
                    + (replyEntryID.map { " · 回合 \($0)" } ?? "")
                    + (planArtifact.map { " · 执行包 \($0)" } ?? "")
                _ = try store.adopt(id: record.id, evidence: evidence, planArtifact: planArtifact)
            } catch {
                // 竞态：生成期间该风险已被其他入口流转（如点了接受）——交付物已在对话留痕，
                // 台账不再变更，落一行说明防「生成完了却没翻转」的困惑（pinned 落 origin 会话）
                let statusText = store.risks.first { $0.id == record.id }
                    .map { RiskStatusPresentation.text($0.status) } ?? "未知"
                appendOriginSystem(
                    "💬 交付物已生成，但该风险状态已变化（\(statusText)），台账未变更。",
                    origin: origin
                )
            }
        case .interrupted:
            // ⏹ / ⚠️ 收尾行已由管线落盘；风险从未预翻转，此处仅补一句恢复指引
            appendOriginSystem(
                "💬 落实未完成：风险保持「待处理」，可在台账重新采纳。",
                origin: origin
            )
        }
        NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
        flushQueuedAdoptsIfIdle() // 落实收口后链式冲洗队列（多条排队逐条跑）
    }

    /// ③ 阶段 system prompt（读已确认结构产物 + 既有原型作迭代基底 + Context Builder 组装）。
    /// - Parameter userMessage: 本轮用户消息（技能意图路由；系统轮闸口生成传 nil）。
    /// - Returns: snapshot = 槽位相对路径 → 全文 SHA256（阶段 4 冲突检测快照：
    ///   与 prompt 注入同一次读盘取得，保证「模型看到的」与「落盘校验的」同源）。
    private func prototypePrompt(
        userMessage: String? = nil, origin: ReplyOrigin? = nil,
        toolsEnabled: Bool = false
    ) async -> (
        prompt: String, skills: [String], snapshot: [String: String]?
    ) {
        // origin 口径（M4）：产物基底读 origin 版本目录（链中途切走不读错版本）；
        // 草稿预演会话（B1）：基底读提案目录镜像，跳过主线冲突快照（草稿无并发写）
        let project = origin?.project ?? pipeline.project
        let version = origin?.version ?? pipeline.version
        let isDraft = origin.map { draftSessionId(of: $0) != nil } ?? false
        let draftSid = isDraft ? origin?.sessionId : nil
        let root = PMAgentStore.artifactRoot(
            project: project, version: version, proposalSessionId: draftSid
        )
        let map = Self.readArtifact(root: root, rel: ArtifactPath.modulePageMap) ?? "（缺失）"
        let flows = Self.readArtifact(root: root, rel: ArtifactPath.coreFlows) ?? "（缺失）"
        let bases = prototypeBases(project: project, version: version, root: isDraft ? root : nil)
        let snapshot = isDraft
            ? nil
            : Dictionary(uniqueKeysWithValues: bases.map { ($0.relPath, $0.sha) })
        let assembled = await assembleSystemPrompt(
            stage: .prototype, userMessage: userMessage, origin: origin,
            toolsSection: toolsEnabled
        ) { injection in
            AgentPrompts.prototype(
                modulePageMap: map, coreFlows: flows,
                previousPrototypes: bases.map { (label: $0.label, html: $0.html) },
                injection: injection
            )
        }
        return (prompt: assembled.prompt, skills: assembled.skills, snapshot: snapshot)
    }

    /// 原型迭代基底：扫产物根 03-prototypes/ 全部槽位文件读全文（多端多份一并回灌，
    /// label = 槽位显示名）。零槽位文件 → 空数组（首次生成）。
    /// 阶段 4：附带 relPath + 全文 SHA256——同一次读盘既作 prompt 注入又作冲突
    /// 检测指纹（readArtifact 原文读出无归一化，SHA 口径与 writeMeasured 一致）。
    /// 边界：用户引用的 fileRefs 注入路径（ReferencedFileMaterial）不纳入快照——
    /// 引用是只读材料，落盘目标恒为槽位路径，v1 不做引用写回。
    /// root：产物根（B1 草稿预演传提案目录；nil = 主线版本目录）。internal 供单测驱动。
    func prototypeBases(project: String, version: String, root: URL? = nil) -> [
        (label: String, html: String, relPath: String, sha: String)
    ] {
        ArtifactPath.prototypeSlotFiles(project: project, version: version, root: root).compactMap { slot in
            Self.readArtifact(root: root ?? PMAgentStore.versionURL(project: project, version: version), rel: slot.relPath)
                .map { (label: slot.display, html: $0, relPath: slot.relPath, sha: ArtifactParser.sha256Hex($0)) }
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

        /// 持久化 key（confirm-silence.json，版本级跨启动静默）。
        var storageKey: String {
            switch self {
            case .clarify: "clarify"
            case .structure: "structure"
            case .prototype: "prototype"
            }
        }

        init?(storageKey: String) {
            switch storageKey {
            case "clarify": self = .clarify
            case "structure": self = .structure
            case "prototype": self = .prototype
            default: return nil
            }
        }
    }

    /// 闸口路径选择（2026-09-17 路径选择）：确认坞选项 / 收尾确认问肯定作答 /
    /// 对话 fast-forward 块三入口同语义——「想出就出，不想就不出，用户自己决定；
    /// 前面跳过的，后面想补随时补（补课 = 删跳过标记，走回退重做机器）」。
    enum GateRoute: Hashable {
        case next             // 常规：确认并进入下一阶段（完整流程）
        case skipToPrototype  // ① 确认时跳过 ② 结构，直出 ③ 原型
        case skipToPRD        // 跳过中间阶段直出 PRD（① 跳②③ / ② 跳③）
        case stopHere         // ③ 到原型为止（本版不出 PRD，停驻态）

        /// 按闸口归一化：① 只接受 next / skipToPrototype / skipToPRD，
        /// ② 只接受 next / skipToPRD，③ 只接受 next / stopHere。
        /// 非法组合回退 .next（UI 分档本就不出非法选项，此为纵深防御）。
        func normalized(for target: ConfirmTarget) -> GateRoute {
            switch (target, self) {
            case (.clarify, .next), (.clarify, .skipToPrototype), (.clarify, .skipToPRD),
                 (.structure, .next), (.structure, .skipToPRD),
                 (.prototype, .next), (.prototype, .stopHere):
                return self
            default:
                return .next
            }
        }

        /// 路径去向描述（决策记账 / 留痕共用）。
        var label: String {
            switch self {
            case .next: "完整流程（进入下一阶段）"
            case .skipToPrototype: "跳过 ② 结构，直出原型"
            case .skipToPRD: "跳过中间阶段，直出 PRD"
            case .stopHere: "到原型为止（本版不出 PRD）"
            }
        }
    }

    /// 自由作答 / 收尾确认问肯定作答中的路径关键词解析（闸口路由三入口之一）。
    /// 按当前闸口归一化后使用；无关键词 → .next 常规推进。
    static func gateRouteFromText(_ text: String) -> GateRoute {
        let t = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .lowercased()
        // 先判 skipToPRD：「跳过结构原型直接出 PRD」一类组合措辞会同时命中
        // 「跳过结构」——PRD 意图必须在前，防误路由到 skipToPrototype。
        if t.contains("直接出prd") || t.contains("直接生成prd") || t.contains("直接写prd")
            || t.contains("跳过结构原型") || t.contains("跳过原型")
            || t.contains("跳过中间") || t.contains("不要原型") {
            return .skipToPRD
        }
        if t.contains("直接出原型") || t.contains("直接生成原型")
            || t.contains("跳过结构") || t.contains("不要结构") {
            return .skipToPrototype
        }
        if t.contains("到此为止") || t.contains("不出prd") || t.contains("不需要prd")
            || t.contains("不要prd") || t.contains("到原型为止") {
            return .stopHere
        }
        return .next
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
        !ArtifactPath.prototypeSlotFiles(
            project: pipeline.project, version: pipeline.version
        ).isEmpty
    }

    // MARK: 确认坞「稍后再说」记忆（每版本每阶段弹一次：推迟后该版本内永久静默，design.md §6.1）

    /// 当前版本已静默的闸口集。版本级持久（PMAgentStore confirm-silence.json，
    /// 跨启动 / 跨会话共享）——「稍后再说」一次后，本版本此阶段不再自动弹坞
    /// （修订落盘也不弹），推进改由用户发起（自由作答「进入下一阶段」/ 摘要条兜底行）；
    /// 修订轮改为在 AI 回复末尾融一句推进邀请（gateInviteSuffix）。
    /// 确认推进后清除（回退重做到该阶段视为新一轮提醒）。进入会话时在
    /// switchContext 重读磁盘——重启后静默仍生效，不重复弹坞、不重复留痕。
    @Published private(set) var deferredConfirmGates: Set<ConfirmTarget> = []

    /// 「稍后再说」/「继续修改」：本阶段进入永久静默（每版本只弹一次）。
    /// 静默写透磁盘（重启后仍生效）；同时在时间线落一条安静留痕——静默反馈 +
    /// 推进指引融进对话（system 行不回灌模型、不弹卡，符合「提示进对话」语义）。
    /// 已静默时调用是 no-op：不写盘、不重复留痕（防 💬 提示行叠加）。
    func deferConfirmGate(_ target: ConfirmTarget) {
        guard deferredConfirmGates.insert(target).inserted else { return }
        persistConfirmSilence()
        try? sessionStore.append(sessionStore.makeEntry(
            role: .system,
            content: "💬 已收起确认——\(target.name)待确认期间不再弹出；想推进随时说「进入下一阶段」。"
        ))
    }

    /// 闸口是否已静默（静默阶段不挂载确认坞）。
    func isConfirmGateDeferred(_ target: ConfirmTarget) -> Bool {
        deferredConfirmGates.contains(target)
    }

    /// 确认推进后清除该阶段静默（含磁盘）：回退重做回到此阶段时，视为新一轮提醒重新弹坞。
    private func clearDeferredConfirmGate(_ target: ConfirmTarget) {
        guard deferredConfirmGates.remove(target) != nil else { return }
        persistConfirmSilence()
    }

    /// 静默集写透磁盘（版本级 confirm-silence.json，随当前上下文版本走）。
    private func persistConfirmSilence() {
        try? PMAgentStore.writeConfirmSilence(
            Set(deferredConfirmGates.map(\.storageKey)),
            project: pipeline.project, version: pipeline.version
        )
    }

    /// 静默中的修订生成轮：userPrompt 尾部追加推进邀请指令——AI 回复最末尾
    /// 融一句自然话（用户语义「提示融进 AI 回答，不再弹卡」）。
    /// 未静默轮次返回空串：坞本身就是邀请，保持单一声源，避免双份文案。
    /// 静默判定按 origin 口径：内存静默集只反映当前上下文（switchContext 时装载），
    /// 链中途切走时读 origin 版本的 confirm-silence.json 才是真相。
    private func gateInviteSuffix(for target: ConfirmTarget, origin: ReplyOrigin) -> String {
        let silenced = originIsCurrentContext(origin)
            ? isConfirmGateDeferred(target)
            : PMAgentStore.readConfirmSilence(project: origin.project, version: origin.version)
                .contains(target.storageKey)
        guard silenced else { return "" }
        return "\n\n（补充输出要求：全部产物输出完成后，在回复的最末尾另起一行，"
            + "用一句自然、不啰嗦的中文提示用户——「\(target.name)已更新落盘，没问题的话回复「进入下一阶段」，"
            + "我随即进入\(target.nextStage)；还要调整直接说。」。只此一句，不要展开、不要重复。）"
    }

    /// 阶段确认链进行中（要点表抽取 / 闸口写盘 / 下游生成）：停靠卡确认段挂载与
    /// 重复确认入口的抑制信号——防确认动作提交后、阶段推进落盘前的空窗内
    /// 确认卡闪现 / 自由作答二次触发（confirmCurrentStage 重入即 no-op）。
    /// 按发起会话 id 键控（M2）：跨版本/跨会话并行的确认链互不抑制。
    @Published private(set) var stageConfirmRunningSessions: Set<String> = []

    /// 阶段推进确认（ConfirmDock 提交 / 自由作答「进入下一个阶段」/ 收尾确认问肯定作答）。
    /// route：闸口路径选择（默认 .next 常规推进；坞选项 / 作答关键词 / fast-forward 传入）。
    func confirmCurrentStage(route: GateRoute = .next) async {
        // 链入口快照 origin（阶段 2 闸口链钉定）：确认链跨多轮 LLM 往返（要点表
        // 抽取 / 记忆与方法论沉淀 / 下游生成），中途用户可能切会话/项目——phase
        // 文案、占位清理与生成回合一律落在发起上下文（缺省「当前会话」路径禁用）。
        let origin = ReplyOrigin(
            project: pipeline.project, version: pipeline.version,
            sessionId: sessionStore.sessionId, stage: pipeline.stage
        )
        guard !stageConfirmRunningSessions.contains(origin.sessionId),
              let target = confirmTarget else { return }
        stageConfirmRunningSessions.insert(origin.sessionId)
        defer { stageConfirmRunningSessions.remove(origin.sessionId) }
        let route = route.normalized(for: target)
        if route != .next {
            recordRouteDecision(
                decision: "【路径选择】\(target.name)确认：\(route.label)",
                why: "用户在\(target.title)闸口显式选定路径；跳过的阶段可随时补做（时间线补做入口 / 对话要求）"
            )
        }
        // 待回复占位即刻置位（幂等）：确认链多跳 LLM 往返（要点表抽取/记忆与方法论
        // 沉淀）期间思考卡带阶段文案显示进度，不再有「点了确认却毫无反应」的空窗；
        // 失败早退路径由 defer 统一收口（成功路径开流转正/流收尾已自行清除，重入无副作用）。
        sessionStore.beginPreparingReply(sessionID: origin.sessionId)
        defer { sessionStore.endPreparingReply(sessionID: origin.sessionId) }
        switch target {
        case .clarify: await confirmClarify(origin: origin, route: route)
        case .structure: await confirmStructure(origin: origin, route: route)
        case .prototype: await confirmPrototype(origin: origin, route: route)
        }
        // 确认推进后清该阶段静默：回退重做回到此阶段时视为新一轮提醒（重新弹坞一次）
        clearDeferredConfirmGate(target)
        reloadTree()
        refreshGateOwner()
    }

    /// 一次确认（① 澄清）：收尾确认问的肯定作答 = 闸口确认。
    /// 答案先留痕（要点表抽取以会话记录为底稿，选定的收束决策随 transcript 进表），
    /// 随即走常规确认链（要点表 + 进②）——AI 不再另行应答一轮，确认坞不再二次弹出。
    func confirmStageByAnswer(_ text: String) async {
        guard confirmTarget == .clarify, !currentVersionReleased else {
            // 闸口不就绪（渲染与提交间状态变化，理论不达）：退回常规发送
            await sendMessage(text)
            return
        }
        sidebarReveal = SidebarReveal(project: pipeline.project, version: pipeline.version)
        // 答案留痕：乐观上屏 + 落盘补齐（同 sendMessage 乐观路径的两步，同 entry id 去重）
        let staged = sessionStore.stageOutgoingUser(text)
        try? sessionStore.append(staged)
        // 路径选择（闸口路由三入口之二）：肯定作答里的去向关键词——
        // 「直接出原型 / 直接出 PRD / 到此为止」由用户自己决定，AI 不代选。
        await confirmCurrentStage(route: Self.gateRouteFromText(text))
    }

    /// PRD 前置确认卡提交（prd_preflight 问题卡，ConversationView 分流进入）：
    /// 答案留痕后直接以答案为指令触发快速通道串链出 PRD——选完直出，不经 AI 转发轮。
    /// 串链各段经 fastTrackNote 引用答案，transcript 里的留痕同被要点表抽取吸收。
    func submitPreflightCard(_ assembled: String) async {
        guard !currentVersionReleased else {
            // 已封板版本不可再推进（理论不达）：退回常规发送，答案留痕即可
            await sendMessage(assembled)
            return
        }
        sidebarReveal = SidebarReveal(project: pipeline.project, version: pipeline.version)
        // 答案留痕：乐观上屏 + 落盘补齐（同 confirmStageByAnswer 的两步式）
        let staged = sessionStore.stageOutgoingUser(assembled)
        try? sessionStore.append(staged)
        // 指令剥掉 App 内部协议前缀（防占位模仿：标记词不回灌 prompt）
        let instruction = assembled
            .replacingOccurrences(of: QuestionCardAssembly.marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = ReplyOrigin(
            project: pipeline.project, version: pipeline.version,
            sessionId: sessionStore.sessionId, stage: pipeline.stage
        )
        await runFastForward(to: .prd, instruction: instruction, origin: origin)
    }

    /// 抽取底稿组装（确认链三连抽共用；2026-09-18 classify 162k 异常实证收敛）：
    /// ① assistant 条目剥离产物块（与历史回灌同口径——雷达/决策块/问题卡协议文本
    ///    不进抽取底稿，抽取所需信息以对话正文为准）；② 硬上限裁剪：超预算从最旧
    ///    条目丢起（保留至少 2 条），尾注如实告知——病态长会话（实测 162k token）
    ///    曾让确认链 3 连发各付一次全价 prefill，且超长底稿拖累抽取质量。
    /// 三个消费方（要点表/记忆/方法论）拿同一字符串 + prompt 侧 transcript 置顶
    /// （AgentPrompts/KnowledgeExtractor）→ 后两次调用命中首次的 provider 前缀缓存。
    nonisolated static func extractionTranscript(
        from entries: [DiscussionEntry], budget: Int = 60_000
    ) -> String {
        var parts: [String] = []
        for entry in entries {
            var content = entry.role == .assistant
                ? ArtifactParser.scrubImitatedPlaceholders(in: entry.content)
                : entry.content
            if entry.role == .assistant,
               !ArtifactParser.parseArtifactBlocks(in: content).isEmpty {
                content = ArtifactParser.stripArtifactBlocks(
                    in: content,
                    placeholder: "（助手回复中的产物块已省略——抽取所需信息以对话正文为准）"
                )
            }
            parts.append("\(entry.role == .user ? "用户" : "助手")：\(content)")
        }
        var dropped = 0
        while parts.count > 2,
              TokenBreakdown.estimate(parts.joined(separator: "\n")) > budget {
            parts.removeFirst()
            dropped += 1
        }
        var transcript = parts.joined(separator: "\n")
        if dropped > 0 {
            transcript += "\n（早期 \(dropped) 条消息已超出抽取底稿上限被省略"
                + "——更早已确认的信息以磁盘产物与既有要点表为准）"
        }
        return transcript
    }

    /// ①→②：要点表生成 + 记忆沉淀 + 结构产物生成。
    /// 增补澄清收束（amend 标记在）时：以既有表为基底合并更新（仅改波及字段），
    /// 结构重生成注入旧结构产物作增量修订基底（新功能落入对应模块，不盲重画）。
    /// route：闸口路径选择——.next 常规进 ②；.skipToPrototype 跳 ② 直出 ③ 原型；
    /// .skipToPRD 跳 ②③ 直出 ④ PRD（跳过阶段写 skipped.json 闭环，不生成产物）。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规确认传 nil。
    /// injectedOpening：快速通道链首的全链开场承接事实（仅链首传，中段 nil——
    /// openingTail 在 directive != nil 且 injected == nil 时返回空串防重复播报）。
    /// origin：链入口快照（阶段 2 闸口链钉定）——phase 文案与生成回合全链显式传它。
    private func confirmClarify(
        origin: ReplyOrigin, route: GateRoute = .next,
        directive: String? = nil, injectedOpening: String? = nil
    ) async {
        // 阶段文案随确认链收尾统一清态（成功/失败出口都覆盖）
        defer { sessionStore.setStreamPhase(nil, for: origin.sessionId) }
        // 坐标与引擎态全走 origin 快照（M3）：快速通道 Task 起跑时可能已切走，
        // 活 pipeline 已是别处引擎；transcript 读 origin 会话投影（磁盘事实源）。
        let project = origin.project
        let version = origin.version
        let amending = pipelineEngine(for: origin).isAmendingClarify
        let fastTrackNote = directive.map { "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。" + $0 }

        // 1. 澄清要点表（JSON Schema 约束抽取）；增补轮注入既有表作合并基底。
        //    maxTokens 8192：思考型模型 reasoning 与正文共用输出池，transcript 长时
        //    2048 会在思考阶段撞线（正文为空抛空流）——咽喉路径预算给足。
        //    失败自动重试 1 次：空流/截断多为服务端抖动，一次重试可救回大半。
        sessionStore.setStreamPhase(
            amending ? "正在更新澄清要点表…" : "正在抽取澄清要点表…", for: origin.sessionId
        )
        let transcript = Self.extractionTranscript(
            from: sessionStore
                .entries(project: project, version: version, sessionId: origin.sessionId)
                .filter { $0.role != .system }
        )
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
            appendOriginSystem(
                "⚠️ 澄清要点表生成失败（已自动重试 1 次仍未成功）："
                    + (tableResult.failureReason ?? "未知原因")
                    + "——稍后回复「进入下一阶段」重试确认。",
                origin: origin
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
            appendOriginSystem(
                "⚠️ 澄清要点表保存失败：\(error.localizedDescription)",
                origin: origin
            )
            return
        }

        // 2+3. 记忆沉淀 + 方法论沉淀并行（此前串行两跳）：两者互不依赖、各自独立
        //      失败域、都只消费同一份 transcript。MainActor 串行化状态与落盘写入，
        //      jsonl 行序交错无渲染语义（记忆行不渲染、方法论行归回合尾部注记）。
        //      ① 要点表刚以同前缀入缓存，两跳抽取都是缓存价 prefill。
        sessionStore.setStreamPhase("正在沉淀记忆与方法论…", for: origin.sessionId)
        async let memoryTask: Void = sedimentMemory(transcript: transcript, origin: origin)
        async let knowledgeTask: Void = sedimentKnowledge(transcript: transcript, origin: origin)
        _ = await (memoryTask, knowledgeTask)

        // 4. 推进 + 生成回合（阶段推进信息作为回合注记并入 AI 回答顶部）：
        //    route 决定去向——.next 常规进 ②（增补场景带旧产物增量修订）；
        //    .skipToPrototype 跳 ② 直出 ③；.skipToPRD 跳 ②③ 直出 ④。
        //    outcome 结算：路径选择 = route_selection；快速通道 = 未逐项确认；
        //    增补收束 = 改后批准；常规 = 批准
        let outcome = route != .next
            ? "route_selection"
            : (directive != nil
                ? "fast_track"
                : (amending ? "approved_after_revision" : "approved"))
        switch route {
        case .next:
            // 引擎访问口（M3）：链中含多轮 await，切走后按 origin 重建实例推进
            //（同上下文即活实例，语义不变）。
            pipelineEngine(for: origin).advanceFromClarify(outcome: outcome)
            snapshotProject(
                message: amending ? "clarify: 增补澄清收束，要点表更新" : "clarify: 澄清要点表确认",
                project: project, version: version
            )
            let riskFact = gateRiskNudge(fromStage: .clarify, nextStageName: "结构")
            let previousArtifacts = amending
                ? Self.readStructureArtifactsBundle(project: project, version: version)
                : nil
            sessionStore.setStreamPhase("正在生成结构产物…", for: origin.sessionId)
            let structurePrompt = await assembleSystemPrompt(stage: .structure, origin: origin) { injection in
                AgentPrompts.structure(
                    clarification: table.markdown,
                    previousArtifacts: previousArtifacts, injection: injection
                )
            }
            await sessionStore.sendSystemTurn(
                note: amending
                    ? "✅ 要点表已按新功能诉求更新——进入 ② 结构（增量修订）"
                    : "✅ 澄清要点表已确认——进入 ② 结构设计",
                noteSilent: true,
                userPrompt: amending
                    ? "澄清要点表已按新功能诉求更新。请在上一版结构产物基础上增量修订：新功能落入对应模块/页面，未波及的部分原样保留，重新输出全部结构产物（完整产物块）。"
                        + gateInviteSuffix(for: .structure, origin: origin)
                        + "\(fastTrackNote.map { "\n\($0)" } ?? "")"
                        + Self.openingTail(
                            directive: directive, injected: injectedOpening,
                            defaultFact: "已按新功能诉求更新要点表，本轮在上一版结构产物基础上增量修订",
                            risk: riskFact)
                    : "请基于已确认的澄清要点表生成结构产物（功能架构图、核心流程图、模块-页面映射表三项必出）。\(fastTrackNote.map { "\n\($0)" } ?? "")"
                        + Self.openingTail(
                            directive: directive, injected: injectedOpening,
                            defaultFact: "已确认澄清要点表，本轮开始生成结构产物",
                            risk: riskFact),
                settings: settings, stage: .structure,
                systemPrompt: structurePrompt.prompt,
                maxTokens: LLMClient.artifactMaxTokens, skills: structurePrompt.skills,
                pinnedOrigin: origin.storeOrigin
            ) { [weak self] reply, _ in
                self?.handleAssistantReply(reply, origin: origin.with(stage: .structure))
            }

        case .skipToPrototype:
            // ① 跳 ② 直出 ③：结构产物不生成（skipped.json 闭环），原型按要点表直设计
            pipelineEngine(for: origin).advanceFromClarify(outcome: outcome, skipping: [.structure])
            snapshotProject(
                message: "clarify: 要点表确认（跳过 ② 结构直出原型）",
                project: project, version: version
            )
            let riskFact = gateRiskNudge(fromStage: .clarify, nextStageName: "原型")
            sessionStore.setStreamPhase("正在生成原型…", for: origin.sessionId)
            let prototypeGenerationPrompt = await prototypePrompt(origin: origin)
            await sessionStore.sendSystemTurn(
                note: "✅ 要点表已确认——跳过 ② 结构，直出 ③ 原型",
                noteSilent: true,
                userPrompt: "请直接基于澄清要点表生成单文件 HTML 原型（P0 页面 3-5 个，页面跳转按合理设计的核心流程连通）。本版本未生成结构产物：模块划分与页面清单按要点表合理设计，并在原型中以「⚠️ 未经结构设计」标注。"
                    + "\(fastTrackNote.map { "\n\($0)" } ?? "")"
                    + Self.openingTail(
                        directive: directive, injected: injectedOpening,
                        defaultFact: "已确认要点表并跳过结构设计，本轮直接生成原型",
                        risk: riskFact),
                settings: settings, stage: .prototype,
                systemPrompt: prototypeGenerationPrompt.prompt,
                maxTokens: LLMClient.artifactMaxTokens, skills: prototypeGenerationPrompt.skills,
                pinnedOrigin: origin.storeOrigin,
                prototypeSnapshot: prototypeGenerationPrompt.snapshot
            ) { [weak self] reply, prototypeSnapshot in
                self?.handleAssistantReply(
                    reply, origin: origin.with(stage: .prototype),
                    prototypeSnapshot: prototypeSnapshot
                )
            }

        case .skipToPRD:
            // ① 跳 ②③ 直出 ④：中间产物不生成，PRD 走精简路径（generatePRD 内注入）
            pipelineEngine(for: origin).advanceFromClarify(outcome: outcome, skipping: [.structure, .prototype])
            snapshotProject(
                message: "clarify: 要点表确认（跳过 ②③ 直出 PRD）",
                project: project, version: version
            )
            let riskFact = gateRiskNudge(fromStage: .clarify, nextStageName: "PRD")
            await generatePRD(
                tierOverride: nil,
                note: "✅ 要点表已确认——跳过 ②③，直出 ④ PRD",
                noteSilent: true,
                directive: directive,
                riskNudge: riskFact,
                injectedOpening: injectedOpening,
                origin: origin
            )

        case .stopHere:
            return  // ① 不接受停驻（归一化已挡，理论不达）
        }
    }

    /// ②→③：确认闸口 + 原型生成。
    /// route：闸口路径选择——.next 常规进 ③；.skipToPRD 跳 ③ 直出 ④ PRD
    /// （③ 写 skipped.json 闭环，原型产物不生成）。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规确认传 nil。
    /// injectedOpening：快速通道链首的全链开场承接事实（仅链首传，中段 nil）。
    /// origin：链入口快照（阶段 2 闸口链钉定）。
    private func confirmStructure(
        origin: ReplyOrigin, route: GateRoute = .next,
        directive: String? = nil, injectedOpening: String? = nil
    ) async {
        // 阶段文案随本链收尾统一清态（快速通道直入时本函数是唯一清态点）
        defer { sessionStore.setStreamPhase(nil, for: origin.sessionId) }
        do {
            // outcome 结算：路径选择 = route_selection；快速通道 = 未逐项确认，常规 = 批准
            // 引擎访问口（M3）：快速通道 Task 起跑时可能已切走，异上下文重建实例推进
            try pipelineEngine(for: origin).confirmStructure(
                outcome: route == .skipToPRD
                    ? "route_selection"
                    : (directive == nil ? "approved" : "fast_track"),
                skippingPrototype: route == .skipToPRD
            )
            snapshotProject(
                message: "structure: 结构产物确认",
                project: origin.project, version: origin.version
            )
        } catch {
            appendOriginSystem(
                "⚠️ 确认记录写入失败：\(error.localizedDescription)", origin: origin
            )
            return
        }
        guard route == .next else {
            // ② 跳 ③ 直出 ④：原型产物不生成，PRD 走精简路径（generatePRD 内注入）
            await generatePRD(
                tierOverride: nil,
                note: "✅ 结构产物已确认——跳过 ③ 原型，直出 ④ PRD",
                noteSilent: true,
                directive: directive,
                riskNudge: gateRiskNudge(fromStage: .structure, nextStageName: "PRD"),
                injectedOpening: injectedOpening,
                origin: origin
            )
            return
        }
        let riskFact = gateRiskNudge(fromStage: .structure, nextStageName: "原型")
        sessionStore.setStreamPhase("正在生成原型…", for: origin.sessionId)
        let prototypeGenerationPrompt = await prototypePrompt(origin: origin)
        let fastTrackNote = directive.map { "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。" + $0 }
        await sessionStore.sendSystemTurn(
            note: "✅ 结构产物已确认——进入 ③ 原型",
            noteSilent: true,
            userPrompt: "请基于模块-页面映射表生成单文件 HTML 原型（P0 页面 3-5 个，页面跳转按核心流程图连通）。\(fastTrackNote.map { "\n\($0)" } ?? "")"
                + Self.openingTail(
                    directive: directive, injected: injectedOpening,
                    defaultFact: "已确认结构产物，本轮开始生成可点击的 HTML 原型",
                    risk: riskFact),
            settings: settings, stage: .prototype,
            systemPrompt: prototypeGenerationPrompt.prompt,
            maxTokens: LLMClient.artifactMaxTokens, skills: prototypeGenerationPrompt.skills,
            pinnedOrigin: origin.storeOrigin,
            prototypeSnapshot: prototypeGenerationPrompt.snapshot
        ) { [weak self] reply, prototypeSnapshot in
            self?.handleAssistantReply(
                reply, origin: origin.with(stage: .prototype),
                prototypeSnapshot: prototypeSnapshot
            )
        }
    }

    /// ③→④：确认闸口 + 评分卡选档 + PRD 生成（Task 3.4）。
    /// route：闸口路径选择——.next 常规进 ④ 出 PRD；.stopHere 到原型为止
    /// （写 stopped-here.json 停驻，不出 PRD；后续说「出 PRD」随时续接）。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规确认传 nil。
    /// injectedOpening：快速通道链首的全链开场承接事实（仅链首传，中段 nil）。
    /// origin：链入口快照（阶段 2 闸口链钉定）。
    private func confirmPrototype(
        origin: ReplyOrigin, route: GateRoute = .next,
        directive: String? = nil, injectedOpening: String? = nil
    ) async {
        do {
            // outcome 结算：快速通道 = 未逐项确认，常规 = 批准
            // 引擎访问口（M3）：快速通道 Task 起跑时可能已切走，异上下文重建实例推进
            if route == .stopHere {
                try pipelineEngine(for: origin).confirmPrototypeStopHere(
                    outcome: directive == nil ? "approved" : "fast_track"
                )
                snapshotProject(
                    message: "prototype: 原型确认（到原型为止）",
                    project: origin.project, version: origin.version
                )
            } else {
                try pipelineEngine(for: origin).confirmPrototype(
                    outcome: directive == nil ? "approved" : "fast_track"
                )
                snapshotProject(
                    message: "prototype: 原型确认",
                    project: origin.project, version: origin.version
                )
            }
        } catch {
            appendOriginSystem(
                "⚠️ 确认记录写入失败：\(error.localizedDescription)", origin: origin
            )
            return
        }
        guard route != .stopHere else {
            // 到原型为止：不生成 PRD，留续接指引（「出 PRD」→ fast-forward prd 续出）
            appendOriginSystem(
                "🏁 本版到原型为止——不出 PRD 也可直接封板；后续想出 PRD，对话回复「出 PRD」随时续接。",
                origin: origin
            )
            return
        }
        let riskFact = gateRiskNudge(fromStage: .prototype, nextStageName: "PRD")
        // 阶段推进信息作为回合注记并入 PRD 生成回合的 AI 回答顶部
        // 原型重做后旧 PRD 过期 → 结算 prd_stale 💀（风险预测「PRD 会过期」命中）
        if pipelineEngine(for: origin).prdStale {
            settleRisks(.prdStale, note: "原型重新确认，旧 PRD 相对新原型过期", origin: origin)
        }
        await generatePRD(
            tierOverride: nil,
            note: "✅ 原型已确认——进入 ④ PRD 撰写",
            noteSilent: true,
            directive: directive,
            riskNudge: riskFact,
            injectedOpening: injectedOpening,
            origin: origin
        )
    }

    // MARK: - ④ PRD Agent（Task 3.4：评分卡选档 + 三档模板路由 + 双重基准）

    /// PRD 是否已落盘。
    private var prdOnDisk: Bool {
        Self.prdOnDisk(project: pipeline.project, version: pipeline.version)
    }

    /// 指定上下文的 PRD 落盘判定（origin 口径落盘段用）。
    private static func prdOnDisk(project: String, version: String) -> Bool {
        FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(ArtifactPath.prd).path
        )
    }

    /// 指定上下文的结构产物落盘判定（origin 口径；精简路径判定共用）。
    private static func structureArtifactsOnDisk(project: String, version: String) -> Bool {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        return [ArtifactPath.architecture, ArtifactPath.coreFlows, ArtifactPath.modulePageMap]
            .allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// 指定上下文的原型落盘判定（origin 口径；精简路径判定共用）。
    private static func prototypeOnDisk(project: String, version: String) -> Bool {
        !ArtifactPath.prototypeSlotFiles(project: project, version: version).isEmpty
    }

    /// PRD 截断草稿落盘：04-prd/PRD截断草稿.md（write-then-verify）。
    /// 刻意不写 PRD文档.md——不触发 prdOnDisk / 确认闸口 / Git 快照；
    /// 内容加截断标注头，附 ⚠️ 系统行提示恢复方式。origin 口径（阶段 2）：
    /// 写 origin 版本目录、系统行落回 origin 会话。
    private func writePRDTruncatedDraft(_ body: String, origin: ReplyOrigin) {
        let banner = """
        > ⚠️ **截断草稿**：模型输出超长被截断，本文档**不完整**（未通过落盘校验，不进入确认闸口）。
        > 恢复方式：对话中回复「重新生成 PRD」重试（已自动续写仍未写完）。

        """
        do {
            try PMAgentStore.writeVerified(
                banner + body,
                to: PMAgentStore.versionURL(
                    project: origin.project, version: origin.version
                ).appendingPathComponent(ArtifactPath.prdTruncatedDraft)
            )
            appendOriginSystem(
                "⚠️ PRD 输出超长被截断——已存截断草稿（\(ArtifactPath.prdTruncatedDraft)，不完整）。"
                    + "可回复「重新生成 PRD」重试。",
                origin: origin
            )
        } catch {
            appendOriginSystem(
                "⚠️ 截断草稿保存失败：\(error.localizedDescription)", origin: origin
            )
        }
    }

    /// 当前档位（评分卡落盘值；缺失 → nil，调用侧回退 standard）。
    private var currentPRDTier: String? {
        Self.readPRDTier(project: pipeline.project, version: pipeline.version)
    }

    /// 指定上下文的 PRD 档位（origin 口径落盘段用：跨上下文后台完成读 origin 的
    /// score-card，而非当前 pipeline 上下文的）。
    private static func readPRDTier(project: String, version: String) -> String? {
        guard let data = try? Data(
            contentsOf: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent("04-prd/score-card.json")
        ), let card = try? JSONDecoder().decode(
            ArtifactParser.ScoreCard.self, from: data
        ) else { return nil }
        return card.validTier
    }

    /// 生成 PRD：评分卡选档（tierOverride 一键切换时跳过）→ 模板路由 → artifact:prd 落盘。
    /// note：回合注记（确认推进/档位切换），与 AI 回答合并展示；nil → 默认撰写提示。
    ///   noteSilent：确认推进注记置 true——语义由开场承接句承载，落盘静默（UI 不渲染）；
    ///   档位切换/首次进入④的注记保持可见。
    /// directive：快速通道透传的用户指令（缺失项按合理假设补齐并标注），常规生成传 nil。
    /// riskNudge：跨门风险提醒事实（confirmPrototype 传入，nil = 无）。
    /// injectedOpening：快速通道链首的全链开场承接事实（仅链首传，中段 nil）。
    /// origin：发起上下文快照（阶段 2 闸口链钉定）——phase 文案与生成回合显式钉它。
    private func generatePRD(
        tierOverride: String?, note: String? = nil, noteSilent: Bool = false,
        directive: String? = nil, riskNudge: String? = nil,
        injectedOpening: String? = nil, origin: ReplyOrigin
    ) async {
        // 阶段文案随本链收尾统一清态（重新生成/换档直入时本函数是唯一清态点）
        defer { sessionStore.setStreamPhase(nil, for: origin.sessionId) }
        let tier: String
        if let tierOverride {
            tier = tierOverride
        } else {
            sessionStore.setStreamPhase("正在评分选档…", for: origin.sessionId)
            if let scored = await resolveScoreCard(), let valid = scored.card.validTier {
                tier = valid
                if scored.isNew {
                    // 评分卡行落 origin 会话（resolveScoreCard 含网络往返，期间可能切会话）
                    let scoreEntry = sessionStore.makeEntry(
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
                        )],
                        sessionID: origin.sessionId
                    )
                    try? sessionStore.appendPinned(scoreEntry, origin: origin.storeOrigin)
                }
            } else {
                tier = "standard"  // 评分卡失败兜底（不阻塞流水线）
            }
        }
        sessionStore.setStreamPhase("正在生成 PRD…", for: origin.sessionId)
        let prdGenerationPrompt = await prdSystemPrompt(tier: tier, origin: origin)
        // 精简路径（②/③ 被路径选择跳过、上游产物不在盘）：PRD 不再双重基准——
        // 基于澄清要点表直接撰写，涉及页面与流程按合理假设设计并标注。
        let leanPath = !Self.structureArtifactsOnDisk(
            project: origin.project, version: origin.version
        ) || !Self.prototypeOnDisk(project: origin.project, version: origin.version)
        // 快速通道 PRD 专属：出稿后把默认项列为可点选的「默认项卡」（prdDefaultsCardSection），
        // ②③ 的同名 note 不带此提醒——前置确认卡（prd_preflight）已在入口分流。
        let fastTrackBase = "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设；出稿后按系统提示中的默认项卡协议，把按默认值处理的项列为可点选题（首选项=保持默认）。"
        let fastTrackNote = directive.map { fastTrackBase + $0 }
        await sessionStore.sendSystemTurn(
            note: note ?? "📝 开始撰写 \(tier) 档 PRD",
            noteSilent: noteSilent,
            userPrompt: (leanPath
                ? "请按 \(tier) 档模板撰写 PRD。本版本走精简路径（结构/原型产物未生成）：相关章节基于澄清要点表直接撰写，不引用不存在的产物；涉及页面与流程时按合理假设设计并标注。"
                : "请按 \(tier) 档模板撰写 PRD（双重基准：功能需求与模块-页面映射表及原型页面一一对应）。")
                + "\(fastTrackNote.map { "\n\($0)" } ?? "")"
                + Self.openingTail(
                    directive: directive, injected: injectedOpening,
                    defaultFact: leanPath
                        ? "已确认要点表，本轮直接撰写 PRD 文档（精简路径）"
                        : "已确认原型，本轮开始撰写 PRD 文档",
                    risk: riskNudge),
            settings: settings, stage: .prd,
            systemPrompt: prdGenerationPrompt.prompt,
            maxTokens: LLMClient.artifactMaxTokens, skills: prdGenerationPrompt.skills,
            pinnedOrigin: origin.storeOrigin
        ) { [weak self] reply, _ in
            self?.handleAssistantReply(reply, origin: origin.with(stage: .prd))
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
    private func prdSystemPrompt(
        tier: String, userMessage: String? = nil, origin: ReplyOrigin? = nil,
        toolsEnabled: Bool = false
    ) async -> (prompt: String, skills: [String]) {
        // origin 口径（M4）：产物与风险台账读 origin 版本（链中途切走不串版本）
        let project = origin?.project ?? pipeline.project
        let version = origin?.version ?? pipeline.version
        let originRisks = origin.map { riskStore(for: $0) } ?? risks
        let clarification = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.clarification
        ) ?? "（缺失）"
        let map = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.modulePageMap
        ) ?? "（缺失）"
        let architecture = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.architecture
        ) ?? ""
        let coreFlows = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.coreFlows
        ) ?? ""
        let analysis = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.competitiveAnalysis
        ) ?? ""
        return await assembleSystemPrompt(
            stage: .prd, userMessage: userMessage, origin: origin,
            toolsSection: toolsEnabled
        ) { injection in
            AgentPrompts.prd(
                tier: tier,
                clarification: clarification,
                modulePageMap: map,
                architecture: architecture,
                coreFlows: coreFlows,
                prototypePages: Self.mapRows(in: map).pages,
                analysisNotes: analysis,
                injection: Self.rejectionsInjection(Self.versionDecisions(project: project, version: version))
                    + Self.openRisksInjection(originRisks.activeRisks)
                    + injection
            )
        }
    }

    /// PRD 迭代分支模式头（2026-09-18 思考提速第五批）：三类意图——①反馈修订 /
    /// ②基底落后对齐重排 / ③无新修改点不重排。③ 针对重复「帮我出PRD」类请求：
    /// 基底与已确认材料一致时全量重排是纯转抄（个案实证：每轮烧 30k 输出 + 长思考），
    /// 改为短确认指向既有产物。判错有逃生门——基底落后/缺漏时走 ② 重排。
    /// nonisolated static 供测试直测。
    nonisolated static func prdIterationModeHeader(hasBase: Bool) -> String {
        guard hasBase else {
            return "\n\n当前模式：迭代——按已确认材料与用户消息意图输出 artifact:prd 块。"
        }
        return "\n\n当前模式：迭代——盘上已有 PRD（见下方修订基底）。先识别用户消息类型：\n"
            + "① 含对 PRD 的具体修改反馈 → 按反馈修订后重新输出完整 artifact:prd 块（未改动章节原样保留）；\n"
            + "② 基底已落后于上方已确认材料（上游有更新 / PRD 有缺漏）→ 以上方已确认材料为准"
            + "输出完整 artifact:prd 块，直接对齐，不逐条解释对齐动作；\n"
            + "③ 要求生成但无新修改点、基底与已确认材料一致 → 不重排：用两三句话确认 PRD 已在"
            + "且可直接使用（提示可给反馈修订），不输出 artifact 块。"
    }

    /// 未闭合风险注入（封板兜底：PRD「已知风险与未决事项」章节的数据源）。
    /// 预算 800 字（2026-09-18 记忆预算审计：唯一无预算的动态注入面——42 条 active
    /// 实测 3763 字，长寿命项目会无界膨胀）：行边界截断、标「其余 N 条略」，
    /// 章节完整性由计数标注兜底（模型须注明还有多少条已登记风险）。
    /// 空列表返回空串（不产生注入段）；nonisolated 供测试直测。
    nonisolated static func openRisksInjection(_ records: [RiskRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let lines = records.map { record -> String in
            var line = "- \(record.hypothesis)"
            if let plan = record.plan, !plan.isEmpty { line += " → 应对方案：\(plan)" }
            if record.status == .mitigating { line += "（方案已挂，验证中）" }
            return line
        }
        var kept: [String] = []
        var budget = 800
        for line in lines {
            if line.count > budget { break }
            kept.append(line)
            budget -= line.count
        }
        let omitted = lines.count - kept.count
        let tail = omitted > 0
            ? "\n（其余 \(omitted) 条已登记风险略——完整清单见风险台账；章节中注明「另有 \(omitted) 条风险登记在台账」。）"
            : ""
        return "## 已登记风险（写入「已知风险与未决事项」章节，逐条列出）\n"
            + kept.joined(separator: "\n") + tail + "\n"
    }

    /// 当前版本 decisions.jsonl 的决策条目（文件序；读失败返回空）。
    nonisolated static func versionDecisions(project: String, version: String) -> [DecisionRecord] {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "decisions.jsonl")
        return PMAgentStore.readLines(DecisionLogEntry.self, from: url).compactMap {
            if case .decision(let record) = $0 { return record }
            return nil
        }
    }

    /// 已否决方案注入（PRD「3.4 范围-不包含」的数据源）：各决策的 rejectedAlternatives
    /// 一行一条摘要，总预算约 300 字（超出在行边界截断标「其余略」）。
    /// 生效视图过滤（2026-09-18 supersedes 协议）：被后续决策推翻的旧否决不再注入——
    /// 临时否决（「需验证」）被裁决翻转后残留注入会迫使模型仲裁新旧矛盾（个案分析：
    /// 单轮 19% 思考量耗在此）。决策档案渲染保留全量历史，仅注入层过滤。
    /// 空返回空串（不产生注入段）；nonisolated 供测试直测。
    nonisolated static func rejectionsInjection(_ records: [DecisionRecord]) -> String {
        let superseded = Set(records.flatMap { $0.supersedes ?? [] })
        let lines = records.enumerated().flatMap { _, record in
            record.rejectedAlternatives.enumerated().compactMap { (index, alt) -> String? in
                guard !superseded.contains("\(record.id)#\(index)") else { return nil }
                var line = "- \(alt.option)（否决原因：\(alt.reason)）"
                if let owner = alt.ownership { line += "［\(owner.label)］" }
                return line
            }
        }
        guard !lines.isEmpty else { return "" }
        var kept: [String] = []
        var budget = 300
        for line in lines {
            if line.count > budget {
                kept.append("（其余略）")
                break
            }
            kept.append(line)
            budget -= line.count
        }
        return "## 已否决方案（写入「三、需求概述 3.4 范围-不包含」，逐条列出）\n"
            + kept.joined(separator: "\n") + "\n"
    }

    /// 历史否决引用键清单（决策 supersedes 协议的注入侧，2026-09-18）：为每条
    /// 未被取代的否决生成「决策id#序号」引用键，随四个主线阶段尾条下发——
    /// 话题闭合决策推翻旧否决时，LLM 照抄引用键回填 decision 块 supersedes 字段。
    /// 只列 option + 否决日期（轻量：每轮都注入，reason 全文由 PRD 的
    /// rejectionsInjection 承载）；预算 400 字，超限保尾部（新否决更可能被推翻，
    /// 更早的截断标「更早的略」）。全无否决 → 空串不注入。nonisolated 供测试直测。
    nonisolated static func supersedableRejections(_ records: [DecisionRecord]) -> String {
        let superseded = Set(records.flatMap { $0.supersedes ?? [] })
        let lines = records.enumerated().flatMap { _, record in
            record.rejectedAlternatives.enumerated().compactMap { (index, alt) -> String? in
                guard !superseded.contains("\(record.id)#\(index)") else { return nil }
                let day = record.createdAt.count >= 10
                    ? String(record.createdAt.prefix(10).suffix(5))  // MM-DD
                    : ""
                return "- [\(record.id)#\(index)] \(alt.option)（否决于 \(day)）"
            }
        }
        guard !lines.isEmpty else { return "" }
        var kept: [String] = []
        var budget = 400
        for line in lines.reversed() {
            if line.count > budget { break }
            kept.insert(line, at: 0)
            budget -= line.count
        }
        if kept.count < lines.count { kept.insert("（更早的略）", at: 0) }
        let header = "## 历史否决引用键（本轮决策推翻某条旧否决时，在 decision 块写"
            + " \"supersedes\": [\"引用键\"]，可多条；未推翻不写，禁止编造引用键）\n"
        return header + kept.joined(separator: "\n") + "\n"
    }

    // MARK: - 变更分诊（提案卡 + 候选池：LLM 分诊提案，用户裁决执行）

    /// 提案落卡：backtrack 块 → changes.jsonl 登记（pending）+ 聊天流变更提案卡。
    /// target 白名单校验在受理处已完成；pool 建议无 target 时仅登记不回退，
    /// 用户若坚持纳入，想法级采纳走 ① 增补澄清（adoptChangeProposal 兜底）。

    // MARK: - 草稿预演（B1：会话级草稿链，产物镜像提案目录，不触主线状态机）

    /// origin 是否草稿预演会话；是则返回其会话 id（提案目录分槽键）。
    private func draftSessionId(of origin: ReplyOrigin) -> String? {
        guard SessionStore.isDraftSession(
            project: origin.project, version: origin.version, sessionId: origin.sessionId
        ) else { return nil }
        return origin.sessionId
    }

    /// 草稿推进位置（阶段显示名，用户可见文案）。
    private static func draftStageName(_ stage: PipelineRun.Stage) -> String {
        switch stage {
        case .clarify: "① 澄清"
        case .structure: "② 结构"
        case .prototype: "③ 原型"
        case .prd: "④ PRD"
        }
    }

    /// 草稿推进意图检测（草稿会话内触发 draftAdvance 的对话指令）。
    private static func isDraftAdvanceIntent(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let intents = ["进入下一阶段", "下一步", "直接出原型", "直接出prd", "直接出 prd", "出原型", "出prd", "出 prd", "继续出"]
        return intents.contains { lowered.contains($0) }
    }

    /// 草稿预演回合落盘：产物块镜像写提案目录 + 推进位置前移 + 刷新提案登记；
    /// 系统行落草稿会话自己的对话流。主线状态机/横切/机器门/里程碑全程不触。
    private func handleDraftReply(
        _ reply: DiscussionEntry, origin: ReplyOrigin,
        proposalSessionId: String, prototypeSnapshot: [String: String]? = nil
    ) {
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply.content)
        let project = origin.project
        let version = origin.version
        do {
            switch origin.stage {
            case .structure:
                guard ArtifactParser.structureArtifactsComplete(blocks) else { return }
                let structure = try ArtifactParser.writeStructureArtifacts(
                    blocks: blocks, project: project, version: version,
                    proposalSessionId: proposalSessionId
                )
                SessionStore.advanceDraftStage(
                    project: project, version: version,
                    sessionId: origin.sessionId, to: .structure
                )
                appendOriginSystem(
                    "📄 结构草稿已生成（\(structure.changes.count) 个文件，不落主线）——"
                        + "回复「进入下一阶段」继续预演原型草稿；或到「决策日志 · 变更池」合并入主线。",
                    origin: origin
                )
                registerDraftProposal(origin: origin, stage: .structure, fileCount: structure.changes.count)
            case .prototype:
                guard let prototype = try ArtifactParser.writePrototypeArtifact(
                    blocks: blocks, project: project, version: version,
                    proposalSessionId: proposalSessionId
                ) else { return }
                SessionStore.advanceDraftStage(
                    project: project, version: version,
                    sessionId: origin.sessionId, to: .prototype
                )
                appendOriginSystem(
                    "🎨 原型草稿已生成（\(prototype.slots.count) 端，不落主线）——"
                        + "回复「出 PRD」继续预演；或到「决策日志 · 变更池」合并入主线。",
                    origin: origin
                )
                registerDraftProposal(origin: origin, stage: .prototype, fileCount: prototype.changes.count)
            case .prd:
                guard let prd = try ArtifactParser.writePRDArtifact(
                    blocks: blocks, tier: "standard", project: project, version: version,
                    proposalSessionId: proposalSessionId
                ) else { return }
                SessionStore.advanceDraftStage(
                    project: project, version: version,
                    sessionId: origin.sessionId, to: .prd
                )
                appendOriginSystem(
                    "📝 PRD 草稿已生成（不落主线）——到「决策日志 · 变更池」"
                        + "合并入主线，或放弃本次草稿。",
                    origin: origin
                )
                registerDraftProposal(origin: origin, stage: .prd, fileCount: prd.changes.count)
            case .clarify:
                break  // 澄清预演轮无产物块
            }
        } catch {
            appendOriginSystem(
                "⚠️ 草稿产物落盘失败：\(error.localizedDescription)", origin: origin
            )
        }
    }

    /// 登记/刷新草稿推进提案（固定 id 幂等：fold 后最新行胜出，append-only 不改历史）。
    private func registerDraftProposal(origin: ReplyOrigin, stage: PipelineRun.Stage, fileCount: Int) {
        let record = ChangeProposalRecord(
            id: "draft-\(origin.sessionId)",
            idea: "草稿预演：\(Self.draftStageName(stage))产物已就绪（\(fileCount) 个文件），可合并入主线",
            checkpointStage: stage.rawValue,
            kind: "stage_draft",
            draftSessionId: origin.sessionId,
            draftStage: stage.rawValue
        )
        ChangeLedger.append(.proposal(record), project: origin.project, version: origin.version)
        if originIsCurrentContext(origin) { refreshChangeLedger() }
    }

    /// 草稿预演推进（对话指令触发）：按草稿推进位置生成下一阶段草稿产物。
    /// 与主线确认链同构，但产物全落提案目录、不触主线引擎/闸口/机器门。
    private func draftAdvance(origin: ReplyOrigin) async {
        guard draftSessionId(of: origin) != nil else { return }
        guard !currentVersionReleased else {
            appendOriginSystem("🔒 版本已封板（只读）——草稿预演不可继续推进。", origin: origin)
            return
        }
        let stage = SessionStore.draftStage(
            project: origin.project, version: origin.version, sessionId: origin.sessionId
        ) ?? .clarify
        switch stage {
        case .clarify:
            // 抽草稿要点表（transcript = 草稿会话投影）→ 写提案目录 → 生成结构草稿回合
            sessionStore.setStreamPhase("正在抽取草稿要点表…", for: origin.sessionId)
            let transcript = Self.extractionTranscript(
                from: sessionStore
                    .entries(project: origin.project, version: origin.version, sessionId: origin.sessionId)
                    .filter { $0.role != .system }
            )
            let tablePrompt = AgentPrompts.clarificationTable(transcript: transcript, previous: nil)
            var tableResult = await extractWithReason(
                ClarificationTable.self, prompt: tablePrompt, maxTokens: 8192
            )
            if tableResult.value == nil {
                tableResult = await extractWithReason(
                    ClarificationTable.self, prompt: tablePrompt, maxTokens: 8192
                )
            }
            guard let table = tableResult.value else {
                appendOriginSystem(
                    "⚠️ 草稿要点表生成失败（已重试 1 次）：\(tableResult.failureReason ?? "未知原因")——稍后回复「进入下一阶段」重试。",
                    origin: origin
                )
                return
            }
            let draftRoot = PMAgentStore.artifactRoot(
                project: origin.project, version: origin.version, proposalSessionId: origin.sessionId
            )
            do {
                try PMAgentStore.writeVerified(
                    table.markdown,
                    to: draftRoot.appendingPathComponent(ArtifactPath.clarification)
                )
            } catch {
                appendOriginSystem("⚠️ 草稿要点表保存失败：\(error.localizedDescription)", origin: origin)
                return
            }
            SessionStore.advanceDraftStage(
                project: origin.project, version: origin.version,
                sessionId: origin.sessionId, to: .structure
            )
            registerDraftProposal(origin: origin, stage: .structure, fileCount: 1)
            await draftGenerateTurn(stage: .structure, origin: origin, clarification: table.markdown)
        case .structure:
            await draftGenerateTurn(stage: .prototype, origin: origin, clarification: nil)
        case .prototype:
            await draftGenerateTurn(stage: .prd, origin: origin, clarification: nil)
        case .prd:
            appendOriginSystem(
                "草稿已推进到 ④ PRD——到「决策日志 · 变更池」合并入主线，或放弃本次草稿。",
                origin: origin
            )
        }
    }

    /// 草稿生成回合（draftAdvance 的三段共用）：组下一阶段草稿 prompt → 系统轮
    /// 生成 → 回调 handleDraftReply 镜像落提案目录。
    private func draftGenerateTurn(
        stage: PipelineRun.Stage, origin: ReplyOrigin, clarification: String?
    ) async {
        let sid = origin.sessionId
        let draftRoot = PMAgentStore.artifactRoot(
            project: origin.project, version: origin.version, proposalSessionId: sid
        )
        let turnOrigin = origin.with(stage: stage)
        sessionStore.setStreamPhase("正在生成草稿…", for: sid)
        let prompt: (prompt: String, skills: [String])
        switch stage {
        case .structure:
            let structurePrompt = await assembleSystemPrompt(
                stage: .structure, origin: turnOrigin
            ) { injection in
                AgentPrompts.structure(
                    clarification: clarification ?? "（草稿要点表缺失）",
                    previousArtifacts: nil, injection: injection
                )
            }
            prompt = structurePrompt
        case .prototype:
            let map = Self.readArtifact(root: draftRoot, rel: ArtifactPath.modulePageMap) ?? "（缺失）"
            let flows = Self.readArtifact(root: draftRoot, rel: ArtifactPath.coreFlows) ?? "（缺失）"
            let prototypePrompt = await assembleSystemPrompt(
                stage: .prototype, origin: turnOrigin
            ) { injection in
                AgentPrompts.prototype(
                    modulePageMap: map, coreFlows: flows,
                    previousPrototypes: [], injection: injection
                )
            }
            prompt = prototypePrompt
        case .prd:
            // 草稿 PRD：standard 档直出（评分卡属主线资产，合并时以主线评分上下文为准）
            let clarificationDraft = Self.readArtifact(root: draftRoot, rel: ArtifactPath.clarification) ?? "（缺失）"
            let map = Self.readArtifact(root: draftRoot, rel: ArtifactPath.modulePageMap) ?? "（缺失）"
            let architecture = Self.readArtifact(root: draftRoot, rel: ArtifactPath.architecture) ?? ""
            let flows = Self.readArtifact(root: draftRoot, rel: ArtifactPath.coreFlows) ?? ""
            let prdPrompt = await assembleSystemPrompt(
                stage: .prd, origin: turnOrigin
            ) { injection in
                AgentPrompts.prd(
                    tier: "standard",
                    clarification: clarificationDraft,
                    modulePageMap: map,
                    architecture: architecture,
                    coreFlows: flows,
                    prototypePages: Self.mapRows(in: map).pages,
                    analysisNotes: "",
                    injection: injection
                )
            }
            prompt = prdPrompt
        case .clarify:
            return
        }
        let note: String
        switch stage {
        case .structure: note = "🧪 草稿预演——进入 ② 结构（产物不落主线）"
        case .prototype: note = "🧪 草稿预演——进入 ③ 原型（产物不落主线）"
        case .prd: note = "🧪 草稿预演——撰写 PRD 草稿（产物不落主线）"
        case .clarify: note = ""
        }
        await sessionStore.sendSystemTurn(
            note: note,
            userPrompt: "请基于上方草稿上下文，输出本阶段完整产物块。",
            settings: settings, stage: LLMStage(rawValue: stage.rawValue) ?? .clarify,
            systemPrompt: prompt.prompt,
            maxTokens: stage == .clarify ? 16384 : 32768,
            skills: prompt.skills, pinnedOrigin: origin.storeOrigin
        ) { [weak self] reply, _ in
            self?.handleAssistantReply(reply, origin: turnOrigin)
        }
    }

    /// 草稿合并入主线（B2）：提案目录镜像文件对拷入主线 + 主线状态机推进到
    /// 草稿终点 + 决策日志留痕 + 提案毕业。要求当前选中即目标版本（合并是
    /// 版本级结构写，且推进读活引擎）。返回错误文案，nil = 成功。
    func mergeDraftProposal(_ item: ChangeItem, project: String, version: String) -> String? {
        guard item.proposal.isStageDraft,
              let sid = item.proposal.draftSessionId,
              let draftStageRaw = item.proposal.draftStage,
              let draftStage = PipelineRun.Stage(rawValue: draftStageRaw) else {
            return "提案数据不完整，无法合并"
        }
        guard pipeline.project == project, pipeline.version == version else {
            return "请先切换到「\(project) · \(version)」的会话再合并"
        }
        guard !currentVersionReleased else { return "版本已封板（只读），不可合并" }
        guard !sessionStore.isVersionBusy(project: project, version: version) else {
            return "该版本有回答生成中，请等待结束后再合并"
        }
        let draftRoot = PMAgentStore.artifactRoot(
            project: project, version: version, proposalSessionId: sid
        )
        let mainlineRoot = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        // 收集草稿文件（相对路径，跳过子目录本身）；两侧统一解析符号链接
        //（/var → /private/var：enumerator 返回解析后路径，前缀截取必须同口径）
        let rootPath = URL(fileURLWithPath: draftRoot.path).resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(
            at: draftRoot, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return "草稿目录读取失败" }
        var relFiles: [String] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            relFiles.append(String(resolved.dropFirst(rootPath.count + 1)))
        }
        guard !relFiles.isEmpty else { return "草稿目录为空，无可合并内容" }
        // 对拷覆盖（中间目录按需创建）
        for rel in relFiles {
            let from = draftRoot.appendingPathComponent(rel)
            let to = mainlineRoot.appendingPathComponent(rel)
            let dir = to.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: to.path) { try? fm.removeItem(at: to) }
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                return "复制「\(rel)」失败：\(error.localizedDescription)"
            }
        }
        // 主线状态机推进到草稿终点（只在主线落后时补齐中间确认；主线更深则仅覆盖产物）
        var advanced: [String] = []
        let engine = pipeline
        let stageOrder: [PipelineRun.Stage] = [.clarify, .structure, .prototype, .prd]
        func stageIndex(_ s: PipelineRun.Stage) -> Int {
            stageOrder.firstIndex(of: s) ?? 0
        }
        let draftIndex = stageIndex(draftStage)
        if draftIndex >= stageIndex(.structure), engine.stage == .clarify {
            engine.advanceFromClarify(outcome: "draft_merge")
            advanced.append("进入 ② 结构")
        }
        if draftIndex >= stageIndex(.prototype), engine.stage == .structure {
            try? engine.confirmStructure(outcome: "draft_merge")
            advanced.append("确认结构，进入 ③ 原型")
        }
        if draftIndex >= stageIndex(.prd), engine.stage == .prototype {
            try? engine.confirmPrototype(outcome: "draft_merge")
            advanced.append("确认原型，进入 ④ PRD")
        }
        // 决策留痕 + 提案毕业 + 退出草稿
        try? ArtifactParser.writeDecisions(
            [DecisionRecord(
                version: version,
                decision: "合并草稿预演：\(item.proposal.idea)",
                why: "草稿会话预演后人工确认合并（覆盖 \(relFiles.count) 个产物文件"
                    + (advanced.isEmpty ? "；主线阶段未推进）" : "；主线推进：" + advanced.joined(separator: "、") + "）")
            )],
            project: project, version: version
        )
        ChangeLedger.append(
            .resolution(ChangeResolutionRecord(id: item.proposal.id, resolution: .adopted, note: "草稿合并入主线")),
            project: project, version: version
        )
        _ = SessionStore.setDraft(project: project, version: version, sessionId: sid, isDraft: false)
        snapshotProject(message: "draft merge: 草稿预演合并入主线", project: project, version: version)
        reloadTree()
        refreshGateOwner()
        refreshChangeLedger()
        NotificationCenter.default.post(name: Notification.Name("pm.worker.artifacts.changed"), object: nil)
        appendOriginSystem(
            "✅ 草稿已合并入主线（覆盖 \(relFiles.count) 个产物文件"
                + (advanced.isEmpty ? "" : "，主线" + advanced.joined(separator: "、")) + "）——草稿预演结束。",
            origin: ReplyOrigin(
                project: project, version: version,
                sessionId: sid, stage: pipeline.stage
            )
        )
        return nil
    }

    /// 放弃草稿（变更池显式动作）：提案毕业 dropped + 退出草稿预演。
    func abandonDraftProposal(_ item: ChangeItem, project: String, version: String) {
        guard item.proposal.isStageDraft, let sid = item.proposal.draftSessionId else { return }
        ChangeLedger.append(
            .resolution(ChangeResolutionRecord(id: item.proposal.id, resolution: .dropped, note: "放弃草稿")),
            project: project, version: version
        )
        _ = SessionStore.setDraft(project: project, version: version, sessionId: sid, isDraft: false)
        if originIsCurrentContext(ReplyOrigin(
            project: project, version: version,
            sessionId: sessionStore.sessionId, stage: pipeline.stage
        )) {
            refreshChangeLedger()
        }
        NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
    }

    /// 会话标记/取消草稿预演（侧栏菜单入口）。返回错误文案，nil = 成功；
    /// 进入草稿时在会话流落一条引导行（产物不落主线，处置走变更池）。
    func setSessionDraft(
        project: String, version: String, sessionId: String, isDraft: Bool
    ) -> String? {
        guard let error = SessionStore.setDraft(
            project: project, version: version, sessionId: sessionId, isDraft: isDraft
        ) else {
            if isDraft {
                let stage = SessionStore.draftStage(
                    project: project, version: version, sessionId: sessionId
                ) ?? .clarify
                appendOriginSystem(
                    "🧪 已进入草稿预演——本会话的方案产物不落主线、不影响版本收敛："
                        + "正常对话澄清需求，回复「进入下一阶段」逐段生成草稿；"
                        + "满意后到「决策日志 · 变更池」合并入主线。",
                    origin: ReplyOrigin(
                        project: project, version: version,
                        sessionId: sessionId, stage: stage
                    )
                )
            }
            NotificationCenter.default.post(name: Notification.Name("pm.worker.risks.changed"), object: nil)
            return nil
        }
        return error
    }

    /// 提案登记（LLM backtrack 块 → 变更提案卡）。internal 供测试直调（impacts 纪律降级判据）。
    func presentChangeProposal(_ request: ArtifactParser.BacktrackRequest) {
        var validatedTarget = request.target.flatMap { Self.backtrackStage($0) }
        let impacts = (request.impacts ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // impacts 纪律（ArtifactParser.BacktrackRequest 契约的 App 侧落地，防轻描淡写）：
        // ②/③ 回退建议必须至少引用一个可解析的具体产物（依赖图解析，ArtifactDependencyGraph）；
        // 解析为零 → 不采信 target（提案卡降级为仅登记，想法级纳入走 ① 增补澄清兜底）。
        // ① 澄清目标豁免（增补澄清是对话式判断，不依赖产物级影响清单）。
        if let raw = validatedTarget,
           let graphStage = ArtifactDependencyGraph.Stage(rawValue: raw.rawValue),
           ArtifactDependencyGraph.verifiedTarget(graphStage, impacts: impacts) == nil {
            validatedTarget = nil
        }
        let idea = [request.idea, request.instruction]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "（模型未概述）"
        let record = ChangeProposalRecord(
            idea: idea,
            category: request.category,
            target: validatedTarget?.rawValue,
            mode: request.mode,
            instruction: request.instruction,
            impacts: impacts.isEmpty ? nil : impacts,
            checkpointStage: pipeline.stage.rawValue
        )
        ChangeLedger.append(
            .proposal(record), project: pipeline.project, version: pipeline.version
        )
        refreshChangeLedger()
        try? sessionStore.append(
            sessionStore.makeEntry(role: .system, content: "", changeProposal: record)
        )
    }

    /// 纳入当前版本（提案卡）：重规划计划可见化 → 回退状态机 + 诉求透传重生成。
    /// 回退目标缺省回①——想法级纳入先过增补澄清判断可行性（与分诊协议 clarify 语义一致）；
    /// clarify 目标忽略 mode（要点表始终保留作增补基底）。
    func adoptChangeProposal(_ record: ChangeProposalRecord) {
        // 当前上下文版本口径（阶段 3）：回退重写状态机 + 紧随重生成回合都落本版本，
        // 只被本版本自身的流拦截；他会话他版本的并发流不再挡纳入。
        guard !currentVersionReleased,
              !sessionStore.isVersionBusy(project: pipeline.project, version: pipeline.version) else { return }
        let target = record.target.flatMap(Self.backtrackStage) ?? .clarify
        guard target != pipeline.stage else { return }
        writeChangeResolution(record.id, .adopted, project: pipeline.project, version: pipeline.version)
        let mode = record.mode?.trimmingCharacters(in: .whitespaces) == "redo" ? "redo" : "revise"
        executeBacktrack(to: target, mode: mode)
        Task { await regenAfterBacktrack(
            to: target, instruction: record.instruction,
            mode: target == .clarify ? "revise" : mode
        ) }
    }

    /// 放入候选池（提案卡）：不回退、不打断当前版本收敛；封板前统一处置。
    func poolChangeProposal(_ record: ChangeProposalRecord) {
        writeChangeResolution(record.id, .pooled, project: pipeline.project, version: pipeline.version)
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "📥 已放入候选池——版本封板前在「决策日志 · 变更池」统一处置。"
            )
        )
    }

    /// 继续讨论（提案卡）：提案不采纳、无产物变更，想法留在对话里（回写 dropped 留痕）。
    func dismissChangeProposal(_ record: ChangeProposalRecord) {
        writeChangeResolution(
            record.id, .dropped, note: "继续讨论",
            project: pipeline.project, version: pipeline.version
        )
    }

    /// 变更池毕业（决策日志整页）：纳入后续版本（转决策记录留痕）/ 放弃 / 顺延。
    /// 毕业动作 = 用户明确决策，决策置信度 1.0；仅处置池内（pooled）条目。
    func graduatePoolItem(
        _ item: ChangeItem, project: String, version: String, to resolution: ChangeResolution
    ) {
        guard item.isPooled else { return }
        writeChangeResolution(item.id, resolution, project: project, version: version)
        guard resolution == .adopted else { return }
        try? ArtifactParser.writeDecisions(
            [DecisionRecord(
                version: version,
                decision: "纳入后续版本：\(item.proposal.idea)",
                why: "变更池毕业裁决（封板前显式处置，不默认沉淀）"
            )],
            project: project, version: version
        )
    }

    /// 处置回写（append-only，最新行胜出）+ 当前上下文台账刷新。
    private func writeChangeResolution(
        _ id: String, _ resolution: ChangeResolution, note: String? = nil,
        project: String, version: String
    ) {
        ChangeLedger.append(
            .resolution(ChangeResolutionRecord(id: id, resolution: resolution, note: note)),
            project: project, version: version
        )
        if project == pipeline.project, version == pipeline.version {
            refreshChangeLedger()
        }
    }

    /// 变更台账刷新（上下文切换 / 提案登记 / 处置回写后调用；提案卡处置状态的唯一依据）。
    func refreshChangeLedger() {
        changeLedger = ChangeLedger.load(project: pipeline.project, version: pipeline.version)
    }

    // MARK: - 回退回路（Task 3.5：E8 / 过期传播 + 💀 事件结算；变更提案卡纳入 + UI 快捷入口共用）

    /// 回退执行（变更提案卡「纳入」/ UI 快捷按钮触发）：重规划计划可见化 + 状态机回退 +
    /// 💀 事件结算 + 分级过期传播。接续动作由 regenAfterBacktrack 完成（structure/prototype 自动重做；
    /// clarify 转入对话式增补澄清，AI 先判断新功能可行性再提问）。
    /// 重规划计划（ArtifactDependencyGraph）折叠进「🔄 已回到」行——先给「将依次重做哪些产物」的
    /// 确定性计划再执行（计划 → 执行 → 重生成 → 过期清除的闭环起点）；不新发独立系统行
    /// （新前缀会切断快速通道链游走判定，bugs.md B004 同教训）。
    /// backfill（2026-09-17 路径选择补课）：补做先前跳过的阶段——不结算风险
    /// （不是「发现缺口」，是主动补全路径），系统行换补做文案，且无重规划计划
    /// （被补做的阶段本无产物，无「失效重做」可言）。
    private func executeBacktrack(
        to target: PipelineRun.Stage, mode: String = "revise", backfill: Bool = false
    ) {
        let source = pipeline.stage
        switch target {
        case .clarify:
            pipeline.invalidateClarify()
            // 新需求回澄清不结算风险——不是「发现缺口」，是需求范围演进
        case .structure:
            pipeline.invalidateStructure()
            if !backfill {
                settleRisks(
                    .structureRegen,
                    note: source == .prd ? "用户在④发现结构缺口，回退重做结构" : "用户在③发现结构缺口，回退重做结构"
                )
            }
        default:
            pipeline.invalidatePrototype()
            if !backfill {
                settleRisks(.prototypeRegen, note: "用户在④发现原型缺口，回退重做原型")
            }
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
            tail = backfill ? "——补做先前跳过的路径，马上生成。" : "——马上重做。"
        default:
            targetName = "③ 原型（PRD 标记过期：局部）"
            tail = backfill ? "——补做先前跳过的路径，马上生成。" : "——马上重做。"
        }
        let replanSuffix: String
        if !backfill,
           let graphStage = ArtifactDependencyGraph.Stage(rawValue: target.rawValue) {
            replanSuffix = ArtifactDependencyGraph.replanSuffix(target: graphStage, mode: mode) ?? ""
        } else {
            replanSuffix = ""
        }
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "🔄 已回到 \(targetName)\(tail)\(replanSuffix)"
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
        // 发起上下文快照（阶段 2）：重做回合与产物解析钉当前上下文
        let origin = ReplyOrigin(
            project: pipeline.project, version: pipeline.version,
            sessionId: sessionStore.sessionId, stage: target
        )
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
                stage: .clarify, userMessage: directive.isEmpty ? nil : directive, origin: origin,
                volatileTail: AgentPrompts.clarifyStateSection(
                    rounds: rounds, limit: PipelineEngine.clarifyRoundLimit,
                    previousTable: previousTable, amending: true
                )
            ) { injection in
                AgentPrompts.clarify(injection: injection)
            }
            let userPrompt = directive.isEmpty
                ? "用户提出了新的产品诉求。请按增补澄清规则处理：先基于既有要点表判断可行性与优先级，再围绕新功能的关键缺口提问（每次一个问题）。"
                : "用户提出新诉求：\(directive)。请按增补澄清规则处理：先基于既有要点表判断这个诉求能不能做、适不适合做（给出依据与优先级建议），再围绕新功能的关键缺口提问（每次一个问题）。"
            await sessionStore.sendSystemTurn(
                note: "🔄 回到 ① 澄清——新功能先判断，再补问缺口",
                userPrompt: userPrompt,
                settings: settings, stage: .clarify,
                systemPrompt: systemPrompt.prompt,
                maxTokens: 16384, skills: systemPrompt.skills,
                pinnedOrigin: origin.storeOrigin
            ) { [weak self] reply, _ in
                self?.handleClarifyTurn(reply, origin: origin)
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
                stage: .structure, userMessage: directive.isEmpty ? nil : directive, origin: origin
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
                }() + gateInviteSuffix(for: .structure, origin: origin),
                settings: settings, stage: .structure,
                systemPrompt: systemPrompt.prompt, maxTokens: LLMClient.artifactMaxTokens,
                skills: systemPrompt.skills, pinnedOrigin: origin.storeOrigin
            ) { [weak self] reply, _ in
                self?.handleAssistantReply(reply, origin: origin)
            }
        case .prototype:
            guard pipeline.canGeneratePrototype else { return }
            let project = pipeline.project
            let version = pipeline.version
            // 阶段 4：revise 基底（本次注入的槽位全文）同步作冲突快照；redo 不注入
            // 旧原型 → 无可校验期望，传 nil（v1 边界：推翻重来不检测外部变更）。
            let bases = revise
                ? prototypeBases(project: project, version: version)
                : []
            let prototypeSnapshot = bases.isEmpty
                ? nil
                : Dictionary(uniqueKeysWithValues: bases.map { ($0.relPath, $0.sha) })
            let map = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.modulePageMap
            ) ?? "（缺失）"
            let flows = Self.readArtifact(
                project: project, version: version, rel: ArtifactPath.coreFlows
            ) ?? "（缺失）"
            let prompt = await assembleSystemPrompt(
                stage: .prototype, userMessage: directive.isEmpty ? nil : directive, origin: origin
            ) { injection in
                AgentPrompts.prototype(
                    modulePageMap: map, coreFlows: flows,
                    previousPrototypes: bases.map { (label: $0.label, html: $0.html) },
                    injection: injection
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
                }() + gateInviteSuffix(for: .prototype, origin: origin),
                settings: settings, stage: .prototype,
                systemPrompt: prompt.prompt, maxTokens: LLMClient.artifactMaxTokens,
                skills: prompt.skills, pinnedOrigin: origin.storeOrigin,
                prototypeSnapshot: prototypeSnapshot
            ) { [weak self] reply, prototypeSnapshot in
                self?.handleAssistantReply(reply, origin: origin, prototypeSnapshot: prototypeSnapshot)
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
    /// .prd→.prd 特例放行（2026-09-17 路径选择）：③ 停驻态续出——仅 PRD 不在盘时
    /// （在盘则属迭代反馈，走 .prd 常规分支，不经快速通道）。
    /// prdOnDisk：当前版本 PRD 落盘事实（调用方实例传入；仅 .prd→.prd 判定用）。
    static func fastForwardTarget(
        _ raw: String, from current: PipelineRun.Stage, prdOnDisk: Bool
    ) -> PipelineRun.Stage? {
        let target: PipelineRun.Stage
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "prototype": target = .prototype
        case "prd": target = .prd
        default: return nil
        }
        let order: [PipelineRun.Stage] = [.clarify, .structure, .prototype, .prd]
        guard let from = order.firstIndex(of: current),
              let to = order.firstIndex(of: target), to > from else {
            return (current == .prd && target == .prd && !prdOnDisk) ? target : nil
        }
        return target
    }

    /// 快速通道执行（2026-09-17 路径选择改义——skip 语义）：「直接出 X」= 直达 X，
    /// 中间阶段按路径选择跳过（写 skipped.json 闭环，不生成产物），不再全产物串链。
    /// (.prd, .prd)：③ 停驻态续出 PRD（清停驻标记 + 评分选档生成）。
    /// 失败自然停在出发阶段（跳过标记仅在要点表收束成功后写入）或目标阶段
    /// （PRD 未落盘可重触发），用户重说「直接出 X」即可重试。
    /// origin：调用点快照（M3）——本函数在独立 Task 里跑，起跑时用户可能已切走；
    /// 运行态按 origin 版本键控（M2），跨版本快速通道并行互不回环。
    private func runFastForward(to target: PipelineRun.Stage, instruction: String?, origin: ReplyOrigin) async {
        let ffKey = VersionKey(origin)
        fastForwardVersions.insert(ffKey)
        fastForwardFinalStages[ffKey] = target
        defer {
            fastForwardVersions.remove(ffKey)
            fastForwardFinalStages[ffKey] = nil
        }
        let directive = "用户要求快速出稿：缺失项按合理假设补齐并在产物中标注假设。"
            + (instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        // 开场承接（系统行融合）：首回合播报路径事实（openingTail 注入）。
        let chainFact: String?
        switch (origin.stage, target) {
        case (.clarify, .prototype):
            chainFact = "已按用户要求跳过 ② 结构与逐步确认：收束要点表，直接生成原型"
        case (.clarify, .prd):
            chainFact = "已按用户要求跳过 ②③ 与逐步确认：收束要点表，直接撰写 PRD"
        case (.structure, .prototype):
            chainFact = "已按用户要求跳过确认，直接生成原型"
        case (.structure, .prd):
            chainFact = "已按用户要求跳过 ③ 原型与确认，直接撰写 PRD"
        case (.prototype, .prd):
            chainFact = "已按用户要求跳过确认，直接撰写 PRD"
        case (.prd, .prd):
            chainFact = "已按用户要求续接，从停驻点开始撰写 PRD"
        default:
            chainFact = nil
        }

        switch (origin.stage, target) {
        case (.clarify, .prototype):
            // ① 跳 ② 直出 ③
            await confirmClarify(
                origin: origin, route: .skipToPrototype,
                directive: directive, injectedOpening: chainFact
            )
        case (.clarify, .prd):
            // ① 跳 ②③ 直出 ④
            await confirmClarify(
                origin: origin, route: .skipToPRD,
                directive: directive, injectedOpening: chainFact
            )
        case (.structure, .prototype):
            // ②→③ 是「少点确认」不跳阶段：常规确认链（outcome = fast_track）
            await confirmStructure(
                origin: origin, directive: directive, injectedOpening: chainFact
            )
        case (.structure, .prd):
            // ② 跳 ③ 直出 ④
            await confirmStructure(
                origin: origin, route: .skipToPRD,
                directive: directive, injectedOpening: chainFact
            )
        case (.prototype, .prd):
            // ③→④ 是「少点确认」不跳阶段：常规确认链
            await confirmPrototype(
                origin: origin, directive: directive, injectedOpening: chainFact
            )
        case (.prd, .prd):
            // ③ 停驻续出：清停驻标记，评分选档直接撰写
            pipelineEngine(for: origin).clearStopHere()
            recordRouteDecision(
                decision: "【路径选择】停驻续出：从「到原型为止」改为出 PRD",
                why: "用户在停驻态显式要求续接出 PRD（阶段路径选择：想出就出，不锁路径）"
            )
            await generatePRD(
                tierOverride: nil,
                note: "✅ 续接出 PRD——从原型直接进入 ④ 撰写",
                noteSilent: true,
                directive: directive,
                injectedOpening: chainFact,
                origin: origin
            )
        default:
            break
        }
        reloadTree()
        refreshGateOwner()
    }

    /// ④/③ 快捷回退入口（UI「重做原型 / 重做结构」按钮）：与 LLM 回退块同一执行路径。
    /// 裸点击不带修改要求 → redo（从零重画）；带明确诉求的修订走对话自然语言（LLM 判 revise）。
    func requestBacktrack(to target: PipelineRun.Stage) {
        // 当前上下文版本口径（阶段 3）：重做回合落本版本，只被本版本自身的流拦截；
        // 他会话他版本的并发流不再挡重做。
        guard !currentVersionReleased,
              !sessionStore.isVersionBusy(project: pipeline.project, version: pipeline.version),
              pipeline.stage == .prd || pipeline.stage == .prototype,
              target != pipeline.stage else { return }
        executeBacktrack(to: target, mode: "redo")
        Task { await regenAfterBacktrack(to: target, instruction: nil, mode: "redo") }
    }

    /// 路径选择决策记账（【路径选择】前缀记账卡，决策日志留痕，DecisionArchive 渲染）：
    /// 跳过 / 到此为止 / 续出 / 补做均为用户显式路径决策——与风险应对卡同构，
    /// 回写 decisions.jsonl（appendLine，最新行胜出）。
    private func recordRouteDecision(decision: String, why: String) {
        try? PMAgentStore.appendLine(
            DecisionLogEntry.decision(DecisionRecord(
                version: pipeline.version, decision: decision, why: why
            )),
            to: PMAgentStore.jsonlURL(
                project: pipeline.project, version: pipeline.version, file: "decisions.jsonl"
            )
        )
    }

    /// 补做入口（2026-09-17 路径选择「随时补课」）：先前按路径选择跳过的阶段，
    /// 现在想补全——删跳过标记走回退机器（invalidate* 已 skip-aware，闭环按
    /// 补做后的确认重推），回到该阶段按常规流程生成 + 确认。
    /// UI 快捷入口（版本时间线补做按钮）；对话自然语言补课走既有 backtrack 块协议。
    func requestBackfill(to target: PipelineRun.Stage) {
        guard !currentVersionReleased,
              !sessionStore.isVersionBusy(project: pipeline.project, version: pipeline.version),
              PipelineEngine.isSkipped(
                  target, project: pipeline.project, version: pipeline.version
              )
        else { return }
        recordRouteDecision(
            decision: "【路径选择】补做\(target == .structure ? " ② 结构" : " ③ 原型")",
            why: "先前跳过的阶段主动补全（阶段路径选择补课），下游闭环按补做后的确认重推"
        )
        executeBacktrack(to: target, backfill: true)
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
    /// origin：链体调用时传发起上下文（M3）——台账与决策日志按 origin 版本落；
    /// nil（同步点击路径）用当前上下文，行为不变。
    private func settleRisks(
        _ trigger: RiskRecord.TriggerSignal, note: String, origin: ReplyOrigin? = nil
    ) {
        let store = origin.map { riskStore(for: $0) } ?? risks
        guard let settled = try? store.settle(trigger: trigger, note: note), !settled.isEmpty
        else { return }
        if let origin {
            appendOriginSystem(
                "💀 风险命中 \(settled.count) 条（触发信号 \(trigger.rawValue)）——预测 vs 实际对照见右栏「风险」台账。",
                origin: origin
            )
        } else {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "💀 风险命中 \(settled.count) 条（触发信号 \(trigger.rawValue)）——预测 vs 实际对照见右栏「风险」台账。"
                )
            )
        }
    }

    /// 跨确认门核验提醒：上一阶段还有「已挂方案」未验证的风险时，落静默审计行
    /// （UI 不渲染），并返回开场承接用的事实文本——由调用方注入当轮 AI 回合的
    /// userPrompt，让模型用大白话把「有 N 个风险待验证」讲进开场承接句。
    /// 验证动作本身在台账行内（已解除 / 没解决），门只负责把人拉回来看一眼。
    /// origin：链体调用传发起上下文（M3）——挂起风险按 origin 版本台账读；
    /// nil（同步路径）用当前上下文，行为不变。
    @discardableResult
    func gateRiskNudge(
        fromStage: RiskRecord.Stage, nextStageName: String, origin: ReplyOrigin? = nil
    ) -> String? {
        let store = origin.map { riskStore(for: $0) } ?? risks
        let hanging = store.mitigatingRisks.filter { $0.stage == fromStage }
        guard !hanging.isEmpty else { return nil }
        if let origin {
            appendOriginSystem(
                "⏳ 进入\(nextStageName)前——「\(Self.stageName(fromStage))」阶段还有 "
                    + "\(hanging.count) 个已挂方案的风险待验证：右栏「风险」台账逐条核（已解除 / 没解决）。",
                origin: origin,
                milestones: [MilestoneStamp(
                    kind: "risk",
                    count: hanging.count,
                    detail: "已挂方案 ≠ 解除 · 验证通过才算数"
                )],
                silent: true
            )
        } else {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⏳ 进入\(nextStageName)前——「\(Self.stageName(fromStage))」阶段还有 "
                        + "\(hanging.count) 个已挂方案的风险待验证：右栏「风险」台账逐条核（已解除 / 没解决）。",
                    milestones: [MilestoneStamp(
                        kind: "risk",
                        count: hanging.count,
                        detail: "已挂方案 ≠ 解除 · 验证通过才算数"
                    )],
                    silent: true
                )
            )
        }
        return "「\(Self.stageName(fromStage))」阶段还有 \(hanging.count) 个已挂方案的风险待验证，"
            + "可提醒用户稍后到右侧「风险」面板逐条核对结论（已解除 / 没解决），不阻塞本轮"
    }

    // MARK: - 开场承接（系统行融合进 AI 回答，2026-09-17 钦定）

    /// 开场承接注入段：把系统交给本回合的事实转成 userPrompt 尾部指令，
    /// 模型在回答开头用大白话承接（替代 ⚡/⏳/✅ 系统行的上屏语义）。
    /// 只给事实与硬约束，不给模板句——防模型照抄标注原文（占位模仿教训）。
    static func openingHandoverSection(fact: String, risk: String?) -> String {
        var text = """
        【开场承接】这是一轮确认后自动开始的生成任务。回复的第一句先用大白话向用户交代当前状态，只依据下面给出的事实，用自己的措辞说，不要照抄本段原文、不要编造其他进展：
        - 本轮状态：\(fact)
        """
        if let risk, !risk.isEmpty {
            text += "- 待核验事项（有则带上，没有就整条略去）：\(risk)\n"
        }
        text += """
        硬要求：开头合计不超过两句，说完立即进入正文；不用任何图标符号；不出现「系统/流程/闸口/阶段/落盘」等内部词，用用户视角的说法（如「你刚确认的要点表」）。
        """
        return text
    }

    /// opening 注入尾组装：常规确认（directive == nil）用当跳默认事实；快速通道
    /// 仅链首（injectedOpening != nil）用全链事实；链中段返回空串——防多跳每轮
    /// 重复播报。risk 为跨门风险提醒事实（nil = 无）。internal 供单测。
    static func openingTail(
        directive: String?, injected: String?, defaultFact: String, risk: String?
    ) -> String {
        if directive != nil && injected == nil { return "" }
        let fact = injected ?? defaultFact
        return "\n" + openingHandoverSection(fact: fact, risk: risk)
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
        snapshotProject(
            message: message, project: pipeline.project, version: pipeline.version
        )
    }

    /// 指定上下文的快照（origin 口径：后台完成落盘段在跨上下文时快照 origin 项目）。
    private func snapshotProject(message: String, project: String, version: String) {
        let projectDir = PMAgentStore.versionURL(project: project, version: version)
            .deletingLastPathComponent()
        Task.detached { [projectDir, message] in
            _ = try? await GitSnapshotQueue.shared.snapshot(projectDir: projectDir, message: message)
        }
    }

    // MARK: - 竞品分析分支（Task 3.8：意图命中分流，主线不阻塞）

    private func runCompetitiveAnalysis(topic: String, origin: ReplyOrigin) async {
        let project = origin.project
        let version = origin.version
        // 分支触发记录（开发者检查器「分支技能触发」展示，Task 4.1 可观测性）
        branchTriggers.append(
            BranchTriggerRecord(
                id: UUID().uuidString,
                kind: "competitive_analysis",
                detail: "竞品分析意图命中：「\(String(topic.prefix(40)))」",
                createdAt: ISO8601.timestamp()
            )
        )
        // 全部系统行 pinned 落 origin 会话——本函数在独立 Task 里跑，起跑时
        // 用户可能已切会话/项目，行归属必须钉发起上下文而非当前打开会话。
        appendOriginSystem("🔍 竞品分析分支后台运行中（主线可继续对话）……", origin: origin)
        let runner = AnalysisRunner()
        do {
            let url = try await runner.run(
                topic: topic, project: project,
                version: version, settings: settings
            )
            if url != nil {
                appendOriginSystem(
                    "📦 竞品分析报告已生成——右栏「文件」可预览，撰写 PRD 时会参考（须标出处）。",
                    origin: origin
                )
            } else {
                appendOriginSystem(
                    "⚠️ 竞品分析未产出（模型未按 artifact:analysis 协议返回），稍后重试。",
                    origin: origin
                )
            }
        } catch {
            appendOriginSystem(
                "⚠️ 竞品分析失败：\(error.localizedDescription)", origin: origin
            )
        }
        reloadTree()
    }

    // MARK: - 分支执行前确认（意图误触发防护：停靠卡裁决回调，design.md §12）

    /// 确认执行（分支确认卡「运行」）：收卡 → 走既有后台执行路径。
    /// 分支归属钉发起上下文（pending 携带 sessionId + project/version）——
    /// 确认时用户可能已切走，行归属与产物落盘都以发起上下文为准。
    func confirmBranchRun() {
        guard let pending = pendingBranchConfirmation else { return }
        pendingBranchConfirmation = nil
        let origin = ReplyOrigin(
            project: pending.project, version: pending.version,
            sessionId: pending.sessionId, stage: pipeline.stage
        )
        Task { await runCompetitiveAnalysis(topic: pending.topic, origin: origin) }
    }

    /// 取消执行（分支确认卡「暂不运行」）：收卡 + 留痕——检查器触发记录记 rejected，
    /// 对话流落 ⏹ 事件条（已有事件 emoji，独立事件条渲染，不并入回合注记）。
    func cancelBranchRun() {
        guard let pending = pendingBranchConfirmation else { return }
        pendingBranchConfirmation = nil
        branchTriggers.append(
            BranchTriggerRecord(
                id: UUID().uuidString,
                kind: "competitive_analysis",
                detail: "分支确认卡取消：「\(String(pending.topic.prefix(40)))」",
                createdAt: ISO8601.timestamp()
            )
        )
        // ⏹ 留痕钉发起上下文：取消时用户可能已切走（与 confirmBranchRun 同口径）
        let origin = ReplyOrigin(
            project: pending.project, version: pending.version,
            sessionId: pending.sessionId, stage: pipeline.stage
        )
        appendOriginSystem("⏹ 已取消运行竞品分析——想调研随时再说。", origin: origin)
    }

    // MARK: - 版本封板（Task 3.7：ProjectHomeView 两段确认后回调）

    func releaseVersion(project: String, version: String) async {
        guard version != "unversioned" else { return }  // 兜底容器不是发布单元（UI 侧已过滤）
        let summary = Self.artifactsSummary(project: project, version: version)
        // 版本不再是记忆作用域（方案 A）：封板只冻结产物，记忆条目带版本溯源标签留在项目池

        // 1. release-notes：LLM 基于产物摘要生成（失败兜底手写清单，不阻塞封板）
        var notes: String
        if let raw = try? await sessionStore.oneShot(
            VersionStore.releaseNotesPrompt(artifactsSummary: summary),
            settings: settings, stage: .classify, maxTokens: 2048
        ), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = raw
        } else {
            notes = "## 本版本概览\n\n（模型不可用，以下为产物清单摘要）\n\n\(summary)"
        }

        // 2. 本版复盘（决策稳定性）确定性追加：变更处置 / 回退 / 闸口 outcome——
        //    对账段不经 LLM 转述，fold 自磁盘事实；无任何信号则不追加
        if let retroSection = ReleaseRetro.load(project: project, version: version)
            .markdownSection {
            notes += "\n\n" + retroSection
        }

        do {
            // 3. 封板：💀 终态结算 → release-notes → version.json → 目录冻结只读
            try versionStore.release(
                project: project, version: version, notes: notes,
                settleRisks: { [weak self] in try self?.risks.settleAllForRelease() }
            )
            // 4. Git 快照（封板终态）
            let projectDir = PMAgentStore.versionURL(project: project, version: version)
                .deletingLastPathComponent()
            _ = try? await GitSnapshotQueue.shared.snapshot(
                projectDir: projectDir, message: "release: \(version) 封板"
            )
        } catch {
            // 封板失败行落被封板版本的会话流：oneShot/快照含 await，期间可能切走——
            // 上下文仍是被封板版本才落行（否则无归属会话，收窄到日志通道不留痕错版本）
            if pipeline.project == project, pipeline.version == version {
                try? sessionStore.append(
                    sessionStore.makeEntry(role: .system, content: "⚠️ 封板失败：\(error.localizedDescription)")
                )
            } else {
                NSLog("pm_worker 封板失败（上下文已切走，行未落会话）：\(error.localizedDescription)")
            }
        }
        reloadTree()
        refreshReleasedState()
    }

    /// 版本产物摘要（release-notes 生成的输入，纯磁盘事实，不虚构）。
    static func artifactsSummary(project: String, version: String) -> String {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        var lines = ["项目：\(project)，版本：\(version)"]
        let upstream: [(String, String)] = [
            (ArtifactPath.clarification, "澄清要点表"),
            (ArtifactPath.architecture, "功能架构图"),
            (ArtifactPath.coreFlows, "核心流程图"),
            (ArtifactPath.modulePageMap, "模块-页面映射表"),
        ]
        for (rel, name) in upstream
        where fm.fileExists(atPath: dir.appendingPathComponent(rel).path) {
            lines.append("- \(name)（\(rel)）")
        }
        // 原型按槽位枚举（多端多份，磁盘事实源；旧单文件 = 默认槽位「交互原型」）
        for slot in ArtifactPath.prototypeSlotFiles(project: project, version: version) {
            lines.append("- \(slot.display)（\(slot.relPath)）")
        }
        let downstream: [(String, String)] = [
            (ArtifactPath.prd, "PRD 文档"),
            (ArtifactPath.competitiveAnalysis, "竞品分析包"),
            (ArtifactPath.releaseNotes, "发布说明"),
        ]
        for (rel, name) in downstream
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

    private func sedimentMemory(transcript: String, origin: ReplyOrigin) async {
        guard let items = await extract(
            [MemoryStore.ExtractionItem].self,
            prompt: AgentPrompts.memoryExtraction(transcript: transcript)
        ) else { return }
        guard !items.isEmpty else { return }

        // 记忆池绑定 (project, version)：同上下文用活实例；链中途切走按 origin 重建
        //（extract 含网络往返）——沉淀归属钉发起上下文，不随选中漂移。
        let store = originIsCurrentContext(origin)
            ? memory : MemoryStore(project: origin.project, version: origin.version)
        _ = store.record(items, sessionId: origin.sessionId) { [weak self] line in
            guard let self else { return }
            try self.sessionStore.appendPinned(line, origin: origin.storeOrigin)
        }
    }

    // MARK: - 方法论自动沉淀（①→② 确认时：阶段对话 → 可复用方法论卡）

    /// 自动沉淀每阶段数量上限（宁缺勿滥：污染卡库的代价高于漏抽，超限条目丢弃）。
    private static let autoSedimentLimit = 3

    /// 阶段收束自动沉淀（与 sedimentMemory 同点触发，各自独立失败域）。
    /// 与手动「记下来」的差异（自动保护策略）：
    /// ① 不让位——同主题改良不 supersede 既有卡（可能是人工资产），降级为注记合并留痕；
    /// ② 数量上限 + 汇总一行系统行（逐条播报噪音大）；
    /// ③ 全程失败静默（不阻塞确认推进；漏抽的卡可随时手动补记）。
    /// 系统行（🧠）归**上一回合尾部注记**（aftermath，见 ConversationView.turnNote）；
    /// 紧随的「✅ 要点表已按新功能诉求更新——进入」是 preamble，归下一回合顶部。
    private func sedimentKnowledge(transcript: String, origin: ReplyOrigin) async {
        // 1. LLM 抽取（复用「记下来」同款 prompt/schema）。maxTokens 8192：思考型
        //    模型 reasoning 与正文共用输出池，长 transcript 下默认 2048 会撞线静默失败。
        guard let extracted = await extract(
            [KnowledgeExtractor.ExtractedKnowledge].self,
            prompt: KnowledgeExtractor.extractionPrompt(transcript: transcript),
            maxTokens: 8192
        ), !extracted.isEmpty else { return }

        let embedder = SettingsBackedEmbedder(settings: settings)
        // 抽取含网络往返：卡候选与溯源标签按 origin 上下文取，不读活 pipeline
        let sourceRef = "\(origin.project)/\(origin.version)"
        let existing = Self.cardCandidates(database: database, project: origin.project)
        var created = 0
        var merged = 0

        for item in extracted.prefix(Self.autoSedimentLimit) {
            // 2. 归属判定（与手动路径同口径：>0.92 近重复合并 / 同主题让位 / 新建）
            let itemEmbedding = (try? await embedder.embed(texts: [item.content]))?.first
                ?? DeterministicHashEmbedder.vector(for: item.content)
            let decision = KnowledgeExtractor.mergeDecision(
                for: item,
                existing: existing.map {
                    (id: $0.id, title: $0.title, content: $0.content, embedding: $0.embedding)
                },
                itemEmbedding: itemEmbedding
            )
            switch decision {
            case .mergeInto(let existingId):
                // 近重复 → 旧卡注记 +1（同一概念不新建）
                if annotateCardSilently(
                    id: existingId,
                    note: "同一概念二次沉淀，已合并（出自 \(sourceRef)）：\(item.content)",
                    project: origin.project
                ) { merged += 1 }
            case .conflict(let existingId):
                // 同主题改良 → 自动沉淀不让位既有卡（人工资产让位不公平），
                // 改良内容降级为注记留痕（手动路径仍按 E10 让位）
                if annotateCardSilently(
                    id: existingId,
                    note: "同主题改良版留痕（自动沉淀·未取代原卡，出自 \(sourceRef)）：\(item.content)",
                    project: origin.project
                ) { merged += 1 }
            case .newCard:
                if await writeCardSilently(
                    item: item, sourceType: "methodology", sourceRef: sourceRef, embedder: embedder
                ) { created += 1 }
            }
        }

        // 3. 汇总一行（无产出不播报——「没新闻」零信息量）；pinned 落 origin 会话
        guard created + merged > 0 else { return }
        appendOriginSystem(
            "🧠 自动沉淀：方法论卡 +\(created) 条 · 合并 \(merged) 条进既有卡"
                + "——卡片库可查，跨项目直接用不降级。",
            origin: origin
        )
    }

    /// 静默落卡（自动沉淀用）：write-then-verify + 增量索引，不发系统行。
    private func writeCardSilently(
        item: KnowledgeExtractor.ExtractedKnowledge,
        sourceType: String,
        sourceRef: String,
        embedder: SettingsBackedEmbedder
    ) async -> Bool {
        do {
            _ = try await KnowledgeExtractor.writeCard(
                content: item.content, confidence: item.confidence,
                sourceType: sourceType, sourceRef: sourceRef,
                database: database, embeddingProvider: embedder
            )
            return true
        } catch {
            return false
        }
    }

    /// 静默注记（自动沉淀用）：旧卡实战注记 +1 + 重建单卡索引，不发系统行。
    private func annotateCardSilently(id: String, note: String, project: String) -> Bool {
        guard let located = Self.locateCard(id: id, project: project) else { return false }
        do {
            try AnnotationWriter.append(
                cardURL: located.url, note: note,
                project: project, date: ISO8601.dayString()
            )
            reindexCard(at: located.url, projectId: located.projectId)
            return true
        } catch {
            return false
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
                ? ArtifactParser.scrubImitatedPlaceholders(in: last.content)
                : ArtifactParser.scrubImitatedPlaceholders(
                    in: ArtifactParser.stripArtifactBlocks(in: last.content)
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !source.isEmpty else { return }
        bookmarkDraft = source
    }

    func cancelBookmarkCapture() {
        bookmarkDraft = nil
    }

    // MARK: - 产物右键「添加到对话」

    /// 产物台账右键「添加到对话」：把待引用文件路径（相对版本目录）排队给输入坞。
    /// ConversationView 消费 pendingFileReference 追加进待发文件 chips 并聚焦，
    /// 属纯 UI 中转不落盘；文件正文在 send 时由 ReferencedFileMaterial 读盘注入。
    func requestAddFileReference(relativePath: String) {
        pendingFileReference = relativePath
    }

    /// 手动方法论卡固定置信度（归属分流不暴露滑杆；与 LLM 抽取默认值一致）。
    private static let manualCardConfidence: Double = 0.8

    /// 归属分流保存：经验路线 → 记忆层「经验」（假设态，固定初始置信度 0.7）；
    /// 卡片路线 → 抽取 + 去重合并 + 落卡。置信度不做手动输入——由使用校准自动升降。
    func saveBookmark(_ capture: BookmarkCapture) async {
        bookmarkDraft = nil
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 入口快照 origin：卡片/经验链含 LLM 往返，期间可能切走——
        // 溯源标签、卡候选与系统行归属都以保存时的上下文为准。
        let origin = ReplyOrigin(
            project: pipeline.project, version: pipeline.version,
            sessionId: sessionStore.sessionId, stage: pipeline.stage
        )

        switch capture.destination {
        case .experience:
            let sourceRef = "\(origin.project)/\(origin.version)"
            let report = memory.recordExperience(
                content: text, sourceRef: sourceRef,
                confidence: MemoryStore.experienceHypothesisConfidence,
                sessionId: origin.sessionId
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
                content: text, confidence: Self.manualCardConfidence, sourceType: "manual",
                origin: origin
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
    /// origin：保存入口快照——抽取/向量化含网络往返，溯源与行归属钉保存时上下文。
    private func saveMethodologyCard(
        content: String, confidence: Double, sourceType: String, origin: ReplyOrigin
    ) async {
        let project = origin.project
        let embedder = SettingsBackedEmbedder(settings: settings)
        let sourceRef = "\(project)/\(origin.version)"

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
                    title: Recommender.title(of: content), content: content,
                    principle: nil, confidence: confidence
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
                mergeIntoExisting(id: existingId, item: item, origin: origin)
            case .conflict(let existingId):
                // 同主题实质改良：新卡落盘 + 旧卡 supersededBy 让位
                await writeCard(item: item, sourceType: sourceType, sourceRef: sourceRef,
                                supersededId: existingId, embedder: embedder, origin: origin)
            case .newCard:
                await writeCard(item: item, sourceType: sourceType, sourceRef: sourceRef,
                                supersededId: nil, embedder: embedder, origin: origin)
            }
        }
    }

    /// 合并分支（E10）：旧卡实战注记区追加「同一概念二次沉淀」，不新建。
    private func mergeIntoExisting(
        id: String, item: KnowledgeExtractor.ExtractedKnowledge, origin: ReplyOrigin
    ) {
        guard let located = Self.locateCard(id: id, project: origin.project) else { return }
        do {
            try AnnotationWriter.append(
                cardURL: located.url,
                note: "同一概念二次沉淀，已合并（出自 \(origin.project)/\(origin.version)）：\(item.content)",
                project: origin.project,
                date: ISO8601.dayString()
            )
            reindexCard(at: located.url, projectId: located.projectId)
            appendOriginSystem(
                "🗃️ 与既有方法论卡近重复（相似度 > 0.92）——已合并进 \(id)，实战注记 +1（同一概念不新建）。",
                origin: origin
            )
        } catch {
            appendOriginSystem(
                "⚠️ 合并注记追加失败：\(error.localizedDescription)", origin: origin
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
        embedder: SettingsBackedEmbedder,
        origin: ReplyOrigin
    ) async {
        do {
            let card = try await KnowledgeExtractor.writeCard(
            content: item.content, confidence: item.confidence,
            sourceType: sourceType, sourceRef: sourceRef,
            principle: item.principle,
            database: database, embeddingProvider: embedder
        )
            if let supersededId,
               let old = Self.locateCard(id: supersededId, project: origin.project) {
                try KnowledgeExtractor.markSuperseded(cardURL: old.url, by: card.id)
                reindexCard(at: old.url, projectId: old.projectId)
                appendOriginSystem(
                    "🔀 方法论卡片已更新：同主题旧卡被改良版取代，新卡已存入卡片库。",
                    origin: origin
                )
            } else {
                appendOriginSystem(
                    "🗃️ 方法论卡已沉淀：\(card.id)（全局卡片库，跨项目直接用不降级）——实战注记将随使用增厚。",
                    origin: origin
                )
            }
        } catch {
            appendOriginSystem(
                "⚠️ 方法论卡片保存失败：\(error.localizedDescription)", origin: origin
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
                // 案例结构（2026-09-17 钦定）：项目/版本/阶段 + 推荐时机线索，
                // 替代旧流水账「xx阶段采纳本方法论」——第一批为确定性草稿，
                // AI 代写案例（依阶段上下文代写「怎么用的」）为第二批。
                note: "\(pipeline.project) \(pipeline.version) · \(stageDisplayName)阶段采纳——\(rec.whyNow)（案例草稿 · 可在卡片库修订补上结果）",
                project: pipeline.project,
                date: ISO8601.dayString()
            )
            reindexCard(at: located.url, projectId: located.projectId)
            // 方法论采纳事件留痕（2026-09-17 反哺基建）：封板复盘据此做
            // 「本版方法论使用报告」（采纳/跳过分布 + 该质疑卡片），并作
            // 下版本开工档案袋的素材。detail 协议：id|标题（ReleaseRetro 解析）。
            PipelineEventLog.append(
                kind: .methodAdopt, stage: pipeline.stage.rawValue,
                detail: "\(rec.id)|\(rec.title)",
                project: pipeline.project, version: pipeline.version
            )

            // AI 代写案例草稿（2026-09-17 钦定）：确定性草稿已在上方落卡，
            // AI 再依阶段上下文代写一条更具体的「怎么用的」案例——成功则追加
            // 第二条（append-only 越用越厚），失败静默（确定性草稿兜底，不打扰）。
            let contextBrief = String(stageQueryText(stage: pipeline.stage).prefix(400))
            let adoptedCardTitle = rec.title
            let adoptProject = pipeline.project
            let adoptVersion = pipeline.version
            let adoptStageLabel = stageDisplayName
            let adoptStageRaw = pipeline.stage.rawValue
            let sendSettings = settings
            Task { [weak self] in
                let prompt = """
                你是产品方法论助手。用户刚在产品工作流中采纳了知识库卡片「\(adoptedCardTitle)」。请依据下方项目上下文，代写一条本次的实战案例：在哪个环节、具体怎么用、预期结果是什么。要求：一行以内不超过 90 字，只陈述上下文中能支撑的事实，不编造。
                项目上下文：\(contextBrief)
                直接输出案例正文，不要任何前缀或引号。
                """
                guard let draft = try? await self?.sessionStore.oneShot(
                    prompt, settings: sendSettings, stage: .classify, maxTokens: 200
                ), !draft.trimmingCharacters(in: .whitespaces).isEmpty,
                   let self,
                   let located = Self.locateCard(id: id, project: adoptProject) else { return }
                let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                try? AnnotationWriter.append(
                    cardURL: located.url,
                    note: "\(adoptProject) \(adoptVersion) · \(adoptStageLabel)阶段：AI 代写案例——\(cleaned)（可在卡片库修订）",
                    project: adoptProject,
                    date: ISO8601.dayString()
                )
                _ = adoptStageRaw  // 保留阶段口径备查
            }

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
    /// 落 methodSkip 事件留痕——封板复盘据此做方法论盘点（该质疑：连续被跳过的卡）。
    func rejectRecommendation(_ id: String) {
        let title = recommendations.first(where: { $0.id == id })?.title ?? id
        rejectedCards.insert(id)
        recommendations.removeAll { $0.id == id }
        PipelineEventLog.append(
            kind: .methodSkip, stage: pipeline.stage.rawValue,
            detail: "\(id)|\(title)",
            project: pipeline.project, version: pipeline.version
        )
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
        readArtifact(root: PMAgentStore.versionURL(project: project, version: version), rel: rel)
    }

    /// 指定产物根读取（B1 草稿预演：草稿产物镜像在提案目录，读基底时按根分流）。
    private static func readArtifact(root: URL, rel: String) -> String? {
        let url = root.appendingPathComponent(rel)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
