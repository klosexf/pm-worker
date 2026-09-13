//
//  NewTaskView.swift
//  pm_worker
//
//  新建任务页（首页，Task 1.2，design.md §5.1.1 v0.9.4 · 对齐原型 v4 Home）：
//  品牌时刻（PM with Copilot）+ 640 宽大输入卡（卡内工具行：本地 chip /
//  关联项目 chip / 澄清模型标签 / ⌘⏎ 发送 + 圆形发送按钮）。
//  工具行只放已实装能力——附件/自动流水线/通知未实装，不占位。
//

import SwiftUI
import AppKit

struct NewTaskView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: String = ""
    @State private var associatedProject: String?
    /// 关联项目下拉（DSMenu 弹层）是否展开
    @State private var showProjectMenu = false
    /// 输入卡实测宽度（原型 640，窄窗口时随中栏收缩）——驱动编辑器行高估算
    @State private var cardWidth: CGFloat = 640
    @FocusState private var inputFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 统一 AI 配置入口的当前模型，原型「对话模型」标签。
    private var chatModelLabel: String {
        let name = model.settings.chatConfig.model
        return name.isEmpty ? "未配置" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DS.Spacing.s64)

            VStack(spacing: DS.Spacing.s48) {
                // 品牌时刻（原型 Home：ai_stars + 「PM with Copilot」，Copilot 品牌紫）
                // 零间距嵌套 HStack 替代弃用的 Text `+` 拼接（macOS 26+）
                // 高级感升级：编辑级衬线展示字（New York）+ 紧字距——首页杂志时刻
                HStack(spacing: DS.Spacing.s10) {
                    DSIcon(.aiStars, size: 30)
                        .foregroundStyle(Color.brandAccent)
                    HStack(spacing: 0) {
                        Text("PM with ")
                            .foregroundStyle(Color.ink900)
                            .dsTight()
                        Text("Copilot")
                            .foregroundStyle(Color.brandAccent)
                            .dsTight()
                    }
                }
                .font(DS.Font.displayLG)
                .dsFadeIn()

                // 大输入卡（原型：640 宽 · 白底 r12 · 聚焦黑边 · 大软阴影）
                inputCard
                    .dsFadeIn()

                if model.sessionStore.isStreaming {
                    HStack(spacing: DS.Spacing.s8) {
                        DSSpinner()
                        Text("正在创建会话…")
                            .font(DS.Font.bodySM)
                            .foregroundStyle(Color.ink500)
                    }
                }
            }

            Spacer(minLength: DS.Spacing.s64)
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(Color.surfaceBase)
        .onAppear { inputFocused = true }
    }

    // MARK: - 输入卡（textarea 2 行 + 卡内工具行）

    /// 输入区高度：原型 rows=2 起步；TextEditor 默认 intrinsic 高度约 100px
    /// 会撑大输入卡（minHeight 压不住），必须按行数钉死——行高 24
    ///（bodyBase 15pt）+ 内建垂直 inset，两行起、八行封顶（更多内部滚动）。
    /// 每行字数按实测卡宽估算（卡收缩时行数估算不失真），中文按 15pt 全宽计。
    private var editorHeight: CGFloat {
        let charsPerLine = max(10, Int((cardWidth - 42) / 15))
        let lineCount = draft
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { max(1, Int(ceil(Double($0.count) / Double(charsPerLine)))) }
            .reduce(0, +)
        return CGFloat(min(max(lineCount, 2), 8)) * 24 + 12
    }

    private var inputCard: some View {
        VStack(spacing: 0) {
            // 输入区：TextEditor 隐藏系统底色；placeholder 与内建 inset 对齐防溢出
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink900)
                    .scrollContentBackground(.hidden)
                    .frame(height: editorHeight, alignment: .topLeading)
                    .padding(.horizontal, DS.Spacing.s16)
                    .padding(.top, DS.Spacing.s16)
                    .padding(.bottom, DS.Spacing.s8)
                    .focused($inputFocused)
                    .onKeyPress { press in
                        // ⌘⏎ 发送（原型 ⏎ 提示的 macOS 等价；普通回车换行）
                        guard press.key == .return,
                              press.modifiers.contains(.command),
                              press.phase == .down,
                              canSend
                        else { return .ignored }
                        sendMessage()
                        return .handled
                    }

                if draft.isEmpty {
                    Text(
                        "说说你的产品想法——帮你澄清需求、调研竞品、撰写 PRD、生成可点击原型，交付带门禁质量分的完整方案。"
                    )
                    .font(DS.Font.bodyBase)
                    .foregroundStyle(Color.ink300)
                    // TextEditor 内建 inset 约 (5, 8)，加上卡内 16/16 对齐
                    .padding(.leading, DS.Spacing.s16 + 5)
                    .padding(.top, DS.Spacing.s16 + 8)
                    .padding(.trailing, DS.Spacing.s16)
                    .allowsHitTesting(false)
                }
            }

            // 工具行（原型 Home 卡内 toolbar：chips 左 · 发送右）
            // 响应式重排：卡宽不足时 ViewThatFits 自动落到紧凑行（去快捷键提示），
            // 保证模型标签与发送按钮在任何宽度下完整可见可点。
            ViewThatFits(in: .horizontal) {
                toolRow(showShortcutHint: true)
                toolRow(showShortcutHint: false)
            }
            .padding(.horizontal, DS.Spacing.s16)
            .padding(.top, DS.Spacing.s10)
            .padding(.bottom, DS.Spacing.s16)
        }
        // 响应式宽度：原型 640 为上限，窄窗口（中栏被侧栏/右栏压缩）时随父容器
        // 收缩，永不满溢——实测宽度回填 cardWidth 供行高估算。
        .frame(maxWidth: 640)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            cardWidth = width
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .fill(Color.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xxl)
                .strokeBorder(
                    inputFocused ? Color.contrastBorder : Color.borderL2,
                    lineWidth: 1
                )
        )
        .shadow(color: Color.shadowInk.opacity(0.08), radius: 32, y: 12)
        // Xcode 语义焦点环：accent 环绕取代描边式焦点（P0-①）
        .dsFocusRing(focused: inputFocused, radius: DS.Radius.xxl)
        // 卡外安全边距：任何窗口宽度下卡片与中栏两缘至少留 24，不贴边不裁切
        .padding(.horizontal, DS.Spacing.s24)
    }

    // MARK: - 工具行（ViewThatFits 两个档位共用）

    /// 完整行含 ⌘⏎ 快捷键提示；窄卡自动切紧凑行（showShortcutHint=false）。
    private func toolRow(showShortcutHint: Bool) -> some View {
        HStack(spacing: DS.Spacing.s12) {
            localChip
            projectChip

            Spacer(minLength: DS.Spacing.s8)

            modelChip

            if showShortcutHint {
                sendShortcutHint
            }

            sendButton
                .layoutPriority(1)
        }
    }

    /// 对话模型标签（=①需求澄清槽位；点击开设置弹框「模型」页）。
    private var modelChip: some View {
        Button {
            model.settingsPage = .model
            model.settingsPresented = true
        } label: {
            HStack(spacing: DS.Spacing.s3) {
                Text(chatModelLabel)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
                DSIcon(.down, size: 8)
                    .foregroundStyle(Color.ink300)
            }
            .padding(.horizontal, DS.Spacing.s6)
            .padding(.vertical, DS.Spacing.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("对话模型 · 即「①需求澄清」槽位，可在设置弹框中调整模型")
    }

    /// ⏎ 发送快捷键提示（ds-kbd 质感）。
    private var sendShortcutHint: some View {
        HStack(spacing: DS.Spacing.s4) {
            Text("⌘⏎")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .padding(.horizontal, DS.Spacing.s4)
                .padding(.vertical, DS.Spacing.s2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .fill(Color.overlayL1)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.xs)
                                .strokeBorder(Color.borderL1, lineWidth: 1)
                        )
                )
            Text("发送")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink300)
        }
    }

    /// 圆形发送按钮（原型：28×28 品牌紫 + 纸飞机）。
    private var sendButton: some View {
        Button {
            sendMessage()
        } label: {
            DSIcon(.send, size: 12)
                .foregroundStyle(canSend ? Color.white : Color.ink300)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        canSend
                            ? Color.brand600
                            : Color.surfaceTertiary
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend || model.sessionStore.isStreaming)
        .help("发送，开始任务")
    }

    // MARK: - chips（展开行：环境 + 项目）

    /// 运行环境 chip（本地优先是产品特性）。
    private var localChip: some View {
        HStack(spacing: DS.Spacing.s4) {
            DSIcon(.browser, size: 11)
                .foregroundStyle(Color.ink500)
            Text("本地")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink700)
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

    /// 关联项目 chip（点击展开 DSMenu 下拉：最近文件夹 / 选择文件夹 / 不关联）。
    private var projectChip: some View {
        Button {
            showProjectMenu.toggle()
        } label: {
            HStack(spacing: DS.Spacing.s4) {
                DSIcon(.folder, size: 11)
                    .foregroundStyle(Color.ink500)
                Text(associatedProject ?? "关联项目")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                    .lineLimit(1)
                    // 长项目名截断，防止把工具行挤出卡片
                    .frame(maxWidth: 140, alignment: .leading)
                DSIcon(.down, size: 8)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        // 菜单走 popover（独立 NSWindow）：TextEditor 是 AppKit 宿主视图，其
        // 宿主层连同占位文字永远压在同层 SwiftUI 内容（overlay 菜单）之上，
        // 只有独立窗口能稳定置顶；点外部自动收起，空间不足系统自动翻转。
        .popover(isPresented: $showProjectMenu, arrowEdge: .bottom) {
            projectMenu
                .presentationBackground(.clear)  // 去系统底，露出 DSMenu 玻璃卡
        }
        .help("关联项目：决定产物落盘位置与右栏面板预览；不关联则落「默认」")
    }

    // MARK: - 关联项目下拉（最近文件夹 + 选择文件夹）

    /// 下拉菜单（原型「最近」式）：历史记录（名称 + 路径 + 相对时间）在前，
    /// 分隔线后是「选择文件夹」入口与「不关联」兜底；无历史时不渲染空段。
    private var projectMenu: some View {
        DSMenu(minWidth: 288) {
            let entries = RecentFolderStore.menuEntries(projects: model.projects.map(\.name))
            if !entries.isEmpty {
                Text("最近")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .padding(.horizontal, DS.Spacing.s8)
                    .padding(.top, DS.Spacing.s2)
                ForEach(entries.prefix(4)) { entry in
                    RecentFolderRow(entry: entry) {
                        associateFolder(entry)
                    }
                }
                DSMenuDivider()
            }
            DSMenuItem(
                title: "选择文件夹", icon: .folder,
                titleFont: DS.Font.bodySM, action: pickNewFolder
            )
            DSMenuItem(
                title: "不关联（落「默认」）", icon: .circleMinus,
                titleFont: DS.Font.bodySM
            ) {
                associatedProject = nil
                showProjectMenu = false
            }
        }
    }

    /// 关联一个文件夹：确保同名 pm 项目存在（外部文件夹首次关联 → 落项目目录，
    /// 产物落盘依赖 ~/PMAgent/Projects/<名称>/），再写入最近记录并回显到 chip。
    private func associateFolder(_ entry: RecentFolder) {
        if !model.projects.contains(where: { $0.name == entry.name }) {
            _ = try? PMAgentStore.createProject(named: entry.name)
            model.reloadTree()
        }
        RecentFolderStore.record(name: entry.name, path: entry.path)
        associatedProject = entry.name
        showProjectMenu = false
    }

    /// 系统选文件夹面板：选中后按「名称 = 文件夹名」走 associateFolder 统一入口。
    private func pickNewFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择文件夹"
        panel.message = "选择要关联的项目文件夹，产物将落到同名项目"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        associateFolder(
            RecentFolder(name: url.lastPathComponent, path: url.path)
        )
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            await model.startTask(message: text, associatedProject: associatedProject)
        }
    }
}

/// 最近文件夹菜单行（DSMenuItem 变体）：folder 图标 + 名称/路径两行 +
/// 右缘相对使用时间；hover overlayL2，DS 菜单条目规格（h≥44 · r8 · gap 8）。
private struct RecentFolderRow: View {
    let entry: RecentFolder
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(.folder, size: 14)
                    .foregroundStyle(Color.ink500)
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(entry.name)
                        .font(DS.Font.bodyBase)
                        .foregroundStyle(Color.ink900)
                        .lineLimit(1)
                    Text(entry.path)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Spacing.s8)
                if let time = RecentFolderStore.relativeTime(entry.lastUsedAt) {
                    Text(time)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.vertical, DS.Spacing.s6)
            .frame(minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(hovered ? Color.overlayL2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
    }
}
