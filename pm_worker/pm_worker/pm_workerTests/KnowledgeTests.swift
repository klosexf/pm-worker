//
//  KnowledgeTests.swift
//  pm_workerTests
//
//  M4 Task 4.4 + 4.5：方法论卡抽取、归属分流、实战注记、主动推荐、记忆校准注入。
//  - KnowledgeExtractor：抽取 prompt / 宽松解析 / 归属合并三分支（E10）/ 落卡往返 + 增量索引 / 旧卡让位
//  - AnnotationWriter：实战注记 append-only + 幂等 + 补区头 + parse 回读
//  - Recommender：阶段推荐（阈值过滤 / 降序 / 上限 3 / 同阶段不重复被拒项 / 确定性理由）
//  - KnowledgeCalibration：经验按假设态注入（主题匹配 / 非 experience 不注入）
//  - MemoryStore.recordExperience / allExperiences：经验沉淀落盘 + 跨项目聚合 + 覆盖语义
//  - MemoryStore 经验校准：注入置待校准（幂等）→ 确认/否定升降置信度（边界 clamp）
//  不依赖网络：DeterministicHashEmbedder + 临时目录（rootOverride）+ 临时 AppDatabase。
//

import XCTest
import GRDB
@testable import pm_worker

final class KnowledgeTests: XCTestCase {
    var tempRoot: URL!
    var database: AppDatabase!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-knowledge-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - 1. 抽取 prompt 与宽松解析

    func testExtractionPromptAndParse() {
        // prompt 携带原文与 schema 约束；transcript 置顶（确认链三连抽共享缓存前缀）
        let prompt = KnowledgeExtractor.extractionPrompt(transcript: "用户说：先访谈再定档")
        XCTAssertTrue(prompt.hasPrefix("## 对话记录\n用户说：先访谈再定档"))
        XCTAssertTrue(prompt.contains("先访谈再定档"))
        XCTAssertTrue(prompt.contains("JSON"))

        // 标准 JSON 数组 → 正常解析
        let standard = """
        [{"title": "访谈先行", "content": "先定访谈目标再列提纲", "confidence": 0.9}]
        """
        var items = KnowledgeExtractor.parse(reply: standard)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "访谈先行")
        XCTAssertEqual(items[0].content, "先定访谈目标再列提纲")
        XCTAssertEqual(items[0].confidence, 0.9, accuracy: 1e-9)

