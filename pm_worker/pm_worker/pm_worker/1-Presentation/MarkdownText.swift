//
//  MarkdownText.swift
//  pm_worker
//
//  对话页 Markdown 渲染（参考 Trae 对话样式）：
//  · 块级解析 MarkdownParser.parseBlocks——手写逐行扫描：标题 #~######、
//    段落、围栏代码块（``` / ~~~，未闭合容错到文末）、引用 >、无序/有序列表
//    （2 空格一层嵌套）、分隔线、管道表格（含 :---: 对齐）
//  · 行内富文本 MarkdownParser.inline——Foundation 原生 AttributedString(markdown:)
//    （CommonMark 语义：**粗体** / __粗体__ / *斜体* / `行内代码` / ~~删除~~ /
//    [链接](url)，含嵌套与转义），解析失败回退纯文本保证渲染稳定
//  · 渲染 MarkdownText——DS 令牌排版（2026-09-15 方案 A「阅读栏 · 刻度阶梯」，
//    见 DS.Typography 对话令牌组）：层级 = 字级刻度阶梯 + 样式差协同 + 阅读栏宽——
//    标题 26 / 21 衬线（h1·h2）与 17 / 15（h3·h4，衬线退场、刻度线随 h4）、
//    导语 16（首段含加粗）、正文 15、小节标签 13（h5·h6 次级色）、
//    表格 13.5（表头 12.5 semibold）、行内代码 12.5、代码块 mono 13。
//    散文（标题/段落/列表/引用）收在 chatMeasure 640 阅读栏内，表格 / 代码 /
//    图表留列宽 720——「读的」与「看的」两条宽度线。
//    代码块带语言标签 + 复制钮（复制后 ✓ 反馈）。全部颜色走 DS 动态令牌。
//

import SwiftUI

// MARK: - 解析器

