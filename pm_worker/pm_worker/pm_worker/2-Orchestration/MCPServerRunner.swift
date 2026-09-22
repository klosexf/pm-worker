//
//  MCPServerRunner.swift
//  pm_worker
//
//  无头 MCP Server（M5 Task 5.1，design.md §7.1）：
//  Claude Desktop / Cursor 直接指向本 App 可执行文件，args 追加 `--mcp-server`
//  → 入口分流到本 runner，在 stdin/stdout 上跑 stdio JSON-RPC，不启 GUI。
//
//  6 工具（design.md §7.1）：
//    analyze_requirement（同步·要点表） / generate_structure / generate_prototype /
//    generate_prd（异步任务，回 task_id）/ review_doc（同步·六维评审）/ get_task。
//  长任务走 mcp_tasks 异步任务模式：提交即回 {task_id, status: submitted}，
//  后台 Task 执行并更新 mcp_tasks（pending → running → done/failed），
//  get_task(task_id) 轮询 {status, result}。
//  重启 failover：启动时把残留 pending/running 任务判 failed（result 带 cause）。
//
//  说明：MCP 路径 MVP 不注入记忆/检索上下文（ContextBuilder 仅 GUI 主线使用，
//  AgentPrompts 的 injection 参数恒传 ""）；MCP 触发的运行会 upsert pipeline_runs，
//  App UI 能看到。闸口事实源与 GUI 一致：澄清要点表 / confirmed.json。
//

import Foundation
import GRDB
import MCP

// MARK: - 入口 runner（transport 层）

