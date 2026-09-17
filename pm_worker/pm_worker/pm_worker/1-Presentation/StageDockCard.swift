//
//  StageDockCard.swift
//  pm_worker
//
//  统一阶段停靠卡（输入区正上方，与输入区同宽的 720 居中列）：
//  作答段 → 分支确认段 → 确认段 依次切换，同一张卡呈现——替代原「确认坞 + 作答坞」
//  两张独立卡同时叠挂的旧设计（样式不一致与视觉噪音的来源）。
//  · 作答段（最高优先）：存在待答问题且作答坞开启 → ClarifyAnswerContent
//    （多题问题卡向导 / 单题选项行；单题口径全阶段放开，同原作答坞）
//  · 分支确认段：意图误触发防护待决（pendingBranchConfirmation 归属本会话）→
//    BranchConfirmContent——分支执行是用户最新消息的直接回应，优先于常驻确认段
//    （闸口状态不消失，分支裁决完自动回补）
//  · 确认段：闸口就绪（confirmTarget 非空 · 非流式 · 未静默）→ ConfirmDockContent
//  卡壳统一且常驻（surfaceBase 底 · brand200 描边 · floating 浮起影 · xxl 圆角 · 滑入）：
//  段切换时卡不重建，内容换段走 spring 过渡（透明度渐变，卡体高度随内容弹簧过渡）。
//  开合契约（宿主 ConversationView 驱动）不变：待答问题自动弹出一次，
//  显式关闭后同问题不再自动弹出（输入区上方触发 chip 兜底重开）。
//

import SwiftUI

/// 待答问题快照（作答段数据源）：多题问题卡优先，否则单题末尾选项行。
/// （原 ConversationView 私有嵌套类型上提：StageDockCard 跨视图消费）
struct PendingQuestion {
    let entryId: String
    let wizard: ArtifactParser.QuestionCardRequest?
    let options: ArtifactParser.ClarifyOptions?
    /// 收尾确认问（① 澄清一次确认）：单组选项行 + [收尾确认] 标记 + 闸口就绪。
    /// 点选「确认」开头选项 = 闸口确认（confirmStageByAnswer），不再二次弹确认段。
    let isGateConfirm: Bool

    init(
        entryId: String,
        wizard: ArtifactParser.QuestionCardRequest?,
        options: ArtifactParser.ClarifyOptions?,
        isGateConfirm: Bool = false
    ) {
        self.entryId = entryId
        self.wizard = wizard
        self.options = options
        self.isGateConfirm = isGateConfirm
    }
}

struct StageDockCard: View {
    let model: AppModel
    let store: SessionStore

    /// 待答问题（nil = 无待答，作答段不挂载）。
    let pending: PendingQuestion?
    /// 作答段开关（宿主维护：自动弹出 / 显式关闭 / 触发 chip 重开）。
    let showAnswerSection: Bool
    /// 确认段闸口（nil = 未就绪 / 流式中 / 已静默，确认段不挂载）。
    let confirmTarget: AppModel.ConfirmTarget?
    /// 分支确认待决（nil = 无待决，分支确认段不挂载；宿主已按归属会话过滤）。
    let branchPending: AppModel.PendingBranchConfirmation?

    /// 当前阶段短名（作答段头部 mono 眉标，如「追问 · ③ 原型」；nil 不显示）。
    let stageLabel: String?

    let onCloseAnswer: () -> Void
    let onSubmitAnswer: (String) -> Void

    /// 卡内激活段：作答段最高优先（待答问题先处理）→ 分支确认段（用户最新意图）→ 确认段。
    private enum Section {
        case answer
        case branch
        case confirm
    }

    private var activeSection: Section? {
        if pending != nil, showAnswerSection { return .answer }
        if branchPending != nil { return .branch }
        if confirmTarget != nil { return .confirm }
        return nil
    }

    var body: some View {
        Group {
            switch activeSection {
            case .answer:
                if let pending {
                    ClarifyAnswerContent(
                        wizard: pending.wizard,
                        options: pending.options,
                        entryId: pending.entryId,
                        stageLabel: stageLabel,
                        isStreaming: store.isStreaming,
                        onClose: onCloseAnswer,
                        onSubmit: onSubmitAnswer
                    )
                    .transition(.opacity)
                }
            case .branch:
                if let branchPending {
                    BranchConfirmContent(model: model, topic: branchPending.topic)
                        .transition(.opacity)
                }
            case .confirm:
                if let confirmTarget {
                    ConfirmDockContent(model: model, target: confirmTarget)
                        .transition(.opacity)
                }
            case nil:
                EmptyView()
            }
        }
        .background(
            Color.surfaceBase,
            in: RoundedRectangle(cornerRadius: DS.Radius.xxl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.brand200, lineWidth: 1)
        )
        .dsShadow(.floating)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
        .dsSlideIn()
        // 段切换（卡壳常驻、内容换段）：spring 驱动透明度与卡体高度过渡
        .animation(DS.Motion.spring, value: activeSection)
        // 与输入区同宽的 720 居中列（原型 DockCard 停靠于输入框正上方）
        .frame(maxWidth: 720 + DS.Spacing.s64)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.s32)
        .padding(.bottom, DS.Spacing.s8)
    }
}

/// 分支确认段内容件（意图误触发防护，design.md §12）：意图命中分支后不直接后台执行，
/// 停靠卡先征求用户裁决——确认前不联网、不落产物。文案结果导向（做什么、产出什么），
/// 不出现内部路径与架构术语。裁决回调走 AppModel.confirmBranchRun / cancelBranchRun。
struct BranchConfirmContent: View {
    @ObservedObject private var model: AppModel
    let topic: String

    init(model: AppModel, topic: String) {
        self.model = model
        self.topic = topic
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            DSDivider()

            Text("你提到了竞品调研。AI 将联网检索竞品资料，生成一份带出处的分析报告存入本项目——撰写 PRD 时会参考。执行在后台进行，不耽误继续对话。")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s12)
                .background(Color.surfaceSecondary)

            footerRow
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s10)
        }
    }

    // MARK: 头部（与确认段头部同规格：图标 16 · brandAccent · headingSM）

    private var headerRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            DSIcon(.search, size: 16)
                .foregroundStyle(Color.brandAccent)
            Text("想运行「竞品分析」")
                .font(DS.Font.headingSM)
                .foregroundStyle(Color.ink900)
            Spacer(minLength: DS.Spacing.s12)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    // MARK: 底部：右对齐动作钮（与确认段页脚同规格）

    private var footerRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            Spacer()
            Button {
                model.cancelBranchRun()
            } label: {
                Text("暂不运行")
            }
            .buttonStyle(.ds(.secondary, size: .sm))

            Button {
                model.confirmBranchRun()
            } label: {
                Label {
                    Text("运行")
                } icon: {
                    DSIcon(.arrowRight, size: 12)
                }
            }
            .buttonStyle(.ds(.brand, size: .sm))
        }
    }
}
