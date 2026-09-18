//
//  BackgroundCompletionTests.swift
//  pm_workerTests
//
//  阶段 2 历史隔离 + 后台完成语义回归锚点：
//  ① buildHistory origin 隔离：当前打开 B，以 A 的 origin 组历史——含 A 条目不含 B
//  ② 压缩缓存 per-session 分键：open 恢复各自键，互不覆盖（全局单份必互踩的回归锚点）
//  ③ saveCompaction origin 钉定回归（originForHistory 实时读 bug）：当前会话切走后
//     压缩行 sessionId == origin（而非实时当前会话）
//  ④ 后台完成：用户停在 B，origin=A 的 send 自然完成（file:// 假 SSE 端点）→
//     回复落 A 的 jsonl、完成回调照发（旧门「origin == 当前会话」会漏掉）
//  ⑤ 跨版本后台完成：闸口不推进，挂起系统行落 origin 会话；产物写 origin 版本目录
//  ⑥ 同版本后台完成：闸口照常触发（死端点评审 → Tier2 降级放行路径，零真实网络）
//
//  说明：项目无 mock 流先例——④ 用 file:// 端点模拟「自然完成」：LLMClient 对
//  file URL 的请求无 HTTPURLResponse（openStreamWithRetry 的重试 guard 放行），
//  URLSession.bytes 按文件字节逐行读 SSE，data: 分片正常解析至 [DONE]。
//

import XCTest
@testable import pm_worker

final class BackgroundCompletionTests: XCTestCase {
    var tempRoot: URL!
    /// 测试专用 Keychain 槽位（独立 key，不碰真实 byok.<provider> 槽位）。
    private let testKeychainKey = "byok.test.bg-completion"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-worker-bg-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        KeychainStore.delete(testKeychainKey)
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func makeDeadEndpointSettings() -> LLMSettings {
        LLMSettings(
            stages: [.clarify: StageModelConfig(
                provider: "openai", model: "stub", baseURL: "http://127.0.0.1:9/v1"
            )],
            maxTokensPerRun: 1000
        )
    }

    private var discussionsURL: URL {
        PMAgentStore.jsonlURL(project: "隔离项目", version: "v1", file: "discussions.jsonl")
    }

    /// 完备的结构产物回复（三项产物块，与落盘段解析/机器门 Tier1 对齐）。
    private static let structureReply = """
    说明文字。

    ```artifact:architecture
    graph TD
      A[首页] --> B[详情]
    ```

    ```artifact:core-flows
    flowchart TD
      S([开始]) --> E([结束])
    ```

    ```artifact:module-page-map
    | 模块 | 原型页面 | 页面说明 |
    |---|---|---|
    | 首页 | index | 入口 |
    ```
    """

    private func makeReply(_ sessionID: String, content: String) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionID,
            role: .assistant,
            content: content,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - ① buildHistory origin 隔离

    @MainActor
    func testBuildHistoryReadsOriginSessionEntriesFromDisk() async throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.ensureWorkspace(project: "隔离项目", version: "v1")
        let store = SessionStore()

        // A 会话留一轮历史（落盘）
        store.open(project: "隔离项目", version: "v1", sessionId: "sA")
        try store.append(DiscussionEntry(
            id: "a1", sessionId: "sA", role: .user, content: "A 的第一问",
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))
        try store.append(DiscussionEntry(
            id: "a2", sessionId: "sA", role: .assistant, content: "A 的第一答",
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))

        // 切到 B（同项目版本）：B 成了当前打开会话
        store.open(project: "隔离项目", version: "v1", sessionId: "sB")
        try store.append(DiscussionEntry(
            id: "b1", sessionId: "sB", role: .user, content: "B 的问题",
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))

        // 以 A 的 origin 组历史（当前打开的是 B）→ 读盘过滤 sA 条目
        let history = await store.buildHistory(
            origin: SessionStore.StreamOrigin(project: "隔离项目", version: "v1", sessionId: "sA"),
            systemPrompt: "系统提示",
            settings: makeDeadEndpointSettings()
        )
        let joined = history.map(\.content).joined(separator: "\n")
        XCTAssertTrue(joined.contains("A 的第一问"), "后台会话历史必须含 origin 会话条目")
        XCTAssertTrue(joined.contains("A 的第一答"))
        XCTAssertFalse(joined.contains("B 的问题"), "后台历史不得串入当前打开会话的条目")

