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
import AppKit
import UniformTypeIdentifiers

// MARK: - 阶段 → 原型 STAGES 映射（① 蓝 / ② 品牌紫 / ③ 琥珀 / ④ 绿；名称行统一叫 Agent，阶段身份由头像编号表达）

extension PipelineRun.Stage {
    /// 原型 STAGES 查表项：编号 / 主色 / 浅底。
    var proto: (num: String, color: Color, surface: Color) {
        switch self {
        case .clarify:
            return ("①", Color.statusPrimary, Color.statusPrimarySurface1)
        case .structure:
            return ("②", Color.brandAccent, Color.brandPopup)
        case .prototype:
            return ("③", Color.statusWarning, Color.statusWarningSurface1)
        case .prd:
            return ("④", Color.statusSuccess, Color.statusSuccessSurface1)
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store: SessionStore
    @ObservedObject private var pipeline: PipelineEngine
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    /// IME 组字中（拼音未上屏）：占位文案须一并隐藏（见 IMEComposingDetector）。
    @State private var imeComposing = false
    /// 记忆抽屉（Task 4.7）：头部 brain 按钮 → 右缘滑出浮动卡。
    @State private var showMemoryDrawer = false
    /// 澄清作答抽屉（右缘滑出，记忆抽屉同停靠位互斥）：所有点选作答统一收口。
    /// 待答问题出现自动滑出一次；显式关闭后同问题不再自动滑出（触发 chip 兜底）。
    @State private var showClarifyDrawer = false
    @State private var clarifyAutoOpenedId: String?
    @State private var clarifyDismissedId: String?
    /// 抽屉渲染缓存：提交后 pending 先清（用户消息入库），缓存内容撑完滑出动画。
    /// 常驻隐藏挂载（opacity 0 + 滑出屏 + 禁命中），开销可忽略。
    @State private var clarifyDrawerCache: PendingQuestion?
    /// 瞬态提示。
    @State private var notif: DSNotifMessage?
    /// 深浅色切换过渡动画的值锚点（对话框平滑变色的观察源）。
    @Environment(\.colorScheme) private var colorScheme
    /// 待发送附图（已拷入 attachments/，文件名引用 + 缩略预览）。
    @State private var pendingImages: [PendingImage] = []
    /// 吸底跟随开关：流式增量只在「视口本就在底部」时自动跟随。
    /// 用户向上滚动（滚轮/触控板/滚动条/键盘）即解除，滚回底部或新回合开始时恢复——
    /// 否则每次追底的 scrollTo 会把视口钉死在底部，表现为「生成中无法向上滚动」。
    /// 解锁判定用「距底增量 vs 内容增量」纯几何判据（ScrollFollowJudge），
    /// 不依赖 scrollPhase（滚轮离散事件在几何回调前 phase 可能已回 idle，会漏判）。
    @State private var stickToBottom = true

    /// 用户长消息的展开集合（key = entry.id）。
    /// 上提到父级而非行内 @State：LazyVStack 滚出视口即销毁行视图，
    /// 行内状态会在滚动往返后复位为折叠，父级 Set 不受虚拟化影响。
    @State private var expandedUserMessages: Set<String> = []

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
            // 确认坞（闸口确认）：与作答抽屉不冲突（抽屉浮于右缘，坞在输入区上方）。
            // 弹出纪律（每阶段弹一次）：已「稍后再说」静默的阶段不挂载坞，
            // 推进改由自由作答发起（design.md §6.1）
            if let target = model.confirmTarget, !store.isStreaming,
               !model.isConfirmGateDeferred(target) {
                ConfirmDock(model: model, target: target)
                DSDivider()
            }
            // ④ 回退坞：显性入口——不必知道「魔法话术」也能重做上游，
            // 与 LLM 回退块同一执行路径（回退 + 自动重生成，诉求可在弹出的生成里继续说）
            // 只在 PRD 生成会话渲染（闸口归属会话口径，同 ConfirmDock）
            if pipeline.stage == .prd, !store.isStreaming, !model.currentVersionReleased,
               model.isGateOwnerSession {
                BacktrackDock(model: model)
                DSDivider()
            }
            // 澄清作答触发 chip：作答统一收口到右缘抽屉（ClarifyAnswerDrawer），
            // 抽屉已关（显式关闭 / 收起动画完）但问题仍待答时的兜底入口，点击滑出抽屉
            if pendingQuestion != nil, !showClarifyDrawer {
                clarifyDrawerTrigger
                DSDivider()
            }
            inputBar
        }
        .frame(minWidth: 480)
        .background(Color.surfaceBase)
        // 点击输入框以外的页面区域（消息流空白 / 头部 / 横幅等）→ 输入框失焦、
        // 光标消失。onTapGesture 只命中无位移单击：按钮与 TextEditor 自行消费
        // 点击不受影响，AI 回答的文本拖选有位移也不触发。
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = false }
        .dsNotifCenter($notif)
        // 阶段开始 / 切换 → 主动推荐刷新（Task 4.5：阶段开始扫描卡片库 1-3 个）
        .task { await model.refreshRecommendations() }
        .onChange(of: pipeline.stage) { _, _ in
            Task { await model.refreshRecommendations() }
        }
        // 作答抽屉：新待答问题出现（entry id 变化）→ 刷新缓存并自动滑出一次；
        // 已答 / 已岔开（pending 清空）→ 抽屉收起（缓存撑完滑出动画）
        .onChange(of: pendingQuestion?.entryId) { _, newId in
            if let pending = pendingQuestion {
                clarifyDrawerCache = pending
            }
            if newId == nil {
                if showClarifyDrawer {
                    withAnimation(DS.Motion.spring) { showClarifyDrawer = false }
                }
            } else {
                syncClarifyDrawerAutoOpen()
            }
        }
        // 流结束才判定新问题（流式写一半的末尾选项行不触发），并刷新缓存到终态
        .onChange(of: store.isStreaming) { _, streaming in
            guard !streaming else { return }
            if let pending = pendingQuestion {
                clarifyDrawerCache = pending
            }
            syncClarifyDrawerAutoOpen()
        }
        // 打开会话即有待答问题 → 滑出一次
        .task { syncClarifyDrawerAutoOpen() }
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
        // 澄清作答抽屉：右缘滑出（记忆抽屉同停靠位，互斥打开）。
        // 挂载条件 = 有待答问题（或收起动画期间的缓存内容）；开合由 offset/opacity
        // 驱动（提交后 pending 先清，缓存撑完滑出动画再等下次问题复用挂载）
        .overlay(alignment: .trailing) {
            if let content = clarifyDrawerContent {
                ClarifyAnswerDrawer(
                    wizard: content.wizard,
                    options: content.options,
                    entryId: content.entryId,
                    isStreaming: store.isStreaming,
                    onClose: closeClarifyDrawer,
                    onSubmit: submitClarifyAnswer
                )
                .padding(.vertical, DS.Spacing.s12)
                .padding(.trailing, DS.Spacing.s12)
                .offset(x: showClarifyDrawer ? 0 : 480)
                .opacity(showClarifyDrawer ? 1 : 0)
                .allowsHitTesting(showClarifyDrawer)
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
            .appendingPathComponent(ArtifactPath.releaseNotes)
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
        .padding(.leading, DS.Spacing.s16)
        // 右栏收起态时中栏右上角有悬浮展开钮（trailing 12 + 宽 28），顶栏尾部
        // 让出 32（钮占位 40 − 已有 16 + 间隙 8），「本月 ¥」不被其遮挡。
        .padding(.trailing, model.inspectorCollapsed ? DS.Spacing.s16 + DS.Spacing.s32 : DS.Spacing.s16)
        .frame(height: 44)
    }

    /// 记忆抽屉开合（右缘滑出 / 收回，动画驱动 transition）。
    /// 与澄清作答抽屉同停靠位（右缘浮层）：开一个关另一个，防双层堆叠。
    private func toggleMemoryDrawer() {
        withAnimation(DS.Motion.spring) {
            showMemoryDrawer.toggle()
            if showMemoryDrawer, showClarifyDrawer {
                showClarifyDrawer = false
            }
        }
    }

    // MARK: - 澄清作答抽屉（开合 / 提交 / 触发 chip）

    /// 待答问题出现 → 自动滑出一次；显式关闭后同问题不再自动滑出
    /// （兜底入口 = 输入区上方触发 chip）。流式中不判定（写一半的选项行）。
    private func syncClarifyDrawerAutoOpen() {
        guard let pending = pendingQuestion, !store.isStreaming else { return }
        guard pending.entryId != clarifyAutoOpenedId else { return }
        clarifyAutoOpenedId = pending.entryId
        guard pending.entryId != clarifyDismissedId else { return }
        withAnimation(DS.Motion.spring) {
            showClarifyDrawer = true
            showMemoryDrawer = false
        }
    }

    /// 显式关闭（X / 跳过此题）：记下当前问题 id，同问题不再自动滑出。
    private func closeClarifyDrawer() {
        withAnimation(DS.Motion.spring) { showClarifyDrawer = false }
        clarifyDismissedId = pendingQuestion?.entryId
    }

    /// 抽屉提交（多题向导拼装消息 / 单题点选即发 / 自由输入）：
    /// 走 sendMessage 通道，答案随用户消息留痕，pending 清空后抽屉收起。
    private func submitClarifyAnswer(_ text: String) {
        withAnimation(DS.Motion.spring) { showClarifyDrawer = false }
        Task { await model.sendMessage(text) }
    }

    /// 触发 chip：抽屉已收起但问题仍待答时的兜底入口。
    private var clarifyDrawerTrigger: some View {
        let count = pendingQuestion?.wizard?.questions.count ?? 1
        return Button {
            withAnimation(DS.Motion.spring) {
                showClarifyDrawer = true
                showMemoryDrawer = false
            }
        } label: {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.question, size: 12)
                Text(count > 1 ? "\(count) 个澄清问题待作答" : "1 个澄清问题待作答")
                DSIcon(.arrowRight, size: 10)
            }
            .font(DS.Font.bodySMStrong)
            .foregroundStyle(Color.ink900)
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s6)
            .background(Capsule().fill(Color.brand100))
            .overlay(Capsule().strokeBorder(Color.brand300, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        // 轻量投影（与 sessions(in:) 的标题口径一致）：session-meta.json 覆盖
        // 优先，默认取内存 entries 首条用户消息前 24 字。不再整读
        // discussions.jsonl——旧实现每次 body 求值都全量解码该版本所有会话，
        // 流式期间每秒十次 MB 级读盘 + JSON 解码，是顶栏侧的卡顿贡献源。
        if let renamed = SessionStore.sessionTitles(project: project, version: version)[sessionId] {
            return renamed
        }
        let firstUser = store.entries.first { $0.role == .user }?.content ?? "（空会话）"
        return String(firstUser.prefix(24))
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
                // LazyVStack：长对话只实例化视口附近的消息（虚拟化）——
                // 旧 VStack 全量持有全部气泡视图，是长会话内存与滚动开销的主因。
                LazyVStack(alignment: .leading, spacing: DS.Spacing.s24) {
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
                            chainContinuation: item.chainContinuation,
                            project: project,
                            version: version,
                            onOpenSink: { tab in
                                // 里程碑行直达右栏对应 Tab（面板收起时同步展开）
                                model.inspectorTab = tab
                                if model.inspectorCollapsed {
                                    withAnimation(DS.Motion.spring) { model.inspectorCollapsed = false }
                                }
                            },
                            onResend: { name in resendOriginal(name, for: item.entry) },
                            resendEnabled: !store.isStreaming && !model.currentVersionReleased,
                            isExpanded: expandedUserMessages.contains(item.entry.id),
                            onToggleExpanded: {
                                withAnimation(DS.Motion.spring) {
                                    if expandedUserMessages.contains(item.entry.id) {
                                        expandedUserMessages.remove(item.entry.id)
                                    } else {
                                        expandedUserMessages.insert(item.entry.id)
                                    }
                                }
                            }
                        )
                        // 未变消息跳过 body 重算（流式期间每秒十次重渲染，
                        // 历史消息的内容/产物解析全部短路，长会话不随流式变卡）
                        .equatable()
                        .dsSlideIn()
                        .id(item.entry.id)
                    }
                    // 流式气泡只在归属会话内渲染：流是全局单份的，生成途中切到
                    // 其他会话不得显示同一份生成内容（回复完成自动落回发起会话）
                    if store.isStreaming, store.streamingSessionID == store.sessionId {
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
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: store.streamingText) { _, _ in
                guard stickToBottom else { return }
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: store.isStreaming) { old, new in
                // 新回合开始（发送 / 采纳推荐 / 确认推进）→ 恢复吸底跟随
                if !old && new { stickToBottom = true }
            }
            // 点击侧栏切换会话 / 首次进入对话页 → 自动定位到最后一条问答。
            // 视图身份在会话间切换时被 SwiftUI 复用（onAppear 不再触发），
            // 故监听本视图的 sessionId（selection didSet 先于 body 重算切好数据源）；
            // 异步一帧等新 entries 完成布局再滚。
            .onChange(of: sessionId) { _, _ in
                stickToBottom = true
                DispatchQueue.main.async { scrollToBottom(proxy, animated: false) }
            }
            .onAppear {
                stickToBottom = true
                DispatchQueue.main.async { scrollToBottom(proxy, animated: false) }
            }
            // 吸底跟随的解锁 / 恢复判据（纯几何，无相位依赖，见 ScrollFollowJudge）：
            // - 距底 ≤ 32pt → 恢复跟随（用户滚回底部）。
            // - 距底增量超出「内容增长量」→ 增长的其余部分只能来自用户上滚 → 解除。
            //   旧实现的 phase 门控有竞态：鼠标滚轮离散事件在几何回调触发前
            //   phase 可能已回 idle，解锁被吞 → 上滚被下一 token 追底拉回，
            //   表现为「生成中滚不上去」。本判据对滚轮 / 触控板 / 惯性 / 键盘 /
            //   拖滚动条全部成立；用户上滚中内容同时增长（增量 = growth + 上滚量）
            //   也能正确解除；生成期间不跟随时视口纹丝不动（阅读位置记忆）。
            .onScrollGeometryChange(for: ScrollGeometry.self) { geo in
                geo
            } action: { old, new in
                let oldBottom = Self.bottomDistance(of: old)
                let newBottom = Self.bottomDistance(of: new)
                if ScrollFollowJudge.shouldRestick(bottomDistance: newBottom) {
                    stickToBottom = true
                } else if ScrollFollowJudge.shouldUnstick(
                    oldBottom: oldBottom,
                    newBottom: newBottom,
                    growth: new.contentSize.height - old.contentSize.height
                ) {
                    stickToBottom = false
                }
            }
        }
    }

    /// 视口底缘到内容底缘的距离（含 insets；≤ 0 = 已在底部 / 内容不足一屏）。
    nonisolated private static func bottomDistance(of geo: ScrollGeometry) -> CGFloat {
        let maxOffset = geo.contentSize.height
            + geo.contentInsets.top + geo.contentInsets.bottom
            - geo.containerSize.height
        return maxOffset - geo.contentOffset.y
    }

    /// 滚到消息流底部：流式气泡在渲染时锚它，否则锚最后一条可见消息。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let target: String = if store.isStreaming, store.streamingSessionID == store.sessionId {
            "streaming"
        } else {
            displayItems.last?.id ?? "streaming"
        }
        if animated {
            withAnimation { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
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

    /// 流式中的回答内容（头部注记 + 思考 spinner + 增量正文），与最终消息同构。
    @ViewBuilder
    private var streamingInner: some View {
        let headerAssembly = MessageBubble.milestoneAssembly(from: streamingHeaderNotes)
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            // 回合注记（阶段推进/切档）在流式开始时即并入气泡顶部；
            // 携带里程碑载荷的行（评分卡）渲染为交付摘要条
            ForEach(Array(headerAssembly.leftovers.enumerated()), id: \.offset) { _, note in
                TurnNoteRow(note: note)
            }
            if !headerAssembly.rows.isEmpty {
                DigestBar(
                    rows: headerAssembly.rows,
                    openSink: { tab in
                        model.inspectorTab = tab
                        if model.inspectorCollapsed {
                            withAnimation(DS.Motion.spring) { model.inspectorCollapsed = false }
                        }
                    }
                )
            }
            // 原型：思考中 spinner + 流光扫字（含本轮引用技能）；文本开始输出后仅展示增量
            if store.streamingThink.isEmpty && store.streamingText.isEmpty {
                ThinkingCard(data: nil, skills: store.streamingSkills)
            } else if !store.streamingThink.isEmpty {
                ThinkingCard(data: nil, skills: store.streamingSkills)
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

    /// 流式中的 AgentShell（思考 spinner + 增量文本）。
    /// 快速通道链上的续段回合（前方跨系统行有「快速通道」标记可回溯到 assistant）
    /// 不出独立回答头——流式期间就保持「一条回答」观感，落盘后与历史续段同构。
    private var streamingBubble: some View {
        let chained = MessageBubble.isFastForwardChainedBefore(
            store.entries.count, in: store.entries
        )
        return Group {
            if chained {
                streamingInner
            } else {
                AgentMessageShell(stage: pipeline.stage, time: nil) {
                    streamingInner
                }
            }
        }
    }

    private func isLastAssistant(_ entry: DiscussionEntry) -> Bool {
        // 全阶段放开（不止澄清）：②③④ 的歧义处理规则同样以末尾 A)/B) 选项行
        // 收尾。末条 AI 回复的选项行统一折叠进右缘作答抽屉（ClarifyAnswerDrawer），
        // 消息流不再渲染点选项；该消息不再是末条后选项行随原文回归留痕。
        guard entry.role == .assistant else { return false }
        return entry.id == store.entries.last(where: { $0.role == .assistant })?.id
    }

    /// 待答问题快照（作答抽屉数据源）：多题问题卡优先，否则单题末尾选项行。
    private struct PendingQuestion {
        let entryId: String
        let wizard: ArtifactParser.QuestionCardRequest?
        let options: ArtifactParser.ClarifyOptions?
    }

    /// ① 多题问题卡待答：最新 assistant 回复中的 artifact:question-card 块，限澄清阶段。
    /// 该回复之后已存在任何用户消息（已作答 / 已岔开继续聊）→ 不再算待答
    /// （旧口径仅按【问题卡作答】前缀判定；统一口径：岔开即视为该问题关闭）。
    private var pendingQuestionCard: ArtifactParser.QuestionCardRequest? {
        guard pipeline.stage == .clarify, !model.currentVersionReleased else { return nil }
        guard let lastAssistantIndex = store.entries.lastIndex(where: { $0.role == .assistant }),
              let request = ArtifactParser.parseQuestionCard(
                  blocks: ArtifactParser.parseArtifactBlocks(in: store.entries[lastAssistantIndex].content)
              ) else { return nil }
        if store.entries.dropFirst(lastAssistantIndex + 1).contains(where: { $0.role == .user }) {
            return nil
        }
        return request
    }

    /// 单题待答：末条 assistant 回复末尾的连续 A)/B) 选项行（全阶段放开——
    /// ②③④ 的歧义处理同样以选项行收尾，与原流内 chips 同口径）。
    /// 该回复之后已存在任何用户消息（已作答 / 已岔开）→ 不再算待答。
    private var pendingClarifyOptions: ArtifactParser.ClarifyOptions? {
        guard let lastAssistantIndex = store.entries.lastIndex(where: { $0.role == .assistant }),
              let options = ArtifactParser.parseClarifyOptions(in: store.entries[lastAssistantIndex].content)
        else { return nil }
        if store.entries.dropFirst(lastAssistantIndex + 1).contains(where: { $0.role == .user }) {
            return nil
        }
        return options
    }

    /// 待答问题（作答抽屉数据源）：多题问题卡优先，否则单题选项行。
    private var pendingQuestion: PendingQuestion? {
        guard let lastAssistantIndex = store.entries.lastIndex(where: { $0.role == .assistant })
        else { return nil }
        let entryId = store.entries[lastAssistantIndex].id
        if let wizard = pendingQuestionCard {
            return PendingQuestion(entryId: entryId, wizard: wizard, options: nil)
        }
        if let options = pendingClarifyOptions {
            return PendingQuestion(entryId: entryId, wizard: nil, options: options)
        }
        return nil
    }

    /// 抽屉渲染内容：活体待答优先，提交后收起动画期间走缓存。
    private var clarifyDrawerContent: PendingQuestion? {
        pendingQuestion ?? clarifyDrawerCache
    }

    // MARK: - 系统事件三分层（独立可见 / 融入回答 / 静默）

    /// 渲染项：一条可见条目 + 已并入其气泡的系统注记。
    private struct DisplayItem: Identifiable {
        let entry: DiscussionEntry
        let headerNotes: [TurnNote]
        let footerNotes: [TurnNote]
        /// 快速通道链式续段：不出独立回答头，内容衔接上一回合（一条消息一条回答）。
        var chainContinuation: Bool = false
        var id: String { entry.id }
    }

    /// 系统事件降噪分层：
    /// ① 记忆行（memory 载荷）静默——照常落盘可回溯，UI 不渲染（记忆抽屉承载）；
    /// ② 推进/切档/产物/决策记录注记并入相邻 AI 回答气泡内部；
    /// ③ 警告、闸口拦截、风险命中等必须独立可见的，保留为独立事件条。
    private var displayItems: [DisplayItem] {
        let entries = store.entries
        // 已并入相邻 assistant 气泡注记的系统行不再作为独立胶囊渲染——
        // 否则同一事件出现两遍（气泡内注记 + 气泡外胶囊）
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        // 流式期间尾部已被流式气泡头部吸收的 preamble 行（✅ 推进行等）同样跳过——
        // 流式条目落盘前 mergedSystemIndices 还看不到它，不跳就是双渲染
        let streamingAbsorbed: Set<Int> =
            store.isStreaming && store.streamingSessionID == store.sessionId
            ? MessageBubble.streamingAbsorbedIndices(in: entries)
            : []
        var items: [DisplayItem] = []
        for (index, entry) in entries.enumerated() {
            if entry.role == .system && entry.memory != nil { continue }
            if entry.role == .system && streamingAbsorbed.contains(index) { continue }
            if entry.role == .assistant {
                items.append(DisplayItem(
                    entry: entry,
                    headerNotes: MessageBubble.mergeableNotes(before: index, in: entries),
                    footerNotes: MessageBubble.mergeableNotes(after: index, in: entries),
                    chainContinuation: MessageBubble.isFastForwardChainedBefore(index, in: entries)
                ))
            } else if entry.role == .system && merged.contains(index) {
                continue
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

                // 思考强度（reasoning_effort）：信号柱图标 + 当前档位文本 → 档位菜单
                // （对话页与新建任务输入卡共用组件；品牌色常亮）
                ComposerEffortButton(store: store)

                // 对话模型切换器（多模型管理）：当前模型 chip → 弹层实时切换
                // （写透 stages 即时生效，「添加模型…」直达设置模型页）
                ComposerModelButton(model: model)

                // 流式回复中（本会话为发起者）→ 停止钮（红色，点击即终止生成）；
                // 其余状态 → 发送钮（空闲/他人会话流式时维持原禁用逻辑）
                if store.isStreaming, store.streamingSessionID == store.sessionId {
                    ComposerStopButton {
                        store.stopGeneration()
                    }
                } else {
                    ComposerSendButton(enabled: canSend && !store.isStreaming) {
                        send()
                    }
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
    /// （字号与用户气泡同为 chatBase 15，所见即所得）。
    private var inputEditor: some View {
        TextEditor(text: $draft)
            .font(DS.Font.chatBase)
            .foregroundStyle(Color.ink900)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                // 坑：中文输入法组字（拼音未上屏）属 NSTextView markedText，
                // draft 绑定仍是空串——只看 draft 会让占位压在组字文本下面。
                // imeComposing 由 IMEComposingDetector 回填，组字期间一并隐藏。
                if draft.isEmpty && !imeComposing {
                    Text(inputPlaceholder)
                        .font(DS.Font.chatBase)
                        .foregroundStyle(Color.composerPlaceholder)
                        .padding(.top, DS.Spacing.s4)
                        .padding(.leading, DS.Spacing.s4)
                        .allowsHitTesting(false)
                }
            }
            .background(IMEComposingDetector(isComposing: $imeComposing))
            .focused($inputFocused)
            .onChange(of: inputFocused) { _, focused in
                if !focused { imeComposing = false }
            }
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

    /// 截断卡「重新发送」：模拟真实用户的交互方式——把触发本回答的原始用户消息回填
    /// 输入框（附图回填待发条），再走与手输完全一致的 send() 标准链路：
    /// 「用户消息发送 → 系统接收 → AI 处理 → 生成回答」，不直接复用/重生成 AI 回答内容。
    private func resendOriginal(_ artifactName: String, for entry: DiscussionEntry) {
        guard !store.isStreaming, !model.currentVersionReleased else { return }
        guard let origin = originalUserMessage(before: entry) else {
            // 理论不达（每条 AI 回答前必有用户消息）：兜底走同链路的指令式重试
            draft = "重新生成\(artifactDisplayName(artifactName))"
            send()
            return
        }
        draft = origin.content
        pendingImages = origin.images.compactMap { file in
            guard let data = PMAgentStore.readAttachment(file, project: project, version: version),
                  let image = NSImage(data: data) else { return nil }
            return PendingImage(fileName: file, preview: image)
        }
        send()
    }

    /// 触发指定 AI 回答的原始用户消息（含附图）：委托可测静态实现。
    private func originalUserMessage(before entry: DiscussionEntry) -> (content: String, images: [String])? {
        MessageBubble.originalUserMessage(before: entry.id, in: store.entries)
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
            // 名称行：头像 + Agent（600）+ 时间（mono tertiary）；阶段身份由头像编号/主色表达
            HStack(spacing: DS.Spacing.s8) {
                StageAvatar(stage: stage, size: 22)
                Text("Agent")
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
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

/// 吸底跟随判定（纯函数，可单测）：距底距离变化与内容增量的联合判据。
/// 核心洞察——内容只在视口下方追加（append-only 消息流）：
/// - 内容增长 growth 且用户不动 → 距底恰好增加 growth（offset 不变）；
/// - 用户上滚 U → 距底增加 U（内容不变）；
/// - 两者叠加 → 距底增加 growth + U。
/// 因此「距底增量 > growth + ε」唯一指向用户上滚，与滚动相位（滚轮离散
/// 事件 phase 竞态）无关，也不需要区分程序化追底（只减不增）。
nonisolated enum ScrollFollowJudge {
    /// 滚回距底 ≤ 阈值 → 恢复吸底跟随。
    static func shouldRestick(bottomDistance: CGFloat, threshold: CGFloat = 32) -> Bool {
        bottomDistance <= threshold
    }

    /// 距底增量超出内容增长 → 解除吸底跟随（用户在向上滚）。
    /// 增量恰好等于 growth 时不解除（等流式追底 scrollTo 拉回）。
    static func shouldUnstick(
        oldBottom: CGFloat,
        newBottom: CGFloat,
        growth: CGFloat,
        epsilon: CGFloat = 0.5,
        threshold: CGFloat = 32
    ) -> Bool {
        newBottom > threshold && (newBottom - oldBottom) > growth + epsilon
    }
}

/// 回合注记（脱 emoji 后的文本 + 语义图标与着色，融入 AI 回答气泡内部）。
/// fileChanges 非空时渲染为落盘文件卡（📦 产物落盘行携带）；
/// milestones 非空时由交付摘要条吸收（方案 B 一行摘要，行文本不再单独渲染）。
/// nonisolated + Equatable：MessageBubble 的等价判据要比较 notes，
/// 值模型显式退出隐式 MainActor（同 DiscussionEntry 约定）。
nonisolated struct TurnNote: Equatable {
    let text: String
    let icon: DSIcon.Name
    let tint: Color
    var fileChanges: [FileChangeSummary]? = nil
    var milestones: [MilestoneStamp]? = nil

    /// icon/tint 不参与等价：由 text 在构造时确定性派生，同 text 必同样式。
    static func == (lhs: TurnNote, rhs: TurnNote) -> Bool {
        lhs.text == rhs.text
            && lhs.fileChanges == rhs.fileChanges
            && lhs.milestones == rhs.milestones
    }
}

/// 里程碑清单行（方案 B）：勾选节点 = 已落盘事实；isNext 节点为数据行，
/// 只供摘要条标题派生（「已交付 原型」），不再单独渲染推进行。
struct MilestoneRow: Identifiable {
    let id: String
    let icon: DSIcon.Name
    let tint: Color
    /// 主体名（「漏项雷达」「决策记录」「原型待确认」「机器初审中」）。
    let name: String
    /// mono 计数（「4 项」「+2 条」「零缺项」）。
    var countText: String? = nil
    /// 下一节点的同行尾注（「确认后 AI 随即撰写 ④ PRD」）。
    var tail: String? = nil
    /// 12px 次行补注。
    var detail: String? = nil
    /// 去向提示（「右栏「决策日志」」），hover 点亮。
    var destination: String? = nil
    /// 行点击 → 右栏 Tab。
    var tab: InspectorPanel.InspectorTab? = nil
    /// 下一节点数据行（不渲染，仅供摘要条标题「已交付 X」派生与明细行过滤）。
    var isNext: Bool = false
    /// 评分卡专用：三维度分数条（非空时 detail 理由改为 hover 才展开）。
    var dims: [MilestoneDim]? = nil
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

/// 评分卡维度条（方案 B）：名字 + mono 分数 + 迷你条；hover 经 help 出评分理由，
/// 长理由不再挤进正文。分数着色按阈值（≥8 红 / ≥5 橙 / 其余绿）。
private struct ScoreDimChip: View {
    let dim: MilestoneDim

    private var tint: Color {
        if dim.score >= 8 { return Color.statusError }
        if dim.score >= 5 { return Color.statusWarning }
        return Color.statusSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(dim.name)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Text("\(dim.score)")
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(tint)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.borderL1).frame(height: 3)
                Capsule()
                    .fill(tint)
                    .frame(width: 48 * CGFloat(min(max(dim.score, 0), 10)) / 10, height: 3)
            }
            .frame(width: 48)
        }
        .help("\(dim.name) \(dim.score)/10 · \(dim.reason)")
    }
}

/// 回合交付摘要条（方案 B：默认展开，可点击整行折叠）：默认展出审计明细行 +
/// 机器初审等待态，摘要行点击折叠为一行——✓ 已交付产物 + 审计计数段。
/// 落盘文件卡独立渲染在摘要条外部（不内嵌）。
/// 展开态纯 UI 状态不落盘（刷新回默认展开）。行 hover 点亮去向，点击直达右栏对应 Tab。
struct DigestBar: View {
    let rows: [MilestoneRow]
    var openSink: ((InspectorPanel.InspectorTab) -> Void)? = nil

    @State private var expanded = true
    @State private var hovered = false
    @State private var hoveredRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            if expanded {
                panel
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg).fill(Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(hovered ? Color.borderL2 : Color.borderL1, lineWidth: 1)
        )
        .animation(DS.Motion.spring, value: expanded)
        .onHover { hovered = $0 }
    }

    // MARK: 摘要行（默认态，整行可点）

    private var summaryBar: some View {
        Button {
            withAnimation(DS.Motion.spring) { expanded.toggle() }
        } label: {
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(.circleCheck, size: 14)
                    .foregroundStyle(Color.statusSuccess)
                Text(title)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink800)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 4) {
                        Text(seg.label)
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(seg.warn ? Color.statusWarning : Color.ink500)
                        if let count = seg.count {
                            Text(count)
                                .font(DS.Font.mono2XS)
                                .foregroundStyle(seg.warn ? Color.statusWarning : Color.ink700)
                        }
                        if seg.warn {
                            Text("超限")
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.statusWarning)
                        }
                    }
                }
                Spacer(minLength: 0)
                DSIcon(.chevronUp, size: 11)
                    .foregroundStyle(Color.ink300)
                    .rotationEffect(.degrees(expanded ? 0 : 180))
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 标题：待确认行去尾缀 → 「已交付 产品需求文档」；初审未出结论 → 产物已落盘；
    /// 仅评分卡 → PRD 评分卡；兜底 → 本回合小结。
    private var title: String {
        if let next = rows.first(where: { $0.isNext }) {
            return "已交付 " + next.name.replacingOccurrences(of: "待确认", with: "")
        }
        if rows.contains(where: { $0.name == "机器初审中" }) { return "产物已落盘" }
        if rows.contains(where: { $0.id.hasPrefix("score@") }) { return "PRD 评分卡" }
        return "本回合小结"
    }

    private struct SummarySegment {
        let label: String
        var count: String? = nil
        var warn = false
    }

    /// 计数段（落盘顺序，风险超限段置尾；评分卡由标题承载，不重复出段）。
    private var segments: [SummarySegment] {
        var plain: [SummarySegment] = []
        var warns: [SummarySegment] = []
        for row in rows where !row.isNext && row.name != "机器初审中" {
            switch row.id.prefix(while: { $0 != "@" }) {
            case "radar":
                plain.append(SummarySegment(label: "雷达", count: row.countText))
            case "decision":
                plain.append(SummarySegment(label: "决策", count: row.countText))
            case "warn":
                warns.append(SummarySegment(label: "风险", count: warnCount, warn: true))
            default:
                break
            }
        }
        return plain + warns
    }

    /// 风险段计数：软上限可从 detail 解析时出「8/3」，否则「8 条」。
    private var warnCount: String? {
        guard let warn = rows.first(where: { $0.id.hasPrefix("warn@") }),
              let count = warn.countText else { return nil }
        let digits = count.filter { $0.isNumber }
        if digits.isEmpty { return count }
        if let detail = warn.detail, detail.hasPrefix("软上限 ") {
            let rest = detail.dropFirst("软上限 ".count)
            if let unit = rest.range(of: " 条"),
               let limit = Int(rest[..<unit.lowerBound]) {
                return "\(digits)/\(limit)"
            }
        }
        return "\(digits) 条"
    }

    // MARK: 展开面板

    private var detailRows: [MilestoneRow] {
        rows.filter { !$0.isNext && $0.name != "机器初审中" }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(detailRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Color.borderL1)
                        .frame(height: 1)
                        .padding(.vertical, DS.Spacing.s3)
                }
                detailRow(row)
            }
            footer
        }
        .padding(.bottom, DS.Spacing.s6)
    }

    /// 明细行：图标 + 主体名 + mono 计数 + 同行尾注，去向右置（hover 点亮，点击跳右栏）；
    /// 次行补注 / 评分卡维度条随行展开。
    private func detailRow(_ row: MilestoneRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(row.icon, size: 13)
                    .foregroundStyle(row.tint)
                Text(row.name)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink800)
                if let count = row.countText {
                    Text(count)
                        .font(DS.Font.mono2XS)
                        .foregroundStyle(Color.ink500)
                }
                if let tail = row.tail {
                    Text(tail)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink700)
                }
                Spacer(minLength: DS.Spacing.s8)
                if let destination = row.destination {
                    HStack(spacing: 3) {
                        Text(destination)
                        DSIcon(.chevronRight, size: 9)
                    }
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(hoveredRowID == row.id ? Color.brandAccent : Color.ink300)
                }
            }
            if let detail = row.detail, row.dims == nil {
                Text(detail)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dims = row.dims {
                HStack(spacing: DS.Spacing.s12) {
                    ForEach(Array(dims.enumerated()), id: \.offset) { _, dim in
                        ScoreDimChip(dim: dim)
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard row.tab != nil else { return }
            hoveredRowID = hovering ? row.id : nil
        }
        .onTapGesture {
            guard let tab = row.tab, let openSink else { return }
            openSink(tab)
        }
    }

    /// 面板脚注：机器初审等待态（结论稍后并入本摘要）。
    /// 阶段推进不再由摘要条承载（确认坞 / 自由作答「进入下一阶段」发起）。
    @ViewBuilder
    private var footer: some View {
        if rows.contains(where: { $0.name == "机器初审中" }) {
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(.clock, size: 12)
                    .foregroundStyle(Color.ink300)
                Text("机器初审中——结论稍后并入本摘要")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.top, DS.Spacing.s8)
        }
    }
}

struct MessageBubble: View {
    let entry: DiscussionEntry
    /// 助手消息的阶段（决定头像与名称行）。
    let stage: PipelineRun.Stage
    /// 末条 assistant：末尾选项行折叠进右缘作答抽屉（不再流内渲染点选项）。
    let showOptions: Bool
    /// 融入气泡顶部的回合注记（阶段推进/切档/进度）。
    let headerNotes: [TurnNote]
    /// 融入气泡底部的注记（产物落盘/决策记录）。
    let footerNotes: [TurnNote]
    /// 快速通道链式续段：跳过 AgentMessageShell 头部，内容直接衔接上一回合
    ///（一条用户消息只出一条连续回答；分段推进注记由 headerNotes 承载）。
    var chainContinuation: Bool = false
    /// 附图归属（attachments/ 定位；空串时附图不渲染，仅文本）。
    let project: String
    let version: String
    /// 里程碑行点击 → 右栏对应 Tab（决策日志 / 漏项雷达）；nil = 行仅展示。
    var onOpenSink: ((InspectorPanel.InspectorTab) -> Void)? = nil
    /// 截断卡「重新发送」回调（参数 = 产物块名，供兜底拼指令）；nil = 卡片不显示按钮。
    var onResend: ((String) -> Void)? = nil
    /// 截断卡发送按钮可用性（流式中 / 封板 = false）。
    let resendEnabled: Bool
    /// 用户长消息是否已展开（父级 expandedUserMessages 派生；仅 foldEnabled 时有意义）。
    var isExpanded: Bool = false
    /// 用户长消息折叠条「展开全部/收起」回调；nil = 不启用折叠（短消息恒 nil 也成立）。
    var onToggleExpanded: (() -> Void)? = nil

    /// 产物 chip 点击后的预览目标（md → Mermaid 渲染 / html → 原型预览）。
    @State private var previewTarget: FileNode?

    // MARK: 用户长消息折叠（方案 B · 折叠操作条）

    /// 折叠阈值：去空白字数超过才启用折叠条（短消息保持原样，不加操作条）。
    private static let foldCharThreshold = 300
    /// 折叠态预览行数（SwiftUI 无法精确半行截断，5 行 + 底部渐隐替代原型的 5 行半）。
    private static let previewLineLimit = 5

    /// 全文字数（去空白，与原型「共 N 字」同口径）。
    private var bodyCharCount: Int {
        entry.content.filter { !$0.isWhitespace }.count
    }
    /// 「### 」标题章节数（用户粘贴 PRD/纪要常见结构）。
    private var sectionCount: Int {
        entry.content.split(separator: "\n").filter { $0.hasPrefix("### ") }.count
    }
    /// 是否启用折叠（有回调且超阈值）。
    private var foldEnabled: Bool {
        onToggleExpanded != nil && bodyCharCount > Self.foldCharThreshold
    }

    var body: some View {
        Group {
            switch entry.role {
            case .user:
                userBubble
            case .assistant:
                if chainContinuation {
                    // 链式续段：不出独立回答头（内容 + 推进注记直接衔接上一回合）
                    assistantContent
                } else {
                    AgentMessageShell(stage: stage, time: hhmm(entry.createdAt)) {
                        assistantContent
                    }
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
                    let clipped = foldEnabled && !isExpanded
                    Text(entry.content)
                        .font(DS.Font.chatBase)
                        .foregroundStyle(Color.white)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(clipped ? Self.previewLineLimit : nil)
                        .mask {
                            if clipped {
                                // 折叠态底部渐隐：「下面还有」的视觉信号（原型遮罩参数）
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.55),
                                        .init(color: .black.opacity(0.45), location: 0.82),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            } else {
                                // 展开态恒等遮罩（保持布局稳定，不参与视觉）
                                Rectangle().fill(Color.black)
                            }
                        }
                }
                // 方案 B · 折叠操作条：hairline 分隔 + 折叠量明示 + 品牌胶囊「展开全部/收起」
                if foldEnabled {
                    foldBar
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

    /// 折叠操作条（方案 B）：hairline 分隔线 + 左侧折叠量 meta + 右侧品牌胶囊按钮。
    /// 用户气泡恒深底白字（light/dark 的 userBubble 都是深色），配色固定白系/品牌系，不分主题。
    private var foldBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.10))    // 原型 bubble-line hairline
                .frame(height: 1)
            HStack(spacing: DS.Spacing.s12) {
                Text(foldMetaText)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.white.opacity(0.52))   // 原型 bubble-dim
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.s12)
                Button {
                    onToggleExpanded?()
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "收起" : "展开全部")
                        DSIcon(isExpanded ? .chevronUp : .down, size: 10)
                    }
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.brand300)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.brand600.opacity(0.22)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, DS.Spacing.s10)
        }
    }

    /// 折叠条 meta 文案：折叠态明示折叠量（N=全文字数，与原型「已折叠 804 字」同口径）。
    private var foldMetaText: String {
        if isExpanded {
            return "全文 \(bodyCharCount) 字 · 已展开"
        }
        var text = "已折叠 \(bodyCharCount) 字"
        if sectionCount > 0 {
            text += " · \(sectionCount) 个章节"
        }
        return text
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

    /// 安静留痕提示（💬 前缀，如「已收起确认」）：居中纯文本渲染，不走语义事件条——
    /// 它是流内留痕（静默反馈 + 推进指引），不是必须独立可见的警告事件。
    fileprivate static func isQuietNotice(_ content: String) -> Bool {
        content.hasPrefix("💬")
    }

    /// 独立系统事件条分流：安静留痕（💬）居中纯文本（方案 A：无图标无容器，12px ink500，
    /// 上方拉开一档留白，像时间戳一样隐入对话流）；其余走左对齐语义胶囊。
    @ViewBuilder
    private var systemPill: some View {
        if Self.isQuietNotice(entry.content) {
            Text(Self.stripEventEmoji(entry.content))
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Spacing.s12)   // 与上一条消息拉开留白（列表 24 + 12 = 36px）
        } else {
            eventPill
        }
    }

    /// 左对齐紧凑胶囊：语义图标着色 + 状态底色，只承载必须独立可见的事件
    /// （警告 / 闸口拦截 / 风险命中等）。
    private var eventPill: some View {
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
        // 未闭合产物块 = 输出撞 max_tokens 被截断（历史会话兜底渲染，新会话已自动续写）。
        // 收起断点后的长代码，换成截断提示卡，避免整屏 HTML 刷屏。
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: entry.content)
        // ViewBuilder 属性内不能写「if + 赋值」语句（if 会被当作视图节点），
        // 截断兜底裁剪收进立即执行的闭包，产出仍是单个 let
        let displayText = {
            var text = blocks.isEmpty
                ? entry.content
                : ArtifactParser.stripArtifactBlocks(
                    in: entry.content,
                    placeholder: "（产物已生成并落盘——点击下方标签预览，或见右栏「文件」面板）",
                    // 所有产物块不插正文占位：图表块直接渲染，其余块底部有胶囊提示，
                    // 避免多条块落多条重复引导文字
                    placeholderFor: { _ in "" }
                )
            if incomplete != nil, let marker = text.range(of: "```artifact:", options: .backwards) {
                text = String(text[..<marker.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 末尾选项行折叠：点选作答统一收口到右缘作答抽屉，正文不再重复渲染
            // 点不了的 A)/B) 原文行（parseClarifyOptions 的 question 即去掉末尾
            // 选项行后的正文）；该消息不再是末条后选项行随原文回归留痕。
            if showOptions, let options = ArtifactParser.parseClarifyOptions(in: text) {
                text = options.question
            }
            return text
        }()
        // 回合里程碑装配（方案 B）：雷达 / 决策 / 评分卡 / 下一节点收编为摘要条；
        // 旧会话注记无载荷 → rows 为空，chips 与注记行走回退渲染
        let assembly = Self.milestoneAssembly(from: footerNotes)
        // 气泡顶部的里程碑（评分卡先于 PRD 回答落盘 → 属头部注记）
        let headerAssembly = Self.milestoneAssembly(from: headerNotes)
        // 落盘文件卡的跳过集：产物块结果卡已承载的文件（原型卡常驻；
        // PRD 卡仅无摘要条的旧会话回退出——摘要条承载期 PRD 由落盘文件卡出）
        let cardSkipPaths = Self.blockCardPaths(
            blocks: blocks, project: project, version: version,
            digestVisible: !assembly.rows.isEmpty
        )

        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            // 回合注记（阶段推进/切档）：并入气泡顶部的安静 meta 行
            ForEach(Array(headerAssembly.leftovers.enumerated()), id: \.offset) { _, note in
                TurnNoteRow(note: note)
            }
            if !headerAssembly.rows.isEmpty {
                DigestBar(
                    rows: headerAssembly.rows,
                    openSink: onOpenSink
                )
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
                hideSinkChips: !assembly.rows.isEmpty,
                onOpen: { previewTarget = $0 }
            )

            // 截断兜底：产物块未闭合（输出撞 max_tokens 且续写未成功）→ 提示卡代替代码墙
            if let incomplete {
                ArtifactTruncatedCard(
                    name: incomplete.name,
                    sendEnabled: resendEnabled,
                    onSend: onResend.map { handler in { handler(incomplete.name) } }
                )
            }

            // 回合交付摘要条（方案 B）：✓ 已交付 + 计数段一行收束；展开面板为
            // 审计明细（点击直达右栏对应 Tab）+ 机器初审等待态。
            // 落盘文件卡独立渲染在条外。
            if !assembly.rows.isEmpty {
                DigestBar(
                    rows: assembly.rows,
                    openSink: onOpenSink
                )
            }

            // 落盘文件卡（📦 注记携带 fileChanges）：每个文件一张生成文件卡，
            // 独立渲染在摘要条下方；产物块结果卡已承载的文件跳过（防同文件双卡）
            ForEach(Array(assembly.absorbedCards.enumerated()), id: \.offset) { _, note in
                if let changes = note.fileChanges, !changes.isEmpty {
                    FileChangeCards(
                        changes: changes, project: project, version: version,
                        skipPaths: cardSkipPaths
                    ) { previewTarget = $0 }
                }
            }

            // 无里程碑载荷的注记：原样渲染（携带 fileChanges 的行保留落盘文件卡 + 门控提示行）
            ForEach(Array(assembly.leftovers.enumerated()), id: \.offset) { _, note in
                if let changes = note.fileChanges, !changes.isEmpty {
                    FileChangeCards(
                        changes: changes, project: project, version: version,
                        skipPaths: cardSkipPaths
                    ) { previewTarget = $0 }
                    TurnNoteRow(note: note)
                } else {
                    TurnNoteRow(note: note)
                }
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
        // PRD 评分卡（方案 B：并入回合里程碑，三格分数条 + 选档结论）
        if content.hasPrefix("📊") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .barList, tint: .ink500
            )
        }
        // 决策沉淀行（新旧两版文案并存：旧会话存量「已沉淀」，新发射为「决策记录 +N 条」）
        if content.hasPrefix("📝 已沉淀") || content.hasPrefix("📝 决策记录") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .bookmark, tint: .ink500
            )
        }
        if content.hasPrefix("🔍") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .search, tint: .ink500
            )
        }
        // ⚠️ 可并入的两类风险行：活跃超软上限警示（旧）、自评审风险登记通知（携 risk
        // milestones 载荷 → 摘要条琥珀「风险 +N 条」行）。漏登记会截断合并行走——
        // 其后本应并入的 🔍 雷达 / 📝 决策行全部回退独立旧卡、气泡产物块回退灰胶囊。
        //（其余 ⚠️——登记失败 / 机器初审未过 / 封板失败等——仍走独立事件条）
        if content.hasPrefix("⚠️ 活跃") || content.hasPrefix("⚠️ 自评审新增") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .warningFill, tint: .statusWarning
            )
        }
        // 机器门降级提示（评审模型不可用 → 直接人工确认）：并入回合注记，
        // 里程碑清单将其吸收为「待确认」状态
        if content.hasPrefix("ℹ️") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .dot, tint: .ink500
            )
        }
        return nil
    }

    /// 系统行归属分类：preamble（确认推进 / 切档 / 评分卡 / 开始撰写）归其**引入**的回合
    /// （下一 assistant 头部）；aftermath（产物📦 / 雷达 / 决策 / 门控结论）归其**跟随**的
    /// 回合（上一 assistant 尾部）。两向行走在此分类处截断 → 相邻气泡不再双渲染同一条注记。
    fileprivate static func isTurnPreamble(_ content: String) -> Bool {
        if content.hasPrefix("🎚️") || content.hasPrefix("🏗️")
            || content.hasPrefix("🎨") || content.hasPrefix("📊") { return true }
        if content.hasPrefix("📝 开始") { return true }
        // ✅ 只有「已确认」是推进语（引入下一回合）；「质量门通过」「机器初审通过」是本轮结论
        if content.hasPrefix("✅") { return content.contains("已确认") }
        return false
    }

    /// assistant 前方连续 preamble 系统行 → 顶部注记（遇 aftermath / 不可并入行 / 记忆行即停）。
    /// internal 供测试（评分卡存量去重判据）。
    static func mergeableNotes(
        before index: Int, in entries: [DiscussionEntry]
    ) -> [TurnNote] {
        let scorecardDups = duplicateScorecardIndices(in: entries)
        var notes: [TurnNote] = []
        var i = index - 1
        while i >= 0,
              entries[i].role == .system, entries[i].memory == nil,
              isTurnPreamble(entries[i].content) {
            if scorecardDups.contains(i) { i -= 1; continue }  // 存量重复评分卡：不进回合注记
            guard var note = turnNote(from: entries[i].content) else { break }
            if let changes = entries[i].fileChanges, !changes.isEmpty {
                note.fileChanges = changes
            }
            if let stamps = entries[i].milestones, !stamps.isEmpty {
                note.milestones = stamps
            }
            notes.insert(note, at: 0)
            i -= 1
        }
        return notes
    }

    /// assistant 后方连续 aftermath 系统行 → 底部注记（停止条件同上）。
    /// internal 供测试（⚠️ 活跃警示并入判据）。
    static func mergeableNotes(
        after index: Int, in entries: [DiscussionEntry]
    ) -> [TurnNote] {
        var notes: [TurnNote] = []
        var i = index + 1
        while i < entries.count,
              entries[i].role == .system, entries[i].memory == nil,
              !isTurnPreamble(entries[i].content) {
            guard var note = turnNote(from: entries[i].content) else { break }
            if let changes = entries[i].fileChanges, !changes.isEmpty {
                note.fileChanges = changes
            }
            if let stamps = entries[i].milestones, !stamps.isEmpty {
                note.milestones = stamps
            }
            notes.append(note)
            i += 1
        }
        return notes
    }

    /// 会被并入相邻 assistant 气泡注记的系统行索引（与两向行走同判据）。
    /// displayItems 据此跳过独立胶囊渲染，防止同一事件双重出现（注记 + 胶囊）。
    static func mergedSystemIndices(in entries: [DiscussionEntry]) -> Set<Int> {
        var merged = Set<Int>()
        for (index, entry) in entries.enumerated() where entry.role == .assistant {
            var i = index - 1
            while i >= 0,
                  entries[i].role == .system, entries[i].memory == nil,
                  isTurnPreamble(entries[i].content),
                  turnNote(from: entries[i].content) != nil {
                merged.insert(i)
                i -= 1
            }
            i = index + 1
            while i < entries.count,
                  entries[i].role == .system, entries[i].memory == nil,
                  !isTurnPreamble(entries[i].content),
                  turnNote(from: entries[i].content) != nil {
                merged.insert(i)
                i += 1
            }
        }
        // 存量数据防洪：旧版中断重试遗留的重复评分卡同样并入（不落独立胶囊）
        merged.formUnion(duplicateScorecardIndices(in: entries))
        return merged
    }

    /// 快速通道链式续段判定（index 可为 entries.count，即流式中的下一回合）：
    /// 前方只跨越连续系统行即可回溯到另一 assistant，且跨越的系统行里有「快速通道」
    /// 标记（⚡ 受理行 / 📦（快速通道：自动确认）行）。链上续段共享首回合的回答头——
    /// 一条用户消息只出一条连续回答，不再「连答多次」各带 Agent 头。
    /// 常规确认推进（无标记）与被用户消息隔断的回合不判链，保留独立回答头。
    static func isFastForwardChainedBefore(_ index: Int, in entries: [DiscussionEntry]) -> Bool {
        var chained = false
        var i = index - 1
        while i >= 0, entries[i].role == .system, entries[i].memory == nil {
            if entries[i].content.contains("快速通道") { chained = true }
            i -= 1
        }
        return chained && i >= 0 && entries[i].role == .assistant
    }

    /// 流式回合头部将吸收的尾部系统行索引（与 streamingHeaderNotes 的合并判据一致）。
    /// displayItems 据此跳过独立胶囊渲染——否则同一行「独立卡 + 流式头部注记」双渲染
    /// 持续整个生成过程（流式条目落盘后才由 mergedSystemIndices 接管去重）。
    static func streamingAbsorbedIndices(in entries: [DiscussionEntry]) -> Set<Int> {
        var absorbed = Set<Int>()
        var i = entries.count - 1
        while i >= 0,
              entries[i].role == .system, entries[i].memory == nil,
              isTurnPreamble(entries[i].content),
              turnNote(from: entries[i].content) != nil {
            absorbed.insert(i)
            i -= 1
        }
        return absorbed
    }

    /// 评分卡整个 PRD 流程只显示一次：保留会话中首条「score」里程碑行，
    /// 其余（旧版 generatePRD 无落盘去重凭据时中断重试追加的重复卡）在显示层折叠。
    /// 源头已由 score-card.json 复用防重（AppModel.generatePRD），此处仅消化存量历史数据。
    static func duplicateScorecardIndices(in entries: [DiscussionEntry]) -> Set<Int> {
        var firstSeen = false
        var dups = Set<Int>()
        for (index, entry) in entries.enumerated()
        where entry.role == .system
            && (entry.milestones ?? []).contains(where: { $0.kind == "score" }) {
            if firstSeen {
                dups.insert(index)
            } else {
                firstSeen = true
            }
        }
        return dups
    }

    /// 截断卡「重新发送」的原始消息查找（internal 供测试）：
    /// 向上找指定条目之前最近一条**真实**用户输入（文本 + 附图文件名）。
    /// 跳过历史遗留的「重新生成×」合成指令——旧版截断卡点击会在会话里堆积这类
    /// 伪用户消息，截断-重试循环后最近一条往往是它，不跳过就会把指令误当原始消息重发。
    static func originalUserMessage(
        before id: String, in entries: [DiscussionEntry]
    ) -> (content: String, images: [String])? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        for prior in entries[..<idx].reversed() {
            guard prior.role == .user else { continue }
            let text = prior.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("重新生成") { continue }
            return (text, prior.images ?? [])
        }
        return nil
    }

    /// 产物块已出全宽结果卡的文件相对路径 → 落盘文件卡据此跳过，防同文件双卡。
    /// 原型卡常驻（不受摘要条影响）；PRD 卡仅在无交付摘要条的旧会话回退路径出
    /// （digestVisible = false 时），摘要条承载期 PRD 由落盘文件卡出卡。
    fileprivate static func blockCardPaths(
        blocks: [ArtifactParser.ArtifactBlock],
        project: String,
        version: String,
        digestVisible: Bool
    ) -> Set<String> {
        var paths: Set<String> = []
        for (name, path) in [("prototype", ArtifactPath.prototype), ("prd", ArtifactPath.prd)] {
            guard blocks.contains(where: { $0.name == name }),
                  artifactFileURL(name, project: project, version: version) != nil else { continue }
            if name == "prd" && digestVisible { continue }
            paths.insert(path)
        }
        return paths
    }

    /// 回合尾部注记 → 摘要条装配（方案 B 一行摘要按需展开）。
    /// - rows：审计行（漏项雷达 / 决策记录 / 风险超限 / 评分卡 / 下一节点），顺序即落盘顺序；
    /// - absorbedCards：被里程碑吸收且携带文件变更的注记 → 落盘文件卡独立渲染在摘要条外；
    /// - leftovers：无里程碑载荷的注记 → 原样渲染（旧会话回退路径）。
    /// 机器初审结论（✅ 通过 / ℹ️ 跳过）不单独成行，吸收为下一节点的「待确认」状态。
    static func milestoneAssembly(
        from notes: [TurnNote]
    ) -> (rows: [MilestoneRow], absorbedCards: [TurnNote], leftovers: [TurnNote]) {
        var rows: [MilestoneRow] = []
        var absorbedCards: [TurnNote] = []
        var leftovers: [TurnNote] = []
        var stageLabel: String?
        var stageAction: String?
        var reviewDone = false

        for note in notes {
            if let stamps = note.milestones, !stamps.isEmpty {
                if let changes = note.fileChanges, !changes.isEmpty {
                    absorbedCards.append(note)
                }
                for stamp in stamps {
                    switch stamp.kind {
                    case "radar":
                        let count = stamp.count ?? 0
                        rows.append(MilestoneRow(
                            id: "radar@\(rows.count)", icon: .search, tint: .ink500,
                            name: "自评审",
                            countText: count > 0 ? "\(count) 项" : "零缺项",
                            detail: stamp.detail,
                            destination: "右栏「风险」",
                            tab: .radar
                        ))
                    case "risk":
                        // 风险登记 / 跨门核验提醒：琥珀计数行，点击直达风险台账
                        rows.append(MilestoneRow(
                            id: "risk@\(rows.count)", icon: .warningFill, tint: .statusWarning,
                            name: "风险",
                            countText: stamp.count.map { "+\($0) 条" },
                            detail: stamp.detail,
                            destination: "右栏「风险」台账",
                            tab: .radar
                        ))
                    case "decision":
                        rows.append(MilestoneRow(
                            id: "decision@\(rows.count)", icon: .bookmark, tint: .ink500,
                            name: "决策记录",
                            countText: stamp.count.map { "+\($0) 条" },
                            detail: stamp.detail,
                            destination: "右栏「决策日志」",
                            tab: .decisions
                        ))
                    case "stage":
                        stageLabel = stamp.label ?? "产物"
                        stageAction = stamp.nextAction
                    case "score":
                        // 评分卡：三格维度条 + 选档结论（理由收进 hover，零机器腔长句）
                        let tier = stamp.label ?? "standard"
                        let tierName = ["lean": "精简", "standard": "标准", "full": "完整"][tier] ?? tier
                        rows.append(MilestoneRow(
                            id: "score@\(rows.count)", icon: .barList, tint: .ink500,
                            name: "PRD 评分卡",
                            tail: "→ \(tierName)档模板（\(tier)）",
                            detail: "判断有误？回复「用 lean / standard / full 档」一键切换",
                            dims: stamp.dims
                        ))
                    case "warn":
                        // 旧版软上限警示（历史载荷；新版不再发射）：琥珀计数行，点击直达风险台账
                        if let count = stamp.count {
                            rows.append(MilestoneRow(
                                id: "warn@\(rows.count)", icon: .warningFill,
                                tint: .statusWarning,
                                name: "活跃风险",
                                countText: "\(count) 条",
                                detail: stamp.detail,
                                destination: "右栏「风险」",
                                tab: .radar
                            ))
                        }
                    default:
                        break
                    }
                }
                continue
            }
            // 机器门结论吸收进下一节点状态（行文本不再单独渲染）
            if note.text.hasPrefix("机器初审通过") || note.text.hasPrefix("机器初审跳过") {
                reviewDone = true
                continue
            }
            // 存量超限警示（无载荷旧数据）：按 RiskStore 稳定发射格式解析为琥珀行，
            // 解析失败（格式漂移）回退普通注记行，不丢警示
            if let warn = warnRow(fromText: note.text, index: rows.count) {
                rows.append(warn)
                continue
            }
            leftovers.append(note)
        }

        // 下一节点：阶段产物已落盘 → 数据行记录（标题派生「已交付 X」）/
        // 机器初审中（等待态，摘要条 footer 展示）。推进入口在确认坞 / 自由作答。
        if stageLabel != nil || stageAction != nil {
            if reviewDone {
                rows.append(MilestoneRow(
                    id: "next", icon: .arrowRight, tint: .brandAccent,
                    name: "\(stageLabel ?? "产物")待确认",
                    tail: stageAction,
                    isNext: true
                ))
            } else {
                rows.append(MilestoneRow(
                    id: "next", icon: .clock, tint: .ink500,
                    name: "机器初审中"
                ))
            }
        }
        // 评分卡行已说「→ X 档模板」，头部「开始撰写 X 档 PRD」注记重复 → 吸收
        if rows.contains(where: { $0.id.hasPrefix("score@") }) {
            leftovers.removeAll { $0.text.hasPrefix("开始撰写") }
        }
        return (rows, absorbedCards, leftovers)
    }

    /// 存量超限警示行解析（无载荷旧会话）：
    /// 「活跃 💀 已达 N 条（软上限 M 条）：建议…」——发射格式由 RiskStore.append 固定；
    /// 前缀不匹配或计数解析失败返回 nil，回退普通注记行渲染。
    static func warnRow(fromText text: String, index: Int) -> MilestoneRow? {
        guard text.hasPrefix("活跃 💀 已达") else { return nil }
        func number(after marker: String) -> Int? {
            guard let markerRange = text.range(of: marker) else { return nil }
            let rest = text[markerRange.upperBound...]
            guard let unitRange = rest.range(of: " 条") else { return nil }
            return Int(rest[..<unitRange.lowerBound])
        }
        guard let count = number(after: "已达 ") else { return nil }
        let limit = number(after: "软上限 ")
        var advice: String?
        if let colon = text.range(of: "：") {
            advice = String(text[colon.upperBound...])
        }
        var detail: String?
        if let limit {
            detail = "软上限 \(limit) 条" + (advice.map { " · \($0)" } ?? "")
        } else {
            detail = advice
        }
        return MilestoneRow(
            id: "warn@\(index)", icon: .warningFill, tint: .statusWarning,
            name: "活跃风险", countText: "\(count) 条", detail: detail,
            destination: "右栏「风险」", tab: .radar
        )
    }

    /// 本应用系统行使用的事件 emoji（含变体选择符，按 Character 整体匹配）。
    /// 💬 = 安静留痕提示（已收起确认等），渲染层剥离 emoji 后走居中纯文本。
    fileprivate static let eventEmojis: Set<String> = [
        "✅", "⚠️", "🏗️", "🎨", "📝", "🎚️", "📦", "📊", "🔍", "🔒", "🔄", "💀", "🗃️", "🔀", "📌", "ℹ️", "⏹", "⏳", "💬"
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
        // 跨门核验提醒（已挂方案的风险待验证）：中性时钟条
        if content.hasPrefix("⏳") {
            return (.clock, Color.ink500, Color.surfaceSecondary)
        }
        // 停止生成注记（用户主动终止流式回复；中性信息条，非错误非警告）
        if content.hasPrefix("⏹") {
            return (.stop, Color.ink500, Color.surfaceSecondary)
        }
        return (.dot, Color.ink500, Color.surfaceSecondary)
    }
}

