//
//  DecisionLogTab.swift
//  pm_worker
//
//  右栏「决策日志」Tab（design.md §5.2 / §6.4）：
//  决策档案生成区（DecisionArchiveSection，2026-09-16）：手动「生成决策日志」
//    → decisions/YYYY-MM-DD.html 按天档案 + 版本总览.html，
//    点已生成行用默认浏览器打开。
//  原始 jsonl 记录不再在 UI 投影（2026-09-16）：decisions.jsonl 保持事实源，
//  UI 消费统一走生成的 HTML 档案。
//

import SwiftUI

struct DecisionLogTab: View {
    @EnvironmentObject private var model: AppModel

    /// decisions.jsonl 文件序条目（喂给档案生成区做按天分组与统计）。
    @State private var entries: [DecisionLogEntry] = []

    var body: some View {
        Group {
            if let ctx = model.selection.inspectorProject {
                DSScroll {
                    DecisionArchiveSection(
                        project: ctx.project,
                        version: ctx.version,
                        entries: entries
                    )
                    .padding(DS.Spacing.s12)
                }
            } else {
                DSEmptyState(
                    icon: .barList,
                    title: "尚无决策上下文",
                    description: "进入会话后可在此生成决策日志 HTML 档案。"
                )
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.selection) { _, _ in reload() }
    }

    // MARK: - 数据（decisions.jsonl 只读）

    private func reload() {
        guard let ctx = model.selection.inspectorProject else {
            entries = []
            return
        }
        entries = PMAgentStore.readLines(
            DecisionLogEntry.self,
            from: PMAgentStore.jsonlURL(
                project: ctx.project, version: ctx.version, file: "decisions.jsonl"
            )
        )
    }
}
