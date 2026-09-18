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
    /// 思考原文回传（仅 assistant 消息有意义）：历史轮 reasoning_content 随消息
    /// 回发，模型免于每轮重新推敲上轮已想清的结论（2026-09-18，opencode /
    /// OpenHands 双印证的做法，DeepSeek 端点收益直接）。nil = 不携带。
    var reasoningContent: String?

    init(
        role: Role, content: String, images: [ChatImage]? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.reasoningContent = reasoningContent
    }

    // Codable 兼容旧存量（无 images / reasoningContent 字段的 JSON）
    private enum CodingKeys: String, CodingKey {
        case role, content, images, reasoningContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        images = try c.decodeIfPresent([ChatImage].self, forKey: .images)
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
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
    /// 流末 finish_reason == "length"：输出撞上 max_tokens 被截断（产物围栏可能未闭合）。
    case truncated
    /// 瞬时故障（429/5xx）自动重试中：响应头阶段已判失败、正文未流出。
    /// 消费方据此在 UI 显示重试状态（重试本身在 LLMClient 内部完成，无需干预）。
    case retrying(code: Int, attempt: Int)
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
        /// Keychain item 存在但读取被拒（构建重签后运行中进程常见）——
        /// 勿与 missingAPIKey 混同：重启 App 即恢复，重填 Key 无效。
        case keychainAccessDenied(OSStatus)
        case missingBaseURL
        case http(Int, String)
        case emptyStream
        /// 思考型模型把单轮输出预算全部烧在 reasoning 上、正文零输出（reasoning
        /// 分片有、content 分片无）。与字面空流（服务端抖动、零数据）区分：
        /// 同请求重发大概率重演（思考长度随任务稳定），重试必须换条件——
        /// 降思考强度 + 加倍输出预算；文案也要给出可执行出路而非笼统「未返回」。
        case emptyAfterThinking
        case streamTimeout

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "未配置 API Key——请到设置（⌘,）填写"
            case .keychainAccessDenied(let status):
                "API Key 在钥匙串中完好但访问被拒（构建重签后常见）——退出并重启 App 即恢复，无需重填（OSStatus \(status)）"
            case .missingBaseURL: "模型端点（baseURL）未配置"
            case .http(let code, let body):
                // 人话化三要素：发生了什么 / 现在怎样 / 用户能做什么。
                // 原始报文（provider JSON、Request ID）绝不直出 UI——429/5xx 在
                // 传输层已自动重试过，走到这里说明重试耗尽，用户需要的是出路而非报文。
                switch code {
                case 401, 403:
                    "API Key 无效或无权限——请到设置（⌘,）检查模型配置"
                case 402:
                    "账户余额不足——请到服务商控制台充值后重新发送这条消息"
                case 429:
                    "模型服务繁忙，已自动重试仍未成功——请稍等片刻后重新发送这条消息"
                case 500...599:
                    "模型服务暂时不可用，已自动重试仍未成功——请稍后重新发送这条消息"
                default:
                    // 非瞬时错误（400 等）多半是配置/模型名问题，透传服务端 message 帮助定位
                    "请求失败（HTTP \(code)）：\(LLMClient.serverMessage(fromBody: body))——请检查模型配置或稍后重试"
                }
            case .emptyStream: "模型未返回任何内容"
            case .emptyAfterThinking:
                "思考型模型把输出预算全部烧在思考上、未产生正文——已用「降低思考强度 + 加大输出上限」重试仍未成功，请重发这条消息或调低思考强度后再试"
            case .streamTimeout: "流式响应超时：服务端长时间未返回内容，已断开（请重试或换模型）"
            }
        }
    }

    /// 流式专用会话：resource 超时是**总时长硬上限**——request 级 timeoutInterval
    /// 只是空闲计时，服务端持续发 keep-alive 心跳行却不给正文时会不断重置，
    /// 流会永久挂起、isStreaming 卡死（实测 40 分钟不结束，后续所有发送被
    /// 「生成中」守卫静默吞掉 = 用户视角「发不出去」）。resource 上限无论心跳
    /// 与否到点必断，错误照常走 ⚠️ 收尾路径。internal 供测试断言配置。
    nonisolated static let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120   // 空闲超时：半开连接 120s 必断
        config.timeoutIntervalForResource = 600  // 总时长硬上限：单次流 ≤10 分钟
        return URLSession(configuration: config)
    }()

    /// OpenAI 兼容请求体（提升到 enum 作用域：测试直测编码行为）。
    nonisolated struct RequestBody: Codable {
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
            /// 思考原文回传（DeepSeek reasoning_content）：nil 时字段整体缺席
            ///（synthesized Codable 对 Optional 走 encodeIfPresent），端点零风险。
            var reasoning_content: String? = nil
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
        /// 思考强度（DeepSeek 思考模式）：nil = 不发送（synthesized Codable
        /// 对 Optional 走 encodeIfPresent，字段整体缺席，走服务端默认档）。
        var reasoning_effort: String? = nil

        /// ChatMessage → 请求消息：无图保持纯字符串（兼容全部端点）；
        /// 有图按 [text, image_url…] 顺序展开。
        static func message(from m: ChatMessage) -> Message {
            guard let images = m.images, !images.isEmpty else {
                return Message(
                    role: m.role.rawValue, content: .text(m.content),
                    reasoning_content: m.reasoningContent
                )
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
            return Message(
                role: m.role.rawValue, content: .parts(parts),
                reasoning_content: m.reasoningContent
            )
        }
    }

    // MARK: - 瞬时故障自动重试（429 限流/过载、5xx 服务端错误）

    /// 自动重试次数上限（与 openStreamWithRetry 的退避表 1s→2s 一一对应）。
    static let maxStreamRetries = 2

    /// 产物生成回合（结构/原型/PRD）的单轮输出预算：65536 实测为方舟 glm 与主流
    /// OpenAI 兼容端点接受的封顶值（与 escalatedRetryBudget 同源）。此前 32768 下
    /// PRD 全档实测输出 25-33k 撞线截断，续写轮要把整段半成品回灌重算（多付一轮
    /// 大额 prefill + 再等一轮生成）。max_tokens 是上限不是目标——输出自然收束时
    /// 按实际量计费，抬高无成本；截断续写机制保留作极端长文兜底。
    nonisolated static let artifactMaxTokens = 65536

    /// 是否瞬时故障：服务端过载/限流（429）与 5xx，通常几秒内自愈——
    /// 值得客户端退避重试吸收掉，而非把原始错误甩给用户。
    static func isTransientStatus(_ code: Int) -> Bool {
        code == 429 || (500...599).contains(code)
    }

    /// 空流重试（思考烧满预算形态）的输出预算：保底 32768、加倍、封顶 65536。
    /// 思考与正文共用输出池，思考占满即正文为零——预算是重试期唯一无损杠杆
    ///（保底覆盖 8192 抽取路径；封顶实测方舟 glm 与主流 OpenAI 兼容端点均接受）。
    /// 纯函数，测试直测。
    static func escalatedRetryBudget(_ maxTokens: Int) -> Int {
        min(max(maxTokens * 2, 32768), artifactMaxTokens)
    }

    /// 重试等待期间的气泡状态文案（人话 + 进度）。纯函数，测试直测。
    static func retryStatusText(code: Int, attempt: Int) -> String {
        let reason = code == 429 ? "模型服务繁忙" : "模型服务暂时不可用"
        return "\(reason)，自动重试中（\(attempt)/\(maxStreamRetries)）…"
    }

    /// 从错误报文提取服务端人话（OpenAI 兼容 {"error":{"message":…}} 结构）；
    /// 解不出回退原报文前 160 字符。纯函数，测试直测。
    static func serverMessage(fromBody body: String) -> String {
        struct Envelope: Codable {
            struct Err: Codable { var message: String? }
            var error: Err?
        }
        if let data = body.data(using: .utf8),
           let e = try? JSONDecoder().decode(Envelope.self, from: data),
           let m = e.error?.message, !m.isEmpty {
            return m
        }
        return String(body.prefix(160))
    }

    /// 打开流式连接：429/5xx 自动重试，指数退避 1s→2s（服务端 Retry-After 秒数优先，
    /// 封顶 8s），最多重试 maxStreamRetries 次。仅在响应头阶段失败时重试——此刻正文
    /// 尚未流出、状态未推进，同请求重发安全；一旦正文开始，重试会造成重复渲染，
    /// 交由上层空流/截断路径兜底。退避等待可被取消：用户「停止」即刻退出，不发僵尸请求。
    /// 每次发起重试前回调 onRetry(状态码, 第几次重试)，供消费方在 UI 显示重试状态。
    private static func openStreamWithRetry(
        _ request: URLRequest,
        onRetry: (Int, Int) -> Void
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let backoffs: [UInt64] = [1_000_000_000, 2_000_000_000]
        var attempt = 0
        while true {
            let (bytes, response) = try await streamingSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  !(200..<300).contains(http.statusCode) else {
                return (bytes, response)
            }
            var bodyText = ""
            for try await line in bytes.lines { bodyText += line }
            guard isTransientStatus(http.statusCode), attempt < backoffs.count else {
                throw LLMError.http(http.statusCode, bodyText)
            }
            attempt += 1
            onRetry(http.statusCode, attempt)
            let wait = min(
                http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    ?? Double(backoffs[attempt - 1]) / 1_000_000_000,
                8
            )
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// 流式对话：逐 token 吐出增量（正文 delta / 思考 reasoning）。
    /// - Parameters:
    ///   - stage: 阶段（取该阶段配置与 API Key）
    ///   - settings: BYOK 设置
    ///   - messages: 对话历史（含 system prompt）
    ///   - maxTokens: 单次回复上限
    ///   - reasoningEffort: 思考强度（nil = 不发送，走服务端默认）
    ///   - roundId: 轮次关联 id（usage/probe 归因对齐用；nil = 辅助调用无轮次）
    static func streamChat(
        stage: LLMStage,
        settings: LLMSettings,
        messages: [ChatMessage],
        maxTokens: Int = 4096,
        reasoningEffort: String? = nil,
        roundId: String? = nil
    ) throws -> AsyncThrowingStream<LLMDelta, Error> {
        guard let config = settings.stages[stage] else {
            throw LLMError.missingBaseURL
        }
        // Key 读取必须区分「未配置」与「访问被拒」：构建重签后运行中进程会被
        // 拒读（item 完好），折叠成 missingAPIKey 会误导用户白填一遍 Key
        //（2026-09-16 事故；设置页同教训见 KeychainStore.read 注释）。
        let apiKey: String
        switch KeychainStore.read(config.apiKeyKeychainKey) {
        case .found(let key) where !key.isEmpty:
            apiKey = key
        case .accessFailed(let status):
            throw LLMError.keychainAccessDenied(status)
        default:
            throw LLMError.missingAPIKey
        }
        let baseURL = config.resolvedBaseURL
        guard !baseURL.isEmpty else { throw LLMError.missingBaseURL }

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body = RequestBody(
            model: config.model,
            messages: messages.map { RequestBody.message(from: $0) },
            stream: true,
            max_tokens: maxTokens,
            stream_options: .init(include_usage: true),
            reasoning_effort: reasoningEffort
        )
        request.httpBody = try JSONEncoder().encode(body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                // 临时探针（2026-09-18）：网络侧到达节奏（见 StreamProbe 注释）
                let probeT0 = Date()
                let probeID = UUID().uuidString.prefix(8)
                var probeStamps: [Double] = []
                var probeRetries: [[String: Any]] = []
                var probeOpenS: Double = 0
                do {
                    let (bytes, response) = try await openStreamWithRetry(request) { code, attempt in
                        probeRetries.append([
                            "t": Date().timeIntervalSince(probeT0), "code": code, "attempt": attempt,
                        ])
                        continuation.yield(.retrying(code: code, attempt: attempt))
                    }
                    probeOpenS = Date().timeIntervalSince(probeT0)

                    var received = false
                    var receivedReasoning = false  // 思考分片到达（正文为零时区分失败成因）
                    var truncated = false   // finish_reason == "length"（撞 max_tokens 截断）
                    var fullText = ""      // 累计正文+思考（usage 缺失时估算 completion 用）
                    var usage: StreamUsage?  // 末 chunk usage（M5 Task 5.4）
                    // SSE 解析：每行 "data: {json}"，"[DONE]" 结束
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        probeStamps.append(Date().timeIntervalSince(probeT0))
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
                                var finishReason: String?

                                enum CodingKeys: String, CodingKey {
                                    case delta
                                    case finishReason = "finish_reason"
                                }
                            }
                            var choices: [Choice]?
                            var usage: StreamUsage?
                        }
                        if let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) {
                            // 末 chunk usage 捕获（含 choices 为空的收尾 chunk）
                            if let chunkUsage = chunk.usage { usage = chunkUsage }
                            // finish_reason == "length" → 输出撞 max_tokens 被截断
                            if chunk.choices?.first?.finishReason == "length" {
                                truncated = true
                            }
                            if let delta = chunk.choices?.first?.delta {
                                if let text = delta.content, !text.isEmpty {
                                    received = true
                                    fullText += text
                                    continuation.yield(.text(text))
                                }
                                if let reasoning = delta.reasoningContent, !reasoning.isEmpty {
                                    receivedReasoning = true
                                    fullText += reasoning
                                    continuation.yield(.reasoning(reasoning))
                                }
                            }
                        }
                    }
                    guard received else {
                        // 正文为零时按成因分流：思考分片有 → 思考烧满预算；零分片 → 字面空流
                        throw receivedReasoning ? LLMError.emptyAfterThinking : LLMError.emptyStream
                    }
                    // 截断信号在用量记录前透出（消费方据此决定是否续写）
                    if truncated { continuation.yield(.truncated) }
                    // 成功路径记一笔用量（失败/空流不记；M5 Task 5.4）；
                    // 2026-09-18 归因增强：roundId + 净耗时/首 token 延迟随记录落盘
                    CostTracker.shared.record(
                        Self.makeUsageRecord(
                            stage: stage, model: config.model, messages: messages,
                            completionText: fullText, usage: usage,
                            roundId: roundId,
                            totalS: probeStamps.last ?? 0,
                            ttftS: probeStamps.first ?? 0
                        )
                    )
                    // 临时探针：网络侧时间线落盘（相对请求起点的秒序列）
                    StreamProbe.shared.append([
                        "side": "net", "id": String(probeID),
                        "roundId": roundId ?? "",
                        "ts": probeT0.timeIntervalSince1970,
                        "stage": stage.rawValue, "model": config.model,
                        "effort": reasoningEffort ?? "", "maxTokens": maxTokens,
                        "promptChars": messages.reduce(0) { $0 + $1.content.count },
                        "openS": probeOpenS, "ttftS": probeStamps.first ?? 0,
                        "totalS": probeStamps.last ?? 0, "lines": probeStamps.count,
                        "truncated": truncated, "retries": probeRetries,
                        "stamps": probeStamps,
                    ])
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    // 临时探针：失败路径也留痕（超时是最可疑的隐形时间黑洞）
                    StreamProbe.shared.append([
                        "side": "net", "id": String(probeID),
                        "roundId": roundId ?? "",
                        "ts": probeT0.timeIntervalSince1970,
                        "stage": stage.rawValue, "model": config.model,
                        "error": "timeout", "openS": probeOpenS,
                        "lines": probeStamps.count, "stamps": probeStamps,
                        "retries": probeRetries,
                    ])
                    // 空闲/总时长超时统一映射为明确的中文文案（⚠️ 收尾行可读）
                    continuation.finish(throwing: LLMError.streamTimeout)
                } catch {
                    StreamProbe.shared.append([
                        "side": "net", "id": String(probeID),
                        "roundId": roundId ?? "",
                        "ts": probeT0.timeIntervalSince1970,
                        "stage": stage.rawValue, "model": config.model,
                        "error": String(describing: error), "openS": probeOpenS,
                        "lines": probeStamps.count, "stamps": probeStamps,
                        "retries": probeRetries,
                    ])
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 思考强度路由（模型路由原则）：对话/产物生成轮走 streamChat 由用户档位决定；
    /// classify 阶段是产品内部辅助调用（要点表/记忆/方法论抽取、历史压缩摘要、
    /// release-notes 等填表类任务），schema 与格式约束已兜底质量——默认压到 low，
    /// 不再陪跑服务端默认 high 深度思考（思考 token 与正文同池计费，辅助调用每次
    /// 白烧数十秒到分钟级，2026-09-18 定性）。显式 override 永远优先。
    static func resolvedEffort(stage: LLMStage, override: String? = nil) -> String? {
        override ?? (stage == .classify ? ThinkingEffort.low.apiValue : nil)
    }

    /// 非流式便捷封装（分类路由 / JSON 抽取等小请求用）。思考强度按
    /// resolvedEffort(stage:) 路由（classify 默认 low）。
    /// 撞 max_tokens 截断时自动续写（MCP 无头生成原型 HTML 同样会截断），上限 2 次。
    /// 空流自动重试上限 1 次：字面空流（服务端抖动）同请求重发；思考烧满预算
    /// （reasoning 有、正文零，emptyAfterThinking）同请求重发大概率重演——
    /// 改为加倍输出预算 + 强制 low 思考直击成因（澄清要点表等长 transcript
    /// 抽取路径的咽喉救援，2026-09-16 「确认后 6 分钟空流」实证）。
    static func complete(
        stage: LLMStage,
        settings: LLMSettings,
        messages: [ChatMessage],
        maxTokens: Int = 1024
    ) async throws -> String {
        var result = ""
        var messages = messages
        var rounds = 0
        var emptyRetries = 0
        var budget = maxTokens
        var effortOverride = resolvedEffort(stage: stage)
        while true {
            var truncated = false
            let roundStart = result.count
            do {
                for try await delta in try streamChat(
                    stage: stage, settings: settings, messages: messages,
                    maxTokens: budget, reasoningEffort: effortOverride
                ) {
                    switch delta {
                    case .text(let text): result += text
                    case .truncated: truncated = true
                    case .reasoning: break
                    case .retrying: break  // 无头路径无实时气泡，重试静默进行
                    }
                }
            } catch LLMError.emptyAfterThinking
                where result.count == roundStart && emptyRetries < 1 {
                // 思考烧满预算：换条件重试（同请求重发大概率重演）
                emptyRetries += 1
                budget = escalatedRetryBudget(budget)
                effortOverride = ThinkingEffort.low.apiValue
                continue
            } catch LLMError.emptyStream
                where result.count == roundStart && emptyRetries < 1 {
                // 字面空流（服务端抖动）：同请求重发
                emptyRetries += 1
                continue
            }
            guard truncated, rounds < 2 else { break }
            rounds += 1
            let roundText = String(result[result.index(result.startIndex, offsetBy: roundStart)...])
            guard !roundText.isEmpty else { break }
            messages.append(ChatMessage(role: .assistant, content: roundText))
            messages.append(ChatMessage(
                role: .user,
                content: "你上一条回复在输出中途被截断了。请从断点处直接继续输出剩余内容，"
                    + "不要重复已输出的部分，不要加任何前缀说明或道歉，接着上一个字符继续直到产物完整闭合。"
            ))
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
        usage: StreamUsage?,
        roundId: String? = nil,
        totalS: Double? = nil,
        ttftS: Double? = nil
    ) -> UsageRecord {
        let ts = ISO8601.timestamp()
        if let usage, let prompt = usage.promptTokens, let completion = usage.completionTokens {
            return UsageRecord(
                ts: ts, stage: stage.rawValue, model: model,
                promptTokens: prompt, completionTokens: completion,
                cacheHitTokens: min(usage.effectiveCacheHitTokens, prompt),
                estimated: false, roundId: roundId, totalS: totalS, ttftS: ttftS
            )
        }
        return UsageRecord(
            ts: ts, stage: stage.rawValue, model: model,
            promptTokens: TokenBreakdown.estimate(
                messages.map(\.content).joined(separator: "\n")
            ),
            completionTokens: TokenBreakdown.estimate(completionText),
            estimated: true, roundId: roundId, totalS: totalS, ttftS: ttftS
        )
    }
}
