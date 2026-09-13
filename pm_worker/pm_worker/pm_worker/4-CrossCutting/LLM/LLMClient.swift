//
//  LLMClient.swift
//  pm_worker
//
//  手写 SSE 流式对话（design.md §8 技术选型：URLSession.bytes + SSE 解析，
//  OpenAI 兼容端点；卡 1 天才切 MacPaw/OpenAI 兜底，不许硬扛）。
//

import Foundation

nonisolated struct ChatMessage: Codable, Equatable {
    enum Role: String, Codable {
        case system, user, assistant
    }

    var role: Role
    var content: String
    /// 附图（仅 user 消息有意义）：OpenAI 兼容 image_url 随 content 数组携带。
    var images: [ChatImage]?

    init(role: Role, content: String, images: [ChatImage]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }

    // Codable 兼容旧存量（无 images 字段的 JSON）
    private enum CodingKeys: String, CodingKey {
        case role, content, images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        images = try c.decodeIfPresent([ChatImage].self, forKey: .images)
    }
}

/// 随消息携带的图片（base64 内联，data URL 形式发给视觉模型）。
nonisolated struct ChatImage: Codable, Equatable {
    /// MIME 类型（image/png 等）。
    var mime: String
    /// base64 编码的图片数据。
    var base64: String

    /// OpenAI 兼容 image_url 的 data URL。
    var dataURL: String { "data:\(mime);base64,\(base64)" }
}

/// 流式增量：正文或思考（DeepSeek/GLM 等兼容端点的 reasoning_content）。
nonisolated enum LLMDelta: Equatable {
    case text(String)
    case reasoning(String)
}

/// 流式末 chunk 携带的 usage（OpenAI 兼容；M5 Task 5.4 成本统计）。
nonisolated struct StreamUsage: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    /// DeepSeek 专属：输入缓存命中 tokens。
    var promptCacheHitTokens: Int? = nil
    /// OpenAI 兼容：prompt_tokens_details.cached_tokens。
    var promptTokensDetails: PromptTokensDetails? = nil

    nonisolated struct PromptTokensDetails: Codable, Equatable {
        var cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    /// 缓存命中数：DeepSeek 专属字段优先，退回 OpenAI details.cached_tokens。
    var effectiveCacheHitTokens: Int {
        promptCacheHitTokens ?? promptTokensDetails?.cachedTokens ?? 0
    }
}

