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
import CryptoKit

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

    // MARK: 闭合围栏口径（嵌套围栏安全协议）

    /// artifact 块解析共用正则：开栏反引号数 ≥3（PRD 等需内嵌围栏的产物用四反引号），
    /// 闭栏必须是「独行反引号围栏行且反引号数 = 开栏」（CommonMark：闭合围栏不得带
    /// info string）。如此 ```text / ```mermaid 等三反引号内嵌围栏（PRD 线框图）属于
    /// 正文，不会提前闭合产物块——旧正则 lazy 到第一个 ``` 就闭栏，任何带线框图的
    /// PRD 都会在第一张图处被截断，后续章节游离在块外落不了盘。
    /// lookbehind (?<!`)：禁止从更长反引号串的中间起配（四反引号块闭栏丢失时不得
    /// 退化为三反引号解析，否则截断块会绕过 prdTruncatedDraft 草稿兜底）。
    /// 捕获组：1 = 开栏围栏，2 = 块名，3 = 正文。
    private static let artifactBlockPattern =
        "(?sm)(?<!`)(`{3,})artifact:([a-zA-Z0-9_-]+)[ \\t]*\\n(.*?)^[ \\t]*\\1[ \\t]*(?=$|\\n)"

    /// 文本中是否存在「独行反引号围栏行且反引号数 ≥ minLength」
    /// （parseIncompleteArtifact 的流式闭栏口径，与 artifactBlockPattern 一致）。
    static func containsClosingFence(_ text: String, minLength: Int) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= minLength && trimmed.allSatisfy { $0 == "`" }
        }
    }

    /// 解析 ```artifact:<name> / ````artifact:<name> ... 围栏块。
    static func parseArtifactBlocks(in text: String) -> [ArtifactBlock] {
        var results: [ArtifactBlock] = []
        guard let regex = try? NSRegularExpression(pattern: artifactBlockPattern) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
        for match in matches where match.numberOfRanges >= 4 {
            let name = ns.substring(with: match.range(at: 2))
            let body = ns.substring(with: match.range(at: 3))
            results.append(ArtifactBlock(name: name, content: body.dropTrailingNewline()))
        }
        return results
    }

    /// 流式中未闭合的 artifact 围栏（最后一个 ```artifact: 标记到文末无闭合围栏）。
    /// 返回块名与已生成正文；nil = 无进行中的产物块（块已完成或后续还有正文）。
    /// 用途：流式渲染时收起进行中的长代码；隐藏哪些块名由调用方按策略过滤
    /// （prototype / prd 收进进度卡，其余文字型产物保留原文流式）。
    /// 闭栏口径与 parseArtifactBlocks 一致：独行反引号围栏行且反引号数 ≥ 开栏
    /// （四反引号产物块内的 ```text / 裸 ``` 三反引号围栏都是正文，不闭栏）。
    static func parseIncompleteArtifact(
        in text: String
    ) -> (name: String, partial: String)? {
        // 向后找标记；开栏可能是更长反引号（````artifact:），把前缀反引号数齐定闭栏长度
        guard let marker = text.range(of: "```artifact:", options: .backwards) else {
            return nil
        }
        var fenceStart = marker.lowerBound
        while fenceStart > text.startIndex,
              text[text.index(before: fenceStart)] == "`" {
            fenceStart = text.index(before: fenceStart)
        }
        let openingLength = text.distance(from: fenceStart, to: marker.lowerBound) + 3
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
        // 已出现闭栏围栏 → 该块已完成（后续可能有正文），不算进行中
        guard !containsClosingFence(body, minLength: openingLength) else { return nil }
        return (name: name, partial: body)
    }

    // MARK: 占位模仿残留清洗

    /// 模型把历史回灌占位当格式模仿的残留特征串（两次实测：2026-09-15 抄
    /// 「（产物已生成并落盘）」伪造落盘声明；2026-09-16 整句照抄反模仿标注）。
    /// 这些串是系统私有文案，业务正文不会合法包含，含任一特征的整行删除。
    /// （前缀匹配同时覆盖展示态长占位「（产物已生成并落盘——点击下方标签预览…）」。）
    nonisolated static let imitationMarkerPrefixes: [String] = [
        "【历史回复中的产物块已剥离省略",
        "（产物已生成并落盘",
    ]

    /// 清洗回复正文里的占位模仿残留（整行删除 + 收敛连续空行）。
    /// 消费点 = 历史回灌 / 气泡展示 / 抽取底稿等所有读取侧；落盘原文不动
    /// （文件系统仍是事实源），已污染的旧会话条目读取时同样受益。
    static func scrubImitatedPlaceholders(in text: String) -> String {
        guard imitationMarkerPrefixes.contains(where: { text.contains($0) }) else {
            return text
        }
        let cleaned = text
            .components(separatedBy: "\n")
            .filter { line in !imitationMarkerPrefixes.contains(where: { line.contains($0) }) }
            .joined(separator: "\n")
        var result = cleaned
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
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
        guard let regex = try? NSRegularExpression(pattern: artifactBlockPattern) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
        var result = text
        // 从后往前逐块替换：前面区间的 range 在已替换串中仍然有效
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            let name = ns.substring(with: match.range(at: 2))
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

    /// 产物并发冲突（阶段 0 乐观锁基座）：调用方携带的期望 SHA 与磁盘现状不符，
    /// 写入在触盘前已取消，磁盘文件保持未动。actualSHA = 磁盘现状内容的 SHA256；
    /// nil = 文件已消失或不可读（期望有存量而磁盘没有，同样视为失配）。
    /// 阶段 0 只建立检测管道（writeMeasured 的 expectedSHA 闸 + writePrototypeArtifact
    /// 的 expectedSnapshot 透传），冲突场景构造与修订文件名生成属后续阶段。
    struct ArtifactConflict: Error, LocalizedError {
        let path: String
        let actualSHA: String?

        var errorDescription: String? {
            switch actualSHA {
            case .some(let sha):
                "产物已被外部修改，为避免覆盖已取消写入：\(path)（磁盘 SHA256 \(sha)）"
            case .none:
                "产物文件已不存在或不可读，写入已取消：\(path)"
            }
        }
    }

    /// 文本 SHA256 十六进制摘要（产物冲突检测的指纹口径，CryptoKit）。
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct StructureArtifacts: Equatable {
        var architecture: String   // 功能架构图.md 全文
        var coreFlows: String      // 核心流程图.md 全文
        var modulePageMap: String  // 模块-页面映射表.md 全文
        var businessFlows: String? // 仅复杂产品
        var changes: [FileChangeSummary] = [] // 本次落盘的文件变更摘要
    }

    /// 落盘并测量变更：读旧内容 → writeVerified → 行级 diff 摘要。
    /// 文件不存在 → isNew；存在但读取失败 → (0, 0)，宁可少显示不虚报。
    /// expectedSHA 非 nil 时做乐观并发校验：对磁盘现状内容算 SHA256（文件缺失 /
    /// 不可读视为失配——期望有存量而磁盘没有），失配抛 ArtifactConflict 且磁盘
    /// 文件保持未动；nil 时不校验，行为与旧口径完全一致。
    private static func writeMeasured(
        _ content: String, to url: URL, relativePath: String,
        expectedSHA: String? = nil
    ) throws -> FileChangeSummary {
        var isNew = true
        var old: String?
        if FileManager.default.fileExists(atPath: url.path) {
            isNew = false
            old = try? String(contentsOf: url, encoding: .utf8)
        }
        if let expectedSHA {
            guard !isNew, let old else {
                throw ArtifactConflict(path: relativePath, actualSHA: nil)
            }
            let actualSHA = sha256Hex(old)
            guard actualSHA == expectedSHA else {
                throw ArtifactConflict(path: relativePath, actualSHA: actualSHA)
            }
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
    /// 三项块名缺一或正文为空即整体不落盘（返回空 changes），避免写出只有标题的
    /// 占位文件——那会让产物台账出现用户从未真正生成的文档。
    @discardableResult
    static func writeStructureArtifacts(
        blocks: [ArtifactBlock], project: String, version: String,
        proposalSessionId: String? = nil
    ) throws -> StructureArtifacts {
        // 同名块 first-wins（与原型落盘同口径）：模型重复输出同一块不得 trap
        let byName = Dictionary(
            blocks.map { ($0.name, $0.content) }, uniquingKeysWith: { first, _ in first }
        )
        func nonBlank(_ name: String) -> String? {
            guard let raw = byName[name],
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return raw
        }
        guard let arch = nonBlank("architecture"),
              let flows = nonBlank("core-flows"),
              let map = nonBlank("module-page-map") else {
            return StructureArtifacts(
                architecture: byName["architecture"] ?? "",
                coreFlows: byName["core-flows"] ?? "",
                modulePageMap: byName["module-page-map"] ?? "",
                businessFlows: byName["business-flows"]
            )
        }

        // 草稿预演（B1）：proposalSessionId 非 nil 时镜像落提案目录，不碰主线
        let dir = PMAgentStore.artifactRoot(
            project: project, version: version, proposalSessionId: proposalSessionId
        )

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
        if let business = nonBlank("business-flows") {
            changes.append(try writeMeasured(
                "# 业务流程图\n\n```mermaid\n\(business)\n```\n",
                to: dir.appendingPathComponent(ArtifactPath.businessFlows),
                relativePath: ArtifactPath.businessFlows
            ))
        }

        return StructureArtifacts(
            architecture: arch, coreFlows: flows, modulePageMap: map,
            businessFlows: nonBlank("business-flows"),
            changes: changes
        )
    }

    /// 结构阶段必出的三项产物块名（闸口最低集）。
    static let requiredStructureBlockNames: Set<String> = [
        "architecture", "core-flows", "module-page-map",
    ]

    /// 结构产物是否已齐（闸口放行的最低集）：三项块名齐全**且各有正文**。
    /// 只查块名会让空块过闸，落盘成只有标题的占位文件。
    static func structureArtifactsComplete(_ blocks: [ArtifactBlock]) -> Bool {
        let names = Set(blocks.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.name))
        return requiredStructureBlockNames.isSubset(of: names)
    }

    /// 本轮回复是否尝试过结构产物（出现任一必出块名）。
    /// 用于区分「试了但没齐」与「本轮本就不产结构物」（如仅计划提案块）——
    /// 前者要落 ⚠️ 留痕，后者不该误报。
    static func hasStructureBlocks(_ blocks: [ArtifactBlock]) -> Bool {
        blocks.contains { requiredStructureBlockNames.contains($0.name) }
    }

    /// 多端原型落盘结果：逐槽位（块名 / 相对路径 / 显示名）+ 全部文件变更摘要。
    nonisolated struct PrototypeArtifacts: Equatable {
        struct Slot: Equatable {
            var blockName: String
            var relPath: String
            var display: String
        }
        var slots: [Slot]
        var changes: [FileChangeSummary]
    }

    /// 原型 HTML 落盘：原型类块（artifact:prototype / prototype-<slug> 分端槽位）
    /// 逐块落独立文件（按回复中出现顺序，同名块 first-wins，附行级变更摘要）；
    /// 零合法块（无原型块 / 内容不含 "<"）返回 nil。部分截断天然降级：
    /// parseArtifactBlocks 只收已闭合块，闭合的槽位照常落盘，未闭合的由调用方单独提示。
    /// 阶段 0 透传管道（默认参数下行为完全不变）：
    /// - slotOverrides：块名 → 改落的相对路径；块落盘前查表，命中则改落该路径
    ///   （不查槽位合法性，调用方负责；改落路径同时回填 slots）。
    /// - expectedSnapshot：相对路径 → 期望 SHA256；对本次实际目标路径（含 override
    ///   改落后）查表，命中传 expectedSHA 给 writeMeasured 做乐观校验，失配抛
    ///   ArtifactConflict。冲突场景构造与修订文件名生成属后续阶段。
    @discardableResult
    static func writePrototypeArtifact(
        blocks: [ArtifactBlock], project: String, version: String,
        expectedSnapshot: [String: String]? = nil,
        slotOverrides: [String: String]? = nil,
        proposalSessionId: String? = nil
    ) throws -> PrototypeArtifacts? {
        var seen = Set<String>()
        var ordered: [(name: String, html: String)] = []
        for block in blocks where ArtifactPath.isPrototypeBlock(block.name) {
            guard block.content.contains("<"), !seen.contains(block.name) else { continue }
            seen.insert(block.name)
            ordered.append((block.name, block.content))
        }
        guard !ordered.isEmpty else { return nil }
        var slots: [PrototypeArtifacts.Slot] = []
        var changes: [FileChangeSummary] = []
        for (name, html) in ordered {
            guard let slot = ArtifactPath.prototypeSlot(forBlockName: name) else { continue }
            let relPath = slotOverrides?[name] ?? slot.relPath
            // 草稿预演（B1）：落提案目录镜像，跳过主线槽位冲突检测（草稿无并发写）
            let url = PMAgentStore.artifactRoot(
                project: project, version: version, proposalSessionId: proposalSessionId
            ).appendingPathComponent(relPath)
            let change = try writeMeasured(
                html, to: url, relativePath: relPath,
                expectedSHA: proposalSessionId == nil ? expectedSnapshot?[relPath] : nil
            )
            slots.append(.init(blockName: name, relPath: relPath, display: slot.display))
            changes.append(change)
        }
        return PrototypeArtifacts(slots: slots, changes: changes)
    }

    // MARK: - M3：漏项雷达 / 决策 WHY / 评分卡 / PRD

    /// 本轮任务计划卡（artifact:plan 块，plan-act-reflect 的 plan 段）：
    /// ②③④ 生成/修订产物的轮次，模型先输出计划再执行——执行顺序、自查锚点
    /// 对用户可见（思考卡之外的第一个结构化产物）。act = 产物块本体，
    /// reflect = 既有内建自评审（radar 对照计划逐项自查）。
    struct PlanCard: Codable, Equatable {
        struct Step: Codable, Equatable {
            /// 步骤内容（做什么、产出什么）。
            var action: String
            /// 依据（上游产物 / 用户要求，可省略）。
            var basis: String?

            enum CodingKeys: String, CodingKey {
                case action = "do"
                case basis
            }
        }
        /// 本轮任务一句话目标。
        var mission: String?
        var steps: [Step]
    }

    /// 从回复块中解析计划卡（无块或 JSON 不合法 → nil；无有效步骤 → nil）。
    /// 归一化：步骤 clamp ≤ 8、空步骤丢弃、mission 空白置 nil。
    static func parsePlan(blocks: [ArtifactBlock]) -> PlanCard? {
        guard let content = blocks.first(where: { $0.name == "plan" })?.content,
              let raw = LenientJSON.decode(PlanCard.self, from: content) else {
            return nil
        }
        return normalizedPlan(raw)
    }

    /// 计划卡归一化（自宣计划与提案计划共用）：步骤 clamp ≤ 8、空步骤丢弃、
    /// mission 空白置 nil；无有效步骤 → nil。
    static let planStepLimit = 8

    private static func normalizedPlan(_ raw: PlanCard) -> PlanCard? {
        var plan = raw
        plan.mission = plan.mission?.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan.mission?.isEmpty == true { plan.mission = nil }
        var steps = Array(plan.steps.prefix(planStepLimit))
        steps.removeAll {
            $0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !steps.isEmpty else { return nil }
        plan.steps = steps
        return plan
    }

    /// 执行计划提案（artifact:plan-proposal 块，P0-2 计划提案权）：②③④ 产物
    /// 首次生成前，模型先交一页「打算怎么做」的草案，用户经计划裁决卡批准 /
    /// 补充 / 跳过后才执行正式生成。LLM 只提案，执行由用户裁决——闸口不变量不破。
    /// 与 plan 块（轮内自宣计划，plan-act-reflect 的 plan 段）区分块名：
    /// 自宣计划随产物轮渲染、不需裁决；提案计划独立成轮、必须裁决后才生成。
    static func parsePlanProposal(blocks: [ArtifactBlock]) -> PlanCard? {
        guard let content = blocks.first(where: { $0.name == "plan-proposal" })?.content,
              let raw = LenientJSON.decode(PlanCard.self, from: content) else {
            return nil
        }
        return normalizedPlan(raw)
    }


    /// 漏项雷达四档声明（artifact:radar 块，design.md §6.2 自评审）。
    struct RadarReport: Codable, Equatable {
        struct Skipped: Codable, Equatable {
            var point: String
            var reason: String
        }
        struct Fatal: Codable, Equatable {
            var hypothesis: String
            /// 后果——具体影响（方案 A 台账行内展示）
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
    /// 2026-09-16 写入时富化：话题闭合时可选携带 topic / user_ask /
    /// turning_points 与备选所有权标注（owner）——全部可选，旧格式不受影响。
    /// 2026-09-17 结论依据富化：basis 三槽（数据/逻辑/事实案例），话题闭合必填。
    struct DecisionDraft: Codable, Equatable {
        var decision: String
        var why: String
        var rejected: [RejectedAlternative]?
        var confidence: Double?
        var toBeVerified: Bool?
        var topic: String?
        var userAsk: String?
        var turningPoints: [TurningPoint]?
        var basis: Basis?
        /// 推翻的旧否决引用键（2026-09-18 supersedes 协议，可选）。
        var supersedes: [String]?

        enum CodingKeys: String, CodingKey {
            case decision, why, rejected, confidence
            case toBeVerified = "to_be_verified"
            case topic
            case userAsk = "user_ask"
            case turningPoints = "turning_points"
            case basis
            case supersedes
        }

        /// basis 草稿（三槽全可选，AI 缺槽照填其余；全空由 DecisionBasis.isEmpty 兜）。
        struct Basis: Codable, Equatable {
            var data: String?
            var logic: String?
            var facts: String?
        }

        /// 补全默认值 → DecisionRecord（version 由调用侧填）。
        func record(version: String) -> DecisionRecord {
            DecisionRecord(
                version: version,
                decision: decision,
                why: why,
                rejectedAlternatives: rejected ?? [],
                confidence: confidence.map { min(max($0, 0), 1) } ?? 1.0,
                toBeVerified: toBeVerified ?? false,
                topic: topic,
                userAsk: userAsk,
                turningPoints: turningPoints,
                basis: basis.map { DecisionBasis(
                    data: $0.data, logic: $0.logic, facts: $0.facts
                ) },
                supersedes: supersedes
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

    /// 变更提案请求（artifact:backtrack 块）：③④ 阶段 LLM 识别新需求/重做上游意图时输出，
    /// 不产出本阶段产物。App 校验 target 白名单（AppModel.backtrackStage）后**不直接执行**——
    /// 转成变更提案卡（影响清单 + 建议）交用户裁决：纳入 / 进池 / 继续讨论。
    /// LLM 只分诊提案，不裁决执行。
    /// suggestion：now（建议立即回退，target 必填）| pool（建议进候选池，target 可省略）；
    ///             缺省按 now（向后兼容旧协议块）。
    /// impacts：受影响产物引用清单——suggestion=now 时的防轻描淡写硬约束：
    ///          缺失/为空则 App 侧不采信 target（提案卡降级为无回退建议，仅登记）。
    struct BacktrackRequest: Codable, Equatable {
        var suggestion: String?  // "now" | "pool"（缺省 now）
        var target: String?      // structure | prototype | clarify（pool 块可省略）
        var idea: String?        // 新想法/诉求一句话概述
        var category: String?    // 局部修订 | 页面流程 | 模块核心 | 目标范围 | 需验证
        var impacts: [String]?   // 受影响产物引用清单
        var instruction: String? // 用户的具体修改要求（重生成合成指令的载荷）
        var mode: String?        // "revise" | "redo"（缺省按 revise）
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

    /// 路线建议（artifact:route 块）：① 澄清收束前 Agent 主动建议流转路径，
    /// 仅展示不执行——路径仍由用户在确认坞选择。与 fast-forward（用户明确要求
    /// 才输出）互补：这是 Agent 的自主提议面（LLM 提议、App 展示、人裁决）。
    struct RouteProposal: Codable, Equatable {
        var recommend: String   // standard | skip_structure | direct_prd
        var reasons: [String]?  // 1-3 条具体理由
        var basis: String?      // 判断依据（引用澄清事实）
    }

    /// 从回复块中解析路线建议（无块或 JSON 不合法 → nil）。
    static func parseRoute(blocks: [ArtifactBlock]) -> RouteProposal? {
        guard let content = blocks.first(where: { $0.name == "route" })?.content else {
            return nil
        }
        return LenientJSON.decode(RouteProposal.self, from: content)
    }

    /// 澄清问题卡（artifact:question-card 块）：① 阶段 LLM 输出相互独立的事实型问题集，
    /// App 渲染为向导卡片批量收集，答案拼装为【问题卡作答】用户消息回传。
    /// purpose 区分变体：缺省 = ① 澄清卡；prd_preflight = PRD 前置确认卡（提交改道快速通道）、
    /// prd_defaults = PRD 默认项卡（提交走常规修订）。purpose 仅 App 分流用，不进向导 UI。
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
        /// 卡用途标记（缺省 nil = ① 澄清卡）：prd_preflight / prd_defaults，见类型注释。
        var purpose: String?
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
        return QuestionCardRequest(questions: questions, purpose: raw.purpose)
    }

    /// 从回复块中解析澄清问题卡（无块、JSON 不合法或无有效题 → nil）。
    static func parseQuestionCard(blocks: [ArtifactBlock]) -> QuestionCardRequest? {
        guard let content = blocks.first(where: { $0.name == "question-card" })?.content,
              let raw = LenientJSON.decode(QuestionCardRequest.self, from: content) else {
            return nil
        }
        return normalizeQuestionCard(raw)
    }

    /// 自评审对账条目（self-review.jsonl 行类型）：Inspector 对账 trace 与
    /// 跨轮新增 diff 共用（B3 事件驱动改版——契约四档保留，落盘全量审计）。
    struct SelfReviewEntry: Codable, Equatable {
        var stage: String
        var radar: RadarReport
        var createdAt: String
    }

    /// 自评摘要落盘：append 到对应阶段目录 self-review.jsonl（UI 可追溯）。
    /// 直接 appendLine(entry) 单层 JSON 行——旧实现经 appendLine(String) 传预编码
    /// 文本会二次编码（外层 JSON 字符串包裹），readSelfReviews 已做双格式兼容。
    static func writeSelfReview(
        _ radar: RadarReport, stage: String, project: String, version: String
    ) throws {
        let entry = SelfReviewEntry(stage: stage, radar: radar, createdAt: ISO8601.timestamp())
        let dir: String
        switch stage {
        case "clarify": dir = "01-requirements"
        case "structure": dir = "02-structure"
        case "prototype": dir = "03-prototypes"
        default: dir = "04-prd"
        }
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("\(dir)/self-review.jsonl")
        try PMAgentStore.appendLine(entry, to: url)
    }

    /// 对账 trace 读取：四个阶段目录的 self-review.jsonl 合并，按时间正序
    /// （covered 全量明细的审计归宿——对话流事件化后 Inspector 承载可审计性）。
    /// 行格式双兼容：新格式单层 JSON；旧格式 appendLine(String) 双重编码行
    /// （外层 JSON 字符串），先解条目、失败剥一层再解。秒级时间戳同秒时按
    /// 落盘顺序 tie-break（jsonl 行序即时间序，append-only）。
    static func readSelfReviews(project: String, version: String) -> [SelfReviewEntry] {
        let base = PMAgentStore.versionURL(project: project, version: version)
        let decoder = JSONDecoder()
        var entries: [(offset: Int, entry: SelfReviewEntry)] = []
        for dir in ["01-requirements", "02-structure", "03-prototypes", "04-prd"] {
            let url = base.appendingPathComponent("\(dir)/self-review.jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard !line.isEmpty else { continue }
                let data = Data(line.utf8)
                if let entry = try? decoder.decode(SelfReviewEntry.self, from: data) {
                    entries.append((entries.count, entry))
                } else if let inner = try? decoder.decode(String.self, from: data),
                          let entry = try? decoder.decode(
                              SelfReviewEntry.self, from: Data(inner.utf8)
                          ) {
                    entries.append((entries.count, entry))
                }
            }
        }
        return entries
            .sorted { a, b in
                a.entry.createdAt == b.entry.createdAt
                    ? a.offset < b.offset
                    : a.entry.createdAt < b.entry.createdAt
            }
            .map(\.entry)
    }

    // MARK: - 声明归一化与跨轮 diff（B3 事件驱动：对话流只报新增）

    /// 匹配口径：大小写折叠 + 全部空白移除（中文场景空白插入是重播微差的
    /// 主要形态，删除比规范化更有效；英文多词声明的重组误合并风险可忽略）。
    /// 模型重播同一声明时字面常有微差，归一化精确匹配先挡大头（语义级近似
    /// 不做，避免误杀）。
    static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined()
    }

    /// 文本数组的新增项：不在上轮集合中的条目（保持本轮顺序）。
    static func newItems(current: [String], previous: [String]) -> [String] {
        let seen = Set(previous.map(normalizedText))
        return current.filter { !seen.contains(normalizedText($0)) }
    }

    /// ⏭️ skipped 的新增项（point 归一化匹配）。
    static func newSkipped(
        current: [RadarReport.Skipped], previous: [RadarReport.Skipped]
    ) -> [RadarReport.Skipped] {
        let seen = Set(previous.map { normalizedText($0.point) })
        return current.filter { !seen.contains(normalizedText($0.point)) }
    }

    /// 💀 fatal 的新增项：与既有风险记录（任意状态）的 hypothesis 归一化匹配
    /// 去重——重播不重复登记（字面相同的重播不进台账；文本有变的复发视作新声明）。
    static func newFatals(
        current: [RadarReport.Fatal], existingHypotheses: [String]
    ) -> [RadarReport.Fatal] {
        let seen = Set(existingHypotheses.map(normalizedText))
        return current.filter { !seen.contains(normalizedText($0.hypothesis)) }
    }

    /// 决策条目 append 到 decisions.jsonl（write-then-verify 由 appendLine 保证）。
    /// 锁约定：整批决策在 PMAgentStore.ioLock 持锁段内经 appendLineLocked 追加
    /// （同批行在文件中连续，不与并发写入器交错；appendLineLocked 不重复加锁）。
    static func writeDecisions(
        _ decisions: [DecisionRecord], project: String, version: String
    ) throws {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "decisions.jsonl"
        )
        PMAgentStore.ioLock.lock()
        defer { PMAgentStore.ioLock.unlock() }
        for decision in decisions {
            try PMAgentStore.appendLineLocked(decision, to: url)
        }
    }

    // MARK: - PRD 图表引用槽拼接（2026-09-18 确定性拼接）

    /// 拼接结果：text = 槽位替换后的全文；unresolved 供度量（行内已带警示，不静默）。
    nonisolated struct MermaidStitch: Equatable {
        var text: String
        var resolvedCount: Int
        var unresolvedSlots: [String]
    }

    /// 扫描文本中全部 ```mermaid 围栏块（返回围栏内源码，按出现顺序）。纯函数。
    static func mermaidBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var collecting: [String]? = nil
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if collecting == nil {
                if line.hasPrefix("```mermaid") { collecting = [] }
            } else if line == "```" {
                blocks.append(collecting!.joined(separator: "\n"))
                collecting = nil
            } else {
                collecting!.append(rawLine)
            }
        }
        return blocks
    }

    /// 图表引用槽拼接（纯函数，测试直测）：PRD 正文中独占一行的
    /// `[[MERMAID:名称]]` / `[[MERMAID:名称#N]]` 替换为 sources[名称] 中的第 N 张
    /// mermaid 图（N 缺省 1）。模型只写引用不抄源码——省转抄输出 tokens，且
    /// 落盘图与已确认材料逐字一致（「成品复用」的确定性形态，opencode/OpenHands
    /// 「不让模型搬运已知内容」思路的落盘侧实现）。未解析槽位降级为行内警示
    ///（文档可见、不静默、不虚构内容）。
    static func stitchMermaidSlots(
        in body: String, sources: [String: String]
    ) -> MermaidStitch {
        var resolved = 0
        var unresolved: [String] = []
        var blocksCache: [String: [String]] = [:]
        let outLines = body.components(separatedBy: "\n").map { rawLine -> String in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[[MERMAID:"), line.hasSuffix("]]") else { return rawLine }
            let inner = line.dropFirst("[[MERMAID:".count).dropLast(2)
            let parts = inner.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first.map(String.init) ?? ""
            let indexPart = parts.count > 1 ? parts[1] : "1"[...]
            guard !name.isEmpty, let index = Int(indexPart), index >= 1,
                  let source = sources[name] else {
                unresolved.append(line)
                return "> ⚠️ 图表引用未解析：\(line)（已确认材料中无对应图）"
            }
            if blocksCache[name] == nil { blocksCache[name] = mermaidBlocks(in: source) }
            let blocks = blocksCache[name]!
            guard index <= blocks.count else {
                unresolved.append(line)
                return "> ⚠️ 图表引用未解析：\(line)（已确认材料中无对应图）"
            }
            resolved += 1
            return "```mermaid\n\(blocks[index - 1])\n```"
        }
        return MermaidStitch(
            text: outLines.joined(separator: "\n"),
            resolvedCount: resolved,
            unresolvedSlots: unresolved
        )
    }

    /// PRD 正文落盘：04-prd/PRD文档.md（write-then-verify，附变更摘要）。
    @discardableResult
    static func writePRDArtifact(
        blocks: [ArtifactBlock], tier: String, project: String, version: String,
        proposalSessionId: String? = nil
    ) throws -> (url: URL, changes: [FileChangeSummary])? {
        guard let body = blocks.first(where: { $0.name == "prd" })?.content,
              body.count > 200 else { return nil }
        // 图表引用槽拼接：正文中的 [[MERMAID:…]] 槽位替换为已确认结构产物中的
        // 图表源码（读主版本目录即时解析；提案目录镜像同样用主线已确认材料）。
        let root = PMAgentStore.versionURL(project: project, version: version)
        func source(_ rel: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }
        let stitch = stitchMermaidSlots(in: body, sources: [
            "功能架构图": source(ArtifactPath.architecture),
            "核心流程图": source(ArtifactPath.coreFlows),
            "业务流程图": source(ArtifactPath.businessFlows),
        ])
        // 草稿预演（B1）：落提案目录镜像，不碰主线
        let url = PMAgentStore.artifactRoot(
            project: project, version: version, proposalSessionId: proposalSessionId
        ).appendingPathComponent(ArtifactPath.prd)
        let change = try writeMeasured(
            stitch.text, to: url, relativePath: ArtifactPath.prd
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

    /// 非 PRD 阶段的 stray PRD 块检测（AppModel 落盘分派兜底提示用）：
    /// 回复携带闭合可解析的 prd 块，或存在未闭合的 prd 围栏（截断）——两者在
    /// 非 PRD 阶段的落盘分派里都没有消费者，会被静默丢弃（2026-09-17「AI 宣称
    /// 出 PRD 却没落盘」零反馈事故）。.prd 阶段不调用：闭合块正常落盘，
    /// 未闭合块走 prdTruncatedDraft 截断草稿兜底。
    static func hasStrayPRDBlock(blocks: [ArtifactBlock], text: String) -> Bool {
        if blocks.contains(where: { $0.name == "prd" }) { return true }
        return parseIncompleteArtifact(in: text)?.name == "prd"
    }

    /// 回复中是否存在可落盘的原型块（块名属原型类 + 正文含 HTML 标记）。
    /// 收块口径与 writePrototypeArtifact 完全一致——顺收判据不能比落盘判据更宽，
    /// 否则会「判定可收 → 落盘返回 nil」，回到静默丢弃。
    static func hasWritablePrototypeBlock(_ blocks: [ArtifactBlock]) -> Bool {
        blocks.contains {
            ArtifactPath.isPrototypeBlock($0.name) && $0.content.contains("<")
        }
    }

    /// 非原型阶段的 stray 原型块检测（AppModel 落盘分派兜底提示用）：闭合原型块
    /// （含正文无 HTML 的无效块）或未闭合原型围栏（截断）任一存在即算。与
    /// hasStrayPRDBlock 同一纪律——两者在别的阶段分派里没有消费者。
    static func hasStrayPrototypeBlock(blocks: [ArtifactBlock], text: String) -> Bool {
        if blocks.contains(where: { ArtifactPath.isPrototypeBlock($0.name) }) { return true }
        guard let incomplete = parseIncompleteArtifact(in: text) else { return false }
        return ArtifactPath.isPrototypeBlock(incomplete.name)
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

    /// 选项行问题组（选项式提问路径的一组）：题干收尾行 + 连续 2-4 行 A-D 选项。
    /// 模型未走问题卡协议一次抛多问时，回复里会出现多组——逐组解析后转问题卡向导逐题作答。
    struct OptionLineQuestionGroup: Equatable {
        var title: String      // 题干收尾行（尾部代码围栏块 / 围栏残行已剥离）
        var options: [String]
    }

    /// 选项行问题组解析结果：问题组按出现顺序 + 剥除所有组选项行后的正文（消息流折叠用）。
    struct OptionLineQuestionGroups: Equatable {
        var questions: [OptionLineQuestionGroup]
        /// 所有组选项行剥除后的回复正文（题干与散文保留）。
        var bodyText: String
        /// 回复带「[收尾确认]」标记（① 澄清收尾确认问协议）：单组时用户点选
        /// 「确认」开头选项即视为闸口确认（一次确认，AppModel.confirmStageByAnswer）。
        var gateConfirm: Bool
    }

    /// 收尾确认标记行（① 澄清收尾确认问独占尾行；兼容全角括号变体）。
    static let gateConfirmMarkers: Set<String> = ["[收尾确认]", "【收尾确认】"]

    /// 解析回复中的选项行问题组：每组 = 连续 2-4 行「A) xxx」；最后一组必须收尾在回复末尾
    /// （选项式提问历史口径：选项行连续在末尾，中途出现不触发）。题干取组前最近的有效文字行。
    /// 尾部「[收尾确认]」标记行先剥离再解析（剥离后选项行重新收尾在末尾）。
    /// 无有效组 → nil。
    static func parseOptionLineQuestionGroups(in text: String) -> OptionLineQuestionGroups? {
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let gateConfirm = lines.contains(where: { Self.gateConfirmMarkers.contains($0) })
        if gateConfirm {
            lines = lines.filter { !Self.gateConfirmMarkers.contains($0) }
        }
        guard !lines.isEmpty else { return nil }

        // 前向扫描：连续 2-4 行 A-D 选项行 = 一组（超 4 行视为列表散文，不成组；
        // 组间至少隔一行非选项行，相邻会并成一组）
        var runs: [(start: Int, end: Int, options: [String])] = []
        var i = 0
        while i < lines.count {
            if matchOptionLine(lines[i]) != nil {
                var j = i
                var opts: [String] = []
                while j < lines.count, let opt = matchOptionLine(lines[j]), opts.count < 5 {
                    opts.append(opt)
                    j += 1
                }
                if opts.count >= 2, opts.count <= 4 {
                    runs.append((i, j, opts))
                }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        // 最后一组必须收尾在回复末尾
        guard let lastRun = runs.last, lastRun.end == lines.count else { return nil }

        // 每组题干 = 组前最近的有效文字行（首组取其前的正文；后续组取上一组选项行之后的收尾段）
        var questions: [OptionLineQuestionGroup] = []
        var optionLineIndexes = Set<Int>()
        for run in runs {
            for k in run.start..<run.end { optionLineIndexes.insert(k) }
        }
        for (runIndex, run) in runs.enumerated() {
            let stemSlice: Array<String>
            if runIndex == 0 {
                stemSlice = Array(lines[..<run.start])
            } else {
                stemSlice = Array(lines[runs[runIndex - 1].end..<run.start])
            }
            let title = stemTitle(from: stemSlice) ?? "问题 \(runIndex + 1)"
            questions.append(OptionLineQuestionGroup(title: title, options: run.options))
        }

        let body = lines.enumerated()
            .filter { !optionLineIndexes.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
        return OptionLineQuestionGroups(
            questions: questions,
            bodyText: body.trimmingCharacters(in: .whitespacesAndNewlines),
            gateConfirm: gateConfirm
        )
    }

    /// 题干收尾行：切片最后一行非围栏文字。尾部若收着代码块（``` 围栏成对）整块跳过，
    /// 未配对的孤立围栏残行（流式截断 / 双围栏收尾）也跳过——题干不能显示成「```」。
    private static func stemTitle(from lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        var end = lines.count
        if lines[end - 1].hasPrefix("```") {
            var depth = 1
            var index = end - 2
            while index >= 0, depth > 0 {
                if lines[index].hasPrefix("```") { depth -= 1 }
                index -= 1
            }
            end = index + 1  // 开启围栏之前的正文收尾段
        }
        while end > 0, lines[end - 1].hasPrefix("```") { end -= 1 }
        return lines[..<end].last
    }

    /// 单组视图（兼容旧口径）：末尾连续 A)/B) 选项行作为一道题，题干 = 剥除选项行后的正文。
    /// 多组回复返回 nil（多组由 parseOptionLineQuestionGroups 消费、转问题卡向导）。
    static func parseClarifyOptions(in text: String) -> ClarifyOptions? {
        guard let groups = parseOptionLineQuestionGroups(in: text), groups.questions.count == 1
        else { return nil }
        return ClarifyOptions(question: groups.bodyText, options: groups.questions[0].options)
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