        // 当前打开会话照旧走内存投影
        let currentHistory = await store.buildHistory(
            origin: SessionStore.StreamOrigin(project: "隔离项目", version: "v1", sessionId: "sB"),
            systemPrompt: "系统提示",
            settings: makeDeadEndpointSettings()
        )
        XCTAssertTrue(
            currentHistory.map(\.content).joined(separator: "\n").contains("B 的问题"),
            "当前会话沿用内存投影（现状路径不回归）"
        )
    }

    // MARK: - ② 压缩缓存 per-session 分键

    @MainActor
    func testCompactionCacheRestoresPerSessionKeys() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.ensureWorkspace(project: "隔离项目", version: "v1")
        let store = SessionStore()

        // 磁盘预置两个会话各自的压缩行
        func compactionEntry(_ session: String, _ summary: String) -> DiscussionEntry {
            DiscussionEntry(
                id: UUID().uuidString, sessionId: session, role: .system,
                content: "🗜️ 上下文已压缩\n\n" + summary,
                compaction: CompactionData(
                    summary: summary, boundary: "边界-\(session)", droppedCount: 4,
                    tokensBefore: 900, viaStage: "classify"
                ),
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        try PMAgentStore.appendLine(compactionEntry("sA", "A 的摘要"), to: discussionsURL)
        try PMAgentStore.appendLine(compactionEntry("sB", "B 的摘要"), to: discussionsURL)

        store.open(project: "隔离项目", version: "v1", sessionId: "sA")
        XCTAssertEqual(store.compactions["sA"]?.summary, "A 的摘要", "open 恢复到本会话的键")
        store.open(project: "隔离项目", version: "v1", sessionId: "sB")
        XCTAssertEqual(store.compactions["sB"]?.summary, "B 的摘要")
        XCTAssertEqual(store.compactions["sA"]?.summary, "A 的摘要", "恢复 B 不得覆盖 A 的键（全局单份必互踩）")

        // 无压缩行的新会话：该键清空，其余键各自保留
        store.open(project: "隔离项目", version: "v1", sessionId: "sC")
        XCTAssertNil(store.compactions["sC"])
        XCTAssertEqual(store.compactions["sA"]?.summary, "A 的摘要")
        XCTAssertEqual(store.compactions["sB"]?.summary, "B 的摘要")
    }

    // MARK: - ③ saveCompaction origin 钉定（originForHistory bug 回归）

    @MainActor
    func testSaveCompactionPinsOriginSessionNotLiveSession() throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.ensureWorkspace(project: "隔离项目", version: "v1")
        let store = SessionStore()
        store.open(project: "隔离项目", version: "v1", sessionId: "sCurrent")

        // 模拟「历史组装期间用户已切会话」：当前会话是 sCurrent，落盘 origin 钉 sOrigin。
        // 旧实现 originForHistory 实时读当前 project/version/sessionId → 压缩行写错会话。
        store.saveCompaction(
            summary: "滚动摘要内容", boundary: "边界签名", droppedCount: 6,
            tokensBefore: 1200,
            origin: SessionStore.StreamOrigin(project: "隔离项目", version: "v1", sessionId: "sOrigin")
        )

        let rows = PMAgentStore.readLines(DiscussionEntry.self, from: discussionsURL)
        let compactionRows = rows.filter { $0.compaction != nil }
        XCTAssertEqual(compactionRows.count, 1, "压缩行恰好一条")
        XCTAssertEqual(
            compactionRows.first?.sessionId, "sOrigin",
            "压缩行必须钉 origin 会话（而非实时当前会话）——originForHistory bug 回归锚点"
        )
        XCTAssertEqual(compactionRows.first?.compaction?.summary, "滚动摘要内容")
    }

    // MARK: - ④ 后台完成：回复落 origin 会话 + 自然完成即回调

    @MainActor
    func testBackgroundCompletionDeliversReplyToOriginSession() async throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.ensureWorkspace(project: "隔离项目", version: "v1")

        // file:// 假 SSE 端点：baseURL 指向 <temp>/mock/v1 → 请求 file://<temp>/mock/v1/chat/completions
        let sseFile = tempRoot
            .appendingPathComponent("mock/v1/chat/completions")
        try FileManager.default.createDirectory(
            at: sseFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let sse = """
        data: {"choices":[{"delta":{"content":"后台完成的回复正文"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        try sse.write(to: sseFile, atomically: true, encoding: .utf8)
        var fileBase = sseFile.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        if fileBase.hasSuffix("/") { fileBase.removeLast() }

        var settings = makeDeadEndpointSettings()
        settings.stages[.clarify] = StageModelConfig(
            provider: "openai", model: "stub", baseURL: fileBase,
            keychainKey: testKeychainKey
        )
        try KeychainStore.set("stub-key", forKey: testKeychainKey)

        let store = SessionStore()
        // 用户停在 B；A 会话的回合后台执行（origin 显式钉 A）
        store.open(project: "隔离项目", version: "v1", sessionId: "sB")
        let origin = SessionStore.StreamOrigin(project: "隔离项目", version: "v1", sessionId: "sA")
        var callbackEntry: DiscussionEntry?
        await store.send(
            "后台的问题", settings: settings, stage: .clarify,
            systemPrompt: "测试系统提示", pinnedOrigin: origin
        ) { reply, _ in
            callbackEntry = reply
        }

        let rows = PMAgentStore.readLines(DiscussionEntry.self, from: discussionsURL)
        let aRows = rows.filter { $0.sessionId == "sA" }
        XCTAssertTrue(
            aRows.contains { $0.role == .user && $0.content == "后台的问题" },
            "用户条目钉 origin 会话落盘"
        )
        XCTAssertTrue(
            aRows.contains { $0.role == .assistant && $0.content.contains("后台完成的回复正文") },
            "自然完成的回复必须落回 origin 会话（即使发起会话不在前台）"
        )
        XCTAssertFalse(
            rows.contains { $0.sessionId == "sB" },
            "回复与用户条目不得串进当前打开会话"
        )
        XCTAssertTrue(
            callbackEntry?.content.contains("后台完成的回复正文") == true,
            "自然完成即回调（旧门要求 origin == 当前会话，会漏掉后台完成）"
        )
        XCTAssertNil(store.streams["sA"], "后台流收尾照常清理流态键")
        XCTAssertFalse(store.isSessionBusy("sA"))
    }

    // MARK: - ⑤ 跨版本后台完成：闸口挂起 + origin 口径落盘

    @MainActor
    func testCrossVersionBackgroundCompletionDefersGateWithPendingLine() async throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "门闸项目")
        try PMAgentStore.createVersion("v1", in: "门闸项目")
        try PMAgentStore.createVersion("v2", in: "门闸项目")
        try PMAgentStore.ensureWorkspace(project: "门闸项目", version: "v2")

        let model = AppModel()
        model.selection = .session(project: "门闸项目", version: "v1", sessionId: "cur")

        // 后台完成：origin 在 v2 的 sOrigin 会话，产物按 v2/structure 口径落盘
        let origin = AppModel.ReplyOrigin(
            project: "门闸项目", version: "v2", sessionId: "sOrigin", stage: .structure
        )
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.structureReply), origin: origin
        )

        // 产物写 origin 版本目录
        let v2Structure = PMAgentStore.versionURL(project: "门闸项目", version: "v2")
            .appendingPathComponent("02-structure/功能架构图.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: v2Structure.path),
            "产物必须写 origin 版本目录"
        )

        // 📦 行与挂起提示行落 origin 会话（v2 的 jsonl）
        let v2Rows = PMAgentStore.readLines(DiscussionEntry.self, from: PMAgentStore.jsonlURL(
            project: "门闸项目", version: "v2", file: "discussions.jsonl"
        ))
        XCTAssertTrue(
            v2Rows.contains {
                $0.sessionId == "sOrigin" && $0.content.hasPrefix("📦 结构产物已生成")
                    && $0.fileChanges != nil
            },
            "落盘系统行必须落回 origin 会话（携带 fileChanges）"
        )
        XCTAssertTrue(
            v2Rows.contains {
                $0.sessionId == "sOrigin" && $0.content.contains("需回到发起会话处理")
            },
            "跨版本后台完成必须落「阶段推进需回发起会话」挂起提示行"
        )
        XCTAssertFalse(
            v2Rows.contains { $0.sessionId == "cur" },
            "origin 口径系统行不得串进当前上下文会话"
        )

        // 闸口不推进：稍候片刻后两版本 events.jsonl 均无 gateEvaluated
        try await Task.sleep(nanoseconds: 400_000_000)
        for version in ["v1", "v2"] {
            XCTAssertFalse(
                PipelineEventLog.events(project: "门闸项目", version: version)
                    .contains { $0.kind == .gateEvaluated },
                "跨版本后台完成不得触发机器门（\(version)）"
            )
        }
    }

    // MARK: - ⑥ 同版本后台完成：闸口照常触发

    @MainActor
    func testSameVersionBackgroundCompletionTriggersGate() async throws {
        try PMAgentStore.bootstrap()
        try PMAgentStore.createProject(named: "门闸项目")
        try PMAgentStore.createVersion("v1", in: "门闸项目")

        let model = AppModel()
        // Tier2 评审走死端点/无 classify 配置 → extractWithReason 即刻失败 →
        // 「评审模型不可用，降级放行」路径，零真实网络
        model.settings = makeDeadEndpointSettings()
        model.selection = .session(project: "门闸项目", version: "v1", sessionId: "cur")

        let origin = AppModel.ReplyOrigin(
            project: "门闸项目", version: "v1", sessionId: "cur", stage: .structure
        )
        model.handleAssistantReply(
            makeReply("cur", content: Self.structureReply), origin: origin
        )

        // 闸口照常触发（同版本共享 pipeline 实例）：gateEvaluated 事件落地
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(
            PipelineEventLog.events(project: "门闸项目", version: "v1")
                .contains { $0.kind == .gateEvaluated && $0.stage == "structure" },
            "同版本后台完成应照常触发机器门评审"
        )
        // 📦 行落 origin（= 当前）会话
        let rows = PMAgentStore.readLines(DiscussionEntry.self, from: PMAgentStore.jsonlURL(
            project: "门闸项目", version: "v1", file: "discussions.jsonl"
        ))
        XCTAssertTrue(
            rows.contains { $0.sessionId == "cur" && $0.content.hasPrefix("📦 结构产物已生成") },
            "同版本后台完成的落盘系统行落 origin 会话"
        )
    }
}
