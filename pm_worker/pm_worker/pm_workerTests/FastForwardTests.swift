//
//  FastForwardTests.swift
//  pm_workerTests
//
//  快速通道（跳步）协议：解析 + 白名单 + prompt 注入。
//

import XCTest
@testable import pm_worker

final class FastForwardTests: XCTestCase {

    // MARK: 解析（artifact:fast-forward 块）

    func testParseFastForward() {
        // 无块 → nil
        XCTAssertNil(ArtifactParser.parseFastForward(
            blocks: ArtifactParser.parseArtifactBlocks(in: "普通回复，没有跳步请求")
        ))

        // 合法块 → 解析出目标与诉求（instruction 原样透传）
        let reply = """
        好的，这就跳过逐步确认，直接生成原型。

        ```artifact:fast-forward
        {"target": "prototype", "instruction": "深色主题，移动端风格"}
        ```
        """
        let request = ArtifactParser.parseFastForward(
            blocks: ArtifactParser.parseArtifactBlocks(in: reply)
        )
        XCTAssertEqual(request?.target, "prototype")
        XCTAssertEqual(request?.instruction, "深色主题，移动端风格")

        // 无诉求（instruction 缺席）→ nil 诉求（走通用快速出稿指令）
        let bare = """
        ```artifact:fast-forward
        {"target": "prd"}
        ```
        """
        XCTAssertEqual(
            ArtifactParser.parseFastForward(
                blocks: ArtifactParser.parseArtifactBlocks(in: bare)
            ),
            ArtifactParser.FastForwardRequest(target: "prd", instruction: nil)
        )

        // JSON 不合法 → nil
        let broken = """
        ```artifact:fast-forward
        不是 JSON
        ```
        """
        XCTAssertNil(ArtifactParser.parseFastForward(
            blocks: ArtifactParser.parseArtifactBlocks(in: broken)
        ))

        // 与 backtrack 块互不混淆：同一回复两块并存时各取各的
        let mixed = """
        ```artifact:backtrack
        {"target": "prototype", "instruction": "重做原型", "mode": "redo"}
        ```

        ```artifact:fast-forward
        {"target": "prd", "instruction": "顺便直接出 PRD"}
        ```
        """
        let blocks = ArtifactParser.parseArtifactBlocks(in: mixed)
        XCTAssertEqual(
            ArtifactParser.parseBacktrack(blocks: blocks)?.target, "prototype"
        )
        XCTAssertEqual(
            ArtifactParser.parseFastForward(blocks: blocks)?.target, "prd"
        )
    }

    // MARK: 白名单 + 严格下游校验

    func testFastForwardTargetWhitelist() {
        // ① 可跳 prototype / prd（主场景）
        XCTAssertEqual(AppModel.fastForwardTarget("prototype", from: .clarify), .prototype)
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .clarify), .prd)
        // ② 单跳
        XCTAssertEqual(AppModel.fastForwardTarget("prototype", from: .structure), .prototype)
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .structure), .prd)
        // ③ 单跳
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .prototype), .prd)
        // 同级 / 上游 / 中间态 / 未知 → 拒
        XCTAssertNil(AppModel.fastForwardTarget("structure", from: .clarify), "structure 是中间态，不可作目标")
        XCTAssertNil(AppModel.fastForwardTarget("prototype", from: .prototype), "同级拒绝")
        XCTAssertNil(AppModel.fastForwardTarget("prototype", from: .prd), "上游拒绝")
        XCTAssertNil(AppModel.fastForwardTarget("prd", from: .prd), "同级拒绝")
        XCTAssertNil(AppModel.fastForwardTarget("clarify", from: .clarify), "上游拒绝")
        XCTAssertNil(AppModel.fastForwardTarget("bogus", from: .clarify), "未知目标拒绝")
        // 前后空白容忍
        XCTAssertEqual(AppModel.fastForwardTarget(" prototype ", from: .clarify), .prototype)
    }

    // MARK: prompt 注入（①②③ 含快速通道段且目标正确；④ 不注入）

    func testFastForwardSectionInPrompts() {
        let clarifyPrompt = AgentPrompts.clarify(
            rounds: 1, limit: 5, previousTable: nil, amending: false, injection: ""
        )
        XCTAssertTrue(clarifyPrompt.contains("artifact:fast-forward"), "① 提示词含快速通道协议")
        XCTAssertTrue(clarifyPrompt.contains("\"prototype\""), "① 可跳③原型")
        XCTAssertTrue(clarifyPrompt.contains("\"prd\""), "① 可跳④PRD")

        let structurePrompt = AgentPrompts.structure(clarification: "要点", injection: "")
        XCTAssertTrue(structurePrompt.contains("artifact:fast-forward"), "② 提示词含快速通道协议")
        XCTAssertTrue(structurePrompt.contains("\"prototype\""), "② 可跳③原型")
        XCTAssertTrue(structurePrompt.contains("\"prd\""), "② 可跳④PRD")

        let prototypePrompt = AgentPrompts.prototype(
            modulePageMap: "| 模块 | 页面 |", coreFlows: "graph TD", injection: ""
        )
        XCTAssertTrue(prototypePrompt.contains("artifact:fast-forward"), "③ 提示词含快速通道协议")
        XCTAssertTrue(prototypePrompt.contains("\"prd\""), "③ 可跳④PRD")
        // ③ 的快速通道段不含 prototype（同级不可跳）——校验收窄到快速通道段内
        if let ffStart = prototypePrompt.range(of: "━━ 快速通道"),
           let reviewStart = prototypePrompt.range(of: "━━ 内建自评审") {
            let ffSection = prototypePrompt[ffStart.lowerBound..<reviewStart.lowerBound]
            XCTAssertFalse(ffSection.contains("\"prototype\""), "③ 不可跳同级")
        } else {
            XCTFail("③ 提示词缺少快速通道/自评审段落标记")
        }

        // ④ 是终点：不注入
        let prdPrompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "", coreFlows: "",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        XCTAssertFalse(prdPrompt.contains("artifact:fast-forward"), "④ 不含快速通道协议")
    }
}
