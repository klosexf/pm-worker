//
//  RiskRegister.swift
//  pm_worker
//
//  risks.jsonl 的 Codable 模型（append-only，design.md §5.2）。
//  四态闭环（方案 A 台账）：待处理 → 采纳方案挂起 → 验证解除；或接受自留。
//  旧版五枚举触发信号状态（triggered / closed_unfired / closed_falsified /
//  merged）保留仅作历史文件解码兼容，只读展示，新写入不再产生。
//

import Foundation

/// 风险登记册条目。四态语义（方案 A）：
/// - open：待处理（自评审登记，带「炸了会怎样」与建议方案）
/// - mitigating：已挂方案（采纳 ≠ 解除——方案落地并确认没出事才算数）
/// - resolved：已解除（验证通过，风险关闭；回写决策日志）
/// - accepted：已接受（风险自留，封板时带入 PRD 已知风险）
/// - 命中（上游产物重做撞上未处理风险）→ 重开回 open，决策日志留 risk_hit 对照
struct RiskRecord: Codable, Equatable {
    /// 触发信号（旧版状态机事件；新登记可缺省——结算点改为阶段确认门）
    enum TriggerSignal: String, Codable {
        case structureRegen = "structure_regen"
        case prototypeRegen = "prototype_regen"
        case prdStale = "prd_stale"
        case decisionOverturned = "decision_overturned"
        case release
    }

    enum Status: String, Codable {
        // 四态（现行）
        case open            // 待处理
        case mitigating      // 已挂方案 · 等验证
        case resolved        // 已解除 · 验证通过
        case accepted        // 已接受 · 风险自留
        // 旧版状态（历史文件兼容，只读展示，不再新写入）
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
    /// 风险一句话（哪个假设一旦不成立会出事）
    var hypothesis: String
    /// 炸了会怎样——对用户 / 进度的具体后果（缺省 = 旧版条目）
    var impact: String?
    /// 建议应对方案——可执行的一句话（缺省 = 旧版条目）
    var plan: String?
    /// 触发信号（可选：新登记按阶段绑定，结算点在确认门）
    var triggerSignal: TriggerSignal?
    var status: Status
    /// 产生该风险的自评审摘要
    var originRef: String
    /// 结算时回填：决策日志编号 / 重开原因 / 自留说明
    var resolution: String?
    var createdAt: String
    var closedAt: String?

    init(
        id: String = IDGenerator.next("r"),
        version: String,
        stage: Stage,
        hypothesis: String,
        impact: String? = nil,
        plan: String? = nil,
        triggerSignal: TriggerSignal? = nil,
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
        self.impact = impact
        self.plan = plan
        self.triggerSignal = triggerSignal
        self.status = status
        self.originRef = originRef
        self.resolution = resolution
        self.createdAt = createdAt
        self.closedAt = closedAt
    }

    // MARK: 状态口径

    /// 未闭合 = 还需要看一眼的（待处理 / 已挂方案）。
    var isActive: Bool { status == .open || status == .mitigating }
    /// 已闭合 = 终态（解除 / 接受 / 旧版各终态）。
    var isClosed: Bool { !isActive }
}

/// 状态的人话与视觉口径（台账 Tab 与决策日志共用；nonisolated 供测试直测）。
nonisolated enum RiskStatusPresentation {
    /// 状态徽章文案。
    static func text(_ status: RiskRecord.Status) -> String {
        switch status {
        case .open: "待处理"
        case .mitigating: "已挂方案"
        case .resolved: "已解除"
        case .accepted: "已接受"
        case .triggered: "被说中了"
        case .closedUnfired: "安全落地"
        case .closedFalsified: "已关闭"
        case .merged: "已合并"
        }
    }

    /// 已处理区内的行内结果行（resolved / accepted 之外的旧终态走 resolution 文案）。
    static func resultText(_ record: RiskRecord) -> String? {
        switch record.status {
        case .resolved: "✓ 已解除 · 验证通过"
        case .accepted: "◦ 已接受 · 风险自留"
        default: nil
        }
    }
}
