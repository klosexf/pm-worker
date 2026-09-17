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

/// 上下文压缩载荷（借鉴 pi compaction entry，P2 结构化压缩）：
/// 挂在 role == .system 的压缩注记行上随 discussions.jsonl 持久化——
/// 冷启动恢复滚动摘要缓存（s08），摘要本体在 content（Finder 可读），
/// 载荷存恢复所需的元数据。旧存量行无此字段 → decodeIfPresent 兼容。
nonisolated struct CompactionData: Codable, Equatable {
    /// 摘要全文（程序恢复用；content 是注记头 + 摘要的 UI/Finder 可读形态）。
    var summary: String
    /// 本条摘要覆盖的被丢轮边界签名（恢复 compactBoundary 用）。
    var boundary: String
    /// 被丢条目数（恢复 compactSummarizedCount 用）。
    var droppedCount: Int
    /// 压缩前上下文 token 估算（审计）。
    var tokensBefore: Int
    /// 生成摘要用的 LLM stage（审计）。
    var viaStage: String
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
    /// 用户消息引用的产物文件（相对版本目录的路径，如 02-structure/模块-页面映射表.md）。
    /// 发送时由 ReferencedFileMaterial 读盘注入本轮 system prompt（AI 据此真正读到内容）。
    var files: [String]?
    /// 产物落盘变更摘要（role == .system 的落盘行携带，渲染为落盘文件卡）。
    var fileChanges: [FileChangeSummary]?
    /// 回合里程碑载荷（role == .system 注记行携带，渲染为里程碑清单）。
    var milestones: [MilestoneStamp]?
    /// 上下文压缩载荷（role == .system 压缩注记行携带，P2 结构化压缩）。
    var compaction: CompactionData?
    /// 变更提案载荷（role == .system 提案行携带，渲染为变更提案卡；处置状态查 changes.jsonl）。
    var changeProposal: ChangeProposalRecord?
    var createdAt: String

    init(
        id: String,
        sessionId: String,
        role: Role,
        content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil,
        images: [String]? = nil,
        files: [String]? = nil,
        fileChanges: [FileChangeSummary]? = nil,
        milestones: [MilestoneStamp]? = nil,
        compaction: CompactionData? = nil,
        changeProposal: ChangeProposalRecord? = nil,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.think = think
        self.memory = memory
        self.images = images
        self.files = files
        self.fileChanges = fileChanges
        self.milestones = milestones
        self.compaction = compaction
        self.changeProposal = changeProposal
        self.createdAt = createdAt
    }

    // Codable 兼容旧存量（无 images / files / fileChanges / milestones / compaction / changeProposal 字段的 discussions.jsonl）
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, think, memory, images, files, fileChanges, milestones, compaction, changeProposal, createdAt
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
        files = try c.decodeIfPresent([String].self, forKey: .files)
        fileChanges = try c.decodeIfPresent([FileChangeSummary].self, forKey: .fileChanges)
        milestones = try c.decodeIfPresent([MilestoneStamp].self, forKey: .milestones)
        compaction = try c.decodeIfPresent(CompactionData.self, forKey: .compaction)
        changeProposal = try c.decodeIfPresent(ChangeProposalRecord.self, forKey: .changeProposal)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

// MARK: - 引用文件读盘注入（产物台账「添加到对话」）

/// 用户引用的产物文件 → 本轮 system prompt 注入段（nonisolated：读盘不受 MainActor 隔离）。
/// 与附图同层处理（附图也是发送时才从 attachments/ 读回）：消息落盘只存相对路径，
/// 请求前才读盘——文件改了立刻拿到最新内容，历史行不携带文件正文。
nonisolated enum ReferencedFileMaterial {
    /// 单文件注入上限（超出截断并标注）。
    static let perFileCharLimit = 12_000
    /// 全部引用文件合计上限（防多文件叠加撑爆窗口）。
    static let totalCharLimit = 32_000
    /// 单轮最多注入正文的文件数（超出只标注路径，不注入正文）。
    static let maxFiles = 8

    /// system prompt 尾部追加引用文件段（无引用 → 原样返回，零开销）。
    static func augment(
        systemPrompt: String, refs: [String], project: String, version: String
    ) -> String {
        guard let section = section(refs: refs, project: project, version: version) else {
            return systemPrompt
        }
        return systemPrompt + "\n\n" + section
    }

    /// 注入段全文（refs 全空 → nil）。路径去重保序；读取失败逐条标注，
    /// 让模型能如实告知用户「这个文件读不到」，而不是含糊搪塞。
    static func section(refs: [String], project: String, version: String) -> String? {
        let paths = deduped(refs)
        guard !paths.isEmpty else { return nil }

        var blocks: [String] = []
        var budget = totalCharLimit
        for (index, path) in paths.enumerated() {
            let title = "### 引用 \(index + 1)：\(path)"
            guard index < maxFiles else {
                blocks.append(title + "\n（本轮引用文件过多，超出部分未注入正文；需要时请用户逐个引用。）")
                continue
            }
            guard let url = resolve(path, project: project, version: version),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                blocks.append(title + "\n（读取失败：文件不存在、不是 UTF-8 文本，或不在当前版本目录内。）")
                continue
            }
            var body = text
            var notes: [String] = []
            if body.count > perFileCharLimit {
                body = String(body.prefix(perFileCharLimit))
                notes.append("单文件超 \(perFileCharLimit) 字，已截断")
            }
            if body.count > budget {
                body = String(body.prefix(max(budget, 0)))
                notes.append("本轮注入总量已达上限，已截断")
            }
            budget -= body.count

            let meta = "\(lineCount(text)) 行 · \(text.count) 字"
                + (notes.isEmpty ? "" : " · " + notes.joined(separator: "；"))
            let mark = fence(for: body)
            blocks.append(
                title + "（\(meta)）\n\(mark)\(languageHint(for: path))\n\(body)\n\(mark)"
            )
        }

        return """
        ## 用户本轮引用的文件（原文已由客户端从磁盘读取，附在下方）
        - 下方每段就是文件原文，视同你已打开并读过：**不要**回答「我无法访问文件系统 / 打不开文件 / 它只是一个路径字符串」。
        - 用户问引用文件里有什么、或要求据此修改时，直接依据对应段落作答。
        - 引用路径相对于当前版本目录（\(version)）。

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// 引用路径 → 磁盘 URL。拒绝绝对路径与 `..` 上跳，且解析结果必须落在版本目录内
    /// （引用来自右栏台账，路径可信；此处仍按边界校验，防手改 jsonl 越权读盘）。
    static func resolve(_ relativePath: String, project: String, version: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            return nil
        }
        guard !trimmed.split(separator: "/").contains("..") else { return nil }
        let root = PMAgentStore.versionURL(project: project, version: version)
            .standardizedFileURL
        let target = root.appendingPathComponent(trimmed).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    /// 去重保序（同一文件重复引用只注入一次）。
    static func deduped(_ refs: [String]) -> [String] {
        var seen = Set<String>()
        return refs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 正文行数（末尾无换行不虚增一行）。
    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// 围栏反引号数 = 正文最长反引号串 + 1（CommonMark 嵌套纪律）：
    /// 引用文件常是含 ``` 代码块的 md / html，固定三反引号会被正文围栏提前闭合
    /// （PRD 预览踩过同款坑）。
    private static func fence(for content: String) -> String {
        var longest = 0
        var current = 0
        for ch in content {
            if ch == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// 代码围栏语言标注（按扩展名，利于模型识别文件类型）。
    private static func languageHint(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md": "markdown"
        case "html", "htm": "html"
        case "mmd": "mermaid"
        case "json", "jsonl": "json"
        default: "text"
        }
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
    /// 瞬时故障自动重试中的状态文案（429/5xx，LLMClient 退避等待期）；nil = 非重试态。
    /// 流式气泡据此显示「模型服务繁忙，自动重试中…」，让等待显得有意为之。
    @Published var streamingRetry: String?
    /// 本轮流式回复引用的技能 id（Context Builder 命中并注入）——
    /// 思考中态思考卡即时显示「引用技能」；流结束随 think 步骤落盘。
    @Published var streamingSkills: [String] = []
    /// 确认链/生成链进行中的阶段文案（如「正在抽取澄清要点表…」）；nil = 通用「正在思考…」。
    /// 闸口确认背后是多跳串行 LLM 往返（要点表抽取/记忆与方法论沉淀/下游生成），
    /// 占位卡据此显示当前在等哪一步——慢等待显性化，不像假死。
    @Published var streamingPhase: String?
    @Published private(set) var isStreaming = false
    /// 流式回复的归属会话（nil = 无流进行）。UI 据此只在发起会话内渲染流式气泡——
    /// 生成途中切换会话时，其他会话不得显示同一份生成内容。
    @Published private(set) var streamingSessionID: String?

    /// 本轮流式回复的起始时刻（nil = 无流）：交接条（值班单）实时计时数据源。
    /// 与 isStreaming / streamingSessionID 同生命周期翻转。
    @Published private(set) var streamingStartedAt: Date?

    /// 用户消息已上屏、回复流尚未开启（提示词组装 / 历史压缩等前置网络往返期间）
    /// 的「待回复」态：UI 与流式气泡同位渲染思考占位卡——发送瞬间即见「正在思考」，
    /// 不必等首个网络往返才出现。开流（streamReply）即转正为流式态。
    @Published private(set) var isPreparingReply = false
    /// 待回复态归属会话（与 streamingSessionID 同语义：只在该会话渲染占位气泡，
    /// 生成途中切会话不得显示同一份占位）。
    @Published private(set) var preparingSessionID: String?

    /// 发送链路乐观置位（幂等）：流式或待回复进行中不动，防覆盖归属会话。
    func beginPreparingReply(sessionID: String) {
        guard !isStreaming, !isPreparingReply else { return }
        isPreparingReply = true
        preparingSessionID = sessionID
    }

    /// 清除待回复态（开流转正 / 停止 / 错误 / 闸口早退路径统一收口）。
    func endPreparingReply() {
        isPreparingReply = false
        preparingSessionID = nil
    }

    // MARK: - Steering / Follow-up 双队列（P3，借鉴 pi-agent-core）

    /// 插话队列：流式期间收到，在截断续写边界注入当前回复上下文；
    /// 流正常结束前未注入 → 全部转入 followUpQueue 自动续发。
    /// 排队期不落盘（仅 UI 显示排队气泡），注入生效时随 appendPinned 落盘。
    @Published private(set) var steeringQueue: [DiscussionEntry] = []
    /// 结束后队列：本轮流式收尾后逐条作为新输入自动续发（走完整 send 链路）。
    @Published private(set) var followUpQueue: [DiscussionEntry] = []

    /// 流式期间（含待回复期）插话（AppModel.sendMessage 分流入口；调用方保证在发起会话内）：
    /// 入队即返回，不打断当前生成；待回复期入队的插话在流开启的首个边界统一注入。
    /// 空闲时调用是 no-op。
    func enqueueSteering(_ text: String) {
        guard isStreaming || isPreparingReply else { return }
        steeringQueue.append(makeEntry(role: .user, content: text))
    }

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
    /// 插话语义是「补指令给当前生成」——停止即一并作废（排队气泡消失，不落盘）。
    func stopGeneration() {
        endPreparingReply()  // 待回复占位一并收起（此时生成任务可能尚未起跑）
        guard let task = generationTask else { return }
        generationTask = nil
        generationTaskID = UUID()  // 令牌失配：旧任务完成时不再清新句柄
        isStreaming = false
        streamingSessionID = nil
        streamingStartedAt = nil
        steeringQueue = []
        followUpQueue = []
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
        // 冷启动恢复压缩缓存（P2）：取本会话最近一条压缩行，恢复滚动摘要三元组，
        // s08 压缩从上次边界无缝续跑（不重算已摘要轮）。无压缩行 → 缓存保持空。
        if let last = entries.last(where: { $0.compaction != nil }),
           let data = last.compaction {
            compactSummary = data.summary
            compactBoundary = data.boundary
            compactSummarizedCount = data.droppedCount
        } else {
            compactSummary = ""
            compactBoundary = ""
            compactSummarizedCount = 0
        }
        // 流进行中不清增量：切回发起会话仍能看到生成过程（气泡渲染由
        // streamingSessionID 门控，其他会话不会误显示）；流结束时统一清空。
        if streamingSessionID == nil {
            streamingText = ""
            streamingThink = ""
            streamingSkills = []
            streamingPhase = nil
        }
    }

    // MARK: - 写入（append + write-then-verify，E5）

    /// append 后回读末行校验，不一致抛错。
    /// 仅当条目属于当前打开会话时才并入内存 entries——流式回复在生成途中
    /// 被切会话后按 origin 落盘，不得串进当前会话的内存消息流。
    func append(_ entry: DiscussionEntry) throws {
        try appendVerified(entry, to: jsonlURL)
        // 按 id 去重：乐观上屏（stageOutgoingUser）已并入内存的同一条目不重复收纳
        if entry.sessionId == sessionId, !entries.contains(where: { $0.id == entry.id }) {
            entries.append(entry)
        }
    }

    /// 乐观上屏（发送体验）：用户消息先并入内存消息流立即显示，落盘仍由
    /// performSend 的 append 补齐（同一 entry id，append 内存收纳按 id 去重）。
    /// 提示词组装（向量检索/技能判定的网络往返）不再挡在气泡上屏之前。
    /// - Returns: 已入列的条目（随 send 的 stagedUserEntry 下传，保证落盘是同一条）。
    @discardableResult
    func stageOutgoingUser(
        _ text: String, imageFiles: [String] = [], fileRefs: [String] = []
    ) -> DiscussionEntry {
        let entry = makeEntry(
            role: .user, content: text,
            images: imageFiles.isEmpty ? nil : imageFiles,
            files: fileRefs.isEmpty ? nil : fileRefs
        )
        if entry.sessionId == sessionId, !entries.contains(where: { $0.id == entry.id }) {
            entries.append(entry)
        }
        return entry
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
        files: [String]? = nil,
        fileChanges: [FileChangeSummary]? = nil,
        milestones: [MilestoneStamp]? = nil,
        changeProposal: ChangeProposalRecord? = nil
    ) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionId,
            role: role,
            content: content,
            think: think,
            memory: memory,
            images: images,
            files: files,
            fileChanges: fileChanges,
            milestones: milestones,
            changeProposal: changeProposal,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - 流式发送（M2：阶段化 system prompt + 思考捕获）

    /// 发送用户消息并流式接收回复；完成后整条落盘（流式期间 UI 由 streamingText 驱动）。
    /// - Parameters:
    ///   - stage: LLM 阶段（取该阶段模型配置）
    ///   - systemPrompt: 由 AgentPrompts 构造的阶段化 system prompt（含记忆注入区）
    ///   - maxTokens: 单次回复上限。默认 16384（与 sendSystemTurn 对齐）：思考型
    ///     模型 reasoning 与正文共用输出池，澄清对话 transcript 长且常遇重度权衡
    ///     问题，思考可烧数千 token——旧默认 4096 被思考占满后正文零输出，
    ///     streamChat 抛 emptyStream「模型未返回任何内容」（2026-09-15 实证；
    ///     回退重做轮因 maxTokens 16384 而幸免，普通聊天轮必撞）。产物阶段
    ///     调用点显式传 32768
    ///   - imageFiles: 用户消息附图（attachments/ 文件名引用；仅当模型配置
    ///     supportsImages 时随请求编码为 image_url，落盘始终保留引用）
    ///   - fileRefs: 用户引用的产物文件（相对版本目录路径）：落盘进条目 files 字段，
    ///     并在本轮 system prompt 尾部注入文件原文（ReferencedFileMaterial）——
    ///     模型据此真正读到内容，不再回答「无法访问文件系统」
    ///   - skills: 本轮引用的技能 id（Context Builder 命中注入，AppModel 组装时取得）
    ///   - onAssistant: 回复完成后的回调（产物解析、轮次推进等由编排层处理）
    func send(
        _ text: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 16384,
        imageFiles: [String] = [],
        fileRefs: [String] = [],
        skills: [String] = [],
        stagedUserEntry: DiscussionEntry? = nil,
        onAssistant: ((DiscussionEntry) -> Void)? = nil
    ) async {
        // 打包进可取消句柄（stopGeneration 的取消来源）；仍 await 完成，调用方语义不变
        await self.trackGeneration {
            await self.performSend(
                text, settings: settings, stage: stage, systemPrompt: systemPrompt,
                maxTokens: maxTokens, imageFiles: imageFiles, fileRefs: fileRefs,
                skills: skills, stagedUserEntry: stagedUserEntry, onAssistant: onAssistant
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
        fileRefs: [String],
        skills: [String],
        stagedUserEntry: DiscussionEntry? = nil,
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async {
        // 发起时快照上下文：生成途中用户可能切换会话/项目，
        // 回复必须落回发起会话（否则串会话），回调也仅在仍在发起会话时执行。
        let origin = StreamOrigin(project: project, version: version, sessionId: sessionId)
        // 待回复占位（幂等）：AppModel.sendMessage 已随乐观上屏置位——此处兜住
        // followUp 续发等未经该入口的调用方，覆盖 buildHistory 压缩摘要的网络往返。
        beginPreparingReply(sessionID: origin.sessionId)
        do {
            // 乐观上屏通道：调用方已提前入列的用户条目原样落盘（同 id 不重复上屏）；
            // 未走该通道的调用方（followUps 续发 / 系统链路）照旧在此构造。
            let userEntry = stagedUserEntry ?? makeEntry(
                role: .user, content: text,
                images: imageFiles.isEmpty ? nil : imageFiles,
                files: fileRefs.isEmpty ? nil : fileRefs
            )
            try append(userEntry)

            // 引用文件读盘注入（本轮 system prompt 尾部；system 段不占历史预算）
            let prompt = ReferencedFileMaterial.augment(
                systemPrompt: systemPrompt, refs: fileRefs,
                project: project, version: version
            )
            var history = await buildHistory(systemPrompt: prompt, settings: settings)
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
            // 正常完成后消费 followUp 队列（P3）：插话续发走完整发送链路。
            // 停止（stopGeneration 清队列 + 任务取消）与错误路径不消费。
            await drainFollowUps(
                origin: origin, settings: settings, stage: stage,
                systemPrompt: systemPrompt, maxTokens: maxTokens, onAssistant: onAssistant
            )
        } catch {
            endPreparingReply()  // 流式开启前即失败：占位气泡必须收起
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
            // 错误收尾：排队中的插话一并作废（用户重发即可），避免半途状态残留
            steeringQueue = []
            followUpQueue = []
            streamingText = ""
            streamingThink = ""
            streamingSkills = []
            streamingPhase = nil
            streamingStartedAt = nil
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

    /// 系统触发回合的收尾口径（采纳落实闭环需要区分成败；其余调用方忽略返回值）。
    enum SystemTurnOutcome {
        case completed     // 自然完成（未停止、无错误）
        case interrupted   // 用户停止或出错（⏹ / ⚠️ 收尾行已落盘）
    }

    /// 系统触发的生成回合（阶段推进后的自动生成）：回合注记系统行 + 合成 user 指令。
    /// 合成指令不落盘为用户消息（它不是用户说的），仅进模型上下文。
    /// 注记照常落盘（审计轨迹），UI 层把它并入随后的助手气泡顶部，不再渲染成独立胶囊。
    /// - Returns: 收尾口径（自然完成 vs 停止/出错）；风险采纳落实据此决定是否流转状态。
    @discardableResult
    func sendSystemTurn(
        note: String?,
        userPrompt: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 16384,
        skills: [String] = [],
        onAssistant: ((DiscussionEntry) -> Void)? = nil
    ) async -> SystemTurnOutcome {
        var outcome = SystemTurnOutcome.interrupted
        // 打包进可取消句柄（stopGeneration 的取消来源）
        await self.trackGeneration {
            outcome = await self.performSendSystemTurn(
                note: note, userPrompt: userPrompt, settings: settings, stage: stage,
                systemPrompt: systemPrompt, maxTokens: maxTokens, skills: skills,
                onAssistant: onAssistant
            )
        }
        return outcome
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
    ) async -> SystemTurnOutcome {
        isStreaming = true  // 先置位：注记行直接并入流式气泡，避免「独立胶囊 → 并入」闪烁
        streamingStartedAt = Date()
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
            // 正常完成后消费 followUp 队列（P3）；完成后才记 .completed
            await drainFollowUps(
                origin: origin, settings: settings, stage: stage,
                systemPrompt: systemPrompt, maxTokens: maxTokens, onAssistant: onAssistant
            )
            return .completed
        } catch {
            isStreaming = false
            // streamReply 未进入即抛错（如历史组装失败）时其 defer 不执行，此处兜底清流起点
            streamingStartedAt = nil
            // 用户主动停止（流式开始前的取消）：只落「⏹ 已停止」注记，不写 ⚠️ 错误行
            if Self.isCancellation(error) {
                let stopped = Self.makeStoppedTurn(
                    partial: "", reasoning: "", duration: 0, skills: [],
                    sessionId: origin.sessionId
                )
                try? appendPinned(stopped.note, origin: origin)
                return .interrupted
            }
            // 错误收尾：排队中的插话一并作废（用户重发即可），避免半途状态残留
            steeringQueue = []
            followUpQueue = []
            streamingText = ""
            streamingThink = ""
            streamingSkills = []
            streamingPhase = nil
            streamingStartedAt = nil
            var errorEntry = makeEntry(
                role: .system,
                content: "⚠️ \(error.localizedDescription)"
            )
            errorEntry.sessionId = origin.sessionId
            try? appendPinned(errorEntry, origin: origin)
            return .interrupted
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

    // MARK: - Follow-up 续发（P3）

    /// 消费 followUp 队列：逐条作为新输入走完整发送链路（落盘 user 条目 +
    /// 历史组装 + 流式回复）。调用方已在可取消句柄内，不再经 trackGeneration。
    /// 续发期间用户切走发起会话 → 终止并清队列（插话不跨会话自动执行）；
    /// 续发轮出错时 performSend 内部已清队列，循环自然终止。
    private func drainFollowUps(
        origin: StreamOrigin,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int,
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async {
        while !followUpQueue.isEmpty, !Task.isCancelled {
            guard project == origin.project, version == origin.version,
                  sessionId == origin.sessionId else {
                followUpQueue = []
                return
            }
            let pending = followUpQueue
            followUpQueue = []
            let text = pending.map(\.content).joined(separator: "\n\n")
            await performSend(
                text, settings: settings, stage: stage, systemPrompt: systemPrompt,
                maxTokens: maxTokens, imageFiles: [], fileRefs: [],
                skills: [], onAssistant: onAssistant
            )
        }
    }

    /// 历史压缩摘要缓存（s08 滚动压缩）：被丢旧轮摘要一次、缓存复用；
    /// 边界移动时只摘要新增被丢轮（旧摘要 + 新轮 → 更新摘要），不全量重算。
    private var compactSummary = ""
    private var compactBoundary = ""
    private var compactSummarizedCount = 0

    private func buildHistory(
        systemPrompt: String, settings: LLMSettings
    ) async -> [ChatMessage] {
        // 投影管道（HistoryProjection）：entries → LLM 消息 → 预算裁剪 → 摘要垫头
        let history = [ChatMessage(role: .system, content: systemPrompt)]
            + HistoryProjection.projectEntries(entries)
        let (kept, dropped) = HistoryProjection.splitByBudget(history, budget: historyTokenBudget)
        guard !dropped.isEmpty else { return kept }

        // 摘要缓存命中：边界未变直接复用
        let boundary = HistoryProjection.droppedBoundary(dropped)
        if boundary == compactBoundary, !compactSummary.isEmpty {
            return HistoryProjection.historyWithSummary(kept: kept, summary: compactSummary)
        }

        // 滚动压缩：旧摘要 + 新增被丢轮 → 一次性 LLM 摘要（classify 档）
        let base = min(compactSummarizedCount, dropped.count)
        let newDropped = dropped.dropFirst(base)
        let transcript = newDropped
            .map { "\($0.role == .user ? "用户" : "助手")：\($0.content)" }
            .joined(separator: "\n")
        if let updated = try? await oneShot(
            HistoryProjection.compactSummaryPrompt(
                previous: compactSummary, transcript: String(transcript.suffix(12000))
            ),
            settings: settings, stage: .classify, maxTokens: 800
        ), !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summary = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            compactSummary = summary
            compactBoundary = boundary
            compactSummarizedCount = dropped.count
            // 压缩结果落盘（P2）：role == .system 注记行 + CompactionData 载荷，
            // 冷启动恢复缓存、Finder 可读。写盘失败不阻塞主流程。
            saveCompaction(
                summary: summary, boundary: boundary, droppedCount: dropped.count,
                tokensBefore: TokenBreakdown.estimate(
                    history.map(\.content).joined(separator: "\n")
                ),
                origin: originForHistory
            )
            return HistoryProjection.historyWithSummary(kept: kept, summary: summary)
        }
        // 摘要失败（模型不可用等）：降级为纯丢弃（旧行为），不阻塞主流程
        return kept
    }

    /// 压缩落盘的归属会话（performSend/performSendSystemTurn 进入时快照；
    /// 历史组装期间用户切会话不串行——与流式回复同一钉回语义）。
    private var originForHistory: StreamOrigin {
        StreamOrigin(project: project, version: version, sessionId: sessionId)
    }

    /// 压缩摘要落盘（P2）：追加 role == .system 的压缩注记行——content = 注记头 +
    /// 摘要全文（UI 渲染压缩卡片、Finder 可读），compaction 载荷存恢复元数据。
    private func saveCompaction(
        summary: String, boundary: String, droppedCount: Int, tokensBefore: Int,
        origin: StreamOrigin
    ) {
        let entry = DiscussionEntry(
            id: UUID().uuidString,
            sessionId: origin.sessionId,
            role: .system,
            content: "🗜️ 上下文已压缩——较早对话轮次已折叠为以下摘要\n\n" + summary,
            compaction: CompactionData(
                summary: summary,
                boundary: boundary,
                droppedCount: droppedCount,
                tokensBefore: tokensBefore,
                viaStage: LLMStage.classify.rawValue
            ),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        try? appendPinned(entry, origin: origin)
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
        endPreparingReply()  // 开流转正：待回复占位无缝切换为真实流式态
        streamingText = ""
        streamingThink = ""
        streamingSkills = skills
        let startedAt = Date()
        streamingStartedAt = startedAt
        defer {
            isStreaming = false
            streamingSessionID = nil
            streamingStartedAt = nil
            streamingSkills = []
            streamingRetry = nil  // 错误上抛等所有出口统一清态，防「重试中」行残留
            streamingPhase = nil  // 阶段文案随流收尾统一清态，防残留到下一轮占位
            endPreparingReply()
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
        // 空流自动重试（上限 1 次），按成因分策略：
        // - emptyAfterThinking（思考分片有、正文零）：思考型模型把输出预算烧满，
        //   同请求重发大概率重演（2026-09-16 实证：glm-5.3-flash 思考 3 分钟烧完
        //   16384 预算，重试再烧 3 分钟再空流，用户等 6 分钟收「模型未返回任何内容」）
        //   ——重试改为加倍输出预算 + 强制 low 思考（low 档可直接关思考，正文即流出）；
        // - emptyStream（零分片，服务端抖动）：同请求重发一次可救回大半。
        // 仅在无正文渲染时触发，截断续写场景不适用。
        var emptyRetries = 0
        var retryBudget = maxTokens
        var retryEffort: ThinkingEffort? = nil  // nil = 沿用用户档位
        // 用户停止（生成任务被取消）：立即中断接收，已生成部分收尾落盘保留
        var stopped = false
        do {
            while !Task.isCancelled {
                // steering 注入（P3）：截断续写边界——当前流已结束、下一次 LLM 调用前。
                // 插话此刻落盘（排队气泡转正）并进入续写上下文。
                if !steeringQueue.isEmpty {
                    let pending = steeringQueue
                    steeringQueue = []
                    for msg in pending {
                        try? appendPinned(msg, origin: origin)
                        messages.append(ChatMessage(role: .user, content: msg.content))
                    }
                }
                let stream = try LLMClient.streamChat(
                    stage: stage, settings: settings, messages: messages, maxTokens: retryBudget,
                    reasoningEffort: (retryEffort ?? thinkingEffort).apiValue
                )
                var truncated = false
                let roundStart = full.count
                do {
                    for try await delta in stream {
                        switch delta {
                        case .text(let text):
                            full += text
                            if streamingRetry != nil { streamingRetry = nil }
                            if textGate.shouldPublish() { streamingText = full }
                        case .reasoning(let chunk):
                            reasoning += chunk
                            if streamingRetry != nil { streamingRetry = nil }
                            if thinkGate.shouldPublish() { streamingThink = reasoning }
                        case .retrying(let code, let attempt):
                            // 瞬时故障自动重试中：气泡状态行（首次正文到达即清除）
                            streamingRetry = LLMClient.retryStatusText(code: code, attempt: attempt)
                        case .truncated:
                            truncated = true
                        }
                    }
                } catch LLMClient.LLMError.emptyAfterThinking
                    where !Task.isCancelled && full.count == roundStart && emptyRetries < 1 {
                    // 思考烧满输出预算：换条件重试（加倍预算 + 强制 low 思考）。
                    // must 排除取消态——用户停止时 LLMClient 也以空流形态浮出
                    //（isCancellation 靠 Task.isCancelled 兜底分流），误重试会吞掉「⏹ 已停止」收尾。
                    emptyRetries += 1
                    retryBudget = LLMClient.escalatedRetryBudget(retryBudget)
                    retryEffort = .low
                    continue
                } catch LLMClient.LLMError.emptyStream
                    where !Task.isCancelled && full.count == roundStart && emptyRetries < 1 {
                    // 字面空流（服务端抖动）重试（上限 1 次）：同请求重发。
                    emptyRetries += 1
                    continue
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

        // 未注入的插话 → followUp（P3）：流自然结束（未截断或续写上限）时，
        // 排队中的插话作为新输入自动续发，不丢失。停止路径（stopped）队列已清。
        if !stopped, !steeringQueue.isEmpty {
            followUpQueue.append(contentsOf: steeringQueue)
            steeringQueue = []
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
}
