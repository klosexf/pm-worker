//
//  MilestoneTests.swift
//  pm_workerTests
//
//  方案 B 里程碑清单数据链路四项测试：
//  ① DiscussionEntry.milestones 编解码与旧格式兼容（decodeIfPresent）
//  ② milestoneAssembly 装配（雷达 / 决策 / 下一节点两态）
//  ③ 机器初审结论吸收（✅ 通过 / 无结论 → 机器初审中）与文件变更卡保留
//  ④ mergedSystemIndices 双重渲染去重判据
//

import XCTest
@testable import pm_worker

final class MilestoneTests: XCTestCase {

    // MARK: - ① 编解码与旧格式兼容

    func testMilestonesCodableRoundtrip() throws {
        let entry = DiscussionEntry(
            id: "m1", sessionId: "s1", role: .system,
            content: "📝 决策记录 +2 条——右栏「决策日志」可查。",
            milestones: [
                MilestoneStamp(kind: "decision", count: 2, detail: "待验证 1 条，日志中已标出"),
                MilestoneStamp(
                    kind: "stage", label: "原型",
                    nextAction: "确认后 AI 随即撰写 ④ PRD"
                ),
            ],
            createdAt: "2026-09-13T12:00:00Z"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiscussionEntry.self, from: data)
        XCTAssertEqual(decoded.milestones, entry.milestones)
        XCTAssertEqual(decoded.milestones?.first?.kind, "decision")
        XCTAssertEqual(decoded.milestones?.last?.nextAction, "确认后 AI 随即撰写 ④ PRD")
    }

    func testLegacyEntryWithoutMilestonesDecodesNil() throws {
        // 旧存量行（无 milestones 字段）必须照常解码 → 回退普通注记渲染
        let json = #"{"id":"e1","sessionId":"s1","role":"system","content":"📦 旧格式行","createdAt":"2026-09-01T00:00:00Z"}"#
        let decoded = try JSONDecoder().decode(
            DiscussionEntry.self, from: Data(json.utf8)
        )
        XCTAssertNil(decoded.milestones)
        XCTAssertEqual(decoded.content, "📦 旧格式行")
    }

    // MARK: - ② 装配：雷达 / 决策 / 下一节点

    private func note(
        _ text: String,
        stamps: [MilestoneStamp]? = nil,
        changes: [FileChangeSummary]? = nil
    ) -> TurnNote {
        // 真实链路中 text 为脱 emoji 后的行文本（✅/ℹ️ 结论行前缀须保留）；
        // 测试直接供给与装配函数同口径的文本
        var turnNote = TurnNote(text: text, icon: .dot, tint: .ink500)
        turnNote.milestones = stamps
        turnNote.fileChanges = changes
        return turnNote
    }

    func testAssemblyRadarDecisionAndAwaitingConfirmNode() {
        let notes = [
            note(
                "🔍 漏项雷达发现 4 项——右栏「漏项雷达」可查。",
                stamps: [MilestoneStamp(kind: "radar", count: 4, detail: "缺项 2 · 修正 1 · 风险 1")]
            ),
            note(
                "📝 决策记录 +2 条——右栏「决策日志」可查。",
                stamps: [MilestoneStamp(kind: "decision", count: 2, detail: "待验证 1 条，日志中已标出")]
            ),
            note(
                "📦 交互原型已生成——机器初审中……",
                stamps: [MilestoneStamp(
                    kind: "stage", label: "原型",
                    nextAction: "确认后 AI 随即撰写 ④ PRD"
                )],
                changes: [FileChangeSummary(
                    path: "03-prototypes/prototype-v1.html", added: 120, removed: 0, isNew: true
                )]
            ),
            note("机器初审通过——确定性检查全部通过。确认后进入 ④ PRD。"),
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.count, 3)

        XCTAssertEqual(assembly.rows[0].name, "自评审")
        XCTAssertEqual(assembly.rows[0].countText, "4 项")
        XCTAssertEqual(assembly.rows[0].tab, .radar)

        XCTAssertEqual(assembly.rows[1].name, "决策记录")
        XCTAssertEqual(assembly.rows[1].countText, "+2 条")
        XCTAssertEqual(assembly.rows[1].tab, .decisions)

        // ✅ 机器初审通过 → 下一节点进入「待确认」态（品牌箭头 + 同行尾注）
        XCTAssertEqual(assembly.rows[2].name, "原型待确认")
        XCTAssertEqual(assembly.rows[2].tail, "确认后 AI 随即撰写 ④ PRD")
        XCTAssertTrue(assembly.rows[2].isNext)

        // 📦 行的行文本被吸收，但文件变更卡保留
        XCTAssertEqual(assembly.absorbedCards.count, 1)
        XCTAssertEqual(assembly.absorbedCards.first?.fileChanges?.first?.path, "03-prototypes/prototype-v1.html")
        XCTAssertTrue(assembly.leftovers.isEmpty)
    }

    func testAssemblyReviewingStateWithoutGateVerdict() {
        // 仅有 📦 行（机器初审未出结论）→ 下一节点为「机器初审中」，非品牌箭头
        let notes = [
            note(
                "📦 结构产物已生成——机器初审中……",
                stamps: [MilestoneStamp(
                    kind: "stage", label: "结构产物",
                    nextAction: "确认后 AI 随即生成 ③ 原型"
                )]
            )
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.count, 1)
        XCTAssertEqual(assembly.rows[0].name, "机器初审中")
        XCTAssertFalse(assembly.rows[0].isNext)
        XCTAssertNil(assembly.rows[0].tail)
    }

