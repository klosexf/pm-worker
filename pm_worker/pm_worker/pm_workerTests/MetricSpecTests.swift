//
//  MetricSpecTests.swift
//  pm_workerTests
//
//  指标口径卡（artifact:metric-specs → 04-prd/metric-specs.jsonl）：
//  - 容错解码：模型不写 id/时间戳、status 写中文、空串当缺项，都不许让整批口径丢
//  - 归一化：同名后写覆盖；口径不齐全强制降 pending（confirmed 只能由用户确认得到）
//  - 落盘与读取：文件不存在即建；append-only；跨修订轮按 name last-wins 折叠
//  - 可对账判据：confirmed 且分子/分母/时间窗三项齐
//  - stray 谓词（B005 纪律：非 ④ 阶段携带该块不许静默）
//  - 评审输入渲染 + prompt 契约与三档模板口径段
//

import XCTest
@testable import pm_worker

final class MetricSpecTests: XCTestCase {

    private let project = "指标口径测试项目"
    private let version = "v1.0"
    /// 磁盘隔离：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/。
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func blocks(_ name: String, _ body: String) -> [ArtifactParser.ArtifactBlock] {
        ArtifactParser.parseArtifactBlocks(in: "```artifact:\(name)\n\(body)\n```")
    }

    private let fullSpecJSON = """
        [{"name":"次日留存率","dataSource":"App 埋点 dau 表",\
        "numerator":"注册次日仍打开 App 的去重用户数","denominator":"当日注册新增用户数",\
        "window":"自然日 00:00-24:00，按 device_id 去重","exclusions":"剔除内测账号",\
        "status":"confirmed"}]
        """

    // MARK: - 容错解码

    func testDecodesWithoutIDOrTimestamps() throws {
        // 模型只写业务字段：id / createdAt / updatedAt 缺省不得让整批失败
        let specs = try XCTUnwrap(
            ArtifactParser.parseMetricSpecs(blocks: blocks("metric-specs", fullSpecJSON))
        )
        XCTAssertEqual(specs.count, 1)
        let spec = try XCTUnwrap(specs.first)
        XCTAssertEqual(spec.name, "次日留存率")
        XCTAssertEqual(spec.status, .confirmed)
        XCTAssertFalse(spec.id.isEmpty)
        XCTAssertFalse(spec.createdAt.isEmpty)
        XCTAssertTrue(spec.reconcilable)
    }

