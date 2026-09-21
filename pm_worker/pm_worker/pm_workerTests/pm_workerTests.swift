//
//  pm_workerTests.swift
//  pm_workerTests
//
//  Created by 陈晓峰 on 2026/9/10.
//

import XCTest
import GRDB
@testable import pm_worker

final class StorageTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - Bootstrap（§5.1 目录规范）

    func testBootstrapCreatesDirectoryTree() throws {
        try PMAgentStore.bootstrap()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: PMAgentStore.skillsDir.path))
        XCTAssertTrue(fm.fileExists(atPath: PMAgentStore.cardsDir.path))
        let defaultDir = PMAgentStore.projectURL("默认")
        XCTAssertTrue(fm.fileExists(atPath: defaultDir.path))
        XCTAssertTrue(fm.fileExists(
            atPath: defaultDir.appendingPathComponent("unversioned").path
        ))

        let project = try XCTUnwrap(try PMAgentStore.readProject("默认"))
        XCTAssertEqual(project.id, "proj_default")
        XCTAssertEqual(project.name, "默认")

        // 幂等：重复调用不报错
        XCTAssertNoThrow(try PMAgentStore.bootstrap())
    }

    func testCreateProjectAndVersion() throws {
        try PMAgentStore.bootstrap()
        let project = try PMAgentStore.createProject(named: "我的健身App")
        XCTAssertEqual(project.name, "我的健身App")
        XCTAssertEqual(PMAgentStore.listProjects(), ["默认", "我的健身App"])

        // 重名报错
        XCTAssertThrowsError(try PMAgentStore.createProject(named: "我的健身App"))

        // 建版本：完整目录树 + jsonl 三件套 + project.json 回写
        let version = try PMAgentStore.createVersion("v1.0", in: "我的健身App", scope: ["社区动态"])
        XCTAssertEqual(version.status, .planning)

        let versionDir = PMAgentStore.versionURL(project: "我的健身App", version: "v1.0")
        let fm = FileManager.default
        for stage in [
            "01-requirements", "02-structure", "03-prototypes", "04-prd",
            "05-analysis", "06-discussions", "07-reports",
        ] {
            XCTAssertTrue(fm.fileExists(atPath: versionDir.appendingPathComponent(stage).path), "缺少 \(stage)")
        }
        for file in ["decisions.jsonl", "risks.jsonl", "discussions.jsonl", "version.json"] {
            XCTAssertTrue(fm.fileExists(atPath: versionDir.appendingPathComponent(file).path), "缺少 \(file)")
        }

        let updated = try XCTUnwrap(try PMAgentStore.readProject("我的健身App"))
        XCTAssertEqual(updated.versions, ["v1.0"])
        XCTAssertEqual(updated.currentVersion, "v1.0")

        // 重名版本报错
        XCTAssertThrowsError(try PMAgentStore.createVersion("v1.0", in: "我的健身App"))
    }

    // MARK: - JSONL（append-only）

    func testDecisionAndRiskJSONL() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "测试项目")
        try PMAgentStore.createVersion("v1.0", in: "测试项目")

        let decisionsURL = PMAgentStore.jsonlURL(
            project: "测试项目", version: "v1.0", file: "decisions.jsonl"
        )
        let decision = DecisionRecord(
            version: "v1.0",
            decision: "目标用户锁定健身小白",
            why: "专业人群已有成熟方案",
            rejectedAlternatives: [RejectedAlternative(option: "覆盖全人群", reason: "资源撑不起")],
            confidence: 0.8,
            toBeVerified: true
        )
        try PMAgentStore.appendLine(decision, to: decisionsURL)
        try PMAgentStore.appendLine(
            RiskHitRecord(riskId: "r_001", predicted: "原型超 5 页难维护", actual: "第 3 轮即超"),
            to: decisionsURL
        )

        let entries = PMAgentStore.readLines(DecisionLogEntry.self, from: decisionsURL)
        XCTAssertEqual(entries.count, 2)
        guard case .decision(let d) = entries[0], case .riskHit(let hit) = entries[1] else {
            return XCTFail("解码失败")
        }
        XCTAssertEqual(d.decision, "目标用户锁定健身小白")
        XCTAssertEqual(d.rejectedAlternatives.count, 1)
        XCTAssertTrue(d.toBeVerified)
        XCTAssertEqual(hit.riskId, "r_001")
        XCTAssertEqual(hit.type, "risk_hit")

        // risks.jsonl
        let risksURL = PMAgentStore.jsonlURL(
            project: "测试项目", version: "v1.0", file: "risks.jsonl"
        )
        let risk = RiskRecord(
            version: "v1.0",
            stage: .prototype,
            hypothesis: "P0 页面数超过 5 将难以维护",
            triggerSignal: .prototypeRegen,
            originRef: "03-prototypes/self-review-round2.md"
        )
        try PMAgentStore.appendLine(risk, to: risksURL)
        let risks = PMAgentStore.readLines(RiskRecord.self, from: risksURL)
        XCTAssertEqual(risks.count, 1)
        XCTAssertEqual(risks[0].triggerSignal, .prototypeRegen)
        XCTAssertEqual(risks[0].status, .open)
    }

    // MARK: - GRDB 五表

    func testDatabaseCreatesFiveTables() throws {
        let dbPath = tempRoot.appendingPathComponent("index.sqlite")
        let db = try AppDatabase(indexURL: dbPath)

        let tables = try db.dbQueue.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
        XCTAssertEqual(
            Set(tables).subtracting(["grdb_migrations"]),  // grdb_migrations 为 GRDB 内部表
            ["knowledge_points", "skills", "pipeline_runs", "risks", "mcp_tasks"]
        )
    }

    // MARK: - 索引重建（文件是唯一事实源）

    func testIndexRebuildFromFiles() throws {
        try PMAgentStore.bootstrap(seedSkills: false)  // 干净 skills/，只验证测试自建文件→索引
        try PMAgentStore.createProject(named: "项目A")
        try PMAgentStore.createVersion("v1.0", in: "项目A")

        // 全局 cards/ 一张方法论卡
        let card = """
        ---
        id: kp_001
        source_type: methodology
        source_ref: v1.1/06-discussions/02-structure-notes.md#D3
        project:
        confidence: 0.9
        supersededBy: null
        created: 2026-09-09
        ---
        KANO 模型：将需求分为基本型/期望型/兴奋型三类，先分类再排优先级。

        ## 实战注记（append-only · 只增不覆盖——越用越厚）
        - 2026-09-10 · 健身App v1.1：把「数据精度」错标为基本型
        """
        try card.write(
            to: PMAgentStore.cardsDir.appendingPathComponent("kano.md"),
            atomically: true, encoding: .utf8
        )

        // 全局 skills/ 一个技能
        let skill = """
        ---
        name: 竞品分析
        type: interactive
        when_to_use: 需要摸清竞品格局时
        best_for: ["产品定位", "差异化分析"]
        tags: ["竞品", "competitive"]
        pitfalls: ["只看功能清单不看数据", "拿国内产品对标海外市场"]
        ---
        # 竞品分析技能正文
        """
        try skill.write(
            to: PMAgentStore.skillsDir.appendingPathComponent("竞品分析.md"),
            atomically: true, encoding: .utf8
        )

        let db = try AppDatabase(indexURL: tempRoot.appendingPathComponent("index.sqlite"))
        let report = try IndexRebuilder.rebuild(database: db)
        XCTAssertEqual(report.knowledgePoints, 1)
        XCTAssertEqual(report.skills, 1)

        // 验证卡片行（含注记计数与来源字段）
        let kpRow = try db.dbQueue.read { database in
            try Row.fetchOne(
                database, sql: "SELECT * FROM knowledge_points WHERE id = ?", arguments: ["kp_001"]
            )
        }
        let row = try XCTUnwrap(kpRow)
        XCTAssertEqual(row["annotation_count"] as Int, 1)
        XCTAssertEqual(row["confidence"] as Double, 0.9)
        XCTAssertTrue((row["content"] as String).contains("KANO"))

        // 验证技能行（pitfalls JSON 数组可回读）
        let skillRow = try db.dbQueue.read { database in
            try Row.fetchOne(database, sql: "SELECT * FROM skills WHERE name = ?", arguments: ["竞品分析"])
        }
        let srow = try XCTUnwrap(skillRow)
        XCTAssertEqual(srow["type"] as String, "interactive")
        let pitfalls = try JSONDecoder().decode(
            [String].self, from: Data((srow["pitfalls"] as String).utf8)
        )
        XCTAssertEqual(pitfalls.count, 2)

        // 重建幂等：再跑一遍结果一致（删表全量 upsert）
        let report2 = try IndexRebuilder.rebuild(database: db)
        XCTAssertEqual(report2, report)
    }

    /// 2026-09-15 根因防回归：真实向量重建必须写「非空 embedding」——
    /// 旧生产入口全走同步零向量重建，技能语义检索恒零命中（路由退化为阶段锚点
    /// 每轮兜底，用户实测「离题提问也被注入高保真原型设计」）。
    func testAsyncRebuildWritesRealSkillVectors() async throws {
        try PMAgentStore.bootstrap(seedSkills: false)
        let skill = """
        ---
        name: 竞品分析
        type: interactive
        when_to_use: 需要摸清竞品格局时
        best_for: ["产品定位"]
        tags: ["竞品"]
        pitfalls: ["只看功能清单不看数据"]
        ---
        # 竞品分析技能正文
        """
        try skill.write(
            to: PMAgentStore.skillsDir.appendingPathComponent("竞品分析.md"),
            atomically: true, encoding: .utf8
        )

        let db = try AppDatabase(indexURL: tempRoot.appendingPathComponent("index.sqlite"))
        let report = try await IndexRebuilder.rebuild(
            database: db, embeddingProvider: DeterministicHashEmbedder()
        )
        XCTAssertEqual(report.skills, 1)

        let blob = try await db.dbQueue.read { database -> Data? in
            try Data.fetchOne(
                database, sql: "SELECT embedding FROM skills WHERE id = ?",
                arguments: ["竞品分析"]
            )
        }
        let embedding = try XCTUnwrap(blob)
        // 非空 + 维度对齐（检索层按此编码解出向量参与余弦）
        XCTAssertEqual(
            embedding.count,
            DeterministicHashEmbedder.dimensions * MemoryLayout<Float>.size
        )
    }

    // MARK: - 模型编解码往返

    func testSkillFrontMatterBlockList() throws {
        // skills-inventory §3 模板为块状列表语法
        let markdown = """
        ---
        name: KANO 模型
        type: component
        when_to_use: 需求优先级排序时
        best_for:
          - 新产品从 0 到 1 砍需求清单
          - 功能池超过 15 条需要分层
        tags: [prioritization, kano, 优先级]
        pitfalls:
          - 全标基本型：未过目标用户画像
          - 兴奋型排最高优先：缺失不致命
        ---
        # 正文标题
        """
        let skill = SkillFrontMatterParser.parse(markdown)
        let s = try! XCTUnwrap(skill)
        XCTAssertEqual(s.name, "KANO 模型")
        XCTAssertEqual(s.type, .component)
        XCTAssertEqual(s.whenToUse, "需求优先级排序时")
        XCTAssertEqual(s.bestFor.count, 2)
        XCTAssertEqual(s.tags.count, 3)
        XCTAssertEqual(s.pitfalls.count, 2)
        XCTAssertTrue(s.body.contains("# 正文标题"))
    }

    // MARK: - 真实内容资产解析（Task 0.3 交付物守卫）

    func testRealContentAssetsParse() throws {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let resources = testDir.deletingLastPathComponent()
            .appendingPathComponent("pm_worker", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        // 21 个技能：六字段完整 + 反模式章节 + 正文 1500 字软上限
        // （skills-inventory §2 首批 14 + §2.6 v1.2 追加 3 + §2.7 v1.3 追加 1 + §4.3 P1 v1.4 追加 3）
        let skillsDir = resources.appendingPathComponent("skills", isDirectory: true)
        let skillFiles = try FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        XCTAssertEqual(skillFiles.count, 21, "技能数应为 21（skills-inventory §2 + §2.6 + §2.7 + §4.3 P1）")

        for file in skillFiles {
            let markdown = try String(contentsOf: file, encoding: .utf8)
            let skill = try XCTUnwrap(
                SkillFrontMatterParser.parse(markdown),
                "\(file.lastPathComponent) front-matter 解析失败"
            )
            XCTAssertFalse(skill.name.isEmpty)
            XCTAssertEqual(skill.type, .component, "\(skill.name) type 异常")
            XCTAssertFalse(skill.whenToUse.isEmpty)
            XCTAssertEqual(skill.bestFor.count, 3, "\(skill.name) best_for 应为 3")
            XCTAssertGreaterThanOrEqual(skill.tags.count, 3, "\(skill.name) tags 过少")
            XCTAssertGreaterThanOrEqual(skill.pitfalls.count, 3, "\(skill.name) pitfalls 过少")
            XCTAssertTrue(skill.body.contains("## 反模式"), "\(skill.name) 缺反模式章节")
            XCTAssertLessThanOrEqual(skill.body.count, 1500, "\(skill.name) 正文超软上限")
        }

        // 3 张方法论卡：含实战注记
        let cardsDir = resources.appendingPathComponent("cards", isDirectory: true)
        let cardFiles = try FileManager.default.contentsOfDirectory(
            at: cardsDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        XCTAssertEqual(cardFiles.count, 3, "初始方法论卡应为 3 张")

        for file in cardFiles {
            let markdown = try String(contentsOf: file, encoding: .utf8)
            let card = try XCTUnwrap(
                MethodologyCard.parse(markdown: markdown),
                "\(file.lastPathComponent) 解析失败"
            )
            XCTAssertFalse(card.content.isEmpty)
            XCTAssertGreaterThan(card.confidence, 0, "\(card.id) 置信度缺失")
            XCTAssertGreaterThanOrEqual(
                card.annotations.count, 1, "\(card.id) 缺实战注记"
            )
        }
    }

    func testCodableRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let project = ProjectDocument(
            name: "P", goalStatement: "g", constraints: ["c"], rejections: ["r"],
            currentVersion: "v1.0", versions: ["v1.0"]
        )
        XCTAssertEqual(
            try decoder.decode(ProjectDocument.self, from: encoder.encode(project)), project
        )

        let run = PipelineRun(projectId: "proj_x", version: "v1.0", currentStage: .structure)
        XCTAssertEqual(
            try decoder.decode(PipelineRun.self, from: encoder.encode(run)), run
        )

        let memory = MemoryEntry(
            scope: .global, kind: .experience, content: "用户偏好简洁", sourceRef: "项目A/v1.0",
            confidence: 0.7
        )
        XCTAssertEqual(
            try decoder.decode(MemoryEntry.self, from: encoder.encode(memory)), memory
        )
    }
}

// MARK: - M2：主线流水线（状态机 / 产物解析 / 记忆层 / 思考卡）

