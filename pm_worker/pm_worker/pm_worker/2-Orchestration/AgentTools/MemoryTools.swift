//
//  MemoryTools.swift
//  pm_worker
//
//  记忆双通道工具（P0：记忆从「只被系统注入」升级为「模型可读写」）：
//  - save_memory：模型主动沉淀长期记忆。写入收口在 MemoryStore.addToolEntry——
//    kind 只放行 结论/经验（⚑ 约束/否决必须来自用户裁决事件），经验落假设态
//    进既有校准回路（注入置 pending → 记忆抽屉确认/否定升降置信度）。
//  - recall_memory：词面检索当前项目池 + 全局池（与注入排序同源评分），
//    补「全量注入超预算被裁的旧条目」的回查通道。
//  两工具都不写闸口文件（红线不破），执行闭包经 AgentToolContext 注入。
//

import Foundation

@MainActor
struct SaveMemoryTool: AgentTool {
    var name: String { "save_memory" }
    var description: String {
        "记一笔需要跨回合长期保留的记忆。kind=conclusion 记用户已明确拍板的结论；"
            + "kind=experience 记可复用的通用做法经验（落假设态，待用户校准确认）。"
            + "约束与否决项只能由用户确认沉淀，本工具不受理；一次性事实不要记。"
    }
    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "description": .string("conclusion（已拍板结论）或 experience（通用经验），缺省 experience"),
                    "enum": .strings(["conclusion", "experience"]),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("一句话记忆正文（不含换行），带结论与依据，如「PRD 只保留五章结构——用户在澄清中两次确认」"),
                ]),
            ]),
            "required": .strings(["content"]),
        ])
    }

    struct Args: Decodable {
        var kind: String?
        var content: String
    }

    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        guard let memorySave = ctx.memorySave else {
            return .failure("本轮记忆服务未启用。")
        }
        guard let args = decodeToolArgs(Args.self, from: argumentsJSON) else {
            return .failure("参数解析失败：需要 {\"kind\": \"conclusion|experience\", \"content\": \"一句话正文\"}。")
        }
        let kindRaw = (args.kind ?? "experience")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let kind: MemoryEntry.Kind
        switch kindRaw {
        case "conclusion": kind = .conclusion
        case "experience": kind = .experience
        default:
            return .failure("save_memory 只支持 kind=conclusion 或 kind=experience；约束与否决项须由用户确认沉淀。")
        }
        if let error = memorySave(kindRaw, args.content) {
            return .failure(error)
        }
        return AgentToolResult(
            ok: true,
            forLLM: "已记入项目记忆（\(kind == .experience ? "经验为假设态，待用户在校准中确认后才升为可靠依据" : "结论态")）。继续当前任务即可，无需向用户复述。",
            forHuman: "🧠 记下一笔记忆（\(kind.rawValue)）"
        )
    }
}

@MainActor
struct RecallMemoryTool: AgentTool {
    var name: String { "recall_memory" }
    var description: String {
        "检索项目与全局长期记忆（结论/约束/否决项/经验）。注入区只带最相关条目，"
            + "需要查更早的否决原因、历史结论或被预算裁掉的条目时用它回查，不凭印象编造记忆内容。"
    }
    var parameters: JSONValue {
        agentToolStringProperty("检索词或主题（如「性能」「否决 深色模式」）")
    }

    func execute(argumentsJSON: String, ctx: AgentToolContext) async -> AgentToolResult {
        guard let memorySearch = ctx.memorySearch else {
            return .failure("本轮记忆服务未启用。")
        }
        struct Args: Codable { var query: String? }
        let query = (decodeToolArgs(Args.self, from: argumentsJSON)?.query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("参数缺失：请提供 query（检索词或主题）。")
        }
        let lines = memorySearch(query)
        if lines.isEmpty {
            return AgentToolResult(
                ok: true,
                forLLM: "记忆池中没有与「\(query)」相关的条目。可换检索词再试一次，或基于已有信息作答。",
                forHuman: "🔎 检索记忆「\(query)」：无命中"
            )
        }
        return AgentToolResult(
            ok: true,
            forLLM: "命中 \(lines.count) 条记忆（项目 > 全局，新覆盖旧，不得与当前回答矛盾）：\n"
                + lines.joined(separator: "\n"),
            forHuman: "🔎 检索记忆「\(query)」：命中 \(lines.count) 条"
        )
    }
}
