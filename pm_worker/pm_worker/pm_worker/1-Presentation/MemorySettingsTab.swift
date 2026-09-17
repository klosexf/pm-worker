//
//  MemorySettingsTab.swift
//  pm_worker
//
//  设置弹框「记忆」页（方案 A 台账式定稿落地）：
//  两级导航——入口列表（全局记忆卡 + 各项目记忆卡，两池完全分离）→
//  独立记忆页（内容 + meta 双行台账；⚑ 硬边界 / 假设两个行为标记，
//  类型为 AI 内部字段不展示；版本只是溯源标签）。
//  操作：添加（大弹框 · Markdown 编辑/预览 · 勾经验填出处 · 版本溯源可选）、
//  修订（supersede 协议旧值留痕）、失效（碑文留痕）、项目经验提升为全局、
//  整理记忆（LLM 出合并失效计划 → 白名单校验落碑文）。
//  数据面全部走 MemoryStore 静态池方法（append-only，不破坏文件事实源）。
//

import SwiftUI

struct MemorySettingsTab: View {
    @EnvironmentObject private var model: AppModel

    /// 二级导航：nil = 入口页。
    enum Pool: Equatable {
        case global
        case project(String)
    }
    @State private var pool: Pool?
    @State private var showInvalidated = false
    @State private var editing: MemoryEntry?
    @State private var adding = false
    @State private var scopeHelpPresented = false
    /// 条目行 hover（操作按钮浮现）。
    @State private var hoveredEntryId: String?
    /// 操作反馈（内联提示条）。
    @State private var feedback: String?

