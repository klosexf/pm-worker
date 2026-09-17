//
//  ProjectHomeView.swift
//  pm_worker
//
//  项目主页骨架（Task 1.3）：目标收敛句 / 长期约束 / 否决项（红）/ 版本时间线 / 四阶段状态点。
//  Task 3.7 版本管理：封板黄条置顶（存在已封板版本时）+ 未封板版本「封板」按钮（两段式确认），
//  封板动作经 onReleaseVersion 闭包交由 AppModel 执行（release-notes 生成 → VersionStore.release
//  + RiskStore.settleAllForRelease + GitSnapshotQueue）——本视图只发意图，不做业务。
//

import SwiftUI

struct ProjectHomeView: View {
    @EnvironmentObject private var model: AppModel
    let projectName: String

    /// 封板意图回调（主 agent 在 AppModel 侧接线：LLM 生成 release-notes →
    /// VersionStore.release(project:version:notes:settleRisks:) → GitSnapshotQueue）。
    /// 为 nil（当前 ContentView 默认构造）时按钮仅展示不执行。
    var onReleaseVersion: ((String) -> Void)? = nil

    @State private var goalStatement: String = ""
    @State private var constraints: [String] = []
    @State private var rejections: [String] = []
    @State private var versions: [String] = []
    @State private var newConstraint = ""
    @State private var newRejection = ""
    @State private var loadFailed = false
    /// 已封板版本集合（version.json status == .released，磁盘为准）。
    @State private var releasedVersions: Set<String> = []
    /// 各版本变更池未处置条目数（毕业仪式：封板前必须逐条处置，不许默认沉淀）。
    @State private var pooledCounts: [String: Int] = [:]
    /// 毕业仪式拦截弹窗：池内有未处置条目时点封板 → 指引先去处置。
    @State private var poolBlockVersion: String?
    /// 封板第一段确认弹窗的一行复盘摘要（点击封板时从磁盘 fold，nil = 无复盘内容）。
    @State private var retroLine: String?
    /// 封板两段式确认：第一段（说明后果）/ 第二段（最终确认）。
    @State private var pendingWarnVersion: String?
    @State private var pendingConfirmVersion: String?
    @State private var showCompare = false

