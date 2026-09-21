//
//  ProposeAnalysisTool.swift
//  pm_worker
//
//  propose_competitive_analysis：模型发起竞品分析——只提交既有确认卡通道
//  （用户裁决后才真正执行，不绕闸），提交即返回，工具循环不被用户裁决阻塞。
//  封板版本直接拒绝。
//

import Foundation

struct ProposeAnalysisTool: AgentTool {
    let name = "propose_competitive_analysis"
    let description =
        "发起竞品分析分支（多轮联网调研，产出带出处的竞品分析包并归档到当前项目）。"
        + "调用后系统会向用户弹出确认卡，用户同意后才执行；适合用户表达调研意图"
        + "（「看看市面上有没有类似的」「帮我调研下竞品」）时主动提议。"
        + "用户已明确拒绝过时不要重复发起。"

    var parameters: JSONValue {
        agentToolStringProperty("竞品分析主题（要调研的产品或方向，如：Notion 类笔记工具）")
    }

    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        struct Args: Codable {
            var query: String?
        }
        let topic = (decodeToolArgs(Args.self, from: argumentsJSON)?.query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            return .failure("参数缺失：请提供 query（竞品分析主题）。")
        }
        guard !ctx.isReleased else {
            return .failure("当前版本已封板（只读），无法发起竞品分析。请直接告知用户。")
        }
        ctx.submitAnalysis(topic)
        return AgentToolResult(
            ok: true,
            forLLM: "已向用户发起竞品分析确认（主题：\(topic)）。请提示用户查看输入框上方的确认卡并做出选择；"
                + "在用户确认前不要重复发起，也不要自行展开分析。",
            forHuman: "发起竞品分析「\(topic)」→ 等待用户确认"
        )
    }
}
