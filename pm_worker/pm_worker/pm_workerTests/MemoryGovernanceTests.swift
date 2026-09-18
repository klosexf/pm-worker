//
//  MemoryGovernanceTests.swift
//  pm_workerTests
//
//  记忆层测试（方案 A 两档作用域定稿）：
//  - 注入序：项目 > 全局（具体性优先），池内新条目在前（超预算先丢最旧）
//  - 项目池读写 + 版本溯源标签；约束/否决项保护层（超预算不裁）
//  - 整理动作白名单解析 + 碑文回链
//  - 提升为全局（项目经验 → 全局池副本 + 原条目碑文回链）
//  - 旧 version 作用域数据读时投影（project + versions 标签）
//  磁盘用 PMAgentStore.rootOverride 临时目录，不依赖网络。
//

import XCTest
@testable import pm_worker

final class MemoryGovernanceTests: XCTestCase {
    var tempRoot: URL!
    let project = "测试项目"
    let version = "v1"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-memory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        PMAgentStore.rootOverride = nil
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: - 磁盘脚手架

    /// 建版本目录 + discussions.jsonl，append 一条带记忆载荷的系统行。
    private func seedMemoryLine(
        project: String, version: String, entry: MemoryEntry
    ) throws {
        let url = PMAgentStore.jsonlURL(
            project: project, version: version, file: "discussions.jsonl"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "seed", role: .system,
            content: "seed", think: nil, memory: entry,
            createdAt: ISO8601.timestamp()
        )
        try PMAgentStore.appendLine(line, to: url)
    }

    private func makeEntry(
        scope: MemoryEntry.Scope, kind: MemoryEntry.Kind, content: String,
        createdAt: String, versions: String? = nil
    ) -> MemoryEntry {
        MemoryEntry(
            scope: scope,
            scopeId: scope == .global ? "" : project,
            kind: kind, content: content, versions: versions, createdAt: createdAt
        )
    }

    // MARK: - 注入序（池内新条目在前）

