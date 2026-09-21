//
//  KnowledgeCalibration.swift
//  pm_worker
//
//  记忆校准注入（Task 4.5，design.md「经验」跨项目假设态注入 / E23）：
//  使用方法论时注入该用户的历史使用倾向——记忆层「经验」条目，
//  按假设态标签注入（未验证前不作硬约束，只作倾向校准）。
//

import Foundation

nonisolated enum KnowledgeCalibration {

    /// 记忆校准上下文：与该方法论主题相关的历史「经验」条目 → 假设态注入文本。
    /// - Parameters:
    ///   - cardTitle: 方法论标题（与经验 content 做主题匹配）
    ///   - memories: 候选记忆条目（调用方负责传入有效条目——未失效、跨项目聚合）
    /// - Returns: 注入文本；无匹配经验返回 ""（不注入）。
    static func calibrationContext(cardTitle: String, memories: [MemoryEntry]) -> String {
        let matched = matchingExperiences(cardTitle: cardTitle, memories: memories)
        guard !matched.isEmpty else { return "" }

        let lines = matched.map { entry -> String in
            var line = "- [经验·假设态] \(entry.content)"
            if let ref = entry.sourceRef, !ref.isEmpty {
                line += "（出处：\(ref)）"
            }
            if let confidence = entry.confidence {
                line += String(format: "（置信度 %.1f）", confidence)
            }
            return line
        }
        return "📈 记忆校准（该方法论的历史使用倾向——假设态，未验证前不作硬约束）：\n"
            + lines.joined(separator: "\n")
    }

    /// 主题匹配的「经验」条目（校准注入与注入后待校准标记共用此口径）。
    static func matchingExperiences(
        cardTitle: String, memories: [MemoryEntry]
    ) -> [MemoryEntry] {
        let keyword = cardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }

        // 只校准「经验」类条目（结论 / 约束 / 否决项走常规记忆注入区，不在此重复）
        return memories.filter { entry in
            entry.kind == .experience && matches(entry.content, keyword: keyword)
        }
    }

    /// 主题匹配：标题任意 4 字连续片段命中经验正文（对专名鲁棒——「KANO 需求分类」
    /// 能命中「上次用 KANO 把数据精度错标…」），或标题 2-gram 对正文的重叠
    /// ≥ topicRelevanceThreshold（P1-5：近义改写、词序调换不再漏配）；
    /// 短标题不足 4 字时退化为整词包含。
    private static func matches(_ content: String, keyword: String) -> Bool {
        let normalizedContent = LexicalSimilarity.normalized(content)
        let chars = Array(LexicalSimilarity.normalized(keyword))
        guard !chars.isEmpty else { return false }
        if chars.count >= 4 {
            for i in 0...(chars.count - 4) {
                let window = String(chars[i..<(i + 4)])
                if normalizedContent.contains(window) { return true }
            }
        } else if normalizedContent.contains(String(chars)) {
            return true
        }
        // 重叠系数 min 侧 = 标题 bigram 全集：标题词有多少比例出现在正文里
        return LexicalSimilarity.bigramOverlap(keyword, content)
            >= LexicalSimilarity.topicRelevanceThreshold
    }
}
