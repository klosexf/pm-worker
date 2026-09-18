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
//  渲染分流：富话题卡（有 topic）/ 记账卡（风险应对·解除·池毕业——系统确定性
//  写入，无话题字段，出专属形态）/ 简单卡（真·历史记录，顶部挂降级说明）；
//  risk_hit 历史（无 createdAt）按文件序回退归日（上方最近决策的天）。
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
        .path-sub{font-size:11px;font-weight:600;color:var(--ink300);letter-spacing:.04em;margin-top:18px}
        .path-row{display:flex;gap:8px;align-items:baseline;margin-top:9px;font-size:12.5px;color:var(--ink800);line-height:1.7}
        .path-row .dot{color:var(--ink300);flex:none}
        .path-row .dot.no{color:var(--err)}
        .path-src{margin:1px 0 0 19px;font-size:11px;color:var(--ink300);line-height:1.7}
        .note{margin:14px 0 0;padding:10px 14px;border:1px dashed var(--b1);border-radius:10px;\
        font-size:12px;color:var(--ink500);line-height:1.8}
        details.atomic{border:1px solid var(--b1);border-radius:12px;margin-top:14px;\
        background:var(--s2);box-shadow:var(--shadow)}
        details.atomic>summary{cursor:pointer;list-style:none;user-select:none;display:flex;\
        align-items:center;gap:7px;padding:12px 16px;font-size:12px;font-weight:600;color:var(--ink500)}
        details.atomic>summary::-webkit-details-marker{display:none}
        details.atomic[open]>summary{border-bottom:1px solid var(--b1);color:var(--ink700)}
        details.atomic .chev{display:inline-block;color:var(--ink300);transition:transform .15s}
        details.atomic[open] .chev{transform:rotate(90deg)}
        details.atomic .hint{margin-left:auto;font-weight:400;font-size:11px;color:var(--ink300)}
        details.atomic .inner{padding:2px 16px 16px}
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
        .badge.brand{color:var(--brand);background:var(--s2)}
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
        .evi-link{color:var(--brand);text-decoration:none}
        .evi-link:hover{text-decoration:underline}
        table{width:100%;border-collapse:collapse;margin-top:8px;font-size:13px}
        th{text-align:left;font-size:11px;font-weight:600;color:var(--ink300);padding:6px 10px;border-bottom:1px solid var(--b1)}
        td{padding:9px 10px;border-bottom:1px solid var(--b1);vertical-align:top;line-height:1.6}
        td.follow{color:var(--ink500);font-size:12.5px;white-space:nowrap}
        .dup-note{font-size:11px;color:var(--ink300);white-space:nowrap}
        .cell-day{margin-left:8px;font-size:11px;color:var(--ink300);font-variant-numeric:tabular-nums}
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

    /// 结论依据小节（2026-09-17）：basis 三槽（数据/逻辑/事实案例）逐行人话展示；
    /// basis 缺失或三槽全空 → 空串（卡片降级为仅 why 一行）。
    private static func basisSectionHTML(_ basis: DecisionBasis?) -> String {
        guard let basis, !basis.isEmpty else { return "" }
        let slots: [(String, String?)] = [
            ("数据", basis.data), ("逻辑", basis.logic), ("事实", basis.facts),
        ]
        let rows = slots.compactMap { label, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "<div class=\"hrow\"><span class=\"hl\">\(esc(label))</span>"
                + "<span class=\"hv\">\(esc(value))</span></div>"
        }.joined()
        return """
        <div class="sec">
        <div class="sec-label">结论依据</div>
        \(rows)
        </div>
        """
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
        \(basisSectionHTML(record.basis))
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
        \(basisSectionHTML(record.basis))
        \(rejected)
        <div class="meta">
        <span class="badge \(record.toBeVerified ? "warn" : "ok")">\(record.toBeVerified ? "待验证" : "已闭环")</span>
        <span>\(esc(timeText(record.createdAt)))</span>
        <span class="conf">置信 \(Int((record.confidence * 100).rounded()))%</span>
        </div>
        </div>
        """
    }

    /// 记账卡：风险应对 / 风险解除 / 变更池毕业——业务流程确定性写入的系统记账，
    /// 不经历话题讨论，天然无话题字段；出专属形态而非降级为「历史格式」。
    private static func ledgerCardHTML(_ record: DecisionRecord) -> String {
        let meta = """
        <div class="meta">
        <span class="badge \(record.toBeVerified ? "warn" : "ok")">\(record.toBeVerified ? "待验证" : "已闭环")</span>
        <span>\(esc(timeText(record.createdAt)))</span>
        <span class="conf">置信 \(Int((record.confidence * 100).rounded()))%</span>
        </div>
        """
        func row(_ label: String, _ value: String) -> String {
            "<div class=\"hrow\"><span class=\"hl\">\(esc(label))</span><span class=\"hv\">\(esc(value))</span></div>"
        }

        switch record.ledgerKind {
        case .riskMitigation:
            // why 由 RiskStore 确定性写成「风险：假设（后果：影响）」，按标记拆行；
            // 拆不开（历史/手改行）则整段作风险文本，不猜。
            let plan = stripPrefix("【风险应对】", from: record.decision)
            var risk = stripPrefix("风险：", from: record.why)
            var impactRow = ""
            if let range = risk.range(of: "（后果："), risk.hasSuffix("）") {
                impactRow = row("后果", String(risk[range.upperBound...].dropLast()))
                risk = String(risk[..<range.lowerBound])
            }
            let evidenceRow = (record.evidence ?? "").isEmpty
                ? "" : evidenceRowHTML(record.evidence!)
            return """
            <div class="card">
            <span class="badge warn">风险应对</span>
            <div class="decision">\(esc(plan))</div>
            \(row("风险", risk))
            \(impactRow)
            \(evidenceRow)
            \(meta)
            </div>
            """
        case .riskResolution:
            var title = stripPrefix("【风险解除】", from: record.decision)
            if title.hasSuffix("——方案验证通过") {
                title = String(title.dropLast("——方案验证通过".count))
            }
            return """
            <div class="card">
            <span class="badge ok">风险解除</span>
            <div class="decision">\(esc(title))</div>
            \(row("验证", record.why))
            \(meta)
            </div>
            """
        case .toNextVersion:
            let idea = stripPrefix("纳入后续版本：", from: record.decision)
            return """
            <div class="card">
            <span class="badge brand">池毕业</span>
            <div class="decision">\(esc(idea))</div>
            \(row("裁决", record.why))
            \(meta)
            </div>
            """
        case .routeSelection:
            // 阶段路径选择记账（跳过 / 停驻 / 补做 / 停驻续出，AppModel.recordRouteDecision 写入）：
            // 前缀剥离后正文即路径一句话（如「澄清确认：跳过中间阶段，直出 PRD」），
            // why 为人话缘由。折叠速览区各自成行（ledgerKind != nil 天然分流）。
            let route = stripPrefix("【路径选择】", from: record.decision)
            return """
            <div class="card">
            <span class="badge brand">路径选择</span>
            <div class="decision">\(esc(route))</div>
            \(row("缘由", record.why))
            \(meta)
            </div>
            """
        case nil:
            return simpleCardHTML(record)
        }
    }

    /// 剥离确定性写入前缀（不匹配则原文返回，容历史/手改行）。
    private static func stripPrefix(_ prefix: String, from text: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// 证据行人话化（2026-09-17）：jsonl 事实源存原始指针（「对话留痕 · 会话 <id> ·
    /// 回合 <id> · 执行包 <path>」，会话/回合标识供程序回跳），档案展示层剥掉机器
    /// 标识——用户可懂的只有「采纳回合的对话留痕」与执行包链接（档案在 decisions/
    /// 下，产物相对版本目录 → ../ 前缀）。无执行包/残缺格式一律说人话不露标识。
    private static func evidenceRowHTML(_ evidence: String) -> String {
        let planPath = evidence
            .components(separatedBy: " · ")
            .first { $0.hasPrefix("执行包 ") }?
            .dropFirst("执行包 ".count)
        guard let path = planPath, !path.isEmpty else {
            return "<div class=\"hrow\"><span class=\"hl\">证据</span>"
                + "<span class=\"hv\">采纳回合的对话留痕</span></div>"
        }
        return """
        <div class="hrow"><span class="hl">证据</span><span class="hv">采纳回合的对话留痕 · \
        <a class="evi-link" href="../\(esc(String(path)))">查看执行包</a></span></div>
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

    // MARK: - 汇总表（分层 + 重复聚合 + 状态列，2026-09-17 重做）

    /// 重复判定阈值：规范化后 LCS 相似度 ≥ 此值判为同表述复读。
    /// 口径：同结论多轮复述（措辞微调）实测 0.45~0.6；不同结论 < 0.3。
    /// 只抓字面级复读，不猜语义（确定性方法不给语义相等背书）。
    private static let dupSimilarityThreshold = 0.45

    /// 重复聚合组：代表 = 组内最新一条（现行口径），注记给出首次出现日。
    private struct DupGroup {
        var representative: DecisionRecord
        var count = 1
        var firstDay: String

        init(representative: DecisionRecord) {
            self.representative = representative
            self.firstDay = shortDay(representative.createdAt)
        }
    }

    /// 规范化（重复判定输入）：小写化，仅保留字母数字（含 CJK）——
    /// 剥空白 / 标点 / 全半角差异后比字面。
    private static func normalizedForDup(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// 最长公共子序列长度（动态规划；决策文本均 <200 字，O(n·m) 无压力）。
    private static func lcsLength(_ x: [Character], _ y: [Character]) -> Int {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            for j in 1...y.count {
                curr[j] = x[i - 1] == y[j - 1]
                    ? prev[j - 1] + 1 : max(prev[j], curr[j - 1])
            }
            (prev, curr) = (curr, prev)
        }
        return prev[y.count]
    }

    /// 重复判定相似度：2·LCS / (lenA + lenB) ∈ [0, 1]。
    private static func dupSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalizedForDup(a))
        let y = Array(normalizedForDup(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(lcsLength(x, y)) * 2 / Double(x.count + y.count)
    }

    /// 重复聚合（确定性，零 token）：文件序扫描，与组代表比相似度，≥ 阈值归并
    /// （代表被最新一条覆盖 = 现行口径）。系统记账条目不参与——它们各自绑定
    /// 风险 / 裁决上下文，合并会破坏对应关系。
    private static func foldDuplicates(_ records: [DecisionRecord]) -> [DupGroup] {
        var groups: [DupGroup] = []
        for record in records where record.ledgerKind == nil {
            if let index = groups.lastIndex(where: {
                dupSimilarity($0.representative.decision, record.decision)
                    >= dupSimilarityThreshold
            }) {
                groups[index].representative = record
                groups[index].count += 1
            } else {
                groups.append(DupGroup(representative: record))
            }
        }
        return groups
    }

    /// 汇总表（结论 | 状态）。分层对齐档案「话题为纲」钦定：话题决策出主表，
    /// 原子 / 记账收默认折叠速览区——此前全量平铺把历史态并集当现状，
    /// 看起来结论又多又互相矛盾（实际多是原子确认与风险记账混排）。
    private static func summaryTableHTML(_ records: [DecisionRecord]) -> String {
        let topics = records.filter { $0.isTopicEnriched }
        let others = records.filter { !$0.isTopicEnriched }
        return tableHTML(topics, emptyNote: "无话题结论——原子决策与系统记账见下方折叠区。")
            + foldedSummarySection(others)
    }

    private static func tableHTML(_ records: [DecisionRecord], emptyNote: String) -> String {
        guard !records.isEmpty else {
            return "<div class=\"empty\">\(esc(emptyNote))</div>"
        }
        let rows = foldDuplicates(records).map { group -> String in
            summaryRowHTML(group.representative, count: group.count, firstDay: group.firstDay)
        }.joined()
        return summaryTable(rows)
    }

    /// 折叠速览区：原子决策（参与重复聚合）+ 系统记账条目（各自成行）。
    private static func foldedSummarySection(_ records: [DecisionRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let ledger = records.filter { $0.ledgerKind != nil }
        let atomic = foldDuplicates(records.filter { $0.ledgerKind == nil })
        let rows = (atomic.map { group -> String in
            summaryRowHTML(group.representative, count: group.count, firstDay: group.firstDay)
        } + ledger.map { summaryRowHTML($0, count: 1, firstDay: shortDay($0.createdAt)) })
            .joined()
        return """
        <details class="atomic">
        <summary><span class="chev">▸</span>原子与记账速览 · \(records.count) 条\
        <span class="hint">简单确认 / 风险记账，点开查看</span></summary>
        <div class="inner">
        \(summaryTable(rows))
        </div>
        </details>
        """
    }

    private static func summaryTable(_ rows: String) -> String {
        """
        <table>
        <thead><tr><th style="width:60%">结论</th><th>状态</th></tr></thead>
        <tbody>\(rows)</tbody>
        </table>
        """
    }

    private static func summaryRowHTML(
        _ record: DecisionRecord, count: Int, firstDay: String
    ) -> String {
        let dupNote = count <= 1
            ? "" : " <span class=\"dup-note\">\(count) 次确认 · 首见 \(esc(firstDay))</span>"
        return """
        <tr><td>\(esc(record.decision))\(dupNote)</td>\
        <td class="follow">\(statusCellHTML(record))</td></tr>
        """
    }

    /// 状态格：不再复读结论原文（信息量为零）——待验证 / 已闭环徽章 + 日期锚定
    /// 先后关系；风险应对有实施证据时附执行包链接（复用证据行的人话化口径）。
    private static func statusCellHTML(_ record: DecisionRecord) -> String {
        let badge = record.toBeVerified
            ? "<span class=\"badge warn\">待验证</span>"
            : "<span class=\"badge ok\">已闭环</span>"
        var evidenceLink = ""
        if record.ledgerKind == .riskMitigation,
           let evidence = record.evidence, !evidence.isEmpty,
           let path = evidence.components(separatedBy: " · ")
               .first(where: { $0.hasPrefix("执行包 ") })?
               .dropFirst("执行包 ".count), !path.isEmpty {
            evidenceLink = " <a class=\"evi-link\" href=\"../\(esc(String(path)))\">查看执行包</a>"
        }
        let day = "<span class=\"cell-day\">\(esc(shortDay(record.createdAt)))</span>"
        return "\(badge)\(evidenceLink)\(day)"
    }

    /// 短日期（MM-DD）：行内锚定时间先后，不占宽。垃圾串 → 容错产出空/残段。
    private static func shortDay(_ timestamp: String) -> String {
        String(timeText(timestamp).prefix(10).suffix(5))
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

    // MARK: - 路径还原（2026-09-17 聚合区）

    /// 路径还原的来源题：富话题用话题标题，原子用决策原文；展示截 40 字。
    private static func pathSourceTitle(_ record: DecisionRecord) -> String {
        let title = record.isTopicEnriched ? (record.topic ?? record.decision) : record.decision
        return title.count <= 40 ? title : String(title.prefix(40)) + "…"
    }

    /// 路径还原聚合区：把散在各卡里的「中途推翻 / 被否备选」汇成一版一眼可浏览的
    /// 路径层——用户否了 AI 什么、讨论拐了什么弯，拒绝原因与认知所有权随行标注，
    /// 来源决策题回链。确定性渲染零 token；两者全空整段省略。
    private static func pathSectionHTML(_ decisions: [DecisionRecord]) -> String {
        let turns = decisions.flatMap { record -> [(String, TurningPoint)] in
            (record.turningPoints ?? []).map { (pathSourceTitle(record), $0) }
        }
        let rejections = decisions.flatMap { record -> [(String, RejectedAlternative)] in
            record.rejectedAlternatives.map { (pathSourceTitle(record), $0) }
        }
        if turns.isEmpty && rejections.isEmpty { return "" }

        func ownerTag(_ owner: String?) -> String {
            owner.flatMap(OwnershipTag.init(rawValue:))
                .map { "<span class=\"otag\">\(esc($0.label))</span>" } ?? ""
        }
        let turnRows = turns.map { pair -> String in
            let (source, point) = pair
            return """
            <div class="path-row"><span class="dot">▸</span><span>\(esc(point.text))</span>\(ownerTag(point.owner))</div>
            <div class="path-src">——《\(esc(source))》</div>
            """
        }.joined()
        let rejectionRows = rejections.map { pair -> String in
            let (source, alternative) = pair
            return """
            <div class="path-row"><span class="dot no">✕</span><span>\(esc(alternative.option))</span>\(ownerTag(alternative.owner))</div>
            <div class="path-src">\(esc(alternative.reason)) ——《\(esc(source))》</div>
            """
        }.joined()

        let turnBlock = turns.isEmpty ? "" : """
        <div class="path-sub">中途推翻 · \(turns.count)</div>
        \(turnRows)
        """
        let rejectionBlock = rejections.isEmpty ? "" : """
        <div class="path-sub">被否备选 · \(rejections.count)</div>
        \(rejectionRows)
        """
        return """
        <div class="eyebrow">本版路径还原（推翻与拒绝 · 确定性聚合）</div>
        \(turnBlock)
        \(rejectionBlock)
        """
    }

    // MARK: - 每日档案

    static func renderDay(
        project: String, version: String, summary: DaySummary, entries: [DecisionLogEntry]
    ) -> String {
        let decisions = entries.compactMap { entry -> DecisionRecord? in
            if case .decision(let record) = entry { return record }
            return nil
        }
        // 分层（2026-09-17 钦定）：主叙事 = 话题卡 + 💀命中卡（保持文件时序）；
        // 原子决策（系统记账卡 + 简单卡）收进默认折叠的「原子决策」区——
        // 汇总表 / 待办 / 统计仍全量，档案以话题为纲但不丢事实。
        let hasRich = decisions.contains { $0.isTopicEnriched }
        let topicCards = entries.compactMap { entry -> String? in
            switch entry {
            case .decision(let record):
                return record.isTopicEnriched ? topicCardHTML(record) : nil
            case .riskHit(let hit):
                return riskHitCardHTML(hit)
            }
        }.joined()

        let atomicDecisions = decisions.filter { !$0.isTopicEnriched }
        let atomicCards = atomicDecisions.map {
            $0.ledgerKind != nil ? ledgerCardHTML($0) : simpleCardHTML($0)
        }.joined()
        // 历史格式 = 无话题字段且非系统记账（真·旧记录，折叠区内挂说明）
        let hasLegacy = atomicDecisions.contains { $0.ledgerKind == nil }
        let degradeNote = hasLegacy
            ? """
            <div class="note">含<b>历史格式</b>记录（写入时富化功能之前）：简单卡 = 无话题 /
            所有权 / 转折点字段的旧记录，缺章节自动降级渲染，非数据缺失。</div>
            """
            : ""
        let atomicSection = atomicDecisions.isEmpty ? "" : """
        <details class="atomic">
        <summary><span class="chev">▸</span>原子决策 · \(atomicDecisions.count) 条\
        <span class="hint">系统记账与简单确认，点开查看</span></summary>
        <div class="inner">
        \(degradeNote)
        \(atomicCards)
        </div>
        </details>
        """

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
        \(topicCards)
        \(atomicSection)
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
        let pathSection = pathSectionHTML(decisions)

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
        \(pathSection)
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
