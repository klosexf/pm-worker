//
//  CostTracker.swift
//  pm_worker
//
//  用量/成本统计（M5 Task 5.4）：append-only JSONL（usage.jsonl）+ 内存聚合。
//  本次会话（App 启动至今）走内存；本月/历史月走 JSONL 读侧聚合。
//  统计非关键数据：append 语义，不做 write-then-verify 重读。
//

import Foundation

/// 聚合结果（本次 / 本月通用）。
nonisolated struct Aggregation: Equatable {
    var calls = 0
    var promptTokens = 0
    var completionTokens = 0
    /// 人民币元（未知单价模型不计费，只登记进 unknownPriceModels）。
    var costCNY = 0.0
    /// 无法计价的模型名集合。
    var unknownPriceModels: Set<String> = []
    /// usage 缺失、按估算口径记录的调用次数（面板「估算占比」用）。
    var estimatedCalls = 0
}

/// 单阶段聚合（本月 per-stage 明细）。
nonisolated struct StageUsage: Equatable, Identifiable {
    var stage: String
    var calls = 0
    var promptTokens = 0
    var completionTokens = 0
    var costCNY = 0.0

    var id: String { stage }
}

/// 模型分档单价（人民币元 / 1M tokens）。字段可空 = 该模型无此计费维度。
/// 口径对齐官方牌价（2026-09 核对）；调价只改 pricingTable，勿动 cost()。
nonisolated struct ModelPrice: Equatable {
    /// 输入单价（高峰档；无峰谷模型即唯一档）。
    var inputPeak: Double
    /// 输出单价（高峰档）。
    var outputPeak: Double
    /// 空闲档输入单价（nil = 无峰谷定价）。
    var inputOffPeak: Double?
    /// 空闲档输出单价。
    var outputOffPeak: Double?
    /// 输入缓存命中单价（nil = 不拆缓存，输入全按未命中价计）。
    var cacheHitPeak: Double?
    var cacheHitOffPeak: Double?
    /// 长上下文第二档（单次输入 tokens 超阈值启用，GLM 32K 分档；该档无峰谷）。
    var largeContext: LargeContextTier?

    nonisolated struct LargeContextTier: Equatable {
        var thresholdTokens: Int
        var input: Double
        var output: Double
        var cacheHit: Double?
    }

    /// 平价模型（无峰谷 / 缓存 / 分档）。
    static func flat(_ input: Double, _ output: Double) -> ModelPrice {
        .init(inputPeak: input, outputPeak: output)
    }
}

/// 价目表查询结果。
nonisolated enum PriceLookup: Equatable {
    case priced(ModelPrice)
    /// 已知零成本（本地推理），费用计 0 且不算无法计价。
    case free
    case unknown
}

