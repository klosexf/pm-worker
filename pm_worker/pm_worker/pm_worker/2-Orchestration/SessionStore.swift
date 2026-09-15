//
//  SessionStore.swift
//  pm_worker
//
//  会话运行时（Task 1.6）：discussions.jsonl append-only 落盘 + write-then-verify。
//  会话窗口是 discussions.jsonl 的视图投影（design.md §5.1.1）——
//  会话本体无独立文件，标题默认取首条用户消息摘要。
//

import Foundation
import Combine

/// 思考卡数据（design.md §6.4.1）：随消息存 session，不新增文件。
nonisolated struct ThinkData: Codable, Equatable {
    struct Step: Codable, Equatable {
        /// 普通步骤：一句推理要点（面向用户可读的摘要，非原始 CoT）。
        var text: String?
        /// 技能调用行：命中了哪个技能 / 注入了什么 / 耗时。
        var skill: String?
        var detail: String?
        var dur: String?
    }

    /// 思考耗时（秒）。
    var dur: Int
    var steps: [Step]

    /// 摘要行：「思考了 Ns · M 步 · <技能>」。技能 ≤2 个直接点名（明确显示所应用
    /// 技能名，折叠态即可见），≥3 收敛为「技能 ×K」防摘要行过长。
    var summary: String {
        let skillNames = steps.compactMap(\.skill)
        var parts = ["思考了 \(dur)s · \(steps.count) 步"]
        switch skillNames.count {
        case 1: parts.append(skillNames[0])
        case 2: parts.append(skillNames.joined(separator: "、"))
        case 3...: parts.append("技能 ×\(skillNames.count)")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// 从 reasoning 原文构造（按行拆步骤；截断超长行，保留可解释性不泄露全文）。
    /// skills：本轮实际注入的技能 id（Context Builder 命中：语义命中 + 阶段核心
    /// 确定性注入）——作为技能步骤置于推理步骤之前，摘要行随之点名。
    static func from(reasoning: String, duration: Int, skills: [String] = []) -> ThinkData? {
        let lines = reasoning
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 步骤上限 12 条，单条截 200 字——结论级信任，非全文
        let reasoningSteps = lines.prefix(12).map { line in
            Step(text: String(line.prefix(200)), skill: nil, detail: nil, dur: nil)
        }
        let skillSteps = skills.map { skill in
            Step(text: nil, skill: skill, detail: "已注入本轮提示词上下文", dur: nil)
        }
        let steps = skillSteps + reasoningSteps
        guard !steps.isEmpty else { return nil }
        return ThinkData(dur: duration, steps: steps)
    }
}

/// 单个产物文件的落盘变更摘要（相对版本目录的路径 + 行级增删统计）。
/// 挂在 role == .system 的 📦 行上随 discussions.jsonl 持久化，UI 渲染为落盘文件卡
/// （每文件一张生成文件卡，与原型结果卡同族）。
nonisolated struct FileChangeSummary: Codable, Equatable {
    /// 相对版本目录的路径，如 02-structure/功能架构图.md
    var path: String
    var added: Int
    var removed: Int
    /// 本次落盘前文件不存在（全新产物）
    var isNew: Bool
}

/// 回合里程碑载荷（方案 B 里程碑清单）：挂在 role == .system 的注记行上随
/// discussions.jsonl 持久化。UI 据此组装时间线（行文案由 UI 组装，content 只作审计）；
/// 旧存量行无此字段 → decodeIfPresent 兼容，回退普通注记行渲染。
nonisolated struct MilestoneStamp: Codable, Equatable {
    /// radar（漏项雷达入账）| decision（决策沉淀）| stage（阶段产物落盘）
    var kind: String
    /// 计数（雷达发现项数 / 决策新增条数）
    var count: Int?
    /// 次行补注（如「缺项 1 · 修正 2 · 风险 1」「待验证 1 条，日志中已标出」）
    var detail: String?
    /// stage 专用：产物短名（「原型」「结构产物」），用于「待确认」节点文案
    var label: String?
    /// stage 专用：确认后的下一步（「确认后 AI 随即撰写 ④ PRD」）
    var nextAction: String?
    /// score 专用：三维度评分（复杂度 / 风险 / 范围，各 0-10，顺序即展示顺序）
    var dims: [MilestoneDim]?
}

/// 评分卡单维度（方案 B：三格分数条 + hover 理由）。
nonisolated struct MilestoneDim: Codable, Equatable {
    /// 维度名（「复杂度」「风险」「范围」）
    var name: String
    /// 得分 0-10
    var score: Int
    /// 评分理由（hover 点亮展示）
    var reason: String
}

/// discussions.jsonl 单条记录。
nonisolated struct DiscussionEntry: Codable, Equatable, Identifiable {
    enum Role: String, Codable {
        case user, assistant, system
    }

    var id: String
    var sessionId: String
    var role: Role
    var content: String
    /// 思考卡数据（随消息存 session）。
    var think: ThinkData?
    /// 记忆条目载荷（role == .system 且有值时为记忆沉淀/覆盖行）。
    var memory: MemoryEntry?
    /// 用户消息附图（attachments/ 目录下的文件名引用，base64 不落 jsonl）。
    var images: [String]?
    /// 产物落盘变更摘要（role == .system 的 📦 行携带，渲染为落盘文件卡）。
    var fileChanges: [FileChangeSummary]?
    /// 回合里程碑载荷（role == .system 注记行携带，渲染为里程碑清单）。
    var milestones: [MilestoneStamp]?
    var createdAt: String

    init(
        id: String,
        sessionId: String,
        role: Role,
        content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil,
        images: [String]? = nil,
        fileChanges: [FileChangeSummary]? = nil,
        milestones: [MilestoneStamp]? = nil,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.think = think
        self.memory = memory
        self.images = images
        self.fileChanges = fileChanges
        self.milestones = milestones
        self.createdAt = createdAt
    }

    // Codable 兼容旧存量（无 images / fileChanges / milestones 字段的 discussions.jsonl）
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, think, memory, images, fileChanges, milestones, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        think = try c.decodeIfPresent(ThinkData.self, forKey: .think)
        memory = try c.decodeIfPresent(MemoryEntry.self, forKey: .memory)
        images = try c.decodeIfPresent([String].self, forKey: .images)
        fileChanges = try c.decodeIfPresent([FileChangeSummary].self, forKey: .fileChanges)
        milestones = try c.decodeIfPresent([MilestoneStamp].self, forKey: .milestones)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

/// 会话投影：从 discussions.jsonl 分组而来，不单独落盘。
nonisolated struct SessionSummary: Identifiable, Equatable {
    var id: String  // sessionId
    var title: String
    var lastActiveAt: String
    var messageCount: Int
}

/// 流式 UI 发布节流器：delta 全量累积（落盘/续写语义不变），@Published 快照
/// 按最小间隔合并发布。逐 delta 发布会让每个 SSE chunk 都触发对话页全量重渲染
/// （含顶栏读盘与全部历史消息重解析），是流式期间滚动卡顿的主因。
/// 快照只影响显示节奏（约 10 次/秒的批量到达），终值在流结束时补发。
nonisolated struct StreamPublishThrottle {
    private(set) var lastAt: Date? = nil
    let interval: TimeInterval

    init(interval: TimeInterval = 0.1) { self.interval = interval }

    /// 本 delta 后是否应发布快照（并记录发布时刻）。now 可注入供测试。
    mutating func shouldPublish(now: Date = Date()) -> Bool {
        if let lastAt, now.timeIntervalSince(lastAt) < interval { return false }
        self.lastAt = now
        return true
    }
}

/// 会话运行时：读侧投影 + 写侧 append-then-verify。
@MainActor
final class SessionStore: ObservableObject {
    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避：显式退出隔离销毁路径
    /// （单测中局部实例销毁会触发 malloc 崩溃，同 PipelineEngine/MemoryStore 坑）。
    nonisolated deinit {}

    /// 当前会话的消息（UI 渲染源）。
    @Published private(set) var entries: [DiscussionEntry] = []
    /// 流式回复中的增量文本（未落盘的尾部）。
    @Published var streamingText: String = ""
    /// 流式思考中的增量（思考卡 spinner 数据源，未落盘）。
    @Published var streamingThink: String = ""
    /// 本轮流式回复引用的技能 id（Context Builder 命中并注入）——
    /// 思考中态思考卡即时显示「引用技能」；流结束随 think 步骤落盘。
    @Published var streamingSkills: [String] = []
    @Published private(set) var isStreaming = false
    /// 流式回复的归属会话（nil = 无流进行）。UI 据此只在发起会话内渲染流式气泡——
    /// 生成途中切换会话时，其他会话不得显示同一份生成内容。
    @Published private(set) var streamingSessionID: String?

    /// 思考强度（reasoning_effort，DeepSeek 思考模式档位）：high = 服务端默认不发送。
    /// Composer 思考强度菜单的数据源；UserDefaults 持久化跨启动保留。
    @Published var thinkingEffort: ThinkingEffort = {
        if let raw = UserDefaults.standard.string(forKey: "pm.worker.thinkingEffort"),
           let effort = ThinkingEffort(rawValue: raw) { return effort }
        return .high
    }() {
        didSet {
            guard oldValue != thinkingEffort else { return }
            UserDefaults.standard.set(thinkingEffort.rawValue, forKey: "pm.worker.thinkingEffort")
        }
    }

    /// 流式回复发起时的上下文快照：回复落盘、内存收纳与完成回调都以发起会话为准，
    /// 不随用户中途切换会话/项目漂移（否则回答会写进最后停留的会话）。
    struct StreamOrigin {
        var project: String
        var version: String
        var sessionId: String
    }

    // MARK: - 停止生成（用户主动取消流式回复）

    /// 进行中的生成任务（send/sendSystemTurn 内部经 trackGeneration 包裹）；
    /// nil = 空闲。持有句柄是唯一可靠的取消通道——调用方 Task 散落在各视图/编排层，无法回收。
    private var generationTask: Task<Void, Never>?
    /// 当前句柄的身份令牌：停止后立即重发时旧任务的收尾不会误清新句柄。
    private var generationTaskID = UUID()

    /// 用户主动停止当前生成：**同步**翻转流式状态（发送钮 ≤300ms 内回「发送」、
    /// 流式气泡即时收起、侧栏呼吸点即时熄灭），再取消底层网络流。
    /// 已生成的部分内容由 streamReply 的取消收尾路径保留落盘（含「⏹ 已停止」注记）。
    func stopGeneration() {
        guard let task = generationTask else { return }
        generationTask = nil
        generationTaskID = UUID()  // 令牌失配：旧任务完成时不再清新句柄
        isStreaming = false
        streamingSessionID = nil
        task.cancel()
    }

    /// 生成任务追踪（可停止句柄的来源）：send/sendSystemTurn 的实际工作包在其中。
    /// internal 供测试（停止延迟 ≤300ms 断言直测）。
    func trackGeneration(_ operation: @escaping () async -> Void) async {
        let id = UUID()
        generationTaskID = id
        let task = Task { await operation() }
        generationTask = task
        await task.value
        // 句柄仍指向本任务时才清空（停止 → 立即重发的新任务不被旧收尾误清）
        if generationTaskID == id { generationTask = nil }
    }

    /// 取消类错误判定（停止路径 vs 真实错误）：Swift 任务取消（CancellationError）
    /// 与 URLSession 取消（URLError.cancelled）都算；Task.isCancelled 兜底覆盖
    /// 端点/中间层把取消包装成其他错误的场景——用户已请求停止，一切后续错误都按停止收尾。
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    /// 停止收尾的回合构造（纯函数，测试直测）：已生成部分 → assistant 条目
    /// （原文逐字保留、sessionId 钉回发起会话、思考数据照常装配）；部分内容为空时
    /// 省略 assistant 条目。恒返回「⏹ 已停止」系统注记（有无部分内容文案分两态）。
    nonisolated static func makeStoppedTurn(
        partial: String,
        reasoning: String,
        duration: Int,
        skills: [String],
        sessionId: String
    ) -> (assistant: DiscussionEntry?, note: DiscussionEntry) {
        let thinkData = ThinkData.from(reasoning: reasoning, duration: duration, skills: skills)
        let assistant: DiscussionEntry? = partial.isEmpty ? nil : DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionId,
            role: .assistant,
            content: partial,
            think: thinkData,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let note = DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionId,
            role: .system,
            content: partial.isEmpty ? "⏹ 已停止" : "⏹ 已停止——已生成的部分已保留",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        return (assistant, note)
    }

    /// 历史段 token 预算（Context Builder 五段分配值下传，design.md §6.4）：
    /// 历史段的实际裁剪只发生在 SessionStore——超预算成对丢最旧整轮。
    var historyTokenBudget: Int = ContextBuilder.defaultBudgets[.history] ?? 6000

    private(set) var project: String = ""
    private(set) var version: String = ""
    private(set) var sessionId: String = ""

    private var jsonlURL: URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // MARK: - 会话投影（左栏第三级数据源）

    /// 某 project/version 下全部会话（固定按创建顺序，2026-09-13 用户决策）。
    nonisolated static func sessions(in project: String, version: String) -> [SessionSummary] {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
        let all = PMAgentStore.readLines(DiscussionEntry.self, from: url)
        var bySession: [String: [DiscussionEntry]] = [:]
        for entry in all { bySession[entry.sessionId, default: []].append(entry) }

        // 固定按创建顺序（首条 entry 时间升序）——不随最近活跃跳位；
        // discussions.jsonl append-only，entries 即追加序，首条即最早。
        // createdAt 为 ISO8601 字符串，字典序 == 时间序（与 lastActiveAt 同约定）。
        let titles = sessionTitles(project: project, version: version)
        return bySession
            .map { sid, entries -> (SessionSummary, String) in
                let firstUser = entries.first { $0.role == .user }?.content ?? "（空会话）"
                let last = entries.map(\.createdAt).max() ?? ""
                return (SessionSummary(
                    id: sid,
                    // 重命名覆盖优先（session-meta.json），默认取首条用户消息前 24 字
                    title: titles[sid] ?? String(firstUser.prefix(24)),
                    lastActiveAt: last,
                    messageCount: entries.count
                ), entries.first?.createdAt ?? "")
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: - 会话管理（重命名 / 删除，侧栏行「更多」菜单）

    /// 会话标题覆盖表（sessionId → 自定义标题），按版本目录落 session-meta.json。
    /// 标题默认投影自首条用户消息（discussions.jsonl 不单独落盘），重命名走覆盖。
    nonisolated static func sessionTitles(project: String, version: String) -> [String: String] {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "session-meta.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// 重命名会话：写入标题覆盖（去首尾空白，截 48 字防长标题撑爆侧栏）。
    nonisolated static func renameSession(
        project: String, version: String, sessionId: String, title: String
    ) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var titles = sessionTitles(project: project, version: version)
        titles[sessionId] = String(trimmed.prefix(48))
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "session-meta.json")
        try JSONEncoder().encode(titles).write(to: url, options: .atomic)
    }

    /// 删除会话：从 discussions.jsonl 移除该会话全部行（原子重写 + 回读校验，
    /// 未命中行保留原始字节不重编码）+ 清理标题覆盖。
    nonisolated static func deleteSession(
        project: String, version: String, sessionId: String
    ) throws {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let decoder = JSONDecoder()
        var kept: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(DiscussionEntry.self, from: Data(line.utf8)),
               entry.sessionId == sessionId { continue }
            kept.append(String(line))
        }
        var text = kept.joined(separator: "\n")
        if !text.isEmpty { text += "\n" }
        try PMAgentStore.writeVerified(text, to: url)

        var titles = sessionTitles(project: project, version: version)
        if titles[sessionId] != nil {
            titles[sessionId] = nil
            let metaURL = PMAgentStore.jsonlURL(project: project, version: version, file: "session-meta.json")
            try JSONEncoder().encode(titles).write(to: metaURL, options: .atomic)
        }
    }

    /// 会话被删除后调用：运行时若仍停在该会话，清空内存投影——避免旧 entries
    /// 残留、也避免 open() 幂等键仍命中已删会话而跳过重读。
    func closeIfCurrent(project: String, version: String, sessionId: String) {
        guard self.project == project, self.version == version, self.sessionId == sessionId else {
            return
        }
        entries = []
        self.project = ""
        self.version = ""
        self.sessionId = ""
    }

    /// 任务 → 空间转化（任务行菜单「转为项目」）：把某会话的全部行从源
    /// discussions.jsonl 迁到目标（原始字节不重编码，未命中行保留原样），
    /// 并迁移标题覆盖与被引用的附图文件（copy 不 move——源任务区其他会话
    /// 可能共享同一 attachments/）。决策/风险/产物是版本级共享文件、无
    /// 会话归属字段，保留在源不动（弹窗文案已向用户说明）。
    /// 迁移顺序 = 目标先追加、源后移除：中途失败的任何点位源数据都在，
    /// 调用方按需清理半成品目标即可，不丢数据。
    nonisolated static func moveSession(
        sessionId: String,
        from sourceProject: String, sourceVersion: String,
        to targetProject: String, targetVersion: String
    ) throws {
        let sourceURL = PMAgentStore.jsonlURL(
            project: sourceProject, version: sourceVersion, file: "discussions.jsonl"
        )
        let raw = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        let decoder = JSONDecoder()
        var moved: [String] = []
        var kept: [String] = []
        var movedImages: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(DiscussionEntry.self, from: Data(line.utf8)),
               entry.sessionId == sessionId {
                moved.append(String(line))
                movedImages.append(contentsOf: entry.images ?? [])
            } else {
                kept.append(String(line))
            }
        }
        guard !moved.isEmpty else { return }  // 未落盘会话（导航未发送）无需迁移

        // 1) 目标追加（ensureWorkspace 补齐目标目录与 jsonl 三件套）
        try PMAgentStore.ensureWorkspace(project: targetProject, version: targetVersion)
        let targetURL = PMAgentStore.jsonlURL(
            project: targetProject, version: targetVersion, file: "discussions.jsonl"
        )
        var targetText = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        if !targetText.isEmpty && !targetText.hasSuffix("\n") { targetText += "\n" }
        targetText += moved.joined(separator: "\n") + "\n"
        try PMAgentStore.writeVerified(targetText, to: targetURL)

        // 2) 附图复制（目标已有同名文件时跳过，幂等；失败降级为缺图纯文本）
        if !movedImages.isEmpty {
            let fm = FileManager.default
            let sourceDir = PMAgentStore.attachmentsDir(project: sourceProject, version: sourceVersion)
            let targetDir = PMAgentStore.attachmentsDir(project: targetProject, version: targetVersion)
            for name in Set(movedImages) {
                let from = sourceDir.appendingPathComponent(name)
                let to = targetDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: to.path) {
                    try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    _ = try? fm.copyItem(at: from, to: to)
                }
            }
        }

        // 3) 源移除该会话行（原子重写 + 回读校验）
        var keptText = kept.joined(separator: "\n")
        if !keptText.isEmpty { keptText += "\n" }
        try PMAgentStore.writeVerified(keptText, to: sourceURL)

        // 4) 标题覆盖迁移（源清、目标写）
        var sourceTitles = sessionTitles(project: sourceProject, version: sourceVersion)
        if let title = sourceTitles[sessionId] {
            var targetTitles = sessionTitles(project: targetProject, version: targetVersion)
            targetTitles[sessionId] = title
            try JSONEncoder().encode(targetTitles).write(
                to: PMAgentStore.jsonlURL(
                    project: targetProject, version: targetVersion, file: "session-meta.json"
                ),
                options: .atomic
            )
            sourceTitles[sessionId] = nil
            try JSONEncoder().encode(sourceTitles).write(
                to: PMAgentStore.jsonlURL(
                    project: sourceProject, version: sourceVersion, file: "session-meta.json"
                ),
                options: .atomic
            )
        }
    }

    // MARK: - 打开会话

    /// 打开已有会话；sessionId 不存在于磁盘时视为新会话（导航不落盘，首条消息才落盘）。
    /// 调用时机：AppModel.selection 的 didSet（赋值动作上下文）——本方法会改 @Published，
    /// 严禁在 view update（如 View.init/body）中调用，否则触发
    /// "Publishing changes from within view updates" 运行时警告。
    /// 幂等：同会话重复 open 直接返回（append 已同步维护内存 entries，跳过回读不丢数据）。
    func open(project: String, version: String, sessionId: String) {
        if self.project == project, self.version == version, self.sessionId == sessionId {
            return
        }
        self.project = project
        self.version = version
        self.sessionId = sessionId
        // 幂等工作区保障：unversioned / 新版本目录缺 discussions.jsonl 时补齐
        try? PMAgentStore.ensureWorkspace(project: project, version: version)
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
        entries = PMAgentStore.readLines(DiscussionEntry.self, from: url)
            .filter { $0.sessionId == sessionId }
        // 流进行中不清增量：切回发起会话仍能看到生成过程（气泡渲染由
        // streamingSessionID 门控，其他会话不会误显示）；流结束时统一清空。
        if streamingSessionID == nil {
            streamingText = ""
            streamingThink = ""
            streamingSkills = []
        }
    }

    // MARK: - 写入（append + write-then-verify，E5）

    /// append 后回读末行校验，不一致抛错。
    /// 仅当条目属于当前打开会话时才并入内存 entries——流式回复在生成途中
    /// 被切会话后按 origin 落盘，不得串进当前会话的内存消息流。
    func append(_ entry: DiscussionEntry) throws {
        try appendVerified(entry, to: jsonlURL)
        if entry.sessionId == sessionId {
            entries.append(entry)
        }
    }

    /// 按发起会话上下文落盘（流式回复专用）：写到 origin 的 jsonl，
    /// 内存收纳仍以「属于当前打开会话」为准。
    func appendPinned(_ entry: DiscussionEntry, origin: StreamOrigin) throws {
        let url = PMAgentStore.jsonlURL(
            project: origin.project, version: origin.version, file: "discussions.jsonl"
        )
        try appendVerified(entry, to: url)
        if entry.sessionId == sessionId {
            entries.append(entry)
        }
    }

    /// appendLine + write-then-verify：回读末行必须与写入内容逐字节一致。
    private func appendVerified(_ entry: DiscussionEntry, to url: URL) throws {
        try PMAgentStore.appendLine(entry, to: url)

        // appendLine 每行以 \n 结尾——按 \n split 后末元素必是空串，
        // 校验取「最后一个非空行」（否则空文件尾行判空导致每次 append 必抛错）。
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(
                domain: "SessionStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "会话写入后回读失败：\(url.path)"]
            )
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let lastLine = lines.last(where: { !$0.isEmpty }),
              lastLine == String(decoding: try encoder.encode(entry), as: UTF8.self)
        else {
            throw NSError(
                domain: "SessionStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "会话写入校验失败（末行不一致）：\(url.path)"]
            )
        }
    }

    func makeEntry(
        role: DiscussionEntry.Role,
        content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil,
        images: [String]? = nil,
        fileChanges: [FileChangeSummary]? = nil,
        milestones: [MilestoneStamp]? = nil
    ) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionId,
            role: role,
            content: content,
            think: think,
            memory: memory,
            images: images,
            fileChanges: fileChanges,
            milestones: milestones,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - 流式发送（M2：阶段化 system prompt + 思考捕获）

    /// 发送用户消息并流式接收回复；完成后整条落盘（流式期间 UI 由 streamingText 驱动）。
    /// - Parameters:
    ///   - stage: LLM 阶段（取该阶段模型配置）
    ///   - systemPrompt: 由 AgentPrompts 构造的阶段化 system prompt（含记忆注入区）
    ///   - maxTokens: 单次回复上限（结构/原型产物生成需要大输出配额）
    ///   - imageFiles: 用户消息附图（attachments/ 文件名引用；仅当模型配置
    ///     supportsImages 时随请求编码为 image_url，落盘始终保留引用）
    ///   - skills: 本轮引用的技能 id（Context Builder 命中注入，AppModel 组装时取得）
    ///   - onAssistant: 回复完成后的回调（产物解析、轮次推进等由编排层处理）
    func send(
        _ text: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 4096,
        imageFiles: [String] = [],
        skills: [String] = [],
        onAssistant: ((DiscussionEntry) -> Void)? = nil
    ) async {
        // 打包进可取消句柄（stopGeneration 的取消来源）；仍 await 完成，调用方语义不变
        await self.trackGeneration {
            await self.performSend(
                text, settings: settings, stage: stage, systemPrompt: systemPrompt,
                maxTokens: maxTokens, imageFiles: imageFiles, skills: skills,
                onAssistant: onAssistant
            )
        }
    }

    private func performSend(
        _ text: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int,
        imageFiles: [String],
        skills: [String],
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async {
        // 发起时快照上下文：生成途中用户可能切换会话/项目，
        // 回复必须落回发起会话（否则串会话），回调也仅在仍在发起会话时执行。
        let origin = StreamOrigin(project: project, version: version, sessionId: sessionId)
        do {
            let userEntry = makeEntry(
                role: .user, content: text,
                images: imageFiles.isEmpty ? nil : imageFiles
            )
            try append(userEntry)

            var history = await buildHistory(systemPrompt: systemPrompt, settings: settings)
            // 当轮 user 消息带图：进模型前从 attachments/ 读回并编码为 base64
            if !imageFiles.isEmpty,
               let config = settings.stages[stage], config.supportsImages {
                let chatImages = imageFiles.compactMap { name -> ChatImage? in
                    guard let data = PMAgentStore.readAttachment(
                        name, project: project, version: version
                    ) else { return nil }
                    let ext = (name as NSString).pathExtension.lowercased()
                    let mime = Self.imageMIME(forExtension: ext)
                    return ChatImage(mime: mime, base64: data.base64EncodedString())
                }
                if !chatImages.isEmpty,
                   let lastUser = history.lastIndex(where: { $0.role == .user }) {
                    history[lastUser] = ChatMessage(
                        role: .user, content: text, images: chatImages
                    )
                }
            }
            try await streamReply(
                origin: origin, history: history, stage: stage, settings: settings,
                maxTokens: maxTokens, skills: skills, onAssistant: onAssistant
            )
        } catch {
            // 用户主动停止（流式开始前的取消，如历史摘要/落盘阶段）：
            // 不写 ⚠️ 错误行，只落「⏹ 已停止」注记（stopGeneration 已即时翻转 UI）
            if Self.isCancellation(error) {
                let stopped = Self.makeStoppedTurn(
                    partial: "", reasoning: "", duration: 0, skills: [],
                    sessionId: origin.sessionId
                )
                try? appendPinned(stopped.note, origin: origin)
                return
            }
            streamingText = ""
            streamingThink = ""
            streamingSkills = []
            var errorEntry = makeEntry(
                role: .system,
                content: "⚠️ \(error.localizedDescription)"
            )
            // 错误行同样钉回发起会话（错误可能发生在用户已切走之后）
            errorEntry.sessionId = origin.sessionId
            try? appendPinned(errorEntry, origin: origin)
        }
    }

    /// 常见图片扩展名 → MIME（OpenAI 兼容 image_url 需要）。
    nonisolated static func imageMIME(forExtension ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    /// 系统触发的生成回合（阶段推进后的自动生成）：回合注记系统行 + 合成 user 指令。
    /// 合成指令不落盘为用户消息（它不是用户说的），仅进模型上下文。
    /// 注记照常落盘（审计轨迹），UI 层把它并入随后的助手气泡顶部，不再渲染成独立胶囊。
    func sendSystemTurn(
        note: String?,
        userPrompt: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 16384,
        skills: [String] = [],
        onAssistant: ((DiscussionEntry) -> Void)? = nil
    ) async {
        // 打包进可取消句柄（stopGeneration 的取消来源）
        await self.trackGeneration {
            await self.performSendSystemTurn(
                note: note, userPrompt: userPrompt, settings: settings, stage: stage,
                systemPrompt: systemPrompt, maxTokens: maxTokens, skills: skills,
                onAssistant: onAssistant
            )
        }
    }

    private func performSendSystemTurn(
        note: String?,
        userPrompt: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int,
        skills: [String],
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async {
        isStreaming = true  // 先置位：注记行直接并入流式气泡，避免「独立胶囊 → 并入」闪烁
        let origin = StreamOrigin(project: project, version: version, sessionId: sessionId)
        do {
            if let note {
                let noteEntry = makeEntry(role: .system, content: note)
                try append(noteEntry)
            }

            var history = await buildHistory(systemPrompt: systemPrompt, settings: settings)
            history.append(ChatMessage(role: .user, content: userPrompt))
            try await streamReply(
                origin: origin, history: history, stage: stage, settings: settings,
                maxTokens: maxTokens, skills: skills, onAssistant: onAssistant
            )
        } catch {
            isStreaming = false
            // 用户主动停止（流式开始前的取消）：只落「⏹ 已停止」注记，不写 ⚠️ 错误行
            if Self.isCancellation(error) {
                let stopped = Self.makeStoppedTurn(
                    partial: "", reasoning: "", duration: 0, skills: [],
                    sessionId: origin.sessionId
                )
                try? appendPinned(stopped.note, origin: origin)
                return
            }
            streamingText = ""
            streamingThink = ""
            streamingSkills = []
            var errorEntry = makeEntry(
                role: .system,
                content: "⚠️ \(error.localizedDescription)"
            )
            errorEntry.sessionId = origin.sessionId
            try? appendPinned(errorEntry, origin: origin)
        }
    }

    /// 一次性指令（无对话副作用）：澄清要点表 / 记忆抽取等 JSON 输出用。
    func oneShot(
        _ prompt: String,
        settings: LLMSettings,
        stage: LLMStage,
        maxTokens: Int = 2048
    ) async throws -> String {
        try await LLMClient.complete(
            stage: stage, settings: settings,
            messages: [ChatMessage(role: .user, content: prompt)],
            maxTokens: maxTokens
        )
    }

    /// 历史压缩摘要缓存（s08 滚动压缩）：被丢旧轮摘要一次、缓存复用；
    /// 边界移动时只摘要新增被丢轮（旧摘要 + 新轮 → 更新摘要），不全量重算。
    private var compactSummary = ""
    private var compactBoundary = ""
    private var compactSummarizedCount = 0

    private func buildHistory(
        systemPrompt: String, settings: LLMSettings
    ) async -> [ChatMessage] {
        var history: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt)]
        history += entries.compactMap { entry -> ChatMessage? in
            // 系统行（胶囊/记忆行）不回灌模型
            guard entry.role != .system else { return nil }
            var content: String
            if entry.role == .assistant,
               ArtifactParser.parseArtifactBlocks(in: entry.content).isEmpty == false {
                // 产物块回灌时剥离（上下文里以说明代替大段源码，省 token）
                content = ArtifactParser.stripArtifactBlocks(in: entry.content)
            } else {
                content = entry.content
            }
            // 历史附图不重发（多模态 token 昂贵）：文本标注代替，当轮图在 send() 里替换
            if let images = entry.images, !images.isEmpty {
                content += "\n（本条附图 \(images.count) 张，回灌省略）"
            }
            return ChatMessage(role: roleOf(entry.role), content: content)
        }
        // 历史段预算裁剪（Context Builder 分配值）：超预算成对丢最旧整轮；
        // 被丢轮不再静默消失——摘要垫头（s08），信息有损但不归零
        let (kept, dropped) = Self.splitByBudget(history, budget: historyTokenBudget)
        guard !dropped.isEmpty else { return kept }

        // 摘要缓存命中：边界未变直接复用
        let boundary = Self.droppedBoundary(dropped)
        if boundary == compactBoundary, !compactSummary.isEmpty {
            return Self.historyWithSummary(kept: kept, summary: compactSummary)
        }

        // 滚动压缩：旧摘要 + 新增被丢轮 → 一次性 LLM 摘要（classify 档）
        let base = min(compactSummarizedCount, dropped.count)
        let newDropped = dropped.dropFirst(base)
        let transcript = newDropped
            .map { "\($0.role == .user ? "用户" : "助手")：\($0.content)" }
            .joined(separator: "\n")
        if let updated = try? await oneShot(
            Self.compactSummaryPrompt(
                previous: compactSummary, transcript: String(transcript.suffix(12000))
            ),
            settings: settings, stage: .classify, maxTokens: 600
        ), !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compactSummary = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            compactBoundary = boundary
            compactSummarizedCount = dropped.count
            return Self.historyWithSummary(kept: kept, summary: compactSummary)
        }
        // 摘要失败（模型不可用等）：降级为纯丢弃（旧行为），不阻塞主流程
        return kept
    }

    // MARK: - 历史段预算裁剪（Task 4.1，design.md §6.4；s08 摘要垫头）

    /// 超预算成对丢最旧整轮（user → assistant 为一轮，保新丢旧不拆对）。
    /// 契约：首条 system（阶段 prompt）常驻不占历史预算；预算 ≤ 0 → 只剩 system
    /// （历史段整体让位，Context Builder 会把 .history 记入 trimmed）。
    nonisolated static func trimmedHistory(
        _ messages: [ChatMessage], budget: Int
    ) -> [ChatMessage] {
        splitByBudget(messages, budget: budget).kept
    }

    /// 按预算切分（trimmedHistory 的伴生）：返回保留段与被丢段——被丢段供摘要压缩。
    nonisolated static func splitByBudget(
        _ messages: [ChatMessage], budget: Int
    ) -> (kept: [ChatMessage], dropped: [ChatMessage]) {
        // 首条 system（组装后的阶段 prompt）剥离出预算核算
        var rest = messages
        var systemPrefix: [ChatMessage] = []
        if rest.first?.role == .system {
            systemPrefix = [rest.removeFirst()]
        }
        guard budget > 0 else { return (systemPrefix, rest) }

        // 预算内全量保留
        if TokenBreakdown.estimate(rest.map(\.content).joined(separator: "\n")) <= budget {
            return (systemPrefix + rest, [])
        }

        // 切整轮：user 起至下一个 assistant 止（尾部孤条单独成轮一并处理）
        var rounds: [[ChatMessage]] = []
        var currentRound: [ChatMessage] = []
        for message in rest {
            currentRound.append(message)
            if message.role == .assistant {
                rounds.append(currentRound)
                currentRound = []
            }
        }
        if !currentRound.isEmpty { rounds.append(currentRound) }

        // 从最新往回收，装不下的整轮丢弃（成对丢最旧）
        var kept: [[ChatMessage]] = []
        var used = 0
        for round in rounds.reversed() {
            let cost = TokenBreakdown.estimate(round.map(\.content).joined(separator: "\n"))
            if used + cost > budget { break }
            kept.insert(round, at: 0)
            used += cost
        }
        let keptMessages = kept.flatMap { $0 }
        let dropped = Array(rest.prefix(rest.count - keptMessages.count))
        return (systemPrefix + keptMessages, dropped)
    }

    /// 被丢段边界签名（条数 + 首尾内容前缀）：append-only 语义下边界只会后移，
    /// 签名变化即「有新被丢轮需要纳入摘要」。
    nonisolated static func droppedBoundary(_ dropped: [ChatMessage]) -> String {
        guard let first = dropped.first, let last = dropped.last else { return "empty" }
        return "\(dropped.count)|\(first.content.prefix(64))|\(last.content.prefix(64))"
    }

    /// 摘要垫头：system 首条之后插一条 user 角色的前情摘要（明确标注为系统注入的压缩内容）。
    nonisolated static func historyWithSummary(
        kept: [ChatMessage], summary: String
    ) -> [ChatMessage] {
        guard let first = kept.first, first.role == .system else { return kept }
        let summaryMessage = ChatMessage(
            role: .user,
            content: "【前情摘要】以下是较早对话轮次的压缩摘要（原文已从上下文移除）：\n\(summary)"
        )
        return [first, summaryMessage] + kept.dropFirst()
    }

    /// 滚动压缩摘要 prompt：旧摘要要点吸收保留 + 新纳入轮次压缩成 5-8 行要点。
    nonisolated static func compactSummaryPrompt(
        previous: String, transcript: String
    ) -> String {
        let previousSection = previous.isEmpty ? "" : """

            ——已有摘要（此前轮次的压缩结论，吸收保留其要点，勿丢失）——
            \(previous)
            """
        return """
        你在为一条产品澄清对话做上下文压缩。把下面的旧对话轮次压缩成 5-8 行要点：\
        已确认的关键事实、用户否决项、尚未解决的开放问题。保留具体名称与数字，不要空泛。
        \(previousSection)

        ——新纳入压缩的对话轮次——
        \(transcript)

        ——直接输出摘要正文（无标题无围栏无前后缀说明）——
        """
    }

    private func streamReply(
        origin: StreamOrigin,
        history: [ChatMessage],
        stage: LLMStage,
        settings: LLMSettings,
        maxTokens: Int,
        skills: [String] = [],
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async throws {
        isStreaming = true
        streamingSessionID = origin.sessionId
        streamingText = ""
        streamingThink = ""
        streamingSkills = skills
        let startedAt = Date()
        defer {
            isStreaming = false
            streamingSessionID = nil
            streamingSkills = []
        }

        var full = ""
        var reasoning = ""
        var messages = history
        // 流式快照节流（100ms 合并发布）：full/reasoning 仍逐 delta 全量累积，
        // 落盘与续写语义不变；@Published 只按节拍更新，避免逐 token 全量重渲染。
        var textGate = StreamPublishThrottle()
        var thinkGate = StreamPublishThrottle()
        // 撞 max_tokens 截断时自动续写（产物 HTML 很长，一轮常写不完）。
        // 上限 2 次，防端点不认续写指令时无限循环。
        var continueRounds = 0
        // 用户停止（生成任务被取消）：立即中断接收，已生成部分收尾落盘保留
        var stopped = false
        do {
            while !Task.isCancelled {
                let stream = try LLMClient.streamChat(
                    stage: stage, settings: settings, messages: messages, maxTokens: maxTokens,
                    reasoningEffort: thinkingEffort.apiValue
                )
                var truncated = false
                let roundStart = full.count
                for try await delta in stream {
                    switch delta {
                    case .text(let text):
                        full += text
                        if textGate.shouldPublish() { streamingText = full }
                    case .reasoning(let chunk):
                        reasoning += chunk
                        if thinkGate.shouldPublish() { streamingThink = reasoning }
                    case .truncated:
                        truncated = true
                    }
                }
                guard truncated, continueRounds < 2 else { break }
                continueRounds += 1
                // 把本轮已生成的正文回灌为 assistant 前缀，要求模型从断点无缝续写。
                let roundText = String(full[full.index(full.startIndex, offsetBy: roundStart)...])
                guard !roundText.isEmpty else { break }
                messages.append(ChatMessage(role: .assistant, content: roundText))
                messages.append(ChatMessage(
                    role: .user,
                    content: "你上一条回复在输出中途被截断了。请从断点处直接继续输出剩余内容，"
                        + "不要重复已输出的部分，不要加任何前缀说明或道歉，接着上一个字符继续直到产物完整闭合。"
                ))
            }
        } catch {
            // 取消以外的一切错误照常上抛（send/performSendSystemTurn 的 ⚠️ 错误路径处理）
            guard Self.isCancellation(error) else { throw error }
            stopped = true
        }

        // 终值补发（含停止路径）：节流窗口内的尾部 delta 也进 UI（紧随其后转正式条目并清空）。
        streamingText = full
        streamingThink = reasoning

        let duration = Int(Date().timeIntervalSince(startedAt))
        // 停止收尾/正常收尾共用同一构造：部分（或完整）内容原文保留、sessionId 钉回发起会话
        let stoppedTurn = Self.makeStoppedTurn(
            partial: full, reasoning: reasoning, duration: duration,
            skills: skills, sessionId: origin.sessionId
        )
        if let assistantEntry = stoppedTurn.assistant {
            try appendPinned(assistantEntry, origin: origin)
        }
        streamingText = ""
        streamingThink = ""
        if stopped {
            // 「⏹ 已停止」注记：停止的唯一持久反馈（有无部分内容文案分两态）
            try? appendPinned(stoppedTurn.note, origin: origin)
        }
        // 完成回调（产物解析 / 阶段推进等编排副作用）仅在自然完成且用户仍停留在
        // 发起会话时执行——被停止的中途回合不得推进阶段或解析半截产物；
        // 回调读取当前 pipeline 上下文，已切走则只落盘，副作用随会话保留待后续。
        if !stopped, let assistantEntry = stoppedTurn.assistant, origin.sessionId == sessionId {
            onAssistant?(assistantEntry)
        }
    }

    private func roleOf(_ role: DiscussionEntry.Role) -> ChatMessage.Role {
        switch role {
        case .user: .user
        case .assistant, .system: .assistant
        }
    }
}
