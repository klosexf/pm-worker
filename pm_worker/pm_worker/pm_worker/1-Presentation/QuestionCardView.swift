//
//  QuestionCardView.swift
//  pm_worker
//
//  澄清问题卡（① 阶段）：LLM 输出 artifact:question-card 块 → 右缘作答抽屉
//  （ClarifyAnswerDrawer）承载。多题逐答：单选 radio / 多选 checkbox（题型由
//  schema multiple 字段或题干启发式判定，头部徽标标注）+ 自定义输入 + 跳过 →
//  上一步回改（答案保留）→ 回顾页可跳题修改 → 确认提交 → 拼装【问题卡作答】
//  用户消息走 sendMessage 通道。页脚按钮右对齐，顺序 = 跳过此题 | 上一步 | 下一道题。
//  本视图只产出抽屉内容（无卡片外壳，chrome / 标题由抽屉头部承载）。
//

import SwiftUI

// MARK: - 答案拼装（nonisolated 纯函数，单测直测）

nonisolated enum QuestionCardAssembly {
    /// 提交消息前缀（ConversationView 已提交判定同用此常量）。
    static let marker = "【问题卡作答】"

    /// titles / answers 按题序一一对应；answer == nil 视为跳过 → 「（跳过）」。
    static func assemble(titles: [String], answers: [String?]) -> String {
        let lines = zip(titles, answers).enumerated().map { index, pair in
            "\(index + 1). \(pair.0) → \(pair.1 ?? "（跳过）")"
        }
        return ([marker] + lines).joined(separator: "\n")
    }
}

// MARK: - 向导卡片

struct ClarifyQuestionCard: View {
    let request: ArtifactParser.QuestionCardRequest
    let isStreaming: Bool
    let onSubmit: (String) -> Void

    /// 单题作答状态（本地态，不落盘——提交后答案随对话流留痕）。
    /// 题型由题目 schema / 题干判定（isMultipleChoice）：单选 radio 圆，多选 checkbox。
    private enum Answer: Equatable {
        case option(Int)                                 // 单选：选项下标
        case custom(String)                              // 单选：自定义输入
        case multi(selected: Set<Int>, custom: String?)  // 多选：勾选下标集 + 自定义并存
        case skipped
    }

    @State private var answers: [Int: Answer] = [:]
    /// 当前步：0..<n 为题目页，n = 回顾确认页。
    @State private var step = 0
    /// 自定义输入草稿（按题记忆，切题 / 回改不丢）。
    @State private var customDrafts: [Int: String] = [:]
    /// 自定义输入框焦点（@FocusState：.focused 需要 FocusState.Binding）。
    @FocusState private var customFieldFocused: Bool
    @State private var hoveredRowKey: String?

    private var questions: [ArtifactParser.QuestionCardRequest.Question] { request.questions }
    private var questionCount: Int { questions.count }
    private var isReview: Bool { step >= questionCount }

    var body: some View {
        VStack(spacing: 0) {
            headerArea
            DSDivider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                    if isReview {
                        reviewPage
                    } else {
                        questionPage(step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.s12)
            }
            .background(Color.surfaceSecondary)

            footerRow
        }
    }

    // MARK: 头部（步数 + 进度 hairline；卡片身份由抽屉头部承载）

