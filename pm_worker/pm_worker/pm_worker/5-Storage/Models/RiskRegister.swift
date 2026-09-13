//
//  RiskRegister.swift
//  pm_worker
//
//  risks.jsonl 的 Codable 模型（💀 条目，append-only，design.md §5.2）。
//  落盘必带 trigger_signal（防悬空）；状态机见 design.md §6.1。
//

import Foundation

/// 风险登记册条目。规则（design.md §5.2）：
/// - 落盘必带 triggerSignal（无可观测信号的不允许落盘）
/// - 活跃（open）上限软性 3 条，超限先收敛而非拒收
/// - 封板时全部 open 统一结算 closed_unfired
/// - 命中 → triggered + 回写决策日志（risk_hit 条目）
struct RiskRecord: Codable, Equatable {
    /// 触发信号枚举（状态机事件，design.md §6.1）
    enum TriggerSignal: String, Codable {
        case structureRegen = "structure_regen"
        case prototypeRegen = "prototype_regen"
        case prdStale = "prd_stale"
        case decisionOverturned = "decision_overturned"
        case release
    }

    enum Status: String, Codable {
        case open
        case triggered
        case closedUnfired = "closed_unfired"
        case closedFalsified = "closed_falsified"
        case merged
    }

    enum Stage: String, Codable {
        case clarify, structure, prototype, prd
    }

    var id: String
    var version: String
    var stage: Stage
    /// 💀 一句话假设
    var hypothesis: String
    var triggerSignal: TriggerSignal
    var status: Status
    /// 产生该 💀 的自评审摘要
    var originRef: String
    /// 结算时回填：命中回写决策日志的 id / 收敛动作说明
    var resolution: String?
    var createdAt: String
    var closedAt: String?

    init(
        id: String = IDGenerator.next("r"),
        version: String,
        stage: Stage,
        hypothesis: String,
        triggerSignal: TriggerSignal,
        status: Status = .open,
        originRef: String,
        resolution: String? = nil,
        createdAt: String = ISO8601.timestamp(),
        closedAt: String? = nil
    ) {
        self.id = id
        self.version = version
        self.stage = stage
        self.hypothesis = hypothesis
        self.triggerSignal = triggerSignal
        self.status = status
        self.originRef = originRef
        self.resolution = resolution
        self.createdAt = createdAt
        self.closedAt = closedAt
    }
}