/// Markdown 解析（纯函数、无状态）。nonisolated：值模型防隐式 MainActor
///（测试与流式渲染上下文均直接调用）。
nonisolated enum MarkdownParser {

    // MARK: 块级结构

    /// 块级元素（渲染顺序即解析顺序）。
    enum Block: Equatable {
        /// 标题 level 1-6。
        case heading(level: Int, text: String)
        /// 段落（多行以 \n 连接）。
        case paragraph(text: String)
        /// 围栏代码块（语言标记可为空）。
        case code(language: String?, text: String)
        /// 引用块（连续 > 行以 \n 连接）。
        case quote(text: String)
        /// 分隔线（--- / *** / ___）。
        case divider
        /// 列表（连续项聚合；嵌套以 level 表达）。
        case list(items: [ListItem])
        /// 管道表格。
        case table(header: [String], rows: [[String]], aligns: [TableAlign])
    }

    /// 列表项（ordered 项带原始序号；level 每 2 空格一层）。
    struct ListItem: Equatable {
        var ordered: Bool
        var number: Int
        var level: Int
        var text: String
    }

    /// 表格列对齐（分隔行 :--- / :---: / ---:）。
    enum TableAlign: Equatable {
        case left, center, right
    }

    // MARK: 语义分节（方案 B · 标签即生成内容）

    /// 语义分节结果：`##` 节名开启一节，节下内容归入同节。
    /// 渲染器不认识任何词——title 原样来自模型生成时写下的节名，
    /// nil = 无头节（前导内容 / 空标题防御），走排版底座不出标签。
    nonisolated struct MarkdownSection: Equatable {
        let title: String?
        /// 节首块在原 blocks 数组的绝对序号（导语升档判定用，只有 0 有语义）。
        let startIndex: Int
        let blocks: [Block]
    }

    /// heading 驱动分节（首版只认 level 2；h1/h3-h6 留在节内走现有标题渲染）。
    /// 无任何 h2 → 单节 title=nil（调用方走原路径，零回归）；
    /// h2 自身不进节内 blocks（节头标签已承载节名，避免双标题）。
    static func splitSections(_ blocks: [Block]) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        var current: (title: String?, start: Int, blocks: [Block])?
        func flush() {
            if let c = current {
                sections.append(MarkdownSection(title: c.title, startIndex: c.start, blocks: c.blocks))
            }
        }
        for (index, block) in blocks.enumerated() {
            if case .heading(2, let t) = block {
                flush()
                let title = t.trimmingCharacters(in: .whitespaces)
                current = (title.isEmpty ? nil : title, index, [])
                continue
            }
            if current == nil { current = (nil, index, []) }
            current!.blocks.append(block)
        }
        flush()
        return sections
    }

    // MARK: 块级解析

    static func parseBlocks(_ raw: String) -> [Block] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行：块分隔
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 围栏代码块（```lang / ~~~lang；未闭合容错到文末）
            if let fence = fenceMarker(trimmed) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isClosingFence(t, marker: fence.char, length: fence.length) { break }
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }  // 跳过闭合围栏
                blocks.append(.code(
                    language: fence.info.isEmpty ? nil : fence.info,
                    text: body.joined(separator: "\n")
                ))
                continue
            }

            // 标题
            if let h = headingOf(trimmed) {
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // 分隔线
            if isHorizontalRule(trimmed) {
                blocks.append(.divider)
                i += 1
                continue
            }

            // 表格（当前行含 | 且下一行是对齐分隔行）
            if trimmed.contains("|"), i + 1 < lines.count,
               let aligns = tableSeparator(lines[i + 1]),
               let header = tableRow(trimmed), header.count >= 2 {
                var rows: [[String]] = []
                i += 2
                while i < lines.count, let row = tableRow(lines[i]) {
                    rows.append(row)
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows, aligns: aligns))
                continue
            }

            // 引用块（连续 > 行；空行终止）
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = String(t.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // 列表（连续项；缩进续行归并到上一条）
            if let first = listItemOf(line) {
                var items: [ListItem] = [first]
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if let item = listItemOf(l) {
                        items.append(item)
                        i += 1
                        continue
                    }
                    let t = l.trimmingCharacters(in: .whitespaces)
                    // 缩进续行（比项更深）→ 归并；空行/其他块 → 终止
                    if !t.isEmpty, l.first == " " || l.first == "\t" {
                        items[items.count - 1].text += " " + t
                        i += 1
                        continue
                    }
                    break
                }
                blocks.append(.list(items: items))
                continue
            }

            // 段落：聚合到空行或下一块起始
            var para: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                let nextIsTable = t.contains("|")
                    && i + 1 < lines.count
                    && tableSeparator(lines[i + 1]) != nil
                if t.isEmpty
                    || fenceMarker(t) != nil
                    || headingOf(t) != nil
                    || isHorizontalRule(t)
                    || t.hasPrefix(">")
                    || listItemOf(l) != nil
                    || nextIsTable {
                    break
                }
                para.append(t)
                i += 1
            }
            blocks.append(.paragraph(text: para.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: 行内富文本

    /// 行内 Markdown → AttributedString（DS 排版：粗体 semibold、
    /// 行内代码 mono 品牌色 + overlayL1 底、链接品牌色下划线可点、删除线）。
    /// 每个 run 都显式带字体（含无行内标记的纯文本 run）——调用方（dsBodyType
    /// 等）只设行距不设字体，漏带会让 Text 退回系统默认字号、字号阶梯失效。
    /// - Parameters:
    ///   - size: 基准字号（行内代码等比缩小）
    ///   - weight: 基础字重（标题传 semibold 时正文继承）
    ///   - design: 字体设计档（2026-09 呼吸感改版：标题衬线传 .serif，默认 nil = 系统 default）
    ///   - textColor: 普通文本前景（不设置则继承外层 foregroundStyle）
    static func inline(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design? = nil,
        textColor: Color? = nil
    ) -> AttributedString {
        var attr: AttributedString
        do {
            attr = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    // 注：新 Foundation 中该 case 为 inlineOnlyPreservingWhitespace（无尾 s）
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            // 解析失败（如未闭合的 [链接）→ 纯文本兜底，保证渲染永不崩
            var plain = AttributedString(text)
            plain.font = Font.system(size: size, weight: weight, design: design ?? .default)
            if let textColor { plain.foregroundColor = textColor }
            return plain
        }

        for run in attr.runs {
            let range = run.range
            let intent = run.inlinePresentationIntent
            let isBold = intent?.contains(.stronglyEmphasized) ?? false
            let isItalic = intent?.contains(.emphasized) ?? false
            let isCode = intent?.contains(.code) ?? false
            let isStrike = intent?.contains(.strikethrough) ?? false

            // 字体：代码 mono（缩小两档半，随正文 15 → 12.5）/ 文本按粗斜组合出字重
            let font: Font
            if isCode {
                font = Font.custom("JetBrainsMono-Regular", size: max(size - 2.5, 10))
            } else {
                var f = Font.system(size: size, weight: isBold ? .semibold : weight,
                                    design: design ?? .default)
                if isItalic { f = f.italic() }
                font = f
            }
            attr[range].font = font

            if isCode {
                attr[range].foregroundColor = Color.brandAccent
                attr[range].backgroundColor = Color.overlayL1
            }
            if isStrike {
                attr[range].strikethroughStyle = Text.LineStyle.single
            }
            // 链接：parser 已填 .link（Text 自动可点），补品牌色 + 下划线
            if run.link != nil {
                attr[range].foregroundColor = Color.brandAccent
                attr[range].underlineStyle = Text.LineStyle.single
            }
            if let textColor, run.link == nil, !isCode {
                attr[range].foregroundColor = textColor
            }
        }
        return attr
    }

    // MARK: 行级识别

    /// 围栏标记（```lang / ~~~lang）→ 字符 + 长度 + 语言。
    static func fenceMarker(_ t: String) -> (char: Character, length: Int, info: String)? {
        guard let first = t.first, first == "`" || first == "~" else { return nil }
        var length = 0
        for c in t where c == first { length += 1 }
        guard length >= 3 else { return nil }
        let rest = String(t.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        return (first, length, rest)
    }

    /// 闭合围栏：同字符连续 ≥ 开头长度，后不带语言。
    private static func isClosingFence(_ t: String, marker: Character, length: Int) -> Bool {
        guard let first = t.first, first == marker else { return false }
        var count = 0
        for c in t where c == marker { count += 1 }
        guard count >= length else { return false }
        return String(t.dropFirst(count)).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 标题（# ~ ######，# 后须有空格；尾部闭合 # 串须前有空格才剥除）。
    static func headingOf(_ t: String) -> (level: Int, text: String)? {
        // 只数前导连续 #（"## 标题 ##" 的尾部 # 不能计入层级）
        var level = 0
        for c in t {
            if c == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, level < t.count else { return nil }
        let rest = t.dropFirst(level)
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        var text = String(rest).trimmingCharacters(in: .whitespaces)
        // 尾部闭合 # 串（CommonMark：须前有空格）——"## 标题 ##" → "标题"，"### C#" 保持
        if text.hasSuffix("#") {
            var stripped = Substring(text)
            while stripped.last == "#" { stripped = stripped.dropLast() }
            if stripped.last == " " || stripped.last == "\t" {
                text = String(stripped).trimmingCharacters(in: .whitespaces)
            }
            // # 串前不是空格 → 是内容的一部分（如 "C#"），原文保留
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    /// 分隔线：去空格后为同一字符（- * _）重复 ≥3。
    static func isHorizontalRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let first = s.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return s.allSatisfy { $0 == first }
    }

    /// 列表项（无序 -/＊/+ 须跟空格；有序 数字. / 数字) 须跟空格；
    /// level 按前导空白每 2 列一层）。
    static func listItemOf(_ line: String) -> ListItem? {
        var indent = 0
        for c in line {
            if c == " " { indent += 1 }
            else if c == "\t" { indent += 2 }
            else { break }
        }
        let t = line.trimmingCharacters(in: .whitespaces)

        for m in ["- ", "* ", "+ "] where t.hasPrefix(m) {
            let text = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return ListItem(ordered: false, number: 0, level: indent / 2, text: text)
        }

        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < t.count {
            let after = t.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return ListItem(
                    ordered: true, number: Int(digits) ?? 1,
                    level: indent / 2, text: text
                )
            }
        }
        return nil
    }

    /// 表格对齐分隔行（| --- | :---: | ---: |）→ 各列对齐；否则 nil。
    static func tableSeparator(_ line: String) -> [TableAlign]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return nil }
        var s = t
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let cells = s.components(separatedBy: "|")
        guard cells.count >= 2 else { return nil }
        var aligns: [TableAlign] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { aligns.append(.center) }
            else if right { aligns.append(.right) }
            else { aligns.append(.left) }
        }
        return aligns
    }

    /// 表格数据行 → 各列文本（剥首尾 |，按 | 切分 trim）。
    static func tableRow(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return nil }
        var s = t
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - 渲染视图

