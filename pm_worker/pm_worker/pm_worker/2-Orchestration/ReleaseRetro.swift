//
//  ReleaseRetro.swift
//  pm_worker
//
//  封板复盘 · 本版决策稳定性（2026-09-16）：changes.jsonl + events.jsonl +
//  decisions.jsonl 的确定性 fold——封板毕业仪式从「清账」升级为「对账」。
//  纯磁盘事实聚合，不虚构、不经 LLM 转述；两处消费：
//  1. ProjectHomeView 封板第一段确认弹窗的一行摘要（oneLiner）
//  2. AppModel.releaseVersion 把复盘段持久化进 release-notes 尾部（markdownSection）
//
//  数据口径：
//  - 变更处置分布 ← changes.jsonl fold（ChangeLedger）
//  - 回退分布 ← events.jsonl stageInvalidate（按回退目标阶段计数，驳回留痕）
//  - 闸口确认 outcome 分布 ← events.jsonl 带 outcome 键的事件
//    （approved / approved_after_revision / fast_track，①②③ 确认漏斗写入）
//

import Foundation

/// 回退分布单项（阶段 → 次数；struct 以便 Equatable 合成）。
nonisolated struct ReleaseRetroStageCount: Equatable {
    let stage: String
    let count: Int
}

/// 封板复盘快照：三类稳定性信号的确定性聚合。
nonisolated struct ReleaseRetro: Equatable {
    /// 变更提案总数（changes.jsonl fold 后的条目数）。
    var proposals: Int = 0
    var adopted: Int = 0    // 纳入当前版本
    var dropped: Int = 0    // 放弃
    var deferred: Int = 0   // 顺延
    var pooled: Int = 0     // 进池未毕业（封板闸拦截 pooled>0，此处兜底呈现）
    var pending: Int = 0    // 提案卡从未处置（闸不拦 pending，封板留痕诚实呈现）
    /// 回退分布（次数降序；并列按阶段名稳定排序）。
    var invalidations: [ReleaseRetroStageCount] = []
    /// 闸口确认 outcome 计数（键 = 事件 outcome 原始值）。
    var confirmOutcomes: [String: Int] = [:]
    /// 决策留痕条数（decisions.jsonl 全量行）。
    var decisions: Int = 0
    /// 本版采纳的方法论卡标题（events.jsonl methodAdopt，出现顺序）。
    var methodAdoptions: [String] = []
    /// 本版推荐被跳过总次数（events.jsonl methodSkip）。
    var methodSkips: Int = 0
    /// 同版本内被跳过 ≥2 次的卡标题（该质疑：补充案例、更新或退场）。
    var methodQuestionable: [String] = []

    /// 三类信号全空 → 不渲染复盘段。
    var isEmpty: Bool {
        proposals == 0 && invalidations.isEmpty && confirmOutcomes.isEmpty
            && methodAdoptions.isEmpty && methodSkips == 0
    }

    // MARK: - 渲染

    /// 弹窗一行摘要；nil = 无复盘内容。
    var oneLiner: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if let segment = proposalSegment { parts.append(segment) }
        if !invalidations.isEmpty {
            let total = invalidations.reduce(0) { $0 + $1.count }
            parts.append("回退 \(total) 次（集中在 \(Self.stageLabel(invalidations[0].stage))）")
        }
        if let segment = confirmSegment { parts.append(segment) }
        guard !parts.isEmpty else { return nil }
        return "本版复盘：" + parts.joined(separator: " · ")
    }

    /// release-notes 尾部持久化段；nil = 不追加。
    var markdownSection: String? {
        guard !isEmpty else { return nil }
        var lines: [String] = ["## 本版复盘（决策稳定性）", ""]
        if let segment = proposalSegment { lines.append("- \(segment)") }
        if !invalidations.isEmpty {
            let total = invalidations.reduce(0) { $0 + $1.count }
            let detail = invalidations
                .map { "\(Self.stageLabel($0.stage)) \($0.count) 次" }
                .joined(separator: "、")
            lines.append("- 回退 \(total) 次：\(detail)")
        }
        if let segment = confirmSegment { lines.append("- \(segment)") }
        if decisions > 0 { lines.append("- 决策留痕 \(decisions) 条（decisions.jsonl）") }
        // 方法论使用报告（2026-09-17 钦定反哺机制③）：确定性统计，
        // 素材随版落 release-notes，并作下版本开工档案袋的输入
        if !methodAdoptions.isEmpty {
            lines.append("- 方法论使用：采纳 \(methodAdoptions.count) 张（\(methodAdoptions.prefix(4).joined(separator: "、"))）")
        }
        if methodSkips > 0 { lines.append("- 方法论推荐被跳过 \(methodSkips) 次") }
        if !methodQuestionable.isEmpty {
            lines.append("- 待校准：\(methodQuestionable.joined(separator: "、"))——本版连续被跳过，建议补充案例、更新或退场")
        }
        return lines.joined(separator: "\n")
    }

    /// 变更处置分布段（proposals > 0 才有）。
    private var proposalSegment: String? {
        guard proposals > 0 else { return nil }
        var parts: [String] = []
        if adopted > 0 { parts.append("纳入 \(adopted)") }
        if dropped > 0 { parts.append("放弃 \(dropped)") }
        if deferred > 0 { parts.append("顺延 \(deferred)") }
        if pooled > 0 { parts.append("进池 \(pooled)") }
        if pending > 0 { parts.append("未处置 \(pending)") }
        return "变更提案 \(proposals) 条（\(parts.joined(separator: " · "))）"
    }

    /// 闸口确认 outcome 段（固定三态顺序，零值省略）。
    private var confirmSegment: String? {
        let parts = Self.outcomeOrder.compactMap { key -> String? in
            guard let count = confirmOutcomes[key], count > 0 else { return nil }
            return "\(Self.outcomeLabel(key)) \(count)"
        }
        guard !parts.isEmpty else { return nil }
        return "闸口确认：" + parts.joined(separator: " · ")
    }

    // MARK: - 展示映射

    private static let outcomeOrder = [
        "approved", "approved_after_revision", "fast_track"
    ]

    private static func stageLabel(_ raw: String) -> String {
        switch raw {
        case "clarify": "① 澄清"
        case "structure": "② 结构"
        case "prototype": "③ 原型"
        case "prd": "④ PRD"
        default: raw
        }
    }

    private static func outcomeLabel(_ raw: String) -> String {
        switch raw {
        case "approved": "批准"
        case "approved_after_revision": "改后批准"
        case "fast_track": "快速通道"
        default: raw
        }
    }

    // MARK: - 磁盘 fold（唯一入口）

    static func load(project: String, version: String) -> ReleaseRetro {
        var retro = ReleaseRetro()

        // 变更处置分布（changes.jsonl fold）
        let items = ChangeLedger.load(project: project, version: version)
        retro.proposals = items.count
        retro.pending = items.filter(\.isPending).count
        retro.pooled = items.filter(\.isPooled).count
        retro.adopted = items.filter { $0.resolution == .adopted }.count
        retro.dropped = items.filter { $0.resolution == .dropped }.count
        retro.deferred = items.filter { $0.resolution == .deferred }.count

        // 事件流（events.jsonl）：回退分布 + outcome 分布
        let events = PipelineEventLog.events(project: project, version: version)
        var invalidateCounts: [String: Int] = [:]
        for event in events where event.kind == .stageInvalidate {
            invalidateCounts[event.stage, default: 0] += 1
        }
        retro.invalidations = invalidateCounts
            .map { ReleaseRetroStageCount(stage: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.stage < $1.stage
            }
        var outcomeCounts: [String: Int] = [:]
        for event in events {
            guard let outcome = event.outcome else { continue }
            outcomeCounts[outcome, default: 0] += 1
        }
        retro.confirmOutcomes = outcomeCounts

        // 方法论使用分布（events.jsonl methodAdopt / methodSkip，2026-09-17 钦定）：
        // detail 协议 = "id|标题"（AppModel 采纳/跳过时写入）
        var adoptions: [String] = []
        var skipTitles: [String: Int] = [:]
        for event in events {
            let title = event.detail.split(separator: "|", maxSplits: 1)
                .dropFirst().first.map(String.init) ?? event.detail
            switch event.kind {
            case .methodAdopt: adoptions.append(title)
            case .methodSkip: skipTitles[title, default: 0] += 1
            default: break
            }
        }
        retro.methodAdoptions = adoptions
        retro.methodSkips = skipTitles.values.reduce(0, +)
        retro.methodQuestionable = skipTitles
            .filter { $0.value >= 2 }
            .map(\.key)
            .sorted()

        // 决策留痕条数
        retro.decisions = PMAgentStore.readLines(
            DecisionRecord.self,
            from: PMAgentStore.jsonlURL(
                project: project, version: version, file: "decisions.jsonl"
            )
        ).count

        return retro
    }
}