    func testInjectionContextNewestFirstWithinScope() throws {
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .conclusion, content: "旧结论",
                createdAt: "2026-09-14T10:00:00Z"
            )
        )
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .conclusion, content: "新结论",
                createdAt: "2026-09-14T11:00:00Z"
            )
        )

        let store = MemoryStore(project: project, version: version)
        let context = store.injectionContext
        let newRange = try XCTUnwrap(context.range(of: "新结论"))
        let oldRange = try XCTUnwrap(context.range(of: "旧结论"))
        XCTAssertLessThan(
            newRange.lowerBound, oldRange.lowerBound,
            "同池内新条目应排在前（超预算从尾部丢时先丢最旧）"
        )
    }

    // MARK: - 注入序（项目 > 全局，具体性优先）

    func testInjectionContextProjectBeforeGlobal() throws {
        // 全局池条目（跨项目）+ 项目池条目（更具体）：项目应排在前
        MemoryStore.ensureJSONLFile(at: PMAgentStore.globalMemoryURL)
        let globalLine = DiscussionEntry(
            id: UUID().uuidString, sessionId: "seed", role: .system,
            content: "seed", think: nil,
            memory: makeEntry(
                scope: .global, kind: .conclusion, content: "全局方法论",
                createdAt: "2026-09-14T09:00:00Z"
            ),
            createdAt: ISO8601.timestamp()
        )
        try PMAgentStore.appendLine(globalLine, to: PMAgentStore.globalMemoryURL)
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .conclusion, content: "项目定位",
                createdAt: "2026-09-14T08:00:00Z"
            )
        )

        let store = MemoryStore(project: project, version: version)
        let context = store.injectionContext
        let projectRange = try XCTUnwrap(context.range(of: "项目定位"))
        let globalRange = try XCTUnwrap(context.range(of: "全局方法论"))
        XCTAssertLessThan(
            projectRange.lowerBound, globalRange.lowerBound,
            "注入优先级：项目记忆 > 全局记忆（具体性优先，非时长优先）"
        )
    }

    // MARK: - 项目池 memory.jsonl 读写

    func testManualAddProjectScopeWritesProjectMemoryFile() throws {
        let store = MemoryStore(project: project, version: version)
        let error = store.addManualEntry(
            kind: .constraint, scope: .project, content: "全流程零遥测"
        )
        XCTAssertNil(error)

        let fileURL = MemoryStore.projectMemoryURL(project: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(
            store.effective.filter { $0.scope == .project }.count, 1,
            "项目级条目应进入有效池"
        )

        // 其他版本的 MemoryStore 也能读到（项目池跨版本共享）
        let v2Store = MemoryStore(project: project, version: "v2")
        XCTAssertTrue(v2Store.effective.contains { $0.content == "全流程零遥测" })
    }

    // MARK: - 全局池与项目池完全分离

    func testGlobalPoolIsolationAndInjection() throws {
        // 全局池写入
        let error = MemoryStore.addEntry(
            project: nil, kind: .conclusion, versions: nil, content: "需求文档宁可短而明确"
        )
        XCTAssertNil(error)

        // 全局池条目落在 ~/PMAgent/memory.jsonl，不在任何项目目录下
        let globalURL = PMAgentStore.globalMemoryURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalURL.path))
        let globalEntries = MemoryStore.readPoolLines(project: nil)
        XCTAssertEqual(globalEntries.count, 1)
        XCTAssertEqual(globalEntries.first?.scope, .global)

        // 项目池读取（当前项目）也能看到全局条目（注入需要），但两池文件分离
        let store = MemoryStore(project: project, version: version)
        XCTAssertTrue(
            store.effective.contains { $0.content == "需求文档宁可短而明确" },
            "全局条目注入所有项目"
        )
        let projectEntries = MemoryStore.readPoolLines(project: project)
        XCTAssertFalse(
            projectEntries.contains { $0.scope == .global },
            "项目池数据源不含全局池文件——两池完全分离"
        )

        // 全局池条目失效：碑文写全局池，项目池不受影响
        let entry = try XCTUnwrap(globalEntries.first)
        XCTAssertNil(
            MemoryStore.invalidateEntry(project: nil, entry: entry, note: "手动失效")
        )
        let store2 = MemoryStore(project: project, version: version)
        XCTAssertFalse(
            store2.effective.contains { $0.content == "需求文档宁可短而明确" }
        )
    }

    // MARK: - 约束保护层（超预算不裁）

    func testTrimMemoryProtectsConstraintsAndRejections() async throws {
        let builder = ContextBuilder(
            database: nil, embedder: DeterministicHashEmbedder(),
            budgets: [.memory: 1]   // 预算压到 1：无保护时全裁
        )
        let memoryText = """
        - [结论] 目标用户是独立开发者
        - [约束] 只做 macOS 桌面端
        - [否决项] 不做小程序
        - [全局] [约束] 数据全部留在本地
        """
        let assembly = await builder.assemble(
            stage: .classify, project: project, stageQuery: "q",
            memoryContext: memoryText, calibration: []
        ) { $0 }

        // 动态材料不进 systemPrompt（ContextTail 尾条协议）——断言落在 injectionText
        XCTAssertTrue(
            assembly.injectionText.contains("只做 macOS 桌面端"),
            "约束为保护层，预算压力下不得裁剪"
        )
        XCTAssertTrue(
            assembly.injectionText.contains("不做小程序"),
            "否决项为保护层，预算压力下不得裁剪"
        )
        XCTAssertTrue(
            assembly.injectionText.contains("数据全部留在本地"),
            "全局来源前缀的约束行同为保护层（标记子串匹配）"
        )
        XCTAssertFalse(
            assembly.injectionText.contains("目标用户是独立开发者"),
            "结论无保护，超预算应被裁掉"
        )
    }

    // MARK: - 整理动作解析（白名单过滤）

    func testParseConsolidationFiltersInvalidActions() {
        let reply = """
        ```json
        [{"action": "supersede", "id": "m1", "keepId": "m2", "reason": "近重复"},
         {"action": "supersede", "id": "m3", "keepId": "m3", "reason": "自合并应过滤"},
         {"action": "supersede", "id": "m4", "reason": "缺 keepId 应过滤"},
         {"action": "invalidate", "id": "m5", "reason": "过时"},
         {"action": "destroy", "id": "m6", "reason": "未知动作应过滤"}]
        ```
        """
        let actions = MemoryStore.parseConsolidation(reply)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].id, "m1")
        XCTAssertEqual(actions[0].keepId, "m2")
        XCTAssertEqual(actions[1].id, "m5")
    }

    // MARK: - 整理应用（碑文 + 回链）

    func testApplyConsolidationTombstonesAndRelinks() throws {
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .conclusion, content: "重复结论A",
                createdAt: "2026-09-14T10:00:00Z"
            )
        )
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .conclusion, content: "重复结论B",
                createdAt: "2026-09-14T11:00:00Z"
            )
        )
        let store = MemoryStore(project: project, version: version)
        let a = try XCTUnwrap(store.effective.first { $0.content == "重复结论A" })
        let b = try XCTUnwrap(store.effective.first { $0.content == "重复结论B" })

        let report = store.applyConsolidation([
            MemoryStore.ConsolidationAction(
                action: "supersede", id: a.id, keepId: b.id, reason: "近重复"
            )
        ])
        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(store.effective.count, 1)
        XCTAssertEqual(store.effective.first?.id, b.id)
        XCTAssertEqual(store.effective.first?.content, "重复结论B")
    }

    // MARK: - 提升为全局（项目经验 → 全局池；两池唯一通道）

    func testPromoteEntryToGlobalScope() throws {
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .experience, content: "原型先行比文字讨论收敛快",
                createdAt: "2026-09-14T10:00:00Z"
            )
        )
        let store = MemoryStore(project: project, version: version)
        let entry = try XCTUnwrap(store.effective.first)

        XCTAssertNil(
            MemoryStore.promoteEntryToGlobal(project: project, entry: entry)
        )

        // 全局池出现副本（scope=global，来源标注），原项目条目碑文失效
        let globalEntries = MemoryStore.applySupersede(
            MemoryStore.readPoolLines(project: nil)
        )
        let promoted = try XCTUnwrap(
            globalEntries.first { $0.content == "原型先行比文字讨论收敛快" }
        )
        XCTAssertEqual(promoted.scope, .global, "提升后应进入全局池")
        XCTAssertTrue(
            promoted.sourceRef?.contains(project) == true,
            "全局副本应标注来源项目（可追溯）"
        )

        // 新读取视角：全局副本有效，原项目条目已被碑文失效（不双份注入）
        let store2 = MemoryStore(project: project, version: version)
        XCTAssertEqual(
            store2.effective.filter { $0.content == "原型先行比文字讨论收敛快" }.count,
            1,
            "提升后只保留全局副本，原项目条目不再注入"
        )
        XCTAssertEqual(store2.effective.first?.scope, .global)
    }

    // MARK: - 旧 version 作用域数据读时投影

    func testLegacyVersionScopeEntriesAreMigrated() throws {
        // 手工构造旧格式 JSON（scope=version，无 versions 字段）
        let legacyJSON = """
        {"id":"m_legacy","scope":"version","scopeId":"v1","kind":"constraint",
         "content":"只做 macOS 桌面端","invalidated":false,
         "createdAt":"2026-09-14T10:00:00Z"}
        """
        .replacingOccurrences(of: "\n", with: "")
        let entry = try JSONDecoder().decode(MemoryEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(entry.scope, .project, "旧 version 作用域应投影为 project")
        XCTAssertEqual(entry.versions, "v1", "旧版本号应转为版本溯源标签")

        // 新写入不受影响：project 条目编码后 scope 为 project
        let modern = makeEntry(
            scope: .project, kind: .conclusion, content: "新条目",
            createdAt: "2026-09-14T11:00:00Z"
        )
        let data = try JSONEncoder().encode(modern)
        let roundtrip = try JSONDecoder().decode(MemoryEntry.self, from: data)
        XCTAssertEqual(roundtrip, modern, "新模型编码-解码往返无损")
    }

    // MARK: - 沉淀 prompt 契约（必抽清单 + 原话原则）

    func testMemoryExtractionPromptHasMustExtractList() {
        let prompt = AgentPrompts.memoryExtraction(transcript: "对话")
        XCTAssertTrue(prompt.hasPrefix("## 对话记录\n对话"), "transcript 置顶（确认链三连抽共享缓存前缀）")
        XCTAssertTrue(prompt.contains("必抽清单"))
        XCTAssertTrue(prompt.contains("平台"), "平台/端边界必须出现在必抽清单")
        XCTAssertTrue(prompt.contains("原话"), "约束与否决项必须保留用户原话")
        XCTAssertTrue(prompt.contains("数字目标"), "数字目标必须出现在必抽清单")
    }

    // MARK: - 覆盖语义回归（碑文兜底序不变量）

    func testProjectMemoryTombstoneWinsByReadOrder() throws {
        // 版本文件里有一条有效条目
        try seedMemoryLine(
            project: project, version: version,
            entry: makeEntry(
                scope: .project, kind: .conclusion, content: "待失效结论",
                createdAt: "2026-09-14T10:00:00Z"
            )
        )
        // 项目级文件里追加同 id 的碑文（模拟封板只读兜底写入）
        let store = MemoryStore(project: project, version: version)
        let entry = try XCTUnwrap(store.effective.first)
        let fallbackURL = MemoryStore.projectMemoryURL(project: project)
        MemoryStore.ensureJSONLFile(at: fallbackURL)
        var tombstone = entry
        tombstone.invalidated = true
        let line = DiscussionEntry(
            id: UUID().uuidString, sessionId: "manual", role: .system,
            content: "碑文", think: nil, memory: tombstone,
            createdAt: ISO8601.timestamp()
        )
        try PMAgentStore.appendLine(line, to: fallbackURL)

        store.reload()
        XCTAssertTrue(
            store.effective.isEmpty,
            "项目级文件的碑文按读序必胜（封板兜底写入语义的前提）"
        )
    }
}
