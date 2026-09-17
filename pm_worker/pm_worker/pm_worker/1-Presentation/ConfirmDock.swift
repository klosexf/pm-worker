//
//  ConfirmDock.swift
//  pm_worker
//
//  确认段内容件（Task 2.2，design.md §6.1 阶段推进确认通用机制）：
//  无卡片外壳，由 StageDockCard 统一停靠卡承载（2026-09-15 改版：作答段 → 确认段
//  同卡分步切换，替代确认坞 / 作答坞两卡同叠；卡壳 / 720 停靠列 / 描边 / 浮起影统一）。
//  结构（2026-09 布局改版：选项卡片 + 右下角动作钮）——
//  单页直接确认（design.md v0.9.12：取消两段式提交的第二页摘要，
//  「确认后会发生什么」由选项卡副标题用人话承载，选中后页脚按钮直接提交生效）——
//  ① 选择处理方式（确认并进入 / 继续修改），单选卡片 + 数字徽章
//  ② 弹出纪律（2026-09-15 改版，每版本每阶段弹一次）：产物落盘弹坞一次；「稍后再说 / 继续修改」
//     写入 AppModel.deferConfirmGate → 版本级持久静默（confirm-silence.json，
//     跨启动 / 跨会话，重启不重复弹、💬 留痕不重复落），修订落盘也不弹，
//     推进由用户发起（自由作答「进入下一阶段」/ 摘要条兜底行）；
//     静默中的修订轮由 gateInviteSuffix 在 AI 回复末尾融一句推进邀请。
//  提交后对话流落确认记录胶囊（AppModel 写入）。
//

import SwiftUI

/// 确认段内容件：头部（图标 + 标题）+ 选项区（浅灰底）+ 页脚动作钮。
/// 卡壳（surfaceBase 底 / brand200 描边 / floating 影 / xxl 圆角 / 滑入）由 StageDockCard 统一承载。
struct ConfirmDockContent: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var store: SessionStore

    let target: AppModel.ConfirmTarget

    /// 单选（默认推荐项：确认并进入）。
    @State private var selection: Option = .proceed
    /// 选项卡 hover 态（边框升阶）。
    @State private var hoveredOption: Option?

    /// 处理方式选项（单选；rawValue = 数字徽章编号）。「稍后再说」走页脚次按钮，不占选项位。
    private enum Option: Int, CaseIterable {
        case proceed = 1       // 确认并进入
        case editLater = 2     // 继续修改
    }

    init(model: AppModel, target: AppModel.ConfirmTarget) {
        self.model = model
        self.store = model.sessionStore
        self.target = target
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            DSDivider()

            // 内容区：浅灰底衬托白底选项卡（问卷卡层次）
            optionsArea
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s12)
                .background(Color.surfaceSecondary)

            footerRow
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s10)
        }
    }

    // MARK: - 头部：图标 + 标题（与作答段头部同规格：图标 16 · brandAccent · headingSM）

    private var headerRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            DSIcon(.circleCheck, size: 16)
                .foregroundStyle(Color.brandAccent)
            Text(target.title)
                .font(DS.Font.headingSM)
                .foregroundStyle(Color.ink900)
            Spacer(minLength: DS.Spacing.s12)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    // MARK: - 主体：问句 + 选项卡片

    private var optionsArea: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            // ① 的要点表在确认时才生成（此刻尚未落盘），不能说「已就绪」——
            // ②③ 产物已在盘，保持「已就绪」表述
            Text(target == .clarify
                 ? "澄清对话已收束，确认后将生成要点表并进入 ② 结构设计："
                 : "\(target.title)已就绪，选择接下来的处理方式：")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .padding(.bottom, DS.Spacing.s2)

            VStack(spacing: DS.Spacing.s6) {
                optionCard(
                    .proceed,
                    title: "确认并进入\(target.nextStage)",
                    subtitle: proceedSubtitle
                )
                optionCard(
                    .editLater,
                    title: "继续修改",
                    subtitle: "收起确认坞，回到对话补充信息"
                )
            }
        }
    }

    /// 主选项副标题（按闸口分档，结果导向：确认后定稿什么、AI 接下来做什么）。
    private var proceedSubtitle: String {
        switch target {
        case .clarify: "把聊定的结论整理成要点表存档，AI 随即开始设计产品结构"
        case .structure: "结构定稿存档，AI 随即开始生成可交互网页原型"
        case .prototype: "原型定稿存档，AI 随即开始撰写产品需求文档"
        }
    }

    // MARK: 选项卡片（白底 + 勾选框 + 说明 + 数字徽章；选中态品牌紫）

    private func optionCard(_ option: Option, title: String, subtitle: String) -> some View {
        let selected = selection == option
        let hovered = hoveredOption == option
        return Button {
            withAnimation(DS.Motion.springFast) { selection = option }
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                checkBox(selected)
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(title)
                        .font(DS.Font.bodySMStrong)
                        .foregroundStyle(Color.ink900)
                    Text(subtitle)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Spacing.s8)
                numberBadge(option.rawValue, selected: selected)
            }
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(selected ? Color.brand50 : Color.surfaceBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(
                        selected ? Color.brand600 : (hovered ? Color.borderL3 : Color.borderL1),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.springFast) {
                hoveredOption = hovering ? option : nil
            }
        }
    }

    /// 勾选框：16×16 圆角方框，选中品牌紫填充 + 白勾。
    private func checkBox(_ selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(selected ? Color.brand600 : Color.surfaceBase)
            if selected {
                DSIcon(.check, size: 10)
                    .foregroundStyle(Color.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 16, height: 16)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(
                    selected ? Color.brand600 : Color.borderL3,
                    lineWidth: 1
                )
        )
        .animation(DS.Motion.springFast, value: selected)
    }

    /// 数字徽章：右侧圆角小方块（未选灰底 / 选中品牌紫底白字）。
    private func numberBadge(_ index: Int, selected: Bool) -> some View {
        Text("\(index)")
            .font(DS.Font.monoSM)
            .foregroundStyle(selected ? Color.white : Color.ink500)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(selected ? Color.brand600 : Color.surfaceTertiary)
            )
            .animation(DS.Motion.springFast, value: selected)
    }

    // MARK: - 底部：右对齐动作钮（随所选选项执行；「确认并进入」直接提交生效）

    private var footerRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            Spacer()
            Button {
                // 稍后再说：本版本内永久静默（每版本每阶段弹一次，持久化跨启动），
                // 坞随挂载条件消失；推进改由自由作答 / 摘要条兜底行发起
                model.deferConfirmGate(target)
            } label: {
                Text("稍后再说")
            }
            .buttonStyle(.ds(.secondary, size: .sm))

            Button {
                performSelection()
            } label: {
                Label {
                    Text(primaryTitle)
                } icon: {
                    DSIcon(selection == .proceed ? .check : .arrowRight, size: 12)
                }
            }
            .buttonStyle(.ds(selection == .proceed ? .brand : .secondary, size: .sm))
            .disabled(selection == .proceed && store.isStreaming)
        }
    }

    /// 主按钮文案随所选选项变化（选什么，按钮就执行什么）。
    private var primaryTitle: String {
        switch selection {
        case .proceed: "确认并进入"
        case .editLater: "继续修改"
        }
    }

    /// 执行所选选项：确认 → 提交生效（触发下一阶段生成）；继续修改 → 静默本阶段。
    private func performSelection() {
        guard selection == .proceed else {
            model.deferConfirmGate(target)
            return
        }
        Task {
            await model.confirmCurrentStage()
        }
    }
}
