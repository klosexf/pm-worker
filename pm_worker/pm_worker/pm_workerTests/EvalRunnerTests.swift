//
//  EvalRunnerTests.swift
//  pm_workerTests
//
//  evals 评测集 runner（第一步：clarify 单阶段 + 仅硬断言，rubric judge 未接）。
//  默认跳过——live 调用产生真实费用，须显式 PM_EVAL_STAGE=clarify 才跑，
//  以免污染「全量测试绿」这条验收标准（AGENTS.md）。
//
//  跑法（注意 TEST_RUNNER_ 前缀：xcodebuild 不透传普通环境变量到测试进程，
//  直接 `PM_EVAL_STAGE=clarify xcodebuild test` 会被静默跳过）：
//    TEST_RUNNER_PM_EVAL_STAGE=clarify xcodebuild -project pm_worker.xcodeproj \
//      -scheme pm_worker -destination 'platform=macOS' test \
//      -parallel-testing-enabled NO -only-testing:pm_workerTests/EvalRunnerTests
//
//  保真度限制与口径见 fidelityNote；评测方法论见 evals/README.md。
//

import XCTest
@testable import pm_worker

// MARK: - case schema（evals/README.md §2，只解第一步用得上的字段）

nonisolated struct EvalCase: Codable {
    nonisolated struct Input: Codable {
        var mode: String
        var setup: String
        var userMessage: String?
        var turns: [Turn]?

        enum CodingKeys: String, CodingKey {
            case mode, setup
            case userMessage = "user_message"
            case turns
        }
    }

    nonisolated struct Turn: Codable {
        var user: String?
        var action: String?
    }

    nonisolated struct Assert: Codable {
        var type: String
        var value: String
        var desc: String?
    }

    var id: String
    var layer: String
    var stage: String
    var title: String
    var input: Input
    var hardAsserts: [Assert]?

    enum CodingKeys: String, CodingKey {
        case id, layer, stage, title, input
        case hardAsserts = "hard_asserts"
    }
}

// MARK: - 报告（evals/README.md §4 结果归档约定）

nonisolated struct EvalReport: Codable {
    nonisolated struct CaseResult: Codable {
        var id: String
        var title: String
        var layer: String
        var status: String            // ran | skipped
        var hardPass: Bool?
        var failedAsserts: [String]?
        var assertTotal: Int?
        var skipReason: String?
        var turnsCalled: Int?
        var outputFile: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case id, title, layer, status, error
            case hardPass = "hard_pass"
            case failedAsserts = "failed_asserts"
            case assertTotal = "assert_total"
            case skipReason = "skip_reason"
            case turnsCalled = "turns_called"
            case outputFile = "output_file"
        }
    }

    var date: String
    var model: String
    var provider: String
    var stage: String
    var mode: String
    var judge: String
    var fidelityNote: String
    var cases: [CaseResult]
    var redlineViolations: Int
    var hardPassRate: String

    enum CodingKeys: String, CodingKey {
        case date, model, provider, stage, mode, judge, cases, fidelityNote
        case redlineViolations = "redline_violations"
        case hardPassRate = "hard_pass_rate"
    }
}

/// clarify.jsonl 行解析失败（区别于断言失败：这是评测集自身的问题）。
nonisolated struct EvalCaseParseError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// MARK: - Runner

final class EvalRunnerTests: XCTestCase {

    private static let stageEnvKey = "PM_EVAL_STAGE"

    /// 第一步只跑硬断言：澄清回复不产正式产物，4096 足够一轮提问 + 选项行。
    private static let replyMaxTokens = 4096

    private static let fidelityNote = """
        第一步为「裸阶段 prompt」口径：system 段直接取 AgentPrompts.clarify(injection: "")，\
        不含规则层 / 记忆 / 技能 / 检索的横切注入（那套组装在 AppModel.assembleSystemPrompt，\
        @MainActor private 且依赖完整 app 状态，runner 拿不到）。因此本结果是相对生产环境的\
        保守下界，不是等价复现。rubric 层 LLM-as-judge 本步未接，报告不含分数。
        """