/// 对话内容 Markdown 渲染（方案 A「阅读栏 · 刻度阶梯」）：块级 VStack，正文 chatBodySize 14
/// （行距 1.72×）、导语 15、标题刻度阶梯 26/21/17/15、小节标签 13、表格 13.5、
/// 行内代码 12.5、代码块 mono 13——字级刻度 + 样式差协同承担层级。
/// 跨块连续选取：相邻正文块（标题/段落）聚合为 ProseTextView 合并渲染成
/// 单个 Text——SwiftUI textSelection 只在单个 Text 内生效，逐块独立 Text 时
/// macOS 拖选跨行即断（只能一块一块选，见 ThinkingCard 同款教训）；块间间距
/// 以排版空行近似。列表 / 表格 / 代码块 / mermaid / 引用为独立块：
/// 列表要悬挂缩进（单个 Text 表达不了，换行会回到第 0 列），其余 Text 无法表达。
/// 块级视图以 block 值做等价短路（.equatable()）：流式正文增长是 append-only
/// 的，稳定前缀段（含其 AttributedString 构建）在每次 tick 重渲染时全部跳过，
/// 只有尾部生长中的段重算。
///
/// longDocument 长文档阅读档（.md 产物预览弹框等整篇场景）：
/// 合并 Text 遇上万字符级整篇文档会退化成巨型 Text——CoreText 排版超线性
/// （实测 10k 字 ≈1.3s 主线程阻塞，`.fixedSize` 全高求值放大 pass 数），
/// 且整篇一次性排版会让离屏 mermaid WKWebView 也全部实例化。
/// 该档位做两件事：① prose 合并分块封顶（单 Text ≤ 8 块且 ≤ 1200 字，
/// 拖选跨块能力保留在块内，块间断开可接受）；② 整篇急切排版（VStack，
/// 2026-09-17 弹框滚动卡顿修复）——LazyVStack 的估算高度修正 / 进视口
/// 排版尖刺 / scrollTo 落估算几何在滚动期表现为持续卡顿（见
/// legacySegmentsView 注释），急切档开窗成本由 sheet 呈现动画遮盖。
struct MarkdownText: View {
    let text: String
    /// 段落基准字号（默认 chatBodySize 14）。
    var bodySize: CGFloat = DS.Typography.chatBodySize
    /// true = mermaid 围栏直接内联渲染；false（流式期间）= 降级为代码块——
    /// 流式中的 mermaid 源未闭合、逐 tick 变化，内联渲染会让 WKWebView
    /// 每次快照都整页重载，等流结束（正式条目）再渲染图表。
    var liveMermaid: Bool = true
    /// 长文档阅读档（整篇 .md 预览）：LazyVStack + prose 合并分块封顶，见类型注释。
    var longDocument: Bool = false
    /// 散文阅读栏宽度上限（方案 A）；nil = 不限制（撑满容器）。
    /// 只约束散文类块（标题 / 段落 / 列表 / 引用 / 分隔线），表格 / 代码 / 图表
    /// 不入栏——数据块需要横向空间。
    var readingMeasure: CGFloat?
    /// 语义分节（方案 B）：`##` 节名渲染成 mono 小标签 + hairline，节下内容归入
    /// 同节。仅 chat 回答正文开启；无 `##` 的回答走原路径，零变化。
    var semanticSections: Bool = false