final class PipelineM2Tests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-m2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func makeWorkspace() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "M2项目")
        try PMAgentStore.createVersion("v1.0", in: "M2项目")
    }

    // MARK: 状态机阶段推导（E8：文件是唯一事实源）

    func testDeriveStageFromDisk() throws {
        try makeWorkspace()
        let project = "M2项目", version = "v1.0"

        // 空目录 → clarify
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .clarify)

        // 澄清要点表 → structure
        try PMAgentStore.writeVerified(
            "要点表",
            to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(ArtifactPath.clarification)
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .structure)

        // 02-structure/confirmed.json → prototype
        try PMAgentStore.writeVerified(
            "{}",
            to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent("02-structure/confirmed.json")
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .prototype)

        // 03-prototypes/confirmed.json → prd
        try PMAgentStore.writeVerified(
            "{}",
            to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent("03-prototypes/confirmed.json")
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .prd)
    }

    // MARK: 路径选择（2026-09-17：跳过 / 停驻 / 补做）

    /// 跳过标记闭环推导：skipped.json 与 confirmed.json 同位推导阶段。
    func testDeriveStageSkippedClosures() throws {
        try makeWorkspace()
        let project = "M2项目", version = "v1.0"
        let dir = PMAgentStore.versionURL(project: project, version: version)

        // ② 跳过标记 → .prototype
        try PMAgentStore.writeVerified(
            "{}", to: dir.appendingPathComponent("02-structure/skipped.json")
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .prototype)

        // ③ 跳过标记 → .prd（① 直出 PRD 路径的落点）
        try PMAgentStore.writeVerified(
            "{}", to: dir.appendingPathComponent("03-prototypes/skipped.json")
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .prd)
        XCTAssertTrue(PipelineEngine.isSkipped(.structure, project: project, version: version))
        XCTAssertTrue(PipelineEngine.isSkipped(.prototype, project: project, version: version))
    }

    /// 引擎闸口的路径选择变体：直出 PRD / 跳 ③ 出 PRD / 停驻 / 补做删标记。
    func testPathSelectionEngineGates() throws {
        try makeWorkspace()
        let project = "M2项目", version = "v1.0"
        let dir = PMAgentStore.versionURL(project: project, version: version)

        // ① 直出 PRD（跳过 ②③）：阶段直推 .prd，skipped 闭环，PRD 闸口放行
        try PMAgentStore.writeVerified(
            "要点表", to: dir.appendingPathComponent(ArtifactPath.clarification)
        )
        let engine = PipelineEngine(project: project, version: version, database: nil)
        engine.advanceFromClarify(outcome: "route_selection", skipping: [.structure, .prototype])
        XCTAssertEqual(engine.stage, .prd)
        XCTAssertTrue(engine.structureSkipped)
        XCTAssertTrue(engine.prototypeSkipped)
        XCTAssertTrue(engine.canGeneratePRD, "③ 跳过即闭环，PRD 闸口放行")

        // 补做 ②：invalidateStructure 删跳过标记 → 回 ②，下游闭环一并失效
        engine.invalidateStructure()
        XCTAssertEqual(engine.stage, .structure)
        XCTAssertFalse(engine.structureSkipped)
        XCTAssertFalse(engine.prototypeSkipped)

        // ② 闸口选「跳过 ③ 直出 PRD」
        try engine.confirmStructure(outcome: "route_selection", skippingPrototype: true)
        XCTAssertEqual(engine.stage, .prd)
        XCTAssertTrue(engine.prototypeSkipped)
        XCTAssertTrue(engine.canGeneratePRD)

        // ③「到原型为止」停驻（新版本走常规路径）：确认 + 停驻标记，不自动进 ④
        try PMAgentStore.createVersion("v1.1", in: project)
        try PMAgentStore.writeVerified(
            "要点表",
            to: PMAgentStore.versionURL(project: project, version: "v1.1")
                .appendingPathComponent(ArtifactPath.clarification)
        )
        let stopped = PipelineEngine(project: project, version: "v1.1", database: nil)
        try stopped.confirmPrototypeStopHere(outcome: "route_selection")
        XCTAssertTrue(stopped.prototypeConfirmed)
        XCTAssertTrue(stopped.stoppedHere)
        XCTAssertEqual(stopped.stage, .prd)
        XCTAssertTrue(stopped.canGeneratePRD, "停驻续出走 App 层门禁，引擎闸口本就放行")
        // 续出：清停驻标记（幂等）
        stopped.clearStopHere()
        XCTAssertFalse(stopped.stoppedHere)
        stopped.clearStopHere()  // 再清不炸
    }

    func testConfirmGatesAndInvalidation() throws {
        try makeWorkspace()
        let engine = PipelineEngine(project: "M2项目", version: "v1.0", database: nil)

        // 闸口拦截：未确认结构不得生成原型（E17a）
        engine.advanceFromClarify()
        XCTAssertFalse(engine.canGeneratePrototype)

        // 手动补齐结构产物 + 确认 → 放行
        let dir = PMAgentStore.versionURL(project: "M2项目", version: "v1.0")
        try PMAgentStore.writeVerified(
            "# 图", to: dir.appendingPathComponent(ArtifactPath.architecture)
        )
        try engine.confirmStructure()
        XCTAssertTrue(engine.structureConfirmed)
        XCTAssertEqual(engine.stage, .prototype)
        XCTAssertTrue(engine.canGeneratePrototype)

        // 回退：invalidateStructure 过期传播（原型确认一并失效）
        try PMAgentStore.writeVerified(
            "{}", to: dir.appendingPathComponent("03-prototypes/confirmed.json")
        )
        engine.invalidateStructure()
        XCTAssertFalse(engine.structureConfirmed)
        XCTAssertFalse(engine.prototypeConfirmed)
        XCTAssertEqual(engine.stage, .structure)
    }

    // MARK: 产物块解析与落盘（E17）

    func testParseArtifactBlocksAndWriteStructure() throws {
        try makeWorkspace()
        let reply = """
        说明文字。

        ```artifact:architecture
        graph TD
          A[首页] --> B[详情]
        ```

        ```artifact:core-flows
        flowchart TD
          S([开始]) --> E([结束])
        ```

        ```artifact:module-page-map
        | 模块 | 原型页面 | 页面说明 |
        |---|---|---|
        | 首页 | index | 入口 |
        ```
        """

        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(Set(blocks.map(\.name)), ["architecture", "core-flows", "module-page-map"])
        XCTAssertTrue(blocks[0].content.contains("graph TD"))
        XCTAssertFalse(blocks[0].content.contains("```"), "围栏不应混入内容")

        // 完备性判定
        XCTAssertTrue(ArtifactParser.structureArtifactsComplete(blocks))
        XCTAssertFalse(ArtifactParser.structureArtifactsComplete(
            [ArtifactParser.ArtifactBlock(name: "architecture", content: "x")]
        ))

        // 落盘 + write-then-verify
        let artifacts = try ArtifactParser.writeStructureArtifacts(
            blocks: blocks, project: "M2项目", version: "v1.0"
        )
        XCTAssertEqual(artifacts.modulePageMap, "| 模块 | 原型页面 | 页面说明 |\n|---|---|---|\n| 首页 | index | 入口 |")
        let dir = PMAgentStore.versionURL(project: "M2项目", version: "v1.0")
            .appendingPathComponent("02-structure")
        for file in ["功能架构图.md", "核心流程图.md", "模块-页面映射表.md"] {
            let content = try String(
                contentsOf: dir.appendingPathComponent(file), encoding: .utf8
            )
            XCTAssertTrue(content.contains("```mermaid") || file == "模块-页面映射表.md")
        }

        // 剥离产物块后的展示正文
        let stripped = ArtifactParser.stripArtifactBlocks(in: reply)
        XCTAssertFalse(stripped.contains("artifact:"))
        XCTAssertTrue(stripped.contains("说明文字"))

        // 按块名定制占位：内联图表块不插提示，其余落默认
        let selective = ArtifactParser.stripArtifactBlocks(
            in: reply,
            placeholder: "（默认占位）",
            placeholderFor: {
                switch $0 {
                case "architecture", "core-flows", "module-page-map": ""
                default: nil
                }
            }
        )
        XCTAssertFalse(selective.contains("artifact:"))
        XCTAssertFalse(selective.contains("（默认占位）"), "三个块均为内联图表名 → 全部空占位")
        XCTAssertTrue(selective.contains("说明文字"))
        let mixed = """
        前文。

        ```artifact:architecture
        graph TD
          A --> B
        ```

        ```artifact:prd
        PRD 正文。
        ```
        """
        let mixedStripped = ArtifactParser.stripArtifactBlocks(
            in: mixed,
            placeholder: "（点击预览）",
            placeholderFor: { $0 == "architecture" ? "" : nil }
        )
        XCTAssertTrue(mixedStripped.contains("（点击预览）"), "非内联块落调用方默认占位")
        XCTAssertFalse(mixedStripped.contains("PRD 正文"))
        XCTAssertTrue(mixedStripped.contains("前文"))
    }

    /// mermaid 渲染 HTML 必须把 run() 推迟到 DOM 就绪——<head> 内脚本先于 <body>
    /// 解析，立即 run() 找不到 .mermaid 元素，图卡会显示原始源码（回归绊线）。
    func testMermaidRenderHTMLDefersRunUntilDOMReady() throws {
        let url = try XCTUnwrap(
            MermaidWebView.Coordinator.writeRenderHTML(
                source: "graph TD\n  A[首页] --> B[详情]", dark: false
            )
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("DOMContentLoaded"))
        XCTAssertTrue(html.contains("renderNow"))
        // run() 只允许出现在 renderNow 函数体内（被推迟调用）
        XCTAssertTrue(html.contains("function renderNow() {\n    mermaid.run()"))
        // 围栏外内容不被误转义
        XCTAssertTrue(html.contains("A[首页] --> B[详情]"))
    }

    func testWritePrototypeArtifact() throws {
        try makeWorkspace()
        let blocks = [
            ArtifactParser.ArtifactBlock(
                name: "prototype",
                content: "<!DOCTYPE html><html><body>灰盒原型</body></html>"
            ),
            ArtifactParser.ArtifactBlock(name: "architecture", content: "非 HTML"),
        ]
        let written = try XCTUnwrap(
            ArtifactParser.writePrototypeArtifact(
                blocks: blocks, project: "M2项目", version: "v1.0"
            )
        )
        XCTAssertEqual(written.slots.count, 1)
        XCTAssertEqual(written.slots.first?.relPath, ArtifactPath.prototype)
        let saved = PMAgentStore.versionURL(project: "M2项目", version: "v1.0")
            .appendingPathComponent(ArtifactPath.prototype)
        XCTAssertEqual(
            try String(contentsOf: saved, encoding: .utf8),
            "<!DOCTYPE html><html><body>灰盒原型</body></html>"
        )

        // 非 HTML 内容不落盘
        XCTAssertNil(try ArtifactParser.writePrototypeArtifact(
            blocks: [blocks[1]], project: "M2项目", version: "v1.0"
        ))
    }

    /// 流式未闭合 artifact 围栏识别（流式渲染把进行中的长代码收进进度卡，不刷原始代码）。
    func testParseIncompleteArtifact() {
        // 无产物标记
        XCTAssertNil(ArtifactParser.parseIncompleteArtifact(in: "普通回复，无产物。"))

        // 块已完成（闭合围栏在文末）
        let complete = "说明。\n\n```artifact:prototype\n<html></html>\n```"
        XCTAssertNil(ArtifactParser.parseIncompleteArtifact(in: complete))

        // 块已完成且后续还有正文
        XCTAssertNil(ArtifactParser.parseIncompleteArtifact(in: complete + "\n\n补充说明。"))

        // 未闭合：正文已流出一部分 → 返回块名与已生成正文
        let streaming = "设计说明。\n\n```artifact:prototype\n<!DOCTYPE html>\n<html lang=\"zh-CN\">\n"
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: streaming)
        XCTAssertEqual(incomplete?.name, "prototype")
        XCTAssertEqual(incomplete?.partial, "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n")

        // 完成块在前、进行中块在后 → 识别的是进行中的那个
        let mixed = "```artifact:architecture\ngraph TD\n```\n\n```artifact:prototype\n<ht"
        let mixedResult = ArtifactParser.parseIncompleteArtifact(in: mixed)
        XCTAssertEqual(mixedResult?.name, "prototype")
        XCTAssertEqual(mixedResult?.partial, "<ht")

        // 块名尚未流完（标记后无换行）
        let nameTyping = "说明。\n\n```artifact:prot"
        let typing = ArtifactParser.parseIncompleteArtifact(in: nameTyping)
        XCTAssertEqual(typing?.name, "")
        XCTAssertEqual(typing?.partial, "")

        // 标记后不是合法块名（普通文本误含标记）→ 不当作进行中的产物
        XCTAssertNil(ArtifactParser.parseIncompleteArtifact(
            in: "```artifact: Hello World\n正文"
        ))
    }

    /// PRD 截断兜底（未闭合 artifact:prd 提取草稿；思考 token 撞 max_tokens 池场景）。
    func testPRDTruncatedDraft() {
        let longBody = String(repeating: "功能需求条目。\n", count: 80)  // >500 字符

        // 未闭合 prd 块且正文够长 → 提取草稿
        let truncated = "撰写说明。\n\n```artifact:prd\n# PRD\n\(longBody)"
        XCTAssertEqual(
            ArtifactParser.prdTruncatedDraft(from: truncated),
            "# PRD\n\(longBody)"
        )

        // 残片过短（≤500 字符）→ 不落盘
        XCTAssertNil(ArtifactParser.prdTruncatedDraft(
            from: "```artifact:prd\n# PRD\n太短的残片"
        ))

        // prd 块完整闭合（截断的是后面的 decision）→ 非 prd 草稿
        XCTAssertNil(ArtifactParser.prdTruncatedDraft(
            from: "```artifact:prd\n完整正文\n```\n\n```artifact:decision\n[{\"decision\":"
        ))

        // 无产物标记 / 完整回复 → nil
        XCTAssertNil(ArtifactParser.prdTruncatedDraft(from: "普通回复，无产物。"))
    }

    /// PRD 产物块四反引号围栏 + 内嵌 ```text 线框图（嵌套围栏安全协议）：
    /// 旧三反引号正则 lazy 到第一个 ``` 就闭栏，线框图与后续章节全部游离在块外
    /// 落不了盘——预览里看不到线框图（回归绊线）。
    func testPRDArtifactSurvivesNestedTextFences() {
        let reply = """
        撰写说明。

        ````artifact:prd
        # PRD

        ### 4.4 页面线框图

        #### P1 今日页

        ```text
        ┌────┐
        │录入│
        └────┘
        ```

        ## 五、数据指标

        基线待建立。
        ````

        ```artifact:radar
        [{"finding": "demo"}]
        ```
        """
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        let prd = blocks.first { $0.name == "prd" }
        XCTAssertNotNil(prd, "四反引号块应完整解析")
        XCTAssertTrue(prd?.content.contains("```text") ?? false, "内嵌 text 围栏留在正文里")
        XCTAssertTrue(prd?.content.contains("┌────┐") ?? false, "内嵌线框图 ASCII 不丢")
        XCTAssertTrue(prd?.content.contains("五、数据指标") ?? false, "内嵌围栏后的章节不截断")
        XCTAssertFalse(prd?.content.contains("````") ?? true, "闭栏不混入正文")
        // 同回复内三反引号 radar 块（旧协议）不受影响
        XCTAssertEqual(blocks.first { $0.name == "radar" }?.content, "[{\"finding\": \"demo\"}]")
        // 剥离展示正文：prd 整块替换，内嵌围栏不残留
        let stripped = ArtifactParser.stripArtifactBlocks(in: reply)
        XCTAssertFalse(stripped.contains("```text"))
        XCTAssertTrue(stripped.contains("撰写说明"))
    }

    /// 流式口径：四反引号 PRD 块内的 ```text 开/闭栏都不算闭合，四反引号闭栏才算完成。
    func testParseIncompleteArtifactFourBacktickNesting() {
        // 内嵌 ```text 围栏（含裸 ``` 闭栏行）仍在进行中
        let streaming = "说明。\n\n````artifact:prd\n# PRD\n\n```text\n┌──┐\n└──┘\n```\n"
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: streaming)
        XCTAssertEqual(incomplete?.name, "prd")
        XCTAssertTrue(incomplete?.partial.contains("┌──┐") ?? false)

        // 四反引号闭栏出现 → 完成
        XCTAssertNil(ArtifactParser.parseIncompleteArtifact(in: streaming + "````\n"))

        // 截断草稿：四反引号块在内嵌围栏处被截断仍可提取（含内嵌围栏正文）
        let longBody = String(repeating: "功能需求条目。\n", count: 80)
        let streaming4 = "说明。\n\n````artifact:prd\n# PRD\n\(longBody)\n```text\n┌──┐\n```\n"
        XCTAssertTrue(
            ArtifactParser.prdTruncatedDraft(from: streaming4)?.contains("```text") ?? false,
            "内嵌围栏后的正文仍在草稿里"
        )

        // 三反引号块（旧协议）行为不变：裸 ``` 行闭合
        XCTAssertNil(ArtifactParser.parseIncompleteArtifact(
            in: "```artifact:prototype\n<ht\n```"
        ))
    }

    // MARK: 澄清选项行解析（E1：选项式提问点选）

    func testParseClarifyOptions() {
        let reply = """
        已知：目标用户是健身小白。
        本轮问题：核心场景是什么？

        A) 训练计划制定
        B) 饮食记录
        C) 社区打卡
        """
        let options = ArtifactParser.parseClarifyOptions(in: reply)
        XCTAssertEqual(options?.options, ["训练计划制定", "饮食记录", "社区打卡"])
        XCTAssertTrue(options?.question.contains("核心场景是什么") == true)

        // 中文括号 / 点号变体
        XCTAssertEqual(
            ArtifactParser.parseClarifyOptions(in: "问：X？\nA）甲\nB）乙")?.options.count, 2
        )

        // 少于 2 项 → 开放问题（无点选）
        XCTAssertNil(ArtifactParser.parseClarifyOptions(in: "问：X？\nA) 只有一个"))
        // 纯文本 → 无选项
        XCTAssertNil(ArtifactParser.parseClarifyOptions(in: "普通回复，无选项"))
    }

    // MARK: 选项行问题组解析（多组 → 问题卡向导逐题作答）

    func testParseOptionLineQuestionGroups() {
        // 单组：与 parseClarifyOptions 同口径（题干收尾行 + 选项）
        let single = ArtifactParser.parseOptionLineQuestionGroups(in: "问：核心场景？\nA) 甲\nB) 乙")
        XCTAssertEqual(single?.questions.count, 1)
        XCTAssertEqual(single?.questions[0].title, "问：核心场景？")
        XCTAssertEqual(single?.questions[0].options, ["甲", "乙"])
        XCTAssertEqual(single?.bodyText, "问：核心场景？")

        // 多组：模型未走问题卡协议一次抛两问 → 两组逐题作答；正文剥除所有组选项行
        let multi = ArtifactParser.parseOptionLineQuestionGroups(in: """
        先对齐两个事实。

        问题一：团队规模？
        A) 1-2 人
        B) 3-5 人

        问题二：预算周期？
        A) 一个月
        B) 半年
        """)
        XCTAssertEqual(multi?.questions.count, 2)
        XCTAssertEqual(multi?.questions[0].title, "问题一：团队规模？")
        XCTAssertEqual(multi?.questions[0].options, ["1-2 人", "3-5 人"])
        XCTAssertEqual(multi?.questions[1].title, "问题二：预算周期？")
        XCTAssertEqual(multi?.questions[1].options, ["一个月", "半年"])
        XCTAssertTrue(multi?.bodyText.contains("问题一：团队规模？") == true)
        XCTAssertTrue(multi?.bodyText.contains("A)") == false)

        // 题干收尾代码围栏块整块跳过（题干不能显示成「```」）
        let fenced = ArtifactParser.parseOptionLineQuestionGroups(in: """
        看下现状
        ```yaml
        key: value
        ```

        A) 甲
        B) 乙
        """)
        XCTAssertEqual(fenced?.questions[0].title, "看下现状")

        // 选项行不在末尾（选项后还有正文）→ 不触发
        XCTAssertNil(ArtifactParser.parseOptionLineQuestionGroups(
            in: "问：X？\nA) 甲\nB) 乙\n以上就是选项。"
        ))

        // 超过 4 行连续选项行 → 视为列表散文，不成组
        XCTAssertNil(ArtifactParser.parseOptionLineQuestionGroups(
            in: "列表：\nA) 1\nB) 2\nC) 3\nD) 4\nE) 5"
        ))
    }

    // MARK: 收尾确认标记（① 澄清一次确认协议）

    func testGateConfirmMarkerParsing() {
        // 标记尾行 + 单组：gateConfirm 置位，选项行照常成组，正文剥除标记行
        let marked = ArtifactParser.parseOptionLineQuestionGroups(in: """
        最后一个问题：以上要点是否确认？
        A) 确认，先只出移动版
        B) 有要改的地方
        [收尾确认]
        """)
        XCTAssertEqual(marked?.gateConfirm, true)
        XCTAssertEqual(marked?.questions.count, 1)
        XCTAssertEqual(marked?.questions[0].options, ["确认，先只出移动版", "有要改的地方"])
        XCTAssertEqual(marked?.questions[0].title, "最后一个问题：以上要点是否确认？")
        XCTAssertEqual(marked?.bodyText.contains("[收尾确认]"), false)

        // 全角括号变体同样识别
        let fullwidth = ArtifactParser.parseOptionLineQuestionGroups(
            in: "确认一下？\nA) 确认\nB) 再改改\n【收尾确认】"
        )
        XCTAssertEqual(fullwidth?.gateConfirm, true)

        // 无标记 → 不置位（常规澄清问路径不受影响）
        let plain = ArtifactParser.parseOptionLineQuestionGroups(in: "问：X？\nA) 甲\nB) 乙")
        XCTAssertEqual(plain?.gateConfirm, false)

        // 标记 + 多组：仍按多组解析（收尾确认问协议要求单组，多组由调用方忽略标记语义）
        let multiMarked = ArtifactParser.parseOptionLineQuestionGroups(
            in: "问一？\nA) 甲\nB) 乙\n\n问二？\nA) 丙\nB) 丁\n[收尾确认]"
        )
        XCTAssertEqual(multiMarked?.questions.count, 2)
        XCTAssertEqual(multiMarked?.gateConfirm, true)

        // 只有标记、无有效选项组 → nil（标记行不成组）
        XCTAssertNil(ArtifactParser.parseOptionLineQuestionGroups(in: "正文\n[收尾确认]"))
    }

    // MARK: 一次确认肯定项判定

    func testGateConfirmSelection() {
        let options = ["确认，先只出移动版", "确认，移动版 + 桌面版一起修订", "有要改的地方"]
        // 点选「确认」开头选项（点选即发送原文）→ 一次确认生效
        XCTAssertTrue(AppModel.isGateConfirmSelection(
            "确认，先只出移动版", options: options
        ))
        // 非确认开头选项 → 常规作答
        XCTAssertFalse(AppModel.isGateConfirmSelection("有要改的地方", options: options))
        // 自由输入（即便以确认开头，非选项原文）→ 不触发，走 AI 判读
        XCTAssertFalse(AppModel.isGateConfirmSelection(
            "确认，但桌面版要支持深色模式", options: options
        ))
        // 空文本兜底
        XCTAssertFalse(AppModel.isGateConfirmSelection("  ", options: options))
    }

    // MARK: JSON 容错解析（要点表 / 记忆抽取）

    @MainActor
    func testLenientJSONDecoding() throws {
        // 带围栏 + 前后废话
        let fenced = """
        好的，以下是抽取结果：
        ```json
        {"kind": "conclusion", "content": "目标用户为健身小白", "overrides": null}
        ```
        """
        let item = try XCTUnwrap(
            LenientJSON.decode(MemoryStore.ExtractionItem.self, from: fenced)
        )
        XCTAssertEqual(item.kind, "conclusion")

        // 数组 + 嵌套引号转义
        let array = """
        [{"kind": "constraint", "content": "他说\\"不做\\"社交", "overrides": null}]
        """
        let items = try XCTUnwrap(
            LenientJSON.decode([MemoryStore.ExtractionItem].self, from: array)
        )
        XCTAssertEqual(items[0].content, "他说\"不做\"社交")

        // 非法输入 → nil
        XCTAssertNil(LenientJSON.decode(MemoryStore.ExtractionItem.self, from: "没有 JSON"))
    }

    // MARK: 记忆层覆盖语义（E9：旧结论不注入）

    @MainActor
    func testMemorySupersedeSemantics() {
        func entry(_ id: String, content: String, invalidated: Bool = false) -> MemoryEntry {
            MemoryEntry(
                id: id, scope: .project, kind: .conclusion, content: content,
                invalidated: invalidated)
        }

        // 同 id 两行（原始行 + 失效标记行）→ 保留后者，失效即剔除
        let entries = [
            entry("m1", content: "目标用户是专业教练"),
            entry("m1", content: "目标用户是专业教练", invalidated: true),
            entry("m2", content: "核心场景是训练计划"),
        ]
        let effective = MemoryStore.applySupersede(entries)
        XCTAssertEqual(effective.map(\.content), ["核心场景是训练计划"])

        // 无覆盖 → 全保留（按首次出现顺序）
        let fresh = MemoryStore.applySupersede([
            entry("a", content: "甲"), entry("b", content: "乙"),
        ])
        XCTAssertEqual(fresh.count, 2)
    }

    // MARK: 思考卡数据（E20）

    func testThinkDataFromReasoning() {
        let reasoning = """
        先分析目标用户
        再确认核心场景
        排除社交方向
        """
        let data = ThinkData.from(reasoning: reasoning, duration: 3)
        XCTAssertEqual(data?.steps.count, 3)
        XCTAssertTrue(data?.summary.contains("思考了 3s") == true)
        // 全文随 full 落盘（展开可回看，不再只有截断步骤）
        XCTAssertEqual(data?.full, reasoning)

        // 空推理 → 无思考卡
        XCTAssertNil(ThinkData.from(reasoning: "  \n ", duration: 1))
    }

    // MARK: 思考卡引用技能（技能注入在思考过程中可见）

    func testThinkDataFromReasoningWithSkills() {
        let data = ThinkData.from(
            reasoning: "先分析目标用户\n再确认核心场景",
            duration: 5,
            skills: ["S18 hi-fi-prototype", "S13 poc-probe-selection"]
        )
        // 技能步骤置于推理步骤之前
        XCTAssertEqual(data?.steps.count, 4)
        XCTAssertEqual(data?.steps.prefix(2).compactMap(\.skill), [
            "S18 hi-fi-prototype", "S13 poc-probe-selection",
        ])
        XCTAssertTrue(data?.steps.prefix(2).allSatisfy { $0.text == nil } == true)
        // 摘要行：技能 ≤2 个直接点名（折叠态即可见所应用技能名）
        XCTAssertTrue(data?.summary.contains("S18 hi-fi-prototype、S13 poc-probe-selection") == true)
        XCTAssertFalse(data?.summary.contains("技能 ×") == true)

        // 仅有技能、无 reasoning → 仍产出思考卡（技能行承载；纯技能退化为元信息行）
        let skillOnly = ThinkData.from(reasoning: "", duration: 2, skills: ["技能X"])
        XCTAssertEqual(skillOnly?.steps.count, 1)
        XCTAssertEqual(skillOnly?.steps.first?.skill, "技能X")
        XCTAssertEqual(skillOnly?.summary, "思考了 2s · 技能X")

        // ≥3 个技能收敛为计数（防摘要行过长）
        let manySkills = ThinkData.from(
            reasoning: "", duration: 2, skills: ["技能X", "技能Y", "技能Z"]
        )
        XCTAssertEqual(manySkills?.summary, "思考了 2s · 技能 ×3")

        // 无技能时行为不变（兼容旧调用）
        let noSkills = ThinkData.from(reasoning: "  \n ", duration: 1)
        XCTAssertNil(noSkills)
    }

    // MARK: 思考卡尾部优先摘要 + 全文持久化（2026-09-18 思考展示升级）

    func testThinkDataTailFirstAndFull() {
        // 15 行超限：reasoning 头部是复述、尾部才是收束——首 2 + 省略提示 + 末 10
        let reasoning = (1...15).map { "推理要点第\($0)行" }.joined(separator: "\n")
        let data = ThinkData.from(reasoning: reasoning, duration: 8)
        XCTAssertEqual(data?.steps.count, 13)
        XCTAssertEqual(data?.steps.first?.text, "推理要点第1行")
        XCTAssertEqual(data?.steps[1].text, "推理要点第2行")
        XCTAssertEqual(data?.steps[2].text, "（中间省略 3 条，展开可看全文）")
        XCTAssertEqual(data?.steps.last?.text, "推理要点第15行")
        // 全文随 full 落盘，完成态展开可回看
        XCTAssertEqual(data?.full, reasoning)
        // 摘要行内容化：尾部收束句开头；「N 步」虚标移除
        XCTAssertTrue(data?.summary.contains("「推理要点第15行」") == true)
        XCTAssertTrue(data?.summary.contains("思考了 8s") == true)
        XCTAssertFalse(data?.summary.contains("13 步") == true)

        // ≤12 行不折叠、摘要行不加省略提示
        let short = ThinkData.from(reasoning: "第一行\n第二行", duration: 1)
        XCTAssertEqual(short?.steps.count, 2)
        XCTAssertFalse(short?.summary.contains("省略") == true)
    }

    func testThinkDataDecodeLegacyWithoutFull() throws {
        // 旧存量行无 full key：解码为 nil 不崩（合成 Codable decodeIfPresent 兼容）
        let legacy = try JSONDecoder().decode(
            ThinkData.self, from: Data(#"{"dur":3,"steps":[{"text":"旧数据步骤"}]}"#.utf8)
        )
        XCTAssertEqual(legacy.dur, 3)
        XCTAssertEqual(legacy.steps.first?.text, "旧数据步骤")
        XCTAssertNil(legacy.full)
        XCTAssertNil(legacy.phaseTrail)

        // 新数据 roundtrip：full 非空编码落盘
        let fresh = ThinkData.from(reasoning: "一行思考", duration: 1)
        let roundtrip = try JSONDecoder().decode(
            ThinkData.self, from: try JSONEncoder().encode(fresh)
        )
        XCTAssertEqual(roundtrip.full, "一行思考")

        // full 为 nil（纯技能卡）时不写盘，jsonl 不增冗余 key
        let skillOnly = ThinkData.from(reasoning: "", duration: 1, skills: ["技能X"])
        let raw = String(decoding: try JSONEncoder().encode(skillOnly), as: UTF8.self)
        XCTAssertFalse(raw.contains("full"))
    }

    // MARK: 确认链跳转历史持久化（2026-09-18，完成态恒可见）

    func testThinkDataPhaseTrailPersistence() throws {
        // 链式回合：跳标签随 think 持久化，完成态展开恒可见
        let trail = ["正在抽取澄清要点表…", "正在沉淀记忆与方法论…", "正在生成结构产物…"]
        let data = ThinkData.from(reasoning: "先分析", duration: 4, phaseTrail: trail)
        XCTAssertEqual(data?.phaseTrail, trail)
        let roundtrip = try JSONDecoder().decode(
            ThinkData.self, from: try JSONEncoder().encode(data)
        )
        XCTAssertEqual(roundtrip.phaseTrail, trail, "跳转历史随 discussions.jsonl 落盘")

        // 普通聊天轮（无链）：空轨迹归一为 nil，不写盘
        let noChain = ThinkData.from(reasoning: "普通轮", duration: 1, phaseTrail: [])
        XCTAssertNil(noChain?.phaseTrail)
        let raw = String(decoding: try JSONEncoder().encode(noChain), as: UTF8.self)
        XCTAssertFalse(raw.contains("phaseTrail"))

        // makeStoppedTurn 透传轨迹（streamReply 收尾快照通道）
        let stopped = SessionStore.makeStoppedTurn(
            partial: "部分内容", reasoning: "思考", duration: 3,
            skills: [], phaseTrail: trail, sessionId: "s1"
        )
        XCTAssertEqual(stopped.assistant?.think?.phaseTrail, trail)
    }

    // MARK: 阶段时间线（确认链多跳进度，2026-09-18 思考展示升级）

    @MainActor
    func testPhaseTrail() {
        let store = SessionStore()
        defer { store.stopGeneration() }
        let id = "s-trail"

        // 逐跳入轨：前置跳标 done、新跳为当前跳
        store.setStreamPhase("正在抽取澄清要点表…", for: id)
        store.setStreamPhase("正在沉淀记忆…", for: id)
        store.setStreamPhase("正在沉淀方法论…", for: id)
        var trail = store.streams[id]?.phaseTrail ?? []
        XCTAssertEqual(trail.map(\.label), [
            "正在抽取澄清要点表…", "正在沉淀记忆…", "正在沉淀方法论…",
        ])
        XCTAssertEqual(trail.map(\.done), [true, true, false])

        // 重复写入相同的当前 label 幂等（防重试路径重复入轨）
        store.setStreamPhase("正在沉淀方法论…", for: id)
        XCTAssertEqual(store.streams[id]?.phaseTrail.count, 3)

        // 链尾收尾（nil）：全部标 done，key 存活（非空态不被剪枝）
        store.setStreamPhase(nil, for: id)
        trail = store.streams[id]?.phaseTrail ?? []
        XCTAssertEqual(trail.map(\.done), [true, true, true])
        XCTAssertTrue(store.streams[id] != nil)

        // trail 清空后回到空态 → key 剪枝（空态不留键不变量）
        store.mutateStream(id) { $0.phaseTrail = [] }
        XCTAssertNil(store.streams[id])
    }

    // MARK: 阶段推进意图识别（自由作答等价选①）

    @MainActor
    func testAdvanceIntent() {
        XCTAssertTrue(AppModel.isAdvanceIntent("可以进入下一个阶段"))
        XCTAssertTrue(AppModel.isAdvanceIntent("确认并进入"))
        XCTAssertTrue(AppModel.isAdvanceIntent("进入下一阶段"))
        XCTAssertFalse(AppModel.isAdvanceIntent("我还想再改改"))
        XCTAssertFalse(AppModel.isAdvanceIntent("这个功能怎么做"))
    }
}