    func testEvalRunnerClarifyHardAsserts() async throws {
        guard ProcessInfo.processInfo.environment[Self.stageEnvKey] == "clarify" else {
            throw XCTSkip(
                "未设 \(Self.stageEnvKey)=clarify——评测 runner 默认跳过（live 调用产生真实费用）"
            )
        }

        let settings = LLMSettings.load()
        let config = settings.chatConfig
        let key = KeychainStore.get(config.apiKeyKeychainKey) ?? ""
        try XCTSkipIf(key.isEmpty, "Keychain 未存 \(config.apiKeyKeychainKey) 的 key——跳过评测实跑")

        let root = Self.repoRoot
        let cases = try Self.loadCases(
            from: root.appendingPathComponent("evals/cases/clarify.jsonl")
        )
        XCTAssertFalse(cases.isEmpty, "evals/cases/clarify.jsonl 没有可解析的 case")

        let resultsDir = root.appendingPathComponent("evals/results")
        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let dayStamp = Self.dateFormat.string(from: Date())

        var results: [EvalReport.CaseResult] = []
        var outputs: [(name: String, text: String)] = []

        for evalCase in cases {
            let outcome = await Self.run(evalCase, settings: settings)
            var result = outcome.result
            if let reply = outcome.reply {
                let fileName = "\(dayStamp)-\(evalCase.id)-\(config.model).txt"
                result.outputFile = "evals/results/\(fileName)"
                outputs.append((name: fileName, text: reply))
            }
            results.append(result)
            print(Self.lineSummary(result, model: config.model))
        }

        // 逐 case 原文落盘（README §4 步骤 3：判定须可复核，不只留在内存）
        for output in outputs {
            try output.text.write(
                to: resultsDir.appendingPathComponent(output.name),
                atomically: true, encoding: .utf8
            )
        }

        let ran = results.filter { $0.status == "ran" }
        let passed = ran.filter { $0.hardPass == true }
        let redlineViolations = ran.filter {
            $0.layer == "B" && ($0.hardPass == false || $0.error != nil)
        }.count

        let report = EvalReport(
            date: ISO8601.timestamp(),
            model: config.model,
            provider: config.provider,
            stage: "clarify",
            mode: "hard-only（第一步：仅硬断言，rubric judge 未接，不产分数）",
            judge: "未启用",
            fidelityNote: Self.fidelityNote,
            cases: results,
            redlineViolations: redlineViolations,
            hardPassRate: ran.isEmpty ? "n/a（无 case 实跑）" : "\(passed.count)/\(ran.count)"
        )
        let reportName = "\(dayStamp)-\(config.model)-hardonly.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: resultsDir.appendingPathComponent(reportName))
        print("\n📊 评测报告：evals/results/\(reportName)")
        print("   硬断言通过 \(report.hardPassRate)｜跳过 \(results.count - ran.count) 条")

        // 硬断言即闸门：任一失败让测试变红
        //（README §3.1「硬断言不过的 case 不允许用 rubric 分数掩盖」）
        let failures = ran.filter { $0.hardPass != true }
        XCTAssertTrue(
            failures.isEmpty,
            "硬断言失败 \(failures.count) 条："
                + failures.map(Self.failureText).joined(separator: " / ")
        )
    }

    // MARK: - 单条 case 执行

    /// 返回结果 + 被评轮回复原文（skipped / 调用失败时 reply 为 nil）。
    private static func run(_ evalCase: EvalCase, settings: LLMSettings) async
        -> (result: EvalReport.CaseResult, reply: String?)
    {
        var result = EvalReport.CaseResult(
            id: evalCase.id, title: evalCase.title, layer: evalCase.layer, status: "ran"
        )

        guard let userTurns = executableTurns(for: evalCase) else {
            result.status = "skipped"
            result.skipReason = skipReason(for: evalCase)
            return (result, nil)
        }

        let fixture = fixture(for: evalCase.id)
        var history: [ChatMessage] = [
            ChatMessage(role: .system, content: AgentPrompts.clarify(injection: ""))
        ]
        var reply = ""

        for (index, userMessage) in userTurns.enumerated() {
            // 当前用户消息必须在尾条之前入历史：VolatileTailMaterial.appending 的语义是
            // 「追加到当前 user 之后」，顺序写反会让模型只看到状态段、看不到用户发言，
            // 而断言照样可能侥幸通过（首轮提问类断言）——2026-09-21 首跑即踩中此坑。
            history.append(ChatMessage(role: .user, content: userMessage))
            // 与 App 同构：轮次状态段走尾条（ContextTail），不进冻结 system 段；
            // rounds = 已问轮数（首轮 0），与 AppModel 传 pipeline.clarifyRounds 同口径
            let tail = AgentPrompts.clarifyStateSection(
                rounds: index, limit: PipelineEngine.clarifyRoundLimit,
                previousTable: fixture?.previousTable, amending: fixture?.amending ?? false
            )
            let messages = VolatileTailMaterial.appending(history, tail: tail)
            // 装配自检：宁可比模型失败更响地报错，也不静默产出无效结论
            guard messages.contains(where: { $0.role == .user && $0.content == userMessage })
            else {
                result.error = "runner 装配缺陷：当前用户消息未进入请求 messages"
                result.hardPass = false
                return (result, nil)
            }
            do {
                reply = try await LLMClient.complete(
                    stage: .clarify, settings: settings,
                    messages: messages, maxTokens: replyMaxTokens
                )
            } catch {
                result.error = "\(type(of: error)): \(error.localizedDescription)"
                result.hardPass = false
                result.turnsCalled = index + 1
                return (result, nil)
            }
            history.append(ChatMessage(role: .assistant, content: reply))
        }
        result.turnsCalled = userTurns.count

        // 被评对象 = 最后一轮回复（README §2 多轮执行语义）
        let asserts = evalCase.hardAsserts ?? []
        let failed = asserts.filter { !evaluate($0, on: reply) }
        result.assertTotal = asserts.count
        result.hardPass = failed.isEmpty
        result.failedAsserts = failed.isEmpty ? nil : failed.map(Self.assertText)
        return (result, reply)
    }

