//
//  PipelineEngine.swift
//  pm_worker
//
//  状态机骨架 + 运行态持久化（Task 2.5，design.md §6.1）：
//  CLARIFY → STRUCTURE →【确认闸口】→ PROTOTYPE →【确认闸口】→ PRD。
//  阶段从磁盘产物推导（文件是唯一事实源）：clarification.md / confirmed.json
//  是闸口依据；澄清轮次等运行态存 pipeline_runs（SQLite，重启不丢）。
//

import Foundation
import Combine
import GRDB

@MainActor
final class PipelineEngine: ObservableObject {
    @Published private(set) var stage: PipelineRun.Stage = .clarify
    @Published private(set) var structureConfirmed = false
    @Published private(set) var prototypeConfirmed = false
    @Published private(set) var clarifyRounds = 0
    /// PRD 相对已确认上游过期（04-prd/stale.json 存在；上游重确认后、PRD 重写前）。
    @Published private(set) var prdStale = false
    /// 累计自评审修正数（pipeline_runs.self_review_fixes，E16 失效告警依据）。
    private(set) var selfReviewFixes = 0
    /// 连续零修正轮数（运行态，达 3 触发失效告警）。
    private var zeroFixStreak = 0

    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避：显式退出隔离销毁路径
    /// （本实例会在 switchContext 中被替换销毁，默认隔离 deinit 会触发 malloc 崩溃）。
    nonisolated deinit {}

    let project: String
    let version: String
    private let database: AppDatabase?
    private var runId: String?

    /// 澄清轮次上限（design.md §6.2 ①：最多 5 轮）。
    static let clarifyRoundLimit = 5

    init(project: String, version: String, database: AppDatabase?) {
        self.project = project
        self.version = version
        self.database = database
        syncFromDisk()
        loadOrCreateRun()
    }

    // MARK: - 磁盘推导（闸口状态以文件为准）

    /// 从版本目录产物推导当前阶段：
    /// 无 clarification.md → clarify；有 → structure（未过闸口）；
    /// 02-structure/confirmed.json 存在 → prototype；03-prototypes/confirmed.json 存在 → prd。
    nonisolated static func deriveStage(project: String, version: String) -> PipelineRun.Stage {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        let has = { (rel: String) in fm.fileExists(atPath: dir.appendingPathComponent(rel).path) }
        if has("03-prototypes/confirmed.json") { return .prd }
        if has("02-structure/confirmed.json") { return .prototype }
        if has("01-requirements/clarification.md") { return .structure }
        return .clarify
    }

    /// 重新对账磁盘（外部改动 / Finder 手改 .md 后调用）。
    func syncFromDisk() {
        stage = Self.deriveStage(project: project, version: version)
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        structureConfirmed = fm.fileExists(
            atPath: dir.appendingPathComponent("02-structure/confirmed.json").path
        )
        prototypeConfirmed = fm.fileExists(
            atPath: dir.appendingPathComponent("03-prototypes/confirmed.json").path
        )
        prdStale = fm.fileExists(
            atPath: dir.appendingPathComponent("04-prd/stale.json").path
        )
    }

    // MARK: - pipeline_runs 持久化（SQLite）

