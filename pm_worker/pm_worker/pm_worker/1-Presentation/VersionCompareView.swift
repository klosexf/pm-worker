//
//  VersionCompareView.swift
//  pm_worker
//
//  版本对比（轻量 MVP，Task 3.7）：选两个版本 → 同名产物左右并排只读展示。
//  同名产物 = 两版本 stage 子目录（01-requirements…07-reports）下相对路径一致的文件
//  （覆盖 澄清要点表 / 功能架构图 / 模块-页面映射表 / 可点击原型.html / PRD文档.md 等关键产物）。
//  不做 diff 算法：.html 用 HTMLPreviewView 渲染，文本类用 ScrollView + Text(monospaced) 并排。
//  视觉还原 Wave 3-B：两栏 dsCard + 版本标识 brand 高亮 + DSEmptyState。
//

import SwiftUI

struct VersionCompareView: View {
    let projectName: String
    /// 候选版本列表；nil → 从磁盘推导（排除 knowledge/unversioned）。
    var availableVersions: [String]?

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [String] = []
    @State private var leftVersion = ""
    @State private var rightVersion = ""
    @State private var commonArtifacts: [String] = []
    @State private var selectedArtifact = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            if candidates.count < 2 {
                emptyState("至少需要两个正式版本", "unversioned 不参与对比。")
            } else if leftVersion == rightVersion {
                emptyState("请选择两个不同的版本", "版本 A 与版本 B 不能相同。")
            } else if selectedArtifact.isEmpty {
                emptyState("无同名产物", "所选两个版本没有同名产物可对比。")
            } else {
                HSplitView {
                    ArtifactPane(
                        project: projectName, version: leftVersion, relativePath: selectedArtifact
                    )
                    .padding(DS.Spacing.s8)
                    .id("left|\(leftVersion)|\(selectedArtifact)")
                    ArtifactPane(
                        project: projectName, version: rightVersion, relativePath: selectedArtifact
                    )
                    .padding(DS.Spacing.s8)
                    .id("right|\(rightVersion)|\(selectedArtifact)")
                }
            }
        }
        // 面板钳在 min–max 之间（ideal 保底尺寸，窗口大于 ideal 时浮卡可长到 max）
        .frame(
            minWidth: 760, idealWidth: 1080, maxWidth: 1320,
            minHeight: 480, idealHeight: 700, maxHeight: 820
        )
        .dsDismissOnOutsideTap { dismiss() }  // 点击面板外关闭（与「完成」同动作）
        .onAppear(perform: reload)
        .onChange(of: leftVersion) { _, _ in recomputeArtifacts() }
        .onChange(of: rightVersion) { _, _ in recomputeArtifacts() }
    }

    // MARK: - 顶部：版本对 + 产物选择

    private var header: some View {
        HStack(spacing: DS.Spacing.s12) {
            Text("版本对比")
                .font(DS.Font.headingSM)
                .foregroundStyle(Color.ink900)
            versionPicker(selection: $leftVersion, label: "版本 A")
            DSIcon(.arrowSwap, size: 13)
                .foregroundStyle(Color.brandAccent)
            versionPicker(selection: $rightVersion, label: "版本 B")
            Rectangle()
                .fill(Color.borderL1)
                .frame(width: 1, height: 18)
            DSSelect(
                options: commonArtifacts.isEmpty
                    ? [DSSelectOption("", "无同名产物")]
                    : commonArtifacts.map { DSSelectOption($0, $0) },
                selection: $selectedArtifact
            )
            .frame(maxWidth: 260)
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.ds(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
    }

    private func versionPicker(selection: Binding<String>, label: String) -> some View {
        DSSelect(
            options: candidates.map { DSSelectOption($0, $0) },
            selection: selection
        )
        .frame(width: 130)
        .help(label)
    }

    private func emptyState(_ title: String, _ description: String) -> some View {
        VStack(spacing: 0) {
            DSEmptyState(
                icon: .arrowSwap,
                title: title,
                description: description
            )
            Spacer()
        }
        .padding(.top, DS.Spacing.s48)
        .padding(.horizontal, DS.Spacing.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private func reload() {
        candidates = (availableVersions ?? PMAgentStore.listVersions(in: projectName))
            .filter { $0 != "knowledge" && $0 != "unversioned" }
        if !candidates.contains(leftVersion) { leftVersion = candidates.first ?? "" }
        if !candidates.contains(rightVersion) {
            rightVersion = candidates.count > 1 ? candidates[1] : candidates.first ?? ""
        }
        recomputeArtifacts()
    }

    private func recomputeArtifacts() {
        guard !leftVersion.isEmpty, !rightVersion.isEmpty, leftVersion != rightVersion else {
            commonArtifacts = []
            selectedArtifact = ""
            return
        }
        let left = Self.artifacts(
            in: PMAgentStore.versionURL(project: projectName, version: leftVersion)
        )
        let right = Self.artifacts(
            in: PMAgentStore.versionURL(project: projectName, version: rightVersion)
        )
        commonArtifacts = left.intersection(right).sorted()
        if !commonArtifacts.contains(selectedArtifact) {
            selectedArtifact = commonArtifacts.first ?? ""
        }
    }

    /// 一个版本 stage 子目录下的产物相对路径集合（深度 1：`02-structure/功能架构图.md`）。
    private static func artifacts(in versionDir: URL) -> Set<String> {
        let fm = FileManager.default
        var result: Set<String> = []
        for stage in stageDirs {
            let files = (try? fm.contentsOfDirectory(
                at: versionDir.appendingPathComponent(stage, isDirectory: true),
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files where !file.hasDirectoryPath {
                result.insert("\(stage)/\(file.lastPathComponent)")
            }
        }
        return result
    }

    private static let stageDirs = [
        "01-requirements", "02-structure", "03-prototypes",
        "04-prd", "05-analysis", "06-discussions", "07-reports",
    ]
}

// MARK: - 单侧产物面板（只读，dsCard 卡片）

private struct ArtifactPane: View {
    let project: String
    let version: String
    let relativePath: String

    private var url: URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(relativePath)
    }

    private var isHTML: Bool {
        url.pathExtension.lowercased() == "html"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.s8) {
                // 版本标识 brand 高亮（对比差异锚点）
                Text(version)
                    .font(DS.Font.bodySMStrong)
                    .foregroundStyle(Color.brandAccent)
                Text(relativePath)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink500)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.s12)
            .padding(.vertical, DS.Spacing.s8)
            DSDivider()
            if isHTML {
                HTMLPreviewView(fileURL: url)
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                textPane
            }
        }
        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        .dsCard(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xxl))
    }

    private var textPane: some View {
        DSScroll {
            Text((try? String(contentsOf: url, encoding: .utf8)) ?? "（文件不存在或读取失败）")
                .font(DS.Font.monoSM)
                .foregroundStyle(Color.ink900)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(DS.Spacing.s12)
        }
    }
}
