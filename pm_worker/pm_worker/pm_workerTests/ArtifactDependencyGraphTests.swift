//
//  ArtifactDependencyGraphTests.swift
//  pm_workerTests
//
//  产物依赖图 + 重规划循环（v0.10 §6.10）回归锚点：
//  ① 引用解析：目录前缀 / 文件名 / 展示名词干 / PRD 大小写 / 模糊文本不猜
//  ② 下游闭包：传递性（要点表 → 结构三件 → 原型 → PRD）；映射表/核心流程图 → 原型+PRD
//  ③ 重规划链：各目标阶段的重生成顺序；用户可见文案零内部路径（文案原则）
//  ④ 行前缀保真：重规划尾折叠进「🔄 已回到」行后，链游走前缀不受影响（B004 同教训）
//  ⑤ impacts 纪律：②/③ 回退建议零可解析引用 → 降级；① 澄清豁免
//  ⑥ 采纳集成：纳入提案 → 处置回写 adopted + 回退到② + 行内含重规划计划
//  全离线：rootOverride 临时目录隔离，不碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class ArtifactDependencyGraphTests: XCTestCase {
    var tempRoot: URL!
    private let project = "依赖图项目"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-agent-depgraph-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion("v1", in: project)
        try? PMAgentStore.ensureWorkspace(project: project, version: "v1")
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    private func jsonlText(project: String, version: String) -> String {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - ① 引用解析

    func testResolveReferenceByDisplayNameStem() {
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("核心流程图 · 支付模块"),
            [ArtifactDependencyGraph.coreFlows]
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("交互原型 首页"),
            [ArtifactDependencyGraph.prototypeFamily]
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("要点表的目标用户字段"),
            [ArtifactDependencyGraph.clarification]
        )
    }

    func testResolveReferenceByPathAndDirectory() {
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("02-structure/模块-页面映射表.md · 登录"),
            [ArtifactDependencyGraph.modulePageMap]
        )
        // 目录级引用视为引用整组产物
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("02-structure 整体重排"),
            Set([
                ArtifactDependencyGraph.architecture,
                ArtifactDependencyGraph.coreFlows,
                ArtifactDependencyGraph.businessFlows,
                ArtifactDependencyGraph.modulePageMap,
            ])
        )
    }

    func testResolveReferencePRDCaseInsensitiveAndVagueTextMisses() {
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("PRD 的数据指标章"),
            [ArtifactDependencyGraph.prd]
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.resolveReference("prd 里补一段"),
            [ArtifactDependencyGraph.prd]
        )
        XCTAssertTrue(
            ArtifactDependencyGraph.resolveReference("整体体验有点乱").isEmpty,
            "模糊文本解析为零——宁可多问，不猜"
        )
        XCTAssertTrue(
            ArtifactDependencyGraph.resolveReference("结构不太对").isEmpty,
            "「结构」单词不算具体产物引用"
        )
    }

    // MARK: - ② 下游闭包

    func testDownstreamTransitiveClosureFromClarification() {
        let closure = ArtifactDependencyGraph.downstream(
            ofSeeds: [ArtifactDependencyGraph.clarification]
        )
        for expected in [
            ArtifactDependencyGraph.architecture,
            ArtifactDependencyGraph.coreFlows,
            ArtifactDependencyGraph.modulePageMap,
            ArtifactDependencyGraph.prototypeFamily,
            ArtifactDependencyGraph.prd,
        ] {
            XCTAssertTrue(closure.contains(expected), "要点表下游须含 \(expected)")
        }
        XCTAssertFalse(closure.contains(ArtifactDependencyGraph.clarification), "闭包不含自身")
    }

    func testDownstreamFromMapAndCoreFlows() {
        let fromMap = ArtifactDependencyGraph.downstream(
            ofSeeds: [ArtifactDependencyGraph.modulePageMap]
        )
        XCTAssertEqual(fromMap, Set([
            ArtifactDependencyGraph.prototypeFamily, ArtifactDependencyGraph.prd,
        ]))
        // 原型具体槽位文件归并到家族节点
        let fromSlot = ArtifactDependencyGraph.downstream(
            ofSeeds: ["03-prototypes/可点击原型.html"]
        )
        XCTAssertEqual(fromSlot, [ArtifactDependencyGraph.prd])
    }

    func testConcretePrototypePathNormalizesToFamily() {
        XCTAssertEqual(
            ArtifactDependencyGraph.normalize("03-prototypes/原型-方案A.html"),
            ArtifactDependencyGraph.prototypeFamily
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.normalize("02-structure/核心流程图.md"),
            ArtifactDependencyGraph.coreFlows
        )
        XCTAssertNil(ArtifactDependencyGraph.normalize("随便一个路径.md"))
    }

    // MARK: - ③ 重规划链

    func testReplanStepsOrderPerTarget() {
        // ② 回退：结构三件 → 原型 → PRD
        let structure = ArtifactDependencyGraph.replanSteps(target: .structure).map(\.node)
        XCTAssertEqual(structure, [
            ArtifactDependencyGraph.architecture,
            ArtifactDependencyGraph.coreFlows,
            ArtifactDependencyGraph.modulePageMap,
            ArtifactDependencyGraph.prototypeFamily,
            ArtifactDependencyGraph.prd,
        ])
        // ③ 回退：原型 → PRD（局部下游）
        let prototype = ArtifactDependencyGraph.replanSteps(target: .prototype).map(\.node)
        XCTAssertEqual(prototype, [
            ArtifactDependencyGraph.prototypeFamily, ArtifactDependencyGraph.prd,
        ])
        // ① 增补：要点表在前（增补基底），后续全链
        let clarify = ArtifactDependencyGraph.replanSteps(target: .clarify).map(\.node)
        XCTAssertEqual(clarify.first, ArtifactDependencyGraph.clarification)
        XCTAssertEqual(clarify.last, ArtifactDependencyGraph.prd)
        // ④ 不是合法回退目标：无链
        XCTAssertTrue(ArtifactDependencyGraph.replanSteps(target: .prd).isEmpty)
    }

    func testReplanSentenceUserFacingNoInternalPaths() {
        for stage in [ArtifactDependencyGraph.Stage.clarify, .structure, .prototype] {
            for mode in ["revise", "redo"] {
                guard let suffix = ArtifactDependencyGraph.replanSuffix(
                    target: stage, mode: mode
                ) else {
                    XCTFail("\(stage) 须产出重规划尾")
                    continue
                }
                XCTAssertFalse(suffix.contains("/"), "界面文案不露内部路径：\(suffix)")
                XCTAssertFalse(suffix.contains(".md"), "界面文案不露文件扩展名：\(suffix)")
                XCTAssertFalse(suffix.contains(".html"), "界面文案不露文件扩展名：\(suffix)")
                XCTAssertTrue(suffix.contains("重规划"))
            }
        }
        XCTAssertTrue(
            ArtifactDependencyGraph.replanSuffix(target: .structure, mode: "redo")!
                .contains("推翻后依次重做"),
            "redo 语义须体现在文案"
        )
        XCTAssertTrue(
            ArtifactDependencyGraph.replanSuffix(target: .structure, mode: "revise")!
                .contains("依次修订重做")
        )
        XCTAssertNil(
            ArtifactDependencyGraph.replanSuffix(target: .prd, mode: "revise"),
            "无下游重做的目标不产计划"
        )
    }

    // MARK: - ④ 行前缀保真（B004：链游走判定依赖「🔄 已回到」前缀）

    func testReplanSuffixKeepsChainPrefixWhenFolded() {
        let suffix = ArtifactDependencyGraph.replanSuffix(target: .structure, mode: "revise") ?? ""
        let row = "🔄 已回到 ② 结构（原型一并标记过期）——马上重做。" + suffix
        XCTAssertTrue(
            row.hasPrefix("🔄 已回到"),
            "重规划尾折叠后行前缀不变——快速通道链游走（isFastForwardChainedBefore）不受影响"
        )
        XCTAssertTrue(suffix.hasPrefix("；"), "重规划尾以「；」起始，拼接不引入换行/新前缀")
    }

    // MARK: - ⑤ impacts 纪律（防轻描淡写）

    func testVerifiedTargetDegradesOnUnresolvableImpacts() {
        XCTAssertEqual(
            ArtifactDependencyGraph.verifiedTarget(
                .structure, impacts: ["整体体验有点乱"]
            ),
            nil,
            "② 回退建议零可解析引用 → 不采信 target"
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.verifiedTarget(.structure, impacts: nil),
            nil,
            "impacts 缺失同样不采信"
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.verifiedTarget(.structure, impacts: ["核心流程图 · 支付"]),
            .structure,
            "引用具体产物 → 采信"
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.verifiedTarget(.prototype, impacts: ["交互原型 · 首页"]),
            .prototype
        )
    }

    func testVerifiedTargetClarifyExempt() {
        XCTAssertEqual(
            ArtifactDependencyGraph.verifiedTarget(.clarify, impacts: nil),
            .clarify,
            "① 增补澄清是对话式判断，豁免 impacts 纪律"
        )
        XCTAssertEqual(
            ArtifactDependencyGraph.verifiedTarget(.clarify, impacts: ["含糊其辞"]),
            .clarify
        )
    }

    // MARK: - ⑥ 采纳集成（提案卡纳入 → 计划可见化 → 回退执行）

    @MainActor
    func testAdoptEmitsReplanRowAndResolution() throws {
        let model = AppModel()
        model.selection = .session(project: project, version: "v1", sessionId: "s1")
        XCTAssertEqual(model.pipeline.stage, .clarify, "全新版本从①起步")

        let record = ChangeProposalRecord(
            idea: "结账支持优惠券",
            category: "模块核心",
            target: "structure",
            mode: "revise",
            instruction: nil,
            impacts: ["02-structure/核心流程图.md · 支付"],
            checkpointStage: "prototype"
        )
        ChangeLedger.append(.proposal(record), project: project, version: "v1")
        model.adoptChangeProposal(record)

        // 处置回写 adopted（append-only 台账）
        let items = ChangeLedger.load(project: project, version: "v1")
        XCTAssertEqual(items.first?.resolution, .adopted, "纳入即回写 adopted")
        // 状态机回退到 ②
        XCTAssertEqual(model.pipeline.stage, .structure, "纳入后回退到目标阶段")
        // 重规划计划折叠进「🔄 已回到」行（同一行内、非独立行；行内含产物中文名）
        let text = jsonlText(project: project, version: "v1")
        let row = text
            .split(separator: "\n")
            .last { $0.contains("🔄 已回到") }
            .map(String.init)
        let emitted = try XCTUnwrap(row, "回退行须落盘")
        XCTAssertTrue(emitted.contains("重规划：依次修订重做"), "revise 模式计划文案（同一行内折叠）")
        XCTAssertTrue(emitted.contains("功能架构图 → 核心流程图 → 模块-页面映射表 → 交互原型 → 产品需求文档"))
        XCTAssertFalse(emitted.contains("02-structure"), "用户可见行不露内部路径")
    }

    @MainActor
    func testAdoptRedoModeWording() throws {
        let model = AppModel()
        model.selection = .session(project: project, version: "v1", sessionId: "s2")
        let record = ChangeProposalRecord(
            idea: "原型完全重来",
            category: "页面流程",
            target: "prototype",
            mode: "redo",
            instruction: nil,
            impacts: ["03-prototypes/可点击原型.html"],
            checkpointStage: "prd"
        )
        ChangeLedger.append(.proposal(record), project: project, version: "v1")
        model.adoptChangeProposal(record)

        XCTAssertEqual(model.pipeline.stage, .prototype)
        let text = jsonlText(project: project, version: "v1")
        let row = text
            .split(separator: "\n")
            .last { $0.contains("🔄 已回到") }
            .map(String.init)
        let emitted = try XCTUnwrap(row)
        XCTAssertTrue(emitted.contains("推翻后依次重做"), "redo 模式计划文案")
        XCTAssertTrue(emitted.contains("重规划："))
        // ③ 回退计划只含 原型 → PRD（局部下游）
        XCTAssertTrue(emitted.contains("交互原型 → 产品需求文档"))
        XCTAssertFalse(emitted.contains("功能架构图"), "③ 回退不连带结构产物")
    }

    @MainActor
    func testPresentProposalDegradesUnverifiableTarget() throws {
        let model = AppModel()
        model.selection = .session(project: project, version: "v1", sessionId: "s3")
        // target=structure 但 impacts 全是模糊文本 → 降级为仅登记（target 置空）
        let request = ArtifactParser.BacktrackRequest(
            suggestion: "now", target: "structure", idea: "整体体验优化",
            category: "需验证", impacts: ["感觉信息架构有点乱"],
            instruction: nil, mode: "revise"
        )
        model.presentChangeProposal(request)

        let items = ChangeLedger.load(project: project, version: "v1")
        let proposal = try XCTUnwrap(items.first?.proposal)
        XCTAssertNil(proposal.target, "零可解析引用 → 不采信回退目标（降级仅登记）")
        XCTAssertFalse(proposal.idea.isEmpty, "想法本身保留")
    }
}
