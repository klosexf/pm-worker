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
        /// 标题（正文首句摘要——卡片无独立标题字段）
        var title: String
        /// 卡片正文
        var content: String
        /// 余弦相似度
        var score: Double
        /// 推荐理由（确定性拼装：阶段 / 相关度 / scope / 注记厚度）
        var reason: String
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
                    annotationCount: card.annotationCount,
                    scope: card.scope
                )
            )
        }
        // 相似度降序，截 1-3 个
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(maxRecommendations))
    }

    /// 标题派生：正文首行截 20 字（卡片无独立标题字段——摘要即标题）。
    static func title(of content: String) -> String {
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? content : trimmed).prefix(20))
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
