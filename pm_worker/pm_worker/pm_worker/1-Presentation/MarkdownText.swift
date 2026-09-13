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
//  · 渲染 MarkdownText——DS 令牌排版：标题 20/17/15/14/13/12 semibold 拉开层级，
//    代码块带语言标签 + 复制钮（复制后 ✓ 反馈），表格 overlayL1 表头 + 行分隔线。
//    全部颜色走 DS 动态令牌，深浅色模式自适应。
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
    /// - Parameters:
    ///   - size: 基准字号（行内代码等比缩小）
    ///   - weight: 基础字重（标题传 semibold 时正文继承）
    ///   - textColor: 普通文本前景（不设置则继承外层 foregroundStyle）
    static func inline(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
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
            if let textColor { plain.foregroundColor = textColor }
            return plain
        }

        let runs = Array(attr.runs)
        for run in runs {
            let range = run.range
            guard let intent = run.inlinePresentationIntent else { continue }
            let isBold = intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)
            let isCode = intent.contains(.code)
            let isStrike = intent.contains(.strikethrough)

            // 字体：代码 mono（缩小一档）/ 文本按粗斜组合出字重
            let font: Font
            if isCode {
                font = Font.custom("JetBrainsMono-Regular", size: max(size - 1.5, 10))
            } else {
                var f = Font.system(size: size, weight: isBold ? .semibold : weight)
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

/// 对话内容 Markdown 渲染。块级 VStack，正文 chatBase 17（行距 1.45×），
/// 标题 20/18/17/16/15/14 semibold（聊天语境梯度，层级靠字重+间距协同），
/// 代码块 / 表格 / 引用 / 列表独立样式。
struct MarkdownText: View {
    let text: String
    /// 段落基准字号（默认 chatBase 17）。
    var bodySize: CGFloat = 17

    init(_ text: String, bodySize: CGFloat = 17) {
        self.text = text
        self.bodySize = bodySize
    }

    var body: some View {
        let blocks = MarkdownParser.parseBlocks(text)
        VStack(alignment: .leading, spacing: DS.Typography.paragraphSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownParser.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            heading(level, text, isFirst: isFirst)

        case .paragraph(let text):
            Text(MarkdownParser.inline(text, size: bodySize))
                .dsBodyType(size: bodySize)
                .foregroundStyle(Color.ink900)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code) where language?.lowercased() == "mermaid":
            // mermaid 围栏块 → 图表直接内联渲染（本地 mermaid.min.js，无需点击预览）
            MermaidFigureCard(source: code)

        case .code(let language, let code):
            MarkdownCodeBlock(language: language, code: code)

        case .quote(let text):
            HStack(alignment: .top, spacing: DS.Spacing.s10) {
                Capsule()
                    .fill(Color.borderL3)
                    .frame(width: 3)
                Text(MarkdownParser.inline(text, size: bodySize - 1))
                    .dsBodyType(size: bodySize - 1)
                    .foregroundStyle(Color.ink700)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            DSDivider()
                .padding(.vertical, DS.Spacing.s2)

        case .list(let items):
            VStack(alignment: .leading, spacing: DS.Typography.listRowSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItemRow(item)
                }
            }

        case .table(let header, let rows, let aligns):
            MarkdownTableView(header: header, rows: rows, aligns: aligns, bodySize: bodySize - 2)
        }
    }

    /// 标题：字号按层级递减（20/18/17/16/15/14，聊天语境收敛梯度），1-2 级紧字距；
    /// 非首个 block 时上方额外间距（headingTop）与正文断开分层。
    private func heading(_ level: Int, _ text: String, isFirst: Bool) -> some View {
        let size: CGFloat = switch level {
        case 1: 20
        case 2: 18
        case 3: 17
        case 4: 16
        case 5: 15
        default: 14
        }
        let attr = MarkdownParser.inline(text, size: size, weight: .semibold)
        return Group {
            // tracking 是 Text 专有方法——须在 View 修饰符之前链
            if level <= 2 {
                Text(attr).tracking(-0.3)
            } else {
                Text(attr)
            }
        }
        .foregroundStyle(Color.ink900)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, isFirst ? 0 : DS.Typography.headingTop)
    }

    /// 列表项：标记列右对齐（• / 1.），嵌套按 level 缩进 18/层。
    private func listItemRow(_ item: MarkdownParser.ListItem) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s6) {
            Text(item.ordered ? "\(item.number)." : "•")
                .font(.system(size: bodySize))
                .foregroundStyle(Color.ink500)
                .frame(minWidth: item.ordered ? 20 : 10, alignment: .trailing)
            Text(MarkdownParser.inline(item.text, size: bodySize))
                .dsBodyType(size: bodySize)
                .foregroundStyle(Color.ink900)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.level) * 18)
    }
}

// MARK: - 代码块（语言标签 + 复制钮 + mono 源码）

/// 对话内围栏代码块：surfaceTertiary 凹槽底（深浅色均比助手卡深一档）、
/// 头部语言标签 + 复制钮（复制后 ✓ 1.4s）、mono 14 正文可选中（随正文 17 同步上移）。
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

/// 管道表格：surfaceBase 底（助手卡上的凹进白盘）、表头 overlayL1 浅底 +
/// 行分隔线、列按 :---: 对齐。Grid 保证跨行列宽对齐。
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let aligns: [MarkdownParser.TableAlign]
    var bodySize: CGFloat = 13

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                    cellText(cell, index: index, weight: .medium)
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
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.borderL1)
            .frame(height: 1)
    }

    /// 单元格：列对齐（aligns 缺失按左对齐）、行内 Markdown 生效。
    private func cellText(
        _ text: String, index: Int, weight: Font.Weight
    ) -> some View {
        let align: Alignment = switch (index < aligns.count ? aligns[index] : .left) {
        case .center: .center
        case .right: .trailing
        case .left: .leading
        }
        return Text(MarkdownParser.inline(text, size: bodySize, weight: weight))
            .lineSpacing(DS.Typography.leading(for: bodySize, ratio: DS.Typography.tableRatio))
            .foregroundStyle(Color.ink900)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: align)
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s6)
    }
}