    /// prose 合并分块封顶：块数上限。
    private static let proseChunkBlocks = 8
    /// prose 合并分块封顶：字数上限（含列表项文字，CJK 口径）。
    private static let proseChunkChars = 1200

    init(
        _ text: String, bodySize: CGFloat = DS.Typography.chatBodySize, liveMermaid: Bool = true,
        longDocument: Bool = false, readingMeasure: CGFloat? = nil,
        semanticSections: Bool = false
    ) {
        self.text = text
        self.bodySize = bodySize
        self.liveMermaid = liveMermaid
        self.longDocument = longDocument
        self.readingMeasure = readingMeasure
        self.semanticSections = semanticSections
    }

    var body: some View {
        let blocks = MarkdownParser.parseBlocks(text)
        let sectioned = semanticSections ? MarkdownParser.splitSections(blocks) : []
        // 无任何 ## 节 → 走原路径（无节名是常态，排版底座原样成立）；
        // 有节 → 逐节渲染：有节名先出 SectionHead，无节名前导节直接渲染内容。
        let useSections = !sectioned.isEmpty
            && !(sectioned.count == 1 && sectioned[0].title == nil)
        Group {
            if useSections {
                sectionedView(sectioned)
            } else {
                legacySegmentsView(blocks)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 语义分节渲染（方案 B）：节头标签 + 节内内容；节间呼吸感走 paragraphSpacing。
    @ViewBuilder
    private func sectionedView(_ sections: [MarkdownParser.MarkdownSection]) -> some View {
        VStack(alignment: .leading, spacing: DS.Typography.paragraphSpacing) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if let title = section.title {
                    SectionHead(title: title, isFirst: index == 0)
                }
                sectionList(section)
            }
        }
    }

    /// 原路径：整条回答不按 ## 分节，块序列照排。
    /// longDocument 档同样走 VStack 急切排版（2026-09-17 弹框滚动卡顿修复）：
    /// LazyVStack 有三个卡顿源——①未物化行按估算高度占位，实际高度算出后
    /// 反复修正 offset，滚动一顿一顿；②新行进视口才排版，每行一次主线程
    /// 排版尖刺；③拖动细胶囊 scrollTo(y:) 落在估算几何上忽跳忽停。
    /// 急切一次性排版把成本挪到开窗瞬间（sheet 呈现动画遮盖），滚动期零
    /// 排版、内容几何稳定——对话页每条消息本就整条急切排版，同款承受力。
    @ViewBuilder
    private func legacySegmentsView(_ blocks: [MarkdownParser.Block]) -> some View {
        let segments = longDocument
            ? Self.segments(
                from: blocks,
                proseChunkLimit: Self.proseChunkBlocks,
                proseCharLimit: Self.proseChunkChars
            )
            : Self.segments(from: blocks)
        VStack(alignment: .leading, spacing: DS.Typography.paragraphSpacing) {
            segmentList(segments)
        }
    }

    @ViewBuilder
    private func segmentList(_ segments: [Segment]) -> some View {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            switch segment {
            case .prose(let blocks, let firstIndex):
                ProseTextView(
                    blocks: blocks, firstIndex: firstIndex, bodySize: bodySize,
                    measure: readingMeasure
                )
                .equatable()
            case .single(let block):
                MarkdownBlockView(
                    block: block, bodySize: bodySize, liveMermaid: liveMermaid,
                    measure: readingMeasure
                )
                .equatable()
            }
        }
    }

