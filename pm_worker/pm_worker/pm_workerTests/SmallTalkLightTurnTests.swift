//
//  SmallTalkLightTurnTests.swift
//  pm_workerTests
//
//  寒暄轻量轮的可单测契约（2026-09-22）。
//
//  发送链本身（AppModel.sendMessage 的短路分支 → sessionStore.send）不在此覆盖：
//  测试侧的假端点是 `file://` 假 SSE（见 PrototypeConflictTests ⑥），只能喂响应、
//  收不到请求体，而 LLMClient.streamingSession 是不可替换的 static let——为断言
//  「发出去的 prompt 从 22,463 token 降到几百」去开一个请求捕获接缝，代价大于收益。
//  该断言由 usage.jsonl 实测取证。这里钉住的是**接缝改坏时最先崩的两条纯契约**：
//  轻量 prompt 不得夹带阶段协议骨架、思考强度三档的优先级不得倒置。
//

import XCTest
@testable import pm_worker

final class SmallTalkLightTurnTests: XCTestCase {

    // MARK: - 轻量 prompt 的瘦身契约

    /// 轻量轮存在的全部理由是「不背 ③ 那套 18k 字符协议骨架」。
    /// 任何一段被拼回去，这句你好就又值 127 秒了。
    func testSmallTalkPromptCarriesNoStageProtocolMandates() {
        let prompt = AgentPrompts.smallTalkReply
        for mandate in [
            "内建自评审", "漏项雷达", "artifact:radar", "artifact:plan",
            "artifact:decision", "第一性原理", "快速通道", "回退",
        ] {
            XCTAssertFalse(
                prompt.contains(mandate),
                "轻量 prompt 夹带了阶段协议段「\(mandate)」——寒暄又会触发完整自评审"
            )
        }
    }

    /// 反向禁令必须显式在位：光「不要求 radar」不够，模型会按自己在 ①②③
    /// 养成的习惯主动补一个（实测那次「你好」的 CoT 就是在给 radar 填字段）。
    func testSmallTalkPromptExplicitlyForbidsArtifactAndToolUse() {
        let prompt = AgentPrompts.smallTalkReply
        XCTAssertTrue(prompt.contains("artifact"), "须明文禁止输出产物块")
        XCTAssertTrue(prompt.contains("禁止") || prompt.contains("不要"))
        XCTAssertTrue(prompt.contains("工具"), "须明文禁止调用工具（工具轮会把轻量轮拖回多轮串行）")
    }

    // MARK: - 思考强度优先级

    /// 三档优先级：重试位 > 轻量轮覆盖位 > 用户选择（默认 high = 不发参）。
    /// 覆盖位排在用户位**之前**才对——轻量轮要压 low，不能被界面上仍显示 High 的
    /// 用户档位顶回去；但空流重试的强制 low 必须仍能压过一切。
    func testStreamEffortPrecedenceRetryOverrideUserDefault() {
        XCTAssertEqual(
            SessionStore.resolvedStreamEffort(retry: nil, override: .low, userDefault: .high), .low,
            "轻量轮覆盖位须压过用户档位"
        )
        XCTAssertEqual(
            SessionStore.resolvedStreamEffort(retry: .medium, override: .low, userDefault: .high),
            .medium, "重试位须压过覆盖位"
        )
        XCTAssertEqual(
            SessionStore.resolvedStreamEffort(retry: nil, override: nil, userDefault: .max), .max,
            "两个覆盖位都不在时回落用户档位（常规轮行为不变）"
        )
    }
}
