//
//  Retriever.swift
//  pm_worker
//
//  检索层（design.md §6.3）：query 向量化 → SQLite 读全量行 → 内存余弦排序。
//  - scope 隔离写在检索层（E12）：卡片只取 project_id ∈ {"", project}，其余计为 filteredCrossProject
//  - 技能渐进式披露（E11）：命中只给 when_to_use 摘要，正文由 loadSkillBody 按需加载；
//    未命中技能全部 id 进 trace.unmatchedSkills（证明正文没被注入）
//  - 近重复去重：两条卡片命中互相 cosine > 0.95 时保留 scope 更窄者（project 赢 global）
//

import Foundation
import GRDB

/// SQLiteVec 切换接口（预留）：向量库统一检索入口。
/// 当前 MVP 始终走内存余弦；库规模超过 Retriever.sqliteVecChunkThreshold
/// 的 chunk 数时换 SQLiteVec 实现，接口已留出——检索层调用方无需改动。
nonisolated protocol VectorStore: Sendable {
    func search(queryVector: [Float], topK: Int) async throws -> [RetrievalHit]
}

/// nonisolated：检索层纯类型（SQLite 读 + 向量数学），无 UI 状态。
nonisolated final class Retriever {

    // MARK: - 常量

    /// 卡片命中阈值（余弦）
    static let cardThreshold: Double = 0.3
    /// 技能命中阈值（余弦）
    static let skillThreshold: Double = 0.35
    /// 近重复去重阈值：两条卡片命中互相 cosine 超过此值视为同一条（窄的赢）
    static let nearDuplicateThreshold: Double = 0.95
    /// 超过此 chunk 数换 SQLiteVec 实现，接口已留出（VectorStore）；当前 MVP 始终走内存余弦
    static let sqliteVecChunkThreshold = 2000

    // MARK: - 状态

    private let database: AppDatabase
    private let embedder: EmbeddingProviding

    init(database: AppDatabase, embedder: EmbeddingProviding) {
        self.database = database
        self.embedder = embedder
    }

    // MARK: - Row 投影

    /// GRDB 的 Row 非 Sendable，不能跨异步边界返回：
    /// 异步 read 闭包内先投影成 Sendable 值类型再带出（卡片行）。
    nonisolated private struct CardRow: Sendable {
        let id: String
        let projectId: String
        let content: String
        let embedding: Data
    }

    /// 同上（技能行：命中只带 when_to_use 摘要，正文渐进式披露）。
    nonisolated private struct SkillRow: Sendable {
        let id: String
        let whenToUse: String
        let embedding: Data
    }

    // MARK: - 检索

    /// 检索方法论卡（knowledge_points）+ 技能（skills 表 when_to_use 四字段语义命中）。
    /// 返回完整 RetrievalTrace（命中 + scope 标签 + 相似度 + 未命中技能列表）。
    /// - Parameters:
    ///   - skillQuery: 技能检索独立查询（意图优先路由，2026-09-14）——卡片按 `query`
    ///     （阶段产物 + 消息，保阶段连续性），技能按 `skillQuery`（最近用户消息，
    ///     消息意图主信号）。nil 时技能与卡片共用 `query`（旧行为）。
    ///   - countsSkillHits: 技能命中是否计入 hit_count。ContextBuilder 注入正文后
    ///     自行按「实际注入」计数（语义 + 锚点同口径），组装链路传 false 防双计；
    ///     知识库页直搜等无注入环节的调用方保持 true。
    func search(
        query: String,
        project: String,
        topK: Int = 5,
        skillQuery: String? = nil,
        countsSkillHits: Bool = true
    ) async throws -> RetrievalTrace {
        let clock = ContinuousClock()
        let start = clock.now

        // 1. query 向量化（embedder 契约保证等长返回；空兜底 → 全部余弦为 0 的空 trace）。
        //    双查询合并一次 embed 调用（真实端点省一次网络往返）。
        let embedTexts = skillQuery.map { [query, $0] } ?? [query]
        let vectors = try await embedder.embed(texts: embedTexts)
        let queryVector = vectors.first ?? []
        let skillVector = (skillQuery != nil ? vectors.last : vectors.first) ?? []

        // 2. 读全部行（两条 SELECT：卡片 + 技能；当前 MVP 内存余弦，
        //    SQLiteVec 切换点见 sqliteVecChunkThreshold）
        //    Row 非 Sendable 不能跨异步边界：闭包内先投影成 Sendable 值类型
        let cardRows = try await database.dbQueue.read { db -> [CardRow] in
            try Row.fetchAll(
                db,
                sql: "SELECT id, project_id, content, embedding FROM knowledge_points"
            )
            .map { row in
                CardRow(
                    id: row["id"],
                    projectId: row["project_id"],
                    content: row["content"],
                    embedding: row["embedding"]
                )
            }
        }
        let skillRows = try await database.dbQueue.read { db -> [SkillRow] in
            try Row.fetchAll(
                db,
                sql: "SELECT id, when_to_use, embedding FROM skills WHERE enabled = 1"
            )
            .map { row in
                SkillRow(
                    id: row["id"],
                    whenToUse: row["when_to_use"],
                    embedding: row["embedding"]
                )
            }
        }

        // 3. 卡片：scope 隔离（E12）+ 阈值过滤（按 stage query 向量）
        var filteredCrossProject = 0
        var cardCandidates: [(hit: RetrievalHit, vector: [Float])] = []
        for row in cardRows {
            // M0 旧数据兼容：零长度占位 blob 跳过（不参与检索，也不计入跨项目过滤）
            guard !row.embedding.isEmpty, let vector = VectorMath.decode(row.embedding) else { continue }
            // scope 隔离写在检索层：只取全局（""）与当前项目，其余计为 filteredCrossProject
            if !row.projectId.isEmpty && row.projectId != project {
                filteredCrossProject += 1
                continue
            }
            let score = VectorMath.cosine(queryVector, vector)
            guard score > Self.cardThreshold else { continue }
            cardCandidates.append((
                hit: RetrievalHit(
                    id: row.id,
                    library: .cards,
                    content: row.content,
                    score: score,
                    scope: row.projectId.isEmpty ? "global" : "project",
                    scopeId: row.projectId
                ),
                vector: vector
            ))
        }

        // 4. 近重复去重（窄的赢）：互相 cosine > nearDuplicateThreshold 的两条保留 scope 更窄者
        cardCandidates.sort { $0.hit.score > $1.hit.score }
        var deduped: [(hit: RetrievalHit, vector: [Float])] = []
        for candidate in cardCandidates {
            if let conflictIndex = deduped.firstIndex(where: {
                VectorMath.cosine(candidate.vector, $0.vector) > Self.nearDuplicateThreshold
            }) {
                // project 赢 global（更窄的上下文优先）；同 scope 保留分数更高的先入者
                if candidate.hit.scope == "project" && deduped[conflictIndex].hit.scope == "global" {
                    deduped[conflictIndex] = candidate
                }
            } else {
                deduped.append(candidate)
            }
        }
        let cardHits = deduped.prefix(topK).map { $0.hit }

        // 5. 技能：阈值过滤（按 skillQuery 向量——意图优先）。命中只给 when_to_use
        //    摘要（正文渐进式披露）；未命中（含被 topK 截断与零长度占位）的技能
        //    全部 id 进 unmatchedSkills——E11 验证依据
        var skillCandidates: [RetrievalHit] = []
        var allSkillIds: [String] = []
        for row in skillRows {
            allSkillIds.append(row.id)
            guard !row.embedding.isEmpty, let vector = VectorMath.decode(row.embedding) else { continue }
            let score = VectorMath.cosine(skillVector, vector)
            guard score > Self.skillThreshold else { continue }
            skillCandidates.append(
                RetrievalHit(
                    id: row.id,
                    library: .skills,
                    content: "when_to_use: \(row.whenToUse)",
                    score: score,
                    scope: "global",
                    scopeId: ""
                )
            )
        }
        skillCandidates.sort { $0.score > $1.score }
        let skillHits = Array(skillCandidates.prefix(topK))

        // 未命中技能 = 全部启用的技能 − 命中集合（含 topK 截断者）
        let hitIds = Set(skillHits.map(\.id))
        let unmatchedSkills = allSkillIds.filter { !hitIds.contains($0) }

        // 6. 命中计数（技能库 UI 的 hit_count 数据源）。组装链路传 countsSkillHits: false——
        //    注入才算命中，由 ContextBuilder 统一计数（语义 + 锚点同口径）
        if countsSkillHits, !hitIds.isEmpty {
            try await database.dbQueue.write { db in
                for id in hitIds {
                    try db.execute(
                        sql: "UPDATE skills SET hit_count = hit_count + 1 WHERE id = ?",
                        arguments: [id]
                    )
                }
            }
        }

        return RetrievalTrace(
            query: query,
            hits: cardHits + skillHits,
            filteredCrossProject: filteredCrossProject,
            unmatchedSkills: unmatchedSkills,
            durationMs: Self.milliseconds(of: clock.now - start),
            skillQuery: skillQuery
        )
    }

    // MARK: - 渐进式披露

    /// 技能命中后加载正文（正文不进索引，命中才读文件；去掉 front-matter）。
    static func loadSkillBody(docPath: String) -> String? {
        SkillLoader.loadBody(docPath: docPath)
    }

    // MARK: - Private

    /// Duration → 毫秒（ContinuousClock 实测，单调时钟）。
    private static func milliseconds(of duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds) * 1000
            + Int((Double(components.attoseconds) / 1_000_000_000_000_000).rounded())
    }
}
