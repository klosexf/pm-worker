//
//  ChangeRecord.swift
//  pm_worker
//
//  changes.jsonl 的 Codable 模型（append-only）。
//  变更分诊层的事实源：提案卡状态、候选池、封板毕业仪式都是它的视图，
//  不另设台账。两种条目：变更提案登记（pending）与处置回写。
//

import Foundation

/// 处置结果（append-only 回写行；同一提案以最新回写行为准）。
nonisolated enum ChangeResolution: String, Codable, Equatable, CaseIterable {
    /// 纳入当前版本（执行回退 + 重生成）；池毕业「纳入后续版本」同值，note 区分。
    case adopted
    /// 放入候选池。
    case pooled
    /// 未采纳：提案卡「继续讨论」/ 池中明确放弃（note 区分）。
    case dropped
    /// 顺延（池毕业仪式：下一版本再议）。
    case deferred
}

/// 变更提案登记行（提案卡生成时写入；尚无回写行 = pending）。
nonisolated struct ChangeProposalRecord: Codable, Equatable {
    var id: String
    /// 新想法 / 诉求概述（模型从用户消息提炼，非原文照抄）。
    var idea: String
    /// 分诊分类：局部修订 | 页面流程 | 模块核心 | 目标范围 | 需验证。
    var category: String?
    /// 建议回退目标（clarify/structure/prototype）；nil = 建议仅登记不回退。
    var target: String?
    /// revise | redo（回退执行时透传 regenAfterBacktrack）。
    var mode: String?
    /// 诉求透传载荷（重生成合成指令）。
    var instruction: String?
    /// 影响清单（产物级引用，如「02-structure/核心流程图.md · 支付模块」）。
    /// 约定 target 非空时必填——无引用不得建议回退（App 侧校验，防轻描淡写）。
    var impacts: [String]?
    /// 登记时的检查点阶段（PipelineRun.Stage rawValue）。
    var checkpointStage: String
    var createdAt: String
    // MARK: 草稿预演扩展（B1，可选字段——旧行无这些键，解码兼容）
    /// 提案种类：nil = 普通变更提案；"stage_draft" = 草稿预演推进提案
    ///（产物在提案目录，合并动作 = 复制入主线 + 主线状态机推进）。
    var kind: String?
    /// 草稿预演所属会话（提案目录按它分槽：05-artifacts/proposals/<sessionId>/）。
    var draftSessionId: String?
    /// 草稿预演已推进到的阶段（PipelineRun.Stage rawValue）。
    var draftStage: String?

    var isStageDraft: Bool { kind == "stage_draft" }

    init(
        id: String = IDGenerator.next("chg"),
        idea: String,
        category: String? = nil,
        target: String? = nil,
        mode: String? = nil,
        instruction: String? = nil,
        impacts: [String]? = nil,
        checkpointStage: String,
        createdAt: String = ISO8601.timestamp(),
        kind: String? = nil,
        draftSessionId: String? = nil,
        draftStage: String? = nil
    ) {
        self.id = id
        self.idea = idea
        self.category = category
        self.target = target
        self.mode = mode
        self.instruction = instruction
        self.impacts = impacts
        self.checkpointStage = checkpointStage
        self.createdAt = createdAt
        self.kind = kind
        self.draftSessionId = draftSessionId
        self.draftStage = draftStage
    }
}

/// 处置回写行（用户在提案卡 / 候选池 / 毕业仪式做出处置时 append，不原地改）。
nonisolated struct ChangeResolutionRecord: Codable, Equatable {
    var type: String  // 固定 "resolution"
    var id: String    // 对应提案 id
    var resolution: ChangeResolution
    var note: String?
    var decidedAt: String

    init(id: String, resolution: ChangeResolution, note: String? = nil) {
        self.type = "resolution"
        self.id = id
        self.resolution = resolution
        self.note = note
        self.decidedAt = ISO8601.timestamp()
    }
}

/// changes.jsonl 单行：提案登记（无 type）或 处置回写（type == "resolution"）。
nonisolated enum ChangeLogEntry: Equatable {
    case proposal(ChangeProposalRecord)
    case resolution(ChangeResolutionRecord)
}

extension ChangeLogEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        if type == "resolution" {
            self = .resolution(try ChangeResolutionRecord(from: decoder))
        } else {
            self = .proposal(try ChangeProposalRecord(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .proposal(let record):
            try record.encode(to: encoder)
        case .resolution(let record):
            try record.encode(to: encoder)
        }
    }
}

/// 折叠视图：提案 + 最新处置（提案卡状态 / 候选池的唯一读取口径）。
nonisolated struct ChangeItem: Equatable, Identifiable {
    let proposal: ChangeProposalRecord
    /// nil = pending（尚无处置行）。
    let resolution: ChangeResolution?
    let resolutionNote: String?

    var id: String { proposal.id }
    var isPending: Bool { resolution == nil }
    var isPooled: Bool { resolution == .pooled }
}

nonisolated enum ChangeLedger {
    /// append-only 折叠：按文件序处理，同一提案的最新回写行胜出。
    static func fold(_ entries: [ChangeLogEntry]) -> [ChangeItem] {
        var order: [String] = []
        var byID: [String: ChangeProposalRecord] = [:]
        var resolved: [String: ChangeResolutionRecord] = [:]
        for entry in entries {
            switch entry {
            case .proposal(let record):
                if byID[record.id] == nil { order.append(record.id) }
                byID[record.id] = record
            case .resolution(let record):
                resolved[record.id] = record  // 后写覆盖先写
            }
        }
        return order.compactMap { id in
            guard let proposal = byID[id] else { return nil }
            let record = resolved[id]
            return ChangeItem(
                proposal: proposal,
                resolution: record?.resolution,
                resolutionNote: record?.note
            )
        }
    }

    // MARK: - 磁盘便捷读写（事实源在 changes.jsonl，可重建索引不涉此文件）

    static func url(project: String, version: String) -> URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "changes.jsonl")
    }

    static func load(project: String, version: String) -> [ChangeItem] {
        fold(PMAgentStore.readLines(ChangeLogEntry.self, from: url(project: project, version: version)))
    }

    /// append 失败静默（台账缺行只丢状态不留痕，不阻塞主流程）。
    /// 锁约定：与其他 jsonl 写入器一致持 PMAgentStore.ioLock，段内经
    /// appendLineLocked 落行（本函数无存在性检查，持锁段即单次追加，
    /// 勿在持锁段内再调会自行加锁的 appendLine）。
    static func append(_ entry: ChangeLogEntry, project: String, version: String) {
        PMAgentStore.ioLock.lock()
        defer { PMAgentStore.ioLock.unlock() }
        try? PMAgentStore.appendLineLocked(entry, to: url(project: project, version: version))
    }

    /// 提案 id → 处置结果（提案卡渲染已处置态用）。
    static func resolutionMap(of items: [ChangeItem]) -> [String: ChangeItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }
}
