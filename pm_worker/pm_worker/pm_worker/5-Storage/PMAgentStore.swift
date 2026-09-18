//
//  PMAgentStore.swift
//  pm_worker
//
//  ~/PMAgent/ 目录创建器与路径规范（design.md §5.1）。
//  文件系统是唯一事实源：本类型只负责目录创建、路径解析与 project/version 读写。
//

import Foundation

/// 产物文件名规范（中文名，用户在 Finder / 产物抽屉直接可读）。
/// 阶段子目录（01-requirements…07-reports）与系统文件（confirmed.json /
/// self-review.jsonl / score-card.json 等）不在此列——只有「给人看的产物」用中文名。
nonisolated enum ArtifactPath {
    static let clarification = "01-requirements/澄清要点表.md"
    /// 增补澄清进行中标记（回退协议 target=clarify 写入；要点表重新落盘推进时清除）。
    /// deriveStage 据此区分「有表待生成结构」与「有表但增补澄清中（回到①）」。
    static let clarifyAmend = "01-requirements/amend.json"
    static let architecture = "02-structure/功能架构图.md"
    static let coreFlows = "02-structure/核心流程图.md"
    static let modulePageMap = "02-structure/模块-页面映射表.md"
    static let businessFlows = "02-structure/业务流程图.md"
    static let prototype = "03-prototypes/可点击原型.html"
    static let prd = "04-prd/PRD文档.md"
    static let prdTruncatedDraft = "04-prd/PRD截断草稿.md"
    /// PRD 模板版本戳（落盘时记录生成所用模板版本；模板升级后据判定存量 PRD 失效）。
    static let prdMeta = "04-prd/prd-meta.json"
    static let competitiveAnalysis = "05-analysis/竞品分析.md"
    static let releaseNotes = "07-reports/发布说明.md"

    /// 旧英文文件名 → 中文文件名（ensureWorkspace 幂等迁移，存量项目无缝升级）。
    static let legacyRenames: [(legacy: String, current: String)] = [
        ("01-requirements/clarification.md", clarification),
        ("02-structure/architecture.md", architecture),
        ("02-structure/core-flows.md", coreFlows),
        ("02-structure/module-page-map.md", modulePageMap),
        ("02-structure/business-flows.md", businessFlows),
        ("03-prototypes/prototype-v1.html", prototype),
        ("04-prd/prd-v1.md", prd),
        ("04-prd/prd-truncated-draft.md", prdTruncatedDraft),
        ("05-analysis/competitive-analysis.md", competitiveAnalysis),
        ("07-reports/release-notes.md", releaseNotes),
    ]

    // MARK: - 多端原型槽位协议（artifact:prototype / prototype-<slug> 双向映射）

    /// 已知槽位表：块名 → 相对路径 + 显示名。默认槽位（prototype）兼容旧数据；
    /// 分端槽位各落独立文件（多端产品按端分块生成，一端一文件，说的份数=磁盘份数）；
    /// plan-a/b/c 为多方案对比槽位（用户要「出几版看看」时按方案分块）。
    static let knownPrototypeSlots: [(block: String, rel: String, display: String)] = [
        ("prototype", prototype, "交互原型"),
        ("prototype-mobile", "03-prototypes/移动端原型.html", "交互原型 · 移动端"),
        ("prototype-desktop", "03-prototypes/桌面端原型.html", "交互原型 · 桌面端"),
        ("prototype-tablet", "03-prototypes/平板端原型.html", "交互原型 · 平板端"),
        ("prototype-plan-a", "03-prototypes/原型-方案A.html", "交互原型 · 方案 A"),
        ("prototype-plan-b", "03-prototypes/原型-方案B.html", "交互原型 · 方案 B"),
        ("prototype-plan-c", "03-prototypes/原型-方案C.html", "交互原型 · 方案 C"),
    ]

    /// 块名是否为原型类（默认槽位或 prototype-<slug> 分端槽位）。
    /// 流式进度卡 / 结果卡 / 截断兜底等按类判定的入口统一走这里。
    static func isPrototypeBlock(_ name: String) -> Bool {
        name == "prototype" || name.hasPrefix("prototype-")
    }

    /// 块名 → 槽位（相对路径 + 显示名）。已知槽位查表；未知 slug 走通用命名
    /// `03-prototypes/原型-<slug>.html`（slug 口径与 artifact 块名一致，防路径注入）。
    static func prototypeSlot(forBlockName name: String) -> (relPath: String, display: String)? {
        if let known = knownPrototypeSlots.first(where: { $0.block == name }) {
            return (known.rel, known.display)
        }
        guard name.hasPrefix("prototype-") else { return nil }
        let slug = String(name.dropFirst("prototype-".count))
        guard isValidSlug(slug) else { return nil }
        return ("03-prototypes/原型-\(slug).html", "交互原型 · \(slug)")
    }

    /// 相对路径 → 块名（反向映射，含未知 slug round-trip；不认识的路径返回 nil）。
    static func prototypeBlockName(forRelativePath rel: String) -> String? {
        if let known = knownPrototypeSlots.first(where: { $0.rel == rel }) {
            return known.block
        }
        // 未知 slug：03-prototypes/原型-<slug>.html
        let prefix = "03-prototypes/原型-"
        guard rel.hasPrefix(prefix), rel.hasSuffix(".html") else { return nil }
        let slug = String(rel.dropFirst(prefix.count).dropLast(".html".count))
        guard isValidSlug(slug) else { return nil }
        return "prototype-\(slug)"
    }

    /// slug 合法性：非空 ASCII 字母/数字/连字符/下划线（与 artifact 块名解析口径一致）。
    private static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    /// 扫描产物根下 03-prototypes/ 槽位文件（磁盘是事实源），按
    /// 默认 → 移动端 → 桌面端 → 平板端 → 未知 slug（字母序）返回；
    /// 不认识的 .html 跳过（产物台账 / 版本对比走目录扫描，可见性不丢）。
    /// root：产物根（B1 草稿预演传提案目录；nil = 主线版本目录）。
    static func prototypeSlotFiles(
        project: String, version: String, root: URL? = nil
    ) -> [(blockName: String, relPath: String, display: String, url: URL)] {
        let dir = (root ?? PMAgentStore.versionURL(project: project, version: version))
            .appendingPathComponent("03-prototypes", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        let htmlNames = Set(entries.filter { $0.hasSuffix(".html") })
        var results: [(blockName: String, relPath: String, display: String, url: URL)] = []
        // 已知槽位按固定顺序
        for slot in knownPrototypeSlots {
            let filename = slot.rel.split(separator: "/").last.map(String.init) ?? slot.rel
            guard htmlNames.contains(filename) else { continue }
            results.append((slot.block, slot.rel, slot.display, dir.appendingPathComponent(filename)))
        }
        // 未知 slug 槽位
        let knownBlocks = Set(knownPrototypeSlots.map(\.block))
        let unknownFiles = htmlNames
            .filter { filename in
                guard let block = prototypeBlockName(forRelativePath: "03-prototypes/\(filename)") else {
                    return false
                }
                return !knownBlocks.contains(block)
            }
            .sorted()
        for filename in unknownFiles {
            let rel = "03-prototypes/\(filename)"
            guard let block = prototypeBlockName(forRelativePath: rel),
                  let slot = prototypeSlot(forBlockName: block) else { continue }
            results.append((block, rel, slot.display, dir.appendingPathComponent(filename)))
        }
        return results
    }
}

/// nonisolated：文件系统操作不受默认 MainActor 隔离约束。
nonisolated enum PMAgentStore {
    /// 测试与正式环境可注入不同根目录。
    nonisolated(unsafe) static var rootOverride: URL?

    /// 进程级写锁：串行化全部落盘写路径（产物覆盖写 writeVerified / jsonl 追加
    /// appendLine，以及外部写入器的「存在性检查+补建+追加」复合段），防跨线程
    /// FileManager 竞态（并发追加丢行损行 / 缺失文件竞态双建截断已有内容）。
    /// 锁约定（NSLock 非重入，务必遵守）：
    /// - 公开方法 appendLine / writeVerified 自行加锁；
    /// - 需要复合原子段的调用方（PipelineEventLog / ChangeLedger /
    ///   ArtifactParser.writeDecisions）自行 lock，持锁段内只调不加锁的底层
    ///   实现 appendLineLocked，禁止再调会自行加锁的公开方法（否则死锁）；
    /// - 单次写入一律直接走公开方法，不要手写 lock/unlock。
    nonisolated(unsafe) static let ioLock = NSLock()

    /// `~/PMAgent/`
    static var root: URL {
        rootOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PMAgent", isDirectory: true)
    }

    static var skillsDir: URL { root.appendingPathComponent("skills", isDirectory: true) }
    static var cardsDir: URL { root.appendingPathComponent("cards", isDirectory: true) }
    static var projectsDir: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    /// 全局记忆池（跨项目共享，与项目记忆完全分离）
    static var globalMemoryURL: URL { root.appendingPathComponent("memory.jsonl") }
    /// 「默认」项目（系统预建，不可删除）
    static var defaultProjectName: String { "默认" }

    static func projectURL(_ name: String) -> URL {
        projectsDir.appendingPathComponent(name, isDirectory: true)
    }

    static func versionURL(project: String, version: String) -> URL {
        projectURL(project).appendingPathComponent(version, isDirectory: true)
    }

    static func jsonlURL(project: String, version: String, file: String) -> URL {
        versionURL(project: project, version: version).appendingPathComponent(file)
    }

    /// 产物根目录（B1 草稿预演分流）：proposalSessionId 为 nil → 主线版本目录；
    /// 非 nil → 草稿提案目录 05-artifacts/proposals/<sessionId>/（草稿预演产物
    /// 按主线同构相对路径镜像落盘，合并时整目录对拷入主线）。
    static func artifactRoot(
        project: String, version: String, proposalSessionId: String?
    ) -> URL {
        let base = versionURL(project: project, version: version)
        guard let sid = proposalSessionId, !sid.isEmpty else { return base }
        return base.appendingPathComponent("05-artifacts/proposals/\(sid)", isDirectory: true)
    }

    // MARK: - Bootstrap

    /// 首次启动调用：建 skills/ / cards/ / Projects/默认/（含 project.json 与 unversioned/），
    /// 并把 bundle 内置技能播种到 skills/。幂等——已存在则跳过。
    /// seedSkills=false 供需要干净 skills/ 的隔离测试使用。
    static func bootstrap(seedSkills: Bool = true) throws {
        let fm = FileManager.default
        for dir in [skillsDir, cardsDir, projectsDir] where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if seedSkills { seedBundledSkills() }

        let defaultDir = projectURL(defaultProjectName)
        if !fm.fileExists(atPath: defaultDir.path) {
            try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            try writeProject(
                ProjectDocument(id: "proj_default", name: defaultProjectName),
                to: defaultDir
            )
        }

        let defaultUnversioned = defaultDir.appendingPathComponent("unversioned", isDirectory: true)
        if !fm.fileExists(atPath: defaultUnversioned.path) {
            try fm.createDirectory(at: defaultUnversioned, withIntermediateDirectories: true)
        }
    }

    /// 出厂播种（Task 4.7 技能库数据源）：bundle 内置技能 → skills/。
    /// PBXFileSystemSynchronizedRootGroup 会把 Resources/skills/ 拍平到 bundle 根，
    /// 与 PRD 模板 / 规则 / 知识卡 md 混放——故双探测子目录，并仅拷贝能被
    /// SkillFrontMatterParser 解析出非空 name 的文件（模板等无 name 字段，自然排除）。
    /// 目标名用 `{name}.md`（非 bundle 原文件名）——与索引 doc_path 口径一致。
    /// 幂等：目标文件已存在则跳过，不覆盖用户编辑；播种失败不阻塞 bootstrap。
    private static func seedBundledSkills() {
        let fm = FileManager.default
        let bundled = ["skills", nil].flatMap { subdirectory in
            Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: subdirectory) ?? []
        }
        for url in bundled {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let skill = SkillFrontMatterParser.parse(text),
                  !skill.name.isEmpty
            else { continue }
            let target = skillsDir.appendingPathComponent("\(skill.name).md")
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.copyItem(at: url, to: target)
        }
    }

    // MARK: - Project

    /// 新建项目：真实文件夹 + project.json + knowledge/ + unversioned/。
    static func createProject(named name: String) throws -> ProjectDocument {
        let dir = projectURL(name)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw NSError(
                domain: "PMAgentStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "项目已存在：\(name)"]
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = ProjectDocument(name: name)
        try writeProject(project, to: dir)
        try fm.createDirectory(
            at: dir.appendingPathComponent("knowledge", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: dir.appendingPathComponent("unversioned", isDirectory: true),
            withIntermediateDirectories: true
        )
        return project
    }

    static func readProject(_ name: String) throws -> ProjectDocument? {
        try read(ProjectDocument.self, at: projectURL(name).appendingPathComponent("project.json"))
    }

    static func writeProject(_ project: ProjectDocument, to dir: URL) throws {
        try write(project, to: dir.appendingPathComponent("project.json"))
    }

    /// 列出全部项目（磁盘目录为准）。
    static func listProjects() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }  // 隐藏目录（.git 等）不是项目
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted { $0 == defaultProjectName && $1 != defaultProjectName }
    }

    /// 项目目录创建时间（任务列表按创建时间倒序用）；读取失败返回 nil。
    static func projectCreatedAt(_ projectName: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: projectURL(projectName).path)
        return attrs?[.creationDate] as? Date
    }

    // MARK: - Version

    /// 新建版本目录：01-requirements … 07-reports + version.json + 三个 jsonl。
    static func createVersion(
        _ version: String,
        in projectName: String,
        scope: [String] = [],
        inheritedFrom: String? = nil
    ) throws -> VersionDocument {
        let dir = versionURL(project: projectName, version: version)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw NSError(
                domain: "PMAgentStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "版本已存在：\(projectName)/\(version)"]
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stageDirs = [
            "01-requirements", "02-structure", "03-prototypes",
            "04-prd", "05-analysis", "06-discussions", "07-reports",
        ]
        for stage in stageDirs {
            try fm.createDirectory(
                at: dir.appendingPathComponent(stage, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let doc = VersionDocument(version: version, scope: scope, inheritedFrom: inheritedFrom)
        try write(doc, to: dir.appendingPathComponent("version.json"))

        // append-only 日志清单（决策/风险/会话/事件/变更提案）：存在即不覆盖
        for file in ["decisions.jsonl", "risks.jsonl", "discussions.jsonl", "events.jsonl", "changes.jsonl"] {
            let url = dir.appendingPathComponent(file)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
        }

        // 回写 project.json 的版本清单
        if var project = try readProject(projectName) {
            if !project.versions.contains(version) { project.versions.append(version) }
            if project.currentVersion == nil { project.currentVersion = version }
            try writeProject(project, to: projectURL(projectName))
        }
        return doc
    }

    static func readVersion(project: String, version: String) throws -> VersionDocument? {
        try read(
            VersionDocument.self,
            at: versionURL(project: project, version: version).appendingPathComponent("version.json")
        )
    }

    /// 幂等工作区保障（M2）：任意版本目录（含 unversioned）补齐阶段子目录
    /// + 三个 jsonl 文件。unversioned 不写 version.json（它不是发布单元）。
    static func ensureWorkspace(project: String, version: String) throws {
        let dir = versionURL(project: project, version: version)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for stage in [
            "01-requirements", "02-structure", "03-prototypes",
            "04-prd", "05-analysis", "06-discussions", "07-reports",
        ] {
            let d = dir.appendingPathComponent(stage, isDirectory: true)
            if !fm.fileExists(atPath: d.path) {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
        }
        for file in ["decisions.jsonl", "risks.jsonl", "discussions.jsonl", "events.jsonl", "changes.jsonl"] {
            let url = dir.appendingPathComponent(file)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    throw NSError(
                        domain: "PMAgentStore", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "无法创建 \(url.path)"]
                    )
                }
            }
        }
        migrateLegacyArtifactNames(dir: dir)
    }

    /// 旧英文产物名 → 中文名（幂等）：旧名存在且新名不存在才搬，失败不阻塞工作区保障。
    private static func migrateLegacyArtifactNames(dir: URL) {
        let fm = FileManager.default
        for rename in ArtifactPath.legacyRenames {
            let oldURL = dir.appendingPathComponent(rename.legacy)
            let newURL = dir.appendingPathComponent(rename.current)
            guard fm.fileExists(atPath: oldURL.path),
                  !fm.fileExists(atPath: newURL.path) else { continue }
            try? fm.moveItem(at: oldURL, to: newURL)
        }
    }

    // MARK: - 确认坞静默（「稍后再说」每版本每阶段只弹一次，design.md §6.1）

    /// 已静默闸口持久化文件（版本级、跨启动）：静默纪律不因重启失忆。
    static func confirmSilenceURL(project: String, version: String) -> URL {
        versionURL(project: project, version: version).appendingPathComponent("confirm-silence.json")
    }

    /// 读取已静默的确认闸口阶段 key（clarify / structure / prototype）。
    /// 缺失或损坏 = 空集（可重建语义：静默丢失只是坞多弹一次，不致命）。
    static func readConfirmSilence(project: String, version: String) -> Set<String> {
        guard let stages = try? read(
            [String].self, at: confirmSilenceURL(project: project, version: version)
        ) else { return [] }
        return Set(stages)
    }

    static func writeConfirmSilence(
        _ stages: Set<String>, project: String, version: String
    ) throws {
        try write(stages.sorted(), to: confirmSilenceURL(project: project, version: version))
    }

    // MARK: - 会话附件（图片走文件引用，base64 不落 jsonl）

    /// 某 project/version 的会话附件目录（attachments/）。
    static func attachmentsDir(project: String, version: String) -> URL {
        versionURL(project: project, version: version)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// 存入附件图片：拷贝为 attachments/{uuid}.{ext}，返回文件名（jsonl 只存引用）。
    static func saveAttachment(
        data: Data, fileExtension: String, project: String, version: String
    ) throws -> String {
        let dir = attachmentsDir(project: project, version: version)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(fileExtension)"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// 读附件文件数据（渲染缩略 / 组装多模态请求用；缺文件返回 nil 不抛）。
    static func readAttachment(
        _ name: String, project: String, version: String
    ) -> Data? {
        try? Data(contentsOf: attachmentsDir(project: project, version: version)
            .appendingPathComponent(name))
    }

    /// 产物写入（write-then-verify，design.md E5）：写后回读校验，不一致抛错。
    /// 整体持 ioLock（写 + 回读校验 + 广播为一个原子段，防并发覆盖写交错）。
    static func writeVerified(_ text: String, to url: URL) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
        let readBack = try String(contentsOf: url, encoding: .utf8)
        guard readBack == text else {
            throw NSError(
                domain: "PMAgentStore", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "产物写入后回读校验失败：\(url.path)"]
            )
        }
        // 落盘成功即广播（右栏「文件」台账实时刷新，免切 Tab 重扫）。
        // 本方法 nonisolated、可能被后台上下文调用，监听侧须 receive(on: main)。
        NotificationCenter.default.post(
            name: Notification.Name("pm.worker.artifacts.changed"), object: nil
        )
    }

    /// 列出某项目下全部版本目录（磁盘为准）。
    static func listVersions(in projectName: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectURL(projectName), includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }  // 隐藏目录（.git 等）不是版本
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: - Project / Version 结构操作（侧栏行「更多」菜单）

    /// 结构操作错误工厂（侧栏菜单的人话报错，经 AppModel 透传到通知条）。
    private static func structError(_ message: String) -> NSError {
        NSError(
            domain: "PMAgentStore", code: 10,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// 目录名合法性：非空、无路径分隔符（/ 与 :）、非「.」「..」——目录名直接拼路径。
    private static func validateNodeName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":") else {
            throw structError("名称不能为空，且不能包含 / 或 : 等路径字符")
        }
    }

    /// 重命名项目：目录整体 move + project.json name 回写。
    /// 「默认」是系统预建项目（newSession/startTask 的兜底落点），不可重命名。
    static func renameProject(from oldName: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateNodeName(trimmed)
        guard oldName != defaultProjectName else {
            throw structError("系统预建项目「\(defaultProjectName)」不可重命名")
        }
        let fm = FileManager.default
        let src = projectURL(oldName)
        guard fm.fileExists(atPath: src.path) else {
            throw structError("项目不存在：\(oldName)")
        }
        let dst = projectURL(trimmed)
        guard !fm.fileExists(atPath: dst.path) else {
            throw structError("项目已存在：\(trimmed)")
        }
        try fm.moveItem(at: src, to: dst)
        if var project = try readProject(trimmed) {
            project.name = trimmed
            try writeProject(project, to: dst)
        }
    }

    /// 删除项目：整目录移除（含全部版本、会话与产物）。「默认」不可删除。
    static func deleteProject(_ name: String) throws {
        guard name != defaultProjectName else {
            throw structError("系统预建项目「\(defaultProjectName)」不可删除")
        }
        let dir = projectURL(name)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw structError("项目不存在：\(name)")
        }
        try FileManager.default.removeItem(at: dir)
    }

    /// 重命名版本：目录 move + version.json version 字段 + project.json
    /// versions 清单与 currentVersion 回写。unversioned 是会话兜底落点
    /// （系统保留）、已封板版本是只读快照，两者均拒绝。
    static func renameVersion(project: String, from oldName: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateNodeName(trimmed)
        guard oldName != "unversioned" else {
            throw structError("「unversioned」为系统保留版本，不可重命名")
        }
        if let doc = try readVersion(project: project, version: oldName), doc.status == .released {
            throw structError("已封板版本为只读快照，不可重命名")
        }
        let fm = FileManager.default
        let src = versionURL(project: project, version: oldName)
        guard fm.fileExists(atPath: src.path) else {
            throw structError("版本不存在：\(project)/\(oldName)")
        }
        let dst = versionURL(project: project, version: trimmed)
        guard !fm.fileExists(atPath: dst.path) else {
            throw structError("版本已存在：\(project)/\(trimmed)")
        }
        try fm.moveItem(at: src, to: dst)
        if var doc = try readVersion(project: project, version: trimmed) {
            doc.version = trimmed
            try write(doc, to: dst.appendingPathComponent("version.json"))
        }
        if var projectDoc = try readProject(project) {
            if let index = projectDoc.versions.firstIndex(of: oldName) {
                projectDoc.versions[index] = trimmed
            }
            if projectDoc.currentVersion == oldName { projectDoc.currentVersion = trimmed }
            try writeProject(projectDoc, to: projectURL(project))
        }
    }

    /// 删除版本：整目录移除 + project.json versions 清单回写。
    /// unversioned（系统保留）与已封板版本（只读快照）拒绝删除。
    static func deleteVersion(project: String, version: String) throws {
        guard version != "unversioned" else {
            throw structError("「unversioned」为系统保留版本，不可删除")
        }
        if let doc = try readVersion(project: project, version: version), doc.status == .released {
            throw structError("已封板版本为只读快照，不可删除")
        }
        let dir = versionURL(project: project, version: version)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw structError("版本不存在：\(project)/\(version)")
        }
        try FileManager.default.removeItem(at: dir)
        if var projectDoc = try readProject(project) {
            projectDoc.versions.removeAll { $0 == version }
            try writeProject(projectDoc, to: projectURL(project))
        }
    }

    // MARK: - JSONL

    /// append-only：一行一条，永不覆盖。持 ioLock（并发追加不丢行不损行）。
    /// 复合原子段的调用方请自行 lock 后调 appendLineLocked（见 ioLock 锁约定）。
    static func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        try appendLineLocked(value, to: url)
    }

    /// append-only 底层实现（不加锁）。锁约定：调用方必须已持有 ioLock，
    /// 否则并发下存在性检查与 seekToEnd+write 不原子（供持锁段内部调用）。
    static func appendLineLocked<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "PMAgentStore", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "JSONL 文件不存在：\(url.path)"]
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
    }

    static func readLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n")
            .compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    // MARK: - Private

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
