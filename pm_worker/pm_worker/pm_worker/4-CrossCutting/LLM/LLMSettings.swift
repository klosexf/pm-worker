//
//  LLMSettings.swift
//  pm_worker
//
//  BYOK 模型配置（design.md §7.3）：每阶段模型 + token 上限。
//  配置存 Application Support（JSON），API Key 走 Keychain（KeychainStore）。
//

import Foundation

/// 流水线各阶段（design.md §7.3）。
nonisolated enum LLMStage: String, Codable, CaseIterable, Identifiable {
    case classify, clarify, structure, research, analysis, prd, prototype, review, embedding

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classify: "意图分类 / 路由"
        case .clarify: "① 澄清"
        case .structure: "② 结构"
        case .research: "调研分支"
        case .analysis: "竞品分析分支"
        case .prd: "④ PRD"
        case .prototype: "③ 原型"
        case .review: "毒舌评审分支"
        case .embedding: "向量编码"
        }
    }

    /// 对话类阶段：统一 AI 配置入口共用一份模型（embedding 是向量化端点，独立配置）。
    static let chatStages: [LLMStage] = [
        .classify, .clarify, .structure, .research, .analysis, .prd, .prototype, .review,
    ]
}

/// 单阶段模型配置：全部走 OpenAI 兼容端点（baseURL + apiKey + model）。
nonisolated struct StageModelConfig: Codable, Equatable {
    var provider: String
    var model: String
    /// nil 时用 provider 预设端点。
    var baseURL: String?
    /// 该模型是否支持图片输入（视觉）：开启后对话可发图，请求按
    /// OpenAI 兼容 content 数组携带 image_url。仅对话阶段有意义。
    var supportsImages: Bool

    init(
        provider: String,
        model: String,
        baseURL: String? = nil,
        supportsImages: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.supportsImages = supportsImages
    }

    /// provider 预设的 OpenAI 兼容端点。
    var resolvedBaseURL: String {
        if let baseURL, !baseURL.isEmpty { return baseURL }
        return Self.presetBaseURL(for: provider)
    }

    static func presetBaseURL(for provider: String) -> String {
        switch provider {
        case "deepseek": "https://api.deepseek.com"
        case "zhipu": "https://open.bigmodel.cn/api/paas/v4"
        case "openai": "https://api.openai.com/v1"
        case "anthropic-compat": ""  // 网关地址用户必填
        case "ollama": "http://localhost:11434/v1"
        default: ""
        }
    }

    /// provider 预设的缺省模型（统一入口切换 provider 时自动带出，免手填错名）。
    static func defaultModel(for provider: String) -> String {
        switch provider {
        case "deepseek": "deepseek-flash"
        case "zhipu": "glm-4.6"
        case "openai": "gpt-4o"
        case "anthropic-compat": "claude-sonnet-4"
        case "ollama": "qwen2.5"
        default: ""
        }
    }

    /// provider 预设的视觉能力默认值（切换供应商时带出，用户可在设置里覆盖）：
    /// gpt-4o / claude 系默认多模态；deepseek-flash / glm-4.6 / qwen2.5 默认纯文本。
    static func defaultSupportsImages(for provider: String) -> Bool {
        switch provider {
        case "openai", "anthropic-compat": true
        default: false
        }
    }

    /// API Key 的 Keychain 键（按 provider 一把钥匙）。
    var apiKeyKeychainKey: String { "byok.\(provider)" }

    // MARK: - Codable 兼容旧存量（缺 supportsImages 的 settings.json 视为 false）

    private enum CodingKeys: String, CodingKey {
        case provider, model, baseURL, supportsImages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? false
    }
}

/// 全量 BYOK 设置。
nonisolated struct LLMSettings: Codable, Equatable {
    /// 各阶段配置（design.md §7.3 缺省值）。
    var stages: [LLMStage: StageModelConfig]
    /// 单次全流程 token 上限。
    var maxTokensPerRun: Int
    /// 竞品分析搜索源（Task 3.8，SearXNG 兼容 JSON 端点；空 = 不联网）。
    var searchEndpoint: String

    init(
        stages: [LLMStage: StageModelConfig],
        maxTokensPerRun: Int,
        searchEndpoint: String = ""
    ) {
        self.stages = stages
        self.maxTokensPerRun = maxTokensPerRun
        self.searchEndpoint = searchEndpoint
    }

    /// 统一 AI 配置入口（2026-09-12 简化）：读 classify、写入全部对话阶段。
    /// 意图分类 → 毒舌评审八个阶段共用一份 provider / model / baseURL / Key；
    /// embedding 是向量化端点，不在此入口范围内。
    var chatConfig: StageModelConfig {
        get {
            stages[.classify] ?? StageModelConfig(
                provider: "deepseek", model: "deepseek-flash", baseURL: nil
            )
        }
        set {
            for stage in LLMStage.chatStages {
                stages[stage] = newValue
            }
        }
    }

    static let `default` = LLMSettings(
        stages: [
            .classify: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .clarify: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .structure: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .research: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .analysis: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .prd: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .prototype: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .review: StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil),
            .embedding: StageModelConfig(provider: "zhipu", model: "embedding-3", baseURL: nil),
        ],
        maxTokensPerRun: 500_000
    )

    /// 旧存量收敛（纯函数，可直测）：分阶段时代的 settings.json 里各对话阶段
    /// provider/model 不一致——统一入口以 classify 为准归一，embedding 不动。
    nonisolated static func normalizedToUnifiedChat(_ settings: LLMSettings) -> LLMSettings {
        var unified = settings
        let chat = unified.chatConfig
        for stage in LLMStage.chatStages {
            unified.stages[stage] = chat
        }
        return unified
    }

    // MARK: - Codable 兼容旧存量（Task 3.8 前的 settings.json 没有 searchEndpoint）

    private enum CodingKeys: String, CodingKey {
        case stages, maxTokensPerRun, searchEndpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stages = try container.decodeIfPresent([LLMStage: StageModelConfig].self, forKey: .stages) ?? [:]
        maxTokensPerRun = try container.decodeIfPresent(Int.self, forKey: .maxTokensPerRun) ?? 500_000
        searchEndpoint = try container.decodeIfPresent(String.self, forKey: .searchEndpoint) ?? ""
    }

    // MARK: - 持久化（Application Support，写后回读校验）

    nonisolated static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pm-worker", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    nonisolated static func load() -> LLMSettings {
        guard let data = try? Data(contentsOf: storageURL),
              var settings = try? JSONDecoder().decode(LLMSettings.self, from: data)
        else { return .default }
        // 旧存量补齐新增阶段（如 .analysis）的缺省模型配置
        for stage in LLMStage.allCases where settings.stages[stage] == nil {
            settings.stages[stage] = LLMSettings.default.stages[stage]
        }
        // 分阶段存量收敛为统一入口（对话阶段全部以 classify 为准）
        settings = normalizedToUnifiedChat(settings)
        return settings
    }

    /// 写入后回读校验，不一致抛错（write-then-verify 纪律，design.md E5）。
    nonisolated func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let dir = Self.storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: Self.storageURL, options: .atomic)

        let written = try Data(contentsOf: Self.storageURL)
        guard written == data else {
            throw NSError(
                domain: "LLMSettings", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "设置写入后回读校验失败：\(Self.storageURL.path)"]
            )
        }
    }

    /// 某阶段的 API Key（Keychain 按 provider 一把）。
    nonisolated func apiKey(for stage: LLMStage) -> String? {
        guard let config = stages[stage] else { return nil }
        return KeychainStore.get(config.apiKeyKeychainKey)
    }
}