    func testChineseStatusIsAccepted() throws {
        // 带齐核心三项，才不会被「口径不全 → 强制 pending」的归一化规则盖掉解析结果
        let specs = ArtifactParser.parseMetricSpecs(
            blocks: blocks("metric-specs",
                           #"[{"name":"付费率","numerator":"a","denominator":"b","window":"c","status":"已确认"}]"#)
        )
        XCTAssertEqual(specs?.first?.status, .confirmed)
    }

    func testMissingStatusDerivesAssumedNeverConfirmed() throws {
        // 口径三项齐但没写状态 → 起草态；绝不能自动升成已确认
        let complete = ArtifactParser.parseMetricSpecs(
            blocks: blocks("metric-specs", #"[{"name":"留存","numerator":"a","denominator":"b","window":"c"}]"#)
        )
        XCTAssertEqual(complete?.first?.status, .assumed)
        XCTAssertEqual(complete?.first?.reconcilable, false)
        // 口径不齐 → pending
        let partial = ArtifactParser.parseMetricSpecs(
            blocks: blocks("metric-specs", #"[{"name":"留存","numerator":"a"}]"#)
        )
        XCTAssertEqual(partial?.first?.status, .pending)
    }

    func testEmptyStringsDecodeAsMissing() throws {
        let spec = try XCTUnwrap(
            ArtifactParser.parseMetricSpecs(
                blocks: blocks("metric-specs", #"[{"name":"留存","numerator":"a","denominator":"","window":null}]"#)
            )?.first
        )
        XCTAssertNil(spec.denominator, "空串须视为缺项，否则 missingFields 会漏报")
        XCTAssertEqual(spec.missingFields, ["数据来源", "分母", "时间窗"])
    }

    func testParseReturnsNilForAbsentOrUnusable() {
        XCTAssertNil(ArtifactParser.parseMetricSpecs(blocks: []), "无块是合法缺省")
        XCTAssertNil(ArtifactParser.parseMetricSpecs(blocks: blocks("metric-specs", "不是 JSON")))
        XCTAssertNil(ArtifactParser.parseMetricSpecs(blocks: blocks("metric-specs", "[]")))
        XCTAssertNil(
            ArtifactParser.parseMetricSpecs(blocks: blocks("metric-specs", #"[{"name":"  "}]"#)),
            "全部条目无指标名 → 视为无口径记录"
        )
    }

    // MARK: - 归一化

    func testSameNameKeepsLastWriteAtFirstPosition() throws {
        let json = """
            [{"name":"次日留存率","numerator":"旧","denominator":"旧","window":"旧"},\
            {"name":"7 日留存","numerator":"b","denominator":"c","window":"d"},\
            {"name":"次日留存率","numerator":"新","denominator":"新","window":"新","status":"confirmed"}]
            """
        let specs = try XCTUnwrap(ArtifactParser.parseMetricSpecs(blocks: blocks("metric-specs", json)))
        XCTAssertEqual(specs.map(\.name), ["次日留存率", "7 日留存"], "同名不得并列两条，且保持首次出现顺序")
        XCTAssertEqual(specs.first?.numerator, "新")
        XCTAssertEqual(specs.first?.status, .confirmed)
    }

    func testWhitespaceVarianceStillDedupes() {
        let json = """
            [{"name":"次日 留存率","numerator":"a","denominator":"b","window":"c"},\
            {"name":"次日留存率","numerator":"d","denominator":"e","window":"f","status":"confirmed"}]
            """
        let specs = ArtifactParser.parseMetricSpecs(blocks: blocks("metric-specs", json))
        XCTAssertEqual(specs?.count, 1, "空白差异是重播微差的主要形态")
        XCTAssertEqual(specs?.first?.status, .confirmed)
    }

    func testIncompleteSpecCannotStayConfirmed() throws {
        // 自称 confirmed 但缺分母 → 归一化降级，否则 C 环会拿不可比数字出对账结论
        let specs = try XCTUnwrap(ArtifactParser.parseMetricSpecs(
            blocks: blocks("metric-specs", #"[{"name":"留存","numerator":"a","window":"c","status":"confirmed"}]"#)
        ))
        XCTAssertEqual(specs.first?.status, .pending)
        XCTAssertFalse(specs.first!.reconcilable)
    }

    // MARK: - 落盘与读取

    func testWriteCreatesFileAndFoldsLastWins() throws {
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: specURL.path
        ), "前置：新版本无口径文件")

        let written = ArtifactParser.writeMetricSpecs(
            blocks: blocks("metric-specs", fullSpecJSON), project: project, version: version
        )
        XCTAssertEqual(written?.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: specURL.path), "appendLine 要求文件先存在")

        // 修订轮改口径：同一指标第二次登记覆盖首次
        let revision = #"[{"name":"次日留存率","numerator":"改后","denominator":"当日注册","window":"滚动 7 日","status":"confirmed"}]"#
        ArtifactParser.writeMetricSpecs(
            blocks: blocks("metric-specs", revision), project: project, version: version
        )
        let current = ArtifactParser.readMetricSpecs(project: project, version: version)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.numerator, "改后")
        // 原始两行都还在盘上（append-only，历史可查）
        let raw = try String(contentsOf: specURL, encoding: .utf8)
        XCTAssertEqual(raw.trimmingCharacters(in: .newlines)
            .split(separator: "\n").count, 2)
    }

    func testWriteIsNoOpWithoutBlock() throws {
        let before = ArtifactParser.readMetricSpecs(project: project, version: version)
        XCTAssertNil(ArtifactParser.writeMetricSpecs(blocks: [], project: project, version: version))
        XCTAssertTrue(before.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: specURL.path), "无块不得凭空建文件")
    }

    func testReadOnMissingFileReturnsEmpty() {
        XCTAssertEqual(ArtifactParser.readMetricSpecs(project: project, version: version), [])
    }

    // MARK: - stray 谓词（B005：本阶段无消费者也不许静默）

    func testStrayDetectionCoversClosedAndIncomplete() {
        let closed = blocks("metric-specs", fullSpecJSON)
        XCTAssertTrue(ArtifactParser.hasStrayMetricSpecsBlock(blocks: closed, text: ""))
        XCTAssertFalse(ArtifactParser.hasStrayMetricSpecsBlock(blocks: [], text: "普通回复"))
        // 未闭合围栏（截断）也算
        let unclosed = "先写两句\n```artifact:metric-specs\n[{\"name\":\"留存\""
        XCTAssertTrue(
            ArtifactParser.hasStrayMetricSpecsBlock(blocks: [], text: unclosed),
            "截断的口径块同样不能静默"
        )
        // 别的块不算
        XCTAssertFalse(ArtifactParser.hasStrayMetricSpecsBlock(
            blocks: blocks("radar", #"{"covered":[]}"#), text: ""
        ))
    }

    func testMetricSpecsBlockStrippedFromDisplayBody() {
        // 正文剥离走通配正则 → 未知块名不会把 JSON 原样刷进气泡
        let text = "正文\n```artifact:metric-specs\n[{\"name\":\"留存\"}]\n```\n收尾"
        let stripped = ArtifactParser.stripArtifactBlocks(in: text)
        XCTAssertFalse(stripped.contains("metric-specs"))
        XCTAssertTrue(stripped.contains("正文"))
    }

    // MARK: - 独立评审输入

    func testJudgeRenderAbsentThenPresent() {
        XCTAssertNil(ArtifactParser.renderMetricSpecsForJudge(project: project, version: version),
                     "无记录时评审材料不带该段，不写「（缺失）」诱导扣分")
        ArtifactParser.writeMetricSpecs(
            blocks: blocks("metric-specs", fullSpecJSON), project: project, version: version
        )
        let rendered = try? XCTUnwrap(
            ArtifactParser.renderMetricSpecsForJudge(project: project, version: version)
        )
        XCTAssertTrue(rendered?.contains("次日留存率") == true)
        XCTAssertTrue(rendered?.contains("已确认") == true)
    }

    // MARK: - 口径引用槽缝合（正文的唯一作者 = 记录）

    private let stitchedSpec = MetricSpec(
        name: "次日留存率", dataSource: "App 埋点 dau 表",
        numerator: "次日内再次打开的去重设备数", denominator: "当日注册新增设备数",
        window: "自然日，device_id 去重", exclusions: "剔除内测账号",
        status: .assumed, assumptionNote: "去重键按常见做法起草"
    )

    func testStitchRendersRecordIntoSlot() {
        let body = "| 次日留存率 | — | 45% | T+30 | [[SPEC:次日留存率]] | 留存 |"
        let out = ArtifactParser.stitchSpecSlots(in: body, specs: [stitchedSpec])
        XCTAssertEqual(out.resolvedCount, 1)
        XCTAssertTrue(out.unresolvedSlots.isEmpty)
        XCTAssertFalse(out.text.contains("[[SPEC:"), "槽必须被吃掉，否则文档里留的是内部语法")
        XCTAssertTrue(out.text.contains("分子 = 次日内再次打开的去重设备数"))
        XCTAssertTrue(out.text.contains("分母 = 当日注册新增设备数"))
        XCTAssertTrue(out.text.contains("剔除内测账号"))
        XCTAssertTrue(out.text.contains("待你确认"))
        XCTAssertTrue(out.text.contains("| 45% |"), "其余列原样保留，只替换口径那一格")
    }

    func testStitchToleratesNameWhitespaceVariance() {
        let out = ArtifactParser.stitchSpecSlots(
            in: "口径：[[SPEC: 次日 留存率 ]]", specs: [stitchedSpec]
        )
        XCTAssertEqual(out.resolvedCount, 1, "槽名带空格/中文重播微差也要命中")
    }

    func testStitchUnresolvedWarnsVisibly() {
        let out = ArtifactParser.stitchSpecSlots(in: "[[SPEC:付费率]]", specs: [stitchedSpec])
        XCTAssertEqual(out.unresolvedSlots.count, 1)
        XCTAssertTrue(out.text.contains("⚠️ 口径未登记"))
        XCTAssertTrue(out.text.contains("付费率"), "警示里要看得出是哪个指标没登记")
    }

    func testStitchIsNoOpWithoutSlots() {
        let body = "没有槽的正文"
        let out = ArtifactParser.stitchSpecSlots(in: body, specs: [])
        XCTAssertEqual(out.text, body)
        XCTAssertEqual(out.resolvedCount, 0)
    }

    func testRenderSpecLineCarriesNoAssumptionProseOrTargetNumber() {
        let line = ArtifactParser.renderSpecLine(stitchedSpec)
        XCTAssertFalse(line.contains("去重键按常见做法起草"), "假设说明不进正文——它会引用用户给的目标值")
        XCTAssertFalse(line.contains("45"), "渲染行不得出现目标值")
        XCTAssertTrue(line.contains("此口径为 Agent 起草"))
    }

    func testRenderSpecLineForPartialPending() {
        let line = ArtifactParser.renderSpecLine(MetricSpec(name: "x", numerator: "a"))
        XCTAssertTrue(line.contains("分子 = a"))
        XCTAssertTrue(line.contains("口径不全"))
    }

    /// 端到端：PRD 落盘时槽被本轮记录块渲染；修订轮只重出 PRD（漏带记录块）时退到盘上记录。
    func testWritePRDArtifactStitchesFromBlockThenFromDisk() throws {
        let prdBody = """
            ## 四、产品目标与成功指标
            ### 4.2 北极星指标
            | 指标 | 基线 | 目标值 | 测量时间点 | 口径 | 对应目标 |
            |---|---|---|---|---|---|
            | 次日留存率 | 无 | 45% | T+30 | [[SPEC:次日留存率]] | 留存 |
            """ + String(repeating: "\n填充行，用于越过 PRD 正文 200 字符的有效性门槛。", count: 8)

        // 第一轮：正文 + 记录块同轮
        let first = try XCTUnwrap(ArtifactParser.writePRDArtifact(
            blocks: [
                ArtifactParser.ArtifactBlock(name: "prd", content: prdBody),
                ArtifactParser.ArtifactBlock(name: "metric-specs", content: fullSpecJSON),
            ],
            tier: "standard", project: project, version: version
        ))
        let written = try String(contentsOf: first.url, encoding: .utf8)
        XCTAssertFalse(written.contains("[[SPEC:"), "落盘后不该残留槽")
        XCTAssertTrue(written.contains("注册次日仍打开 App 的去重用户数"), "口径须由记录块渲染进表格")

        // 第二轮：只重出 PRD（模型漏带记录块）→ 退到盘上现有记录，仍不得残留裸槽
        let second = try XCTUnwrap(ArtifactParser.writePRDArtifact(
            blocks: [ArtifactParser.ArtifactBlock(name: "prd", content: prdBody)],
            tier: "standard", project: project, version: version
        ))
        let rewritten = try String(contentsOf: second.url, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("[[SPEC:"), "缺记录块时也要从盘上取，不能把裸槽落进文档")
    }

    // MARK: - 契约（prompt 与三档模板）

    func testPRDPromptCarriesMetricSpecsContract() {
        let prompt = AgentPrompts.prd(
            tier: "standard", clarification: "要点", modulePageMap: "| 模块 | 页面 |",
            architecture: "graph TD", coreFlows: "A --> B",
            prototypePages: ["首页"], analysisNotes: "", injection: ""
        )
        XCTAssertTrue(prompt.contains("artifact:metric-specs"))
        XCTAssertTrue(prompt.contains("[[SPEC:"), "正文只写引用槽的约定必须在 prompt 里")
        XCTAssertTrue(prompt.contains("assumptionNote"))
    }

    func testDefaultsCardForcesSpecConfirmation() {
        let card = AgentPrompts.prdDefaultsCardSection()
        XCTAssertTrue(card.contains("指标口径优先占位"))
        XCTAssertTrue(card.contains("confirmed"), "用户确认后须把状态升上来")
    }

    func testPRDChecklistCoversSpecs() {
        let checklist = AgentPrompts.stageChecklist("prd")
        XCTAssertTrue(checklist.contains("指标口径"))
        XCTAssertTrue(checklist.contains("[[SPEC:"), "残留未渲染槽要能被独立评审判成缺陷")
    }

    func testAllTiersDeclareFifthStepAndBumpVersion() throws {
        for tier in ["lean", "standard", "full"] {
            let template = AgentPrompts.prdTemplate(tier: tier)
            XCTAssertFalse(
                template.contains("（模板缺失"),
                "\(tier) 档模板未打进 bundle，资源口径变了要先修测试环境"
            )
            XCTAssertTrue(template.contains("[[SPEC:"), "\(tier) 档 4.2 未改成引用槽写法")
            XCTAssertEqual(AgentPrompts.prdTemplateVersion(tier: tier), "3",
                           "\(tier) 档改了内容必须升版本戳，否则存量 PRD 逃过失效检查")
        }
    }

    // MARK: - 私有

    private var specURL: URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(ArtifactPath.metricSpecs)
    }
}
