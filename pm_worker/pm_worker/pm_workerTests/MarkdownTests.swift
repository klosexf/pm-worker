//
//  MarkdownTests.swift
//  pm_workerTests
//
//  对话页 Markdown 渲染的解析测试：块级（标题/段落/代码块/列表/引用/
//  分隔线/表格）+ 行内（粗体/斜体/行内代码/删除线/链接）+ 容错（未闭合
//  围栏 / 非法行内标记回退纯文本）。
//

import SwiftUI
import XCTest
@testable import pm_worker

final class MarkdownTests: XCTestCase {

    // MARK: - 块级：标题

    func testHeadingAllSixLevels() {
        let blocks = MarkdownParser.parseBlocks(
            "# 大标题\n## 二级标题\n### 三级\n#### 四级\n##### 五级\n###### 六级"
        )
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "大标题"))
        XCTAssertEqual(blocks[1], .heading(level: 2, text: "二级标题"))
        XCTAssertEqual(blocks[2], .heading(level: 3, text: "三级"))
        XCTAssertEqual(blocks[3], .heading(level: 4, text: "四级"))
        XCTAssertEqual(blocks[4], .heading(level: 5, text: "五级"))
        XCTAssertEqual(blocks[5], .heading(level: 6, text: "六级"))
    }

    func testHeadingStripsClosingHashesOnlyWhenSpaced() {
        // 尾部闭合 # 串（前有空格）剥除
        let closed = MarkdownParser.parseBlocks("## 标题 ##")
        XCTAssertEqual(closed[0], .heading(level: 2, text: "标题"))
        // "### C#" 的 # 是内容一部分，不剥
        let csharp = MarkdownParser.parseBlocks("### C#")
        XCTAssertEqual(csharp[0], .heading(level: 3, text: "C#"))
    }

    func testHeadingRequiresSpaceAfterHashes() {
        // # 后无空格是普通文本（防止 #标签 误判）；无空行的两行同属一段
        let blocks = MarkdownParser.parseBlocks("#标签内容\nC# 语言")
        XCTAssertEqual(blocks, [.paragraph(text: "#标签内容\nC# 语言")])
    }

    // MARK: - 块级：段落

    func testParagraphMergesConsecutiveLines() {
        let blocks = MarkdownParser.parseBlocks("第一行\n第二行\n\n第三行（新段落）")
        XCTAssertEqual(blocks, [
            .paragraph(text: "第一行\n第二行"),
            .paragraph(text: "第三行（新段落）"),
        ])
    }

    // MARK: - 块级：代码块

    func testCodeFenceWithLanguage() {
        let blocks = MarkdownParser.parseBlocks("前文\n\n```json\n{\"a\": 1}\n```\n\n后文")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .code(language: "json", text: "{\"a\": 1}"))
    }

    func testCodeFenceWithoutLanguage() {
        let blocks = MarkdownParser.parseBlocks("```\nplain\nlines\n```")
        XCTAssertEqual(blocks, [.code(language: nil, text: "plain\nlines")])
    }

    func testUnterminatedCodeFenceToleratedToEOF() {
        // 流式中途：围栏未闭合 → 整段作为代码块渲染（不崩、不丢内容）
        let blocks = MarkdownParser.parseBlocks("```swift\nlet a = 1")
        XCTAssertEqual(blocks, [.code(language: "swift", text: "let a = 1")])
    }

    func testFenceContentIsNotParsedAsMarkdown() {
        let blocks = MarkdownParser.parseBlocks("```\n# 不是标题\n**不是粗体**\n```")
        XCTAssertEqual(blocks, [.code(language: nil, text: "# 不是标题\n**不是粗体**")])
    }

    func testTildeFence() {
        let blocks = MarkdownParser.parseBlocks("~~~\ncode\n~~~")
        XCTAssertEqual(blocks, [.code(language: nil, text: "code")])
    }

    // MARK: - 块级：列表

    func testUnorderedListGroupsConsecutiveItems() {
        let blocks = MarkdownParser.parseBlocks("- 第一项\n- 第二项\n* 第三项\n+ 第四项")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "第一项"),
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "第二项"),
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "第三项"),
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "第四项"),
        ])])
    }

    func testOrderedListKeepsOriginalNumbers() {
        let blocks = MarkdownParser.parseBlocks("1. 一步\n2. 二步\n10. 十步")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownParser.ListItem(ordered: true, number: 1, level: 0, text: "一步"),
            MarkdownParser.ListItem(ordered: true, number: 2, level: 0, text: "二步"),
            MarkdownParser.ListItem(ordered: true, number: 10, level: 0, text: "十步"),
        ])])
    }

    func testOrderedListWithParenMarker() {
        let blocks = MarkdownParser.parseBlocks("1) 甲\n2) 乙")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownParser.ListItem(ordered: true, number: 1, level: 0, text: "甲"),
            MarkdownParser.ListItem(ordered: true, number: 2, level: 0, text: "乙"),
        ])])
    }

    func testNestedListByIndent() {
        let blocks = MarkdownParser.parseBlocks("- 顶层\n  - 嵌套一层")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "顶层"),
            MarkdownParser.ListItem(ordered: false, number: 0, level: 1, text: "嵌套一层"),
        ])])
    }

    func testIndentedContinuationMergesIntoItem() {
        let blocks = MarkdownParser.parseBlocks("- 长项\n  续行内容")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "长项 续行内容"),
        ])])
    }

    func testListItemRequiresSpaceAfterMarker() {
        // "-负号" 不是列表项（负号 + 非空格）
        let blocks = MarkdownParser.parseBlocks("-负号-1 和 -2 都不是列表")
        XCTAssertEqual(blocks[0], .paragraph(text: "-负号-1 和 -2 都不是列表"))
    }

    // MARK: - 块级：引用 / 分隔线

    func testBlockquoteMergesConsecutiveLines() {
        let blocks = MarkdownParser.parseBlocks("> 引用一\n> 引用二\n\n正文")
        XCTAssertEqual(blocks, [
            .quote(text: "引用一\n引用二"),
            .paragraph(text: "正文"),
        ])
    }

    func testHorizontalRules() {
        let blocks = MarkdownParser.parseBlocks("---\n***\n___\n- - -")
        XCTAssertEqual(blocks, [.divider, .divider, .divider, .divider])
    }

    func testHyphenDashIsNotRuleWhenFollowedByText() {
        let blocks = MarkdownParser.parseBlocks("- 这是列表项不是分隔线")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownParser.ListItem(ordered: false, number: 0, level: 0, text: "这是列表项不是分隔线"),
        ])])
    }

    // MARK: - 块级：表格

    func testTableParsingWithAlignments() {
        let md = """
        | 模块 | 页面 | 优先级 |
        | :--- | :---: | ---: |
        | 登录 | Login | P0 |
        | 首页 | Home | P1 |
        """
        let blocks = MarkdownParser.parseBlocks(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let header, let rows, let aligns) = blocks[0] else {
            return XCTFail("应为表格块，实际 \(blocks[0])")
        }
        XCTAssertEqual(header, ["模块", "页面", "优先级"])
        XCTAssertEqual(rows, [["登录", "Login", "P0"], ["首页", "Home", "P1"]])
        XCTAssertEqual(aligns, [.left, .center, .right])
    }

    func testTableWithoutSeparatorRowIsParagraph() {
        let blocks = MarkdownParser.parseBlocks("a | b\n1 | 2")
        XCTAssertEqual(blocks, [.paragraph(text: "a | b\n1 | 2")])
    }

    // MARK: - 行内富文本

    func testInlineBoldRun() {
        let attr = MarkdownParser.inline("这是**重点**内容", size: 15)
        let bold = attr.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertEqual(bold.map { String(attr[$0.range].characters) }, "重点")
    }

    func testInlineUnderscoreBoldAndItalic() {
        let attr = MarkdownParser.inline("__粗体__ 与 *斜体* 混排", size: 15)
        let bold = attr.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertEqual(bold.map { String(attr[$0.range].characters) }, "粗体")
        let italic = attr.runs.first {
            $0.inlinePresentationIntent?.contains(.emphasized) == true
        }
        XCTAssertEqual(italic.map { String(attr[$0.range].characters) }, "斜体")
    }

    func testInlineCodeRunHasBrandColorAndBackground() {
        let attr = MarkdownParser.inline("运行 `npm install` 安装", size: 15)
        let code = attr.runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        XCTAssertEqual(code.map { String(attr[$0.range].characters) }, "npm install")
        XCTAssertNotNil(code?.foregroundColor)   // 品牌色已设置
        XCTAssertNotNil(code?.backgroundColor)   // 浅底已设置
    }

    func testInlineStrikethrough() {
        let attr = MarkdownParser.inline("~~作废~~", size: 15)
        let strike = attr.runs.first {
            $0.inlinePresentationIntent?.contains(.strikethrough) == true
        }
        XCTAssertEqual(strike.map { String(attr[$0.range].characters) }, "作废")
    }

    func testInlineLinkIsClickable() {
        let attr = MarkdownParser.inline("参考[文档](https://example.com/PRD)", size: 15)
        let link = attr.runs.first { $0.link != nil }
        XCTAssertEqual(link?.link, URL(string: "https://example.com/PRD"))
        XCTAssertEqual(link.map { String(attr[$0.range].characters) }, "文档")
    }

    func testInlinePlainTextUntouched() {
        let attr = MarkdownParser.inline("普通中文段落，无任何标记。", size: 15)
        XCTAssertTrue(attr.runs.allSatisfy { $0.inlinePresentationIntent == nil })
        XCTAssertEqual(String(attr.characters), "普通中文段落，无任何标记。")
    }

    func testInlineFallbackKeepsTextOnOddInput() {
        // 未闭合链接等非法标记：不抛错、文本完整保留（渲染永不崩）
        let attr = MarkdownParser.inline("见 [链接](broken", size: 15)
        XCTAssertEqual(String(attr.characters), "见 [链接](broken")
    }

    func testInlineNestedBoldItalic() {
        let attr = MarkdownParser.inline("***既粗又斜***", size: 15)
        let both = attr.runs.first { run in
            guard let intent = run.inlinePresentationIntent else { return false }
            return intent.contains(.stronglyEmphasized) && intent.contains(.emphasized)
        }
        XCTAssertEqual(both.map { String(attr[$0.range].characters) }, "既粗又斜")
    }

    // MARK: - 端到端（参考样式全文）

    func testFullAssistantReplyShape() {
        let md = """
        原因查清楚了，给您解释一下。

        ## 发生了什么

        截图里的报错是 **TRAE 插件市场服务端临时故障** 导致的，不是您本地环境的问题。

        1. 14:37-14:39（您的会话启动时），TRAE 会自动把官方插件同步安装到本地。
        2. 插件市场服务器开始返回 HTTP 503 和超时：

        ```
        14:39:40 [warning] syncMarketplacePluginsToLocal partially failed
          seedance → HTTP 503: Service Unavailable
        ```

        | 阶段 | 状态 |
        | :--- | :--- |
        | 澄清 | 已完成 |
        """
        let blocks = MarkdownParser.parseBlocks(md)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .paragraph(text: "原因查清楚了，给您解释一下。"))
        XCTAssertEqual(blocks[1], .heading(level: 2, text: "发生了什么"))
        XCTAssertEqual(blocks[3], .list(items: [
            MarkdownParser.ListItem(ordered: true, number: 1, level: 0, text: "14:37-14:39（您的会话启动时），TRAE 会自动把官方插件同步安装到本地。"),
            MarkdownParser.ListItem(ordered: true, number: 2, level: 0, text: "插件市场服务器开始返回 HTTP 503 和超时："),
        ]))
        guard case .code(nil, let codeText) = blocks[4] else {
            return XCTFail("第 5 块应为无语言代码块")
        }
        XCTAssertTrue(codeText.contains("syncMarketplacePluginsToLocal"))
        guard case .table = blocks[5] else {
            return XCTFail("末块应为表格")
        }
    }
}
