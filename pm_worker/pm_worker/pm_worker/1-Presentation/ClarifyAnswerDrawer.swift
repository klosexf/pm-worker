//
//  ClarifyAnswerDrawer.swift
//  pm_worker
//
//  澄清作答段内容件：所有需要用户点选作答的澄清问题统一收口到输入区上方
//  StageDockCard 统一停靠卡的作答段（2026-09-15 改版：作答段 → 确认段同卡分步切换，
//  本视图不再自带卡片外壳——卡壳 / 720 停靠列 / 描边 / 浮起影由 StageDockCard 统一承载，
//  与确认段同规格）。
//  两种模式（选项样式统一为 ConfirmDock optionCard 同款卡片：radio 圆 / 勾选框 + 数字徽标）：
//  · 多题：artifact:question-card 块 → ClarifyQuestionCard 向导整体搬入
//    （逐题 / 上一步 / 回顾 / 跳过，作答进度在坞内维护）；末条回复末尾出现
//    ≥2 组「A) xxx」选项行组（模型未走问题卡协议一次抛多问）同样转该向导逐题作答；
//  · 单题：末条 AI 回复末尾连续「A) xxx」选项行 → ClarifySingleForm
//    （点选即发送 + 自由输入 + 跳过此题）。
//
//  开合契约（宿主 ConversationView 驱动）：
//  · 待答问题出现自动弹出一次；显式关闭后同一问题不再自动弹出（输入区上方触发 chip 兜底）；
//  · 提交 = 拼装消息走 sendMessage 通道，答案随用户消息留痕，pending 清空后切回确认段；
//  · 消息流不再渲染可点选 chips——末条消息的原始选项行同步折叠（防点不了的假选项）。
//

import SwiftUI

/// 作答段内容件：头部（图标 + 标题 + 模式副标题 + 关闭钮）+ 多题向导 / 单题表单。
struct ClarifyAnswerContent: View {
    /// 多题问题卡（优先）；单题选项行（兜底）——同一条回复理论上只出其一。
    let wizard: ArtifactParser.QuestionCardRequest?
    let options: ArtifactParser.ClarifyOptions?
    /// 承载待答问题的 assistant entry id（作为内容身份：新问题重置向导作答进度）。
    let entryId: String
    /// 当前阶段短名（头部 mono 眉标「追问 · ③ 原型」：标注追问归属阶段；nil 不显示）。
    let stageLabel: String?
    /// 本会话 busy（阶段 3 口径，宿主传 isSessionBusy(本会话)）：问题卡属于当前
    /// 会话的澄清流——本会话流式/占位中禁动作，他会话的流不影响。
    let sessionBusy: Bool
    /// 显式关闭（X / 跳过此题）：宿主记下当前问题 id，同问题不再自动弹出。
    let onClose: () -> Void
    /// 提交（多题拼装消息 / 单题点选即发 / 自定义输入），宿主走 sendMessage 通道。
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            DSDivider()
            Group {
                if let wizard {
                    ClarifyQuestionCard(
                        request: wizard,
                        sessionBusy: sessionBusy
                    ) { assembled in
                        onSubmit(assembled)
                    }
                } else if let options {
                    ClarifySingleForm(
                        options: options,
                        sessionBusy: sessionBusy,
                        onSubmit: onSubmit,
                        onSkip: onClose
                    )
                }
            }
            // 新问题新身份：entryId 变化即重置内容 @State（旧向导进度不串题）
            .id(entryId)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: - 头部（标题 + 模式副标题 + 关闭钮；与确认段头部同规格）

    private var headerBar: some View {
        HStack(spacing: DS.Spacing.s8) {
            DSIcon(.question, size: 16)
                .foregroundStyle(Color.brandAccent)
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Text("澄清作答")
                    .font(DS.Font.headingSM)
                    .foregroundStyle(Color.ink900)
                Text(subtitle)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
            }
            Spacer(minLength: 0)
            if let stageLabel, !stageLabel.isEmpty {
                Text("追问 · \(stageLabel)")
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
            }
            DSDialogCloseButton(action: onClose)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    private var subtitle: String {
        if let wizard {
            return "\(wizard.questions.count) 个问题 · 逐题作答，可跳过"
        }
        return "点选即发送 · 自由输入 · 可跳过"
    }
}

// MARK: - 单题作答（末条 AI 回复末尾选项行）

/// 单题模式：题干取自选项行前的收尾段（通常即问句本身，完整分析仍留在消息流气泡里），
/// 点选项即发送（原流内 chips 同交互），自定义输入回车 / 点发送提交，跳过 = 关闭作答段不发送。
struct ClarifySingleForm: View {
    let options: ArtifactParser.ClarifyOptions
    /// 本会话 busy（阶段 3 口径）：本会话流式/占位中禁动作，他会话的流不影响。
    let sessionBusy: Bool
    let onSubmit: (String) -> Void
    let onSkip: () -> Void

