//
//  MetricSpecsLiveProbeTests.swift
//  pm_workerTests
//
//  ④ 环第 ⑤ 步（指标口径）的 live 探针：真打一次模型，验的是「模型那头」——
//  `MetricSpecTests` 只锁住了契约文本与落盘逻辑，模型是否**愿意**按协议出口径块、
//  是否守住「只存口径不存数值」、缺口径时是否真走默认项卡，全部未经证实。
//
//  默认跳过——live 调用产生真实费用。跑法（TEST_RUNNER_ 前缀必需：xcodebuild
//  不透传普通环境变量到测试进程，直接前缀赋值会被静默跳过）：
//    TEST_RUNNER_PM_LIVE_SPEC=1 xcodebuild -project pm_worker.xcodeproj \
//      -scheme pm_worker -destination 'platform=macOS' test \
//      -parallel-testing-enabled NO -only-testing:pm_workerTests/MetricSpecsLiveProbeTests
//
//  保真度口径同 EvalRunnerTests：裸阶段 prompt，不含规则 / 记忆 / 技能 / 检索横切注入，
//  因此结论是生产环境的**保守下界**（生产里还多一层注入，只会更利于遵守协议）。
//  原文一律落 evals/results/ 供人工复核——不只看断言绿灯。
//

import XCTest
@testable import pm_worker

final class MetricSpecsLiveProbeTests: XCTestCase {

    private static let gateKey = "PM_LIVE_SPEC"
    /// lean 档整篇 PRD + 自评块；思考型模型的 reasoning 也吃这个池，给足。
    private static let maxTokens = 16000
    /// 用户口述过的目标值字面——它绝不允许出现在口径块里（数值事实源是 4.2 表）。
    private static let userStatedTarget = "45%"

    func testPRDEmitsUsableMetricSpecs() async throws {
        guard ProcessInfo.processInfo.environment[Self.gateKey] == "1" else {
            throw XCTSkip("未设 \(Self.gateKey)=1——live 探针默认跳过（真实费用）")
        }
        let settings = LLMSettings.load()
        let config = settings.chatConfig
        let key = KeychainStore.get(config.apiKeyKeychainKey) ?? ""
        try XCTSkipIf(key.isEmpty, "Keychain 无 \(config.apiKeyKeychainKey)——跳过 live 探针")
        continueAfterFailure = true   // 一次调用很贵：把所有判据都跑完再红，别第一条就短路

        let system = AgentPrompts.prd(
            tier: "lean",
            clarification: Self.clarification,
            modulePageMap: Self.modulePageMap,
            architecture: Self.architecture,
            coreFlows: Self.coreFlows,
            prototypePages: ["今日页", "打卡页", "统计页"],
            analysisNotes: "",
            injection: ""
        )
        let reply = try await LLMClient.complete(
            stage: .prd, settings: settings,
            messages: [
                ChatMessage(role: .system, content: system),
                ChatMessage(role: .user, content: Self.directive),
            ],
            maxTokens: Self.maxTokens
        )
        let outFile = try Self.writeRawOutput(reply, model: config.model)
        print("📄 原文已落 \(outFile)（\(reply.count) 字符 / \(config.model)）")

        // ── 判据 1：协议块存在
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        guard let raw = blocks.first(where: { $0.name == "metric-specs" })?.content else {
            XCTFail("模型没输出 artifact:metric-specs 块 → 第⑤步在模型侧失效，落盘链路根本不会被触发。"
                    + "（PRD 块是否照常出了：\(blocks.contains(where: { $0.name == "prd" }))；原文见 \(outFile)）")
            return
        }
        print("✅ 判据 1 协议块存在（\(raw.count) 字符）")

        // ── 判据 2：块能被现有解码器吃下，且指标名非空
        guard let specs = ArtifactParser.parseMetricSpecs(blocks: blocks), !specs.isEmpty else {
            XCTFail("口径块存在但解不出任何有效条目（JSON 坏 / 全无指标名）。原文见 \(outFile)")
            return
        }
        for spec in specs {
            print("   · \(spec.name)｜\(spec.status.label)｜缺项 \(spec.missingFields.isEmpty ? "无" : spec.missingFields.joined(separator: "/"))"
                + "\(spec.assumptionNote.map { "｜假设：\($0)" } ?? "")")
        }

        // ── 判据 3：目标值 / 基线值不得进口径字段（数值事实源是 4.2 表）。
        // 收窄口径：口径字段天生要写时刻与窗口（「00:00-24:00」「第 30 天」），禁所有
        // 数字不现实；真正会造出第二事实源的是**用户给的那个目标值**，它只能活在 4.2 表。
        // assumptionNote 允许引用它——那句话的作用正是解释「为什么这条待确认」。
        let numericLeak = ["dataSource", "numerator", "denominator", "window", "exclusions"]
            .compactMap { field -> String? in
                let value = Self.fieldValue(raw, field)
                return value?.contains(Self.userStatedTarget) == true ? field : nil
            }
        XCTAssertNil(
            numericLeak.first,
            "口径字段 \(numericLeak) 里写进了用户口述的目标值——对账时会与 4.2 表打架"
        )
        // ── 判据 4：至少一条把核心三项说全，否则第⑤步形同未落地
        XCTAssertTrue(
            specs.contains(where: \.hasCoreSpec),
            "没有任何一条指标集齐分子/分母/时间窗——第⑤步在模型侧被当成可选项了"
        )
        // ── 判据 5：用户从未说过口径，首轮一律不得自封 confirmed
        let selfDeclared = specs.filter { $0.status == .confirmed }
        XCTAssertNil(
            selfDeclared.first,
            "模型把口径自封为「已确认」\(selfDeclared.map(\.name))——confirmed 只能来自用户在默认项卡上的确认"
        )
        // ── 判据 6：起草的口径必须带假设说明，否则读者无从知道哪里该改
        let assumedWithoutNote = specs.filter { $0.status == .assumed && $0.assumptionNote == nil }
        XCTAssertNil(
            assumedWithoutNote.first,
            "assumed 态却没写 assumptionNote：\(assumedWithoutNote.map(\.name))"
        )
        // ── 判据 7：缺口径要走默认项卡（这是采集回路的唯一出口，不出卡 = 口径永远悬空）
        let card = ArtifactParser.parseQuestionCard(blocks: blocks)
        guard let purpose = card?.purpose, purpose == "prd_defaults" else {
            XCTFail("未出口径默认项卡（purpose=\(card?.purpose ?? "nil")）——起草的口径没有确认通道，第二圈对账时全是悬空账")
            return
        }
        let cardText = (card?.questions ?? []).reduce("") {
            $0 + ($1.title ?? "") + ($1.detail ?? "") + ($1.options ?? []).joined()
        }
        XCTAssertTrue(
            cardText.contains("口径") || cardText.contains("分子") || cardText.contains("分母"),
            "出了默认项卡但卡里没问口径：\(cardText.prefix(120))"
        )
        print("✅ 判据 7 默认项卡已问口径")

        // ── 判据 8：模型是否接受「正文只写引用槽」的新协议。口径的正文与记录自 2026-09-22
        // 起同源（落盘时由 stitchSpecSlots 用记录块渲染），比对两边文字已无意义；
        // 这里判的是模型有没有停止自己抄第二份——它首跑就是在正文写了「打卡活跃用户」、
        // 在记录写了「活跃设备」两套分母，才促成这次改造。
        // 判的是 PRD 块**正文**（不能用 stripArtifactBlocks 后的文本——那一步正是把
        // 整个产物块剥掉，槽在块内，剥完必然找不到）。
        guard let prdBody = blocks.first(where: { $0.name == "prd" })?.content else {
            XCTFail("没有 artifact:prd 块，无从判断正文是否走引用槽")
            return
        }
        XCTAssertTrue(
            prdBody.contains("[[SPEC:"),
            "正文没写口径引用槽（模型仍自行抄口径）→ 落盘后正文与记录会再次各写一套"
        )
        let stitched = ArtifactParser.stitchSpecSlots(in: prdBody, specs: specs)
        XCTAssertEqual(stitched.unresolvedSlots.count, 0,
                       "有槽没被记录渲染掉：\(stitched.unresolvedSlots)——文档里会留 ⚠️ 未登记")
        XCTAssertTrue(
            stitched.text.contains("分母 = \(specs.first?.denominator ?? "∅")"),
            "缝合后的正文里没有记录中的分母——说明渲染没生效"
        )
        print("✅ 判据 8 正文走引用槽，\(stitched.resolvedCount) 个槽由记录渲染")
    }

