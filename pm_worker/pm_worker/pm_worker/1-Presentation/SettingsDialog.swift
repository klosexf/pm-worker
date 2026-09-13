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

/// 弹框左导航六页（通用置首，对应系统设置惯例）。
enum SettingsDialogPage: String, CaseIterable, Identifiable {
    case general
    case model
    case usage
    case data
    case mcp
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .model: "模型"
        case .usage: "用量"
        case .data: "数据"
        case .mcp: "MCP 服务"
        case .about: "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "外观模式 · 界面偏好"
        case .model: "BYOK · 统一模型配置 · Key 存 Keychain"
        case .usage: "本次 / 本月 token 与费用估算"
        case .data: "文件系统是唯一事实源 · 索引可随时重建"
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
        case .mcp: .connector
        case .about: .question
        }
    }
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
    @State private var apiKeys: [String: String] = [:]
    /// 竞品联网搜索的 Tavily Key（Keychain byok.search；SearXNG 源不用）。
    @State private var searchAPIKey: String = ""
    @State private var rebuildResult: String?
    /// 外观模式（通用页）：@AppStorage 直写 UserDefaults，四窗口 appAppearance 即时联动。
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    var body: some View {
        HStack(spacing: 0) {
            navColumn
            contentColumn
        }
        .frame(width: 880, height: 560)
        .background(
            Color.surfaceBase,
            in: RoundedRectangle(cornerRadius: DS.Radius.big)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.big)
                .strokeBorder(Color.borderL2, lineWidth: 1)
        )
        // 原型对话框阴影：0 24/64 14% + 0 4/16 8%
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

    // MARK: - 模型页分区

    /// AI 模型区：每行单一职责（供应商 / 模型 / baseURL / 生效端点 / 图片开关 / Key），
    /// Keychain 说明走区脚注；配置状态由 Key 行状态标签承载（原 hero 卡就绪标冗余，已删）。
    private var modelSection: some View {
        section(
            "AI 模型",
            footer: "OpenAI 兼容端点 · 意图分类 → 毒舌评审 8 个对话阶段共用这一份配置。仅存 macOS Keychain（com.xiaofengchen.pm-worker.byok）· 不落明文 · 不入 Git。"
        ) {
            settingsRow("供应商") {
                DSSelect(
                    options: DSProviderOption.selectOptions,
                    selection: chatProviderBinding
                )
                .frame(width: 170)
            }

            settingsDivider()

            settingsRow("模型") {
                TextField("model", text: chatModelBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 260)
            }

            settingsDivider()

            settingsRow("baseURL · 可选") {
                TextField("覆盖预设端点", text: chatBaseURLBinding)
                    .textFieldStyle(.plain)
                    .dsInput()
                    .frame(width: 300)
            }

            settingsDivider()

            settingsRow("生效端点", detail: "实际请求的端点——预设值或上方覆盖值") {
                EndpointLine(
                    baseURL: settings.chatConfig.baseURL,
                    provider: settings.chatConfig.provider
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            settingsDivider()

            settingsRow("支持图片输入", detail: imageSupportHint) {
                DSSwitch(isOn: chatSupportsImagesBinding)
            }

            settingsDivider()

            chatKeyRow
        }
    }

    /// 图片输入的动态说明（跟随开关状态）。
    private var imageSupportHint: String {
        chatSupportsImagesBinding.wrappedValue
            ? "已开启——对话输入区可添加图片，随消息发给模型识别（需模型本身具备视觉能力）"
            : "开启后对话可发送图片（截图 / 竞品界面 / 原型稿），模型将识别图片内容"
    }

    /// API Key 行：状态标签 + 密钥输入；格式可疑时行内警示（不阻断保存）。
    private var chatKeyRow: some View {
        VStack(spacing: 0) {
            settingsRow("API Key") {
                HStack(spacing: DS.Spacing.s8) {
                    keyTag(configured: chatKeyConfigured, optional: false)
                    SecureField("粘贴 API Key", text: chatKeyBinding)
                        .textFieldStyle(.plain)
                        .dsInput()
                        .frame(width: 240)
                }
            }
            if let warning = Self.keyFormatWarning(chatKeyBinding.wrappedValue, provider: settings.chatConfig.provider) {
                HStack(spacing: DS.Spacing.s4) {
                    DSIcon(.warningFill, size: 12)
                        .foregroundStyle(Color.statusWarning)
                    Text(warning)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.statusWarning)
                }
                .padding(.bottom, DS.Spacing.s10)
            }
        }
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
        if WebTool.isTavilyEndpoint(endpoint)
            && searchAPIKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return DSTag(title: "已启用 · 缺 Key", variant: .warning)
        }
        return DSTag(title: "已启用", variant: .success, icon: .circleCheck)
    }

    private var chatKeyConfigured: Bool {
        apiKeys[settings.chatConfig.provider]?.isEmpty == false
    }

    private var embeddingKeyConfigured: Bool {
        guard let config = settings.stages[.embedding] else { return false }
        return apiKeys[config.provider]?.isEmpty == false
    }

    /// 粘贴错误的常见形态（URL / 含空白 / 前缀不对）——非阻断，仅提示。
    nonisolated private static func keyFormatWarning(_ key: String, provider: String) -> String? {
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

    private func keyTag(configured: Bool, optional: Bool) -> DSTag {
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

    // MARK: - 绑定（统一入口写 chatConfig，向量编码写 .embedding）

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
                    KeychainStore.delete(WebTool.searchAPIKeyKeychainKey)
                } else {
                    try? KeychainStore.set(newValue, forKey: WebTool.searchAPIKeyKeychainKey)
                }
            }
        )
    }

    // 切 provider = 换一家供应商：model/baseURL 重置为该 provider 缺省，避免残留旧端点
    private var chatProviderBinding: Binding<String> {
        Binding(
            get: { settings.chatConfig.provider },
            set: { newValue in
                var config = settings.chatConfig
                guard config.provider != newValue else { return }
                config.provider = newValue
                config.model = StageModelConfig.defaultModel(for: newValue)
                config.baseURL = nil
                // 视觉能力按供应商预设带出（gpt-4o / claude 系默认支持）
                config.supportsImages = StageModelConfig.defaultSupportsImages(for: newValue)
                settings.chatConfig = config
                persistSoon()
            }
        )
    }

    /// 图片输入开关（写全部对话阶段；向量编码无视觉语义不涉及）。
    private var chatSupportsImagesBinding: Binding<Bool> {
        Binding(
            get: { settings.chatConfig.supportsImages },
            set: { newValue in
                var config = settings.chatConfig
                config.supportsImages = newValue
                settings.chatConfig = config
                persistSoon()
            }
        )
    }

    private var chatModelBinding: Binding<String> {
        Binding(
            get: { settings.chatConfig.model },
            set: { newValue in
                settings.chatConfig.model = newValue
                persistSoon()
            }
        )
    }

    private var chatBaseURLBinding: Binding<String> {
        Binding(
            get: { settings.chatConfig.baseURL ?? "" },
            set: { newValue in
                settings.chatConfig.baseURL = newValue.isEmpty ? nil : newValue
                persistSoon()
            }
        )
    }

    private var chatKeyBinding: Binding<String> {
        Binding(
            get: { apiKeys[settings.chatConfig.provider] ?? "" },
            set: { newValue in
                let keychainKey = settings.chatConfig.apiKeyKeychainKey
                apiKeys[settings.chatConfig.provider] = newValue
                if newValue.isEmpty {
                    KeychainStore.delete(keychainKey)
                } else {
                    try? KeychainStore.set(newValue, forKey: keychainKey)
                }
            }
        )
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
                return apiKeys[config.provider] ?? ""
            },
            set: { newValue in
                guard let config = settings.stages[.embedding] else { return }
                apiKeys[config.provider] = newValue
                if newValue.isEmpty {
                    KeychainStore.delete(config.apiKeyKeychainKey)
                } else {
                    try? KeychainStore.set(newValue, forKey: config.apiKeyKeychainKey)
                }
            }
        )
    }

    private func reloadKeys() {
        var keys: [String: String] = [:]
        for stage in LLMStage.allCases {
            guard let config = settings.stages[stage] else { continue }
            if keys[config.provider] == nil {
                keys[config.provider] = KeychainStore.get(config.apiKeyKeychainKey) ?? ""
            }
        }
        apiKeys = keys
        searchAPIKey = KeychainStore.get(WebTool.searchAPIKeyKeychainKey) ?? ""
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

// MARK: - 模型页组件（文件私有）

/// 供应商选项（value = settings 存储值；title = 展示名）。
private struct DSProviderOption {
    let value: String
    let title: String

    static let all: [DSProviderOption] = [
        DSProviderOption(value: "deepseek", title: "DeepSeek"),
        DSProviderOption(value: "zhipu", title: "智谱"),
        DSProviderOption(value: "openai", title: "OpenAI"),
        DSProviderOption(value: "anthropic-compat", title: "Anthropic 网关"),
        DSProviderOption(value: "ollama", title: "Ollama 本地"),
    ]

    /// DSSelect 用的选项映射。
    static var selectOptions: [DSSelectOption<String>] {
        all.map { DSSelectOption($0.value, $0.title) }
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
