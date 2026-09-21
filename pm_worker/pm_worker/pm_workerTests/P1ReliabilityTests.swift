//
//  P1ReliabilityTests.swift
//  pm_workerTests
//
//  P1 三项可靠性修复的回归面：
//  - P1-4 嵌入守卫：来源戳兼容判定；不同源 / 不等维行不参与余弦且 trace.degraded
//    留痕（旧行为是余弦恒 0 的静默零命中）；索引写入侧盖戳
//  - P1-5 词面相似度：LexicalSimilarity 边界、mergeDecision 近义改写标题
//    判为同主题冲突、KnowledgeCalibration 无 4 字窗命中仍能按重叠率匹配
//  - P1-6 预算自适应：budgets(contextWindow:) 比例、夹逼上下限与 rules 下限
//  磁盘全部走临时目录，不依赖网络。
//

import XCTest
import GRDB
@testable import pm_worker

/// 假向量源：固定维度向量 + 自定义来源戳（模拟「换了嵌入模型」）。
/// nonisolated：跨隔离接缝（EmbeddingProviding 为 nonisolated 协议）。
private nonisolated struct FixedEmbedder: EmbeddingProviding {
    var dimension: Int
    var signature: String
    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float](repeating: 0.1, count: dimension) }
    }
    func embedWithSource(texts: [String]) async throws -> (vectors: [[Float]], source: String) {
        (try await embed(texts: texts), signature)
    }
}