    /// 从口径块 JSON 原文取某字段的字符串值（不经解码器，判的是模型字面写了什么）。
    private static func fieldValue(_ json: String, _ field: String) -> String? {
        Self.firstGroup(in: json, pattern: "\"\(field)\":\\s*\"([^\"]*)\"")
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 输入素材（刻意只给数字、不给口径，把第⑤步逼到「须起草」的位置上）

    private static let clarification = """
        | 字段 | 内容 |
        | --- | --- |
        | target_user | 25-40 岁、下班后在家徒手健身的新手 |
        | core_scenario | 每晚练完当场记一组动作与时长 |
        | core_value | 不用动脑就能坚持，一眼看到自己连着练了几天 |
        | constraints | 纯单机、无账号、免费、iOS 优先 |
        | open_questions | 商业化本版不做 |
        用户原话补充：「我就是要次日留存能到 45%，上线第 30 天看这个数。」
        """

    private static let modulePageMap = """
        | 模块 | 页面 | 优先级 |
        | --- | --- | --- |
        | 打卡 | 今日页 | P0 |
        | 打卡 | 打卡页 | P0 |
        | 回顾 | 统计页 | P1 |
        """

    private static let architecture = """
        ```mermaid
        graph TD
          健身打卡 --> 打卡
          健身打卡 --> 回顾
          打卡 --> 今日页
          打卡 --> 打卡页
          回顾 --> 统计页
        ```
        """

    private static let coreFlows = """
        ```mermaid
        flowchart LR
          打开App --> 今日页 --> 点打卡 --> 打卡页 --> 保存 --> 今日页
        ```
        """

    private static let directive = """
        上游都已确认，按 lean 档出 PRD。北极星我说过：次日留存做到 45%，上线第 30 天看。
        其余细节按合理假设补，这轮不要再问我。
        """

    // MARK: - 原文落盘（判定须可复核）

    private static func writeRawOutput(_ reply: String, model: String) throws -> String {
        let resultsDir = repoRoot.appendingPathComponent("evals/results")
        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let day = ISO8601.dayString()
        let name = "\(day)-SPEC-lean-\(model.replacingOccurrences(of: "/", with: "_")).txt"
        try reply.write(to: resultsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return "evals/results/\(name)"
    }

    /// 由源文件编译期路径回溯仓库根：<root>/pm_worker/pm_worker/pm_workerTests/本文件
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