    func testAssemblyGateSkippedAlsoCountsAsReviewDone() {
        // ℹ️ 机器初审跳过（评审模型不可用）→ 同样进入「待确认」态
        let notes = [
            note(
                "📦 交互原型已生成——机器初审中……",
                stamps: [MilestoneStamp(
                    kind: "stage", label: "原型", nextAction: "确认后 AI 随即撰写 ④ PRD"
                )]
            ),
            note("机器初审跳过（评审模型不可用）——直接进入人工确认。"),
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.last?.name, "原型待确认")
        XCTAssertTrue(assembly.rows.last?.isNext ?? false)
    }

    func testAssemblyRadarZeroIssuesShowsCleanCount() {
        let notes = [
            note(
                "🔍 漏项雷达零缺项——自评覆盖充分。",
                stamps: [MilestoneStamp(kind: "radar", count: 0, detail: nil)]
            )
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.first?.countText, "零缺项")
        XCTAssertNil(assembly.rows.first?.detail)
    }

    // MARK: - ②b 评分卡（PRD 选档）

    func testAssemblyScoreCardRow() {
        let notes = [
            note(
                "📊 PRD 评分卡 → full 档",
                stamps: [MilestoneStamp(
                    kind: "score", label: "full",
                    dims: [
                        MilestoneDim(name: "复杂度", score: 3, reason: "仅 1 条约束"),
                        MilestoneDim(name: "风险", score: 8, reason: "多项开放问题未决"),
                        MilestoneDim(name: "范围", score: 3, reason: "边界有限"),
                    ]
                )]
            ),
            note("开始撰写 full 档 PRD"),
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.count, 1)
        XCTAssertEqual(assembly.rows[0].name, "PRD 评分卡")
        XCTAssertEqual(assembly.rows[0].tail, "→ 完整档模板（full）")
        XCTAssertEqual(assembly.rows[0].dims?.count, 3)
        XCTAssertEqual(assembly.rows[0].dims?[1].score, 8)
        // 评分卡已说「→ 完整档模板」，头部「开始撰写」注记被吸收避免重复
        XCTAssertTrue(assembly.leftovers.isEmpty)
    }

    // MARK: - ③ 旧会话回退

    func testAssemblyLegacyNotesFallBackToLeftovers() {
        // 无任何里程碑载荷（旧会话）→ rows 为空，注记原样回流普通渲染
        let notes = [
            note("📦 交互原型已生成——右栏「产物」可预览——机器初审中……"),
            note("📝 已沉淀 2 条决策记录——「决策日志」可查（待验证项高亮）。"),
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertTrue(assembly.rows.isEmpty)
        XCTAssertTrue(assembly.absorbedCards.isEmpty)
        XCTAssertEqual(assembly.leftovers.count, 2)
    }

    // MARK: - ⑥ 风险超限警示（方案 B 摘要条琥珀段）

    func testAssemblyWarnStampBuildsAmberRow() {
        // 新发射：⚠️ 行携带 kind "warn" 结构化载荷 → 摘要条琥珀行（点击直达雷达）
        let notes = [
            note(
                "活跃 💀 已达 8 条（软上限 3 条）：建议先收敛（证伪关闭 / 降级为 open_question / 合并同源）再继续登记。",
                stamps: [MilestoneStamp(
                    kind: "warn", count: 8,
                    detail: "软上限 3 条 · 建议先收敛（证伪关闭 / 降级为 open_question / 合并同源）再继续登记"
                )]
            )
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.count, 1)
        XCTAssertEqual(assembly.rows[0].name, "活跃风险")
        XCTAssertEqual(assembly.rows[0].countText, "8 条")
        XCTAssertEqual(assembly.rows[0].tab, .radar)
        XCTAssertEqual(
            assembly.rows[0].detail,
            "软上限 3 条 · 建议先收敛（证伪关闭 / 降级为 open_question / 合并同源）再继续登记"
        )
    }

    func testAssemblyLegacyWarnTextParsesWithoutPayload() {
        // 旧会话超限警示无载荷：按 RiskStore 稳定发射格式解析，警示不丢
        let notes = [
            note(
                "活跃 💀 已达 5 条（软上限 3 条）：建议先收敛（证伪关闭 / 降级为 open_question / 合并同源）再继续登记。"
            )
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.count, 1)
        XCTAssertEqual(assembly.rows[0].name, "活跃风险")
        XCTAssertEqual(assembly.rows[0].countText, "5 条")
        XCTAssertEqual(assembly.rows[0].tab, .radar)
        XCTAssertEqual(
            assembly.rows[0].detail,
            "软上限 3 条 · 建议先收敛（证伪关闭 / 降级为 open_question / 合并同源）再继续登记。"
        )
        XCTAssertTrue(assembly.leftovers.isEmpty)
    }

    func testMergeableNotesAbsorbActiveRiskWarningOnly() {
        // 「⚠️ 活跃…」并入回合尾部注记（摘要条承载）；其余 ⚠️（机器初审未过 /
        // 登记失败等）仍走独立事件条，不并入
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        let entries = [
            entry(.assistant, "回答"),
            entry(.system, "⚠️ 活跃 💀 已达 8 条（软上限 3 条）：建议先收敛。"),
            entry(.system, "⚠️ 机器初审未过（Tier2）：页面覆盖不足"),
        ]
        let notes = MessageBubble.mergeableNotes(after: 0, in: entries)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "活跃 💀 已达 8 条（软上限 3 条）：建议先收敛。")

        // 双重渲染去重：仅超限警示行（1）并入气泡，机器初审未过行（2）保持独立胶囊
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        XCTAssertEqual(merged, [1])
    }

