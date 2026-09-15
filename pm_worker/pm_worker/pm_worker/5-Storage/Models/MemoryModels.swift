//
//  MemoryModels.swift
//  pm_worker
//
//  记忆层条目模型（方案 A 台账式 · 两档作用域定稿）：
//  - 作用域两档：global（跨项目）/ project（本项目，跨版本共享）——完全分离
//  - 版本不是作用域：条目带 versions 溯源标签（如 "v1.0~v1.2"），留空 = 跨版本通用
//  - 类型四值为 AI 内部字段（沉淀时自动打标），UI 只暴露两个行为标记：
//    ⚑ 硬边界（constraint/rejection，永不裁剪）、假设（experience，未验证可裁剪）
//  - confidence 为 AI 内部自评，仅用于注入裁剪排序，不对用户显示
//  - 核心语义：新结论覆盖旧结论（supersededBy 回链），失效条目不注入、留痕可追溯
//  - 旧数据兼容：scope=version 的历史条目解码时投影为 project + versions=原版本号
//

import Foundation

nonisolated struct MemoryEntry: Codable, Equatable, Identifiable {
    enum Scope: String, Codable {
        case global, project
    }

    /// 类型（AI 内部字段）：结论 / 约束 / 否决项 / 经验
    enum Kind: String, Codable {
        case conclusion   // 结论
        case constraint    // 约束
        case rejection     // 否决项
        case experience    // 经验
    }

    var id: String
    var scope: Scope
    /// scope 对应的对象 id（global 时为空，project 时为项目名）
    var scopeId: String
    var kind: Kind
    var content: String
    /// 版本溯源标签（如 "v1.0~v1.2"）；nil/空 = 跨版本通用
    var versions: String?
    /// 「经验」可选：出自哪个项目哪次讨论
    var sourceRef: String?
    /// AI 内部自评置信度（仅裁剪排序用，不显示）
    var confidence: Double?
    /// 「经验」校准中：最近一次被注入后待用户确认（确认/否定后清除）
    var calibrationPending: Bool?
    /// 「经验」最近一次被注入的时间（ISO8601）
    var lastInjectedAt: String?
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
        versions: String? = nil,
        sourceRef: String? = nil,
        confidence: Double? = nil,
        calibrationPending: Bool? = nil,
        lastInjectedAt: String? = nil,
        invalidated: Bool = false,
        supersededBy: String? = nil,
        createdAt: String = ISO8601.timestamp()
    ) {
        self.id = id
        self.scope = scope
        self.scopeId = scopeId
        self.kind = kind
        self.content = content
        self.versions = versions
        self.sourceRef = sourceRef
        self.confidence = confidence
        self.calibrationPending = calibrationPending
        self.lastInjectedAt = lastInjectedAt
        self.invalidated = invalidated
        self.supersededBy = supersededBy
        self.createdAt = createdAt
    }

    // MARK: - 旧数据兼容解码（version scope → project + versions 标签）

    private enum CodingKeys: String, CodingKey {
        case id, scope, scopeId, kind, content, versions
        case sourceRef, confidence, calibrationPending, lastInjectedAt
        case invalidated, supersededBy, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawScope = (try? c.decode(String.self, forKey: .scope)) ?? "project"
        switch rawScope {
        case "global": scope = .global
        default: scope = .project   // "project" 与旧 "version" 都归项目池
        }
        scopeId = (try? c.decodeIfPresent(String.self, forKey: .scopeId)) ?? ""
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .conclusion
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        versions = try c.decodeIfPresent(String.self, forKey: .versions)
        // 旧 version 作用域条目：scopeId 即版本号 → 转为溯源标签（读时迁移，旧文件不动）
        if rawScope == "version", (versions ?? "").isEmpty {
            versions = scopeId
        }
        sourceRef = try c.decodeIfPresent(String.self, forKey: .sourceRef)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        calibrationPending = try c.decodeIfPresent(Bool.self, forKey: .calibrationPending)
        lastInjectedAt = try c.decodeIfPresent(String.self, forKey: .lastInjectedAt)
        invalidated = (try? c.decode(Bool.self, forKey: .invalidated)) ?? false
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ISO8601.timestamp()
    }
}
