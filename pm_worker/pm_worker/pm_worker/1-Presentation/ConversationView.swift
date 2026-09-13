//
//  ConversationView.swift
//  pm_worker
//
//  中栏对话视图（参考 Trae 对话版式）：
//  vibrancy 顶栏（返回/项目名/版本下拉/会话胶囊/目标/本月成本）
//  + 消息流（720 居中 · AI 回答 = 头像名称行 + hairline + 纯文字正文（无卡片壳）
//    · 用户深反气泡 · 系统居中胶囊）
//  + 输入区（radius 16 浮起输入卡两段式：附件 + 记下来 + 模型 chip + 品牌紫发送钮）。
//  会话窗口是 discussions.jsonl 的视图投影（design.md §5.1.1）。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 阶段 → 原型 STAGES 映射（① 蓝 / ② 品牌紫 / ③ 琥珀 / ④ 绿；名称行统一缀 Agent）

extension PipelineRun.Stage {
    /// 原型 STAGES 查表项：编号 / 名称 / Agent / 主色 / 浅底。
    var proto: (num: String, name: String, agent: String, color: Color, surface: Color) {
        switch self {
        case .clarify:
            return ("①", "需求澄清", "Agent", Color.statusPrimary, Color.statusPrimarySurface1)
        case .structure:
            return ("②", "结构设计", "Agent", Color.brandAccent, Color.brandPopup)
        case .prototype:
            return ("③", "原型生成", "Agent", Color.statusWarning, Color.statusWarningSurface1)
        case .prd:
            return ("④", "PRD 撰写", "Agent", Color.statusSuccess, Color.statusSuccessSurface1)
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store: SessionStore
    @ObservedObject private var pipeline: PipelineEngine
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    /// 记忆抽屉（Task 4.7）：头部 brain 按钮 → 右缘滑出浮动卡。
    @State private var showMemoryDrawer = false
    /// 瞬态提示。
    @State private var notif: DSNotifMessage?
    /// 深浅色切换过渡动画的值锚点（对话框平滑变色的观察源）。
    @Environment(\.colorScheme) private var colorScheme
    /// 待发送附图（已拷入 attachments/，文件名引用 + 缩略预览）。
    @State private var pendingImages: [PendingImage] = []
    /// 吸底跟随开关：流式增量只在「视口本就在底部」时自动跟随。
    /// 用户向上滚动（滚轮/触控板/键盘）即解除，滚回底部或新回合开始时恢复——
    /// 否则每个 token 的 scrollTo 会把视口钉死在底部，表现为「AI 思考时无法向上滚动」。
    @State private var stickToBottom = true
    /// 最近一次滚动几何的「距底部距离」（pt），供滚动阶段收束时提交吸底判定。
    @State private var distanceFromBottom: CGFloat = 0
    /// 用户正在主动滚动（滚轮/触控板/惯性）——期间实时提交吸底判定。
    @State private var inUserScroll = false

    private let project: String
    private let version: String
    private let sessionId: String

    init(model: AppModel, project: String, version: String, sessionId: String) {
        // 不在 init 切数据源：本视图在 body 求值中被创建，此时改 @Published 会触发
        // "Publishing changes from within view updates"。数据源已由 AppModel.selection
        // 的 didSet 在赋值动作中提前切换（先于本次 body 重算，首帧数据有保障）。
        self.store = model.sessionStore
        self.pipeline = model.pipeline
        self.project = project
        self.version = version
        self.sessionId = sessionId
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            if model.currentVersionReleased {
                ReleaseBanner(version: version, onOpenNotes: openReleaseNotes)
                    .padding(.horizontal, DS.Spacing.s12)
                    .padding(.top, DS.Spacing.s8)
            }
            messageList
            if !model.recommendations.isEmpty, !store.isStreaming {
                RecommendationStrip(
                    recommendations: model.recommendations,
                    onAdopt: { model.adoptRecommendation($0) },
                    onReject: { model.rejectRecommendation($0) }
                )
                DSDivider()
            }
            if let target = model.confirmTarget, !store.isStreaming {
                ConfirmDock(model: model, target: target)
                DSDivider()
            }
            inputBar
        }
        .frame(minWidth: 480)
        .background(Color.surfaceBase)
        .dsNotifCenter($notif)
        // 阶段开始 / 切换 → 主动推荐刷新（Task 4.5：阶段开始扫描卡片库 1-3 个）
        .task { await model.refreshRecommendations() }
        .onChange(of: pipeline.stage) { _, _ in
            Task { await model.refreshRecommendations() }
        }
        // 「这条记下来」归属分流弹窗（E10）
        .sheet(isPresented: bookmarkSheetPresented) {
            if let text = model.bookmarkDraft {
                KnowledgeCaptureSheet(
                    isPresented: bookmarkSheetPresented,
                    initialText: text
                ) { capture in
                    Task { await model.saveBookmark(capture) }
                }
            }
        }
        // 记忆抽屉：右缘滑出 .ds-drawer 浮动卡（360 宽 r12 大软影，无背板不挡输入）
        .overlay(alignment: .trailing) {
            if showMemoryDrawer {
                MemoryDrawerView(onClose: toggleMemoryDrawer)
                    .environmentObject(model)
                    .padding(.vertical, DS.Spacing.s12)
                    .padding(.trailing, DS.Spacing.s12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// bookmarkDraft ≠ nil → 弹窗展示（收起 = cancelBookmarkCapture）。
    private var bookmarkSheetPresented: Binding<Bool> {
        Binding(
            get: { model.bookmarkDraft != nil },
            set: { shown in if !shown { model.cancelBookmarkCapture() } }
        )
    }

    /// 查看封板 release-notes（系统默认 Markdown 编辑器打开）。
    private func openReleaseNotes() {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("07-reports/release-notes.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 顶栏（原型 vibrancy 44 高：返回 · 项目名 · 版本下拉 · 会话胶囊 · 目标 · 成本）

    private var header: some View {
        HStack(spacing: DS.Spacing.s10) {
            // 返回首页（原型 goHome）
            Button {
                model.selection = .newTask
            } label: {
                DSIcon(.arrowLeft, size: 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink500)
            .help("返回首页")

            DSIcon(.folder, size: 14)
                .foregroundStyle(Color.ink500)

            Text(project)
                .font(DS.Font.bodyMDStrong)
                .foregroundStyle(Color.ink900)

            versionMenu

            sessionChip

            if pipeline.prdStale {
                DSTag(title: "PRD 已过期", variant: .warning)
            }

            if let goal = projectGoal, !goal.isEmpty {
                Text(goal)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink300)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DS.Spacing.s8)

            // 记忆抽屉入口（Task 4.7）：查看当前上下文有效记忆与覆盖链历史
            Button {
                toggleMemoryDrawer()
            } label: {
                DSIcon(.mem, size: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink700)
            .help("记忆抽屉：当前上下文有效记忆（版本 / 项目 / 全局）+ 失效覆盖链")

            // 本月成本入口（原型 v4.16：点击开设置弹框「模型」页，与用量面板同口径）
            Button {
                model.settingsPage = .model
                model.settingsPresented = true
            } label: {
                Text(monthCostText)
                    .font(DS.Font.monoSM)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink300)
            .help("本月模型费用 · 点击打开设置")
        }
        .padding(.horizontal, DS.Spacing.s16)
        .frame(height: 44)
    }

    /// 记忆抽屉开合（右缘滑出 / 收回，动画驱动 transition）。
    private func toggleMemoryDrawer() {
        withAnimation(DS.Motion.spring) { showMemoryDrawer.toggle() }
    }

    /// 项目下的版本列表（含封板态，用于顶栏下拉）。
    private var versionNodes: [VersionNode] {
        model.projects.first { $0.name == project }?.versions ?? []
    }

    /// 版本切换（原型 select）：mono 边框胶囊；封板版本警示色 + 只读标注。
    private var versionMenu: some View {
        Menu {
            ForEach(versionNodes) { node in
                Button {
                    switchVersion(node.name)
                } label: {
                    if node.isReleased {
                        Text("\(node.displayName) · 只读")
                    } else {
                        Text(node.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.s4) {
                Text(currentVersionNode?.displayName ?? version)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(
                        // 坑：三元必须写全类型，隐式成员语法会让重载解析崩溃
                        model.currentVersionReleased ? Color.statusWarning : Color.ink700
                    )
                DSIcon(.down, size: 10)
                    .foregroundStyle(Color.ink300)
            }
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.vertical, DS.Spacing.s3)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(Color.surfaceBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换版本（封板版本只读）")
    }

    private var currentVersionNode: VersionNode? {
        versionNodes.first { $0.name == version }
    }

    /// 切版本：目标版本有会话 → 打开其最近活跃会话；否则进项目主页。
    private func switchVersion(_ target: String) {
        guard target != version else { return }
        let sessions = SessionStore.sessions(in: project, version: target)
        if let latest = sessions.first {
            model.selection = .session(project: project, version: target, sessionId: latest.id)
        } else {
            model.selection = .projectHome(project)
        }
    }

    /// 当前会话胶囊（原型第三层节点：run 状态点 + 标题，边框胶囊 maxWidth 240）。
    private var sessionChip: some View {
        HStack(spacing: DS.Spacing.s6) {
            Circle()
                .fill(Color.brand600)
                .frame(width: 5, height: 5)
            Text(sessionTitle)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink700)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, DS.Spacing.s10)
        .padding(.vertical, DS.Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .frame(maxWidth: 220)
        .help(sessionTitle)
    }

    private var sessionTitle: String {
        let all = SessionStore.sessions(in: project, version: version)
        return all.first { $0.id == sessionId }?.title ?? "（空会话）"
    }

    private var projectGoal: String? {
        try? PMAgentStore.readProject(project)?.goalStatement
    }

    /// 本月模型费用（CostTracker JSONL 月聚合，与用量面板同口径）。
    private var monthCostText: String {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        let agg = CostTracker.shared.month(year: comps.year ?? 0, month: comps.month ?? 0)
        return String(format: "本月 ¥%.2f", agg.costCNY)
    }

    // MARK: - 消息流（纯文字回答块 · maxWidth 720 居中 · 消息间距 24 呼吸感）

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                    if store.entries.isEmpty && !store.isStreaming {
                        emptyState
                    }
                    ForEach(displayItems) { item in
                        MessageBubble(
                            entry: item.entry,
                            stage: pipeline.stage,
                            showOptions: isLastAssistant(item.entry),
                            headerNotes: item.headerNotes,
                            footerNotes: item.footerNotes,
                            project: project,
                            version: version
                        )
                        .dsSlideIn()
                        .id(item.entry.id)
                    }
                    if store.isStreaming {
                        streamingBubble
                            .dsSlideIn()
                            .id("streaming")
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Spacing.s20)
                .padding(.horizontal, DS.Spacing.s32)
                .padding(.bottom, DS.Spacing.s12)
            }
            .onChange(of: store.entries.count) { _, _ in
                guard stickToBottom else { return }
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
            .onChange(of: store.streamingText) { _, _ in
                guard stickToBottom else { return }
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: store.isStreaming) { old, new in
                // 新回合开始（发送 / 采纳推荐 / 确认推进）→ 恢复吸底跟随
                if !old && new { stickToBottom = true }
            }
            // 吸底跟随的解锁机制：
            // - 几何变化只记录「距底距离」；用户主动滚动期间实时提交（拖离底部即停跟随，
            //   拖回底部即恢复），流式内容增长不属于用户滚动、不提交（由上方 onChange 追赶）。
            // - 滚动收束回 idle 时统一提交判定，覆盖键盘方向键滚动（走 .animating，结束落点
            //   即用户意图位置）与惯性减速结束。
            // - .animating 不算用户滚动——我们自己的 scrollTo 也走该阶段，避免误关跟随。
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                let maxOffset = geo.contentSize.height
                    + geo.contentInsets.top + geo.contentInsets.bottom
                    - geo.containerSize.height
                return maxOffset - geo.contentOffset.y
            } action: { _, newDistance in
                distanceFromBottom = newDistance
                if inUserScroll {
                    stickToBottom = newDistance <= 32
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle {
                    inUserScroll = false
                    stickToBottom = distanceFromBottom <= 32
                } else if phase != .animating {
                    inUserScroll = true
                }
            }
        }
    }

    /// 空态（原型：居中图标 + 会话未开始 + 副文案）。
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.s6) {
            DSIcon(.chat, size: 26)
                .foregroundStyle(Color.ink300)
                .padding(.bottom, DS.Spacing.s4)
            Text("会话「\(sessionTitle)」尚未开始")
                .font(DS.Font.bodyMD)
                .foregroundStyle(Color.ink500)
            Text("发送第一条消息，结论与决策会自动沉淀到该项目")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.s48)
    }

    /// 流式中的 AgentShell（思考 spinner + 增量文本）。
    private var streamingBubble: some View {
        AgentMessageShell(stage: pipeline.stage, time: nil) {
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                // 回合注记（阶段推进/切档）在流式开始时即并入气泡顶部
                ForEach(Array(streamingHeaderNotes.enumerated()), id: \.offset) { _, note in
                    TurnNoteRow(note: note)
                }
                // 原型：思考中 spinner + 流光扫字；文本开始输出后仅展示增量
                if store.streamingThink.isEmpty && store.streamingText.isEmpty {
                    ThinkingCard(data: nil)
                } else if !store.streamingThink.isEmpty {
                    ThinkingCard(data: nil)
                }
                if !store.streamingText.isEmpty {
                    // 与最终消息同构的产物渲染；进行中的产物块（原型 HTML 等长代码）
                    // 收进生成进度卡，不再原样刷屏
                    StreamingContentBody(
                        text: store.streamingText,
                        project: project,
                        version: version
                    )
                }
            }
        }
    }

    private func isLastAssistant(_ entry: DiscussionEntry) -> Bool {
        guard entry.role == .assistant, pipeline.stage == .clarify else { return false }
        return entry.id == store.entries.last(where: { $0.role == .assistant })?.id
    }

    // MARK: - 系统事件三分层（独立可见 / 融入回答 / 静默）

    /// 渲染项：一条可见条目 + 已并入其气泡的系统注记。
    private struct DisplayItem: Identifiable {
        let entry: DiscussionEntry
        let headerNotes: [TurnNote]
        let footerNotes: [TurnNote]
        var id: String { entry.id }
    }

    /// 系统事件降噪分层：
    /// ① 记忆行（memory 载荷）静默——照常落盘可回溯，UI 不渲染（记忆抽屉承载）；
    /// ② 推进/切档/产物/决策记录注记并入相邻 AI 回答气泡内部；
    /// ③ 警告、闸口拦截、风险命中等必须独立可见的，保留为独立事件条。
    private var displayItems: [DisplayItem] {
        let entries = store.entries
        var items: [DisplayItem] = []
        for (index, entry) in entries.enumerated() {
            if entry.role == .system && entry.memory != nil { continue }
            if entry.role == .assistant {
                items.append(DisplayItem(
                    entry: entry,
                    headerNotes: MessageBubble.mergeableNotes(before: index, in: entries),
                    footerNotes: MessageBubble.mergeableNotes(after: index, in: entries)
                ))
            } else {
                items.append(DisplayItem(entry: entry, headerNotes: [], footerNotes: []))
            }
        }
        return items
    }

    /// 流式回合的注记：entries 尾部连续可并入的系统行（回合开始即并入，无「独立胶囊→并入」闪烁）。
    private var streamingHeaderNotes: [TurnNote] {
        MessageBubble.mergeableNotes(before: store.entries.count, in: store.entries)
    }

    // MARK: - 输入区（对话框组件 · 参考图 Trae 输入卡两段式布局）

    /// 输入卡：radius 16 浮起卡（composerSurface）+ 渐进描边（idle L1 → focus L3）
    /// + 贴地阴影；卡内自上而下 = 待发附图条 → 编辑区 → 工具栏
    /// （左：附件 + / 记下来 · 右：当前模型 → 设置模型页 / 发送钮 32×32 r10 品牌紫）。
    /// 深浅色由 DS 动态令牌承载，卡上挂 colorScheme 动画保证切换平滑过渡。
    private var inputBar: some View {
        VStack(spacing: 0) {
            // 待发送附图条（卡内顶部：缩略图 + 移除钮；附件按钮添加进来）
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.s8) {
                        ForEach(pendingImages) { image in
                            PendingImageChip(image: image) {
                                pendingImages.removeAll { $0.id == image.id }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.s2)
                    .padding(.bottom, DS.Spacing.s8)
                }
            }

            inputEditor

            HStack(spacing: DS.Spacing.s8) {
                // 附件：模型支持图片时选图发送，否则引导去设置开启
                ComposerIconButton(
                    icon: .plus, size: 13,
                    // brand 收敛：附件钮恒中性（是否支持图片走 help 说明），发送钮是
                    // 输入卡唯一品牌色
                    tint: Color.ink700,
                    help: model.settings.chatConfig.supportsImages
                        ? "添加图片（截图 / 竞品界面 / 原型稿）"
                        : "当前模型未开启图片输入——设置（⌘,）→ 模型 → 支持图片输入"
                ) {
                    attachImage()
                }

                // 「这条记下来」（Task 4.4）：草稿（空则最近一条助手回复）→ 归属分流弹窗
                ComposerBarChip(
                    help: "这条记下来：沉淀为方法论卡片或经验记忆（归属分流，默认判定可改）",
                    action: { model.startBookmarkCapture(draft) }
                ) {
                    DSIcon(.star, size: 11)
                    Text("记下来")
                        .font(DS.Font.bodySMStrong)
                }
                .disabled(store.isStreaming)

                Spacer(minLength: DS.Spacing.s8)

                // 当前对话模型（统一 AI 配置入口）→ 设置「模型」页
                ComposerBarChip(
                    help: "当前对话模型 · 点击打开设置（⌘,）→ 模型",
                    showsChevron: true,
                    action: {
                        model.settingsPage = .model
                        model.settingsPresented = true
                    }
                ) {
                    Text(model.settings.chatConfig.model)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink700)
                }

                ComposerSendButton(enabled: canSend && !store.isStreaming) {
                    send()
                }
            }
            .padding(.top, DS.Spacing.s6)
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.top, DS.Spacing.s12)
        .padding(.bottom, DS.Spacing.s10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.big)
                .fill(Color.composerSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.big)
                .strokeBorder(
                    // 坑：三元必须写全类型
                    inputFocused ? Color.borderL3 : Color.borderL1,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.big))
        .dsShadow(.card)
        // Xcode 语义焦点环：accent 环绕取代描边式焦点（P0-①）
        .dsFocusRing(focused: inputFocused, radius: DS.Radius.big)
        // 深浅色切换平滑过渡（与 appAppearance 根 0.28s 交叉淡化同参数）
        .animation(.easeInOut(duration: 0.28), value: colorScheme)
        // 响应式：与消息流同列宽（720 + 64 页边距）居中，窄窗口随 min 480 收缩
        .frame(maxWidth: 720 + DS.Spacing.s64)
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Spacing.s10)
        .padding(.horizontal, DS.Spacing.s32)
        .padding(.bottom, DS.Spacing.s16)
    }

    /// 编辑区：占位左上（composerPlaceholder AA 达标）+ 随内容增高
    /// （字号与用户气泡同为 chatBase 16，所见即所得）。
    private var inputEditor: some View {
        TextEditor(text: $draft)
            .font(DS.Font.chatBase)
            .foregroundStyle(Color.ink900)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(inputPlaceholder)
                        .font(DS.Font.chatBase)
                        .foregroundStyle(Color.composerPlaceholder)
                        .padding(.top, DS.Spacing.s4)
                        .padding(.leading, DS.Spacing.s4)
                        .allowsHitTesting(false)
                }
            }
            .focused($inputFocused)
            .onKeyPress { press in
                // ⏎ 直接发送（⇧⏎ 换行）；不可发送时回车保持系统换行行为
                guard press.key == .return,
                      press.phase == .down,
                      !press.modifiers.contains(.shift),
                      canSend,
                      !store.isStreaming
                else { return .ignored }
                send()
                return .handled
            }
    }

    /// 占位文案（原型：pending 时提示「进入下一阶段」等价确认，否则每轮一问）。
    private var inputPlaceholder: String {
        if model.confirmTarget != nil {
            return "回复 Agent…（说「进入下一阶段」等价确认）"
        }
        return "回复 Agent…（\(pipeline.stage.proto.num) 每轮只问一个最关键的问题）"
    }

    /// 可发送：有文本或有待发附图（纯图消息也允许）。
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingImages.isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !text.isEmpty || !images.isEmpty, !store.isStreaming else { return }
        draft = ""
        pendingImages = []

        // 自由作答「进入下一个阶段」等价选①（design.md §6.1）
        if model.confirmTarget != nil && !text.isEmpty
            && AppModel.isAdvanceIntent(text) && images.isEmpty {
            Task { await model.confirmCurrentStage() }
            return
        }
        Task {
            await model.sendMessage(text, imageFiles: images.map(\.fileName))
        }
    }

