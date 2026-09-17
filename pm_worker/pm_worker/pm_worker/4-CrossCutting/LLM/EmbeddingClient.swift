//
//  EmbeddingClient.swift
//  pm_worker
//
//  向量编码客户端（design.md §6.3）：POST {resolvedBaseURL}/embeddings
//  （OpenAI 兼容端点）。请求构造与错误风格对齐 LLMClient；
//  配置取 .embedding 阶段（LLMSettings.stages）+ Keychain API Key。
//

import Foundation

/// nonisolated：纯网络与解析，无 UI 状态（横切层纯类型）。
nonisolated enum EmbeddingClient {

    enum EmbeddingError: LocalizedError {
        case missingAPIKey
        /// Keychain item 存在但读取被拒（构建重签后运行中进程常见）——
        /// 勿与 missingAPIKey 混同：重启 App 即恢复，重填 Key 无效。
        case keychainAccessDenied(OSStatus)
        case missingBaseURL
        case http(Int, String)
        /// 返回向量条数与输入不符
        case mismatchedRows(expected: Int, received: Int)
        /// 返回向量维度不一致
        case dimensionMismatch
        /// 响应体无法解析（缺少 data / index / embedding 字段，或 index 重复越界）
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "未配置向量编码阶段的 API Key——请到设置（⌘,）填写"
            case .keychainAccessDenied(let status):
                "向量编码阶段的 API Key 在钥匙串中完好但访问被拒（构建重签后常见）——退出并重启 App 即恢复，无需重填（OSStatus \(status)）"
            case .missingBaseURL: "向量编码阶段的模型端点（baseURL）未配置"
            case .http(let code, let body): "HTTP \(code)：\(body.prefix(300))"
            case .mismatchedRows(let expected, let received):
                "向量编码返回条数（\(received)）与输入（\(expected)）不符"
            case .dimensionMismatch: "向量编码返回的各向量维度不一致"
            case .invalidResponse: "向量编码响应无法解析（缺少 data / index / embedding 字段）"
            }
        }
    }

    /// 独立会话：请求超时 60s（嵌入批量大，比对话宽松）。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    /// 批量编码：POST {resolvedBaseURL}/embeddings（OpenAI 兼容）。
    /// body: {"model": ..., "input": [texts]}；
    /// response: {"data":[{"index":i,"embedding":[...]}]}——按 index 对齐输入顺序。
    /// 空输入直接返回空（不发请求）；所有向量等长（维度校验）。
    static func embed(texts: [String], settings: LLMSettings) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        guard let config = settings.stages[.embedding] else {
            throw EmbeddingError.missingBaseURL
        }
        // 与 LLMClient.streamChat 同纪律：拒读（accessFailed）不得折叠成「未配置」。
        let apiKey: String
        switch KeychainStore.read(config.apiKeyKeychainKey) {
        case .found(let key) where !key.isEmpty:
            apiKey = key
        case .accessFailed(let status):
            throw EmbeddingError.keychainAccessDenied(status)
        default:
            throw EmbeddingError.missingAPIKey
        }
        let baseURL = config.resolvedBaseURL
        guard !baseURL.isEmpty else { throw EmbeddingError.missingBaseURL }

        var request = URLRequest(url: URL(string: "\(baseURL)/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // OpenAI 兼容请求体
        struct Body: Codable {
            var model: String
            var input: [String]
        }
        request.httpBody = try JSONEncoder().encode(Body(model: config.model, input: texts))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EmbeddingError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let vectors = try parseResponse(data, count: texts.count)
        recordUsage(data: data, texts: texts, model: config.model)
        return vectors
    }

    /// 成功调用记一笔用量（CostTracker，stage=embedding；此前 embedding 调用不入账）。
    /// 输入 token = usage.prompt_tokens（OpenAI 兼容）；端点未返回 usage 时按文本估算。
    private static func recordUsage(data: Data, texts: [String], model: String) {
        struct Wrapper: Codable {
            struct Usage: Codable {
                var promptTokens: Int?
                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                }
            }
            var usage: Usage?
        }
        let usage = (try? JSONDecoder().decode(Wrapper.self, from: data))?.usage
        let estimated = usage?.promptTokens == nil
        let tokens = usage?.promptTokens
            ?? TokenBreakdown.estimate(texts.joined(separator: "\n"))
        CostTracker.shared.record(UsageRecord(
            ts: ISO8601.timestamp(), stage: LLMStage.embedding.rawValue, model: model,
            promptTokens: tokens, completionTokens: 0, estimated: estimated
        ))
    }

    /// 响应解析（独立成函数便于直测，不发网络）：
    /// - data 数组按 index 对齐输入顺序（服务端乱序返回也能对回）
    /// - 条数不符 / 维度不一致 / index 缺失、重复、越界 / 向量为空 → 抛错
    static func parseResponse(_ data: Data, count: Int) throws -> [[Float]] {
        struct Response: Codable {
            struct Item: Codable {
                var index: Int?
                var embedding: [Float]?
            }
            var data: [Item]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw EmbeddingError.invalidResponse
        }
        let items = decoded.data ?? []
        guard items.count == count else {
            throw EmbeddingError.mismatchedRows(expected: count, received: items.count)
        }

        var result = [[Float]](repeating: [], count: count)
        var seen = Set<Int>()
        var dimension: Int?
        for item in items {
            guard let index = item.index, (0..<count).contains(index), !seen.contains(index) else {
                throw EmbeddingError.invalidResponse
            }
            guard let vector = item.embedding, !vector.isEmpty else {
                throw EmbeddingError.invalidResponse
            }
            if let dimension {
                guard vector.count == dimension else { throw EmbeddingError.dimensionMismatch }
            } else {
                dimension = vector.count
            }
            seen.insert(index)
            result[index] = vector
        }
        return result
    }
}
