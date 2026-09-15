//
//  HarnessUpgradeTests.swift
//  pm_workerTests
//
//  harness 借鉴四件套的单元测试：
//  ① 澄清质量门判定 / ② 历史滚动摘要（splitByBudget 纯函数族）
//  / ④ 机器门（Tier1 确定性检查 + stageJudge prompt + GateVerdict 解码）。
//

import XCTest
@testable import pm_worker

final class HarnessUpgradeTests: XCTestCase {

    private let project = "harness升级测试项目"
    private let version = "v1.0"
    /// 磁盘隔离：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/
    /// （此套件 setUp 会整目录删除同名项目——曾把用户真实会话一并清掉）。
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        // 清残留：上轮运行落盘的产物会让「全缺失」类断言失效
        try? FileManager.default.removeItem(at: PMAgentStore.projectURL(project))
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    private func versionDir() -> URL {
        PMAgentStore.versionURL(project: project, version: version)
    }

    // MARK: - ② splitByBudget（trimmedHistory 伴生：保留段 + 被丢段）

    func testSplitByBudgetPartition() {
        // kept + dropped 恒等于原始（无 system 时）
        var messages: [ChatMessage] = []
        for i in 1...6 {
            messages.append(ChatMessage(role: .user, content: "用户消息\(i)这是一段足够长的内容用于撑预算"))
            messages.append(ChatMessage(role: .assistant, content: "助手回答\(i)同样是一段足够长的内容"))
        }
        let (kept, dropped) = SessionStore.splitByBudget(messages, budget: 200)
        // dropped = 最旧整轮在前，kept = 最新轮在后，拼接恒等于原始序列
        XCTAssertEqual(dropped + kept, messages)
        XCTAssertFalse(dropped.isEmpty)
        // 丢的是最旧整轮（成对）
        XCTAssertEqual(dropped.first?.content.hasPrefix("用户消息1"), true)
        // 保的是最新轮
        XCTAssertEqual(kept.last?.content.hasPrefix("助手回答6"), true)
    }

    func testSplitByBudgetUnderBudgetNoDrop() {
        let messages = [
            ChatMessage(role: .system, content: "阶段提示词"),
            ChatMessage(role: .user, content: "你好"),
            ChatMessage(role: .assistant, content: "你好，请问想做什么产品？"),
        ]
        let (kept, dropped) = SessionStore.splitByBudget(messages, budget: 10_000)
        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(kept, messages)
    }

    func testSplitByBudgetZeroBudget() {
        let messages = [
            ChatMessage(role: .system, content: "阶段提示词"),
            ChatMessage(role: .user, content: "你好"),
        ]
        let (kept, dropped) = SessionStore.splitByBudget(messages, budget: 0)
        XCTAssertEqual(kept.map(\.role), [.system])
        XCTAssertEqual(dropped.map(\.role), [.user])
    }

    func testDroppedBoundaryChangesWhenHistoryGrows() {
        func msg(_ i: Int) -> ChatMessage {
            ChatMessage(role: .user, content: "轮次\(i)的较长内容用于区分边界签名")
        }
        let small = [msg(1), msg(2)]
        let grown = [msg(1), msg(2), msg(3)]
        // append-only：前缀一致时旧签名是新签名的前缀；不同边界签名必不同
        XCTAssertNotEqual(
            SessionStore.droppedBoundary(small),
            SessionStore.droppedBoundary(grown)
        )
        XCTAssertEqual(SessionStore.droppedBoundary([]), "empty")
    }

