//
//  VersionStore.swift
//  pm_worker
//
//  版本封板运行时（Task 3.7，design.md 版本管理）：
//  ① 风险结算挂载点（settleRisks 回调——AppModel 接线 RiskStore.settleAllForRelease，
//     因为 RiskStore 实例归 AppModel 持有）
//  ② release-notes 写入 07-reports/release-notes.md（write-then-verify）
//  ③ version.json status → released（保持 PMAgentStore 的 prettyPrinted + sortedKeys 编码）
//  ④ 版本目录及其子项递归 immutable（目录只读）
//  Git 快照（GitSnapshotQueue）由调用方在封板成功后自行触发（主 agent 在 AppModel 接线）。
//

import Foundation
import Combine

@MainActor
final class VersionStore: ObservableObject {
    /// 封板进行中（防重入）。
    @Published private(set) var releasing = false
    /// 最近一次封板成功的版本号。
    @Published private(set) var lastReleased: String?

    /// Xcode 26 / Swift 6.2 isolated-deinit 运行时 bug 规避：显式退出隔离销毁路径。
    nonisolated deinit {}

    // MARK: - 封板

    /// 封板：风险结算 → 写 release-notes → 标记 version.json → 目录冻结只读。
    ///
    /// - Parameter notes: release-notes Markdown 正文（AppModel 先用 releaseNotesPrompt 生成再传入）。
    /// - Parameter settleRisks: 目录冻结前调用的结算闭包（必须趁目录可写时落盘）。
    ///   AppModel 接线点：`settleRisks: { [weak riskStore] in try riskStore?.settleAllForRelease() }`。
    /// - Throws: 版本不存在 / 已封板 / 目录已只读 / 磁盘写失败。
    func release(
        project: String,
        version: String,
        notes: String,
        settleRisks: (() throws -> Void)? = nil
    ) throws {
        guard !releasing else { return }
        let dir = PMAgentStore.versionURL(project: project, version: version)

        guard let doc = try PMAgentStore.readVersion(project: project, version: version) else {
            throw Self.error(
                "版本不存在：\(project)/\(version)（unversioned 不是发布单元，不可封板）", code: 1
            )
        }
        guard doc.status != .released else {
            throw Self.error("版本已封板：\(version)", code: 2)
        }
        guard !Self.isImmutable(at: dir) else {
            throw Self.error("版本目录已只读（immutable）：\(dir.path)", code: 3)
        }

        releasing = true
        defer { releasing = false }

        // ① 风险结算挂载点：封板时全部 open 💀 结算为 closed_unfired（§6.2 ④ 悬空口径闭合）。
        //    RiskStore 实例归 AppModel 持有，这里只留回调槽，由主 agent 在 AppModel 接线：
        //    release(..., settleRisks: { try riskStore.settleAllForRelease() })
        try settleRisks?()

        // ② release-notes.md（write-then-verify，E5）
        try PMAgentStore.writeVerified(
            notes,
            to: dir.appendingPathComponent("07-reports/release-notes.md")
        )

        // ③ version.json：status = released（编码格式与 PMAgentStore 私有 write 一致，读写兼容）
        var released = doc
        released.status = .released
        released.releasedAt = ISO8601.dayString()
        try writeVersionDocument(released, to: dir.appendingPathComponent("version.json"))

        // ④ 目录冻结：版本目录 + 所有子项递归 immutable
        try Self.setImmutable(dir)

        lastReleased = version
    }

    // MARK: - 只读目录（immutable）

    /// 该项目自身是否被 immutable 保护。
    nonisolated static func isImmutable(at url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.immutable] as? NSNumber)?.boolValue == true
    }

    /// 解除保护：递归清掉 immutable（测试 tearDown / 人工清理用；正常封板流程后不应调用）。
    nonisolated static func unprotect(_ url: URL) throws {
        try applyImmutable(false, to: url)
    }

    nonisolated private static func setImmutable(_ url: URL) throws {
        try applyImmutable(true, to: url)
    }

    /// url 自身 + 全部后代递归设置 immutable（子项单点失败不阻断整体——目录已冻结即可拦截写入）。
    nonisolated private static func applyImmutable(_ flag: Bool, to url: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes([.immutable: flag], ofItemAtPath: url.path)
        let children = (try? fm.subpathsOfDirectory(atPath: url.path)) ?? []
        for rel in children {
            try? fm.setAttributes([.immutable: flag], ofItemAtPath: url.appendingPathComponent(rel).path)
        }
    }

    // MARK: - release-notes LLM prompt（生成辅助）

    /// 封板时生成 release-notes 的 LLM prompt（AppModel 持有本 prompt 调 LLM，
    /// 产出作为 release(notes:) 参数落盘）。AgentPrompts.swift 归主 agent 所有，故置于本文件。
    nonisolated static func releaseNotesPrompt(artifactsSummary: String) -> String {
        """
        你是 PM Copilot。请基于下面给出的「版本产物摘要」，为即将封板的版本撰写 release-notes（发布说明）。

        要求：
        1. 只输出 Markdown 正文本身，不要任何前后缀说明，不要用代码围栏包裹。
        2. 内容必须严格来自产物摘要，禁止虚构不存在的阶段、产物、数据或结论。
        3. 使用中文，简洁清晰，总长不超过 400 字。
        4. 结构建议：
           - ## 本版本概览：一句话总结本版本的目标与范围。
           - ## 完成阶段：列出本版本实际完成的主要流水线阶段（澄清/结构/原型/PRD 等）。
           - ## 产物清单：逐项列出实际存在的产物文件并各配一句话说明。

        版本产物摘要：
        \(artifactsSummary)
        """
    }

    // MARK: - Private

    /// version.json 写入（与 PMAgentStore 私有 write 格式一致：prettyPrinted + sortedKeys，
    /// 经 writeVerified 做 write-then-verify）。
    private func writeVersionDocument(_ doc: VersionDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = String(data: try encoder.encode(doc), encoding: .utf8) ?? ""
        try PMAgentStore.writeVerified(text, to: url)
    }

    nonisolated private static func error(_ message: String, code: Int) -> NSError {
        NSError(domain: "VersionStore", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