    /// 单节内容渲染：节内 blocks 复用 segments 聚合 + segmentList 照排。
    /// indexOffset 传节首块绝对序号——导语升档（firstIndex == 0）保持消息级语义，
    /// 只有消息真正的首段升档。
    @ViewBuilder
    private func sectionList(_ section: MarkdownParser.MarkdownSection) -> some View {
        segmentList(Self.segments(from: section.blocks, indexOffset: section.startIndex))
    }

    /// 渲染段：连续正文块聚合（合并选取），结构块（列表/表格/代码/mermaid/引用/
    /// 分隔线）逐块独立渲染。
    /// 长文档档（proseChunkLimit / proseCharLimit 非 nil）时 prose 聚合追加
    /// 封顶：任一上限触顶即切新段，避免整篇文档坍缩成巨型单 Text。
    enum Segment {
        case prose(blocks: [MarkdownParser.Block], firstIndex: Int)
        case single(MarkdownParser.Block)
    }

    static func segments(
        from blocks: [MarkdownParser.Block],
        proseChunkLimit: Int? = nil,
        proseCharLimit: Int? = nil,
        indexOffset: Int = 0
    ) -> [Segment] {
        var segments: [Segment] = []
        var prose: [MarkdownParser.Block] = []
        var proseStart = indexOffset

        func flush() {
            guard !prose.isEmpty else { return }
            if proseChunkLimit == nil && proseCharLimit == nil {
                segments.append(.prose(blocks: prose, firstIndex: proseStart))
            } else {
                // 分块封顶：firstIndex 传各块真实绝对序号（只有 0 参与
                // 导语判定，其余值无语义；此处保持正确以免误触导语升档）
                var chunk: [MarkdownParser.Block] = []
                var chunkChars = 0
                var cursor = proseStart
                for block in prose {
                    let chars = blockCharCount(block)
                    let blockCap = proseChunkLimit ?? .max
                    let charCap = proseCharLimit ?? .max
                    if !chunk.isEmpty,
                       chunk.count >= blockCap || chunkChars + chars > charCap {
                        segments.append(.prose(blocks: chunk, firstIndex: cursor))
                        cursor += chunk.count
                        chunk = []
                        chunkChars = 0
                    }
                    chunk.append(block)
                    chunkChars += chars
                }
                if !chunk.isEmpty {
                    segments.append(.prose(blocks: chunk, firstIndex: cursor))
                }
            }
            prose = []
        }

        for (index, block) in blocks.enumerated() {
            switch block {
            case .heading, .paragraph:
                if prose.isEmpty { proseStart = index + indexOffset }
                prose.append(block)
            case .list, .quote, .code, .divider, .table:
                // 列表也走独立块：悬挂缩进需要「标记列 + 文本列」两列布局，
                // 合并 Text 里办不到（换行会回到第 0 列）。
                flush()
                segments.append(.single(block))
            }
        }
        flush()
        return segments
    }

    /// prose 块字数（封顶口径；只有标题/段落会进 prose 聚合）。
    private static func blockCharCount(_ block: MarkdownParser.Block) -> Int {
        switch block {
        case .heading(_, let text): return text.count
        case .paragraph(let text): return text.count
        case .list, .quote, .code, .divider, .table: return 0
        }
    }
}

// MARK: - 合并正文段（跨块连续选取的关键）

