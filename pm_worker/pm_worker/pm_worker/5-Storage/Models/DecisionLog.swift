//
//  DecisionLog.swift
//  pm_worker
//
//  decisions.jsonl 的 Codable 模型（append-only，design.md §5.2）。
//  两种条目：决策（五要素缺一不可）与 💀 命中回写（risk_hit）。
//  2026-09-16 写入时富化：决策可选携带话题字段（topic / user_ask /
//  turning_points）与认知所有权标注（owner）——历史行无这些键，解码为 nil，
//  渲染侧按「有 topic = 富话题卡，无 = 历史简单卡」降级。
//

import Foundation

/// 认知所有权标注（写入时富化，防「认知所有权失窃」）：
/// 备选方案 / 转折点是谁的思路。存储层存原始字符串（LLM 输出未知枚举值
/// 不得炸整行解码），本枚举只做展示映射。
nonisolated enum OwnershipTag: String {
    case original   // 用户原创
    case adopted    // AI 建议-采纳
    case modified   // AI 建议-修改
    case rejected   // AI 建议-未采纳

    var label: String {
        switch self {
        case .original: return "原创"
        case .adopted: return "AI建议-采纳"
        case .modified: return "AI建议-修改"
        case .rejected: return "AI建议-未采纳"
        }
    }
}

/// 系统记账决策类别（区别于话题讨论决策）：风险应对 / 风险解除 / 变更池毕业。
/// 这些是业务流程触发的确定性记账，不经历话题讨论，因此天然无 topic /
/// userAsk / turningPoints——渲染层按此出「记账卡」，而非降级成「历史格式」。
nonisolated enum LedgerKind: String {
    case riskMitigation = "风险应对"
    case riskResolution = "风险解除"
    case toNextVersion = "纳入后续版本"
    case routeSelection = "路径选择"
}

/// 决策条目：决策 / WHY / 排除方案 / 置信度 / 待验证 五字段缺一不可。
nonisolated struct DecisionRecord: Codable, Equatable {
    var id: String
    var version: String
    var decision: String
    var why: String
    var rejectedAlternatives: [RejectedAlternative]
    var confidence: Double
    var toBeVerified: Bool
    /// 实施证据指针（可选，采纳落实闭环写入）：生成实施交付物的对话留痕，
    /// 形如「对话留痕 · 会话 s_xx · 回合 m_xx」。历史行无此字段 → 解码为 nil。
    var evidence: String?
    /// 话题标题（可选富化）：非空 = 本条是一次话题闭合的结论，
    /// 档案渲染为富话题卡（诉求 / 备选取舍 / 转折点）；nil = 历史原子决策。
    var topic: String?
    /// 用户最初诉求（可选富化，随 topic 出现）。
    var userAsk: String?
    /// 关键转折点（可选富化，随 topic 出现）：推翻 / 拐弯的终局视角还原。
    /// 可选存储：合成 Codable 用 decodeIfPresent——旧行无此键不炸解码
    /// （非可选数组会严格 decode 导致历史行被静默丢弃）。
    var turningPoints: [TurningPoint]?
    /// 结论依据（可选富化）：支撑数据 / 核心逻辑链路 / 参考事实或案例三槽。
    /// 历史行无此键 → 解码 nil，渲染降级为仅 why 一行。
    var basis: DecisionBasis?
    /// 取代的旧否决（可选，2026-09-18 supersedes 协议）：形如 ["d_xxx#0"]——
    /// 决策 id + 被推翻否决的序号。本决策推翻历史决策的某条否决（典型：当初
    /// 临时否决注明「需验证」，后续裁决翻转）时由 LLM 在 decision 块回填。
    /// 注入层（rejectionsInjection / supersedableRejections）跳过被取代条目
    /// （生效视图），决策档案渲染保留全量历史（路过视图）。append-only 不改写
    /// 旧行，取代关系由新行携带。历史行无此键 → 解码 nil。
    var supersedes: [String]?
    var createdAt: String

    init(
        id: String = IDGenerator.next("d"),
        version: String,
        decision: String,
        why: String,
        rejectedAlternatives: [RejectedAlternative] = [],
        confidence: Double = 1.0,
        toBeVerified: Bool = false,
        evidence: String? = nil,
        topic: String? = nil,
        userAsk: String? = nil,
        turningPoints: [TurningPoint]? = nil,
        basis: DecisionBasis? = nil,
        supersedes: [String]? = nil,
        createdAt: String = ISO8601.timestamp()
    ) {
        self.id = id
        self.version = version
        self.decision = decision
        self.why = why
        self.rejectedAlternatives = rejectedAlternatives
        self.confidence = confidence
        self.toBeVerified = toBeVerified
        self.evidence = evidence
        self.topic = topic
        self.userAsk = userAsk
        self.turningPoints = turningPoints
        self.basis = basis
        self.supersedes = supersedes
        self.createdAt = createdAt
    }

    /// 是否为富话题记录（决定档案渲染形态）。
    var isTopicEnriched: Bool { !(topic ?? "").isEmpty }

    /// 系统记账判别：决策文本命中确定性写入前缀 → 对应记账类别（nil = 非记账）。
    /// 前缀与 RiskStore.mitigationDecision / resolutionDecision、
    /// AppModel 变更池毕业写入的 decision 首缀严格一致。
    var ledgerKind: LedgerKind? {
        if decision.hasPrefix("【风险应对】") { return .riskMitigation }
        if decision.hasPrefix("【风险解除】") { return .riskResolution }
        if decision.hasPrefix("纳入后续版本：") { return .toNextVersion }
        if decision.hasPrefix("【路径选择】") { return .routeSelection }
        return nil
    }
}