/// 消息等价判据（配合 .equatable()）：流式期间对话页每秒十次重渲染，
/// 历史消息在此短路——不再重跑 entry 的产物解析 / Markdown 解析 / 时间格式化。
/// 闭包（onOpenSink/onResend）不参与比较：由调用方每帧重建、语义恒定；
/// entry/notes 任一变化（含 footerNotes 随新系统行并入）即不等，触发重渲染。
extension MessageBubble: Equatable {
    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.entry == rhs.entry
            && lhs.stage == rhs.stage
            && lhs.showOptions == rhs.showOptions
            && lhs.headerNotes == rhs.headerNotes
            && lhs.footerNotes == rhs.footerNotes
            && lhs.chainContinuation == rhs.chainContinuation
            && lhs.project == rhs.project
            && lhs.version == rhs.version
            && lhs.resendEnabled == rhs.resendEnabled
    }
}

/// 文件字节数 → 人类可读大小（KB / MB 一位小数；读取失败按 0 兜底）。
private func fileSizeText(_ url: URL) -> String {
    let bytes: Int
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int {
        bytes = size
    } else {
        bytes = 0
    }
    let kb = Double(bytes) / 1024
    return kb >= 1024
        ? String(format: "%.1f MB", kb / 1024)
        : String(format: "%.1f KB", max(kb, 0.1))
}

