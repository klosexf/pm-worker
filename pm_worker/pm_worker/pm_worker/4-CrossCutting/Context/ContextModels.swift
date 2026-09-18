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

// MARK: - 动态材料尾条协议（前缀缓存，2026-09-17）

/// system prompt 与「动态材料」的组装/拆分协议（前缀缓存改造）：
/// 冻结段（角色/任务/约束/输出协议/上游产物/规则层/自检清单）留在 system prompt——
/// 同阶段跨轮次字节级一致，是 provider 前缀缓存（DeepSeek/GLM implicit caching，
/// 只认字节级一致前缀）的可命中区；动态材料（记忆/技能正文/检索参考/引用文件正文）
/// 每轮随语义命中与记忆收纳变化——曾嵌入 system prompt 中部，任何变化都使其后的
/// 全部对话历史（唯一 append-only 的可缓存区）连坐失效，实测大请求缓存命中 0%。
///
/// 协议流转：assemble 产出「冻结段 + marker + 动态材料」复合 prompt，沿既有
/// systemPrompt 参数链下传（send/sendSystemTurn 调用点零改动）；发送前
/// SessionStore.split 拆开——冻结段进 system 消息，动态材料以独立 user 角色消息
/// 追加在当前用户消息之后。user 角色是刻意的：部分 provider 会把 conversation
/// 中部的 system 消息折叠回头部（前缀缓存再次失效），user 消息无归一化风险，
/// 与「前情摘要」user 注入先例同构。
/// 未拆分的消费路径拿到复合 prompt 组 system = 自动退化为旧行为（材料仍在
/// system，功能不损失，仅缓存不命中）——安全兜底。
nonisolated enum ContextTail {
    /// 冻结段与动态材料的分割标记（独占一行；注入内容来自本地组装，不含该串）。
    static let marker = "<<<PM_VOLATILE_TAIL>>>"

    /// 复合 prompt：tail 为空原样返回（不产生标记，split 恒得空尾）。
    static func compose(system: String, tail: String) -> String {
        tail.isEmpty ? system : system + "\n" + marker + "\n" + tail
    }

    /// 拆分：无标记 → (prompt, "")。compose/split 字节级往返恒等
    ///（compose 恰补一对换行，split 原样摘除）。
    static func split(_ prompt: String) -> (system: String, tail: String) {
        guard let range = prompt.range(of: marker) else { return (prompt, "") }
        var system = String(prompt[..<range.lowerBound])
        var tail = String(prompt[range.upperBound...])
        if system.hasSuffix("\n") { system.removeLast() }
        if tail.hasPrefix("\n") { tail.removeFirst() }
        return (system, tail)
    }
}

// MARK: - 组装结果与 trace

/// 一次 Context Builder 组装的完整产物（历史段由 SessionStore 按预算截断注入）。
nonisolated struct ContextAssembly: Codable, Equatable {
    /// 冻结 system prompt（骨架 + 规则层 + 自检清单；已过预算裁剪）。
    /// 动态材料不在此——见 injectionText / ContextTail 协议。
    var systemPrompt: String
    /// 组装时的阶段查询摘要（检索 query）。
    var query: String
    /// 阶段。
    var stage: String
    /// token 构成。
    var breakdown: TokenBreakdown
    /// 检索 trace（命中 + scope 标签 + 相似度；未命中技能列表在其中）。
    var retrieval: RetrievalTrace?
    /// 动态材料全文（记忆 + 技能正文 + 检索参考；已过预算裁剪）——不嵌入
    /// systemPrompt，由 SessionStore 以「动态材料尾条」（ContextTail 协议）追加。
    var injectionText: String = ""
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
