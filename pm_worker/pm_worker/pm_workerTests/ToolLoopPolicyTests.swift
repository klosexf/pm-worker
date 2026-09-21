//
//  ToolLoopPolicyTests.swift
//  pm_workerTests
//
//  工具循环消息拼装（纯函数）：assistant(tool_calls) + 逐调用 tool 结果、
//  超预算截断、超限兜底文本。
//

import XCTest
@testable import pm_worker

final class ToolLoopPolicyTests: XCTestCase {

    func testFollowUpMessagesPairsCallsAndResults() {
        let calls = [
            LLMToolCall(id: "a", name: "load_skill", argumentsJSON: "{}"),
            LLMToolCall(id: "b", name: "web_search", argumentsJSON: "{}"),
        ]
        let results = [
            AgentToolResult(ok: true, forLLM: "技能正文", forHuman: "加载技能"),
            AgentToolResult(ok: false, forLLM: "搜索源未配置", forHuman: "未配置"),
        ]
        let msgs = ToolLoopPolicy.followUpMessages(
            assistantContent: "我先查一下", calls: calls, results: results
        )
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].content, "我先查一下")
        XCTAssertEqual(msgs[0].toolCalls?.count, 2)
        XCTAssertEqual(msgs[1].role, .tool)
        XCTAssertEqual(msgs[1].toolCallID, "a")
        XCTAssertEqual(msgs[1].content, "技能正文")
        XCTAssertEqual(msgs[2].toolCallID, "b")
        XCTAssertEqual(msgs[2].content, "搜索源未配置")
    }

    /// 超预算的 forLLM 结果截断（调用方兜底，双保险的第二道）。
    func testOverBudgetResultTruncated() {
        let long = String(repeating: "长", count: agentToolResultBudget + 100)
        let msgs = ToolLoopPolicy.followUpMessages(
            assistantContent: "", calls: [LLMToolCall(id: "a", name: "t", argumentsJSON: "{}")],
            results: [AgentToolResult(ok: true, forLLM: long, forHuman: "x")]
        )
        let text = msgs[1].content
        XCTAssertLessThanOrEqual(text.count, agentToolResultBudget + 20)
        XCTAssertTrue(text.hasSuffix("…（结果过长已截断）"))
    }

    /// 结果数少于调用数（执行中途被取消）：zip 语义只拼有结果的，不崩。
    func testFewerResultsThanCallsDoesNotCrash() {
        let calls = [
            LLMToolCall(id: "a", name: "t", argumentsJSON: "{}"),
            LLMToolCall(id: "b", name: "t", argumentsJSON: "{}"),
        ]
        let msgs = ToolLoopPolicy.followUpMessages(
            assistantContent: "", calls: calls,
            results: [AgentToolResult(ok: true, forLLM: "r", forHuman: "r")]
        )
        XCTAssertEqual(msgs.count, 2)  // assistant + 1 条 tool
    }

    /// 超限兜底：文本含上限提示，驱动模型直答。
    func testLimitExceededResultText() {
        let result = ToolLoopPolicy.limitExceededResult()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("已达上限"))
        XCTAssertTrue(result.forLLM.contains("4 轮"))
    }
}
