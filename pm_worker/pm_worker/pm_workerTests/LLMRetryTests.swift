//
//  LLMRetryTests.swift
//  pm_workerTests
//
//  瞬时故障自动重试 + 错误文案人话化（2026-09-16 429 原始 JSON 直出 UI 事故回归锚点）：
//  服务端过载（429 ServerOverloaded）是瞬时故障，客户端必须退避重试吸收掉；
//  重试耗尽后的文案要给「发生了什么 / 怎么办」，绝不透出原始报文与 Request ID。
//

import XCTest
@testable import pm_worker

final class LLMRetryTests: XCTestCase {

    // MARK: - 瞬时故障判定

    func testTransientStatusCovers429And5xx() {
        XCTAssertTrue(LLMClient.isTransientStatus(429), "429 限流/过载必须重试")
        for code in [500, 502, 503, 504] {
            XCTAssertTrue(LLMClient.isTransientStatus(code), "\(code) 服务端错误必须重试")
        }
    }

    func testNonTransientStatusNotRetried() {
        // 4xx 配置类错误重试无意义（Key 无效 / 模型名错误 / 余额不足）
        for code in [400, 401, 402, 403, 404] {
            XCTAssertFalse(LLMClient.isTransientStatus(code), "\(code) 不应重试")
        }
    }

    // MARK: - 服务端人话提取

    func testServerMessageExtractsOpenAICompatibleEnvelope() {
        let body = #"{"error":{"code":"ServerOverloaded","message":"The service is currently unable to handle additional requests.","param":"","type":"TooManyRequests"}}"#
        XCTAssertEqual(
            LLMClient.serverMessage(fromBody: body),
            "The service is currently unable to handle additional requests."
        )
    }

    func testServerMessageFallsBackToRawPrefixWhenNotEnvelope() {
        let message = LLMClient.serverMessage(fromBody: "<html>Bad Gateway</html>")
        XCTAssertEqual(message, "<html>Bad Gateway</html>")
    }

    // MARK: - 重试状态文案（流式气泡状态行）

    func testRetryStatusTextShowsReasonAndProgress() {
        let busy = LLMClient.retryStatusText(code: 429, attempt: 1)
        XCTAssertTrue(busy.contains("繁忙"), "429 文案须说明服务繁忙：\(busy)")
        XCTAssertTrue(busy.contains("重试中"), "文案须说明正在自动重试：\(busy)")
        XCTAssertTrue(busy.contains("1/\(LLMClient.maxStreamRetries)"), "文案须带重试进度：\(busy)")

        let unavailable = LLMClient.retryStatusText(code: 503, attempt: LLMClient.maxStreamRetries)
        XCTAssertTrue(unavailable.contains("暂时不可用"), "5xx 文案须说明服务不可用：\(unavailable)")
        XCTAssertTrue(unavailable.contains("2/\(LLMClient.maxStreamRetries)"), "进度须随次数推进：\(unavailable)")
    }

    func testMaxStreamRetriesMatchesBackoffTable() {
        XCTAssertEqual(LLMClient.maxStreamRetries, 2, "重试上限须与退避表（1s→2s）条目数一致")
    }

    // MARK: - 文案人话化（不透出原始报文）

    func testHTTP429CopyIsHumanAndActionable() {
        let raw = #"{"error":{"code":"ServerOverloaded","message":"overloaded","request_id":"0217895281003190a3079a058b707e59510a9e5fba8ef68f7ef11"}}"#
        let message = LLMClient.LLMError.http(429, raw).errorDescription ?? ""
        XCTAssertTrue(message.contains("繁忙"), "文案须说明发生了什么：\(message)")
        XCTAssertTrue(message.contains("重新发送"), "文案须给出下一步动作：\(message)")
        XCTAssertFalse(message.contains("request_id"), "原始报文字段绝不出现在用户文案：\(message)")
        XCTAssertFalse(message.contains("{"), "JSON 报文绝不出现在用户文案：\(message)")
    }

    func testHTTP401CopyPointsToSettings() {
        let message = LLMClient.LLMError.http(401, #"{"error":{"message":"Invalid API key"}}"#).errorDescription ?? ""
        XCTAssertTrue(message.contains("设置") || message.contains("Key"), "401 须指向配置入口：\(message)")
    }

    // MARK: - 空流重试（思考烧满预算 vs 字面空流，2026-09-16 确认后 6 分钟空流事故）

    func testEscalatedRetryBudgetDoublesWithFloorAndCap() {
        XCTAssertEqual(LLMClient.escalatedRetryBudget(16384), 32768, "聊天轮 16384 加倍到 32768")
        XCTAssertEqual(LLMClient.escalatedRetryBudget(8192), 32768, "抽取路径 8192 须抬到保底 32768")
        XCTAssertEqual(LLMClient.escalatedRetryBudget(32768), 65536, "产物轮 32768 加倍到 65536")
        XCTAssertEqual(LLMClient.escalatedRetryBudget(49152), 65536, "封顶 65536，防端点拒收超大 max_tokens")
        XCTAssertEqual(LLMClient.escalatedRetryBudget(40000), 65536)
    }

    func testEmptyAfterThinkingCopyExplainsCauseAndNextStep() {
        let message = LLMClient.LLMError.emptyAfterThinking.errorDescription ?? ""
        XCTAssertTrue(message.contains("思考"), "文案须点明成因是思考烧满预算：\(message)")
        XCTAssertTrue(message.contains("正文"), "文案须说明后果是零正文：\(message)")
        XCTAssertTrue(message.contains("重试") || message.contains("重发"), "文案须给出下一步动作：\(message)")
    }

    func testEmptyStreamVariantsAreDistinctCases() {
        // 两种空流必须可区分：重试策略分叉（字面空流→同请求重发；思考烧预算→降思考+加倍预算）
        func kind(_ error: LLMClient.LLMError) -> String {
            switch error {
            case .emptyStream: "emptyStream"
            case .emptyAfterThinking: "emptyAfterThinking"
            default: "other"
            }
        }
        XCTAssertEqual(kind(.emptyStream), "emptyStream")
        XCTAssertEqual(kind(.emptyAfterThinking), "emptyAfterThinking")
        XCTAssertNotEqual(
            LLMClient.LLMError.emptyStream.errorDescription,
            LLMClient.LLMError.emptyAfterThinking.errorDescription,
            "两种空流的用户文案必须不同"
        )
    }

    func testLowEffortSendsExplicitParamForEmptyRetry() {
        // 思考烧预算重试强制 low 档：apiValue 必须显式下发（实测 low 可直接关思考，正文即流出）
        XCTAssertEqual(ThinkingEffort.low.apiValue, "low")
        XCTAssertEqual(ThinkingEffort.low.rawValue, "low")
    }
}