// MARK: - M3：💀 风险登记闭环（design.md §6.2）

@MainActor
final class RiskStoreTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-risk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func makeWorkspace() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "风险项目")
        try PMAgentStore.createVersion("v1.0", in: "风险项目")
    }

    private func makeRisk(
        _ hypothesis: String,
        trigger: RiskRecord.TriggerSignal,
        stage: RiskRecord.Stage = .prototype
    ) -> RiskRecord {
        RiskRecord(
            version: "v1.0",
            stage: stage,
            hypothesis: hypothesis,
            triggerSignal: trigger,
            originRef: "self-review.md"
        )
    }

    // MARK: 追加与读侧折叠（append-only）

    func testAppendAndCollapse() throws {
        try makeWorkspace()
        let risksURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "risks.jsonl"
        )

        let store = RiskStore(project: "风险项目", version: "v1.0")
        let a = makeRisk("结构改动会导致返工", trigger: .structureRegen, stage: .structure)
        let b = makeRisk("原型页数超 5 难维护", trigger: .prototypeRegen)
        try store.append(a)
        try store.append(b)
        XCTAssertEqual(store.risks.count, 2)
        XCTAssertEqual(store.activeRisks.count, 2)

        // 同 id 结算行（append-only 不改写旧行）→ 折叠后该 id 仍 1 条且为终态
        var settled = a
        settled.status = .closedUnfired
        settled.closedAt = ISO8601.timestamp()
        try PMAgentStore.appendLine(settled, to: risksURL)

        let all = PMAgentStore.readLines(RiskRecord.self, from: risksURL)
        XCTAssertEqual(all.count, 3, "原始 2 行 + 结算 1 行")
        let collapsed = RiskStore.collapse(all)
        XCTAssertEqual(collapsed.count, 2)
        XCTAssertEqual(collapsed.filter { $0.id == a.id }.count, 1)
        XCTAssertEqual(collapsed.first { $0.id == a.id }?.status, .closedUnfired)
    }

    // MARK: 状态机事件结算（回写 risk_hit）

    func testSettleByTrigger() throws {
        try makeWorkspace()
        let decisionsURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "decisions.jsonl"
        )

        let store = RiskStore(project: "风险项目", version: "v1.0")
        let structure = makeRisk("结构会被推翻重做", trigger: .structureRegen, stage: .structure)
        let prd = makeRisk("PRD 会过期", trigger: .prdStale, stage: .prd)
        let proto1 = makeRisk("原型第 2 轮推翻", trigger: .prototypeRegen)
        let proto2 = makeRisk("原型页数超限", trigger: .prototypeRegen)
        for risk in [structure, prd, proto1, proto2] { try store.append(risk) }

        // 只结算 triggerSignal == .prototypeRegen 且 open 的条目
        let settled = try store.settle(trigger: .prototypeRegen, note: "第 3 轮原型重做")
        XCTAssertEqual(Set(settled.map(\.id)), Set([proto1.id, proto2.id]))
        XCTAssertEqual(store.risks.first { $0.id == structure.id }?.status, .open)
        XCTAssertEqual(store.risks.first { $0.id == prd.id }?.status, .open)
        XCTAssertEqual(store.risks.first { $0.id == proto1.id }?.status, .triggered)
        XCTAssertNotNil(store.risks.first { $0.id == proto1.id }?.closedAt)

        // decisions.jsonl 回写 risk_hit（predicted = 当初假设，actual = note）
        let hits = PMAgentStore.readLines(DecisionLogEntry.self, from: decisionsURL)
            .compactMap { entry -> RiskHitRecord? in
                if case .riskHit(let hit) = entry { return hit }
                return nil
            }
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.riskId)), Set([proto1.id, proto2.id]))
        let proto1Hit = try XCTUnwrap(hits.first { $0.riskId == proto1.id })
        XCTAssertEqual(proto1Hit.type, "risk_hit")
        XCTAssertEqual(proto1Hit.predicted, "原型第 2 轮推翻")
        XCTAssertEqual(proto1Hit.actual, "第 3 轮原型重做")
    }

    // MARK: 四态闭环（采纳 → 挂起 → 解除 / 重开；接受自留）

    func testFourStateFlow() throws {
        try makeWorkspace()
        let decisionsURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "decisions.jsonl"
        )
        let risksURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "risks.jsonl"
        )

        let store = RiskStore(project: "风险项目", version: "v1.0")
        var risk = makeRisk("首页并入速记后信息密度超载", trigger: .structureRegen, stage: .structure)
        risk.impact = "30 秒记不完一笔，核心场景失效"
        risk.plan = "首页只留单行速记框，完整处理挪浮层"
        try store.append(risk)

        // 采纳：open → mitigating（≠ 解除），回写待验证决策
        let adopted = try store.adopt(id: risk.id)
        XCTAssertEqual(store.risks.first { $0.id == risk.id }?.status, .mitigating)
        XCTAssertTrue(adopted.toBeVerified)
        XCTAssertTrue(adopted.decision.contains("单行速记框"))
        XCTAssertEqual(store.risks.first { $0.id == risk.id }?.resolution, "决策日志 \(adopted.id)")

        // 解除：mitigating → resolved，回写闭环决策（toBeVerified=false）
        let resolved = try store.resolve(id: risk.id)
        XCTAssertEqual(store.risks.first { $0.id == risk.id }?.status, .resolved)
        XCTAssertNotNil(store.risks.first { $0.id == risk.id }?.closedAt)
        XCTAssertFalse(resolved.toBeVerified)
        XCTAssertTrue(resolved.decision.contains("风险解除"))

        // decisions.jsonl：采纳 1 条 + 解除 1 条（均为 decision 条目）
        let decisions = PMAgentStore.readLines(DecisionLogEntry.self, from: decisionsURL)
        XCTAssertEqual(decisions.count, 2)
        guard case .decision(let first)? = decisions.first,
              case .decision(let second)? = decisions.last else {
            return XCTFail("决策条目类型不符")
        }
        XCTAssertTrue(first.toBeVerified)
        XCTAssertFalse(second.toBeVerified)

        // append-only：1 原始行 + 采纳行 + 解除行 = 3 行
        XCTAssertEqual(PMAgentStore.readLines(RiskRecord.self, from: risksURL).count, 3)

        // 接受路径：open → accepted（自留，不写决策日志）
        let other = makeRisk("团队协作诉求打破单机假设", trigger: .decisionOverturned)
        try store.append(other)
        try store.accept(id: other.id)
        let accepted = store.risks.first { $0.id == other.id }
        XCTAssertEqual(accepted?.status, .accepted)
        XCTAssertEqual(accepted?.resolution, "风险自留 · 封板时带入 PRD 已知风险")
    }

    func testReopenOnUnresolvedMitigation() throws {
        try makeWorkspace()
        let store = RiskStore(project: "风险项目", version: "v1.0")
        let risk = makeRisk("迁移成本高导致新用户流失", trigger: .prototypeRegen)
        try store.append(risk)

        try store.adopt(id: risk.id)
        try store.reopen(id: risk.id)
        let reopened = store.risks.first { $0.id == risk.id }
        XCTAssertEqual(reopened?.status, .open, "没解决 → 重开回待处理")
        XCTAssertEqual(reopened?.resolution, "验证未过 · 已重开（方案需升级）")
        XCTAssertNil(reopened?.closedAt)

        // 重开后可再采纳（状态机回路）
        XCTAssertNoThrow(try store.adopt(id: risk.id))
        XCTAssertEqual(store.risks.first { $0.id == risk.id }?.status, .mitigating)

        // 状态守卫：open 不能直接解除、mitigating 不能重复采纳
        let fresh = makeRisk("未挂方案的风险", trigger: .release)
        try store.append(fresh)
        XCTAssertThrowsError(try store.resolve(id: fresh.id))
        XCTAssertThrowsError(try store.adopt(id: risk.id))
    }

    func testAdoptWithEvidencePointer() throws {
        // 采纳落实闭环（2026-09-15）：带证据指针的采纳——决策日志 evidence 字段
        // 落盘可回读，resolution 标注「实施证据已留对话」；普通采纳口径不变
        // （testFourStateFlow 的 resolution 精确断言依赖此项）。
        try makeWorkspace()
        let decisionsURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "decisions.jsonl"
        )
        let store = RiskStore(project: "风险项目", version: "v1.0")
        let risk = makeRisk("留存假设无一手数据支撑", trigger: .decisionOverturned, stage: .clarify)
        try store.append(risk)

        let adopted = try store.adopt(
            id: risk.id, evidence: "对话留痕 · 会话 s1 · 回合 m9"
        )
        XCTAssertEqual(adopted.evidence, "对话留痕 · 会话 s1 · 回合 m9")
        XCTAssertTrue(adopted.toBeVerified)
        XCTAssertEqual(
            store.risks.first { $0.id == risk.id }?.resolution,
            "决策日志 \(adopted.id) · 实施证据已留对话"
        )

        // decisions.jsonl 回读：evidence 字段随行持久化（append-only 可查）
        let decisions = PMAgentStore.readLines(DecisionLogEntry.self, from: decisionsURL)
        guard case .decision(let first)? = decisions.first else {
            return XCTFail("决策条目类型不符")
        }
        XCTAssertEqual(first.evidence, "对话留痕 · 会话 s1 · 回合 m9")

        // 普通采纳（无证据）：evidence 为 nil，resolution 保持原口径
        let plain = makeRisk("无需生成的线下方案", trigger: .release)
        try store.append(plain)
        let plainAdopted = try store.adopt(id: plain.id)
        XCTAssertNil(plainAdopted.evidence)
        XCTAssertEqual(
            store.risks.first { $0.id == plain.id }?.resolution,
            "决策日志 \(plainAdopted.id)"
        )
    }

    // MARK: 封板兜底（未闭合统一自留；已闭合不动）

    func testReleaseSettlement() throws {
        try makeWorkspace()
        let store = RiskStore(project: "风险项目", version: "v1.0")
        let pending = makeRisk("未处理风险", trigger: .decisionOverturned)
        let hanging = makeRisk("已挂方案风险", trigger: .prdStale, stage: .prd)
        let fired = makeRisk("已命中", trigger: .structureRegen, stage: .structure)
        try store.append(pending)
        try store.append(hanging)
        try store.append(fired)
        try store.adopt(id: hanging.id)
        _ = try store.settle(trigger: .structureRegen, note: "结构被推翻")
        XCTAssertEqual(store.risks.filter { $0.status == .mitigating }.count, 1)

        try store.settleAllForRelease()
        // 未闭合（open + mitigating）→ accepted 自留；triggered 封板不动
        XCTAssertEqual(store.risks.first { $0.id == pending.id }?.status, .accepted)
        XCTAssertEqual(store.risks.first { $0.id == hanging.id }?.status, .accepted)
        XCTAssertEqual(
            store.risks.first { $0.id == pending.id }?.resolution,
            "封板收尾 · 风险自留（带入 PRD 已知风险）"
        )
        XCTAssertEqual(store.risks.first { $0.id == fired.id }?.status, .triggered)
        XCTAssertEqual(store.activeRisks.count, 0, "封板后无未闭合条目")

        // 重开 store（append-only 折叠）：终态保持
        let reloaded = RiskStore(project: "风险项目", version: "v1.0")
        XCTAssertEqual(reloaded.risks.filter { $0.status == .accepted }.count, 2)
        XCTAssertEqual(reloaded.risks.first { $0.id == fired.id }?.status, .triggered)
    }

    // MARK: 旧版 risks.jsonl 解码兼容（无 impact/plan、带 trigger_signal）

    func testLegacyRecordDecodeCompat() throws {
        try makeWorkspace()
        let risksURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "risks.jsonl"
        )
        // 旧版行格式：无 impact/plan，trigger_signal 必带，status 为旧终态
        let legacyLine = #"{"id":"r_legacy1","version":"v1.0","stage":"prototype","hypothesis":"旧版假设","triggerSignal":"structure_regen","status":"closed_unfired","originRef":"自评审（prototype）","createdAt":"2026-01-01T00:00:00Z"}"#
        try legacyLine.write(to: risksURL, atomically: true, encoding: .utf8)

        let store = RiskStore(project: "风险项目", version: "v1.0")
        XCTAssertEqual(store.risks.count, 1)
        let legacy = try XCTUnwrap(store.risks.first)
        XCTAssertEqual(legacy.id, "r_legacy1")
        XCTAssertEqual(legacy.status, .closedUnfired)
        XCTAssertEqual(legacy.triggerSignal, .structureRegen)
        XCTAssertNil(legacy.impact)
        XCTAssertNil(legacy.plan)
    }
}