        // 围栏 + 前后废话 → 剥出；confidence 越界 → clamp 到 1
        let fenced = """
        好的，以下是抽取结果：
        ```json
        [{"title": "KANO 需求分类", "content": "KANO 模型将需求分为基本型、期望型、兴奋型三类", "confidence": 1.5}]
        ```
        希望有帮助。
        """
        items = KnowledgeExtractor.parse(reply: fenced)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "KANO 需求分类")
        XCTAssertEqual(items[0].confidence, 1.0, accuracy: 1e-9)

        // 无 title → 取正文前 20 字；无 confidence → 默认 0.8
        let missingFields = """
        [{"content": "一二三四五六七八九十一二三四五六七八九十一二三四五"}]
        """
        items = KnowledgeExtractor.parse(reply: missingFields)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title.count, 20)
        XCTAssertEqual(items[0].confidence, 0.8, accuracy: 1e-9)

        // 负 confidence → clamp 到 0
        items = KnowledgeExtractor.parse(
            reply: "[{\"title\": \"t\", \"content\": \"c\", \"confidence\": -0.5}]"
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].confidence, 0, accuracy: 1e-9)

        // 缺 content 的条目被丢弃；空数组 / 非 JSON 输入 → []
        XCTAssertEqual(KnowledgeExtractor.parse(reply: "[{\"title\": \"无正文\"}]"), [])
        XCTAssertEqual(KnowledgeExtractor.parse(reply: "[]"), [])
        XCTAssertEqual(KnowledgeExtractor.parse(reply: "这不是 JSON"), [])
    }

    // MARK: - 2. 归属合并判定（E10：三分支 + 优先级）

    func testMergeDecision() {
        let item = KnowledgeExtractor.ExtractedKnowledge(
            title: "KANO 需求分类",
            content: "KANO 模型将需求分为基本型、期望型、兴奋型三类，先分类再排优先级",
            confidence: 0.9
        )
        let itemVec = DeterministicHashEmbedder.vector(for: item.content)

        // ① 近重复（同内容 cosine = 1 > 0.92）→ mergeInto（同一概念第二次触发不新建）
        //    多卡混合时 merge 优先于 conflict（近重复卡赢）
        let dup = (
            id: "kp_dup", title: "KANO 分类法",
            content: item.content,
            embedding: DeterministicHashEmbedder.vector(for: item.content)
        )
        let improved = "MoSCoW method groups requirements into Must, Should, Could and Won't buckets"
        let sameTopic = (
            id: "kp_old", title: "kano需求分类",  // 归一化后与 item 标题一致
            content: improved,
            embedding: DeterministicHashEmbedder.vector(for: improved)
        )
        XCTAssertEqual(
            KnowledgeExtractor.mergeDecision(for: item, existing: [dup, sameTopic], itemEmbedding: itemVec),
            .mergeInto(existingId: "kp_dup")
        )

        // ② 同主题（标题归一化一致）但内容实质改良（非近重复）→ conflict（旧卡让位）
        XCTAssertEqual(
            KnowledgeExtractor.mergeDecision(for: item, existing: [sameTopic], itemEmbedding: itemVec),
            .conflict(existingId: "kp_old")
        )

        // ③ 无关既有卡 → newCard
        let unrelated = (
            id: "kp_other", title: "RBAC 权限设计",
            content: "基于角色的最小权限原则设计后台权限",
            embedding: DeterministicHashEmbedder.vector(for: "基于角色的最小权限原则设计后台权限")
        )
        XCTAssertEqual(
            KnowledgeExtractor.mergeDecision(for: item, existing: [unrelated], itemEmbedding: itemVec),
            .newCard
        )

        // ④ 无既有卡 → newCard
        XCTAssertEqual(
            KnowledgeExtractor.mergeDecision(for: item, existing: [], itemEmbedding: itemVec),
            .newCard
        )
    }

    // MARK: - 3. 落卡：write-then-verify + parse 往返 + 增量索引

    @MainActor
    func testWriteCardRoundTripAndIncrementalIndex() async throws {
        let card = try await KnowledgeExtractor.writeCard(
            content: "用户访谈方法论：先定访谈目标再列提纲，避免引导性问题",
            confidence: 1.5,  // 越界 → clamp 到 1.0
            sourceType: "manual",
            sourceRef: "测试项目/v1",
            database: database,
            embeddingProvider: DeterministicHashEmbedder()
        )

        // 落盘路径：cards/<id>.md
        let url = PMAgentStore.cardsDir.appendingPathComponent("\(card.id).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // MethodologyCard.parse 回读：字段往返一致
        let parsed = try XCTUnwrap(
            MethodologyCard.parse(markdown: try String(contentsOf: url, encoding: .utf8))
        )
        XCTAssertEqual(parsed.id, card.id)
        XCTAssertEqual(parsed.content, card.content)
        XCTAssertEqual(parsed.confidence, 1.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.sourceType, "manual")
        XCTAssertEqual(parsed.sourceRef, "测试项目/v1")
        XCTAssertNil(parsed.project)       // 方法论卡全局（跨项目直接用不降级）
        XCTAssertNil(parsed.supersededBy)  // 新卡未让位
        XCTAssertTrue(parsed.annotations.isEmpty)

        // 增量索引：knowledge_points 表有对应行（写完即建索引）
        let count = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM knowledge_points WHERE id = ?",
                arguments: [card.id]
            )
        }
        XCTAssertEqual(count, 1)

        // cardMarkdown 序列化带注记的卡 → parse 往复读出注记（三方同格式）
        var annotated = MethodologyCard(id: "kp_annotated", content: "注记往返正文")
        annotated.annotations = [
            .init(date: "2026-09-10", project: "健身App", note: "首次实战有效"),
            .init(date: "2026-09-11", project: "电商中台", note: "第二次使用"),
        ]
        let reparsed = MethodologyCard.parse(markdown: KnowledgeExtractor.cardMarkdown(annotated))
        XCTAssertEqual(reparsed?.annotations, annotated.annotations)
        XCTAssertEqual(reparsed?.content, "注记往返正文")
    }

    // MARK: - 4. 旧卡让位（冲突消解链）

    @MainActor
    func testMarkSuperseded() async throws {
        // 纯文件模式（database: nil）落卡不崩
        let card = try await KnowledgeExtractor.writeCard(
            content: "旧版方法论：拍脑袋定优先级",
            confidence: 0.7,
            sourceType: "methodology",
            sourceRef: "甲/v1",
            database: nil,
            embeddingProvider: DeterministicHashEmbedder()
        )
        let url = PMAgentStore.cardsDir.appendingPathComponent("\(card.id).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // 让位 → supersededBy 回链写回
        try KnowledgeExtractor.markSuperseded(cardURL: url, by: "kp_new")
        let parsed = try XCTUnwrap(
            MethodologyCard.parse(markdown: try String(contentsOf: url, encoding: .utf8))
        )
        XCTAssertEqual(parsed.supersededBy, "kp_new")
        XCTAssertEqual(parsed.content, card.content)  // 正文与元数据其余部分不动

        // 文件不存在 → 抛错（不让位静默失败）
        XCTAssertThrowsError(
            try KnowledgeExtractor.markSuperseded(
                cardURL: PMAgentStore.cardsDir.appendingPathComponent("kp_不存在.md"), by: "x"
            )
        )
    }

    // MARK: - 5. 实战注记（append-only + 幂等 + 补区头）

    func testAnnotationWriter() throws {
        // 手写卡（无注记区）
        let url = tempRoot.appendingPathComponent("card-manual.md")
        try PMAgentStore.writeVerified(
            """
            ---
            id: kp_manual
            source_type: manual
            source_ref:
            project:
            confidence: 1.0
            supersededBy: null
            created: 2026-09-11
            ---
            手写方法论正文：先定目标再动手。
            """,
            to: url
        )

        // 追加第一条：自动补注记区头
        try AnnotationWriter.append(
            cardURL: url, note: "首次实战有效", project: "健身App", date: "2026-09-10"
        )
        var parsed = try XCTUnwrap(
            MethodologyCard.parse(markdown: try String(contentsOf: url, encoding: .utf8))
        )
        XCTAssertEqual(parsed.annotations.count, 1)
        XCTAssertEqual(parsed.annotations.first?.date, "2026-09-10")
        XCTAssertEqual(parsed.annotations.first?.project, "健身App")
        XCTAssertEqual(parsed.annotations.first?.note, "首次实战有效")
        XCTAssertEqual(parsed.content, "手写方法论正文：先定目标再动手。")  // 正文不被污染

        // 已有注记区 → 追加第二条（只增不覆盖，越用越厚）
        try AnnotationWriter.append(
            cardURL: url, note: "第二次使用", project: "电商中台", date: "2026-09-11"
        )
        parsed = try XCTUnwrap(
            MethodologyCard.parse(markdown: try String(contentsOf: url, encoding: .utf8))
        )
        XCTAssertEqual(parsed.annotations.count, 2)
        XCTAssertEqual(parsed.annotations.map(\.project), ["健身App", "电商中台"])

        // 幂等：完全相同的注记行重复追加不产生重复
        try AnnotationWriter.append(
            cardURL: url, note: "首次实战有效", project: "健身App", date: "2026-09-10"
        )
        parsed = try XCTUnwrap(
            MethodologyCard.parse(markdown: try String(contentsOf: url, encoding: .utf8))
        )
        XCTAssertEqual(parsed.annotations.count, 2)

        // 文件不存在 → 抛错
        XCTAssertThrowsError(
            try AnnotationWriter.append(
                cardURL: tempRoot.appendingPathComponent("nope.md"),
                note: "x", project: "y", date: "z"
            )
        )
    }

    // MARK: - 6. 主动推荐（阈值 / 降序 / 上限 3 / 拒绝过滤 / 确定性理由）

    func testRecommender() {
        // 手工构造 2 维向量：余弦完全确定（不依赖哈希向量的相似度分布）
        let query: [Float] = [1, 0]
        let cards: [(id: String, title: String, content: String, annotationCount: Int, scope: String, embedding: [Float])] = [
            (id: "kp_1", title: "卡一", content: "内容一", annotationCount: 2, scope: "global", embedding: [1, 0]),        // 1.0
            (id: "kp_2", title: "卡二", content: "内容二", annotationCount: 0, scope: "project", embedding: [0.8, 0.6]),   // 0.8
            (id: "kp_3", title: "卡三", content: "内容三", annotationCount: 0, scope: "global", embedding: [0.6, 0.8]),    // 0.6
            (id: "kp_4", title: "卡四", content: "内容四", annotationCount: 0, scope: "global", embedding: [0, 1]),        // 0 → 低于阈值
            (id: "kp_5", title: "卡五", content: "内容五", annotationCount: 0, scope: "global", embedding: []),            // 零长度 → 跳过
        ]

        var recs = Recommender.recommend(
            stage: .structure, project: "P", cards: cards,
            stageSummary: "搭建信息架构", queryEmbedding: query, rejected: []
        )
        // 降序 + 上限 3（kp_4 低于阈值、kp_5 空向量被跳过）
        XCTAssertEqual(recs.map(\.id), ["kp_1", "kp_2", "kp_3"])
        XCTAssertEqual(recs[0].score, 1.0, accuracy: 1e-9)
        // 0.8/0.6 在 float32 下有 ~1e-8 表示误差，精度放到 1e-6
        XCTAssertEqual(recs[1].score, 0.8, accuracy: 1e-6)

        // 确定性理由：相关度百分比 / scope 中文 / 注记厚度 / 阶段要点
        XCTAssertTrue(recs[0].reason.contains("相关度 100%"))
        XCTAssertTrue(recs[0].reason.contains("全局方法论"))
        XCTAssertTrue(recs[0].reason.contains("已被实战验证 2 次"))
        XCTAssertTrue(recs[0].reason.contains("阶段要点"))
        XCTAssertTrue(recs[1].reason.contains("本项目方法论"))
        XCTAssertFalse(recs[1].reason.contains("已被实战验证"))  // 0 条注记不拼该段

        // 同阶段不重复被拒项（E23）
        recs = Recommender.recommend(
            stage: .structure, project: "P", cards: cards,
            stageSummary: "搭建信息架构", queryEmbedding: query, rejected: ["kp_1", "kp_2"]
        )
        XCTAssertEqual(recs.map(\.id), ["kp_3"])

        // 标题派生：正文首行清洗 + 句界截 32（2026-09-17 升级：不再 20 字硬切半句）
        XCTAssertEqual(Recommender.title(of: "第一行标题\n第二行"), "第一行标题")
        XCTAssertEqual(Recommender.title(of: String(repeating: "长", count: 30)).count, 30)  // 30 字未超 32 上限不截
        XCTAssertEqual(Recommender.title(of: String(repeating: "长", count: 40)).count, 32)
        // 「定义：」引导词剥离
        XCTAssertEqual(Recommender.title(of: "定义：KANO 需求分类"), "KANO 需求分类")
        // 句界回退：超限长句在最近逗号处断，不硬切半句
        let longSentence = String(repeating: "长", count: 30) + "，" + String(repeating: "尾", count: 30)
        XCTAssertEqual(Recommender.title(of: longSentence), String(repeating: "长", count: 30))
        // 是什么摘要：跳过标题行取正文首段
        XCTAssertTrue(Recommender.plainSummary(of: "## 标题\n把需求分成三类再排优先级。问卷判定。").hasPrefix("把需求分成三类"))

        // 详情弹层方案 B 三段解析：新卡三段多行结构逐行归段
        let segments = Recommender.contentSegments(of:
            "定义：方向词只是入口，不是需求。\n必须下钻确认真任务。\n做法：先复述字面诉求，再列真实任务层。\n适用边界：需求澄清阶段；核心任务确认即停。"
        )
        XCTAssertEqual(segments.definition, "方向词只是入口，不是需求。\n必须下钻确认真任务。")
        XCTAssertEqual(segments.how, "先复述字面诉求，再列真实任务层。")
        XCTAssertEqual(segments.boundary, "需求澄清阶段；核心任务确认即停。")

        // 旧单行整段卡：段界标记前内联补换行后同路解析（不丢内容）
        let inline = Recommender.contentSegments(
            of: "定义：方向词只是入口。做法：先复述再收口。适用边界：澄清阶段。"
        )
        XCTAssertEqual(inline.definition, "方向词只是入口。")
        XCTAssertEqual(inline.how, "先复述再收口。")
        XCTAssertEqual(inline.boundary, "澄清阶段。")

        // 自由卡（无任何段界标记）：首行归定义、其余归做法
        let freeform = Recommender.contentSegments(of: "复述用户诉求后再动方案\n一次问清胜过多轮挤牙膏")
        XCTAssertEqual(freeform.definition, "复述用户诉求后再动方案")
        XCTAssertEqual(freeform.how, "一次问清胜过多轮挤牙膏")
        XCTAssertNil(freeform.boundary)

        // 半角冒号段界同样识别
        let halfColon = Recommender.contentSegments(of: "定义:入口非需求\n做法:复述后收口\n适用边界:澄清期")
        XCTAssertEqual(halfColon.definition, "入口非需求")
        XCTAssertEqual(halfColon.how, "复述后收口")
        XCTAssertEqual(halfColon.boundary, "澄清期")
    }

    // MARK: - 7. 记忆校准注入（经验按假设态标签注入）

    func testCalibrationContext() {
        let memories: [MemoryEntry] = [
            // 相关经验：4 字窗口命中（「kano」出现在正文中）
            MemoryEntry(
                scope: .project, scopeId: "甲", kind: .experience,
                content: "上次用 KANO 把数据精度错标成期望型，访谈交叉验证后再定档",
                sourceRef: "甲/v1", confidence: 0.8
            ),
            // 内容匹配但非 experience kind → 不注入（结论走常规记忆注入区）
            MemoryEntry(
                scope: .project, scopeId: "乙", kind: .conclusion,
                content: "KANO 相关结论不应在此注入"
            ),
            // experience kind 但主题无关 → 不注入
            MemoryEntry(
                scope: .project, scopeId: "丙", kind: .experience,
                content: "完全无关的云主机成本优化经验"
            ),
        ]

        let context = KnowledgeCalibration.calibrationContext(
            cardTitle: "KANO 需求分类", memories: memories
        )
        // 假设态标签 + 经验正文 + 出处 + 置信度
        XCTAssertTrue(context.contains("假设态"))
        XCTAssertTrue(context.contains("上次用 KANO 把数据精度错标成期望型"))
        XCTAssertTrue(context.contains("甲/v1"))
        XCTAssertTrue(context.contains("0.8"))
        // 非经验条目与无关经验不出现
        XCTAssertFalse(context.contains("相关结论不应在此注入"))
        XCTAssertFalse(context.contains("云主机成本优化"))

        // 无匹配经验 / 空标题 → 不注入
        XCTAssertEqual(
            KnowledgeCalibration.calibrationContext(cardTitle: "北极星指标拆解", memories: memories),
            ""
        )
        XCTAssertEqual(
            KnowledgeCalibration.calibrationContext(cardTitle: "", memories: memories),
            ""
        )
    }

    // MARK: - 8. 经验沉淀（recordExperience：落盘载荷 + reload 可见 + 失败路径）

    @MainActor
    func testRecordExperience() throws {
        try PMAgentStore.createProject(named: "经验项目")
        try PMAgentStore.ensureWorkspace(project: "经验项目", version: "v1")
        let url = PMAgentStore.jsonlURL(
            project: "经验项目", version: "v1", file: "discussions.jsonl"
        )

        let store = MemoryStore(project: "经验项目", version: "v1")
        XCTAssertTrue(store.effective.isEmpty)

        // 沉淀一条经验（confidence 越界 → clamp）
        let report = store.recordExperience(
            content: "KANO 分类要访谈交叉验证，不能拍脑袋定档",
            sourceRef: "经验项目/v1",
            confidence: 1.5,
            sessionId: "s1"
        ) { line in
            try PMAgentStore.appendLine(line, to: url)
        }
        XCTAssertFalse(report.isEmpty)
        XCTAssertTrue(report.contains("经验已沉淀"))

        // 落盘行载荷校验：kind / sourceRef / confidence / scope
        let lines = PMAgentStore.readLines(DiscussionEntry.self, from: url)
        let memory = try XCTUnwrap(lines.first(where: { $0.memory?.kind == .experience })?.memory)
        XCTAssertEqual(memory.content, "KANO 分类要访谈交叉验证，不能拍脑袋定档")
        XCTAssertEqual(memory.sourceRef, "经验项目/v1")
        XCTAssertEqual(memory.confidence ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(memory.scope, .project)
        XCTAssertEqual(memory.invalidated, false)

        // reload 后 effective 可见（注入链路通）
        XCTAssertEqual(store.effective.count, 1)
        XCTAssertEqual(store.effective.first?.kind, .experience)

        // 写入失败路径：appendLine 抛错 → 返回空串（UI 提示重试）
        let failed = store.recordExperience(
            content: "x", sourceRef: "y", confidence: 0.5, sessionId: "s1"
        ) { _ in
            throw NSError(domain: "test", code: 1)
        }
        XCTAssertEqual(failed, "")
    }

    // MARK: - 9. 跨项目经验聚合（allExperiences：只聚经验 + 覆盖语义）

    @MainActor
    func testAllExperiencesCrossProjectAndSupersede() throws {
        // 两个项目各写一条经验 + 一条结论（甲用固定 id，供后续失效标记覆盖）
        let sources: [(project: String, experience: String, id: String)] = [
            ("项目甲", "甲经验：先访谈再定档", "m_fixed"),
            ("项目乙", "乙经验：原型先做灰盒", "m_kept"),
        ]
        for source in sources {
            try PMAgentStore.createProject(named: source.project)
            try PMAgentStore.ensureWorkspace(project: source.project, version: "v1")
            let url = PMAgentStore.jsonlURL(
                project: source.project, version: "v1", file: "discussions.jsonl"
            )
            try PMAgentStore.appendLine(
                DiscussionEntry(
                    id: UUID().uuidString, sessionId: "s", role: .system,
                    content: "经验行", think: nil,
                    memory: MemoryEntry(
                        id: source.id, scope: .project, scopeId: source.project,
                        kind: .experience,
                        content: source.experience, sourceRef: "\(source.project)/v1",
                        confidence: 0.7
                    ),
                    createdAt: "t"
                ),
                to: url
            )
            try PMAgentStore.appendLine(
                DiscussionEntry(
                    id: UUID().uuidString, sessionId: "s", role: .system,
                    content: "结论行", think: nil,
                    memory: MemoryEntry(
                        scope: .project, scopeId: "测试项目", kind: .conclusion,
                        content: "结论不应被聚合", versions: "v1"
                    ),
                    createdAt: "t"
                ),
                to: url
            )
        }

        // 只聚「经验」，结论不出现
        var all = MemoryStore.allExperiences()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.kind == .experience })
        XCTAssertFalse(all.contains { $0.content.contains("结论") })

        // 覆盖语义：项目甲追加同 id 失效标记行 → 该经验不再聚合
        let urlA = PMAgentStore.jsonlURL(project: "项目甲", version: "v1", file: "discussions.jsonl")
        try PMAgentStore.appendLine(
            DiscussionEntry(
                id: UUID().uuidString, sessionId: "s", role: .system,
                content: "覆盖行", think: nil,
                memory: MemoryEntry(
                    id: "m_fixed", scope: .project, scopeId: "项目甲", kind: .experience,
                    content: "甲经验：先访谈再定档",
                    invalidated: true, supersededBy: "m_new"
                ),
                createdAt: "t"
            ),
            to: urlA
        )
        all = MemoryStore.allExperiences()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.content, "乙经验：原型先做灰盒")
    }

    // MARK: - 10. 经验校准（注入标记 → 确认/否定，置信度自动升降）

    /// 沉淀一条经验并返回其 id（走 recordExperience 正式链路）。
    @MainActor
    private func sedimentExperience(
        _ content: String, confidence: Double,
        project: String, version: String, url: URL
    ) throws -> String {
        let store = MemoryStore(project: project, version: version)
        _ = store.recordExperience(
            content: content, sourceRef: "\(project)/\(version)", confidence: confidence,
            sessionId: "s1"
        ) { line in
            try PMAgentStore.appendLine(line, to: url)
        }
        return try XCTUnwrap(store.effective.first(where: { $0.content == content })?.id)
    }

    @MainActor
    func testExperienceCalibrationLifecycle() throws {
        try PMAgentStore.createProject(named: "校准项目")
        try PMAgentStore.ensureWorkspace(project: "校准项目", version: "v1")
        let url = PMAgentStore.jsonlURL(
            project: "校准项目", version: "v1", file: "discussions.jsonl"
        )
        let entryId = try sedimentExperience(
            "KANO 分类要访谈交叉验证，不能拍脑袋定档",
            confidence: MemoryStore.experienceHypothesisConfidence,
            project: "校准项目", version: "v1", url: url
        )

        // ① 注入标记：置待校准 + 记注入时间，置信度不动
        XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: [entryId]), 1)
        let calibrated = try XCTUnwrap(
            MemoryStore.allExperiences().first(where: { $0.id == entryId })
        )
        XCTAssertEqual(calibrated.calibrationPending, true)
        XCTAssertNotNil(calibrated.lastInjectedAt)
        XCTAssertEqual(
            calibrated.confidence ?? -1,
            MemoryStore.experienceHypothesisConfidence, accuracy: 1e-9
        )

        // 幂等：已 pending 不重复标记（返回 0，不落新行）
        let lineCountBefore = PMAgentStore.readLines(DiscussionEntry.self, from: url).count
        XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: [entryId]), 0)
        XCTAssertEqual(
            PMAgentStore.readLines(DiscussionEntry.self, from: url).count, lineCountBefore
        )

        // ② 确认有效：0.7 + 0.1 = 0.8，清除待校准
        let confirmed = try XCTUnwrap(
            MemoryStore.applyExperienceCalibration(id: entryId, confirmed: true)
        )
        XCTAssertEqual(confirmed.confidence ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(confirmed.calibrationPending, false)

        // ③ 再注入 → 否定：0.8 − 0.2 = 0.6（负证据降得快）
        XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: [entryId]), 1)
        let rejected = try XCTUnwrap(
            MemoryStore.applyExperienceCalibration(id: entryId, confirmed: false)
        )
        XCTAssertEqual(rejected.confidence ?? -1, 0.6, accuracy: 1e-9)

        // ④ 无待校准标记 → 拒绝回写（防重复升降）；未知 id → 0（未标记任何条目）
        XCTAssertNil(MemoryStore.applyExperienceCalibration(id: entryId, confirmed: true))
        XCTAssertNil(MemoryStore.applyExperienceCalibration(id: "m_不存在", confirmed: true))
        XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: ["m_不存在"]), 0)
    }

    @MainActor
    func testExperienceCalibrationBoundariesAndKindGuard() throws {
        try PMAgentStore.createProject(named: "边界项目")
        try PMAgentStore.ensureWorkspace(project: "边界项目", version: "v1")
        let url = PMAgentStore.jsonlURL(
            project: "边界项目", version: "v1", file: "discussions.jsonl"
        )

        // 上限：confidence 1.0 确认后仍为 1.0（不破 1）
        let topId = try sedimentExperience(
            "上限经验：天花板测试", confidence: 1.0,
            project: "边界项目", version: "v1", url: url
        )
        XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: [topId]), 1)
        let topped = try XCTUnwrap(
            MemoryStore.applyExperienceCalibration(id: topId, confirmed: true)
        )
        XCTAssertEqual(topped.confidence ?? -1, 1.0, accuracy: 1e-9)

        // 下限：0.1 连续两轮否定 → 0.0 触底不转负
        let lowId = try sedimentExperience(
            "下限经验：触底测试", confidence: 0.1,
            project: "边界项目", version: "v1", url: url
        )
        for _ in 0..<2 {
            XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: [lowId]), 1)
            let rejected = try XCTUnwrap(
                MemoryStore.applyExperienceCalibration(id: lowId, confirmed: false)
            )
            XCTAssertGreaterThanOrEqual(rejected.confidence ?? -1, 0)
        }
        let grounded = try XCTUnwrap(
            MemoryStore.allExperiences().first(where: { $0.id == lowId })
        )
        XCTAssertEqual(grounded.confidence ?? -1, 0.0, accuracy: 1e-9)

        // 非「经验」条目不参与校准（结论 / 约束不走该机制）
        let conclusion = MemoryEntry(
            scope: .project, scopeId: "测试项目", kind: .conclusion,
            content: "结论不参与校准", versions: "v1"
        )
        try PMAgentStore.appendLine(
            DiscussionEntry(
                id: UUID().uuidString, sessionId: "s", role: .system,
                content: "结论行", think: nil, memory: conclusion, createdAt: "t"
            ),
            to: url
        )
        XCTAssertEqual(MemoryStore.markExperiencesPendingCalibration(ids: [conclusion.id]), 0)
        XCTAssertNil(MemoryStore.applyExperienceCalibration(id: conclusion.id, confirmed: true))
    }
}
