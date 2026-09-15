//
//  NewTaskView.swift
//  pm_worker
//
//  新建任务页（首页，Task 1.2，design.md §5.1.1 v0.9.4 · 对齐原型 v4 Home）：
//  品牌时刻（PM with Copilot）+ 640 宽大输入卡（卡内工具行：本地 chip /
//  关联项目 chip / 澄清模型标签 / ⏎ 发送 + 圆形发送按钮）。
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
    /// 关联版本（本次对话的迭代基底）：nil = 未选择，落「默认无版本号」。
    /// 强依赖关联项目——项目变更即重置（版本跟随项目存在）。
    @State private var selectedVersion: String?
    /// 明确「不选择版本」（chip 灰态，区别于未选择的默认态）
    @State private var explicitNoVersion = false
    /// 版本下拉（DSMenu 弹层）与菜单内联「新建版本」表单态
    @State private var showVersionMenu = false
    @State private var versionCreateMode = false
    @State private var newVersionName = ""
    @FocusState private var versionNameFocused: Bool
    /// 输入卡实测宽度（原型 640，窄窗口时随中栏收缩）——驱动编辑器行高估算
    @State private var cardWidth: CGFloat = 640
    @FocusState private var inputFocused: Bool
    /// IME 组字中（拼音未上屏）：回车确认组字不触发发送（与对话页同策略）
    @State private var imeComposing = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
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
            }

            Spacer(minLength: DS.Spacing.s64)
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(Color.surfaceBase)
        // 点击输入卡以外的页面空白 → 输入框失焦、光标消失（onTapGesture 只命中
        // 无位移单击，按钮与 TextEditor 自行消费点击不受影响）。
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = false }
        .onAppear { inputFocused = true }
        .onChange(of: associatedProject) { _, _ in
            // 版本强依赖关联项目：项目变更即重置版本选择与内联表单
            selectedVersion = nil
            explicitNoVersion = false
            versionCreateMode = false
        }
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
                    .background(IMEComposingDetector(isComposing: $imeComposing))
                    .onKeyPress { press in
                        // ⏎ 直接发送（⇧⏎ 换行，IME 组字中回车仅确认组字）；
                        // 不可发送时回车保持系统换行行为——与对话页输入框同策略
                        guard press.key == .return,
                              press.phase == .down,
                              !press.modifiers.contains(.shift),
                              !imeComposing,
                              canSend,
                              !model.sessionStore.isStreaming
                        else { return .ignored }
                        sendMessage()
                        return .handled
                    }

                // 占位在聚焦（光标出现）时即消失，与对话页输入框交互一致
                if draft.isEmpty && !inputFocused {
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

    /// 完整行含 ⏎ 快捷键提示；窄卡自动切紧凑行（showShortcutHint=false，
    /// 思考强度同步收成只留图标）。
    private func toolRow(showShortcutHint: Bool) -> some View {
        HStack(spacing: DS.Spacing.s12) {
            localChip
            projectChip
            versionChip

            Spacer(minLength: DS.Spacing.s8)

            // 思考强度（与对话页 Composer 同一全局偏好，随首条消息生效）
            ComposerEffortButton(store: model.sessionStore, showsLabel: showShortcutHint)

            // 对话模型切换器（多模型管理）：当前模型 → 弹层实时切换（与对话页共用）
            ComposerModelButton(model: model)

            if showShortcutHint {
                sendShortcutHint
            }

            sendButton
                .layoutPriority(1)
        }
    }

    /// ⏎ 发送快捷键提示（ds-kbd 质感）。
    private var sendShortcutHint: some View {
        HStack(spacing: DS.Spacing.s4) {
            Text("⏎")
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

    // MARK: - 关联版本 chip + 下拉（方案 A：与「关联项目」chip/菜单同构）

    /// chip 文案：选中 → 版本名；明确不选择 → 灰态文案；默认 → 「版本」。
    private var versionChipLabel: String {
        if let selectedVersion { return selectedVersion }
        return explicitNoVersion ? "不关联版本" : "版本"
    }

    /// 关联项目下的可选版本（左栏树投影：排除 unversioned/knowledge 系统目录）。
    private var versionNodes: [VersionNode] {
        guard let project = associatedProject,
              let node = model.projects.first(where: { $0.name == project }) else { return [] }
        return node.versions.filter { $0.name != "unversioned" && $0.name != "knowledge" }
    }

    /// 新建版本建议名（与侧栏 suggestedVersionName 同规则：v〈最大号+1〉.0）。
    private var suggestedVersionName: String {
        let numbers = versionNodes.compactMap { node -> Int? in
            guard node.name.hasPrefix("v") else { return nil }
            return Int(node.name.dropFirst().split(separator: ".").first ?? "")
        }
        guard let maxNumber = numbers.max() else { return "v1.0" }
        return "v\(maxNumber + 1).0"
    }

    /// 关联版本 chip（点击展开 DSMenu：选择现有 / 新建 / 不选择）。
    /// 强依赖关联项目：未关联时菜单给门控引导而非版本列表。
    private var versionChip: some View {
        Button {
            versionCreateMode = false
            showVersionMenu.toggle()
        } label: {
            HStack(spacing: DS.Spacing.s4) {
                DSIcon(.layers, size: 11)
                    .foregroundStyle(selectedVersion != nil ? Color.brandAccent : Color.ink500)
                Text(versionChipLabel)
                    .font(DS.Font.bodySM)
                    .fontWeight(selectedVersion != nil ? .medium : .regular)
                    .foregroundStyle(
                        selectedVersion != nil
                            ? Color.ink900
                            : (explicitNoVersion ? Color.ink500 : Color.ink700)
                    )
                    .lineLimit(1)
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
        // 菜单走 popover（独立 NSWindow）：与关联项目 chip 同因——TextEditor
        // 宿主层会压住 overlay 内容，只有独立窗口能稳定置顶。
        .popover(isPresented: $showVersionMenu, arrowEdge: .bottom) {
            versionMenu
                .presentationBackground(.clear)
        }
        .help(
            selectedVersion != nil
                ? "当前版本基底：\(selectedVersion ?? "")（点击可更换）"
                : "关联版本：本次对话的迭代基底；需先关联项目，未选择时落「默认无版本号」"
        )
    }

    // MARK: - 关联版本下拉

    /// 版本菜单：未关联项目 → 依赖门控引导；已关联 → 列表态 / 内联新建表单。
    @ViewBuilder
    private var versionMenu: some View {
        DSMenu(minWidth: 288) {
            if associatedProject == nil {
                versionGateSection
            } else if versionCreateMode {
                versionCreateForm
            } else {
                versionListSection
            }
        }
    }

    /// 依赖门控引导：版本跟随关联项目，未关联时不可选（去关联入口兜底）。
    @ViewBuilder
    private var versionGateSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            HStack(spacing: DS.Spacing.s8) {
                DSIcon(.warningFill, size: 13)
                    .foregroundStyle(Color.statusAlert)
                Text("需先关联项目，才能选择版本")
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink700)
                Spacer(minLength: 0)
            }
            Text("版本跟随关联项目存在；关联后可选择现有版本或新建版本。")
                .font(DS.Font.bodyXS)
                .dsCaptionType(size: 12)
                .foregroundStyle(Color.ink500)
        }
        .padding(.horizontal, DS.Spacing.s8)
        .padding(.vertical, DS.Spacing.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        DSMenuDivider()
        DSMenuItem(
            title: "去关联项目（选择文件夹）", icon: .folder,
            titleFont: DS.Font.bodySM, action: pickNewFolder
        )
    }

    /// 列表态：现有版本（radio，已封板禁选）+ 新建 + 不选择 + 脚注。
    @ViewBuilder
    private var versionListSection: some View {
        let versions = versionNodes
        Text(versions.isEmpty ? "版本" : "现有版本")
            .font(DS.Font.bodyXS)
            .foregroundStyle(Color.ink500)
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.top, DS.Spacing.s2)
        if versions.isEmpty {
            Text("「\(associatedProject ?? "")」下暂无版本，可新建一个作为对话基底")
                .font(DS.Font.bodyXS)
                .dsCaptionType(size: 12)
                .foregroundStyle(Color.ink500)
                .padding(.horizontal, DS.Spacing.s8)
                .padding(.vertical, DS.Spacing.s4)
        }
        ForEach(versions) { node in
            VersionMenuRow(
                node: node,
                isSelected: selectedVersion == node.name
            ) {
                selectVersion(node)
            }
        }
        DSMenuDivider()
        DSMenuItem(
            title: "新建版本…", icon: .plus,
            description: "命名并创建，本次对话的产物将落入新版本",
            titleFont: DS.Font.bodySM
        ) {
            newVersionName = suggestedVersionName
            versionCreateMode = true
            DispatchQueue.main.async { versionNameFocused = true }
        }
        DSMenuItem(
            title: "不选择版本", icon: .circleMinus,
            description: "本次对话不关联版本，产物落「默认无版本号」",
            titleFont: DS.Font.bodySM
        ) {
            selectedVersion = nil
            explicitNoVersion = true
            showVersionMenu = false
        }
        DSMenuDivider()
        Text("选择版本前需先关联项目；未选择时落「默认无版本号」。")
            .font(DS.Font.bodyXS)
            .foregroundStyle(Color.ink500)
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.bottom, DS.Spacing.s2)
    }

    /// 菜单内联「新建版本」表单（复用 AppModel.createVersion，错误走通知条）。
    private var versionCreateForm: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            HStack(spacing: DS.Spacing.s8) {
                Text(suggestedVersionName)
                    .font(DS.Font.mono2XS)
                    .foregroundStyle(Color.brandAccent)
                    .padding(.horizontal, DS.Spacing.s6)
                    .padding(.vertical, DS.Spacing.s4)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .fill(Color.brand50)
                    )
                Text("新建版本")
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.ink900)
                Spacer(minLength: 0)
            }
            TextField("版本名称，如：\(suggestedVersionName)", text: $newVersionName)
                .textFieldStyle(.plain)
                .font(DS.Font.bodyBase)
                .foregroundStyle(Color.ink900)
                .dsInput(focused: versionNameFocused)
                .focused($versionNameFocused)
                .onSubmit { createVersionAndSelect() }
                .accessibilityLabel("版本名称")
            Text("将创建并关联为本次对话的迭代基底。")
                .font(DS.Font.bodyXS)
                .dsCaptionType(size: 12)
                .foregroundStyle(Color.ink500)
            HStack(spacing: DS.Spacing.s8) {
                Spacer(minLength: 0)
                Button("取消") { versionCreateMode = false }
                    .buttonStyle(.ds(.ghost, size: .sm))
                    .keyboardShortcut(.cancelAction)
                Button("创建并关联") { createVersionAndSelect() }
                    .buttonStyle(.ds(.primary, size: .sm))
                    .disabled(newVersionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.s4)
    }

    /// 选择现有版本（已封板版本在行级禁用，这里再兜底一次）。
    private func selectVersion(_ node: VersionNode) {
        guard !node.isReleased else { return }
        selectedVersion = node.name
        explicitNoVersion = false
        showVersionMenu = false
    }

    /// 新建版本并关联为本次对话基底；失败经通知条透传人话报错。
    private func createVersionAndSelect() {
        let name = newVersionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let project = associatedProject else { return }
        if let error = model.createVersion(in: project, name: name) {
            model.notif = DSNotifMessage(variant: .error, title: "新建版本失败", description: error)
            return
        }
        selectedVersion = name
        explicitNoVersion = false
        versionCreateMode = false
        showVersionMenu = false
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            await model.startTask(
                message: text,
                associatedProject: associatedProject,
                version: selectedVersion
            )
        }
    }
}

