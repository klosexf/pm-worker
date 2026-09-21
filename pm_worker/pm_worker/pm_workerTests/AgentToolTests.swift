//
//  AgentToolTests.swift
//  pm_workerTests
//
//  AgentTool 层（@MainActor 协议）：三工具执行器 + 注册表。
//  闭包注入 mock；测试不触网——WebSearch 未配置 endpoint 时在 Keychain
//  读取之前即返回人话文本（实现顺序保证）。
//

import XCTest
@testable import pm_worker

@MainActor
final class AgentToolTests: XCTestCase {

    private func makeContext(
        searchEndpoint: String = "",
        isReleased: Bool = false,
        skillSearch: @escaping (String) -> [(id: String, docPath: String)] = { _ in [] },
        submitAnalysis: @escaping (String) -> Void = { _ in }
    ) -> AgentToolContext {
        AgentToolContext(
            settings: LLMSettings(stages: [:], maxTokensPerRun: 1000, searchEndpoint: searchEndpoint),
            project: "p", version: "v1.0", sessionId: "s",
            isReleased: isReleased,
            skillSearch: skillSearch,
            submitAnalysis: submitAnalysis
        )
    }

    // MARK: - load_skill

    func testLoadSkillLoadsBodyFromDocPath() async {
        let dir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("skill-\(UUID().uuidString).md")
        try? "---\nname: KANO\n---\n正文第一行\n正文第二行".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tool = LoadSkillTool()
        let result = await tool.execute(
            argumentsJSON: "{\"query\":\"KANO\"}",
            ctx: makeContext(skillSearch: { _ in [(id: "kano", docPath: url.path)] })
        )
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.forLLM.contains("正文第一行"))
        // front-matter 已剥离
        XCTAssertFalse(result.forLLM.contains("name: KANO"))
        XCTAssertEqual(result.forHuman, "加载技能「kano」")
    }

    func testLoadSkillMissReturnsGuidance() async {
        let tool = LoadSkillTool()
        let result = await tool.execute(
            argumentsJSON: "{\"query\":\"不存在\"}",
            ctx: makeContext()
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("未找到"))
    }

    func testLoadSkillMissingQueryFails() async {
        let tool = LoadSkillTool()
        let result = await tool.execute(argumentsJSON: "{}", ctx: makeContext())
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("参数缺失"))
    }

    // MARK: - web_search（不触网：endpoint 空 → 配置提示；缺参 → 参数提示）

    func testWebSearchUnconfiguredReturnsHumanGuidance() async {
        let tool = WebSearchTool()
        let result = await tool.execute(
            argumentsJSON: "{\"query\":\"竞品\"}",
            ctx: makeContext(searchEndpoint: "")
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("搜索源未配置"))
        XCTAssertTrue(result.forHuman.contains("未配置"))
    }

    func testWebSearchMissingQueryFails() async {
        let tool = WebSearchTool()
        let result = await tool.execute(argumentsJSON: "{}", ctx: makeContext())
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("参数缺失"))
    }

    // MARK: - propose_competitive_analysis

    func testProposeAnalysisSubmitsConfirmation() async {
        var submitted: String?
        let tool = ProposeAnalysisTool()
        let result = await tool.execute(
            argumentsJSON: "{\"query\":\"Notion 类工具\"}",
            ctx: makeContext { submitted = $0 }
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(submitted, "Notion 类工具")
        XCTAssertTrue(result.forLLM.contains("确认"))
    }

    func testProposeAnalysisRejectedWhenReleased() async {
        var submitted: String?
        let tool = ProposeAnalysisTool()
        let result = await tool.execute(
            argumentsJSON: "{\"query\":\"Notion\"}",
            ctx: makeContext(isReleased: true) { submitted = $0 }
        )
        XCTAssertFalse(result.ok)
        XCTAssertNil(submitted)
        XCTAssertTrue(result.forLLM.contains("封板"))
    }

    // MARK: - query_impact（产物依赖图查询：纯本地计算，零磁盘零网络）

    func testQueryImpactDownstreamOrdered() async {
        let tool = DependencyQueryTool()
        let result = await tool.execute(
            argumentsJSON: "{\"seeds\":[\"核心流程图\"]}",
            ctx: makeContext()
        )
        XCTAssertTrue(result.ok)
        // 下游 = 交互原型 → 产品需求文档（重做顺序：原型在前 PRD 在后）
        XCTAssertTrue(result.forLLM.contains("交互原型"))
        XCTAssertTrue(result.forLLM.contains("产品需求文档"))
        let prototypeRange = result.forLLM.range(of: "交互原型")
        let prdRange = result.forLLM.range(of: "产品需求文档")
        XCTAssertLessThan(prototypeRange!.lowerBound, prdRange!.lowerBound, "按重做顺序排列")
        XCTAssertTrue(result.forHuman.contains("2 个下游"))
    }

    func testQueryImpactMixedSeedsDedupeClosure() async {
        let tool = DependencyQueryTool()
        // PRD（茎匹配）+ 映射表（路径）→ 并集闭包，PRD 不因双重 seed 重复
        let result = await tool.execute(
            argumentsJSON: "{\"seeds\":[\"PRD · 发布计划章节\",\"02-structure/模块-页面映射表.md\"]}",
            ctx: makeContext()
        )
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.forLLM.contains("交互原型"))
        XCTAssertTrue(result.forLLM.contains("产品需求文档"))
        XCTAssertFalse(result.forLLM.contains("未识别"), "两个引用都应可解析")
    }

    func testQueryImpactNoDownstream() async {
        let tool = DependencyQueryTool()
        let result = await tool.execute(
            argumentsJSON: "{\"seeds\":[\"功能架构图\"]}",
            ctx: makeContext()
        )
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.forLLM.contains("没有下游依赖"), "信息性参考产物无下游")
        XCTAssertTrue(result.forHuman.contains("无下游"))
    }

    func testQueryImpactUnrecognizedReference() async {
        let tool = DependencyQueryTool()
        let result = await tool.execute(
            argumentsJSON: "{\"seeds\":[\"不存在的产物\"]}",
            ctx: makeContext()
        )
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.forLLM.contains("未识别"))
        XCTAssertTrue(result.forLLM.contains("可用产物名"), "未识别时给菜单纠偏")
    }

    func testQueryImpactMissingSeedsFails() async {
        let tool = DependencyQueryTool()
        let result = await tool.execute(argumentsJSON: "{}", ctx: makeContext())
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("参数缺失"))
    }

    // MARK: - 注册表

    func testRegistryUnknownToolAndDefinitions() async {
        let registry = AgentToolRegistry(tools: [
            LoadSkillTool(), WebSearchTool(), ProposeAnalysisTool(), DependencyQueryTool(),
        ])
        let result = await registry.execute(
            name: "nope", argumentsJSON: "{}", ctx: makeContext()
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.forLLM.contains("未知工具"))
        XCTAssertTrue(result.forLLM.contains("load_skill"))

        let names = registry.definitions().map(\.function.name)
        // 排序稳定（新增 query_impact 后四工具齐）
        XCTAssertEqual(
            names,
            ["load_skill", "propose_competitive_analysis", "query_impact", "web_search"]
        )
        XCTAssertEqual(registry.definitions().first?.type, "function")
    }
}
