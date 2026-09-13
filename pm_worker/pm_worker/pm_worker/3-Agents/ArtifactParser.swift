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
    /// （当前仅 prototype 收进进度卡，PRD 等文字型产物保留原文流式）。
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
        var architecture: String   // architecture.md 全文
        var coreFlows: String      // core-flows.md 全文
        var modulePageMap: String  // module-page-map.md 全文
        var businessFlows: String? // 仅复杂产品
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
            .appendingPathComponent("02-structure", isDirectory: true)

        try PMAgentStore.writeVerified(
            "# 功能架构图\n\n```mermaid\n\(arch)\n```\n",
            to: dir.appendingPathComponent("architecture.md")
        )
        try PMAgentStore.writeVerified(
            "# 核心流程图（P0 场景用户路径）\n\n```mermaid\n\(flows)\n```\n",
            to: dir.appendingPathComponent("core-flows.md")
        )
        try PMAgentStore.writeVerified(
            "# 模块-页面映射表\n\n\(map)\n",
            to: dir.appendingPathComponent("module-page-map.md")
        )
        if let business = byName["business-flows"], !business.isEmpty {
            try PMAgentStore.writeVerified(
                "# 业务流程图\n\n```mermaid\n\(business)\n```\n",
                to: dir.appendingPathComponent("business-flows.md")
            )
        }

        return StructureArtifacts(
            architecture: arch, coreFlows: flows, modulePageMap: map,
            businessFlows: byName["business-flows"]
        )
    }

    /// 结构产物是否已齐（闸口放行的最低集）。
    static func structureArtifactsComplete(_ blocks: [ArtifactBlock]) -> Bool {
        let names = Set(blocks.map(\.name))
        return Set(["architecture", "core-flows", "module-page-map"]).isSubset(of: names)
    }

    /// 原型 HTML 落盘到 03-prototypes/prototype-v1.html。
    @discardableResult
    static func writePrototypeArtifact(
        blocks: [ArtifactBlock], project: String, version: String
    ) throws -> URL? {
        guard let html = blocks.first(where: { $0.name == "prototype" })?.content,
              html.contains("<") else { return nil }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("03-prototypes/prototype-v1.html")
        try PMAgentStore.writeVerified(html, to: url)
        return url
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
            var triggerSignal: String

            enum CodingKeys: String, CodingKey {
                case hypothesis
                case triggerSignal = "trigger_signal"
            }

            /// 转 RiskRecord.TriggerSignal（未知信号返回 nil，调用侧丢弃防悬空）。
            var signal: RiskRecord.TriggerSignal? {
                RiskRecord.TriggerSignal(rawValue: triggerSignal)
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

    /// PRD 正文落盘：04-prd/prd-v1.md（write-then-verify）。
    @discardableResult
    static func writePRDArtifact(
        blocks: [ArtifactBlock], tier: String, project: String, version: String
    ) throws -> URL? {
        guard let body = blocks.first(where: { $0.name == "prd" })?.content,
              body.count > 200 else { return nil }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("04-prd/prd-v1.md")
        try PMAgentStore.writeVerified(body, to: url)
        return url
    }

    /// 竞品分析包落盘：05-analysis/competitive-analysis.md。
    @discardableResult
    static func writeAnalysisArtifact(
        blocks: [ArtifactBlock], project: String, version: String
    ) throws -> URL? {
        guard let body = blocks.first(where: { $0.name == "analysis" })?.content,
              body.count > 100 else { return nil }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("05-analysis/competitive-analysis.md")
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
