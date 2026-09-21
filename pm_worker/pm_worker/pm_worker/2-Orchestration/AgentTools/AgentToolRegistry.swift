//
//  AgentToolRegistry.swift
//  pm_worker
//
//  工具注册表：声明（definitions → 请求体 tools）与执行（execute）的单一入口。
//  未知工具名 / 参数解析失败一律返回错误文本（不计抛错），由模型自纠。
//

import Foundation

@MainActor
struct AgentToolRegistry {
    private var tools: [String: any AgentTool]

    init(tools: [any AgentTool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    /// 注册表是否为空（空 = 请求不携带 tools，省一次无谓参数）。
    var isEmpty: Bool { tools.isEmpty }

    var toolNames: [String] { tools.keys.sorted() }

    /// OpenAI 兼容 tools 数组（按名排序，声明顺序稳定）。
    func definitions() -> [ToolDefinition] {
        tools.values.sorted(by: { $0.name < $1.name }).map {
            ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
        }
    }

    /// 按名执行；错误一律转 ok=false 文本回流。
    func execute(name: String, argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        guard let tool = tools[name] else {
            return .failure(
                "未知工具「\(name)」。可用工具：\(toolNames.joined(separator: "、"))。"
            )
        }
        return await tool.execute(argumentsJSON: argumentsJSON, ctx: ctx)
    }
}

/// 工具参数解析的统一容错：argumentsJSON 解码失败返回 nil（调用方转错误文本）。
nonisolated func decodeToolArgs<Args: Decodable>(
    _ type: Args.Type, from argumentsJSON: String
) -> Args? {
    guard let data = argumentsJSON.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Args.self, from: data)
}
