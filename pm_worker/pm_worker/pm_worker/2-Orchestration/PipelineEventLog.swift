//
//  PipelineEventLog.swift
//  pm_worker
//
//  流水线事件流（Codex rollout 模式，design.md §5 事实源体系）：
//  阶段推进 / 确认闸口 / 回退 / 产物落盘 / PRD 过期等关键节点
//  追加写 events.jsonl（append-only，一行一事件）——审计轨迹 +
//  崩溃后按事件重放恢复的底座。写入失败静默（事件流是旁路，不阻塞流水线）。
//

import Foundation

/// events.jsonl 单条事件。
nonisolated struct PipelineEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case clarifyRound       // 澄清一轮完成
        case stageAdvance       // 阶段推进（①→②）
        case stageConfirm       // 确认闸口通过（②/③）
        case stageInvalidate    // 回退（结构重生成 / 原型重做）
        case artifactGenerated  // 产物落盘（结构三项 / 原型 / PRD）
        case prdStaleMarked     // PRD 过期标记
        case prdStaleCleared    // PRD 过期清除
        case radarRecorded      // 自评审入账（修正数）
        case gateEvaluated      // 机器门评审（Tier1/Tier2 结果与打回）
    }

    var id: String
    var kind: Kind
    /// 事件发生后的当前阶段（PipelineRun.Stage.rawValue）。
    var stage: String
    /// 人话描述（审计可读）。
    var detail: String
    /// 回退 / 标记原因（structure_regen / prototype_regen / prd_stale 等）。
    var reason: String?
    /// 闸口确认 outcome 结算（approved / approved_after_revision / fast_track）：
    /// 仅带批准仪式语义的事件携带（① 确认推进 / ②③ stageConfirm）。
    /// 驳回不在此列——stageInvalidate 事件即驳回留痕。历史行无此键 → nil。
    var outcome: String?
    var createdAt: String
}

/// 事件流读写：append-only 写 + 全量读（重放 / 审计 / 测试）。
nonisolated enum PipelineEventLog {

    /// events.jsonl 位置：版本目录根（与 decisions.jsonl 同级）。
    static func url(project: String, version: String) -> URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("events.jsonl")
    }

    /// 追加事件（文件缺失自动补建——兼容 events.jsonl 之前创建的旧工作区）。
    /// 静默失败：事件流是旁路，永不阻塞流水线。
    static func append(
        kind: PipelineEvent.Kind,
        stage: String,
        detail: String,
        reason: String? = nil,
        outcome: String? = nil,
        project: String,
        version: String
    ) {
        let url = url(project: project, version: version)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard fm.createFile(atPath: url.path, contents: nil) else { return }
        }
        let event = PipelineEvent(
            id: UUID().uuidString,
            kind: kind,
            stage: stage,
            detail: detail,
            reason: reason,
            outcome: outcome,
            createdAt: ISO8601.timestamp()
        )
        try? PMAgentStore.appendLine(event, to: url)
    }

    /// 全量读回（文件缺失 / 单行解析失败跳过，不抛错）。
    static func events(project: String, version: String) -> [PipelineEvent] {
        PMAgentStore.readLines(
            PipelineEvent.self, from: url(project: project, version: version)
        )
    }
}