    // MARK: - 附图选择（模型开启图片输入后可用）

    private func attachImage() {
        guard model.settings.chatConfig.supportsImages else {
            notif = DSNotifMessage(
                variant: .info,
                title: "当前模型未开启图片输入",
                description: "到 设置（⌘,）→ 模型 → 打开「支持图片输入」，并确认所用模型具备视觉能力"
            )
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.message = "可选多张：截图 / 竞品界面 / 原型稿"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            guard let name = try? PMAgentStore.saveAttachment(
                data: data, fileExtension: ext, project: project, version: version
            ) else { continue }
            pendingImages.append(
                PendingImage(fileName: name, preview: NSImage(data: data))
            )
        }
    }
}

// MARK: - AgentShell（参考 Trae 对话：22px 阶段头像 + 名称行 + hairline 分隔 + 纯文字正文，无卡片壳）

struct AgentMessageShell<Content: View>: View {
    let stage: PipelineRun.Stage
    /// 名称行时间（HH:mm）；nil → 流式中不显示。
    let time: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 名称行：头像 + 阶段名（600）+ Agent 名（mono tertiary）+ 时间（mono tertiary）
            HStack(spacing: DS.Spacing.s8) {
                StageAvatar(stage: stage, size: 22)
                Text(stage.proto.name)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                Text(stage.proto.agent)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
                if let time {
                    Text(time)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink300)
                }
            }
            // 名称行下的 hairline：行距 8 / 线到正文 12（参考图非对称节奏，精确控制）
            DSDivider()
                .padding(.top, DS.Spacing.s8)
            // 正文：纯文字直接铺在画布上（无背景 / 无描边 / 无限宽收缩），层级靠排版
            content
                .padding(.top, DS.Spacing.s12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    init(
        stage: PipelineRun.Stage,
        time: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.stage = stage
        self.time = time
        self.content = content()
    }
}

