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
    /// 作答段开关（统一停靠卡 StageDockCard 内）：待答问题出现自动弹出一次；
    /// 显式关闭后同问题不再自动弹出（触发 chip 兜底）。
    @State private var showClarifyDrawer = false
    @State private var clarifyAutoOpenedId: String?
    @State private var clarifyDismissedId: String?
    /// 瞬态提示。
    @State private var notif: DSNotifMessage?
    /// 深浅色切换过渡动画的值锚点（对话框平滑变色的观察源）。
    @Environment(\.colorScheme) private var colorScheme
    /// 待发送附图（已拷入 attachments/，文件名引用 + 缩略预览）。
    @State private var pendingImages: [PendingImage] = []
    /// 待发送的引用文件（相对版本目录路径；正文在发送时读盘注入本轮上下文）。
    @State private var pendingFileRefs: [String] = []
    /// 吸底跟随开关：流式增量只在「视口本就在底部」时自动跟随。
    /// 用户向上滚动（滚轮/触控板/滚动条/键盘）即解除，滚回底部或新回合开始时恢复——
    /// 否则每次追底的 scrollTo 会把视口钉死在底部，表现为「生成中无法向上滚动」。
    /// 解锁判定用「距底增量 vs 内容增量」纯几何判据（ScrollFollowJudge），
    /// 不依赖 scrollPhase（滚轮离散事件在几何回调前 phase 可能已回 idle，会漏判）。
    @State private var stickToBottom = true
    /// 回到底部浮钮：距底 > 50pt 显示，≤ 50pt（含已吸底 / 内容不足一屏）隐藏。
    @State private var showJumpToBottom = false
    @State private var jumpToBottomHovered = false

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
            // 聚光灯推荐已收口到左栏知识库整页（2026-09-17 钦定），
            // 聊天流只留过程反馈——原内嵌 RecommendationStrip 移除
            // 统一停靠卡（作答段 → 确认段，同卡分步切换）：待答问题先作答，
            // 答毕 / 显式关闭后同卡切换为阶段确认（闸口）。两段弹出纪律均不变——
            // 作答段：新问题自动弹出一次，显式关闭后由触发 chip 兜底重开；
            // 确认段：每版本每阶段弹一次，「稍后再说」持久静默，推进改由自由作答发起
            //（design.md §6.1）。一次确认：① 的收尾确认问点选「确认」项即闸口确认
            //（confirmStageByAnswer），答案留痕后直接收束，不再切确认段二次确认
            if stageDockVisible {
                StageDockCard(
                    model: model,
                    store: store,
                    pending: pendingQuestion,
                    showAnswerSection: showClarifyDrawer,
                    confirmTarget: confirmDockTarget,
                    branchPending: branchPending,
                    stageLabel: stageShortName,
                    onCloseAnswer: closeClarifyDrawer,
                    onSubmitAnswer: submitClarifyAnswer
                )
                DSDivider()
            }
            // ④ 回退坞：显性入口——不必知道「魔法话术」也能重做上游，
            // 与 LLM 回退块同一执行路径（回退 + 自动重生成，诉求可在弹出的生成里继续说）
            // 只在 PRD 生成会话渲染（闸口归属会话口径，同 ConfirmDock）
            // 本会话口径（阶段 3）：回溯重发本会话消息，他会话的流不隐藏本坞
            if pipeline.stage == .prd, !store.isSessionBusy(store.sessionId),
               !model.currentVersionReleased, model.isGateOwnerSession {
                BacktrackDock(model: model)
                DSDivider()
            }
            // 作答触发 chip：作答段已收起（显式关闭）但问题仍待答时的兜底入口，
            // 点击重新弹出作答段（同卡切回作答）
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
        // 作答坞：新待答问题出现（entry id 变化）→ 自动弹出一次；
        // 已答 / 已岔开（pending 清空）→ 坞收起
        .onChange(of: pendingQuestion?.entryId) { _, newId in
            if newId == nil {
                if showClarifyDrawer {
                    withAnimation(DS.Motion.spring) { showClarifyDrawer = false }
                }
            } else {
                syncClarifyDrawerAutoOpen()
            }
        }
        // 流结束才判定新问题（流式写一半的末尾选项行不触发）
        // 本会话口径（阶段 3）：他会话的流结束不再触发本会话抽屉同步
        .onChange(of: store.streams[store.sessionId]?.isStreaming ?? false) { _, streaming in
            guard !streaming else { return }
            syncClarifyDrawerAutoOpen()
        }
        // 打开会话即有待答问题 → 自动弹出一次
        .task { syncClarifyDrawerAutoOpen() }
        // 产物右键「添加到对话」：消费待插文件引用（onAppear 兜底跨页排队场景）
        .onAppear { consumePendingFileReference() }
        .onChange(of: model.pendingFileReference) { _, _ in
            consumePendingFileReference()
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
            .appendingPathComponent(ArtifactPath.releaseNotes)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 顶栏（原型 vibrancy 44 高：返回 · 项目名 · 会话胶囊 · 目标 · 成本；
    //  版本切换下拉已摘除——版本归属由左栏树 / 项目主页表达，顶栏不再重复）

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
                .lineLimit(1)
                .truncationMode(.tail)

            sessionChip

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
    /// 与澄清作答坞互斥：作答时开记忆抽屉会遮住底部作答坞，开一个关另一个。
    private func toggleMemoryDrawer() {
        withAnimation(DS.Motion.spring) {
            showMemoryDrawer.toggle()
            if showMemoryDrawer, showClarifyDrawer {
                showClarifyDrawer = false
            }
        }
    }

    // MARK: - 统一停靠卡（作答段开合 / 提交 / 触发 chip）

    /// 确认段闸口（非 nil 即挂载确认段）：闸口就绪 + 本版本空闲 + 未静默。
    /// （本版本 busy 口径，阶段 3：确认坞属于当前版本闸口——他会话他版本的流
    /// 不再抑制本版本确认坞；本版本自身的流/占位（含待回复窗口）仍拦截，
    /// 防「正在思考」上方叠卡、开流后隐藏的闪现）
    private var confirmDockTarget: AppModel.ConfirmTarget? {
        guard let target = model.confirmTarget,
              !store.isVersionBusy(project: pipeline.project, version: pipeline.version),
              !model.isConfirmGateDeferred(target) else { return nil }
        return target
    }

    /// 分支确认待决（意图误触发防护）：归属本会话才可见（挂起态绑定发起会话），
    /// 本会话空闲（本会话口径，阶段 3：分支确认卡与本会话「正在思考」卡同位，
    /// 他会话的流不抑制本会话的裁决卡）。
    private var branchPending: AppModel.PendingBranchConfirmation? {
        guard !store.isSessionBusy(store.sessionId) else { return nil }
        guard let pending = model.pendingBranchConfirmation,
              pending.sessionId == store.sessionId else { return nil }
        return pending
    }

    /// 统一停靠卡可见性：作答段 / 分支确认段 / 确认段任一成立（卡内按优先级切段）；
    /// 确认链进行中（要点表抽取 / 下游生成）整卡抑制——防推进空窗内确认卡闪现。
    /// 抑制按会话键控（M2）：只有本会话的确认链在跑才抑制，他会话/他版本不拦。
    private var stageDockVisible: Bool {
        !model.stageConfirmRunningSessions.contains(store.sessionId)
            && ((pendingQuestion != nil && showClarifyDrawer)
                || branchPending != nil
                || confirmDockTarget != nil)
    }

    /// 待答问题出现 → 自动弹出一次；显式关闭后同问题不再自动弹出
    /// （兜底入口 = 输入区上方触发 chip）。本会话流式中不判定（写一半的选项行）；
    /// 他会话的流不拦截（本会话口径，阶段 3）。
    private func syncClarifyDrawerAutoOpen() {
        guard let pending = pendingQuestion, !store.isSessionBusy(store.sessionId) else { return }
        guard pending.entryId != clarifyAutoOpenedId else { return }
        clarifyAutoOpenedId = pending.entryId
        guard pending.entryId != clarifyDismissedId else { return }
        withAnimation(DS.Motion.spring) {
            showClarifyDrawer = true
            showMemoryDrawer = false
        }
    }

    /// 显式关闭（X / 跳过此题）：记下当前问题 id，同问题不再自动弹出。
    private func closeClarifyDrawer() {
        withAnimation(DS.Motion.spring) { showClarifyDrawer = false }
        clarifyDismissedId = pendingQuestion?.entryId
    }

    /// 作答坞提交（多题向导拼装消息 / 单题点选即发 / 自由输入）：
    /// 走 sendMessage 通道，答案随用户消息留痕，pending 清空后坞收起。
    /// 一次确认（① 澄清）：收尾确认问点选「确认」开头选项 = 闸口确认——答案留痕后
    /// 直接收束（要点表 + 进②），AI 不再应答一轮、确认段不再二次弹出。
    private func submitClarifyAnswer(_ text: String) {
        withAnimation(DS.Motion.spring) { showClarifyDrawer = false }
        if let pending = pendingQuestion, pending.wizard == nil, pending.isGateConfirm,
           AppModel.isGateConfirmSelection(text, options: pending.options?.options ?? []) {
            Task { await model.confirmStageByAnswer(text) }
            return
        }
        // PRD 前置确认卡（prd_preflight）：选完不走常规发言，答案留痕后直接
        // 以答案为指令串链快速通道出 PRD（选完直出，无二次确认）。
        if pendingQuestion?.wizard?.purpose == "prd_preflight" {
            Task { await model.submitPreflightCard(text) }
            return
        }
        Task { await model.sendMessage(text) }
    }

    /// 当前阶段短名（作答坞题干系统行的 mono 眉标：追问 · ③ 原型）。
    private var stageShortName: String {
        switch pipeline.stage {
        case .clarify: "① 澄清"
        case .structure: "② 结构"
        case .prototype: "③ 原型"
        case .prd: "④ PRD"
        }
    }

    /// 触发 chip：作答坞已收起但问题仍待答时的兜底入口。
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

    // MARK: - 消息流（纯文字回答块 · maxWidth 720 居中 · 消息间距 52 呼吸感）

    private var messageList: some View {
        ScrollViewReader { proxy in
            // edgeClearance：右栏展开时本栏右缘贴 HSplitView 分割条，滚动条内收让位——
            // 调右栏宽度的拖拽不被滚动条热区截胡（截胡 = 光标/手势变滚动条拖动）。
            DSScroll(edgeClearance: dsScrollDividerEdgeClearance) {
                // LazyVStack：长对话只实例化视口附近的消息（虚拟化）——
                // 旧 VStack 全量持有全部气泡视图，是长会话内存与滚动开销的主因。
                // 间距 0：轮距 52 改由逐项 topInset 承载（2026-09 呼吸感改版 B+C；
                // 提示行簇内 12–16，不吃整段轮距）。
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 空态展示本会话口径（阶段 3）：他会话的流不隐藏本会话空态
                    if store.entries.isEmpty && !store.isSessionBusy(store.sessionId) {
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
                            handover: item.handover,
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
                            // 重发本会话消息：本会话口径（阶段 3），他会话的流不禁用
                            resendEnabled: !store.isSessionBusy(store.sessionId)
                                && !model.currentVersionReleased,
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
                        .padding(.top, item.topInset)
                        .dsSlideIn()
                        .id(item.entry.id)
                    }
                    // 流式气泡只在归属会话内渲染：流态按会话键隔离（streams[sessionId]），
                    // 他会话的并发流不会显示到本会话（回复完成自动落回发起会话）。
                    // 待回复期（消息已上屏、提示词组装中）同位渲染同一气泡——
                    // 此时思考占位卡即「正在思考」，开流转正后无切换感。
                    if store.isSessionBusy(store.sessionId) {
                        streamingBubble(proxy: proxy, stickToBottom: stickToBottom)
                            .padding(.top, streamingTopInset)
                            .dsSlideIn()
                            .id("streaming")
                    }
                    // P3 插话排队气泡：未注入生效的插话（user 气泡半透明 + 「已排队」）。
                    // 注入生效 / 续发落盘后队列清空，由正式气泡替代。
                    if store.isSessionBusy(store.sessionId),
                       !store.currentSteeringQueue.isEmpty || !store.currentFollowUpQueue.isEmpty {
                        ForEach(store.currentSteeringQueue + store.currentFollowUpQueue) { entry in
                            steeringBubble(entry)
                                .padding(.top, DS.Spacing.s12)
                                .dsSlideIn()
                                .id(entry.id)
                        }
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Spacing.s20)
                .padding(.horizontal, DS.Spacing.s48)
                .padding(.bottom, DS.Spacing.s12)
            }
            .onChange(of: store.entries.count) { _, _ in
                guard stickToBottom else { return }
                scrollToBottom(proxy, animated: true)
            }
            // 流式期逐文本追底已下沉到 StreamingBubbleView（订阅流盒驱动）：
            // 父视图不再随 delta 重估，此处 onChange 会失聪。
            .onChange(of: store.streams[store.sessionId]?.isStreaming ?? false) { old, new in
                // 新回合开始（发送 / 采纳推荐 / 确认推进）→ 恢复吸底跟随，并立刻
                // 追到流式气泡（「正在思考…」卡）：思考阶段只有本会话流态 think 在变
                // （卡片高度固定），若不在此追底，首个正文 token 前视口纹丝不动，
                // 用户无从得知已在回答（采纳推荐 / 确认推进回合没有新用户气泡，
                // entries.count 追底也不会触发）。本会话口径：他会话开流不触发。
                guard new, !old else { return }
                stickToBottom = true
                // 异步一帧等条件分支（streamingBubble）完成挂载再滚，LazyVStack 才找得到 id
                DispatchQueue.main.async { scrollToBottom(proxy, animated: true) }
            }
            .onChange(of: store.streams[store.sessionId]?.isPreparing ?? false) { old, new in
                // 待回复态开始（发送 / followUp 续发）：思考占位卡与流式气泡同位，
                // 挂载即追底——followUp 续发无新 entries、isStreaming 尚未翻转，
                // 不在此追底则占位卡出现在视口外（发送轮有 entries.count 追底兜底）。
                guard new, !old else { return }
                stickToBottom = true
                DispatchQueue.main.async { scrollToBottom(proxy, animated: true) }
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
                // 回到底部浮钮显隐（同一几何回调顺带判距，不另挂监听）：
                // 距底 > 50pt 显示，≤ 50pt（含已吸底 / 内容不足一屏）隐藏。
                // onScrollGeometryChange 按帧合流回调，动作为 O(1) 判距 + 翻转才写态，
                // 无需额外节流器即无抖动；窗口尺寸变化同样触发，天然适配不同屏宽。
                let shouldShowJump = newBottom > Self.jumpToBottomThreshold
                if shouldShowJump != showJumpToBottom {
                    withAnimation(DS.Motion.springFast) { showJumpToBottom = shouldShowJump }
                }
            }
            // 回到底部浮钮：浮在滚动容器右下角（不随内容滚动），点击恢复吸底
            // 并平滑滚回底部。显隐 = 透明度 + 缩放 + 位移过渡（springFast）。
            .overlay(alignment: .bottomTrailing) {
                jumpToBottomButton(proxy: proxy)
                    .opacity(showJumpToBottom ? 1 : 0)
                    .scaleEffect(showJumpToBottom ? 1 : 0.7)
                    .offset(y: showJumpToBottom ? 0 : 8)
                    .allowsHitTesting(showJumpToBottom)
                    .padding(.trailing, DS.Spacing.s20)
                    .padding(.bottom, DS.Spacing.s12)
            }
        }
    }

    /// 回到底部浮钮的隐藏阈值：距底 ≤ 50pt 视为「已在底部附近」，与需求口径一致。
    nonisolated private static let jumpToBottomThreshold: CGFloat = 50

    /// 视口底缘到内容底缘的距离（含 insets；≤ 0 = 已在底部 / 内容不足一屏）。
    nonisolated private static func bottomDistance(of geo: ScrollGeometry) -> CGFloat {
        let maxOffset = geo.contentSize.height
            + geo.contentInsets.top + geo.contentInsets.bottom
            - geo.containerSize.height
        return maxOffset - geo.contentOffset.y
    }

    /// 滚到消息流底部：流式气泡（含待回复占位，同锚 id）在渲染时锚它，否则锚最后一条可见消息。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let streamingHere = store.streams[store.sessionId]?.isStreaming == true
        let preparingHere = store.streams[store.sessionId]?.isPreparing == true
        let target: String = if streamingHere || preparingHere {
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

    /// 回到底部浮钮：圆形浮层 + 向下箭头（DSIcon(.down)），hover 底色提亮。
    /// 点击 = 恢复吸底跟随 + 平滑滚回底部（复用 scrollToBottom 的锚点口径：
    /// 流式期锚「streaming」，否则锚最后一条消息）。浮层投影按 DS 纪律走
    /// .floating 极轻环境影；surfaceBase 底 + 发丝线描边，深浅色全自适应。
    private func jumpToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            jumpToBottomHovered = false
            stickToBottom = true
            scrollToBottom(proxy, animated: true)
        } label: {
            DSIcon(.down, size: 14)
                .foregroundStyle(Color.ink700)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(jumpToBottomHovered ? Color.surfaceSecondary : Color.surfaceBase)
                )
                .overlay(Circle().strokeBorder(Color.borderL2, lineWidth: 1))
                .dsShadow(.floating)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { jumpToBottomHovered = $0 }
        .accessibilityLabel("回到底部")
        .help("回到底部")
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

    /// 流式气泡：解析本会话流盒传给子视图（2026-09-18 吞吐修复）。成员增删
    /// （开流/收流/占位起止）经 streamBoxes 发布、驱动本气泡挂载/卸载；流式
    /// 增量只在盒上发布，由订阅盒的 StreamingBubbleView 承接——父视图不随
    /// delta 重估（探针实证：整页重渲染 ~0.3s/次曾吃满 MainActor）。
    @ViewBuilder
    private func streamingBubble(proxy: ScrollViewProxy, stickToBottom: Bool) -> some View {
        if let box = store.streamBoxes[store.sessionId] {
            StreamingBubbleView(
                box: box, store: store, model: model, pipeline: pipeline,
                project: project, version: version,
                scrollProxy: proxy, stickToBottom: stickToBottom
            )
        }
    }

    /// 流式气泡子视图：**唯一订阅 StreamBox 的视图**。delta 增量只重渲染这里，
    /// 不再连坐整个对话页（883s 轮网络侧仅 45.5s 的修复主体）。文本滚动跟随
    /// 也由盒驱动——父视图不再逐 delta 重估，原 onChange(currentStream.text)
    /// 在父视图会失聪，故下沉到本视图监听盒内文本。
    private struct StreamingBubbleView: View {
        @ObservedObject var box: StreamBox
        @ObservedObject var store: SessionStore
        @ObservedObject var model: AppModel
        @ObservedObject var pipeline: PipelineEngine
        let project: String
        let version: String
        let scrollProxy: ScrollViewProxy
        let stickToBottom: Bool

        var body: some View {
            inner
                .onChange(of: box.value.text) { _, _ in
                    guard stickToBottom else { return }
                    scrollProxy.scrollTo("streaming", anchor: .bottom)
                }
        }

        private var inner: some View {
            let chained = MessageBubble.isFastForwardChainedBefore(
                store.entries.count, in: store.entries
            )
            // 回合注记（阶段推进/切档）在流式开始时即并入气泡顶部；
            // 携带里程碑载荷的行（评分卡）渲染为交付摘要条
            let headerAssembly = MessageBubble.milestoneAssembly(
                from: MessageBubble.mergeableNotes(before: store.entries.count, in: store.entries)
            )
            // 交接条（值班单）与链判定同集：段序号按已落盘段数顺延，
            // 实时计量取流盒（起始时刻 + 已生成字数，随增量刷新）
            let handover = chained
                ? MessageBubble.dutyHandover(for: store.entries.count, in: store.entries)
                : nil
            let live = handover == nil ? nil : DutyHandoverBar.Live(
                startedAt: box.value.startedAt,
                charCount: box.value.text.count
            )
            let stream = box.value
            let core = VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                // 系统代答链交接条（值班单）：流式期即并入续段顶部（进行态计时 + 字数）
                if let handover {
                    DutyHandoverBar(data: handover, live: live)
                }
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
                // 原型：思考中 spinner + 流光扫字（含本轮引用技能）；文本开始输出后仅展示增量。
                // 瞬时故障自动重试中（429/5xx）：琥珀状态行替代思考卡——等待显性化，不像假死
                if let retryNote = stream.retry {
                    HStack(spacing: DS.Spacing.s8) {
                        DSPulseDot(tint: .statusWarning)
                        Text(retryNote)
                            .font(DS.Font.bodySM)
                            .foregroundStyle(Color.ink500)
                    }
                } else if (stream.think.isEmpty && stream.text.isEmpty) || !stream.think.isEmpty {
                    ThinkingCard(
                        data: nil, reasoning: stream.think, skills: stream.skills,
                        phases: stream.phaseTrail, toolSteps: stream.toolSteps
                    )
                }
                if !stream.text.isEmpty {
                    // 与最终消息同构的产物渲染；展示正文与产物事实由发布点
                    // StreamDisplayPayload.make 全量算好（进行中的产物块收进
                    // 生成进度卡，不再原样刷屏——识别不依赖被裁剪的展示文本）
                    StreamingContentBody(
                        display: stream.text,
                        blocks: stream.artifactBlocks,
                        inProgressName: stream.inProgressName,
                        inProgressLines: stream.inProgressLines,
                        project: project,
                        version: version
                    )
                }
            }
            return Group {
                if chained {
                    core
                } else {
                    AgentMessageShell(stage: pipeline.stage, time: nil) { core }
                }
            }
        }
    }

    /// 插话排队气泡（P3）：user 气泡同形制（深底白字、右下角小圆角）但半透明，
    /// 右上角「已排队」小标——注入生效 / 续发落盘后由正式气泡替代。
    private func steeringBubble(_ entry: DiscussionEntry) -> some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                Text("已排队")
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.brand400)
                Text(entry.content)
                    .font(DS.Font.chatBase)
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 21)
            .padding(.vertical, 16)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: DS.Radius.r20,
                    bottomLeadingRadius: DS.Radius.r20,
                    bottomTrailingRadius: DS.Radius.md,
                    topTrailingRadius: DS.Radius.r20
                )
                .fill(Color.userBubble.opacity(0.55))
            )
        }
    }

    /// 流式气泡顶距（与 displayItems 共用 MessageBubble.topInset 口径）：
    /// 链式续段并入上一条回答（簇内 16），常规回合吃 52 轮距。
    /// 口径不一致会让续段在落盘瞬间跳开一段空白。
    private var streamingTopInset: CGFloat {
        let chained = MessageBubble.isFastForwardChainedBefore(
            store.entries.count, in: store.entries
        )
        return MessageBubble.topInset(
            for: .assistant, isFirst: displayItems.isEmpty,
            previousWasSystem: false, isContinuation: chained
        )
    }

    private func isLastAssistant(_ entry: DiscussionEntry) -> Bool {
        // 全阶段放开（不止澄清）：②③④ 的歧义处理规则同样以末尾 A)/B) 选项行
        // 收尾。末条 AI 回复的选项行统一折叠进统一停靠卡的作答段（StageDockCard），
        // 消息流不再渲染点选项；该消息不再是末条后选项行随原文回归留痕。
        guard entry.role == .assistant else { return false }
        return entry.id == store.entries.last(where: { $0.role == .assistant })?.id
    }

    /// 多题问题卡待答：最新 assistant 回复中的 artifact:question-card 块（全阶段——
    /// ① 澄清卡 / ②③ 发起的 prd_preflight 前置确认卡 / ④ prd_defaults 默认项卡，
    /// 提交分流看 purpose）。该回复之后已存在任何用户消息（已作答 / 已岔开继续聊）
    /// → 不再算待答（旧口径仅按【问题卡作答】前缀判定；统一口径：岔开即视为该问题关闭）。
    private var pendingQuestionCard: ArtifactParser.QuestionCardRequest? {
        guard !model.currentVersionReleased else { return nil }
        guard let lastAssistantIndex = store.entries.lastIndex(where: { $0.role == .assistant }),
              let request = ArtifactParser.parseQuestionCard(
                  blocks: ArtifactParser.parseArtifactBlocks(in: store.entries[lastAssistantIndex].content)
              ) else { return nil }
        if store.entries.dropFirst(lastAssistantIndex + 1).contains(where: { $0.role == .user }) {
            return nil
        }
        return request
    }

    /// 选项行问题组待答：末条 assistant 回复末尾的连续 A)/B) 选项行组（全阶段放开——
    /// ②③④ 的歧义处理同样以选项行收尾，与原流内 chips 同口径）。
    /// 该回复之后已存在任何用户消息（已作答 / 已岔开）→ 不再算待答。
    private var pendingOptionLineGroups: ArtifactParser.OptionLineQuestionGroups? {
        guard let lastAssistantIndex = store.entries.lastIndex(where: { $0.role == .assistant }),
              let groups = ArtifactParser.parseOptionLineQuestionGroups(
                  in: store.entries[lastAssistantIndex].content
              )
        else { return nil }
        if store.entries.dropFirst(lastAssistantIndex + 1).contains(where: { $0.role == .user }) {
            return nil
        }
        return groups
    }

    /// 待答问题（作答坞数据源）：多题问题卡优先；选项行组 ≥2 转问题卡向导
    /// （逐题作答：第 1 题 → 下一道题 → 第 2 题，与问题卡同一流程同一样式）；
    /// 单组保持单题点选即发表单。
    private var pendingQuestion: PendingQuestion? {
        guard let lastAssistantIndex = store.entries.lastIndex(where: { $0.role == .assistant })
        else { return nil }
        let entryId = store.entries[lastAssistantIndex].id
        if let wizard = pendingQuestionCard {
            return PendingQuestion(entryId: entryId, wizard: wizard, options: nil)
        }
        if let groups = pendingOptionLineGroups {
            if groups.questions.count >= 2 {
                // 选项行多组 → 问题卡向导：每组成一题（单选 + 自定义输入，题型按题干启发式）
                let request = ArtifactParser.normalizeQuestionCard(
                    ArtifactParser.QuestionCardRequest(
                        questions: groups.questions.map { group in
                            ArtifactParser.QuestionCardRequest.Question(
                                id: nil, title: group.title, detail: nil,
                                options: group.options, allowCustom: true, multiple: nil
                            )
                        }
                    )
                )
                if let request {
                    return PendingQuestion(entryId: entryId, wizard: request, options: nil)
                }
            }
            if let single = groups.questions.first {
                return PendingQuestion(
                    entryId: entryId, wizard: nil,
                    options: ArtifactParser.ClarifyOptions(
                        question: groups.bodyText, options: single.options
                    ),
                    // 一次确认（① 澄清）：收尾确认问标记 + 单组 + 闸口就绪才生效
                    //（多组转问题卡 / 非①阶段 / 闸口未就绪 → 常规作答）
                    isGateConfirm: groups.gateConfirm
                        && groups.questions.count == 1
                        && pipeline.stage == .clarify
                        && model.confirmTarget == .clarify
                )
            }
        }
        return nil
    }

    // MARK: - 系统事件三分层（独立可见 / 融入回答 / 静默）

    /// 渲染项：一条可见条目 + 已并入其气泡的系统注记。
    private struct DisplayItem: Identifiable {
        let entry: DiscussionEntry
        let headerNotes: [TurnNote]
        let footerNotes: [TurnNote]
        /// 快速通道链式续段：不出独立回答头，内容衔接上一回合（一条消息一条回答）。
        var chainContinuation: Bool = false
        /// 系统代答链交接条（值班单）：仅链式续段有值（首段 / 非链为 nil）。
        var handover: DutyHandover? = nil
        /// 顶距（按相邻项类型算，见 displayItems）：提示行不吃 52 轮距，
        /// 簇内紧凑（消息→提示 16、提示→提示 12），消息轮间仍 52。
        var topInset: CGFloat = 0
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
            store.streams[store.sessionId]?.isStreaming == true
            ? MessageBubble.streamingAbsorbedIndices(in: entries)
            : []
        var items: [DisplayItem] = []
        // 顶距按「上一个已渲染项」的类别算：提示行（💬 留痕 / 事件胶囊）是
        // 前一条回答的脚注簇，簇内 12–16，不摊 52 的轮距；消息轮间恒 52。
        var previousWasSystem = false
        for (index, entry) in entries.enumerated() {
            if entry.role == .system && entry.memory != nil { continue }
            // 静默事件行（⚡ 受理 / ⏳ 风险提醒 / ✅ 推进确认）：照常落盘（审计/链判定
            // 数据源），语义已由当轮 AI 回答开场承接句承载——UI 不再渲染
            if entry.role == .system && entry.isSilent { continue }
            if entry.role == .system && streamingAbsorbed.contains(index) { continue }
            if entry.role == .assistant {
                // 交接条与「续段不出独立回答头」同判据，门控在 chained——
                // 避免每条 assistant 都跑一次链回溯
                let chained = MessageBubble.isFastForwardChainedBefore(index, in: entries)
                items.append(DisplayItem(
                    entry: entry,
                    headerNotes: MessageBubble.mergeableNotes(before: index, in: entries),
                    footerNotes: MessageBubble.mergeableNotes(after: index, in: entries),
                    chainContinuation: chained,
                    handover: chained ? MessageBubble.dutyHandover(for: index, in: entries) : nil,
                    topInset: MessageBubble.topInset(
                        for: .assistant, isFirst: items.isEmpty,
                        previousWasSystem: previousWasSystem, isContinuation: chained
                    )
                ))
                previousWasSystem = false
            } else if entry.role == .system && merged.contains(index) {
                continue
            } else {
                items.append(DisplayItem(
                    entry: entry, headerNotes: [], footerNotes: [],
                    topInset: MessageBubble.topInset(
                        for: entry.role, isFirst: items.isEmpty,
                        previousWasSystem: previousWasSystem, isContinuation: false
                    )
                ))
                previousWasSystem = true
            }
        }
        return items
    }

    /// 流式回合的注记（引用点已下沉到 StreamingBubbleView.inner，此处保留
    /// 判据入口：L2787 的头部吸收索引与其共用 mergeableNotes 口径）。
    private var streamingHeaderNotes: [TurnNote] {
        MessageBubble.mergeableNotes(before: store.entries.count, in: store.entries)
    }

    // MARK: - 输入区（对话框组件 · 参考图 Trae 输入卡两段式布局）

    /// 输入卡：radius 20 悬浮坞（composerSurface + overlayBorder 发丝边 + .dock 双层大软阴影，
    /// 2026-09 呼吸感改版）；卡内自上而下 = 待发附图条 → 待发引用文件 chips →
    /// 编辑区 → 工具栏（左：附件 + / 记下来 · 右：当前模型 → 设置模型页 / 发送钮 32×32 r10 品牌紫）。
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
                // macOS 26：showsIndicators:false 语义同 .hidden（滚动中仍画），
                // 必须 .never 才强制永不绘制
                .scrollIndicators(.never)
            }

            // 待发送引用文件条（产物台账右键「添加到对话」；正文发送时读盘注入）
            if !pendingFileRefs.isEmpty {
                FlowLayout(spacing: DS.Spacing.s6) {
                    ForEach(pendingFileRefs, id: \.self) { ref in
                        ReferencedFileChip(relativePath: ref) {
                            withAnimation(DS.Motion.springFast) {
                                pendingFileRefs.removeAll { $0 == ref }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.s2)
                .padding(.bottom, DS.Spacing.s8)
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
                // 本会话口径（阶段 3）：他会话的流不禁用本会话的记下来
                .disabled(store.isSessionBusy(store.sessionId))

                Spacer(minLength: DS.Spacing.s8)

                // 思考强度（reasoning_effort）：信号柱图标 + 当前档位文本 → 档位菜单
                // （对话页与新建任务输入卡共用组件；品牌色常亮）
                ComposerEffortButton(store: store)

                // 对话模型切换器（多模型管理）：当前模型 chip → 弹层实时切换
                // （写透 stages 即时生效，「添加模型…」直达设置模型页）
                ComposerModelButton(model: model)

                // 流式回复中（本会话为发起者）→ 单钮互替：草稿有字 = 插话发送钮，
                // 清空即翻回停止钮（插话仅支持文本，附件不参与判据）；其余状态 → 发送钮
                if store.streams[store.sessionId]?.isStreaming == true {
                    if canInterject {
                        ComposerSendButton(enabled: true, help: "插话：不打断生成，生成结束后自动送达") {
                            send()
                        }
                    } else {
                        ComposerStopButton {
                            store.stopGeneration()
                        }
                    }
                } else {
                    ComposerSendButton(enabled: canSend) {
                        send()
                    }
                }
            }
            .padding(.top, DS.Spacing.s6)
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.top, DS.Spacing.s12)
        .padding(.bottom, DS.Spacing.s10)
        // 2026-09 呼吸感改版：悬浮输入坞——去渐进描边，双层大软阴影 + overlayBorder
        // 发丝边勾轮廓（DSMenu 同款写法）；聚焦反馈由 accent 焦点环独立承担
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.r20)
                .fill(Color.composerSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.r20)
                .strokeBorder(Color.overlayBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r20))
        .dsShadow(.dock)
        // Xcode 语义焦点环：accent 环绕取代描边式焦点（P0-①）
        .dsFocusRing(focused: inputFocused, radius: DS.Radius.r20)
        // 深浅色切换平滑过渡（与 appAppearance 根 0.28s 交叉淡化同参数）
        .animation(.easeInOut(duration: 0.28), value: colorScheme)
        // 响应式：与消息流同宽（720）居中，窄窗口随 min 480 收缩
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Spacing.s10)
        .padding(.horizontal, DS.Spacing.s48)
        .padding(.bottom, DS.Spacing.s24)
    }

    /// 编辑区：占位左上（composerPlaceholder AA 达标）+ 随内容增高
    /// （字号与用户气泡同为 chatBase 15，所见即所得）。
    private var inputEditor: some View {
        TextEditor(text: $draft)
            .font(DS.Font.chatBase)
            .foregroundStyle(Color.ink900)
            .scrollContentBackground(.hidden)
            // macOS 26：TextEditor 内部滚动条槽静止也绘制，强制永不显示
            .scrollIndicators(.never)
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
                // ⏎ 直接发送（⇧⏎ 换行；发起会话流式中 = 插话，send 内部分流）；
                // 不可发送时回车保持系统换行行为
                guard press.key == .return,
                      press.phase == .down,
                      !press.modifiers.contains(.shift),
                      canSend
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

    /// 可发送：有文本、有待发附图或待发引用文件（纯附件消息也允许）。
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingImages.isEmpty
            || !pendingFileRefs.isEmpty
    }

    /// 流式中单钮互替判据：草稿有字 → 显示插话发送钮，清空 → 翻回停止钮。
    /// （插话仅支持文本：附件/引用文件流式期间不可送达，不参与判据）
    private var canInterject: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 产物右键「添加到对话」：把待引用文件追加进输入坞 chips 并聚焦输入框。
    /// 追加而非覆盖（保留已输入内容与既有引用）；同一文件重复添加是 no-op。
    private func consumePendingFileReference() {
        guard let path = model.pendingFileReference else { return }
        model.pendingFileReference = nil
        guard !pendingFileRefs.contains(path) else {
            inputFocused = true
            return
        }
        pendingFileRefs.append(path)
        inputFocused = true
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let fileRefs = pendingFileRefs
        guard !text.isEmpty || !images.isEmpty || !fileRefs.isEmpty else { return }

        // P3 Steering：发起会话生成进行中（含回复流未开的待回复期）→
        // 文本插话入队（不打断生成）。附件/引用文件不支持插话携带：
        // 保留在输入坞，正文为空时不动作。
        if store.isSessionBusy(store.sessionId) {
            guard !text.isEmpty else { return }
            draft = ""
            Task { await model.sendMessage(text) }
            return
        }

        // 旧全局 !isStreaming 闸已摘（阶段 3）：上方分支已兜住本会话 busy，
        // 他会话的流不拦本会话发送（多流并行，origin 各自钉定）
        draft = ""
        pendingImages = []
        pendingFileRefs = []

        // 自由作答「进入下一个阶段」等价选①（design.md §6.1）
        if model.confirmTarget != nil && !text.isEmpty
            && AppModel.isAdvanceIntent(text) && images.isEmpty {
            Task { await model.confirmCurrentStage() }
            return
        }
        Task {
            await model.sendMessage(
                text, imageFiles: images.map(\.fileName), fileRefs: fileRefs
            )
        }
    }

    /// 截断卡「重新发送」：模拟真实用户的交互方式——把触发本回答的原始用户消息回填
    /// 输入框（附图回填待发条），再走与手输完全一致的 send() 标准链路：
    /// 「用户消息发送 → 系统接收 → AI 处理 → 生成回答」，不直接复用/重生成 AI 回答内容。
    private func resendOriginal(_ artifactName: String, for entry: DiscussionEntry) {
        // 本会话口径（阶段 3）：重发回填本会话输入坞，他会话的流不拦截
        guard !store.isSessionBusy(store.sessionId),
              !model.currentVersionReleased else { return }
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
        pendingFileRefs = origin.files
        send()
    }

    /// 触发指定 AI 回答的原始用户消息（含附图 / 引用文件）：委托可测静态实现。
    private func originalUserMessage(
        before entry: DiscussionEntry
    ) -> (content: String, images: [String], files: [String])? {
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
            // 名称行：头像 + Agent（600）+ 时间（mono tertiary）；阶段身份由头像编号/主色表达。
            // 2026-09 呼吸感改版：去 hairline 分隔线 + 名称降次级灰（降噪——
            // 轮次分隔交给 52pt 纯留白，名称行不再与正文抢层级）。
            HStack(spacing: DS.Spacing.s8) {
                StageAvatar(stage: stage, size: 22)
                Text("Agent")
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink500)
                if let time {
                    Text(time)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink300)
                }
            }
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