/// 连续正文块（标题 / 段落）合并为单个 Text 渲染。层级信息全部内联进
/// run：标题字号 / 字重 / 颜色、h4 品牌刻度线（▏字符近似原 Capsule）、
/// 导语升档；块间间距以「空行 run」近似原 VStack spacing
/// （SwiftUI Text 表达不了段落间距，单 \n 的可视间距只有行距附加量）。
/// 列表不进合并（走 MarkdownListView 的悬挂缩进两列布局）。
private struct ProseTextView: View, Equatable {
    let blocks: [MarkdownParser.Block]
    /// 首块在整条消息中的 index（0 = 消息开头 → 首段含加粗升导语）。
    let firstIndex: Int
    let bodySize: CGFloat
    /// 阅读栏宽度上限（nil = 撑满容器）。
    let measure: CGFloat?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blocks == rhs.blocks
            && lhs.firstIndex == rhs.firstIndex
            && lhs.bodySize == rhs.bodySize
            && lhs.measure == rhs.measure
    }

    var body: some View {
        Text(attributed)
            .dsBodyType(size: bodySize, ratio: DS.Typography.chatRatio)
            .foregroundStyle(Color.ink900)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .readingMeasure(measure)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (offset, block) in blocks.enumerated() {
            if offset > 0 {
                out += Self.gap(
                    Self.gapTarget(after: blocks[offset - 1], before: block),
                    bodySize: bodySize
                )
            }
            out += Self.blockRun(
                block,
                isMessageFirst: firstIndex == 0 && offset == 0,
                bodySize: bodySize
            )
        }
        return out
    }

    /// 块间目标间距：标题「上远下近」倒挂（上 34、下 8），其余段间 22。
    private static func gapTarget(
        after previous: MarkdownParser.Block, before next: MarkdownParser.Block
    ) -> CGFloat {
        if case .heading = previous { return DS.Typography.headingBottom }
        if case .heading = next {
            return DS.Typography.paragraphSpacing + DS.Typography.headingTop
        }
        return DS.Typography.paragraphSpacing
    }

    /// 块间 / 列表项间空行：单 \n 的可视间距 = 行距附加量 leading(for:chatRatio)
    /// （≈7.8@15pt）；目标间距更大时插入一行以字号撑高的空行（行高 ≈1.21×字号）
    /// 抬到原 VStack 间距节奏。目标小于 2×leading（标题下 8）时落回单 \n ——
    /// 已是本函数能表达的最近距离，仍明显小于段间 22，倒挂节奏成立。
    private static func gap(_ target: CGFloat, bodySize: CGFloat) -> AttributedString {
        let leading = DS.Typography.leading(for: bodySize, ratio: DS.Typography.chatRatio)
        let spacer = (target - 2 * leading) / 1.21
        var g = AttributedString("\n")
        if spacer > 1 {
            var line = AttributedString("\n")
            line.font = Font.system(size: spacer)
            g += line
        }
        return g
    }

    /// 单个正文块 → 内联富文本 run。
    private static func blockRun(
        _ block: MarkdownParser.Block,
        isMessageFirst: Bool,
        bodySize: CGFloat
    ) -> AttributedString {
        switch block {
        case .heading(let level, let text):
            // 2026-09-15 方案 A「刻度阶梯」：h1/h2 衬线章节标题，h3 起退场回
            // 无衬线条目档（读者一眼知道「章节结束了，进入条目」）；
            // h5/h6 次级小标签。
            let index = min(max(level, 1), 6) - 1
            let ladder = DS.Typography.chatHeadingLadder
            let size = index < ladder.count ? ladder[index] : DS.Typography.chatLabelSize
            var attr = MarkdownParser.inline(
                text, size: size, weight: .semibold,
                design: level <= 2 ? .serif : nil,
                textColor: level >= 5 ? Color.ink500 : Color.ink900
            )
            // 品牌刻度线（原 3×13 Capsule）：文本字符近似，保住正文合并选取；
            // 方案 A 起随 h4 保留（h3 靠 17pt 与 h4 的级差区分，不再加刻度线）
            if level == 4 {
                var tick = AttributedString("▏ ")
                tick.font = Font.system(size: size)
                tick.foregroundColor = Color.brandAccent
                attr = tick + attr
            }
            return attr

        case .paragraph(let text):
            // 导语 / 结论行：消息首个段落且含加粗 → 升半档（16）。
            let isLead = isMessageFirst && text.contains("**")
            let size: CGFloat = isLead
                ? min(bodySize + 1, DS.Typography.chatLeadSize)
                : bodySize
            return MarkdownParser.inline(text, size: size, textColor: Color.ink900)

        case .list, .quote, .code, .divider, .table:
            // 正文聚合只含标题 / 段落，其余块走 MarkdownBlockView
            return AttributedString()
        }
    }
}

// MARK: - 节头标签（方案 B · 语义分节）

/// `##` 节名渲染：mono 小标签 + 右侧延伸 hairline（对齐方案 B 原型 blk-head）。
/// 标签统一单色 ink300——系统不认识词，无按词配色；节名是模型生成时写下的字，
/// 渲染器照排。hairline 不入 640 阅读栏：分节线是版面元素，与散文栏刻意分离。
private struct SectionHead: View, Equatable {
    let title: String
    let isFirst: Bool

