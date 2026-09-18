//
//  BacktrackDock.swift
//  pm_worker
//
//  回退坞（④ PRD 阶段的快捷回退入口，与 ConfirmDock 同构的询问卡）：
//  收起态 = 虚线图标小胶囊（不占空间的可选动作入口，无文案）；点击展开 = 选项卡片单选
//  （重做原型 / 重做结构，回退后果写在副标题里，不再藏 tooltip），
//  页脚动作钮执行 AppModel.requestBacktrack（回退 + 自动重生成，redo 语义）。
//  视觉规格与 ConfirmDock 逐一对齐（折叠胶囊 / 白底浮卡 / 勾选框 / 数字徽章）。
//

import SwiftUI

struct BacktrackDock: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var store: SessionStore

    /// 收起态（默认收起：可选动作而非闸口，不像确认坞默认展开）。
    @State private var collapsed = true
    /// 单选（默认推荐项：重做原型——最近的上游）。
    @State private var selection: Option = .prototype
    /// 选项卡 hover 态（边框升阶）。
    @State private var hoveredOption: Option?

    /// 重做目标（单选；rawValue = 数字徽章编号）。
    enum Option: Int, CaseIterable {
        case prototype = 1  // 重做原型
        case structure = 2  // 重做结构

        var title: String {
            switch self {
            case .prototype: "重做原型"
            case .structure: "重做结构"
            }
        }

        var subtitle: String {
            switch self {
            case .prototype: "回退到 ③ 原型并立即重新生成，PRD 标记过期；新原型确认后可重新生成 PRD"
            case .structure: "回退到 ② 结构并立即重新生成，原型与 PRD 一并标记过期"
            }
        }
    }

    init(model: AppModel) {
        self.model = model
        self.store = model.sessionStore
    }

    var body: some View {
        Group {
            if collapsed {
                collapsedBar
            } else {
                dock
            }
        }
        // 与输入区同宽的 720 居中列（与 ConfirmDock 同一停靠规格）
        .frame(maxWidth: 720 + DS.Spacing.s64)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.s32)
        .padding(.bottom, DS.Spacing.s8)
    }

    // MARK: - 收起细条（虚线胶囊，点击展开询问卡）

    private var collapsedBar: some View {
        Button {
            withAnimation(DS.Motion.springFast) { collapsed = false }
        } label: {
            DSIcon(.refresh, size: 13)
                .foregroundStyle(Color.ink500)
                .padding(.horizontal, DS.Spacing.s10)
                .padding(.vertical, DS.Spacing.s6)
                .background(
                    Capsule().fill(Color.surfaceSecondary)
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.borderL2,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("重做上游产物")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 询问卡（白底浮起 · 淡紫描边 · 大软阴影，与确认坞同构）

    private var dock: some View {
        VStack(spacing: 0) {
            headerRow
            DSDivider()

            // 内容区（同 ConfirmDock）：窗口变矮时降级为坞内滚动，不挤占消息流
            ViewThatFits(in: .vertical) {
                optionsPanel
                DSScroll { optionsPanel }
            }

            footerRow
                .padding(.horizontal, DS.Spacing.s12)
                .padding(.vertical, DS.Spacing.s10)
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
    }

    private var headerRow: some View {
        HStack(spacing: DS.Spacing.s6) {
            DSIcon(.refresh, size: 14)
                .foregroundStyle(Color.brandAccent)
            Text("重做上游产物")
                .font(DS.Font.headingXS)
                .foregroundStyle(Color.ink900)
            Spacer(minLength: DS.Spacing.s12)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    private var optionsArea: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            Text("选择要回退重做的上游阶段，AI 随即回退并重新生成：")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .padding(.bottom, DS.Spacing.s2)

            VStack(spacing: DS.Spacing.s6) {
                ForEach(Option.allCases, id: \.self) { option in
                    optionCard(option)
                }
            }
        }
    }

    /// 选项区面板（浅灰底衬托）：ViewThatFits 自然 / 滚动两分支复用同一内容
    private var optionsPanel: some View {
        optionsArea
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s12)
            .background(Color.surfaceSecondary)
    }

    // MARK: 选项卡片（白底 + 勾选框 + 说明 + 数字徽章；选中态品牌紫，与确认坞同款）

    private func optionCard(_ option: Option) -> some View {
        let selected = selection == option
        let hovered = hoveredOption == option
        return Button {
            withAnimation(DS.Motion.springFast) { selection = option }
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                checkBox(selected)
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(option.title)
                        .font(DS.Font.bodySMStrong)
                        .foregroundStyle(Color.ink900)
                    Text(option.subtitle)
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

    // MARK: - 底部：右对齐动作钮（取消收起 / 执行所选重做）

    private var footerRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            Spacer()
            Button {
                withAnimation(DS.Motion.springFast) { collapsed = true }
            } label: {
                Text("取消")
            }
            .buttonStyle(.ds(.secondary, size: .sm))

            Button {
                performSelection()
            } label: {
                Label {
                    Text(selection.title)
                } icon: {
                    DSIcon(.refresh, size: 12)
                }
            }
            .buttonStyle(.ds(.brand, size: .sm))
            // 本会话口径（阶段 3）：回溯重发本会话消息，他会话的流不禁用本坞
            .disabled(store.isSessionBusy(store.sessionId))
        }
    }

    /// 执行所选重做：先收起（回退会切阶段，本坞随条件移除；守卫拦截时也不残留展开卡）。
    private func performSelection() {
        withAnimation(DS.Motion.springFast) { collapsed = true }
        model.requestBacktrack(to: selection == .prototype ? .prototype : .structure)
    }
}
