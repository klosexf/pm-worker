//
//  ClarifyAnswerDrawer.swift
//  pm_worker
//
//  澄清作答抽屉：所有需要用户点选作答的澄清问题统一收口到右缘抽屉
//  （记忆抽屉同停靠位 .ds-drawer 形态，两者互斥打开）。两种模式：
//  · 多题：artifact:question-card 块 → ClarifyQuestionCard 向导整体搬入
//    （逐题 / 上一步 / 回顾 / 跳过，作答进度在抽屉内维护）；
//  · 单题：末条 AI 回复末尾连续「A) xxx」选项行 → ClarifySingleForm
//    （点选即发送 + 自由输入 + 跳过此题）。
//
//  开合契约（宿主 ConversationView 驱动）：
//  · 待答问题出现自动滑出一次；显式关闭后同一问题不再自动滑出（输入区上方触发 chip 兜底）；
//  · 提交 = 拼装消息走 sendMessage 通道，答案随用户消息留痕，pending 清空后抽屉收起；
//  · 消息流不再渲染可点选 chips——末条消息的原始选项行同步折叠（防点不了的假选项）。
//

import SwiftUI

struct ClarifyAnswerDrawer: View {
    /// 多题问题卡（优先）；单题选项行（兜底）——同一条回复理论上只出其一。
    let wizard: ArtifactParser.QuestionCardRequest?
    let options: ArtifactParser.ClarifyOptions?
    /// 承载待答问题的 assistant entry id（作为内容身份：新问题重置向导作答进度）。
    let entryId: String
    let isStreaming: Bool
    /// 显式关闭（X / 跳过此题）：宿主记下当前问题 id，同问题不再自动滑出。
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
                        isStreaming: isStreaming
                    ) { assembled in
                        onSubmit(assembled)
                    }
                } else if let options {
                    ClarifySingleForm(
                        options: options,
                        isStreaming: isStreaming,
                        onSubmit: onSubmit,
                        onSkip: onClose
                    )
                }
            }
            // 新问题新身份：entryId 变化即重置内容 @State（旧向导进度不串题）
            .id(entryId)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // 原型 .ds-drawer：bg-base · neutral 边 · r12 · 双层大软影（记忆抽屉同款）
        .frame(maxWidth: 420, maxHeight: .infinity)
        .background(Color.surfaceBase, in: RoundedRectangle(cornerRadius: DS.Radius.xxl))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(Color.overlayBorder, lineWidth: 1)
        )
        .shadow(color: Color.shadowInk.opacity(0.14), radius: 32, y: 12)
        .shadow(color: Color.shadowInk.opacity(0.08), radius: 16, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
    }

    // MARK: - 头部（标题 + 模式副标题 + 关闭钮）

    private var headerBar: some View {
        HStack(spacing: DS.Spacing.s8) {
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                Label { Text("澄清作答") } icon: { DSIcon(.question, size: 16) }
                    .font(DS.Font.headingSM)
                    .foregroundStyle(Color.ink900)
                Text(subtitle)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
            }
            Spacer(minLength: 0)
            DSDialogCloseButton(action: onClose)
        }
        .padding(.horizontal, DS.Spacing.s20)
        .padding(.vertical, DS.Spacing.s16)
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
/// 点选项即发送（原流内 chips 同交互），自定义输入回车 / 点发送提交，跳过 = 关闭抽屉不发送。
struct ClarifySingleForm: View {
    let options: ArtifactParser.ClarifyOptions
    let isStreaming: Bool
    let onSubmit: (String) -> Void
    let onSkip: () -> Void

    @State private var customDraft = ""
    @FocusState private var customFocused: Bool
    @State private var hoveredKey: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
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
            }
            .background(Color.surfaceSecondary)

            footer
        }
    }

    /// 题干收尾段：选项行前的最后一行非空文字（澄清问句惯例收尾在最后一句）。
    private var stemLine: String {
        options.question
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last.map(String.init) ?? options.question
    }

    /// 选项行动作卡（hover 高亮 + 右缘箭头示意「点选即发送」，非持久选中态）。
    private func optionRow(_ index: Int) -> some View {
        let key = "opt-\(index)"
        let hovered = hoveredKey == key
        return Button {
            onSubmit(options.options[index])
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                Text(options.options[index])
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Spacing.s8)
                DSIcon(.arrowRight, size: 12)
                    .foregroundStyle(hovered ? Color.brandAccent : Color.ink300)
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
        .disabled(isStreaming)
        .onHover { hovering in
            withAnimation(DS.Motion.springFast) {
                hoveredKey = hovering ? key : nil
            }
        }
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
            .disabled(isStreaming || customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
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
            .disabled(isStreaming)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    private func sendCustom() {
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
