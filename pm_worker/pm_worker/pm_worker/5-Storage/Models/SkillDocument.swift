//
//  SkillDocument.swift
//  pm_worker
//
//  技能 front-matter 六字段模型（design.md v0.9.11）：
//  name / type / when_to_use / best_for / tags / pitfalls。
//  pitfalls 为漏项雷达信号源，走确定性路由（不编码 embedding）。
//

import Foundation

nonisolated struct SkillDocument: Codable, Equatable {
    /// 命中后生效形态
    enum Kind: String, Codable {
        case component
        case interactive
    }

    var name: String
    var type: Kind
    /// 何时使用（元数据常驻，正文不进索引）
    var whenToUse: String
    /// 典型场景短句（编码进 embedding）
    var bestFor: [String]
    /// 中英双语（编码进 embedding）
    var tags: [String]
    /// 结构化反模式——供自评审按阶段规则路由确定性读取（§6.2）
    var pitfalls: [String]
    /// 技能正文（Markdown）
    var body: String

    init(
        name: String,
        type: Kind = .component,
        whenToUse: String = "",
        bestFor: [String] = [],
        tags: [String] = [],
        pitfalls: [String] = [],
        body: String = ""
    ) {
        self.name = name
        self.type = type
        self.whenToUse = whenToUse
        self.bestFor = bestFor
        self.tags = tags
        self.pitfalls = pitfalls
        self.body = body
    }
}

/// 极简 front-matter 解析：`---` 包裹的 `key: value` 块。
/// 数组字段支持两种写法（skills-inventory §3 模板为块状列表）：
///   - 内联：`tags: [a, b]`（JSON / YAML flow）
///   - 块状：`tags:` 后跟若干 `  - item` 行
/// 技能文件格式受控，不引第三方 YAML 依赖。
nonisolated enum SkillFrontMatterParser {
    static func parse(_ markdown: String) -> SkillDocument? {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        var blockLists: [String: [String]] = [:]
        var body: [String] = []
        var currentListKey: String?

        var inFrontMatter = true
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFrontMatter {
                if trimmed == "---" {
                    inFrontMatter = false
                    currentListKey = nil
                    continue
                }
                // 块状列表项：`- item`
                if trimmed.hasPrefix("- "), let key = currentListKey {
                    blockLists[key]?.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    currentListKey = key
                    blockLists[key] = []
                    fields[key] = ""
                } else {
                    currentListKey = nil
                    fields[key] = value
                }
            } else {
                body.append(line)
            }
        }

        func strings(_ key: String) -> [String] {
            if let items = blockLists[key], !items.isEmpty { return items }
            guard let raw = fields[key], !raw.isEmpty else { return [] }
            // 内联数组：`[a, b]` 或 JSON 数组
            var text = raw
            if text.hasPrefix("[") && text.hasSuffix("]") {
                text = String(text.dropFirst().dropLast())
                // 去引号后按逗号切分
                return text.split(whereSeparator: { $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
            }
            return [raw]
        }

        return SkillDocument(
            name: fields["name"] ?? "",
            type: SkillDocument.Kind(rawValue: fields["type"] ?? "component") ?? .component,
            whenToUse: fields["when_to_use"] ?? "",
            bestFor: strings("best_for"),
            tags: strings("tags"),
            pitfalls: strings("pitfalls"),
            body: body.joined(separator: "\n")
        )
    }
}
