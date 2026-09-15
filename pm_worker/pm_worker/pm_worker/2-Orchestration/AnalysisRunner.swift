//
//  AnalysisRunner.swift
//  pm_worker
//
//  竞品分析分支编排（Task 3.8）：搜索 → 抓正文 → prompt → LLM → 解析落盘。
//  主 agent 在 sendMessage 命中 isAnalysisIntent 时调用 run（主线不阻塞）。
//

import Foundation
import Combine

/// 竞品分析分支运行器（@MainActor：供 AppModel 持有与接线）。
@MainActor
final class AnalysisRunner: ObservableObject {

    nonisolated deinit {}

    /// 意图识别：命中竞品分析分支的关键词（主 agent 在 sendMessage 里先判这个）。
    nonisolated static func isAnalysisIntent(_ text: String) -> Bool {
        let keywords = ["竞品", "竞争对手", "对标", "对手分析", "competitive"]
        return keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// 运行竞品分析：搜索（可配）→ 抓正文 → LLM 五要素分析 → 落盘 05-analysis/竞品分析.md。
    /// - Returns: 产物 URL；模型未按协议输出有效 analysis 块时返回 nil。
    func run(
        topic: String,
        project: String,
        version: String,
        settings: LLMSettings
    ) async throws -> URL? {
        // ① 联网佐证（搜索源未配置 / 检索失败 → 材料为空，prompt 内置「未联网检索」标注）
        let materials = await gatherMaterials(
            topic: topic,
            endpoint: settings.searchEndpoint,
            apiKey: KeychainStore.get(WebTool.searchAPIKeyKeychainKey)
        )

        // ② 组装 prompt（五要素 + artifact:analysis 协议）
        let prompt = CompetitiveAnalysisAgent.prompt(topic: topic, searchResults: materials)

        // ③ LLM（竞品分析阶段模型，非流式一次性收完）
        let reply = try await LLMClient.complete(
            stage: .analysis,
            settings: settings,
            messages: [ChatMessage(role: .user, content: prompt)],
            maxTokens: 8192
        )

        // ④ 解析 artifact:analysis 块 → 落盘 05-analysis/竞品分析.md
        let blocks = ArtifactParser.parseArtifactBlocks(in: reply)
        return try ArtifactParser.writeAnalysisArtifact(blocks: blocks, project: project, version: version)
    }

    // MARK: - 联网佐证

    /// 搜索取前 5 条摘要；对前 3 条 URL 抓正文（每条截 4000 字，失败跳过继续）。
    /// apiKey 供 Tavily 协议源使用（SearXNG 忽略）。
    private func gatherMaterials(topic: String, endpoint: String, apiKey: String?) async -> [String] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 检索失败不阻塞：回退模型自身知识（prompt 标注「未联网检索」）
        guard let results = try? await WebTool.search(query: topic, endpoint: trimmed, apiKey: apiKey) else { return [] }

        var materials: [String] = []
        let top = Array(results.prefix(5))
        for (index, result) in top.enumerated() {
            materials.append(
                "【搜索结果 \(index + 1)】\(result.title)\nURL: \(result.url)\n摘要：\(result.snippet)"
            )
        }
        for result in top.prefix(3) {
            guard let page = try? await WebTool.fetch(url: result.url, timeout: 15) else { continue }
            // 先提取纯文本再截断：巨型 head 页（如公众号 HTML 可达数 MB）裸截 prefix 全是噪音
            let excerpt = WebTool.extractText(fromHTML: page)
            materials.append("【网页正文摘录】来源：\(result.url)\n\(String(excerpt.prefix(4000)))")
        }
        return materials
    }
}