// MARK: - M3：PRD Agent / 过期传播 / 自评审审计（Task 3.1/3.4/3.5）

@MainActor
final class PipelineM3Tests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-m3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func makePRDWorkspace() throws -> (project: String, version: String) {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "M3项目")
        try PMAgentStore.createVersion("v1.0", in: "M3项目")
        let project = "M3项目", version = "v1.0"
        let dir = PMAgentStore.versionURL(project: project, version: version)
        for rel in [
            ArtifactPath.clarification,
            "02-structure/confirmed.json",
            "03-prototypes/confirmed.json",
            ArtifactPath.prd,
        ] {
            try PMAgentStore.writeVerified("x", to: dir.appendingPathComponent(rel))
        }
        return (project, version)
    }

    // MARK: 过期传播（Task 3.5：结构改→原型+PRD 过期；原型改→PRD 过期）

    func testInvalidateStructureMarksPRDStale() throws {
        let ctx = try makePRDWorkspace()
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)
        XCTAssertEqual(engine.stage, .prd)
        XCTAssertTrue(engine.canGeneratePRD)

        engine.invalidateStructure()
        XCTAssertEqual(engine.stage, .structure)
        XCTAssertFalse(engine.structureConfirmed)
        XCTAssertFalse(engine.canGeneratePRD)
        XCTAssertTrue(engine.prdStale, "PRD 应标记过期（全部下游失效）")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
                .appendingPathComponent("04-prd/stale.json").path
        ))
        // 磁盘推导同步回退：confirmed.json 删除 → structure
        XCTAssertEqual(
            PipelineEngine.deriveStage(project: ctx.project, version: ctx.version), .structure
        )
    }

    func testInvalidatePrototypeMarksPRDStaleAndClear() throws {
        let ctx = try makePRDWorkspace()
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)

        engine.invalidatePrototype()
        XCTAssertEqual(engine.stage, .prototype)
        XCTAssertTrue(engine.prdStale, "PRD 应标记过期（局部下游）")

        // PRD 重写后清除过期标记
        engine.clearPRDStale()
        XCTAssertFalse(engine.prdStale)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
                .appendingPathComponent("04-prd/stale.json").path
        ))
    }

    func testInvalidateWithoutPRDDoesNotMarkStale() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "无PRD项目")
        try PMAgentStore.createVersion("v1.0", in: "无PRD项目")
        let dir = PMAgentStore.versionURL(project: "无PRD项目", version: "v1.0")
        try PMAgentStore.writeVerified("x", to: dir.appendingPathComponent("02-structure/confirmed.json"))

        let engine = PipelineEngine(project: "无PRD项目", version: "v1.0", database: nil)
        engine.invalidateStructure()
        XCTAssertFalse(engine.prdStale, "无 PRD 时无下游可标记")
    }

    // MARK: 自评审审计（Task 3.1：连续 3 轮零修正失效告警）

    func testRecordRadarZeroFixStreak() {
        let engine = PipelineEngine(project: "默认", version: "unversioned", database: nil)
        XCTAssertFalse(engine.recordRadar(fixedCount: 0))
        XCTAssertFalse(engine.recordRadar(fixedCount: 0))
        XCTAssertTrue(engine.recordRadar(fixedCount: 0), "第 3 轮零修正触发告警（只此一次）")
        XCTAssertFalse(engine.recordRadar(fixedCount: 0), "后续轮不重复告警")
        XCTAssertEqual(engine.selfReviewFixes, 0)

        XCTAssertFalse(engine.recordRadar(fixedCount: 2), "有修正清零连击")
        XCTAssertEqual(engine.selfReviewFixes, 2)
        XCTAssertFalse(engine.recordRadar(fixedCount: 0))
        XCTAssertFalse(engine.recordRadar(fixedCount: 0))
        XCTAssertTrue(engine.recordRadar(fixedCount: 0), "重新计满 3 轮再次告警")
    }

    // MARK: ④ 意图识别（回退块目标白名单 / 档位切换）

    func testPRDIntentHelpers() {
        // 回退意图改由 LLM 回退块（artifact:backtrack）承载：AppModel.backtrackStage
        // 只做目标字段白名单校验，任意自然说法由模型识别，不再依赖固定话术正则。
        XCTAssertEqual(AppModel.backtrackStage("prototype"), .prototype)
        XCTAssertEqual(AppModel.backtrackStage(" structure "), .structure)
        XCTAssertEqual(AppModel.backtrackStage("clarify"), .clarify, "新功能回①增补澄清")
        XCTAssertNil(AppModel.backtrackStage("prd"), "当前阶段不是合法回退目标")
        XCTAssertNil(AppModel.backtrackStage(""))

        XCTAssertEqual(AppModel.tierFromText("用 lean 档"), "lean")
        XCTAssertEqual(AppModel.tierFromText("切换到 Full"), "full")
        XCTAssertEqual(AppModel.tierFromText("标准档"), "standard")
        XCTAssertNil(AppModel.tierFromText("再补充一节数据指标"))
    }

    // MARK: 回退请求块解析（artifact:backtrack）

    func testParseBacktrackRequest() {
        // 无块 → nil
        XCTAssertNil(ArtifactParser.parseBacktrack(
            blocks: ArtifactParser.parseArtifactBlocks(in: "普通回复，没有回退")
        ))

        // 合法块 → 解析出目标与诉求（诉求原样透传；mode 缺省 nil = revise）
        let reply = """
        好的，这就回 ③ 重做原型。

        ```artifact:backtrack
        {"target": "prototype", "instruction": "配色太冷，换成暖色系，整体更精致"}
        ```
        """
        let request = ArtifactParser.parseBacktrack(
            blocks: ArtifactParser.parseArtifactBlocks(in: reply)
        )
        XCTAssertEqual(request?.target, "prototype")
        XCTAssertEqual(request?.instruction, "配色太冷，换成暖色系，整体更精致")
        XCTAssertNil(request?.mode, "mode 缺省按 revise 处理")

        // redo 模式 → 解析出 mode（推翻重来，App 不注入旧版）
        let redo = """
        ```artifact:backtrack
        {"target": "prototype", "instruction": "这版不要了", "mode": "redo"}
        ```
        """
        XCTAssertEqual(
            ArtifactParser.parseBacktrack(
                blocks: ArtifactParser.parseArtifactBlocks(in: redo)
            ),
            ArtifactParser.BacktrackRequest(
                target: "prototype", instruction: "这版不要了", mode: "redo"
            )
        )

        // 无诉求（instruction 缺席）→ nil 诉求（走通用重做指令）
        let bare = """
        ```artifact:backtrack
        {"target": "structure"}
        ```
        """
        XCTAssertEqual(
            ArtifactParser.parseBacktrack(
                blocks: ArtifactParser.parseArtifactBlocks(in: bare)
            ),
            ArtifactParser.BacktrackRequest(target: "structure", instruction: nil, mode: nil)
        )

        // JSON 不合法 → nil（模型误判由白名单 + 容错双层兜底）
        let broken = """
        ```artifact:backtrack
        不是 JSON
        ```
        """
        XCTAssertNil(ArtifactParser.parseBacktrack(
            blocks: ArtifactParser.parseArtifactBlocks(in: broken)
        ))
    }

    // MARK: 回退协议注入（②③④ 提示词包含 backtrack 段；② 仅含 clarify 目标）

    func testBacktrackSectionInPrompts() {
        let prototypePrompt = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD", injection: ""
        )
        XCTAssertTrue(prototypePrompt.contains("artifact:backtrack"), "③ 提示词含回退协议")
        XCTAssertTrue(prototypePrompt.contains("\"structure\""), "③ 可回退②结构")
        XCTAssertTrue(prototypePrompt.contains("\"clarify\""), "③ 可回①澄清（新功能）")
        XCTAssertTrue(prototypePrompt.contains("\"mode\""), "回退协议含 mode 字段（revise/redo）")

        let prdPrompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "", coreFlows: "",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        XCTAssertTrue(prdPrompt.contains("artifact:backtrack"), "④ 提示词含回退协议")
        XCTAssertTrue(prdPrompt.contains("\"prototype\""), "④ 可回退③原型")
        XCTAssertTrue(prdPrompt.contains("\"structure\""), "④ 可回退②结构")
        XCTAssertTrue(prdPrompt.contains("\"clarify\""), "④ 可回①澄清（新功能）")

        let structurePrompt = AgentPrompts.structure(clarification: "要点", injection: "")
        XCTAssertTrue(structurePrompt.contains("artifact:backtrack"), "② 含变更提案协议（新功能回①增补澄清）")
        // ② 的回退目标校验收窄到变更提案段内断言（快速通道段合法引入 prototype/prd 字样）
        if let backtrackStart = structurePrompt.range(of: "━━ 变更提案"),
           let ffStart = structurePrompt.range(of: "━━ 快速通道") {
            let backtrackSection = structurePrompt[backtrackStart.lowerBound..<ffStart.lowerBound]
            XCTAssertTrue(backtrackSection.contains("\"clarify\""), "② 只含 clarify 目标")
            XCTAssertFalse(backtrackSection.contains("\"structure\""), "② 不可回自身")
            XCTAssertFalse(backtrackSection.contains("\"prototype\""), "② 不可回下游")
        } else {
            XCTFail("② 提示词缺少回退/快速通道段落标记")
        }
        // ④ 是终点：不注入快速通道
        XCTAssertFalse(prdPrompt.contains("artifact:fast-forward"), "④ 不含快速通道协议")
    }

    // MARK: 新功能增补澄清（回退协议 target=clarify：判断先行、表保留作基底）

    func testBacktrackStageClarifyWhitelist() {
        XCTAssertEqual(AppModel.backtrackStage("clarify"), .clarify, "白名单含 clarify")
        XCTAssertEqual(AppModel.backtrackStage(" structure "), .structure, "前后空白容忍")
        XCTAssertNil(AppModel.backtrackStage("prd"), "prd 不在白名单（④ 是终点）")
        XCTAssertNil(AppModel.backtrackStage("bogus"), "未知目标拒绝")
    }

    func testClarifyPromptAmendBaseSection() {
        // 增补模式：表 = 修订基底，判断先行 + 只问增量
        // （2026-09-18 迁移：基底段随轮次状态进 clarifyStateSection 尾条，不再在冻结段）
        let amend = AgentPrompts.clarifyStateSection(
            rounds: 0, limit: 5, previousTable: "# 既有表\n- target_user: 记录者",
            amending: true
        )
        XCTAssertTrue(amend.contains("既有澄清要点表（增补基底）"), "增补段头")
        XCTAssertTrue(amend.contains("判断先行"), "先判断能不能做/适不适合做")
        XCTAssertTrue(amend.contains("只问增量"), "已覆盖字段不重问")
        XCTAssertTrue(amend.contains("# 既有表"), "旧表全文注入")
        XCTAssertTrue(amend.contains("已问 0 轮"), "轮次状态与基底段同轨")

        // 参考模式（新版本开局）：跨版本表 = 背景参考，不得照抄
        let reference = AgentPrompts.clarifyStateSection(
            rounds: 0, limit: 5, previousTable: "# 上一版表", amending: false
        )
        XCTAssertTrue(reference.contains("背景参考"), "参考段头")
        XCTAssertTrue(reference.contains("不得照抄"), "参考非基底")
        XCTAssertTrue(reference.contains("# 上一版表"))

        // 无表 → 无基底段（首次澄清行为不变）
        let fresh = AgentPrompts.clarifyStateSection(rounds: 0, limit: 5)
        XCTAssertFalse(fresh.contains("增补基底"))
        XCTAssertFalse(fresh.contains("背景参考"))
    }

    func testClarificationTableMergeRule() {
        // 首次澄清：无合并段
        let fresh = AgentPrompts.clarificationTable(transcript: "用户：想做个 App")
        XCTAssertFalse(fresh.contains("合并规则"))

        // 增补收束：注入旧表 + 合并规则（未波及字段保持原值）
        let merged = AgentPrompts.clarificationTable(
            transcript: "用户：加个消息通知", previous: "# 既有表"
        )
        XCTAssertTrue(merged.contains("既有澄清要点表（增补基底）"))
        XCTAssertTrue(merged.contains("合并规则"))
        XCTAssertTrue(merged.contains("保持原值原样"))
        XCTAssertTrue(merged.contains("# 既有表"))

        // transcript 置顶（前缀缓存契约）：确认链三连抽共享底稿前缀
        XCTAssertTrue(fresh.hasPrefix("## 对话记录\n用户：想做个 App"))
        XCTAssertTrue(merged.hasPrefix("## 对话记录\n用户：加个消息通知"))
        // 底稿在前、指令在后（材料 → 任务的阅读顺序）
        let transcriptRange = fresh.range(of: "用户：想做个 App")!
        let taskRange = fresh.range(of: "——以上为材料，以下为任务——")!
        XCTAssertLessThan(transcriptRange.lowerBound, taskRange.lowerBound)
    }

    /// 抽取底稿助手（2026-09-18 classify 162k 收敛）：产物块剥离 + 硬上限裁最旧。
    func testExtractionTranscriptStripsArtifactsAndCapsOldest() {
        let ts = ISO8601DateFormatter().string(from: Date())
        let withBlock = "正文说明。\n```artifact:radar\n缺项：目标用户\n```\n尾注。"
        let entries = [
            DiscussionEntry(
                id: "1", sessionId: "s", role: .user, content: "最旧的一轮", createdAt: ts
            ),
            DiscussionEntry(
                id: "2", sessionId: "s", role: .assistant, content: withBlock, createdAt: ts
            ),
            DiscussionEntry(
                id: "3", sessionId: "s", role: .user, content: "最新的一轮", createdAt: ts
            ),
        ]

        // 产物块剥离：块内容不进底稿，占位标注在场，对话正文保留
        let transcript = AppModel.extractionTranscript(from: entries, budget: 10_000)
        XCTAssertFalse(transcript.contains("缺项：目标用户"), "产物块正文不进抽取底稿")
        XCTAssertTrue(transcript.contains("产物块已省略"), "剥离处以占位标注如实说明")
        XCTAssertTrue(transcript.contains("正文说明。"), "块外对话正文保留")
        XCTAssertTrue(transcript.contains("最新的一轮"))
        XCTAssertFalse(transcript.contains("已超出抽取底稿上限"), "预算内不裁剪")

        // 硬上限：预算压到极小 → 从最旧丢起（保留至少 2 条），尾注如实标注
        let capped = AppModel.extractionTranscript(from: entries, budget: 5)
        XCTAssertFalse(capped.contains("最旧的一轮"), "超预算从最旧条目丢起")
        XCTAssertTrue(capped.contains("最新的一轮"), "最新条目保留")
        XCTAssertTrue(capped.contains("已超出抽取底稿上限"), "裁剪尾注如实告知")
    }

    func testDeriveStageClarifyAmendMarker() throws {
        let project = " amend-proj ", version = "v1"
        let dir = PMAgentStore.versionURL(project: project, version: version)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("01-requirements", isDirectory: true),
            withIntermediateDirectories: true
        )

        // 无表 → clarify
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .clarify)

        // 有表无标记 → structure（要点表落盘即闸口）
        try "# 表".write(
            to: dir.appendingPathComponent(ArtifactPath.clarification),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .structure)

        // 有表 + amend 标记 → clarify（增补澄清进行中）
        try "{}".write(
            to: dir.appendingPathComponent(ArtifactPath.clarifyAmend),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .clarify)

        // 结构确认 → prototype（增补收束后闸口恢复推导）
        let structConfirmed = dir.appendingPathComponent("02-structure/confirmed.json")
        try FileManager.default.createDirectory(
            at: structConfirmed.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{}".write(to: structConfirmed, atomically: true, encoding: .utf8)
        XCTAssertEqual(PipelineEngine.deriveStage(project: project, version: version), .prototype)
    }

    func testInvalidateClarifyKeepsTableAndPropagates() throws {
        let project = " amend-engine ", version = "v2"
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let engine = PipelineEngine(project: project, version: version, database: nil)
        for sub in ["01-requirements", "02-structure", "03-prototypes", "04-prd"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // 盘面：表 + 结构产物 + 双确认 + PRD
        try "# 表".write(to: dir.appendingPathComponent(ArtifactPath.clarification),
                         atomically: true, encoding: .utf8)
        try "# 架构图".write(to: dir.appendingPathComponent(ArtifactPath.architecture),
                             atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("02-structure/confirmed.json"),
                       atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("03-prototypes/confirmed.json"),
                       atomically: true, encoding: .utf8)
        try "# PRD".write(to: dir.appendingPathComponent(ArtifactPath.prd),
                          atomically: true, encoding: .utf8)
        engine.syncFromDisk()
        XCTAssertEqual(engine.stage, .prd, "双确认齐备 → ④ PRD（新功能在下游任意阶段提出）")

        // 回①：stage 推导回 clarify；表与产物文件保留；确认清除；PRD 标过期；轮次清零
        engine.invalidateClarify()
        XCTAssertEqual(engine.stage, .clarify)
        XCTAssertTrue(engine.isAmendingClarify, "增补标记写入")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ArtifactPath.clarification).path
        ), "要点表保留作增补基底")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ArtifactPath.architecture).path
        ), "结构产物保留作修订基底")
        XCTAssertFalse(engine.structureConfirmed, "下游确认清除（过期传播）")
        XCTAssertFalse(engine.prototypeConfirmed)
        XCTAssertTrue(engine.prdStale, "PRD 过期标记")
        XCTAssertEqual(engine.clarifyRounds, 0, "新一轮澄清周期")

        // 收束推进：增补标记清除 → 推导回 structure
        engine.advanceFromClarify()
        XCTAssertEqual(engine.stage, .structure)
        XCTAssertFalse(engine.isAmendingClarify, "收束清标记")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ArtifactPath.clarifyAmend).path
        ))
    }


    // MARK: 本轮任务计划卡（artifact:plan，plan-act-reflect 的 plan 段）

    func testParsePlan() {
        // 无块 → nil
        XCTAssertNil(ArtifactParser.parsePlan(
            blocks: ArtifactParser.parseArtifactBlocks(in: "普通回复，没有计划块")
        ))

        // 合法块：mission + steps（`do` 键解码）；basis 省略兼容
        let reply = """
        先规划本轮工作，再动手——

        ```artifact:plan
        {"mission": "按用户反馈补齐支付流程",
         "steps": [
           {"do": "修订核心流程图，补支付失败分支", "basis": "用户 3 轮反馈集中在此"},
           {"do": "同步更新映射表支付页说明"}
         ]}
        ```
        """
        let plan = ArtifactParser.parsePlan(
            blocks: ArtifactParser.parseArtifactBlocks(in: reply)
        )
        XCTAssertEqual(plan?.mission, "按用户反馈补齐支付流程")
        XCTAssertEqual(plan?.steps.count, 2)
        XCTAssertEqual(plan?.steps[0].action, "修订核心流程图，补支付失败分支")
        XCTAssertEqual(plan?.steps[0].basis, "用户 3 轮反馈集中在此")
        XCTAssertNil(plan?.steps[1].basis, "basis 省略 → nil")
    }

    func testParsePlanNormalization() {
        // 步数 clamp ≤8、空步骤丢弃、mission 空白置 nil
        let manyJSON = (1...10).map { i in
            "{\"do\":\"步骤\(i)\"}"
        }.joined(separator: ",")
        let clamped = ArtifactParser.parsePlan(blocks: ArtifactParser.parseArtifactBlocks(in: """
        ```artifact:plan
        {"mission": "  ", "steps": [\(manyJSON), {"do": "  "}, {"do": "有效步骤"}]}
        ```
        """))
        XCTAssertEqual(clamped?.steps.count, 8, "步骤 clamp ≤ 8（截前 8 项）")
        XCTAssertNil(clamped?.mission, "mission 空白置 nil")

        // 无有效步骤 → nil
        XCTAssertNil(ArtifactParser.parsePlan(blocks: ArtifactParser.parseArtifactBlocks(in: """
        ```artifact:plan
        {"mission": "目标", "steps": [{"do": ""}, {"do": " "}]}
        ```
        """)))
    }

    func testPlanSectionInjectedIntoProductionStagesOnly() {
        // ②③④ 必注（plan-act-reflect），① 澄清是对话阶段不注入
        let structurePrompt = AgentPrompts.structure(clarification: "要点", injection: "")
        let prototypePrompt = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "flowchart TD", injection: ""
        )
        let prdPrompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "", coreFlows: "",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        for (name, prompt) in [("②", structurePrompt), ("③", prototypePrompt), ("④", prdPrompt)] {
            XCTAssertTrue(prompt.contains("artifact:plan"), "\(name) 提示词含计划卡协议")
            XCTAssertTrue(prompt.contains("先计划后执行"), "\(name) 计划协议含先计划后执行")
            XCTAssertTrue(prompt.contains("本轮不产出产物时不输出计划块"), "\(name) 含豁免规则（防仪式化）")
        }
        let clarifyPrompt = AgentPrompts.clarify(injection: "")
        XCTAssertFalse(clarifyPrompt.contains("artifact:plan"), "① 澄清不注入计划协议")
        // 计划块不在 strip 白名单之外的消费路径——radar/decision 自评块照常不受影响
        XCTAssertTrue(structurePrompt.contains("artifact:radar"), "② 自评审协议不受影响")
    }

    // MARK: Agent 主动简报（风险登记 / 变更池催办）

    func testProactiveBriefingPromptsContract() {
        // 两组主动轮 prompt 的共同契约：注入区接入 + artifact 协议块硬禁令
        // （简报轮刻意不带产物协议——模型违规输出协议块会触发跨切处理）
        let injection = "记忆注入样例行"
        let riskSystem = AgentPrompts.riskBriefingSystem(injection: injection)
        XCTAssertTrue(riskSystem.contains(injection), "风险简报带注入区")
        XCTAssertTrue(riskSystem.contains("禁止输出任何 ```artifact: 协议块"), "风险简报禁产物块")
        XCTAssertTrue(riskSystem.contains("右侧「风险」面板"), "引导到风险台账处置")

        let poolSystem = AgentPrompts.poolGraduationSystem(injection: injection)
        XCTAssertTrue(poolSystem.contains(injection), "变更池催办带注入区")
        XCTAssertTrue(poolSystem.contains("禁止输出任何 ```artifact: 协议块"), "变更池催办禁产物块")
        XCTAssertTrue(poolSystem.contains("决策日志"), "引导到决策日志裁决")

        // 合成指令载荷：风险三要素 + 池内想法逐条呈现
        let risk = RiskRecord(
            version: "v1.0", stage: .prd,
            hypothesis: "用户可能不接受订阅制",
            impact: "商业化口径塌方",
            plan: "先出买断 + 订阅双轨验证",
            originRef: "自评审（prd）"
        )
        let riskTask = AgentPrompts.riskBriefingTask(records: [risk])
        XCTAssertTrue(riskTask.contains("用户可能不接受订阅制"))
        XCTAssertTrue(riskTask.contains("商业化口径塌方"))
        XCTAssertTrue(riskTask.contains("先出买断 + 订阅双轨验证"))

        let item = ChangeItem(
            proposal: ChangeProposalRecord(
                idea: "加一个消息通知", category: "模块核心", checkpointStage: "prd"
            ),
            resolution: .pooled, resolutionNote: nil
        )
        let poolTask = AgentPrompts.poolGraduationTask(items: [item])
        XCTAssertTrue(poolTask.contains("加一个消息通知"))
        XCTAssertTrue(poolTask.contains("纳入后续版本 / 放弃 / 顺延"))
    }

    // MARK: 澄清问题卡（artifact:question-card）

    func testParseQuestionCard() {
        // 无块 → nil
        XCTAssertNil(ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: "普通澄清回复，没有问题卡")
        ))

        // 合法块 → 解析出问题集；id 缺省归一化补齐
        let reply = """
        下面几道题互相独立，集中一次答完——

        ```artifact:question-card
        {"questions":[
          {"id":"platform","title":"这个产品主要面向哪个端？","options":["iOS App","Web 网页端"],"allow_custom":true},
          {"title":"目标用户是谁？","options":["养宠新手","多宠家庭"]}
        ]}
        ```
        """
        let request = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: reply)
        )
        XCTAssertEqual(request?.questions.count, 2)
        XCTAssertEqual(request?.questions[0].id, "platform")
        XCTAssertEqual(request?.questions[0].title, "这个产品主要面向哪个端？")
        XCTAssertEqual(request?.questions[1].id, "q2", "id 缺省归一化补 q2")
        XCTAssertEqual(request?.questions[1].options, ["养宠新手", "多宠家庭"])

        // 病态输出 clamp：题数 >5 截前 5、选项 >4 截前 4
        let manyJSON = (1...7).map { i in
            "{\"id\":\"q\(i)\",\"title\":\"题\(i)\",\"options\":[\"a\",\"b\",\"c\",\"d\",\"e\"]}"
        }.joined(separator: ",")
        let many = """
        ```artifact:question-card
        {"questions":[\(manyJSON)]}
        ```
        """
        let clamped = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: many)
        )
        XCTAssertEqual(clamped?.questions.count, 5, "题数 clamp ≤5")
        XCTAssertEqual(clamped?.questions[0].options?.count, 4, "选项数 clamp ≤4")

        // 空标题题丢弃；空标题占位 id 归一化按过滤后序号补齐
        let partial = """
        ```artifact:question-card
        {"questions":[{"title":"  "},{"title":"有效题"}]}
        ```
        """
        let normalized = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: partial)
        )
        XCTAssertEqual(normalized?.questions.count, 1, "空标题题丢弃")
        XCTAssertEqual(normalized?.questions[0].id, "q1")

        // 全部无效（无有效题）→ nil
        let allEmpty = """
        ```artifact:question-card
        {"questions":[{"title":" "}]}
        ```
        """
        XCTAssertNil(ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: allEmpty)
        ))

        // JSON 不合法 → nil
        let broken = """
        ```artifact:question-card
        不是 JSON
        ```
        """
        XCTAssertNil(ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: broken)
        ))
    }

    // MARK: 问题卡题型判定（multiple 字段 + 题干启发式回退）

    func testQuestionCardMultipleChoice() {
        // LLM 显式标注 multiple:true → 多选
        let explicit = """
        ```artifact:question-card
        {"questions":[{"title":"首版必须覆盖哪些能力？","options":["a","b"],"multiple":true}]}
        ```
        """
        let explicitReq = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: explicit)
        )
        XCTAssertEqual(explicitReq?.questions[0].isMultipleChoice, true, "显式 multiple:true → 多选")

        // 显式 multiple:false 覆盖题干关键词（「哪些」）→ 单选
        let overridden = """
        ```artifact:question-card
        {"questions":[{"title":"覆盖哪些能力？","options":["a","b"],"multiple":false}]}
        ```
        """
        let overriddenReq = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: overridden)
        )
        XCTAssertEqual(overriddenReq?.questions[0].isMultipleChoice, false, "显式 false 优先于启发式")

        // 缺省字段 → 题干/说明启发式：并列诉求关键词 → 多选；单一取舍 → 单选
        XCTAssertTrue(ArtifactParser.QuestionCardRequest.Question.inferMultipleChoice(
            title: "首版必须覆盖哪几类核心场景？", detail: nil), "题干「哪几」→ 多选")
        XCTAssertTrue(ArtifactParser.QuestionCardRequest.Question.inferMultipleChoice(
            title: "目标用户是谁？", detail: "可选多个方向"), "说明含「多个」→ 多选")
        XCTAssertFalse(ArtifactParser.QuestionCardRequest.Question.inferMultipleChoice(
            title: "这个产品首要落在哪个端？", detail: "端决定了交互形态"), "单一取舍 → 单选")
    }

    // MARK: 问题卡协议注入（① 澄清卡；②③ 经快速通道携带 prd_preflight 前置分诊；④ prd_defaults 默认项卡）

    func testQuestionCardSectionInPrompts() {
        let clarifyPrompt = AgentPrompts.clarify(injection: "")
        XCTAssertTrue(clarifyPrompt.contains("artifact:question-card"), "① 提示词含问题卡协议")
        XCTAssertTrue(clarifyPrompt.contains("allow_custom"), "协议含自定义输入字段")
        XCTAssertTrue(clarifyPrompt.contains("\"multiple\""), "协议含题型标注字段")
        XCTAssertTrue(clarifyPrompt.contains("首个问题卡必须包含平台题"), "平台未定时平台题必含")
        XCTAssertTrue(clarifyPrompt.contains("【问题卡作答】"), "答案回传协议说明")
        XCTAssertTrue(clarifyPrompt.contains("不再追加 A) 选项行"), "出卡轮免选项行")

        // ②③：常规提问仍走选项行，但快速通道协议内嵌「PRD 前置确认分诊」（prd_preflight）
        let structurePrompt = AgentPrompts.structure(clarification: "要点", injection: "")
        XCTAssertTrue(structurePrompt.contains("prd_preflight"), "② 经快速通道携带 PRD 前置确认卡规范")
        XCTAssertTrue(structurePrompt.contains("PRD 前置确认分诊"), "② 含 ≤3 走卡 / ≥4 文字清单的分诊规则")

        let prototypePrompt = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD", injection: ""
        )
        XCTAssertTrue(prototypePrompt.contains("prd_preflight"), "③ 同样携带前置分诊规范")

        // ④：无前置分诊（已在 PRD 阶段），出稿轮携带默认项卡协议
        let prdPrompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "", coreFlows: "",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        XCTAssertFalse(prdPrompt.contains("prd_preflight"), "④ 已在 PRD 阶段，无前置分诊")
        XCTAssertTrue(prdPrompt.contains("prd_defaults"), "④ 含默认项卡协议")
        XCTAssertTrue(prdPrompt.contains("保持默认"), "默认项卡首选项 = 保持默认")
        XCTAssertTrue(prdPrompt.contains("【问题卡作答】"), "默认项卡答案回传协议")
    }

    // MARK: 问题卡 purpose 变体（prd_preflight / prd_defaults，仅 App 分流用）

    func testParseQuestionCardPurpose() {
        // prd_preflight：解析 + 归一化保留
        let preflight = """
        先确认这几点就出稿——

        ```artifact:question-card
        {"purpose":"prd_preflight","questions":[
          {"id":"timing","title":"提醒时机怎么定？","options":["纳入 v1","实施期再定"]}
        ]}
        ```
        """
        let preflightRequest = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: preflight)
        )
        XCTAssertEqual(preflightRequest?.purpose, "prd_preflight")
        XCTAssertEqual(preflightRequest?.questions.count, 1)

        // prd_defaults：同上
        let defaults = """
        ```artifact:question-card
        {"purpose":"prd_defaults","questions":[
          {"title":"提醒时机按「纳入 v1」起草，是否调整？","options":["保持默认：纳入 v1","实施期再定"]}
        ]}
        ```
        """
        let defaultsRequest = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: defaults)
        )
        XCTAssertEqual(defaultsRequest?.purpose, "prd_defaults")

        // 旧口径缺省 purpose → nil（① 澄清卡兼容）
        let legacy = """
        ```artifact:question-card
        {"questions":[{"title":"目标用户是谁？"}]}
        ```
        """
        let legacyRequest = ArtifactParser.parseQuestionCard(
            blocks: ArtifactParser.parseArtifactBlocks(in: legacy)
        )
        XCTAssertNil(legacyRequest?.purpose, "缺省 purpose = ① 澄清卡")
        XCTAssertNotNil(legacyRequest)
    }

    // MARK: PRD 回复混合块解析（artifact:prd + question-card 共存）

    func testParsePRDReplyWithQuestionCardBlock() {
        let reply = """
        PRD 已生成——

        ````artifact:prd
        # PRD 文档
        ## 需求概述
        ````
        radar 照常——

        ```artifact:question-card
        {"purpose":"prd_defaults","questions":[
          {"id":"timing","title":"提醒时机按「纳入 v1」起草，是否调整？","options":["保持默认：纳入 v1","实施期再定"]}
        ]}
        ```
        """
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        XCTAssertEqual(blocks.first(where: { $0.name == "prd" })?.content.contains("PRD 文档"), true,
                       "PRD 产物块完整可解析")
        let card = ArtifactParser.parseQuestionCard(blocks: blocks)
        XCTAssertEqual(card?.purpose, "prd_defaults", "混合块中问题卡正常解析")
        XCTAssertEqual(card?.questions.first?.options?.first, "保持默认：纳入 v1")
    }

    // MARK: 问题卡答案拼装（提交消息格式 = 已提交判定依据）

    func testQuestionCardAssembledAnswer() {
        let assembled = QuestionCardAssembly.assemble(
            titles: ["这个产品主要面向哪个端？", "目标用户是谁？", "v1 最核心的使用场景是？"],
            answers: ["iOS App", nil, "健康档案与就医记录"]
        )
        XCTAssertTrue(assembled.hasPrefix(QuestionCardAssembly.marker), "提交消息带统一前缀")
        XCTAssertTrue(assembled.contains("1. 这个产品主要面向哪个端？ → iOS App"))
        XCTAssertTrue(assembled.contains("2. 目标用户是谁？ → （跳过）"), "跳过项显式标注，LLM 记入 open_questions")
        XCTAssertTrue(assembled.contains("3. v1 最核心的使用场景是？ → 健康档案与就医记录"))
        XCTAssertFalse(assembled.contains("nil"), "nil 不应泄漏进消息文本")
    }

    // MARK: 迭代基底（上一版产物全文注入：反馈驱动的修订，而非盲重画）

    func testRevisionBaseSection() {
        // nil / 空白 → 空串（首次生成无基底，行为不变）
        XCTAssertEqual(AgentPrompts.revisionBaseSection(title: "原型", previous: nil), "")
        XCTAssertEqual(AgentPrompts.revisionBaseSection(title: "原型", previous: "  \n  "), "")

        // 有内容 → 基底段：段头标记 + 保留指令 + 全文（不折叠）
        let section = AgentPrompts.revisionBaseSection(
            title: "原型", previous: "<html>旧版</html>", fence: "html"
        )
        XCTAssertTrue(section.contains("上一版原型（修订基底）"))
        XCTAssertTrue(section.contains("仅做反馈明确要求的变化"), "基底段明确「只改说的部分」")
        XCTAssertTrue(section.contains("未提及的部分原样保留"))
        XCTAssertTrue(section.contains("<html>旧版</html>"), "全文注入不折叠")

        // fence：HTML 原型围栏包裹
        XCTAssertTrue(section.contains("```html"))

        // Markdown 产物裸放（防嵌套围栏错乱）
        let mdSection = AgentPrompts.revisionBaseSection(title: "PRD", previous: "# PRD v1")
        XCTAssertTrue(mdSection.contains("# PRD v1"))
        XCTAssertFalse(mdSection.contains("```"))
    }

    func testRevisionBaseSectionConditionalPhrasingAndPriorityRule() {
        // 2026-09-18 思考空转个案分析（19% 思考量耗在仲裁输入矛盾）后的两处措辞修正：
        let section = AgentPrompts.revisionBaseSection(title: "PRD", previous: "# 旧稿")
        // ① 条件式措辞：不武断断言本轮必有修改反馈（生成类请求也进迭代分支）
        XCTAssertTrue(section.contains("若用户消息是对这一版的修改反馈"))
        XCTAssertFalse(section.contains("用户反馈是针对这一版的修改："))
        // ② 优先级规则：基底与已确认上游冲突时对齐上游，把逐点对账压成按规则执行
        XCTAssertTrue(section.contains("以已确认材料为准"))
        XCTAssertTrue(section.contains("不需要反复权衡"))
    }

    func testIterativePromptInjectsPreviousBase() {
        // 段头「上一版×（修订基底）」是注入段独有标记（backtrack 协议文案里的
        // 「修订基底」字样不算——用完整段头断言防撞词）。
        // ③ 有旧原型 → 逐槽位注入基底；无 → 不含基底段（首次生成行为不变）
        let iterative = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD",
            previousPrototypes: [(label: "交互原型", html: "<html><body>旧原型</body></html>")],
            injection: ""
        )
        XCTAssertTrue(iterative.contains("上一版原型（交互原型）（修订基底）"))
        XCTAssertTrue(iterative.contains("<html><body>旧原型</body></html>"))
        XCTAssertLessThan(
            iterative.range(of: "（修订基底）")!.lowerBound,
            iterative.range(of: "任务：")!.lowerBound,
            "基底段在任务指令之前（先见上一版再干活）"
        )

        let fresh = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD", injection: ""
        )
        XCTAssertFalse(fresh.contains("（修订基底）"), "首次生成无基底，不注入")

        // 多端多基底：逐槽位注入（label 区分端），输出协议含分端块
        let multi = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD",
            previousPrototypes: [
                (label: "交互原型 · 移动端", html: "<html>m</html>"),
                (label: "交互原型 · 桌面端", html: "<html>d</html>"),
            ],
            injection: ""
        )
        XCTAssertTrue(multi.contains("上一版原型（交互原型 · 移动端）（修订基底）"))
        XCTAssertTrue(multi.contains("<html>m</html>"))
        XCTAssertTrue(multi.contains("上一版原型（交互原型 · 桌面端）（修订基底）"))
        XCTAssertTrue(multi.contains("<html>d</html>"))
        XCTAssertTrue(multi.contains("```artifact:prototype-mobile"))
        XCTAssertTrue(multi.contains("```artifact:prototype-desktop"))

        // ② 结构迭代同理
        let structureIterative = AgentPrompts.structure(
            clarification: "要点",
            previousArtifacts: "### 功能架构图\n\ngraph TD", injection: ""
        )
        XCTAssertTrue(structureIterative.contains("上一版结构产物（修订基底）"))
        XCTAssertTrue(structureIterative.contains("### 功能架构图"))
        let structureFresh = AgentPrompts.structure(clarification: "要点", injection: "")
        XCTAssertFalse(structureFresh.contains("（修订基底）"))
    }

    // MARK: 评分卡锚定数字（clarification 约束数 / 映射表行列）

    func testCountConstraints() {
        let md = """
        # 澄清要点表

        ## 目标用户
        小微团队 PM

        ## 约束
        - 离线优先
        - 数据不出本机
        - 零账号

        ## 开放问题
        - 定价模式
        """
        XCTAssertEqual(AppModel.countConstraints(in: md), 3)
        XCTAssertEqual(AppModel.countConstraints(in: "# 无约束"), 0)
    }

    func testMapRowsParsesModulesAndPages() {
        let md = """
        # 模块-页面映射表

        | 模块 | 原型页面 | 页面说明 |
        | --- | --- | --- |
        | 任务管理 | 任务列表页 | P0 |
        | 任务管理 | 任务详情页 | P0 |
        | 报表 | 任务列表页 | 复用 |
        """
        let rows = AppModel.mapRows(in: md)
        XCTAssertEqual(rows.modules, 3)
        XCTAssertEqual(rows.pages, ["任务列表页", "任务详情页"], "页面去重")
    }

    // MARK: 雷达 / 决策解析（radar fatal → 触发信号；decision → 五要素记录）

    func testParseRadarAndDecisions() throws {
        let reply = """
        本轮修正了流程断头路。

        ```artifact:radar
        {"fixed": ["修复流程断头路"], "remaining": [], "covered": ["目标用户", "核心场景"],
         "missing": ["定价模式"],
         "skipped": [{"point": "多租户", "reason": "MVP 不展开"}],
         "fatal": [{"hypothesis": "单机文件粒度足够", "trigger_signal": "structure_regen"}]}
        ```

        ```artifact:decision
        [{"decision": "用本地 JSONL 而非 SQLite 做事实源", "why": "文件是唯一事实源",
          "rejected": [{"option": "SQLite 主存储", "reason": "索引可重建"}],
          "confidence": 0.7, "to_be_verified": true}]
        ```
        """
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        XCTAssertEqual(Set(blocks.map(\.name)), ["radar", "decision"])

        let radar = try XCTUnwrap(ArtifactParser.parseRadar(blocks: blocks))
        XCTAssertEqual(radar.fixed, ["修复流程断头路"])
        XCTAssertEqual(radar.missing, ["定价模式"])
        XCTAssertEqual(radar.skipped?.first?.point, "多租户")
        XCTAssertEqual(radar.fatal?.first?.signal, RiskRecord.TriggerSignal.structureRegen)

        let drafts = ArtifactParser.parseDecisions(blocks: blocks)
        XCTAssertEqual(drafts.count, 1)
        let record = drafts[0].record(version: "v1.0")
        XCTAssertEqual(record.toBeVerified, true)
        XCTAssertEqual(record.confidence, 0.7)
        XCTAssertEqual(record.rejectedAlternatives.first?.option, "SQLite 主存储")
    }

    func testParseRadarUnknownSignalDropped() {
        let reply = """
        ```artifact:radar
        {"fixed": [], "covered": ["x"], "fatal": [{"hypothesis": "h", "trigger_signal": "不存在的信号"}]}
        ```
        """
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        let radar = try? XCTUnwrap(ArtifactParser.parseRadar(blocks: blocks))
        XCTAssertNil(radar?.fatal?.first?.signal, "未知触发信号应返回 nil（调用侧丢弃防悬空）")
    }

    // MARK: 自评审对账 trace（B3 事件驱动：落盘往返 + 跨轮 diff + 💀 去重）

    func testSelfReviewWriteReadRoundTrip() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "B3项目")
        try PMAgentStore.createVersion("v1.0", in: "B3项目")
        // appendLine 不建文件：先铺阶段目录骨架（对账 trace 数据源）
        let base = PMAgentStore.versionURL(project: "B3项目", version: "v1.0")
        for dir in ["01-requirements", "02-structure"] {
            let stageDir = base.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: stageDir.appendingPathComponent("self-review.jsonl").path, contents: nil
            )
        }

        let radar1 = ArtifactParser.RadarReport(
            fixed: ["修正A"], covered: ["目标用户"],
            missing: ["定价模式"],
            skipped: [ArtifactParser.RadarReport.Skipped(point: "多租户", reason: "MVP 不展开")],
            fatal: [ArtifactParser.RadarReport.Fatal(
                hypothesis: "单机文件粒度足够", impact: nil, plan: nil, triggerSignal: nil)]
        )
        try ArtifactParser.writeSelfReview(
            radar1, stage: "clarify", project: "B3项目", version: "v1.0"
        )
        let radar2 = ArtifactParser.RadarReport(covered: ["目标用户", "核心场景"], missing: ["定价模式"])
        try ArtifactParser.writeSelfReview(
            radar2, stage: "structure", project: "B3项目", version: "v1.0"
        )

        let reviews = ArtifactParser.readSelfReviews(project: "B3项目", version: "v1.0")
        XCTAssertEqual(reviews.count, 2, "两轮落盘都要能读回（对账 trace 数据源）")
        let first = try XCTUnwrap(reviews.first)
        let last = try XCTUnwrap(reviews.last)
        XCTAssertEqual([first.stage, last.stage], ["clarify", "structure"], "按时间正序合并")
        XCTAssertEqual(first.radar.covered, ["目标用户"], "covered 全量保留（审计契约不动）")
        XCTAssertEqual(last.radar.covered, ["目标用户", "核心场景"])

        // 旧格式兼容：B3 前经 appendLine(String) 双重编码的行（外层 JSON 字符串）
        // 也能剥层读出（存量会话的 diff 基线依赖此兼容）
        let legacyInner = """
        {"stage":"prototype","radar":{"covered":["旧轮覆盖"]},"createdAt":"2026-09-15T10:00:00+08:00"}
        """
        let protoDir = base.appendingPathComponent("03-prototypes")
        try FileManager.default.createDirectory(at: protoDir, withIntermediateDirectories: true)
        let protoURL = protoDir.appendingPathComponent("self-review.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: protoURL.path, contents: nil))
        let quotedData = try JSONEncoder().encode(legacyInner)
        let handle = try FileHandle(forWritingTo: protoURL)
        try handle.write(contentsOf: quotedData + Data("\n".utf8))
        try handle.close()

        let mixed = ArtifactParser.readSelfReviews(project: "B3项目", version: "v1.0")
        XCTAssertEqual(mixed.count, 3, "旧双重编码行兼容读出")
        XCTAssertEqual(mixed.first?.radar.covered, ["旧轮覆盖"], "createdAt 最早排前")
        XCTAssertEqual(mixed.first?.stage, "prototype")
    }

    func testRadarDiffNormalizedMatching() {
        // 归一化口径：大小写折叠 + 全部空白移除
        XCTAssertEqual(ArtifactParser.normalizedText("  iOS  App\n首版 "), "iosapp首版")

        // ❓ missing：重播（含空白微差）被挡，新增保留本轮顺序
        let newMissing = ArtifactParser.newItems(
            current: ["定价模式", "分发渠道"],
            previous: ["定价 模式", "已答过的用户画像"]
        )
        XCTAssertEqual(newMissing, ["分发渠道"])

        // ⏭️ skipped：point 归一化匹配（reason 变化不算新增）
        let newSkipped = ArtifactParser.newSkipped(
            current: [
                ArtifactParser.RadarReport.Skipped(point: "多租户", reason: "MVP 不展开"),
                ArtifactParser.RadarReport.Skipped(point: "SSO", reason: "v2 再说"),
            ],
            previous: [ArtifactParser.RadarReport.Skipped(point: "多 租户", reason: "旧理由")]
        )
        XCTAssertEqual(newSkipped.map(\.point), ["SSO"])

        // 💀 fatal：与台账全量 hypothesis 归一化去重——重播不重复登记
        let fresh = ArtifactParser.newFatals(
            current: [
                ArtifactParser.RadarReport.Fatal(
                    hypothesis: "单机文件粒度足够", impact: nil, plan: nil, triggerSignal: nil),
                ArtifactParser.RadarReport.Fatal(
                    hypothesis: "付费意愿足够强", impact: nil, plan: nil, triggerSignal: nil),
            ],
            existingHypotheses: ["单机  文件粒度足够", "已登记的其他假设"]
        )
        XCTAssertEqual(fresh.map(\.hypothesis), ["付费意愿足够强"])
    }
}

