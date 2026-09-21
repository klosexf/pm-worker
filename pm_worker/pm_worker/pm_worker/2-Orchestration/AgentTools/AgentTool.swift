//
//  AgentTool.swift
//  pm_worker
//
//  模型自主工具调用（Function Calling v1，PRD §11 V2 路线首项）：
//  模型只决定「调不调、调哪个、传什么参数」，执行权留在系统侧——
//  可解释可追溯（思考卡工具行 + 开发者检查器），闸口不变量由红线保证：
//  工具路径禁写 confirmed.json / skipped.json / stale.json 与正式产物。
//

import Foundation

/// 工具结果回灌 LLM 的单结果截断预算（防工具轮拉爆上下文；结果用不上全文时
/// 模型可再次调用收敛查询）。
nonisolated let agentToolResultBudget = 4000

/// 工具执行结果：forLLM 回灌对话（失败也转人话文本——模型自纠优于终止回合）、
/// forHuman 进思考卡工具行。
nonisolated struct AgentToolResult: Equatable {
    var ok: Bool
    /// 回灌模型的文本（调用方按 agentToolResultBudget 截断）。
    var forLLM: String
    /// 思考卡工具行展示文案（人话摘要）。
    var forHuman: String

    static func failure(_ message: String) -> AgentToolResult {
        AgentToolResult(ok: false, forLLM: message, forHuman: message)
    }
}

/// 工具执行上下文（AppModel 按发起会话组装；闭包注入 = 测试 mock 点与
/// 依赖倒置接缝——工具层不直接依赖 AppModel / Retriever 具体类型）。
struct AgentToolContext {
    var settings: LLMSettings
    var project: String
    var version: String
    var sessionId: String
    /// 版本是否已封板（封板 → propose_competitive_analysis 拒绝）。
    var isReleased: Bool
    /// 技能检索（scope 过滤在闭包内完成）：query → (技能 id, doc 路径) 列表。
    /// async：检索走 embedding + 余弦（AppModel 侧组装）。
    var skillSearch: (String) async -> [(id: String, docPath: String)]
    /// 发起竞品分析确认卡（复用既有 pendingBranchConfirmation 通道）。
    var submitAnalysis: (String) -> Void
    /// 记忆写入（save_memory）：kind + 正文 → 错误文案（nil = 成功）。
    /// kind 白名单（结论/经验）与假设态落库在 MemoryStore 收口；
    /// nil = 未接线（无头/测试链路），工具侧回流「暂不可用」。
    var memorySave: ((String, String) -> String?)? = nil
    /// 记忆检索（recall_memory）：query → 命中条目注入格式行。
    /// nil = 未接线，同 memorySave 口径。
    var memorySearch: ((String) -> [String])? = nil
}

/// 单个可调用工具。@MainActor：执行可能触碰 UI（确认卡）与 MainActor 状态。
@MainActor
protocol AgentTool {
    var name: String { get }
    var description: String { get }
    /// JSON Schema（OpenAI 兼容 function parameters）。
    var parameters: JSONValue { get }
    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult
}

/// 一次发送链路的工具运行时：注册表 + 上下文打包下传 SessionStore
///（nil = 工具未启用，streamReply 行为与旧版完全一致）。
struct AgentToolRuntime {
    var registry: AgentToolRegistry
    var context: AgentToolContext
}

/// 便捷构造：单字符串参数 schema（load_skill.skill_query / web_search.query 同构）。
nonisolated func agentToolStringProperty(_ description: String) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string(description),
            ])
        ]),
        "required": .strings(["query"]),
    ])
}
