//
//  PrototypeConflictTests.swift
//  pm_workerTests
//
//  阶段 4：原型冲突分槽 + 台账选主回归锚点：
//  ① prototypeBases 快照指纹：relPath + 全文 SHA256 与磁盘内容一致（prompt 注入
//    与落盘校验同源，readArtifact 原文读出无归一化）
//  ② 冲突分槽端到端：expectedSnapshot 旧 SHA + 磁盘已被外部改写 → handleAssistantReply
//    降级落「原型-修订-MMdd-HHmm.html」，主槽位内容不被触碰；⚠️ 系统行落 origin 会话、
//    📦 fileChanges 行含修订路径、事件留痕注明冲突分槽；未冲突槽位（移动端）照常落原路径
//  ③ 同分钟冲突序号防覆盖：修订目标已存在 → 自动 -2，已占用文件不被改写
//  ④ reserveRevisionPrototypePath：同名探测-递增（注入固定 now 做确定性断言）
//  ⑤ setAsMasterPrototype：源文件全文写主槽位 + 📌 系统行 + 事件留痕；源缺失时
//    不写盘且通知条可见（不许无声）；版本 busy 时拦截（防与流完成落盘竞态）
//  ⑥ 快照链：stage == prototype 时 send 经 onAssistant 透传非 nil 快照；
//    其他阶段强制 nil（performSend 按 stage 闸死）
//  ⑦ 选主可见性谓词：03-prototypes/原型-*.html 命中，主槽位/分端槽位/非原型不命中
//
//  手法沿用 BackgroundCompletionTests：file:// 假 SSE 端点模拟自然完成（零真实网络）、
//  死端点设置让机器门 Tier2 走「评审模型不可用，降级放行」。
//

import XCTest
@testable import pm_worker

final class PrototypeConflictTests: XCTestCase {

