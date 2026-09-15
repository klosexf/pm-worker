//
//  MarkdownEditOpsTests.swift
//  pm_workerTests
//
//  文档弹框编辑工具条的排版变换（纯函数）：
//  包裹 toggle（加粗/斜体/行内代码/链接/代码块）、行前缀 toggle（引用/无序列表）、
//  有序编号、标题级别、片段插入（表格/分割线）、越界选区收敛。
//

import XCTest
@testable import pm_worker

final class MarkdownEditOpsTests: XCTestCase {

    // MARK: - 选区包裹

    func testWrapSelectionAddsMarkers() {
        let (text, range) = MarkdownEditOps.wrapSelection(
            text: "hello world", range: NSRange(location: 6, length: 5),
            prefix: "**", suffix: "**"
        )
        XCTAssertEqual(text, "hello **world**")
        XCTAssertEqual((text as NSString).substring(with: range), "world", "新选区 = 被包裹的原文")
    }

    func testWrapSelectionTogglesOff() {
        let (text, range) = MarkdownEditOps.wrapSelection(
            text: "hello **world**", range: NSRange(location: 6, length: 9),
            prefix: "**", suffix: "**"
        )
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual((text as NSString).substring(with: range), "world")
    }

    func testWrapEmptySelectionPlacesCursorBetween() {
        let (text, range) = MarkdownEditOps.wrapSelection(
            text: "ab", range: NSRange(location: 1, length: 0),
            prefix: "**", suffix: "**"
        )
        XCTAssertEqual(text, "a****b")
        XCTAssertEqual(range, NSRange(location: 3, length: 0), "空选区：光标落在成对符号中间")
    }

    func testLinkWrap() {
        let (text, _) = MarkdownEditOps.wrapSelection(
            text: "见文档", range: NSRange(location: 0, length: 3),
            prefix: "[", suffix: "](url)"
        )
        XCTAssertEqual(text, "[见文档](url)")
    }

    // MARK: - 行前缀（引用 / 无序列表）

    func testQuotePrefixAddsToAllLines() {
        let (text, range) = MarkdownEditOps.toggleLinePrefix(
            text: "甲\n乙\n丙", range: NSRange(location: 0, length: 5), prefix: "> "
        )
        XCTAssertEqual(text, "> 甲\n> 乙\n> 丙")
        XCTAssertEqual(
            range,
            NSRange(location: 0, length: (text as NSString).length),
            "行级变换的新选区 = 整个改动行块"
        )
    }

    func testQuotePrefixTogglesOffWhenAllPrefixed() {
        let (text, _) = MarkdownEditOps.toggleLinePrefix(
            text: "> 甲\n> 乙", range: NSRange(location: 0, length: 8), prefix: "> "
        )
        XCTAssertEqual(text, "甲\n乙")
    }

    func testQuotePrefixPartiallyPrefixedStillAdds() {
        // 仅部分行带前缀 → 统一添加（非逐行反转）
        let (text, _) = MarkdownEditOps.toggleLinePrefix(
            text: "> 甲\n乙", range: NSRange(location: 0, length: 5), prefix: "> "
        )
        XCTAssertEqual(text, "> 甲\n> 乙")
    }

    func testBulletListSkipsEmptyLines() {
        let (text, _) = MarkdownEditOps.toggleLinePrefix(
            text: "甲\n\n乙", range: NSRange(location: 0, length: 4), prefix: "- "
        )
        XCTAssertEqual(text, "- 甲\n\n- 乙")
    }

    // MARK: - 有序列表

    func testOrderedListNumbersLines() {
        let (text, _) = MarkdownEditOps.toggleOrderedList(
            text: "甲\n乙", range: NSRange(location: 0, length: 3)
        )
        XCTAssertEqual(text, "1. 甲\n2. 乙")
    }

    func testOrderedListToggleOffStripsNumbers() {
        let (text, _) = MarkdownEditOps.toggleOrderedList(
            text: "1. 甲\n2. 乙\n3. 丙", range: NSRange(location: 0, length: 14)
        )
        XCTAssertEqual(text, "甲\n乙\n丙")
    }

    // MARK: - 标题

    func testHeadingSetsLevel() {
        let (text, _) = MarkdownEditOps.heading(
            text: "概述", range: NSRange(location: 0, length: 2), level: 2
        )
        XCTAssertEqual(text, "## 概述")
    }

    func testHeadingReplacesExistingLevel() {
        let (text, _) = MarkdownEditOps.heading(
            text: "# 概述", range: NSRange(location: 0, length: 4), level: 3
        )
        XCTAssertEqual(text, "### 概述")
    }

    func testHeadingTogglesOffAtSameLevel() {
        let (text, _) = MarkdownEditOps.heading(
            text: "## 概述", range: NSRange(location: 0, length: 5), level: 2
        )
        XCTAssertEqual(text, "概述")
    }

    // MARK: - 代码块

    func testCodeBlockWraps() {
        let (text, _) = MarkdownEditOps.codeBlock(
            text: "代码", range: NSRange(location: 0, length: 2)
        )
        XCTAssertEqual(text, "```\n代码\n```")
    }

    func testCodeBlockUnwraps() {
        let (text, _) = MarkdownEditOps.codeBlock(
            text: "```\n代码\n```", range: NSRange(location: 0, length: 10)
        )
        XCTAssertEqual(text, "代码")
    }

    // MARK: - 片段插入

    func testInsertSnippetPlacesCursorAtEnd() {
        let (text, range) = MarkdownEditOps.insertSnippet(
            text: "前后", range: NSRange(location: 1, length: 0), snippet: "\n\n---\n\n"
        )
        XCTAssertEqual(text, "前\n\n---\n\n后")
        XCTAssertEqual(range.location, 8, "光标落在片段末尾")
    }

    func testTableSnippet() {
        let (text, _) = MarkdownEditOps.table(text: "", range: NSRange(location: 0, length: 0))
        XCTAssertTrue(text.contains("| 列一 | 列二 | 列三 |"))
        XCTAssertTrue(text.contains("| --- | --- | --- |"))
    }

    // MARK: - 越界收敛

    func testOutOfRangeSelectionIsClamped() {
        let (text, _) = MarkdownEditOps.wrapSelection(
            text: "abc", range: NSRange(location: 10, length: 5), prefix: "**", suffix: "**"
        )
        XCTAssertEqual(text, "abc****", "越界选区收敛到文本末尾（空选区插入成对符号），不崩")
    }

    func testEmptyTextLinePrefixIsNoOp() {
        let (text, _) = MarkdownEditOps.toggleLinePrefix(
            text: "", range: NSRange(location: 0, length: 0), prefix: "> "
        )
        XCTAssertEqual(text, "")
    }
}