/// 版本菜单行（DSMenuItem radio 变体）：check/layers 图标位 + 名称/摘要两行 +
/// 右缘封板标记；选中态 brandPopup 底 + 中量字重，已封板只读禁选。
private struct VersionMenuRow: View {
    let node: VersionNode
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.s8) {
                Group {
                    if isSelected {
                        DSIcon(.check, size: 14)
                            .foregroundStyle(Color.brand600)
                    } else {
                        DSIcon(.layers, size: 14)
                            .foregroundStyle(Color.ink500)
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(node.displayName)
                        .font(DS.Font.bodyBase)
                        .fontWeight(isSelected ? .medium : .regular)
                        .foregroundStyle(Color.ink900)
                        .lineLimit(1)
                    Text(node.sessions.isEmpty ? "暂无对话" : "\(node.sessions.count) 次对话")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Spacing.s8)
                if node.isReleased {
                    Text("已封板")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                }
            }
            .padding(.horizontal, DS.Spacing.s8)
            .padding(.vertical, DS.Spacing.s6)
            .frame(minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(isSelected ? Color.brandPopup : (hovered ? Color.overlayL2 : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .opacity(node.isReleased ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(node.isReleased)
        .onHover { hovered = $0 }
        .animation(DS.Motion.springFast, value: hovered)
        .help(
            node.isReleased
                ? "已封板版本为只读快照，不可作为对话基底"
                : "以 \(node.displayName) 为基底开始本次对话"
        )
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