    var body: some View {
        VStack(spacing: 0) {
            if let pool {
                poolPage(pool)
            } else {
                entryPage
            }
        }
        .sheet(isPresented: $adding) {
            MemoryEntryEditor(pool: pool ?? .project(model.pipeline.project), entry: nil) {
                feedback = nil
            }
            .environmentObject(model)
        }
        .sheet(item: $editing) { entry in
            MemoryEntryEditor(pool: pool ?? .project(model.pipeline.project), entry: entry) {
                feedback = nil
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $scopeHelpPresented) {
            scopeHelpSheet
        }
    }

    // MARK: - 池数据（实时读盘，量小无需缓存）

    private func poolProject(_ pool: Pool) -> String? {
        switch pool {
        case .global: return nil
        case .project(let name): return name
        }
    }

    private func poolName(_ pool: Pool) -> String {
        switch pool {
        case .global: return "全局记忆"
        case .project(let name): return name
        }
    }

    private func poolEffective(_ pool: Pool) -> [MemoryEntry] {
        MemoryStore.applySupersede(
            MemoryStore.readPoolLines(project: poolProject(pool))
        )
    }

    private func poolInvalidated(_ pool: Pool) -> [MemoryEntry] {
        var latest: [String: MemoryEntry] = [:]
        var order: [String] = []
        for entry in MemoryStore.readPoolLines(project: poolProject(pool)) {
            if latest[entry.id] == nil { order.append(entry.id) }
            latest[entry.id] = entry
        }
        return order.compactMap { id in
            guard let entry = latest[id], entry.invalidated else { return nil }
            return entry
        }
    }

    private func poolStats(_ pool: Pool) -> (total: Int, hard: Int, hypothesis: Int, stale: Int) {
        let effective = poolEffective(pool)
        let kinds = Dictionary(grouping: effective, by: \.kind).mapValues(\.count)
        return (
            effective.count,
            (kinds[.constraint] ?? 0) + (kinds[.rejection] ?? 0),
            kinds[.experience] ?? 0,
            poolInvalidated(pool).count
        )
    }

    // MARK: - 入口页（全局记忆 + 各项目记忆，完全分离）

    private var entryPage: some View {
        DSScroll {
            VStack(alignment: .leading, spacing: DS.Spacing.s16) {
                VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                    Text("记忆")
                        .font(DS.Font.headingMD)
                        .foregroundStyle(Color.ink900)
                    Text("沉淀给 AI 的长期上下文 · 内容支持 Markdown")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                    Button("全局 / 项目两档说明") { scopeHelpPresented = true }
                        .buttonStyle(.plain)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.brandAccent)
                }

                poolSectionHeader("全局记忆", hint: "单一入口 · 跨项目 · 与项目记忆完全分离")
                poolCard(
                    icon: "◈", tint: .brand600, surface: .brandPopup,
                    name: "全局记忆",
                    desc: "跨项目共享 · 注入所有项目的对话 · 方法论与个人偏好",
                    pool: .global
                )

                poolSectionHeader("项目记忆", hint: "每个项目独立的记忆池 · 点击进入")
                ForEach(PMAgentStore.listProjects(), id: \.self) { name in
                    poolCard(
                        icon: "◆", tint: .statusPrimary, surface: .statusPrimarySurface1,
                        name: name,
                        desc: name == model.pipeline.project
                            ? "当前项目 · 整合本项目所有类型与版本的记忆"
                            : "项目记忆池",
                        pool: .project(name)
                    )
                }

                Text("两池完全分离、互不混淆；唯一通道是「提升」：项目经验验证为普适方法论后提升为全局，原条目保留来源标注。")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.s8)
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s20)
        }
    }

    private func poolSectionHeader(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink700)
            Spacer(minLength: 0)
            Text(hint)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink300)
        }
    }

    private func poolCard(
        icon: String, tint: Color, surface: Color,
        name: String, desc: String, pool: Pool
    ) -> some View {
        let stats = poolStats(pool)
        let latest = poolEffective(pool)
            .map(\.createdAt)
            .max() ?? ""
        let updatedText = latest.isEmpty
            ? "暂无条目"
            : "更新于 \(String(latest.prefix(10)))"
        return Button {
            self.pool = pool
            showInvalidated = false
            feedback = nil
        } label: {
            HStack(spacing: DS.Spacing.s12) {
                Text(icon)
                    .font(DS.Font.bodyLG)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(surface))
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(name)
                        .font(DS.Font.bodyMDStrong)
                        .foregroundStyle(Color.ink900)
                    Text(desc)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: DS.Spacing.s2) {
                    Text("\(stats.total) 条有效")
                        .font(DS.Font.bodyXS)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink700)
                    Text(stats.stale > 0 ? "已失效 \(stats.stale) 条" : updatedText)
                        .font(DS.Font.bodyXS)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink300)
                }
                Text("›")
                    .font(DS.Font.bodyLG)
                    .foregroundStyle(Color.ink300)
            }
            .padding(DS.Spacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .fill(Color.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .strokeBorder(Color.overlayBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 池页（方案 A 台账：内容 + meta 双行）

    private func poolPage(_ pool: Pool) -> some View {
        let effective = poolEffective(pool)
        let invalidated = poolInvalidated(pool)
        let isGlobal = pool == .global
        let isCurrentProject = pool == .project(model.pipeline.project)
        return VStack(spacing: 0) {
            // 头：返回 + 标题 + 统计 + 添加
            HStack(spacing: DS.Spacing.s10) {
                Button {
                    self.pool = nil
                    showInvalidated = false
                    feedback = nil
                } label: {
                    Text("‹")
                        .font(DS.Font.bodyLG)
                        .foregroundStyle(Color.ink700)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.surfaceSecondary))
                }
                .buttonStyle(.plain)
                .help("返回记忆入口")

                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(poolName(pool))
                        .font(DS.Font.headingMD)
                        .foregroundStyle(Color.ink900)
                    Text(
                        isGlobal
                            ? "跨项目共享 · 注入所有项目的对话 · 与项目记忆完全分离"
                            : "整合本项目所有类型与版本的记忆 · 版本只是溯源标签"
                    )
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                }
                Spacer(minLength: 0)
                Button("＋ 添加记忆") { adding = true }
                    .buttonStyle(.ds(.brand, size: .sm))
            }
            .padding(.horizontal, DS.Spacing.s24)
            .padding(.vertical, DS.Spacing.s16)

            DSDivider()

            if let feedback {
                InlineHint(text: feedback, tone: .neutral)
                    .padding(.horizontal, DS.Spacing.s24)
                    .padding(.top, DS.Spacing.s8)
            }

            DSScroll {
                VStack(alignment: .leading, spacing: 0) {
                    if effective.isEmpty {
                        VStack(spacing: DS.Spacing.s8) {
                            Text("还没有记忆")
                                .font(DS.Font.bodyMDStrong)
                                .foregroundStyle(Color.ink500)
                            Text("点右上角「＋ 添加记忆」沉淀第一条；当前项目对话中的结论 / 约束 / 否决项也会自动沉淀到项目池。")
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink500)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.s40)
                    } else {
                        ForEach(Array(effective.enumerated()), id: \.element.id) { index, entry in
                            ledgerRow(entry: entry, pool: pool)
                            if index != effective.count - 1 {
                                DSDivider()
                            }
                        }
                    }
                    staleSection(pool: pool, invalidated: invalidated)
                    if isCurrentProject {
                        consolidateSection
                    }
                }
                .padding(.horizontal, DS.Spacing.s24)
                .padding(.vertical, DS.Spacing.s12)
            }
        }
    }

    private var consolidateHint: String { "" }

    // MARK: - 整理记忆（LLM 通读当前项目池：近重复合并 / 过时失效，留痕可追溯）

    @State private var consolidating = false
    @State private var consolidateResult: String?

    private var consolidateSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s10) {
                Button(consolidating ? "整理中…" : "整理记忆") {
                    consolidating = true
                    consolidateResult = nil
                    Task {
                        let result = await model.consolidateMemory()
                        consolidateResult = result
                        consolidating = false
                    }
                }
                .buttonStyle(.ds(.secondary, size: .sm))
                .disabled(consolidating)
                Text("让模型通读项目池，找出近重复与过时条目——只产生失效标记，从不物理删除")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
                Spacer(minLength: 0)
            }
            .padding(.top, DS.Spacing.s12)
            if let consolidateResult, !consolidateResult.isEmpty {
                Text(consolidateResult)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink700)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 台账行（内容 + meta 双行；hover 浮现操作）

    private func ledgerRow(entry: MemoryEntry, pool: Pool) -> some View {
        let isGlobalPool = pool == .global
        let canPromote = !isGlobalPool && entry.kind == .experience
        return VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            MemoryContentView(content: entry.content)

            HStack(spacing: DS.Spacing.s8) {
                MemoryNatureMark(kind: entry.kind)
                if let versions = entry.versions, !versions.isEmpty {
                    Text(versions)
                        .font(DS.Font.monoSM)
                        .foregroundStyle(Color.ink300)
                        .padding(.horizontal, DS.Spacing.s4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm)
                                .strokeBorder(Color.overlayBorder, lineWidth: 1)
                        )
                        .help("版本溯源标签：老版本的教训在新版本照样可见，不随封板归档")
                }
                Text(entry.createdAt)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink300)
                Spacer(minLength: 0)

                HStack(spacing: DS.Spacing.s2) {
                    rowButton("✎", "修订（旧值留痕，可追溯）") {
                        editing = entry
                    }
                    if canPromote {
                        rowButton("↑", "提升为全局记忆（注入所有项目，原条目保留来源标注）") {
                            guard case .project(let name) = pool else { return }
                            if let err = MemoryStore.promoteEntryToGlobal(project: name, entry: entry) {
                                feedback = err
                            } else {
                                feedback = "已提升为全局记忆——原项目条目已留痕，可在「已失效」中追溯"
                            }
                        }
                    }
                    rowButton("⊘", "失效（不再注入，留痕可追溯）") {
                        if let err = MemoryStore.invalidateEntry(
                            project: poolProject(pool), entry: entry,
                            note: "手动失效（设置）"
                        ) {
                            feedback = err
                        } else {
                            feedback = nil
                        }
                    }
                }
                .opacity(hoveredEntryId == entry.id ? 1 : 0.35)
            }
        }
        .padding(.vertical, DS.Spacing.s10)
        .contentShape(Rectangle())
        .onHover { hovered in
            hoveredEntryId = hovered ? entry.id : (hoveredEntryId == entry.id ? nil : hoveredEntryId)
        }
        .id(entry.id)
    }

    private func rowButton(_ glyph: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 已失效折叠区（留痕可追溯）

    private func staleSection(pool: Pool, invalidated: [MemoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            if !invalidated.isEmpty {
                Button {
                    withAnimation(DS.Motion.spring) { showInvalidated.toggle() }
                } label: {
                    HStack(spacing: DS.Spacing.s6) {
                        Text(showInvalidated ? "▾" : "▸")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        Text("已失效 · \(invalidated.count) 条")
                            .font(DS.Font.bodySMStrong)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink500)
                        Spacer(minLength: 0)
                        Text("留痕可追溯 · 不再注入")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink300)
                    }
                    .padding(DS.Spacing.s10)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.lg).fill(Color.surfaceSecondary))
                }
                .buttonStyle(.plain)
                .padding(.top, DS.Spacing.s16)

                if showInvalidated {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(invalidated.enumerated()), id: \.element.id) { index, entry in
                            VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                                Text(entry.content)
                                    .font(DS.Font.bodyMD)
                                    .strikethrough()
                                    .foregroundStyle(Color.ink500)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: DS.Spacing.s8) {
                                    Text(entry.createdAt)
                                        .font(DS.Font.monoSM)
                                        .foregroundStyle(Color.ink300)
                                    if let ref = entry.sourceRef, !ref.isEmpty {
                                        Text("出处：\(ref)")
                                            .font(DS.Font.bodyXS)
                                            .foregroundStyle(Color.ink300)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.vertical, DS.Spacing.s8)
                            if index != invalidated.count - 1 {
                                DSDivider()
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.s12)
                    .padding(.bottom, DS.Spacing.s8)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.lg).fill(Color.surfaceSecondary))
                }
            }
        }
    }

    // MARK: - 作用域说明 sheet

    private var scopeHelpSheet: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s12) {
            Text("全局记忆 / 项目记忆")
                .font(DS.Font.headingMD)
                .foregroundStyle(Color.ink900)
            Text("两套完全分离的记忆池——各自独立入口、独立页面、独立管理。注入优先级：项目 > 全局。")
                .font(DS.Font.bodySM)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
            scopeHelpCard(
                name: "全局记忆", tint: .brand600, surface: .brandPopup,
                lines: [
                    "注入范围：所有项目的对话。",
                    "管理入口：记忆首页的「全局记忆」卡片，单一入口、独立页面。",
                    "适合放：工作方法论、个人偏好级的长效结论。",
                ]
            )
            scopeHelpCard(
                name: "项目记忆", tint: .statusPrimary, surface: .statusPrimarySurface1,
                lines: [
                    "注入范围：本项目的所有对话，整合该项目下所有类型与版本的记忆。",
                    "版本溯源：条目可标注适用版本区间（如 v1.0~v1.2）——老版本的教训在新版本照样可见，不随封板归档。",
                    "适合放：项目定位、需求边界、已确认的取舍、约束与经验。",
                ]
            )
            Text("内容一律 Markdown 存储与注入；类型由 AI 沉淀时自动识别，界面只显示行为标记（⚑ 硬边界永不裁剪 / 假设未验证可裁剪）。")
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("明白了") { scopeHelpPresented = false }
                    .buttonStyle(.ds(.primary, size: .sm))
            }
        }
        .padding(DS.Spacing.s24)
        .frame(width: 520)
    }

    private func scopeHelpCard(name: String, tint: Color, surface: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            HStack(spacing: DS.Spacing.s6) {
                Text(name)
                    .font(DS.Font.bodyMDStrong)
                    .foregroundStyle(Color.ink900)
                Text(name == "全局记忆" ? "跨项目" : "本项目")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(tint)
                    .padding(.horizontal, DS.Spacing.s6)
                    .padding(.vertical, DS.Spacing.s2)
                    .background(Capsule().fill(surface))
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg).fill(Color.surfaceSecondary))
    }
}

