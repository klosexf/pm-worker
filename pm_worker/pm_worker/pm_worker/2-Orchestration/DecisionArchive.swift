//
//  DecisionArchive.swift
//  pm_worker
//
//  决策档案：decisions.jsonl 的确定性 HTML 投影（2026-09-16 决策档案功能）。
//  - 按天一档（decisions/YYYY-MM-DD.html）+ 版本总览（decisions/版本总览.html）；
//  - 渲染 = 纯函数：零 LLM、零 token、毫秒级；
//  - 写盘 = 内容比对幂等：内容相同跳过（mtime 不动），变了才写——
//    点「生成」永远无条件全量重建，保证所有文件与 jsonl 当前状态严格一致；
//  - HTML 不嵌生成时刻：新鲜度由数据本身表达，否则内容比对永不相等；
//  - 档案是派生产物，删了可随时重建——decisions.jsonl 仍是唯一事实源
//    （「删库可重建」不变量的同级推广）。
//  渲染降级：历史决策（无 topic 字段）为简单卡；risk_hit 历史（无 createdAt）
//  按文件序回退归日（上方最近决策的天）。
//

import Foundation

nonisolated enum DecisionArchive {

    // MARK: - 常量与路径

    /// 无法归日条目的兜底天（排序最早 → 倒序列表中垫底）。
    static let unknownDay = "0000-00-00"
    /// 版本总览档案名（中文名：档案是「给人看的产物」，对齐 ArtifactPath 命名规范）。
    static let overviewName = "版本总览.html"

    static func archiveDir(project: String, version: String) -> URL {
        PMAgentStore.versionURL(project: project, version: version)
            .appendingPathComponent("decisions", isDirectory: true)
    }

    static func archiveURL(project: String, version: String, day: String) -> URL {
        archiveDir(project: project, version: version)
            .appendingPathComponent("\(day).html")
    }

    static func overviewURL(project: String, version: String) -> URL {
        archiveDir(project: project, version: version).appendingPathComponent(overviewName)
    }

    // MARK: - 按天归组（纯函数，UI 与渲染共用）

    /// 单日条目（保持文件序 = 真实时序）。
    struct DayEntry: Equatable {
        let day: String
        let entry: DecisionLogEntry
    }

    /// 天级摘要（UI 文件列表行 + 渲染统计共用）。
    struct DaySummary: Identifiable, Equatable {
        let day: String
        var decisions = 0
        var topics = 0
        var pending = 0
        var hits = 0

        var id: String { day }

        /// 展示名（兜底天 → 「未知」）。
        var displayName: String { day == DecisionArchive.unknownDay ? "未知" : day }
    }

    /// 文件序条目 → 按天归组。天判定：
    /// 决策 = createdAt 解析；risk_hit = 自身 createdAt（2026-09-16 起有），
    /// 历史行 nil → 回退文件序上方最近一条已定天条目，无前驱 → 最近后继，
    /// 全无 → unknownDay。 createdAt 解析失败的决策同 rules 回退。
    static func groupByDay(_ entries: [DecisionLogEntry]) -> [DayEntry] {
        var days: [String?] = Array(repeating: nil, count: entries.count)
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .decision(let record):
                days[index] = day(of: record.createdAt)
            case .riskHit(let hit):
                days[index] = hit.createdAt.flatMap { day(of: $0) }
            }
        }
        // 回退 1：文件序上方最近已定天
        var last: String?
        for index in entries.indices {
            if days[index] == nil { days[index] = last }
            last = days[index] ?? last
        }
        // 回退 2：仍无前驱 → 最近后继
        var next: String?
        for index in entries.indices.reversed() {
            if days[index] == nil { days[index] = next }
            next = days[index] ?? next
        }
        return entries.enumerated().map { index, entry in
            DayEntry(day: days[index] ?? unknownDay, entry: entry)
        }
    }

    /// ISO8601 时刻 → 本地日（yyyy-MM-dd）。解析失败取前缀兜底，再失败返回 nil。
    static func day(of timestamp: String) -> String? {
        if let date = ISO8601.parse(timestamp) { return ISO8601.dayString(date) }
        let prefix = String(timestamp.prefix(10))
        return prefix.count == 10 && prefix.firstIndex(of: "T") == nil ? prefix : nil
    }

    /// 归组结果 → 天摘要（天序倒序：最新在前；unknownDay 垫底）。
    static func summarize(_ grouped: [DayEntry]) -> [DaySummary] {
        var order: [String] = []
        var map: [String: DaySummary] = [:]
        for item in grouped {
            if map[item.day] == nil {
                map[item.day] = DaySummary(day: item.day)
                order.append(item.day)
            }
            var summary = map[item.day]!
            switch item.entry {
            case .decision(let record):
                summary.decisions += 1
                if record.isTopicEnriched { summary.topics += 1 }
                if record.toBeVerified { summary.pending += 1 }
            case .riskHit:
                summary.hits += 1
            }
            map[item.day] = summary
        }
        return order.sorted().reversed().compactMap { map[$0] }
    }

    // MARK: - 生成（全量幂等重建）

    struct GenerateResult: Equatable {
        /// 涉及的天（含兜底天，倒序）。
        var days: [String]
        /// 实际写盘的文件名（内容有变化）。
        var written: [String]
        /// 内容相同跳过的文件数。
        var skipped: Int
    }

    /// 读 decisions.jsonl → 渲染每日档案 + 版本总览 → 内容比对幂等写盘。
    /// 无记录时清空态：仍生成 overview（总览「暂无记录」），不生成日档。
    @discardableResult
    static func generate(project: String, version: String) throws -> GenerateResult {
        let jsonlURL = PMAgentStore.jsonlURL(
            project: project, version: version, file: "decisions.jsonl"
        )
        let entries = PMAgentStore.readLines(DecisionLogEntry.self, from: jsonlURL)
        let grouped = groupByDay(entries)
        let summaries = summarize(grouped)

        let dir = archiveDir(project: project, version: version)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 一次性迁移：overview.html（英文旧名，上线当日即更名中文名）——
        // 派生物可随时重建，直接清除，防其在文件列表里残留为幽灵日期行。
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("overview.html")
        )

        var result = GenerateResult(days: summaries.map(\.day), written: [], skipped: 0)
        for summary in summaries {
            let dayEntries = grouped.filter { $0.day == summary.day }.map(\.entry)
            let html = renderDay(
                project: project, version: version, summary: summary, entries: dayEntries
            )
            try writeIfChanged(
                html, to: archiveURL(project: project, version: version, day: summary.day),
                result: &result
            )
        }
        let overview = renderOverview(
            project: project, version: version, summaries: summaries, grouped: grouped
        )
        try writeIfChanged(overview, to: overviewURL(project: project, version: version), result: &result)
        return result
    }

    /// 已生成的天（UI 标注「已生成/未生成」用）。
    static func generatedDays(project: String, version: String) -> Set<String> {
        let path = archiveDir(project: project, version: version).path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return Set(
            names
                .filter { $0.hasSuffix(".html") && $0 != overviewName }
                .map { String($0.dropLast(".html".count)) }
        )
    }

    static func hasOverview(project: String, version: String) -> Bool {
        FileManager.default.fileExists(atPath: overviewURL(project: project, version: version).path)
    }

    private static func writeIfChanged(
        _ html: String, to url: URL, result: inout GenerateResult
    ) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == html {
            result.skipped += 1
            return
        }
        try html.write(to: url, atomically: true, encoding: .utf8)
        result.written.append(url.lastPathComponent)
    }

    // MARK: - 所有权统计（简报条）

    struct OwnerTally: Equatable {
        var original = 0
        var adopted = 0
        var modified = 0
        var rejected = 0

        var isEmpty: Bool {
            original == 0 && adopted == 0 && modified == 0 && rejected == 0
        }

        mutating func add(_ tag: OwnershipTag?) {
            switch tag {
            case .original: original += 1
            case .adopted: adopted += 1
            case .modified: modified += 1
            case .rejected: rejected += 1
            case nil: break
            }
        }
    }

    /// 备选 + 转折点的所有权分布。
    static func ownerTally(_ entries: [DecisionLogEntry]) -> OwnerTally {
        var tally = OwnerTally()
        for entry in entries {
            guard case .decision(let record) = entry else { continue }
            record.rejectedAlternatives.forEach { tally.add($0.ownership) }
            (record.turningPoints ?? []).forEach { tally.add($0.ownership) }
        }
        return tally
    }

    // MARK: - HTML 渲染（纯函数）

    /// XML/HTML 转义（用户内容与 LLM 产物均不可信）。
    private static func esc(_ text: String) -> String {
        var result = text
        result = result
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    private static func css() -> String {
        """
        :root{--base:#fbfaf8;--s2:#f3f2ef;--ink900:#1d1f24;--ink800:#3a3d45;--ink700:#4d515b;\
        --ink500:#787d89;--ink300:#b4b8c2;--b1:#e5e3de;--brand:#4f46e5;--shadow:0 1px 2px rgba(29,31,36,.04),0 4px 12px rgba(29,31,36,.05);\
        --warn:#b45309;--warn-s:#fef3e2;--err:#c93b2d;--err-s:#fdecea;--ok:#15803d;--ok-s:#e9f7ee}
        @media(prefers-color-scheme:dark){:root{--base:#1a1b1e;--s2:#232428;--ink900:#eceae6;--ink800:#c9c7c2;\
        --ink700:#a8a6a1;--ink500:#7d7b78;--ink300:#55534f;--b1:#333438;--brand:#818cf8;--shadow:0 1px 2px rgba(0,0,0,.3),0 4px 12px rgba(0,0,0,.25);\
        --warn:#e8a04c;--warn-s:#3a2d1a;--err:#e0705f;--err-s:#3a201c;--ok:#5cb87a;--ok-s:#1a2e22}}
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:14px/1.7 -apple-system,"SF Pro Text","PingFang SC",sans-serif;color:var(--ink800);\
        background:var(--base);max-width:880px;margin:0 auto;padding:28px 24px 48px}
        .crumb{font:11px/1.6 "JetBrains Mono",ui-monospace,monospace;color:var(--ink500);word-break:break-all}
        h1{font-size:22px;font-weight:700;color:var(--ink900);margin:10px 0 4px;letter-spacing:-.01em}
        .chips{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0 4px}
        .chip{display:inline-flex;align-items:baseline;gap:5px;padding:3px 10px;border:1px solid var(--b1);\
        border-radius:99px;background:var(--s2);font-size:12px;color:var(--ink500)}
        .chip b{font-size:13px;color:var(--ink900);font-variant-numeric:tabular-nums}
        .owners{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 0}
        .owner{font-size:11px;padding:2px 8px;border-radius:99px;background:var(--s2);border:1px solid var(--b1);color:var(--ink500)}
        .note{margin:14px 0 0;padding:10px 14px;border:1px dashed var(--b1);border-radius:10px;\
        font-size:12px;color:var(--ink500);line-height:1.8}
        .card{border:1px solid var(--b1);border-radius:12px;background:var(--s2);padding:16px 18px;margin-top:14px;box-shadow:var(--shadow)}
        .card.rich{background:var(--base)}
        .topic-tag{display:inline-block;font-size:11px;font-weight:600;color:var(--brand);\
        border:1px solid var(--b1);border-radius:6px;padding:1px 8px;margin-bottom:8px}
        .decision{font-size:15px;font-weight:650;color:var(--ink900);line-height:1.6}
        .meta{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-top:10px;font-size:11px;color:var(--ink300)}
        .badge{font-size:11px;font-weight:600;padding:2px 9px;border-radius:99px}
        .badge.warn{color:var(--warn);background:var(--warn-s)}
        .badge.ok{color:var(--ink500);background:var(--s2)}
        .badge.err{color:var(--err);background:var(--err-s)}
        .conf{margin-left:auto;font-variant-numeric:tabular-nums;color:var(--ink500)}
        .sec{margin-top:14px}
        .sec-label{font-size:11px;font-weight:600;color:var(--ink300);margin-bottom:6px;letter-spacing:.04em}
        .ask{border-left:2px solid var(--b1);padding:2px 0 2px 12px;color:var(--ink700);font-size:13px}
        .opt{border:1px solid var(--b1);border-radius:10px;padding:10px 12px;margin-top:8px}
        .opt.win{border-color:var(--ok)}
        .opt-name{font-size:13px;font-weight:600;color:var(--ink800);display:flex;gap:8px;align-items:center;flex-wrap:wrap}
        .opt-name .verdict{font-weight:700}
        .opt.win .verdict{color:var(--ok)}
        .opt.lose .verdict{color:var(--ink300)}
        .opt-reason{font-size:12px;color:var(--ink500);margin-top:4px}
        .otag{font-size:10px;color:var(--ink500);border:1px solid var(--b1);border-radius:99px;padding:0 7px}
        .turn{display:flex;gap:8px;font-size:12.5px;color:var(--ink700);margin-top:8px}
        .turn .dot{color:var(--ink300)}
        .why{font-size:13px;color:var(--ink700);margin-top:8px}
        .card.hit{border-color:var(--err);background:var(--err-s)}
        .hrow{display:flex;gap:10px;font-size:13px;margin-top:6px}
        .hrow .hl{color:var(--ink500);flex:none;width:32px}
        .hrow .hv{color:var(--ink800)}
        table{width:100%;border-collapse:collapse;margin-top:8px;font-size:13px}
        th{text-align:left;font-size:11px;font-weight:600;color:var(--ink300);padding:6px 10px;border-bottom:1px solid var(--b1)}
        td{padding:9px 10px;border-bottom:1px solid var(--b1);vertical-align:top;line-height:1.6}
        td.follow{color:var(--ink500);font-size:12.5px}
        .todo{display:flex;gap:10px;align-items:flex-start;padding:8px 0;border-bottom:1px solid var(--b1);font-size:13px;color:var(--ink800)}
        .todo input{margin-top:4px;accent-color:var(--brand)}
        .todo .src{color:var(--ink300);font-size:11px;margin-left:auto;flex:none}
        .days{display:flex;flex-direction:column;gap:8px;margin-top:8px}
        .daylink{display:flex;align-items:center;gap:10px;border:1px solid var(--b1);border-radius:10px;\
        padding:11px 14px;text-decoration:none;color:var(--ink800);font-size:13px}
        .daylink:hover{border-color:var(--brand)}
        .daylink .fname{font-family:"JetBrains Mono",ui-monospace,monospace;font-weight:600}
        .daylink .cnt{color:var(--ink500);font-size:12px}
        .eyebrow{font-size:11px;font-weight:600;letter-spacing:.06em;color:var(--ink300);margin:30px 0 2px}
        .footer{margin-top:36px;padding-top:14px;border-top:1px solid var(--b1);\
        font-size:11px;color:var(--ink300);line-height:1.8}
        .empty{margin-top:16px;padding:24px;border:1px dashed var(--b1);border-radius:12px;\
        text-align:center;color:var(--ink500);font-size:13px}
        """
    }

    private static func headHTML(_ title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>\(css())</style>
        </head>
        <body>
        """
    }

    private static func footerHTML() -> String {
        """
        <div class="footer">本文件为 decisions.jsonl 的确定性派生产物，请勿手工编辑——\
        任何时候都可在「决策日志」中点「生成决策日志」无条件全量重建（内容相同则跳过写入）。</div>
        </body>
        </html>
        """
    }

    private static func chip(_ value: Int, _ label: String) -> String {
        "<span class=\"chip\"><b>\(value)</b>\(esc(label))</span>"
    }

    private static func timeText(_ timestamp: String) -> String {
        String(timestamp.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    /// 备选卡（win = 结论本身，lose = 被否决备选）。
    private static func optionHTML(win: Bool, name: String, reason: String, owner: String?) -> String {
        let tag = (owner.flatMap(OwnershipTag.init(rawValue:))).map { ownerTag in
            "<span class=\"otag\">\(esc(ownerTag.label))</span>"
        } ?? ""
        let verdict = win ? "<span class=\"verdict\">✓ 采纳</span>" : "<span class=\"verdict\">✕ 否决</span>"
        return """
        <div class="opt \(win ? "win" : "lose")">
        <div class="opt-name"><span>\(esc(name))</span>\(verdict)\(tag)</div>
        <div class="opt-reason">\(esc(reason))</div>
        </div>
        """
    }

    /// 富话题卡：话题标题 → 诉求 → 备选取舍 → 转折点 → 结论。
    private static func topicCardHTML(_ record: DecisionRecord) -> String {
        let winOption = optionHTML(
            win: true, name: record.decision, reason: record.why, owner: nil
        )
        let loseOptions = record.rejectedAlternatives.map { alternative in
            optionHTML(
                win: false, name: alternative.option,
                reason: alternative.reason, owner: alternative.owner
            )
        }.joined()

        let askSection = (record.userAsk ?? "").isEmpty ? "" : """
        <div class="sec">
        <div class="sec-label">用户诉求</div>
        <div class="ask">\(esc(record.userAsk!))</div>
        </div>
        """

        let turning = record.turningPoints ?? []
        let turnSection = turning.isEmpty ? "" : """
        <div class="sec">
        <div class="sec-label">转折点（终局视角）</div>
        \(turning.map { point -> String in
            let tag = point.ownership.map { "<span class=\"otag\">\(esc($0.label))</span>" } ?? ""
            return "<div class=\"turn\"><span class=\"dot\">▸</span><span>\(esc(point.text))</span>\(tag)</div>"
        }.joined())
        </div>
        """

        return """
        <div class="card rich">
        <span class="topic-tag">话题</span>
        <div class="decision">\(esc(record.topic!))</div>
        \(askSection)
        <div class="sec">
        <div class="sec-label">备选与取舍</div>
        \(winOption)
        \(loseOptions)
        </div>
        \(turnSection)
        <div class="meta">
        <span class="badge \(record.toBeVerified ? "warn" : "ok")">\(record.toBeVerified ? "待验证" : "已闭环")</span>
        <span>\(esc(timeText(record.createdAt)))</span>
        <span class="conf">置信 \(Int((record.confidence * 100).rounded()))%</span>
        </div>
        </div>
        """
    }

    /// 历史简单卡（无话题字段，降级渲染）。
    private static func simpleCardHTML(_ record: DecisionRecord) -> String {
        let rejected = record.rejectedAlternatives.map { alternative in
            optionHTML(
                win: false, name: alternative.option,
                reason: alternative.reason, owner: alternative.owner
            )
        }.joined()
        return """
        <div class="card">
        <div class="decision">\(esc(record.decision))</div>
        <div class="why">\(esc(record.why))</div>
        \(rejected)
        <div class="meta">
        <span class="badge \(record.toBeVerified ? "warn" : "ok")">\(record.toBeVerified ? "待验证" : "已闭环")</span>
        <span>\(esc(timeText(record.createdAt)))</span>
        <span class="conf">置信 \(Int((record.confidence * 100).rounded()))%</span>
        </div>
        </div>
        """
    }

    private static func riskHitCardHTML(_ record: RiskHitRecord) -> String {
        let time = record.createdAt.map { "<span>\(esc(timeText($0)))</span>" } ?? ""
        return """
        <div class="card hit">
        <span class="badge err">💀 风险命中</span>
        <div class="hrow"><span class="hl">预测</span><span class="hv">\(esc(record.predicted))</span></div>
        <div class="hrow"><span class="hl">实际</span><span class="hv">\(esc(record.actual))</span></div>
        <div class="meta">\(time)</div>
        </div>
        """
    }

    /// 汇总表（结论 | 待跟进）。
    private static func summaryTableHTML(_ records: [DecisionRecord]) -> String {
        let rows = records.map { record -> String in
            let follow = record.toBeVerified ? "验证：\(esc(record.decision))" : "无"
            return "<tr><td>\(esc(record.decision))</td><td class=\"follow\">\(follow)</td></tr>"
        }.joined()
        return """
        <table>
        <thead><tr><th style="width:55%">结论</th><th>待跟进</th></tr></thead>
        <tbody>\(rows)</tbody>
        </table>
        """
    }

    /// 待办清单（可勾选，纯客户端视觉）。
    private static func todoListHTML(_ records: [DecisionRecord]) -> String {
        let items = records.filter(\.toBeVerified).map { record in
            """
            <label class="todo"><input type="checkbox"><span>\(esc(record.decision))</span>\
            <span class="src">\(esc(timeText(record.createdAt)))</span></label>
            """
        }.joined()
        return items.isEmpty ? "<div class=\"empty\">无待验证事项。</div>" : items
    }

    private static func ownerStripHTML(_ tally: OwnerTally) -> String {
        guard !tally.isEmpty else { return "" }
        var parts: [String] = []
        if tally.original > 0 { parts.append("原创 \(tally.original)") }
        if tally.adopted > 0 { parts.append("AI建议-采纳 \(tally.adopted)") }
        if tally.modified > 0 { parts.append("AI建议-修改 \(tally.modified)") }
        if tally.rejected > 0 { parts.append("AI建议-未采纳 \(tally.rejected)") }
        return "<div class=\"owners\">"
            + parts.map { "<span class=\"owner\">\(esc($0))</span>" }.joined()
            + "</div>"
    }

    // MARK: - 每日档案

    static func renderDay(
        project: String, version: String, summary: DaySummary, entries: [DecisionLogEntry]
    ) -> String {
        let decisions = entries.compactMap { entry -> DecisionRecord? in
            if case .decision(let record) = entry { return record }
            return nil
        }
        let hasLegacy = decisions.contains { !$0.isTopicEnriched }
        let hasRich = decisions.contains { $0.isTopicEnriched }
        let degradeNote = hasLegacy
            ? """
            <div class="note">本日含<b>历史格式</b>记录（写入时富化功能之前）：简单卡 = 无话题 /
            所有权 / 转折点字段的旧记录，缺章节自动降级渲染，非数据缺失。</div>
            """
            : ""

        let cards = entries.map { entry -> String in
            switch entry {
            case .decision(let record):
                return record.isTopicEnriched ? topicCardHTML(record) : simpleCardHTML(record)
            case .riskHit(let hit):
                return riskHitCardHTML(hit)
            }
        }.joined()

        let chips = [
            hasRich ? chip(summary.topics, "话题") : nil,
            chip(summary.decisions, "决策"),
            chip(summary.pending, "待验证"),
            summary.hits > 0 ? chip(summary.hits, "💀命中") : nil,
        ].compactMap { $0 }.joined()

        return """
        \(headHTML("决策日志 · \(summary.displayName) · \(project)"))
        <div class="crumb">\(esc(project)) / \(esc(version)) / decisions / \(esc(summary.day)).html</div>
        <h1>决策日志 · \(esc(summary.displayName))</h1>
        <div class="chips">\(chips)</div>
        \(ownerStripHTML(ownerTally(entries)))
        \(degradeNote)
        \(cards)
        <div class="eyebrow">当日关键结论汇总</div>
        \(decisions.isEmpty ? "<div class=\"empty\">本日无决策记录（仅风险命中回写）。</div>" : summaryTableHTML(decisions))
        <div class="eyebrow">当日待办</div>
        \(todoListHTML(decisions))
        \(footerHTML())
        """
    }

    // MARK: - 版本总览

    static func renderOverview(
        project: String, version: String, summaries: [DaySummary], grouped: [DayEntry]
    ) -> String {
        let entries = grouped.map(\.entry)
        let decisions = entries.compactMap { entry -> DecisionRecord? in
            if case .decision(let record) = entry { return record }
            return nil
        }
        let pending = decisions.filter(\.toBeVerified)
        let closed = decisions.count - pending.count
        let tally = ownerTally(entries)
        let rejectedCount = decisions.reduce(0) { $0 + $1.rejectedAlternatives.count }

        let chips = [
            chip(summaries.count, "天"),
            chip(decisions.count, "决策"),
            chip(decisions.filter(\.isTopicEnriched).count, "话题"),
            chip(pending.count, "待验证"),
            chip(entries.count - decisions.count, "💀命中"),
        ].compactMap { $0 }.joined()

        // 简报三项（确定性统计，零 token）。分母为零不显示。
        var insights: [String] = []
        let totalOptions = decisions.count + rejectedCount
        if totalOptions > 0 {
            let rate = Int((Double(rejectedCount) / Double(totalOptions) * 100).rounded())
            insights.append(insightHTML(
                "\(rate)%", "备选否决率",
                "\(totalOptions) 个备选中 \(rejectedCount) 个被否决——高否决率说明备选是真备选。"
            ))
        }
        let tagged = tally.original + tally.adopted + tally.modified + tally.rejected
        if tagged > 0 {
            let landed = tally.adopted + tally.modified
            let rate = Int((Double(landed) / Double(tagged) * 100).rounded())
            insights.append(insightHTML(
                "\(rate)%", "AI 方案落地率",
                "有所有权标注的 \(tagged) 个思路中 \(landed) 个落地；被否决的均有书面原因留档。"
            ))
        }
        if !decisions.isEmpty {
            let rate = Int((Double(closed) / Double(decisions.count) * 100).rounded())
            insights.append(insightHTML(
                "\(rate)%", "待验证闭环率",
                "\(decisions.count) 条决策中 \(closed) 条已闭环，\(pending.count) 条待验证。"
            ))
        }
        let insightHTMLContent = insights.joined()

        let dayLinks = summaries.map { summary -> String in
            let meta = [
                "\(summary.decisions) 决策",
                summary.topics > 0 ? "\(summary.topics) 话题" : nil,
                summary.pending > 0 ? "\(summary.pending) 待验证" : nil,
                summary.hits > 0 ? "💀 \(summary.hits)" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
            return """
            <a class="daylink" href="\(esc(summary.day)).html">
            <span class="fname">\(esc(summary.displayName)).html</span>
            <span class="cnt">\(esc(meta))</span>
            </a>
            """
        }.joined()

        return """
        \(headHTML("版本决策总览 · \(project) \(version)"))
        <div class="crumb">\(esc(project)) / \(esc(version)) / decisions / \(esc(overviewName))</div>
        <h1>版本决策总览 · \(esc(version))</h1>
        <div class="chips">\(chips)</div>
        \(ownerStripHTML(tally))
        <div class="eyebrow">版本简报（确定性统计 · 零 token）</div>
        \(insightHTMLContent.isEmpty ? "<div class=\"empty\">暂无决策记录——跑流水线或聊天闭合话题后生成。</div>" : "<div class=\"chips\" style=\"display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px\">\(insightHTMLContent)</div>")
        <div class="note">叙事洞察（决策模式总结、转折还原）需 LLM 参与、非确定性 → \
        v1 不做自动生成；需要时在对话中让 AI「总结本版本」。</div>
        <div class="eyebrow">按天档案</div>
        <div class="days">\(dayLinks.isEmpty ? "<div class=\"empty\">暂无每日档案。</div>" : dayLinks)</div>
        <div class="eyebrow">跨天关键结论汇总</div>
        \(decisions.isEmpty ? "<div class=\"empty\">暂无记录。</div>" : summaryTableHTML(decisions))
        <div class="eyebrow">全部待办</div>
        \(todoListHTML(decisions))
        \(footerHTML())
        """
    }

    private static func insightHTML(_ number: String, _ label: String, _ note: String) -> String {
        """
        <div class="card rich" style="margin-top:0">
        <div style="font-size:24px;font-weight:700;color:var(--ink900);font-variant-numeric:tabular-nums">\(esc(number))</div>
        <div style="font-size:12px;font-weight:600;color:var(--ink700);margin:2px 0 6px">\(esc(label))</div>
        <div style="font-size:12px;color:var(--ink500);line-height:1.7">\(esc(note))</div>
        </div>
        """
    }
}