    static func == (lhs: SectionHead, rhs: SectionHead) -> Bool {
        lhs.title == rhs.title && lhs.isFirst == rhs.isFirst
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.s10) {
            Text(title)
                .font(DS.Font.mono2XS)
                .tracking(1.8)
                .foregroundStyle(Color.ink300)
                .lineLimit(1)
            Rectangle()
                .fill(Color.borderL1)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, isFirst ? 0 : DS.Spacing.s12)
        .padding(.bottom, DS.Spacing.s8)
    }
}

// MARK: - 阅读栏（散文宽度上限）

/// 散文宽度上限：nil 时原样（撑满容器）。表格 / 代码 / 图表不加此修饰符——
/// 数据块需要横向空间（「读的」与「看的」两条宽度线）。
private struct ReadingMeasureModifier: ViewModifier {
    let width: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let width {
            content.frame(maxWidth: width, alignment: .leading)
        } else {
            content
        }
    }
}

private extension View {
    func readingMeasure(_ width: CGFloat?) -> some View {
        modifier(ReadingMeasureModifier(width: width))
    }
}

// MARK: - 列表（悬挂缩进：标记列 + 文本列）

/// 列表块（方案 A 新增独立视图）：标记列定宽 + 文本列，换行回到文本列而不是
/// 第 0 列——合并 Text 里的「行首标记 + 空格」做不到悬挂缩进，长条目会读成两段。
/// 标记用 ink500（与 SkillLibraryView / MemorySettingsTab 的 bulletList 同色，
/// 也是 AA 达标档）；有序号 mono 12.5 右对齐 + tabular（等宽成列，可竖着扫）。
/// 嵌套层按 level × listHangingIndent 缩进。
private struct MarkdownListView: View, Equatable {
    let items: [MarkdownParser.ListItem]
    let bodySize: CGFloat
    let measure: CGFloat?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items
            && lhs.bodySize == rhs.bodySize
            && lhs.measure == rhs.measure
    }

    /// 标记列宽（悬挂缩进的锚点减去标记与文本之间的间隔）。
    private var markerWidth: CGFloat {
        max(DS.Typography.listHangingIndent - DS.Spacing.s6, DS.Spacing.s8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Typography.listRowSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s6) {
                    marker(item)
                        .frame(width: markerWidth, alignment: .trailing)
                    Text(MarkdownParser.inline(item.text, size: bodySize, textColor: Color.ink900))
                        .dsBodyType(size: bodySize, ratio: DS.Typography.chatRatio)
                        .foregroundStyle(Color.ink900)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, DS.Typography.listHangingIndent * CGFloat(item.level))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readingMeasure(measure)
    }

    /// 列表标记：无序 • / 有序 1.（mono 等宽右对齐）。
    @ViewBuilder
    private func marker(_ item: MarkdownParser.ListItem) -> some View {
        if item.ordered {
            Text("\(item.number).")
                .font(.custom("JetBrainsMono-Regular", size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Color.ink500)
        } else {
            Text("•")
                .font(.system(size: bodySize))
                .foregroundStyle(Color.ink500)
        }
    }
}

// MARK: - 结构块（表格 / 代码 / mermaid / 引用 / 分隔线）

/// 单个结构块的渲染：Equatable + .equatable() 让未变块在流式 tick 间跳过重渲染。
/// 标题 / 段落已并入 ProseTextView（跨块连续选取），此处不再处理。
private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownParser.Block
    let bodySize: CGFloat
    let liveMermaid: Bool
    /// 阅读栏宽度上限（引用 / 分隔线随散文收栏；表格 / 代码 / 图表不入栏）。
    let measure: CGFloat?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
            && lhs.bodySize == rhs.bodySize
            && lhs.liveMermaid == rhs.liveMermaid
            && lhs.measure == rhs.measure
    }

    @ViewBuilder
    var body: some View {
        switch block {
        case .code(let language, let code) where language?.lowercased() == "mermaid":
            // mermaid 围栏块 → 图表直接内联渲染（本地 mermaid.min.js，无需点击预览）；
            // 流式期间（liveMermaid = false）降级为代码块，见 MarkdownText.liveMermaid
            if liveMermaid {
                MermaidFigureCard(source: code)
            } else {
                MarkdownCodeBlock(language: language, code: code)
            }

        case .code(let language, let code):
            MarkdownCodeBlock(language: language, code: code)

        case .list(let items):
            MarkdownListView(items: items, bodySize: bodySize, measure: measure)

        case .quote(let text):
            HStack(alignment: .top, spacing: DS.Spacing.s10) {
                Capsule()
                    .fill(Color.statusAlert)
                    .frame(width: 2)
                Text(MarkdownParser.inline(text, size: bodySize - 1))
                    .dsBodyType(size: bodySize - 1, ratio: DS.Typography.chatRatio)
                    .foregroundStyle(Color.ink700)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .readingMeasure(measure)

        case .divider:
            DSDivider()
                .padding(.vertical, DS.Spacing.s2)
                .readingMeasure(measure)

        case .table(let header, let rows, let aligns):
            MarkdownTableView(header: header, rows: rows, aligns: aligns, bodySize: bodySize - 1.5)

        case .heading, .paragraph:
            // 已并入 ProseTextView（见 segments 聚合），不会到达
            EmptyView()
        }
    }
}

