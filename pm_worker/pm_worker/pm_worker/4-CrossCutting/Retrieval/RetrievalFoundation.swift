//
//  RetrievalFoundation.swift
//  pm_worker
//
//  检索层共享基座（M4，design.md §5.3 / §6.3）：
//  - EmbeddingProviding：向量编码统一接口（真实实现 LLMClient 扩展；测试/离线兜底用确定性哈希向量）
//  - VectorMath：余弦相似度 + [Float] ↔ BLOB 编解码（SQLite embedding 列格式）
//  - RetrievalHit / RetrievalTrace：检索结果与 trace（可观测性——E11/E12 的验证依据）
//

import Foundation

// MARK: - 向量编码接口

/// 向量编码统一接口（design.md §6.3 注入链路）。
/// 实现：EmbeddingClient（OpenAI 兼容 /embeddings 端点）、DeterministicHashEmbedder（测试/离线兜底）。
nonisolated protocol EmbeddingProviding: Sendable {
    /// 批量编码；返回与输入等长的向量数组（各实现保证维度一致）。
    func embed(texts: [String]) async throws -> [[Float]]
}

/// 确定性哈希向量器：无网络环境下保证管线不断（语义质量无意义，仅保活），
/// 也是单测的假向量源——可复现、无网络依赖。
/// 原理：把文本按 2-gram 哈希进固定 256 维桶（中文友好），再 L2 归一化。
nonisolated struct DeterministicHashEmbedder: EmbeddingProviding {
    static let dimensions = 256

    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { Self.vector(for: $0) }
    }

    static func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > 0 else {
            v[0] = 1
            return v
        }
        // 字符级 + 字符级 2-gram 双通道，增强局部区分度
        for i in scalars.indices {
            bump(&v, bucket: hash(scalars[i]))
            if i + 1 < scalars.count {
                bump(&v, bucket: hash(scalars[i], scalars[i + 1]))
            }
        }
        // L2 归一化（零向量兜底给一个单位分量，防除零）
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else {
            v[0] = 1
            return v
        }
        return v.map { $0 / norm }
    }

    private static func bump(_ v: inout [Float], bucket: Int) {
        v[abs(bucket) % dimensions] += 1
    }

    private static func hash(_ s: Unicode.Scalar...) -> Int {
        var hasher = Hasher()
        for scalar in s { hasher.combine(scalar.value) }
        return hasher.finalize()
    }
}

// MARK: - 向量数学

nonisolated enum VectorMath {
    /// 余弦相似度（维度不等或零向量返回 0）。
    /// Double 域累加：Float 累加会有 ~1e-7 舍入（同向量算不出 1.0），
    /// 去重阈值（0.95）与合并判据（0.92）需要更高精度。
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    /// [Float] → BLOB（little-endian Float32 数组，无 header）。
    static func encode(_ vector: [Float]) -> Data {
        // withUnsafeBufferPointer 保证缓冲区生命周期覆盖 Data 拷贝（避免悬垂指针）
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// BLOB → [Float]（长度非 4 的倍数返回 nil）。
    static func decode(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Float.self).map { element -> Float in element }
        }
    }

    /// 相似合并判据（design.md §6.3：相似度 > 0.92 → 合并而非新建）。
    static let mergeThreshold = 0.92
}

// MARK: - 检索结果与 trace

/// 单条命中（卡片库或技能库）。
nonisolated struct RetrievalHit: Codable, Equatable, Identifiable {
    enum Library: String, Codable {
        case cards   // 方法论卡片（knowledge_points 表）
        case skills  // 技能（skills 表）
    }

    /// knowledge_points.id / skills.id
    var id: String
    var library: Library
    /// 卡片正文；技能命中后此字段为正文摘要，正文全文由 SkillLoader 按需加载（渐进式披露）
    var content: String
    /// 余弦相似度
    var score: Double
    /// scope 标签：version | project | global（命中来源，E12 验证依据）
    var scope: String
    /// scope 对象 id（global 为空）
    var scopeId: String
}

/// 一次检索的完整 trace（design.md §8 可观测性：每次检索打出 scope 与命中来源）。
nonisolated struct RetrievalTrace: Codable, Equatable {
    var query: String
    var hits: [RetrievalHit]
    /// 被过滤的跨项目条数（scope 隔离证明）
    var filteredCrossProject: Int
    /// 未命中技能 id 列表（证明其正文没被注入——E11 验证依据）
    var unmatchedSkills: [String]
    /// 检索耗时（毫秒）
    var durationMs: Int
}
