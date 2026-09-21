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

/// 思考强度档位（OpenAI 兼容端点的 reasoning_effort，DeepSeek 思考模式文档）：
/// low/high/max 为真实档位，medium 是文档确认的兼容别名（服务端映射到 high）。
/// high 为服务端默认档——不发送参数（对不认该参数的端点零风险）。
nonisolated enum ThinkingEffort: String, Codable, CaseIterable, Identifiable {
    case low, medium, high, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    /// 请求体 reasoning_effort 取值；nil = 不发送（high 走服务端默认）。
    var apiValue: String? { self == .high ? nil : rawValue }
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
    /// API Key 的 Keychain 槽位覆盖（nil = 按 provider 一把钥匙）。
    /// 多模型管理引入：同一 provider 的多个模型可各持一把 Key
    ///（如两个智谱账号），旧存量 settings.json 无此字段视为 nil，行为不变。
    var keychainKey: String?

    init(
        provider: String,
        model: String,
        baseURL: String? = nil,
        supportsImages: Bool = false,
        keychainKey: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.supportsImages = supportsImages
        self.keychainKey = keychainKey
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
        case "volcengine": "https://ark.cn-beijing.volces.com/api/v3"
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
        case "volcengine": "doubao-seed-1-6"
        case "openai": "gpt-4o"
        case "anthropic-compat": "claude-sonnet-4"
        case "ollama": "qwen2.5"
        default: ""
        }
    }

    /// provider 预设的视觉能力默认值（切换供应商时带出，用户可在设置里覆盖）：
    /// gpt-4o / claude 系 / 豆包 seed 系默认多模态；deepseek / glm / qwen2.5 默认纯文本。
    static func defaultSupportsImages(for provider: String) -> Bool {
        switch provider {
        case "openai", "anthropic-compat", "volcengine": true
        default: false
        }
    }

    /// API Key 的 Keychain 键（多模型可按 profile 独立持钥，缺省仍按 provider 一把）。
    var apiKeyKeychainKey: String { keychainKey ?? "byok.\(provider)" }

    // MARK: - Codable 兼容旧存量（缺 supportsImages / keychainKey 的 settings.json 视为 false / nil）

    private enum CodingKeys: String, CodingKey {
        case provider, model, baseURL, supportsImages, keychainKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? false
        keychainKey = try c.decodeIfPresent(String.self, forKey: .keychainKey)
    }
}

/// 多模型档案（2026-09-14 多模型管理）：设置页可添加任意多个模型，
/// 对话输入栏可实时切换「使用中」的那一个。enabled 只控制是否出现在
/// 切换器列表；运行时配置永远来自 activeProfile（写透 stages，下游零改动）。
nonisolated struct ModelProfile: Codable, Equatable, Identifiable {
    /// 稳定 id（UUID）：Keychain 独立槽位、列表 diff 都以它为准。
    var id: String
    var provider: String
    var model: String
    /// nil 时用 provider 预设端点。
    var baseURL: String?
    /// 是否支持图片输入（视觉）。
    var supportsImages: Bool
    /// 启用开关：false = 不出现在对话输入栏的模型切换器（运行时不受影响）。
    var enabled: Bool
    /// API Key 的 Keychain 槽位。旧存量迁移来的首档案沿用 `byok.<provider>`
    ///（Key 不丢）；用户新增的档案一律 `byok.model.<id>`（同供应商多 Key 隔离）。
    var keychainKey: String
    /// 模型上下文窗口（tokens，P1-6 预算自适应）：填了才按比例伸缩五段注入预算；
    /// nil = 用缺省预算（不感知窗口）。常见值：16000 / 32000 / 64000 / 128000。
    var contextWindow: Int?

    init(
        id: String = UUID().uuidString,
        provider: String,
        model: String,
        baseURL: String? = nil,
        supportsImages: Bool = false,
        enabled: Bool = true,
        keychainKey: String? = nil,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.supportsImages = supportsImages
        self.enabled = enabled
        self.keychainKey = keychainKey ?? "byok.model.\(id)"
        self.contextWindow = contextWindow
    }

    /// 新增档案缺省值（跟随最近一次使用的 provider 带出预设模型，免手填错名）。
    static func newProfile(defaultProvider: String) -> ModelProfile {
        ModelProfile(
            provider: defaultProvider,
            model: StageModelConfig.defaultModel(for: defaultProvider),
            baseURL: nil,
            supportsImages: StageModelConfig.defaultSupportsImages(for: defaultProvider)
        )
    }

    /// 运行时投影：进入 stages 的对话阶段配置（携带独立 Key 槽位）。
    var stageModelConfig: StageModelConfig {
        StageModelConfig(
            provider: provider, model: model, baseURL: baseURL,
            supportsImages: supportsImages, keychainKey: keychainKey
        )
    }

    /// 新增/用户自管槽位前缀（删除档案时只清理这类槽，legacy 槽可能被 embedding 共用）。
    var ownsKeychainSlot: Bool { keychainKey.hasPrefix("byok.model.") }
}

