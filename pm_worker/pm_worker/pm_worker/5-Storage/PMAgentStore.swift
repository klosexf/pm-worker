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
}

/// nonisolated：文件系统操作不受默认 MainActor 隔离约束。
nonisolated enum PMAgentStore {
    /// 测试与正式环境可注入不同根目录。
    nonisolated(unsafe) static var rootOverride: URL?

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

        // append-only 日志三件套：存在即不覆盖
        for file in ["decisions.jsonl", "risks.jsonl", "discussions.jsonl", "events.jsonl"] {
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
        for file in ["decisions.jsonl", "risks.jsonl", "discussions.jsonl", "events.jsonl"] {
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
    static func writeVerified(_ text: String, to url: URL) throws {
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

    /// append-only：一行一条，永不覆盖。
    static func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
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
