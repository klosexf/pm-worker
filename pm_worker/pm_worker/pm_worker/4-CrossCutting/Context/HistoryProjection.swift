//
//  HistoryProjection.swift
//  pm_worker
//
//  历史段投影管道（借鉴 pi-agent-core 的两级投影，design.md §6.4）：
//  ① projectEntries——应用态 entries → LLM 消息（系统行剔除 / 产物块剥离 /
//    附图与引用文件标注，即 convertToLlm 的应用投影）；
//  ② splitByBudget——预算内整轮保留、成对丢最旧（transformContext 的裁剪段）；
//  ③ historyWithSummary——被丢轮滚动摘要垫头（s08 摘要不归零）。
//  全部纯函数，SessionStore 只做编排（摘要的 LLM 调用与缓存仍在 SessionStore）。
//

import Foundation

/// 历史段投影管道（nonisolated：纯值变换，无 UI 状态）。
nonisolated enum HistoryProjection {

    // MARK: - ① 应用态 → LLM 消息投影

    /// discussions.jsonl 条目 → ChatMessage 序列（不含 system 段与预算裁剪）：
    /// - 系统行（胶囊/记忆行）不回灌模型；
    /// - assistant 产物块回灌时剥离（上下文里以说明代替大段源码，省 token）；
    /// - 历史附图不重发（多模态 token 昂贵）：文本标注代替，当轮图在 send() 里替换；
    /// - 引用文件正文只在该轮注入（不随历史重发）：标注路径供模型理解前后文；
    /// - replayReasoning（2026-09-18 思考回传）：assistant 轮携带落盘思考原文
    ///   （think.full），门控与「只留最后一轮」的收敛由 SessionStore 编排。
    static func projectEntries(
        _ entries: [DiscussionEntry], replayReasoning: Bool = false
    ) -> [ChatMessage] {
        entries.compactMap { entry -> ChatMessage? in
            guard entry.role != .system else { return nil }
            var content: String
            if entry.role == .assistant {
                // 先清洗占位模仿残留（模型照抄的剥离标注/落盘占位，可独立于真实
                // 产物块出现——伪造落盘声明形态），再剥离产物块回灌。
                content = ArtifactParser.scrubImitatedPlaceholders(in: entry.content)
                if ArtifactParser.parseArtifactBlocks(in: content).isEmpty == false {
                    // 占位文案必须不可模仿：默认占位「（产物已生成并落盘）」会被模型照抄进新回复、
                    // 伪造落盘声明（2026-09-15 实测）。回灌占位只做剥离说明 + 反模仿指令。
                    content = ArtifactParser.stripArtifactBlocks(
                        in: content,
                        placeholder: "【历史回复中的产物块已剥离省略——勿复述本标注；只有本轮实际输出完整产物块，才代表产物生成】"
                    )
                }
            } else {
                content = entry.content
            }
            if let images = entry.images, !images.isEmpty {
                content += "\n（本条附图 \(images.count) 张，回灌省略）"
            }
            if let files = entry.files, !files.isEmpty {
                content += "\n（本条引用了文件：\(files.joined(separator: "、"))；"
                    + "正文仅在该轮注入，未随历史回灌。）"
            }
            let reasoning = replayReasoning && entry.role == .assistant
                ? entry.think?.full.flatMap { $0.isEmpty ? nil : $0 }
                : nil
            return ChatMessage(
                role: roleOf(entry.role), content: content, reasoningContent: reasoning
            )
        }
    }

    private static func roleOf(_ role: DiscussionEntry.Role) -> ChatMessage.Role {
        switch role {
        case .user: .user
        case .assistant, .system: .assistant
        }
    }

    // MARK: - ② 预算裁剪

    /// 超预算成对丢最旧整轮（user → assistant 为一轮，保新丢旧不拆对）。
    /// 契约：首条 system（阶段 prompt）常驻不占历史预算；预算 ≤ 0 → 只剩 system
    /// （历史段整体让位，Context Builder 会把 .history 记入 trimmed）。
    static func trimmedHistory(
        _ messages: [ChatMessage], budget: Int
    ) -> [ChatMessage] {
        splitByBudget(messages, budget: budget).kept
    }

    /// 按预算切分（trimmedHistory 的伴生）：返回保留段与被丢段——被丢段供摘要压缩。
    static func splitByBudget(
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
    static func droppedBoundary(_ dropped: [ChatMessage]) -> String {
        guard let first = dropped.first, let last = dropped.last else { return "empty" }
        return "\(dropped.count)|\(first.content.prefix(64))|\(last.content.prefix(64))"
    }

    /// 思考回传收敛（2026-09-18）：只保留最后一条携带思考的 assistant 消息，
    /// 其余轮 reasoningContent 置空。历史预算按正文估算（TokenBreakdown），
    /// 全量回传会无界膨胀；且更早轮的结论已外化进产物与前情摘要，连贯价值
    /// 集中在最近一轮（修订轮直接续上前一版的推敲线）。纯函数，测试直测。
    static func keepRecentReasoning(in messages: [ChatMessage]) -> [ChatMessage] {
        guard let last = messages.lastIndex(where: { $0.reasoningContent != nil }) else {
            return messages
        }
        var result = messages
        for index in result.indices where index != last {
            result[index].reasoningContent = nil
        }
        return result
    }

    // MARK: - ③ 摘要垫头

    /// 摘要垫头：system 首条之后插一条 user 角色的前情摘要（明确标注为系统注入的压缩内容）。
    /// bridging（2026-09-18 分块压缩）：暂缓期内新被丢的轮次以原文垫在摘要之后、
    /// 保留段之前（时间序）——旧摘要与既有历史保持字节级不变，前缀缓存可命中。
    static func historyWithSummary(
        kept: [ChatMessage], summary: String, bridging: [ChatMessage] = []
    ) -> [ChatMessage] {
        guard let first = kept.first, first.role == .system else { return kept }
        let summaryMessage = ChatMessage(
            role: .user,
            content: "【前情摘要】以下是较早对话轮次的压缩摘要（原文已从上下文移除）：\n\(summary)"
        )
        return [first, summaryMessage] + bridging + kept.dropFirst()
    }

    /// 滚动压缩摘要 prompt：旧摘要要点吸收保留 + 新纳入轮次压缩成结构化要点。
    static func compactSummaryPrompt(
        previous: String, transcript: String
    ) -> String {
        let previousSection = previous.isEmpty ? "" : """

            ——已有摘要（此前轮次的压缩结论，吸收保留其要点，勿丢失）——
            \(previous)
            """
        return """
            你在为一条产品澄清对话做上下文压缩。把下面的旧对话轮次压缩成结构化要点，\
            按以下小节组织（无内容的小节省略）：「目标」「约束与偏好」「进展（已完成/进行中/受阻）」\
            「关键决策（决策：理由）」「关键上下文（继续工作所需的具体名称与数字）」。\
            保留具体名称与数字，不要空泛。
            \(previousSection)

            ——新纳入压缩的对话轮次——
            \(transcript)

            ——直接输出摘要正文（Markdown 小节，无围栏无前后缀说明）——
            """
    }
}
