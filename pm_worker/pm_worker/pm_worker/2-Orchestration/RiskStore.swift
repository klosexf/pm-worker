//
//  RiskStore.swift
//  pm_worker
//
//  💀 风险登记闭环运行时（design.md §6.2 四步 / E16a）：
//  ① 追加（落盘必带触发信号；软上限 3 条，超限提示收敛而非拒收）
//  ② 状态机事件结算（命中 → triggered + 回写决策日志 risk_hit）
//  ③ 封板终态（全部 open 统一结算 closed_unfired，悬空口径闭合）
//  ④ 收敛动作（证伪关闭 / 降级为 open_question / 合并同源）。
//  risks.jsonl append-only：结算与收敛不改写旧行，而是 append 同 id 新行，
//  读取侧按「同 id 取最后一行」折叠（collapse）。
//

import Foundation
import Combine

@MainActor
final class RiskStore: ObservableObject {
    @Published private(set) var risks: [RiskRecord]

    /// 活跃（open + triggered）软上限（§6.2 ③：工作集限制，类比 WIP limit）。
    static let activeLimit = 3

    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避：显式退出隔离销毁路径
    /// （本实例会在切换上下文时被替换销毁，默认隔离 deinit 会触发 malloc 崩溃）。
    nonisolated deinit {}

    let project: String
    let version: String

    private var risksURL: URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "risks.jsonl")
    }

    private var decisionsURL: URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "decisions.jsonl")
    }

    // MARK: - 初始化（读侧折叠）

    init(project: String, version: String) {
        self.project = project
        self.version = version
        // 幂等工作区保障：目录 / risks.jsonl 缺失时补齐
        try? PMAgentStore.ensureWorkspace(project: project, version: version)
        let url = PMAgentStore.jsonlURL(project: project, version: version, file: "risks.jsonl")
        risks = Self.collapse(PMAgentStore.readLines(RiskRecord.self, from: url))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 同 id 多行（原始行 + 结算 / 收敛行）→ 保留最后一条（按首次出现顺序）。
    nonisolated static func collapse(_ records: [RiskRecord]) -> [RiskRecord] {
        var latest: [String: RiskRecord] = [:]
        var order: [String] = []
        for record in records {
            if latest[record.id] == nil { order.append(record.id) }
            latest[record.id] = record
        }
        return order.compactMap { latest[$0] }
    }

    // MARK: - 活跃口径（§6.2 ③）

    /// 活跃 = open + triggered（未闭合条目）。
    var activeRisks: [RiskRecord] {
        risks.filter { $0.status == .open || $0.status == .triggered }
    }

    var needsConvergence: Bool {
        activeRisks.count > Self.activeLimit
    }

    // MARK: - ① 追加（软上限：超限提示收敛，不拒收）

    /// - Returns: 需收敛时的建议文案；nil 表示未超限。
    @discardableResult
    func append(_ risk: RiskRecord) throws -> String? {
        try PMAgentStore.appendLine(risk, to: risksURL)
        risks.append(risk)
        risks.sort { $0.createdAt < $1.createdAt }
        guard needsConvergence else { return nil }
        return "活跃 💀 已达 \(activeRisks.count) 条（软上限 \(Self.activeLimit) 条）："
            + "建议先收敛（证伪关闭 / 降级为 open_question / 合并同源）再继续登记。"
    }

    // MARK: - ② 状态机事件结算（§6.2 ②：事件驱动，非每轮轮询）

    /// 把所有 triggerSignal == trigger 且 status == .open 的条目结算为 .triggered，
    /// 并为每条回写一条决策日志（risk_hit：当初预测 vs 实际发生——复盘最值钱资产）。
    /// - Returns: 被结算的条目（触发后的最新状态）。
    @discardableResult
    func settle(trigger: RiskRecord.TriggerSignal, note: String? = nil) throws -> [RiskRecord] {
        let matched = risks.filter { $0.triggerSignal == trigger && $0.status == .open }
        let now = ISO8601.timestamp()
        var settled: [RiskRecord] = []
        for record in matched {
            var fired = record
            fired.status = .triggered
            fired.closedAt = now
            try PMAgentStore.appendLine(fired, to: risksURL)
            try PMAgentStore.appendLine(
                DecisionLogEntry.riskHit(
                    RiskHitRecord(
                        riskId: fired.id,
                        predicted: fired.hypothesis,
                        actual: note ?? Self.describe(trigger)
                    )
                ),
                to: decisionsURL
            )
            if let index = risks.firstIndex(where: { $0.id == fired.id }) {
                risks[index] = fired
            }
            settled.append(fired)
        }
        return settled
    }

    // MARK: - ③ 封板终态（§6.2 ④：每条 💀 有始有终）

    /// 所有 open 统一结算为 .closedUnfired；triggered 不动（已闭合为命中）。
    func settleAllForRelease() throws {
        let now = ISO8601.timestamp()
        for index in risks.indices where risks[index].status == .open {
            risks[index].status = .closedUnfired
            risks[index].closedAt = now
            try PMAgentStore.appendLine(risks[index], to: risksURL)
        }
    }

    // MARK: - ④ 收敛动作（软上限超限时调用；全部 append-only）

    /// 关闭（已证伪）。
    func closeAsFalsified(id: String) throws {
        try converge(id: id, status: .closedFalsified, resolution: "已证伪关闭")
    }

    /// 降级为 open_question（实为 ❓ 非 💀；不新增模型字段，resolution 记录去向）。
    func downgradeToOpenQuestion(id: String) throws {
        guard let record = risks.first(where: { $0.id == id }) else {
            throw RiskStore.notFound(id)
        }
        try converge(
            id: id,
            status: .closedFalsified,
            resolution: "降级为 open_question：\(record.hypothesis)"
        )
    }

    /// 合并同源 💀：source 关闭为 .merged，target 保留不动。
    func merge(into targetId: String, from sourceId: String) throws {
        guard targetId != sourceId else {
            throw NSError(
                domain: "RiskStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "风险不能合并到自身：\(sourceId)"]
            )
        }
        guard risks.contains(where: { $0.id == targetId }) else {
            throw NSError(
                domain: "RiskStore", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "合并目标不存在：\(targetId)"]
            )
        }
        try converge(id: sourceId, status: .merged, resolution: "合并到 \(targetId)")
    }

    // MARK: - Private

    /// 收敛通用路径：append 同 id 新行（status / closedAt / resolution），内存同步。
    private func converge(id: String, status: RiskRecord.Status, resolution: String) throws {
        guard let index = risks.firstIndex(where: { $0.id == id }) else {
            throw RiskStore.notFound(id)
        }
        risks[index].status = status
        risks[index].closedAt = ISO8601.timestamp()
        risks[index].resolution = resolution
        try PMAgentStore.appendLine(risks[index], to: risksURL)
    }

    private static func notFound(_ id: String) -> NSError {
        NSError(
            domain: "RiskStore", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "风险不存在：\(id)"]
        )
    }

    /// 触发信号的缺省描述（risk_hit.actual 无 note 时的兜底文案）。
    nonisolated private static func describe(_ trigger: RiskRecord.TriggerSignal) -> String {
        switch trigger {
        case .structureRegen: return "结构产物重新生成（structure_regen）"
        case .prototypeRegen: return "原型产物重新生成（prototype_regen）"
        case .prdStale: return "PRD 相对已确认原型过期（prd_stale）"
        case .decisionOverturned: return "既有决策被推翻（decision_overturned）"
        case .release: return "版本封板（release）"
        }
    }
}