    func testMergeableNotesAbsorbRiskRegistrationRow() {
        // 风险改版新增的「⚠️ 自评审新增…」登记行（携 risk 载荷）必须并入回合尾部注记，
        // 由摘要条收编为琥珀「风险 +N 条」行。漏登记会截断合并行走——其后 🔍 雷达 /
        // 📝 决策行全部回退独立旧卡、气泡产物块回退灰胶囊（旧布局回退回归锚点）。
        // ⚡ 快速通道行与「⚠️ 澄清要点表生成失败…」仍走独立事件条。
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(
            _ role: DiscussionEntry.Role, _ content: String,
            stamps: [MilestoneStamp]? = nil
        ) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                milestones: stamps,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        let entries = [
            entry(.assistant, "回答正文（含 artifact:radar / artifact:decision 块）"),
            entry(
                .system,
                "⚠️ 自评审新增 1 个风险（各带应对方案）——右栏「风险」台账逐条决定：采纳方案 / 接受风险。",
                stamps: [MilestoneStamp(kind: "risk", count: 1)]
            ),
            entry(
                .system,
                "🔍 自评审发现 8 项——风险已入右栏「风险」台账。",
                stamps: [MilestoneStamp(kind: "radar", count: 8)]
            ),
            entry(
                .system,
                "📝 决策记录 +1 条——右栏「决策日志」可查。",
                stamps: [MilestoneStamp(kind: "decision", count: 1)]
            ),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，自动收束要点表后直接生成原型（所有产物落盘，均可事后修改）。"),
            entry(.system, "⚠️ 澄清要点表生成失败（模型未返回合法 JSON）——稍后重试确认。"),
            entry(.system, "⚡ 快速通道中止：结构产物没有生成成功——可重试，或走常规确认流程。"),
        ]
        let notes = MessageBubble.mergeableNotes(after: 0, in: entries)
        XCTAssertEqual(notes.count, 3, "风险登记 + 雷达 + 决策三行并入，行走停在 ⚡ 快速通道行")
        XCTAssertEqual(notes[0].milestones?.first?.kind, "risk", "risk 载荷随注记带入摘要条装配")
        XCTAssertEqual(notes[1].milestones?.first?.kind, "radar")
        XCTAssertEqual(notes[2].milestones?.first?.kind, "decision")

        // 双重渲染去重：三行并入气泡，⚡ / 失败警示行保持独立事件条
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        XCTAssertEqual(merged, [1, 2, 3])

        // 摘要条装配：risk → 琥珀「风险 +N 条」行，点击直达风险台账
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows[0].name, "风险")
        XCTAssertEqual(assembly.rows[0].countText, "+1 条")
        XCTAssertEqual(assembly.rows[0].tab, .radar)
        XCTAssertEqual(assembly.rows[1].name, "自评审")
        XCTAssertEqual(assembly.rows[2].name, "决策记录")
    }

    func testWarnRowParserRejectsMalformedText() {
        // 格式漂移 / 非警示行 → nil（回退普通注记渲染，不误判）
        XCTAssertNil(MessageBubble.warnRow(fromText: "机器初审通过——确定性检查全部通过。", index: 0))
        XCTAssertNil(MessageBubble.warnRow(fromText: "活跃 💀 已达 多条（软上限 3 条）：建议收敛。", index: 0))
    }

    func testMergeableNotesAbsorbRiskAdoptionNote() {
        // 采纳落实闭环（2026-09-15）的「⚡ 风险台账 · 已受理采纳…」受理行必须作为
        // preamble 并入落实回合顶部注记。漏登记会让受理行退回独立事件条、与落实
        // 回合断开（回归锚点：⚡ 不入 eventEmojis，白名单走「⚡ 风险台账」专属前缀）。
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        let entries = [
            entry(.assistant, "上一回合回答正文"),
            entry(.system, "⚡ 风险台账 · 已受理采纳，正在落实方案"),
            entry(.assistant, "执行包正文（纯 Markdown，无产物块）"),
        ]
        let notes = MessageBubble.mergeableNotes(before: 2, in: entries)
        XCTAssertEqual(notes.count, 1, "受理行并入落实回合顶部")
        XCTAssertTrue(notes[0].text.contains("风险台账"), "⚡ 前缀已剥（图标由 DSIcon.bolt 承担）")
        XCTAssertFalse(notes[0].text.hasPrefix("⚡"))

        // 快速通道链判定不受影响：受理行不含「快速通道」标记，不构成链式续段
        XCTAssertFalse(
            MessageBubble.isFastForwardChainedBefore(2, in: entries),
            "采纳落实是独立回合，不并上一条回答的头"
        )
    }

    func testMergeableNotesAbsorbAutoSedimentRow() {
        // 方法论自动沉淀行（🧠，①→② 收束时落卡）归**上一回合尾部注记**（aftermath 归属，
        // 刻意不进 isTurnPreamble）：
        // ① 与 ✅ 推进链互不干扰——✅ 仍归下一回合顶部注记；
        // ② amending 场景（「✅ 要点表已按新功能诉求更新——进入」为推进语 preamble）
        //    归增量修订回答顶部，🧠 仍归上一回合尾部，互不打断；
        // ③ ⏳ 待验证提醒行（独立事件条）隔断时 🧠 仍就近归上一回合。
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }

        // 场景① 常规确认：[澄清 assistant][🧠][✅][结构 assistant]
        let rows = [
            entry(.assistant, "澄清最后回答"),
            entry(.system, "🧠 自动沉淀：方法论卡 +2 条 · 合并 1 条进既有卡——卡片库可查，跨项目直接用不降级。"),
            entry(.system, "✅ 澄清要点表已确认——进入 ① 结构设计"),
            entry(.assistant, "结构生成回答"),
        ]
        var notes = MessageBubble.mergeableNotes(after: 0, in: rows)
        XCTAssertEqual(notes.count, 1, "沉淀行并入上一回合尾部")
        XCTAssertEqual(
            notes[0].text,
            "自动沉淀：方法论卡 +2 条 · 合并 1 条进既有卡——卡片库可查，跨项目直接用不降级。"
        )
        XCTAssertFalse(notes[0].text.hasPrefix("🧠"), "emoji 已剥（图标由 DSIcon.mem 承担）")

        notes = MessageBubble.mergeableNotes(before: 3, in: rows)
        XCTAssertEqual(notes.count, 1, "✅ 推进仍归下一回合顶部，不被沉淀行干扰")
        XCTAssertTrue(notes[0].text.contains("澄清要点表已确认"))

        XCTAssertEqual(
            MessageBubble.mergedSystemIndices(in: rows), [1, 2],
            "两行各归其位——无独立胶囊与注记双重渲染"
        )

        // 场景② amending（增补澄清）：[assistant][🧠][✅（推进语 → preamble）][assistant]
        let amending = [
            entry(.assistant, "上一回合回答"),
            entry(.system, "🧠 自动沉淀：方法论卡 +1 条 · 合并 0 条进既有卡——卡片库可查，跨项目直接用不降级。"),
            entry(.system, "✅ 要点表已按新功能诉求更新——进入 ② 结构（增量修订）"),
            entry(.assistant, "增量结构回答"),
        ]
        let amendingNotes = MessageBubble.mergeableNotes(after: 0, in: amending)
        XCTAssertEqual(
            amendingNotes.count, 1,
            "amending 场景：🧠 仍并入上一回合尾部；✅ 推进语不再走 after 链"
        )
        XCTAssertTrue(amendingNotes[0].text.contains("自动沉淀"))
        let amendingTop = MessageBubble.mergeableNotes(before: 3, in: amending)
        XCTAssertEqual(
            amendingTop.count, 1,
            "✅ 要点表已更新行并入增量修订回答顶部注记（塞进 Agent 的回答，不落独立事件条）"
        )
        XCTAssertTrue(amendingTop[0].text.contains("要点表已按新功能诉求更新"))
        XCTAssertEqual(
            MessageBubble.mergedSystemIndices(in: amending), [1, 2],
            "两行各归其位（🧠 → 上一回合尾部 / ✅ → 下一回合顶部）——无独立胶囊与注记双重渲染"
        )

        // 场景③ 待验证提醒（⏳，独立事件条）隔断：[assistant][🧠][⏳][✅][assistant]
        let withNudge = [
            entry(.assistant, "上一回合回答"),
            entry(.system, "🧠 自动沉淀：方法论卡 +0 条 · 合并 2 条进既有卡——卡片库可查，跨项目直接用不降级。"),
            entry(.system, "⏳ 进入结构前——「澄清」阶段还有 1 个已挂方案的风险待验证：右栏「风险」台账逐条核（已解除 / 没解决）。"),
            entry(.system, "✅ 澄清要点表已确认——进入 ① 结构设计"),
            entry(.assistant, "结构回答"),
        ]
        let nudgeNotes = MessageBubble.mergeableNotes(after: 0, in: withNudge)
        XCTAssertEqual(nudgeNotes.count, 1, "沉淀行就近归上一回合（⏳ 隔断不影响 after 链）")
        XCTAssertTrue(nudgeNotes[0].text.contains("自动沉淀"))
        // ⏳ 仍是独立事件条；✅ 仍归下一回合顶部
        XCTAssertFalse(MessageBubble.mergedSystemIndices(in: withNudge).contains(2))
        XCTAssertEqual(MessageBubble.mergeableNotes(before: 4, in: withNudge).count, 1)
    }

    // MARK: - ⑤ 快速通道链式续段 / 流式双渲染去重

    func testFastForwardChainedBeforeDetection() {
        // 系统行工厂（时间戳递增保证 id/排序唯一）
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        // 链式：ack → ⚡ 快速通道行 → 下一回合（index = count 即流式中的续段）
        var entries = [
            entry(.user, "帮我直接出原型"),
            entry(.assistant, "明白了，不再追问。"),
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，自动收束要点表后直接生成原型（所有产物落盘，均可事后修改）。"),
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(entries.count, in: entries),
            "⚡ 受理行在连接器里 → 判链，续段不出独立回答头"
        )
        // 链内第二跳：📦（快速通道：自动确认）行连接结构 → 原型
        entries.append(entry(.assistant, "② 结构产物说明"))
        entries.append(entry(.system, "📦 结构产物已生成（快速通道：自动确认，继续生成 ③ 原型）"))
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(entries.count, in: entries),
            "📦（快速通道：自动确认）行同样构成链"
        )
        // 常规确认推进（无快速通道标记）→ 不判链，保留独立回答头
        let normalEntries = [
            entry(.assistant, "第一答"),
            entry(.system, "📦 结构产物已生成——机器初审中……"),
            entry(.system, "✅ 结构产物已确认——进入 ③ 原型设计"),
        ]
        XCTAssertFalse(
            MessageBubble.isFastForwardChainedBefore(normalEntries.count, in: normalEntries),
            "常规确认推进不带快速通道标记，回合各自保留回答头"
        )
        // 用户消息隔断（快速通道中止后用户重试）→ 不判链
        let userSeparated = [
            entry(.assistant, "ack"),
            entry(.system, "⚡ 快速通道中止：结构产物没有生成成功——可重试，或走常规确认流程。"),
            entry(.user, "重试一下"),
            entry(.assistant, "新回答"),
        ]
        XCTAssertFalse(
            MessageBubble.isFastForwardChainedBefore(3, in: userSeparated),
            "用户消息隔断后不判链，新回答有独立回答头"
        )
    }

    /// 回退重做的链式续段（2026-09-15）：LLM 回退块触发 executeBacktrack 发
    /// 「🔄 已回到 …——马上重做。」连接器行后，regenAfterBacktrack 自动续的第二轮
    /// 生成必须并入上一条回答（不出新 Agent 头）——「一条用户消息一条回答」不因
    /// 中间跨了阶段而破例。漏判会让续段独立出头，观感变成「AI 分两次回答」。
    func testBacktrackContinuationChainedBefore() {
        // 系统行工厂（时间戳递增保证 id/排序唯一）
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        // 流式期：assistant 回答1（含 backtrack 块）→ 🔄 连接器行 → 🎨 note 行 → 续段生成中
        let streaming = [
            entry(.user, "样式改一下，顺便把配色调成苹果质感"),
            entry(.assistant, "本轮判断：上游原型样式修订，走回退。\n```artifact:backtrack\n{\"target\": \"prototype\", \"instruction\": \"…\"}\n```"),
            entry(.system, "🔄 已回到 ③ 原型（PRD 标记过期：局部）——马上重做。"),
            entry(.system, "🎨 按你的要求重做原型"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(streaming.count, in: streaming),
            "🔄 已回到连接器 → 判链，流式续段不出独立回答头"
        )
        // 落盘后：续段 assistant 已在 entries，同样判链
        var settled = streaming
        settled.append(entry(.assistant, "原型修订说明 + 产物块"))
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(3, in: settled),
            "落盘续段同样并入上一条回答"
        )
        // 回退到 ① 增补澄清：note 行「🔄 回到 ① 澄清」（无「已」字）不构成标记，
        // 判链凭据仍是 executeBacktrack 发的「🔄 已回到」行
        let amend = [
            entry(.assistant, "上一答"),
            entry(.system, "🔄 已回到 ① 澄清（增补模式：要点表保留作基底）——AI 将先判断新功能能不能做、适不适合做，再围绕缺口提问。"),
            entry(.system, "🔄 回到 ① 澄清——新功能先判断，再补问缺口"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(amend.count, in: amend),
            "增补澄清续段同样并入"
        )
        // 反例：只有重做 note 行、无「🔄 已回到」连接器 → 不判链（标记收窄防误伤）
        let noteOnly = [
            entry(.assistant, "第一答"),
            entry(.system, "🎨 按你的要求重做原型"),
        ]
        XCTAssertFalse(
            MessageBubble.isFastForwardChainedBefore(noteOnly.count, in: noteOnly),
            "🎨 note 行不是链标记，无连接器的回合保留独立回答头"
        )
    }

    /// 自动收束链的链式续段（2026-09-16）：质量门通过 / 轮次耗尽的「澄清自动收束」
    /// 受理行、增补收束的「要点表已按新功能诉求更新」推进行——确认链自动续生的
    /// 第二条回答（要点表更新 → 结构重生成）必须并入上一条回答（不出新 Agent 头，
    /// 值班单过渡）。漏判会让收束续段独立出头，观感变成「发送一条消息，AI 分两次回答」。
    func testAutoSettleContinuationChainedBefore() {
        // 系统行工厂（时间戳递增保证 id/排序唯一）
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        // 质量门自动收束：回答1 → ✅ 质量门行 → 流式续段生成中
        let qualityGate = [
            entry(.assistant, "风险二讨论 + 三条路"),
            entry(.system, "✅ 质量门通过：漏项雷达无缺项、自检覆盖充分——澄清自动收束，生成要点表并进入 ② 结构。"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(qualityGate.count, in: qualityGate),
            "质量门自动收束行 → 判链，要点表/结构生成不出独立回答头"
        )
        // 轮次耗尽收束：回答1 → ⏳ 耗尽受理行 → 流式续段生成中
        let exhausted = [
            entry(.assistant, "第五轮回答"),
            entry(.system, "⏳ 澄清轮次已达上限——澄清自动收束，缺失项记入要点表 open_questions，进入 ② 结构。"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(exhausted.count, in: exhausted),
            "轮次耗尽受理行 → 判链，自动收束续段同样并入"
        )
        // 增补收束：回答1 → ✅ 要点表已更新推进行 → 流式续段生成中（落盘后同判）
        var amend = [
            entry(.assistant, "增补讨论回答"),
            entry(.system, "✅ 要点表已按新功能诉求更新——进入 ② 结构（增量修订）"),
        ]
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(amend.count, in: amend),
            "增补收束推进行 → 判链，结构增量修订续段并入"
        )
        amend.append(entry(.assistant, "增量结构产物说明"))
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(2, in: amend),
            "落盘后的增补收束续段同样并入上一条回答"
        )
        // 反例：常规确认推进的 ✅ note（无自动收束语）不构成标记——
        // 该场景本就被用户确认消息隔断，标记收窄防「✅ 推进语」整体变成链凭据
        let normal = [
            entry(.assistant, "第一答"),
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计"),
        ]
        XCTAssertFalse(
            MessageBubble.isFastForwardChainedBefore(normal.count, in: normal),
            "常规确认 note 行不是链标记，保留独立回答头"
        )
    }

    func testStreamingAbsorbedIndicesDedupTailPreamble() {
        // 流式期间尾部 preamble 行被流式气泡头部吸收 → displayItems 跳过独立渲染，
        // 防同一行「独立卡 + 流式头部注记」双渲染（持续整个生成过程的旧 bug）
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }
        let ack = entry(.assistant, "ack")
        let entries = [
            ack,
            entry(.system, "⚡ 快速通道：已受理。"),  // 非 preamble → 保持独立事件条
            entry(.system, "✅ 澄清要点表已确认——进入 ② 结构设计"),  // preamble → 流式头部吸收
        ]
        XCTAssertEqual(MessageBubble.streamingAbsorbedIndices(in: entries), [2])
        // 无尾部系统行 → 空集
        XCTAssertEqual(MessageBubble.streamingAbsorbedIndices(in: [ack]), [])
    }

    // MARK: - ④ 双重渲染去重判据

    func testMergedSystemIndicesCoverAdjacentMergeableRowsOnly() {
        // 系统行工厂（时间戳递增保证 id/排序唯一）
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ role: DiscussionEntry.Role, _ content: String) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }

        let entries = [
            entry(.user, "第一问"),
            entry(.assistant, "第一答"),
            entry(.system, "🔍 漏项雷达发现 4 项——右栏「漏项雷达」可查。"),
            entry(.system, "📝 决策记录 +2 条——右栏「决策日志」可查。"),
            entry(.system, "⚠️ 机器初审未过（Tier2）：页面覆盖不足"),  // 不可并入 → 保持独立胶囊
            entry(.user, "第二问"),
            entry(.assistant, "第二答"),
            entry(.system, "📝 决策记录 +1 条——右栏「决策日志」可查。"),  // 尾部注记同样并入
            entry(.system, "✅ 原型已确认——进入 ④ PRD 撰写"),  // preamble → 归下一回合，不并入第二答
            entry(.system, "📊 PRD 评分卡 → full 档"),           // 同上
            entry(.assistant, "第三答"),
        ]
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        // preamble 行（8、9）归第三答头部（9 依赖 8 连续行走），不并入第二答
        XCTAssertEqual(merged, [2, 3, 7, 8, 9])
    }

    func testDuplicateScorecardCollapsedToFirstOccurrence() {
        // 旧版中断重试遗留的重复评分卡（存量历史行）：显示层只保留首张
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(
            _ role: DiscussionEntry.Role, _ content: String, score: Bool = false
        ) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                milestones: score
                    ? [MilestoneStamp(kind: "score", label: "full", dims: nil)]
                    : nil,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }

        let entries = [
            entry(.system, "📊 PRD 评分卡 → full 档", score: true),  // 首张：保留
            entry(.system, "📝 开始撰写 full 档 PRD"),
            entry(.assistant, "第一答（被中断）"),
            entry(.system, "📊 PRD 评分卡 → full 档", score: true),  // 重复：折叠
            entry(.system, "📝 开始撰写 full 档 PRD"),
            entry(.assistant, "第二答"),
        ]

        // 独立胶囊：两张评分卡都不单独渲染（首张并入第一答，重复并入去重集合）
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        XCTAssertEqual(merged, [0, 1, 3, 4])

        // 回合注记：第一答仍携带首张评分卡里程碑
        let first = MessageBubble.mergeableNotes(before: 2, in: entries)
        XCTAssertEqual(first.map(\.text), ["PRD 评分卡 → full 档", "开始撰写 full 档 PRD"])
        XCTAssertEqual(first.first?.milestones?.first?.kind, "score")

        // 第二答只并到 📝 开写注记，重复评分卡被跳过（不重复出卡）
        let second = MessageBubble.mergeableNotes(before: 5, in: entries)
        XCTAssertEqual(second.map(\.text), ["开始撰写 full 档 PRD"])
        XCTAssertNil(second.first?.milestones)
    }

    func testFullPipelineFlowNoDoubleRenderInvariant() {
        // 双渲染防回归总锚点（2026-09-15）：快速通道链 + 常规确认推进混排的**全流程**
        // 差分不变量——逐场景测试守住已知序列，此处守住两套判据的结构对称性本身：
        // ① 每条被气泡吸收（mergeableNotes 两向行走）的系统行都在 mergedSystemIndices
        //    里（displayItems 据此跳过独立胶囊），漏一条即「注记 + 胶囊」双渲染回归；
        // ② 设计上保持独立胶囊的行（⚡ 受理行 = 判链标记，须肉眼可见）不被误吸收；
        // ③ 链式续段判定与注记归属互不污染（连接器是 aftermath，不进续段头部）。
        var at = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(
            _ role: DiscussionEntry.Role, _ content: String,
            stamps: [MilestoneStamp]? = nil
        ) -> DiscussionEntry {
            at.addTimeInterval(1)
            return DiscussionEntry(
                id: UUID().uuidString, sessionId: "s1", role: role, content: content,
                milestones: stamps,
                createdAt: ISO8601DateFormatter().string(from: at)
            )
        }

        let entries = [
            entry(.user, "别问了，直接给我 PRD"),
            // 1 ⚡ 受理行：turnNote 不可并入 → 独立事件条（判链标记须可见）
            entry(.system, "⚡ 快速通道：已按你的要求跳过逐步确认，直接生成原型并撰写 PRD（产物落盘，可事后修改）。"),
            entry(.assistant, "结构产物回答（artifact:structure）"),
            entry(
                .system, "📦 结构产物已生成——机器初审中……（快速通道：自动确认，继续生成 ③ 原型）",
                stamps: [MilestoneStamp(
                    kind: "stage", label: "结构产物", nextAction: "确认后 AI 随即生成 ③ 原型"
                )]
            ),
            entry(.system, "✅ 机器初审通过——确定性检查全部通过。确认后进入 ③ 原型。"),
            entry(.assistant, "原型回答（artifact:prototype）"),  // 5 快速通道链式续段
            entry(
                .system, "⚠️ 自评审新增 2 个风险（各带应对方案）——右栏「风险」台账逐条决定：采纳方案 / 接受风险。",
                stamps: [MilestoneStamp(kind: "risk", count: 2)]
            ),
            entry(
                .system, "🔍 自评审发现 5 项——风险已入右栏「风险」台账。",
                stamps: [MilestoneStamp(kind: "radar", count: 5, detail: "缺项 2 · 修正 1 · 风险 2")]
            ),
            entry(
                .system, "📝 决策记录 +2 条——右栏「决策日志」可查。",
                stamps: [MilestoneStamp(kind: "decision", count: 2)]
            ),
            entry(
                .system, "📦 交互原型已生成——机器初审中……",
                stamps: [MilestoneStamp(
                    kind: "stage", label: "原型", nextAction: "确认后 AI 随即撰写 ④ PRD"
                )]
            ),
            entry(.system, "ℹ️ 机器初审跳过（评审模型不可用）——直接进入人工确认。"),
            entry(.user, "可以，进入下一阶段"),
            entry(.system, "✅ 交互原型已确认——进入 ④ PRD。"),  // 12 preamble：归 PRD 回合头部
            entry(
                .system, "📊 PRD 评分卡 → standard 档",
                stamps: [MilestoneStamp(kind: "score", label: "standard", dims: nil)]
            ),
            entry(.assistant, "PRD 回答（artifact:prd）"),  // 14 被用户消息隔断：独立回答头
            entry(
                .system, "📦 产品需求文档已生成——数据指标与验收用例见文内。",
                stamps: [MilestoneStamp(kind: "stage", label: "PRD")]
            ),
        ]

        // ③ 链判定：原型续段并头；PRD 回合被用户消息隔断，保留独立回答头
        XCTAssertTrue(
            MessageBubble.isFastForwardChainedBefore(5, in: entries),
            "📦 连接器带「快速通道」标记 → 原型回答是结构回答的链式续段"
        )
        XCTAssertFalse(
            MessageBubble.isFastForwardChainedBefore(14, in: entries),
            "用户消息隔断 → PRD 回合不吃上一条回答的头"
        )

        // ① 吸收归属（两向行走）
        XCTAssertEqual(MessageBubble.mergeableNotes(after: 2, in: entries).count, 2,
                       "📦 连接器 + ✅ 初审结论归结构回答尾部")
        XCTAssertEqual(MessageBubble.mergeableNotes(before: 5, in: entries).count, 0,
                       "连接器是 aftermath，不进续段头部（不与结构回答重复渲染）")
        XCTAssertEqual(MessageBubble.mergeableNotes(after: 5, in: entries).count, 5,
                       "风险 / 雷达 / 决策 / 📦 / ℹ️ 五行全归原型回答尾部")
        XCTAssertEqual(MessageBubble.mergeableNotes(before: 14, in: entries).count, 2,
                       "✅ 已确认 + 📊 评分卡归 PRD 回合头部")
        XCTAssertEqual(MessageBubble.mergeableNotes(after: 14, in: entries).count, 1,
                       "📦 PRD 落盘行归 PRD 回答尾部")

        // ② 双渲染不变量：吸收行全集 == 去重集；⚡ 受理行（1）不在其中（独立胶囊保留）
        let merged = MessageBubble.mergedSystemIndices(in: entries)
        XCTAssertEqual(merged, [3, 4, 6, 7, 8, 9, 10, 12, 13, 15])

        // 装配终态：原型回合摘要条 = 风险 / 自评审 / 决策 / 原型待确认（ℹ️ 跳过 → reviewDone）
        let assemblyB = MessageBubble.milestoneAssembly(
            from: MessageBubble.mergeableNotes(after: 5, in: entries)
        )
        XCTAssertEqual(assemblyB.rows.map(\.name), ["风险", "自评审", "决策记录", "原型待确认"])
        XCTAssertTrue(assemblyB.rows.last?.isNext ?? false)
        XCTAssertTrue(assemblyB.leftovers.isEmpty)
        // PRD 回合头部：评分卡进摘要条，✅ 推进行保留为注记行
        let assemblyC = MessageBubble.milestoneAssembly(
            from: MessageBubble.mergeableNotes(before: 14, in: entries)
        )
        XCTAssertEqual(assemblyC.rows.map(\.name), ["PRD 评分卡"])
        XCTAssertEqual(assemblyC.leftovers.count, 1)
    }

    // MARK: - ⑤ 截断卡「重新发送」原始消息查找

    private func entry(
        _ role: DiscussionEntry.Role,
        _ content: String,
        images: [String]? = nil,
        files: [String]? = nil,
        id: String = UUID().uuidString
    ) -> DiscussionEntry {
        DiscussionEntry(
            id: id, sessionId: "s1", role: role, content: content,
            images: images, files: files, createdAt: "2026-09-13T12:00:00Z"
        )
    }

    func testOriginalUserMessageSkipsLegacyRegenerateInstructions() {
        // 截断-重试循环的典型存量：真实请求之后堆积旧版点击留下的「重新生成×」伪用户消息。
        // 重发必须跳过指令，找到真正的原始请求，而非把指令当原始消息重发。
        let entries = [
            entry(.user, "帮我做一个番茄钟的交互原型", id: "u1"),
            entry(.assistant, "```artifact:prototype\n<html>未闭合"),
            entry(.user, "重新生成交互原型"),
            entry(.assistant, "```artifact:prototype\n<html>仍未闭合", id: "a2"),
        ]
        let origin = MessageBubble.originalUserMessage(before: "a2", in: entries)
        XCTAssertEqual(origin?.content, "帮我做一个番茄钟的交互原型")
        XCTAssertEqual(origin?.images, [])
    }

    func testOriginalUserMessageReturnsNearestRealUserMessage() {
        // 多轮会话：取触发本回答的最近一条真实用户输入（含附图文件名 / 引用文件）
        let entries = [
            entry(.user, "第一条", id: "u1"),
            entry(.assistant, "第一答"),
            entry(
                .user, "第二条（带截图与引用文件）",
                images: ["shot-1.png"], files: ["02-structure/模块-页面映射表.md"],
                id: "u2"
            ),
            entry(.system, "📦 注记行"),
            entry(.assistant, "第二答（截断）", id: "a2"),
        ]
        let origin = MessageBubble.originalUserMessage(before: "a2", in: entries)
        XCTAssertEqual(origin?.content, "第二条（带截图与引用文件）")
        XCTAssertEqual(origin?.images, ["shot-1.png"])
        // 重发须一并回填引用文件（否则重生成时 AI 读不到被引用的产物）
        XCTAssertEqual(origin?.files, ["02-structure/模块-页面映射表.md"])
    }

    func testOriginalUserMessageEdgeCases() {
        // 无前置用户消息 → nil（调用方兜底走指令式重试）
        let lonely = [entry(.assistant, "无源回答", id: "a1")]
        XCTAssertNil(MessageBubble.originalUserMessage(before: "a1", in: lonely))

        // 目标条目不在集合内 → nil
        XCTAssertNil(MessageBubble.originalUserMessage(before: "ghost", in: lonely))

        // 全部前置用户消息都是合成指令 → 一路跳过后返回 nil（不误发指令）
        let onlySynthetic = [
            entry(.user, "重新生成PRD"),
            entry(.assistant, "```artifact:prd\n未闭合", id: "a1"),
        ]
        XCTAssertNil(MessageBubble.originalUserMessage(before: "a1", in: onlySynthetic))

        // 首尾空白修剪
        let padded = [
            entry(.user, "  帮我做原型  ", id: "u1"),
            entry(.assistant, "回答", id: "a1"),
        ]
        XCTAssertEqual(
            MessageBubble.originalUserMessage(before: "a1", in: padded)?.content,
            "帮我做原型"
        )
    }

    // MARK: - ⑦ 交付回执卡（方案 A「一次交付，一张回执」）

    func testReceiptFooterWaitingState() {
        // 📦 已落盘但机器初审未出结论 → 等待态脚注（原居中注脚文案统一收进脚注行）
        let rows = [MilestoneRow(id: "next", icon: .clock, tint: .ink500, name: "机器初审中")]
        let footer = MessageBubble.receiptFooter(for: rows)
        XCTAssertEqual(footer?.text, "机器初审中——结论稍后并入本回执")
        XCTAssertEqual(footer?.waiting, true)
    }

    func testReceiptFooterDockGuidanceStripsConfirmedPrefix() {
        // ①②③ 有确认坞：尾注「确认后 …」剥前缀接入确认坞指路句——
        // 推进动作只活在确认坞，回执只指路不替按，不出现双重「确认」措辞
        let rows = [MilestoneRow(
            id: "next", icon: .arrowRight, tint: .brandAccent, name: "原型待确认",
            tail: "确认后 AI 随即撰写 ④ PRD", isNext: true
        )]
        let footer = MessageBubble.receiptFooter(for: rows)
        XCTAssertEqual(
            footer?.text,
            "本轮产物就绪。预览满意后，在下方确认坞选择「确认并进入」，AI 随即撰写 ④ PRD。"
        )
        XCTAssertEqual(footer?.waiting, false)
    }

    func testReceiptFooterPRDSealFlowWithoutDockPhrase() {
        // ④ PRD 封板流程（无确认坞）：尾注无「确认后」前缀 → 不硬套确认坞句式
        let rows = [MilestoneRow(
            id: "next", icon: .arrowRight, tint: .brandAccent, name: "产品需求文档待确认",
            tail: "审阅后可在项目页封板版本", isNext: true
        )]
        let footer = MessageBubble.receiptFooter(for: rows)
        XCTAssertEqual(footer?.text, "本轮产物就绪。审阅后可在项目页封板版本。")
    }

    func testReceiptFooterNilWithoutNextRow() {
        // 仅雷达 / 决策的修订轮（无 stage 行）→ 无脚注
        let rows = [MilestoneRow(
            id: "decision@0", icon: .bookmark, tint: .ink500, name: "决策记录",
            countText: "+1 条", tab: .decisions
        )]
        XCTAssertNil(MessageBubble.receiptFooter(for: rows))
    }

    func testFastForwardAutoNoteExtraction() {
        // 括注句提取；无括注走通用兜底；无标记返回 nil
        XCTAssertEqual(
            MessageBubble.fastForwardAutoNote(
                from: "📦 结构产物已生成——机器初审中……（快速通道：自动确认，继续生成 ③ 原型）"
            ),
            "快速通道 · 自动确认，继续生成 ③ 原型"
        )
        XCTAssertEqual(
            MessageBubble.fastForwardAutoNote(from: "📦 结构产物已生成——快速通道"),
            "快速通道 · 自动确认，产物已落盘，继续推进后续阶段"
        )
        XCTAssertNil(MessageBubble.fastForwardAutoNote(from: "📦 结构产物已生成——机器初审中……"))
    }

    func testAssemblyMarksFastForwardStageAutoNoteAndSkipsDockGuidance() {
        // 快速通道 📦 行（自动确认，无机器门无确认坞）→ 下一节点直接进 isNext 态
        // 且携带自动确认脚注；回执脚注走自动确认句，禁走「确认坞」指路
        let notes = [
            note(
                "结构产物已生成——机器初审中……（快速通道：自动确认，继续生成 ③ 原型）",
                stamps: [MilestoneStamp(
                    kind: "stage", label: "结构产物",
                    nextAction: "确认后 AI 随即生成 ③ 原型"
                )]
            )
        ]
        let assembly = MessageBubble.milestoneAssembly(from: notes)
        XCTAssertEqual(assembly.rows.count, 1)
        XCTAssertTrue(assembly.rows[0].isNext, "快速通道链无机器门，不落「机器初审中」等待态")
        XCTAssertEqual(assembly.rows[0].autoNote, "快速通道 · 自动确认，继续生成 ③ 原型")
        XCTAssertEqual(
            MessageBubble.receiptFooter(for: assembly.rows)?.text,
            "快速通道 · 自动确认，继续生成 ③ 原型"
        )
    }
}
