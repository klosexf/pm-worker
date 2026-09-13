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

        // 17 个技能：六字段完整 + 反模式章节 + 正文 1500 字软上限
        // （skills-inventory §2 首批 14 + §2.6 v1.2 追加 3）
        let skillsDir = resources.appendingPathComponent("skills", isDirectory: true)
        let skillFiles = try FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        XCTAssertEqual(skillFiles.count, 17, "技能数应为 17（skills-inventory §2 + §2.6）")

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

        // clarification.md → structure
        try PMAgentStore.writeVerified(
            "要点表",
            to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent("01-requirements/clarification.md")
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

    func testConfirmGatesAndInvalidation() throws {
        try makeWorkspace()
        let engine = PipelineEngine(project: "M2项目", version: "v1.0", database: nil)

        // 闸口拦截：未确认结构不得生成原型（E17a）
        engine.advanceFromClarify()
        XCTAssertFalse(engine.canGeneratePrototype)

        // 手动补齐结构产物 + 确认 → 放行
        let dir = PMAgentStore.versionURL(project: "M2项目", version: "v1.0")
        try PMAgentStore.writeVerified(
            "# 图", to: dir.appendingPathComponent("02-structure/architecture.md")
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
        for file in ["architecture.md", "core-flows.md", "module-page-map.md"] {
            let content = try String(
                contentsOf: dir.appendingPathComponent(file), encoding: .utf8
            )
            XCTAssertTrue(content.contains("```mermaid") || file == "module-page-map.md")
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
        let url = try ArtifactParser.writePrototypeArtifact(
            blocks: blocks, project: "M2项目", version: "v1.0"
        )
        let saved = try XCTUnwrap(url)
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
                id: id, scope: .version, kind: .conclusion, content: content,
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

        // 空推理 → 无思考卡
        XCTAssertNil(ThinkData.from(reasoning: "  \n ", duration: 1))
    }

    // MARK: Mermaid 提取（E17：结构产物渲染源）

    func testMermaidExtractor() {
        let markdown = """
        # 功能架构图

        ```mermaid
        graph TD
          A --> B
        ```

        # 模块-页面映射表

        | 模块 | 页面 |
        |---|---|
        | 首页 | index |
        """
        let diagrams = MermaidExtractor.diagrams(in: markdown)
        XCTAssertEqual(diagrams.count, 1)
        XCTAssertEqual(diagrams[0].title, "功能架构图")
        XCTAssertTrue(diagrams[0].source.contains("graph TD"))
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
        XCTAssertNil(try store.append(a))
        XCTAssertNil(try store.append(b))
        XCTAssertEqual(store.risks.count, 2)
        XCTAssertEqual(store.activeRisks.count, 2)
        XCTAssertFalse(store.needsConvergence)

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

    // MARK: 软上限（超限不拒收，提示收敛）

    func testSoftLimit() throws {
        try makeWorkspace()
        let store = RiskStore(project: "风险项目", version: "v1.0")

        for index in 1...3 {
            let risk = makeRisk("假设\(index)", trigger: .decisionOverturned)
            XCTAssertNil(try store.append(risk), "第 \(index) 条不应提示收敛")
        }
        XCTAssertFalse(store.needsConvergence)
        XCTAssertEqual(store.activeRisks.count, 3)

        // 第 4 条：仍收下（不抛错），返回收敛建议
        let fourth = makeRisk("假设4", trigger: .decisionOverturned)
        let suggestion = try XCTUnwrap(try store.append(fourth), "第 4 条应返回收敛建议")
        XCTAssertFalse(suggestion.isEmpty)
        XCTAssertTrue(store.needsConvergence)
        XCTAssertEqual(store.activeRisks.count, 4, "软上限不拒收")

        // 证伪关闭一条后回到限内
        try store.closeAsFalsified(id: fourth.id)
        XCTAssertFalse(store.needsConvergence)
        XCTAssertEqual(store.activeRisks.count, 3)
        XCTAssertEqual(store.risks.first { $0.id == fourth.id }?.status, .closedFalsified)
    }

    // MARK: 封板终态

    func testReleaseSettlement() throws {
        try makeWorkspace()
        let store = RiskStore(project: "风险项目", version: "v1.0")
        let open1 = makeRisk("未触发一", trigger: .decisionOverturned)
        let open2 = makeRisk("未触发二", trigger: .prdStale, stage: .prd)
        let fired = makeRisk("已命中", trigger: .structureRegen, stage: .structure)
        try store.append(open1)
        try store.append(open2)
        try store.append(fired)
        _ = try store.settle(trigger: .structureRegen, note: "结构被推翻")
        XCTAssertEqual(store.risks.filter { $0.status == .open }.count, 2)

        try store.settleAllForRelease()
        XCTAssertEqual(store.risks.filter { $0.status == .closedUnfired }.count, 2)
        XCTAssertEqual(store.risks.first { $0.id == fired.id }?.status, .triggered, "triggered 封板不动")
        XCTAssertFalse(store.needsConvergence)

        // 重开 store（append-only 折叠）：终态保持
        let reloaded = RiskStore(project: "风险项目", version: "v1.0")
        XCTAssertEqual(reloaded.risks.count, 3)
        XCTAssertEqual(reloaded.risks.filter { $0.status == .closedUnfired }.count, 2)
        XCTAssertEqual(reloaded.risks.first { $0.id == fired.id }?.status, .triggered)
    }

    // MARK: 收敛动作（合并 / 降级）

    func testMergeAndDowngrade() throws {
        try makeWorkspace()
        let risksURL = PMAgentStore.jsonlURL(
            project: "风险项目", version: "v1.0", file: "risks.jsonl"
        )

        let store = RiskStore(project: "风险项目", version: "v1.0")
        let target = makeRisk("同源风险（目标）", trigger: .structureRegen, stage: .structure)
        let source = makeRisk("同源风险（来源）", trigger: .structureRegen, stage: .structure)
        let downgraded = makeRisk("降级候选", trigger: .prdStale, stage: .prd)
        try store.append(target)
        try store.append(source)
        try store.append(downgraded)

        // 合并：source → target
        try store.merge(into: target.id, from: source.id)
        let merged = try XCTUnwrap(store.risks.first { $0.id == source.id })
        XCTAssertEqual(merged.status, .merged)
        XCTAssertEqual(merged.resolution, "合并到 \(target.id)")
        XCTAssertNotNil(merged.closedAt)
        XCTAssertEqual(store.risks.first { $0.id == target.id }?.status, .open, "target 保留")

        // 降级为 open_question
        try store.downgradeToOpenQuestion(id: downgraded.id)
        let degraded = try XCTUnwrap(store.risks.first { $0.id == downgraded.id })
        XCTAssertEqual(degraded.status, .closedFalsified)
        XCTAssertEqual(degraded.resolution, "降级为 open_question：降级候选")

        // append-only：3 原始行 + 合并行 + 降级行 = 5 行
        XCTAssertEqual(PMAgentStore.readLines(RiskRecord.self, from: risksURL).count, 5)

        // 容错：不存在的 id 报错、自合并报错
        XCTAssertThrowsError(try store.closeAsFalsified(id: "r_不存在"))
        XCTAssertThrowsError(try store.merge(into: target.id, from: target.id))
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
            "01-requirements/clarification.md",
            "02-structure/confirmed.json",
            "03-prototypes/confirmed.json",
            "04-prd/prd-v1.md",
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

    // MARK: ④ 意图识别（回退 / 档位切换）

    func testPRDIntentHelpers() {
        XCTAssertEqual(AppModel.prdBacktrackTarget("回退到结构阶段"), .structure)
        XCTAssertEqual(AppModel.prdBacktrackTarget("帮我重新设计结构"), .structure)
        XCTAssertEqual(AppModel.prdBacktrackTarget("改一下原型"), .prototype)
        XCTAssertEqual(AppModel.prdBacktrackTarget("修改原型流程"), .prototype)
        XCTAssertNil(AppModel.prdBacktrackTarget("帮我完善 PRD 的验收用例"))

        XCTAssertEqual(AppModel.tierFromText("用 lean 档"), "lean")
        XCTAssertEqual(AppModel.tierFromText("切换到 Full"), "full")
        XCTAssertEqual(AppModel.tierFromText("标准档"), "standard")
        XCTAssertNil(AppModel.tierFromText("再补充一节数据指标"))
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