    private var headerArea: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s6) {
                Text(isReview ? "确认答案" : "第 \(step + 1)/\(questionCount) 题")
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
                Spacer(minLength: DS.Spacing.s12)
                // 题型徽标：单选灰 / 多选品牌紫，作答前一眼可辨
                if !isReview {
                    DSTag(
                        title: questions[step].isMultipleChoice ? "多选" : "单选",
                        variant: questions[step].isMultipleChoice ? .brand : .neutral
                    )
                }
            }
            progressBar
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    private var progressFraction: CGFloat {
        isReview ? 1 : CGFloat(step) / CGFloat(max(questionCount, 1))
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.borderL1)
                Capsule().fill(Color.brand600)
                    .frame(width: proxy.size.width * progressFraction)
            }
        }
        .frame(height: 2)
        .animation(DS.Motion.spring, value: progressFraction)
    }

    // MARK: 题目页

    @ViewBuilder
    private func questionPage(_ index: Int) -> some View {
        let q = questions[index]
        Text(q.title)
            .font(DS.Font.bodyMDStrong)
            .foregroundStyle(Color.ink900)
        if let detail = q.detail, !detail.isEmpty {
            Text(detail)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(spacing: DS.Spacing.s6) {
            let options = q.options ?? []
            ForEach(options.indices, id: \.self) { optIndex in
                optionRow(index, optIndex: optIndex, text: options[optIndex])
            }
            if q.allowCustom ?? true {
                customRow(index)
                // 自定义展开：多选 = 勾选即展开（文本可待输入）；单选 = 选中即展开
                let customExpanded = q.isMultipleChoice
                    ? isMultiCustomChecked(index) : isCustomSelected(index)
                if customExpanded {
                    TextField(
                        "输入你的答案…",
                        text: q.isMultipleChoice ? multiCustomBinding(index) : customBinding(index)
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodySM)
                    .focused($customFieldFocused)
                    .dsInput(focused: customFieldFocused, minHeight: 30)
                    .onSubmit { goNext() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.top, DS.Spacing.s2)
    }

    /// 选项行（单选 radio 圆 / 多选 checkbox 方框 + 行卡片；视觉同 ConfirmDock optionCard）。
    private func optionRow(_ qIndex: Int, optIndex: Int, text: String) -> some View {
        let multi = questions[qIndex].isMultipleChoice
        let selected = multi
            ? multiSelection(qIndex).contains(optIndex)
            : selectedOption(qIndex) == optIndex
        let key = "\(qIndex)-\(optIndex)"
        let hovered = hoveredRowKey == key
        return Button {
            withAnimation(DS.Motion.springFast) {
                if multi {
                    toggleMultiOption(qIndex, optIndex: optIndex)
                } else {
                    answers[qIndex] = .option(optIndex)
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                if multi {
                    checkBox(selected)
                } else {
                    radioCircle(selected)
                }
                Text(text)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Spacing.s8)
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
        .disabled(isStreaming)
        .onHover { hovering in
            withAnimation(DS.Motion.springFast) {
                hoveredRowKey = hovering ? key : nil
            }
        }
    }

    /// 自定义答案行（单选：选中即展开输入框；多选：checkbox 勾选计入提交，回车 = 下一步）。
    private func customRow(_ qIndex: Int) -> some View {
        let multi = questions[qIndex].isMultipleChoice
        let selected = multi ? isMultiCustomChecked(qIndex) : isCustomSelected(qIndex)
        let key = "\(qIndex)-custom"
        let hovered = hoveredRowKey == key
        return Button {
            withAnimation(DS.Motion.springFast) {
                if multi {
                    if toggleMultiCustom(qIndex) { customFieldFocused = true }
                } else {
                    answers[qIndex] = .custom(customDrafts[qIndex] ?? "")
                    customFieldFocused = true
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.s10) {
                if multi {
                    checkBox(selected)
                } else {
                    radioCircle(selected)
                }
                Text("自定义答案…")
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                Spacer(minLength: DS.Spacing.s8)
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
        .disabled(isStreaming)
        .onHover { hovering in
            withAnimation(DS.Motion.springFast) {
                hoveredRowKey = hovering ? key : nil
            }
        }
    }

    /// 16×16 radio 圆：选中品牌紫填充 + 白芯（单选题）。
    private func radioCircle(_ selected: Bool) -> some View {
        ZStack {
            Circle().fill(selected ? Color.brand600 : Color.surfaceBase)
            if selected {
                Circle().fill(Color.white).frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 16)
        .overlay(
            Circle().strokeBorder(selected ? Color.brand600 : Color.borderL3, lineWidth: 1)
        )
        .animation(DS.Motion.springFast, value: selected)
    }

    /// 16×16 checkbox 圆角方框：选中品牌紫填充 + 白勾（多选题，视觉同 ConfirmDock 勾选框）。
    private func checkBox(_ selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(selected ? Color.brand600 : Color.surfaceBase)
            if selected {
                DSIcon(.check, size: 10)
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 16, height: 16)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(selected ? Color.brand600 : Color.borderL3, lineWidth: 1)
        )
        .animation(DS.Motion.springFast, value: selected)
    }

    // MARK: 回顾页

    private var reviewPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            Text("确认你的答案")
                .font(DS.Font.headingXS)
                .foregroundStyle(Color.ink900)
            Text("点击「修改」可返回任意一题；确认后答案将随消息发送给 AI")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)

            VStack(spacing: DS.Spacing.s6) {
                ForEach(questions.indices, id: \.self) { i in
                    reviewRow(i)
                }
            }

            Text("跳过的题目会记入「待澄清问题」，不阻塞流程")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
        }
    }

    private func reviewRow(_ i: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s8) {
            Text("Q\(i + 1)")
                .font(DS.Font.monoSM)
                .foregroundStyle(Color.ink500)
            Text(questions[i].title)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .lineLimit(1)
            answerView(i)
            Spacer(minLength: DS.Spacing.s8)
            Button {
                withAnimation(DS.Motion.spring) { step = i }
            } label: {
                Text("修改")
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.brandAccent)
            }
            .buttonStyle(.plain)
            .disabled(isStreaming)
        }
        .padding(.horizontal, DS.Spacing.s10)
        .padding(.vertical, DS.Spacing.s8)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg).fill(Color.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Color.borderL1)
        )
    }

    @ViewBuilder
    private func answerView(_ i: Int) -> some View {
        switch answers[i] {
        case .option(let v):
            let opts = questions[i].options ?? []
            Text(v < opts.count ? opts[v] : "")
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink900)
                .lineLimit(1)
        case .multi(let sel, let custom):
            Text(multiAnswerText(i, selected: sel, custom: custom))
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink900)
                .lineLimit(1)
        case .custom(let text):
            Text(text)
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink900)
                .lineLimit(1)
        case .skipped, .none:
            Text("跳过")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.statusWarning)
                .padding(.horizontal, DS.Spacing.s6)
                .padding(.vertical, DS.Spacing.s2)
                .background(Capsule().fill(Color.statusWarningSurface1))
        }
    }

    /// 多选答案展示/提交文本：勾选项按题序以「、」连接，自定义以「其他：」追加。
    private func multiAnswerText(_ qIndex: Int, selected: Set<Int>, custom: String?) -> String {
        let opts = questions[qIndex].options ?? []
        var parts = selected.sorted().compactMap { $0 < opts.count ? opts[$0] : nil }
        if let c = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            parts.append("其他：\(c)")
        }
        return parts.joined(separator: "、")
    }

    // MARK: - 页脚（右对齐：跳过此题 | 上一步 | 下一道题，末题 = 完成作答；回顾页：上一步 | 确认提交）

    private var footerRow: some View {
        HStack(spacing: DS.Spacing.s8) {
            Spacer()
            if isReview {
                Button {
                    goPrev()
                } label: {
                    Text("上一步")
                }
                .buttonStyle(.ds(.secondary, size: .sm))
                .disabled(isStreaming)

                Button {
                    submit()
                } label: {
                    Label {
                        Text("确认提交")
                    } icon: {
                        DSIcon(.check, size: 12)
                    }
                }
                .buttonStyle(.ds(.brand, size: .sm))
                .disabled(isStreaming)
            } else {
                Button {
                    skipCurrent()
                } label: {
                    Text("跳过此题")
                }
                .buttonStyle(.ds(.ghost, size: .sm))
                .disabled(isStreaming || answers[step] == .skipped)

                Button {
                    goPrev()
                } label: {
                    Text("上一步")
                }
                .buttonStyle(.ds(.secondary, size: .sm))
                .disabled(isStreaming || step == 0)

                Button {
                    goNext()
                } label: {
                    HStack(spacing: DS.Spacing.s6) {
                        Text(step == questionCount - 1 ? "完成作答" : "下一道题")
                        DSIcon(.arrowRight, size: 12)
                    }
                }
                .buttonStyle(.ds(.brand, size: .sm))
                .disabled(isStreaming || !canAdvance(step))
            }
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    // MARK: - 状态机

    private func selectedOption(_ qIndex: Int) -> Int? {
        if case .option(let v)? = answers[qIndex] { return v }
        return nil
    }

    private func isCustomSelected(_ qIndex: Int) -> Bool {
        if case .custom = answers[qIndex] { return true }
        return false
    }

    /// 多选：已勾选的选项下标集。
    private func multiSelection(_ qIndex: Int) -> Set<Int> {
        guard case .multi(let sel, _)? = answers[qIndex] else { return [] }
        return sel
    }

    /// 多选：自定义答案是否已勾选（勾选即计入提交，文本可待输入）。
    private func isMultiCustomChecked(_ qIndex: Int) -> Bool {
        guard case .multi(_, let custom)? = answers[qIndex] else { return false }
        return custom != nil
    }

    /// 多选：切换选项勾选态（保留自定义勾选与草稿）。
    private func toggleMultiOption(_ qIndex: Int, optIndex: Int) {
        var sel = multiSelection(qIndex)
        if sel.contains(optIndex) {
            sel.remove(optIndex)
        } else {
            sel.insert(optIndex)
        }
        answers[qIndex] = .multi(
            selected: sel,
            custom: isMultiCustomChecked(qIndex) ? (customDrafts[qIndex] ?? "") : nil
        )
    }

    /// 多选：切换自定义勾选态；返回勾选后的状态（宿主据此聚焦输入框）。
    @discardableResult
    private func toggleMultiCustom(_ qIndex: Int) -> Bool {
        let checked = !isMultiCustomChecked(qIndex)
        answers[qIndex] = .multi(
            selected: multiSelection(qIndex),
            custom: checked ? (customDrafts[qIndex] ?? "") : nil
        )
        return checked
    }

    /// 是否可推进：选项已选（多选 = 至少勾一项），或自定义答案非空。
    private func canAdvance(_ qIndex: Int) -> Bool {
        switch answers[qIndex] {
        case .option: return true
        case .multi(let sel, let custom):
            if !sel.isEmpty { return true }
            return !(custom ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .custom(let text): return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .skipped, .none: return false
        }
    }

    private func customBinding(_ qIndex: Int) -> Binding<String> {
        Binding(
            get: { customDrafts[qIndex] ?? "" },
            set: { text in
                customDrafts[qIndex] = text
                if case .custom = answers[qIndex] {
                    answers[qIndex] = .custom(text)
                }
            }
        )
    }

    /// 多选自定义输入绑定：草稿与勾选态答案同步（切题 / 回改不丢）。
    private func multiCustomBinding(_ qIndex: Int) -> Binding<String> {
        Binding(
            get: { customDrafts[qIndex] ?? "" },
            set: { text in
                customDrafts[qIndex] = text
                if case .multi(let sel, let custom)? = answers[qIndex], custom != nil {
                    answers[qIndex] = .multi(selected: sel, custom: text)
                }
            }
        )
    }

    private func goNext() {
        guard step < questionCount, canAdvance(step) else { return }
        customFieldFocused = false
        withAnimation(DS.Motion.spring) { step += 1 }
    }

    private func goPrev() {
        guard step > 0 else { return }
        customFieldFocused = false
        withAnimation(DS.Motion.spring) { step -= 1 }
    }

    private func skipCurrent() {
        customFieldFocused = false
        withAnimation(DS.Motion.springFast) {
            answers[step] = .skipped
            step = min(step + 1, questionCount)
        }
    }

    /// 收集全部答案 → 拼装【问题卡作答】消息 → 走 sendMessage 通道。
    private func submit() {
        let titles = questions.map(\.title)
        let answerTexts: [String?] = questions.indices.map { i in
            switch answers[i] {
            case .option(let v):
                let opts = questions[i].options ?? []
                return v < opts.count ? opts[v] : nil
            case .multi(let sel, let custom):
                let text = multiAnswerText(i, selected: sel, custom: custom)
                return text.isEmpty ? nil : text
            case .custom(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .skipped, .none:
                return nil
            }
        }
        onSubmit(QuestionCardAssembly.assemble(titles: titles, answers: answerTexts))
    }
}
