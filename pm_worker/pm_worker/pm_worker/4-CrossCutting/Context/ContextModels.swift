//
//  ContextModels.swift
//  pm_worker
//
//  Context Builder 共享模型（M4 Task 4.1，design.md §6.3/§6.4）：
//  五段组装（规则/记忆/技能正文/检索/历史）+ token 预算分配 + 超预算按优先级裁剪。
//  本文件只放数据结构（B 实现 ContextBuilder 组装逻辑；D 的开发者检查器读取展示）。
//

import Foundation

// MARK: - 上下文分段

/// 五段（design.md §6.4 token 预算分配）：规则 / 记忆 / 技能正文 / 检索 / 历史。
/// rawValue 同时是优先级顺序（预算超限时从低优先级——数组尾部——开始裁剪）。
nonisolated enum ContextSegment: String, Codable, CaseIterable {
    case rules        // 规则层（rules/global.md 等）
    case memory       // 记忆层有效条目（版本 > 项目 > 全局）
    case skillBodies  // 技能库渐进式披露：仅命中技能正文
    case retrieval    // 检索结果（卡片库 top-k + 技能命中摘要）
    case history      // 对话历史
}

// MARK: - token 构成

/// token 构成条（检查器 ⌘D 展示；估算口径：中文按字符计、英文按词 ×1.3）。
nonisolated struct TokenBreakdown: Codable, Equatable {
    /// 各段 token 估算（键 = 分段）。
    var segments: [ContextSegment: Int]
    /// 本次组装预算上限。
    var budget: Int
    /// 因超预算被裁剪掉的分段（按优先级从低到高记录）。
    var trimmed: [ContextSegment]

    var total: Int { segments.values.reduce(0, +) }

    /// 简易估算：中文字符 1:1，连续英文字母数字词 ×1.3，标点忽略。
    static func estimate(_ text: String) -> Int {
        var cjk = 0
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.value > 0x2E7F {  // CJK 及全角区
                cjk += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || scalar == "_" {
                if !inWord { words += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return cjk + Int((Double(words) * 1.3).rounded())
    }
}

// MARK: - 组装结果与 trace

/// 一次 Context Builder 组装的完整产物（systemPrompt 已含前四段；历史段由 SessionStore 按预算截断注入）。
nonisolated struct ContextAssembly: Codable, Equatable {
    /// 组装后的最终 system prompt（规则+记忆+技能正文+检索 拼装、已过预算裁剪）。
    var systemPrompt: String
    /// 组装时的阶段查询摘要（检索 query）。
    var query: String
    /// 阶段。
    var stage: String
    /// token 构成。
    var breakdown: TokenBreakdown
    /// 检索 trace（命中 + scope 标签 + 相似度；未命中技能列表在其中）。
    var retrieval: RetrievalTrace?
    /// 本次注入的技能正文（渐进式披露证明：未命中技能不在此）。
    var injectedSkillBodies: [String]
    /// 本次注入的记忶校准文本（假设态「经验」条目）。
    var calibration: [String]
    /// 自检清单 pitfalls 信号源（确定性路由条目）。
    var pitfalls: [PitfallsRouter.Entry]
    /// 组装时间戳。
    var createdAt: String
    /// 本次实际注入的技能 id（按相关度降序、过预算裁剪后的口径）——
    /// 思考卡「引用技能」展示的数据源；默认空兼容既有构造点。
    var skillIds: [String] = []
    /// 技能判定通道结果（混合路由兜底通道；nil = 未调用——本地已命中或未接线）。
    var skillJudgeReport: SkillJudgeReport? = nil
}

/// 技能判定通道结果（本地检索零命中时由 classify 档小模型判定；检查器可观测）。
nonisolated struct SkillJudgeReport: Codable, Equatable {
    /// 判定查询（发送轮 = 本轮消息；系统轮 = 历史兜底文本）。
    var query: String
    /// 是否成功拿到判定（false = 通道不可用：网络/解析失败）。
    var available: Bool
    /// 判出的技能名（available 且为空 = 判定为「本轮不需要技能」）。
    var picked: [String]
}

/// 分支触发记录（检查器「分支技能触发记录」：竞品分析/毒舌评审等）。
nonisolated struct BranchTriggerRecord: Codable, Equatable, Identifiable {
    var id: String
    /// 分支类型：competitive_analysis | devils_review | ...
    var kind: String
    /// 人话描述（触发词/入参摘要）。
    var detail: String
    var createdAt: String
}