/// 阶段头像（原型 Avatar：阶段浅底 + 阶段号，26px 圆形）。
struct StageAvatar: View {
    let stage: PipelineRun.Stage
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(stage.proto.surface)
            .frame(width: size, height: size)
            .overlay {
                Text(stage.proto.num)
                    .font(.system(size: max(9, size * 0.46), weight: .semibold))
                    .foregroundStyle(stage.proto.color)
            }
    }
}

// MARK: - 主动推荐条（Task 4.5，E23）

/// 主动推荐条（阶段开始扫描卡片库推荐 1-3 个方法论，
/// 含理由、可采纳（实战注记 + 记忆校准）、可拒绝（同阶段不再重复）。
struct RecommendationStrip: View {
    let recommendations: [Recommender.Recommendation]
    var onAdopt: (String) -> Void
    var onReject: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.aiStars, size: 11)
                    .foregroundStyle(Color.ink700)
                Text("主动推荐 · \(recommendations.count) 个方法论（本阶段可能用得上）")
                    .font(DS.Font.bodySMStrong)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink500)
            }

            ForEach(recommendations) { rec in
                HStack(alignment: .top, spacing: DS.Spacing.s8) {
                    VStack(alignment: .leading, spacing: DS.Spacing.s3) {
                        Text(rec.title)
                            .font(DS.Font.bodyBaseStrong)
                            .foregroundStyle(Color.ink900)
                            .lineLimit(1)
                        Text(rec.reason)
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Spacing.s8)
                    Button {
                        onAdopt(rec.id)
                    } label: {
                        Text("采纳")
                    }
                    .buttonStyle(.ds(.secondary, size: .xs))
                    .help("采纳：卡片实战注记 +1（带项目出处与日期），并注入你的历史使用倾向")

                    Button {
                        onReject(rec.id)
                    } label: {
                        Text("不适用")
                    }
                    .buttonStyle(.ds(.ghost, size: .xs))
                    .help("本阶段不再重复推荐该方法论")
                }
                .padding(DS.Spacing.s8)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .fill(Color.surfaceSecondary)
                )
            }
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s8)
    }
}

