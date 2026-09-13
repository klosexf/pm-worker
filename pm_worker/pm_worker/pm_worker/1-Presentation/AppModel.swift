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
        didSet { syncSessionRuntime() }
    }
    /// 用户已交互选中的项目（默认置顶规则：未选中时「默认」置顶）。
    @Published var activeProject: String?

    /// 设置弹框（Trae 风格模态）：侧栏左下角齿轮 / ⌘, / MCP 导航深链三入口共用。
    @Published var settingsPresented = false
    /// 弹框当前页（深链用：MCP Server 导航 → .mcp）。
    @Published var settingsPage: SettingsDialogPage = .model

    /// 右栏 Inspector 面板是否折叠（面板头部按钮切换；折叠后仅保留窄条展开钮）。
    @Published var inspectorCollapsed = false

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
        var nodes: [ProjectNode] = []
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
            nodes.append(ProjectNode(name: projectName, versions: versionNodes))
        }

        // 「默认」置顶规则：未选项目时置顶；选中真实项目后沉底
        let hasActive = activeProject != nil && activeProject != PMAgentStore.defaultProjectName
        nodes.sort { a, b in
            let aDefault = a.name == PMAgentStore.defaultProjectName
            let bDefault = b.name == PMAgentStore.defaultProjectName
            if hasActive {
                if aDefault != bDefault { return !aDefault }  // 默认沉底
                return a.name < b.name
            }
            if aDefault != bDefault { return aDefault }  // 默认置顶
            return a.name < b.name
        }
        projects = nodes
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
    func startTask(message: String, associatedProject: String?) async {
        let project = associatedProject ?? PMAgentStore.defaultProjectName
        let sessionId = UUID().uuidString
        // selection didSet 同步完成 sessionStore.open + switchContext
        selection = .session(project: project, version: "unversioned", sessionId: sessionId)
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

    /// 会话上下文切换（状态机 + 记忆层跟随）。
    /// 幂等：同上下文不重建（selection didSet 会随重复赋值多次触发）。
    func switchContext(project: String, version: String) {
        guard pipeline.project != project || pipeline.version != version else { return }
        pipeline = PipelineEngine(project: project, version: version, database: database)
        memory = MemoryStore(project: project, version: version)
        risks = RiskStore(project: project, version: version)
        // 上下文切换 → 已采纳方法论清零（校准注入随会话走，不跨上下文）
        adoptedMethodologies = []
        refreshReleasedState()
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
    private func assembleSystemPrompt(
        stage: LLMStage,
        promptBuilder: @escaping (String) -> String
    ) async -> String {
        let assembly = await makeContextBuilder().assemble(
            stage: stage,
            project: pipeline.project,
            stageQuery: stageQueryText(stage: pipeline.stage),
            memoryContext: memory.injectionContext,
            calibration: calibrationLines()
        ) { injection in
            promptBuilder(injection)
        }
        lastAssembly = assembly
        return assembly.systemPrompt
    }

    /// 记忆校准注入（E23）：已采纳方法论 → 该用户历史使用倾向（假设态经验条目）。
    private func calibrationLines() -> [String] {
        guard !adoptedMethodologies.isEmpty else { return [] }
        let experiences = MemoryStore.allExperiences()
        return adoptedMethodologies.compactMap {
            KnowledgeCalibration.calibrationContext(cardTitle: $0, memories: experiences)
        }
    }

    /// 阶段化发送入口（ConversationView 调用）。
    /// - Parameter imageFiles: 用户附图（attachments/ 文件名引用，可为空）。
    func sendMessage(_ text: String, imageFiles: [String] = []) async {
        let project = pipeline.project
        let version = pipeline.version
        // 封板版本目录只读（黄条已提示）——静默拦截写入，回看走快照/release-notes
        guard !currentVersionReleased else { return }
        try? PMAgentStore.ensureWorkspace(project: project, version: version)

        // 竞品分析分支（Task 3.8）：意图命中即分流——主线流水线不推进不阻塞。
        if AnalysisRunner.isAnalysisIntent(text) {
            await runCompetitiveAnalysis(topic: text)
            return
        }

        let stage = pipeline.stage
        let roundLimit = PipelineEngine.clarifyRoundLimit

        switch stage {
        case .clarify:
            let rounds = pipeline.clarifyRounds
            let clarifyPrompt = await assembleSystemPrompt(stage: .clarify) { injection in
                AgentPrompts.clarify(rounds: rounds, limit: roundLimit, injection: injection)
            }
            await sessionStore.send(
                text, settings: settings, stage: .clarify,
                systemPrompt: clarifyPrompt, imageFiles: imageFiles
            ) { [weak self] reply in
                guard let self else { return }
                self.processCrossCutting(reply)
                self.pipeline.bumpClarifyRound()
                // 5 轮耗尽 → 强制收束（缺失项入 open_questions，不阻塞流水线）
                if self.pipeline.clarifyExhausted {
                    Task { await self.confirmCurrentStage() }
                }
            }

        case .structure:
            let clarification = Self.readArtifact(
                project: project, version: version, rel: "01-requirements/clarification.md"
            ) ?? "（要点表缺失）"
            let structurePrompt = await assembleSystemPrompt(stage: .structure) { injection in
                AgentPrompts.structure(clarification: clarification, injection: injection)
            }
            await sessionStore.send(
                text, settings: settings, stage: .structure,
                systemPrompt: structurePrompt, maxTokens: 16384,
                imageFiles: imageFiles
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
            let prompt = await prototypePrompt()
            await sessionStore.send(
                text, settings: settings, stage: .prototype,
                systemPrompt: prompt, maxTokens: 16384,
                imageFiles: imageFiles
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
            // ④ 发现缺口 → 回退 ②③ 回路（下游产物分级标记过期 + 💀 事件结算）
            if let target = Self.prdBacktrackTarget(text) {
                backtrackFromPRD(to: target)
                return
            }
            if prdOnDisk {
                if let tier = Self.tierFromText(text), tier != currentPRDTier {
                    // 档位切换作为回合注记并入重新生成的 AI 回答
                    await generatePRD(
                        tierOverride: tier,
                        note: "🎚️ 已切换 \(tier) 档，重新生成 PRD"
                    )
                } else {
                    // 对话式迭代：反馈驱动修订，重新输出完整 artifact:prd 块
                    let prdIterationPrompt = await prdSystemPrompt(
                        tier: currentPRDTier ?? "standard"
                    )
                    await sessionStore.send(
                        text, settings: settings, stage: .prd,
                        systemPrompt: prdIterationPrompt
                            + "\n\n当前模式：迭代——用户消息是对现有 PRD 的修改反馈；"
                            + "按反馈修订后重新输出完整 artifact:prd 块（未改动章节原样保留）。",
                        maxTokens: 16384,
                        imageFiles: imageFiles
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
        guard !blocks.isEmpty else { return }
        let project = pipeline.project
        let version = pipeline.version

        do {
            switch pipeline.stage {
            case .structure:
                if ArtifactParser.structureArtifactsComplete(blocks) {
                    try ArtifactParser.writeStructureArtifacts(
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
                            content: "📦 功能架构图、核心流程图、模块-页面映射表已生成——确认后进入 ③ 原型"
                        )
                    )
                }
            case .prototype:
                if try ArtifactParser.writePrototypeArtifact(
                    blocks: blocks, project: project, version: version
                ) != nil {
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: pipeline.stage.rawValue,
                        detail: "交互原型落盘（单文件 HTML）",
                        project: project, version: version
                    )
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: "📦 交互原型已生成——右栏「产物」可预览，确认后进入 ④ PRD"
                        )
                    )
                }
            case .prd:
                if try ArtifactParser.writePRDArtifact(
                    blocks: blocks, tier: currentPRDTier ?? "standard",
                    project: project, version: version
                ) != nil {
                    pipeline.clearPRDStale()
                    PipelineEventLog.append(
                        kind: .artifactGenerated, stage: pipeline.stage.rawValue,
                        detail: "PRD 落盘（\(currentPRDTier ?? "standard") 档）",
                        project: project, version: version
                    )
                    try? sessionStore.append(
                        sessionStore.makeEntry(
                            role: .system,
                            content: "📦 产品需求文档已生成——右栏「产物」可预览；数据指标与验收用例见文内。"
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
        // PRD 落盘成功后的 Git 快照（非闸口，但属重要产物节点）
        if pipeline.stage == .prd && prdOnDisk { snapshotProject(message: "prd: PRD 生成") }
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
        }

        // 决策 WHY：三判据关键决策 append-only 落盘（E14）
        let drafts = ArtifactParser.parseDecisions(blocks: blocks)
        if !drafts.isEmpty {
            let records = drafts.map { $0.record(version: version) }
            do {
                try ArtifactParser.writeDecisions(records, project: project, version: version)
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "📝 已沉淀 \(records.count) 条决策记录——「决策日志」可查（待验证项高亮）。"
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

    /// 💀 风险登记：radar fatal → risks.jsonl（带触发信号；软上限超限提示收敛）。
    private func registerFatalRisks(
        _ fatals: [ArtifactParser.RadarReport.Fatal], stageKey: String
    ) {
        guard !fatals.isEmpty else { return }
        let version = pipeline.version
        let stage = RiskRecord.Stage(rawValue: stageKey) ?? .prd
        for fatal in fatals {
            guard let signal = fatal.signal else { continue }  // 未知信号丢弃防悬空
            let record = RiskRecord(
                version: version, stage: stage,
                hypothesis: fatal.hypothesis, triggerSignal: signal,
                originRef: "自评审（\(stageKey)）"
            )
            do {
                if let warn = try risks.append(record) {
                    try? sessionStore.append(
                        sessionStore.makeEntry(role: .system, content: "⚠️ \(warn)")
                    )
                }
            } catch {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system, content: "⚠️ 风险登记失败：\(error.localizedDescription)"
                    )
                )
            }
        }
    }

    /// ③ 阶段 system prompt（读已确认结构产物 + Context Builder 组装）。
    private func prototypePrompt() async -> String {
        let project = pipeline.project
        let version = pipeline.version
        let map = Self.readArtifact(
            project: project, version: version, rel: "02-structure/module-page-map.md"
        ) ?? "（缺失）"
        let flows = Self.readArtifact(
            project: project, version: version, rel: "02-structure/core-flows.md"
        ) ?? "（缺失）"
        return await assembleSystemPrompt(stage: .prototype) { injection in
            AgentPrompts.prototype(
                modulePageMap: map, coreFlows: flows, injection: injection
            )
        }
    }

    // MARK: - 确认闸口推进（ConfirmDock ① 触发）

    /// 确认坞三档状态（UI 渲染依据）。
    enum ConfirmTarget: Equatable {
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
    }

    /// 当前是否停在确认闸口（产物就绪 + 阶段未推进）。
    var confirmTarget: ConfirmTarget? {
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
        return ["architecture.md", "core-flows.md", "module-page-map.md"].allSatisfy {
            fm.fileExists(atPath: dir.appendingPathComponent("02-structure/\($0)").path)
        }
    }

    private var prototypeOnDisk: Bool {
        FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
                .appendingPathComponent("03-prototypes/prototype-v1.html").path
        )
    }

    /// 阶段推进确认（ConfirmDock 提交 / 自由作答「进入下一个阶段」）。
    func confirmCurrentStage() async {
        guard let target = confirmTarget else { return }
        switch target {
        case .clarify: await confirmClarify()
        case .structure: await confirmStructure()
        case .prototype: await confirmPrototype()
        }
        reloadTree()
    }

    /// ①→②：要点表生成 + 记忆沉淀 + 结构产物生成。
    private func confirmClarify() async {
        let project = pipeline.project
        let version = pipeline.version

        // 1. 澄清要点表（JSON Schema 约束抽取）
        let transcript = sessionStore.entries
            .filter { $0.role != .system }
            .map { "\($0.role == .user ? "用户" : "助手")：\($0.content)" }
            .joined(separator: "\n")
        guard let table: ClarificationTable = await extract(
            prompt: AgentPrompts.clarificationTable(transcript: transcript)
        ) else {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "⚠️ 澄清要点表生成失败（模型未返回合法 JSON）——稍后重试确认。"
                )
            )
            return
        }

        do {
            try PMAgentStore.writeVerified(
                table.markdown,
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent("01-requirements/clarification.md")
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

        // 3. 推进 + 生成回合（阶段推进信息作为回合注记并入 AI 回答顶部）
        pipeline.advanceFromClarify()
        snapshotProject(message: "clarify: 澄清要点表确认")
        let structurePrompt = await assembleSystemPrompt(stage: .structure) { injection in
            AgentPrompts.structure(clarification: table.markdown, injection: injection)
        }
        await sessionStore.sendSystemTurn(
            note: "✅ 澄清要点表已确认——进入 ② 结构设计",
            userPrompt: "请基于已确认的澄清要点表生成结构产物（功能架构图、核心流程图、模块-页面映射表三项必出）。",
            settings: settings, stage: .structure,
            systemPrompt: structurePrompt,
            maxTokens: 16384
        ) { [weak self] reply in
            self?.handleAssistantReply(reply)
        }
    }

    /// ②→③：确认闸口 + 原型生成。
    private func confirmStructure() async {
        do {
            try pipeline.confirmStructure()
            snapshotProject(message: "structure: 结构产物确认")
        } catch {
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system, content: "⚠️ 确认记录写入失败：\(error.localizedDescription)"
                )
            )
            return
        }
        let prototypeGenerationPrompt = await prototypePrompt()
        await sessionStore.sendSystemTurn(
            note: "✅ 结构产物已确认——进入 ③ 原型",
            userPrompt: "请基于模块-页面映射表生成单文件 HTML 原型（P0 页面 3-5 个，页面跳转按核心流程图连通）。",
            settings: settings, stage: .prototype,
            systemPrompt: prototypeGenerationPrompt,
            maxTokens: 16384
        ) { [weak self] reply in
            self?.handleAssistantReply(reply)
        }
    }

    /// ③→④：确认闸口 + 评分卡选档 + PRD 生成（Task 3.4）。
    private func confirmPrototype() async {
        do {
            try pipeline.confirmPrototype()
            snapshotProject(message: "prototype: 原型确认")
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
            note: "✅ 原型已确认——进入 ④ PRD 撰写"
        )
    }

    // MARK: - ④ PRD Agent（Task 3.4：评分卡选档 + 三档模板路由 + 双重基准）

    /// PRD 是否已落盘。
    private var prdOnDisk: Bool {
        FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: pipeline.project, version: pipeline.version)
                .appendingPathComponent("04-prd/prd-v1.md").path
        )
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
    private func generatePRD(tierOverride: String?, note: String? = nil) async {
        let tier: String
        if let tierOverride {
            tier = tierOverride
        } else if let card = await resolveScoreCard(), let valid = card.validTier {
            tier = valid
            try? sessionStore.append(
                sessionStore.makeEntry(
                    role: .system,
                    content: "📊 PRD 评分卡：复杂度 \(card.complexity.score)/10（\(card.complexity.reason)）"
                        + " · 风险 \(card.risk.score)/10（\(card.risk.reason)）"
                        + " · 范围 \(card.scope.score)/10（\(card.scope.reason)）"
                        + " → \(valid) 档模板。回复「用 lean / standard / full 档」可一键切换。"
                )
            )
        } else {
            tier = "standard"  // 评分卡失败兜底（不阻塞流水线）
        }
        let prdGenerationPrompt = await prdSystemPrompt(tier: tier)
        await sessionStore.sendSystemTurn(
            note: note ?? "📝 开始撰写 \(tier) 档 PRD",
            userPrompt: "请按 \(tier) 档模板撰写 PRD（双重基准：功能需求与模块-页面映射表及原型页面一一对应）。",
            settings: settings, stage: .prd,
            systemPrompt: prdGenerationPrompt,
            maxTokens: 16384
        ) { [weak self] reply in
            self?.handleAssistantReply(reply)
        }
    }

    /// 三维度评分选档（oneShot；锚定上游已确认产物的确定性数字）+ 落盘 score-card.json。
    private func resolveScoreCard() async -> ArtifactParser.ScoreCard? {
        let project = pipeline.project
        let version = pipeline.version
        guard let clarification = Self.readArtifact(
            project: project, version: version, rel: "01-requirements/clarification.md"
        ) else { return nil }
        let map = Self.readArtifact(
            project: project, version: version, rel: "02-structure/module-page-map.md"
        ) ?? ""
        let rows = Self.mapRows(in: map)
        guard let card: ArtifactParser.ScoreCard = await extract(
            prompt: AgentPrompts.prdScoreCard(
                clarification: clarification,
                moduleCount: rows.modules,
                pageCount: rows.pages.count,
                constraintCount: Self.countConstraints(in: clarification)
            )
        ) else { return nil }
        // 落盘（write-then-verify；失败不阻塞，仅失去一键切换记忆）
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(card) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent("04-prd/score-card.json")
            )
        }
        return card
    }

    /// ④ system prompt（读已确认上游产物 + 竞品调研注记 + Context Builder 组装）。
    private func prdSystemPrompt(tier: String) async -> String {
        let project = pipeline.project
        let version = pipeline.version
        let clarification = Self.readArtifact(
            project: project, version: version, rel: "01-requirements/clarification.md"
        ) ?? "（缺失）"
        let map = Self.readArtifact(
            project: project, version: version, rel: "02-structure/module-page-map.md"
        ) ?? "（缺失）"
        let analysis = Self.readArtifact(
            project: project, version: version, rel: "05-analysis/competitive-analysis.md"
        ) ?? ""
        return await assembleSystemPrompt(stage: .prd) { injection in
            AgentPrompts.prd(
                tier: tier,
                clarification: clarification,
                modulePageMap: map,
                prototypePages: Self.mapRows(in: map).pages,
                analysisNotes: analysis,
                injection: injection
            )
        }
    }

    // MARK: - ④ 回退回路（Task 3.5：E8 / 过期传播 + 💀 事件结算）

    /// ④ 发现缺口回退：结构缺口 → ②（全部下游失效）；原型缺口 → ③（局部）。
    private func backtrackFromPRD(to target: PipelineRun.Stage) {
        switch target {
        case .structure:
            pipeline.invalidateStructure()
            settleRisks(.structureRegen, note: "用户在④发现结构缺口，回退重做结构")
        default:
            pipeline.invalidatePrototype()
            settleRisks(.prototypeRegen, note: "用户在④发现原型缺口，回退重做原型")
        }
        let targetName = target == .structure
            ? "② 结构（原型与 PRD 一并标记过期：全部下游失效）"
            : "③ 原型（PRD 标记过期：局部）"
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "🔄 已回退到 \(targetName)。请修改产物后重新走确认闸口。"
            )
        )
        reloadTree()
    }

    /// 💀 状态机事件结算（事件驱动，非模型轮询；命中回写决策日志 risk_hit）。
    private func settleRisks(_ trigger: RiskRecord.TriggerSignal, note: String) {
        guard let settled = try? risks.settle(trigger: trigger, note: note), !settled.isEmpty
        else { return }
        try? sessionStore.append(
            sessionStore.makeEntry(
                role: .system,
                content: "💀 风险命中 \(settled.count) 条（触发信号 \(trigger.rawValue)）——预测 vs 实际对照见右栏「漏项雷达」。"
            )
        )
    }

    /// ④ 用户消息中的回退意图 → 目标阶段（无意图 nil）。
    static func prdBacktrackTarget(_ text: String) -> PipelineRun.Stage? {
        let wantsStructure = text.range(
            of: "回退.{0,6}结构|重新(设计|输出|生成|做)结构|改(一?下)?结构|修改结构",
            options: .regularExpression
        ) != nil
        let wantsPrototype = text.range(
            of: "回退.{0,6}原型|重新(设计|生成|做)原型|改(一?下)?原型|修改原型",
            options: .regularExpression
        ) != nil
        if wantsStructure { return .structure }
        if wantsPrototype { return .prototype }
        return nil
    }

    /// 用户消息中的档位切换意图（「用 lean 档」/「切换到 full」/「精简档」…）。
    static func tierFromText(_ text: String) -> String? {
        let lowered = text.lowercased()
        if lowered.contains("lean") || text.contains("精简档") { return "lean" }
        if lowered.contains("full") || text.contains("完整档") { return "full" }
        if lowered.contains("standard") || text.contains("标准档") { return "standard" }
        return nil
    }

    /// clarification.md「## 约束」小节的 `- ` 条目数（评分卡锚定数字）。
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

    /// module-page-map.md 表格解析：数据行数（模块数）+ 去重页面名（第 2 列）。
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
            sessionStore.makeEntry(role: .system, content: "🔍 竞品分析分支启动（主线流水线不推进）……")
        )
        let runner = AnalysisRunner()
        do {
            let url = try await runner.run(
                topic: topic, project: pipeline.project,
                version: pipeline.version, settings: settings
            )
            if url != nil {
                try? sessionStore.append(
                    sessionStore.makeEntry(
                        role: .system,
                        content: "📦 竞品分析报告已生成——右栏「产物」可预览，撰写 PRD 时会参考（须标出处）。"
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
            ("01-requirements/clarification.md", "澄清要点表"),
            ("02-structure/architecture.md", "功能架构图"),
            ("02-structure/core-flows.md", "核心流程图"),
            ("02-structure/module-page-map.md", "模块-页面映射表"),
            ("03-prototypes/prototype-v1.html", "可点击原型"),
            ("04-prd/prd-v1.md", "PRD 文档"),
            ("05-analysis/competitive-analysis.md", "竞品分析包"),
            ("07-reports/release-notes.md", "发布说明"),
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

    private func sedimentMemory(transcript: String) async {
        guard let items: [MemoryStore.ExtractionItem] = await extract(
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

    /// 归属分流保存：经验路线 → 记忆层「经验」（假设态）；卡片路线 → 抽取 + 去重合并 + 落卡。
    func saveBookmark(_ capture: BookmarkCapture) async {
        bookmarkDraft = nil
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch capture.destination {
        case .experience:
            let sourceRef = "\(pipeline.project)/\(pipeline.version)"
            let report = memory.recordExperience(
                content: text, sourceRef: sourceRef, confidence: capture.confidence,
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
                content: text, confidence: capture.confidence, sourceType: "manual"
            )
        }
        reloadTree()
    }

    /// 方法论卡保存（卡片路线）：LLM 抽取（失败回退原文）→ 去重合并判定
    /// （>0.92 合并 / 同主题冲突旧卡让位 / 新建）→ 落卡 + 增量索引。
    private func saveMethodologyCard(content: String, confidence: Double, sourceType: String) async {
        let project = pipeline.project
        let embedder = SettingsBackedEmbedder(settings: settings)
        let sourceRef = "\(project)/\(pipeline.version)"

        // 1. LLM 抽取（schema 约束；无 Key / 失败 → 回退原文单条）
        var items: [KnowledgeExtractor.ExtractedKnowledge] = []
        if let extracted: [KnowledgeExtractor.ExtractedKnowledge] = await extract(
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
            // 用户滑杆置信度优先（归属分流弹窗里的判定覆盖抽取值）
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
            let calibration = KnowledgeCalibration.calibrationContext(
                cardTitle: rec.title, memories: MemoryStore.allExperiences()
            )
            var line = "📌 已采纳方法论「\(rec.title)」——实战注记已追加（\(pipeline.project) · \(ISO8601.dayString())）。"
            if !calibration.isEmpty { line += "\n" + calibration }
            try? sessionStore.append(sessionStore.makeEntry(role: .system, content: line))
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

    /// 阶段推荐查询文本（确定性路由：阶段关键产物 → 最近用户消息 → 项目名兜底）。
    private func stageQueryText(stage: PipelineRun.Stage) -> String {
        let rel: String?
        switch stage {
        case .clarify: rel = nil
        case .structure: rel = "01-requirements/clarification.md"
        case .prototype, .prd: rel = "02-structure/module-page-map.md"
        }
        if let rel,
           let text = Self.readArtifact(
               project: pipeline.project, version: pipeline.version, rel: rel
           ),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
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

    /// oneShot JSON 抽取的泛型便捷封装。
    private func extract<T: Decodable>(prompt: String) async -> T? {
        guard let raw = try? await sessionStore.oneShot(
            prompt, settings: settings, stage: .classify
        ) else { return nil }
        return LenientJSON.decode(T.self, from: raw)
    }

    private static func readArtifact(project: String, version: String, rel: String) -> String? {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(rel)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