// MARK: - 知识引用条（系统层，2026-09-17 钦定）

/// assistant 气泡底部的「参考知识卡」引用行：本轮 Context Builder 注入的卡命中
/// （确定性数据，注入即显示——AI 是否真正采用由第二批 prompt 协议标注）。
/// 数据随 entry.think.knowledgeRefs 落 discussions.jsonl，历史回放照常渲染。
/// chip 可点击：按 id 定位卡片 .md 解析后弹出知识库页同款详情弹层。
struct KnowledgeCiteBar: View {
    let refs: [String: String]
    /// 当前项目 id（卡片定位：全局 cards/ → 项目 knowledge/）。
    let project: String

    /// 详情弹层目标行（nil = 未打开）；detail 按需读 .md 解析。
    @State private var detailRow: CardLibraryRow?
    @State private var detail: MethodologyCard?

    var body: some View {
        HStack(spacing: DS.Spacing.s6) {
            DSIcon(.books, size: 12)
                .foregroundStyle(Color.ink500)
            Text("参考知识卡")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
            ForEach(sortedRefs, id: \.key) { id, title in
                Button {
                    openCard(id: id, fallbackTitle: title)
                } label: {
                    Text(title)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.brandAccent)
                        .padding(.horizontal, DS.Spacing.s8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.brandPopup.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .help("\(id)——点击查看卡片全文与案例")
                .lineLimit(1)
            }
        }
        .padding(.top, DS.Spacing.s2)
        .sheet(isPresented: Binding(
            get: { detailRow != nil },
            set: { if !$0 { closeDetail() } }
        )) {
            if let row = detailRow {
                CardDetailSheet(
                    row: row,
                    detail: detail,
                    recommendation: nil,
                    onClose: { closeDetail() }
                )
            }
        }
    }

    private var sortedRefs: [(key: String, value: String)] {
        refs.sorted { $0.key < $1.key }
    }

    private func closeDetail() {
        detailRow = nil
        detail = nil
    }

    /// 点击 chip：定位卡片 .md（全局 → 项目）→ 解析成详情行弹层。
    /// 文件缺失/解析失败以引用标题兜底开卡（confidence 0 = 未经全量解析），点击必有反馈。
    private func openCard(id: String, fallbackTitle: String) {
        var row = CardLibraryRow(
            id: id, projectId: project, title: fallbackTitle, content: fallbackTitle,
            annotationCount: 0, confidence: 0, supersededBy: nil, createdAt: ""
        )
        var card: MethodologyCard?
        if let url = CardLibraryView.locateCardFile(id: id, projectId: project),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            card = MethodologyCard.parse(markdown: text)
            if let card {
                row = CardLibraryRow(
                    id: card.id,
                    projectId: card.project ?? "",
                    title: Recommender.title(of: card.content),
                    content: card.content,
                    annotationCount: card.annotations.count,
                    confidence: card.confidence,
                    supersededBy: card.supersededBy,
                    createdAt: card.created
                )
            }
        }
        detail = card
        detailRow = row
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
    /// 方案 A 回执脚注：快速通道自动确认句（「快速通道 · 自动确认，继续生成 ③ 原型」）。
    /// 非空时回执脚注走自动确认态（快速通道链无确认坞，禁指路确认坞）。
    var autoNote: String? = nil
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

/// 回合交付摘要条（方案 B：默认展开，可点击整行折叠）：默认展出审计明细行，
/// 摘要行点击折叠为一行——✓ 已交付产物 + 审计计数段。
/// 落盘文件卡独立渲染在摘要条外部（不内嵌）。
/// 展开态纯 UI 状态不落盘（刷新回默认展开）。行 hover 点亮去向，点击直达右栏对应 Tab。
struct DigestBar: View {
    let rows: [MilestoneRow]
    var openSink: ((InspectorPanel.InspectorTab) -> Void)? = nil

    @State private var expanded = true
    @State private var hoveredRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            if expanded {
                panel
            }
        }
        // 2026-09-15 钦定：外框回归——发丝边框圈出模块边界（无 bg 无阴影，保持注脚安静感），
        // 摘要行降字号降灰与展开面板明细行交互、hover 跳转高亮（hoveredRowID）全部保留。
        // 2026-09-15 呼吸感：内衬横向 s12→s16，摘要行/分隔线/明细行留白整体放大一档。
        .padding(.horizontal, DS.Spacing.s16)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .animation(DS.Motion.spring, value: expanded)
    }

