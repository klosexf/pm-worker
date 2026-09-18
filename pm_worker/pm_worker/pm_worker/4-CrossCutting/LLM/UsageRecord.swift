//
//  UsageRecord.swift
//  pm_worker
//
//  单次 LLM 调用用量记录（M5 Task 5.4）：流式/非流式统一捕获。
//  JSONL 落盘（Application Support/pm-worker/usage.jsonl，append-only）。
//

import Foundation

/// 单次调用用量记录（JSONL 落盘：Application Support/pm-worker/usage.jsonl）。
nonisolated struct UsageRecord: Codable, Equatable {
    /// ISO8601.timestamp() 时刻（读侧按 yyyy-MM 前缀聚合月份；峰谷判定也按它）。
    var ts: String
    /// LLMStage rawValue。
    var stage: String
    /// 模型名（CostTracker 价目表查价键）。
    var model: String
    var promptTokens: Int
    var completionTokens: Int
    /// 输入中缓存命中部分（≤ promptTokens；旧记录无此字段按 0）。
    var cacheHitTokens: Int = 0
    /// 端点未返回 usage、用 TokenBreakdown.estimate 估算时 true。
    var estimated: Bool
    /// 归因增强（2026-09-18 提速归因）：轮次关联 id——同一轮的多次请求
    ///（空流重试/截断续写）共享；与 StreamProbe 时间线可按 id 对齐。旧记录 nil。
    var roundId: String? = nil
    /// 本次请求净耗时（秒，流开到流末；探针同源）。旧记录 nil。
    var totalS: Double? = nil
    /// 首 token 延迟（秒）。旧记录 nil。
    var ttftS: Double? = nil
}

// 旧 JSONL 兼容：cacheHitTokens 缺省 0（decodeIfPresent）；
// 放 extension 保住 memberwise init 的默认参。
// nonisolated：extension 不继承 nonisolated（默认 MainActor 隔离会让
// init(from:) 与 nonisolated struct 上的 Decodable 一致性跨隔离冲突）。
nonisolated extension UsageRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decode(String.self, forKey: .ts)
        stage = try container.decode(String.self, forKey: .stage)
        model = try container.decode(String.self, forKey: .model)
        promptTokens = try container.decode(Int.self, forKey: .promptTokens)
        completionTokens = try container.decode(Int.self, forKey: .completionTokens)
        cacheHitTokens = try container.decodeIfPresent(Int.self, forKey: .cacheHitTokens) ?? 0
        estimated = try container.decode(Bool.self, forKey: .estimated)
        roundId = try container.decodeIfPresent(String.self, forKey: .roundId)
        totalS = try container.decodeIfPresent(Double.self, forKey: .totalS)
        ttftS = try container.decodeIfPresent(Double.self, forKey: .ttftS)
    }
}
