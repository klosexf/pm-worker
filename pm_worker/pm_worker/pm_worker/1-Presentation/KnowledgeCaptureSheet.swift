//
//  KnowledgeCaptureSheet.swift
//  pm_worker
//
//  「这条记下来」弹窗（Task 4.4，E10）：归属分流——
//  方法论卡片（全局卡片库，跨项目直接用不降级）/
//  经验记忆（记忆层「经验」，跨项目假设态注入）。
//  不暴露置信度控件：经验一律按假设态沉淀（初始置信度 0.7），
//  置信度由使用校准自动升降（MemoryStore.applyExperienceCalibration）。
//  视觉还原 Wave 3-B：.ds-dialog 质感（白底 r12 大软阴影 + overlay 背板）、
//  DSTabs 胶囊分流、DS 按钮。
//

import SwiftUI

/// 归属分流捕获结果（弹窗 → AppModel.saveBookmark）。
struct BookmarkCapture: Equatable {
    enum Destination: String, CaseIterable, Identifiable {
        /// 方法论卡片：可复用的「怎么做事」→ 全局 cards/
        case card
        /// 经验记忆：带项目出处的个人使用倾向 → 记忆层「经验」
        case experience

        var id: String { rawValue }

        var label: String {
            self == .card ? "方法论卡片" : "经验记忆"
        }

        var hint: String {
            switch self {
            case .card:
                return "可跨项目复用的「怎么做事」→ 全局卡片库（cards/），跨项目直接用不降级"
            case .experience:
                return "带项目出处的个人使用倾向 → 记忆层「经验」，假设态沉淀；使用方法论时注入校准，随使用结果自动升降置信度"
            }
        }
    }

    /// 捕获文本（弹窗内可编辑）
    var text: String
    /// 归属分流目标（默认判定可改）
    var destination: Destination

    /// 默认归属判定（确定性规则，弹窗中可改）：
    /// 出现个人化倾向词（踩坑 / 教训 / 下次…）→ 经验记忆；其余 → 方法论卡片。
    static func defaultDestination(for text: String) -> Destination {
        let markers = ["踩坑", "教训", "下次", "我发现", "我们曾", "个人倾向", "更喜欢", "习惯"]
        return markers.contains(where: text.contains) ? .experience : .card
    }
}

/// 「这条记下来」归属分流弹窗（E10：含归属分流、默认判定可改；置信度由使用校准）。
struct KnowledgeCaptureSheet: View {
    @Binding var isPresented: Bool

    /// 初始捕获文本（输入栏草稿或最近一条助手回复）
    var initialText: String

    /// 保存回调（AppModel 走归属分流落盘）
    var onSave: (BookmarkCapture) -> Void

    @State private var text: String
    @State private var destination: BookmarkCapture.Destination
    @FocusState private var textFocused: Bool

    init(
        isPresented: Binding<Bool>,
        initialText: String,
        onSave: @escaping (BookmarkCapture) -> Void
    ) {
        self._isPresented = isPresented
        self.initialText = initialText
        self.onSave = onSave
        self._text = State(initialValue: initialText)
        self._destination = State(
            initialValue: BookmarkCapture.defaultDestination(for: initialText)
        )
    }

    var body: some View {
        DSDialog(
            title: "这条记下来",
            icon: DSIcon.Name.bookmark,
            onClose: { isPresented = false },
            width: 460
        ) {
            dialogContent
        } footer: {
            HStack(spacing: DS.Spacing.s8) {
                Button("取消") {
                    isPresented = false
                }
                .buttonStyle(.ds(.ghost))
                .keyboardShortcut(.cancelAction)

                Button {
                    save()
                } label: {
                    Label { Text("记下来") } icon: { DSIcon(.bookmark, size: 14) }
                }
                .buttonStyle(.ds(.primary))
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dsDismissOnOutsideTap { isPresented = false }  // 点击面板外关闭（与关闭钮/取消钮同动作）
    }

    /// 对话框 body：捕获文本 + 归属分流。
    private var dialogContent: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s16) {
            // 捕获文本（.ds-textarea：白底聚焦黑边）
            TextEditor(text: $text)
                .font(DS.Font.bodyBase)
                .foregroundStyle(Color.ink900)
                .scrollContentBackground(.hidden)
                .dsTextarea(focused: textFocused, minHeight: 120)
                .focused($textFocused)

            // 归属分流（默认判定可改，E10；原型 .seg 胶囊分段）
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                DSTabs(
                    items: BookmarkCapture.Destination.allCases.map {
                        DSTabItem($0, $0.label)
                    },
                    selection: $destination
                )

                Text(destination.hint)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(
            BookmarkCapture(text: trimmed, destination: destination)
        )
        isPresented = false
    }
}

#Preview("默认判定：方法论") {
    KnowledgeCaptureSheet(
        isPresented: .constant(true),
        initialText: "KANO 需求分类：先分类（基本型/期望型/兴奋型）再排优先级，分类必须锚定目标用户画像"
    ) { _ in }
}

#Preview("默认判定：经验") {
    KnowledgeCaptureSheet(
        isPresented: .constant(true),
        initialText: "上次踩坑：把数据精度标成基本型，小白用户其实无所谓——分类前先过目标用户画像"
    ) { _ in }
}
