//
//  RunPatternLearner.swift
//  pm_worker
//
//  跨会话策略学习：从运行事实（pipeline_runs / events.jsonl / risks 索引）
//  提取确定性统计——澄清深度倾向 / 机器门失败率 / 风险跨版本复发——
//  以「运行校准」注入新会话的阶段 prompt 尾条（假设态，不作硬约束）。
//
//  设计立场（design.md §4 刻意设计 9）：能从既有事实算出来的不交给 LLM——
//  统计提取全纯函数（brief 入参为纯数据投影，单测直测）；防噪声内建
//  （样本下限 + 触发阈值，正常范围不打扰）；学习是旁路，任何采集失败
//  静默返回空，永不阻塞流水线。
//

import Foundation
import GRDB

nonisolated enum RunPatternLearner {

    // MARK: - 输入投影（纯数据，单测直测）

    struct RunStat: Equatable {
        var project: String
        var version: String
        var clarifyRounds: Int
    }

    struct GateEventHit: Equatable {
        var stage: String        // PipelineRun.Stage.rawValue
        var passed: Bool
    }

    struct RiskHit: Equatable {
        var hypothesis: String
        var version: String
    }

    // MARK: - 阈值（防噪声：正常范围不打扰，宁缺毋滥）

    /// 项目级历史样本下限（历史版本数，少于 → 回退全局池）。
    static let projectSampleFloor = 2
    /// 全局样本下限（少于 → 不注入任何澄清统计）。
    static let globalSampleFloor = 3
    /// 澄清平均轮次触发阈值（≥ 视为「历史澄清偏深」）。
    static let clarifyRoundTrigger = 3.5
    /// 轮次耗尽占比触发阈值（触及 5 轮上限的版本占比）。
    static let clarifyExhaustedRatio = 1.0 / 3.0
    /// 机器门评审样本下限（该阶段累计评审次数）。
    static let gateSampleFloor = 3
    /// 机器门失败率触发阈值。
    static let gateFailRatio = 0.4
    /// 风险跨版本复现版本数下限。
    static let riskRecurFloor = 2
    /// hypothesis 归一化分组的最短长度（过短关键词分组易误并）。
    static let minHypothesisLength = 8
    /// 注入行数上限（校准是调味料，不能反客为主）。
    static let maxLines = 3

    // MARK: - 纯函数主入口

    /// 产出运行校准注入行（≤ maxLines；无值得说的返回空数组——不注入）。
    /// - Parameters:
    ///   - stage: PipelineRun.Stage.rawValue（仅四个主线阶段产出统计行）
    ///   - currentVersion: 当前版本（澄清统计排除——未跑完的版本不算历史）
    static func brief(
        stage: String,
        project: String,
        currentVersion: String,
        runs: [RunStat],
        gateEvents: [GateEventHit],
        risks: [RiskHit]
    ) -> [String] {
        var lines: [String] = []
        switch stage {
        case "clarify":
            lines.append(contentsOf: clarifyLine(project: project, currentVersion: currentVersion, runs: runs))
        case "structure", "prototype", "prd":
            lines.append(contentsOf: gateLine(stage: stage, gateEvents: gateEvents))
        default:
            break
        }
        lines.append(contentsOf: recurringRiskLine(risks: risks))
        return Array(lines.prefix(maxLines))
    }

    /// 澄清深度倾向：项目历史（≥ projectSampleFloor 版本）优先，
    /// 不足回退全局池（≥ globalSampleFloor）；平均轮次深或耗尽占比高才提示。
    static func clarifyLine(
        project: String, currentVersion: String, runs: [RunStat]
    ) -> [String] {
        let historical = runs.filter { $0.version != currentVersion }
        let projectRuns = historical.filter { $0.project == project }
        let sample: [RunStat]
        if projectRuns.count >= projectSampleFloor {
            sample = projectRuns
        } else if historical.count >= globalSampleFloor {
            sample = historical
        } else {
            return []
        }
        let avg = Double(sample.reduce(0) { $0 + $1.clarifyRounds }) / Double(sample.count)
        let exhausted = sample.filter { $0.clarifyRounds >= 5 }.count
        guard avg >= clarifyRoundTrigger
                || Double(exhausted) / Double(sample.count) >= clarifyExhaustedRatio else {
            return []
        }
        var line = "历史 \(sample.count) 个版本澄清平均 \(String(format: "%.1f", avg)) 轮"
        if exhausted > 0 {
            line += "、\(exhausted) 次触及 5 轮上限"
        }
        line += "——信息缺口常超出直觉，倾向于一次问透而不是省轮次"
        return [line]
    }

    /// 机器门失败率（阶段维度，项目全版本聚合；样本与阈值都够才提示）。
    static func gateLine(stage: String, gateEvents: [GateEventHit]) -> [String] {
        let hits = gateEvents.filter { $0.stage == stage }
        guard hits.count >= gateSampleFloor else { return [] }
        let fails = hits.filter { !$0.passed }.count
        let ratio = Double(fails) / Double(hits.count)
        guard ratio >= gateFailRatio else { return [] }
        let percent = Int((ratio * 100).rounded())
        return ["本阶段机器门历史未过率 \(percent)%（\(fails)/\(hits.count) 次评审）——落盘前对照自检清单预查一遍，能省一轮打回"]
    }

    /// 风险跨版本复发（hypothesis 归一化分组；≥ riskRecurFloor 个不同版本
    /// 出现同一假设才提示，按复现版本数降序）。
    static func recurringRiskLine(risks: [RiskHit]) -> [String] {
        var byHypothesis: [String: Set<String>] = [:]
        for hit in risks {
            let key = hit.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count >= minHypothesisLength else { continue }
            byHypothesis[key, default: []].insert(hit.version)
        }
        let recurring = byHypothesis
            .filter { $0.value.count >= riskRecurFloor }
            .sorted { $0.value.count > $1.value.count }
            .prefix(maxLines)
        guard !recurring.isEmpty else { return [] }
        return recurring.map { key, versions in
            "风险「\(String(key.prefix(40)))」已在 \(versions.count) 个版本复现——本轮产物生成时优先核对这一假设"
        }
    }

    // MARK: - IO 采集（nonisolated；失败静默——学习是旁路，不阻塞流水线）

    /// pipeline_runs 运行统计（全表一次取，量级 = 版本数）。
    static func runStats(database: AppDatabase) -> [RunStat] {
        struct Row: Codable, FetchableRecord {
            var project_id: String
            var version: String
            var clarify_rounds: Int
        }
        let sql = "SELECT project_id, version, clarify_rounds FROM pipeline_runs"
        let rows: [Row]? = try? database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql)
        }
        guard let rows else { return [] }
        return rows.map { row in
            RunStat(project: row.project_id, version: row.version, clarifyRounds: row.clarify_rounds)
        }
    }

    /// 项目全版本机器门评审事件（events.jsonl 扫描，跨版本读取与记忆池同模式）。
    static func gateEvents(project: String) -> [GateEventHit] {
        var hits: [GateEventHit] = []
        let versions = PMAgentStore.listVersions(in: project).filter { $0 != "knowledge" }
        for version in versions {
            let events = PipelineEventLog.events(project: project, version: version)
            for event in events where event.kind == .gateEvaluated {
                hits.append(GateEventHit(stage: event.stage, passed: event.reason == "pass"))
            }
        }
        return hits
    }

    /// 项目全部已登记风险（risks 索引表；事实源 risks.jsonl 可重建）。
    static func riskHits(project: String, database: AppDatabase) -> [RiskHit] {
        struct Row: Codable, FetchableRecord {
            var hypothesis: String
            var version: String
        }
        let sql = "SELECT hypothesis, version FROM risks WHERE project_id = ?"
        let rows: [Row]? = try? database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [project])
        }
        guard let rows else { return [] }
        return rows.map { RiskHit(hypothesis: $0.hypothesis, version: $0.version) }
    }
}