    func testHistoryWithSummaryPlacesSummaryAfterSystem() {
        let kept = [
            ChatMessage(role: .system, content: "阶段提示词"),
            ChatMessage(role: .user, content: "最近的问题"),
        ]
        let result = SessionStore.historyWithSummary(
            kept: kept, summary: "前三轮澄清了目标用户与付费意愿"
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].role, .system)
        XCTAssertEqual(result[1].role, .user)
        XCTAssertTrue(result[1].content.contains("前情摘要"))
        XCTAssertTrue(result[1].content.contains("目标用户"))
        XCTAssertEqual(result[2].content, "最近的问题")
    }

    func testCompactSummaryPromptIncludesPreviousAndTranscript() {
        let prompt = SessionStore.compactSummaryPrompt(
            previous: "旧摘要：目标用户为独立开发者",
            transcript: "用户：我想要一个笔记工具"
        )
        XCTAssertTrue(prompt.contains("已有摘要"))
        XCTAssertTrue(prompt.contains("目标用户为独立开发者"))
        XCTAssertTrue(prompt.contains("笔记工具"))
        XCTAssertTrue(prompt.contains("5-8 行要点"))
        // 首次压缩（无旧摘要）不含旧摘要段
        let first = SessionStore.compactSummaryPrompt(previous: "", transcript: "用户：你好")
        XCTAssertFalse(first.contains("已有摘要"))
    }

    // MARK: - ④ 机器门

    func testStageJudgePromptContainsRubricAndContract() {
        let prompt = AgentPrompts.stageJudge(
            stage: "structure", artifacts: "graph TD\nA --> B"
        )
        // rubric 来自 stageChecklist（与自评审共用）
        XCTAssertTrue(prompt.contains("核心场景覆盖度"))
        XCTAssertTrue(prompt.contains("与澄清要点一致"))
        // 独立性声明 + JSON 契约
        XCTAssertTrue(prompt.contains("独立质量评审"))
        XCTAssertTrue(prompt.contains("不继承其任何假设"))
        XCTAssertTrue(prompt.contains(#""pass""#))
        // 待审产物注入
        XCTAssertTrue(prompt.contains("graph TD"))
    }

    func testGateVerdictLenientDecode() {
        // 完整 JSON
        let full = """
        {"pass": false, "issues": ["流程图存在断头路"], "verdict": "不通过"}
        """
        let v1 = LenientJSON.decode(AgentPrompts.GateVerdict.self, from: full)
        XCTAssertEqual(v1?.pass, false)
        XCTAssertEqual(v1?.issues?.count, 1)
        XCTAssertEqual(v1?.verdict, "不通过")

        // 模型省略 issues/verdict（宽松可选）
        let sparse = """
        {"pass": true}
        """
        let v2 = LenientJSON.decode(AgentPrompts.GateVerdict.self, from: sparse)
        XCTAssertEqual(v2?.pass, true)
        XCTAssertNil(v2?.issues)
    }

    func testTier1StructureChecks() throws {
        let dir = versionDir()
        // 全缺失 → 三条缺失问题
        var issues = AppModel.tier1Issues(
            stage: .structure, project: project, version: version
        )
        XCTAssertEqual(issues.count, 3)
        XCTAssertTrue(issues.allSatisfy { $0.contains("缺失或为空") })

        // 补齐三项合法产物 → 零问题
        try PMAgentStore.writeVerified(
            "# 功能架构图\n\n```mermaid\ngraph TD\nA --> B\n```\n",
            to: dir.appendingPathComponent(ArtifactPath.architecture)
        )
        try PMAgentStore.writeVerified(
            "# 核心流程图\n\n```mermaid\nflowchart TD\nA --> B\n```\n",
            to: dir.appendingPathComponent(ArtifactPath.coreFlows)
        )
        try PMAgentStore.writeVerified(
            "# 模块-页面映射表\n\n| 模块 | 原型页面 | 页面说明 |\n| --- | --- | --- |\n| 首页 | home | 入口 |\n",
            to: dir.appendingPathComponent(ArtifactPath.modulePageMap)
        )
        issues = AppModel.tier1Issues(
            stage: .structure, project: project, version: version
        )
        XCTAssertTrue(issues.isEmpty)

        // Mermaid 声明缺失 → 报问题
        try PMAgentStore.writeVerified(
            "# 功能架构图\n\nA --> B\n",
            to: dir.appendingPathComponent(ArtifactPath.architecture)
        )
        issues = AppModel.tier1Issues(
            stage: .structure, project: project, version: version
        )
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("Mermaid"))
    }

    func testTier1PrototypeChecks() throws {
        let dir = versionDir()
        // CDN 引用 → 外部依赖问题 + 空壳问题（<2KB）
        let tiny = "<html><head><script src=\"https://cdn.example.com/x.js\"></script></head><body>hi</body></html>"
        try PMAgentStore.writeVerified(
            tiny, to: dir.appendingPathComponent(ArtifactPath.prototype)
        )
        var issues = AppModel.tier1Issues(
            stage: .prototype, project: project, version: version
        )
        XCTAssertTrue(issues.contains { $0.contains("外部资源引用") })
        XCTAssertTrue(issues.contains { $0.contains("空壳") })

        // 干净的本地大原型 → 零问题
        let body = String(repeating: "<div class='page'>页面内容占位</div>", count: 120)
        let clean = "<html><head><style>.page{margin:0}</style></head><body>\(body)</body></html>"
        try PMAgentStore.writeVerified(
            clean, to: dir.appendingPathComponent(ArtifactPath.prototype)
        )
        issues = AppModel.tier1Issues(
            stage: .prototype, project: project, version: version
        )
        XCTAssertTrue(issues.isEmpty)

        // 协议内联链接（http:// 出现在正文文本，非资源加载）不误报
        let inline = clean.replacingOccurrences(
            of: "页面内容占位", with: "详见 http://example.com 文档"
        )
        try PMAgentStore.writeVerified(
            inline, to: dir.appendingPathComponent(ArtifactPath.prototype)
        )
        issues = AppModel.tier1Issues(
            stage: .prototype, project: project, version: version
        )
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - ① 质量门（纯判定逻辑）

    func testClarifyPromptMentionsQualityGate() {
        // 质量门契约进入 clarify prompt 冻结段（模型诚实填 missing 的激励）
        let prompt = AgentPrompts.clarify(rounds: 2, limit: 5, injection: "")
        XCTAssertTrue(prompt.contains("质量门"))
        XCTAssertTrue(prompt.contains("禁止为凑轮次虚构缺项"))
    }

    func testClarifyPromptMentionsAmbiguityDecomposition() {
        // 含混请求拆解内建澄清 prompt（skills-inventory §4.3 P1 · incoming-request-advisor
        // 二选一裁决：每轮必读走确定性注入，不做语义检索的独立技能卡）
        let prompt = AgentPrompts.clarify(rounds: 2, limit: 5, injection: "")
        XCTAssertTrue(prompt.contains("含混请求拆解"))
        XCTAssertTrue(prompt.contains("真实任务"))
    }

    func testClarifyPromptMentionsDiscussionAndFirstPrinciples() {
        // 正面回答讨论 + 主动建议 + 第一性原理三条契约进入 clarify prompt 冻结段；
        // 自检 rubric 同步兜底（模型自评可查）
        let prompt = AgentPrompts.clarify(rounds: 2, limit: 5, injection: "")
        XCTAssertTrue(prompt.contains("正面回答讨论"))
        XCTAssertTrue(prompt.contains("不回避、不绕到提问"))
        XCTAssertTrue(prompt.contains("主动提出你的建议和想法"))
        XCTAssertTrue(prompt.contains("第一性原理"))
        XCTAssertTrue(prompt.contains("本质目的"))
        let checklist = AgentPrompts.stageChecklist("clarify")
        XCTAssertTrue(checklist.contains("第一性原理"))
        XCTAssertTrue(checklist.contains("正面充分回答"))
    }

    func testClarifyPromptCoreBehaviorConstraints() {
        // 核心行为约束五条契约（需求穿透+小白视角 / 先排问题 / 延伸 / 开工前对齐 / 说人话）
        // 进入 clarify prompt 冻结段；自检 rubric 同步兜底
        let prompt = AgentPrompts.clarify(rounds: 2, limit: 5, injection: "")
        XCTAssertTrue(prompt.contains("需求穿透"))                 // 约束 11
        XCTAssertTrue(prompt.contains("如果长辈第一次用会怎样"))     // 小白视角检验标准
        XCTAssertTrue(prompt.contains("先排问题，不排功能"))         // 约束 12
        XCTAssertTrue(prompt.contains("Painkiller"))               // 止痛药判断标准
        XCTAssertTrue(prompt.contains("第二视角延伸"))              // 约束 13
        XCTAssertTrue(prompt.contains("开工前对齐"))                // 约束 14 门禁
        XCTAssertTrue(prompt.contains("若 XX 是 A → 答案偏向 P"))   // 敏感度映射强制格式
        XCTAssertTrue(prompt.contains("唯一关键问题"))              // 单问题门禁
        XCTAssertTrue(prompt.contains("别问了直接给"))              // 逃生阀
        XCTAssertTrue(prompt.contains("防锚定"))                    // 第一性原理增强
        XCTAssertTrue(prompt.contains("赋能 / 抓手 / 打法"))         // 说人话禁词
        let checklist = AgentPrompts.stageChecklist("clarify")
        XCTAssertTrue(checklist.contains("小白视角"))
        XCTAssertTrue(checklist.contains("Painkiller"))
        XCTAssertTrue(checklist.contains("开工前对齐"))
    }
}
