//
//  SettingsDialog.swift
//  pm_worker
//
//  设置弹框（Trae 风格模态，对齐用户参考图）：
//  侧栏左下角齿轮 / ⌘, / MCP 导航深链三入口 → 全窗口遮罩 + 居中弹框。
//  左导航列（账户区 + 模型/用量/数据/MCP/关于）+ 右内容区（页标题 + 关闭钮）。
//  取代原系统 Settings 窗（SettingsView 已删）：配置项与 MCP 设置全部收进本弹框。
//

import SwiftUI

// MARK: - 页定义

/// 弹框左导航七页（通用置首，对应系统设置惯例）。
enum SettingsDialogPage: String, CaseIterable, Identifiable {
    case general
    case model
    case usage
    case data
    case memory
    case mcp
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .model: "模型"
        case .usage: "用量"
        case .data: "数据"
        case .memory: "记忆"
        case .mcp: "MCP 服务"
        case .about: "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "外观模式 · 界面偏好"
        case .model: "BYOK · 多模型管理 · Key 存 Keychain"
        case .usage: "本次 / 本月 token 与费用估算"
        case .data: "文件系统是唯一事实源 · 索引可随时重建"
        case .memory: "有效条目管理 · 手动新增 · 整理收纳"
        case .mcp: "服务开关 · 工具列表 · 调用日志 · 接入配置"
        case .about: "本地优先的 AI 产品经理 Agent"
        }
    }

    var icon: DSIcon.Name {
        switch self {
        case .general: .gear
        case .model: .agent
        case .usage: .qps
        case .data: .folder
        case .memory: .mem
        case .mcp: .connector
        case .about: .question
        }
    }
}

// MARK: - 模型编辑器弹框目标（新增 = 全新草稿档案；编辑 = 既有档案副本）

/// 模型编辑器弹框的编辑对象：新增走草稿档案，编辑持既有档案副本（保存才落）。
nonisolated struct ModelEditorTarget: Equatable {
    var profile: ModelProfile
    var isNew: Bool
}

// MARK: - 遮罩层（全窗口暗底 + 居中弹框；Esc / 点遮罩关闭）

struct SettingsDialogOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.settingsPresented = false }

            SettingsDialog()
                .dsFadeIn()
        }
        .onExitCommand { model.settingsPresented = false }
    }
}

// MARK: - 弹框本体

/// 左导航 + 右内容（参考图布局）：880×560 · 白底 r16 · 双层大软阴影。
/// 表单逻辑（编辑即存 persistSoon，关闭时兜底 persist）承接原 ModelConfigPage（已删）。
struct SettingsDialog: View {
    @EnvironmentObject private var model: AppModel

