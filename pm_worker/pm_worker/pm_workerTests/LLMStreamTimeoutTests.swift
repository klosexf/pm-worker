//
//  LLMStreamTimeoutTests.swift
//  pm_workerTests
//
//  流式挂死防护（2026-09-15「发不出去」事故回归锚点）：
//  request 级 timeoutInterval 只是空闲计时，服务端持续发 keep-alive 心跳
//  却不给正文时会不断重置 → 流永久挂起 → isStreaming 卡死，后续所有发送
//  被「生成中」守卫静默吞掉。流式专用会话必须带 resource 级总时长硬上限。
//

import XCTest
@testable import pm_worker

final class LLMStreamTimeoutTests: XCTestCase {

    func testStreamingSessionHasResourceTimeoutCap() {
        // 总时长硬上限：任何流式请求（含心跳黑洞）到点必断，防 isStreaming 永久卡死
        XCTAssertEqual(
            LLMClient.streamingSession.configuration.timeoutIntervalForResource,
            600,
            "流式会话必须配置 resource 级总时长上限（防心跳黑洞挂死）"
        )
        // 空闲超时：半开连接 120s 必断（与原 request.timeoutInterval 同语义）
        XCTAssertEqual(
            LLMClient.streamingSession.configuration.timeoutIntervalForRequest,
            120
        )
    }

    func testStreamTimeoutErrorHasActionableMessage() {
        let error = LLMClient.LLMError.streamTimeout
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("超时"), "文案须说明是超时：\(message)")
        XCTAssertTrue(message.contains("重试") || message.contains("换模型"), "文案须给出下一步动作：\(message)")
    }
}