    // MARK: 摘要行（默认态，整行可点）

    private var summaryBar: some View {
        Button {
            withAnimation(DS.Motion.spring) { expanded.toggle() }
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                DSIcon(.circleCheck, size: 14)
                    .foregroundStyle(Color.statusSuccess)
                Text(title)
                    .font(DS.Font.bodyFootnote.weight(.medium))
                    .foregroundStyle(Color.ink500)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 4) {
                        Text(seg.label)
                            .font(DS.Font.bodyFootnote)
                            .foregroundStyle(seg.warn ? Color.statusWarning : Color.ink500)
                        if let count = seg.count {
                            Text(count)
                                .font(DS.Font.mono2XS)
                                .foregroundStyle(seg.warn ? Color.statusWarning : Color.ink700)
                        }
                        if seg.warn {
                            Text("超限")
                                .font(DS.Font.bodyFootnote)
                                .foregroundStyle(Color.statusWarning)
                        }
                    }
                }
                Spacer(minLength: 0)
                DSIcon(.chevronUp, size: 11)
                    .foregroundStyle(Color.ink300)
                    .rotationEffect(.degrees(expanded ? 0 : 180))
            }
            .padding(.horizontal, 0)
            .padding(.vertical, DS.Spacing.s12)
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
                        .padding(.vertical, DS.Spacing.s8)
                }
                detailRow(row)
            }
        }
        .padding(.bottom, DS.Spacing.s10)
    }

    /// 明细行：图标 + 主体名 + mono 计数 + 同行尾注，去向右置（hover 点亮，点击跳右栏）；
    /// 次行补注 / 评分卡维度条随行展开。
    private func detailRow(_ row: MilestoneRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s10) {
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
        .padding(.horizontal, 0)
        .padding(.vertical, DS.Spacing.s8)
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
}

