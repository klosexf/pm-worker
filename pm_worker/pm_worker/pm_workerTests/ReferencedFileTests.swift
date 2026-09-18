//
//  ReferencedFileTests.swift
//  pm_workerTests
//
//  产物台账「添加到对话」引用文件链路（离线单测）：
//  - ReferencedFileMaterial：读盘注入段（内容/路径/反幻觉指令）、缺失容错、
//    路径越界拒绝、嵌套围栏安全、单文件与总量截断、去重保序
//  - DiscussionEntry.files 编解码与旧格式兼容（无 files 字段的历史行照常解码）
//  全离线：rootOverride 指向临时目录，绝不触碰真实 ~/PMAgent/。
//

import XCTest
@testable import pm_worker

final class ReferencedFileTests: XCTestCase {

    private let project = "引用文件测试项目"
    private let version = "v1.0"
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-refs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
        try? PMAgentStore.bootstrap()
        try? PMAgentStore.createProject(named: project)
        try? PMAgentStore.createVersion(version, in: project)
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - 辅助

    @discardableResult
    private func put(_ relative: String, content: String) throws -> URL {
        let root = PMAgentStore.versionURL(project: project, version: version)
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private func section(_ refs: [String]) -> String? {
        ReferencedFileMaterial.section(
            refs: refs, project: project, version: version
        )
    }

    // MARK: - 读盘注入（AI 必须真正读到内容）

    func testSectionCarriesFileContentAndAntiHallucinationInstruction() throws {
        let content = "| 模块 | 页面 |\n| --- | --- |\n| 任务录入 | today.html |"
        try put("02-structure/模块-页面映射表.md", content: content)

        let text = try XCTUnwrap(section(["02-structure/模块-页面映射表.md"]))
        XCTAssertTrue(text.contains("02-structure/模块-页面映射表.md"), "须标注引用路径")
        XCTAssertTrue(text.contains(content), "文件原文必须原样进注入段")
        XCTAssertTrue(text.contains("视同你已打开"), "须声明内容等同已读")
        XCTAssertTrue(text.contains("不要"), "须显式禁止『无法访问文件系统』式回答")
    }

    // MARK: - 动态材料尾条协议（前缀缓存改造：引用文件正文并入尾条）

    func testContextTailComposeSplitRoundtrip() {
        // 空尾 = 原样（不产生标记，split 恒得空尾）
        let frozen = "冻结 system prompt"
        XCTAssertEqual(ContextTail.compose(system: frozen, tail: ""), frozen)
        XCTAssertEqual(ContextTail.split(frozen).system, frozen)
        XCTAssertEqual(ContextTail.split(frozen).tail, "")

        // 往返恒等：compose → split 还原冻结段与动态材料（字节级）
        let tail = "### 记忆\n- [结论] 目标用户是独立开发者"
        let composed = ContextTail.compose(system: frozen, tail: tail)
        XCTAssertTrue(composed.contains(ContextTail.marker), "复合 prompt 须含分割标记")
        let (system, extracted) = ContextTail.split(composed)
        XCTAssertEqual(system, frozen)
        XCTAssertEqual(extracted, tail)
    }

    func testTailAppendingAddsSingleUserMessageAfterHistory() {
        let history = [
            ChatMessage(role: .system, content: "冻结 system"),
            ChatMessage(role: .user, content: "用户问题"),
        ]
        // 空尾原样返回（无多余消息）
        XCTAssertEqual(VolatileTailMaterial.appending(history, tail: ""), history)

        // 非空尾：追加一条 user 角色尾条（当前用户消息之后），携带自述头防误认为用户发言
        let withTail = VolatileTailMaterial.appending(history, tail: "### 检索参考\n- [卡名/scope]")
        XCTAssertEqual(withTail.count, history.count + 1)
        XCTAssertEqual(withTail.last?.role, .user)
        XCTAssertTrue(withTail.last?.content.contains("【动态材料 · 系统注入】") ?? false)
        XCTAssertTrue(withTail.last?.content.contains("不是用户新发言") ?? false)
        XCTAssertTrue(withTail.last?.content.contains("### 检索参考") ?? false)
        // 历史本体不被改写
        XCTAssertEqual(Array(withTail.prefix(history.count)), history)
    }

    func testAugmentWithoutRefsIsIdentity() {
        // 引用文件段归位尾条后，无引用 = 无段落（section nil），尾条协议由上方两用例覆盖
        XCTAssertNil(section([]))
        XCTAssertNil(section(["  "]))
    }

    func testMissingFileIsReportedInsteadOfSilentlyDropped() throws {
        try put("01-requirements/澄清要点表.md", content: "# 表\n")
        let text = try XCTUnwrap(section(["02-structure/不存在.md", "01-requirements/澄清要点表.md"]))

        XCTAssertTrue(text.contains("读取失败"), "缺失文件须逐条标注，模型才能如实告知用户")
        XCTAssertTrue(text.contains("# 表"), "同轮其他文件照常注入")
    }

    // MARK: - 路径边界

    func testPathTraversalAndAbsolutePathsRejected() {
        XCTAssertNil(ReferencedFileMaterial.resolve("../secrets.md", project: project, version: version))
        XCTAssertNil(ReferencedFileMaterial.resolve("02-structure/../../x.md", project: project, version: version))
        XCTAssertNil(ReferencedFileMaterial.resolve("/etc/hosts", project: project, version: version))
        XCTAssertNil(ReferencedFileMaterial.resolve("~/x.md", project: project, version: version))
        XCTAssertNil(ReferencedFileMaterial.resolve("", project: project, version: version))
    }

    func testResolveKeepsInsideVersionDirectory() throws {
        let url = try XCTUnwrap(
            ReferencedFileMaterial.resolve(
                "04-prd/PRD文档.md", project: project, version: version
            )
        )
        let root = PMAgentStore.versionURL(project: project, version: version).path
        XCTAssertTrue(url.path.hasPrefix(root + "/"))
        XCTAssertTrue(url.path.hasSuffix("/04-prd/PRD文档.md"))
    }

    // MARK: - 围栏安全 / 截断 / 去重

    func testNestedBacktickFencesDoNotBreakInjection() throws {
        // 引用文件正文自带 ``` 代码块：围栏须升到 4 个反引号（PRD 预览踩过同款坑）
        let content = "# 原型说明\n```html\n<div>a</div>\n```\n"
        try put("03-prototypes/说明.md", content: content)

        let text = try XCTUnwrap(section(["03-prototypes/说明.md"]))
        XCTAssertTrue(text.contains("````markdown"), "正文含三反引号 → 围栏升为四")
        XCTAssertTrue(text.contains(content), "正文（含内层围栏）须完整保留")
    }

    func testPlainContentUsesTripleFence() throws {
        try put("04-prd/PRD文档.md", content: "# PRD\n正文\n")
        let text = try XCTUnwrap(section(["04-prd/PRD文档.md"]))
        XCTAssertTrue(text.contains("```markdown"))
        XCTAssertFalse(text.contains("````markdown"))
    }

    func testOversizedFileIsTruncatedWithNote() throws {
        let big = String(repeating: "长", count: ReferencedFileMaterial.perFileCharLimit + 500)
        try put("05-analysis/竞品分析.md", content: big)

        let text = try XCTUnwrap(section(["05-analysis/竞品分析.md"]))
        XCTAssertTrue(text.contains("已截断"), "超限须标注截断")
        // 注入正文不超过单文件上限（标注与头部不含正文体量）
        let body = text.split(separator: "\n").filter { $0.hasPrefix("长") }
        XCTAssertLessThanOrEqual(body.joined().count, ReferencedFileMaterial.perFileCharLimit)
    }

    func testDuplicateRefsDedupedPreservingOrder() throws {
        try put("01-requirements/澄清要点表.md", content: "# 表\n")
        let paths = ReferencedFileMaterial.deduped(
            ["01-requirements/澄清要点表.md", "01-requirements/澄清要点表.md", "  ", "b.md"]
        )
        XCTAssertEqual(paths, ["01-requirements/澄清要点表.md", "b.md"])

        let text = try XCTUnwrap(section(["01-requirements/澄清要点表.md", "01-requirements/澄清要点表.md"]))
        XCTAssertEqual(text.components(separatedBy: "### 引用 ").count - 1, 1, "同一文件只注入一次")
    }

    func testTooManyRefsSkipsBodyBeyondLimit() throws {
        var refs: [String] = []
        for index in 0..<(ReferencedFileMaterial.maxFiles + 1) {
            let path = "01-requirements/文件\(index).md"
            try put(path, content: "内容\(index)\n")
            refs.append(path)
        }
        let text = try XCTUnwrap(section(refs))
        XCTAssertTrue(text.contains("引用文件过多"), "超出上限的条目只标注、不注入正文")
        XCTAssertFalse(text.contains("内容\(ReferencedFileMaterial.maxFiles)"), "第 9 个文件正文不入注入段")
    }

    // MARK: - DiscussionEntry.files 编解码

    func testFilesRoundtrip() throws {
        let entry = DiscussionEntry(
            id: "e1", sessionId: "s1", role: .user,
            content: "这个文件里是什么？",
            files: ["02-structure/模块-页面映射表.md"],
            createdAt: "2026-09-15T10:00:00Z"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiscussionEntry.self, from: data)
        XCTAssertEqual(decoded.files, entry.files)
    }

    func testLegacyJSONWithoutFilesDecodesNil() throws {
        let legacy = """
        {"id":"e2","sessionId":"s1","role":"user","content":"旧格式行","createdAt":"2026-09-01T00:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(DiscussionEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.files)
        XCTAssertEqual(decoded.content, "旧格式行")
    }
}