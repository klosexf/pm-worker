//
//  Recommender.swift
//  pm_worker
//
//  主动推荐（Task 4.5，design.md §6.3 / E23）：阶段开始时扫描卡片库，
//  按阶段任务文本与卡片的余弦相似度推荐 1-3 个方法论——
//  含理由（确定性拼装，可观测）、可拒绝、同阶段不重复被拒项。
//  scope 隔离（全局 + 当前项目）由调用方负责——与 Retriever 同规则。
//

import Foundation

nonisolated enum Recommender {

    /// 推荐条目（UI 渲染 + trace 可观测）。
    struct Recommendation: Codable, Equatable, Identifiable {
        /// 卡片 id（knowledge_points.id）
        var id: String
        /// 标题（正文首句清洗——去 markdown 前缀与「定义：」引导词，句界截断）
        var title: String
        /// 卡片正文
        var content: String
        /// 余弦相似度
        var score: Double
        /// 推荐理由（确定性拼装：匹配度 / scope / 注记厚度，详情区展示）
        var reason: String
        /// 是什么（正文首段白话清洗，≤120 字）
        var what: String
        /// 为什么现在（推荐时机：阶段 + 用户产物线索，确定性拼装）
        var whyNow: String
        /// 实战注记条数（已被验证次数）
        var annotationCount: Int
        /// global | project
        var scope: String
    }

    /// 推荐上限（1-3 个，Task 4.5 硬性区间）。
    static let maxRecommendations = 3
    /// 推荐命中阈值（与检索层卡片阈值同口径，Retriever.cardThreshold）。
    static let threshold: Double = 0.3

    /// 阶段推荐主入口。
    /// - Parameters:
    ///   - cards: scope 隔离后的候选卡（全局 + 当前项目；零长度占位 embedding 由调用方过滤）
    ///   - rejected: 本阶段已拒绝的卡片 id（同阶段不重复被拒项）
    ///   - stageSummary: 阶段任务摘要（查询文本，理由中引用）
    ///   - queryEmbedding: stageSummary 的向量编码
    static func recommend(
        stage: LLMStage,
        project: String,
        cards: [(id: String, title: String, content: String, annotationCount: Int, scope: String, embedding: [Float])],
        stageSummary: String,
        queryEmbedding: [Float],
        rejected: Set<String>
    ) -> [Recommendation] {
        var scored: [Recommendation] = []
        for card in cards {
            // 同阶段不重复被拒项（E23）
            guard !rejected.contains(card.id) else { continue }
            guard !card.embedding.isEmpty else { continue }
            let score = VectorMath.cosine(queryEmbedding, card.embedding)
            guard score > threshold else { continue }
            scored.append(
                Recommendation(
                    id: card.id,
                    title: card.title,
                    content: card.content,
                    score: score,
                    reason: reason(
                        stage: stage, scope: card.scope,
                        score: score, annotationCount: card.annotationCount,
                        summary: stageSummary
                    ),
                    what: plainSummary(of: card.content),
                    whyNow: whyNow(stage: stage, summary: stageSummary),
                    annotationCount: card.annotationCount,
                    scope: card.scope
                )
            )
        }
        // 相似度降序，截 1-3 个
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(maxRecommendations))
    }

    /// 标题派生：正文首行清洗（去 markdown 井号与「定义：」类引导词），
    /// 按句界截断（上限 32 字，避免半句硬切）——卡片无独立标题字段，摘要即标题。
    /// 「记下来」沉淀的卡常是单行整段长文：标题必须截断（fullTitle 已废弃，
    /// 单行长文做标题会把正文整段顶进标题位——2026-09-17 实测教训）。
    static func title(of content: String) -> String {
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? content
        let t = sentenceClipped(stripLead(firstLine), limit: 32)
        return t.isEmpty ? content : t
    }

    /// 剥离 markdown 井号与「定义：」类引导词（标题/摘要共用清洗）。
    private static func stripLead(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t = String(t.dropFirst()) }
        t = t.trimmingCharacters(in: .whitespaces)
        for prefix in ["定义：", "定义:", "方法论：", "方法论:", "方法：", "方法:"]
        where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 「是什么」摘要：正文取首个非标题、非列表行块，清洗后按句界截 120 字。
    /// 旧单行整段卡里「定义…做法…适用边界」挤成一行：段界标记处换行，
    /// 让 hero 的「是什么」可扫读（新卡本就分行，替换无命中不受影响）。
    static func plainSummary(of content: String) -> String {
        let bodyLine = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") && !$0.hasPrefix("!") }
        guard let t = bodyLine.map({ stripLead($0) }) else {
            return String(content.prefix(120))
        }
        return sentenceClipped(t, limit: 120)
            .replacingOccurrences(of: "做法：", with: "\n做法：")
            .replacingOccurrences(of: "做法:", with: "\n做法:")
            .replacingOccurrences(of: "适用边界：", with: "\n适用边界：")
            .replacingOccurrences(of: "适用边界:", with: "\n适用边界:")
    }

    /// 详情弹层方案 B 三段解析：content 拆成 定义 / 做法 / 适用边界。
    /// 新卡按三段多行沉淀（提炼模板强制），逐行状态机归段；旧单行整段卡
    /// 在段界标记前补换行后同路解析（与 plainSummary 内联拆分同思路）。
    /// 完全没有段界标记的自由卡：首行清洗稿归定义、其余归做法，不丢内容。
    static func contentSegments(of content: String) -> (definition: String?, how: String?, boundary: String?) {
        let normalized = content
            .replacingOccurrences(of: "做法：", with: "\n做法：")
            .replacingOccurrences(of: "做法:", with: "\n做法:")
            .replacingOccurrences(of: "适用边界：", with: "\n适用边界：")
            .replacingOccurrences(of: "适用边界:", with: "\n适用边界:")
        var defLines: [String] = []
        var howLines: [String] = []
        var boundLines: [String] = []
        var mode = 0   // 0=定义 1=做法 2=适用边界
        var sawLabel = false
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("适用边界：") || line.hasPrefix("适用边界:") {
                sawLabel = true
                mode = 2
                boundLines.append(String(line.dropFirst("适用边界：".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("做法：") || line.hasPrefix("做法:") {
                sawLabel = true
                mode = 1
                howLines.append(String(line.dropFirst("做法：".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("定义：") || line.hasPrefix("定义:") {
                sawLabel = true
                mode = 0
                defLines.append(stripLead(line))
            } else if line.hasPrefix("#") {
                continue   // markdown 标题行不进正文段
            } else {
                switch mode {
                case 0: defLines.append(stripLead(line))
                case 1: howLines.append(line)
                default: boundLines.append(line)
                }
            }
        }
        let joined: ([String]) -> String? = { lines in
            let t = lines.filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if sawLabel {
            return (joined(defLines), joined(howLines), joined(boundLines))
        }
        // 兜底：无任何段界标记的旧卡——首行归定义，其余行归做法
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return (nil, nil, nil) }
        let definition = stripLead(lines[0])
        let how = joined(Array(lines.dropFirst()))
        return (definition.isEmpty ? nil : definition, how, nil)
    }

    /// 「为什么现在」白话拼装：阶段名 + 用户产物线索（清洗 markdown，
    /// 取前两行实质内容；表格行 `| … |` / `----` 一并剔除——产物线索常引
    /// 功能清单草稿，表格语法漏进 quote 块会排成乱码 2026-09-17 实测）。
    static func whyNow(stage: LLMStage, summary: String) -> String {
        let cleaned = summary
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") && !$0.hasPrefix("|")
            }
            .prefix(2)
            .joined(separator: "；")
        let brief = sentenceClipped(cleaned, limit: 48)
        return brief.isEmpty
            ? "你正在\(stage.displayName)阶段——这张卡与当前任务相关"
            : "你正在\(stage.displayName)阶段，线索：\(brief)——这张卡正好用在这个环节"
    }

    /// 句界截断：超限时回退到最近的句读点（保底 8 字防过短），不硬切半句。
    private static func sentenceClipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let stops: Set<Character> = ["。", "！", "？", "；", "，", ",", "、"]
        if let idx = head.lastIndex(where: { stops.contains($0) }),
           head.distance(from: head.startIndex, to: idx) >= 8 {
            return String(head[..<idx])
        }
        return head
    }

    /// 确定性理由拼装（trace 可观测：阶段、相关度、scope、注记厚度、阶段要点）。
    private static func reason(
        stage: LLMStage, scope: String, score: Double, annotationCount: Int, summary: String
    ) -> String {
        let percent = Int((score * 100).rounded())
        var parts: [String] = [
            "与\(stage.displayName)阶段任务相关度 \(percent)%",
            "\(scope == "global" ? "全局" : "本项目")方法论",
        ]
        if annotationCount > 0 {
            parts.append("已被实战验证 \(annotationCount) 次")
        }
        let brief = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty {
            parts.append("阶段要点：\(String(brief.prefix(24)))…")
        }
        return parts.joined(separator: " · ")
    }
}