/// 全量 BYOK 设置。
nonisolated struct LLMSettings: Codable, Equatable {
    /// 各阶段配置（design.md §7.3 缺省值）。
    var stages: [LLMStage: StageModelConfig]
    /// 多模型档案（多模型管理入口；旧 settings.json 无此字段 → load 时从 chat 配置播种）。
    var models: [ModelProfile]
    /// 「使用中」档案 id（对话输入栏切换器的选中态）。
    var activeModelID: String?
    /// 单次全流程 token 上限。
    var maxTokensPerRun: Int
    /// 竞品分析搜索源（Task 3.8，SearXNG 兼容 JSON 端点；空 = 不联网）。
    var searchEndpoint: String
    /// Agent 工具调用总开关（Function Calling v1）：false = 请求不带 tools，
    /// 行为与旧版完全一致（一键回滚点，PRD §11 V2 路线首项的降级闸）。默认开。
    var agentToolsEnabled: Bool
    /// 计划提案开关（P0-2 模型计划提案权）：②③④ 首次产物生成前先出一轮
    /// 「执行计划草案」由用户裁决（按批准执行 / 补充后执行 / 跳过直接生成）。
    /// false = 确认链直接生成（旧行为）。默认开。
    var planProposalsEnabled: Bool

    init(
        stages: [LLMStage: StageModelConfig],
        models: [ModelProfile] = [],
        activeModelID: String? = nil,
        maxTokensPerRun: Int,
        searchEndpoint: String = "",
        agentToolsEnabled: Bool = true,
        planProposalsEnabled: Bool = true
    ) {
        self.stages = stages
        self.models = models
        self.activeModelID = activeModelID
        self.maxTokensPerRun = maxTokensPerRun
        self.searchEndpoint = searchEndpoint
        self.agentToolsEnabled = agentToolsEnabled
        self.planProposalsEnabled = planProposalsEnabled
        // 使用中缺省指向首个档案（显式传入优先；不在此处播种——播种只发生在
        // default / load()，构造器保持无副作用，测试手工构造行为可预期）
        if self.activeModelID == nil {
            self.activeModelID = self.models.first?.id
        }
    }

    /// 统一 AI 配置入口（2026-09-12 简化）：读 classify、写入全部对话阶段。
    /// 意图分类 → 毒舌评审八个阶段共用一份 provider / model / baseURL / Key；
    /// embedding 是向量化端点，不在此入口范围内。
    /// 多模型时代：stages 由 activeProfile 写透同步（syncActiveStages），此处只读投影。
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

    // MARK: - 多模型管理（2026-09-14）

    /// 当前使用中的档案（对话输入栏切换器选中态、运行时配置来源）。
    /// 兜底链：activeModelID 命中 → 首个启用档案 → 首个档案 → chatConfig 缺省。
    var activeProfile: ModelProfile? {
        if let id = activeModelID, let profile = models.first(where: { $0.id == id }) {
            return profile
        }
        return models.first(where: \.enabled) ?? models.first
    }

    /// 模型切换器数据源：启用档案；全禁用时保底返回当前使用中档案（切换器不空转）。
    var switcherProfiles: [ModelProfile] {
        let enabled = models.filter(\.enabled)
        if !enabled.isEmpty { return enabled }
        return activeProfile.map { [$0] } ?? []
    }

    /// 新增或更新档案；档案即当前使用中（或尚无 active）时写透 stages。
    mutating func upsertModel(_ profile: ModelProfile) {
        if let idx = models.firstIndex(where: { $0.id == profile.id }) {
            models[idx] = profile
        } else {
            models.append(profile)
        }
        if activeModelID == nil { activeModelID = profile.id }
        if activeModelID == profile.id { syncActiveStages() }
    }

    /// 删除档案；删的是使用中档案 → 自动落到下一个启用档案（没有则首个）。
    mutating func removeModel(id: String) {
        models.removeAll { $0.id == id }
        if activeModelID == id {
            activeModelID = (models.first(where: \.enabled) ?? models.first)?.id
            syncActiveStages()
        }
    }

    /// 切换使用中档案（对话输入栏即时生效：写透 stages，运行时下一次请求即用新模型）。
    mutating func setActiveModel(id: String) {
        guard models.contains(where: { $0.id == id }) else { return }
        activeModelID = id
        syncActiveStages()
    }

    /// 启用开关：停用使用中档案时自动迁移到下一个启用档案（无备选则保留原档案，
    /// 保证对话链路永不断粮）；重新启用不自动抢占使用中。
    mutating func setModelEnabled(id: String, enabled: Bool) {
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return }
        models[idx].enabled = enabled
        guard !enabled, activeModelID == id else { return }
        if let fallback = models.first(where: { $0.enabled && $0.id != id }) {
            activeModelID = fallback.id
        }
        syncActiveStages()
    }

    /// 使用中档案 → 全部对话阶段写透（多模型与运行时的唯一接缝，
    /// LLMClient/SessionStore/AnalysisRunner 等下游照旧读 stages，零改动）。
    mutating func syncActiveStages() {
        guard let active = activeProfile else { return }
        let config = active.stageModelConfig
        for stage in LLMStage.chatStages {
            stages[stage] = config
        }
    }

    /// 旧存量播种（纯函数语义，init 与 load 共用）：models 为空时从 classify
    /// 配置生成首个档案——Keychain 槽沿用 `byok.<provider>`（已存 Key 不丢）。
    mutating func seedModelsFromChat() {
        let source = stages[.classify]
            ?? StageModelConfig(provider: "deepseek", model: "deepseek-flash", baseURL: nil)
        let legacySlot = source.keychainKey ?? "byok.\(source.provider)"
        let profile = ModelProfile(
            provider: source.provider, model: source.model, baseURL: source.baseURL,
            supportsImages: source.supportsImages, enabled: true, keychainKey: legacySlot
        )
        models = [profile]
        if activeModelID == nil { activeModelID = profile.id }
    }

    static let `default`: LLMSettings = {
        var settings = LLMSettings(
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
        // 出厂首启播种首个模型档案（Key 槽沿用 byok.<provider>）
        settings.seedModelsFromChat()
        settings.syncActiveStages()
        return settings
    }()

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

    // MARK: - Codable 兼容旧存量（多模型字段引入前的 settings.json 无 models / activeModelID）

    private enum CodingKeys: String, CodingKey {
        case stages, models, activeModelID, maxTokensPerRun, searchEndpoint
        case agentToolsEnabled, planProposalsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stages = try container.decodeIfPresent([LLMStage: StageModelConfig].self, forKey: .stages) ?? [:]
        models = try container.decodeIfPresent([ModelProfile].self, forKey: .models) ?? []
        activeModelID = try container.decodeIfPresent(String.self, forKey: .activeModelID)
        maxTokensPerRun = try container.decodeIfPresent(Int.self, forKey: .maxTokensPerRun) ?? 500_000
        searchEndpoint = try container.decodeIfPresent(String.self, forKey: .searchEndpoint) ?? ""
        agentToolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentToolsEnabled) ?? true
        planProposalsEnabled = try container.decodeIfPresent(Bool.self, forKey: .planProposalsEnabled) ?? true
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
        // 多模型播种：旧 settings.json 无 models → 从 classify 生成首档案（Key 槽沿用）
        if settings.models.isEmpty {
            settings.seedModelsFromChat()
        }
        // 使用中档案写透（重启后多模型状态恢复，stages 与档案必然一致）
        settings.syncActiveStages()
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

}