    @State private var settings: LLMSettings = .default
    /// Keychain 槽位 → Key 值（槽位 = profile.keychainKey / embedding / search 各自独立，
    /// 多模型下同一 provider 的多个模型可各持一把 Key）。
    @State private var apiKeys: [String: String] = [:]
    /// Keychain 读取失败的槽位（byok.*）：失败 ≠ 未配置——此时字段空不代表 Key 丢，
    /// 且空值提交不得触发 delete（见 2026-09-13 Key「消失」事故）。
    @State private var keyReadFailures: Set<String> = []
    /// 竞品联网搜索的 Tavily Key（Keychain byok.search；SearXNG 源不用）。
    @State private var searchAPIKey: String = ""
    /// 模型编辑器弹框：nil = 收起；非 nil = 正在新增（profile 为草稿）或编辑（含原档案）。
    @State private var modelEditor: ModelEditorTarget?
    @State private var rebuildResult: String?
    /// 外观模式（通用页）：@AppStorage 直写 UserDefaults，四窗口 appAppearance 即时联动。
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                navColumn
                contentColumn
            }

            // 模型编辑器（独立弹框，浮于设置弹框之上）：新增 / 编辑共用一套配置表单
            if let editor = modelEditor {
                ModelEditorSheet(
                    draft: editorDraftBinding,
                    target: editor,
                    keyReadFailures: keyReadFailures,
                    initialKey: apiKeys[editor.profile.keychainKey] ?? "",
                    onCancel: { modelEditor = nil },
                    onSave: { saveModelEditor($0, $1) }
                )
                .dsFadeIn()
            }
        }
        .frame(width: 880, height: 560)
        .background(
            Color.surfaceBase,
            in: RoundedRectangle(cornerRadius: DS.Radius.big)
        )
        // 「无框纯影」：零描边，边界由明度差 + 双层大软阴影承担
        // （原型对话框阴影：0 24/64 14% + 0 4/16 8%）
        .shadow(color: Color.shadowInk.opacity(0.14), radius: 32, y: 12)
        .shadow(color: Color.shadowInk.opacity(0.08), radius: 16, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.big))
        .onAppear {
            settings = model.settings
            reloadKeys()
        }
        .onDisappear { persist() }
    }

    // MARK: - 左导航列（参考图：账户区 + 页导航，选中项浅底浮起）

    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 账户区（原型「本地 Agent」形制，与侧栏底部同款）
            VStack(alignment: .leading, spacing: DS.Spacing.s10) {
                DSAvatar(label: "本地 Agent", size: .md, icon: DSIcon.Name.agent)
                HStack(spacing: DS.Spacing.s6) {
                    Text("本地优先")
                        .font(DS.Font.bodySMStrong)
                        .foregroundStyle(Color.ink900)
                    DSTag(title: "MIT 开源", variant: .neutral)
                }
            }
            .padding(DS.Spacing.s16)

            DSDivider()

            // 页导航（参考图导航列：icon + 标题，选中 overlay-l2 浮起，hover 微亮——
            // 原生源列表语义：hover 即时变色，无缩放无动画）
            VStack(spacing: DS.Spacing.s2) {
                ForEach(SettingsDialogPage.allCases) { page in
                    SettingsNavRow(
                        page: page,
                        isSelected: model.settingsPage == page
                    ) {
                        model.settingsPage = page
                    }
                }
            }
            .padding(DS.Spacing.s8)

            Spacer(minLength: 0)
        }
        .frame(width: 216, alignment: .leading)
        .background(Color.surfaceSecondary)
    }

    // MARK: - 右内容区（页标题 + 关闭钮 → 分隔线 → 页内容）

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DS.Spacing.s12) {
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(model.settingsPage.title)
                        .font(DS.Font.headingMD)
                        .foregroundStyle(Color.ink900)
                    Text(model.settingsPage.subtitle)
                        .font(DS.Font.bodySM)
                        .foregroundStyle(Color.ink500)
                }
                Spacer(minLength: 0)
                DSDialogCloseButton { model.settingsPresented = false }
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.top, DS.Spacing.s16)
            .padding(.bottom, DS.Spacing.s12)

            DSDivider()

            Group {
                switch model.settingsPage {
                case .general: generalPage
                case .model: modelPage
                case .usage: usagePage
                case .data: dataPage
                case .memory: MemorySettingsTab()
                case .mcp: MCPStatusTab()
                case .about: aboutPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceBase)
    }

    // MARK: - 通用页（外观模式）

    /// 外观模式三分段（跟随系统 / 浅色 / 深色）：写 AppStorage → 四窗口即时联动。
    private var generalPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                section(
                    "外观",
                    footer: "模式偏好保存在本机（重启后保持）。「跟随系统」随 macOS「系统设置 → 外观」联动切换。"
                ) {
                    settingsRow("界面外观", detail: appearanceDescription) {
                        DSTabs(
                            items: AppearanceMode.allCases.map { DSTabItem($0, $0.title) },
                            selection: appearanceBinding,
                            compact: true
                        )
                        .frame(width: 210)
                    }
                }

                section(
                    "元素示例",
                    footer: "当前模式下的基础元素观感——切换上方分段，此处与全应用同步过渡（0.28s 交叉淡化）。"
                ) {
                    settingsRow("文字与按钮") {
                        HStack(spacing: DS.Spacing.s12) {
                            Text("标题文字")
                                .font(DS.Font.headingXS)
                                .foregroundStyle(Color.ink900)
                            Text("正文文字")
                                .font(DS.Font.bodyMD)
                                .foregroundStyle(Color.ink700)
                            Text("辅助文字")
                                .font(DS.Font.bodySM)
                                .foregroundStyle(Color.ink500)
                            Button("主要按钮") {}
                                .buttonStyle(.ds(.primary, size: .sm))
                            Button("品牌按钮") {}
                                .buttonStyle(.ds(.brand, size: .sm))
                        }
                    }

                    settingsDivider()

                    settingsRow("标签与状态") {
                        HStack(spacing: DS.Spacing.s8) {
                            DSTag(title: "标签", variant: .brand)
                            DSTag(title: "成功", variant: .success)
                            DSTag(title: "警示", variant: .warning)
                            DSSwitch(isOn: .constant(true))
                            DSKbd(key: "⌘,")
                            Spacer(minLength: DS.Spacing.s8)
                            Text("状态色")
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink500)
                            DSIcon(.circleCheck, size: 12)
                                .foregroundStyle(Color.statusSuccess)
                            DSIcon(.warningFill, size: 12)
                                .foregroundStyle(Color.statusWarning)
                            DSIcon(.circleX, size: 12)
                                .foregroundStyle(Color.statusError)
                        }
                    }

                    settingsDivider()

                    settingsRow("输入控件") {
                        HStack(spacing: DS.Spacing.s8) {
                            TextField("输入框（聚焦时对比描边）", text: .constant(""))
                                .textFieldStyle(.plain)
                                .dsInput(focused: true)
                                .frame(width: 250)
                            DSSelect(
                                options: [DSSelectOption("sample", "下拉选择")],
                                selection: .constant("sample")
                            )
                            .frame(width: 140)
                            .disabled(true)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s20)
        }
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    private var appearanceDescription: String {
        switch appearanceMode {
        case .system: "跟随 macOS 系统外观自动切换浅色 / 深色"
        case .light: "恒定浅色（与交互原型 v4 一致）"
        case .dark: "恒定深色（对齐交互原型 v4 · TraeWork Dark）"
        }
    }

    /// 切换即写 AppStorage；easeInOut 事务令全窗口颜色交叉淡化（appAppearance 挂动画）。
    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.28)) {
                    appearanceRaw = newValue.rawValue
                }
            }
        )
    }

    // MARK: - 模型页（Xcode 偏好面板扁平形制：区头 + 行 + 发丝分隔，零卡片零投影）

    private var modelPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                modelSection
                budgetSection
                retrievalSection
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s20)
        }
    }

    // MARK: - 模型页分区（多模型管理，2026-09-14）

    /// AI 模型区（多模型列表，对齐参考图一）：每行 = 供应商标识 + 模型名 + 供应商名
    /// + 使用中标记 + 编辑 / 删除 + 启用开关；点击行主体切换「使用中」。
    /// 添加 / 编辑均弹独立编辑器弹框（ModelEditorSheet），列表保持纯管理视图。
    private var modelSection: some View {
        section(
            "AI 模型",
            footer: "OpenAI 兼容端点 · 对话阶段共用「使用中」模型的配置。点击行切换使用中模型（即时生效），开关控制是否出现在输入栏切换器；每个模型的 Key 独立存 macOS Keychain（com.xiaofengchen.pm-worker.byok）· 不落明文 · 不入 Git。"
        ) {
            ForEach(settings.models) { profile in
                modelRow(profile)

                if profile.id != settings.models.last?.id {
                    settingsDivider()
                }
            }

            addModelButton
        }
    }

    /// 单个模型行：主体按钮（标识 + 名称 + 供应商 + 使用中标记）与右侧控件
    /// （编辑 / 删除 / 启用开关）分离——点主体切换使用中，控件各自独立响应。
    private func modelRow(_ profile: ModelProfile) -> some View {
        let isActive = settings.activeModelID == profile.id
        return HStack(spacing: DS.Spacing.s10) {
            Button {
                withAnimation(DS.Motion.springFast) {
                    settings.setActiveModel(id: profile.id)
                    persistSoon()
                }
            } label: {
                HStack(spacing: DS.Spacing.s10) {
                    providerBadge(profile.provider)
                    VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                        Text(profile.model)
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink900)
                            .lineLimit(1)
                        Text(DSProviderOption.title(for: profile.provider))
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Spacing.s8)
                    if isActive {
                        DSTag(title: "使用中", variant: .brand)
                    }
                }
                .padding(.vertical, DS.Spacing.s8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("使用 \(profile.model)（\(DSProviderOption.title(for: profile.provider))）")

            rowIconButton(.pencil, help: "编辑模型配置") {
                openModelEditor(profile)
            }

            rowIconButton(
                .delete,
                help: settings.models.count > 1 ? "删除该模型" : "至少保留一个模型",
                disabled: settings.models.count <= 1
            ) {
                removeModel(profile)
            }

            DSSwitch(isOn: enabledBinding(for: profile))
        }
        .padding(.vertical, DS.Spacing.s6)
    }

    /// 供应商标识（20×20 圆角方块 + 首字母 mono）：DS 中性徽标语义，不引入品牌色噪声。
    private func providerBadge(_ provider: String) -> some View {
        Text(String(DSProviderOption.title(for: provider).prefix(1)).uppercased())
            .font(DS.Font.mono2XS)
            .foregroundStyle(Color.ink700)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(Color.overlayL2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
    }

    /// 行内图标按钮（编辑 / 删除）：hover overlayL2，禁用 45% 透明。
    private func rowIconButton(
        _ icon: DSIcon.Name,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ModelRowIconButton(icon: icon, help: help, disabled: disabled, action: action)
    }

    /// 添加模型行（对齐参考图三底部入口）：虚线边框弱主行动，点击弹独立编辑器弹框。
    private var addModelButton: some View {
        Button {
            openModelEditor(nil)
        } label: {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.plus, size: 12)
                Text("添加模型")
                    .font(DS.Font.bodySM)
            }
            .foregroundStyle(Color.ink700)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(
                        Color.borderL1,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .padding(.top, DS.Spacing.s8)
        .help("添加一个新的 AI 模型（OpenAI 兼容端点）")
    }

    // MARK: - 模型编辑器弹框（新增 / 编辑共用，独立于列表；保存才落盘）

    /// 打开编辑器：nil = 新增（草稿档案跟随最近供应商带出预设），否则编辑既有档案副本。
    private func openModelEditor(_ profile: ModelProfile?) {
        let target: ModelEditorTarget
        if let profile {
            target = ModelEditorTarget(profile: profile, isNew: false)
        } else {
            target = ModelEditorTarget(
                profile: ModelProfile.newProfile(
                    defaultProvider: settings.models.last?.provider ?? "deepseek"
                ),
                isNew: true
            )
        }
        modelEditor = target
    }

    /// 编辑器草稿双向绑定（弹框内逐字段编辑；保存才写 settings / Keychain）。
    private var editorDraftBinding: Binding<ModelProfile> {
        Binding(
            get: {
                modelEditor?.profile ?? ModelProfile(provider: "deepseek", model: "")
            },
            set: { newValue in
                modelEditor?.profile = newValue
            }
        )
    }

    /// 保存编辑器：Key 按最终槽位写 / 删（读取失败时空值不删，防误清真 Key），
    /// 档案 upsert 即写透 stages（使用中档案即时生效），关闭弹框。
    private func saveModelEditor(_ profile: ModelProfile, _ keyValue: String) {
        let profile = profile
        let slot = profile.keychainKey
        let trimmed = keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !keyReadFailures.contains(slot) {
                KeychainStore.delete(slot)
            }
            apiKeys[slot] = ""
        } else {
            try? KeychainStore.set(trimmed, forKey: slot)
            apiKeys[slot] = trimmed
        }
        // 供应商切换导致槽位迁移时，旧共享槽不动（embedding / 其他档案可能仍引用）
        settings.upsertModel(profile)
        modelEditor = nil
        persistSoon()
    }

    /// 单行预算控制区：档位语义提示随选择联动。
    private var budgetSection: some View {
        section("用量预算") {
            settingsRow("单次全流程 token 上限", detail: tokenTierHint) {
                DSTabs(
                    items: [
                        DSTabItem(100_000, "10 万"),
                        DSTabItem(300_000, "30 万"),
                        DSTabItem(500_000, "50 万"),
                        DSTabItem(1_000_000, "100 万"),
                    ],
                    selection: maxTokensBinding,
                    compact: true
                )
                .frame(width: 264)
            }
        }
    }

    /// 当前档位的语义说明（给数字选择附上「这档适合什么」）。
    private var tokenTierHint: String {
        switch settings.maxTokensPerRun {
        case 100_000: "轻量 · 单文档澄清 / 结构"
        case 300_000: "日常 · 单项目全流程"
        case 500_000: "标准 · 全流程含调研评审"
        case 1_000_000: "重度 · 多轮评审 / 长文档"
        default: "按单次全流程预算熔断，防止跑飞"
        }
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { settings.maxTokensPerRun },
            set: { newValue in
                settings.maxTokensPerRun = newValue
                persistSoon()
            }
        )
    }

    /// 检索增强区：向量编码 + 竞品联网搜索，两个可选项各占一组行。
    private var retrievalSection: some View {
        section(
            "检索增强",
            footer: "两项均可选 · 不配置不影响主流程。"
        ) {
            settingsRow("向量编码", detail: "仅用于知识库向量化，与对话模型相互独立；不配置则知识库不走向量检索。") {
                embeddingStatusTag
            }

            settingsDivider()

            // 向量编码字段行：供应商 / 模型 / baseURL / Key 一行排布（可选项降权密度）
            HStack(spacing: DS.Spacing.s8) {
                DSSelect(
                    options: DSProviderOption.selectOptions,
                    selection: embeddingProviderBinding
                )
                .frame(width: 140)

                TextField("model", text: embeddingModelBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 140)

                TextField("baseURL · 可选", text: embeddingBaseURLBinding)
                    .textFieldStyle(.plain)
                    .dsInput()

                SecureField("API Key · 可选", text: embeddingKeyBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 180)
            }
            .padding(.vertical, DS.Spacing.s10)

            if let config = settings.stages[.embedding] {
                settingsDivider()
                settingsRow("向量生效端点") {
                    EndpointLine(baseURL: config.baseURL, provider: config.provider)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            settingsDivider()

            settingsRow(
                "竞品联网搜索",
                detail: "支持 SearXNG 兼容端点（GET JSON）或 Tavily 兼容端点（POST + Bearer，含官方与国内中转，按端点域名自动识别）。配置后竞品分析分支会先联网检索并抓取网页佐证；留空则基于模型自身知识分析，文中标注「未联网检索」。"
            ) {
                searchStatusTag
            }

            settingsDivider()

            HStack(spacing: DS.Spacing.s10) {
                TextField(
                    "https://searxng.example.com/search?format=json",
                    text: searchEndpointBinding
                )
                .textFieldStyle(.plain)
                .dsInput()

                SecureField("Tavily Key · 仅 Tavily 源需要", text: searchAPIKeyBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 180)
            }
            .padding(.vertical, DS.Spacing.s10)
        }
    }

    private var embeddingStatusTag: DSTag {
        if let config = settings.stages[.embedding],
           keyReadFailures.contains(config.apiKeyKeychainKey) {
            return DSTag(title: "Keychain 读取失败", variant: .warning, icon: .warningFill)
        }
        if embeddingKeyConfigured {
            return DSTag(title: "已配置", variant: .success, icon: .circleCheck)
        }
        return DSTag(title: "未配置 · 可选", variant: .neutral)
    }

    private var searchStatusTag: DSTag {
        let endpoint = settings.searchEndpoint.trimmingCharacters(in: .whitespaces)
        if endpoint.isEmpty {
            return DSTag(title: "未启用 · 可选", variant: .neutral)
        }
        // Tavily 源必须配 Key（SearXNG 无 Key）：缺 Key 给警示，避免运行时静默回退离线分析
        if keyReadFailures.contains(WebTool.searchAPIKeyKeychainKey) {
            return DSTag(title: "Keychain 读取失败", variant: .warning, icon: .warningFill)
        }
        if WebTool.isTavilyEndpoint(endpoint)
            && searchAPIKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return DSTag(title: "已启用 · 缺 Key", variant: .warning)
        }
        return DSTag(title: "已启用", variant: .success, icon: .circleCheck)
    }

    private var embeddingKeyConfigured: Bool {
        guard let config = settings.stages[.embedding] else { return false }
        return apiKeys[config.apiKeyKeychainKey]?.isEmpty == false
    }

    /// 粘贴错误的常见形态（URL / 含空白 / 前缀不对）——非阻断，仅提示。
    nonisolated static func keyFormatWarning(_ key: String, provider: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.lowercased().hasPrefix("http") || trimmed.hasSuffix(".com") {
            return "这看起来是网址而非 API Key——请到平台「API Keys」页复制密钥本身"
        }
        if trimmed.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            return "Key 中混入空白字符——复制时可能带上了多余内容"
        }
        if provider == "deepseek" && !trimmed.hasPrefix("sk-") {
            return "DeepSeek 的 Key 以 sk- 开头——请检查是否复制完整"
        }
        return nil
    }

    /// 状态标签：Key 配置三态（已存 / 未配置 / 读取失败）。
    nonisolated static func keyTag(configured: Bool, optional: Bool, readFailed: Bool = false) -> DSTag {
        if readFailed {
            return DSTag(title: "Keychain 读取失败", variant: .warning, icon: .warningFill)
        }
        if configured {
            return DSTag(title: "已存入 Keychain", variant: .success, icon: .circleCheck)
        }
        if optional {
            return DSTag(title: "未配置 · 可选", variant: .neutral)
        }
        return DSTag(title: "未配置", variant: .warning)
    }

    // MARK: - 用量页（原「模型」Tab 内的 DisclosureGroup 独立成页）

    private var usagePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                section(
                    "用量与成本",
                    footer: "费用按内置估算单价（人民币元 / 1M tokens）计算，可在 CostTracker 价目表调整；端点未返回 usage 时按字符口径估算（即「估算占比」）。"
                ) {
                    UsagePanel()
                }
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s20)
        }
    }

    // MARK: - 数据页（原 SettingsView「数据」Tab 平移）

    private var dataPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                section(
                    "文件系统是唯一事实源",
                    footer: "index.sqlite 只是索引，可随时删除并从文件全量重建。"
                ) {
                    settingsRow("数据目录") {
                        Text(PMAgentStore.root.path)
                            .font(DS.Font.monoSM)
                            .foregroundStyle(Color.ink900)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 340, alignment: .trailing)
                    }

                    settingsDivider()

                    settingsRow("在 Finder 中显示") {
                        Button("打开") {
                            NSWorkspace.shared.open(PMAgentStore.root)
                        }
                        .buttonStyle(.ds(.secondary, size: .sm))
                    }
                }

                section("索引") {
                    settingsRow("重建索引", detail: rebuildResult ?? "知识点与技能的 SQLite 全量重建，随时可重跑") {
                        Button("重建") { rebuildIndex() }
                            .buttonStyle(.ds(.primary, size: .sm))
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s20)
        }
    }

    // MARK: - 关于页（参考图「关于 TraeWork」）

    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                section(
                    "应用",
                    footer: "从一句话想法到澄清表、PRD、交互原型、决策日志与风险登记册，全部产物以纯文件落盘 ~/PMAgent，可 Git 管理。"
                ) {
                    HStack(spacing: DS.Spacing.s12) {
                        DSAvatar(label: "PM", size: .lg, icon: DSIcon.Name.agent)
                        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                            Text("PM Copilot")
                                .font(DS.Font.headingSM)
                                .foregroundStyle(Color.ink900)
                            Text("v\(appVersion)（Build \(appBuild)）· MIT 开源")
                                .font(DS.Font.bodySM)
                                .foregroundStyle(Color.ink500)
                        }
                    }
                    .padding(.vertical, DS.Spacing.s10)
                }

                section(
                    "技术栈",
                    footer: "无遥测 · 无云同步 · API Key 仅存 macOS Keychain。"
                ) {
                    aboutRow("界面", "SwiftUI · TraeWork 设计系统（浅色 / 深色）")

                    settingsDivider()

                    aboutRow("存储", "GRDB（SQLite 索引）· 纯文件产物目录")

                    settingsDivider()

                    aboutRow("协议", "MCP stdio —— Claude Desktop / Cursor 可直接调用")
                }
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s20)
        }
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        settingsRow(title) {
            Text(value)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .multilineTextAlignment(.trailing)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    // MARK: - 区块与行（Xcode 偏好面板形制：小灰区头 + 行列表 + 发丝分隔 + 脚注）
    // 弃 dsCard 卡片容器——灰底描边圆角是 web 卡片语义；Xcode 设置页的质感
    // 来自「无容器 + hairline 分隔 + 标签/控件稳定对齐」的密度与秩序。

    private func section<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Text(title)
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink500)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let footer {
                Text(footer)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.s4)
            }
        }
    }

    /// 设置行：左标签列（+ 辅助说明）+ 右控件——System Settings 对齐范式。
    private func settingsRow<Content: View>(
        _ label: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.s16) {
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text(label)
                    .font(DS.Font.bodyMD)
                    .foregroundStyle(Color.ink900)
                if let detail {
                    Text(detail)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.s16)
            trailing()
        }
        .padding(.vertical, DS.Spacing.s10)
    }

    /// 行间发丝分隔线（组内分隔，首行前 / 末行后不出现）。
    private func settingsDivider() -> some View {
        DSDivider()
    }

    // MARK: - 绑定（多模型档案逐档案绑定；向量编码写 .embedding）

    private var searchEndpointBinding: Binding<String> {
        Binding(
            get: { settings.searchEndpoint },
            set: { newValue in
                settings.searchEndpoint = newValue
                persistSoon()
            }
        )
    }

    /// Tavily Key 写 Keychain（与 chat/embedding Key 同款 BYOK 路径，不进 settings.json）。
    private var searchAPIKeyBinding: Binding<String> {
        Binding(
            get: { searchAPIKey },
            set: { newValue in
                searchAPIKey = newValue
                if newValue.isEmpty {
                    guard !keyReadFailures.contains(WebTool.searchAPIKeyKeychainKey) else { return }
                    KeychainStore.delete(WebTool.searchAPIKeyKeychainKey)
                } else {
                    try? KeychainStore.set(newValue, forKey: WebTool.searchAPIKeyKeychainKey)
                }
            }
        )
    }

    // MARK: 模型档案绑定（编辑即存 + 使用中档案写透 stages 即时生效）

    /// 档案整体绑定：按 id 定位（ForEach 行内表单共用）。
    private func profileBinding(for profile: ModelProfile) -> Binding<ModelProfile> {
        Binding(
            get: {
                settings.models.first(where: { $0.id == profile.id }) ?? profile
            },
            set: { newValue in
                settings.upsertModel(newValue)
                persistSoon()
            }
        )
    }

    /// 启用开关：停用使用中档案时 setActiveModel 兜底链自动迁移（数据层保证）。
    private func enabledBinding(for profile: ModelProfile) -> Binding<Bool> {
        Binding(
            get: { profileBinding(for: profile).wrappedValue.enabled },
            set: { newValue in
                settings.setModelEnabled(id: profile.id, enabled: newValue)
                persistSoon()
            }
        )
    }

    /// 删除模型（至少保留一个；档案私有 Key 槽一并清理——旧存量共享槽不删，
    /// embedding / 其他档案可能仍引用）。
    private func removeModel(_ profile: ModelProfile) {
        guard settings.models.count > 1 else { return }
        if profile.ownsKeychainSlot, !keyReadFailures.contains(profile.keychainKey) {
            KeychainStore.delete(profile.keychainKey)
        }
        apiKeys[profile.keychainKey] = nil
        settings.removeModel(id: profile.id)
        persistSoon()
    }

    private var embeddingProviderBinding: Binding<String> {
        Binding(
            get: { settings.stages[.embedding]?.provider ?? "" },
            set: { newValue in
                guard settings.stages[.embedding] != nil,
                      settings.stages[.embedding]!.provider != newValue else { return }
                settings.stages[.embedding]!.provider = newValue
                settings.stages[.embedding]!.model = StageModelConfig.defaultModel(for: newValue)
                settings.stages[.embedding]!.baseURL = nil
                persistSoon()
            }
        )
    }

    private var embeddingModelBinding: Binding<String> {
        Binding(
            get: { settings.stages[.embedding]?.model ?? "" },
            set: { newValue in
                if settings.stages[.embedding] != nil {
                    settings.stages[.embedding]!.model = newValue
                    persistSoon()
                }
            }
        )
    }

    private var embeddingBaseURLBinding: Binding<String> {
        Binding(
            get: { settings.stages[.embedding]?.baseURL ?? "" },
            set: { newValue in
                if settings.stages[.embedding] != nil {
                    settings.stages[.embedding]!.baseURL = newValue.isEmpty ? nil : newValue
                    persistSoon()
                }
            }
        )
    }

    private var embeddingKeyBinding: Binding<String> {
        Binding(
            get: {
                guard let config = settings.stages[.embedding] else { return "" }
                return apiKeys[config.apiKeyKeychainKey] ?? ""
            },
            set: { newValue in
                guard let config = settings.stages[.embedding] else { return }
                let slot = config.apiKeyKeychainKey
                apiKeys[slot] = newValue
                if newValue.isEmpty {
                    guard !keyReadFailures.contains(slot) else { return }
                    KeychainStore.delete(slot)
                } else {
                    try? KeychainStore.set(newValue, forKey: slot)
                }
            }
        )
    }

    private func reloadKeys() {
        // 按槽位读取（多模型下每个档案独立槽位；embedding / search 各自独立）
        var keys: [String: String] = [:]
        var failures: Set<String> = []
        var slots: [String] = settings.models.map(\.keychainKey)
        if let embedding = settings.stages[.embedding] {
            slots.append(embedding.apiKeyKeychainKey)
        }
        for slot in slots where keys[slot] == nil {
            switch KeychainStore.read(slot) {
            case .found(let value): keys[slot] = value
            case .notFound: keys[slot] = ""
            case .accessFailed: failures.insert(slot)
            }
        }
        apiKeys = keys
        keyReadFailures = failures
        switch KeychainStore.read(WebTool.searchAPIKeyKeychainKey) {
        case .found(let value): searchAPIKey = value
        case .notFound: searchAPIKey = ""
        case .accessFailed:
            searchAPIKey = ""
            keyReadFailures.insert(WebTool.searchAPIKeyKeychainKey)
        }
    }

    // MARK: - 持久化与索引

    private func persistSoon() {
        // 卡片内联编辑即存（设置量小，直接写）
        persist()
    }

    private func persist() {
        model.settings = settings
        model.saveSettings()
    }

    private func rebuildIndex() {
        let dbURL = PMAgentStore.root.appendingPathComponent("index.sqlite")
        do {
            let db = try AppDatabase(indexURL: dbURL)
            let report = try IndexRebuilder.rebuild(database: db)
            rebuildResult =
                "已重建：知识点 \(report.knowledgePoints) · 技能 \(report.skills)"
        } catch {
            rebuildResult = "重建失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 模型页组件（internal：对话输入栏的模型切换器 ComposerModelButton 复用供应商名）

/// 供应商选项（value = settings 存储值；title = 展示名）。
struct DSProviderOption {
    let value: String
    let title: String

    static let all: [DSProviderOption] = [
        DSProviderOption(value: "deepseek", title: "DeepSeek"),
        DSProviderOption(value: "zhipu", title: "智谱"),
        DSProviderOption(value: "volcengine", title: "火山引擎"),
        DSProviderOption(value: "openai", title: "OpenAI"),
        DSProviderOption(value: "anthropic-compat", title: "Anthropic 网关"),
        DSProviderOption(value: "ollama", title: "Ollama 本地"),
    ]

    /// DSSelect 用的选项映射。
    static var selectOptions: [DSSelectOption<String>] {
        all.map { DSSelectOption($0.value, $0.title) }
    }

    /// provider 存储值 → 展示名（未知值原样回显，自定义网关不丢名）。
    static func title(for provider: String) -> String {
        all.first(where: { $0.value == provider })?.title ?? provider
    }
}

/// 模型行内图标按钮（编辑 / 删除）：24×24 hover overlayL2，禁用降透明。
private struct ModelRowIconButton: View {
    let icon: DSIcon.Name
    var help: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(icon, size: 13)
                .foregroundStyle(disabled ? Color.ink300 : Color.ink500)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(hovered && !disabled ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help(help)
    }
}

/// 模型编辑器弹框（2026-09-14，浮于设置弹框之上的独立模态）：
/// 新增 / 编辑共用一套配置表单——草稿在弹框内逐字段编辑，点「添加 / 保存」
/// 才写 settings + Keychain（写透 stages 即时生效），取消 / Esc / 关闭钮全部丢弃草稿。
/// 点遮罩不关闭（防误触丢配置），Esc 优先关闭本弹框而非设置弹框。
private struct ModelEditorSheet: View {
    @Binding var draft: ModelProfile
    let target: ModelEditorTarget
    let keyReadFailures: Set<String>
    /// 打开时槽位已存的 Key（编辑态回显；新增态槽位全新恒为空串）。
    let initialKey: String
    let onCancel: () -> Void
    let onSave: (ModelProfile, String) -> Void

    @State private var keyValue: String = ""

    private var title: String { target.isNew ? "添加模型" : "编辑模型" }
    private var saveButtonTitle: String { target.isNew ? "添加" : "保存" }

    var body: some View {
        ZStack {
            // 遮罩：阻断与底层设置页的交互；刻意不响应点击关闭（防误触丢草稿）
            Color.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 0) {
                header
                DSDivider()
                ScrollView {
                    form
                        .padding(.horizontal, DS.Spacing.s24)
                        .padding(.vertical, DS.Spacing.s20)
                }
                DSDivider()
                footer
            }
            .frame(width: 620, height: 540)
            .background(
                Color.surfaceBase,
                in: RoundedRectangle(cornerRadius: DS.Radius.big)
            )
            // 与设置弹框同款「无框纯影」：0 24/64 14% + 0 4/16 8%
            .shadow(color: Color.shadowInk.opacity(0.14), radius: 32, y: 12)
            .shadow(color: Color.shadowInk.opacity(0.08), radius: 16, y: 4)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.big))
        }
        .onAppear { keyValue = initialKey }
        .onExitCommand { onCancel() }  // Esc 先关本弹框，不穿透到设置弹框
    }

    // MARK: 头部（标题 + 副标题 + 关闭钮，与设置弹框同形制）

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s12) {
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text(title)
                    .font(DS.Font.headingMD)
                    .foregroundStyle(Color.ink900)
                Text("OpenAI 兼容端点 · 保存后即时生效，对话阶段共用该配置")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink500)
            }
            Spacer(minLength: 0)
            DSDialogCloseButton { onCancel() }
        }
        .padding(.horizontal, DS.Spacing.s24)
        .padding(.top, DS.Spacing.s16)
        .padding(.bottom, DS.Spacing.s12)
    }

    // MARK: 表单（行形制与设置页同款：左标签 + 右控件 + 发丝分隔）

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorRow("供应商") {
                DSSelect(options: DSProviderOption.selectOptions, selection: providerBinding)
                    .frame(width: 170)
            }

            editorDivider

            editorRow("模型") {
                TextField("model", text: modelBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 260)
            }

            editorDivider

            editorRow("baseURL · 可选") {
                TextField("覆盖预设端点", text: baseURLBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 300)
            }

            editorDivider

            editorRow("生效端点", detail: "实际请求的端点——预设值或上方覆盖值") {
                EndpointLine(baseURL: draft.baseURL, provider: draft.provider)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            editorDivider

            editorRow("支持图片输入", detail: imageSupportHint) {
                DSSwitch(isOn: supportsImagesBinding)
            }

            editorDivider

            keyRow
        }
    }

    /// 图片输入的动态说明（跟随开关状态）。
    private var imageSupportHint: String {
        draft.supportsImages
            ? "已开启——对话输入区可添加图片，随消息发给模型识别（需模型本身具备视觉能力）"
            : "开启后对话可发送图片（截图 / 竞品界面 / 原型稿），模型将识别图片内容"
    }

    /// API Key 行（草稿槽位独立持钥）：状态标签 + 密钥输入；格式可疑时行内警示。
    private var keyRow: some View {
        VStack(spacing: 0) {
            editorRow("API Key") {
                HStack(spacing: DS.Spacing.s8) {
                    SettingsDialog.keyTag(
                        configured: !keyValue.trimmingCharacters(in: .whitespaces).isEmpty,
                        optional: false,
                        readFailed: keyReadFailures.contains(draft.keychainKey)
                    )
                    SecureField("粘贴 API Key", text: $keyValue)
                        .textFieldStyle(.plain)
                        .dsInput()
                        .frame(width: 240)
                }
            }
            if let warning = SettingsDialog.keyFormatWarning(keyValue, provider: draft.provider) {
                keyWarningLine(warning)
            } else if keyReadFailures.contains(draft.keychainKey) {
                // 读取失败 ≠ 未配置：Key 很可能仍在，此时清空输入不会删 Key
                keyWarningLine(
                    "Keychain 暂时读不出来（常见于并行构建 / 沙盒启动后）——重启 App 即可恢复，已存的 Key 不会因此丢失"
                )
            }
        }
    }

    private func keyWarningLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s4) {
            DSIcon(.warningFill, size: 12)
                .foregroundStyle(Color.statusWarning)
            Text(text)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DS.Spacing.s2)
        .padding(.bottom, DS.Spacing.s10)
    }

    // MARK: 底部操作区（取消丢弃草稿 · 添加/保存提交）

    private var footer: some View {
        HStack(spacing: DS.Spacing.s10) {
            Spacer(minLength: 0)
            Button("取消") { onCancel() }
                .buttonStyle(.ds(.secondary, size: .sm))
            Button(saveButtonTitle) { onSave(draft, keyValue) }
                .buttonStyle(.ds(.primary, size: .sm))
        }
        .padding(.horizontal, DS.Spacing.s24)
        .padding(.vertical, DS.Spacing.s12)
    }

    // MARK: 草稿绑定（换供应商重置缺省；共享槽跨供应商迁移见 openModelEditor 侧说明）

    /// 切供应商 = 换一家：model/baseURL 重置为该 provider 缺省，视觉能力按预设带出；
    /// 旧存量沿用的 `byok.<provider>` 共享槽不跨供应商复用——迁到档案私有槽，Key 重新粘贴。
    private var providerBinding: Binding<String> {
        Binding(
            get: { draft.provider },
            set: { newValue in
                guard draft.provider != newValue else { return }
                draft.provider = newValue
                draft.model = StageModelConfig.defaultModel(for: newValue)
                draft.baseURL = nil
                draft.supportsImages = StageModelConfig.defaultSupportsImages(for: newValue)
                if !draft.ownsKeychainSlot {
                    draft.keychainKey = "byok.model.\(draft.id)"
                    keyValue = ""
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.model },
            set: { draft.model = $0 }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { draft.baseURL ?? "" },
            set: { draft.baseURL = $0.isEmpty ? nil : $0 }
        )
    }

    private var supportsImagesBinding: Binding<Bool> {
        Binding(
            get: { draft.supportsImages },
            set: { draft.supportsImages = $0 }
        )
    }

    // MARK: 行助手（弹框自含，避免扩大 SettingsDialog 的私有 API 面）

    private func editorRow<Content: View>(
        _ label: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.s16) {
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text(label)
                    .font(DS.Font.bodyMD)
                    .foregroundStyle(Color.ink900)
                if let detail {
                    Text(detail)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.s16)
            trailing()
        }
        .padding(.vertical, DS.Spacing.s10)
    }

    private var editorDivider: some View {
        DSDivider()
    }
}

