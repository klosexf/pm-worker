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

    /// 摘要行：「思考了 Ns · M 步 · 技能 ×K」。
    var summary: String {
        let skillCount = steps.filter { $0.skill != nil }.count
        var parts = ["思考了 \(dur)s · \(steps.count) 步"]
        if skillCount > 0 { parts.append("技能 ×\(skillCount)") }
        return parts.joined(separator: " · ")
    }

    /// 从 reasoning 原文构造（按行拆步骤；截断超长行，保留可解释性不泄露全文）。
    static func from(reasoning: String, duration: Int) -> ThinkData? {
        let lines = reasoning
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        // 步骤上限 12 条，单条截 200 字——结论级信任，非全文
        let steps = lines.prefix(12).map { line in
            Step(text: String(line.prefix(200)), skill: nil, detail: nil, dur: nil)
        }
        return ThinkData(dur: duration, steps: steps)
    }
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
    var createdAt: String

    init(
        id: String,
        sessionId: String,
        role: Role,
        content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil,
        images: [String]? = nil,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.think = think
        self.memory = memory
        self.images = images
        self.createdAt = createdAt
    }

    // Codable 兼容旧存量（无 images 字段的 discussions.jsonl）
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, think, memory, images, createdAt
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
    @Published private(set) var isStreaming = false

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

    /// 某 project/version 下全部会话（按最后活跃倒序）。
    nonisolated static func sessions(in project: String, version: String) -> [SessionSummary] {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
        let all = PMAgentStore.readLines(DiscussionEntry.self, from: url)
        var bySession: [String: [DiscussionEntry]] = [:]
        for entry in all { bySession[entry.sessionId, default: []].append(entry) }

        return bySession.map { sid, entries in
            let firstUser = entries.first { $0.role == .user }?.content ?? "（空会话）"
            let last = entries.map(\.createdAt).max() ?? ""
            return SessionSummary(
                id: sid,
                title: String(firstUser.prefix(24)),
                lastActiveAt: last,
                messageCount: entries.count
            )
        }
        .sorted { $0.lastActiveAt > $1.lastActiveAt }
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
        streamingText = ""
        streamingThink = ""
    }

    // MARK: - 写入（append + write-then-verify，E5）

    /// append 后回读末行校验，不一致抛错。
    func append(_ entry: DiscussionEntry) throws {
        try PMAgentStore.appendLine(entry, to: jsonlURL)

        // write-then-verify：回读末行必须与写入内容逐字节一致。
        // appendLine 每行以 \n 结尾——按 \n split 后末元素必是空串，
        // 校验取「最后一个非空行」（否则空文件尾行判空导致每次 append 必抛错）。
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else {
            throw NSError(
                domain: "SessionStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "会话写入后回读失败：\(jsonlURL.path)"]
            )
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let lastLine = lines.last(where: { !$0.isEmpty }),
              lastLine == String(decoding: try encoder.encode(entry), as: UTF8.self)
        else {
            throw NSError(
                domain: "SessionStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "会话写入校验失败（末行不一致）：\(jsonlURL.path)"]
            )
        }
        entries.append(entry)
    }

    func makeEntry(
        role: DiscussionEntry.Role,
        content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil,
        images: [String]? = nil
    ) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionId,
            role: role,
            content: content,
            think: think,
            memory: memory,
            images: images,
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
    ///   - onAssistant: 回复完成后的回调（产物解析、轮次推进等由编排层处理）
    func send(
        _ text: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 4096,
        imageFiles: [String] = [],
        onAssistant: ((DiscussionEntry) -> Void)? = nil
    ) async {
        do {
            let userEntry = makeEntry(
                role: .user, content: text,
                images: imageFiles.isEmpty ? nil : imageFiles
            )
            try append(userEntry)

            var history = buildHistory(systemPrompt: systemPrompt)
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
                history: history, stage: stage, settings: settings, maxTokens: maxTokens,
                onAssistant: onAssistant
            )
        } catch {
            streamingText = ""
            let errorEntry = makeEntry(
                role: .system,
                content: "⚠️ \(error.localizedDescription)"
            )
            try? append(errorEntry)
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
        onAssistant: ((DiscussionEntry) -> Void)? = nil
    ) async {
        isStreaming = true  // 先置位：注记行直接并入流式气泡，避免「独立胶囊 → 并入」闪烁
        do {
            if let note {
                let noteEntry = makeEntry(role: .system, content: note)
                try append(noteEntry)
            }

            var history = buildHistory(systemPrompt: systemPrompt)
            history.append(ChatMessage(role: .user, content: userPrompt))
            try await streamReply(
                history: history, stage: stage, settings: settings, maxTokens: maxTokens,
                onAssistant: onAssistant
            )
        } catch {
            isStreaming = false
            streamingText = ""
            let errorEntry = makeEntry(
                role: .system,
                content: "⚠️ \(error.localizedDescription)"
            )
            try? append(errorEntry)
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

    private func buildHistory(systemPrompt: String) -> [ChatMessage] {
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
        // 历史段预算裁剪（Context Builder 分配值）：超预算成对丢最旧整轮
        return Self.trimmedHistory(history, budget: historyTokenBudget)
    }

    // MARK: - 历史段预算裁剪（Task 4.1，design.md §6.4）

    /// 超预算成对丢最旧整轮（user → assistant 为一轮，保新丢旧不拆对）。
    /// 契约：首条 system（阶段 prompt）常驻不占历史预算；预算 ≤ 0 → 只剩 system
    /// （历史段整体让位，Context Builder 会把 .history 记入 trimmed）。
    nonisolated static func trimmedHistory(
        _ messages: [ChatMessage], budget: Int
    ) -> [ChatMessage] {
        // 首条 system（组装后的阶段 prompt）剥离出预算核算
        var rest = messages
        var systemPrefix: [ChatMessage] = []
        if rest.first?.role == .system {
            systemPrefix = [rest.removeFirst()]
        }
        guard budget > 0 else { return systemPrefix }

        // 预算内全量保留
        if TokenBreakdown.estimate(rest.map(\.content).joined(separator: "\n")) <= budget {
            return systemPrefix + rest
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
        return systemPrefix + kept.flatMap { $0 }
    }

    private func streamReply(
        history: [ChatMessage],
        stage: LLMStage,
        settings: LLMSettings,
        maxTokens: Int,
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async throws {
        isStreaming = true
        streamingText = ""
        streamingThink = ""
        let startedAt = Date()
        defer { isStreaming = false }

        var full = ""
        var reasoning = ""
        let stream = try LLMClient.streamChat(
            stage: stage, settings: settings, messages: history, maxTokens: maxTokens
        )
        for try await delta in stream {
            switch delta {
            case .text(let text):
                full += text
                streamingText = full
            case .reasoning(let chunk):
                reasoning += chunk
                streamingThink = reasoning
            }
        }

        let duration = Int(Date().timeIntervalSince(startedAt))
        let thinkData = ThinkData.from(reasoning: reasoning, duration: duration)
        let assistantEntry = makeEntry(
            role: .assistant, content: full, think: thinkData
        )
        try append(assistantEntry)
        streamingText = ""
        streamingThink = ""
        onAssistant?(assistantEntry)
    }

    private func roleOf(_ role: DiscussionEntry.Role) -> ChatMessage.Role {
        switch role {
        case .user: .user
        case .assistant, .system: .assistant
        }
    }
}
