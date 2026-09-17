//
//  IndexRebuilder.swift
//  pm_worker
//
//  索引重建器（design.md §5.3）：扫描 knowledge/ + cards/ + skills/
//  → 逐条 upsert 进 index.sqlite。索引可随时删掉全量重建，以文件系统为准。
//  - 同步 rebuild：零长度 embedding 占位 blob（M0 兼容路径，测试在用）。
//  - 异步 rebuild / indexCard / indexSkill（M4）：真实向量编码——
//    卡片对 content 编码，技能对四字段文本（name + when_to_use + best_for + tags）编码。
//    indexCard 供 KnowledgeExtractor 落卡后调用（写完即建索引，签名不可变）。
//

import Foundation
import GRDB

/// nonisolated：存储层纯类型（文件扫描 + SQLite upsert + 向量编码注入）。
nonisolated enum IndexRebuilder {
    struct RebuildReport: Equatable {
        var knowledgePoints = 0
        var skills = 0
    }

    /// 全量重建（零 embedding 占位路径，M0 兼容）：
    /// 先清空 knowledge_points / skills，再从文件扫描 upsert。
    /// risks / pipeline_runs / mcp_tasks 各有事实源或运行时写入方，不在此重建范围。
    /// **仅供测试使用**：占位向量（空 blob）会让检索层跳过整行——生产入口
    /// （AppModel.reindexStaleSkills / SettingsDialog.rebuildIndex）必须走下面
    /// 带 embeddingProvider 的真实向量版，否则技能语义检索恒零命中，
    /// 路由退化为阶段锚点每轮兜底（2026-09-15 真实踩坑，勿回退）。
    static func rebuild(database: AppDatabase) throws -> RebuildReport {
        var report = RebuildReport()

        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM knowledge_points")
            try db.execute(sql: "DELETE FROM skills")
        }

        let scanned = scanAll()

        try database.dbQueue.write { db in
            for card in scanned.globalCards {
                try upsertCard(card, projectId: "", db: db, embedding: Data())
                report.knowledgePoints += 1
            }
            for entry in scanned.projectCards {
                try upsertCard(entry.card, projectId: entry.projectId, db: db, embedding: Data())
                report.knowledgePoints += 1
            }
            for entry in scanned.skills {
                try upsertSkill(entry.skill, db: db, embedding: Data(), docPath: entry.url.path)
                report.skills += 1
            }
        }

        return report
    }

    /// 全量重建（M4 真实向量路径）：逻辑同同步版，
    /// 但卡片对 content 编码、技能对四字段文本编码，写真实 blob。
    static func rebuild(database: AppDatabase, embeddingProvider: EmbeddingProviding) async throws -> RebuildReport {
        try await database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM knowledge_points")
            try db.execute(sql: "DELETE FROM skills")
        }

        let scanned = scanAll()

        // 批量编码（卡片、技能各一次请求）：卡片正文 + 技能四字段文本
        let cardTexts = scanned.globalCards.map(\.content)
            + scanned.projectCards.map { $0.card.content }
        let skillTexts = scanned.skills.map { SkillLoader.fourFieldText($0.skill) }
        let cardVectors = try await embedBatch(cardTexts, embeddingProvider: embeddingProvider)
        let skillVectors = try await embedBatch(skillTexts, embeddingProvider: embeddingProvider)

        try await database.dbQueue.write { db in
            for (i, card) in scanned.globalCards.enumerated() {
                try upsertCard(card, projectId: "", db: db, embedding: VectorMath.encode(cardVectors[i]))
            }
            for (i, entry) in scanned.projectCards.enumerated() {
                try upsertCard(
                    entry.card,
                    projectId: entry.projectId,
                    db: db,
                    embedding: VectorMath.encode(cardVectors[scanned.globalCards.count + i])
                )
            }
            for (i, entry) in scanned.skills.enumerated() {
                try upsertSkill(
                    entry.skill, db: db, embedding: VectorMath.encode(skillVectors[i]),
                    docPath: entry.url.path
                )
            }
        }

        var report = RebuildReport()
        report.knowledgePoints = scanned.globalCards.count + scanned.projectCards.count
        report.skills = scanned.skills.count
        return report
    }

    // MARK: - 增量索引（写完即建索引——KnowledgeExtractor 落卡后调用，签名不可变）

    /// 单卡增量索引：对 content 编码后 upsert（幂等——同 id 覆盖更新）。
    static func indexCard(
        _ card: MethodologyCard,
        projectId: String,
        database: AppDatabase,
        embeddingProvider: EmbeddingProviding
    ) async throws {
        let vector = try await embedSingle(card.content, embeddingProvider: embeddingProvider)
        try await database.dbQueue.write { db in
            try upsertCard(card, projectId: projectId, db: db, embedding: VectorMath.encode(vector))
        }
    }

    /// 单技能增量索引：对四字段文本编码后 upsert（幂等——同 id 覆盖更新）。
    static func indexSkill(
        _ skill: SkillDocument,
        database: AppDatabase,
        embeddingProvider: EmbeddingProviding
    ) async throws {
        let vector = try await embedSingle(
            SkillLoader.fourFieldText(skill), embeddingProvider: embeddingProvider
        )
        try await database.dbQueue.write { db in
            try upsertSkill(skill, db: db, embedding: VectorMath.encode(vector))
        }
    }

    // MARK: - Scan

    /// 扫描全部事实源文件：全局 cards/ + 各项目 knowledge/ + 全局 skills/。
    private static func scanAll() -> (
        globalCards: [MethodologyCard],
        projectCards: [(card: MethodologyCard, projectId: String)],
        skills: [(skill: SkillDocument, url: URL)]
    ) {
        // 1. 全局 cards/ —— 跨项目通用方法论卡
        let globalCards = scanCards(in: PMAgentStore.cardsDir, projectId: "")
        // 2. 各项目 knowledge/ —— 归属单一项目
        var projectCards: [(card: MethodologyCard, projectId: String)] = []
        for projectName in PMAgentStore.listProjects() {
            let dir = PMAgentStore.projectURL(projectName)
                .appendingPathComponent("knowledge", isDirectory: true)
            for card in scanCards(in: dir, projectId: projectName) {
                projectCards.append((card, projectName))
            }
        }
        // 3. 全局 skills/ —— 技能 front-matter + 正文
        let skills = scanSkills()
        return (globalCards, projectCards, skills)
    }

    private static func scanCards(in dir: URL, projectId: String) -> [MethodologyCard] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap {
                guard let text = try? String(contentsOf: $0, encoding: .utf8) else { return nil }
                return MethodologyCard.parse(markdown: text)
            }
    }

    private static func scanSkills() -> [(skill: SkillDocument, url: URL)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: PMAgentStore.skillsDir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let skill = SkillFrontMatterParser.parse(text)
                else { return nil }
                return (skill, url)
            }
    }

    // MARK: - Embedding

    /// 单条文本编码（增量索引用）：返回一个向量；返回空 / 空向量视为失败。
    private static func embedSingle(
        _ text: String, embeddingProvider: EmbeddingProviding
    ) async throws -> [Float] {
        let vectors = try await embeddingProvider.embed(texts: [text])
        guard let vector = vectors.first, !vector.isEmpty else {
            throw NSError(
                domain: "IndexRebuilder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "向量编码返回为空：\(text.prefix(50))…"]
            )
        }
        return vector
    }

    /// 批量编码（全量重建用）：空输入返回空（不发请求）。
    private static func embedBatch(
        _ texts: [String], embeddingProvider: EmbeddingProviding
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let vectors = try await embeddingProvider.embed(texts: texts)
        guard vectors.count == texts.count else {
            throw NSError(
                domain: "IndexRebuilder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "向量编码返回数量（\(vectors.count)）与输入（\(texts.count)）不符"]
            )
        }
        return vectors
    }

    // MARK: - Upsert

    private static func upsertCard(
        _ card: MethodologyCard, projectId: String, db: Database, embedding: Data
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO knowledge_points
                    (id, project_id, content, source_type, source_ref, embedding,
                     annotation_count, confidence, superseded_by, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    embedding = excluded.embedding,
                    annotation_count = excluded.annotation_count,
                    confidence = excluded.confidence,
                    superseded_by = excluded.superseded_by
                """,
            arguments: [
                card.id, projectId, card.content, card.sourceType, card.sourceRef,
                embedding,  // 真实 blob 或零长度占位（同步 rebuild 的 M0 兼容路径）
                card.annotations.count, card.confidence, card.supersededBy, card.created,
            ]
        )
    }

    /// docPath：技能 .md 实际路径（全量扫描传真实文件；nil 回退 name.md 既有口径，
    /// 供 indexSkill 增量调用——签名不可变）。
    private static func upsertSkill(
        _ skill: SkillDocument, db: Database, embedding: Data, docPath: String? = nil
    ) throws {
        let encoder = JSONEncoder()
        let bestFor = try encoder.encode(skill.bestFor)
        let tags = try encoder.encode(skill.tags)
        let pitfalls = try encoder.encode(skill.pitfalls)
        let id = skill.name

        try db.execute(
            sql: """
                INSERT INTO skills
                    (id, name, type, when_to_use, best_for, tags, pitfalls,
                     doc_path, embedding, hit_count, enabled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    type = excluded.type,
                    when_to_use = excluded.when_to_use,
                    best_for = excluded.best_for,
                    tags = excluded.tags,
                    pitfalls = excluded.pitfalls,
                    doc_path = excluded.doc_path,
                    embedding = excluded.embedding
                """,
            arguments: [
                id, skill.name, skill.type.rawValue, skill.whenToUse,
                String(decoding: bestFor, as: UTF8.self),
                String(decoding: tags, as: UTF8.self),
                String(decoding: pitfalls, as: UTF8.self),
                docPath ?? PMAgentStore.skillsDir.appendingPathComponent("\(skill.name).md").path,
                embedding,  // 真实 blob 或零长度占位（同步 rebuild 的 M0 兼容路径）
            ]
        )
    }
}

nonisolated extension MethodologyCard {
    /// 解析卡片 Markdown（front-matter + 正文 + 实战注记区）。
    /// 格式受控（本 App 生成，design.md §5.2），不引第三方 YAML 依赖。
    static func parse(markdown: String) -> MethodologyCard? {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        var body: [String] = []
        var inFrontMatter = true

        for line in lines {
            if inFrontMatter {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    inFrontMatter = false
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                fields[key] = value
            } else {
                body.append(line)
            }
        }

        let fullBody = body.joined(separator: "\n")
        let annotationHeader = "## 实战注记"
        var content = fullBody
        var annotations: [Annotation] = []

        if let range = fullBody.range(of: annotationHeader) {
            content = String(fullBody[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let annotationBlock = String(fullBody[range.upperBound...])
            for line in annotationBlock.split(separator: "\n") {
                // 格式：- 2026-09-10 · 健身App v1.1：注记正文
                guard line.hasPrefix("- ") else { continue }
                let note = String(line.dropFirst(2))
                let parts = note.split(separator: "·", maxSplits: 1)
                if parts.count == 2 {
                    let date = parts[0].trimmingCharacters(in: .whitespaces)
                    let rest = parts[1]
                    let projAndNote = rest.split(separator: "：", maxSplits: 1)
                    if projAndNote.count == 2 {
                        annotations.append(
                            Annotation(
                                date: date,
                                project: projAndNote[0].trimmingCharacters(in: .whitespaces),
                                note: projAndNote[1].trimmingCharacters(in: .whitespaces)
                            )
                        )
                        continue
                    }
                }
                annotations.append(Annotation(date: "", project: "", note: note))
            }
        } else {
            content = fullBody.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return MethodologyCard(
            id: fields["id"] ?? IDGenerator.next("kp"),
            sourceType: fields["source_type"] ?? "methodology",
            sourceRef: fields["source_ref"] ?? "",
            project: fields["project"].flatMap { $0.isEmpty ? nil : $0 },
            confidence: Double(fields["confidence"] ?? "") ?? 1.0,
            supersededBy: fields["supersededBy"].flatMap { $0 == "null" ? nil : $0 },
            created: fields["created"] ?? ISO8601.dayString(),
            content: content,
            annotations: annotations
        )
    }
}
