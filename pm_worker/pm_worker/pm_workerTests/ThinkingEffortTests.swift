//
//  ThinkingEffortTests.swift
//  pm_workerTests
//
//  思考强度选择三件事：
//  ① 档位 → API 值映射（high = 服务端默认不发参数，medium 是文档确认的别名）
//  ② 请求体编码：非默认档携带 reasoning_effort，默认档字段整体缺席（encodeIfPresent）
//  ③ SessionStore 状态默认 .high + UserDefaults 持久化回读
//

import XCTest
@testable import pm_worker

final class ThinkingEffortTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "pm.worker.thinkingEffort")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "pm.worker.thinkingEffort")
        super.tearDown()
    }

    // MARK: - ① 档位 → API 值

    func testAPIValueMapping() {
        XCTAssertNil(ThinkingEffort.high.apiValue, "high 是服务端默认档，不得发送参数")
        XCTAssertEqual(ThinkingEffort.low.apiValue, "low")
        XCTAssertEqual(ThinkingEffort.medium.apiValue, "medium", "medium 是 DeepSeek 文档确认的兼容别名")
        XCTAssertEqual(ThinkingEffort.max.apiValue, "max")
    }

    func testMenuOrderMatchesReferenceDesign() {
        // 菜单顺序即参考图顺序：Low / Medium / High / Max
        XCTAssertEqual(ThinkingEffort.allCases.map(\.displayName), ["Low", "Medium", "High", "Max"])
    }

    // MARK: - ② 请求体编码

    private func makeBody(_ effort: String?) -> LLMClient.RequestBody {
        LLMClient.RequestBody(
            model: "deepseek-flash",
            messages: [.init(role: "user", content: .text("hi"))],
            stream: true,
            max_tokens: 100,
            stream_options: nil,
            reasoning_effort: effort
        )
    }

    func testRequestBodyCarriesEffortWhenSet() throws {
        let data = try JSONEncoder().encode(makeBody("low"))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""reasoning_effort":"low""#), "非默认档必须携带 reasoning_effort：\(json)")
    }

    func testRequestBodyOmitsEffortWhenNil() throws {
        let data = try JSONEncoder().encode(makeBody(nil))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("reasoning_effort"), "nil 档字段须整体缺席（服务端默认），不得编码成 null：\(json)")
    }

    // MARK: - ③ SessionStore 状态与持久化

    @MainActor
    func testStoreDefaultsToHighAndPersistsSelection() {
        let store = SessionStore()
        XCTAssertEqual(store.thinkingEffort, .high, "默认档必须是服务端默认 high")

        store.thinkingEffort = .max
        XCTAssertEqual(UserDefaults.standard.string(forKey: "pm.worker.thinkingEffort"), "max")

        // 新实例从 Defaults 回读（跨启动保留语义）
        let reloaded = SessionStore()
        XCTAssertEqual(reloaded.thinkingEffort, .max)
    }
}