/// PRD 模板 13 章契约（2026-09-16 结构升级）：三档 prompt 均嵌入模板全文，
/// 骨架章名与关键机制锚必须在场；档位差异（lean 收敛 / full 基线表）可断言。
@MainActor
final class PRDTemplateContractTests: XCTestCase {
    private let chapterAnchors = [
        "文档基本信息", "修订记录", "需求概述", "产品目标与成功指标", "用户分析",
        "设计与原型", "功能清单", "业务流程", "详细设计", "性能与兼容性",
        "发布计划", "上线效果验证", "协作与依赖",
    ]

    private func makePrompt(tier: String) -> String {
        AgentPrompts.prd(
            tier: tier, clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "", coreFlows: "", prototypePages: ["首页"],
            analysisNotes: "", injection: ""
        )
    }

    func testAllTiersEmbedThirteenChapterSkeleton() {
        for tier in ["lean", "standard", "full"] {
            let prompt = makePrompt(tier: tier)
            for anchor in chapterAnchors {
                XCTAssertTrue(prompt.contains(anchor), "\(tier) 档缺章锚：\(anchor)")
            }
            XCTAssertTrue(prompt.contains("目标收敛句"), "\(tier) 档缺目标收敛句")
            XCTAssertTrue(prompt.contains("行为规则表"), "\(tier) 档缺行为规则表")
            XCTAssertTrue(prompt.contains("状态完整性"), "\(tier) 档缺状态完整性检验")
            XCTAssertTrue(prompt.contains("穷举三步法"), "\(tier) 档缺状态穷举三步法")
            XCTAssertTrue(prompt.contains("验收 eval"), "\(tier) 档缺验收 eval")
        }
    }

