//
//  DecisionLog.swift
//  pm_worker
//
//  decisions.jsonl 的 Codable 模型（append-only，design.md §5.2）。
//  两种条目：决策（五要素缺一不可）与 💀 命中回写（risk_hit）。
//

import Foundation

/// 决策条目：决策 / WHY / 排除方案 / 置信度 / 待验证 五字段缺一不可。
nonisolated struct DecisionRecord: Codable, Equatable {
    var id: String
    var version: String
    var decision: String
    var why: String
    var rejectedAlternatives: [RejectedAlternative]
    var confidence: Double
    var toBeVerified: Bool
    var createdAt: String

    init(
        id: String = IDGenerator.next("d"),
        version: String,
        decision: String,
        why: String,
        rejectedAlternatives: [RejectedAlternative] = [],
        confidence: Double = 1.0,
        toBeVerified: Bool = false,
        createdAt: String = ISO8601.timestamp()
    ) {
        self.id = id
        self.version = version
        self.decision = decision
        self.why = why
        self.rejectedAlternatives = rejectedAlternatives
        self.confidence = confidence
        self.toBeVerified = toBeVerified
        self.createdAt = createdAt
    }
}

nonisolated struct RejectedAlternative: Codable, Equatable {
    var option: String
    var reason: String
}

/// 💀 命中回写条目：风险触发信号被结算时自动 append。
nonisolated struct RiskHitRecord: Codable, Equatable {
    var type: String  // 固定 "risk_hit"
    var riskId: String
    /// 当初预测
    var predicted: String
    /// 实际发生
    var actual: String

    init(riskId: String, predicted: String, actual: String) {
        self.type = "risk_hit"
        self.riskId = riskId
        self.predicted = predicted
        self.actual = actual
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
