//
//  ArtifactParser.swift
//  pm_worker
//
//  Agent 输出解析（Task 2.1/2.3/2.4）：
//  ① artifact: fenced block 解析（structure 三产物 / prototype HTML）
//  ② 澄清选项行解析（A) / B) / C) 点选）
//  ③ 澄清要点表 / 记忆抽取 JSON 解析（容错：剥围栏、截首个 JSON 值）
//

import Foundation

/// 行级 diff 统计（落盘文件卡数据源）：added = 新增行数、removed = 删除行数。
/// 标准 LCS（滚动数组，空间 O(min(m,n))）；n·m 超 400 万 cell（超长 PRD 全量重写等）
/// 退化为按行多重集估算——只影响显示精度，不影响落盘正确性。
nonisolated enum FileLineDiff {

    /// old 为 nil（文件不存在）→ 全部计为新增；内容完全一致 → (0, 0)。
    static func changedLines(old: String?, new: String) -> (added: Int, removed: Int) {
        let newLines = normalizedLines(new)
        guard let old, !old.isEmpty else { return (newLines.count, 0) }
        let oldLines = normalizedLines(old)
        if oldLines == newLines { return (0, 0) }

        // 超限退化：公共行 = 按行多重集取 min 计数
        if oldLines.count * newLines.count > 4_000_000 {
            var counts: [String: Int] = [:]
            for line in oldLines { counts[line, default: 0] += 1 }
            var common = 0
            for line in newLines {
                if let c = counts[line], c > 0 {
                    counts[line] = c - 1
                    common += 1
                }
            }
            return (newLines.count - common, oldLines.count - common)
        }

        // LCS：a = 短序列放内层，滚动数组两行
        let a = oldLines.count <= newLines.count ? oldLines : newLines
        let b = oldLines.count <= newLines.count ? newLines : oldLines
        var prev = [Int](repeating: 0, count: a.count + 1)
        var curr = [Int](repeating: 0, count: a.count + 1)
        for j in 1...b.count {
            for i in 1...a.count {
                curr[i] = a[i - 1] == b[j - 1] ? prev[i - 1] + 1 : max(prev[i], curr[i - 1])
            }
            swap(&prev, &curr)
        }
        let lcs = prev[a.count]
        return (newLines.count - lcs, oldLines.count - lcs)
    }

    /// 按行切分并去掉单个末尾空行（落盘内容普遍以 \n 结尾，避免噪声 ±1）。
    private static func normalizedLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

nonisolated enum ArtifactParser {

    // MARK: - artifact 块

    struct ArtifactBlock: Equatable {
        var name: String   // architecture | core-flows | module-page-map | prototype | business-flows
        var content: String
    }

    /// 解析 ```artifact:<name> ... ``` 围栏块。
    static func parseArtifactBlocks(in text: String) -> [ArtifactBlock] {
        var results: [ArtifactBlock] = []
        // (?s) dot-all；标记在围栏语言位
        let pattern = "(?s)```artifact:([a-zA-Z0-9_-]+)[ \\t]*\\n(.*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
        for match in matches where match.numberOfRanges >= 3 {
            let name = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            results.append(ArtifactBlock(name: name, content: body.dropTrailingNewline()))
        }
        return results
    }

    /// 流式中未闭合的 artifact 围栏（最后一个 ```artifact: 标记到文末无闭合 ```）。
    /// 返回块名与已生成正文；nil = 无进行中的产物块（块已完成或后续还有正文）。
    /// 用途：流式渲染时收起进行中的长代码；隐藏哪些块名由调用方按策略过滤
    /// （prototype / prd 收进进度卡，其余文字型产物保留原文流式）。
    static func parseIncompleteArtifact(
        in text: String
    ) -> (name: String, partial: String)? {
        guard let marker = text.range(of: "```artifact:", options: .backwards) else {
            return nil
        }
        let afterMarker = text[marker.upperBound...]
        // 块名尚未流完（标记后还没有换行）→ 视为刚开始生成，正文为空
        guard let newline = afterMarker.firstIndex(of: "\n") else {
            return (name: "", partial: "")
        }
        let name = String(afterMarker[..<newline]).trimmingCharacters(in: .whitespaces)
        // 块名需符合 artifact 命名（与 parseArtifactBlocks 的 [a-zA-Z0-9_-]+ 口径一致）
        guard !name.isEmpty,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let body = String(afterMarker[afterMarker.index(after: newline)...])
        // 已出现闭合围栏 → 该块已完成（后续可能有正文），不算进行中
        guard !body.contains("```") else { return nil }
        return (name: name, partial: body)
    }

    /// 从回复中剥离 artifact 块后的正文（对用户展示）。
    /// placeholder 由调用方按会话上下文选择（默认指向 chip 点击预览与右栏产物面板）；
    /// 回灌 / 素材提取等非指引场景用默认中性文案。
    /// placeholderFor：按块名定制占位（返回 nil 落默认；如内联渲染的图表块传 "" 不插提示）。
    static func stripArtifactBlocks(
        in text: String,
        placeholder: String = "（产物已生成并落盘）",
        placeholderFor: ((String) -> String?)? = nil
    ) -> String {
        let pattern = "(?s)```artifact:([a-zA-Z0-9_-]+)[ \\t]*\\n.*?```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
        var result = text
        // 从后往前逐块替换：前面区间的 range 在已替换串中仍然有效
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let name = ns.substring(with: match.range(at: 1))
            let ph = placeholderFor?(name) ?? placeholder
            result = (result as NSString).replacingCharacters(
                in: match.range(at: 0), with: ph
            )
        }
        // 合并连续空行
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result
    }

    // MARK: - 结构产物落盘（write-then-verify）

    struct StructureArtifacts: Equatable {
        var architecture: String   // 功能架构图.md 全文
        var coreFlows: String      // 核心流程图.md 全文
        var modulePageMap: String  // 模块-页面映射表.md 全文
        var businessFlows: String? // 仅复杂产品
        var changes: [FileChangeSummary] = [] // 本次落盘的文件变更摘要
    }

    /// 落盘并测量变更：读旧内容 → writeVerified → 行级 diff 摘要。
    /// 文件不存在 → isNew；存在但读取失败 → (0, 0)，宁可少显示不虚报。
    private static func writeMeasured(
        _ content: String, to url: URL, relativePath: String
    ) throws -> FileChangeSummary {
        var isNew = true
        var old: String?
        if FileManager.default.fileExists(atPath: url.path) {
            isNew = false
            old = try? String(contentsOf: url, encoding: .utf8)
        }
        try PMAgentStore.writeVerified(content, to: url)
        let diff: (added: Int, removed: Int)
        if isNew {
            diff = FileLineDiff.changedLines(old: nil, new: content)
        } else if let old {
            diff = FileLineDiff.changedLines(old: old, new: content)
        } else {
            diff = (0, 0)
        }
        return FileChangeSummary(
            path: relativePath, added: diff.added, removed: diff.removed, isNew: isNew
        )
    }

    /// 从 assistant 回复解析结构三产物并落盘到 02-structure/。
    /// 返回 nil 表示产物不全（architecture / core-flows / module-page-map 缺一不可）。
    @discardableResult
    static func writeStructureArtifacts(
        blocks: [ArtifactBlock], project: String, version: String
    ) throws -> StructureArtifacts {
        let byName = Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0.content) })
        guard let arch = byName["architecture"],
              let flows = byName["core-flows"],
              let map = byName["module-page-map"] else {
            return StructureArtifacts(
                architecture: byName["architecture"] ?? "",
                coreFlows: byName["core-flows"] ?? "",
                modulePageMap: byName["module-page-map"] ?? "",
                businessFlows: byName["business-flows"]
            )
        }

        let dir = PMAgentStore.versionURL(project: project, version: version)

        var changes: [FileChangeSummary] = []
        changes.append(try writeMeasured(
            "# 功能架构图\n\n```mermaid\n\(arch)\n```\n",
            to: dir.appendingPathComponent(ArtifactPath.architecture),
            relativePath: ArtifactPath.architecture
        ))
        changes.append(try writeMeasured(
            "# 核心流程图（P0 场景用户路径）\n\n```mermaid\n\(flows)\n```\n",
            to: dir.appendingPathComponent(ArtifactPath.coreFlows),
            relativePath: ArtifactPath.coreFlows
        ))
        changes.append(try writeMeasured(
            "# 模块-页面映射表\n\n\(map)\n",
            to: dir.appendingPathComponent(ArtifactPath.modulePageMap),
            relativePath: ArtifactPath.modulePageMap
        ))
        if let business = byName["business-flows"], !business.isEmpty {
            changes.append(try writeMeasured(
                "# 业务流程图\n\n```mermaid\n\(business)\n```\n",
                to: dir.appendingPathComponent(ArtifactPath.businessFlows),
                relativePath: ArtifactPath.businessFlows
            ))
        }

        return StructureArtifacts(
            architecture: arch, coreFlows: flows, modulePageMap: map,
            businessFlows: byName["business-flows"],
            changes: changes
        )
    }

    /// 结构产物是否已齐（闸口放行的最低集）。
    static func structureArtifactsComplete(_ blocks: [ArtifactBlock]) -> Bool {
        let names = Set(blocks.map(\.name))
        return Set(["architecture", "core-flows", "module-page-map"]).isSubset(of: names)
    }

    /// 原型 HTML 落盘到 03-prototypes/可点击原型.html（附变更摘要）。
    @discardableResult
    static func writePrototypeArtifact(
        blocks: [ArtifactBlock], project: String, version: String
    ) throws -> (url: URL, changes: [FileChangeSummary])? {
        guard let html = blocks.first(where: { $0.name == "prototype" })?.content,
              html.contains("<") else { return nil }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(ArtifactPath.prototype)
        let change = try writeMeasured(
            html, to: url, relativePath: ArtifactPath.prototype
        )
        return (url: url, changes: [change])
    }

    // MARK: - M3：漏项雷达 / 决策 WHY / 评分卡 / PRD

    /// 漏项雷达四档声明（artifact:radar 块，design.md §6.2 自评审）。
    struct RadarReport: Codable, Equatable {
        struct Skipped: Codable, Equatable {
            var point: String
            var reason: String
        }
        struct Fatal: Codable, Equatable {
            var hypothesis: String
            /// 炸了会怎样——具体后果（方案 A 台账行内展示）
            var impact: String?
            /// 建议应对方案（采纳后挂起等验证）
            var plan: String?
            var triggerSignal: String?

            enum CodingKeys: String, CodingKey {
                case hypothesis, impact, plan
                case triggerSignal = "trigger_signal"
            }

            /// 转 RiskRecord.TriggerSignal（未知信号返回 nil，登记不再强依赖信号）。
            var signal: RiskRecord.TriggerSignal? {
                triggerSignal.flatMap(RiskRecord.TriggerSignal.init(rawValue:))
            }
        }

        var fixed: [String]?
        var remaining: [String]?
        var covered: [String]?
        var missing: [String]?
        var skipped: [Skipped]?
        var fatal: [Fatal]?
    }

    /// 决策 WHY 草稿（artifact:decision 块，五要素，design.md 附录 B）。
    struct DecisionDraft: Codable, Equatable {
        var decision: String
        var why: String
        var rejected: [RejectedAlternative]?
        var confidence: Double?
        var toBeVerified: Bool?

        enum CodingKeys: String, CodingKey {
            case decision, why, rejected, confidence
            case toBeVerified = "to_be_verified"
        }

        /// 补全默认值 → DecisionRecord（version 由调用侧填）。
        func record(version: String) -> DecisionRecord {
            DecisionRecord(
                version: version,
                decision: decision,
                why: why,
                rejectedAlternatives: rejected ?? [],
                confidence: confidence.map { min(max($0, 0), 1) } ?? 1.0,
                toBeVerified: toBeVerified ?? false
            )
        }
    }

    /// PRD 三维度评分卡（artifact 块外裸 JSON，design.md §6.2 ④）。
    struct ScoreCard: Codable, Equatable {
        struct Dimension: Codable, Equatable {
            var score: Int
            var reason: String
        }
        var complexity: Dimension
        var risk: Dimension
        var scope: Dimension
        var tier: String

        /// 档位合法性（lean/standard/full）。
        var validTier: String? {
            ["lean", "standard", "full"].contains(tier) ? tier : nil
        }
    }

    /// 从回复块中解析漏项雷达（无 radar 块或 JSON 不合法 → nil）。
    static func parseRadar(blocks: [ArtifactBlock]) -> RadarReport? {
        guard let content = blocks.first(where: { $0.name == "radar" })?.content else {
            return nil
        }
        return LenientJSON.decode(RadarReport.self, from: content)
    }

    /// 从回复块中解析决策条目数组（无块 → 空数组）。
    static func parseDecisions(blocks: [ArtifactBlock]) -> [DecisionDraft] {
        guard let content = blocks.first(where: { $0.name == "decision" })?.content else {
            return []
        }
        return LenientJSON.decode([DecisionDraft].self, from: content) ?? []
    }

    /// 回退请求（artifact:backtrack 块）：③④ 阶段 LLM 识别用户要重做上游产物时输出，
    /// 不产出本阶段产物。App 校验 target 白名单（AppModel.backtrackStage）后回退状态机，
    /// 并按 instruction 透传诉求自动重生成——LLM 只请求，不裁决。
    /// mode：revise（默认，改上一版）= App 注入旧产物作修订基底；
    ///       redo（推翻重来）= 不注入旧版，从零重画。
    struct BacktrackRequest: Codable, Equatable {
        var target: String       // structure | prototype
        var instruction: String? // 用户的具体修改要求（重生成合成指令的载荷）
        var mode: String?       // "revise" | "redo"（缺省按 revise）
    }

    /// 从回复块中解析回退请求（无块或 JSON 不合法 → nil）。
    static func parseBacktrack(blocks: [ArtifactBlock]) -> BacktrackRequest? {
        guard let content = blocks.first(where: { $0.name == "backtrack" })?.content else {
            return nil
        }
        return LenientJSON.decode(BacktrackRequest.self, from: content)
    }

    /// 快速通道请求（artifact:fast-forward 块）：用户明确要求跳过逐步确认、直接出下游产物时
    /// LLM 输出，不产出本阶段产物。App 校验 target 白名单（AppModel.fastForwardTarget）后
    /// 自动串链「收束当前阶段 → 生成中间产物并确认 → 目标产物落盘」——LLM 只请求，不裁决。
    struct FastForwardRequest: Codable, Equatable {
        var target: String       // prototype | prd
        var instruction: String? // 用户对目标产物的具体要求（下游生成合成指令的载荷）
    }

    /// 从回复块中解析快速通道请求（无块或 JSON 不合法 → nil）。
    static func parseFastForward(blocks: [ArtifactBlock]) -> FastForwardRequest? {
        guard let content = blocks.first(where: { $0.name == "fast-forward" })?.content else {
            return nil
        }
        return LenientJSON.decode(FastForwardRequest.self, from: content)
    }

    /// 澄清问题卡（artifact:question-card 块）：① 阶段 LLM 输出相互独立的事实型问题集，
    /// App 渲染为向导卡片批量收集，答案拼装为【问题卡作答】用户消息回传。
    struct QuestionCardRequest: Codable, Equatable {
        struct Question: Codable, Equatable {
            var id: String?          // 稳定标识（缺省由 App 归一化补 q1…qn）
            var title: String        // 问题文本
            var detail: String?      // 一句话补充说明
            var options: [String]?   // 2-4 个候选选项（缺省 = 仅自定义输入）
            var allowCustom: Bool?   // 允许自定义输入（缺省 true）
            var multiple: Bool?      // 多选题标记（缺省由题干启发式推断）
            enum CodingKeys: String, CodingKey {
                case id, title, detail, options
                case allowCustom = "allow_custom"
                case multiple
            }

            /// 题型判定：LLM 显式 multiple 优先，缺省按题干/说明启发式推断。
            var isMultipleChoice: Bool {
                multiple ?? Question.inferMultipleChoice(title: title, detail: detail)
            }

            /// 题型启发式（纯函数，单测直测）：题干或说明出现并列诉求关键词 → 多选
            /// （「哪些 / 哪几 / 多选 / 可多选 / 多个 / 不限一项」；「哪几」已覆盖「哪几种」）。
            static func inferMultipleChoice(title: String, detail: String?) -> Bool {
                var text = title
                if let detail, !detail.isEmpty { text += "\n\(detail)" }
                let multiHints = ["哪些", "哪几", "多选", "可多选", "多个", "不限一项"]
                return multiHints.contains { text.contains($0) }
            }
        }
        var questions: [Question]
    }

    /// 问题卡归一化：题数 clamp ≤5、每题选项 clamp ≤4、id 缺省补齐、空标题题丢弃；
    /// 无有效题 → nil。防止病态输出撑爆卡片。
    static func normalizeQuestionCard(_ raw: QuestionCardRequest) -> QuestionCardRequest? {
        var questions = Array(raw.questions.prefix(5))
        questions.removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !questions.isEmpty else { return nil }
        for i in questions.indices {
            if let opts = questions[i].options, opts.count > 4 {
                questions[i].options = Array(opts.prefix(4))
            }
            let id = questions[i].id ?? ""
            if id.trimmingCharacters(in: .whitespaces).isEmpty {
                questions[i].id = "q\(i + 1)"
            }
        }
        return QuestionCardRequest(questions: questions)
    }

    /// 从回复块中解析澄清问题卡（无块、JSON 不合法或无有效题 → nil）。
    static func parseQuestionCard(blocks: [ArtifactBlock]) -> QuestionCardRequest? {
        guard let content = blocks.first(where: { $0.name == "question-card" })?.content,
              let raw = LenientJSON.decode(QuestionCardRequest.self, from: content) else {
            return nil
        }
        return normalizeQuestionCard(raw)
    }

    /// 自评摘要落盘：append 到对应阶段目录 self-review.jsonl（UI 可追溯）。
    static func writeSelfReview(
        _ radar: RadarReport, stage: String, project: String, version: String
    ) throws {
        struct ReviewEntry: Codable {
            var stage: String
            var radar: RadarReport
            var createdAt: String
        }
        let entry = ReviewEntry(stage: stage, radar: radar, createdAt: ISO8601.timestamp())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let dir: String
        switch stage {
        case "clarify": dir = "01-requirements"
        case "structure": dir = "02-structure"
        case "prototype": dir = "03-prototypes"
        default: dir = "04-prd"
        }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("\(dir)/self-review.jsonl")
        try PMAgentStore.appendLine(String(decoding: data, as: UTF8.self), to: url)
    }

    /// 决策条目 append 到 decisions.jsonl（write-then-verify 由 appendLine 保证）。
    static func writeDecisions(
        _ decisions: [DecisionRecord], project: String, version: String
    ) throws {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "decisions.jsonl"
        )
        for decision in decisions {
            try PMAgentStore.appendLine(decision, to: url)
        }
    }

    /// PRD 正文落盘：04-prd/PRD文档.md（write-then-verify，附变更摘要）。
    @discardableResult
    static func writePRDArtifact(
        blocks: [ArtifactBlock], tier: String, project: String, version: String
    ) throws -> (url: URL, changes: [FileChangeSummary])? {
        guard let body = blocks.first(where: { $0.name == "prd" })?.content,
              body.count > 200 else { return nil }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(ArtifactPath.prd)
        let change = try writeMeasured(
            body, to: url, relativePath: ArtifactPath.prd
        )
        return (url: url, changes: [change])
    }

    /// 截断兜底：未闭合 artifact:prd 块的部分正文（思考型模型思考 token 与正文
    /// 共用 max_tokens 池，撞线时围栏不闭合、解析不到完整块）。
    /// 部分正文足够长（>500 字符）才视为有效草稿，避免把零星残片落盘。
    static func prdTruncatedDraft(from text: String) -> String? {
        guard let (name, partial) = parseIncompleteArtifact(in: text),
              name == "prd", partial.count > 500 else { return nil }
        return partial
    }

    /// 竞品分析包落盘：05-analysis/竞品分析.md。
    @discardableResult
    static func writeAnalysisArtifact(
        blocks: [ArtifactBlock], project: String, version: String
    ) throws -> URL? {
        guard let body = blocks.first(where: { $0.name == "analysis" })?.content,
              body.count > 100 else { return nil }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(ArtifactPath.competitiveAnalysis)
        try PMAgentStore.writeVerified(body, to: url)
        return url
    }

    // MARK: - 澄清选项行（点选）

    struct ClarifyOptions: Equatable {
        var question: String
        var options: [String]
    }

    /// 解析回复末尾的「A) xxx」选项行（2-4 行才有效；0-1 行视为开放问题）。
    static func parseClarifyOptions(in text: String) -> ClarifyOptions? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        var optionLines: [String] = []
        var questionEnd = lines.count
        for (index, line) in lines.enumerated().reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let option = matchOptionLine(trimmed) {
                optionLines.insert(option, at: 0)
                questionEnd = index
            } else if !optionLines.isEmpty {
                break  // 选项行必须连续在末尾
            }
        }
        guard optionLines.count >= 2, optionLines.count <= 4 else { return nil }
        let question = lines[..<questionEnd]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClarifyOptions(question: question, options: optionLines)
    }

    private static func matchOptionLine(_ line: String) -> String? {
        // 「A) xxx」「A）xxx」「A. xxx」「A、xxx」
        let pattern = "^[A-D][）)．.、][ \\t]*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line, range: NSRange(location: 0, length: (line as NSString).length)
              ),
              match.numberOfRanges >= 2 else { return nil }
        let value = (line as NSString).substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

// MARK: - JSON 容错解析

nonisolated enum LenientJSON {

    /// 从模型回复中剥出首个 JSON 值（容忍围栏、前后废话）。
    static func extractJSONObject(from text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥 ```json ... ``` 围栏
        if cleaned.hasPrefix("```") {
            if let newline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: newline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 截取首个 { 或 [ 到与之配对的末字符
        guard let start = cleaned.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        let openChar = cleaned[start]
        let closeChar: Character = openChar == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var end: String.Index?
        var index = start
        while index < cleaned.endIndex {
            let ch = cleaned[index]
            if inString {
                if ch == "\\" {
                    index = cleaned.index(after: index)  // 跳过转义字符
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" { inString = true }
                else if ch == openChar { depth += 1 }
                else if ch == closeChar {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
            }
            index = cleaned.index(after: index)
        }
        guard let end else { return nil }
        return String(cleaned[start...end])
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

nonisolated extension String {
    func dropTrailingNewline() -> String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
