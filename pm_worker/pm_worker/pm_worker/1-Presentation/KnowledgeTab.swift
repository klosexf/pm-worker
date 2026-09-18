//
//  KnowledgeTab.swift
//  pm_worker
//
//  右栏「知识点」Tab 已移除（2026-09-17 钦定）：语义检索收口到左栏知识库
//  整页（CardLibraryView 搜索框挂 Retriever），右栏回归「会话伴随上下文」。
//  本文件保留跨视图共享的知识层组件：SearchTraceLog（开发者检查器 ⌘D 读取）、
//  ScopeBadge（scope 徽章）、AnnotationTimeline（实战案例时间线）。
//

import SwiftUI
import GRDB
import Combine

// MARK: - 检索 trace 共享（产出 → 开发者检查器 ⌘D 展示）

/// 最近一次手动检索 trace（AppModel 禁改，轻量单例跨窗口共享）。
/// 进程级存活；开发者检查器「检索 trace」区实时联动读取。
@MainActor
final class SearchTraceLog: ObservableObject {
    @Published private(set) var last: RetrievalTrace?

    static let shared = SearchTraceLog()

    /// Xcode 26 默认 MainActor：ObservableObject 若被销毁须显式退出隔离路径
    ///（单例实际不销毁，防御性声明）。
    nonisolated deinit {}

    private init() {}

    func record(_ trace: RetrievalTrace) {
        last = trace
    }
}

// MARK: - 共享小组件

/// scope 徽章：project=品牌紫 global=绿（E12 命中来源可观测；原型 .ds-tag 变体）。
struct ScopeBadge: View {
    let scope: String

    var body: some View {
        DSTag(
            title: scope == "global" ? "全局" : "项目",
            variant: scope == "global" ? .success : .brand
        )
    }
}

/// 实战案例时间线（读卡片 .md → MethodologyCard.parse → annotations
/// 逐条「日期 · 项目：注记」；知识库页与卡片详情弹层共用。
/// 详情弹层方案 B 分区块里头部让位给语义色签，showsHeader 传 false）。
struct AnnotationTimeline: View {
    let card: MethodologyCard?
    var showsHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            if showsHeader {
                Text("实战案例时间线（append-only · 只增不覆盖）")
                    .font(DS.Font.bodyXSStrong)
                    .foregroundStyle(Color.ink500)
            }
            if let card, !card.annotations.isEmpty {
                ForEach(Array(card.annotations.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: DS.Spacing.s6) {
                        Circle()
                            .fill(Color.brand600)
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        Text("\(note.date) · \(note.project)：\(note.note)")
                            .font(DS.Font.bodyXS)
                            .foregroundStyle(Color.ink500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if card != nil {
                Text("暂无实战案例（方法论被采纳 / 合并时自动追加，越用越厚）")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink300)
            } else {
                Text("卡片文件读取失败或已被移除（索引行仍在）")
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.statusWarning)
            }
        }
        .padding(.top, showsHeader ? DS.Spacing.s2 : 0)
    }
}