// MARK: - 单条消息（用户深反气泡 / 助手 AgentShell / 系统事件条）

/// 回合注记（脱 emoji 后的文本 + 语义图标与着色，融入 AI 回答气泡内部）。
struct TurnNote {
    let text: String
    let icon: DSIcon.Name
    let tint: Color
}

/// 回合注记行（安静 meta 行：12px 图标 + bodyXS 次要文字，不与正文争夺注意力）。
struct TurnNoteRow: View {
    let note: TurnNote

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s6) {
            DSIcon(note.icon, size: 12)
                .foregroundStyle(note.tint)
                .padding(.top, 2)
            Text(note.text)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MessageBubble: View {
    let entry: DiscussionEntry
    /// 助手消息的阶段（决定头像与名称行）。
    var stage: PipelineRun.Stage = .clarify
    /// 澄清阶段末条 assistant：选项以点选 chip 呈现。
    var showOptions: Bool = false
    /// 融入气泡顶部的回合注记（阶段推进/切档/进度）。
    var headerNotes: [TurnNote] = []
    /// 融入气泡底部的注记（产物落盘/决策记录）。
    var footerNotes: [TurnNote] = []
    /// 附图归属（attachments/ 定位；空串时附图不渲染，仅文本）。
    var project: String = ""
    var version: String = ""

    /// 产物 chip 点击后的预览目标（md → Mermaid 渲染 / html → 原型预览）。
    @State private var previewTarget: FileNode?

    var body: some View {
        Group {
            switch entry.role {
            case .user:
                userBubble
            case .assistant:
                AgentMessageShell(stage: stage, time: hhmm(entry.createdAt)) {
                    assistantContent
                }
            case .system:
                systemPill
            }
        }
        .sheet(item: $previewTarget) { node in
            if node.url.pathExtension.lowercased() == "html" {
                HTMLPreviewSheet(title: node.name, fileURL: node.url)
            } else {
                MermaidPreviewSheet(title: node.name, fileURL: node.url)
            }
        }
    }

    /// 用户气泡（原型：深反色底白字，radius 12 + 右下角 4，maxWidth 72%，无时间戳）。
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                // 附图缩略（点按放大预览原图）
                if let files = entry.images, !files.isEmpty, !project.isEmpty {
                    HStack(spacing: DS.Spacing.s6) {
                        ForEach(files, id: \.self) { file in
                            if let nsImage = Self.loadAttachmentImage(
                                file, project: project, version: version
                            ) {
                                AttachmentThumbnail(image: nsImage, size: 96)
                            }
                        }
                    }
                }
                if !entry.content.isEmpty {
                    Text(entry.content)
                        .font(DS.Font.chatBase)
                        .foregroundStyle(Color.white)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: DS.Radius.xxl,
                    bottomLeadingRadius: DS.Radius.xxl,
                    bottomTrailingRadius: DS.Radius.sm,
                    topTrailingRadius: DS.Radius.xxl
                )
                // 原型 userBubble：浅 ink900 深底 / Dark --bg-invert #32323A，白字
                .fill(Color.userBubble)
            )
        }
    }

    /// 读 attachments/ 图片（文件缺失/超时返回 nil，消息降级纯文本）。
    nonisolated private static func loadAttachmentImage(
        _ file: String, project: String, version: String
    ) -> NSImage? {
        guard let data = PMAgentStore.readAttachment(
            file, project: project, version: version
        ) else { return nil }
        return NSImage(data: data)
    }

    /// 独立系统事件条（左对齐紧凑胶囊：语义图标着色 + 状态底色，只承载必须独立可见的事件）。
    private var systemPill: some View {
        let style = Self.eventChipStyle(entry.content)
        return HStack(spacing: 0) {
            HStack(alignment: .top, spacing: DS.Spacing.s8) {
                DSIcon(style.icon, size: 12)
                    .foregroundStyle(style.tint)
                    .padding(.top, 2)
                Text(Self.stripEventEmoji(entry.content))
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(style.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(Color.borderL1, lineWidth: 1)
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        let blocks = ArtifactParser.parseArtifactBlocks(in: entry.content)
        let displayText = blocks.isEmpty
            ? entry.content
            : ArtifactParser.stripArtifactBlocks(
                in: entry.content,
                placeholder: "（产物已生成并落盘——点击下方标签预览，或见右栏「产物」面板）",
                // 所有产物块不插正文占位：图表块直接渲染，其余块底部有胶囊提示，
                // 避免多条块落多条重复引导文字
                placeholderFor: { _ in "" }
            )

        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            // 回合注记（阶段推进/切档）：并入气泡顶部的安静 meta 行
            ForEach(Array(headerNotes.enumerated()), id: \.offset) { _, note in
                TurnNoteRow(note: note)
            }
            if let think = entry.think {
                ThinkingCard(data: think)
            }
            // Markdown 渲染：标题/粗斜体/列表/代码块/表格/引用分层排版
            MarkdownText(displayText)

            // 产物区：图表内联渲染 + 文件产物卡片（与流式视图共用同一渲染）
            ArtifactBlocksSection(
                blocks: blocks,
                project: project,
                version: version,
                onOpen: { previewTarget = $0 }
            )

            // 产物/决策注记：并入气泡底部（紧跟本条回复的系统事实）
            ForEach(Array(footerNotes.enumerated()), id: \.offset) { _, note in
                TurnNoteRow(note: note)
            }

            // 澄清选项点选（每轮一问的候选，点选即发送）
            if showOptions, let options = ArtifactParser.parseClarifyOptions(in: entry.content) {
                OptionChips(options: options.options)
            }
        }
    }

    /// ISO8601 → 本地 HH:mm（原型名称行时间；解析失败回退原串前 5 位）。
    private func hhmm(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        if let date = Self.isoParser.date(from: iso) {
            return Self.hhmmFormatter.string(from: date)
        }
        return nil
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: 系统事件分类（渲染分层的数据侧判据）

    /// 可并入相邻 AI 回答的注记（推进 ✅、切档 🎚️、进度（历史数据）、产物 📦、决策记录）。
    /// 返回 nil → 独立事件条。
    fileprivate static func turnNote(from content: String) -> TurnNote? {
        if content.hasPrefix("✅") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .circleCheck, tint: .statusSuccess
            )
        }
        if content.hasPrefix("🎚️") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .arrowSwap, tint: .statusPrimary
            )
        }
        if content.hasPrefix("🏗️") || content.hasPrefix("🎨") || content.hasPrefix("📝 开始") {
            // 历史会话的进度胶囊（新代码已并入回合注记，不再单独发）
            return TurnNote(
                text: stripEventEmoji(content), icon: .aiStars, tint: .ink500
            )
        }
        if content.hasPrefix("📦") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .fileUpload, tint: .ink500
            )
        }
        if content.hasPrefix("📝 已沉淀") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .bookmark, tint: .ink500
            )
        }
        return nil
    }

    /// assistant 前方连续可并入的系统行 → 顶部注记；遇到不可并入行 / 非系统行 / 记忆行即停。
    fileprivate static func mergeableNotes(
        before index: Int, in entries: [DiscussionEntry]
    ) -> [TurnNote] {
        var notes: [TurnNote] = []
        var i = index - 1
        while i >= 0,
              entries[i].role == .system, entries[i].memory == nil,
              let note = turnNote(from: entries[i].content) {
            notes.insert(note, at: 0)
            i -= 1
        }
        return notes
    }

    /// assistant 后方连续可并入的系统行 → 底部注记（停止条件同上）。
    fileprivate static func mergeableNotes(
        after index: Int, in entries: [DiscussionEntry]
    ) -> [TurnNote] {
        var notes: [TurnNote] = []
        var i = index + 1
        while i < entries.count,
              entries[i].role == .system, entries[i].memory == nil,
              let note = turnNote(from: entries[i].content) {
            notes.append(note)
            i += 1
        }
        return notes
    }

    /// 本应用系统行使用的事件 emoji（含变体选择符，按 Character 整体匹配）。
    fileprivate static let eventEmojis: Set<String> = [
        "✅", "⚠️", "🏗️", "🎨", "📝", "🎚️", "📦", "📊", "🔍", "🔒", "🔄", "💀", "🗃️", "🔀", "📌"
    ]

    /// 脱前导事件 emoji 与随后的一个空格（注记/事件条统一走 DSIcon，不用 emoji 本体）。
    fileprivate static func stripEventEmoji(_ text: String) -> String {
        let chars = Array(text)
        var i = 0
        while i < chars.count, eventEmojis.contains(String(chars[i])) { i += 1 }
        if i < chars.count, chars[i] == " " { i += 1 }
        return String(chars[i...])
    }

    /// 独立事件条的语义样式（图标 / 前景 / 底色，全 DS 动态令牌，深浅色自适应）。
    fileprivate static func eventChipStyle(
        _ content: String
    ) -> (icon: DSIcon.Name, tint: Color, bg: Color) {
        if content.hasPrefix("⚠️") {
            return (.warningFill, Color.statusWarning, Color.statusWarningSurface1)
        }
        if content.hasPrefix("💀") {
            return (.skull, Color.statusError, Color.statusErrorSurface1)
        }
        if content.hasPrefix("🔒") {
            return (.lock, Color.statusPrimary, Color.statusPrimarySurface1)
        }
        if content.hasPrefix("🔄") {
            return (.arrowSwap, Color.statusPrimary, Color.statusPrimarySurface1)
        }
        if content.hasPrefix("✅") {
            return (.circleCheck, Color.statusSuccess, Color.statusSuccessSurface1)
        }
        if content.hasPrefix("📌") {
            return (.bookmark, Color.ink500, Color.surfaceSecondary)
        }
        if content.hasPrefix("🗃️") {
            return (.books, Color.ink500, Color.surfaceSecondary)
        }
        if content.hasPrefix("🔀") {
            return (.arrowSwap, Color.ink500, Color.surfaceSecondary)
        }
        if content.hasPrefix("📦") {
            return (.fileUpload, Color.ink500, Color.surfaceSecondary)
        }
        if content.hasPrefix("📊") {
            return (.barList, Color.ink500, Color.surfaceSecondary)
        }
        if content.hasPrefix("🔍") {
            return (.search, Color.ink500, Color.surfaceSecondary)
        }
        return (.dot, Color.ink500, Color.surfaceSecondary)
    }
}