/// 无头入口：bootstrap + 重启 failover + 6 工具注册 + stdio 挂起。
nonisolated enum MCPServerRunner {

    /// 服务名与版本（initialize 响应里的 serverInfo）。
    static let serverName = "pm-copilot"
    static let serverVersion = "1.0.0"

    /// 服务开关的 UserDefaults key（Task 5.2 状态页 Toggle ↔ 无头实例启动检查）。
    /// 未设置 = 允许；显式 false = 无头实例拉起即退出（客户端收到 EOF）。
    static let enabledKey = "mcpServerEnabled"

    /// 无头主流程。调用方（pm_workerEntry）负责把主线程常驻起来。
    static func run() async {
        // 0. 服务开关（GUI 状态页控制；关 = 拒绝外部客户端拉起，立即退出）
        if let raw = UserDefaults.standard.object(forKey: enabledKey),
           (raw as? Bool) == false {
            exit(0)
        }

        // 1. 存储 bootstrap + 索引库（mcp_tasks / pipeline_runs）+ 设置一次性加载
        //    （LLMSettings.load 放 handler 外，避免每次工具调用重读磁盘）。
        try? PMAgentStore.bootstrap()
        let database = try? AppDatabase()
        let settings = LLMSettings.load()
        let handlers = MCPToolHandlers(database: database) { stage, systemPrompt, userPrompt in
            try await LLMClient.complete(
                stage: stage,
                settings: settings,
                messages: systemPrompt.isEmpty
                    ? [ChatMessage(role: .user, content: userPrompt)]
                    : [
                        ChatMessage(role: .system, content: systemPrompt),
                        ChatMessage(role: .user, content: userPrompt),
                    ],
                maxTokens: LLMClient.artifactMaxTokens
            )
        }

        // 2. 重启 failover：上次进程残留的 pending/running 任务判 failed
        await handlers.failoverStaleTasks()

        // 3. 注册 6 工具 + 启动 stdio
        let server = Server(
            name: serverName,
            version: serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolDefinitions)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await dispatch(params: params, handlers: handlers)
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
        } catch {
            return  // stdio 不可用（无标准输入等）——直接退出进程
        }
        // 等消息循环结束（stdin EOF / 客户端断开时 readLoop 退出、stream finish）。
        // 主线程被 dispatchMain 常驻，这里须显式 exit 结束进程，防孤儿残留；
        // 执行中的后台任务由重启 failover 兜底（残留判 failed）。
        await server.waitUntilCompleted()
        exit(0)
    }

    // MARK: - 路径规范化校验

    /// project/version 段合法性：非空、不含 `/` `\`、不含 `..`、不以 `.` 开头、长度 ≤ 60。
    /// 不合法返回 nil（工具侧报「project/version 含非法字符」）。
    static func sanitizeSegment(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(".."),
              !trimmed.hasPrefix("."),
              trimmed.count <= 60
        else { return nil }
        return trimmed
    }

    /// 入参兜底 + 校验：project 缺省 →「默认」；version 缺省 → unversioned；
    /// 任一段非法 → nil。
    static func resolvedTarget(
        project: String?, version: String?
    ) -> (project: String, version: String)? {
        let rawProject = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackProject = rawProject.isEmpty ? PMAgentStore.defaultProjectName : rawProject
        let fallbackVersion = rawVersion.isEmpty ? "unversioned" : rawVersion
        guard let safeProject = sanitizeSegment(fallbackProject),
              let safeVersion = sanitizeSegment(fallbackVersion)
        else { return nil }
        return (safeProject, safeVersion)
    }

    // MARK: - Claude Desktop 配置生成（Task 5.2 状态页「复制配置」）

    /// 生成 Claude Desktop / Cursor 的 mcpServers 配置 JSON（pretty-printed）。
    /// executablePath 注入（生产传 Bundle.main.executableURL；测试传假路径）。
    static func claudeConfigJSON(executablePath: String) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "command": executablePath,
                    "args": ["--mcp-server"],
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 工具清单（tools/list）

    /// 字符串参数的 JSON Schema 片段。
    private static func stringProp(_ description: String) -> Value {
        .object(["type": "string", "description": .string(description)])
    }

    /// 6 工具定义（design.md §7.1）。
    static var toolDefinitions: [Tool] {
        [
            Tool(
                name: "analyze_requirement",
                description: "① 澄清：把一句话产品想法直接转成澄清要点表 Markdown"
                    + "（目标用户 / 核心场景 / 核心价值 / 约束 / 开放问题）。同步返回。",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object(["idea": stringProp("一句话产品想法")]),
                    "required": .array([.string("idea")]),
                ])
            ),
            Tool(
                name: "generate_structure",
                description: "② 结构：基于该版本已确认的澄清要点表生成结构三产物"
                    + "（功能架构图 / 核心流程图 / 模块-页面映射表），落盘 02-structure/。"
                    + "长任务，返回 task_id，用 get_task 轮询。",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "project": stringProp("项目名（缺省「默认」）"),
                        "version": stringProp("版本目录名（缺省 unversioned）"),
                    ]),
                ])
            ),
            Tool(
                name: "generate_prototype",
                description: "③ 原型：基于已确认结构（02-structure/confirmed.json）生成 HTML 原型，"
                    + "落盘 03-prototypes/（单端产品落 可点击原型.html；多端产品按端分块，"
                    + "如 prototype-mobile → 移动端原型.html；多方案对比按方案分块，"
                    + "如 prototype-plan-a → 原型-方案A.html）。长任务，返回 task_id。",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "project": stringProp("项目名（缺省「默认」）"),
                        "version": stringProp("版本目录名（缺省 unversioned）"),
                    ]),
                ])
            ),
            Tool(
                name: "generate_prd",
                description: "④ PRD：基于已确认原型（03-prototypes/confirmed.json）撰写 PRD"
                    + "（standard 档模板），落盘 04-prd/PRD文档.md。长任务，返回 task_id。",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "project": stringProp("项目名（缺省「默认」）"),
                        "version": stringProp("版本目录名（缺省 unversioned）"),
                    ]),
                ])
            ),
            Tool(
                name: "review_doc",
                description: "⑤ 评审：按六维评审清单（需求完整性 / 方案合理性 / 用户价值 / "
                    + "技术可行性 / 文档质量 / 原型一致性）对文档打分，同步返回评审 Markdown。",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object(["doc": stringProp("被评文档全文（Markdown）")]),
                    "required": .array([.string("doc")]),
                ])
            ),
            Tool(
                name: "get_task",
                description: "查询异步任务状态：{status, result}。"
                    + "status ∈ pending | running | done | failed；done 时 result 为产物路径数组。",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object(["task_id": stringProp("任务 id（生成类工具返回）")]),
                    "required": .array([.string("task_id")]),
                ])
            ),
        ]
    }

    // MARK: - 工具调用路由（transport 层只做参数解包 → 调 handler → 包装结果）

    private static func dispatch(
        params: CallTool.Parameters,
        handlers: MCPToolHandlers
    ) async throws -> CallTool.Result {
        func arg(_ key: String) -> String? {
            guard let value = params.arguments?[key]?.stringValue else { return nil }
            return value
        }

        switch params.name {
        case "analyze_requirement":
            let markdown = try await handlers.analyzeRequirement(idea: arg("idea") ?? "")
            return CallTool.Result(content: [
                .text(text: MCPToolHandlers.encodeJSONObject(["clarification": markdown]), annotations: nil, _meta: nil)
            ])

        case "generate_structure", "generate_prototype", "generate_prd":
            let taskId = try await handlers.submitGenerationTask(
                type: params.name, project: arg("project"), version: arg("version")
            )
            // 后台执行长任务（不阻塞工具响应；任务内部自管 pending → running → done/failed）
            Task { await handlers.runTask(taskId) }
            return CallTool.Result(content: [
                .text(text: MCPToolHandlers.encodeJSONObject(["task_id": taskId, "status": "submitted"]), annotations: nil, _meta: nil)
            ])

        case "review_doc":
            let review = try await handlers.reviewDoc(doc: arg("doc") ?? "")
            return CallTool.Result(content: [
                .text(text: MCPToolHandlers.encodeJSONObject(["review": review]), annotations: nil, _meta: nil)
            ])

        case "get_task":
            let (status, result) = try await handlers.taskStatus(taskId: arg("task_id") ?? "")
            var object: [String: String] = ["status": status]
            if let result { object["result"] = result }
            return CallTool.Result(content: [
                .text(text: MCPToolHandlers.encodeJSONObject(object), annotations: nil, _meta: nil)
            ])

        default:
            throw MCPError.methodNotFound("未知工具：\(params.name)")
        }
    }
}

