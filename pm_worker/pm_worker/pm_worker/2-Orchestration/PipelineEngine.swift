//
//  PipelineEngine.swift
//  pm_worker
//
//  状态机骨架 + 运行态持久化（Task 2.5，design.md §6.1）：
//  CLARIFY → STRUCTURE →【确认闸口】→ PROTOTYPE →【确认闸口】→ PRD。
//  阶段从磁盘产物推导（文件是唯一事实源）：澄清要点表 / confirmed.json
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
    /// ② 已按路径选择跳过（skipped.json 在盘；闭环 = 确认 ∨ 跳过）。
    @Published private(set) var structureSkipped = false
    /// ③ 已按路径选择跳过。
    @Published private(set) var prototypeSkipped = false
    /// 「到原型为止」停驻态（③ 已确认 + stopped-here.json，不自动进 ④ 出 PRD）。
    @Published private(set) var stoppedHere = false
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

    /// 从版本目录产物推导当前阶段（阶段闭环三态：未达 / 已确认 confirmed.json /
    /// 已跳过 skipped.json——闭环 = 确认 ∨ 跳过，2026-09-17 路径选择）：
    /// 无澄清要点表 → clarify；有 → structure（未过闸口）；
    /// 有表但处于增补澄清（01-requirements/amend.json，新功能诉求从下游回①）→ clarify；
    /// 02-structure/confirmed.json ∨ skipped.json 存在 → prototype；
    /// 03-prototypes/confirmed.json ∨ skipped.json 存在 → prd。
    nonisolated static func deriveStage(project: String, version: String) -> PipelineRun.Stage {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        let has = { (rel: String) in fm.fileExists(atPath: dir.appendingPathComponent(rel).path) }
        if has("03-prototypes/confirmed.json") || has("03-prototypes/skipped.json") { return .prd }
        if has("02-structure/confirmed.json") || has("02-structure/skipped.json") { return .prototype }
        if has(ArtifactPath.clarification) {
            return has(ArtifactPath.clarifyAmend) ? .clarify : .structure
        }
        return .clarify
    }

    /// 跳过标记相对路径（与 confirmed.json 同级同构）。
    nonisolated static func skipMarker(for stage: PipelineRun.Stage) -> String? {
        switch stage {
        case .structure: return "02-structure/skipped.json"
        case .prototype: return "03-prototypes/skipped.json"
        default: return nil  // ① 是必经起点；④ 由 PRD 落盘闭环
        }
    }

    /// 「到原型为止」停驻标记（③ 已确认但不出 PRD）。
    nonisolated static let stopHereMarker = "03-prototypes/stopped-here.json"

    /// 指定阶段的跳过标记是否在盘（供 UI / 闸口判定消费）。
    nonisolated static func isSkipped(
        _ stage: PipelineRun.Stage, project: String, version: String
    ) -> Bool {
        guard let rel = skipMarker(for: stage) else { return false }
        return FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(rel).path
        )
    }

    /// 重新对账磁盘（外部改动 / Finder 手改 .md 后调用）。
    func syncFromDisk() {
        stage = Self.deriveStage(project: project, version: version)
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        structureConfirmed = fm.fileExists(
            atPath: dir.appendingPathComponent("02-structure/confirmed.json").path
        )
        structureSkipped = fm.fileExists(
            atPath: dir.appendingPathComponent("02-structure/skipped.json").path
        )
        prototypeConfirmed = fm.fileExists(
            atPath: dir.appendingPathComponent("03-prototypes/confirmed.json").path
        )
        prototypeSkipped = fm.fileExists(
            atPath: dir.appendingPathComponent("03-prototypes/skipped.json").path
        )
        stoppedHere = fm.fileExists(
            atPath: dir.appendingPathComponent(Self.stopHereMarker).path
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
        _ kind: PipelineEvent.Kind, detail: String, reason: String? = nil, outcome: String? = nil
    ) {
        PipelineEventLog.append(
            kind: kind, stage: stage.rawValue, detail: detail, reason: reason,
            outcome: outcome, project: project, version: version
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

    /// 澄清要点表落盘后的阶段推进（①→…）；增补澄清收束时清增补标记。
    /// outcome：闸口确认结算（approved / approved_after_revision / fast_track），
    /// 由 AppModel 按确认形态判定（增补收束 / 快速通道指令）。
    /// skipping：路径选择要跳过的中间阶段（② / ②③），空 = 常规进 ②——
    /// 跳过阶段写 skipped.json（闭环标记），不生成产物，位置按闭环链重推导。
    func advanceFromClarify(
        outcome: String = "approved", skipping: [PipelineRun.Stage] = []
    ) {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let wasAmending = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ArtifactPath.clarifyAmend).path
        )
        removeIfExists(ArtifactPath.clarifyAmend)
        let skippedNames = skipping
            .compactMap { stageName($0) }
            .joined(separator: " · ")
        for target in skipping { writeSkipMarker(target) }
        stage = Self.deriveStage(project: project, version: version)
        persist()
        if skipping.isEmpty {
            log(.stageAdvance, detail: wasAmending
                ? "① 增补澄清收束 → ② 结构（要点表已按新功能诉求更新）"
                : "① 澄清 → ② 结构（澄清要点表已确认）", outcome: outcome)
        } else {
            log(.stageAdvance, detail: "① 澄清收束 → 跳过 \(skippedNames)（路径选择）", outcome: outcome)
            log(.stageSkip, detail: "按路径选择跳过：\(skippedNames)", reason: "route_selection")
        }
    }

    /// 阶段跳过（路径选择）：写 skipped.json + 位置重推导 + 事件。
    /// ② 闸口选「跳过原型直接出 PRD」等场景调用；① 起跳走 advanceFromClarify(skipping:)。
    func skipStage(_ target: PipelineRun.Stage, reason: String = "route_selection") {
        guard let name = stageName(target) else { return }
        writeSkipMarker(target)
        stage = Self.deriveStage(project: project, version: version)
        persist()
        log(.stageSkip, detail: "按路径选择跳过：\(name)", reason: reason)
    }

    /// 写跳过标记（skipped.json，与 AmendRecord/ConfirmRecord 同构）。
    private func writeSkipMarker(_ target: PipelineRun.Stage) {
        guard let rel = Self.skipMarker(for: target) else { return }
        struct SkipRecord: Codable {
            var reason: String
            var skippedAt: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(
            SkipRecord(reason: "route_selection", skippedAt: ISO8601.timestamp())
        ) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(rel)
            )
        }
        switch target {
        case .structure: structureSkipped = true
        case .prototype: prototypeSkipped = true
        default: break
        }
    }

    /// 阶段中文名（事件 / 系统行共用；① 必经、④ 由产物闭环，均不可跳）。
    private func stageName(_ stage: PipelineRun.Stage) -> String? {
        switch stage {
        case .clarify: return nil
        case .structure: return "② 结构"
        case .prototype: return "③ 原型"
        case .prd: return nil
        }
    }

    /// ② 确认闸口：写 confirmed.json（闸口事实源）。
    /// skippingPrototype：② 闸口选「跳过原型直接出 PRD」时置 true——③ 写跳过标记，
    /// 位置直接推到 ④（skipToPRD 路径）。
    func confirmStructure(outcome: String = "approved", skippingPrototype: Bool = false) throws {
        try writeConfirmRecord(stage: "structure", rel: "02-structure/confirmed.json")
        structureConfirmed = true
        if skippingPrototype { writeSkipMarker(.prototype) }
        stage = Self.deriveStage(project: project, version: version)
        persist()
        if skippingPrototype {
            log(.stageConfirm, detail: "② 结构产物确认，跳过 ③ 原型（路径选择）", outcome: outcome)
            log(.stageSkip, detail: "按路径选择跳过：③ 原型", reason: "route_selection")
        } else {
            log(.stageConfirm, detail: "② 结构产物确认，进入 ③ 原型", outcome: outcome)
        }
    }

    /// ③ 确认闸口。
    func confirmPrototype(outcome: String = "approved") throws {
        try writeConfirmRecord(stage: "prototype", rel: "03-prototypes/confirmed.json")
        prototypeConfirmed = true
        stage = .prd
        persist()
        log(.stageConfirm, detail: "③ 原型确认，进入 ④ PRD", outcome: outcome)
    }

    /// ③ 确认闸口（「到原型为止」变体）：原型确认 + 写停驻标记，不进 ④ 生成 PRD。
    /// 位置照常推导（confirmed.json 在 → .prd），stopped-here.json 供 App 层
    /// 跳过自动 PRD 生成；后续说「出 PRD」随时可续出（用户自由，不锁路径）。
    func confirmPrototypeStopHere(outcome: String = "approved") throws {
        try writeConfirmRecord(stage: "prototype", rel: "03-prototypes/confirmed.json")
        prototypeConfirmed = true
        struct StopRecord: Codable {
            var stoppedAt: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(
            StopRecord(stoppedAt: ISO8601.timestamp())
        ) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(Self.stopHereMarker)
            )
        }
        stoppedHere = true
        stage = .prd
        persist()
        log(.stageConfirm, detail: "③ 原型确认，本版到原型为止（不出 PRD）", outcome: outcome)
    }

    /// 清停驻标记（续出 PRD 时调用：不再停驻）。
    func clearStopHere() {
        guard stoppedHere else { return }
        removeIfExists(Self.stopHereMarker)
        stoppedHere = false
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
    /// 跳过感知（补课同路径）：skipped.json 一并删除——删标记即补课，
    /// deriveStage 自然回到该阶段；下游闭环（③ 确认/跳过）同步失效。
    /// 触发信号 structure_regen（M3 风险结算挂载点）。
    func invalidateStructure() {
        removeIfExists("02-structure/confirmed.json")
        removeIfExists("02-structure/skipped.json")   // 补课：删跳过标记
        removeIfExists("03-prototypes/confirmed.json")  // 过期传播：原型相应失效
        removeIfExists("03-prototypes/skipped.json")    // 路径一并重决
        structureConfirmed = false
        structureSkipped = false
        prototypeConfirmed = false
        prototypeSkipped = false
        stage = .structure
        // 过期传播分级标记：结构改 → 全部下游（原型 + PRD）失效
        markPRDStale(reason: "structure_regen", scope: "全部")
        persist()
        log(.stageInvalidate, detail: "② 回退：结构重生成（原型确认连带失效）", reason: "structure_regen")
    }

    /// ③ 回退：原型重做（反馈驱动），PRD 相应过期（M3 落地）。
    /// 跳过感知（补课同路径）：skipped.json 删除——direct_prd 版本补原型即走此路。
    /// 触发信号 prototype_regen。
    func invalidatePrototype() {
        removeIfExists("03-prototypes/confirmed.json")
        removeIfExists("03-prototypes/skipped.json")  // 补课：删跳过标记
        removeIfExists(Self.stopHereMarker)             // 停驻态随之失效
        prototypeConfirmed = false
        prototypeSkipped = false
        stoppedHere = false
        stage = .prototype
        // 过期传播分级标记：原型改 → 局部下游（仅 PRD）失效
        markPRDStale(reason: "prototype_regen", scope: "局部")
        persist()
        log(.stageInvalidate, detail: "③ 回退：原型重做", reason: "prototype_regen")
    }

    /// 增补澄清进行中（01-requirements/amend.json 存在）。
    var isAmendingClarify: Bool {
        FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(ArtifactPath.clarifyAmend).path
        )
    }

    /// ① 增补澄清回退（新功能/范围变化诉求从 ②③④ 回到澄清）：
    /// 写增补标记（deriveStage 据此推导回①）+ 清下游确认 + PRD 过期传播。
    /// 要点表与下游产物文件**保留**——表是增补基底，结构/原型/PRD 是后续增量修订基底。
    /// 触发信号 clarify_backtrack。轮次重置（新一轮澄清周期）。
    func invalidateClarify() {
        struct AmendRecord: Codable {
            var reason: String
            var markedAt: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(
            AmendRecord(reason: "clarify_backtrack", markedAt: ISO8601.timestamp())
        ) {
            try? PMAgentStore.writeVerified(
                String(decoding: data, as: UTF8.self),
                to: PMAgentStore.versionURL(project: project, version: version)
                    .appendingPathComponent(ArtifactPath.clarifyAmend)
            )
        }
        // 过期传播：澄清重开 → 下游确认/跳过全部失效（产物文件保留作修订基底；
        // 跳过标记一并清除——回 ① 即重选路径，下游闭环方式重新决定）
        removeIfExists("02-structure/confirmed.json")
        removeIfExists("02-structure/skipped.json")
        removeIfExists("03-prototypes/confirmed.json")
        removeIfExists("03-prototypes/skipped.json")
        removeIfExists(Self.stopHereMarker)
        structureConfirmed = false
        structureSkipped = false
        prototypeConfirmed = false
        prototypeSkipped = false
        stoppedHere = false
        clarifyRounds = 0
        stage = .clarify
        markPRDStale(reason: "clarify_backtrack", scope: "全部")
        persist()
        log(.stageInvalidate, detail: "① 增补澄清：新功能诉求回①（要点表保留作基底）",
            reason: "clarify_backtrack")
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

    /// 模板升级失效检查（2026-09-17 钦定：产出必须按当前模板版本，存量不豁免）：
    /// PRD 已存在但版本戳缺失（prd-meta.json 不存在 = 旧模板产物）或落后于
    /// currentVersion → 标过期（reason template_upgrade，scope 全部）。
    /// 已有过期标记时不覆盖（保留首次失效原因，重生成路径不变）。
    /// App 在 pipeline 装配（init / switchContext）后调用。
    func markPRDStaleForTemplateUpgradeIfNeeded(currentVersion: String) {
        guard !prdStale else { return }
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(ArtifactPath.prd).path) else {
            return
        }
        struct PRDMeta: Codable {
            var tier: String
            var templateVersion: String
            var writtenAt: String
        }
        let meta = (try? Data(contentsOf: dir.appendingPathComponent(ArtifactPath.prdMeta)))
            .flatMap { try? JSONDecoder().decode(PRDMeta.self, from: $0) }
        guard meta?.templateVersion != currentVersion else { return }
        markPRDStale(reason: "template_upgrade", scope: "全部")
    }

    /// 过期分级标记：仅当 PRD 已存在时写 04-prd/stale.json（不存在则无下游可标记）。
    private func markPRDStale(reason: String, scope: String) {
        let dir = PMAgentStore.versionURL(project: project, version: version)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(ArtifactPath.prd).path) else {
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

    /// ③ 原型生成前置：② 已闭环（确认 ∨ 跳过——跳过 = 无结构基底，AI 按要点表直接设计）。
    var canGeneratePrototype: Bool {
        stage == .prototype && (structureConfirmed || structureSkipped)
    }

    /// ④ PRD 生成前置：③ 已闭环（确认 ∨ 跳过——跳过 = 精简路径，基于要点表/结构直接撰写）。
    var canGeneratePRD: Bool {
        stage == .prd && (prototypeConfirmed || prototypeSkipped)
    }
}
