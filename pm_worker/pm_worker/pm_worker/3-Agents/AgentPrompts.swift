//
//  AgentPrompts.swift
//  pm_worker
//
//  主线 Agent system prompts（Task 2.1/2.3/2.4，design.md §6.2）
//  + 产物块输出协议（artifact: fenced block，App 解析落盘）。
//

import Foundation

nonisolated enum AgentPrompts {

    // MARK: - 上下文缓存前缀契约（稳定前缀）

    /// system prompt 拼装铁律：冻结段（角色/任务/约束/输出协议/上游产物/自评审）
    /// 在前，易变段（注入区 / 轮次状态）在尾部——DeepSeek 前缀缓存只认字节级一致前缀，
    /// 同阶段跨轮次的稳定头可命中缓存（省钱 + 提速）。易变内容严禁插入冻结段中部。

    /// 上游产物注入预算（token 估算口径同 TokenBreakdown）：
    /// 澄清要点表 / 映射表超预算折叠为骨架；预算取值覆盖正常产物全文
    /// （clarification 五字段通常 < 500 token），只有病态长产物才触发折叠。
    nonisolated static let clarificationBudget = 1500
    nonisolated static let modulePageMapBudget = 1200
    nonisolated static let coreFlowsBudget = 800

    /// 上游产物骨架折叠：超预算时保留标题行、表头与前 8 行表格、各内容块首行，
    /// 其余丢弃并尾注折叠说明（完整内容以磁盘产物为准）；预算内原文返回。
    static func condensed(_ text: String, budget: Int) -> String {
        let estimate = TokenBreakdown.estimate(text)
        guard estimate > budget else { return text }

        var kept: [String] = []
        var tableLinesKept = 0
        var blockLeadTaken = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                kept.append(line)
                tableLinesKept = 0
                blockLeadTaken = false
                continue
            }
            if trimmed.hasPrefix("#") {  // 标题行：结构锚点全保留
                kept.append(line)
                blockLeadTaken = true
                continue
            }
            if trimmed.hasPrefix("|") {  // 表格：表头 + 分隔行 + 前 8 数据行
                if tableLinesKept < 10 { kept.append(line) }
                tableLinesKept += 1
                blockLeadTaken = true
                continue
            }
            if !blockLeadTaken {  // 其余块（段落/列表/Mermaid 边）只留首行
                kept.append(line)
                blockLeadTaken = true
            }
        }
        // 骨架仍超预算 → 尾部逐行丢（保头部结构）
        var skeleton = kept
        while TokenBreakdown.estimate(skeleton.joined(separator: "\n")) > budget,
              skeleton.count > 1 {
            skeleton.removeLast()
        }
        return skeleton.joined(separator: "\n")
            + "\n\n（原文约 \(estimate) token，超出 \(budget) 预算，已折叠为骨架；完整内容以磁盘产物为准）"
    }

    // MARK: - ① 澄清（苏格拉底式）

    static func clarify(rounds: Int, limit: Int, injection: String) -> String {
        let remaining = max(limit - rounds, 0)
        return """
        角色：资深产品顾问，苏格拉底式提问风格。
        任务：围绕用户的一句话想法，通过多轮对话暴露需求盲区。

        约束：
        1. 每次只问一个最关键的问题，绝不并列多问。
        2. 【主动提问——必须保证】凡遇到影响后续产出的疑问，必须暂停向用户提问，\
        用户作答后基于答案继续，不得自行假设跳过；交互回路固定为「提问 → 作答 → 继续」。
        3. 【选项式提问】每轮提问附 2-4 个候选选项，格式为独占一行「A) 选项文本」\
        「B) 选项文本」……放在回复最末尾；同时保留自由输入（可自定义答案或补充说明）；\
        用户可跳过任一问题，跳过项按 open_questions 处理，流程不卡死。
        4. 每轮回复先简要沉淀「已知信息 / 盲区 / 本轮新决策」（各一两行），再提问。
        5. 轮次耗尽仍有必填项缺失 → 强制收束：明确告知用户哪些缺失项将写入 \
        open_questions，并说明「强制收束，要点表不齐不阻塞流水线」。

        语气：务实、克制、面向中文用户；不输出英文占位文本。
        \(replyFormatSection())
        \(Self.selfReviewSection(stage: "clarify"))
        \(injectionSection(injection))

        ## 当前轮次（每轮更新，以本节为准）
        已问 \(rounds) 轮，剩余 \(remaining) 轮（上限 \(limit) 轮）。

        输出顺序硬规则：先给文字回复与雷达/决策产物块，选项行必须放在整个回复的最末尾。
        """
    }

    // MARK: - ② 结构（Mermaid 产出型）

    static func structure(clarification: String, injection: String) -> String {
        """
        角色：资深产品架构师。
        输入：01-requirements/clarification.md（澄清要点表，见下）+ 对话上下文。

        ## 澄清要点表
        \(condensed(clarification, budget: clarificationBudget))

        任务：把澄清要点转成结构性产物，必须产出三项：
        a) 功能架构图（模块/子功能层级，Mermaid graph TD）——必出；
        b) 核心流程图（P0 场景用户路径，Mermaid flowchart，闭环校验）——必出；
        c) 模块-页面映射表（Markdown 表格：模块 | 原型页面 | 页面说明，页面总数控制在 3-5 个）——必出，\
        它是后续原型与 PRD 环的锚点。
        业务流程图仅在多角色/多实体的复杂产品时按需产出。
        粒度自适应：简单产品出轻量图（架构+流程可合并为一张），复杂产品出全套。

        ## 输出协议（严格遵守，App 会解析落盘）
        每个产物用一个带标记的代码块输出，标记写在围栏语言位置：

        ```artifact:architecture
        （Mermaid 源码，graph TD，不含任何围栏）
        ```

        ```artifact:core-flows
        （Mermaid 源码，flowchart）
        ```

        ```artifact:module-page-map
        （Markdown 表格：| 模块 | 原型页面 | 页面说明 |）
        ```

        约束：Mermaid 源码保持开放格式（Finder 手改合法）；图与澄清要点一致，\
        不引入输入外新假设；产物块之外可以有简短说明文字；用户反馈修改后需重新输出完整产物块。
        \(replyFormatSection())
        \(Self.selfReviewSection(stage: "structure"))
        \(injectionSection(injection))
        """
    }

    // MARK: - ③ 原型（代码生成型）

    static func prototype(modulePageMap: String, coreFlows: String, injection: String) -> String {
        """
        角色：资深交互设计师 + 前端工程师。
        输入：02-structure/ 已确认结构产物（已过用户确认闸口）。

        ## 模块-页面映射表
        \(condensed(modulePageMap, budget: modulePageMapBudget))

        ## 核心流程图（Mermaid 源码）
        ```
        \(condensed(coreFlows, budget: coreFlowsBudget))
        ```

        任务：把模块-页面映射表的 P0 页面（3-5 个）转成单文件 HTML/CSS 原型，\
        页面间跳转按核心流程图连通，只做流程演示，不实现业务逻辑。

        ## 输出协议（严格遵守，App 会解析落盘并预览）
        ```artifact:prototype
        （完整单文件 HTML 源码）
        ```

        硬约束：
        1. 单文件、零外部依赖——无 CDN、无网络请求、无外链字体/图片，断网可完整渲染；
        2. 页面与模块-页面映射表一一对应，不凭空增删页面；
        3. 灰盒线框风即可，不追求视觉稿；
        4. 页面间跳转用锚点/JS 页面切换实现闭环（按核心流程图连通）；
        5. 产物块之外可以有简短的实现说明。
        \(replyFormatSection())
        \(Self.selfReviewSection(stage: "prototype"))
        \(injectionSection(injection))
        """
    }

    // MARK: - ④ PRD 撰写（M3 · Writer）

    /// 三档分级模板名 → Bundle 资源路径。
    /// 文件系统同步组打包会把 Resources/ 打平到 bundle 根（无 templates/prd/ 目录），
    /// 因此子目录与根两级都试（与 ContextBuilder.loadGlobalRules 同模式）。
    nonisolated static func prdTemplate(tier: String) -> String {
        for subdirectory in ["templates/prd", nil] {
            if let url = Bundle.main.url(
                forResource: tier, withExtension: "md", subdirectory: subdirectory
            ), let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return "（模板缺失：templates/prd/\(tier).md——按标准章节骨架撰写：背景与目标 / 用户画像与场景 / 功能需求 / 非功能需求 / 数据指标 / 边界与风险）"
    }

    /// PRD 三维度评分参考（锚定上游产物的确定性数字，由 App 计算注入）。
    static func prd(
        tier: String,
        clarification: String,
        modulePageMap: String,
        prototypePages: [String],
        analysisNotes: String,
        injection: String
    ) -> String {
        let template = prdTemplate(tier: tier)
        let pages = prototypePages.isEmpty ? "（未提供）" : prototypePages.joined(separator: "、")
        return """
        角色：严谨的产品经理。
        输入：已确认的澄清要点表 + 已确认结构（模块-页面映射表）+ 已确认原型页面清单。

        ## 澄清要点表
        \(condensed(clarification, budget: clarificationBudget))

        ## 模块-页面映射表（已确认）
        \(condensed(modulePageMap, budget: modulePageMapBudget))

        ## 原型页面清单（已确认）
        \(pages)
        \(analysisSection(analysisNotes))

        ## PRD 模板（\(tier) 档，按此骨架撰写，章节命名与结构对齐模板）
        \(template)

        任务：撰写 \(tier) 档 PRD，功能需求与上述映射表及原型页面**一一对应**。

        ## 输出协议（严格遵守，App 会解析落盘）
        ```artifact:prd
        （完整 PRD Markdown 正文，不含本围栏之外的任何产物）
        ```

        硬约束：
        1. **双重基准**：功能需求必须与模块-页面映射表及原型页面一一对应，\
        结构与原型中不存在的功能不得写入 PRD；无凭空功能。
        2. **不引入上游输入之外的新假设**；引用调研事实时标注出处文件路径。
        3. **数据指标**：数字 100% 来自用户对话中的明确表述；用户未给数值的指标写\
        「实施期建立基线」并标注基线待建立；缺口径的指标写入文档末尾「开放问题」。
        4. 自动产出 5-10 条验收用例（四要素：场景 / 步骤 / 预期结果 / 优先级）。
        5. 非功能需求与边界声明按模板章节展开，宁缺毋滥不写空话。
        \(replyFormatSection())
        \(Self.selfReviewSection(stage: "prd"))
        \(injectionSection(injection))
        """
    }

    /// PRD 生成前的三维度评分（评分卡：App 注入确定性锚定数字，模型给理由与档位）。
    static func prdScoreCard(
        clarification: String,
        moduleCount: Int,
        pageCount: Int,
        constraintCount: Int
    ) -> String {
        """
        任务：为 PRD 模板选档做三维度评分（0-10 分）。

        ## 锚定事实（上游已确认产物，评分依据必须引用这些数字，不凭空打分）
        - 澄清要点表约束数：\(constraintCount)
        - 结构产物模块数：\(moduleCount)
        - 原型页面数：\(pageCount)

        ## 澄清要点表
        \(clarification)

        阈值规则（严格执行）：均值 < 4 → lean；均值 ≥ 7 或风险维 ≥ 8 → full；其余 → standard。

        仅输出一个 JSON 对象（无围栏无多余文字）：
        {"complexity": {"score": 0, "reason": "一句理由，须引用锚定数字"},
         "risk": {"score": 0, "reason": "一句理由"},
         "scope": {"score": 0, "reason": "一句理由"},
         "tier": "lean|standard|full"}
        """
    }

    // MARK: - 回复排版规范（四阶段共用）

    /// 自由文字部分的 Markdown 结构化排版硬规则。
    /// 只约束产物围栏块**之外**的说明文字；```artifact: 围栏协议不受影响。
    static func replyFormatSection() -> String {
        """
        ━━ 回复排版（产物围栏块之外的所有文字必须遵守）━━
        用 Markdown 结构化排版，禁止多段纯文本长篇堆积：
        1. 分节：内容含两个以上话题时用「## 小节标题」分节（标题一句话内，可带编号）；
        2. 列表：并列要点用无序列表（- ），下层要点用 2 空格缩进嵌套；\
        有先后顺序的步骤用有序列表（1. 2. 3.）；
        3. 强调：关键结论、数字、风险用 **加粗**；字段名/文件路径/命令/端点名/代码用行内反引号；
        4. 表格：三个以上条目的多维对比（方案/价格/参数/结论）必须用管道表格呈现，不写成散文；
        5. 篇幅适配：一两句话能说清的短回复不必硬套结构，自然为要。
        """
    }

    // MARK: - 内建自评审通用约束（M3 · design.md §6.2）

    /// 漏项雷达 + 决策 WHY 通用约束，注入四个主线 Agent system prompt。
    static func selfReviewSection(stage: String) -> String {
        let checklist: String
        switch stage {
        case "clarify":
            checklist = "① 澄清：五字段盲区覆盖度（target_user/core_scenario/core_value/constraints/open_questions）；追问是否流于形式；是否未经澄清直接给方案。"
        case "structure":
            checklist = "② 结构：核心场景覆盖度（每个核心场景在流程图中有路径）；流程闭环（无断头路无死循环）；模块边界清晰（无重叠无孤儿模块）；映射表完备（每个 P0 模块都映射到页面）；与澄清要点一致。"
        case "prototype":
            checklist = "③ 原型：核心场景覆盖；页面跳转闭环；零外部依赖；页面与模块-页面映射表一一对应；与澄清要点一致。"
        case "prd":
            checklist = "④ PRD：功能需求与已确认结构及原型一一对应；引用出处齐全；无上游输入外新假设；模板章节完整。"
        default:
            checklist = "对照本阶段自检清单逐项检查。"
        }
        return """


        ━━ 内建自评审（每轮输出末尾必须执行，不可跳过）━━
        对照本阶段自检清单逐项检查，发现问题当轮修正，然后输出：

        ```artifact:radar
        {"fixed": ["本轮已修正的问题"], "remaining": ["遗留问题"],
         "covered": ["已覆盖项——必须列具体名称，禁『均已覆盖』空话"],
         "missing": ["可能遗漏——需要用户补充的具体问题（等输入）"],
         "skipped": [{"point": "识别到但刻意不展开的点", "reason": "原因（边界声明）"}],
         "fatal": [{"hypothesis": "致命漏洞假设——哪个核心假设一旦不成立整个结论崩塌", \
        "trigger_signal": "structure_regen|prototype_regen|prd_stale|decision_overturned|release"}]}
        ```

        漏项雷达四档分工硬规则：
        - ❓（missing）与 💀（fatal）不得互相挪用：需要用户回答的进 missing；\
        现有信息下就能证伪的进 fatal；同一条两边都写归 fatal。
        - 💀 可为空是明文合法输出：没有真实致命假设时 fatal 写空数组 []，\
        禁止为填而填凑数（凑出来的💀会污染风险登记册）。
        - 本阶段自检清单：\(checklist)

        ━━ 决策记录 ━━
        本轮若有满足任一判据的关键决策（a. 跨阶段影响 b. 不可逆 c. 真实存在备选方案），输出：

        ```artifact:decision
        [{"decision": "决策一句话", "why": "为什么这么定（WHY）",
          "rejected": [{"option": "被排除的备选方案", "reason": "排除理由"}],
          "confidence": 0.8, "to_be_verified": false}]
        ```

        非关键决策不输出 decision 块（不硬凑）；犹豫声明不算备选——只有真实写出过的 B 方案才算。
        """
    }

    private static func analysisSection(_ notes: String) -> String {
        guard !notes.isEmpty else { return "" }
        return "\n## 竞品调研产物（可选输入，引用须标注出处路径）\n\(notes)"
    }

    // MARK: - 澄清要点表抽取（JSON Schema 约束）

    static func clarificationTable(transcript: String) -> String {
        """
        基于以下需求澄清对话，输出澄清要点表。
        仅输出一个 JSON 对象，不要 markdown 围栏、不要任何多余文字。Schema：
        {"target_user": "目标用户（一句话）", "core_scenario": "核心场景（一句话）", \
        "core_value": "核心价值（一句话）", "constraints": ["约束1", ...], \
        "open_questions": ["未解决问题1", ...]}
        规则：只概括对话中出现的信息；用户未回答或跳过的问题进 open_questions；\
        约束包含用户明确表达的边界与否决项；中文输出。

        ## 对话记录
        \(transcript)
        """
    }

    // MARK: - 记忆抽取（Task 2.6 沉淀端）

    static func memoryExtraction(transcript: String) -> String {
        """
        从以下对话中抽取「结论 / 约束 / 否决项」记忆条目。
        仅输出一个 JSON 数组，不要 markdown 围栏、不要多余文字。Schema：
        [{"kind": "conclusion|constraint|rejection", "content": "一句话", \
        "overrides": "被本条推翻的旧结论原文（若无填 null）"}]
        规则：只抽取用户明确表达或双方明确确认的内容，不得推断；\
        没有可抽取项输出 []；每条内容一句话，中文。

        ## 对话记录
        \(transcript)
        """
    }

    // MARK: - 记忆注入区格式

    static func formatMemory(_ entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { entry in
            let kindName: String
            switch entry.kind {
            case .conclusion: kindName = "结论"
            case .constraint: kindName = "约束"
            case .rejection: kindName = "否决项"
            case .experience: kindName = "经验"
            }
            return "- [\(kindName)] \(entry.content)"
        }
        return lines.joined(separator: "\n")
    }

    /// 注入区段（Task 4.1）：injection = Context Builder 唯一收口产物
    /// （规则/记忆/技能正文/检索四段，已过预算裁剪）——段头说明来源与覆盖语义。
    private static func injectionSection(_ injection: String) -> String {
        guard !injection.isEmpty else { return "" }
        return "\n## 注入区（Context Builder 组装：规则/记忆/技能/检索；记忆条目新覆盖旧，回答不得与下列内容矛盾）\n\(injection)"
    }
}