// MARK: - 代码块（语言标签 + 复制钮 + mono 源码）

/// 对话内围栏代码块：surfaceTertiary 凹槽底（深浅色均比助手卡深一档）、
/// 头部语言标签 + 复制钮（复制后 ✓ 1.4s）、mono 13 正文可选中（随正文 15 同档收敛）。
/// 不内滚——长行折行，overflow 由外层消息 ScrollView 承担。
struct MarkdownCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "Plain Text" }
        return language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.s8) {
                Text(displayLanguage)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.s8)
                Button {
                    copyCode()
                } label: {
                    if copied {
                        DSIcon(.check, size: 13)
                            .foregroundStyle(Color.statusSuccess)
                    } else {
                        DSIcon(.copy, size: 13)
                            .foregroundStyle(Color.ink500)
                    }
                }
                .buttonStyle(.plain)
                .help("复制代码")
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)

            DSDivider()

            Text(code)
                .font(DS.Font.monoLG)
                .dsCaptionType(size: 14)
                .foregroundStyle(Color.ink900)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s10)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.surfaceTertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        guard !copied else { return }
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

// MARK: - 表格（表头浅底 + 行分隔线）

/// 管道表格：surfaceBase 底（助手卡上的凹进白盘）、表头 overlayL1 浅底小号
/// semibold（12.5 小标签气质）+ 行分隔线、列按 :---: 对齐。Grid 保证跨行列宽对齐。
/// 纯数值列（如「置信度」0.75 / 0.7 / 0.65）自动右对齐 + 等宽数字——小数位对齐后
/// 才能竖着比较（表格的价值就在列内比较）；markdown 显式指定过对齐的列不覆盖。
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [MarkdownParser.TableAlign]
    var bodySize: CGFloat = 13.5

    /// 全列单元格都是数值的列（严格判据：混一个文本就不算，避免误伤）。
    private var numericColumns: Set<Int> {
        var result: Set<Int> = []
        for index in header.indices {
            let cells = rows
                .compactMap { index < $0.count ? $0[index] : nil }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !cells.isEmpty, cells.allSatisfy(Self.isNumeric) else { continue }
            result.insert(index)
        }
        return result
    }

    /// 数值判据：剥掉常见前后缀符号后能被 Double 解析。
    static func isNumeric(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for symbol in ["≈", "~", ">", "<", "+", "$"] where t.hasPrefix(symbol) {
            t.removeFirst()
        }
        if t.hasSuffix("%") { t.removeLast() }
        t = t.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && Double(t) != nil
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                    cellText(
                        cell, index: index,
                        weight: .semibold,
                        size: DS.Typography.chatTableHeaderSize
                    )
                    .background(Color.overlayL1)
                    .overlay(alignment: .bottom) {
                        dividerLine
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(header.indices), id: \.self) { index in
                        let cell = index < row.count ? row[index] : ""
                        cellText(cell, index: index, weight: .regular)
                            .overlay(alignment: .bottom) {
                                if rowIndex < rows.count - 1 { dividerLine }
                            }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.borderL1)
            .frame(height: 1)
    }

    /// 单元格：列对齐（aligns 缺失按左对齐，纯数值列自动右对齐）、行内 Markdown 生效。
    /// 表头传小号字号（chatTableHeaderSize）+ semibold。
    @ViewBuilder
    private func cellText(
        _ text: String, index: Int, weight: Font.Weight, size: CGFloat? = nil
    ) -> some View {
        let explicit = index < aligns.count ? aligns[index] : MarkdownParser.TableAlign.left
        let isNumericColumn = numericColumns.contains(index)
        let columnAlign: MarkdownParser.TableAlign = isNumericColumn ? .right : explicit
        let align: Alignment = switch columnAlign {
        case .center: .center
        case .right: .trailing
        case .left: .leading
        }
        let fontSize = size ?? bodySize
        let cell = Text(MarkdownParser.inline(text, size: fontSize, weight: weight))
            .lineSpacing(DS.Typography.leading(for: fontSize, ratio: DS.Typography.tableRatio))
            .foregroundStyle(Color.ink900)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Group {
            if isNumericColumn {
                cell.monospacedDigit()
            } else {
                cell
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: align)
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s8)
    }
}