// MARK: - 交付回执卡（系统消息改版 · 方案 A「一次交付，一张回执」）

/// 阶段完成后的所有交付信息收进一张结构化卡：产物是主行，沉淀是次行，下一步是脚注。
/// 取代回合尾部的交付摘要条 + 独立落盘文件卡 + 机器初审居中注脚——散落的 chips、
/// 注记、胶囊收编进卡，每条信息只出现一次。文案从「机器播报」改写为「交付对账」：
/// 短句、数量前置、去向可点。
/// - 主行：📦 注记携带的 fileChanges（含原型——回执承载期产物块文件卡静默防双卡）；
/// - 沉淀行：里程碑装配行（自评审 / 风险 / 决策记录，点击直达右栏对应 Tab）；
/// - 脚注三态由 `MessageBubble.receiptFooter` 推导（机器初审中 / 确认坞指路 /
///   快速通道自动确认），推进动作只活在确认坞，回执只指路不替按。
private struct DeliveryReceiptCard: View {
    let stage: PipelineRun.Stage
    /// 回执时间（HH:mm，与回答头时间同源）。
    let time: String?
    /// 里程碑装配行（全量；沉淀行与脚注各自过滤派生）。
    let rows: [MilestoneRow]
    /// 📦 注记携带的落盘文件（组内去重保序）。
    let files: [FileChangeSummary]
    let project: String
    let version: String
    /// 沉淀行点击 → 右栏对应 Tab；nil = 行仅展示。
    var openSink: ((InspectorPanel.InspectorTab) -> Void)? = nil
    /// 主行点击 → 预览；nil = 非交互态（无预览入口，仍展示交付事实）。
    var onOpenFile: ((FileNode) -> Void)? = nil
    /// PRD 未改动轮的文件锚（2026-09-18）：④ 阶段回合没有携带任何落盘文件
    /// （AI 判定「PRD 已是最新，不重排」的迭代轮）时，回执仍给出在盘最新 PRD 的
    /// 可点击入口，副行标「本轮未改动」——文件未写 ≠ 用户不需要可达的文档入口。
    var unchangedFile: FileChangeSummary? = nil

    @State private var hoveredRowID: String?
    @State private var hoveredFile: String?