    var body: some View {
        DSScroll {
            VStack(alignment: .leading, spacing: DS.Spacing.s32) {
                // 封板黄条置顶：项目存在已封板版本时提示（最新封板版本号）
                if let latestReleased = releasedVersions.max() {
                    ReleaseBanner(version: latestReleased)
                }

                header

                // 目标收敛句（可编辑，写回 project.json）
                section("目标收敛句") {
                    TextEditor(text: $goalStatement)
                        .font(DS.Font.bodyBase)
                        .dsTextarea(focused: false, minHeight: 56)
                        .onChange(of: goalStatement) { _, _ in saveProject() }
                }

                // 长期约束
                section("长期约束") {
                    listEditor(
                        items: $constraints, draft: $newConstraint,
                        placeholder: "例如：只做 Apple Silicon；不上安卓"
                    ) { saveProject() }
                }

                // 否决项（红色醒目）
                section("否决项 · 红线") {
                    listEditor(
                        items: $rejections, draft: $newRejection,
                        placeholder: "例如：不做社交裂变",
                        destructive: true
                    ) { saveProject() }
                }

                // 版本时间线 + 四阶段状态点 + 封板入口（Task 3.7）+ 版本对比入口
                section("版本时间线") {
                    VStack(alignment: .leading, spacing: DS.Spacing.s12) {
                        if versions.filter({ $0 != "unversioned" }).count >= 2 {
                            HStack {
                                Spacer()
                                Button {
                                    showCompare = true
                                } label: {
                                    Label {
                                        Text("对比版本")
                                    } icon: {
                                        DSIcon(.split, size: 14)
                                    }
                                }
                                .buttonStyle(.ds(.secondary, size: .sm))
                                .help("选两个版本，同名产物左右并排只读对比")
                            }
                        }
                        if versions.isEmpty {
                            DSEmptyState(
                                icon: .layers,
                                title: "暂无版本",
                                description: "会话运行后可建版本"
                            )
                        } else {
                            ForEach(versions, id: \.self) { version in
                                versionTimelineRow(version)
                            }
                        }
                    }
                }
            }
            .padding(DS.Spacing.s32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
        // 封板两段式确认：第一段说明后果 → 第二段最终确认
        .alert(
            "封板 \(pendingWarnVersion ?? "")",
            isPresented: Binding(
                get: { pendingWarnVersion != nil },
                set: { if !$0 { pendingWarnVersion = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingWarnVersion = nil }
            Button("继续…") {
                pendingConfirmVersion = pendingWarnVersion
                pendingWarnVersion = nil
            }
        } message: {
            Text(
                "封板后版本目录转为只读（不可再修改产物），风险全部结算"
                    + "（open 💀 → closed_unfired），并留存 release-notes 与 Git 快照。"
                    + "如需继续修改，请新建版本。"
                    + (retroLine.map { "\n\n\($0)" } ?? "")
            )
        }
        .alert(
            "确认封板 \(pendingConfirmVersion ?? "")",
            isPresented: Binding(
                get: { pendingConfirmVersion != nil },
                set: { if !$0 { pendingConfirmVersion = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingConfirmVersion = nil }
            Button("封板", role: .destructive) {
                if let version = pendingConfirmVersion {
                    onReleaseVersion?(version)
                }
                pendingConfirmVersion = nil
            }
        } message: {
            Text("目录即将冻结为只读，此操作不可在应用内撤销。确认封板？")
        }
        .alert(
            "无法封板 \(poolBlockVersion ?? "")",
            isPresented: Binding(
                get: { poolBlockVersion != nil },
                set: { if !$0 { poolBlockVersion = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { poolBlockVersion = nil }
        } message: {
            Text(
                "变更池还有 \(pooledCounts[poolBlockVersion ?? ""] ?? 0) 条未处置——"
                    + "封板前需在「决策日志 · 变更池」逐条裁决（纳入后续版本 / 放弃 / 顺延），"
                    + "不许默认沉淀。"
            )
        }
        .sheet(isPresented: $showCompare) {
            VersionCompareView(
                projectName: projectName,
                availableVersions: versions.filter { $0 != "unversioned" }
            )
        }
    }

    // MARK: - 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            // 高级感升级：项目名用编辑级衬线展示字（New York）——文档标题时刻
            Text(projectName)
                .font(DS.Font.displayLG)
                .dsTight()
                .foregroundStyle(Color.ink900)
            Text("项目主页")
                .font(DS.Font.bodyBase)
                .foregroundStyle(Color.ink500)
            if loadFailed {
                Text("⚠️ project.json 读取失败，展示可能不是最新")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.statusError)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            Text(title)
                .font(DS.Font.headingSM)
                .foregroundStyle(Color.ink900)
            content()
        }
    }

    private func listEditor(
        items: Binding<[String]>,
        draft: Binding<String>,
        placeholder: String,
        destructive: Bool = false,
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s8) {
            ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { index, item in
                HStack(spacing: DS.Spacing.s8) {
                    DSIcon(destructive ? .circleX : .circleCheck, size: 16)
                        .foregroundStyle(destructive ? Color.statusError : Color.ink500)
                        .font(DS.Font.bodySM)
                    Text(item)
                        .font(DS.Font.bodySM)
                        .foregroundStyle(destructive ? Color.statusError : Color.ink700)
                    Spacer()
                    Button {
                        items.wrappedValue.remove(at: index)
                        onChange()
                    } label: {
                        DSIcon(.circleMinus, size: 16)
                            .foregroundStyle(Color.ink300)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DS.Spacing.s8)
                .padding(.vertical, DS.Spacing.s4)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(destructive ? Color.statusErrorSurface1 : Color.overlayL1)
                )
                .overlay {
                    if destructive {
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .strokeBorder(Color.statusError.opacity(0.16), lineWidth: 1)
                    }
                }
            }
            HStack(spacing: DS.Spacing.s8) {
                TextField(placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .font(DS.Font.bodySM)
                    .foregroundStyle(Color.ink900)
                    .onSubmit { addListItem(items, draft: draft, onChange: onChange) }
                Button {
                    addListItem(items, draft: draft, onChange: onChange)
                } label: {
                    DSIcon(.plus, size: 16)
                }
                .buttonStyle(.ds(.secondary, size: .sm))
                .help("添加")
            }
        }
    }

    private func addListItem(
        _ items: Binding<[String]>, draft: Binding<String>, onChange: @escaping () -> Void
    ) {
        let value = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        items.wrappedValue.append(value)
        draft.wrappedValue = ""
        onChange()
    }

    // MARK: - 版本时间线 + 四阶段状态点 + 封板（Task 3.7）

    private func versionTimelineRow(_ version: String) -> some View {
        let isUnversioned = version == "unversioned"
        let isReleased = releasedVersions.contains(version)
        return HStack(spacing: DS.Spacing.s12) {
            // 封板 = 成功绿锁 / 未封板品牌点 / 无版本灰点
            DSIcon(isReleased ? .lock : .dot, size: 8)
                .foregroundStyle(
                    isReleased
                        ? Color.statusSuccess
                        : (isUnversioned ? Color.ink300 : Color.brand600)
                )
            VStack(alignment: .leading, spacing: DS.Spacing.s6) {
                HStack(spacing: DS.Spacing.s6) {
                    Text(isUnversioned ? "默认无版本号" : version)
                        .font(DS.Font.bodyMDStrong)
                        .foregroundStyle(Color.ink900)
                    if isReleased {
                        Text("封板 · 只读")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.statusSuccess)
                            .padding(.horizontal, DS.Spacing.s6)
                            .padding(.vertical, DS.Spacing.s2)
                            .background(Capsule().fill(Color.statusSuccessSurface1))
                    }
                }
                // 四阶段状态点（M1 骨架：全灰；M2 状态机接入后点亮）
                HStack(spacing: DS.Spacing.s16) {
                    ForEach(["澄清", "结构", "原型", "PRD"], id: \.self) { stage in
                        HStack(spacing: DS.Spacing.s4) {
                            Circle().fill(Color.overlayL2).frame(width: 5, height: 5)
                            Text(stage)
                                .font(DS.Font.bodyXS)
                                .foregroundStyle(Color.ink500)
                        }
                    }
                }
            }
            Spacer()
            Button("打开会话列表") {
                model.selection = .session(
                    project: projectName,
                    version: version,
                    sessionId: UUID().uuidString
                )
            }
            .buttonStyle(.ds(.ghost, size: .sm))
            if !isUnversioned && !isReleased {
                Button {
                    // 毕业仪式闸：池内有未处置条目 → 拦截指引先去处置（不许默认沉淀）
                    if (pooledCounts[version] ?? 0) > 0 {
                        poolBlockVersion = version
                    } else {
                        // 对账前置：一行复盘（变更处置 / 回退 / 闸口 outcome）随第一段确认展示
                        retroLine = ReleaseRetro.load(
                            project: projectName, version: version
                        ).oneLiner
                        pendingWarnVersion = version
                    }
                } label: {
                    Label {
                        Text("封板")
                    } icon: {
                        DSIcon(.lock, size: 14)
                    }
                }
                .buttonStyle(.ds(.secondary, size: .sm))
                .help("封板此版本：目录转只读，留存 release-notes 与 Git 快照")
            }
        }
        .dsCard(padding: DS.Spacing.s16)
    }

    // MARK: - project.json 读写

    private func load() {
        guard let project = try? PMAgentStore.readProject(projectName) else {
            loadFailed = true
            return
        }
        goalStatement = project.goalStatement ?? ""
        constraints = project.constraints
        rejections = project.rejections
        versions = PMAgentStore.listVersions(in: projectName).filter { $0 != "knowledge" }
        // 封板状态（磁盘 version.json 为准）
        releasedVersions = Set(
            versions.compactMap { version in
                let doc = try? PMAgentStore.readVersion(project: projectName, version: version)
                return doc?.status == .released ? version : nil
            }
        )
        // 毕业仪式前置：各版本变更池未处置条目数（封板闸依据）
        pooledCounts = Dictionary(uniqueKeysWithValues: versions.map { version in
            (
                version,
                ChangeLedger.load(project: projectName, version: version)
                    .filter(\.isPooled).count
            )
        })
    }

    private func saveProject() {
        guard var project = try? PMAgentStore.readProject(projectName) else { return }
        project.goalStatement = goalStatement.isEmpty ? nil : goalStatement
        project.constraints = constraints
        project.rejections = rejections
        try? PMAgentStore.writeProject(project, to: PMAgentStore.projectURL(projectName))
        model.reloadTree()
    }
}