/// 扩展名 → 类型元信息（产物族语境：.html 即原型）。
private func fileTypeLabel(_ path: String) -> String {
    if path.hasSuffix(".html") { return "HTML 原型" }
    if path.hasSuffix(".md") { return "Markdown 文档" }
    if path.hasSuffix(".json") || path.hasSuffix(".jsonl") { return "JSON 数据" }
    return "文件"
}

/// 扩展名 → 自绘图标（.html 浏览器 / .md markdown / 其余文档回退）。
private func fileIcon(_ path: String) -> DSIcon.Name {
    if path.hasSuffix(".html") { return .browser }
    if path.hasSuffix(".md") { return .markdown }
    return .doc
}

/// 相对版本目录的产物路径 → 卡片标题：映射回 artifact 块名复用 artifactDisplayName
/// （产物中文名单一事实源），未知路径回退去扩展名文件名。
private func artifactCardTitle(_ relativePath: String) -> String {
    let blockName: String?
    switch relativePath {
    case ArtifactPath.architecture: blockName = "architecture"
    case ArtifactPath.coreFlows: blockName = "core-flows"
    case ArtifactPath.modulePageMap: blockName = "module-page-map"
    case ArtifactPath.businessFlows: blockName = "business-flows"
    case ArtifactPath.prototype: blockName = "prototype"
    case ArtifactPath.prd: blockName = "prd"
    case ArtifactPath.competitiveAnalysis: blockName = "analysis"
    default: blockName = nil
    }
    if let blockName { return artifactDisplayName(blockName) }
    let filename = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    return (filename as NSString).deletingPathExtension
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
    case "architecture": relativePath = ArtifactPath.architecture
    case "core-flows": relativePath = ArtifactPath.coreFlows
    case "module-page-map": relativePath = ArtifactPath.modulePageMap
    case "business-flows": relativePath = ArtifactPath.businessFlows
    case "prototype": relativePath = ArtifactPath.prototype
    case "prd": relativePath = ArtifactPath.prd
    case "analysis": relativePath = ArtifactPath.competitiveAnalysis
    default: relativePath = nil  // radar/decision 落 jsonl，右栏 Tab 承载
    }
    guard let relativePath, !project.isEmpty, !version.isEmpty else { return nil }
    let url = PMAgentStore.versionURL(project: project, version: version)
        .appendingPathComponent(relativePath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// 产物块渲染区：结构图表（architecture/core-flows/business-flows = mermaid 图源，
/// module-page-map = 管道表格 markdown）内联直接渲染；文件类产物（原型 / PRD / 竞品
/// 分析等）已落盘可交互 → 全宽生成文件卡，未落盘 / jsonl 类 → 中性提示胶囊降级。
private struct ArtifactBlocksSection: View {
    let blocks: [ArtifactParser.ArtifactBlock]
    var project: String = ""
    var version: String = ""
    /// 雷达 / 决策入账已由交付摘要条承载（方案 B）、PRD 由落盘文件卡承载 → 不再重复
    /// 渲染提示胶囊；旧会话（无里程碑载荷）与流式中保持 false，回退胶囊提示。
    var hideSinkChips: Bool = false
    /// 点击文件产物卡片 → 打开预览；nil = 非交互提示态（流式中）
    var onOpen: ((FileNode) -> Void)? = nil

    /// 内容为空（异常流）→ 退回胶囊兜底。
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
            // 原型结果卡：阶段主交付物，全宽块卡（与图表卡 / 生成文件卡 / 交付摘要条
            // 同族容器），不进胶囊流——FlowLayout 按理想尺寸摆放会把卡压成窄条
            ForEach(blocks.filter { $0.name == "prototype" }, id: \.name) { block in
                prototypeBlock(block)
            }
            // 文件类产物卡（prd / analysis 等已落盘可交互）：与原型卡同族的生成文件卡，
            // 全宽；prd 在交付摘要条承载期（hideSinkChips）不出卡——落盘文件卡已覆盖
            ForEach(blocks.filter(showsFileCard), id: \.name) { block in
                fileCard(block)
            }
            let pillBlocks = blocks.filter {
                !isInlineChart($0) && $0.name != "prototype" && $0.name != "backtrack"
                    && $0.name != "fast-forward" && !showsFileCard($0)
            }
            if !pillBlocks.isEmpty {
                FlowLayout(spacing: DS.Spacing.s6) {
                    ForEach(pillBlocks, id: \.name) { block in
                        pill(block)
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

    /// 原型块：已落盘且可交互 → 全宽生成文件卡（Claude artifacts 式）；
    /// 流式中 / 未落盘 → 中性提示胶囊回退。
    @ViewBuilder
    private func prototypeBlock(_ block: ArtifactParser.ArtifactBlock) -> some View {
        if let onOpen, let url = artifactFileURL(block.name, project: project, version: version) {
            GeneratedFileCard(
                title: artifactDisplayName(block.name),
                metaText: "HTML 原型 · \(fileSizeText(url))",
                icon: .browser,
                helpText: "点击预览原型（弹窗内置「在浏览器打开」兜底）"
            ) {
                onOpen(FileNode(
                    name: artifactDisplayName(block.name),
                    url: url,
                    isDirectory: false,
                    children: nil
                ))
            }
        } else {
            neutralPill(block.name)
        }
    }

    /// 文件类产物块出卡判据：已落盘且可交互（流式 onOpen = nil 不出卡）；
    /// 结构图表块（architecture / core-flows / business-flows / module-page-map）已内联
    /// 渲染，不再出文件卡——否则同一产物「内联图表 + 文件卡」双渲染（落盘后必现）；
    /// prd 在交付摘要条承载期（hideSinkChips）不出卡——落盘文件卡已覆盖。
    private func showsFileCard(_ block: ArtifactParser.ArtifactBlock) -> Bool {
        guard onOpen != nil, !isInlineChart(block), block.name != "prototype",
              !(block.name == "prd" && hideSinkChips),
              artifactFileURL(block.name, project: project, version: version) != nil
        else { return false }
        return true
    }

    /// 文件类产物卡：与原型结果卡同族（图标块 + 名称 + 类型/大小 + 预览入口）。
    @ViewBuilder
    private func fileCard(_ block: ArtifactParser.ArtifactBlock) -> some View {
        if let onOpen, let url = artifactFileURL(block.name, project: project, version: version) {
            GeneratedFileCard(
                title: artifactDisplayName(block.name),
                metaText: "\(fileTypeLabel(url.path)) · \(fileSizeText(url))",
                icon: fileIcon(url.path)
            ) {
                onOpen(FileNode(
                    name: artifactDisplayName(block.name),
                    url: url,
                    isDirectory: false,
                    children: nil
                ))
            }
        }
    }

    /// 中性提示胶囊回退区：jsonl 类（radar / decision）、流式未落盘、旧会话回退；
    /// 交付摘要条承载期（hideSinkChips）的雷达 / 决策 / PRD 静默不渲染。
    @ViewBuilder
    private func pill(_ block: ArtifactParser.ArtifactBlock) -> some View {
        if hideSinkChips
            && (block.name == "radar" || block.name == "decision" || block.name == "prd") {
            // 摘要条 / 落盘文件卡已承载，不再重复提示
        } else {
            neutralPill(block.name)
        }
    }

    /// 中性提示胶囊（产物已生成但不可交互：流式未落盘 / jsonl 类回退）。
    private func neutralPill(_ name: String) -> some View {
        HStack(spacing: DS.Spacing.s6) {
            DSIcon(.fileUpload, size: 11)
            Text(artifactDisplayName(name) + "已生成")
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

// MARK: - 生成文件卡（Claude artifacts 式：图标块 + 名称 + 类型/大小元信息 + 预览入口）
// 全宽块卡，容器规格对齐交付摘要条 / 生成进度卡同族；原型结果卡与落盘文件卡共用同一视觉。

private struct GeneratedFileCard: View {
    let title: String
    /// 类型 · 大小 元信息行（如「HTML 原型 · 46.7 KB」）。
    let metaText: String
    let icon: DSIcon.Name
    var helpText: String = "点击预览文件内容"
    let onOpen: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: DS.Spacing.s12) {
                DSIcon(icon, size: 16)
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(Color.brand100)
                    )
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(title)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help(helpText)
    }
}

// MARK: - 落盘文件卡（📦 产物落盘行携带 fileChanges：本次回答落盘了哪些文件）

/// 每个落盘文件一张生成文件卡（与原型结果卡同族：图标块 + 名称 + 类型/大小 + 预览），
/// 取代旧「N 个文件已更改」折叠卡；产物块结果卡已承载的文件经 skipPaths 跳过防双卡。
/// 注记随会话持久化，是事实记录而非临时通知，故无关闭 ×。
private struct FileChangeCards: View {
    let changes: [FileChangeSummary]
    let project: String
    let version: String
    /// 已由产物块结果卡渲染的文件相对路径（如原型卡 → 可点击原型.html）。
    var skipPaths: Set<String> = []
    let onOpen: (FileNode) -> Void

    /// 去重（防御同回合重复路径）+ 跳过结果卡已承载的文件，顺序保持落盘顺序。
    private var displayed: [FileChangeSummary] {
        var seen: Set<String> = []
        return changes.filter { change in
            !skipPaths.contains(change.path) && seen.insert(change.path).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            ForEach(displayed, id: \.path) { change in
                let url = PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(change.path)
                GeneratedFileCard(
                    title: artifactCardTitle(change.path),
                    metaText: "\(fileTypeLabel(change.path)) · \(fileSizeText(url))",
                    icon: fileIcon(change.path)
                ) {
                    onOpen(FileNode(
                        name: artifactCardTitle(change.path),
                        url: url,
                        isDirectory: false,
                        children: nil
                    ))
                }
            }
        }
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

/// 产物块未闭合（输出撞 max_tokens 且自动续写仍未写完）的兜底卡：
/// 收起长代码，说明情况并给出下一步动作，避免整屏 HTML 刷屏。
/// 右侧「重新发送」按钮重发触发本回答的原始用户消息，走完整标准发送链路。
private struct ArtifactTruncatedCard: View {
    let name: String
    /// 发送按钮可用性（流式生成中 / 封板版本 = false，防重复提交与误发）。
    var sendEnabled: Bool = true
    /// 一键发送回调；nil = 不显示按钮（只读兜底）。
    var onSend: (() -> Void)? = nil

    /// 点击后钉住「已发送」态：原始消息已进消息流，按钮不再可点。
    @State private var sent = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s10) {
            DSIcon(.warningFill, size: 15)
                .foregroundStyle(Color.statusWarning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text("\(artifactDisplayName(name))未写完")
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                Text("输出在写入过程中被截断，产物尚未落盘。点击「重新发送」重发你的原始消息，我会完整重新生成并落盘。")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onSend {
                Button {
                    guard !sent, sendEnabled else { return }
                    sent = true
                    onSend()
                } label: {
                    HStack(spacing: DS.Spacing.s4) {
                        DSIcon(sent ? .check : .send, size: 12)
                        Text(sent ? "已发送" : "重新发送")
                    }
                }
                .buttonStyle(.ds(sent ? .secondary : .brand, size: .sm))
                .disabled(!sendEnabled || sent)
                .help(sendEnabled ? "重发触发本回答的原始消息（与手动发送走同一链路）" : "生成中 / 封板版本暂不可发送")
            }
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.statusWarningSurface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }
}

// MARK: - 流式正文（与最终消息同构的产物渲染 + 进行中原型进度卡）

/// 流式期间的 AI 正文：已完成 artifact 块与最终消息同构（图表内联 / 产物 chip）。
/// prototype / prd 收进生成进度卡（长产物源码刷屏无阅读价值；PRD 按用户要求
/// 仅展示进度状态与完成提示，不显示文档源码内容）；其余文字型产物保留原文流式。
private struct StreamingContentBody: View {
    let text: String
    var project: String = ""
    var version: String = ""

    /// 收进进度卡的块名（流式中收起源码，只显进度）。
    private static let progressCardBlocks: Set<String> = ["prototype", "prd"]

    /// （展示文本, 已完成块, 进行中的产物块）
    private func content() -> (
        display: String,
        blocks: [ArtifactParser.ArtifactBlock],
        incomplete: (name: String, partial: String)?
    ) {
        let blocks = ArtifactParser.parseArtifactBlocks(in: text)
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: text)
            .flatMap { Self.progressCardBlocks.contains($0.name) ? $0 : nil }
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
                // Markdown 实时渲染（未闭合普通围栏容错到文末）；
                // liveMermaid = false：流式中的 mermaid 围栏降级为代码块，
                // 避免逐 tick 的 WKWebView 整页重载（流结束转正式条目后恢复图表）
                MarkdownText(content.display, liveMermaid: false)
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

/// 思考强度按钮（对话页 Composer 与新建任务输入卡共用）：信号柱图标 + 当前档位
/// 文本（用户要求显式展示所选项，否则不知道选的是什么强度）；点击弹档位菜单
/// （Low/Medium/High/Max，High 是服务端默认档标注「默认」，勾号跟随当前选择）。
/// 图标与文本统一亮品牌色（用户要求各档位颜色一致，不按默认/非默认区分）。
struct ComposerEffortButton: View {
    @ObservedObject var store: SessionStore
    /// 紧凑档不显示档位文本（新建任务窄卡 ViewThatFits 回退行用，只留图标）。
    var showsLabel: Bool = true

    @State private var menuOpen = false
    @State private var hovered = false

    var body: some View {
        Button {
            menuOpen.toggle()
        } label: {
            HStack(spacing: DS.Spacing.s3) {
                DSIcon(.qps, size: 13)
                    .foregroundStyle(effortTint)
                if showsLabel {
                    Text(store.thinkingEffort.displayName)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(effortTint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(hovered || menuOpen ? Color.overlayL2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .accessibilityLabel("思考强度 · \(store.thinkingEffort.displayName)")
        .help("思考强度 · \(store.thinkingEffort.displayName)")
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            menu
                .presentationBackground(.clear)  // 去系统底，露出 DSMenu 玻璃卡
        }
    }

    private var effortTint: Color {
        Color.brand600
    }

    private var menu: some View {
        DSMenu(minWidth: 180) {
            Text("思考强度")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .padding(.horizontal, DS.Spacing.s8)
                .padding(.bottom, DS.Spacing.s2)
            ForEach(ThinkingEffort.allCases) { effort in
                DSMenuItem(
                    title: effort == .high ? "High（默认）" : effort.displayName,
                    isSelected: store.thinkingEffort == effort,
                    titleFont: DS.Font.bodySM
                ) {
                    store.thinkingEffort = effort
                    menuOpen = false
                }
            }
        }
    }
}

/// 对话模型切换器（2026-09-14 多模型管理；对话页与新建任务输入卡共用）：
/// 当前模型 chip（agent 图标 + mono 模型名 + 下拉箭头）→ DSMenu 弹层列出
/// 全部启用模型（勾号标记使用中，次行供应商名辅助区分），分隔线后「添加模型…」
/// 直达设置弹框模型页。切换即写透 stages（下一次请求生效）并落盘，无需重启。
struct ComposerModelButton: View {
    @ObservedObject var model: AppModel
    /// 紧凑档不显示模型名（窄卡 ViewThatFits 回退行用，只留图标）。
    var showsLabel: Bool = true

    @State private var menuOpen = false
    @State private var hovered = false

    /// 切换器数据源：启用档案（全禁用时数据层保底返回使用中档案）。
    private var profiles: [ModelProfile] { model.settings.switcherProfiles }

    private var activeProfile: ModelProfile? { model.settings.activeProfile }

    private var activeModelName: String {
        guard let profile = activeProfile else { return "未配置" }
        return profile.model
    }

    var body: some View {
        Button {
            menuOpen.toggle()
        } label: {
            HStack(spacing: DS.Spacing.s3) {
                DSIcon(.agent, size: 13)
                    .foregroundStyle(Color.ink500)
                if showsLabel {
                    Text(activeModelName)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink700)
                        .lineLimit(1)
                }
                DSIcon(.down, size: 8)
                    .foregroundStyle(Color.ink300)
            }
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(hovered || menuOpen ? Color.overlayL2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .accessibilityLabel("对话模型 · \(activeModelName)")
        .help("切换对话模型（即时生效）")
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            menu
                .presentationBackground(.clear)  // 去系统底，露出 DSMenu 玻璃卡
        }
    }

    private var menu: some View {
        DSMenu(minWidth: 240) {
            Text("模型")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .padding(.horizontal, DS.Spacing.s8)
                .padding(.bottom, DS.Spacing.s2)
            ForEach(profiles) { profile in
                DSMenuItem(
                    title: profile.model,
                    description: DSProviderOption.title(for: profile.provider),
                    isSelected: profile.id == activeProfile?.id,
                    titleFont: DS.Font.bodySM
                ) {
                    model.switchChatModel(to: profile.id)
                    menuOpen = false
                }
            }
            DSMenuDivider()
            DSMenuItem(
                title: "添加模型…", icon: .plus, titleFont: DS.Font.bodySM
            ) {
                menuOpen = false
                model.settingsPage = .model
                model.settingsPresented = true
            }
        }
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

/// 停止钮（32×32 · radius 10 状态红方块 + 白 stop 方块图标；与发送钮同形制互替，
/// 点击即终止当前生成——按钮态由 isStreaming 驱动，点击瞬间同步翻回「发送」）。
private struct ComposerStopButton: View {
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(.stop, size: 12)
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xl)
                        .fill(
                            // 坑：三元必须写全类型
                            hovered ? Color.statusError.opacity(0.85) : Color.statusError
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.xl))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help("停止生成")
    }
}

// MARK: - IME 组字检测（占位文案伴生）

/// 中文输入法组字（拼音未上屏）期间文本在 NSTextView.markedText 里，
/// SwiftUI 的 TextEditor 绑定仍是空串——占位只看 `draft.isEmpty` 会压在
/// 组字文本下面（与拼音重叠）。
/// 通知选型（/tmp/ime_test2.swift 实证，2026-09-13）：组字的 setMarkedText
/// **不**发 NSText.didChangeNotification，也从不发 NSControl 的
/// textDidChangeNotification（那是 NSControl/field editor 专用，TextEditor
/// 内部 NSTextView 不走）；每次 setMarkedText / insertText 都稳定触发
/// NSTextView.didChangeSelectionNotification——以它为主信号 + textDidChange
/// 补位。通知触发瞬间 markedRange 可能尚未落定（同一 mutation 通知在前、
/// 状态在后），异步读最终态。
struct IMEComposingDetector: NSViewRepresentable {
    @Binding var isComposing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isComposing: $isComposing) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private let isComposing: Binding<Bool>
        private weak var host: NSView?
        private var tokens: [NSObjectProtocol] = []

        init(isComposing: Binding<Bool>) { self.isComposing = isComposing }

        func attach(to view: NSView) {
            host = view
            let names: [Notification.Name] = [
                NSTextView.didChangeSelectionNotification,
                NSText.didChangeNotification
            ]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    self?.handle(note)
                }
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }

        private func handle(_ note: Notification) {
            // 只响应本窗口当前第一响应者文本视图（SwiftUI TextEditor 的内部
            // NSTextView 成为焦点时它即第一响应者），其他视图输入不影响本占位。
            guard let window = host?.window,
                  let textView = note.object as? NSTextView,
                  window.firstResponder === textView
            else { return }
            // 通知先于 markedRange 落定，异步读最终态
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let composing = textView.markedRange().location != NSNotFound
                if self.isComposing.wrappedValue != composing {
                    self.isComposing.wrappedValue = composing
                }
            }
        }
    }
}
