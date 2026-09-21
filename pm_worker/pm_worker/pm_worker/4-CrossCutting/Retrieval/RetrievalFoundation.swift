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
    /// 批量编码 + 向量来源戳（P1 嵌入守卫）：写入索引 embedding_source、
    /// 检索时与行戳比对——来源不一致的向量空间互不可比，禁止混算静默零命中。
    /// 缺省实现只能给出维度签名（自定义测试假向量走这条）。
    func embedWithSource(texts: [String]) async throws -> (vectors: [[Float]], source: String)
}

nonisolated extension EmbeddingProviding {
    func embedWithSource(texts: [String]) async throws -> (vectors: [[Float]], source: String) {
        let vectors = try await embed(texts: texts)
        return (vectors, "dim:\(vectors.first?.count ?? 0)")
    }
}

/// 向量来源戳兼容判定（P1 嵌入守卫）：
/// - 任一为空/缺省（v2 迁移前的旧行、M0 占位路径）→ 放行（维度守卫仍在检索层兜底）；
/// - 完全相等 → 放行（同模型 / 同为 hash256 空间）；
/// - 其余（真实模型 A vs 模型 B、真实模型 vs 本地兜底 hash256）→ 不兼容，不参与余弦。
nonisolated enum EmbeddingSourceStamp {
    /// 本地确定性哈希空间的统一戳（DeterministicHashEmbedder 与
    /// SettingsBackedEmbedder 的回退路径同属此空间，互相比价有效）。
    nonisolated static let hash256 = "hash256"

    static func isCompatible(_ stored: String?, _ current: String) -> Bool {
        guard let stored, !stored.isEmpty else { return true }
        return stored == current
    }
}

/// 确定性哈希向量器：无网络环境下保证管线不断（语义质量无意义，仅保活），
/// 也是单测的假向量源——可复现、无网络依赖。
/// 原理：把文本按 2-gram 哈希进固定 256 维桶（中文友好），再 L2 归一化。
/// 哈希用 FNV-1a（跨进程稳定）：索引里的技能向量是持久化的，查询向量在
/// 每次启动的新进程里现算——若用 Swift `Hasher`（每进程随机种子），
/// 两者跨启动不可比、相关度退化为噪声。勿换回 Hasher。
nonisolated struct DeterministicHashEmbedder: EmbeddingProviding {
    static let dimensions = 256

    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { Self.vector(for: $0) }
    }

    /// 哈希空间统一戳（与 SettingsBackedEmbedder 的回退路径同戳，互相比价有效）。
    func embedWithSource(texts: [String]) async throws -> (vectors: [[Float]], source: String) {
        (try await embed(texts: texts), EmbeddingSourceStamp.hash256)
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
            v[bucket(of: scalars[i])] += 1
            if i + 1 < scalars.count {
                v[bucket(of: scalars[i], scalars[i + 1])] += 1
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

    /// 桶位（0..<dimensions）：FNV-1a 64 位，仅依赖 Unicode 标量值——
    /// 同输入在任何进程/任何启动上落同一桶（稳定哈希，勿用 Hasher）。
    private static func bucket(of scalars: Unicode.Scalar...) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in scalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(dimensions))
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

// MARK: - 词面相似度（P1-5：近义改写不遗漏）

/// 零网络词面相似度：2-gram 集合重叠系数（对调序、加修饰词的近义改写鲁棒）。
/// 用于标题同主题判定与方法论↔经验主题匹配——向量口径要额外网络调用，
/// 短文本词面信号已足够（标题 ≤20 字，2-gram 全集很小，噪声可控）。
nonisolated enum LexicalSimilarity {
    /// 归一化：去全部空白 + 小写。
    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(
            of: " ", with: ""
        ).replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 重叠系数：|A∩B| / min(|A|,|B|)，短侧全覆盖时 = 1。0-1。
    nonisolated static func bigramOverlap(_ a: String, _ b: String) -> Double {
        let gramsA = bigrams(normalized(a))
        let gramsB = bigrams(normalized(b))
        guard !gramsA.isEmpty, !gramsB.isEmpty else {
            return normalized(a) == normalized(b) && !gramsA.isEmpty ? 1 : 0
        }
        let intersection = gramsA.intersection(gramsB).count
        return Double(intersection) / Double(min(gramsA.count, gramsB.count))
    }

    /// 同主题判定阈值（卡标题互比）：词序调换 / 加「的」「下」类修饰仍能命中，
    /// 同域不同主题（共享 1-2 个词）不命中——0.62 经验值，测试钉死边界。
    nonisolated static let sameTopicThreshold = 0.62
    /// 主题相关阈值（标题 vs 经验正文：min 侧是标题 bigram，取更松）。
    nonisolated static let topicRelevanceThreshold = 0.4

    private nonisolated static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count > 1 else { return chars.isEmpty ? [] : Set(chars.map(String.init)) }
        var set = Set<String>()
        for i in 0..<(chars.count - 1) {
            set.insert(String(chars[i..<(i + 2)]))
        }
        return set
    }
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
    /// 技能检索独立查询（意图优先路由：技能命中由消息语义 query 决定，卡片仍走
    /// stage query）；nil = 未分流（技能与卡片同 query）。Optional 缺键解码为 nil，
    /// 旧 trace 数据可继续解码。
    var skillQuery: String? = nil
    /// 技能索引可用性（本次检索时技能表是否存在可解码向量）：false / nil = 失效态
    ///（零长度占位向量、空表、embedder 抛错）——Context Builder 阶段锚点兜底判据。
    /// 语义为准（2026-09-15）：索引可用时零命中即不注入技能，失效态才由阶段锚点保底。
    /// Optional 缺键解码为 nil，旧 trace 数据可继续解码。
    var skillIndexReady: Bool? = nil
    /// 检索降级人话说明（P1 嵌入守卫）：向量来源戳/维度与当前编码端不一致被排除
    /// 的行数 > 0 时给出（如「18 行索引来自其他向量来源，重建索引恢复」）；
    /// nil = 未降级。Optional 缺键解码为 nil，旧 trace 数据可继续解码。
    var degraded: String? = nil
}