nonisolated struct RejectedAlternative: Codable, Equatable {
    var option: String
    var reason: String
    /// 认知所有权原始标注（original / adopted / modified / rejected）。
    /// 历史行与未知值 → nil（不炸解码）。
    var owner: String?

    init(option: String, reason: String, owner: String? = nil) {
        self.option = option
        self.reason = reason
        self.owner = owner
    }

    /// 所有权展示映射（未知值 → nil 不显示）。
    var ownership: OwnershipTag? { owner.flatMap(OwnershipTag.init(rawValue:)) }
}

/// 转折点（写入时富化）：话题讨论中的推翻 / 拐弯，终局视角一句话。
nonisolated struct TurningPoint: Codable, Equatable {
    var text: String
    var owner: String?

    init(text: String, owner: String? = nil) {
        self.text = text
        self.owner = owner
    }

    var ownership: OwnershipTag? { owner.flatMap(OwnershipTag.init(rawValue:)) }
}

/// 结论依据（2026-09-17 富化）：话题闭合决策必填的「为什么」结构化三槽——
/// 支撑数据 / 核心逻辑链路 / 参考事实或案例。事后回溯时看 basis 就能还原
/// 当时为什么这么判断；缺一手数据的槽写明依据来源（行业共识/类比案例/用户原话）。
/// 历史行无此键 → 解码 nil（合成 Codable 对可选属性用 decodeIfPresent）。
nonisolated struct DecisionBasis: Codable, Equatable {
    var data: String?    // 支撑数据
    var logic: String?   // 核心逻辑链路
    var facts: String?   // 参考的事实或案例

    /// 三槽全空 = 无有效依据（渲染层据此整节省略）。
    var isEmpty: Bool {
        (data ?? "").isEmpty && (logic ?? "").isEmpty && (facts ?? "").isEmpty
    }
}

/// 💀 命中回写条目：风险触发信号被结算时自动 append。
nonisolated struct RiskHitRecord: Codable, Equatable {
    var type: String  // 固定 "risk_hit"
    var riskId: String
    /// 当初预测
    var predicted: String
    /// 实际发生
    var actual: String
    /// 结算时刻（2026-09-16 起）：档案按天归组用。历史行无此字段 → nil，
    /// 归组时回退文件序上方最近一条决策的天。
    var createdAt: String?

    init(riskId: String, predicted: String, actual: String, createdAt: String? = nil) {
        self.type = "risk_hit"
        self.riskId = riskId
        self.predicted = predicted
        self.actual = actual
        self.createdAt = createdAt
    }
}

/// decisions.jsonl 单行：决策 或 💀 命中回写。
nonisolated enum DecisionLogEntry: Equatable {
    case decision(DecisionRecord)
    case riskHit(RiskHitRecord)
}

extension DecisionLogEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        if type == "risk_hit" {
            self = .riskHit(try RiskHitRecord(from: decoder))
        } else {
            self = .decision(try DecisionRecord(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .decision(let record):
            try record.encode(to: encoder)
        case .riskHit(let record):
            try record.encode(to: encoder)
        }
    }
}