    private let project = "冲突分槽项目"
    private let version = "v1"
    /// 磁盘隔离：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/。
    private var tempRoot: URL!
    /// 测试专用 Keychain 槽位（独立 key，不碰真实 byok.<provider> 槽位）。
    private let testKeychainKey = "byok.test.prototype-conflict"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-worker-proto-conflict-\(UUID().uuidString)", isDirectory: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
        try? PMAgentStore.ensureWorkspace(project: project, version: version)
    }

    override func tearDown() {
        KeychainStore.delete(testKeychainKey)
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private func block(_ name: String, _ html: String) -> ArtifactParser.ArtifactBlock {
        .init(name: name, content: html)
    }

    private func masterURL() -> URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent(ArtifactPath.prototype)
    }

    private func prototypesDir() -> URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("03-prototypes", isDirectory: true)
    }

    private func revisionFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: prototypesDir(), includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("原型-修订-") && $0.lastPathComponent.hasSuffix(".html") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func discussionsURL() -> URL {
        PMAgentStore.jsonlURL(project: project, version: version, file: "discussions.jsonl")
    }

    private func makeReply(_ sessionID: String, content: String) -> DiscussionEntry {
        DiscussionEntry(
            id: UUID().uuidString,
            sessionId: sessionID,
            role: .assistant,
            content: content,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// 大于 2KB 的正文（Tier1 原型空壳检查阈值），零外部资源引用。
    private static func bigHTML(_ marker: String) -> String {
        "<html>\n<head><title>\(marker)</title></head>\n<body>\n"
            + String(repeating: "<p>\(marker)页面内容段落，用于撑过空壳阈值。</p>\n", count: 120)
            + "</body>\n</html>"
    }

    private static func prototypeReply(_ html: String) -> String {
        """
        说明文字。

        ```artifact:prototype
        \(html)
        ```

        """
    }

    /// 死端点设置（机器门 Tier2 走降级放行，零真实网络）。
    private func makeDeadEndpointSettings() -> LLMSettings {
        LLMSettings(
            stages: [.prototype: StageModelConfig(
                provider: "openai", model: "stub", baseURL: "http://127.0.0.1:9/v1"
            )],
            maxTokensPerRun: 1000
        )
    }

    // MARK: - ① prototypeBases 快照指纹

    @MainActor
    func testPrototypeBasesSnapshotMatchesDiskContent() throws {
        let html = "<html>\n<body>v1 基底</body>\n</html>"
        try PMAgentStore.writeVerified(html, to: masterURL())

        let model = AppModel()
        let bases = model.prototypeBases(project: project, version: version)

        XCTAssertEqual(bases.count, 1, "主槽位文件应被扫入迭代基底")
        XCTAssertEqual(bases.first?.relPath, ArtifactPath.prototype)
        XCTAssertEqual(bases.first?.sha, ArtifactParser.sha256Hex(html), "快照指纹必须等于磁盘全文 SHA256")
        XCTAssertEqual(bases.first?.html, html, "注入 prompt 的全文与校验指纹必须同源同一次读盘")
    }

    // MARK: - ② 冲突分槽端到端

    @MainActor
    func testConflictForkWritesRevisionAndKeepsMasterUntouched() async throws {
        // 预置主槽位（外部已落盘的版本）
        let external = Self.bigHTML("外部更新")
        try PMAgentStore.writeVerified(external, to: masterURL())
        // 快照取自生成前（旧版本），随后磁盘被另一对话/外部改写 → 期望失配
        let staleSnapshot = [
            ArtifactPath.prototype: ArtifactParser.sha256Hex(Self.bigHTML("旧版本"))
        ]

        let model = AppModel()
        model.settings = makeDeadEndpointSettings()
        model.selection = .session(project: project, version: version, sessionId: "cur")

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .prototype
        )
        let generated = Self.bigHTML("本次生成")
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.prototypeReply(generated)),
            origin: origin,
            prototypeSnapshot: staleSnapshot
        )

        // 主槽位内容 = 外部更新版（本次生成不得覆盖）
        XCTAssertEqual(
            try String(contentsOf: masterURL(), encoding: .utf8), external,
            "冲突时主槽位文件必须保持未被触碰"
        )
        // 修订文件存在且内容为本次生成
        let revisions = try revisionFiles()
        XCTAssertEqual(revisions.count, 1, "冲突块必须恰好分槽到一个修订文件")
        XCTAssertEqual(
            try String(contentsOf: revisions[0], encoding: .utf8), generated,
            "修订文件内容必须是本次生成的原型"
        )
        XCTAssertTrue(
            revisions[0].lastPathComponent.range(
                of: #"^原型-修订-\d{4}-\d{4}\.html$"#, options: .regularExpression
            ) != nil,
            "修订文件名必须是 原型-修订-MMdd-HHmm.html 口径，实际 \(revisions[0].lastPathComponent)"
        )

        // ⚠️ 人话系统行落 origin 会话（含修订文件名与「设为主原型」指引）
        let rows = PMAgentStore.readLines(DiscussionEntry.self, from: discussionsURL())
        XCTAssertTrue(
            rows.contains {
                $0.sessionId == "sOrigin" && $0.role == .system
                    && $0.content.contains("原型已被另一对话或外部更新")
                    && $0.content.contains("「\(revisions[0].lastPathComponent)」")
                    && $0.content.contains("设为主原型")
            },
            "冲突降级必须落用户可见的说明系统行（落发起会话）"
        )
        // 📦 fileChanges 系统行照常，含修订路径
        XCTAssertTrue(
            rows.contains {
                $0.sessionId == "sOrigin" && $0.content.hasPrefix("📦 交互原型已生成")
                    && $0.fileChanges?.contains {
                        $0.path.hasPrefix("03-prototypes/原型-修订-") && $0.isNew
                    } == true
            },
            "落盘系统行必须携带修订路径的 fileChanges"
        )
        // 事件留痕注明冲突分槽
        XCTAssertTrue(
            PipelineEventLog.events(project: project, version: version).contains {
                $0.kind == .artifactGenerated && $0.detail.contains("冲突分槽")
                    && $0.detail.contains(revisions[0].lastPathComponent)
            },
            "冲突分槽必须落事件留痕"
        )

        // 异步机器门收尾（死端点降级放行）落定后再拆除临时目录
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    @MainActor
    func testConflictForkWritesUnconflictedSlotToNormalPath() async throws {
        // 主槽位冲突；移动端槽位不在快照中（未冲突）→ 照常落原路径
        let external = Self.bigHTML("外部更新")
        try PMAgentStore.writeVerified(external, to: masterURL())
        let staleSnapshot = [
            ArtifactPath.prototype: ArtifactParser.sha256Hex(Self.bigHTML("旧版本"))
        ]

        let model = AppModel()
        model.settings = makeDeadEndpointSettings()
        model.selection = .session(project: project, version: version, sessionId: "cur")

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .prototype
        )
        let mobile = Self.bigHTML("移动端")
        model.handleAssistantReply(
            makeReply("sOrigin", content: """
            说明文字。

            ```artifact:prototype
            \(Self.bigHTML("本次生成"))
            ```

            ```artifact:prototype-mobile
            \(mobile)
            ```

            """),
            origin: origin,
            prototypeSnapshot: staleSnapshot
        )

        // 未冲突槽位照常落原路径
        let mobileURL = PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("03-prototypes/移动端原型.html")
        XCTAssertEqual(
            try String(contentsOf: mobileURL, encoding: .utf8), mobile,
            "未冲突块必须照常落原槽位路径"
        )
        // 冲突块落修订文件
        let revisions = try revisionFiles()
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(
            try String(contentsOf: revisions[0], encoding: .utf8),
            Self.bigHTML("本次生成")
        )

        try await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - ③ 同分钟冲突序号防覆盖（端到端）

    @MainActor
    func testConflictForkIncrementsSuffixWhenRevisionTargetExists() async throws {
        let external = Self.bigHTML("外部更新")
        try PMAgentStore.writeVerified(external, to: masterURL())
        let staleSnapshot = [
            ArtifactPath.prototype: ArtifactParser.sha256Hex(Self.bigHTML("旧版本"))
        ]
        // 预占同分钟修订目标（模拟同分钟已发生一次冲突）：文件名取当前探测结果
        let occupiedRel = AppModel.reserveRevisionPrototypePath(project: project, version: version)
        try PMAgentStore.writeVerified("已占用", to: PMAgentStore.versionURL(
            project: project, version: version
        ).appendingPathComponent(occupiedRel))

        let model = AppModel()
        model.settings = makeDeadEndpointSettings()
        model.selection = .session(project: project, version: version, sessionId: "cur")

        let origin = AppModel.ReplyOrigin(
            project: project, version: version, sessionId: "sOrigin", stage: .prototype
        )
        let generated = Self.bigHTML("本次生成")
        model.handleAssistantReply(
            makeReply("sOrigin", content: Self.prototypeReply(generated)),
            origin: origin,
            prototypeSnapshot: staleSnapshot
        )

        // 已占用文件不被改写；本次生成落 -2 序号文件
        XCTAssertEqual(
            try String(contentsOf: PMAgentStore.versionURL(
                project: project, version: version
            ).appendingPathComponent(occupiedRel), encoding: .utf8),
            "已占用",
            "已存在的修订目标文件不得被覆盖"
        )
        let revisions = try revisionFiles()
        XCTAssertEqual(revisions.count, 2)
        let suffixed = revisions.last { $0.lastPathComponent != (occupiedRel as NSString).lastPathComponent }
        XCTAssertEqual(suffixed?.lastPathComponent.hasSuffix("-2.html"), true, "同分钟冲突必须追加 -2 序号")
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(suffixed), encoding: .utf8), generated
        )

        try await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - ④ reserveRevisionPrototypePath 探测-递增

    func testReserveRevisionPrototypePathIncrementsOnExistingTarget() throws {
        let now = Date()
        let first = AppModel.reserveRevisionPrototypePath(
            project: project, version: version, now: now
        )
        XCTAssertTrue(first.hasPrefix("03-prototypes/原型-修订-"))
        XCTAssertTrue(first.hasSuffix(".html"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(first).path
        ))
        // 目标已存在 → -2；-2 也存在 → -3
        try PMAgentStore.writeVerified("x", to: PMAgentStore.versionURL(
            project: project, version: version
        ).appendingPathComponent(first))
        let second = AppModel.reserveRevisionPrototypePath(
            project: project, version: version, now: now
        )
        XCTAssertEqual(
            second, first.replacingOccurrences(of: ".html", with: "-2.html"),
            "同分钟目标已存在必须追加 -2 序号"
        )
        try PMAgentStore.writeVerified("x", to: PMAgentStore.versionURL(
            project: project, version: version
        ).appendingPathComponent(second))
        let third = AppModel.reserveRevisionPrototypePath(
            project: project, version: version, now: now
        )
        XCTAssertEqual(third, first.replacingOccurrences(of: ".html", with: "-3.html"))
    }

    // MARK: - ⑤ setAsMasterPrototype

    @MainActor
    func testSetAsMasterPrototypeCopiesSourceToMasterAndLogs() throws {
        try PMAgentStore.writeVerified(Self.bigHTML("旧主原型"), to: masterURL())
        let sourceRel = "03-prototypes/原型-修订-0917-1430.html"
        let promoted = Self.bigHTML("修订版")
        try PMAgentStore.writeVerified(
            promoted, to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(sourceRel)
        )

        let model = AppModel()
        model.selection = .session(project: project, version: version, sessionId: "cur")
        model.setAsMasterPrototype(relativePath: sourceRel)

        // 主槽位内容 == 源文件全文
        XCTAssertEqual(
            try String(contentsOf: masterURL(), encoding: .utf8), promoted,
            "设主后主槽位必须是源文件全文"
        )
        // 源文件保持不动
        XCTAssertEqual(
            try String(contentsOf: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(sourceRel), encoding: .utf8),
            promoted
        )
        // 📌 系统行落当前会话
        let rows = PMAgentStore.readLines(DiscussionEntry.self, from: discussionsURL())
        XCTAssertTrue(
            rows.contains {
                $0.sessionId == "cur" && $0.role == .system
                    && $0.content.contains("📌 已将「原型-修订-0917-1430.html」设为主原型")
            },
            "选主必须落系统行留痕（落当前会话）"
        )
        // 事件留痕
        XCTAssertTrue(
            PipelineEventLog.events(project: project, version: version).contains {
                $0.kind == .artifactGenerated && $0.detail.contains("原型选主")
            }
        )
        XCTAssertNil(model.notif, "成功路径不得弹错误通知")
    }

    @MainActor
    func testSetAsMasterPrototypeMissingSourceFailsVisiblyWithoutWrite() throws {
        let masterBefore = Self.bigHTML("旧主原型")
        try PMAgentStore.writeVerified(masterBefore, to: masterURL())

        let model = AppModel()
        model.selection = .session(project: project, version: version, sessionId: "cur")
        model.setAsMasterPrototype(relativePath: "03-prototypes/原型-不存在.html")

        // 不写盘
        XCTAssertEqual(
            try String(contentsOf: masterURL(), encoding: .utf8), masterBefore,
            "源文件读失败时不得写主槽位"
        )
        // 失败可见（通知条），事件不留痕
        XCTAssertEqual(model.notif?.variant, .error, "源文件读失败必须用户可见（不许无声）")
        XCTAssertFalse(
            PipelineEventLog.events(project: project, version: version)
                .contains { $0.detail.contains("原型选主") }
        )
    }

    @MainActor
    func testSetAsMasterPrototypeBlockedWhileVersionBusy() throws {
        let masterBefore = Self.bigHTML("旧主原型")
        try PMAgentStore.writeVerified(masterBefore, to: masterURL())
        let sourceRel = "03-prototypes/原型-修订-0917-1430.html"
        try PMAgentStore.writeVerified(
            Self.bigHTML("修订版"), to: PMAgentStore.versionURL(project: project, version: version)
                .appendingPathComponent(sourceRel)
        )

        let model = AppModel()
        model.selection = .session(project: project, version: version, sessionId: "cur")
        // 占位置位连带登记发起上下文 → isVersionBusy 为真（流完成落盘窗口）
        model.sessionStore.beginPreparingReply(
            sessionID: "cur",
            origin: SessionStore.StreamOrigin(project: project, version: version, sessionId: "cur")
        )
        defer { model.sessionStore.endPreparingReply(sessionID: "cur") }

        model.setAsMasterPrototype(relativePath: sourceRel)

        XCTAssertEqual(
            try String(contentsOf: masterURL(), encoding: .utf8), masterBefore,
            "版本 busy 时选主必须被拦截（防与流完成落盘竞态）"
        )
        XCTAssertEqual(model.notif?.variant, .error, "busy 拦截必须用户可见")
    }

    // MARK: - ⑥ 快照链（send 按阶段透传）

    @MainActor
    func testPrototypeSnapshotFlowsThroughSendOnlyForPrototypeStage() async throws {
        // file:// 假 SSE 端点：LLMClient 对 file URL 按 SSE 逐行解析至 [DONE]
        let sseFile = tempRoot.appendingPathComponent("mock/v1/chat/completions")
        try FileManager.default.createDirectory(
            at: sseFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let sse = """
        data: {"choices":[{"delta":{"content":"原型回复正文"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        try sse.write(to: sseFile, atomically: true, encoding: .utf8)
        var fileBase = sseFile.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        if fileBase.hasSuffix("/") { fileBase.removeLast() }

        var settings = makeDeadEndpointSettings()
        settings.stages[.prototype] = StageModelConfig(
            provider: "openai", model: "stub", baseURL: fileBase, keychainKey: testKeychainKey
        )
        settings.stages[.clarify] = StageModelConfig(
            provider: "openai", model: "stub", baseURL: fileBase, keychainKey: testKeychainKey
        )
        try KeychainStore.set("stub-key", forKey: testKeychainKey)

        let store = SessionStore()
        store.open(project: project, version: version, sessionId: "s1")
        let origin = SessionStore.StreamOrigin(project: project, version: version, sessionId: "s1")
        let snapshot = [ArtifactPath.prototype: "deadbeef"]

        // 原型阶段：快照经 onAssistant 透传（performSend 局部捕获 → 回调第二参数）
        var protoSnapshot: [String: String]?
        await store.send(
            "出原型", settings: settings, stage: .prototype, systemPrompt: "测试系统提示",
            pinnedOrigin: origin, prototypeSnapshot: snapshot
        ) { _, received in
            protoSnapshot = received
        }
        XCTAssertEqual(
            protoSnapshot, snapshot,
            "原型阶段 send 必须把快照经 onAssistant 透传给落盘段"
        )

        // 非原型阶段：误传也强制 nil（performSend 按 stage 闸死，防误校验）
        var clarifySnapshot: [String: String]? = snapshot
        await store.send(
            "澄清一下", settings: settings, stage: .clarify, systemPrompt: "测试系统提示",
            pinnedOrigin: origin, prototypeSnapshot: snapshot
        ) { _, received in
            clarifySnapshot = received
        }
        XCTAssertNil(
            clarifySnapshot,
            "非原型阶段快照必须强制失效（回调收到 nil）"
        )
    }

    // MARK: - ⑦ 选主可见性谓词

    func testPromotablePrototypePathPredicate() {
        // 非主槽位原型槽位文件：修订 / 方案 / 未知 slug
        XCTAssertTrue(AppModel.isPromotablePrototypePath("03-prototypes/原型-修订-0917-1430.html"))
        XCTAssertTrue(AppModel.isPromotablePrototypePath("03-prototypes/原型-方案A.html"))
        XCTAssertTrue(AppModel.isPromotablePrototypePath("03-prototypes/原型-wiki.html"))
        // 主槽位 / 分端槽位 / 非原型
        XCTAssertFalse(AppModel.isPromotablePrototypePath(ArtifactPath.prototype))
        XCTAssertFalse(AppModel.isPromotablePrototypePath("03-prototypes/移动端原型.html"))
        XCTAssertFalse(AppModel.isPromotablePrototypePath("03-prototypes/桌面端原型.html"))
        XCTAssertFalse(AppModel.isPromotablePrototypePath("02-structure/功能架构图.md"))
        XCTAssertFalse(AppModel.isPromotablePrototypePath("03-prototypes/随手.html"))
    }
}
