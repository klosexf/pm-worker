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
        /// 工具调用行（Function Calling）：工具名 + 人话结果摘要。
        var tool: String?
        var detail: String?
        var dur: String?
    }

    /// 思考耗时（秒）。
    var dur: Int
    var steps: [Step]

    /// 知识引用（2026-09-17 钦定：系统层「参考知识卡」）——本轮 Context Builder
    /// 注入的卡命中（id → 标题），回答气泡底部渲染引用条；默认空兼容旧行。
    var knowledgeRefs: [String: String]? = nil
    /// reasoning 原文全文（2026-09-18 思考展示升级）：完成态展开可回看全文，不再
    /// 只留截断步骤。合成 Codable 对 optional 走 decodeIfPresent/encodeIfPresent——
    /// 旧存量行缺 key 解码为 nil、nil 不写盘，双向兼容。
    var full: String? = nil
    /// 确认链跳转历史（2026-09-18 持久化）：链式回合的阶段跳标签（如「正在抽取
    /// 澄清要点表…」→「正在沉淀记忆与方法论…」→「正在生成结构产物…」）。进行中
    /// 时间线随流收起，这里保留全程打勾痕迹——单跳/双跳链（②③闸口）在流式期
    /// 无打勾行，完成态展开恒可见。普通聊天轮无链 → nil。
    var phaseTrail: [String]? = nil

    /// 摘要行：「思考了 Ns · <技能> · 工具 ×N」（2026-09-22 收口：去掉「收束句」段）。
    /// 原「以推理尾部收束句开头」的改版把原始 CoT 直接印在了每条气泡的折叠行上
    /// ——不打开展开区也照漏，实测那句「你好」漏出的是
    /// 「the tool-calling section says tools available; not needed here」。
    /// 技能 ≤2 个直接点名（折叠态即可见所应用技能名），≥3 收敛为「技能 ×K」防过长；
    /// 工具调用（Function Calling）单列「工具 ×N」计数，不与技能混算。
    var summary: String {
        let skillNames = steps.compactMap(\.skill)
        let toolNames = steps.compactMap(\.tool)
        var parts: [String] = ["思考了 \(dur)s"]
        switch skillNames.count {
        case 1: parts.append(skillNames[0])
        case 2: parts.append(skillNames.joined(separator: "、"))
        case 3...: parts.append("技能 ×\(skillNames.count)")
        default: break
        }
        if !toolNames.isEmpty { parts.append("工具 ×\(toolNames.count)") }
        return parts.joined(separator: " · ")
    }

    /// 从 reasoning 原文构造。
    /// **steps 只装产品自己生成的结构化行**（工具调用行 + 技能注入行）——模型原始
    /// 思维链不进这里，它既含内部字段名也含实现细节，违反 AGENTS.md「用户信息展示
    /// 规范」，且 design.md §6.4.1 v0.9.6 本就写明「推理步骤是面向用户可读的摘要
    /// 而非原始思维链」。原文只进 `full` 落盘（DeepSeek reasoning_content 回放依赖），
    /// 用户侧回看入口在开发者模式（⌘D）。
    /// skills：本轮实际注入的技能 id（Context Builder 命中：语义命中 + 阶段核心
    /// 确定性注入）。toolSteps：Function Calling 工具调用行，置于最前（执行时序
    /// 最靠前）。knowledgeRefs：本轮注入的知识卡命中（id→标题），气泡底部引用条数据源。
    static func from(
        reasoning: String, duration: Int, skills: [String] = [],
        toolSteps: [Step] = [],
        knowledgeRefs: [String: String]? = nil,
        phaseTrail: [String]? = nil
    ) -> ThinkData? {
        let skillSteps = skills.map { skill in
            Step(text: nil, skill: skill, detail: "已注入本轮提示词上下文", dur: nil)
        }
        let steps = toolSteps + skillSteps
        // 纯空白 reasoning 视同「本轮没思考」：旧实现按行拆分 + 滤空顺带把它归零了，
        // 现在不拆行，必须显式判空——否则一句空思考也会凭空冒出「思考了 Ns」摘要行。
        let fullText = reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : reasoning
        // 无任何可展示内容（结构化行 / 思考耗时 / 知识引用）时不出卡。
        // 有 reasoning 但无结构化行时仍出卡——摘要行的「思考了 Ns」是长等待的唯一
        // 进度凭据，不能因为没技能没工具就把整卡收掉。
        guard !steps.isEmpty || fullText != nil || knowledgeRefs?.isEmpty == false else {
            return nil
        }
        return ThinkData(
            dur: duration, steps: steps, knowledgeRefs: knowledgeRefs,
            full: fullText,
            phaseTrail: (phaseTrail?.isEmpty == false) ? phaseTrail : nil
        )
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
    /// 本条摘要覆盖的被丢轮边界签名（恢复压缩缓存 boundary 用）。
    var boundary: String
    /// 被丢条目数（恢复压缩缓存 count 用）。
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
    /// 静默事件行（role == .system 且为 true）：照常落盘（审计/回放/链式判定数据源），
    /// 但 UI 不渲染——其语义已由当轮 AI 回答的开场承接句承载（快速通道受理 / 跨门
    /// 风险提醒 / 阶段推进确认三类，2026-09-17 钦定「系统行融合进 AI 回答」）。
    var silent: Bool?
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
        silent: Bool? = nil,
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
        self.silent = silent
        self.createdAt = createdAt
    }

    /// 静默行判据（displayItems 过滤 + 合并行走排除共用）。
    /// 旧存量「⚡ 已排队」排队提示行（2026-09-18 停止发射）按静默处理：
    /// 落盘留痕不变，UI 不再渲染。
    var isSilent: Bool {
        silent == true || (role == .system && content.hasPrefix("⚡ 已排队"))
    }

    // Codable 兼容旧存量（无 images / files / fileChanges / milestones / compaction / changeProposal / silent 字段的 discussions.jsonl）
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, think, memory, images, files, fileChanges, milestones, compaction, changeProposal, silent, createdAt
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
        silent = try c.decodeIfPresent(Bool.self, forKey: .silent)
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

    /// 注入段全文（refs 全空 → nil）。路径去重保序；读取失败逐条标注，
    /// 让模型能如实告知用户「这个文件读不到」，而不是含糊搪塞。
    /// 消费点 = 动态材料尾条（前缀缓存改造后不再追加 system prompt）。
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

// MARK: - 动态材料尾条（前缀缓存改造，ContextTail 协议的发送侧）

