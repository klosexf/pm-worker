//
//  AppDatabase.swift
//  pm_worker
//
//  GRDB SQLite 索引（design.md §5.3）——仅索引，可随时删掉从文件全量重建。
//  五张表：knowledge_points / skills / pipeline_runs / risks / mcp_tasks。
//

import Foundation
import GRDB

/// nonisolated：存储层类型不受默认 MainActor 隔离约束
/// （Xcode 26 起 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）。
nonisolated final class AppDatabase {
    let dbQueue: DatabaseQueue

    /// index.sqlite 位于 ~/PMAgent/ 根目录；可注入路径（测试用）。
    init(indexURL: URL? = nil) throws {
        let url = indexURL ?? PMAgentStore.root.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: url.path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-create-tables") { db in
            // 方法论卡片索引（事实源为 knowledge/ 与全局 cards/）
            try db.create(table: "knowledge_points") { t in
                t.column("id", .text).primaryKey()               // 与文件 id 一致
                t.column("project_id", .text).notNull()
                t.column("content", .text).notNull()
                t.column("source_type", .text).notNull()         // methodology | manual
                t.column("source_ref", .text).notNull()
                t.column("embedding", .blob).notNull()            // 仅对正文编码，注记不参与检索
                t.column("annotation_count", .integer).notNull().defaults(to: 0)
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("superseded_by", .text)
                t.column("created_at", .text)
            }
            try db.create(indexOn: "knowledge_points", columns: ["project_id"])

            // 技能索引（事实源为 skills/*.md front-matter + 正文）
            try db.create(table: "skills") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull().defaults(to: "component")  // component | interactive
                t.column("when_to_use", .text).notNull()        // 元数据常驻，正文不进索引
                t.column("best_for", .text)                     // JSON 数组，编码进 embedding
                t.column("tags", .text)                         // 中英双语，编码进 embedding
                t.column("pitfalls", .text)                     // JSON 数组——确定性路由，不编码 embedding
                t.column("doc_path", .text).notNull()
                t.column("embedding", .blob).notNull()          // 对 name+when_to_use+best_for+tags 编码
                t.column("hit_count", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }

            // 流水线运行态（重启不丢）
            try db.create(table: "pipeline_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text).notNull()
                t.column("version", .text).notNull()
                t.column("current_stage", .text).notNull()       // clarify | structure | prototype | prd
                t.column("structure_confirmed", .boolean).notNull().defaults(to: false)
                t.column("prototype_confirmed", .boolean).notNull().defaults(to: false)
                t.column("status", .text).notNull()              // running | suspended | failed | done
                t.column("self_review_fixes", .integer).notNull().defaults(to: 0)
                t.column("radar_risk_hits", .integer).notNull().defaults(to: 0)
                t.column("clarify_rounds", .integer).notNull().defaults(to: 0)
                t.column("error", .text)
                t.column("updated_at", .text)
            }
            try db.create(indexOn: "pipeline_runs", columns: ["project_id", "version"])

            // 风险登记册索引（事实源为 risks.jsonl，可重建）
            try db.create(table: "risks") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text).notNull()
                t.column("version", .text).notNull()
                t.column("stage", .text).notNull()
                t.column("hypothesis", .text).notNull()
                t.column("trigger_signal", .text).notNull()
                t.column("status", .text).notNull()   // open | triggered | closed_unfired | closed_falsified | merged
                t.column("origin_ref", .text).notNull()
                t.column("resolution", .text)
                t.column("created_at", .text)
                t.column("closed_at", .text)
            }
            try db.create(indexOn: "risks", columns: ["project_id", "version"])
            try db.create(indexOn: "risks", columns: ["status"])

            // MCP 异步任务（get_task 轮询数据源）
            try db.create(table: "mcp_tasks") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()     // generate_structure | generate_prd | generate_prototype
                t.column("payload", .text).notNull()  // JSON
                t.column("status", .text).notNull()   // pending | running | done | failed
                t.column("result", .text)             // JSON
                t.column("created_at", .text)
            }
            try db.create(indexOn: "mcp_tasks", columns: ["status"])
        }

        migrator.registerMigration("v2-embedding-source") { db in
            // 向量来源戳（P1 嵌入守卫）：model:<名> / hash256；
            // 旧行 NULL = 来源未知，检索放行但受维度守卫兜底。
            try db.execute(sql: "ALTER TABLE knowledge_points ADD COLUMN embedding_source TEXT")
            try db.execute(sql: "ALTER TABLE skills ADD COLUMN embedding_source TEXT")
        }

        return migrator
    }
}