/// 用量/成本统计（append-only JSONL + 内存聚合）。线程安全（NSLock）。
nonisolated final class CostTracker {
    static let shared = CostTracker()

    // MARK: - 价目表
    // 官方牌价快照（2026-09 核对，人民币元 / 1M tokens）：
    // - DeepSeek 2026-08-17 起峰谷定价（高峰=北京周一至五 9-12/14-18 点，空闲减半）。
    // - GLM-4.6 官方直连分档价（输入 ≤32K：3/14 + 缓存命中 0.6；32-200K：4/16 + 0.8）。
    // - gpt-4o / claude 系按 usdToCNY 折算；调价只改本表。

    /// 统一美元→人民币折算率（官方 USD 牌价按此折算；调汇率只动这里）。
    static let usdToCNY = 7.0

    /// 已知零成本模型（本地推理）：不计费、不进 unknownPriceModels。
    static let freeModels: Set<String> = ["qwen2.5"]

    static let pricingTable: [String: ModelPrice] = [
        "deepseek-flash": .init(
            inputPeak: 2, outputPeak: 8,
            inputOffPeak: 1, outputOffPeak: 4,
            cacheHitPeak: 0.04, cacheHitOffPeak: 0.02
        ),
        "glm-4.6": .init(
            inputPeak: 3, outputPeak: 14,
            cacheHitPeak: 0.6,
            largeContext: .init(thresholdTokens: 32_768, input: 4, output: 16, cacheHit: 0.8)
        ),
        "embedding-3": .flat(0.5, 0),
        "gpt-4o": .init(
            inputPeak: 2.5 * usdToCNY, outputPeak: 10 * usdToCNY,
            cacheHitPeak: 1.25 * usdToCNY
        ),
        "claude-sonnet-4": .flat(3 * usdToCNY, 15 * usdToCNY),
    ]

    /// 查价：命中 → priced；零成本白名单 → free；其余 → unknown（面板「无法计价」警告）。
    static func priceLookup(for model: String) -> PriceLookup {
        if let price = pricingTable[model] { return .priced(price) }
        if freeModels.contains(model) { return .free }
        return .unknown
    }

    /// DeepSeek 峰谷判定：北京时间周一至五 09:00–12:00、14:00–18:00 为高峰。
    /// ts 解析失败按高峰（保守口径）。
    static func isPeakHours(ts: String) -> Bool {
        guard let date = ISO8601.parse(ts) else { return true }
        return isPeakHours(date: date)
    }

    /// 峰谷判定（Date 版，测试直测）。
    static func isPeakHours(
        date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute else { return true }
        guard (2...6).contains(weekday) else { return false }  // 周一(2)至周五(6)
        let minuteOfDay = hour * 60 + minute
        return (540..<720).contains(minuteOfDay) || (840..<1080).contains(minuteOfDay)
    }

    /// 费用（元）= 缓存命中×命中价 + (输入−命中)×未命中价 + 输出×输出价（按时段选档）。
    /// 长上下文分档按单次输入总量切换（该档无峰谷）；cacheHitTokens 以 promptTokens 为上限。
    static func cost(
        price: ModelPrice,
        promptTokens: Int,
        cacheHitTokens: Int,
        completionTokens: Int,
        peak: Bool
    ) -> Double {
        let hit = min(max(cacheHitTokens, 0), promptTokens)
        let miss = promptTokens - hit

        // 长上下文第二档（threshold 命中即整体换档）
        if let tier = price.largeContext, promptTokens > tier.thresholdTokens {
            let hitCost = tier.cacheHit.map { Double(hit) / 1_000_000 * $0 } ?? 0
            return hitCost
                + Double(miss) / 1_000_000 * tier.input
                + Double(completionTokens) / 1_000_000 * tier.output
        }

        func unit(_ peakValue: Double, _ offPeak: Double?) -> Double {
            peak || offPeak == nil ? peakValue : offPeak!
        }
        let inputUnit = unit(price.inputPeak, price.inputOffPeak)
        let outputUnit = unit(price.outputPeak, price.outputOffPeak)
        guard let hitUnit = price.cacheHitPeak.map({ unit($0, price.cacheHitOffPeak) }) else {
            // 无缓存档：输入全按未命中价
            return Double(promptTokens) / 1_000_000 * inputUnit
                + Double(completionTokens) / 1_000_000 * outputUnit
        }
        return Double(hit) / 1_000_000 * hitUnit
            + Double(miss) / 1_000_000 * inputUnit
            + Double(completionTokens) / 1_000_000 * outputUnit
    }

    // MARK: - 状态

    private let lock = NSLock()
    /// 本次会话（App 启动至今）的记录（内存聚合源）。
    private var sessionRecords: [UsageRecord] = []
    /// JSONL 落盘位置（shared 用默认路径；测试注入临时目录）。
    private let storageURL: URL

    /// 默认存储：Application Support/pm-worker/usage.jsonl（与 LLMSettings 同目录纪律）。
    static let defaultStorageURL: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0]
        .appendingPathComponent("pm-worker", isDirectory: true)
        .appendingPathComponent("usage.jsonl")

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
    }

    // MARK: - 写侧（append-only；目录不存在则建）

    /// 追加 JSONL + 更新内存。
    func record(_ r: UsageRecord) {
        lock.lock()
        defer { lock.unlock() }
        sessionRecords.append(r)
        appendLineToDisk(r)
    }

    private func appendLineToDisk(_ record: UsageRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)  // '\n'——JSONL 行分隔
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let handle = try FileHandle(forWritingTo: storageURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: storageURL, options: .atomic)
            }
        } catch {
            // 统计落盘失败静默（append-only，丢一行不致命）
        }
    }

    // MARK: - 读侧

    /// 本次（App 启动至今，内存聚合）。
    var session: Aggregation {
        lock.lock()
        defer { lock.unlock() }
        return Self.aggregate(sessionRecords)
    }

    /// 本月（读 JSONL 聚合；ts 前缀 yyyy-MM 匹配）。
    func month(year: Int, month: Int) -> Aggregation {
        Self.aggregate(monthRecords(year: year, month: month))
    }

    /// 本月 per-stage 明细（费用降序，费用同则按阶段名）。
    func monthStages(year: Int, month: Int) -> [StageUsage] {
        var byStage: [String: StageUsage] = [:]
        for record in monthRecords(year: year, month: month) {
            var usage = byStage[record.stage] ?? StageUsage(stage: record.stage)
            usage.calls += 1
            usage.promptTokens += record.promptTokens
            usage.completionTokens += record.completionTokens
            switch Self.priceLookup(for: record.model) {
            case .priced(let price):
                usage.costCNY += Self.cost(
                    price: price,
                    promptTokens: record.promptTokens,
                    cacheHitTokens: record.cacheHitTokens,
                    completionTokens: record.completionTokens,
                    peak: Self.isPeakHours(ts: record.ts)
                )
            case .free, .unknown:
                break
            }
            byStage[record.stage] = usage
        }
        return byStage.values.sorted {
            $0.costCNY == $1.costCNY ? $0.stage < $1.stage : $0.costCNY > $1.costCNY
        }
    }

    private func monthRecords(year: Int, month: Int) -> [UsageRecord] {
        let prefix = String(format: "%04d-%02d", year, month)
        return readAllRecords().filter { $0.ts.hasPrefix(prefix) }
    }

    /// 读 JSONL 全量（坏行跳过——append-only 容错）。
    private func readAllRecords() -> [UsageRecord] {
        guard let text = try? String(contentsOf: storageURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(UsageRecord.self, from: Data($0.utf8))
        }
    }

    // MARK: - 聚合（纯函数，测试直测）

    static func aggregate(_ records: [UsageRecord]) -> Aggregation {
        var agg = Aggregation()
        for record in records {
            agg.calls += 1
            agg.promptTokens += record.promptTokens
            agg.completionTokens += record.completionTokens
            if record.estimated { agg.estimatedCalls += 1 }
            switch priceLookup(for: record.model) {
            case .priced(let price):
                agg.costCNY += cost(
                    price: price,
                    promptTokens: record.promptTokens,
                    cacheHitTokens: record.cacheHitTokens,
                    completionTokens: record.completionTokens,
                    peak: isPeakHours(ts: record.ts)
                )
            case .free:
                break
            case .unknown:
                agg.unknownPriceModels.insert(record.model)
            }
        }
        return agg
    }
}
