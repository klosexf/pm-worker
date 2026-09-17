//
//  DutyHandover.swift
//  pm_worker
//
//  系统代答链「值班单」交接条（方案 C，2026-09-15 钦定）：
//  一条用户消息触发多次 LLM 调用时（判断段 → 回退/跳步 → 自动重做段），
//  每个续段的内容顶部渲染一行段级计量——进行态给「计时 + 已生成字数」，
//  完成态定格为「耗时 + 步数 + 阶段」，点击展开链内交接明细时间轴。
//  数据全部由已有条目推导（MessageBubble.dutyHandover，见 ConversationView），
//  不新增持久化；历史会话重开同样可见（think 随 assistant 条目落盘）。
//

import Combine
import SwiftUI

/// 交接条数据（纯值类型）。
/// 铁律：不得含 Date()/now 派生字段——MessageBubble 走 Equatable 短路
/// （流式期间对话页每秒十次重渲染），历史气泡每帧不等会让短路失效。
nonisolated struct DutyHandover: Equatable {
    /// 明细时间轴节点（HH:mm:ss + 文案，均为已格式化字符串）。
    nonisolated struct Node: Equatable {
        let time: String
        let text: String
    }

    /// 本段在链内的序号（1-based；链首段为 1，故交接条只出现在 ≥2 的续段）。
    let segmentIndex: Int
    /// 本段耗时（秒，来自 entry.think.dur）；进行态 / 无思考模型为 nil。
    let durationSeconds: Int?
    /// 本段步数（entry.think.steps.count）；同上。
    let stepCount: Int?
    /// 链内阶段徽标（如「③ 原型」）；链内行无阶段标记时为 nil。
    let stageLabel: String?
    /// 明细时间轴（升序）。
    let nodes: [Node]
}

/// 交接条：一行段级计量（可展开明细）。零容器零描边（降噪基调），与正文同起始线；
/// 与生成文件卡（42 砖那种）明确区分，不做成卡片。
struct DutyHandoverBar: View {
    /// 段计量数据（进行态时 duration/stepCount 为 nil，由 live 承接）。
    let data: DutyHandover
    /// 进行态附加数据；nil = 已完成态（不显示脉冲点与实时计时）。
    var live: Live? = nil

    struct Live {
        /// 本轮流起始时刻（nil = 尚未进入生成，显示「正在准备…」）。
        let startedAt: Date?
        /// 已生成字数（store.streamingText.count）。
        let charCount: Int
    }

    @State private var expanded = false
    @State private var hovered = false

    /// 明细可展开性：无节点（时间戳全部不可解析的存量数据）时不显示 chevron、不可点。
    private var expandable: Bool { !data.nodes.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            summaryLine
            if expanded {
                detailPanel
            }
        }
    }

    // MARK: 汇总行（一行段级计量）

    private var summaryLine: some View {
        HStack(spacing: DS.Spacing.s6) {
            if live != nil {
                DSPulseDot(tint: Color.ink500)
            }
            Text(headline)
                .font(DS.Font.bodyXS)
                .foregroundStyle(hovered ? Color.ink700 : Color.ink500)
            if let live {
                // 叶视图承载秒级刷新：外层气泡（含 Markdown）不随计时重渲染
                HandoverLiveClock(
                    startedAt: live.startedAt,
                    charCount: live.charCount,
                    highlighted: hovered
                )
            } else if !settledMetrics.isEmpty {
                Text(settledMetrics)
                    .font(DS.Font.bodyXS)
                    .monospacedDigit()
                    .foregroundStyle(hovered ? Color.ink500 : Color.ink300)
            }
            if expandable {
                DSIcon(.chevronRight, size: 10)
                    .foregroundStyle(hovered ? Color.ink500 : Color.ink300)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .animation(DS.Motion.springFast, value: hovered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in hovered = hovering }
        .onTapGesture {
            guard expandable else { return }
            withAnimation(DS.Motion.spring) { expanded.toggle() }
        }
    }

    /// 主文案：进行态 / 完成态。
    private var headline: String {
        live == nil ? "第 \(data.segmentIndex) 段完成" : "第 \(data.segmentIndex) 段进行中"
    }

    /// 完成态计量段（耗时 · 步数 · 阶段；缺失项整段省略，不伪造）。
    private var settledMetrics: String {
        var parts: [String] = []
        if let text = durationText { parts.append(text) }
        if let stepCount = data.stepCount { parts.append("\(stepCount) 步") }
        if let stageLabel = data.stageLabel { parts.append(stageLabel) }
        return parts.joined(separator: " · ")
    }

    private var durationText: String? {
        guard let seconds = data.durationSeconds else { return nil }
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s"
    }

    // MARK: 展开明细（交接时间轴）

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s4) {
            ForEach(Array(data.nodes.enumerated()), id: \.offset) { _, node in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s10) {
                    Text(node.time)
                        .font(DS.Font.mono2XS)
                        .foregroundStyle(Color.ink300)
                        .frame(width: 58, alignment: .leading)
                    Text(node.text)
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, DS.Spacing.s2)
        .padding(.top, DS.Spacing.s2)
    }
}

// MARK: - 进行态实时计量（叶视图）

/// 每秒刷新的「mm:ss · 已生成 N 字」。独立叶视图把 @State now 的失效范围
/// 限制在这一小段文本内——不用 TimelineView（本仓无先例，且会引入新的调度面）；
/// 计时器随视图出现/消失自动起停（完成态此视图不存在）。
private struct HandoverLiveClock: View {
    let startedAt: Date?
    let charCount: Int
    /// hover 提亮（与外层汇总行联动）。
    let highlighted: Bool

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(clockText)
            .font(DS.Font.bodyXS)
            .monospacedDigit()
            .foregroundStyle(highlighted ? Color.ink500 : Color.ink300)
            .onReceive(ticker) { now = $0 }
    }

    private var clockText: String {
        guard let startedAt else { return "· 正在准备…" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return "· \(String(format: "%02d:%02d", seconds / 60, seconds % 60))"
            + " · 已生成 \(charCount) 字"
    }
}