/// 可点击产物 chip（文件类产物 → 点击打开预览）：link 语义 brandAccent +
/// hover 底色升阶（与右栏产物树可点文件同语义）。
private struct ArtifactChipButton: View {
    let title: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.fileUpload, size: 11)
                Text(title)
                    .font(DS.Font.bodySM)
            }
            .foregroundStyle(Color.brandAccent)
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(hovered ? Color.overlayL1 : Color.surfaceSecondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help("点击预览")
    }
}

// MARK: - 产物区（最终消息与流式共用：图表内联渲染 + 文件产物卡片）

/// artifact 块名 → 产物中文名（未知块名兜底「产物」）。
private func artifactDisplayName(_ name: String) -> String {
    switch name {
    case "architecture": "功能架构图"
    case "core-flows": "核心流程图"
    case "module-page-map": "模块-页面映射表"
    case "business-flows": "业务流程图"
    case "prototype": "交互原型"
    case "prd": "产品需求文档"
    case "analysis": "竞品分析报告"
    case "radar": "漏项雷达"
    case "decision": "决策记录"
    default: "产物"
    }
}

/// artifact 块名 → 已落盘产物文件 URL（与 ArtifactParser 落盘规则一一对应；
/// 文件不存在（business-flows 可选产物 / radar/decision 落 jsonl / 流式未落盘）返回 nil）。
private func artifactFileURL(_ name: String, project: String, version: String) -> URL? {
    let relativePath: String?
    switch name {
    case "architecture": relativePath = "02-structure/architecture.md"
    case "core-flows": relativePath = "02-structure/core-flows.md"
    case "module-page-map": relativePath = "02-structure/module-page-map.md"
    case "business-flows": relativePath = "02-structure/business-flows.md"
    case "prototype": relativePath = "03-prototypes/prototype-v1.html"
    case "prd": relativePath = "04-prd/prd-v1.md"
    case "analysis": relativePath = "05-analysis/competitive-analysis.md"
    default: relativePath = nil  // radar/decision 落 jsonl，右栏 Tab 承载
    }
    guard let relativePath, !project.isEmpty, !version.isEmpty else { return nil }
    let url = PMAgentStore.versionURL(project: project, version: version)
        .appendingPathComponent(relativePath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// 产物块渲染区：结构图表（architecture/core-flows/business-flows = mermaid 图源，
/// module-page-map = 管道表格 markdown）内联直接渲染；文件类产物出卡片/chip（点击预览）。
/// 流式中文件尚未落盘（onOpen = nil）→ 纯提示胶囊降级。
private struct ArtifactBlocksSection: View {
    let blocks: [ArtifactParser.ArtifactBlock]
    var project: String = ""
    var version: String = ""
    /// 点击文件产物卡片 → 打开预览；nil = 非交互提示态（流式中）
    var onOpen: ((FileNode) -> Void)? = nil

    /// 内容为空（异常流）→ 退回 chip 兜底。
    private func isInlineChart(_ block: ArtifactParser.ArtifactBlock) -> Bool {
        let isChartName: Bool = switch block.name {
        case "architecture", "core-flows", "business-flows", "module-page-map": true
        default: false
        }
        return !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isChartName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            ForEach(blocks.filter(isInlineChart), id: \.name) { block in
                inlineArtifactFigure(block)
            }
            let chipBlocks = blocks.filter { !isInlineChart($0) }
            if !chipBlocks.isEmpty {
                FlowLayout(spacing: DS.Spacing.s6) {
                    ForEach(chipBlocks, id: \.name) { block in
                        chip(block)
                    }
                }
            }
        }
    }

    /// 内联图表卡：mermaid 图（带工具条：源代码切换 / 放大弹窗）或 markdown 表格。
    @ViewBuilder
    private func inlineArtifactFigure(_ block: ArtifactParser.ArtifactBlock) -> some View {
        if block.name == "module-page-map" {
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                HStack(spacing: DS.Spacing.s6) {
                    DSIcon(.table, size: 13)
                        .foregroundStyle(Color.ink500)
                    Text(artifactDisplayName(block.name))
                        .font(DS.Font.bodyMDStrong)
                        .foregroundStyle(Color.ink900)
                }
                MarkdownText(block.content, bodySize: 15)
            }
        } else {
            MermaidFigureCard(
                source: block.content,
                title: artifactDisplayName(block.name),
                icon: .layers
            )
        }
    }

    /// 产物 chip：文件类产物可点击 → 直接打开预览（Mermaid 图渲染 / 原型 HTML）；
    /// 原型是阶段主交付物 → 升级为结果卡（Claude artifacts 式）；
    /// radar/decision 落 jsonl（右栏 Tab 承载），保持纯提示。
    @ViewBuilder
    private func chip(_ block: ArtifactParser.ArtifactBlock) -> some View {
        if let onOpen, let url = artifactFileURL(block.name, project: project, version: version) {
            if block.name == "prototype" {
                PrototypeArtifactCard(fileURL: url) {
                    onOpen(FileNode(
                        name: artifactDisplayName(block.name),
                        url: url,
                        isDirectory: false,
                        children: nil
                    ))
                }
            } else {
                ArtifactChipButton(title: artifactDisplayName(block.name)) {
                    onOpen(FileNode(
                        name: artifactDisplayName(block.name),
                        url: url,
                        isDirectory: false,
                        children: nil
                    ))
                }
            }
        } else {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.fileUpload, size: 11)
                Text(artifactDisplayName(block.name) + "已生成")
                    .font(DS.Font.bodySM)
            }
            // brand 收敛：产物提示是系统事件 → 中性胶囊（与 TurnNoteRow 中性档一致）
            .foregroundStyle(Color.ink700)
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(Color.surfaceSecondary)
            )
        }
    }
}