final class P1ReliabilityTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-p1-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        PMAgentStore.rootOverride = nil
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(
            indexURL: tempRoot.appendingPathComponent("index-\(UUID().uuidString).sqlite")
        )
    }

    // MARK: - P1-4 来源戳判定

    func testSourceStampCompatibilityRule() {
        XCTAssertTrue(EmbeddingSourceStamp.isCompatible(nil, "model:tex"))
        XCTAssertTrue(EmbeddingSourceStamp.isCompatible("", "hash256"))
        XCTAssertTrue(EmbeddingSourceStamp.isCompatible("hash256", "hash256"))
        XCTAssertFalse(EmbeddingSourceStamp.isCompatible("model:a", "model:b"))
        XCTAssertFalse(EmbeddingSourceStamp.isCompatible("hash256", "model:a"))
    }

    func testSettingsBackedEmbedderFallsBackWithHashStamp() async throws {
        // 无 embedding 阶段配置 → EmbeddingClient 必抛错 → 回退路径盖 hash256 戳
        let embedder = SettingsBackedEmbedder(settings: LLMSettings(stages: [:], maxTokensPerRun: 100))
        let result = try await embedder.embedWithSource(texts: ["任何文本"])
        XCTAssertEqual(result.source, EmbeddingSourceStamp.hash256)
        XCTAssertEqual(result.vectors.first?.count, DeterministicHashEmbedder.dimensions)
    }

    func testIndexCardStampsSource() async throws {
        let database = try makeDatabase()
        let card = MethodologyCard(
            sourceType: "manual", sourceRef: "测试", project: nil,
            confidence: 0.8, content: "先分类再排优先级"
        )
        try await IndexRebuilder.indexCard(
            card, projectId: "", database: database,
            embeddingProvider: DeterministicHashEmbedder()
        )
        let row: Row? = try await database.dbQueue.read { db in
            try Row.fetchOne(
                db, sql: "SELECT embedding_source FROM knowledge_points WHERE id = ?",
                arguments: [card.id]
            )
        }
        let source: String? = row?["embedding_source"]
        XCTAssertEqual(source, EmbeddingSourceStamp.hash256, "索引写入侧必须盖来源戳")
    }

    func testRetrieverExcludesForeignStampAndMarksDegraded() async throws {
        let database = try makeDatabase()
        let card = MethodologyCard(
            sourceType: "manual", sourceRef: "测试", project: nil,
            confidence: 0.8, content: "KANO 基本型期望型兴奋型分类"
        )
        try await IndexRebuilder.indexCard(
            card, projectId: "", database: database,
            embeddingProvider: DeterministicHashEmbedder()
        )

        // 同源（hash256 空间）：正常命中、无降级
        let same = Retriever(database: database, embedder: DeterministicHashEmbedder())
        let okTrace = try await same.search(
            query: "KANO 分类", project: "某项目", topK: 5, countsSkillHits: false
        )
        XCTAssertTrue(okTrace.hits.contains { $0.id == card.id })
        XCTAssertNil(okTrace.degraded)

        // 换源（等维但异戳）：行被排除 + degraded 留痕，不再是静默零命中
        let foreign = Retriever(
            database: database,
            embedder: FixedEmbedder(dimension: DeterministicHashEmbedder.dimensions,
                                    signature: "model:other-vendor")
        )
        let badTrace = try await foreign.search(
            query: "KANO 分类", project: "某项目", topK: 5, countsSkillHits: false
        )
        XCTAssertFalse(badTrace.hits.contains { $0.id == card.id })
        XCTAssertNotNil(badTrace.degraded)
        XCTAssertTrue(badTrace.degraded!.contains("重建索引"))

        // 维度不等（1536 查询 × 256 索引）：同样被排除并留痕
        let dimMismatch = Retriever(
            database: database,
            embedder: FixedEmbedder(dimension: 1536, signature: "hash256")
        )
        let dimTrace = try await dimMismatch.search(
            query: "KANO 分类", project: "某项目", topK: 5, countsSkillHits: false
        )
        XCTAssertFalse(dimTrace.hits.contains { $0.id == card.id })
        XCTAssertNotNil(dimTrace.degraded)
    }

    // MARK: - P1-5 词面相似度

    func testBigramOverlapParaphraseAndDissimilar() {
        XCTAssertGreaterThanOrEqual(
            LexicalSimilarity.bigramOverlap("KANO 需求分类", "需求分类下的 KANO 模型"),
            LexicalSimilarity.sameTopicThreshold
        )
        XCTAssertLessThan(
            LexicalSimilarity.bigramOverlap("KANO 需求分类", "RICE 优先级排序"), 0.2
        )
    }

    func testMergeDecisionDetectsParaphrasedTitle() {
        let item = KnowledgeExtractor.ExtractedKnowledge(
            title: "需求分类下的 KANO 模型", content: "新表述正文", confidence: 0.8
        )
        // 既有卡正文向量刻意正交（低余弦），旧口径「标题全等」必漏 → conflict
        let existing = [(
            id: "k1", title: "KANO 需求分类", content: "旧正文",
            embedding: [Float]([1, 0, 0, 0].map(Float.init))
        )]
        let decision = KnowledgeExtractor.mergeDecision(
            for: item, existing: existing,
            itemEmbedding: [Float]([0, 1, 0, 0].map(Float.init))
        )
        XCTAssertEqual(decision, .conflict(existingId: "k1"))
    }

    func testMergeDecisionKeepsMergeAndNewCardBranches() {
        let shared = [Float]([1, 1, 1, 1].map(Float.init))
        let item = KnowledgeExtractor.ExtractedKnowledge(
            title: "任意标题", content: "正文", confidence: 0.8
        )
        // ① 同向量 cosine=1 > 0.92 → merge（标题无关也不新建）
        XCTAssertEqual(
            KnowledgeExtractor.mergeDecision(
                for: item,
                existing: [("k1", "别的标题", "正文", shared)], itemEmbedding: shared
            ),
            .mergeInto(existingId: "k1")
        )
        // ③ 正交向量 + 无关标题 → newCard
        XCTAssertEqual(
            KnowledgeExtractor.mergeDecision(
                for: item,
                existing: [("k2", "RICE 优先级", "正文", [Float]([1, 0, 0, 0].map(Float.init)))]
                    .map { (id: $0.0, title: $0.1, content: $0.2, embedding: $0.3) },
                itemEmbedding: [Float]([0, 1, 0, 0].map(Float.init))
            ),
            .newCard
        )
    }

    func testCalibrationMatchesWithoutFourCharWindow() {
        // 标题「北极星指标评审」的任一 4 字连续片段都不在正文里（旧口径必漏），
        // 但标题 2-gram 对正文重叠率过半 → 新口径命中
        let entry = MemoryEntry(
            scope: .project, scopeId: "p", kind: .experience,
            content: "指标是北极星，评审先看它", confidence: 0.7
        )
        let matched = KnowledgeCalibration.matchingExperiences(
            cardTitle: "北极星指标评审", memories: [entry]
        )
        XCTAssertEqual(matched.count, 1)
        // 无关主题不误伤
        XCTAssertTrue(KnowledgeCalibration.matchingExperiences(
            cardTitle: "北极星指标评审",
            memories: [MemoryEntry(
                scope: .project, scopeId: "p", kind: .experience,
                content: "支付通道对账口径", confidence: 0.7
            )]
        ).isEmpty)
    }

    // MARK: - P1-6 预算自适应

    func testBudgetsScaleWithWindow() {
        XCTAssertEqual(ContextBuilder.budgets(contextWindow: nil), ContextBuilder.defaultBudgets)
        XCTAssertEqual(
            ContextBuilder.budgets(contextWindow: ContextBuilder.referenceContextWindow),
            ContextBuilder.defaultBudgets
        )
        // 小窗 16k → 夹到下限 0.4 倍；rules 有 300 地板
        let small = ContextBuilder.budgets(contextWindow: 16_000)
        XCTAssertEqual(small[.memory], 800)
        XCTAssertEqual(small[.skillBodies], 1600)
        XCTAssertEqual(small[.rules], 300)
        // 大窗 128k → 2 倍
        let large = ContextBuilder.budgets(contextWindow: 128_000)
        XCTAssertEqual(large[.memory], 4000)
        XCTAssertEqual(large[.history], 12_000)
        // 超窗 1M → 夹到上限 2.5 倍
        let huge = ContextBuilder.budgets(contextWindow: 1_000_000)
        XCTAssertEqual(huge[.history], 15_000)
    }

    func testModelProfileContextWindowDecode() throws {
        let base = #""id":"m1","provider":"deepseek","model":"d","supportsImages":false,"enabled":true,"keychainKey":"byok.model.m1""#
        let json = "{\(base),\"contextWindow\":64000}".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ModelProfile.self, from: json).contextWindow, 64000)
        // 旧存量档案（无 contextWindow 键）→ nil = 不伸缩
        let legacy = "{\(base)}".data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(ModelProfile.self, from: legacy).contextWindow)
    }
}
