//
//  AnnotationWriter.swift
//  pm_worker
//
//  实战注记追加器（Task 4.5，design.md §5.2）：
//  方法论被使用后卡片注记区 append——只增不覆盖（append-only，越用越厚），
//  带项目出处与日期；write-then-verify；幂等（同一行重复追加不产生重复注记）。
//

import Foundation

nonisolated enum AnnotationWriter {

    /// 注记区头（与 Resources/cards 模板卡、MethodologyCard.parse 三方同格式：
    /// parse 侧按「## 实战注记」前缀定位，序列化侧写全标题）。
    static let sectionHeader = "## 实战注记（append-only · 只增不覆盖——越用越厚）"

    /// 追加一条实战注记。
    /// - 行格式：`- 日期 · 项目出处：注记正文`（MethodologyCard.parse 可回读）
    /// - 幂等：完全相同的注记行已存在时跳过（重复采纳 / 二次合并不产生重复行）
    /// - 无注记区的手写卡：自动补区头后再追加
    /// - write-then-verify：写后回读校验，不一致抛错（E5 纪律）
    static func append(cardURL: URL, note: String, project: String, date: String) throws {
        guard let text = try? String(contentsOf: cardURL, encoding: .utf8) else {
            throw NSError(
                domain: "AnnotationWriter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "卡片读取失败：\(cardURL.path)"]
            )
        }

        let line = "- \(date) · \(project)：\(note)"

        // 幂等：同一行已存在 → 不重复追加（append-only 但不冗余）
        let existingLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !existingLines.contains(line) else { return }

        var updated = text
        if !text.contains("## 实战注记") {
            // 手写卡无注记区 → 补区头（正文与注记区之间空一行，对齐模板格式）
            if !updated.hasSuffix("\n") { updated += "\n" }
            updated += "\n\(sectionHeader)\n"
        } else if !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += line + "\n"

        // write-then-verify
        try PMAgentStore.writeVerified(updated, to: cardURL)
    }
}