    func testFullTemplateAddsBaselineAndDecisionLink() {
        let prompt = makePrompt(tier: "full")
        XCTAssertTrue(prompt.contains("基线表"), "full 档必备基线表")
        XCTAssertTrue(prompt.contains("决策回链"), "full 档必备决策回链")
    }

    func testLeanTemplateCollapsesDetail() {
        let prompt = makePrompt(tier: "lean")
        XCTAssertTrue(prompt.contains("页面概览"), "lean 每页 3 子项之一")
        XCTAssertFalse(prompt.contains("基线表"), "lean 档不展开基线表")
        XCTAssertFalse(prompt.contains("状态流转图"), "lean 档免状态流转图")
    }

    // MARK: - rejections 注入（PRD 3.4「范围-不包含」数据源）

    func testRejectionsInjectionListsRejectedAlternatives() {
        let record = DecisionRecord(
            version: "v1.0", decision: "采用 A 方案", why: "成本最低",
            rejectedAlternatives: [
                RejectedAlternative(option: "B 方案", reason: "集成成本高", owner: "adopted"),
                RejectedAlternative(option: "C 方案", reason: "超出范围", owner: nil),
            ]
        )
        let injection = AppModel.rejectionsInjection([record])
        XCTAssertTrue(injection.contains("B 方案"))
        XCTAssertTrue(injection.contains("否决原因：集成成本高"))
        XCTAssertTrue(injection.contains("范围-不包含"))
        XCTAssertTrue(injection.contains("AI建议-采纳"), "所有权标注展示")
        XCTAssertTrue(injection.contains("C 方案"), "无所有权标注的行不丢")
    }

    func testRejectionsInjectionEmptyReturnsEmptyString() {
        XCTAssertEqual(AppModel.rejectionsInjection([]), "")
        let noAlternatives = DecisionRecord(version: "v1.0", decision: "拍板", why: "唯一可行")
        XCTAssertEqual(AppModel.rejectionsInjection([noAlternatives]), "")
    }

    func testRejectionsInjectionBudgetTruncation() {
        let record = DecisionRecord(
            version: "v1.0", decision: "拍板", why: "w",
            rejectedAlternatives: [
                RejectedAlternative(option: "超长项", reason: String(repeating: "长", count: 400)),
            ]
        )
        XCTAssertTrue(AppModel.rejectionsInjection([record]).contains("（其余略）"))
    }

    // MARK: - supersedes 协议（2026-09-18 思考空转个案分析：被推翻的旧否决不再注入）

    private func makeRejectionRecord(
        id: String, options: [(String, String)], createdAt: String
    ) -> DecisionRecord {
        DecisionRecord(
            id: id, version: "v1.0", decision: "决策 \(id)", why: "w",
            rejectedAlternatives: options.map {
                RejectedAlternative(option: $0.0, reason: $0.1)
            },
            createdAt: createdAt
        )
    }

    func testRejectionsInjectionSkipsSupersededEntries() {
        let old = makeRejectionRecord(
            id: "d_old",
            options: [("移动端优先", "用户未选，需验证"), ("双端薄铺", "火力分散")],
            createdAt: "2026-09-14T06:12:13Z"
        )
        let pivot = DecisionRecord(
            id: "d_pivot", version: "v1.0", decision: "v1 移动优先", why: "用户裁决",
            supersedes: ["d_old#0"], createdAt: "2026-09-16T06:12:13Z"
        )
        let injection = AppModel.rejectionsInjection([old, pivot])
        XCTAssertFalse(injection.contains("移动端优先"), "被推翻的旧否决不再注入（生效视图）")
        XCTAssertTrue(injection.contains("双端薄铺"), "未被取代的否决保留")
    }

    func testSupersedableRejectionsRendersRefsAndFiltersSuperseded() {
        let old = makeRejectionRecord(
            id: "d_old",
            options: [("移动端优先", "需验证"), ("双端薄铺", "火力分散")],
            createdAt: "2026-09-14T06:12:13Z"
        )
        let section = AppModel.supersedableRejections([old])
        XCTAssertTrue(section.contains("[d_old#0] 移动端优先"), "引用键 = 决策id#序号")
        XCTAssertTrue(section.contains("[d_old#1] 双端薄铺"))
        XCTAssertTrue(section.contains("否决于 09-14"), "日期锚定 MM-DD")
        XCTAssertTrue(section.contains("supersedes"), "段头带协议指引")

        // 已被取代的引用键不再下发（防模型照抄已失效的键）
        let pivot = DecisionRecord(
            id: "d_pivot", version: "v1.0", decision: "v1 移动优先", why: "用户裁决",
            supersedes: ["d_old#0"], createdAt: "2026-09-16T06:12:13Z"
        )
        let filtered = AppModel.supersedableRejections([old, pivot])
        XCTAssertFalse(filtered.contains("[d_old#0]"), "被取代引用键下线")
        XCTAssertTrue(filtered.contains("[d_old#1]"), "未取代引用键保留")
    }

