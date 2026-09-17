//
//  DecisionArchiveSection.swift
//  pm_worker
//
//  决策档案生成区（2026-09-16 决策档案功能）：「生成决策日志」手动入口 +
//  按天 HTML 档案文件列表（decisions/YYYY-MM-DD.html + 版本总览.html）。
//  右栏 DecisionLogTab 与中栏 DecisionLogPage 共用本组件（单份维护）。
//  交互契约：点「生成」= 无条件全量幂等重建（内容相同跳过写入）；
//  点已生成行 = 默认浏览器打开该档案；点未生成行 = 触发生成。
//

import SwiftUI
import AppKit

struct DecisionArchiveSection: View {
    let project: String
    let version: String
    /// decisions.jsonl 文件序条目（调用方已加载，保持文件序）。
    let entries: [DecisionLogEntry]

    @State private var note: String?
    @State private var noteIsError = false
    @State private var generatedDays: Set<String> = []
    @State private var overviewGenerated = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            // 生成入口：手动触发，无状态、无定时器——点完按钮 = 所有文件与 jsonl 严格一致
            HStack(spacing: DS.Spacing.s10) {
                Spacer(minLength: 0)

                Button("生成决策日志") { generate() }
                    .buttonStyle(DSButtonStyle(variant: .primary, size: .sm))
            }

            if let note {
                Text(note)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(noteIsError ? Color.statusError : Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 文件列表：按天倒序（最新在前），版本总览钉底
            if summaries.isEmpty {
                Text("尚无决策记录——跑流水线或在对话中闭合关键话题后再生成。")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .padding(.vertical, DS.Spacing.s6)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.s8) {
                    ForEach(summaries) { summary in
                        ArchiveFileRow(
                            icon: .doc,
                            fileName: "\(summary.displayName).html",
                            meta: dayMeta(summary),
                            generated: generatedDays.contains(summary.day)
                        ) {
                            rowTapped(day: summary.day, generated: generatedDays.contains(summary.day))
                        }
                    }
                    ArchiveFileRow(
                        icon: .books,
                        fileName: DecisionArchive.overviewName,
                        meta: "版本总览 · 跨天结论汇总 + 全部待办 + 简报",
                        generated: overviewGenerated
                    ) {
                        rowTapped(day: DecisionArchive.overviewName, generated: overviewGenerated)
                    }
                }
            }
        }
        .onAppear(perform: refreshGenerated)
        .onChange(of: project) { _, _ in refreshGenerated() }
        .onChange(of: version) { _, _ in refreshGenerated() }
    }

    // MARK: - 数据

    private var summaries: [DecisionArchive.DaySummary] {
        DecisionArchive.summarize(DecisionArchive.groupByDay(entries))
    }

    private func dayMeta(_ summary: DecisionArchive.DaySummary) -> String {
        [
            "\(summary.decisions) 决策",
            summary.topics > 0 ? "\(summary.topics) 话题" : nil,
            summary.pending > 0 ? "\(summary.pending) 待验证" : nil,
            summary.hits > 0 ? "💀 \(summary.hits)" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func refreshGenerated() {
        generatedDays = DecisionArchive.generatedDays(project: project, version: version)
        overviewGenerated = DecisionArchive.hasOverview(project: project, version: version)
    }

    // MARK: - 动作

    private func generate() {
        do {
            let result = try DecisionArchive.generate(project: project, version: version)
            refreshGenerated()
            noteIsError = false
            if result.written.isEmpty {
                note = "已重建 \(result.skipped) 个文件：内容无变化，全部跳过写入（幂等）。"
            } else {
                let skipped = result.skipped > 0 ? "；\(result.skipped) 个无变化跳过" : ""
                note = "已生成/更新 \(result.written.count) 个文件（\(result.written.joined(separator: "、"))）\(skipped)。"
            }
        } catch {
            note = "生成失败：\(error.localizedDescription)"
            noteIsError = true
        }
    }

    private func rowTapped(day: String, generated: Bool) {
        if generated {
            let url = day == DecisionArchive.overviewName
                ? DecisionArchive.overviewURL(project: project, version: version)
                : DecisionArchive.archiveURL(project: project, version: version, day: day)
            NSWorkspace.shared.open(url)
        } else {
            generate()
        }
    }
}

// MARK: - 档案文件行（hover 升一阶；未生成 = 置灰引导生成）

private struct ArchiveFileRow: View {
    let icon: DSIcon.Name
    let fileName: String
    let meta: String
    let generated: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.s10) {
            DSIcon(icon, size: 14)
                .foregroundStyle(generated ? Color.ink700 : Color.ink300)
            Text(fileName)
                .font(DS.Font.monoSM)
                .foregroundStyle(Color.ink900)
                .lineLimit(1)
            Text(meta)
                .font(DS.Font.bodyXS)
                .foregroundStyle(Color.ink500)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            DSTag(title: generated ? "已生成" : "未生成", variant: generated ? .success : .neutral)
        }
        .padding(.horizontal, DS.Spacing.s12)
        .padding(.vertical, DS.Spacing.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(hovered ? Color.surfaceSecondary : Color.surfaceBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
        .opacity(generated ? 1 : 0.72)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}