/// nonisolated：纯网络与解析，无 UI 状态。
nonisolated enum LLMClient {

    enum LLMError: LocalizedError {
        case missingAPIKey
        case missingBaseURL
        case http(Int, String)
        case emptyStream

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "未配置 API Key——请到设置（⌘,）填写"
            case .missingBaseURL: "模型端点（baseURL）未配置"
            case .http(let code, let body): "HTTP \(code)：\(body.prefix(300))"
            case .emptyStream: "模型未返回任何内容"
            }
        }
    }

    /// 流式对话：逐 token 吐出增量（正文 delta / 思考 reasoning）。
    /// - Parameters:
    ///   - stage: 阶段（取该阶段配置与 API Key）
    ///   - settings: BYOK 设置
    ///   - messages: 对话历史（含 system prompt）
    ///   - maxTokens: 单次回复上限
    static func streamChat(
        stage: LLMStage,
        settings: LLMSettings,
        messages: [ChatMessage],
        maxTokens: Int = 4096
    ) throws -> AsyncThrowingStream<LLMDelta, Error> {
        guard let config = settings.stages[stage] else {
            throw LLMError.missingBaseURL
        }
        guard let apiKey = KeychainStore.get(config.apiKeyKeychainKey), !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        let baseURL = config.resolvedBaseURL
        guard !baseURL.isEmpty else { throw LLMError.missingBaseURL }

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        // OpenAI 兼容请求体
        struct Body: Codable {
            /// content 双形态：纯文本消息用字符串（最大兼容）；
            /// 带图消息用 parts 数组（text + image_url parts，OpenAI 多模态格式）。
            enum MessageContent: Codable {
                case text(String)
                case parts([ContentPart])

                struct ContentPart: Codable {
                    var type: String
                    var text: String?
                    var image_url: ImageURL?

                    struct ImageURL: Codable {
                        var url: String
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var c = encoder.singleValueContainer()
                    switch self {
                    case .text(let s): try c.encode(s)
                    case .parts(let p): try c.encode(p)
                    }
                }
            }
            struct Message: Codable {
                var role: String
                var content: MessageContent
            }
            struct StreamOptions: Codable {
                var include_usage: Bool
            }
            var model: String
            var messages: [Message]
            var stream: Bool
            var max_tokens: Int
            // M5 Task 5.4：请求末 chunk 携带 usage（OpenAI 需显式开启；
            // deepseek/zhipu 本身就在末 chunk 带，多余字段无害）
            var stream_options: StreamOptions?

            /// ChatMessage → 请求消息：无图保持纯字符串（兼容全部端点）；
            /// 有图按 [text, image_url…] 顺序展开。
            static func message(from m: ChatMessage) -> Message {
                guard let images = m.images, !images.isEmpty else {
                    return Message(role: m.role.rawValue, content: .text(m.content))
                }
                var parts: [MessageContent.ContentPart] = [
                    .init(type: "text", text: m.content, image_url: nil)
                ]
                for image in images {
                    parts.append(.init(
                        type: "image_url", text: nil,
                        image_url: .init(url: image.dataURL)
                    ))
                }
                return Message(role: m.role.rawValue, content: .parts(parts))
            }
        }
        let body = Body(
            model: config.model,
            messages: messages.map { Body.message(from: $0) },
            stream: true,
            max_tokens: maxTokens,
            stream_options: .init(include_usage: true)
        )
        request.httpBody = try JSONEncoder().encode(body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var bodyText = ""
                        for try await line in bytes.lines { bodyText += line }
                        throw LLMError.http(http.statusCode, bodyText)
                    }

                    var received = false
                    var fullText = ""      // 累计正文+思考（usage 缺失时估算 completion 用）
                    var usage: StreamUsage?  // 末 chunk usage（M5 Task 5.4）
                    // SSE 解析：每行 "data: {json}"，"[DONE]" 结束
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }

                        struct Chunk: Codable {
                            struct Choice: Codable {
                                struct Delta: Codable {
                                    var content: String?
                                    var reasoningContent: String?

                                    enum CodingKeys: String, CodingKey {
                                        case content
                                        case reasoningContent = "reasoning_content"
                                    }
                                }
                                var delta: Delta?
                            }
                            var choices: [Choice]?
                            var usage: StreamUsage?
                        }
                        if let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) {
                            // 末 chunk usage 捕获（含 choices 为空的收尾 chunk）
                            if let chunkUsage = chunk.usage { usage = chunkUsage }
                            if let delta = chunk.choices?.first?.delta {
                                if let text = delta.content, !text.isEmpty {
                                    received = true
                                    fullText += text
                                    continuation.yield(.text(text))
                                }
                                if let reasoning = delta.reasoningContent, !reasoning.isEmpty {
                                    fullText += reasoning
                                    continuation.yield(.reasoning(reasoning))
                                }
                            }
                        }
                    }
                    guard received else { throw LLMError.emptyStream }
                    // 成功路径记一笔用量（失败/空流不记；M5 Task 5.4）
                    CostTracker.shared.record(
                        Self.makeUsageRecord(
                            stage: stage, model: config.model, messages: messages,
                            completionText: fullText, usage: usage
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 非流式便捷封装（分类路由 / JSON 抽取等小请求用）。
    static func complete(
        stage: LLMStage,
        settings: LLMSettings,
        messages: [ChatMessage],
        maxTokens: Int = 1024
    ) async throws -> String {
        var result = ""
        for try await delta in try streamChat(
            stage: stage, settings: settings, messages: messages, maxTokens: maxTokens
        ) {
            if case .text(let text) = delta { result += text }
        }
        return result
    }

    // MARK: - 用量捕获（M5 Task 5.4）

    /// 从 SSE data 载荷解析 usage（末 chunk 携带；无 usage 字段返回 nil）。
    /// 纯函数，测试直测。
    static func parseUsage(fromPayload data: Data) -> StreamUsage? {
        struct Wrapper: Codable { var usage: StreamUsage? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.usage
    }

    /// 用量记录构造：端点 usage 优先；缺失用 TokenBreakdown.estimate 估算
    /// （中文 1:1、英文词 ×1.3）并标记 estimated。
    static func makeUsageRecord(
        stage: LLMStage,
        model: String,
        messages: [ChatMessage],
        completionText: String,
        usage: StreamUsage?
    ) -> UsageRecord {
        let ts = ISO8601.timestamp()
        if let usage, let prompt = usage.promptTokens, let completion = usage.completionTokens {
            return UsageRecord(
                ts: ts, stage: stage.rawValue, model: model,
                promptTokens: prompt, completionTokens: completion,
                cacheHitTokens: min(usage.effectiveCacheHitTokens, prompt),
                estimated: false
            )
        }
        return UsageRecord(
            ts: ts, stage: stage.rawValue, model: model,
            promptTokens: TokenBreakdown.estimate(
                messages.map(\.content).joined(separator: "\n")
            ),
            completionTokens: TokenBreakdown.estimate(completionText),
            estimated: true
        )
    }
}
