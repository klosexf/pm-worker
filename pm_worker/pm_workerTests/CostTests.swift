//
//  CostTests.swift
//  pm_workerTests
//
//  M5 Task 5.4：token 用量捕获 + 成本统计
//  （CostTracker 价目/聚合/JSONL 落盘 + UsageRecord Codable + usage 解析）。
//  2026-09 计价口径升级：官方牌价分档（DeepSeek 峰谷/缓存、GLM 32K 分档、
//  USD 统一折算、free 白名单）+ 缓存命中捕获（旧 JSONL 兼容）。
//

import XCTest
@testable import pm_worker

final class CostTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmworker-cost-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    /// 临时目录注入的独立实例（不碰 shared 的默认存储）。
    private func makeTracker() -> CostTracker {
        CostTracker(storageURL: tempDir.appendingPathComponent("usage.jsonl"))
    }

    private func record(
        _ tracker: CostTracker,
        ts: String,
        model: String = "deepseek-flash",
        prompt: Int,
        completion: Int,
        cacheHit: Int = 0,
        estimated: Bool = false
    ) {
        tracker.record(UsageRecord(
            ts: ts, stage: "clarify", model: model,
            promptTokens: prompt, completionTokens: completion,
            cacheHitTokens: cacheHit, estimated: estimated
        ))
    }

    /// 固定时段测试时刻（ Asia/Shanghai），保证峰谷断言确定性。
    private func beijingDate(
        _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: components)!
    }

    // MARK: 1. 价目表查表（分档结构 + free 白名单 + unknown）

    func testPriceLookup() {
        // deepseek-flash：峰谷 + 缓存全档
        guard case let .priced(price) = CostTracker.priceLookup(for: "deepseek-flash") else {
            return XCTFail("deepseek-flash 应命中价目表")
        }
        XCTAssertEqual(price.inputPeak, 2)
        XCTAssertEqual(price.inputOffPeak, 1)
        XCTAssertEqual(price.outputPeak, 8)
        XCTAssertEqual(price.outputOffPeak, 4)
        XCTAssertEqual(price.cacheHitPeak, 0.04)
        XCTAssertEqual(price.cacheHitOffPeak, 0.02)

        // free 白名单：不计费也不算 unknown
        XCTAssertEqual(CostTracker.priceLookup(for: "qwen2.5"), .free)
        // 未知模型 → unknown
        XCTAssertEqual(CostTracker.priceLookup(for: "not-a-model"), .unknown)

        // 其余内置条目命中
        for model in ["glm-4.6", "embedding-3", "gpt-4o", "claude-sonnet-4"] {
            guard case .priced = CostTracker.priceLookup(for: model) else {
                return XCTFail("\(model) 应命中价目表")
            }
        }
        // USD 统一折算：gpt-4o $2.5/$10、claude-sonnet-4 $3/$15 × 7
        guard case let .priced(gpt4o) = CostTracker.priceLookup(for: "gpt-4o") else {
            return XCTFail()
        }
        XCTAssertEqual(gpt4o.inputPeak, 17.5, accuracy: 1e-9)
        XCTAssertEqual(gpt4o.outputPeak, 70, accuracy: 1e-9)
        guard case let .priced(claude) = CostTracker.priceLookup(for: "claude-sonnet-4") else {
            return XCTFail()
        }
        XCTAssertEqual(claude.inputPeak, 21, accuracy: 1e-9)
        XCTAssertEqual(claude.outputPeak, 105, accuracy: 1e-9)
    }

    // MARK: 2. 峰谷判定（北京周一至五 9-12 / 14-18）

    func testPeakHoursDecision() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-09-07 为周一
        XCTAssertFalse(CostTracker.isPeakHours(date: beijingDate(9, 7, 8, 59), timeZone: tz))
        XCTAssertTrue(CostTracker.isPeakHours(date: beijingDate(9, 7, 9, 0), timeZone: tz))
        XCTAssertTrue(CostTracker.isPeakHours(date: beijingDate(9, 7, 11, 59), timeZone: tz))
        XCTAssertFalse(CostTracker.isPeakHours(date: beijingDate(9, 7, 12, 0), timeZone: tz))
        XCTAssertFalse(CostTracker.isPeakHours(date: beijingDate(9, 7, 13, 59), timeZone: tz))
        XCTAssertTrue(CostTracker.isPeakHours(date: beijingDate(9, 7, 14, 0), timeZone: tz))
        XCTAssertTrue(CostTracker.isPeakHours(date: beijingDate(9, 7, 17, 59), timeZone: tz))
        XCTAssertFalse(CostTracker.isPeakHours(date: beijingDate(9, 7, 18, 0), timeZone: tz))
        // 2026-09-12 周六白天 → 空闲；2026-09-11 周五下午 → 高峰
        XCTAssertFalse(CostTracker.isPeakHours(date: beijingDate(9, 12, 10), timeZone: tz))
        XCTAssertTrue(CostTracker.isPeakHours(date: beijingDate(9, 11, 15), timeZone: tz))

        // ts 字符串链路：周二 10:00 高峰 / 周二 22:00 空闲；坏串保守按高峰
        XCTAssertTrue(CostTracker.isPeakHours(ts: "2026-09-01T10:00:00+08:00"))
        XCTAssertFalse(CostTracker.isPeakHours(ts: "2026-09-01T22:00:00+08:00"))
        XCTAssertTrue(CostTracker.isPeakHours(ts: "not-a-timestamp"))
    }

    // MARK: 3. 计费公式（峰谷选档 + 缓存拆分 + 长上下文分档）

    func testDeepSeekCostWithCacheAndPeak() {
        let price = CostTracker.pricingTable["deepseek-flash"]!
        // 高峰：0.8M 命中×0.04 + 0.2M 未命中×2 + 1M 输出×8
        let peak = CostTracker.cost(
            price: price, promptTokens: 1_000_000, cacheHitTokens: 800_000,
            completionTokens: 1_000_000, peak: true
        )
        XCTAssertEqual(peak, 0.8 * 0.04 + 0.2 * 2 + 8, accuracy: 1e-9)

        // 空闲：同量减半
        let offPeak = CostTracker.cost(
            price: price, promptTokens: 1_000_000, cacheHitTokens: 800_000,
            completionTokens: 1_000_000, peak: false
        )
        XCTAssertEqual(offPeak, 0.8 * 0.02 + 0.2 * 1 + 4, accuracy: 1e-9)

        // 命中数超输入 → clamp 到 promptTokens
        let clamped = CostTracker.cost(
            price: price, promptTokens: 100, cacheHitTokens: 500,
            completionTokens: 0, peak: true
        )
        XCTAssertEqual(clamped, 100.0 / 1_000_000 * 0.04, accuracy: 1e-9)
    }

    func testGLMTierByContext() {
        let price = CostTracker.pricingTable["glm-4.6"]!
        // ≤32K 第一档 3/14
        let small = CostTracker.cost(
            price: price, promptTokens: 32_768, cacheHitTokens: 0,
            completionTokens: 0, peak: true
        )
        XCTAssertEqual(small, 32_768.0 / 1_000_000 * 3, accuracy: 1e-9)

        // >32K 整体切第二档 4/16（缓存命中价 0.8）
        let large = CostTracker.cost(
            price: price, promptTokens: 32_769, cacheHitTokens: 30_000,
            completionTokens: 1_000, peak: true
        )
        XCTAssertEqual(
            large,
            30_000.0 / 1_000_000 * 0.8 + 2_769.0 / 1_000_000 * 4 + 1_000.0 / 1_000_000 * 16,
            accuracy: 1e-9
        )
    }

    func testFlatModelCost() {
        // 平价模型：无峰谷（peak 参数无效）、无缓存档（输入全按 input 单价）
        let price = CostTracker.pricingTable["claude-sonnet-4"]!
        let cost = CostTracker.cost(
            price: price, promptTokens: 1_000_000, cacheHitTokens: 400_000,
            completionTokens: 500_000, peak: false
        )
        XCTAssertEqual(cost, 3 + 0.5 * 15, accuracy: 1e-9)
    }

    // MARK: 4. record → session 聚合（固定 ts 消除时段不确定性）

    func testSessionAggregation() {
        let tracker = makeTracker()
        // 周二 10:00（高峰）：deepseek 1M 输入 ×2 + 0.5M 输出 ×8 = 6.0
        record(
            tracker, ts: "2026-09-01T10:00:00+08:00", prompt: 1_000_000, completion: 500_000
        )
        // glm-4.6：100×3/M + 100×14/M
        record(
            tracker, ts: "2026-09-01T10:00:00+08:00", model: "glm-4.6", prompt: 100, completion: 100
        )
        // 估算口径记录（费用同公式）
        record(
            tracker, ts: "2026-09-01T10:00:00+08:00", prompt: 50, completion: 50, estimated: true
        )

        let session = tracker.session
        XCTAssertEqual(session.calls, 3)
        XCTAssertEqual(session.promptTokens, 1_000_150)
        XCTAssertEqual(session.completionTokens, 500_150)
        XCTAssertEqual(session.estimatedCalls, 1)
        let deepseekCost = Double(1_000_050) / 1_000_000 * 2 + Double(500_050) / 1_000_000 * 8
        let glmCost = Double(100) / 1_000_000 * 3 + Double(100) / 1_000_000 * 14
        XCTAssertEqual(session.costCNY, deepseekCost + glmCost, accuracy: 1e-9)
        XCTAssertTrue(session.unknownPriceModels.isEmpty)
    }

    // MARK: 5. JSONL 落盘 → month() 聚合（新实例只读磁盘 + 月份过滤 + free/unknown）

    func testMonthAggregationFromDisk() throws {
        let tracker = makeTracker()
        record(tracker, ts: "2026-09-01T10:00:00+08:00", prompt: 2_000_000, completion: 0)
        record(
            tracker, ts: "2026-09-15T10:00:00+08:00",
            model: "unknown-model", prompt: 10, completion: 10
        )
        // 上月记录不计入 9 月
        record(tracker, ts: "2026-08-31T23:59:59+08:00", prompt: 9_999_999, completion: 0)

        // 落盘校验：3 行 JSONL
        let url = tempDir.appendingPathComponent("usage.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 3)

        // 新实例（只读磁盘）→ 本月聚合正确
        let reloaded = CostTracker(storageURL: url)
        let sept = reloaded.month(year: 2026, month: 9)
        XCTAssertEqual(sept.calls, 2)
        XCTAssertEqual(sept.promptTokens, 2_000_010)
        XCTAssertEqual(sept.completionTokens, 10)
        // 费用：deepseek-flash 周二 10:00 高峰 2M 输入 × ¥2/M；unknown 不计费
        XCTAssertEqual(sept.costCNY, 4.0, accuracy: 1e-9)
        XCTAssertEqual(sept.unknownPriceModels, Set(["unknown-model"]))

        let august = reloaded.month(year: 2026, month: 8)
        XCTAssertEqual(august.calls, 1)
        XCTAssertEqual(august.promptTokens, 9_999_999)

        // per-stage 明细（两条同为 clarify 阶段）
        let stages = reloaded.monthStages(year: 2026, month: 9)
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(stages[0].stage, "clarify")
        XCTAssertEqual(stages[0].calls, 2)
        XCTAssertEqual(stages[0].promptTokens, 2_000_010)
        XCTAssertEqual(stages[0].costCNY, 4.0, accuracy: 1e-9)
    }

    /// 聚合层峰谷链路：空闲时段记录按空闲价计（周二 22:00 → 1M×1 + 1M×4）。
    func testMonthAggregationOffPeakPricing() throws {
        let tracker = makeTracker()
        record(tracker, ts: "2026-09-01T22:00:00+08:00", prompt: 1_000_000, completion: 1_000_000)

        let url = tempDir.appendingPathComponent("usage.jsonl")
        let reloaded = CostTracker(storageURL: url)
        XCTAssertEqual(reloaded.month(year: 2026, month: 9).costCNY, 5.0, accuracy: 1e-9)
    }

    /// free 白名单：本地模型计入次数但零费用、不进 unknownPriceModels。
    func testFreeModelNotUnknown() {
        let tracker = makeTracker()
        record(tracker, ts: "2026-09-01T10:00:00+08:00", model: "qwen2.5", prompt: 9_999, completion: 9_999)
        let session = tracker.session
        XCTAssertEqual(session.calls, 1)
        XCTAssertEqual(session.costCNY, 0)
        XCTAssertTrue(session.unknownPriceModels.isEmpty)
    }

    // MARK: 6. 旧 JSONL 兼容（无 cacheHitTokens 字段按 0）

    func testLegacyJSONLWithoutCacheHitField() throws {
        let legacyLine = """
        {"completionTokens":500,"estimated":false,"model":"deepseek-flash","promptTokens":1000,"stage":"clarify","ts":"2026-09-01T10:00:00+08:00"}
        """
        let url = tempDir.appendingPathComponent("usage.jsonl")
        try Data((legacyLine + "\n").utf8).write(to: url)

        let record = try JSONDecoder().decode(UsageRecord.self, from: Data(legacyLine.utf8))
        XCTAssertEqual(record.cacheHitTokens, 0)

        let reloaded = CostTracker(storageURL: url)
        let month = reloaded.month(year: 2026, month: 9)
        XCTAssertEqual(month.calls, 1)
        // 全输入按未命中高峰价：1000×2/M + 500×8/M
        XCTAssertEqual(month.costCNY, 1000.0 / 1_000_000 * 2 + 500.0 / 1_000_000 * 8, accuracy: 1e-9)
    }

    // MARK: 7. UsageRecord Codable 往返（含 cacheHitTokens）

    func testUsageRecordCodableRoundTrip() throws {
        let original = UsageRecord(
            ts: "2026-09-11T14:30:00+08:00", stage: "prd", model: "claude-sonnet-4",
            promptTokens: 123, completionTokens: 456, cacheHitTokens: 100, estimated: true
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(UsageRecord.self, from: data), original)

        // JSONL 行级解码（落盘格式：单行无换行）
        let line = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(
            try JSONDecoder().decode(UsageRecord.self, from: Data(line.utf8)), original
        )
    }

    // MARK: 8. LLMClient usage 解析（含缓存命中字段，纯函数直测）

    func testParseStreamUsage() throws {
        // 末 chunk 带 usage（OpenAI 兼容：choices 为空、usage 在顶层）
        let payload = """
        {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34,"total_tokens":46}}
        """
        let usage = try XCTUnwrap(LLMClient.parseUsage(fromPayload: Data(payload.utf8)))
        XCTAssertEqual(usage.promptTokens, 12)
        XCTAssertEqual(usage.completionTokens, 34)

        // 普通 delta chunk 无 usage → nil
        let delta = """
        {"choices":[{"delta":{"content":"你好"}}]}
        """
        XCTAssertNil(LLMClient.parseUsage(fromPayload: Data(delta.utf8)))

        // 未知字段容错（不破坏既有解析风格）
        let extra = """
        {"id":"x","object":"chat.completion.chunk","created":1,"model":"m","choices":null,"usage":{"prompt_tokens":1,"completion_tokens":2}}
        """
        XCTAssertEqual(LLMClient.parseUsage(fromPayload: Data(extra.utf8))?.promptTokens, 1)

        // usage 只带部分字段 → 有值但缺项（调用侧按缺失回退估算）
        let partial = """
        {"usage":{"prompt_tokens":7}}
        """
        let partialUsage = try XCTUnwrap(LLMClient.parseUsage(fromPayload: Data(partial.utf8)))
        XCTAssertEqual(partialUsage.promptTokens, 7)
        XCTAssertNil(partialUsage.completionTokens)
    }

    func testParseStreamUsageCacheHit() throws {
        // DeepSeek 专属字段
        let deepseek = """
        {"usage":{"prompt_tokens":100,"completion_tokens":50,"prompt_cache_hit_tokens":80}}
        """
        let deepseekUsage = try XCTUnwrap(LLMClient.parseUsage(fromPayload: Data(deepseek.utf8)))
        XCTAssertEqual(deepseekUsage.effectiveCacheHitTokens, 80)

        // OpenAI 兼容 details.cached_tokens
        let openai = """
        {"usage":{"prompt_tokens":100,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":64}}}
        """
        let openaiUsage = try XCTUnwrap(LLMClient.parseUsage(fromPayload: Data(openai.utf8)))
        XCTAssertEqual(openaiUsage.effectiveCacheHitTokens, 64)

        // DeepSeek 字段优先
        let both = """
        {"usage":{"prompt_tokens":100,"completion_tokens":50,"prompt_cache_hit_tokens":80,"prompt_tokens_details":{"cached_tokens":64}}}
        """
        XCTAssertEqual(
            LLMClient.parseUsage(fromPayload: Data(both.utf8))?.effectiveCacheHitTokens, 80
        )

        // 无缓存字段 → 0
        XCTAssertEqual(try XCTUnwrap(
            LLMClient.parseUsage(fromPayload: Data(
                #"{"usage":{"prompt_tokens":10,"completion_tokens":5}}"#.utf8
            ))
        ).effectiveCacheHitTokens, 0)
    }

    // MARK: 9. 用量记录构造（usage 优先 / 缺失估算 + 缓存命中捕获）

    func testMakeUsageRecordEstimateFallback() {
        let messages = [
            ChatMessage(role: .system, content: "你是产品经理"),
            ChatMessage(role: .user, content: "帮我写 PRD"),
        ]

        // 端点带 usage → 原值 + estimated=false
        let exact = LLMClient.makeUsageRecord(
            stage: .prd, model: "gpt-4o", messages: messages,
            completionText: "很长的回复",
            usage: StreamUsage(promptTokens: 100, completionTokens: 200)
        )
        XCTAssertEqual(exact.promptTokens, 100)
        XCTAssertEqual(exact.completionTokens, 200)
        XCTAssertFalse(exact.estimated)
        XCTAssertEqual(exact.stage, "prd")
        XCTAssertEqual(exact.model, "gpt-4o")

        // usage 缺失 → TokenBreakdown.estimate 估算 + estimated=true
        let estimated = LLMClient.makeUsageRecord(
            stage: .prd, model: "gpt-4o", messages: messages,
            completionText: "很长的回复", usage: nil
        )
        XCTAssertTrue(estimated.estimated)
        XCTAssertEqual(
            estimated.promptTokens,
            TokenBreakdown.estimate(messages.map(\.content).joined(separator: "\n"))
        )
        XCTAssertEqual(estimated.completionTokens, TokenBreakdown.estimate("很长的回复"))
    }

    func testMakeUsageRecordCapturesCacheHit() {
        let messages = [ChatMessage(role: .user, content: "hi")]

        // 命中数超输入 → clamp 到 promptTokens
        let clamped = LLMClient.makeUsageRecord(
            stage: .clarify, model: "deepseek-flash", messages: messages,
            completionText: "ok",
            usage: StreamUsage(promptTokens: 50, completionTokens: 10, promptCacheHitTokens: 80)
        )
        XCTAssertEqual(clamped.cacheHitTokens, 50)

        // OpenAI details 路径
        let details = LLMClient.makeUsageRecord(
            stage: .clarify, model: "gpt-4o", messages: messages,
            completionText: "ok",
            usage: StreamUsage(
                promptTokens: 100, completionTokens: 10,
                promptTokensDetails: .init(cachedTokens: 64)
            )
        )
        XCTAssertEqual(details.cacheHitTokens, 64)
    }
}
