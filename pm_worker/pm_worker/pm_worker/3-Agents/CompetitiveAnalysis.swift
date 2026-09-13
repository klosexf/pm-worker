//
//  CompetitiveAnalysis.swift
//  pm_worker
//
//  竞品分析分支（Task 3.8）：五要素结构化竞品分析 prompt 构造。
//  产物走 ```artifact:analysis``` 围栏块，由 ArtifactParser 落盘 05-analysis/competitive-analysis.md。
//

import Foundation

/// nonisolated：纯 prompt 构造，无 IO。
nonisolated enum CompetitiveAnalysisAgent {

    /// 竞品分析 prompt：五要素（竞品名/定位/核心功能/差异点/出处 URL）+ artifact:analysis 协议。
    /// - Parameters:
    ///   - topic: 分析主题（产品方向 / 一句话需求）
    ///   - searchResults: 搜索摘要与网页正文摘录材料（空 = 未联网检索，用模型自身知识）
    static func prompt(topic: String, searchResults: [String]) -> String {
        let material: String
        if searchResults.isEmpty {
            material = "（本次未联网检索——未配置搜索源或检索失败。请基于你自身确信的公开知识分析，"
                + "并在报告开头标注「未联网检索」，所有出处写「模型知识（未联网检索）」。）"
        } else {
            material = searchResults.joined(separator: "\n\n---\n\n")
        }

        return """
        角色：资深产品经理，擅长竞品分析。
        任务：对「\(topic)」做竞品分析，输出结构化报告。

        ## 输入材料（搜索摘要与网页正文摘录）
        \(material)

        ## 分析要求
        1. 识别 3~6 个与该方向直接对标的核心竞品；材料未覆盖但确属直接竞品的，\
        可基于公开知识补充并在出处注明「模型知识」。
        2. 每个竞品必须给出五要素，缺一不可：
           - 竞品名：正式产品名；
           - 定位：一句话概括其目标用户与核心价值；
           - 核心功能：3~5 条最关键的功能；
           - 差异点：与「\(topic)」相比的优势 / 劣势；
           - 出处 URL：材料中的来源链接；材料没有的写「未找到」，禁止编造。
        3. 任何查不到的信息（融资、用户量、定价等）明文写「未找到」，不许臆造数据。
        4. 报告结构：开头一段分析口径说明 → 每个竞品一个小节（含五要素）→ \
        末尾汇总表格（| 竞品名 | 定位 | 核心差异 | 出处 |）→ 一段「对本方向的启示」。

        ## 输出协议（严格遵守，App 会解析落盘到 05-analysis/competitive-analysis.md）
        先用 1~2 句话说明检索口径，然后把完整 Markdown 报告放进一个围栏块，\
        标记写在围栏语言位置：

        ```artifact:analysis
        （完整 Markdown 报告正文）
        ```

        围栏块内是纯 Markdown，不要嵌套其他 artifact 围栏；围栏块外只保留口径说明，不输出报告正文。
        """
    }
}