/// 尾条组装辅助（nonisolated：纯值变换，测试直测）。
nonisolated enum VolatileTailMaterial {
    /// 尾条消息全文：user 角色 + 自述头——非用户新发言，模型须遵守其中约束
    /// （记忆新覆盖旧）并回答上一条用户消息。头部措辞承接 injectionSection
    /// 原有的「回答不得与下列内容矛盾」约束语义。
    static func message(_ tail: String) -> String {
        "【动态材料 · 系统注入】以下是本轮动态装配的材料（记忆/技能/检索参考/引用文件正文/阶段状态），"
            + "不是用户新发言；请遵守其中约束作答，记忆条目新覆盖旧，回答不得与下列内容矛盾。\n\n"
            + tail
    }

    /// 追加尾条到历史末尾（当前用户消息之后）：[system 冻结][历史 append-only]
    /// [当前 user][动态材料]——前缀缓存的可命中区止于动态材料之前。
    /// tail 为空原样返回（无标记轮次不产生多余消息）。
    static func appending(_ history: [ChatMessage], tail: String) -> [ChatMessage] {
        guard !tail.isEmpty else { return history }
        return history + [ChatMessage(role: .user, content: message(tail))]
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

/// 阶段时间线单跳（2026-09-18 确认链多跳进度）：确认链/生成链的每段阶段文案
/// 依次入轨，前置跳标 done（UI 打勾），当前跳未 done（呼吸点 + 流光）。
nonisolated struct PhaseStep: Equatable {
    var label: String
    var done: Bool
}

/// 工具循环常量（Function Calling v1）：单回合工具执行轮上限——超过后不再执行、
/// 直接以「已达上限」文本作为工具结果回流，并把 tools 从后续请求中摘除，
/// 强制模型基于已有结果作答（防失控兜底）。
nonisolated enum ToolLoopPolicy {
    static let maxToolRounds = 4

    /// 超限后不再执行的兜底结果文本。
    static func limitExceededResult(maxRounds: Int = maxToolRounds) -> AgentToolResult {
        .failure("本轮工具调用次数已达上限（\(maxRounds) 轮）。请直接基于以上工具结果与已有信息作答，不要再调用工具。")
    }

    /// 工具轮消息拼装（纯函数，测试直测）：assistant(tool_calls) + 逐调用 tool 结果。
    /// 这些消息只存在于本轮 streamReply 的局部 messages——不入盘、不进
    /// HistoryProjection（对齐「动态材料」先例：discussions.jsonl 是闸门事实源，
    /// 工具轮是生成过程而非用户裁决事件；可追溯由思考卡工具行承担）。
    static func followUpMessages(
        assistantContent: String,
        calls: [LLMToolCall],
        results: [AgentToolResult]
    ) -> [ChatMessage] {
        var msgs: [ChatMessage] = [
            ChatMessage(role: .assistant, content: assistantContent, toolCalls: calls)
        ]
        for (call, result) in zip(calls, results) {
            var text = result.forLLM
            if text.count > agentToolResultBudget {
                text = String(text.prefix(agentToolResultBudget)) + "\n…（结果过长已截断）"
            }
            msgs.append(ChatMessage(role: .tool, content: text, toolCallID: call.id))
        }
        return msgs
    }
}

/// 单会话流态快照（阶段 1 流态扇出）：per-session 键值的值类型，字段与旧全局
/// 单流同名位一一对应。跨隔离传递用显式 nonisolated（工程默认 MainActor 隔离）。
nonisolated struct StreamState: Equatable {
    var isStreaming = false
    var isPreparing = false
    /// 展示正文：发布点经 StreamDisplayPayload.make(full:) 算出——完整产物块
    /// 已剥离、进行中块已裁除，只剩块间正文（不再是全文原样）。
    var text = ""
    var think = ""
    var skills: [String] = []
    /// 工具调用轨道（Function Calling）：本轮已执行的工具行（流中实时展示，
    /// 落盘时并入 ThinkData.steps）。
    var toolSteps: [ThinkData.Step] = []
    /// 阶段时间线（DSH 左脊时间线轻量版）：原 phase 单行文案升级为多跳轨迹——
    /// 确认链「要点表 → 记忆 → 方法论 → 生成」逐跳入轨，长等待显性化为可见进度。
    var phaseTrail: [PhaseStep] = []
    var retry: String?
    var startedAt: Date?
    /// 结构化产物事实（与展示文本解耦，见 StreamDisplayPayload）：
    /// 完整块列表 + 进行中块名/行数——流式进度卡与块卡的渲染依据。
    var artifactBlocks: [ArtifactParser.ArtifactBlock] = []
    var inProgressName = ""
    var inProgressLines = 0
}

/// 流式盒（2026-09-18 吞吐修复，探针实证）：per-session ObservableObject。
/// 流式增量只触碰盒自身 objectWillChange，订阅者只有流式气泡子视图——
/// 对话页等大视图不再随每个 delta 整页重渲染（修复前：3103 次发布 × ~0.3s
/// 整页重渲染吃满 MainActor，883s 轮网络侧仅 45.5s）。
@MainActor
final class StreamBox: ObservableObject {
    @Published var value: StreamState
    init(_ value: StreamState = StreamState()) { self.value = value }
    // 铁律：@MainActor ObservableObject 在流收尾/空态剪枝时被销毁，
    // 必须退出隔离销毁路径，否则 isolated-deinit 触发 malloc 崩溃（同 PipelineEngine）。
    nonisolated deinit {}
}

/// 流式发布尾窗（2026-09-18 吞吐修复，探针实证）：流式态 UI 只拿字符串尾部，
/// 流式气泡的 Text 布局成本常数化（61k 字符全量逐次重排曾拖垮消费循环）。
/// 全量语义不变：streamReply 的本地 full/reasoning 持续累积，落盘 / 续写 /
/// 停止收尾 / 终值补发一律全量。
enum StreamPublishTail {
    /// 正文尾窗：保底可视上下文（流式气泡自动吸底，视野集中在尾部）。
    static let textChars = 12000
    /// 思考尾窗：思考卡本就是流式预览（全文随完成卡落盘）。
    /// 注：2026-09-22 起原始 CoT 不再进思考卡视图，本值只服务「本轮是否在思考」
    /// 的判据与落盘链路；曾配套过一个 `liveThinkChars = 900`（展开态实时尾随的
    /// 渲染尾窗），随该渲染路径一并删除。
    static let thinkChars = 4000

    static func clip(_ source: String, limit: Int) -> String {
        guard source.count > limit else { return source }
        return String(source.suffix(limit))
    }
}

/// 流式正文展示载荷（2026-09-18 进度卡回归修复）：识别事实在发布点用**全量
/// full** 计算、结构化下发，与展示文本彻底解耦——此前「尾窗裁剪 + 拼回开栏」
/// 被实测打穿（四反引号 prd 块内嵌 ``` 围栏把拼回的三反引号开栏误判闭合、
/// 多块场景 radar 开栏在窗内但不收卡），根因是展示文本被裁剪后识别标记不可靠。
nonisolated struct StreamDisplayPayload: Equatable {
    /// 剥离完整产物块、裁掉进行中块之后的块间正文（已保尾裁剪）。
    var display = ""
    /// 已闭合的完整产物块（流式 ArtifactBlocksSection 渲染源）。
    var blocks: [ArtifactParser.ArtifactBlock] = []
    /// 进行中（未闭合）产物块名；空 = 无。
    var inProgressName = ""
    /// 进行中块已生成行数（全量口径，修复前从尾窗计虚低）。
    var inProgressLines = 0

    /// 全量 full → 展示载荷。发布点每次 text 发布调用（解析 ~1ms 级 ×
    /// 0.1s 节流，MainActor 占比 <5%，探针实证正文阶段本就满速）。
    static func make(full rawFull: String) -> StreamDisplayPayload {
        var payload = StreamDisplayPayload()
        // 占位模仿残留清洗先于解析（模型照抄的系统标注行不进气泡，与旧视图层口径一致）
        let full = ArtifactParser.scrubImitatedPlaceholders(in: rawFull)
        let blocks = ArtifactParser.parseArtifactBlocks(in: full)
        payload.blocks = blocks
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: full)
        payload.inProgressName = incomplete?.name ?? ""
        if let partial = incomplete?.partial {
            payload.inProgressLines =
                partial.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        var display = blocks.isEmpty
            ? full
            : ArtifactParser.stripArtifactBlocks(in: full, placeholderFor: { _ in "" })
        if incomplete != nil, let marker = display.range(of: "```artifact:", options: .backwards) {
            // 开栏可能是更长反引号（````artifact:），前缀反引号一并裁掉
            var cutStart = marker.lowerBound
            while cutStart > display.startIndex,
                  display[display.index(before: cutStart)] == "`" {
                cutStart = display.index(before: cutStart)
            }
            display = String(display[..<cutStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        payload.display = StreamPublishTail.clip(display, limit: StreamPublishTail.textChars)
        return payload
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

    // MARK: - 多会话流态（阶段 1 流态扇出：全局单流 → per-session 并行流）

    /// 单会话流态盒表（key = sessionId）：取代旧 [String: StreamState] 值字典
    /// （2026-09-18 吞吐修复，探针实证）。key 存在即「有内容」（流式 / 待回复 /
    /// 增量 / 重试与阶段文案任一非空），全空即移除（空态不留键）。**流式增量只
    /// 触碰盒自身 objectWillChange，不经过本表**——本表仅在成员增删（开流/收流/
    /// 占位起止）时发布，对话页等大视图不再随每个 delta 整页重渲染。
    /// 并发流互不污染；外部读点经 currentStream（本会话口径）/ isStreaming
    /// （全局资源闸口径）/ isSessionBusy（归属判据）。
    @Published private(set) var streamBoxes: [String: StreamBox] = [:]
    /// 流态快照（兼容读点）：测试断言与一次性布尔判读用，每键取盒内当前值。
    /// **流式增量不经过此快照**——依赖逐 delta 更新的读点必须订阅 StreamBox，
    /// 读快照只会在成员增删时看到新值（流中恒为上次快照）。
    var streams: [String: StreamState] { streamBoxes.mapValues { $0.value } }
    /// 单会话插话队列（key = sessionId）：流式期间收到，在截断续写边界注入该会话
    /// 当前回复上下文；流正常结束前未注入 → 转入该会话 followUpQueues 自动续发。
    /// 排队期不落盘（仅 UI 显示排队气泡），注入生效时随 appendPinned 落盘。
    @Published private(set) var steeringQueues: [String: [DiscussionEntry]] = [:]
    /// 单会话结束后队列（key = sessionId）：该轮流式收尾后逐条作为新输入自动续发。
    @Published private(set) var followUpQueues: [String: [DiscussionEntry]] = [:]

    /// 任意会话有流进行中（全局口径，阶段 3 后仅存兼容读点）：流态扇出后
    /// 业务判据已迁 isSessionBusy（会话归属）/ isVersionBusy（版本归属），
    /// 保留供测试与全局观测（侧栏总闸类读点）。
    var isStreaming: Bool { streamBoxes.values.contains { $0.value.isStreaming } }
    /// 任意会话有待回复占位（全局口径，同 isStreaming）。
    var isPreparingReply: Bool { streamBoxes.values.contains { $0.value.isPreparing } }
    /// 当前打开会话的流态快照（nil = 本会话无流/占位）：UI 本会话口径读点统一入口。
    var currentStream: StreamState? { streamBoxes[sessionId]?.value }
    /// 当前会话的插话队列（排队气泡数据源）。
    var currentSteeringQueue: [DiscussionEntry] { steeringQueues[sessionId] ?? [] }
    /// 当前会话的结束后队列。
    var currentFollowUpQueue: [DiscussionEntry] { followUpQueues[sessionId] ?? [] }

    /// 指定会话是否有流式回复或待回复占位进行中（per-session 归属判据统一入口：
    /// 流式/排队气泡渲染、侧栏生成指示点、插话分流）。
    func isSessionBusy(_ sessionID: String) -> Bool {
        guard let box = streamBoxes[sessionID] else { return false }
        return box.value.isStreaming || box.value.isPreparing
    }

    // MARK: 版本级 busy 判据（阶段 3）：流 → 发起上下文登记表

    /// 活动流会话 → 发起上下文（sessionId → (project, version)）：isVersionBusy /
    /// isProjectBusy 的数据源。与 streams 键**同生命周期**——开流/占位置位点登记
    /// （performSend / performSendSystemTurn / 乐观置位），键清理点一并注销
    /// （mutateStream 空态剪枝 / streamReply defer / stopGeneration），防泄漏。
    /// 非 @Published：每次登记/注销都与同一轮 streams 变更同帧发生，UI 经
    /// streams 的 objectWillChange 自然重估 isVersionBusy 读点。
    private var streamContexts: [String: (project: String, version: String)] = [:]

    /// 开流/占位置位时登记发起上下文（内部通道，与 beginPreparingReply /
    /// mutateStream(isStreaming:) 置位点成对调用）。
    private func registerStreamContext(_ origin: StreamOrigin) {
        streamContexts[origin.sessionId] = (project: origin.project, version: origin.version)
    }

    /// 指定版本是否有流式回复或待回复占位进行中（版本级 busy 判据，阶段 3）：
    /// 结构锁（删除/改名/移动等 discussions.jsonl 整文件重写与版本目录操作）、
    /// 确认坞/风险闸等版本闸口动作只被「目标版本自身的流」拦截——他会话
    /// 他版本的并发流不再挡路（B 会话的流不锁死 A 会话的交互）。
    func isVersionBusy(project: String, version: String) -> Bool {
        streamContexts.contains { sessionID, ctx in
            ctx.project == project && ctx.version == version && isSessionBusy(sessionID)
        }
    }

    /// 指定项目的任一版本是否有流进行中（项目级结构锁：整目录改名/删除
    /// 影响该项目全部版本的 jsonl，任一版本流中都要拦）。
    func isProjectBusy(project: String) -> Bool {
        streamContexts.contains { sessionID, ctx in
            ctx.project == project && isSessionBusy(sessionID)
        }
    }

    /// per-session 流态便捷写入口：key 不存在先插初始值；写完全空则移除 key
    /// （空态不留键）。SessionStore 内部流态写入的唯一通道（internal 供多会话
    /// 流态单测驱动状态机）。空态剪枝连带注销该会话的发起上下文登记
    /// （streamContexts 与 streams 键同生命周期，防泄漏）。
    /// 盒已存在时只触碰盒（发布走盒自身 objectWillChange）；成员增删才发布本表。
    func mutateStream(_ sessionID: String, _ body: (inout StreamState) -> Void) {
        var state = streamBoxes[sessionID]?.value ?? StreamState()
        body(&state)
        if state == StreamState() {
            streamBoxes[sessionID] = nil
            streamContexts[sessionID] = nil
        } else if let box = streamBoxes[sessionID] {
            box.value = state
        } else {
            streamBoxes[sessionID] = StreamBox(state)
        }
    }

    /// 闸口链阶段文案写入（AppModel 确认链直写迁移入口）：新阶段文案入轨
    /// phaseTrail（既有跳标 done、新跳为当前跳）；nil = 链尾收尾，全部标 done
    /// （此刻流已结束、完成卡即将接管，无僵尸 key）。重复写入相同的未完成
    /// label 幂等（防重试路径重复入轨）。归属钉定 origin 语义留阶段 2。
    func setStreamPhase(_ text: String?, for sessionID: String? = nil) {
        let id = sessionID ?? sessionId
        guard text != nil || streamBoxes[id] != nil else { return }  // 清空且无 key：免空转
        mutateStream(id) {
            if let text {
                if let last = $0.phaseTrail.last, !last.done, last.label == text { return }
                for i in $0.phaseTrail.indices { $0.phaseTrail[i].done = true }
                $0.phaseTrail.append(PhaseStep(label: text, done: false))
            } else {
                for i in $0.phaseTrail.indices { $0.phaseTrail[i].done = true }
            }
        }
    }

    /// 发送链路乐观置位（幂等，per-session）：本会话流式或待回复进行中不动。
    /// origin 非空时同步登记发起上下文（streamContexts）：待回复窗口（提示词
    /// 组装等前置往返）即计入 isVersionBusy，防「占位期版本判空闲」竞态。
    func beginPreparingReply(sessionID: String, origin: StreamOrigin? = nil) {
        if let origin { registerStreamContext(origin) }
        guard streams[sessionID]?.isStreaming != true,
              streams[sessionID]?.isPreparing != true else { return }
        mutateStream(sessionID) { $0.isPreparing = true }
    }

    /// 清除待回复态（per-session，缺省 = 当前会话）：开流转正 / 停止 / 错误 /
    /// 闸口早退路径统一收口；空态键随之移除。
    func endPreparingReply(sessionID: String? = nil) {
        mutateStream(sessionID ?? sessionId) { $0.isPreparing = false }
    }

    /// 流式期间（含待回复期）插话（AppModel.sendMessage 分流入口；调用方保证在
    /// 发起会话内）：入队即返回，不打断当前生成；条目进**当前会话**队列，
    /// 待回复期入队的插话在流开启的首个边界统一注入。空闲时调用是 no-op。
    func enqueueSteering(_ text: String) {
        guard isSessionBusy(sessionId) else { return }
        steeringQueues[sessionId, default: []].append(makeEntry(role: .user, content: text))
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

    /// 进行中的生成任务（per-session，send/sendSystemTurn 内部经 trackGeneration
    /// 包裹，key = sessionId）；nil = 该会话空闲。持有句柄是唯一可靠的取消通道——
    /// 调用方 Task 散落在各视图/编排层，无法回收。
    private var generationTasks: [String: (task: Task<Void, Never>, token: UUID)] = [:]

    /// 用户主动停止指定会话（缺省 = 当前会话）的生成：**同步**翻转该会话流式状态
    /// （发送钮 ≤300ms 内回「发送」、流式气泡即时收起、侧栏呼吸点即时熄灭），
    /// 再取消底层网络流。已生成的部分内容由 streamReply 的取消收尾路径保留落盘
    /// （含「⏹ 已停止」注记）。插话语义是「补指令给当前生成」——停止即一并作废
    /// （该会话排队气泡消失，不落盘）；其他会话的流态/队列/任务不受影响。
    func stopGeneration(sessionID: String? = nil) {
        let id = sessionID ?? sessionId
        endPreparingReply(sessionID: id)  // 待回复占位一并收起（此时生成任务可能尚未起跑）
        if let handle = generationTasks.removeValue(forKey: id) {
            handle.task.cancel()
        }
        streamBoxes[id] = nil  // 该会话流态整体收起（含增量/重试行/阶段文案）
        streamContexts[id] = nil  // 发起上下文登记一并注销（与流态键同生命周期）
        steeringQueues[id] = nil
        followUpQueues[id] = nil
    }

    /// 生成任务追踪（可停止句柄的来源，per-session）：send/sendSystemTurn 的实际
    /// 工作包在其中。sessionID 缺省 = 当前会话（测试直驱用）。internal 供测试
    /// （停止延迟 ≤300ms 断言直测）。
    func trackGeneration(sessionID: String? = nil, _ operation: @escaping () async -> Void) async {
        let id = sessionID ?? sessionId
        let token = UUID()
        let task = Task { await operation() }
        generationTasks[id] = (task, token)
        await task.value
        // 句柄仍指向本任务时才清空（停止 → 立即重发的新任务不被旧收尾误清）
        if generationTasks[id]?.token == token { generationTasks[id] = nil }
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
        knowledgeRefs: [String: String]? = nil,
        phaseTrail: [String]? = nil,
        toolSteps: [ThinkData.Step] = [],
        sessionId: String
    ) -> (assistant: DiscussionEntry?, note: DiscussionEntry) {
        let thinkData = ThinkData.from(
            reasoning: reasoning, duration: duration,
            skills: skills, toolSteps: toolSteps,
            knowledgeRefs: knowledgeRefs,
            phaseTrail: phaseTrail
        )
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

    /// 某 project/version 下全部会话（固定按创建时间倒序，2026-09-22 用户决策）。
    nonisolated static func sessions(in project: String, version: String) -> [SessionSummary] {
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
        let all = PMAgentStore.readLines(DiscussionEntry.self, from: url)
        var bySession: [String: [DiscussionEntry]] = [:]
        for entry in all { bySession[entry.sessionId, default: []].append(entry) }

        // 固定按创建时间倒序（首条 entry 时间降序，新的在前，与项目排序同口径）
        // ——不随最近活跃跳位；discussions.jsonl append-only，entries 即追加序，
        // 首条即最早。createdAt 为 ISO8601 字符串，字典序 == 时间序（与 lastActiveAt 同约定）。
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
            .sorted { $0.1 > $1.1 }
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

    // MARK: - 会话标记（草稿预演等，B1；独立 session-flags.json，与标题覆盖互不影响）

    /// 会话级标记（草稿预演）：draft = 草稿预演会话；draftStage = 预演推进位置
    ///（PipelineRun.Stage rawValue）。独立文件存储——session-meta.json 保持
    /// [String: String] 标题表不变量，旧版本 App 互不干扰。
    nonisolated struct SessionFlags: Codable, Equatable {
        var draft: Bool?
        var draftStage: String?
    }

    nonisolated static func sessionFlagsURL(project: String, version: String) -> URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "session-flags.json")
    }

    nonisolated static func sessionFlags(project: String, version: String) -> [String: SessionFlags] {
        let url = sessionFlagsURL(project: project, version: version)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SessionFlags].self, from: data)) ?? [:]
    }

    nonisolated static func flags(
        ofSession sessionId: String, project: String, version: String
    ) -> SessionFlags {
        sessionFlags(project: project, version: version)[sessionId] ?? SessionFlags()
    }

    /// 覆盖写单会话标记（读-改-写整表，原子落盘；MainActor 调用方串行）。
    nonisolated static func setFlags(
        _ flags: SessionFlags, forSession sessionId: String,
        project: String, version: String
    ) throws {
        var table = sessionFlags(project: project, version: version)
        if flags == SessionFlags() {
            table[sessionId] = nil  // 空标记不留键（删会话/退出草稿后目录干净）
        } else {
            table[sessionId] = flags
        }
        try JSONEncoder().encode(table).write(
            to: sessionFlagsURL(project: project, version: version), options: .atomic
        )
    }

    /// 是否草稿预演会话。
    nonisolated static func isDraftSession(
        project: String, version: String, sessionId: String
    ) -> Bool {
        flags(ofSession: sessionId, project: project, version: version).draft == true
    }

    /// 草稿预演推进位置（非草稿会话返回 nil）。
    nonisolated static func draftStage(
        project: String, version: String, sessionId: String
    ) -> PipelineRun.Stage? {
        let f = flags(ofSession: sessionId, project: project, version: version)
        guard f.draft == true else { return nil }
        return f.draftStage.flatMap { PipelineRun.Stage(rawValue: $0) } ?? .clarify
    }

    /// 标记/取消草稿预演（取消时清推进位置）。返回错误文案，nil = 成功。
    nonisolated static func setDraft(
        project: String, version: String, sessionId: String, isDraft: Bool
    ) -> String? {
        var f = flags(ofSession: sessionId, project: project, version: version)
        f.draft = isDraft ? true : nil
        if !isDraft { f.draftStage = nil }
        do {
            try setFlags(f, forSession: sessionId, project: project, version: version)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 草稿预演推进位置前移（产物落盘成功后调用；非草稿会话 no-op）。
    nonisolated static func advanceDraftStage(
        project: String, version: String, sessionId: String, to stage: PipelineRun.Stage
    ) {
        var f = flags(ofSession: sessionId, project: project, version: version)
        guard f.draft == true else { return }
        f.draftStage = stage.rawValue
        try? setFlags(f, forSession: sessionId, project: project, version: version)
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
        // 冷启动恢复压缩缓存（P2，阶段 2 per-session 键值化）：取本会话最近一条
        // 压缩行，恢复滚动摘要三元组到该会话的键，s08 压缩从上次边界无缝续跑
        //（不重算已摘要轮）。无压缩行 → 该键清空（磁盘是事实源）。
        if let last = entries.last(where: { $0.compaction != nil }),
           let data = last.compaction {
            compactions[sessionId] = CompactionCache(
                summary: data.summary, boundary: data.boundary, count: data.droppedCount
            )
        } else {
            compactions[sessionId] = nil
        }
        // 流态按会话键隔离（streams[sessionId]）：增量/占位/阶段文案只在其归属
        // 会话渲染，切会话互不泄漏——旧单流时代需在此手动清全局增量，键值化后
        // 天然隔离；他会话进行中的流态保留在键里，切回仍可见（流收尾 defer 移除键）。
    }

    /// 任意会话的只读投影（origin 化基建）：按 (project, version) 读盘、按 sessionId
    /// 过滤。内存 entries 只驻当前打开会话（open 仅加载当前会话），异步链中途
    /// 需要 origin 会话内容（上下文组装/历史）时从这里读盘取——磁盘是事实源。
    func entries(project: String, version: String, sessionId: String) -> [DiscussionEntry] {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        return PMAgentStore.readLines(DiscussionEntry.self, from: url)
            .filter { $0.sessionId == sessionId }
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

    /// 撤回乐观上屏的待发送消息（采纳排队逃生门等）：仅从内存消息流移除——
    /// 此类条目从未落盘，无磁盘动作；已落盘的条目不走这里。
    func discardStaged(_ entry: DiscussionEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    /// 按发起会话上下文落盘（流式回复/后台完成落盘段专用）：写到 origin 的 jsonl，
    /// 内存收纳仍以「属于当前打开会话」为准（按 id 去重，同 append）。
    func appendPinned(_ entry: DiscussionEntry, origin: StreamOrigin) throws {
        let url = PMAgentStore.jsonlURL(
            project: origin.project, version: origin.version, file: "discussions.jsonl"
        )
        try appendVerified(entry, to: url)
        if entry.sessionId == sessionId, !entries.contains(where: { $0.id == entry.id }) {
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

    /// - Parameter sessionID: 条目归属会话（nil = 当前打开会话）。后台完成落盘段
    ///   传 origin.sessionId，让系统行钉回发起会话（即使该会话不在前台）。
    func makeEntry(
        role: DiscussionEntry.Role,
        content: String,
        think: ThinkData? = nil,
        memory: MemoryEntry? = nil,
        images: [String]? = nil,
        files: [String]? = nil,
        fileChanges: [FileChangeSummary]? = nil,
        milestones: [MilestoneStamp]? = nil,
        changeProposal: ChangeProposalRecord? = nil,
        silent: Bool? = nil,
        sessionID: String? = nil
    ) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionID ?? sessionId,
            role: role,
            content: content,
            think: think,
            memory: memory,
            images: images,
            files: files,
            fileChanges: fileChanges,
            milestones: milestones,
            changeProposal: changeProposal,
            silent: silent,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - 流式发送（M2：阶段化 system prompt + 思考捕获）

    /// 发送用户消息并流式接收回复；完成后整条落盘（流式期间 UI 由本会话流态
    /// streams[origin.sessionId].text 驱动）。
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
    ///   - knowledgeRefs: 本轮注入的知识卡命中（id→标题；气泡底部引用条，2026-09-17）
    ///   - pinnedOrigin: 发起上下文快照（nil = 入口现取）。AppModel 发送链在提示词
    ///     组装（网络往返）前快照下传——往返期间用户切会话/项目时 origin 不漂移。
    ///   - prototypeSnapshot: 原型冲突检测快照（阶段 4，相对路径 → 期望 SHA256）。
    ///     发起时槽位文件的指纹，随发送链下传并经 onAssistant 回调透传给编排层
    ///     落盘段做乐观校验（后写者分槽并立）。仅原型阶段生效——performSend 内
    ///     按 stage 闸死，非原型阶段误传也强制失效。回调第二参数即本值。
    ///   - tools: Function Calling 工具运行时（nil = 未启用，行为与旧版一致）。
    ///   - onAssistant: 回复完成后的回调（产物解析、轮次推进等由编排层处理）；
    ///     第二参数为本轮生效的原型快照（非原型阶段 / followUp 续发轮为 nil）
    func send(
        _ text: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 16384,
        imageFiles: [String] = [],
        fileRefs: [String] = [],
        skills: [String] = [],
        knowledgeRefs: [String: String]? = nil,
        stagedUserEntry: DiscussionEntry? = nil,
        pinnedOrigin: StreamOrigin? = nil,
        prototypeSnapshot: [String: String]? = nil,
        tools: AgentToolRuntime? = nil,
        thinkingEffortOverride: ThinkingEffort? = nil,
        onAssistant: ((DiscussionEntry, [String: String]?) -> Void)? = nil
    ) async {
        // 打包进可取消句柄（stopGeneration 的取消来源，按发起会话登记）；仍 await
        // 完成，调用方语义不变。origin 优先用调用方快照（链入口钉定），缺省入口
        // 现取：句柄键与流态键同源，生成途中用户切会话不漂移。
        let origin = pinnedOrigin ?? StreamOrigin(project: project, version: version, sessionId: sessionId)
        await self.trackGeneration(sessionID: origin.sessionId) {
            await self.performSend(
                text, settings: settings, stage: stage, systemPrompt: systemPrompt,
                maxTokens: maxTokens, imageFiles: imageFiles, fileRefs: fileRefs,
                skills: skills, knowledgeRefs: knowledgeRefs,
                stagedUserEntry: stagedUserEntry, onAssistant: onAssistant, origin: origin,
                prototypeSnapshot: prototypeSnapshot, tools: tools,
                thinkingEffortOverride: thinkingEffortOverride
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
        knowledgeRefs: [String: String]? = nil,
        stagedUserEntry: DiscussionEntry? = nil,
        onAssistant: ((DiscussionEntry, [String: String]?) -> Void)?,
        origin: StreamOrigin,
        prototypeSnapshot: [String: String]? = nil,
        tools: AgentToolRuntime? = nil,
        thinkingEffortOverride: ThinkingEffort? = nil
    ) async {
        // 阶段 4 原型快照：仅原型回合生效（非原型阶段调用方误传也强制失效，防误校验）。
        // followUp 续发轮不带快照（drainFollowUps 不透传，下方调用缺省 nil）——
        // 首轮自写盘后快照必然失配，续发迭代轮落主槽位是正常迭代语义
        //（v1 边界：续发窗口内外部写入不检测）。
        let effectiveSnapshot = stage == .prototype ? prototypeSnapshot : nil
        // origin 已由调用方快照下传（send 入口 / drainFollowUps / AppModel 链入口）：
        // 生成途中用户可能切换会话/项目，回复与历史组装必须以发起上下文为准
        //（否则串会话/串版本），回调也按后台完成语义执行（AppModel 以 origin 口径落盘）。
        // 待回复占位（幂等）：AppModel.sendMessage 已随乐观上屏置位——此处兜住
        // followUp 续发等未经该入口的调用方，覆盖 buildHistory 压缩摘要的网络往返。
        // 占位置位即登记发起上下文（版本级 busy 判据数据源，与流态键同生命周期）。
        beginPreparingReply(sessionID: origin.sessionId, origin: origin)
        do {
            // 乐观上屏通道：调用方已提前入列的用户条目原样落盘（同 id 不重复上屏）；
            // 未走该通道的调用方（followUps 续发 / 系统链路）照旧在此构造。
            // 条目归属与落盘位置一律钉 origin（makeEntry 缺省取当前会话，切走后即错）。
            var userEntry = stagedUserEntry ?? makeEntry(
                role: .user, content: text,
                images: imageFiles.isEmpty ? nil : imageFiles,
                files: fileRefs.isEmpty ? nil : fileRefs
            )
            userEntry.sessionId = origin.sessionId
            try appendPinned(userEntry, origin: origin)

            // 前缀缓存改造（2026-09-17，ContextTail 协议）：systemPrompt 可能是
            // 「冻结段 + marker + 动态材料」复合体——拆开后冻结段进 system 消息，
            // 动态材料与引用文件正文合并为「动态材料尾条」，以独立 user 消息追加在
            // 当前用户消息之后。system 与历史随之成为 append-only 可缓存前缀
            //（记忆/技能/检索每轮变化曾嵌入 system 中部，使其后历史连坐失效）。
            // 引用文件正文按 origin 版本目录读盘（切走后读当前版本会注错内容）。
            let (frozenSystem, injectionTail) = ContextTail.split(systemPrompt)
            let fileSection = ReferencedFileMaterial.section(
                refs: fileRefs, project: origin.project, version: origin.version
            )
            let tail = [injectionTail, fileSection ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            var history = await buildHistory(origin: origin, systemPrompt: frozenSystem, settings: settings)
            // 当轮 user 消息带图：进模型前从 attachments/ 读回并编码为 base64（origin 口径）
            if !imageFiles.isEmpty,
               let config = settings.stages[stage], config.supportsImages {
                let chatImages = imageFiles.compactMap { name -> ChatImage? in
                    guard let data = PMAgentStore.readAttachment(
                        name, project: origin.project, version: origin.version
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
            // 动态材料尾条：追加在当前用户消息之后（离生成点最近——材料遵循度受益于
            // 近因注意力；永不入盘、不占历史预算，投影回灌天然不含它）
            history = VolatileTailMaterial.appending(history, tail: tail)
            try await streamReply(
                origin: origin, history: history, stage: stage, settings: settings,
                maxTokens: maxTokens, skills: skills, knowledgeRefs: knowledgeRefs,
                tools: tools, thinkingEffortOverride: thinkingEffortOverride,
                onAssistant: onAssistant.map { fn in
                    { entry in fn(entry, effectiveSnapshot) }
                }
            )
            // 正常完成后消费 followUp 队列（P3）：插话续发走完整发送链路。
            // 停止（stopGeneration 清队列 + 任务取消）与错误路径不消费。
            await drainFollowUps(
                origin: origin, settings: settings, stage: stage,
                systemPrompt: systemPrompt, maxTokens: maxTokens, onAssistant: onAssistant
            )
        } catch {
            endPreparingReply(sessionID: origin.sessionId)  // 流式开启前即失败：占位气泡必须收起
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
            // 错误收尾：本会话排队中的插话一并作废（用户重发即可），流态清零只动本 key，
            // 避免半途状态残留
            steeringQueues[origin.sessionId] = nil
            followUpQueues[origin.sessionId] = nil
            mutateStream(origin.sessionId) {
                $0.text = ""
                $0.think = ""
                $0.skills = []
                $0.phaseTrail = []
                $0.startedAt = nil
            }
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
    /// - Parameter pinnedOrigin: 发起上下文快照（nil = 入口现取）。确认链多跳 LLM
    ///   往返期间用户可能切会话/项目——AppModel 在链入口快照一次全链下传，
    ///   防中途漂移到切换后会话（phase 文案/流态/落盘同源）。
    /// - Parameter prototypeSnapshot: 原型冲突检测快照（阶段 4，同 send；确认链 /
    ///   机器门重生成 / 回退重做等系统触发的原型生成回合照常携带）。
    @discardableResult
    func sendSystemTurn(
        note: String?,
        noteSilent: Bool = false,
        userPrompt: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int = 16384,
        skills: [String] = [],
        pinnedOrigin: StreamOrigin? = nil,
        prototypeSnapshot: [String: String]? = nil,
        tools: AgentToolRuntime? = nil,
        onAssistant: ((DiscussionEntry, [String: String]?) -> Void)? = nil
    ) async -> SystemTurnOutcome {
        var outcome = SystemTurnOutcome.interrupted
        // 发起会话快照下传：句柄键与流态键同源（同 send），生成途中切会话不漂移
        let origin = pinnedOrigin ?? StreamOrigin(project: project, version: version, sessionId: sessionId)
        // 打包进可取消句柄（stopGeneration 的取消来源）
        await self.trackGeneration(sessionID: origin.sessionId) {
            outcome = await self.performSendSystemTurn(
                note: note, noteSilent: noteSilent, userPrompt: userPrompt, settings: settings,
                stage: stage, systemPrompt: systemPrompt, maxTokens: maxTokens, skills: skills,
                onAssistant: onAssistant, origin: origin,
                prototypeSnapshot: prototypeSnapshot, tools: tools
            )
        }
        return outcome
    }

    private func performSendSystemTurn(
        note: String?,
        noteSilent: Bool = false,
        userPrompt: String,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int,
        skills: [String],
        onAssistant: ((DiscussionEntry, [String: String]?) -> Void)?,
        origin: StreamOrigin,
        prototypeSnapshot: [String: String]? = nil,
        tools: AgentToolRuntime? = nil
    ) async -> SystemTurnOutcome {
        // 阶段 4 原型快照闸（同 performSend）：仅原型回合生效
        let effectiveSnapshot = stage == .prototype ? prototypeSnapshot : nil
        // 开流即登记发起上下文（版本级 busy 判据数据源，与流态键同生命周期）
        registerStreamContext(origin)
        mutateStream(origin.sessionId) {
            $0.isStreaming = true  // 先置位：注记行直接并入流式气泡，避免「独立胶囊 → 并入」闪烁
            $0.startedAt = Date()
        }
        do {
            if let note {
                // 回合注记钉回发起会话（链中途切会话不串：落盘也走 origin 的 jsonl）
                // noteSilent：注记语义已由 AI 回答开场承接句承载时，落盘静默、UI 不渲染
                var noteEntry = makeEntry(role: .system, content: note, silent: noteSilent ? true : nil)
                noteEntry.sessionId = origin.sessionId
                try appendPinned(noteEntry, origin: origin)
            }

            // 前缀缓存改造（2026-09-17）：冻结段进 system，动态材料尾条追加在
            // 合成 userPrompt 之后（同 performSend，ContextTail 协议）
            let (frozenSystem, injectionTail) = ContextTail.split(systemPrompt)
            var history = await buildHistory(origin: origin, systemPrompt: frozenSystem, settings: settings)
            history.append(ChatMessage(role: .user, content: userPrompt))
            history = VolatileTailMaterial.appending(history, tail: injectionTail)
            try await streamReply(
                origin: origin, history: history, stage: stage, settings: settings,
                maxTokens: maxTokens, skills: skills, tools: tools,
                onAssistant: onAssistant.map { fn in
                    { entry in fn(entry, effectiveSnapshot) }
                }
            )
            // 正常完成后消费 followUp 队列（P3）；完成后才记 .completed
            await drainFollowUps(
                origin: origin, settings: settings, stage: stage,
                systemPrompt: systemPrompt, maxTokens: maxTokens, onAssistant: onAssistant
            )
            return .completed
        } catch {
            // streamReply 未进入即抛错（如历史组装失败）时其 defer 不执行，此处兜底清流起点
            mutateStream(origin.sessionId) { $0.isStreaming = false; $0.startedAt = nil }
            // 用户主动停止（流式开始前的取消）：只落「⏹ 已停止」注记，不写 ⚠️ 错误行
            if Self.isCancellation(error) {
                let stopped = Self.makeStoppedTurn(
                    partial: "", reasoning: "", duration: 0, skills: [],
                    sessionId: origin.sessionId
                )
                try? appendPinned(stopped.note, origin: origin)
                return .interrupted
            }
            // 错误收尾：本会话排队中的插话一并作废（用户重发即可），流态清零只动本 key，
            // 避免半途状态残留
            steeringQueues[origin.sessionId] = nil
            followUpQueues[origin.sessionId] = nil
            mutateStream(origin.sessionId) {
                $0.text = ""
                $0.think = ""
                $0.skills = []
                $0.phaseTrail = []
                $0.startedAt = nil
            }
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

    /// 消费该会话的 followUp 队列：逐条作为新输入走完整发送链路（落盘 user 条目 +
    /// 历史组装 + 流式回复）。调用方已在可取消句柄内，不再经 trackGeneration。
    /// 续发轮携带原 origin（origin.sessionId = 原会话），跨上下文也按 origin 落盘。
    /// 续发轮出错时 performSend 内部已清该会话队列，循环自然终止。
    /// （阶段 2 收口：续发闸从「用户仍停留发起上下文」改为「目标会话空闲」——
    /// 历史按 origin 读盘、落盘按 origin 钉回后，跨上下文续发已安全；会话有流/
    /// 占位进行中（如用户已在该会话手动发起新回合）则保留队列本轮不消费，
    /// 待该会话下一次收尾的 drainFollowUps 续接，避免并发流互踩。）
    private func drainFollowUps(
        origin: StreamOrigin,
        settings: LLMSettings,
        stage: LLMStage,
        systemPrompt: String,
        maxTokens: Int,
        onAssistant: ((DiscussionEntry, [String: String]?) -> Void)?
    ) async {
        while let pending = followUpQueues[origin.sessionId], !pending.isEmpty,
              !Task.isCancelled {
            guard !isSessionBusy(origin.sessionId) else { return }
            followUpQueues[origin.sessionId] = nil
            let text = pending.map(\.content).joined(separator: "\n\n")
            await performSend(
                text, settings: settings, stage: stage, systemPrompt: systemPrompt,
                maxTokens: maxTokens, imageFiles: [], fileRefs: [],
                skills: [], onAssistant: onAssistant, origin: origin
            )
        }
    }

    /// 历史压缩摘要缓存（s08 滚动压缩，阶段 2 per-session 键值化）：被丢旧轮摘要
    /// 一次、缓存复用；边界移动时只摘要新增被丢轮（旧摘要 + 新轮 → 更新摘要），
    /// 不全量重算。按 sessionId 分键——后台流与前台流各有各的压缩游标，互不覆盖。
    /// internal 供单测驱动（分键不串的关键锚点）。
    var compactions: [String: CompactionCache] = [:]

    /// 单会话压缩缓存三元组（值类型，键入 compactions）。
    struct CompactionCache {
        var summary: String
        var boundary: String
        var count: Int
    }

    /// 历史组装（origin 口径）对外入口：先走 assembledHistory 编排投影/预算/压缩，
    /// 再按门控收敛思考回传（只挂最后一轮，见 keepRecentReasoning）。
    func buildHistory(
        origin: StreamOrigin, systemPrompt: String, settings: LLMSettings
    ) async -> [ChatMessage] {
        let replay = Self.replaysReasoning(settings: settings)
        let messages = await assembledHistory(
            origin: origin, systemPrompt: systemPrompt, settings: settings,
            replayReasoning: replay
        )
        guard replay else { return messages }
        return HistoryProjection.keepRecentReasoning(in: messages)
    }

    /// 历史思考回传门控（2026-09-18，借鉴 opencode / OpenHands 双印证）：
    /// DeepSeek 端点多轮对话回传历史 reasoning_content，维持思考连贯、免每轮
    /// 重新推敲上轮已想清的结论（对应个案分析里的复读复述与对账空转）。
    /// 其他 provider 暂不回传（GLM/豆包思考协议不同，白名单按需扩展）；
    /// 非思考轮 think 为空天然无回传，门控只需圈定端点族。纯函数，测试直测。
    nonisolated static func replaysReasoning(settings: LLMSettings) -> Bool {
        settings.chatConfig.provider == "deepseek"
    }

    /// 分块压缩阈值（2026-09-18，借鉴 OpenHands Condenser 摊薄缓存重建成本）：
    /// 新增被丢轮不足该 token 数时暂缓滚动摘要——新被丢轮以原文垫在旧摘要之后，
    /// system+摘要+稳定历史保持 append-only，前缀缓存持续命中；积累满一块才做
    /// 一次摘要（缓存重建从「超预算后每轮一次」摊薄为「每块一次」）。
    nonisolated static let compactionDeferralTokens = 3000

    /// 是否暂缓滚动压缩（纯函数，测试直测）：仅当确实新增了被丢轮且增量不足一块。
    nonisolated static func shouldDeferCompaction(
        droppedCount: Int, cachedCount: Int, newDroppedTokens: Int
    ) -> Bool {
        droppedCount > cachedCount && newDroppedTokens < compactionDeferralTokens
    }

    /// 历史组装编排：条目来源按 origin 归属——当前打开会话用内存投影；
    /// 否则读盘该 (project, version) 的 jsonl 过滤 origin.sessionId（后台会话/跨上下文
    /// 续发轮的历史不再错拿前台会话）。投影管道与预算裁剪不变。internal 供单测驱动。
    private func assembledHistory(
        origin: StreamOrigin, systemPrompt: String, settings: LLMSettings,
        replayReasoning: Bool
    ) async -> [ChatMessage] {
        // 投影管道（HistoryProjection）：entries → LLM 消息 → 预算裁剪 → 摘要垫头
        let sourceEntries: [DiscussionEntry]
        if origin.sessionId == sessionId {
            sourceEntries = entries
        } else {
            sourceEntries = Self.readSessionEntries(
                project: origin.project, version: origin.version, sessionId: origin.sessionId
            )
        }
        let history = [ChatMessage(role: .system, content: systemPrompt)]
            + HistoryProjection.projectEntries(sourceEntries, replayReasoning: replayReasoning)
        let (kept, dropped) = HistoryProjection.splitByBudget(history, budget: historyTokenBudget)
        guard !dropped.isEmpty else { return kept }

        // 摘要缓存命中：边界未变直接复用（per-session 键）
        let boundary = HistoryProjection.droppedBoundary(dropped)
        let cache = compactions[origin.sessionId]
        if let cache, boundary == cache.boundary, !cache.summary.isEmpty {
            return HistoryProjection.historyWithSummary(kept: kept, summary: cache.summary)
        }

        // 分块暂缓（借鉴 OpenHands Condenser）：边界小幅移动时复用旧摘要，
        // 新被丢轮原文垫头——前缀字节级不变保住缓存，满一块才滚动摘要一次
        let base = min(cache?.count ?? 0, dropped.count)
        let newDropped = dropped.dropFirst(base)
        if let cache, !cache.summary.isEmpty,
           Self.shouldDeferCompaction(
               droppedCount: dropped.count, cachedCount: cache.count,
               newDroppedTokens: TokenBreakdown.estimate(
                   newDropped.map(\.content).joined(separator: "\n")
               )
           ) {
            return HistoryProjection.historyWithSummary(
                kept: kept, summary: cache.summary, bridging: Array(newDropped)
            )
        }

        // 滚动压缩：旧摘要 + 新增被丢轮 → 一次性 LLM 摘要（classify 档）
        let transcript = newDropped
            .map { "\($0.role == .user ? "用户" : "助手")：\($0.content)" }
            .joined(separator: "\n")
        if let updated = try? await oneShot(
            HistoryProjection.compactSummaryPrompt(
                previous: cache?.summary ?? "", transcript: String(transcript.suffix(12000))
            ),
            settings: settings, stage: .classify, maxTokens: 800
        ), !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summary = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            compactions[origin.sessionId] = CompactionCache(
                summary: summary, boundary: boundary, count: dropped.count
            )
            // 压缩结果落盘（P2）：role == .system 注记行 + CompactionData 载荷，
            // 冷启动恢复缓存、Finder 可读。写盘失败不阻塞主流程。
            // origin 直用 buildHistory 收到的快照（阶段 2 修 originForHistory 实时读 bug）：
            // 历史组装期间用户切会话，压缩行仍落回发起会话。
            saveCompaction(
                summary: summary, boundary: boundary, droppedCount: dropped.count,
                tokensBefore: TokenBreakdown.estimate(
                    history.map(\.content).joined(separator: "\n")
                ),
                origin: origin
            )
            return HistoryProjection.historyWithSummary(kept: kept, summary: summary)
        }
        // 摘要失败（模型不可用等）：有旧摘要时降级为「旧摘要 + 新被丢轮原文垫头」
        //（优于旧行为的纯丢弃——纯丢弃连旧摘要一起丢，前情全失）；无旧摘要维持纯丢弃
        if let cache, !cache.summary.isEmpty {
            return HistoryProjection.historyWithSummary(
                kept: kept, summary: cache.summary, bridging: Array(newDropped)
            )
        }
        return kept
    }

    /// 读盘指定 (project, version) 会话条目（buildHistory 的后台会话来源）：
    /// nonisolated 静态读盘，不触碰 MainActor 状态。读不到（新会话尚无 jsonl）
    /// 按空历史处理——发送链先 append 用户条目，ensureWorkspace 已由调用链保障。
    nonisolated static func readSessionEntries(
        project: String, version: String, sessionId: String
    ) -> [DiscussionEntry] {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        return PMAgentStore.readLines(DiscussionEntry.self, from: url)
            .filter { $0.sessionId == sessionId }
    }

    /// 压缩摘要落盘（P2）：追加 role == .system 的压缩注记行——content = 注记头 +
    /// 摘要全文（UI 渲染压缩卡片、Finder 可读），compaction 载荷存恢复元数据。
    /// internal 供单测回归（origin 钉定：落盘条目 sessionId == origin.sessionId）。
    func saveCompaction(
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

    /// 流式请求的思考强度取值优先级（纯函数，测试直测）：空流重试位 > 本轮覆盖位
    /// （寒暄轻量轮压 low）> 用户在 Composer 选的档位（默认 high = 不发参走服务端默认）。
    /// 覆盖位须排在用户位**之前**——轻量轮要压 low，不能被界面上仍显示 High 的档位
    /// 顶回去；但空流重试的强制 low 仍须压过一切。
    nonisolated static func resolvedStreamEffort(
        retry: ThinkingEffort?, override: ThinkingEffort?, userDefault: ThinkingEffort
    ) -> ThinkingEffort {
        retry ?? override ?? userDefault
    }

    private func streamReply(
        origin: StreamOrigin,
        history: [ChatMessage],
        stage: LLMStage,
        settings: LLMSettings,
        maxTokens: Int,
        skills: [String] = [],
        knowledgeRefs: [String: String]? = nil,
        tools: AgentToolRuntime? = nil,
        thinkingEffortOverride: ThinkingEffort? = nil,
        onAssistant: ((DiscussionEntry) -> Void)?
    ) async throws {
        // 开流转正：本会话待回复占位无缝切换为真实流式态（归属由 key 承载）
        mutateStream(origin.sessionId) {
            $0.isStreaming = true
            $0.isPreparing = false
            $0.text = ""
            $0.think = ""
            $0.skills = skills
        }
        let startedAt = Date()
        // 提速归因（2026-09-18）：轮次 id 贯穿 usage/probe——同一轮的多次请求
        //（空流重试/续写）与 App 侧时间线可对齐；start 探针 = 组装完成、流即将开启
        //（与用户消息 createdAt 的差值 = 组装/排队耗时）
        let roundId = UUID().uuidString
        mutateStream(origin.sessionId) { $0.startedAt = startedAt }
        StreamProbe.shared.append([
            "side": "app-start", "roundId": roundId,
            "stage": stage.rawValue, "ts": startedAt.timeIntervalSince1970,
        ])
        defer {
            // 只清本 key（含占位/重试行/阶段文案/增量），他会话并发流不受影响；
            // 发起上下文登记一并注销（与流态键同生命周期，防泄漏）
            streamBoxes[origin.sessionId] = nil
            streamContexts[origin.sessionId] = nil
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
        // Function Calling 工具循环状态（nil = 未启用，零开销走旧路径）
        var toolRounds = 0            // 已执行的工具轮数（上限 ToolLoopPolicy.maxToolRounds）
        var noMoreTools = false       // 超限后摘除 tools，强制模型直答
        var pendingToolCalls: [LLMToolCall] = []  // 本轮流结束时累积到的工具调用组
        var toolSteps: [ThinkData.Step] = []      // 思考卡工具行（流中 + 落盘共用）
        // 临时探针（2026-09-18）：App 侧消费/发布节奏（见 StreamProbe 注释）
        var probeConsume: [Double] = []
        var probePubs: [[String: Any]] = []
        var probeEvents: [[String: Any]] = []
        do {
            while !Task.isCancelled {
                probeEvents.append(["t": Date().timeIntervalSince(startedAt), "ev": "round-start"])
                // steering 注入（P3）：截断续写边界——当前流已结束、下一次 LLM 调用前。
                // 插话此刻落盘（排队气泡转正）并进入续写上下文（本会话队列）。
                if let pending = steeringQueues[origin.sessionId], !pending.isEmpty {
                    steeringQueues[origin.sessionId] = nil
                    for msg in pending {
                        try? appendPinned(msg, origin: origin)
                        messages.append(ChatMessage(role: .user, content: msg.content))
                    }
                }
                let stream = try LLMClient.streamChat(
                    stage: stage, settings: settings, messages: messages, maxTokens: retryBudget,
                    reasoningEffort: Self.resolvedStreamEffort(
                        retry: retryEffort, override: thinkingEffortOverride,
                        userDefault: thinkingEffort
                    ).apiValue,
                    roundId: roundId,
                    tools: (tools != nil && !noMoreTools) ? tools!.registry.definitions() : nil
                )
                var truncated = false
                let roundStart = full.count
                do {
                    for try await delta in stream {
                        switch delta {
                        case .text(let text):
                            full += text
                            probeConsume.append(Date().timeIntervalSince(startedAt))
                            mutateStream(origin.sessionId) {
                                if $0.retry != nil { $0.retry = nil }
                                if textGate.shouldPublish() {
                                    // 展示文本 + 结构化产物事实都在发布点用全量 full
                                    // 算好（StreamDisplayPayload.make），识别链不再依赖
                                    // 被裁剪的展示文本
                                    let payload = StreamDisplayPayload.make(full: full)
                                    $0.text = payload.display
                                    $0.artifactBlocks = payload.blocks
                                    $0.inProgressName = payload.inProgressName
                                    $0.inProgressLines = payload.inProgressLines
                                    probePubs.append([
                                        "t": Date().timeIntervalSince(startedAt),
                                        "k": "t", "len": full.count,
                                    ])
                                }
                            }
                        case .reasoning(let chunk):
                            reasoning += chunk
                            probeConsume.append(Date().timeIntervalSince(startedAt))
                            mutateStream(origin.sessionId) {
                                if $0.retry != nil { $0.retry = nil }
                                if thinkGate.shouldPublish() {
                                    $0.think = StreamPublishTail.clip(reasoning, limit: StreamPublishTail.thinkChars)
                                    probePubs.append([
                                        "t": Date().timeIntervalSince(startedAt),
                                        "k": "r", "len": reasoning.count,
                                    ])
                                }
                            }
                        case .retrying(let code, let attempt):
                            // 瞬时故障自动重试中：气泡状态行（首次正文到达即清除）
                            probeEvents.append([
                                "t": Date().timeIntervalSince(startedAt),
                                "ev": "retrying", "code": code, "attempt": attempt,
                            ])
                            mutateStream(origin.sessionId) {
                                $0.retry = LLMClient.retryStatusText(code: code, attempt: attempt)
                            }
                        case .toolCalls(let calls):
                            pendingToolCalls = calls
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
                    probeEvents.append([
                        "t": Date().timeIntervalSince(startedAt),
                        "ev": "empty-after-thinking", "budget": retryBudget,
                    ])
                    continue
                } catch LLMClient.LLMError.emptyStream
                    where !Task.isCancelled && full.count == roundStart && emptyRetries < 1 {
                    // 字面空流（服务端抖动）重试（上限 1 次）：同请求重发。
                    emptyRetries += 1
                    probeEvents.append(["t": Date().timeIntervalSince(startedAt), "ev": "empty-stream"])
                    continue
                }
                // Function Calling 工具轮（优先于截断续写判断）：模型发起调用 →
                // 执行 → 结果回灌 → 继续下一轮生成。工具消息只进局部 messages
                //（不入盘、不进 HistoryProjection），思考卡工具行全程留痕。
                if !pendingToolCalls.isEmpty {
                    let calls = pendingToolCalls
                    pendingToolCalls = []
                    let overLimit = toolRounds >= ToolLoopPolicy.maxToolRounds
                    if overLimit {
                        noMoreTools = true  // 下一轮起摘除 tools，强制模型直答
                    } else {
                        toolRounds += 1
                    }
                    var results: [AgentToolResult] = []
                    for call in calls {
                        if Task.isCancelled { break }  // 停止语义：执行中取消即刻退出
                        probeEvents.append([
                            "t": Date().timeIntervalSince(startedAt),
                            "ev": "tool-execute", "tool": call.name, "over": overLimit,
                        ])
                        let result: AgentToolResult
                        if let tools, !overLimit {
                            result = await tools.registry.execute(
                                name: call.name, argumentsJSON: call.argumentsJSON,
                                ctx: tools.context
                            )
                        } else {
                            result = ToolLoopPolicy.limitExceededResult()
                        }
                        results.append(result)
                        toolSteps.append(ThinkData.Step(
                            text: nil, skill: nil, tool: call.name,
                            detail: result.forHuman, dur: nil
                        ))
                    }
                    mutateStream(origin.sessionId) { $0.toolSteps = toolSteps }
                    // 本轮 assistant 段文本（工具轮常零正文）随 tool_calls 回灌
                    let roundText = String(full[full.index(full.startIndex, offsetBy: roundStart)...])
                    messages.append(contentsOf: ToolLoopPolicy.followUpMessages(
                        assistantContent: roundText, calls: calls, results: results
                    ))
                    continue
                }
                guard truncated, continueRounds < 2 else { break }
                continueRounds += 1
                probeEvents.append([
                    "t": Date().timeIntervalSince(startedAt),
                    "ev": "trunc-continue", "round": continueRounds,
                ])
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
        // 本会话排队中的插话作为新输入自动续发，不丢失。停止路径（stopped）队列已清。
        if !stopped, let pending = steeringQueues[origin.sessionId], !pending.isEmpty {
            followUpQueues[origin.sessionId, default: []].append(contentsOf: pending)
            steeringQueues[origin.sessionId] = nil
        }

        // 终值补发（含停止路径）：节流窗口内的尾部 delta 也进 UI（紧随其后转正式条目并清空）。
        mutateStream(origin.sessionId) { $0.text = full; $0.think = reasoning }

        let duration = Int(Date().timeIntervalSince(startedAt))
        // 临时探针：App 侧消费/发布时间线落盘（相对轮起点的秒序列）
        StreamProbe.shared.append([
            "side": "app", "roundId": roundId,
            "ts": startedAt.timeIntervalSince1970,
            "stage": stage.rawValue, "durS": duration,
            "textChars": full.count, "thinkChars": reasoning.count,
            "consume": probeConsume, "pubs": probePubs, "events": probeEvents,
        ])
        // 确认链跳转历史快照（defer 清键前读取）：链式回合持久化全程跳标签，
        // 完成态展开恒可见（流式期打勾行只覆盖多跳链的第 2 跳起）
        let chainTrail = streams[origin.sessionId]?.phaseTrail.map(\.label)
        // 停止收尾/正常收尾共用同一构造：部分（或完整）内容原文保留、sessionId 钉回发起会话
        let stoppedTurn = Self.makeStoppedTurn(
            partial: full, reasoning: reasoning, duration: duration,
            skills: skills, knowledgeRefs: knowledgeRefs,
            phaseTrail: chainTrail, toolSteps: toolSteps, sessionId: origin.sessionId
        )
        if let assistantEntry = stoppedTurn.assistant {
            try appendPinned(assistantEntry, origin: origin)
        }
        mutateStream(origin.sessionId) { $0.text = ""; $0.think = "" }
        if stopped {
            // 「⏹ 已停止」注记：停止的唯一持久反馈（有无部分内容文案分两态）
            try? appendPinned(stoppedTurn.note, origin: origin)
        }
        // 完成回调（产物解析 / 阶段推进等编排副作用）——阶段 2 后台完成语义：
        // 自然完成（非停止/非错误）即回调，无论用户是否停留在发起会话。
        // AppModel 落盘段以 origin 口径执行（回复落盘已按 origin 钉回，回调再补
        // 产物解析/系统行/事件日志）；被停止的中途回合不回调——不得推进阶段或
        // 解析半截产物。旧门（origin.sessionId == 当前 sessionId）会漏掉后台
        // 完成的落盘段，产物只在用户恰好停留时才写盘。
        if !stopped, let assistantEntry = stoppedTurn.assistant {
            onAssistant?(assistantEntry)
        }
    }
}
