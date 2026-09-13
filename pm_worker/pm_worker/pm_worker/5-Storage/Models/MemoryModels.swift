//
//  MemoryModels.swift
//  pm_worker
//
//  记忆层条目模型（design.md §4 / §5.2 记忆条目）。
//  核心语义：新结论覆盖旧结论，不并存——旧条目标记失效并留回链。
//  「经验」类型带 source_ref 与 confidence，跨项目按假设态注入。
//

import Foundation

nonisolated struct MemoryEntry: Codable, Equatable {
    enum Scope: String, Codable {
        case global, project, version
    }

    /// 类型：结论 / 约束 / 否决项 / 经验（v0.9.10 起讨论萃取物归记忆层）
    enum Kind: String, Codable {
        case conclusion   // 结论
        case constraint    // 约束
        case rejection     // 否决项
        case experience    // 经验
    }

    var id: String
    var scope: Scope
    /// scope 对应的对象 id（global 时为空）
    var scopeId: String
    var kind: Kind
    var content: String
    /// 「经验」必填：出自哪个项目哪次讨论
    var sourceRef: String?
    /// 「经验」带，其余可省
    var confidence: Double?
    /// 是否失效（被新结论覆盖后置 true）
    var invalidated: Bool
    /// 被谁覆盖（失效回链）
    var supersededBy: String?
    var createdAt: String

    init(
        id: String = IDGenerator.next("m"),
        scope: Scope,
        scopeId: String = "",
        kind: Kind,
        content: String,
        sourceRef: String? = nil,
        confidence: Double? = nil,
        invalidated: Bool = false,
        supersededBy: String? = nil,
        createdAt: String = ISO8601.timestamp()
    ) {
        self.id = id
        self.scope = scope
        self.scopeId = scopeId
        self.kind = kind
        self.content = content
        self.sourceRef = sourceRef
        self.confidence = confidence
        self.invalidated = invalidated
        self.supersededBy = supersededBy
        self.createdAt = createdAt
    }
}
