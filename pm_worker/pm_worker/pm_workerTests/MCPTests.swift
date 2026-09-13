//
//  MCPTests.swift
//  pm_workerTests
//
//  MCP Server（Task 5.1）离线单测：
//  - sanitizeSegment / resolvedTarget：路径段校验与入参兜底
//  - 确认闸口：clarification.md / confirmed.json 缺失拦截、有则放行
//  - 任务生命周期：mcp_tasks pending → running → done 流转 + 产物落盘 + pipeline_runs upsert
//  - 重启 failover：残留 pending/running 判 failed
//  - LLM 失败路径：缺 API Key → 任务 failed 且 result 带人话指引
//  全离线：假 LLM 闭包注入（不发网络、不启 stdio）+ 临时目录（rootOverride）+ 临时 AppDatabase。
//

import XCTest
import GRDB
@testable import pm_worker

final class MCPTests: XCTestCase {
    var tempRoot: URL!
    var database: AppDatabase!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
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

    // MARK: - 测试辅助

    private func makeHandlers(
        llm: @escaping MCPToolHandlers.LLMInvoker
    ) -> MCPToolHandlers {
        MCPToolHandlers(database: database, llm: llm)
    }

    /// 默认工作区（默认/unversioned）写入相对路径产物。
    private func writeArtifact(_ text: String, rel: String) throws {
        try PMAgentStore.writeVerified(
            text,
            to: PMAgentStore.versionURL(project: "默认", version: "unversioned")
                .appendingPathComponent(rel)
        )
    }

    /// 模型结构三产物假回复（含合法 artifact 块）。
    private static let structureReply = """
    结构产物如下：

    ```artifact:architecture
    graph TD
        A[读书App] --> B[书架模块]
        A --> C[播放模块]
    ```

    ```artifact:core-flows
    flowchart TD
        S[打开App] --> L[浏览书架] --> P[播放书籍] --> E[退出]
    ```

    ```artifact:module-page-map
    | 模块 | 原型页面 | 页面说明 |
    |---|---|---|
    | 书架 | 书架页 | 浏览全部书目 |
    | 播放 | 播放页 | 播放与进度 |
    ```
    """

    /// 执行期状态快照盒（llm 假闭包里记录调用瞬间 mcp_tasks 的全表 status）。
    private actor StatusBox {
        private(set) var observed: [String] = []
        func record(_ value: String) { observed.append(value) }
    }

    // MARK: - 1. sanitizeSegment 路径段校验

    func testSanitizeSegment() {
        // 合法：中文 / 英文 / 语义化版本 / 前导空格
        XCTAssertEqual(MCPServerRunner.sanitizeSegment("默认项目"), "默认项目")
        XCTAssertEqual(MCPServerRunner.sanitizeSegment("my-project"), "my-project")
        XCTAssertEqual(MCPServerRunner.sanitizeSegment("v1.0"), "v1.0")
        XCTAssertEqual(MCPServerRunner.sanitizeSegment("  v2.1  "), "v2.1")
        // 拒绝：路径穿越 / 分隔符 / 隐藏目录 / 空 / 超长
        XCTAssertNil(MCPServerRunner.sanitizeSegment("../x"))
        XCTAssertNil(MCPServerRunner.sanitizeSegment("a/b"))
        XCTAssertNil(MCPServerRunner.sanitizeSegment("a\\b"))
        XCTAssertNil(MCPServerRunner.sanitizeSegment(".hidden"))
        XCTAssertNil(MCPServerRunner.sanitizeSegment("a..b"))
        XCTAssertNil(MCPServerRunner.sanitizeSegment(""))
        XCTAssertNil(MCPServerRunner.sanitizeSegment("   "))
        XCTAssertNil(MCPServerRunner.sanitizeSegment(String(repeating: "a", count: 61)))
        // 边界：恰好 60 通过
        XCTAssertEqual(
            MCPServerRunner.sanitizeSegment(String(repeating: "a", count: 60)),
            String(repeating: "a", count: 60)
        )
    }

    // MARK: - 2. 入参兜底

