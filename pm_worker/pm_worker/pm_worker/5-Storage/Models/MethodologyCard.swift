//
//  MethodologyCard.swift
//  pm_worker
//
//  方法论卡片模型（design.md §5.2）：「怎么做事」，跨项目直接用不降级；
//  实战注记 append-only、只增不覆盖——与记忆层「覆盖语义」的本质区别。
//

import Foundation

nonisolated struct MethodologyCard: Codable, Equatable {
    /// id、来源（methodology | manual）、出处、项目归属（空 = 全局）
    var id: String
    var sourceType: String
    var sourceRef: String
    /// 空 = 全局；方法论卡跨项目直接用，不降级
    var project: String?
    var confidence: Double
    /// 冲突消解链：方法论被实质改良时旧卡让位（非日常覆盖）
    var supersededBy: String?
    var created: String
    /// 正文：方法论定义（官方定义谁都有）
    var content: String
    /// 实战注记（append-only · 只增不覆盖——越用越厚）
    var annotations: [Annotation]

    struct Annotation: Codable, Equatable {
        var date: String
        /// 项目出处
        var project: String
        var note: String
    }

    init(
        id: String = IDGenerator.next("kp"),
        sourceType: String = "methodology",
        sourceRef: String = "",
        project: String? = nil,
        confidence: Double = 1.0,
        supersededBy: String? = nil,
        created: String = ISO8601.dayString(),
        content: String = "",
        annotations: [Annotation] = []
    ) {
        self.id = id
        self.sourceType = sourceType
        self.sourceRef = sourceRef
        self.project = project
        self.confidence = confidence
        self.supersededBy = supersededBy
        self.created = created
        self.content = content
        self.annotations = annotations
    }

    /// 追加一条实战注记（只增不覆盖）。
    mutating func appendAnnotation(project: String, note: String) {
        annotations.append(
            Annotation(date: ISO8601.dayString(), project: project, note: note)
        )
    }
}
