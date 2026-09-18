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
        XCTAssertEqual(AppModel.fastForwardTarget("prototype", from: .clarify, prdOnDisk: false), .prototype)
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .clarify, prdOnDisk: false), .prd)
        // ② 单跳
        XCTAssertEqual(AppModel.fastForwardTarget("prototype", from: .structure, prdOnDisk: false), .prototype)
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .structure, prdOnDisk: false), .prd)
        // ③ 单跳
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .prototype, prdOnDisk: false), .prd)
        // 同级 / 上游 / 中间态 / 未知 → 拒
        XCTAssertNil(AppModel.fastForwardTarget("structure", from: .clarify, prdOnDisk: false), "structure 是中间态，不可作目标")
        XCTAssertNil(AppModel.fastForwardTarget("prototype", from: .prototype, prdOnDisk: false), "同级拒绝")
        XCTAssertNil(AppModel.fastForwardTarget("prototype", from: .prd, prdOnDisk: false), "上游拒绝")
        // .prd→.prd（2026-09-17 路径选择）：PRD 在盘 = 迭代反馈，拒；不在盘 = ③ 停驻态续出，放行
        XCTAssertNil(AppModel.fastForwardTarget("prd", from: .prd, prdOnDisk: true), "PRD 在盘属迭代反馈，不经快速通道")
        XCTAssertEqual(AppModel.fastForwardTarget("prd", from: .prd, prdOnDisk: false), .prd, "停驻态续出放行")
        XCTAssertNil(AppModel.fastForwardTarget("clarify", from: .clarify, prdOnDisk: false), "上游拒绝")
        XCTAssertNil(AppModel.fastForwardTarget("bogus", from: .clarify, prdOnDisk: false), "未知目标拒绝")
        // 前后空白容忍
        XCTAssertEqual(AppModel.fastForwardTarget(" prototype ", from: .clarify, prdOnDisk: false), .prototype)
    }

    // MARK: 闸口路由解析（收尾确认问作答 / 自由作答关键词 → GateRoute）

    func testGateRouteFromText() {
        // 组合措辞优先判 PRD：「跳过结构原型直接出 PRD」防误命中 skipToPrototype
        XCTAssertEqual(AppModel.gateRouteFromText("确认，跳过结构原型直接出 PRD"), .skipToPRD)
        XCTAssertEqual(AppModel.gateRouteFromText("跳过中间阶段，直接出 PRD"), .skipToPRD)
        XCTAssertEqual(AppModel.gateRouteFromText("别问了直接出prd"), .skipToPRD)
        XCTAssertEqual(AppModel.gateRouteFromText("跳过原型，直接出 PRD"), .skipToPRD)
        // 原型路由
        XCTAssertEqual(AppModel.gateRouteFromText("确认，跳过结构直接出原型"), .skipToPrototype)
        XCTAssertEqual(AppModel.gateRouteFromText("直接生成原型"), .skipToPrototype)
        // 停驻
        XCTAssertEqual(AppModel.gateRouteFromText("到此为止，本版不出 PRD"), .stopHere)
        XCTAssertEqual(AppModel.gateRouteFromText("到原型为止"), .stopHere)
        // 常规确认无路径关键词
        XCTAssertEqual(AppModel.gateRouteFromText("确认，进入结构设计"), .next)
        XCTAssertEqual(AppModel.gateRouteFromText("确认"), .next)
        XCTAssertEqual(AppModel.gateRouteFromText("没问题，就这样"), .next)
    }

    // MARK: PRD 精简路径 prompt（结构/原型跳过 → 基于要点表直接撰写）

    func testPRDLeanPathPrompt() {
        // ① 直出 PRD（全精简）：结构 + 原型均未生成
        let leanFromClarify = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "（缺失）",
            architecture: "", coreFlows: "",
            prototypePages: [], analysisNotes: "", injection: ""
        )
        XCTAssertTrue(leanFromClarify.contains("精简路径"), "① 直出 PRD 走精简指令")
        XCTAssertTrue(leanFromClarify.contains("精简基准"))
        XCTAssertFalse(leanFromClarify.contains("双重基准"))

        // ② 跳 ③ 出 PRD（半精简）：结构在、原型缺
        let leanFromStructure = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "graph TD", coreFlows: "flowchart",
            prototypePages: [], analysisNotes: "", injection: ""
        )
        XCTAssertTrue(leanFromStructure.contains("精简路径"), "② 跳原型直出 PRD 同走精简指令")

        // 完整路径：结构 + 原型齐备 → 双重基准
        let full = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "graph TD", coreFlows: "flowchart",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        XCTAssertTrue(full.contains("双重基准"))
        XCTAssertFalse(full.contains("精简路径"))
    }

    // MARK: prompt 注入（①②③ 含快速通道段且目标正确；④ 不注入）

    func testFastForwardSectionInPrompts() {
        let clarifyPrompt = AgentPrompts.clarify(injection: "")
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

    // MARK: stray PRD 块检测（非 PRD 阶段静默丢弃兜底，2026-09-17 事故）

    func testHasStrayPRDBlock() {
        // 闭合 prd 块（可解析但非 PRD 阶段无消费者）→ true
        let closed = """
        PRD 完整全文如下。

        ```artifact:prd
        # 小步 · 产品需求文档（PRD）

        ## 1. 产品概述
        正文……
        ```
        """
        XCTAssertTrue(ArtifactParser.hasStrayPRDBlock(
            blocks: ArtifactParser.parseArtifactBlocks(in: closed), text: closed
        ))

        // 未闭合 prd 围栏（截断场景，blocks 为空）→ true
        let truncated = "这就出 PRD：\n```artifact:prd\n# 小步 · 产品需求文档\n\n## 1. 概述"
        XCTAssertTrue(ArtifactParser.hasStrayPRDBlock(blocks: [], text: truncated))

        // 其他产物块（radar / 原型）→ false
        let radar = """
        ```artifact:radar
        {"fixed": [], "remaining": []}
        ```
        """
        XCTAssertFalse(ArtifactParser.hasStrayPRDBlock(
            blocks: ArtifactParser.parseArtifactBlocks(in: radar), text: radar
        ))

        // 纯文本回复 → false
        XCTAssertFalse(ArtifactParser.hasStrayPRDBlock(blocks: [], text: "普通讨论回复"))
    }
}