    func testSupersedableRejectionsEmptyCases() {
        XCTAssertEqual(AppModel.supersedableRejections([]), "")
        let noAlternatives = DecisionRecord(version: "v1.0", decision: "拍板", why: "唯一可行")
        XCTAssertEqual(AppModel.supersedableRejections([noAlternatives]), "")
    }

    func testDecisionDraftParsesSupersedesAndCarriesToRecord() throws {
        let json = #"{"decision": "v1 移动优先", "why": "用户裁决", "supersedes": ["d_old#0"]}"#
        let draft = try JSONDecoder()
            .decode(ArtifactParser.DecisionDraft.self, from: Data(json.utf8))
        XCTAssertEqual(draft.supersedes, ["d_old#0"])
        XCTAssertEqual(draft.record(version: "v1.0").supersedes, ["d_old#0"])
    }

    func testDecisionDraftWithoutSupersedesDecodesNil() throws {
        // 旧格式（无 supersedes 键）照常解码——历史行与旧模型输出双向兼容
        let json = #"{"decision": "拍板", "why": "唯一可行"}"#
        let draft = try JSONDecoder()
            .decode(ArtifactParser.DecisionDraft.self, from: Data(json.utf8))
        XCTAssertNil(draft.supersedes)
        XCTAssertNil(draft.record(version: "v1.0").supersedes)
    }

    // MARK: - 模板版本戳 + 升级失效（2026-09-17 钦定：产出必须按当前模板版本）

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-prdtpl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func makeWorkspace(name: String, withPRD: Bool) throws -> (project: String, version: String) {
        try PMAgentStore.bootstrap()
        let project = "\(name)-\(UUID().uuidString.prefix(6))"
        try PMAgentStore.createProject(named: project)
        try PMAgentStore.createVersion("v1.0", in: project)
        if withPRD {
            try PMAgentStore.writeVerified(
                "旧 PRD", to: PMAgentStore.versionURL(project: project, version: "v1.0")
                    .appendingPathComponent(ArtifactPath.prd)
            )
        }
        return (project, "v1.0")
    }

    private func staleReason(project: String, version: String) -> String? {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("04-prd/stale.json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return record["reason"]
    }

    func testTemplateVersionStampedInAllTiers() {
        for tier in ["lean", "standard", "full"] {
            XCTAssertEqual(AgentPrompts.prdTemplateVersion(tier: tier), "2", "\(tier) 档缺版本行")
        }
    }

    func testWritePRDMetaRecordsCurrentVersion() throws {
        let ctx = try makeWorkspace(name: "戳测试", withPRD: false)
        AppModel.writePRDMeta(project: ctx.project, version: ctx.version, tier: "full")
        let url = PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
            .appendingPathComponent(ArtifactPath.prdMeta)
        let meta = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: url)
        )
        XCTAssertEqual(meta["templateVersion"], "2")
        XCTAssertEqual(meta["tier"], "full")
    }

    func testLegacyPRDWithoutMetaMarkedStale() throws {
        let ctx = try makeWorkspace(name: "存量失效", withPRD: true)
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)
        XCTAssertFalse(engine.prdStale)
        engine.markPRDStaleForTemplateUpgradeIfNeeded(currentVersion: "2")
        XCTAssertTrue(engine.prdStale, "无版本戳的存量 PRD 应标模板过期")
        XCTAssertEqual(staleReason(project: ctx.project, version: ctx.version), "template_upgrade")
    }

    func testCurrentVersionMetaNotMarked() throws {
        let ctx = try makeWorkspace(name: "新版不标", withPRD: true)
        AppModel.writePRDMeta(project: ctx.project, version: ctx.version, tier: "standard")
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)
        engine.markPRDStaleForTemplateUpgradeIfNeeded(currentVersion: "2")
        XCTAssertFalse(engine.prdStale, "当前版本戳的 PRD 不标")
        XCTAssertNil(staleReason(project: ctx.project, version: ctx.version))
    }

    func testOutdatedMetaMarkedStale() throws {
        let ctx = try makeWorkspace(name: "旧版戳", withPRD: true)
        AppModel.writePRDMeta(project: ctx.project, version: ctx.version, tier: "standard")
        // 手写旧版本戳覆盖
        let metaURL = PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
            .appendingPathComponent(ArtifactPath.prdMeta)
        try PMAgentStore.writeVerified(
            "{\"templateVersion\":\"1\",\"tier\":\"standard\",\"writtenAt\":\"x\"}", to: metaURL
        )
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)
        engine.markPRDStaleForTemplateUpgradeIfNeeded(currentVersion: "2")
        XCTAssertTrue(engine.prdStale, "版本戳落后应标模板过期")
        XCTAssertEqual(staleReason(project: ctx.project, version: ctx.version), "template_upgrade")
    }

    func testExistingStaleReasonNotOverwritten() throws {
        let ctx = try makeWorkspace(name: "不覆盖", withPRD: true)
        try PMAgentStore.writeVerified(
            "{\"reason\":\"clarify_backtrack\",\"scope\":\"全部\",\"markedAt\":\"x\"}",
            to: PMAgentStore.versionURL(project: ctx.project, version: ctx.version)
                .appendingPathComponent("04-prd/stale.json")
        )
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)
        engine.markPRDStaleForTemplateUpgradeIfNeeded(currentVersion: "2")
        XCTAssertEqual(
            staleReason(project: ctx.project, version: ctx.version), "clarify_backtrack",
            "已有过期标记保留首次失效原因"
        )
    }

    func testNoPRDDoesNotMark() throws {
        let ctx = try makeWorkspace(name: "无产物", withPRD: false)
        let engine = PipelineEngine(project: ctx.project, version: ctx.version, database: nil)
        engine.markPRDStaleForTemplateUpgradeIfNeeded(currentVersion: "2")
        XCTAssertFalse(engine.prdStale, "无 PRD 无下游可标记")
        XCTAssertNil(staleReason(project: ctx.project, version: ctx.version))
    }
}

/// 回归（2026-09-11 生产 bug）：appendLine 每行以 \n 结尾，append 回读按
/// \n split 后末元素必为空串，旧校验「末行判空」导致每次 append 必抛
/// 「会话写入校验失败」——用户消息/系统行全部进不了内存 entries，
/// 流式回复被 catch 短路，UI 表现为发消息无反应。
final class SessionStoreIOTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    @MainActor
    func testAppendWritesAndVerifiesOnDisk() throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")

        let entry = store.makeEntry(role: .user, content: "你好")
        XCTAssertNoThrow(try store.append(entry), "append 用户消息不得抛错（尾部换行不得误判）")
        XCTAssertEqual(store.entries.count, 1, "append 成功后内存 entries 必须更新（UI 渲染源）")

        // 磁盘末行与重新编码逐字节一致（write-then-verify 语义）
        let jsonl = PMAgentStore.jsonlURL(
            project: "默认", version: "unversioned", file: "discussions.jsonl"
        )
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = String(decoding: try encoder.encode(entry), as: UTF8.self)
        let nonEmpty = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertEqual(nonEmpty.last.map(String.init), expected, "磁盘末行应与写入条目逐字节一致")
    }

    @MainActor
    func testConsecutiveAppendsAllSucceed() throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s2")

        // 连续多条（旧 bug 从第 1 条起即失败）：user / assistant / system 三角色
        let user = store.makeEntry(role: .user, content: "第一问")
        let assistant = store.makeEntry(role: .assistant, content: "第一答")
        let system = store.makeEntry(role: .system, content: "📦 落盘提示")
        try store.append(user)
        try store.append(assistant)
        try store.append(system)

        XCTAssertEqual(
            store.entries.map(\.role), [.user, .assistant, .system],
            "连续 append 后 entries 顺序完整（发消息后 UI 必须有反应的前提）"
        )

        // 回读投影：readLines 完整解析 3 条（磁盘与内存一致）
        let reloaded = PMAgentStore.readLines(
            DiscussionEntry.self,
            from: PMAgentStore.jsonlURL(
                project: "默认", version: "unversioned", file: "discussions.jsonl"
            )
        )
        XCTAssertEqual(reloaded.count, 3)
        XCTAssertEqual(reloaded.map(\.content), ["第一问", "第一答", "📦 落盘提示"])
    }

    // MARK: - 流式回复归属（修复：生成途中切会话导致同答串会话）

    /// 不属于当前会话的条目照常落盘但不得进入内存消息流（UI 渲染源隔离）。
    @MainActor
    func testAppendForeignSessionEntryNotInMemory() throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")
        var foreign = store.makeEntry(role: .assistant, content: "别家的回答")
        foreign.sessionId = "s999"

        try store.append(foreign)

        XCTAssertTrue(store.entries.isEmpty, "不属于当前会话的条目不得进入内存 entries")
        let text = try String(contentsOf: PMAgentStore.jsonlURL(
            project: "默认", version: "unversioned", file: "discussions.jsonl"
        ), encoding: .utf8)
        XCTAssertTrue(text.contains("别家的回答"), "磁盘照常落盘（数据不丢，按 sessionId 投影）")
    }

    /// 生成途中用户切到其他项目/会话：回复必须按 origin 落回发起会话的项目，
    /// 不写进当前停留会话，也不串内存（串会话 bug 的核心回归）。
    @MainActor
    func testAppendPinnedRoutesToOriginWorkspace() throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "甲", version: "unversioned", sessionId: "s1")
        var reply = store.makeEntry(role: .assistant, content: "发起会话的回答")
        reply.sessionId = "s1"

        store.open(project: "乙", version: "unversioned", sessionId: "s2")
        XCTAssertTrue(store.streams.isEmpty, "空闲态无流归属")
        try store.appendPinned(
            reply,
            origin: SessionStore.StreamOrigin(
                project: "甲", version: "unversioned", sessionId: "s1"
            )
        )

        let originText = try String(contentsOf: PMAgentStore.jsonlURL(
            project: "甲", version: "unversioned", file: "discussions.jsonl"
        ), encoding: .utf8)
        XCTAssertTrue(originText.contains("发起会话的回答"), "回复必须落回发起会话的项目")
        let currentText = try? String(contentsOf: PMAgentStore.jsonlURL(
            project: "乙", version: "unversioned", file: "discussions.jsonl"
        ), encoding: .utf8)
        XCTAssertFalse(
            currentText?.contains("发起会话的回答") ?? false,
            "当前停留会话不得混入别家回复"
        )
        XCTAssertTrue(store.entries.isEmpty, "跨会话回复不得串进当前内存消息流")
    }

    /// 切换会话不泄漏上一会话的流态：流态按会话键隔离，新会话无键即无流式气泡；
    /// 他会话进行中的流态保留在键里（切回仍可见），空态键由收尾路径移除。
    @MainActor
    func testOpenDoesNotLeakPreviousSessionsStreamState() throws {
        try? PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "默认", version: "unversioned", sessionId: "s1")
        store.beginPreparingReply(sessionID: "s1")  // s1 占位进行中（等价旧「增量残留」场景）

        store.open(project: "默认", version: "unversioned", sessionId: "s2")

        XCTAssertNil(store.currentStream, "新会话不得继承上一会话的流态")
        XCTAssertEqual(store.streams["s1"]?.isPreparing, true, "他会话进行中的流态保留（切回仍可见）")
    }
}

/// 图片输入链路（2026-09 追加）：存量兼容 + 引用落盘 + MIME 映射。
final class ImageSupportTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-img-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    /// 旧存量 settings.json（无 supportsImages 键）能 decode，默认 false。
    func testStageModelConfigLegacyDecode() throws {
        let legacy = #"{"provider":"deepseek","model":"deepseek-flash"}"#
        let config = try JSONDecoder().decode(
            StageModelConfig.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(config.provider, "deepseek")
        XCTAssertFalse(config.supportsImages, "缺省 supportsImages 必须回退 false")
        // roundtrip 后带出新键
        let encoded = try JSONEncoder().encode(config)
        let redecoded = try JSONDecoder().decode(StageModelConfig.self, from: encoded)
        XCTAssertTrue(redecoded.supportsImages == false)
    }

    /// supportsImages = true 全链路 roundtrip。
    func testStageModelConfigImageRoundtrip() throws {
        let config = StageModelConfig(
            provider: "openai", model: "gpt-4o", baseURL: nil, supportsImages: true
        )
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(StageModelConfig.self, from: encoded)
        XCTAssertTrue(decoded.supportsImages)
    }

    /// 供应商视觉预设：openai/anthropic 网关默认支持，其余默认不支持。
    func testDefaultSupportsImages() {
        XCTAssertTrue(StageModelConfig.defaultSupportsImages(for: "openai"))
        XCTAssertTrue(StageModelConfig.defaultSupportsImages(for: "anthropic-compat"))
        XCTAssertFalse(StageModelConfig.defaultSupportsImages(for: "deepseek"))
        XCTAssertFalse(StageModelConfig.defaultSupportsImages(for: "zhipu"))
        XCTAssertFalse(StageModelConfig.defaultSupportsImages(for: "ollama"))
    }

    /// ChatMessage 带图 roundtrip + dataURL 格式。
    func testChatMessageImagesRoundtrip() throws {
        let message = ChatMessage(
            role: .user, content: "看下这张竞品截图",
            images: [ChatImage(mime: "image/png", base64: "aGk=")]
        )
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
        XCTAssertEqual(decoded.images?.count, 1)
        XCTAssertEqual(decoded.images?.first?.dataURL, "data:image/png;base64,aGk=")

        // 无图消息 decode（旧 JSON 无 images 键）
        let legacy = #"{"role":"user","content":"纯文本"}"#
        let legacyMsg = try JSONDecoder().decode(
            ChatMessage.self, from: Data(legacy.utf8)
        )
        XCTAssertNil(legacyMsg.images)
    }

    /// DiscussionEntry 带图引用 roundtrip + 旧存量无 images 键兼容。
    func testDiscussionEntryImagesRoundtrip() throws {
        let entry = DiscussionEntry(
            id: "e1", sessionId: "s1", role: .user, content: "看图",
            images: ["abc123.png"], createdAt: "t"
        )
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiscussionEntry.self, from: encoded)
        XCTAssertEqual(decoded.images, ["abc123.png"])

        let legacy = """
        {"id":"e2","sessionId":"s1","role":"user","content":"旧消息","createdAt":"t"}
        """
        let legacyEntry = try JSONDecoder().decode(
            DiscussionEntry.self, from: Data(legacy.utf8)
        )
        XCTAssertNil(legacyEntry.images)
    }

    /// 附件存取 roundtrip：saveAttachment → readAttachment 字节一致。
    func testAttachmentSaveAndRead() throws {
        try PMAgentStore.ensureWorkspace(project: "默认", version: "unversioned")
        let payload = Data("fake-png-bytes".utf8)
        let name = try PMAgentStore.saveAttachment(
            data: payload, fileExtension: "png",
            project: "默认", version: "unversioned"
        )
        XCTAssertTrue(name.hasSuffix(".png"), "附件文件名保留扩展名")
        let readBack = PMAgentStore.readAttachment(
            name, project: "默认", version: "unversioned"
        )
        XCTAssertEqual(readBack, payload, "读回字节必须一致")
        // 缺文件返回 nil 不抛
        XCTAssertNil(
            PMAgentStore.readAttachment(
                "no-such.png", project: "默认", version: "unversioned"
            )
        )
    }

    /// MIME 映射表。
    func testImageMIME() {
        XCTAssertEqual(SessionStore.imageMIME(forExtension: "png"), "image/png")
        XCTAssertEqual(SessionStore.imageMIME(forExtension: "jpg"), "image/jpeg")
        XCTAssertEqual(SessionStore.imageMIME(forExtension: "webp"), "image/webp")
        XCTAssertEqual(SessionStore.imageMIME(forExtension: "heic"), "image/png")
    }
}

/// 对话链路真连通冒烟（用户 BYOK 配置实测）：跑在 App 测试宿主进程内
/// （TEST_HOST = pm_worker.app），同签名进程读自己写入的 Keychain item 不弹窗。
/// 无 key / 无网络环境自动 skip——不影响常规测试批次。
final class LLMLiveTests: XCTestCase {

    /// 临时诊断（排查 401）：输出各 keychain 槽位的元数据（不含 key 内容）。
    func testKeychainSlotDiagnostic() {
        for slot in ["byok.deepseek", "byok.zhipu", "byok.openai", "byok.anthropic", "byok.qwen"] {
            let v = KeychainStore.get(slot) ?? ""
            let meta = v.isEmpty
                ? "<空>"
                : "len=\(v.count), sk-前缀=\(v.hasPrefix("sk-")), .com结尾=\(v.hasSuffix(".com")), 含空白=\(v.contains(where: { $0 == " " || $0 == "\n" }))"
            print("DIAG \(slot): \(meta)")
        }
    }

    /// 临时诊断（排查 401）：验证写入路径本身（写→读→清理，不留测试数据）。
    func testKeychainWritePath() throws {
        let slot = "byok.deepseek"
        let original = KeychainStore.get(slot) // 保存原值，结束恢复
        defer { if let original { try? KeychainStore.set(original, forKey: slot) } }

        let marker = "sk-diagwrite-111111111111"
        try KeychainStore.set(marker, forKey: slot)
        XCTAssertEqual(KeychainStore.get(slot), marker, "写入后应立即回读到新值")

        KeychainStore.delete(slot)
        XCTAssertNil(KeychainStore.get(slot), "删除后应为空")
        print("DIAG write-path: OK（写入/回读/删除全通过）")
    }

    /// read 三态：空槽位 = notFound（不是 accessFailed）、写入后 = found——
    /// 「不存在」与「读取失败」必须可区分（2026-09-13 Key「消失」事故）。
    func testKeychainReadDistinguishesNotFoundFromFailure() throws {
        let slot = "byok.unittest.\(UUID().uuidString)"
        guard case .notFound = KeychainStore.read(slot) else {
            XCTFail("未写入的随机槽位应返回 notFound")
            return
        }
        try KeychainStore.set("sk-readtest-123", forKey: slot)
        defer { KeychainStore.delete(slot) }
        guard case .found(let value) = KeychainStore.read(slot) else {
            XCTFail("写入后应返回 found")
            return
        }
        XCTAssertEqual(value, "sk-readtest-123")
    }

    /// 真实配置 + Keychain key → LLMClient 流式对话走通（DeepSeek）。
    func testDeepSeekLiveStreamChat() async throws {
        // 读用户真实设置（Application Support/pm-worker/settings.json）
        let settings = LLMSettings.load()
        let config = settings.chatConfig
        let key = KeychainStore.get(config.apiKeyKeychainKey) ?? ""
        try XCTSkipIf(
            key.isEmpty,
            "Keychain 未存 \(config.apiKeyKeychainKey) 的 key——跳过真连通测试"
        )

        // 配置完整性：baseURL 可解析 + 模型名非空
        XCTAssertFalse(config.resolvedBaseURL.isEmpty, "baseURL 未配置")
        XCTAssertFalse(config.model.isEmpty, "model 未配置")

        let stream = try LLMClient.streamChat(
            stage: .clarify,
            settings: settings,
            messages: [
                ChatMessage(role: .system, content: "你是测试助手，只回复两个字：收到"),
                ChatMessage(role: .user, content: "你好"),
            ],
            maxTokens: 512
        )
        var full = ""
        var reasoning = ""
        for try await delta in stream {
            switch delta {
            case .text(let text): full += text
            case .reasoning(let chunk): reasoning += chunk
            case .toolCalls: break  // 无工具请求时不可达（穷举完备）
            case .truncated: break
            case .retrying: break  // live 测试不校验重试状态
            }
        }
        XCTAssertFalse(
            full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "模型未返回正文（reasoning 已收 \(reasoning.count) 字）——检查模型名/key/端点"
        )
    }
}