// MARK: - 添加 / 修订弹框（大窗口 · Markdown 编辑/预览 · 勾经验 · 版本溯源）

private struct MemoryEntryEditor: View {
    @EnvironmentObject private var model: AppModel
    let pool: MemorySettingsTab.Pool
    let entry: MemoryEntry?      // nil = 新增
    var onDismiss: () -> Void

    @State private var content = ""
    @State private var isExperience = false
    @State private var sourceRef = ""
    @State private var versions = ""
    @State private var previewing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var isGlobal: Bool { pool == .global }
    private var poolName: String {
        switch pool {
        case .global: return "全局记忆"
        case .project(let name): return "项目记忆 · \(name)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头
            HStack(alignment: .top, spacing: DS.Spacing.s10) {
                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                    Text(entry == nil ? "添加记忆" : "修订记忆")
                        .font(DS.Font.headingMD)
                        .foregroundStyle(Color.ink900)
                    Text(entry == nil
                        ? "保存后按归属注入后续对话，随时可修订或失效"
                        : "保存后旧条目失效留痕（被修订版取代），全程可追溯"
                    )
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                DSDialogCloseButton { dismiss() }
            }
            .padding(.horizontal, DS.Spacing.s20)
            .padding(.top, DS.Spacing.s16)

            VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                // 归属（只读——由进入的池决定）
                HStack(spacing: DS.Spacing.s6) {
                    Text("◈ 保存到：\(poolName)")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.brandAccent)
                        .padding(.horizontal, DS.Spacing.s10)
                        .padding(.vertical, DS.Spacing.s6)
                        .background(Capsule().fill(Color.brandPopup))
                    Spacer(minLength: 0)
                }

                // 经验勾选（新增）/ 性质说明（修订）
                if entry == nil {
                    Toggle(isOn: $isExperience) {
                        Text("这是一条待验证的经验 / 假设")
                            .font(DS.Font.bodySM)
                            .foregroundStyle(Color.ink700)
                    }
                    .toggleStyle(.checkbox)
                    Text("类型不用选——保存后 AI 自动识别硬边界（永不裁剪）与否决语义；把「为什么」写清楚即可")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let entry {
                    Text("性质：\(natureText(entry)) · AI 沉淀时自动打标，修订内容后重新识别")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 版本溯源（项目池）
                if !isGlobal {
                    VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                        Text("版本溯源（可选）")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        TextField("例：v1.0~v1.2 · 留空 = 跨版本通用", text: $versions)
                            .textFieldStyle(.plain)
                            .dsInput()
                        Text("版本不是作用域——条目自带适用区间，老版本的教训在新版本照样可见")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink300)
                    }
                }

                // 内容（Markdown 编辑 / 预览）
                VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("内容 · 支持 Markdown（**加粗** / 列表 / `代码`）")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        Spacer(minLength: 0)
                        Button(previewing ? "编辑" : "预览") { previewing.toggle() }
                            .buttonStyle(.plain)
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.brandAccent)
                    }
                    if previewing {
                        DSScroll {
                            MemoryContentView(content: content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 128)
                        .padding(DS.Spacing.s8)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.surfaceSecondary))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.md)
                                .strokeBorder(Color.overlayBorder, lineWidth: 1)
                        )
                    } else {
                        TextEditor(text: $content)
                            .font(DS.Font.bodyMD)
                            .scrollContentBackground(.hidden)
                            .frame(height: 128)
                            .padding(DS.Spacing.s8)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.surfaceSecondary))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.md)
                                    .strokeBorder(Color.overlayBorder, lineWidth: 1)
                            )
                    }
                    Text("Markdown 会按原格式注入——加粗、列表、代码帮助模型理解结构")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink300)
                }

                // 经验出处（勾选或已有出处的条目显示）
                if isExperience || entry?.kind == .experience {
                    VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                        Text("经验出处（可选）")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                        TextField("出自哪次讨论，例：v0.9 定位评审", text: $sourceRef)
                            .textFieldStyle(.plain)
                            .dsInput()
                        Text("保存后标记为「假设」——是否成立由后续项目验证；可靠度由 AI 内部评估，仅用于注入裁剪排序，不显示")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink300)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error {
                    InlineHint(text: error, tone: .warning)
                }
            }
            .padding(.horizontal, DS.Spacing.s20)
            .padding(.top, DS.Spacing.s12)

            Spacer(minLength: 0)

            // 底
            HStack {
                Spacer(minLength: 0)
                Button("取消") { dismiss() }
                    .buttonStyle(.ds(.secondary, size: .sm))
                Button(entry == nil ? "保存并注入" : "保存修订") { save() }
                    .buttonStyle(.ds(.primary, size: .sm))
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, DS.Spacing.s20)
            .padding(.vertical, DS.Spacing.s16)
        }
        .frame(width: 560)
        .background(Color.surfaceBase)
        .onAppear { prefill() }
    }

    private func natureText(_ entry: MemoryEntry) -> String {
        switch entry.kind {
        case .experience: "假设态（未验证经验）"
        case .constraint, .rejection: "硬边界（注入时永不裁剪）"
        case .conclusion: "常规认知"
        }
    }

    private func prefill() {
        guard let entry else { return }
        content = entry.content
        isExperience = entry.kind == .experience
        sourceRef = entry.sourceRef ?? ""
        versions = entry.versions ?? ""
    }

    private func save() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let project = switch pool {
        case .global: String?.none
        case .project(let name): String?.some(name)
        }
        let result: String?
        if let entry {
            result = MemoryStore.supersedeEntry(
                project: project, entry: entry, newContent: text,
                newVersions: isGlobal ? nil : versions,
                newSourceRef: sourceRef.isEmpty ? nil : sourceRef
            )
        } else {
            result = MemoryStore.addEntry(
                project: project,
                kind: isExperience ? .experience : .conclusion,
                versions: isGlobal ? nil : versions,
                content: text
            )
        }
        if let result {
            error = result
        } else {
            model.memory.reload()
            dismiss()
            onDismiss()
        }
    }
}

// MARK: - 行内提示（警示/中性一句话）

private struct InlineHint: View {
    let text: String
    let tone: Tone

    enum Tone { case warning, neutral }

    var body: some View {
        HStack(spacing: DS.Spacing.s4) {
            if tone == .warning {
                DSIcon(.warningFill, size: 12)
                    .foregroundStyle(Color.statusWarning)
            }
            Text(text)
                .font(DS.Font.bodyXS)
                .foregroundStyle(tone == .warning ? Color.statusWarning : Color.ink500)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 轻量 Markdown 内容渲染（加粗 / 行内代码 / 列表 / 空行）

struct MemoryContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s2) {
            ForEach(
                Array(content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                id: \.offset
            ) { _, line in
                let text = String(line)
                if text.hasPrefix("- ") || text.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: DS.Spacing.s6) {
                        Text("•")
                            .font(DS.Font.bodyMD)
                            .foregroundStyle(Color.ink500)
                        mdText(String(text.dropFirst(2)))
                    }
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: DS.Spacing.s4)
                } else {
                    mdText(text)
                }
            }
        }
    }

    private func mdText(_ s: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(s)
        return Text(attributed)
            .font(DS.Font.bodyMD)
            .foregroundStyle(Color.ink900)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