// MARK: - 原型结果卡（Claude artifacts 式：图标块 + 名称 + 类型/大小元信息 + 预览入口）

private struct PrototypeArtifactCard: View {
    let fileURL: URL
    let onOpen: () -> Void

    @State private var hovered = false

    private var metaText: String {
        let bytes: Int
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int {
            bytes = size
        } else {
            bytes = 0
        }
        let kb = Double(bytes) / 1024
        let sizeText = kb >= 1024
            ? String(format: "%.1f MB", kb / 1024)
            : String(format: "%.1f KB", max(kb, 0.1))
        return "HTML 原型 · \(sizeText)"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: DS.Spacing.s12) {
                DSIcon(.browser, size: 16)
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(Color.brand100)
                    )
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text("交互原型")
                        .font(DS.Font.bodyMDStrong)
                        .foregroundStyle(Color.ink900)
                    Text(metaText)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .monospacedDigit()
                }
                Spacer(minLength: DS.Spacing.s8)
                HStack(spacing: DS.Spacing.s4) {
                    Text("预览")
                        .font(DS.Font.bodySM)
                    DSIcon(.arrowUpRight, size: 11)
                }
                .foregroundStyle(hovered ? Color.brandAccent : Color.ink500)
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(hovered ? Color.overlayL1 : Color.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(hovered ? Color.brand300 : Color.borderL1, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help("点击预览原型（弹窗内置「在浏览器打开」兜底）")
    }
}

