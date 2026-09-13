//
//  RetrievalTests.swift
//  pm_workerTests
//
//  M4 Task 4.2 + 4.3：检索层与技能库渐进式披露。
//  - VectorMath 余弦 / blob 往返
//  - scope 隔离（E12）：跨项目卡被过滤、全局卡可命中
//  - 技能渐进式披露（E11）：命中只给 when_to_use 摘要，未命中技能正文不注入
//  - 近重复去重（窄的赢） / 增量索引幂等
//  - pitfalls 确定性路由
//  - EmbeddingClient 响应解析（不发网络）
//  不依赖网络：DeterministicHashEmbedder + 临时 AppDatabase，直接 INSERT 测试行，
//  不走 PMAgentStore 文件系统。
//

import XCTest
import GRDB
@testable import pm_worker

final class RetrievalTests: XCTestCase {
    var tempRoot: URL!
    var database: AppDatabase!
    let embedder = DeterministicHashEmbedder()

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-retrieval-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        do {
            database = try AppDatabase(indexURL: tempRoot.appendingPathComponent("index.sqlite"))
        } catch {
            XCTFail("AppDatabase 初始化失败: \(error)")
        }
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - 测试行插入（带真实编码的 embedding blob）

    private func insertCard(id: String, projectId: String, content: String) throws {
        let vector = DeterministicHashEmbedder.vector(for: content)
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO knowledge_points
                        (id, project_id, content, source_type, source_ref, embedding,
                         annotation_count, confidence, superseded_by, created_at)
                    VALUES (?, ?, ?, 'methodology', '', ?, 0, 1.0, NULL, '2026-09-11')
                    """,
                arguments: [id, projectId, content, VectorMath.encode(vector)]
            )
        }
    }

    private func insertSkill(
        id: String,
        name: String,
        whenToUse: String,
        bestFor: [String] = [],
        tags: [String] = [],
        pitfalls: [String] = [],
        docPath: String = "/nonexistent/skill.md"
    ) throws {
        // 与 IndexRebuilder 同口径：embedding 对 name + when_to_use + best_for + tags 编码
        let fourField = ([name, whenToUse] + bestFor + tags).joined(separator: "\n")
        let vector = DeterministicHashEmbedder.vector(for: fourField)
        let encoder = JSONEncoder()
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO skills
                        (id, name, type, when_to_use, best_for, tags, pitfalls,
                         doc_path, embedding, hit_count, enabled)
                    VALUES (?, ?, 'component', ?, ?, ?, ?, ?, ?, 0, 1)
                    """,
                arguments: [
                    id, name, whenToUse,
                    String(decoding: try encoder.encode(bestFor), as: UTF8.self),
                    String(decoding: try encoder.encode(tags), as: UTF8.self),
                    String(decoding: try encoder.encode(pitfalls), as: UTF8.self),
                    docPath,
                    VectorMath.encode(vector),
                ]
            )
        }
    }

    // MARK: - 1. VectorMath：余弦正确性 + blob 往返

    func testVectorMathCosineAndBlobRoundTrip() {
        let a: [Float] = [1, 2, 3, 4]
        // 同向量 = 1
        XCTAssertEqual(VectorMath.cosine(a, a), 1, accuracy: 1e-9)
        // 正交 ≈ 0
        let u: [Float] = [1, 0, 2, 0]
        let v: [Float] = [0, 3, 0, 4]
        XCTAssertEqual(VectorMath.cosine(u, v), 0, accuracy: 1e-9)
        // 维度不等 / 零向量 → 0
        XCTAssertEqual(VectorMath.cosine([1, 2], [1, 2, 3]), 0)
        XCTAssertEqual(VectorMath.cosine([0, 0], [1, 2]), 0)

        // blob encode/decode 往返
        let blob = VectorMath.encode(u)
        XCTAssertEqual(blob.count, 4 * MemoryLayout<Float>.size)
        XCTAssertEqual(VectorMath.decode(blob), u)
        // 长度非 4 的倍数 → nil
        XCTAssertNil(VectorMath.decode(Data([0x01, 0x02, 0x03])))
    }

    // MARK: - 2. scope 隔离（E12）

    func testScopeIsolationFiltersCrossProjectCards() async throws {
        let queryText = "KANO 模型将需求分为基本型、期望型、兴奋型三类，先分类再排优先级"
        // 项目 A 的卡：与 query 极相似（本应是最高分命中），但属于另一项目
        try insertCard(id: "kp-project-a", projectId: "项目A", content: queryText + "。")
        // 当前项目（B）的卡：内容无关
        try insertCard(
            id: "kp-project-b", projectId: "项目B",
            content: "企业后台权限设计：基于角色 RBAC 的最小权限原则"
        )
        // 全局卡：与 query 完全一致
        try insertCard(id: "kp-global", projectId: "", content: queryText)

        let retriever = Retriever(database: database, embedder: embedder)
        let trace = try await retriever.search(query: queryText, project: "项目B")

        // 项目 A 的卡绝不出现在命中里（哪怕它与 query 最相似）——E12
        XCTAssertFalse(trace.hits.contains { $0.id == "kp-project-a" })
        // 跨项目过滤计数 ≥ 1（A 的卡被 scope 隔离拦下）
        XCTAssertGreaterThanOrEqual(trace.filteredCrossProject, 1)
        // 全局卡可命中且 scope = "global"
        let globalHit = try XCTUnwrap(trace.hits.first { $0.id == "kp-global" })
        XCTAssertEqual(globalHit.library, .cards)
        XCTAssertEqual(globalHit.scope, "global")
        XCTAssertEqual(globalHit.scopeId, "")
    }

    // MARK: - 3. 技能渐进式披露（E11）

    func testSkillProgressiveDisclosure() async throws {
        // 技能文件（带 front-matter，正文含唯一哨兵串）
        let xBody = "技能X正文：SECRET_X_BODY_TOKEN"
        let yBody = "技能Y正文：SECRET_Y_BODY_TOKEN"
        let xPath = tempRoot.appendingPathComponent("skill-x.md").path
        let yPath = tempRoot.appendingPathComponent("skill-y.md").path
        try """
        ---
        name: 技能X
        ---
        \(xBody)
        """.write(to: URL(fileURLWithPath: xPath), atomically: true, encoding: .utf8)
        try """
        ---
        name: 技能Y
        ---
        \(yBody)
        """.write(to: URL(fileURLWithPath: yPath), atomically: true, encoding: .utf8)

        try insertSkill(
            id: "技能X", name: "技能X",
            whenToUse: "KANO 需求优先级排序时",
            bestFor: ["砍需求清单"], tags: ["kano", "优先级"],
            docPath: xPath
        )
        try insertSkill(
            id: "技能Y", name: "技能Y",
            whenToUse: "需要摸清竞品格局时",
            bestFor: ["产品定位"], tags: ["竞品"],
            docPath: yPath
        )

        let retriever = Retriever(database: database, embedder: embedder)
        let trace = try await retriever.search(query: "KANO 需求优先级排序", project: "项目B")

        // X 命中（技能库），Y 未命中
        let xHit = try XCTUnwrap(trace.hits.first { $0.id == "技能X" && $0.library == .skills })
        XCTAssertTrue(trace.unmatchedSkills.contains("技能Y"))
        XCTAssertFalse(trace.unmatchedSkills.contains("技能X"))

        // 命中 content 只是 when_to_use 摘要——两份正文都不在其中——E11
        XCTAssertEqual(xHit.content, "when_to_use: KANO 需求优先级排序时")
        for hit in trace.hits {
            XCTAssertFalse(hit.content.contains("SECRET_X_BODY_TOKEN"))
            XCTAssertFalse(hit.content.contains("SECRET_Y_BODY_TOKEN"))
            XCTAssertFalse(hit.content.contains("需要摸清竞品格局时"))
        }

        // 渐进式披露：正文命中后才按需加载（去掉 front-matter）
        XCTAssertEqual(Retriever.loadSkillBody(docPath: xPath), xBody)
        XCTAssertNil(Retriever.loadSkillBody(docPath: "/nonexistent/nope.md"))

        // 命中计数 +1（技能库 UI 数据源）；未命中技能不计
        let xCount = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT hit_count FROM skills WHERE id = ?", arguments: ["技能X"])
        }
        XCTAssertEqual(xCount, 1)
        let yCount = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT hit_count FROM skills WHERE id = ?", arguments: ["技能Y"])
        }
        XCTAssertEqual(yCount, 0)
    }

    // MARK: - 4. 近重复去重：窄的赢

    func testNearDuplicateKeepsNarrowerScope() async throws {
        let queryText = "KANO 模型将需求分为基本型、期望型、兴奋型三类，先分类再排优先级"
        // 全局与项目 B 各一条内容极相似（只差一个句号）的卡
        try insertCard(id: "kp-global-dup", projectId: "", content: queryText)
        try insertCard(id: "kp-project-dup", projectId: "项目B", content: queryText + "。")

        let retriever = Retriever(database: database, embedder: embedder)
        let trace = try await retriever.search(query: queryText, project: "项目B")

        let cardHits = trace.hits.filter { $0.library == .cards }
        XCTAssertEqual(cardHits.count, 1, "近重复（cosine > 0.95）应只保留一条")
        let hit = try XCTUnwrap(cardHits.first)
        XCTAssertEqual(hit.id, "kp-project-dup", "窄的赢：project 赢 global")
        XCTAssertEqual(hit.scope, "project")
        XCTAssertEqual(hit.scopeId, "项目B")
    }

    // MARK: - 5. 增量 indexCard / indexSkill：可命中 + 幂等

    func testIncrementalIndexCardIdempotent() async throws {
        let card = MethodologyCard(
            id: "kp_incremental",
            content: "用户访谈方法论：先定访谈目标再列提纲，避免引导性问题"
        )
        try await IndexRebuilder.indexCard(
            card, projectId: "增量项目", database: database, embeddingProvider: embedder
        )

        let retriever = Retriever(database: database, embedder: embedder)
        let trace = try await retriever.search(
            query: "用户访谈：先定访谈目标再列提纲", project: "增量项目"
        )
        let hit = try XCTUnwrap(trace.hits.first { $0.id == "kp_incremental" })
        XCTAssertEqual(hit.scope, "project")
        XCTAssertEqual(hit.scopeId, "增量项目")

        // 幂等：重复索引不新增行（upsert 同 id 覆盖）
        try await IndexRebuilder.indexCard(
            card, projectId: "增量项目", database: database, embeddingProvider: embedder
        )
        let count = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_points")
        }
        XCTAssertEqual(count, 1)
    }

    func testIncrementalIndexSkillSearchable() async throws {
        let skill = SkillDocument(
            name: "访谈提纲技能",
            whenToUse: "用户访谈前列提纲时",
            bestFor: ["访谈目标"],
            tags: ["访谈", "interview"]
        )
        try await IndexRebuilder.indexSkill(
            skill, database: database, embeddingProvider: embedder
        )

        let retriever = Retriever(database: database, embedder: embedder)
        let trace = try await retriever.search(query: "用户访谈前列提纲时", project: "任意项目")
        XCTAssertTrue(trace.hits.contains { $0.id == "访谈提纲技能" && $0.library == .skills })
    }

    // MARK: - 6. PitfallsRouter 确定性路由

    func testPitfallsRouterDeterministicRouting() throws {
        try insertSkill(
            id: "原型技能", name: "原型技能",
            whenToUse: "产出高保真原型时",
            tags: ["原型", "wireframe"],
            pitfalls: ["p1", "p2"]
        )
        try insertSkill(
            id: "竞品技能", name: "竞品技能",
            whenToUse: "摸清竞品格局",
            tags: ["竞品"],
            pitfalls: ["q1"]
        )

        let entries = try PitfallsRouter.pitfalls(for: .prototype, database: database)
        // 只返回第一条技能的 2 条 Entry，source 恒为 "pitfalls确定性路由"
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.pitfall), ["p1", "p2"])
        XCTAssertTrue(entries.allSatisfy { $0.skill == "原型技能" })
        XCTAssertTrue(entries.allSatisfy { $0.source == "pitfalls确定性路由" })
        XCTAssertFalse(entries.contains { $0.skill == "竞品技能" })

        // 关键词命不中的阶段 / 无映射阶段返回空
        XCTAssertTrue(try PitfallsRouter.pitfalls(for: .clarify, database: database).isEmpty)
        XCTAssertTrue(try PitfallsRouter.pitfalls(for: .review, database: database).isEmpty)
    }

    // MARK: - 7. EmbeddingClient 响应解析（不发网络）

    func testEmbeddingResponseParsing() throws {
        // 乱序 index 对齐：data 中 index=1 在前，结果仍按输入顺序排列
        let disordered = """
        {"data":[{"index":1,"embedding":[0.2,0.4]},{"index":0,"embedding":[0.1,0.3]}]}
        """
        let vectors = try EmbeddingClient.parseResponse(Data(disordered.utf8), count: 2)
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [0.1, 0.3])
        XCTAssertEqual(vectors[1], [0.2, 0.4])

        // 维度不一致 → 抛错
        let badDimensions = """
        {"data":[{"index":0,"embedding":[0.1]},{"index":1,"embedding":[0.1,0.2]}]}
        """
        XCTAssertThrowsError(try EmbeddingClient.parseResponse(Data(badDimensions.utf8), count: 2))

        // 缺行（count=2 只回来 1 行）→ 抛错
        let missingRow = """
        {"data":[{"index":0,"embedding":[0.1,0.2]}]}
        """
        XCTAssertThrowsError(try EmbeddingClient.parseResponse(Data(missingRow.utf8), count: 2))

        // 多行（count=2 回来 3 行）→ 抛错
        let extraRow = """
        {"data":[{"index":0,"embedding":[0.1]},{"index":1,"embedding":[0.2]},{"index":2,"embedding":[0.3]}]}
        """
        XCTAssertThrowsError(try EmbeddingClient.parseResponse(Data(extraRow.utf8), count: 2))

        // 空输入（count=0，data 缺失）→ 空
        let empty = try EmbeddingClient.parseResponse(Data("{}".utf8), count: 0)
        XCTAssertEqual(empty, [])
    }
}