/// 生效端点行：链接图标 + mono 端点 + 预设/自定义标注；网关缺 baseURL 时警示。
/// 作为设置行 trailing 簇使用（右对齐），不带内部 Spacer。
private struct EndpointLine: View {
    let baseURL: String?
    let provider: String

    private var custom: String {
        (baseURL ?? "").trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        let preset = StageModelConfig.presetBaseURL(for: provider)

        return HStack(spacing: DS.Spacing.s6) {
            DSIcon(.link, size: 12)
                .foregroundStyle(Color.ink300)
            if !custom.isEmpty {
                Text(custom)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("自定义")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.brandAccent)
            } else if preset.isEmpty {
                Text("未设置端点 · 该网关必填 baseURL")
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.statusWarning)
            } else {
                Text(preset)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("预设")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
            }
        }
    }
}

/// 弹框左导航行：icon + 标题，选中 overlay-l2 浮起、hover overlay-l1 微亮
/// （原生源列表语义：hover 即时变色，无缩放无动画）。
private struct SettingsNavRow: View {
    let page: SettingsDialogPage
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s10) {
                DSIcon(page.icon, size: 14)
                    .foregroundStyle(isSelected ? Color.ink700 : Color.ink500)
                Text(page.title)
                    .font(DS.Font.bodyMD)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? Color.ink900 : Color.ink700)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s6)
            .frame(minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(isSelected ? Color.overlayL2 : (hovering ? Color.overlayL1 : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    SettingsDialogOverlay()
        .environmentObject(AppModel())
        .frame(width: 1000, height: 640)
}