// MARK: - 深色模式系统（外观模式枚举 / UserDefaults 持久化）

final class AppearanceTests: XCTestCase {
    // 隔离 suite：测试宿主在真实 App 进程里，UserDefaults.standard 就是用户偏好域，
    // 直接读写会擦掉用户的外观设置（曾导致「设置了深色重启后回跟随系统」）。
    private var defaults: UserDefaults!
    private let suiteName = "test.pm.worker.appearance"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAppearanceModeRoundtrip() {
        for mode in AppearanceMode.allCases {
            let revived = AppearanceMode(rawValue: mode.rawValue)
            XCTAssertEqual(revived, mode, "rawValue 往返应还原 \(mode.rawValue)")
        }
        // 未知存量值 → nil（调用侧回退 .system）
        XCTAssertNil(AppearanceMode(rawValue: "auto"))
        XCTAssertNil(AppearanceMode(rawValue: ""))
    }

    func testAppearanceModeSchemes() {
        // 跟随系统 = nil（不覆盖系统外观）；显式模式给对应 scheme
        XCTAssertNil(AppearanceMode.system.scheme)
        XCTAssertEqual(AppearanceMode.light.scheme, .light)
        XCTAssertEqual(AppearanceMode.dark.scheme, .dark)
    }

    func testAppearanceModeAppKitNames() {
        // AppKit 应用级外观：跟随系统 = nil（NSApp.appearance 清除覆盖），
        // 显式模式映射 aqua / darkAqua
        XCTAssertNil(AppearanceMode.system.appKitAppearanceName)
        XCTAssertEqual(AppearanceMode.light.appKitAppearanceName, .aqua)
        XCTAssertEqual(AppearanceMode.dark.appKitAppearanceName, .darkAqua)
    }

    func testAppearanceModeTitlesUnique() {
        let titles = AppearanceMode.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "三个模式标题不得重名")
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(AppearanceMode.allCases.count, 3)
    }

    func testAppearancePersistenceAcrossDefaults() {
        // 模拟 @AppStorage 读写路径：写 UserDefaults → 重读（重启后保持的等价验证）
        let key = AppearanceMode.storageKey
        defaults.set(AppearanceMode.dark.rawValue, forKey: key)
        let revived = AppearanceMode(rawValue: defaults.string(forKey: key) ?? "")
        XCTAssertEqual(revived, .dark, "UserDefaults 重读应还原深色偏好")

        defaults.set(AppearanceMode.light.rawValue, forKey: key)
        XCTAssertEqual(
            AppearanceMode(rawValue: defaults.string(forKey: key) ?? ""),
            .light
        )

        // 未写入（首启）→ 默认跟随系统
        defaults.removeObject(forKey: key)
        XCTAssertEqual(
            AppearanceMode(rawValue: defaults.string(forKey: key) ?? "") ?? .system,
            .system,
            "无存量值时默认跟随系统"
        )
    }
}

/// 思考提速第四批（2026-09-18，借鉴 opencode / OpenHands）：
/// 历史 reasoning 回传 / compaction 分块暂缓 / PRD 图表引用槽拼接。
final class ThinkingSpeedBatch4Tests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-speed4-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - 项 2：历史 reasoning 回传

    /// 门控：缺省 chatConfig 兜底即 deepseek（回传）；显式其他 provider 不回传。
    func testReplaysReasoningGateByProvider() {
        XCTAssertTrue(
            SessionStore.replaysReasoning(
                settings: LLMSettings(stages: [:], maxTokensPerRun: 1000)
            ),
            "缺省兜底 provider 是 deepseek，默认回传"
        )
        var stages: [LLMStage: StageModelConfig] = [:]
        stages[.classify] = StageModelConfig(provider: "zhipu", model: "glm-4.6")
        XCTAssertFalse(
            SessionStore.replaysReasoning(
                settings: LLMSettings(stages: stages, maxTokensPerRun: 1000)
            ),
            "非 deepseek 端点不回传（思考协议不同）"
        )
    }

    /// 线协议：携带思考的 assistant 消息输出 reasoning_content 字段；
    /// 不携带时字段整体缺席（encodeIfPresent，对不认该字段的端点零风险）；
    /// 旧存量 JSON（无该字段）解码兼容。
    func testRequestBodyCarriesReasoningContentOnlyWhenPresent() throws {
        let plain = LLMClient.RequestBody.message(
            from: ChatMessage(role: .assistant, content: "答")
        )
        let plainJSON = String(
            decoding: try JSONEncoder().encode(plain), as: UTF8.self
        )
        XCTAssertFalse(plainJSON.contains("reasoning_content"))

        let carried = LLMClient.RequestBody.message(
            from: ChatMessage(role: .assistant, content: "答", reasoningContent: "思考")
        )
        let carriedJSON = String(
            decoding: try JSONEncoder().encode(carried), as: UTF8.self
        )
        XCTAssertTrue(carriedJSON.contains("reasoning_content"))

        let revived = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"assistant","content":"答"}"#.utf8)
        )
        XCTAssertNil(revived.reasoningContent, "旧存量 JSON 无该字段 → nil")
    }

    /// 投影：replayReasoning 开启时 assistant 轮携带落盘思考原文（think.full），
    /// user 轮与无思考轮不携带；缺省关闭（其他调用点行为不变）。
    @MainActor
    func testProjectEntriesAttachesReasoningOnlyWhenEnabled() {
        let store = SessionStore()
        let think = ThinkData.from(reasoning: "第一行推敲\n第二行结论", duration: 3)
        XCTAssertNotNil(think)
        let entries = [
            store.makeEntry(role: .user, content: "问题"),
            store.makeEntry(role: .assistant, content: "回答一", think: think),
            store.makeEntry(role: .assistant, content: "回答二"),
        ]

        let with = HistoryProjection.projectEntries(entries, replayReasoning: true)
        XCTAssertEqual(with.count, 3)
        XCTAssertNil(with[0].reasoningContent, "user 轮不携带")
        XCTAssertEqual(with[1].reasoningContent, think?.full, "assistant 轮携带思考原文")
        XCTAssertNil(with[2].reasoningContent, "无思考的 assistant 轮不携带")

        let without = HistoryProjection.projectEntries(entries)
        XCTAssertTrue(without.allSatisfy { $0.reasoningContent == nil })
    }

    /// 收敛：只保留最后一条携带思考的消息，其余置空（回传量有界）；
    /// 全空时原样返回。
    func testKeepRecentReasoningRetainsOnlyLastCarrier() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "S"),
            ChatMessage(role: .assistant, content: "A1", reasoningContent: "想1"),
            ChatMessage(role: .user, content: "U"),
            ChatMessage(role: .assistant, content: "A2", reasoningContent: "想2"),
            ChatMessage(role: .assistant, content: "A3"),
        ]
        let kept = HistoryProjection.keepRecentReasoning(in: messages)
        XCTAssertNil(kept[1].reasoningContent, "更早轮思考置空（结论已外化进产物/摘要）")
        XCTAssertEqual(kept[3].reasoningContent, "想2", "最后一轮思考保留")
        XCTAssertEqual(kept[0].content, "S")

        let plain = [ChatMessage(role: .user, content: "U")]
        XCTAssertEqual(HistoryProjection.keepRecentReasoning(in: plain), plain)
    }

    /// 集成：deepseek 门控下 buildHistory 只回传最后一轮思考；zhipu 下全不回传。
    @MainActor
    func testBuildHistoryReplaysLastRoundReasoningOnly() async throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "速度4", version: "unversioned", sessionId: "s-replay")
        let think = ThinkData.from(reasoning: "推敲甲\n推敲乙", duration: 2)
        XCTAssertNotNil(think)
        try store.append(store.makeEntry(role: .user, content: "第一问"))
        try store.append(store.makeEntry(role: .assistant, content: "第一答", think: think))
        try store.append(store.makeEntry(role: .user, content: "第二问"))
        try store.append(store.makeEntry(role: .assistant, content: "第二答", think: think))
        XCTAssertEqual(store.entries.count, 4)

        var stages: [LLMStage: StageModelConfig] = [:]
        stages[.classify] = StageModelConfig(provider: "deepseek", model: "deepseek-flash")
        let origin = SessionStore.StreamOrigin(
            project: "速度4", version: "unversioned", sessionId: store.sessionId
        )

        let history = await store.buildHistory(
            origin: origin, systemPrompt: "SYS",
            settings: LLMSettings(stages: stages, maxTokensPerRun: 1000)
        )
        XCTAssertEqual(history.count, 5, "system + 4 条历史")
        XCTAssertEqual(history[0].content, "SYS")
        XCTAssertNil(history[2].reasoningContent, "只回传最后一轮")
        XCTAssertEqual(history[4].reasoningContent, think?.full)

        stages[.classify] = StageModelConfig(provider: "zhipu", model: "glm-4.6")
        let zhipuHistory = await store.buildHistory(
            origin: origin, systemPrompt: "SYS",
            settings: LLMSettings(stages: stages, maxTokensPerRun: 1000)
        )
        XCTAssertTrue(zhipuHistory.allSatisfy { $0.reasoningContent == nil })
    }

    // MARK: - 项 4：compaction 分块暂缓

    func testShouldDeferCompaction() {
        XCTAssertTrue(
            SessionStore.shouldDeferCompaction(
                droppedCount: 5, cachedCount: 3, newDroppedTokens: 100
            ),
            "有新增被丢轮且增量不足一块 → 暂缓"
        )
        XCTAssertFalse(
            SessionStore.shouldDeferCompaction(
                droppedCount: 3, cachedCount: 3, newDroppedTokens: 100
            ),
            "无新增被丢轮不暂缓（走缓存命中路径）"
        )
        XCTAssertFalse(
            SessionStore.shouldDeferCompaction(
                droppedCount: 30, cachedCount: 3,
                newDroppedTokens: SessionStore.compactionDeferralTokens
            ),
            "增量满一块必须滚动摘要（摊薄而非无限膨胀）"
        )
    }

    /// 垫头位置：system + 摘要 + 桥接（新被丢轮原文）+ 保留段，时间序不乱。
    func testHistoryWithSummaryBridgingPlacement() {
        let kept: [ChatMessage] = [
            ChatMessage(role: .system, content: "S"),
            ChatMessage(role: .user, content: "新问题"),
        ]
        let bridging = [ChatMessage(role: .user, content: "被丢的旧问")]
        let out = HistoryProjection.historyWithSummary(
            kept: kept, summary: "旧摘要", bridging: bridging
        )
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].content, "S")
        XCTAssertTrue(out[1].content.contains("旧摘要"))
        XCTAssertEqual(out[2], bridging[0], "桥接段垫在摘要之后、保留段之前")
        XCTAssertEqual(out[3].content, "新问题")
    }

    /// 集成：缓存边界小幅移动 → 旧摘要复用 + 新被丢轮原文垫头（暂缓路径），
    /// 不触发 LLM 摘要、压缩缓存计数不变。
    @MainActor
    func testBuildHistoryDefersCompactionWithBridging() async throws {
        try PMAgentStore.bootstrap()
        let store = SessionStore()
        store.open(project: "速度4", version: "unversioned", sessionId: "s-defer")
        try store.append(store.makeEntry(role: .user, content: "第一问"))
        try store.append(store.makeEntry(role: .assistant, content: "第一答"))
        try store.append(store.makeEntry(role: .user, content: "第二问"))
        try store.append(store.makeEntry(role: .assistant, content: "第二答"))
        store.historyTokenBudget = 1  // 全部轮次超预算（保留段仅剩 system）
        // 旧缓存边界 = 前两条被丢时的签名（count = 2）；现被丢 4 条 → 小幅移动
        store.compactions["s-defer"] = SessionStore.CompactionCache(
            summary: "旧摘要", boundary: "2|第一问|第一答", count: 2
        )
        let origin = SessionStore.StreamOrigin(
            project: "速度4", version: "unversioned", sessionId: "s-defer"
        )

        let history = await store.buildHistory(
            origin: origin, systemPrompt: "SYS",
            settings: LLMSettings(stages: [:], maxTokensPerRun: 1000)
        )
        XCTAssertEqual(history.count, 4, "system + 摘要 + 桥接 2 条")
        XCTAssertTrue(history[1].content.contains("旧摘要"), "旧摘要复用（不重算）")
        XCTAssertEqual(history[2].content, "第二问", "新被丢轮原文垫头")
        XCTAssertEqual(history[3].content, "第二答")
        XCTAssertEqual(
            store.compactions["s-defer"]?.count, 2,
            "暂缓路径不滚动摘要，压缩缓存计数不变"
        )
    }

    // MARK: - 项 3：PRD 图表引用槽拼接

    /// 围栏扫描 + 槽位解析：具名取第 1 张、#N 取第 N 张、未解析降级行内警示、
    /// 行内出现（非独占一行）不算槽位。
    func testMermaidBlocksAndStitchSlots() {
        let source = """
        前置说明
        ```mermaid
        graph TD
        A-->B
        ```
        中间
        ```mermaid
        flowchart LR
        C-->D
        ```
        尾部
        """
        XCTAssertEqual(
            ArtifactParser.mermaidBlocks(in: source),
            ["graph TD\nA-->B", "flowchart LR\nC-->D"]
        )
        let body = """
        ## 6.1 信息架构
        [[MERMAID:功能架构图]]
        ## 8.1 核心流程
        [[MERMAID:核心流程图#2]]
        [[MERMAID:业务流程图]]
        """
        let stitch = ArtifactParser.stitchMermaidSlots(in: body, sources: [
            "功能架构图": source,
            "核心流程图": source,
        ])
        XCTAssertTrue(stitch.text.contains("graph TD\nA-->B"), "具名槽取第 1 张")
        XCTAssertTrue(stitch.text.contains("flowchart LR\nC-->D"), "#2 取第 2 张")
        XCTAssertEqual(stitch.resolvedCount, 2)
        XCTAssertEqual(stitch.unresolvedSlots, ["[[MERMAID:业务流程图]]"])
        XCTAssertTrue(stitch.text.contains("图表引用未解析"), "未解析降级为行内警示，不静默")

        let inline = ArtifactParser.stitchMermaidSlots(
            in: "见 [[MERMAID:功能架构图]] 说明", sources: ["功能架构图": source]
        )
        XCTAssertEqual(inline.resolvedCount, 0, "行内出现不算槽位（须独占一行）")
        XCTAssertTrue(inline.text.contains("[[MERMAID:功能架构图]]"))
    }
}

/// 思考提速第五批（2026-09-18）：无改动不重排 + 正文反呓语。
final class ThinkingSpeedBatch5Tests: XCTestCase {
    /// 模式头三类意图：③无新修改点不重排（重复生成请求省整轮全量重排）；
    /// 无基底时维持简单模式头。
    func testPrdIterationModeHeaderCoversNoChangeCase() {
        let withBase = AppModel.prdIterationModeHeader(hasBase: true)
        XCTAssertTrue(withBase.contains("① 含对 PRD 的具体修改反馈"))
        XCTAssertTrue(withBase.contains("② 基底已落后"), "② 收窄为「基底落后」才重排")
        XCTAssertTrue(withBase.contains("③"), "③ 无新修改点不重排")
        XCTAssertTrue(withBase.contains("不输出 artifact 块"), "③ 不产产物块")

        let withoutBase = AppModel.prdIterationModeHeader(hasBase: false)
        XCTAssertTrue(withoutBase.contains("artifact:prd"))
        XCTAssertFalse(withoutBase.contains("不重排"), "无基底（首次生成）无③分支")
    }

    /// 正文反呓语硬约束（截图实证：模型在正文里自我叙述输出策略）。
    func testPrdPromptContainsBodyDisciplineRule() {
        let prompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "graph TD", coreFlows: "flowchart LR", prototypePages: ["首页"],
            analysisNotes: "", injection: ""
        )
        XCTAssertTrue(prompt.contains("正文纪律"), "缺反呓语硬约束")
        XCTAssertTrue(prompt.contains("输出策略的自我说明"))
        XCTAssertTrue(prompt.contains("按照输出协议"), "须点名「按协议复述」这一具体形态")
    }

    /// 记忆预算审计（2026-09-18）：风险注入加 800 字预算——超预算行边界截断、
    /// 标「其余 N 条」计数兜底章节完整性；预算内原样。
    func testOpenRisksInjectionBudgetTruncatesWithCount() {
        let long = String(repeating: "风", count: 60)
        let records = (0..<40).map { i in
            RiskRecord(
                version: "v1", stage: .prd, hypothesis: "假设\(i)：\(long)",
                plan: "方案\(i)", status: .open, originRef: "测试"
            )
        }
        let text = AppModel.openRisksInjection(records)
        XCTAssertLessThan(
            text.count, 1600,
            "注入体积须受 800 字预算约束（实测全量 40 条 ≈ 3200 字）"
        )
        XCTAssertTrue(text.contains("其余"), "截断须标略")
        XCTAssertTrue(text.contains("风险台账"), "截断须指向完整清单")
        XCTAssertTrue(text.contains("另有"), "计数标注兜底章节完整性")

        let small = [RiskRecord(
            version: "v1", stage: .prd, hypothesis: "短假设",
            plan: nil, status: .open, originRef: "测试"
        )]
        let smallText = AppModel.openRisksInjection(small)
        XCTAssertTrue(smallText.contains("短假设"))
        XCTAssertFalse(smallText.contains("其余"), "预算内不出现截断标注")
        XCTAssertTrue(smallText.contains("已登记风险"))
    }

    /// usage 归因字段（roundId/totalS/ttftS）：旧存量 JSON 解码 nil、新记录往返一致。
    func testUsageRecordAttributionFieldsCompat() throws {
        let old = try JSONDecoder().decode(
            UsageRecord.self,
            from: Data(
                #"{"ts":"2026-09-18T14:00:00+08:00","stage":"prd","model":"m","promptTokens":100,"completionTokens":50,"cacheHitTokens":0,"estimated":false}"#.utf8
            )
        )
        XCTAssertNil(old.roundId, "旧存量无归因字段 → nil")
        XCTAssertNil(old.totalS)
        XCTAssertNil(old.ttftS)

        let enriched = UsageRecord(
            ts: "t", stage: "prd", model: "m", promptTokens: 1, completionTokens: 2,
            estimated: false, roundId: "r1", totalS: 45.5, ttftS: 1.7
        )
        let revived = try JSONDecoder().decode(
            UsageRecord.self, from: JSONEncoder().encode(enriched)
        )
        XCTAssertEqual(revived.roundId, "r1")
        XCTAssertEqual(revived.totalS, 45.5)
        XCTAssertEqual(revived.ttftS, 1.7)
    }
}
