//
//  RiskStore.swift
//  pm_worker
//
//  风险登记闭环运行时（方案 A 四态版）：
//  ① 追加（自评审 fatal → risks.jsonl，带影响与建议方案；登记不设上限）
//  ② 采纳 / 接受（open → mitigating + 决策日志；或 accepted 自留）
//  ③ 验证解除 / 重开（mitigating → resolved + 决策日志；没解决 → 重开回 open）
//  ④ 封板兜底（未闭合的统一 accepted 自留，带入 PRD 已知风险；命中走 risk_hit 对照）。
//  risks.jsonl append-only：状态流转不改写旧行，而是 append 同 id 新行，
//  读取侧按「同 id 取最后一行」折叠（collapse）。
//

import Foundation
import Combine

@MainActor
final class RiskStore: ObservableObject {
    @Published private(set) var risks: [RiskRecord]

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

    /// 同 id 多行（原始行 + 状态流转行）→ 保留最后一条（按首次出现顺序）。
    nonisolated static func collapse(_ records: [RiskRecord]) -> [RiskRecord] {
        var latest: [String: RiskRecord] = [:]
        var order: [String] = []
        for record in records {
            if latest[record.id] == nil { order.append(record.id) }
            latest[record.id] = record
        }
        return order.compactMap { latest[$0] }
    }

    // MARK: - 分区口径（台账三分区）

    /// 待处理（自评审登记，等用户决定）。
    var pendingRisks: [RiskRecord] {
        risks.filter { $0.status == .open }
    }

    /// 已挂方案（采纳后等验证；跨确认门时批量核验）。
    var mitigatingRisks: [RiskRecord] {
        risks.filter { $0.status == .mitigating }
    }

    /// 未闭合（待处理 + 已挂方案）——封板兜底与 PRD 注入口径。
    var activeRisks: [RiskRecord] {
        risks.filter(\.isActive)
    }

    // MARK: - ① 追加

    func append(_ risk: RiskRecord) throws {
        try PMAgentStore.appendLine(risk, to: risksURL)
        risks.append(risk)
        risks.sort { $0.createdAt < $1.createdAt }
    }

    // MARK: - ② 采纳 / 接受

    /// 采纳方案：open → mitigating（挂起等验证，≠ 解除）。
    /// 同步回写一条决策日志（待验证态——方案落地验证通过后由 resolve 补一条解除决策）。
    /// - Parameter evidence: 实施证据指针（采纳落实闭环：AI 生成实施交付物的对话留痕，
    ///   形如「对话留痕 · 会话 s_xx · 回合 m_xx」；普通采纳传 nil）。
    /// - Parameter planArtifact: 执行包产物相对路径（采纳落实闭环落盘的
    ///   05-artifacts/risk-plans/&lt;id&gt;.md；普通采纳传 nil）。
    /// - Returns: 回写的决策记录（含 id，供台账行展示「→ 决策日志 d_xx」）。
    @discardableResult
    func adopt(id: String, evidence: String? = nil, planArtifact: String? = nil) throws -> DecisionRecord {
        guard let index = risks.firstIndex(where: { $0.id == id }) else {
            throw RiskStore.notFound(id)
        }
        guard risks[index].status == .open else {
            throw RiskStore.wrongState(id, from: risks[index].status, expect: .open)
        }
        var record = risks[index]
        record.status = .mitigating
        let decision = Self.mitigationDecision(for: record, evidence: evidence)
        record.resolution = evidence == nil
            ? "决策日志 \(decision.id)"
            : "决策日志 \(decision.id) · 实施证据已留对话"
        if let planArtifact {
            record.resolution = (record.resolution ?? "") + " · 执行包 \(planArtifact)"
        }
        record.planArtifact = planArtifact
        record.closedAt = nil
        try PMAgentStore.appendLine(record, to: risksURL)
        try PMAgentStore.appendLine(DecisionLogEntry.decision(decision), to: decisionsURL)
        risks[index] = record
        return decision
    }

    // MARK: 执行包产物（采纳落实闭环 · 2026-09-17 方案 C）