    /// 阶段短名（kicker 用：③ 原型 · 交付回执）。
    private var stageName: String {
        switch stage {
        case .clarify: "澄清"
        case .structure: "结构"
        case .prototype: "原型"
        case .prd: "PRD"
        }
    }

    /// 沉淀行 = 装配行滤除下一节点数据行（脚注承载）。
    private var sinks: [MilestoneRow] {
        rows.filter { $0.id != "next" }
    }

    /// 主行文件去重（防御同回合重复路径），顺序保持落盘顺序。
    private var mainFiles: [FileChangeSummary] {
        var seen: Set<String> = []
        return files.filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            kicker
            if !mainFiles.isEmpty {
                hairline
                ForEach(mainFiles, id: \.path) { mainRow($0) }
            } else if let unchanged = unchangedFile {
                hairline
                mainRow(unchanged, unchangedNote: "本轮未改动")
            }
            let sinkRows = sinks
            if !sinkRows.isEmpty {
                hairline
                ForEach(sinkRows, id: \.id) { sinkRow($0) }
            }
            if let footer = MessageBubble.receiptFooter(for: rows) {
                hairline
                footerRow(footer)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .fill(Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }

    private var hairline: some View {
        Rectangle().fill(Color.borderL1).frame(height: 1)
    }

    // MARK: kicker（交付回执眉标）

    private var kicker: some View {
        HStack(spacing: DS.Spacing.s8) {
            Circle().fill(Color.statusSuccess).frame(width: 5, height: 5)
            Text("\(stage.proto.num) \(stageName) · 交付回执")
                .font(DS.Font.mono2XS)
                .kerning(1.2)
                .foregroundStyle(Color.ink300)
            Spacer(minLength: 0)
            if let time {
                Text(time)
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(Color.ink300)
            }
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.vertical, DS.Spacing.s10)
    }

    // MARK: 主行（本轮交付物，吸收产物块文件卡）

    private func mainRow(_ change: FileChangeSummary, unchangedNote: String? = nil) -> some View {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(change.path)
        let title = artifactCardTitle(change.path)
        return Button {
            onOpenFile?(FileNode(name: title, url: url, isDirectory: false, children: nil))
        } label: {
            HStack(spacing: DS.Spacing.s12) {
                DSIcon(fileIcon(change.path), size: 16)
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.lg)
                            .fill(Color.brand100)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.bodyMDStrong)
                        .foregroundStyle(Color.ink900)
                    Text(
                        "\(fileTypeLabel(change.path)) · \(fileSizeText(url))"
                            + (unchangedNote.map { " · \($0)" } ?? "")
                    )
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .monospacedDigit()
                }
                Spacer(minLength: DS.Spacing.s8)
                if onOpenFile != nil {
                    HStack(spacing: DS.Spacing.s4) {
                        Text("预览")
                        DSIcon(.arrowUpRight, size: 11)
                    }
                    .font(DS.Font.bodySM)
                    .foregroundStyle(hoveredFile == change.path ? Color.brandAccent : Color.ink500)
                }
            }
            .padding(.horizontal, DS.Spacing.s16)
            .padding(.vertical, DS.Spacing.s12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenFile == nil)
        .onHover { hovering in
            guard onOpenFile != nil else { return }
            hoveredFile = hovering ? change.path : nil
        }
        .help(
            unchangedNote == nil
                ? "点击预览（弹窗内置「在浏览器打开」兜底）"
                : "本轮没有重写文档，这是在盘最新版——点击预览"
        )
    }

    // MARK: 沉淀行（随本轮落盘的横切产物，可点 → 右栏）

    private func sinkRow(_ row: MilestoneRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s10) {
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
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.vertical, DS.Spacing.s10)
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

    // MARK: 脚注（下一步：指路，不替按）

