//
//  KnowledgeExtractor.swift
//  pm_worker
//
//  方法论卡抽取与落卡（Task 4.4，design.md §5.2 / §6.3）：
//  - LLM 抽取（schema 约束）→ ExtractedKnowledge（标题 / 正文 / 置信度）
//  - 归属合并判定（E10）：相似度 > 0.92 → 合并不新建；同主题实质改良 → 旧卡让位
//  - writeCard：卡片 Markdown 序列化（与 MethodologyCard.parse 同格式）+
//    write-then-verify 落盘 + 写完即建索引（IndexRebuilder.indexCard）
//

import Foundation

nonisolated enum KnowledgeExtractor {

    // MARK: - 抽取结果模型

    /// LLM 抽取结果条目（schema 约束）。
    struct ExtractedKnowledge: Codable, Equatable {
        /// 方法论一句话标题（检索摘要与同主题冲突判定的锚点）
        var title: String
        /// 方法论正文（卡片 content）
        var content: String
        /// 为什么有效：底层原理/因果逻辑（写时富化；nil = 模型未提供，兼容旧输出）
        var principle: String?
        /// 置信度 0-1
        var confidence: Double
    }

    /// 归属合并决策（E10：同一概念第二次触发合并；同主题冲突旧卡失效）。
    enum MergeDecision: Equatable {
        /// 新方法论 → 新建卡片
        case newCard
        /// 与既有卡近重复（cosine > 0.92）→ 合并：注记区追加，不新建
        case mergeInto(existingId: String)
        /// 同主题但实质改良 → 新卡落盘，旧卡 supersededBy 让位
        case conflict(existingId: String)
    }

    // MARK: - LLM 抽取（schema 约束）

    /// 方法论抽取 prompt（「这条记下来」卡片路线：把原文提炼成可复用方法论）。
    /// 写时富化（2026-09-17 钦定）：content 强制三段多行 + principle 底层原理——
    /// 单行整段卡会让详情层「标题/是什么/全文」三重重复（实测教训），模板层根治。
    static func extractionPrompt(transcript: String) -> String {
        // transcript 置顶：与要点表/记忆抽取共享底稿前缀（provider 前缀缓存，
        // 2026-09-18 前缀缓存契约——确认链三连抽同一底稿只付一次全价 prefill）。
        return """
        ## 对话记录
        \(transcript)

        ——以上为材料，以下为任务——
        从上述内容中抽取「可跨项目复用的产品方法论」。仅输出一个 JSON 数组，\
        不要 markdown 围栏、不要任何多余文字。Schema：
        [{"title": "方法论一句话标题（≤20字）", \
        "content": "方法论正文，必须三段、每段独立一行，禁止写成一段：\n定义：一句说清是什么\n做法：怎么用，步骤或要点\n适用边界：什么场景适用、什么场景不适用", \
        "principle": "为什么有效：这条方法论的底层原理/因果逻辑，一两句话", \
        "confidence": 0.8}]
        规则：只提炼内容中明确出现的方法论，不得推断补全；没有可抽取项输出 []；\
        聚焦「怎么做事」的通用做法，剥离项目特定细节；content 必须多行分段（每段独立一行），禁止挤成一段；中文输出。
        """
    }

    /// 宽松解析模型回复：容忍围栏与前后废话（LenientJSON）；
    /// 字段缺失容错（无 title → 取正文前 20 字；无 confidence → 默认 0.8；
    /// 无 principle → nil，兼容旧模型输出）；非法输入返回 []。
    static func parse(reply: String) -> [ExtractedKnowledge] {
        // 中间 DTO：字段全部可选，单条缺字段不拖垮整个数组
        struct DTO: Decodable {
            var title: String?
            var content: String?
            var principle: String?
            var confidence: Double?
        }
        guard let dtos = LenientJSON.decode([DTO].self, from: reply) else { return [] }
        var results: [ExtractedKnowledge] = []
        for dto in dtos {
            // 无正文（或纯空白）的条目丢弃，不拖垮整个数组
            guard let rawContent = dto.content else { continue }
            let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            // 无标题 / 标题纯空白 → 取正文前 20 字
            let rawTitle = (dto.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? String(content.prefix(20)) : rawTitle
            let principle = dto.principle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = min(max(dto.confidence ?? 0.8, 0), 1)
            results.append(
                ExtractedKnowledge(
                    title: title, content: content,
                    principle: principle?.isEmpty == true ? nil : principle,
                    confidence: confidence
                )
            )
        }
        return results
    }

    // MARK: - 归属合并判定

    /// 去重合并三分支：
    /// ① 与某既有卡 cosine > 0.92（VectorMath.mergeThreshold）→ mergeInto（E10 合并不新建）；
    /// ② 标题归一化后与既有卡一致但内容非近重复 → conflict（实质改良，旧卡让位）；
    /// ③ 其余 → newCard。
    /// - existing：scope 隔离后的候选卡（全局 + 当前项目，调用方负责筛选）。
    static func mergeDecision(
        for item: ExtractedKnowledge,
        existing: [(id: String, title: String, content: String, embedding: [Float])],
        itemEmbedding: [Float]
    ) -> MergeDecision {
        var bestSimilarity: Double = 0
        var bestId: String?
        var conflictId: String?

        for card in existing {
            let similarity = VectorMath.cosine(itemEmbedding, card.embedding)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestId = card.id
            }
            // 同主题（标题去空白后一致）且内容非近重复 → 冲突候选
            if normalizedTitle(card.title) == normalizedTitle(item.title),
               similarity <= VectorMath.mergeThreshold {
                conflictId = card.id
            }
        }

        // ① 近重复 → 合并（同一概念第二次触发不新建）
        if bestSimilarity > VectorMath.mergeThreshold, let bestId {
            return .mergeInto(existingId: bestId)
        }
        // ② 同主题冲突 → 新卡 + 旧卡让位
        if let conflictId { return .conflict(existingId: conflictId) }
        // ③ 新方法论
        return .newCard
    }

    /// 标题归一化：去空白 + 小写（「KANO 需求分类」与「kano需求分类」视为同主题）。
    private static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - 落卡（write-then-verify + 写完即建索引）

    /// 新卡落盘：序列化 → write-then-verify 写入全局 cards/（方法论跨项目直接用不降级）
    /// → 增量索引（IndexRebuilder.indexCard，幂等；失败不回滚——索引可随时全量重建）。
    /// - Parameters:
    ///   - sourceType: methodology（讨论抽取）| manual（「这条记下来」手动沉淀）
    ///   - sourceRef: 出处（项目/版本或讨论引用）
    ///   - principle: 为什么有效（写时富化；nil = 旧模板无此字段）
    @MainActor
    static func writeCard(
        content: String,
        confidence: Double,
        sourceType: String,
        sourceRef: String,
        principle: String? = nil,
        database: AppDatabase?,
        embeddingProvider: EmbeddingProviding
    ) async throws -> MethodologyCard {
        let card = MethodologyCard(
            sourceType: sourceType,
            sourceRef: sourceRef,
            project: nil,  // 方法论卡全局（跨项目直接用不降级）
            confidence: min(max(confidence, 0), 1),
            content: content,
            principle: principle
        )
        let url = PMAgentStore.cardsDir.appendingPathComponent("\(card.id).md")
        try PMAgentStore.writeVerified(cardMarkdown(card), to: url)

        // 写完即建索引（签名不可变契约；database 为 nil → 纯文件模式跳过）
        if let database {
            try? await IndexRebuilder.indexCard(
                card, projectId: "", database: database, embeddingProvider: embeddingProvider
            )
        }
        return card
    }

    /// 卡片 Markdown 序列化：front-matter + 正文 + 为什么有效 + 实战注记区
    /// （与 Resources/cards 模板卡、MethodologyCard.parse 三方同格式；
    /// principle 节为写时富化 2026-09-17 新增，旧卡无此节照常解析）。
    static func cardMarkdown(_ card: MethodologyCard) -> String {
        var lines: [String] = [
            "---",
            "id: \(card.id)",
            "source_type: \(card.sourceType)",
            "source_ref: \(card.sourceRef)",
            "project: \(card.project ?? "")",
            "confidence: \(card.confidence)",
            "supersededBy: \(card.supersededBy ?? "null")",
            "created: \(card.created)",
            "---",
            card.content,
        ]
        if let principle = card.principle, !principle.isEmpty {
            lines.append("")
            lines.append("## 为什么有效")
            lines.append(principle)
        }
        lines.append("")
        lines.append(AnnotationWriter.sectionHeader)
        for annotation in card.annotations {
            lines.append("- \(annotation.date) · \(annotation.project)：\(annotation.note)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 旧卡让位（冲突消解链）：重写 front-matter 的 supersededBy 回链。
    /// write-then-verify；文件缺失 / 解析失败抛错。
    static func markSuperseded(cardURL: URL, by newId: String) throws {
        guard let text = try? String(contentsOf: cardURL, encoding: .utf8),
              var card = MethodologyCard.parse(markdown: text)
        else {
            throw NSError(
                domain: "KnowledgeExtractor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "卡片读取或解析失败：\(cardURL.path)"]
            )
        }
        card.supersededBy = newId
        try PMAgentStore.writeVerified(cardMarkdown(card), to: cardURL)
    }
}

// MARK: - 设置驱动的向量编码适配器

/// 向量编码适配器：优先真实 /embeddings 端点（EmbeddingClient），
/// 失败（未配 Key / 断网 / 端点异常）回退确定性哈希向量——管线保活不阻塞
/// （与 DeterministicHashEmbedder 的离线兜底语义一致）。
nonisolated struct SettingsBackedEmbedder: EmbeddingProviding {
    let settings: LLMSettings

    func embed(texts: [String]) async throws -> [[Float]] {
        if let vectors = try? await EmbeddingClient.embed(texts: texts, settings: settings),
           vectors.count == texts.count {
            return vectors
        }
        return texts.map { DeterministicHashEmbedder.vector(for: $0) }
    }
}
