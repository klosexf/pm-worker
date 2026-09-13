//
//  SkillLoader.swift
//  pm_worker
//
//  技能渐进式披露（design.md §6.3）：正文不进索引，命中后才按 doc_path 读文件。
//  索引侧的四字段拼接文本也在这里统一口径：
//  name + when_to_use + best_for + tags（type / pitfalls 不编码——
//  pitfalls 走 PitfallsRouter 确定性路由，不依赖语义命中）。
//

import Foundation

/// nonisolated：纯文件系统与文本处理，无 UI 状态。
nonisolated enum SkillLoader {

    /// 去掉 front-matter（`---` 包裹块），返回其后的正文。
    /// 无 front-matter 时原样返回；有开头 `---` 但无闭合时返回空
    /// （与 SkillFrontMatterParser 的 body 语义一致）。
    static func stripFrontMatter(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return text
        }
        lines.removeFirst()
        for (offset, line) in lines.enumerated()
        where line.trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(offset + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 读技能文件正文（渐进式披露：命中后才调用；去掉 front-matter）。
    /// 文件不存在 / 读失败返回 nil。
    static func loadBody(docPath: String) -> String? {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: docPath), encoding: .utf8)
        else { return nil }
        return stripFrontMatter(text)
    }

    /// 四字段拼接文本（编码进 embedding 的部分）：
    /// name + when_to_use + best_for + tags；type / pitfalls 不编码。
    /// 供 IndexRebuilder 全量 / 增量建索引时调用。
    static func fourFieldText(_ skill: SkillDocument) -> String {
        ([skill.name, skill.whenToUse] + skill.bestFor + skill.tags)
            .joined(separator: "\n")
    }
}