// MARK: - 产物生成进度卡（流式中）

/// 流式中未闭合 prototype 块的替身：图标 + 产物名 + 实时已生成行数，
/// 原型 HTML 长代码不再原样刷屏（参考 Claude artifacts「生成中收起内容」）。
private struct ArtifactProgressCard: View {
    let name: String     // artifact 块名；空串 = 块名尚未流完
    let partial: String  // 已生成正文

    private var icon: DSIcon.Name {
        switch name {
        case "prototype": .browser
        case "prd": .document
        case "analysis": .barList
        case "radar": .glasses
        case "decision": .note
        default: .doc
        }
    }

    private var progressText: String {
        guard !partial.isEmpty else { return "正在准备…" }
        let lines = partial.split(separator: "\n", omittingEmptySubsequences: false).count
        return "已生成 \(lines) 行"
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s12) {
            DSIcon(icon, size: 16)
                .foregroundStyle(Color.brandAccent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(Color.brand100)
                )
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text("\(artifactDisplayName(name)) · 正在生成")
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                Text(progressText)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .monospacedDigit()
            }
            Spacer(minLength: DS.Spacing.s8)
            DSPulseDot()
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }
}

// MARK: - 流式正文（与最终消息同构的产物渲染 + 进行中原型进度卡）

/// 流式期间的 AI 正文：已完成 artifact 块与最终消息同构（图表内联 / 产物 chip）。
/// 仅 prototype 启用进度卡（HTML 长代码刷屏无阅读价值）；PRD/竞品分析等
/// 文字型产物保留原文流式，允许边看边读。
private struct StreamingContentBody: View {
    let text: String
    var project: String = ""
    var version: String = ""