    func testResolvedTargetFallback() {
        // 缺省：project → 默认；version → unversioned
        let target = MCPServerRunner.resolvedTarget(project: nil, version: nil)
        XCTAssertEqual(target?.project, "默认")
        XCTAssertEqual(target?.version, "unversioned")

        // 显式传入保留
        let explicit = MCPServerRunner.resolvedTarget(project: "读书App", version: "v1.0")
        XCTAssertEqual(explicit?.project, "读书App")
        XCTAssertEqual(explicit?.version, "v1.0")

        // 非法段拒绝（任一段非法 → nil）
        XCTAssertNil(MCPServerRunner.resolvedTarget(project: "../etc", version: nil))
        XCTAssertNil(MCPServerRunner.resolvedTarget(project: nil, version: "a/b"))
    }

    // MARK: - 3. 确认闸口

    func testStructureGateRequiresClarification() async throws {
        let handlers = makeHandlers { _, _, _ in Self.structureReply }

        // 无 clarification.md → 报错并引导先澄清
        do {
            _ = try await handlers.submitGenerationTask(
                type: "generate_structure", project: nil, version: nil
            )
            XCTFail("缺 clarification.md 应抛闸口错误")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains("澄清"), "错误应引导先完成澄清：\(text)")
        }

        // 补齐要点表 → 过闸（返回 task_id）
        try writeArtifact("# 澄清要点表", rel: "01-requirements/clarification.md")
        let taskId = try await handlers.submitGenerationTask(
            type: "generate_structure", project: nil, version: nil
        )
        XCTAssertTrue(taskId.hasPrefix("task_"))
    }

    func testPrototypeAndPRDGatesRequireConfirmation() async throws {
        let handlers = makeHandlers { _, _, _ in "<html></html>" }

        // 无 02-structure/confirmed.json → generate_prototype 报错（含「确认」）
        do {
            _ = try await handlers.submitGenerationTask(
                type: "generate_prototype", project: "默认", version: "unversioned"
            )
            XCTFail("缺结构确认应抛闸口错误")
        } catch {
            XCTAssertTrue("\(error)".contains("确认"), "闸口错误须含「确认」：\(error)")
        }

        // 补结构确认 → 原型过闸；但 PRD 仍被原型确认闸口拦
        try writeArtifact("{}", rel: "02-structure/confirmed.json")
        let prototypeTaskId = try await handlers.submitGenerationTask(
            type: "generate_prototype", project: "默认", version: "unversioned"
        )
        XCTAssertTrue(prototypeTaskId.hasPrefix("task_"))

        do {
            _ = try await handlers.submitGenerationTask(
                type: "generate_prd", project: "默认", version: "unversioned"
            )
            XCTFail("缺原型确认应抛闸口错误")
        } catch {
            XCTAssertTrue("\(error)".contains("确认"), "闸口错误须含「确认」：\(error)")
        }

        // 补原型确认 → PRD 过闸
        try writeArtifact("{}", rel: "03-prototypes/confirmed.json")
        let prdTaskId = try await handlers.submitGenerationTask(
            type: "generate_prd", project: "默认", version: "unversioned"
        )
        XCTAssertTrue(prdTaskId.hasPrefix("task_"))
    }

    // MARK: - 4. 任务生命周期（pending → running → done + 落盘 + pipeline_runs）

    func testStructureTaskLifecycle() async throws {
        try writeArtifact("# 澄清要点表", rel: "01-requirements/clarification.md")

        let box = StatusBox()
        let db = try XCTUnwrap(database)
        let handlers = makeHandlers { _, _, _ in
            // 模型执行期间快照全表 status（此时应只有本任务，且处于 running）
            if let statuses = try? await db.dbQueue.read({ db in
                try String.fetchAll(db, sql: "SELECT status FROM mcp_tasks")
            }) {
                await box.record(statuses.joined(separator: ","))
            }
            return Self.structureReply
        }

        // 提交 → pending
        let taskId = try await handlers.submitGenerationTask(
            type: "generate_structure", project: nil, version: nil
        )
        let pending = try await handlers.taskStatus(taskId: taskId)
        XCTAssertEqual(pending.status, "pending")
        XCTAssertNil(pending.result)

        // 执行 → done（result 为产物路径数组）
        await handlers.runTask(taskId)
        let done = try await handlers.taskStatus(taskId: taskId)
        XCTAssertEqual(done.status, "done")
        XCTAssertTrue(done.result?.contains("02-structure/architecture.md") == true)
        XCTAssertTrue(done.result?.contains("02-structure/module-page-map.md") == true)

        // 模型执行期观察到 running（状态机在调用 LLM 前置位）
        let observed = await box.observed
        XCTAssertEqual(observed, ["running"])

        // 产物按 AppModel 结构阶段同款路径与文件名落盘
        let dir = PMAgentStore.versionURL(project: "默认", version: "unversioned")
        let fm = FileManager.default
        for rel in [
            "02-structure/architecture.md",
            "02-structure/core-flows.md",
            "02-structure/module-page-map.md",
        ] {
            XCTAssertTrue(
                fm.fileExists(atPath: dir.appendingPathComponent(rel).path),
                "产物未落盘：\(rel)"
            )
        }

        // pipeline_runs upsert（UI 可见 MCP 触发的运行）
        let run: (stage: String, status: String)? = try await database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT current_stage, status FROM pipeline_runs WHERE project_id = ? AND version = ?",
                arguments: ["默认", "unversioned"]
            ) else { return nil }
            let stage: String = row["current_stage"] ?? ""
            let status: String = row["status"] ?? ""
            return (stage, status)
        }
        XCTAssertEqual(run?.stage, "structure")
        XCTAssertEqual(run?.status, "done")
    }

    /// 原型任务执行：假 artifact:prototype HTML → 03-prototypes/prototype-v1.html。
    func testPrototypeTaskWritesHTML() async throws {
        try writeArtifact("{}", rel: "02-structure/confirmed.json")
        try writeArtifact("| 模块 | 页面 |\n|---|---|\n| A | 首页 |", rel: "02-structure/module-page-map.md")
        try writeArtifact("flowchart TD", rel: "02-structure/core-flows.md")

        let handlers = makeHandlers { _, _, _ in
            "```artifact:prototype\n<html><body>灰盒原型</body></html>\n```"
        }
        let taskId = try await handlers.submitGenerationTask(
            type: "generate_prototype", project: "默认", version: "unversioned"
        )
        await handlers.runTask(taskId)

        let done = try await handlers.taskStatus(taskId: taskId)
        XCTAssertEqual(done.status, "done")
        let url = PMAgentStore.versionURL(project: "默认", version: "unversioned")
            .appendingPathComponent("03-prototypes/prototype-v1.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// PRD 任务执行：假 artifact:prd → 04-prd/prd-v1.md（standard 档）。
    func testPRDTaskWritesDocument() async throws {
        try writeArtifact("{}", rel: "03-prototypes/confirmed.json")
        try writeArtifact("# 澄清要点表", rel: "01-requirements/clarification.md")

        let longBody = String(repeating: "功能需求与映射表一一对应。", count: 30)
        let handlers = makeHandlers { _, _, _ in
            "```artifact:prd\n# PRD（standard 档）\n\(longBody)\n```"
        }
        let taskId = try await handlers.submitGenerationTask(
            type: "generate_prd", project: "默认", version: "unversioned"
        )
        await handlers.runTask(taskId)

        let done = try await handlers.taskStatus(taskId: taskId)
        XCTAssertEqual(done.status, "done")
        XCTAssertEqual(done.result, "[\"04-prd/prd-v1.md\"]")
        let url = PMAgentStore.versionURL(project: "默认", version: "unversioned")
            .appendingPathComponent("04-prd/prd-v1.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// get_task：不存在的任务 → taskNotFound。
    func testGetTaskNotFound() async throws {
        let handlers = makeHandlers { _, _, _ in "" }
        do {
            _ = try await handlers.taskStatus(taskId: "task_missing")
            XCTFail("不存在的任务应抛错")
        } catch {
            // 对外文案走 LocalizedError.errorDescription（MCP 客户端可见）
            XCTAssertTrue(
                error.localizedDescription.contains("不存在"),
                "错误文案应含「不存在」：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - 5. 重启 failover

    func testRestartFailover() async throws {
        try await database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO mcp_tasks (id, type, payload, status, result, created_at)
                VALUES ('task_r1', 'generate_structure', '{}', 'running', NULL, '2026-01-01T00:00:00+08:00')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO mcp_tasks (id, type, payload, status, result, created_at)
                VALUES ('task_p1', 'generate_structure', '{}', 'pending', NULL, '2026-01-01T00:00:00+08:00')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO mcp_tasks (id, type, payload, status, result, created_at)
                VALUES ('task_d1', 'generate_structure', '{}', 'done', '[]', '2026-01-01T00:00:00+08:00')
                """
            )
        }

        let handlers = makeHandlers { _, _, _ in "" }
        await handlers.failoverStaleTasks()

        // running / pending → failed（result 带重启原因）
        let staleRunning = try await handlers.taskStatus(taskId: "task_r1")
        XCTAssertEqual(staleRunning.status, "failed")
        XCTAssertEqual(staleRunning.result, "{\"error\":\"server restarted\"}")
        let stalePending = try await handlers.taskStatus(taskId: "task_p1")
        XCTAssertEqual(stalePending.status, "failed")

        // 终态不受影响
        let untouched = try await handlers.taskStatus(taskId: "task_d1")
        XCTAssertEqual(untouched.status, "done")
    }

    // MARK: - 6. LLM 失败路径（缺 API Key）

    func testMissingAPIKeyFailsTaskWithGuidance() async throws {
        try writeArtifact("# 澄清要点表", rel: "01-requirements/clarification.md")
        let handlers = makeHandlers { _, _, _ in
            throw LLMClient.LLMError.missingAPIKey
        }

        let taskId = try await handlers.submitGenerationTask(
            type: "generate_structure", project: nil, version: nil
        )
        await handlers.runTask(taskId)

        let failed = try await handlers.taskStatus(taskId: taskId)
        XCTAssertEqual(failed.status, "failed")
        // result 带人话指引（App Settings 配 BYOK Key）
        XCTAssertTrue(failed.result?.contains("BYOK") == true, "指引应含 BYOK：\(failed.result ?? "")")
        XCTAssertTrue(failed.result?.contains("Settings") == true)

        // pipeline_runs 同步落 failed（UI 可见）
        let status: String? = try await database.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status FROM pipeline_runs WHERE project_id = ? AND version = ?",
                arguments: ["默认", "unversioned"]
            )?["status"]
        }
        XCTAssertEqual(status, "failed")
    }

    // MARK: - 附加：analyze_requirement 解析

    func testAnalyzeRequirementParsesTable() async throws {
        let fakeJSON = """
        {"target_user": "读书爱好者", "core_scenario": "通勤听书", "core_value": "碎片时间读透一本书", \
        "constraints": ["完全免费"], "open_questions": ["是否需要社区共读"]}
        """
        let handlers = makeHandlers { _, _, _ in fakeJSON }

        let markdown = try await handlers.analyzeRequirement(idea: "做一个读书 App")
        XCTAssertTrue(markdown.contains("# 澄清要点表"))
        XCTAssertTrue(markdown.contains("读书爱好者"))
        XCTAssertTrue(markdown.contains("完全免费"))

        // 空 idea → 参数错误
        do {
            _ = try await handlers.analyzeRequirement(idea: "   ")
            XCTFail("空 idea 应抛错")
        } catch {
            XCTAssertTrue("\(error)".contains("idea"))
        }
    }

    /// analyze_requirement 模型未返回合法 JSON → 报错（不落盘）。
    func testAnalyzeRequirementRejectsInvalidModelOutput() async throws {
        let handlers = makeHandlers { _, _, _ in "抱歉，我无法处理。" }
        do {
            _ = try await handlers.analyzeRequirement(idea: "做一个读书 App")
            XCTFail("非法模型输出应抛错")
        } catch {
            XCTAssertTrue("\(error)".contains("产物块") || "\(error)".contains("要点表"))
        }
    }

    // MARK: - 附加：Task 5.2 Claude Desktop 配置生成

    /// 配置 JSON 结构：mcpServers → pm-copilot → command / args（含 --mcp-server）。
    func testClaudeConfigJSONStructure() throws {
        let json = MCPServerRunner.claudeConfigJSON(
            executablePath: "/Applications/pm_worker.app/Contents/MacOS/pm_worker"
        )

        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let servers = try XCTUnwrap(object?["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[MCPServerRunner.serverName] as? [String: Any])
        XCTAssertEqual(
            server["command"] as? String,
            "/Applications/pm_worker.app/Contents/MacOS/pm_worker"
        )
        XCTAssertEqual(server["args"] as? [String], ["--mcp-server"])
    }

    /// 配置 JSON 对含空格 / 引号的路径正确转义（可直接粘贴到 claude_desktop_config.json）。
    func testClaudeConfigJSONEscapesPath() throws {
        let tricky = "/Users/tom/App Library/pm\"worker.app/pm_worker"
        let json = MCPServerRunner.claudeConfigJSON(executablePath: tricky)
        // 编码后应是合法 JSON 且 round-trip 还原原路径
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let servers = try XCTUnwrap(object?["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[MCPServerRunner.serverName] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, tricky)
    }
}
