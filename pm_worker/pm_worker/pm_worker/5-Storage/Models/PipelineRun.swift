//
//  PipelineRun.swift
//  pm_worker
//
//  流水线运行态模型（pipeline_runs，design.md §5.3）：
//  重启不丢，退出 App 再打开恢复到中断前。
//

import Foundation

struct PipelineRun: Codable, Equatable {
    enum Stage: String, Codable {
        case clarify, structure, prototype, prd
    }

    enum Status: String, Codable {
        case running, suspended, failed, done
    }

    var id: String
    var projectId: String
    var version: String
    var currentStage: Stage
    /// ② 环确认闸口（未确认不得进 ③）
    var structureConfirmed: Bool
    /// ③ 环确认闸口（未确认不得进 ④）
    var prototypeConfirmed: Bool
    var status: Status
    /// 自评审发现并修正的问题数（连续为 0 触发告警）
    var selfReviewFixes: Int
    /// 💀 触发信号被结算的次数（Goodhart 防护：盯事后结算）
    var radarRiskHits: Int
    /// 已用澄清轮次（上限 5）
    var clarifyRounds: Int
    var error: String?
    var updatedAt: String

    init(
        id: String = IDGenerator.next("run"),
        projectId: String,
        version: String,
        currentStage: Stage = .clarify,
        structureConfirmed: Bool = false,
        prototypeConfirmed: Bool = false,
        status: Status = .running,
        selfReviewFixes: Int = 0,
        radarRiskHits: Int = 0,
        clarifyRounds: Int = 0,
        error: String? = nil,
        updatedAt: String = ISO8601.timestamp()
    ) {
        self.id = id
        self.projectId = projectId
        self.version = version
        self.currentStage = currentStage
        self.structureConfirmed = structureConfirmed
        self.prototypeConfirmed = prototypeConfirmed
        self.status = status
        self.selfReviewFixes = selfReviewFixes
        self.radarRiskHits = radarRiskHits
        self.clarifyRounds = clarifyRounds
        self.error = error
        self.updatedAt = updatedAt
    }
}
