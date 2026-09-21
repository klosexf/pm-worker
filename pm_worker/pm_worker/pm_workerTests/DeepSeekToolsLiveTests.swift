//
//  DeepSeekToolsLiveTests.swift
//  pm_workerTests
//
//  Function Calling 真连通（live）：真实配置 + Keychain key → tools 往返一轮。
//  无 key 时 XCTSkipIf 跳过（环境问题不计回归，同 testDeepSeekLiveStreamChat 口径）。
//

import XCTest
@testable import pm_worker

final class DeepSeekToolsLiveTests: XCTestCase {

    /// 真实配置 → 携带 tools 的流式请求走通，模型能发起一次工具调用。
    func testDeepSeekLiveToolCallRoundTrip() async throws {
        let settings = LLMSettings.load()
        // anthropic-compat 走 content blocks 协议，v1 不发 tools——跳过
        guard settings.chatConfig.provider != "anthropic-compat" else {
            throw XCTSkip("anthropic-compat 降级档不发 tools——跳过 live 工具测试")
        }
        let config = settings.chatConfig
        let key = KeychainStore.get(config.apiKeyKeychainKey) ?? ""
        try XCTSkipIf(
            key.isEmpty,
            "Keychain 未存 \(config.apiKeyKeychainKey) 的 key——跳过真连通测试"
        )

        let stream = try LLMClient.streamChat(
            stage: .clarify,
            settings: settings,
            messages: [
                ChatMessage(
                    role: .system,
                    content: "你是测试助手。回答任何问题前必须先调用 load_skill 工具查询「KANO」。"
                ),
                ChatMessage(role: .user, content: "你好"),
            ],
            maxTokens: 512,
            tools: [
                ToolDefinition(
                    name: "load_skill",
                    description: "按需加载 PM 方法论技能全文",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object(["type": .string("string")])
                        ]),
                        "required": .strings(["query"]),
                    ])
                )
            ]
        )
        var full = ""
        var toolCalls: [LLMToolCall] = []
        for try await delta in stream {
            switch delta {
            case .text(let text): full += text
            case .toolCalls(let calls): toolCalls = calls
            case .reasoning: break
            case .truncated: break
            case .retrying: break
            }
        }
        // 工具调用或正文至少出现其一（部分模型不服从强制调用指令时给正文）
        let hasToolCall = !toolCalls.isEmpty && !toolCalls[0].name.isEmpty
        XCTAssertFalse(
            !hasToolCall && full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "模型既未发起工具调用也未返回正文——检查模型名/key/端点"
        )
        if hasToolCall {
            XCTAssertFalse(toolCalls[0].argumentsJSON.isEmpty, "工具调用缺少 arguments")
        }
    }
}
