//
//  WebSearchTool.swift
//  pm_worker
//
//  web_search：联网搜索（Tavily 兼容端点，与竞品分析分支共用配置）。
//  只读；Key/endpoint 未配置时返回人话提示让模型转告用户并继续（不抛错、不阻塞）。
//

import Foundation

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let description =
        "联网搜索，返回带链接的结果列表（标题 / 链接 / 摘要）。需要外部事实、"
        + "竞品公开信息或最新资料时调用；回答中引用搜索到的事实时必须附出处链接。"

    var parameters: JSONValue {
        agentToolStringProperty("搜索查询词（具体、含关键实体）")
    }

    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        struct Args: Codable {
            var query: String?
        }
        let query = (decodeToolArgs(Args.self, from: argumentsJSON)?.query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("参数缺失：请提供 query（搜索查询词）。")
        }
        let endpoint = ctx.settings.searchEndpoint
        guard !endpoint.isEmpty else {
            return AgentToolResult(
                ok: false,
                forLLM: "搜索源未配置。请直接告知用户「需要在设置（⌘,）中配置搜索源后才能联网搜索」，然后基于已有知识继续回答。",
                forHuman: "搜索源未配置"
            )
        }
        let key = KeychainStore.read("byok.search")
        guard case .found(let apiKey) = key, !apiKey.isEmpty else {
            return AgentToolResult(
                ok: false,
                forLLM: "搜索 API Key 未配置。请直接告知用户「需要在设置（⌘,）中填写搜索 API Key 后才能联网搜索」，然后基于已有知识继续回答。",
                forHuman: "搜索 Key 未配置"
            )
        }
        do {
            let results = try await WebTool.search(query: query, endpoint: endpoint, apiKey: apiKey)
            guard !results.isEmpty else {
                return AgentToolResult(
                    ok: true,
                    forLLM: "搜索「\(query)」无结果。可换关键词重试一次，或基于已有知识回答。",
                    forHuman: "搜索「\(query)」无结果"
                )
            }
            var lines: [String] = []
            for (i, r) in results.prefix(8).enumerated() {
                lines.append("\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)")
            }
            var text = lines.joined(separator: "\n")
            if text.count > agentToolResultBudget {
                text = String(text.prefix(agentToolResultBudget)) + "\n…（结果过长已截断）"
            }
            return AgentToolResult(
                ok: true,
                forLLM: text,
                forHuman: "搜索「\(query)」×\(results.count)"
            )
        } catch {
            return AgentToolResult(
                ok: false,
                forLLM: "搜索失败：\(error.localizedDescription)。可基于已有知识继续回答。",
                forHuman: "搜索失败"
            )
        }
    }
}
