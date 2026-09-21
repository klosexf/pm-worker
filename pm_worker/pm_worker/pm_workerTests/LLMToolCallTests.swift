//
//  LLMToolCallTests.swift
//  pm_workerTests
//
//  Function Calling 协议层（纯函数直测，无网络）：
//  tool_calls 流式分片累积、请求体 tools/tool_calls/tool_call_id 编码、
//  ChatMessage Role.tool 与旧存量 JSON 双向兼容。
//

import XCTest
@testable import pm_worker

final class LLMToolCallAccumulatorTests: XCTestCase {

    private func fragment(
        index: Int? = nil, id: String? = nil, name: String? = nil, args: String? = nil
    ) -> ToolCallFragment {
        ToolCallFragment(
            index: index, id: id, type: id == nil ? nil : "function",
            function: (name == nil && args == nil)
                ? nil : .init(name: name, arguments: args)
        )
    }

    /// 增量下发：arguments 分多次 fragment 追加到同一调用。
    func testIncrementalArgumentsAppend() {
        var calls = LLMClient.accumulateToolFragments([], into: [])
        calls = LLMClient.accumulateToolFragments(
            [fragment(index: 0, id: "call_1", name: "web_search", args: "{\"qu")],
            into: calls
        )
        calls = LLMClient.accumulateToolFragments(
            [fragment(index: 0, args: "ery\":")],
            into: calls
        )
        calls = LLMClient.accumulateToolFragments(
            [fragment(index: 0, args: "\"Swift 6\"}")],
            into: calls
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"query\":\"Swift 6\"}")
    }

    /// 多调用并发：按 index 分流到不同调用。
    func testMultipleCallsByIndex() {
        let calls = LLMClient.accumulateToolFragments([
            fragment(index: 0, id: "a", name: "load_skill", args: "{\"query\":\"KA"),
            fragment(index: 1, id: "b", name: "web_search", args: "{\"query\":\"x\"}"),
            fragment(index: 0, args: "NO\"}"),
        ], into: [])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].id, "a")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"query\":\"KANO\"}")
        XCTAssertEqual(calls[1].id, "b")
        XCTAssertEqual(calls[1].argumentsJSON, "{\"query\":\"x\"}")
    }

    /// 单分片全量下发形态（部分端点不切分）。
    func testSingleFragmentFullPayload() {
        let calls = LLMClient.accumulateToolFragments([
            fragment(index: 0, id: "c1", name: "load_skill", args: "{\"query\":\"KANO\"}")
        ], into: [])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].argumentsJSON, "{\"query\":\"KANO\"}")
    }

    /// index 缺失 → 视为新调用追加；空 fragments 原样返回。
    func testMissingIndexAppendsAndEmptyNoop() {
        let base = [LLMToolCall(id: "x", name: "t", argumentsJSON: "{}")]
        let appended = LLMClient.accumulateToolFragments(
            [fragment(id: "y", name: "u", args: "{}")], into: base
        )
        XCTAssertEqual(appended.count, 2)
        XCTAssertEqual(appended[1].id, "y")
        XCTAssertEqual(LLMClient.accumulateToolFragments([], into: base).count, 1)
    }
}

final class RequestBodyToolEncodingTests: XCTestCase {

    private func encode(_ body: LLMClient.RequestBody) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    /// 携带 tools：tools 数组按 OpenAI function 形态编码。
    func testToolsEncoded() throws {
        var body = LLMClient.RequestBody(
            model: "m", messages: [], stream: true, max_tokens: 100
        )
        body.tools = [ToolDefinition(
            name: "load_skill", description: "d",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
            ])
        )]
        let json = try encode(body)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "load_skill")
    }

    /// 不带 tools：字段整体缺席（对不认该参数的端点零风险）。
    func testToolsOmittedWhenNil() throws {
        let json = try encode(LLMClient.RequestBody(
            model: "m", messages: [], stream: true, max_tokens: 100
        ))
        XCTAssertFalse(json.keys.contains("tools"))
    }

    /// 工具轮消息：assistant.tool_calls 与 tool.tool_call_id 按位编码。
    func testToolMessagesEncoded() throws {
        let messages: [ChatMessage] = [
            ChatMessage(
                role: .assistant, content: "",
                toolCalls: [LLMToolCall(id: "t1", name: "web_search", argumentsJSON: "{\"query\":\"q\"}")]
            ),
            ChatMessage(role: .tool, content: "结果", toolCallID: "t1"),
        ]
        let body = LLMClient.RequestBody(
            model: "m",
            messages: messages.map { LLMClient.RequestBody.message(from: $0) },
            stream: true, max_tokens: 100
        )
        let json = try encode(body)
        let msgs = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(msgs[0]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(assistant[0]["id"] as? String, "t1")
        let function = try XCTUnwrap(assistant[0]["function"] as? [String: Any])
        XCTAssertEqual(function["arguments"] as? String, "{\"query\":\"q\"}")
        let toolMsg = msgs[1]
        XCTAssertEqual(toolMsg["role"] as? String, "tool")
        XCTAssertEqual(toolMsg["tool_call_id"] as? String, "t1")
    }

    /// 旧存量兼容：无工具字段的 ChatMessage JSON 正常解码；Role.tool 原样往返。
    func testLegacyDecodeAndToolRole() throws {
        let legacy = "{\"role\":\"user\",\"content\":\"hi\"}"
        let msg = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(msg.toolCalls)
        XCTAssertNil(msg.toolCallID)

        let tool = ChatMessage(role: .tool, content: "r", toolCallID: "t9")
        let data = try JSONEncoder().encode(tool)
        let round = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(round.role, .tool)
        XCTAssertEqual(round.role.rawValue, "tool")
        XCTAssertEqual(round.toolCallID, "t9")
    }
}
