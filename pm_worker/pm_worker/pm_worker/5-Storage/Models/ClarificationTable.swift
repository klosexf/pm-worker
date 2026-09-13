//
//  ClarificationTable.swift
//  pm_worker
//
//  澄清要点表（Task 2.1，design.md §6.2 ① JSON Schema）：
//  target_user / core_scenario / core_value / constraints / open_questions。
//  落盘到 01-requirements/clarification.md，是 ①→② 的推进依据。
//

import Foundation

nonisolated struct ClarificationTable: Codable, Equatable {
    var targetUser: String
    var coreScenario: String
    var coreValue: String
    var constraints: [String]
    var openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case targetUser = "target_user"
        case coreScenario = "core_scenario"
        case coreValue = "core_value"
        case constraints
        case openQuestions = "open_questions"
    }

    /// clarification.md 全文（Markdown，人可读、Finder 手改合法）。
    var markdown: String {
        var lines: [String] = []
        lines.append("# 澄清要点表")
        lines.append("")
        lines.append("## 目标用户")
        lines.append(targetUser)
        lines.append("")
        lines.append("## 核心场景")
        lines.append(coreScenario)
        lines.append("")
        lines.append("## 核心价值")
        lines.append(coreValue)
        lines.append("")
        lines.append("## 约束")
        if constraints.isEmpty {
            lines.append("（无）")
        } else {
            constraints.forEach { lines.append("- \($0)") }
        }
        lines.append("")
        lines.append("## 开放问题")
        if openQuestions.isEmpty {
            lines.append("（无）")
        } else {
            openQuestions.forEach { lines.append("- \($0)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