// MARK: - 工具错误（闸口 / 参数 / 任务）

/// MCP 工具层错误：transport 抛给 SDK 转 protocol error（isError 响应）。
nonisolated enum MCPToolError: LocalizedError {
    /// project/version 段含非法字符。
    case invalidSegment(String)
    /// 必填参数为空。
    case emptyInput(String)
    /// 确认闸口未过（带引导文案）。
    case gate(String)
    /// 任务不存在。
    case taskNotFound(String)
    /// 模型回复未包含合法产物块。
    case artifactIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .invalidSegment(let segment):
            "project/version 含非法字符：「\(segment)」——禁 / \\ .. 与前导点，长度 ≤ 60"
        case .emptyInput(let field):
            "参数 \(field) 不能为空"
        case .gate(let guidance):
            "🔒 确认闸口：\(guidance)"
        case .taskNotFound(let taskId):
            "任务不存在：\(taskId)"
        case .artifactIncomplete(let detail):
            "模型回复未包含合法产物块：\(detail)"
        }
    }
}

// MARK: - 工具逻辑（可单测：database / LLM 均注入）

/// 全部 6 工具的业务逻辑。transport 层（MCPServerRunner.dispatch）只做参数解包
/// 与结果包装；单测直接实例化本类型（离线：注入假 LLM 闭包 + 临时 AppDatabase）。
nonisolated struct MCPToolHandlers {

    /// LLM 执行依赖（生产：LLMClient.complete；测试：注入假实现）。
    /// 参数：阶段（取该阶段 BYOK 配置）、system prompt、user prompt。
    typealias LLMInvoker = @Sendable (
        _ stage: LLMStage, _ systemPrompt: String, _ userPrompt: String
    ) async throws -> String

    /// 索引库（mcp_tasks / pipeline_runs；nil = 无索引环境，任务降级报错）。
    let database: AppDatabase?
    /// 注入的 LLM 调用。
    let llm: LLMInvoker

    init(database: AppDatabase?, llm: @escaping LLMInvoker) {
        self.database = database
        self.llm = llm
    }

    // MARK: - JSON 编码（工具返回 / result 字段统一走这里，sortedKeys 稳定输出）

    /// 字典 → 紧凑 JSON 字符串。
    nonisolated static func encodeJSONObject(_ object: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 字符串数组 → 紧凑 JSON 字符串（产物路径数组）。
    nonisolated static func encodePaths(_ paths: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(paths) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 失败任务 result：缺 Key 给人话指引，其余带错误描述。
    nonisolated static func failureResult(_ error: Error) -> String {
        let message: String
        if case LLMClient.LLMError.missingAPIKey = error {
            message = "未配置 API Key——请在 pm_worker App 的 Settings（⌘,）中配置 BYOK Key 后重试"
        } else {
            message = "任务失败：\(error.localizedDescription)"
        }
        return encodeJSONObject(["error": message])
    }

    // MARK: - 同步工具

    /// analyze_requirement：一句话想法 → 澄清要点表 Markdown。
    /// 实现：AgentPrompts.clarificationTable one-shot（stage .clarify）+ LenientJSON 解析。
    func analyzeRequirement(idea: String) async throws -> String {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPToolError.emptyInput("idea") }
        let raw = try await llm(
            .clarify,
            "",
            AgentPrompts.clarificationTable(transcript: "用户想法：\(trimmed)")
        )
        guard let table: ClarificationTable = LenientJSON.decode(
            ClarificationTable.self, from: raw
        ) else {
            throw MCPToolError.artifactIncomplete("模型未返回合法的要点表 JSON，请稍后重试")
        }
        return table.markdown
    }

    /// review_doc：六维评审 Markdown。
    /// rubric 从 Bundle 读 templates/prd-review-rubric.md（同步组打平双路径回退，
    /// 与 AgentPrompts.prdTemplate 同模式）；评审意见落盘 07-reports/（失败不阻塞）。
    func reviewDoc(doc: String) async throws -> String {
        let trimmed = doc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPToolError.emptyInput("doc") }
        let system = """
        角色：独立毒舌评审官（六维打分）。
        按以下评审清单对文档打分：六维各 0-10 分 + 总评 + 扣分点清单
        （维度 / 未通过条目 / 理由 / 修改建议），输出 Markdown。
        每个扣分点必须给理由与修改建议，禁「感觉不好」式评价；
        数字无来源（非用户提供且未标「实施期建立基线 / 待定」）按红线零容忍处理。

        ## 评审清单
        \(Self.loadReviewRubric())
        """
        let review = try await llm(
            .review, system, "请评审以下文档：\n\n\(trimmed)"
        )
        // 落盘不阻塞：默认项目 / unversioned 的 07-reports/（既有目录习惯：
        // PMAgentStore 版本目录是 07-reports 而非 06-reports）。
        let stamp = ISO8601.timestamp().replacingOccurrences(of: ":", with: "")
        try? PMAgentStore.writeVerified(
            review,
            to: PMAgentStore.versionURL(
                project: PMAgentStore.defaultProjectName, version: "unversioned"
            )
            .appendingPathComponent("07-reports/review-\(stamp).md")
        )
        return review
    }

    /// Bundle 评审清单加载（templates/prd-review-rubric.md，打平双路径回退）。
    nonisolated static func loadReviewRubric() -> String {
        for subdirectory in ["templates", nil] {
            if let url = Bundle.main.url(
                forResource: "prd-review-rubric", withExtension: "md",
                subdirectory: subdirectory
            ), let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return "（评审清单缺失：按六维通用标准评审——需求完整性 / 方案合理性 / 用户价值 / "
            + "技术可行性 / 文档质量 / 原型一致性，各 0-10 分）"
    }

    // MARK: - 异步任务提交（闸口校验 + mcp_tasks 落 pending 行）

    /// 生成类工具提交入口：参数兜底校验 → 闸口检查 → 落 pending 行 → 返回 task_id。
    /// 后台执行由 runTask(taskId) 驱动（MCPServerRunner spawn Task / 测试直接 await）。
    func submitGenerationTask(
        type: String, project: String?, version: String?
    ) async throws -> String {
        guard let target = MCPServerRunner.resolvedTarget(
            project: project, version: version
        ) else {
            throw MCPToolError.invalidSegment(project ?? version ?? "")
        }
        // 闸口检查（纯函数，磁盘事实源；口径与 App 内 E15/E17 一致）
        let dir = PMAgentStore.versionURL(project: target.project, version: target.version)
        switch type {
        case "generate_structure":
            guard Self.gatePassed(dir: dir, rel: ArtifactPath.clarification) else {
                throw MCPToolError.gate(
                    "该版本尚无澄清要点表（\(ArtifactPath.clarification) 缺失）——"
                        + "请先在 App 里完成①澄清阶段，或先用 analyze_requirement 生成要点表。"
                )
            }
        case "generate_prototype":
            // 闸口闭环 = 确认 ∨ 跳过（2026-09-17 路径选择，口径与 PipelineEngine 一致）
            guard Self.gatePassed(dir: dir, rel: "02-structure/confirmed.json")
                || Self.gatePassed(dir: dir, rel: "02-structure/skipped.json") else {
                throw MCPToolError.gate(
                    "结构产物尚未确认（02-structure/confirmed.json 缺失）——"
                        + "请先在 App 里完成②结构阶段并确认（或按路径选择跳过），再生成原型。"
                )
            }
        case "generate_prd":
            guard Self.gatePassed(dir: dir, rel: "03-prototypes/confirmed.json")
                || Self.gatePassed(dir: dir, rel: "03-prototypes/skipped.json") else {
                throw MCPToolError.gate(
                    "原型产物尚未确认（03-prototypes/confirmed.json 缺失）——"
                        + "请先在 App 里完成③原型阶段并确认（或按路径选择跳过），再撰写 PRD。"
                )
            }
        default:
            throw MCPToolError.artifactIncomplete("未知任务类型：\(type)")
        }
        let payload = Self.encodeJSONObject([
            "project": target.project, "version": target.version,
        ])
        return try await submitTask(type: type, payload: payload)
    }

    /// 闸口检查（纯函数，便于单测）：目录下相对路径文件是否存在。
    nonisolated static func gatePassed(dir: URL, rel: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path)
    }

    /// mcp_tasks 落 pending 行，返回 task_id。
    @discardableResult
    func submitTask(type: String, payload: String) async throws -> String {
        let taskId = "task_\(UUID().uuidString)"
        guard let database else {
            throw MCPToolError.taskNotFound("索引库不可用，无法跟踪异步任务")
        }
        try await database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO mcp_tasks (id, type, payload, status, result, created_at)
                VALUES (?, ?, ?, 'pending', NULL, ?)
                """,
                arguments: [taskId, type, payload, ISO8601.timestamp()]
            )
        }
        return taskId
    }

    // MARK: - 任务执行（后台驱动：pending → running → done / failed）

    /// 任务负载（mcp_tasks.payload 的 JSON 结构）。
    fileprivate struct TaskPayload: Decodable {
        var project: String
        var version: String
    }

    /// 读任务行并分发执行（status 流转 + 产物落盘 + pipeline_runs upsert）。
    func runTask(_ taskId: String) async {
        guard let database else { return }
        // Row 非 Sendable：异步读闭包内投影成值元组再带出
        guard let info: (type: String, project: String, version: String) =
            try? await database.dbQueue.read({ db in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT type, payload FROM mcp_tasks WHERE id = ?",
                    arguments: [taskId]
                ), let payloadText: String = row["payload"],
                    let payload = try? JSONDecoder().decode(
                        TaskPayload.self, from: Data(payloadText.utf8)
                    )
                else { return nil }
                let type: String = row["type"] ?? ""
                return (type: type, project: payload.project, version: payload.version)
            })
        else { return }

        await updateTask(id: taskId, status: "running", result: nil)
        do {
            let paths: [String]
            switch info.type {
            case "generate_structure":
                paths = try await executeStructure(project: info.project, version: info.version)
            case "generate_prototype":
                paths = try await executePrototype(project: info.project, version: info.version)
            case "generate_prd":
                paths = try await executePRD(project: info.project, version: info.version)
            default:
                throw MCPToolError.artifactIncomplete("未知任务类型：\(info.type)")
            }
            await updateTask(id: taskId, status: "done", result: Self.encodePaths(paths))
        } catch {
            await updateTask(id: taskId, status: "failed", result: Self.failureResult(error))
            await upsertPipelineRun(
                project: info.project, version: info.version,
                stage: stageKey(info.type), status: "failed"
            )
        }
    }

    /// 任务类型 → pipeline_runs.current_stage。
    nonisolated private func stageKey(_ type: String) -> String {
        switch type {
        case "generate_structure": "structure"
        case "generate_prototype": "prototype"
        case "generate_prd": "prd"
        default: "clarify"
        }
    }

    /// ② 结构执行：照 AppModel 结构阶段——structure prompt one-shot →
    /// 解析 artifact 块 → 三产物落盘 02-structure/（ArtifactParser 既有路径与文件名）。
    private func executeStructure(project: String, version: String) async throws -> [String] {
        try PMAgentStore.ensureWorkspace(project: project, version: version)
        await upsertPipelineRun(
            project: project, version: version, stage: "structure", status: "running"
        )
        // 闸口复查（提交与执行之间文件可能被删）
        guard let clarification = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.clarification
        ) else {
            throw MCPToolError.gate(
                "该版本尚无澄清要点表（\(ArtifactPath.clarification) 缺失）——"
                    + "请先在 App 里完成①澄清阶段，或先用 analyze_requirement 生成要点表。"
            )
        }
        let reply = try await llm(
            .structure,
            AgentPrompts.structure(clarification: clarification, injection: ""),
            "请基于澄清要点表生成结构产物（功能架构图、核心流程图、模块-页面映射表三项必出）。"
        )
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        guard ArtifactParser.structureArtifactsComplete(blocks) else {
            throw MCPToolError.artifactIncomplete(
                "结构产物不全（architecture / core-flows / module-page-map 三项必出）"
            )
        }
        try ArtifactParser.writeStructureArtifacts(blocks: blocks, project: project, version: version)
        await upsertPipelineRun(
            project: project, version: version, stage: "structure", status: "done"
        )
        return [
            ArtifactPath.architecture,
            ArtifactPath.coreFlows,
            ArtifactPath.modulePageMap,
        ]
    }

    /// ③ 原型执行：照 AppModel 原型阶段——读已确认结构产物 → prototype prompt →
    /// HTML 落盘 03-prototypes/可点击原型.html。
    private func executePrototype(project: String, version: String) async throws -> [String] {
        try PMAgentStore.ensureWorkspace(project: project, version: version)
        await upsertPipelineRun(
            project: project, version: version, stage: "prototype", status: "running"
        )
        // 闸口复查
        guard Self.gatePassed(
            dir: PMAgentStore.versionURL(project: project, version: version),
            rel: "02-structure/confirmed.json"
        ) else {
            throw MCPToolError.gate(
                "结构产物尚未确认（02-structure/confirmed.json 缺失）——"
                    + "请先在 App 里完成②结构阶段并确认，再生成原型。"
            )
        }
        let map = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.modulePageMap
        ) ?? "（缺失）"
        let flows = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.coreFlows
        ) ?? "（缺失）"
        let reply = try await llm(
            .prototype,
            AgentPrompts.prototype(modulePageMap: map, coreFlows: flows, injection: ""),
            "请基于模块-页面映射表生成 HTML 原型（P0 页面 3-5 个，页面跳转按核心流程图连通；"
                + "多端产品按端分块输出 artifact:prototype-<端名> 块）。"
        )
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        guard let prototype = try ArtifactParser.writePrototypeArtifact(
            blocks: blocks, project: project, version: version
        ) else {
            throw MCPToolError.artifactIncomplete(
                "模型回复未包含合法的 artifact:prototype（或 prototype-mobile / prototype-desktop 等"
                    + "分端块）HTML 块"
            )
        }
        await upsertPipelineRun(
            project: project, version: version, stage: "prototype", status: "done"
        )
        return prototype.slots.map(\.relPath)
    }

    /// ④ PRD 执行：照 AppModel PRD 阶段（三档模板默认 standard）——
    /// 读上游已确认产物 → prd prompt → 落盘 04-prd/PRD文档.md。
    private func executePRD(project: String, version: String) async throws -> [String] {
        try PMAgentStore.ensureWorkspace(project: project, version: version)
        await upsertPipelineRun(
            project: project, version: version, stage: "prd", status: "running"
        )
        // 闸口复查
        guard Self.gatePassed(
            dir: PMAgentStore.versionURL(project: project, version: version),
            rel: "03-prototypes/confirmed.json"
        ) else {
            throw MCPToolError.gate(
                "原型产物尚未确认（03-prototypes/confirmed.json 缺失）——"
                    + "请先在 App 里完成③原型阶段并确认，再撰写 PRD。"
            )
        }
        let clarification = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.clarification
        ) ?? "（缺失）"
        let map = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.modulePageMap
        ) ?? "（缺失）"
        let architecture = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.architecture
        ) ?? ""
        let coreFlows = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.coreFlows
        ) ?? ""
        let analysis = Self.readArtifact(
            project: project, version: version, rel: ArtifactPath.competitiveAnalysis
        ) ?? ""
        let rows = await AppModel.mapRows(in: map)
        let reply = try await llm(
            .prd,
            AgentPrompts.prd(
                tier: "standard",
                clarification: clarification,
                modulePageMap: map,
                architecture: architecture,
                coreFlows: coreFlows,
                prototypePages: rows.pages,
                analysisNotes: analysis,
                injection: ""
            ),
            "请按 standard 档模板撰写 PRD（双重基准：功能需求与模块-页面映射表及原型页面一一对应）。"
        )
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        guard try ArtifactParser.writePRDArtifact(
            blocks: blocks, tier: "standard", project: project, version: version
        ) != nil else {
            throw MCPToolError.artifactIncomplete(
                "模型回复未包含合法的 artifact:prd 块（正文需 > 200 字符）"
            )
        }
        // 指标口径卡与 App 侧同轮落盘（无块即 no-op，PRD 可无量化指标）
        ArtifactParser.writeMetricSpecs(blocks: blocks, project: project, version: version)
        await upsertPipelineRun(
            project: project, version: version, stage: "prd", status: "done"
        )
        var result = [ArtifactPath.prd]
        if FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(ArtifactPath.metricSpecs).path
        ) {
            result.append(ArtifactPath.metricSpecs)
        }
        return result
    }

    // MARK: - get_task / 状态更新 / failover

    /// get_task：读 mcp_tasks 行（不存在抛 taskNotFound）。
    func taskStatus(taskId: String) async throws -> (status: String, result: String?) {
        guard !taskId.isEmpty else { throw MCPToolError.emptyInput("task_id") }
        guard let database else { throw MCPToolError.taskNotFound(taskId) }
        // Row 非 Sendable：异步读闭包内投影成值元组再带出
        guard let row: (status: String, result: String?) =
            try? await database.dbQueue.read({ db in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT status, result FROM mcp_tasks WHERE id = ?",
                    arguments: [taskId]
                ) else { return nil }
                let status: String = row["status"] ?? ""
                let result: String? = row["result"]
                return (status: status, result: result)
            })
        else { throw MCPToolError.taskNotFound(taskId) }
        return row
    }

    /// 更新任务状态（失败静默——状态机尽力而为，事实以最终一行为准）。
    func updateTask(id: String, status: String, result: String?) async {
        guard let database else { return }
        try? await database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE mcp_tasks SET status = ?, result = ? WHERE id = ?",
                arguments: [status, result, id]
            )
        }
    }

    /// 重启 failover：残留 pending/running 任务判 failed（result 带 cause）。
    func failoverStaleTasks() async {
        guard let database else { return }
        try? await database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE mcp_tasks
                SET status = 'failed', result = ?
                WHERE status IN ('pending', 'running')
                """,
                arguments: [Self.encodeJSONObject(["error": "server restarted"])]
            )
        }
    }

    // MARK: - pipeline_runs upsert（MCP 触发的运行对 UI 可见）

    /// 按 (project, version) upsert：有行则只动 current_stage / status / updated_at
    /// （保留确认闸口位与轮次计数——INSERT OR REPLACE 全字段重建会清掉它们，
    /// 故采用同事务内「查最新行 → UPDATE，否则 INSERT」的等价语义）。
    func upsertPipelineRun(
        project: String, version: String, stage: String, status: String
    ) async {
        guard let database else { return }
        try? await database.dbQueue.write { db in
            if let existing: String = try Row.fetchOne(
                db,
                sql: """
                SELECT id FROM pipeline_runs
                WHERE project_id = ? AND version = ?
                ORDER BY updated_at DESC LIMIT 1
                """,
                arguments: [project, version]
            )?["id"] {
                try db.execute(
                    sql: """
                    UPDATE pipeline_runs
                    SET current_stage = ?, status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [stage, status, ISO8601.timestamp(), existing]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO pipeline_runs (
                        id, project_id, version, current_stage, structure_confirmed,
                        prototype_confirmed, status, self_review_fixes, radar_risk_hits,
                        clarify_rounds, error, updated_at
                    ) VALUES (?, ?, ?, ?, 0, 0, ?, 0, 0, 0, NULL, ?)
                    """,
                    arguments: [
                        IDGenerator.next("run"), project, version, stage,
                        status, ISO8601.timestamp(),
                    ]
                )
            }
        }
    }

    // MARK: - 产物读取（与 AppModel.readArtifact 同拼法）

    nonisolated private static func readArtifact(
        project: String, version: String, rel: String
    ) -> String? {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(rel)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