    /// case 是否可机读执行：单轮取 user_message；多轮要求每个 turn 都带字面 user 文本。
    private static func executableTurns(for evalCase: EvalCase) -> [String]? {
        if evalCase.input.mode == "single_turn" {
            guard let message = evalCase.input.userMessage, isFilled(message) else { return nil }
            return [message]
        }
        guard let turns = evalCase.input.turns, !turns.isEmpty else { return nil }
        var messages: [String] = []
        for turn in turns {
            guard let user = turn.user, isFilled(user) else { return nil }
            messages.append(user)
        }
        return messages
    }

    private static func skipReason(for evalCase: EvalCase) -> String {
        if evalCase.input.mode == "single_turn" {
            return "single_turn 但 input.user_message 缺失"
        }
        let missing = (evalCase.input.turns ?? []).enumerated()
            .filter { !isFilled($0.element.user ?? "") }
            .map(\.offset)
        guard !missing.isEmpty else { return "无可执行轮次" }
        return "case 缺口：turns[\(missing.map(String.init).joined(separator: ","))] "
            + "只有 action 散文描述用户回答、无字面 user 文本，机读不可得（需 case 侧补 user 字段）"
    }

    /// CLF-006 的「增补基底」按该 case setup 的五字段逐字转写（自然语言 setup → 机读 fixture）；
    /// 其余 case 为全新项目，无基底。
    private static func fixture(for id: String) -> (previousTable: String?, amending: Bool)? {
        guard id == "CLF-006" else { return nil }
        let table = """
            | 字段 | 内容 |
            | --- | --- |
            | target_user | 健身新手 |
            | core_scenario | 每日训练后记录动作与组数 |
            | core_value | 坚持可视化 |
            | constraints | 仅iOS、免费、单机无社交 |
            | open_questions | （空） |
            """
        return (table, true)
    }

    // MARK: - 硬断言（README §2 语义：区分大小写、不做归一化）

    private static func evaluate(_ assert: EvalCase.Assert, on reply: String) -> Bool {
        switch assert.type {
        case "contains": return reply.contains(assert.value)
        case "not_contains": return !reply.contains(assert.value)
        case "regex", "not_regex":
            // 正则编译失败按断言不通过（fail-closed：坏 pattern 不许静默放行）
            guard let regex = try? NSRegularExpression(pattern: assert.value) else { return false }
            let range = NSRange(reply.startIndex..<reply.endIndex, in: reply)
            let hit = regex.firstMatch(in: reply, range: range) != nil
            return assert.type == "regex" ? hit : !hit
        default: return false      // 未知断言语义按失败，不静默放过
        }
    }

    private static func isFilled(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func assertText(_ assert: EvalCase.Assert) -> String {
        "\(assert.type) 「\(assert.value)」——\(assert.desc ?? "")"
    }

    // MARK: - 路径与报告辅助

    /// 由源文件编译期路径回溯仓库根：<root>/pm_worker/pm_worker/pm_workerTests/本文件
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // pm_workerTests
            .deletingLastPathComponent()   // pm_worker（Xcode 工程根）
            .deletingLastPathComponent()   // pm_worker（仓库子目录）
            .deletingLastPathComponent()   // 仓库根
    }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func loadCases(from url: URL) throws -> [EvalCase] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var cases: [EvalCase] = []
        for (index, line) in raw.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do {
                cases.append(try JSONDecoder().decode(EvalCase.self, from: Data(trimmed.utf8)))
            } catch {
                throw EvalCaseParseError(
                    message: "clarify.jsonl 第 \(index + 1) 行解析失败：\(error.localizedDescription)"
                )
            }
        }
        return cases
    }

    private static func lineSummary(_ result: EvalReport.CaseResult, model: String) -> String {
        if result.status == "skipped" {
            return "⏭️  \(result.id) 跳过——\(result.skipReason ?? "")"
        }
        if let error = result.error {
            return "❌ \(result.id) 调用失败：\(error)"
        }
        let pass = result.hardPass == true
        let marks = (result.failedAsserts ?? []).joined(separator: "；")
        return (pass ? "✅ " : "🚫 ") + "\(result.id) 硬断言 \(result.assertTotal ?? 0) 条"
            + "\(pass ? "全过" : "未过：\(marks)")（\(result.turnsCalled ?? 0) 轮 / \(model)）"
    }

    private static func failureText(_ result: EvalReport.CaseResult) -> String {
        if let error = result.error { return "\(result.id) 调用失败 \(error)" }
        return "\(result.id) [\((result.failedAsserts ?? []).joined(separator: "、"))]"
    }
}