    /// pipeline_runs 表行。
    private struct RunRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "pipeline_runs"
        var id: String
        var project_id: String
        var version: String
        var current_stage: String
        var structure_confirmed: Bool
        var prototype_confirmed: Bool
        var status: String
        var self_review_fixes: Int
        var radar_risk_hits: Int
        var clarify_rounds: Int
        var error: String?
        var updated_at: String
    }

    private func loadOrCreateRun() {
        guard let database else { return }
        do {
            if let row = try database.dbQueue.read({ db in
                try RunRow
                    .filter(Column("project_id") == project && Column("version") == version)
                    .order(Column("updated_at").desc)
                    .fetchOne(db)
            }) {
                runId = row.id
                clarifyRounds = row.clarify_rounds
                selfReviewFixes = row.self_review_fixes
                // 磁盘产物优先于库里记录（索引只是加速，事实源在文件）
                if row.current_stage != stage.rawValue
                    || row.structure_confirmed != structureConfirmed
                    || row.prototype_confirmed != prototypeConfirmed {
                    persist()
                }
            } else {
                let runId = IDGenerator.next("run")
                self.runId = runId
                try database.dbQueue.write { db in
                    try RunRow(
                        id: runId, project_id: project, version: version,
                        current_stage: stage.rawValue,
                        structure_confirmed: structureConfirmed,
                        prototype_confirmed: prototypeConfirmed,
                        status: "running", self_review_fixes: 0, radar_risk_hits: 0,
                        clarify_rounds: 0, error: nil,
                        updated_at: ISO8601.timestamp()
                    ).insert(db)
                }
            }
        } catch {
            // 运行态持久化失败不阻塞流水线（轮次退化为内存态）
        }
    }

    private func persist() {
        guard let database, let runId else { return }
        let row = RunRow(
            id: runId, project_id: project, version: version,
            current_stage: stage.rawValue,
            structure_confirmed: structureConfirmed,
            prototype_confirmed: prototypeConfirmed,
            status: "running", self_review_fixes: selfReviewFixes, radar_risk_hits: 0,
            clarify_rounds: clarifyRounds, error: nil,
            updated_at: ISO8601.timestamp()
        )
        try? database.dbQueue.write { db in
            try row.update(db)
        }
    }

    // MARK: - 自评审审计（Task 3.1：E16 连续零修正失效告警）

    /// 雷达入账：fixedCount > 0 记修正数并清零连击；否则连击 +1。
    /// - Returns: 恰好达到连续 3 轮零修正时 true（App 侧发告警，只触发一次）。
    func recordRadar(fixedCount: Int) -> Bool {
        if fixedCount > 0 {
            selfReviewFixes += fixedCount
            zeroFixStreak = 0
        } else {
            zeroFixStreak += 1
        }
        persist()
        log(.radarRecorded, detail: "自评审修正 \(fixedCount) 项（累计 \(selfReviewFixes)）")
        return zeroFixStreak == 3
    }

    // MARK: - 事件

    /// 事件流旁路（append-only events.jsonl，审计 / 崩溃恢复底座）；失败静默不阻塞。
    private func log(
        _ kind: PipelineEvent.Kind, detail: String, reason: String? = nil
    ) {
        PipelineEventLog.append(
            kind: kind, stage: stage.rawValue, detail: detail, reason: reason,
            project: project, version: version
        )
    }

    /// 澄清一轮完成（assistant 提问一次计一轮）。
    func bumpClarifyRound() {
        clarifyRounds += 1
        persist()
        log(.clarifyRound, detail: "澄清第 \(clarifyRounds) 轮完成")
    }

    /// 5 轮耗尽？→ 强制收束（缺失项入 open_questions，不阻塞流水线）。
    var clarifyExhausted: Bool { clarifyRounds >= Self.clarifyRoundLimit }

    /// 澄清要点表落盘后的阶段推进（①→②）。
    func advanceFromClarify() {
        stage = .structure
        persist()
        log(.stageAdvance, detail: "① 澄清 → ② 结构（澄清要点表已确认）")
    }

    /// ② 确认闸口：写 confirmed.json（闸口事实源）。
    func confirmStructure() throws {
        try writeConfirmRecord(stage: "structure", rel: "02-structure/confirmed.json")
        structureConfirmed = true
        stage = .prototype
        persist()
        log(.stageConfirm, detail: "② 结构产物确认，进入 ③ 原型")
    }

    /// ③ 确认闸口。
    func confirmPrototype() throws {
        try writeConfirmRecord(stage: "prototype", rel: "03-prototypes/confirmed.json")
        prototypeConfirmed = true
        stage = .prd
        persist()
        log(.stageConfirm, detail: "③ 原型确认，进入 ④ PRD")
    }

    private func writeConfirmRecord(stage name: String, rel: String) throws {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(rel)
        struct ConfirmRecord: Codable {
            var stage: String
            var confirmedAt: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ConfirmRecord(stage: name, confirmedAt: ISO8601.timestamp()))
        try PMAgentStore.writeVerified(String(decoding: data, as: UTF8.self), to: url)
    }

    /// 对话式改图（② 回退）：confirmed.json 删除 → 回到 structure 待确认。
    /// 触发信号 structure_regen（M3 风险结算挂载点）。
    func invalidateStructure() {
        removeIfExists("02-structure/confirmed.json")
        removeIfExists("03-prototypes/confirmed.json")  // 过期传播：原型相应失效
        structureConfirmed = false
        prototypeConfirmed = false
        stage = .structure
        // 过期传播分级标记：结构改 → 全部下游（原型 + PRD）失效
        markPRDStale(reason: "structure_regen", scope: "全部")
        persist()
        log(.stageInvalidate, detail: "② 回退：结构重生成（原型确认连带失效）", reason: "structure_regen")
    }

    /// ③ 回退：原型重做（反馈驱动），PRD 相应过期（M3 落地）。
    /// 触发信号 prototype_regen。
    func invalidatePrototype() {
        removeIfExists("03-prototypes/confirmed.json")
        prototypeConfirmed = false
        stage = .prototype
        // 过期传播分级标记：原型改 → 局部下游（仅 PRD）失效
        markPRDStale(reason: "prototype_regen", scope: "局部")
        persist()
        log(.stageInvalidate, detail: "③ 回退：原型重做", reason: "prototype_regen")
    }

    /// PRD 重写完成后清除过期标记（App 在 writePRDArtifact 成功后调用）。
    func clearPRDStale() {
        let wasStale = prdStale
        removeIfExists("04-prd/stale.json")
        prdStale = false
        if wasStale {
            log(.prdStaleCleared, detail: "PRD 过期标记清除（重写完成）")
        }
    }

    /// 过期分级标记：仅当 PRD 已存在时写 04-prd/stale.json（不存在则无下游可标记）。
    private func markPRDStale(reason: String, scope: String) {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("04-prd/prd-v1.md").path) else {
            return
        }
        struct StaleRecord: Codable {
            var reason: String
            var scope: String
            var markedAt: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(
            StaleRecord(reason: reason, scope: scope, markedAt: ISO8601.timestamp())
        ) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: dir.appendingPathComponent("04-prd/stale.json")
            )
        }
        prdStale = true
        log(.prdStaleMarked, detail: "PRD 过期标记（\(scope)下游失效）", reason: reason)
    }

    private func removeIfExists(_ rel: String) {
        let url = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 闸口校验（E17/E17a）

    /// ③ 原型生成前置：② 已确认（confirmed.json 存在）。
    var canGeneratePrototype: Bool {
        stage == .prototype && structureConfirmed
    }

    /// ④ PRD 生成前置：③ 已确认。
    var canGeneratePRD: Bool {
        stage == .prd && prototypeConfirmed
    }
}