    /// （展示文本, 已完成块, 进行中的原型块）
    private func content() -> (
        display: String,
        blocks: [ArtifactParser.ArtifactBlock],
        incomplete: (name: String, partial: String)?
    ) {
        let blocks = ArtifactParser.parseArtifactBlocks(in: text)
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: text)
            .flatMap { $0.name == "prototype" ? $0 : nil }
        var display = blocks.isEmpty
            ? text
            : ArtifactParser.stripArtifactBlocks(in: text, placeholderFor: { _ in "" })
        if incomplete != nil, let marker = display.range(of: "```artifact:", options: .backwards) {
            display = String(display[..<marker.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (display, blocks, incomplete)
    }

    var body: some View {
        let content = content()
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            if !content.display.isEmpty {
                // Markdown 实时渲染（未闭合普通围栏容错到文末）
                MarkdownText(content.display)
            }
            ArtifactBlocksSection(
                blocks: content.blocks,
                project: project,
                version: version,
                onOpen: nil
            )
            if let incomplete = content.incomplete {
                ArtifactProgressCard(name: incomplete.name, partial: incomplete.partial)
            }
        }
    }
}

/// 澄清选项点选 chips（可点选 + 自由输入 + 可跳过——跳过即不选直接输入）。
struct OptionChips: View {
    let options: [String]
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Text("点选作答（或自由输入 / 直接发送消息跳过）")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
            FlowLayout(spacing: DS.Spacing.s6) {
                ForEach(options, id: \.self) { option in
                    Button {
                        guard !model.sessionStore.isStreaming else { return }
                        Task { await model.sendMessage(option) }
                    } label: {
                        Text(option)
                            .font(DS.Font.bodyMD)
                            .lineLimit(1)
                            .padding(.horizontal, DS.Spacing.s10)
                            .padding(.vertical, DS.Spacing.s4)
                            .background(
                                Capsule().fill(Color.brand100)
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.brand300, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ink900)
                }
            }
        }
    }
}

// MARK: - 附图组件（待发送 chips + 气泡缩略图）

/// 待发送附图：attachments/ 文件名引用 + 内存缩略预览（Identifiable 供 ForEach）。
struct PendingImage: Identifiable {
    var id: String { fileName }
    let fileName: String
    let preview: NSImage?
}

/// 待发送附图 chip：48 缩略 + 右上角移除钮（hover 显示）。
struct PendingImageChip: View {
    let image: PendingImage
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let preview = image.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.overlayL2)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(Color.borderL2, lineWidth: 1)
            )

            Button(action: onRemove) {
                DSIcon(.close, size: 8)
                    .foregroundStyle(Color.white)
                    .frame(width: 16, height: 16)
                    // 固定深色遮罩（不随模式反转）：浮于图片上的删除钮双模式均可读
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .offset(x: 6, y: -6)
        }
        .onHover { hovering = $0 }
    }
}

/// 气泡内附图缩略（深底气泡上，白描边 + 可点击用 QuickLook 预览）。
struct AttachmentThumbnail: View {
    let image: NSImage
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
            .onTapGesture {
                // 打开原图（预览窗由系统接管）
                let panel = NSPanel(
                    contentRect: .zero,
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                panel.contentView = NSImageView(image: image)
                panel.title = "图片预览"
                panel.setContentSize(
                    CGSize(
                        width: min(image.size.width, 960),
                        height: min(image.size.height, 720)
                    )
                )
                panel.center()
                panel.makeKeyAndOrderFront(nil)
            }
    }
}

/// 简易流式布局（chips 换行）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 输入卡工具栏组件（对话框 · 参考图 Trae 输入卡底栏）

/// 工具栏图标钮（24×24 · hover 底色升阶 · springFast 反馈）。
/// 深浅色：图标 tint 由调用点给令牌，hover 底走 overlay 阶梯（双模式自适应）。
private struct ComposerIconButton: View {
    let icon: DSIcon.Name
    var size: CGFloat = 13
    var tint: Color = .ink500
    var help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(icon, size: size)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(hovered ? Color.overlayL2 : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help(help)
    }
}

/// 工具栏文字胶囊（图标 + 文本（+ 下拉箭头）· hover 浮起 · springFast）。
/// 文字 tint 语义：装饰性辅助文字走 ink500（配图标），正文语义走 ink700（AA ≥ 6:1）。
private struct ComposerBarChip<Label: View>: View {
    var help: String
    var showsChevron: Bool = false
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(
        help: String,
        showsChevron: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.help = help
        self.showsChevron = showsChevron
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s4) {
                label
                if showsChevron {
                    DSIcon(.down, size: 10)
                        .foregroundStyle(Color.ink500)
                }
            }
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.vertical, DS.Spacing.s6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(hovered && isEnabled ? Color.overlayL1 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help(help)
    }
}

/// 发送钮（32×32 · radius 10 品牌紫方块 + 白 send 图标；禁用 = overlayL3 中性底）。
private struct ComposerSendButton: View {
    let enabled: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(.send, size: 14)
                // 坑：三元必须写全类型
                .foregroundStyle(enabled ? Color.white : Color.ink500)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xl)
                        .fill(
                            enabled
                                // 坑：三元必须写全类型
                                ? (hovered ? Color.brand500 : Color.brand600)
                                : Color.overlayL3
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.xl))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help("发送（⏎ · ⇧⏎ 换行）")
    }
}