    private func footerRow(_ footer: (text: String, waiting: Bool)) -> some View {
        let auto = rows.first(where: { $0.id == "next" })?.autoNote != nil
        return HStack(alignment: .top, spacing: DS.Spacing.s8) {
            DSIcon(
                auto ? .bolt : (footer.waiting ? .clock : .circleCheck),
                size: 13
            )
            .foregroundStyle(
                auto ? Color.statusWarning : (footer.waiting ? Color.ink500 : Color.statusSuccess)
            )
            Text(footer.text)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, DS.Spacing.s16)
        .padding(.vertical, DS.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageBubble: View {
    let entry: DiscussionEntry
    /// 助手消息的阶段（决定头像与名称行）。
    let stage: PipelineRun.Stage
    /// 末条 assistant：末尾选项行折叠进作答坞（不再流内渲染点选项）。
    let showOptions: Bool
    /// 融入气泡顶部的回合注记（阶段推进/切档/进度）。
    let headerNotes: [TurnNote]
    /// 融入气泡底部的注记（产物落盘/决策记录）。
    let footerNotes: [TurnNote]
    /// 快速通道链式续段：跳过 AgentMessageShell 头部，内容直接衔接上一回合
    ///（一条用户消息只出一条连续回答；分段推进注记由 headerNotes 承载）。
    var chainContinuation: Bool = false
    /// 系统代答链交接条（值班单）：仅链式续段有值；nil = 首段 / 非链。
    var handover: DutyHandover? = nil
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

    /// 用户气泡（原型：深反色底白字，maxWidth 72%，无时间戳）。
    /// 2026-09 呼吸感改版：内衬 21/16 + radius 20（右下角 6 保留发言方向语义）。
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
                // 引用文件 chips（产物台账「添加到对话」；与输入坞同款胶囊，深底反色）
                if let refs = entry.files, !refs.isEmpty {
                    FlowLayout(spacing: DS.Spacing.s6) {
                        ForEach(refs, id: \.self) { ref in
                            ReferencedFileChip(relativePath: ref, tone: .bubble)
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
                        // 折叠渐隐（原用 .mask：macOS 上 compositing 会拍平 Text、
                        // 击穿 textSelection 拖选——用户消息永远选不中）。改用
                        // overlay 淡入气泡底色：userBubble 纯色底，视觉等价；
                        // allowsHitTesting(false) 不挡文字命中。渐隐色取 mask 的
                        // alpha 互补（clear→1.0）， stops 中点对齐原遮罩参数。
                        .overlay(alignment: .bottom) {
                            if clipped {
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.userBubble.opacity(0), location: 0),
                                        .init(color: Color.userBubble.opacity(0), location: 0.55),
                                        .init(color: Color.userBubble.opacity(0.55), location: 0.82),
                                        .init(color: Color.userBubble, location: 1.0),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                                .allowsHitTesting(false)
                            }
                        }
                }
                // 方案 B · 折叠操作条：hairline 分隔 + 折叠量明示 + 品牌胶囊「展开全部/收起」
                if foldEnabled {
                    foldBar
                }
            }
            // HTML 定稿值；本组件既有 14/10 字面量先例
            .padding(.horizontal, 21)
            .padding(.vertical, 16)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: DS.Radius.r20,
                    bottomLeadingRadius: DS.Radius.r20,
                    bottomTrailingRadius: DS.Radius.md,
                    topTrailingRadius: DS.Radius.r20
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

    /// 风险自留留痕（💬 已接受「…」；历史行 📌 已接受风险——「…」）：居中微行渲染，
    /// 与安静留痕同基调——记账反馈不与正文抢层级，历史行同款保持视觉一致。
    fileprivate static func isRiskAcceptedNotice(_ content: String) -> Bool {
        content.hasPrefix("💬 已接受「") || content.hasPrefix("📌 已接受风险——「")
    }

    /// 独立系统事件条分流：变更提案卡（载荷行）> 压缩注记（居中灰字）>
    /// 风险自留微行 > 安静留痕（💬）居中纯文本 > 语义胶囊。
    @ViewBuilder
    private var systemPill: some View {
        if let proposal = entry.changeProposal {
            ChangeProposalCard(proposal: proposal)
        } else if entry.compaction != nil {
            // 压缩注记：只留一行居中灰字提示；摘要全文在 CompactionData 载荷
            // （冷启动恢复 / Finder 可读），不在聊天流里刷屏。
            Text("上下文已压缩")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        } else if Self.isRiskAcceptedNotice(entry.content) {
            riskAcceptedNotice
        } else if Self.isQuietNotice(entry.content) {
            Text(Self.stripEventEmoji(entry.content))
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        } else {
            eventPill
        }
    }

    /// 风险自留微行（2026-09-17 方案 A「居中安静留痕」）：bodyXS 居中灰字，
    /// 「…」风险名片段提亮一档——从落盘原文切出着色，不改事实源；
    /// 无引号片段的畸形行回退纯灰字。
    private var riskAcceptedNotice: some View {
        let text = Self.stripEventEmoji(entry.content)
        return Group {
            if let seg = Self.quotedNameSegments(in: text) {
                Text(seg.before)
                    + Text(seg.name).foregroundStyle(Color.ink700)
                    + Text(seg.after)
            } else {
                Text(text)
            }
        }
        .font(DS.Font.bodyXS)
        .foregroundStyle(Color.ink500)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }

    /// 左对齐细字行（2026-09-17「纸面流」降噪：胶囊底色 + 描边退场，系统行
    /// 不与正文抢层级；状态色由语义图标承担，四类染状态色原则不变）。
    /// 只承载必须独立可见的事件（警告 / 闸口拦截 / 风险命中等）。
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
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        // 先清洗占位模仿残留（模型照抄的系统剥离标注/落盘占位行），再解析展示
        let rawContent = ArtifactParser.scrubImitatedPlaceholders(in: entry.content)
        let blocks = ArtifactParser.parseArtifactBlocks(in: rawContent)
        // 未闭合产物块 = 输出撞 max_tokens 被截断（历史会话兜底渲染，新会话已自动续写）。
        // 收起断点后的长代码，换成截断提示卡，避免整屏 HTML 刷屏。
        let incomplete = ArtifactParser.parseIncompleteArtifact(in: rawContent)
        // ViewBuilder 属性内不能写「if + 赋值」语句（if 会被当作视图节点），
        // 截断兜底裁剪收进立即执行的闭包，产出仍是单个 let
        let displayText = {
            var text = blocks.isEmpty
                ? rawContent
                : ArtifactParser.stripArtifactBlocks(
                    in: rawContent,
                    placeholder: "（产物已生成并落盘——点击下方标签预览，或见右栏「文件」面板）",
                    // 所有产物块不插正文占位：图表块直接渲染，其余块底部有胶囊提示，
                    // 避免多条块落多条重复引导文字
                    placeholderFor: { _ in "" }
                )
            if incomplete != nil, let marker = text.range(of: "```artifact:", options: .backwards) {
                // 开栏可能是更长反引号（````artifact:），前缀反引号一并裁掉
                var cutStart = marker.lowerBound
                while cutStart > text.startIndex, text[text.index(before: cutStart)] == "`" {
                    cutStart = text.index(before: cutStart)
                }
                text = String(text[..<cutStart])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 末尾选项行折叠：点选作答统一收口到输入区上方作答坞，正文不再重复渲染
            // 点不了的 A)/B) 原文行（多组问题全部进坞——单组单题表单 / 多组问题卡向导；
            // bodyText 即剥除所有组选项行后的正文）；该消息不再是末条后选项行随原文回归留痕。
            if showOptions, let groups = ArtifactParser.parseOptionLineQuestionGroups(in: text) {
                text = groups.bodyText
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
            // 系统代答链交接条（值班单）：续段顶部的段级计量（点击展开交接明细）
            if let handover {
                DutyHandoverBar(data: handover)
            }
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
                // 思考/正文 divider（DSH 式过程与产出分隔）：思考卡与正文之间一条 hairline
                Rectangle()
                    .fill(Color.borderL1)
                    .frame(height: 1)
                    .padding(.top, DS.Spacing.s4)
            }
            // 本轮任务计划卡（plan-act-reflect 的 plan 段）：先计划后执行的可见锚点，
            // 位于正文之前（计划块在回复首部，展示顺序对齐语义）
            if let plan = ArtifactParser.parsePlan(blocks: blocks) {
                PlanCardView(plan: plan)
            }
            // Markdown 渲染：标题/粗斜体/列表/代码块/表格/引用分层排版
            // （散文收在 chatMeasure 阅读栏内，表格/代码/图表留列宽）
            // semanticSections：## 节名渲染成 mono 标签 + hairline（方案 B 语义分节）
            MarkdownText(
                displayText, readingMeasure: DS.Typography.chatMeasure,
                semanticSections: true
            )

            // 产物区：图表内联渲染（回执承载期文件类产物卡静默——主行收进交付回执卡，
            // 防同文件「块卡 + 回执主行」双渲染）
            ArtifactBlocksSection(
                blocks: blocks,
                project: project,
                version: version,
                hideFileCards: !assembly.rows.isEmpty,
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

            // 交付回执卡（方案 A「一次交付，一张回执」）：产物是主行，沉淀是次行，
            // 下一步是脚注——取代旧交付摘要条 / 独立落盘文件卡 / 机器初审居中注脚
            // 三处散落渲染。机器初审等待态也统一收进脚注行（两版漂移文案归一）。
            if !assembly.rows.isEmpty {
                // PRD 未改动轮文件锚：④ 阶段回执无任何落盘文件且在盘 PRD 存在
                // → 主行渲染「PRD文档.md · 本轮未改动」，点击预览在盘最新版
                let receiptFiles = assembly.absorbedCards.compactMap(\.fileChanges).flatMap { $0 }
                let prdURL = PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(ArtifactPath.prd)
                DeliveryReceiptCard(
                    stage: stage,
                    time: hhmm(entry.createdAt),
                    rows: assembly.rows,
                    files: receiptFiles,
                    project: project,
                    version: version,
                    openSink: onOpenSink,
                    onOpenFile: { previewTarget = $0 },
                    unchangedFile: MessageBubble.unchangedPRDPointer(
                        stage: stage,
                        deliveredFiles: receiptFiles,
                        prdExists: FileManager.default.fileExists(atPath: prdURL.path)
                    )
                )
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

            // 知识引用条（系统层，2026-09-17 钦定）：本轮注入的卡命中——
            // 让「卡片在反哺 AI 回答」可感知、可核对（AI 层采用标注为第二批）
            // 挂在气泡最底：正文 → 产物卡 → 回执/注记 → 参考知识，引用是整回合的附注
            if let refs = entry.think?.knowledgeRefs, !refs.isEmpty {
                KnowledgeCiteBar(refs: refs, project: project)
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
        // 方法论自动沉淀行（🧠，①→② 收束时落卡）：归**上一回合尾部注记**（aftermath，
        // 刻意不登记 isTurnPreamble）。amending 场景紧随其后的「✅ 要点表已按新功能
        // 诉求更新——进入」已是 preamble（归下一回合顶部），两向行走各归其位互不打断。
        if content.hasPrefix("🧠") {
            return TurnNote(
                text: stripEventEmoji(content), icon: .mem, tint: .ink500
            )
        }
        // 风险台账采纳落实受理行（2026-09-15 闭环）：并入落实回合注记。
        // ⚡ 不入 eventEmojis（快速通道 ⚡ 行仍走独立事件条），此处手工剥前缀。
        if content.hasPrefix("⚡ 风险台账") {
            return TurnNote(
                text: String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                icon: .bolt, tint: .statusWarning
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
        // 风险台账采纳落实受理行（引入落实回合）
        if content.hasPrefix("⚡ 风险台账") { return true }
        if content.hasPrefix("📝 开始") { return true }
        // ✅ 推进语（引入下一回合）归下一回合顶部注记：「已确认」、amending 的
        // 「要点表已按新功能诉求更新——进入」（无「已确认」措辞，同为推进宣告——
        // 塞进 Agent 的回答，不再落独立事件条）；
        // 「质量门通过」（并进入）「机器初审通过」（确认后进入）是本轮结论，仍归上一回合尾部
        if content.hasPrefix("✅") {
            return content.contains("已确认") || content.contains("——进入")
        }
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
              !entries[i].isSilent,
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
              !entries[i].isSilent,
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
                  !entries[i].isSilent,
                  isTurnPreamble(entries[i].content),
                  turnNote(from: entries[i].content) != nil {
                merged.insert(i)
                i -= 1
            }
            i = index + 1
            while i < entries.count,
                  entries[i].role == .system, entries[i].memory == nil,
                  !entries[i].isSilent,
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

    /// 系统代发链式续段判定（index 可为 entries.count，即流式中的下一回合）：
    /// 前方只跨越连续系统行即可回溯到另一 assistant，且跨越的系统行里有链标记——
    /// 「快速通道」（⚡ 受理行 / 📦（快速通道：自动确认）行）、「🔄 已回到」
    /// （回退重做受理行：LLM 回退块 / UI 回退按钮触发后 executeBacktrack 发出）
    /// 或自动收束（2026-09-16 纳入：质量门/轮次耗尽的「澄清自动收束」受理行、
    /// 增补收束的「要点表已按新功能诉求更新」推进行）。
    /// 链上续段共享首回合的回答头——一条用户消息只出一条连续回答，回退后自动
    /// 重做的续段同样并入，不因中间跨了阶段再出新 Agent 头。
    /// 常规确认推进（隔用户确认消息）与被用户消息隔断的回合不判链，保留独立回答头。
    static func isFastForwardChainedBefore(_ index: Int, in entries: [DiscussionEntry]) -> Bool {
        var chained = false
        var i = index - 1
        while i >= 0, entries[i].role == .system, entries[i].memory == nil {
            if isChainMarked(entries[i].content) { chained = true }
            i -= 1
        }
        return chained && i >= 0 && entries[i].role == .assistant
    }

    /// 链标记判据：链上受理/推进系统行必须携带的语义词。
    /// 自动收束链（质量门/耗尽/增补）与快速通道、回退重做同权——
    /// 都是「AI 代答续段」，观感统一为一条回答 + 值班单过渡。
    fileprivate static func isChainMarked(_ content: String) -> Bool {
        content.contains("快速通道")
            || content.hasPrefix("🔄 已回到")
            || content.contains("澄清自动收束")
            || content.contains("要点表已按新功能诉求更新")
    }

    // MARK: 系统代答链交接条（方案 C「值班单」）

    /// 消息流顶距（唯一事实源，displayItems 与流式气泡共用）。
    /// 链式续段是上一条回答的延续——簇内 16（与「提示→消息」同档），
    /// 不吃新回合的 52 轮距（否则「一条回答」中间裂出一道大空白）；
    /// 常规 assistant 吃 52 轮距；系统提示行簇内 12–16 不摊轮距。
    nonisolated static func topInset(
        for role: DiscussionEntry.Role,
        isFirst: Bool,
        previousWasSystem: Bool,
        isContinuation: Bool
    ) -> CGFloat {
        guard !isFirst else { return 0 }
        if role == .assistant {
            return isContinuation ? DS.Spacing.s16 : DS.Spacing.s52
        }
        return previousWasSystem ? DS.Spacing.s12 : DS.Spacing.s16
    }

    /// 回溯本段所处代答链，产出交接条数据（段序号 / 本段耗时步数 / 明细时间轴）。
    /// index 可为 entries.count（流式续段尚未落盘）——此时段序号按已落盘段数 +1 顺延。
    /// nil = 非链续段：链首段、单段直答、被用户消息或记忆行隔断。
    static func dutyHandover(for index: Int, in entries: [DiscussionEntry]) -> DutyHandover? {
        // 与「续段不出独立回答头」严格同判据：有交接条的必是续段，反之亦然。
        guard isFastForwardChainedBefore(index, in: entries) else { return nil }
        // 反向跨连续系统行回溯到链首 assistant
        var i = index - 1
        while i >= 0, entries[i].role == .system, entries[i].memory == nil { i -= 1 }
        guard i >= 0, entries[i].role == .assistant else { return nil }
        var headIndex = i
        // 链可能是多段（快速通道沿途逐段推进）：中途的 assistant 本身也是续段时
        // 继续向前回溯——否则段序号会从半途重数（段 3 被算成段 2）。
        while isFastForwardChainedBefore(headIndex, in: entries) {
            var j = headIndex - 1
            while j >= 0, entries[j].role == .system, entries[j].memory == nil { j -= 1 }
            guard j >= 0, entries[j].role == .assistant else { break }
            headIndex = j
        }
        let settled = index < entries.count
        let lastIndex = settled ? index : entries.count - 1
        guard lastIndex >= headIndex else { return nil }

        // 明细时间轴：链内各段完成 + 各系统行（记忆行不入轴，与渲染层同口径）
        var segmentIndex = 0
        var nodes: [DutyHandover.Node] = []
        for j in headIndex...lastIndex {
            let entry = entries[j]
            guard entry.memory == nil else { continue }
            if entry.role == .assistant {
                segmentIndex += 1
                if let time = hms(entry.createdAt) {
                    nodes.append(DutyHandover.Node(
                        time: time, text: "第 \(segmentIndex) 段回答完成"
                    ))
                }
            } else if entry.role == .system {
                if let time = hms(entry.createdAt) {
                    nodes.append(DutyHandover.Node(
                        time: time, text: self.chainNodeText(entry.content)
                    ))
                }
            }
        }
        // 流式续段的目标段尚未落盘 → 序号顺延；链首段（第 1 段）不出交接条。
        let target = settled ? segmentIndex : segmentIndex + 1
        guard target >= 2 else { return nil }

        let think = settled ? entries[index].think : nil
        return DutyHandover(
            segmentIndex: target,
            durationSeconds: think?.dur,
            stepCount: think.map { $0.steps.count },
            stageLabel: self.chainStageLabel(
                headIndex: headIndex, lastIndex: lastIndex, entries: entries
            ),
            nodes: nodes
        )
    }

    /// 链内系统行 → 明细文案：剥事件 emoji（⚡ 不入 eventEmojis，手工剥，同采纳受理行先例），
    /// 超长截断（明细行不做长文展开）。
    fileprivate static func chainNodeText(_ content: String) -> String {
        var text = content
        if text.hasPrefix("⚡") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        text = stripEventEmoji(text)
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    /// 链内阶段徽标（如「③ 原型」）：强模式（①②③④ + 阶段名）命中，取链内最近一次。
    /// 「🔄 已回到 ③ 原型（PRD 标记过期：局部）」同时含 ③ 与 PRD，靠「③ 在前」取胜。
    fileprivate static func chainStageLabel(
        headIndex: Int, lastIndex: Int, entries: [DiscussionEntry]
    ) -> String? {
        let pattern = "[①②③④]\\s*(澄清|结构|原型|PRD)"
        guard lastIndex >= headIndex else { return nil }
        for j in stride(from: lastIndex, through: headIndex, by: -1) {
            let content = entries[j].content
            if let range = content.range(of: pattern, options: .regularExpression) {
                return String(content[range])
            }
        }
        return nil
    }

    /// ISO8601 → 本地 HH:mm:ss（交接明细时间轴；解析失败返回 nil，该行不入轴）。
    private static func hms(_ iso: String) -> String? {
        guard !iso.isEmpty, let date = isoParser.date(from: iso) else { return nil }
        return hmsFormatter.string(from: date)
    }

    private static let hmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 流式回合头部将吸收的尾部系统行索引（与 streamingHeaderNotes 的合并判据一致）。
    /// displayItems 据此跳过独立胶囊渲染——否则同一行「独立卡 + 流式头部注记」双渲染
    /// 持续整个生成过程（流式条目落盘后才由 mergedSystemIndices 接管去重）。
    static func streamingAbsorbedIndices(in entries: [DiscussionEntry]) -> Set<Int> {
        var absorbed = Set<Int>()
        var i = entries.count - 1
        while i >= 0,
              entries[i].role == .system, entries[i].memory == nil,
              !entries[i].isSilent,
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
    /// 向上找指定条目之前最近一条**真实**用户输入（文本 + 附图文件名 + 引用文件路径）。
    /// 跳过历史遗留的「重新生成×」合成指令——旧版截断卡点击会在会话里堆积这类
    /// 伪用户消息，截断-重试循环后最近一条往往是它，不跳过就会把指令误当原始消息重发。
    static func originalUserMessage(
        before id: String, in entries: [DiscussionEntry]
    ) -> (content: String, images: [String], files: [String])? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        for prior in entries[..<idx].reversed() {
            guard prior.role == .user else { continue }
            let text = prior.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("重新生成") { continue }
            return (text, prior.images ?? [], prior.files ?? [])
        }
        return nil
    }

    /// 产物块已出全宽结果卡的文件相对路径 → 落盘文件卡据此跳过，防同文件双卡。
    /// 仅旧会话回退路径消费（leftovers 携带 fileChanges 且无交付回执卡时）：
    /// 原型卡常驻（不受回执影响）；PRD 卡仅在无回执的旧会话回退路径出
    /// （digestVisible = false 时），回执承载期 PRD 由回执主行出卡。
    fileprivate static func blockCardPaths(
        blocks: [ArtifactParser.ArtifactBlock],
        project: String,
        version: String,
        digestVisible: Bool
    ) -> Set<String> {
        var paths: Set<String> = []
        // 原型类块逐槽位出卡（多端多份各自可点，防同文件双卡）
        for block in blocks where ArtifactPath.isPrototypeBlock(block.name) {
            guard let slot = ArtifactPath.prototypeSlot(forBlockName: block.name),
                  artifactFileURL(block.name, project: project, version: version) != nil else {
                continue
            }
            paths.insert(slot.relPath)
        }
        // prd 卡仅在无交付摘要条的旧会话回退路径出（digestVisible = false 时）
        if blocks.contains(where: { $0.name == "prd" }),
           artifactFileURL("prd", project: project, version: version) != nil,
           !digestVisible {
            paths.insert(ArtifactPath.prd)
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
        var stageAutoNote: String?
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
                        // 快速通道链的 📦 行（自动确认，无机器门无确认坞）：
                        // 脚注走自动确认句，禁走「确认坞」指路（方案 A 回执三态之一）
                        if note.text.contains("快速通道") {
                            stageAutoNote = fastForwardAutoNote(from: note.text)
                        }
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
        // 机器初审中（等待态，回执脚注展示）。推进入口在确认坞 / 自由作答。
        if stageLabel != nil || stageAction != nil {
            if reviewDone || stageAutoNote != nil {
                rows.append(MilestoneRow(
                    id: "next", icon: .arrowRight, tint: .brandAccent,
                    name: "\(stageLabel ?? "产物")待确认",
                    tail: stageAction,
                    isNext: true,
                    autoNote: stageAutoNote
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

    /// 快速通道 📦 行文本 → 自动确认脚注句（方案 A 回执三态之一）。
    /// 「📦 结构产物已生成——机器初审中……（快速通道：自动确认，继续生成 ③ 原型）」
    /// → 「快速通道 · 自动确认，继续生成 ③ 原型」；含标记但无括注 → 通用句兜底；
    /// 无快速通道标记 → nil（非快速通道行不适用）。
    static func fastForwardAutoNote(from text: String) -> String? {
        guard text.contains("快速通道") else { return nil }
        if let start = text.range(of: "（快速通道："),
           let end = text.range(of: "）", options: .backwards),
           start.upperBound <= end.lowerBound {
            return "快速通道 · " + text[start.upperBound..<end.lowerBound]
        }
        return "快速通道 · 自动确认，产物已落盘，继续推进后续阶段"
    }

    /// 方案 A 回执脚注推导（纯函数，可单测）：
    /// - autoNote 非空（快速通道）→ 自动确认句（链上无确认坞，禁指路确认坞）；
    /// - isNext（机器初审通过 / 跳过）→ 尾注带「确认后」前缀（①②③ 有确认坞）→
    ///   确认坞指路句——推进动作只活在确认坞，回执只指路不替按；
    ///   尾注无「确认后」前缀（④ PRD 封板流程，无确认坞）→ 就绪句直接接尾注；
    /// - 机器初审中（未出结论）→ 等待态句（原居中注脚文案统一收进脚注行）。
    /// rows 无下一节点行（仅雷达 / 决策的修订轮）→ nil，脚注不渲染。
    static func receiptFooter(for rows: [MilestoneRow]) -> (text: String, waiting: Bool)? {
        guard let next = rows.first(where: { $0.id == "next" }) else { return nil }
        if let auto = next.autoNote {
            return (auto, false)
        }
        if next.isNext {
            if let tail = next.tail {
                if tail.hasPrefix("确认后 ") {
                    let action = String(tail.dropFirst("确认后 ".count))
                    return ("本轮产物就绪。预览满意后，在下方确认坞选择「确认并进入」，\(action)。", false)
                }
                return ("本轮产物就绪。\(tail)。", false)
            }
            return ("本轮产物就绪。", false)
        }
        return ("机器初审中——结论稍后并入本回执", true)
    }

    /// PRD 未改动轮的文件锚（纯函数，可单测；2026-09-18 用户缺口反馈）：
    /// ④ 阶段回合没有携带任何落盘文件（AI 判定「PRD 已是最新，不重排」的迭代轮，
    /// 无 📦 注记 → 回执无主行）且在盘 PRD 存在 → 回执仍渲染一行可点击的
    /// 「PRD文档.md · 本轮未改动」——文件未写 ≠ 用户不需要可达的文档入口。
    /// 非④阶段 / 本轮有真实落盘 / 在盘 PRD 缺失 → nil（不渲染）。
    static func unchangedPRDPointer(
        stage: PipelineRun.Stage, deliveredFiles: [FileChangeSummary], prdExists: Bool
    ) -> FileChangeSummary? {
        guard stage == .prd, deliveredFiles.isEmpty, prdExists else { return nil }
        return FileChangeSummary(path: ArtifactPath.prd, added: 0, removed: 0, isNew: false)
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
        "✅", "⚠️", "🏗️", "🎨", "📝", "🎚️", "📦", "📊", "🔍", "🔒", "🔄", "💀", "🗃️", "🔀", "📌", "ℹ️", "⏹", "⏳", "💬", "🧠"
    ]

    /// 脱前导事件 emoji 与随后的一个空格（注记/事件条统一走 DSIcon，不用 emoji 本体）。
    fileprivate static func stripEventEmoji(_ text: String) -> String {
        let chars = Array(text)
        var i = 0
        while i < chars.count, eventEmojis.contains(String(chars[i])) { i += 1 }
        if i < chars.count, chars[i] == " " { i += 1 }
        return String(chars[i...])
    }

    /// 切出首个「…」片段及其前后文（用于风险自留微行的风险名提亮；
    /// 无闭合引号返回 nil，调用方回退纯灰字）。
    fileprivate static func quotedNameSegments(
        in text: String
    ) -> (before: String, name: String, after: String)? {
        guard let start = text.firstIndex(of: "「") else { return nil }
        let afterStart = text.index(after: start)
        guard let end = text[afterStart...].firstIndex(of: "」") else { return nil }
        return (
            String(text[..<start]),
            String(text[start...end]),
            String(text[text.index(after: end)...])
        )
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
            && lhs.handover == rhs.handover
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
    default: blockName = ArtifactPath.prototypeBlockName(forRelativePath: relativePath)
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
    case "prd": "产品需求文档"
    case "analysis": "竞品分析报告"
    case "radar": "漏项雷达"
    case "decision": "决策记录"
    case let n where ArtifactPath.isPrototypeBlock(n):
        ArtifactPath.prototypeSlot(forBlockName: n)?.display ?? "交互原型"
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
    case "prd": relativePath = ArtifactPath.prd
    case "analysis": relativePath = ArtifactPath.competitiveAnalysis
    case let n where ArtifactPath.isPrototypeBlock(n):
        relativePath = ArtifactPath.prototypeSlot(forBlockName: n)?.relPath
    default: relativePath = nil  // radar/decision 落 jsonl，右栏 Tab 承载
    }
    guard let relativePath, !project.isEmpty, !version.isEmpty else { return nil }
    let url = PMAgentStore.versionURL(project: project, version: version)
        .appendingPathComponent(relativePath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// 产物块渲染区：结构图表（architecture/core-flows/business-flows = mermaid 图源，
/// module-page-map = 管道表格 markdown）内联直接渲染；文件类产物（原型 / PRD / 竞品
/// 分析等）已落盘可交互 → 全宽生成文件卡；jsonl 类（雷达 / 决策）与未落盘产物
/// 不出占位卡——2026-09-15 用户钦定：「XX 已生成」灰胶囊一律不要（雷达 / 决策的
/// 入账事实由交付回执卡承载，右栏台账亦可查）。**勿恢复胶囊兜底**
/// （切会话中途完成的回合无回执载荷，旧胶囊正是在这些会话里冒出来）。
// MARK: - 本轮任务计划卡（plan-act-reflect 的 plan 段）

/// 计划卡：②③④ 生成/修订产物轮次的「先计划后执行」可见锚点。
/// 零容器降噪基调（与 DutyHandoverBar 同族）：图标行 + 编号步骤列表，
/// 不与正文抢层级；条目可拖选（不挂 compositing 修饰符）。
private struct PlanCardView: View {
    let plan: ArtifactParser.PlanCard

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s6) {
                DSIcon(.barList, size: 12)
                    .foregroundStyle(Color.ink500)
                Text("本轮计划")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                if let mission = plan.mission, !mission.isEmpty {
                    Text(mission)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink700)
                        .lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: DS.Spacing.s6) {
                        Text("\(index + 1).")
                            .font(DS.Font.bodyXS)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink300)
                        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                            Text(step.action)
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink700)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if let basis = step.basis,
                               !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("依据：\(basis)")
                                    .font(DS.Font.bodyXS)
                                    .foregroundStyle(Color.ink300)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, DS.Spacing.s16)
    }
}

private struct ArtifactBlocksSection: View {
    let blocks: [ArtifactParser.ArtifactBlock]
    var project: String = ""
    var version: String = ""
    /// 交付回执卡承载期（方案 A）文件类产物块全静默：原型卡 / PRD / analysis 等
    /// 文件卡的主行事实由回执卡主行承载（防同文件双卡）；内联图表（mermaid /
    /// 管道表格）是回答正文的一部分，不受影响。雷达 / 决策块本就无卡无胶囊，恒静默。
    var hideFileCards: Bool = false
    /// 点击文件产物卡片 → 打开预览；nil = 非交互态（流式中）
    var onOpen: ((FileNode) -> Void)? = nil

    /// 内容为空（异常流）→ 按无内容处理（不出图，也不出占位）。
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
            // 原型结果卡：阶段主交付物（含 prototype-<slug> 分端槽位，多端多卡），
            // 全宽块卡；交付回执卡承载期静默——主行事实由回执卡承载（防双卡）
            ForEach(blocks.filter { ArtifactPath.isPrototypeBlock($0.name) && !hideFileCards }, id: \.name) { block in
                prototypeBlock(block)
            }
            // 文件类产物卡（prd / analysis 等已落盘可交互）：与原型卡同族的生成文件卡，
            // 全宽；交付回执卡承载期（hideFileCards）不出卡——回执主行已承载。
            // 其余块（雷达 / 决策 / 流式未落盘）无卡即无渲染，不设灰胶囊占位。
            ForEach(blocks.filter(showsFileCard), id: \.name) { block in
                fileCard(block)
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
                MarkdownText(block.content, bodySize: DS.Typography.chatBodySize, readingMeasure: DS.Typography.chatMeasure)
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
    /// 流式中（生成进度卡承载）/ 未落盘 → 不出占位。
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
        }
    }

    /// 文件类产物块出卡判据：已落盘且可交互（流式 onOpen = nil 不出卡）；
    /// 结构图表块（architecture / core-flows / business-flows / module-page-map）已内联
    /// 渲染，不再出文件卡——否则同一产物「内联图表 + 文件卡」双渲染（落盘后必现）；
    /// 交付回执卡承载期（hideFileCards）一律不出卡——回执主行已承载全部文件事实。
    private func showsFileCard(_ block: ArtifactParser.ArtifactBlock) -> Bool {
        guard onOpen != nil, !hideFileCards, !isInlineChart(block),
              !ArtifactPath.isPrototypeBlock(block.name),
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

    /// 中性提示胶囊回退区已整体移除（2026-09-15 钦定）：雷达 / 决策无卡可出即静默，
    /// 产物落盘后由生成文件卡承载；「XX 已生成」灰胶囊不得再引入。
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
                DSIcon(icon, size: 18)
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.xl)
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
            // 2026-09 呼吸感改版：42 图标砖 + 22/18 内衬 + 无描边明度浮起（hover 加深一档）
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r18)
                    .fill(hovered ? Color.overlayL2 : Color.overlayL1)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.r18))
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

// MARK: - 变更提案卡（变更分诊：LLM 提案，用户三选裁决；处置状态查 AppModel.changeLedger）

/// 提案卡三动作：纳入当前版本（走回退 + 重生成）/ 放入候选池 / 继续讨论。
/// 已处置后按钮收起、出处置徽章——台账（changes.jsonl）是状态事实源，卡片只渲染。
private struct ChangeProposalCard: View {
    @EnvironmentObject private var model: AppModel
    let proposal: ChangeProposalRecord

    private var item: ChangeItem? {
        model.changeLedger.first { $0.id == proposal.id }
    }
    private var resolution: ChangeResolution? { item?.resolution }

    /// 建议文案（target 已在登记时过白名单；nil = 模型仅登记未建议回退）。
    private var suggestionText: String? {
        switch proposal.target.flatMap(AppModel.backtrackStage) {
        case .clarify: "回① 澄清（增补模式，先判断可行性）"
        case .structure: "回② 结构（原型与 PRD 连带失效）"
        case .prototype: "回③ 原型重做（PRD 失效）"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            // 头行：标识 + 分类 + 建议
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(.arrowSwap, size: 13)
                    .foregroundStyle(Color.brand600)
                Text("变更提案")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink500)
                if let category = proposal.category, !category.isEmpty {
                    DSTag(title: category, variant: .neutral)
                }
                Spacer(minLength: 0)
                if let suggestionText, resolution == nil {
                    Text("建议 \(suggestionText)")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .lineLimit(1)
                }
            }

            // 想法一句话（卡片主角）
            Text(proposal.idea)
                .font(DS.Font.bodyMDStrong)
                .foregroundStyle(Color.ink900)
                .dsBodyType(size: 14)
                .textSelection(.enabled)

            // 影响清单（防轻描淡写：看得见论据的确认才不是橡皮图章）
            impactSection

            // 处置区
            if resolution == nil {
                DSDivider()
                HStack(spacing: DS.Spacing.s8) {
                    Button {
                        model.adoptChangeProposal(proposal)
                    } label: {
                        Text("纳入当前版本")
                    }
                    .buttonStyle(.ds(.primary, size: .sm))
                    // 本版本口径（阶段 3）：纳入重写本版本状态机并重生成，
                    // 与 AppModel.adoptChangeProposal 守卫同口径
                    .disabled(model.currentVersionReleased
                        || model.sessionStore.isVersionBusy(project: model.pipeline.project, version: model.pipeline.version))

                    Button {
                        model.poolChangeProposal(proposal)
                    } label: {
                        Text("放入候选池")
                    }
                    .buttonStyle(.ds(.secondary, size: .sm))

                    Button {
                        model.dismissChangeProposal(proposal)
                    } label: {
                        Text("继续讨论")
                    }
                    .buttonStyle(.ds(.ghost, size: .sm))
                }
            } else {
                resolvedBadge
            }
        }
        .padding(DS.Spacing.s12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }

    /// 影响清单：产物级引用逐条列出；缺失时明示（不假装没有论据）。
    @ViewBuilder
    private var impactSection: some View {
        if let impacts = proposal.impacts, !impacts.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                Text("影响")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink300)
                ForEach(impacts, id: \.self) { impact in
                    HStack(alignment: .top, spacing: DS.Spacing.s6) {
                        DSIcon(.dot, size: 5)
                            .foregroundStyle(Color.ink300)
                            .padding(.top, 6)
                        Text(impact)
                            .font(DS.Font.bodySM)
                            .foregroundStyle(Color.ink700)
                            .dsBodyType(size: 13)
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            Text("未提供影响清单——建议仅供参考。")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink300)
        }
    }

    /// 已处置徽章（台账状态投影；note 补充处置语境）。
    private var resolvedBadge: some View {
        HStack(spacing: DS.Spacing.s6) {
            switch resolution {
            case .adopted:
                DSIcon(.circleCheck, size: 12).foregroundStyle(Color.statusSuccess)
                Text("已采纳").font(DS.Font.bodyXSStrong).foregroundStyle(Color.statusSuccess)
            case .pooled:
                DSIcon(.bookmark, size: 12).foregroundStyle(Color.brand600)
                Text("已放入候选池").font(DS.Font.bodyXSStrong).foregroundStyle(Color.brand600)
            case .deferred:
                DSIcon(.clock, size: 12).foregroundStyle(Color.ink500)
                Text("已顺延").font(DS.Font.bodyXSStrong).foregroundStyle(Color.ink500)
            default:
                DSIcon(.circleMinus, size: 12).foregroundStyle(Color.ink500)
                Text("未采纳").font(DS.Font.bodyXSStrong).foregroundStyle(Color.ink500)
            }
            if let note = item?.resolutionNote, !note.isEmpty {
                Text("· \(note)")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
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
    /// 行数直传（流式结构化口径，全量行数）；nil = 从 partial 现算（历史轮全量文本）
    var lineCount: Int? = nil

    private var icon: DSIcon.Name {
        switch name {
        case "prd": .document
        case "analysis": .barList
        case "radar": .glasses
        case "decision": .note
        case let n where ArtifactPath.isPrototypeBlock(n): .browser
        default: .doc
        }
    }

    private var progressText: String {
        if let lineCount, lineCount > 0 { return "已生成 \(lineCount) 行" }
        guard !partial.isEmpty else { return "正在准备…" }
        let lines = partial.split(separator: "\n", omittingEmptySubsequences: false).count
        return "已生成 \(lines) 行"
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s12) {
            DSIcon(icon, size: 18)
                .foregroundStyle(Color.brandAccent)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xl)
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
        // 2026-09 呼吸感改版：与 GeneratedFileCard 同族——42 砖 + 22/18 内衬 + 无描边浮起
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.r18)
                .fill(Color.overlayL1)
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
    /// 展示正文（发布点已剥离完整块、裁除进行中块，只剩块间正文）
    let display: String
    /// 已闭合完整产物块（结构化下发，识别链不再依赖被裁剪的展示文本）
    let blocks: [ArtifactParser.ArtifactBlock]
    /// 进行中（未闭合）产物块名；空 = 无
    let inProgressName: String
    /// 进行中块已生成行数（全量口径）
    let inProgressLines: Int
    var project: String = ""
    var version: String = ""

    /// 收进进度卡的块名判定（流式中收起源码，只显进度）：prd + 全部原型类槽位
    /// （prototype / prototype-<slug> 分端块同样收起，防 HTML 源码刷屏）。
    private static func isProgressCardBlock(_ name: String) -> Bool {
        name == "prd" || ArtifactPath.isPrototypeBlock(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            // 本轮任务计划卡（流式中与最终消息同位：计划块最先闭合 → 卡先于正文出现）
            if let plan = ArtifactParser.parsePlan(blocks: blocks) {
                PlanCardView(plan: plan)
            }
            if !display.isEmpty {
                // Markdown 实时渲染（未闭合普通围栏容错到文末）；
                // liveMermaid = false：流式中的 mermaid 围栏降级为代码块，
                // 避免逐 tick 的 WKWebView 整页重载（流结束转正式条目后恢复图表）
                MarkdownText(
                    display, liveMermaid: false,
                    readingMeasure: DS.Typography.chatMeasure,
                    semanticSections: true
                )
            }
            ArtifactBlocksSection(
                blocks: blocks,
                project: project,
                version: version,
                onOpen: nil
            )
            if Self.isProgressCardBlock(inProgressName) {
                ArtifactProgressCard(
                    name: inProgressName, partial: "",
                    lineCount: inProgressLines
                )
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

/// 引用文件 chip（产物台账右键「添加到对话」）：`<>` 图标 + 文件名。
/// 输入坞内可移除——hover 时左侧图标槽位交叉淡化为关闭钮（同槽位不产生布局跳变）；
/// 用户气泡内为静态展示（深底反色）。完整相对路径走 help 悬停提示。
struct ReferencedFileChip: View {

    enum Tone {
        case composer   // 输入坞：浅底描边胶囊
        case bubble     // 用户气泡：深底白系胶囊
    }

    let relativePath: String
    var tone: Tone = .composer
    var onRemove: (() -> Void)?

    @State private var hovering = false

    private var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    private var showRemove: Bool { hovering && onRemove != nil }

    var body: some View {
        HStack(spacing: DS.Spacing.s6) {
            // 左槽位：`<>` ↔ 关闭钮 交叉淡化（16×16 固定，hover 不推挤文件名）
            ZStack {
                DSIcon(.code, size: 10)
                    .foregroundStyle(iconColor)
                    .opacity(showRemove ? 0 : 1)
                if let onRemove {
                    Button(action: onRemove) {
                        DSIcon(.close, size: 8)
                            .foregroundStyle(iconColor)
                            .frame(width: 15, height: 15)
                            .background(
                                Circle().fill(
                                    tone == .composer
                                        ? Color.overlayL2
                                        : Color.white.opacity(0.22)
                                )
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(showRemove ? 1 : 0)
                    .allowsHitTesting(showRemove)
                    .help("移除该文件引用")
                }
            }
            .frame(width: 16, height: 16)

            Text(fileName)
                .font(DS.Font.bodySM)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DS.Spacing.s8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(tone == .composer ? Color.surfaceSecondary : Color.white.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(
                    tone == .composer
                        ? (hovering ? Color.borderL3 : Color.borderL2)
                        : Color.white.opacity(0.18),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        // 文件名超长时 chip 不撑破输入坞：上限 220pt，超出中间省略
        .frame(maxWidth: 220, alignment: .leading)
        .onHover { inside in
            withAnimation(DS.Motion.springFast) { hovering = inside }
        }
        .help(relativePath)
        .animation(DS.Motion.springFast, value: hovering)
    }

    private var iconColor: Color {
        tone == .composer ? Color.ink500 : Color.white.opacity(0.75)
    }

    private var titleColor: Color {
        tone == .composer ? Color.ink800 : Color.white
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
/// P3：发起会话流式期间复用为插话钮（同形制，help 文案区分语义）。
private struct ComposerSendButton: View {
    let enabled: Bool
    var help: String = "发送（⏎ · ⇧⏎ 换行）"
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
        .help(help)
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
