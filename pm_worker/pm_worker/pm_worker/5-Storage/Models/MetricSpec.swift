//
//  MetricSpec.swift
//  pm_worker
//
//  04-prd/metric-specs.jsonl 的 Codable 模型（append-only，机读侧）。
//  只存「这个数怎么算」的口径定义，不存任何数值——数值的唯一事实源是 PRD 4.2 表
//  （AGENTS.md 衍生品不留副本：多一份数字副本就会多一处腐烂）。
//  status 三态同时是第二圈 C 环（结果对账）的准入门：口径不齐的数字不可参与对账。
//

import Foundation

/// 口径确认状态。
nonisolated enum MetricSpecStatus: String, Codable {
    /// 用户明确给出口径——可参与结果对账
    case confirmed
    /// Agent 按假设起草并标注了假设——尚未过默认项卡确认
    case assumed
    /// 口径缺失或只有部分——留在待定问题清单
    case pending

    /// 面向用户 / 评审的可读标签（jsonl 存 rawValue，展示走这里）。
    var label: String {
        switch self {
        case .confirmed: return "已确认"
        case .assumed: return "按假设起草·待确认"
        case .pending: return "口径待补"
        }
    }
}

/// 一条指标的口径定义（分子 / 分母 / 时间窗为核心三项，缺任一项即不可对账）。
/// 落点见 `ArtifactPath.metricSpecs`。
nonisolated struct MetricSpec: Codable, Equatable {

    var id: String
    /// 指标名，与 PRD 4.2 表首列同字面；也是 last-wins 去重键与对账匹配键
    var name: String
    /// 数据从哪来（哪个系统 / 表 / 文件 / 人工统计）
    var dataSource: String?
    /// 分子：统计什么、怎么计数
    var numerator: String?
    /// 分母
    var denominator: String?
    /// 去重规则与统计时间窗
    var window: String?
    /// 排除条件（哪些样本不计入）
    var exclusions: String?
    var status: MetricSpecStatus
    /// status = assumed 时说明假设了什么，让用户一眼看出该改哪里
    var assumptionNote: String?
    var createdAt: String
    var updatedAt: String

    init(
        id: String = IDGenerator.next("ms"),
        name: String,
        dataSource: String? = nil,
        numerator: String? = nil,
        denominator: String? = nil,
        window: String? = nil,
        exclusions: String? = nil,
        status: MetricSpecStatus = .pending,
        assumptionNote: String? = nil,
        createdAt: String = ISO8601.timestamp(),
        updatedAt: String = ISO8601.timestamp()
    ) {
        self.id = id
        self.name = name
        self.dataSource = dataSource
        self.numerator = numerator
        self.denominator = denominator
        self.window = window
        self.exclusions = exclusions
        self.status = status
        self.assumptionNote = assumptionNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 归一化匹配键：转小写 + 删尽空白（口径同 `ArtifactParser.normalizedText`）。
    /// 中文指标名的重播微差主要是插一个空格（「次日 留存率」），折叠而非删除空白
    /// 会让同一指标在 jsonl 里并列两条，last-wins 失效。
    var matchKey: String { MetricSpec.normalizedKey(name) }

    static func normalizedKey(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined()
    }

    /// 核心三项（分子 / 分母 / 时间窗）是否齐备。
    var hasCoreSpec: Bool {
        [numerator, denominator, window].allSatisfy { filled($0) }
    }

    /// 可否参与结果对账：口径齐备且已确认。
    var reconcilable: Bool { status == .confirmed && hasCoreSpec }

    /// 缺失字段名（待定问题清单与卡片副标题文案用），按口径阅读顺序排列。
    var missingFields: [String] {
        var missing: [String] = []
        if !filled(dataSource) { missing.append("数据来源") }
        if !filled(numerator) { missing.append("分子") }
        if !filled(denominator) { missing.append("分母") }
        if !filled(window) { missing.append("时间窗") }
        return missing
    }

    private func filled(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 容错解码（模型产物的现实形状）

    /// 合成解码不认 init 默认值：模型不写 id / 时间戳、把 status 写成中文、
    /// 空串当缺项，都会让整批口径解码失败而静默丢弃。逐键 decodeIfPresent +
    /// 兜底，是唯一能让「一次生成一批」成立的做法。
    private enum CodingKeys: String, CodingKey {
        case id, name, dataSource, numerator, denominator, window, exclusions
        case status, assumptionNote, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        self.id = text(.id) ?? IDGenerator.next("ms")
        self.name = text(.name) ?? ""
        self.dataSource = text(.dataSource)
        self.numerator = text(.numerator)
        self.denominator = text(.denominator)
        self.window = text(.window)
        self.exclusions = text(.exclusions)
        self.assumptionNote = text(.assumptionNote)
        let stamp = ISO8601.timestamp()
        self.createdAt = text(.createdAt) ?? stamp
        self.updatedAt = text(.updatedAt) ?? stamp
        // status 缺失或写了中文时推导：口径齐 → assumed（起草态，须用户确认），
        // 口径不齐 → pending。任何路径都不会自动升成 confirmed。
        switch MetricSpecStatus(raw: text(.status)) {
        case .some(let value): self.status = value
        case .none:
            let corePresent = [numerator, denominator, window].allSatisfy { $0 != nil }
            self.status = corePresent ? .assumed : .pending
        }
    }
}

nonisolated extension MetricSpecStatus {
    /// 宽松解析：认 rawValue（大小写不敏感）与常见中文写法；认不出返回 nil 交推导。
    init?(raw: String?) {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "confirmed", "已确认", "用户确认": self = .confirmed
        case "assumed", "假设", "按假设起草", "待确认": self = .assumed
        case "pending", "待定", "待补", "缺失": self = .pending
        default: return nil
        }
    }
}