    @State private var customDraft = ""
    @FocusState private var customFocused: Bool
    @State private var hoveredKey: String?

    var body: some View {
        VStack(spacing: 0) {
            // 自然高度布局（停靠坞内不设滚动，防与消息流 ScrollView 抢弹性空间）
            VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                Text(stemLine)
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: DS.Spacing.s6) {
                    ForEach(options.options.indices, id: \.self) { index in
                        optionRow(index)
                    }
                    customRow
                }
                .padding(.top, DS.Spacing.s2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.s12)
            .background(Color.surfaceSecondary)

            footer
        }
    }

    /// 题干收尾段：选项行前的最后一行非空文字（澄清问句惯例收尾在最后一句）。
    /// 尾部若收着代码块（``` 围栏成对），整块跳过再取收尾句——模型常在选项行前
    /// 收尾一个代码块，最后一行是闭合围栏，题干不能显示成「```」或代码内容。
    private var stemLine: String {
        let lines = options.question
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var end = lines.count
        if let last = lines.last, last.hasPrefix("```") {
            var depth = 1
            var index = end - 2
            while index >= 0, depth > 0 {
                if lines[index].hasPrefix("```") { depth -= 1 }
                index -= 1
            }
            end = index + 1  // 开启围栏之前的正文收尾段
        }
        return lines[..<end].reversed().first ?? options.question
    }

    /// 选项行动作卡（视觉同 ConfirmDock optionCard / 问题卡选项行：
    /// radio 圆 + 选项文本 + 数字徽标；hover 品牌底示意「点选即发送」，非持久选中态）。
    private func optionRow(_ index: Int) -> some View {
        let key = "opt-\(index)"
        let hovered = hoveredKey == key
        return Button {
            onSubmit(options.options[index])
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                radioCircle(hovered)
                Text(options.options[index])
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Spacing.s8)
                numberBadge(index + 1, hovered: hovered)
            }
            .padding(.horizontal, DS.Spacing.s10)
            .padding(.vertical, DS.Spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(hovered ? Color.brand50 : Color.surfaceBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(hovered ? Color.brand600 : Color.borderL1, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(sessionBusy)  // 本会话 busy（阶段 3 口径）
        .onHover { hovering in
            withAnimation(DS.Motion.springFast) {
                hoveredKey = hovering ? key : nil
            }
        }
    }

    /// 16×16 radio 圆：hover 品牌描边（点选即发送无持久选中态，视觉同问题卡单选圆）。
    private func radioCircle(_ hovered: Bool) -> some View {
        Circle()
            .fill(Color.surfaceBase)
            .frame(width: 16, height: 16)
            .overlay(
                Circle().strokeBorder(
                    hovered ? Color.brand600 : Color.borderL3,
                    lineWidth: 1
                )
            )
            .animation(DS.Motion.springFast, value: hovered)
    }

    /// 数字徽章：右侧圆角小方块（视觉同 ConfirmDock；hover 品牌紫底白字）。
    private func numberBadge(_ index: Int, hovered: Bool) -> some View {
        Text("\(index)")
            .font(DS.Font.monoSM)
            .foregroundStyle(hovered ? Color.white : Color.ink500)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(hovered ? Color.brand600 : Color.surfaceTertiary)
            )
            .animation(DS.Motion.springFast, value: hovered)
    }

    /// 自由输入行：回车或点发送提交（空草稿禁发送）。
    private var customRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            TextField("或自由输入你的答案…", text: $customDraft)
                .textFieldStyle(.plain)
                .font(DS.Font.bodySM)
                .focused($customFocused)
                .dsInput(focused: customFocused, minHeight: 30)
                .onSubmit(sendCustom)
            Button(action: sendCustom) {
                Text("发送")
            }
            .buttonStyle(.ds(.brand, size: .sm))
            .disabled(sessionBusy || customDraft.trimmingCharacters(in: .whitespaces).isEmpty)  // 本会话 busy（阶段 3）
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.s8) {
            Spacer()
            Button {
                onSkip()
            } label: {
                Text("跳过此题")
            }
            .buttonStyle(.ds(.ghost, size: .sm))
            .disabled(sessionBusy)  // 本会话 busy（阶段 3 口径）
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    private func sendCustom() {
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionBusy, !trimmed.isEmpty else { return }  // 本会话 busy（阶段 3 口径）
        onSubmit(trimmed)
    }
}