    /// 把采纳落实回合的执行逻辑落成真产物文件（05-artifacts/risk-plans/&lt;id&gt;.md）。
    /// 执行不再只是聊天气泡——产物可预览、可经产物引用通道注入下一轮，
    /// AI 据此真改文件（仍走主线确认门）。写失败返回 nil（调用方降级为仅对话留痕）。
    static func writePlanArtifact(
        project: String, version: String, record: RiskRecord, reply: String,
        baseURL: URL? = nil
    ) -> String? {
        let rel = "05-artifacts/risk-plans/\(record.id).md"
        let root = baseURL ?? PMAgentStore.versionURL(project: project, version: version)
        let dir = root.appendingPathComponent("05-artifacts/risk-plans", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let md = """
            # 执行包 · \(record.id)

            - **风险**：\(record.hypothesis)
            - **后果**：\(record.impact ?? "—")
            - **方案**：\(record.plan ?? "—")
            - **来源**：⚡ 风险台账 · 采纳落实闭环（\(record.originRef)）

            ## 执行逻辑（AI 生成）

            \(reply.isEmpty ? "（落实回合未捕获回复正文）" : reply)

            ## 完成判据

            执行项逐项落地并确认没出事 → 台账「✓ 已解除」；任一步失败 → 「✕ 没解决」重开，方案升级。
            """
            try md.write(to: dir.appendingPathComponent("\(record.id).md"), atomically: true, encoding: .utf8)
            return rel
        } catch {
            NSLog("pm_worker 执行包落盘失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 接受风险：open → accepted（风险自留，封板时带入 PRD 已知风险）。
    func accept(id: String) throws {
        guard let index = risks.firstIndex(where: { $0.id == id }) else {
            throw RiskStore.notFound(id)
        }
        guard risks[index].status == .open else {
            throw RiskStore.wrongState(id, from: risks[index].status, expect: .open)
        }
        risks[index].status = .accepted
        risks[index].resolution = "风险自留 · 封板时带入 PRD 已知风险"
        risks[index].closedAt = ISO8601.timestamp()
        try PMAgentStore.appendLine(risks[index], to: risksURL)
    }

    // MARK: - ③ 验证解除 / 重开

    /// 验证通过：mitigating → resolved（风险真的没了——方案落地且确认没出事）。
    /// 回写一条解除决策（闭环上一条待验证的采纳决策）。
    @discardableResult
    func resolve(id: String) throws -> DecisionRecord {
        guard let index = risks.firstIndex(where: { $0.id == id }) else {
            throw RiskStore.notFound(id)
        }
        guard risks[index].status == .mitigating else {
            throw RiskStore.wrongState(id, from: risks[index].status, expect: .mitigating)
        }
        var record = risks[index]
        record.status = .resolved
        let decision = Self.resolutionDecision(for: record)
        record.resolution = "决策日志 \(decision.id)"
        record.closedAt = ISO8601.timestamp()
        try PMAgentStore.appendLine(record, to: risksURL)
        try PMAgentStore.appendLine(DecisionLogEntry.decision(decision), to: decisionsURL)
        risks[index] = record
        return decision
    }

    /// 没解决：mitigating → open（重开回待处理，方案需升级；留痕「验证未过」）。
    func reopen(id: String) throws {
        guard let index = risks.firstIndex(where: { $0.id == id }) else {
            throw RiskStore.notFound(id)
        }
        guard risks[index].status == .mitigating else {
            throw RiskStore.wrongState(id, from: risks[index].status, expect: .mitigating)
        }
        risks[index].status = .open
        risks[index].resolution = "验证未过 · 已重开（方案需升级）"
        risks[index].closedAt = nil
        try PMAgentStore.appendLine(risks[index], to: risksURL)
    }

    // MARK: - 状态机事件结算（风险炸了：上游产物重做撞上未处理风险）

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
                        actual: note ?? Self.describe(trigger),
                        // 结算时刻：决策档案按天归组用（历史行无此字段，回退文件序归日）
                        createdAt: now
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

    // MARK: - ④ 封板兜底（每条风险有始有终）

    /// 未闭合（open + mitigating）统一 accepted 自留——带入 PRD 已知风险章节；
    /// resolved / triggered 不动（已闭合）。
    func settleAllForRelease() throws {
        let now = ISO8601.timestamp()
        for index in risks.indices where risks[index].isActive {
            risks[index].status = .accepted
            risks[index].resolution = "封板收尾 · 风险自留（带入 PRD 已知风险）"
            risks[index].closedAt = now
            try PMAgentStore.appendLine(risks[index], to: risksURL)
        }
    }

    // MARK: - Private

    /// 采纳决策（决策日志五要素；toBeVerified=true，解除时补闭环决策）。
    /// evidence 非空 = 采纳落实闭环：决策带实施证据指针（生成回合的对话留痕）。
    private static func mitigationDecision(
        for record: RiskRecord, evidence: String? = nil
    ) -> DecisionRecord {
        var why = "风险：\(record.hypothesis)"
        if let impact = record.impact, !impact.isEmpty { why += "（后果：\(impact)）" }
        return DecisionRecord(
            version: record.version,
            decision: "【风险应对】\(record.plan ?? "挂上应对方案，等验证")",
            why: why,
            rejectedAlternatives: [],
            confidence: 1.0,
            toBeVerified: true,
            evidence: evidence
        )
    }

    /// 解除决策（闭环：验证通过，方案有效）。
    private static func resolutionDecision(for record: RiskRecord) -> DecisionRecord {
        DecisionRecord(
            version: record.version,
            decision: "【风险解除】\(record.hypothesis)——方案验证通过",
            why: "方案「\(record.plan ?? "见风险条目")」落地后确认风险未发生",
            confidence: 1.0,
            toBeVerified: false
        )
    }

    private static func notFound(_ id: String) -> NSError {
        NSError(
            domain: "RiskStore", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "风险不存在：\(id)"]
        )
    }

    private static func wrongState(
        _ id: String, from status: RiskRecord.Status, expect: RiskRecord.Status
    ) -> NSError {
        NSError(
            domain: "RiskStore", code: 4,
            userInfo: [NSLocalizedDescriptionKey:
                "风险 \(id) 当前状态为「\(RiskStatusPresentation.text(status))」，"
                    + "该操作要求「\(RiskStatusPresentation.text(expect))」"]
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
