//
//  ArtifactDependencyGraph.swift
//  pm_worker
//
//  产物依赖图（v0.10 §6.10，自适应主线的「任务图」半边）：
//  产物级变更 → 下游受影响集合的确定性推导。两个消费点——
//  ① 重规划循环（变更治理采纳 / 回退坞）：回退执行前先算「将依次重做哪些产物」，
//    折叠进「🔄 已回到」行可见化（计划 → 执行 → 重生成 → 过期清除的闭环起点）；
//  ② 变更提案 impacts 纪律的 App 侧校验（ArtifactParser.BacktrackRequest 契约）：
//    ②/③ 回退建议必须引用至少一个可解析的具体产物，否则不采信 target（降级仅登记）。
//  设计立场（design.md §4 刻意设计 9）：能从既有事实算出来的不交给 LLM——
//  依赖边是硬编码的「严格锚点」（页面清单 ← 映射表、流程基准 ← 核心流程图、
//  PRD ← 映射表/核心流程图/原型/竞品分析），不是「信息性参考」；
//  业务流程图只启发生成、不是锚点，故无下游（② 阶段回退会连带重做它，不走本图）。
//  全纯函数（nonisolated），零磁盘读取，单测直测。
//

import Foundation

nonisolated enum ArtifactDependencyGraph {

    // MARK: - 阶段（rawValue 与 PipelineRun.Stage 一致；独立声明避免隔离耦合）

    nonisolated enum Stage: String {
        case clarify, structure, prototype, prd
    }

    // MARK: - 节点（标识 = ArtifactPath 相对路径；原型为多槽位家族，按目录前缀识别）

    static let clarification = ArtifactPath.clarification      // 01-requirements/澄清要点表.md
    static let architecture = ArtifactPath.architecture        // 02-structure/功能架构图.md
    static let coreFlows = ArtifactPath.coreFlows              // 02-structure/核心流程图.md
    static let businessFlows = ArtifactPath.businessFlows      // 02-structure/业务流程图.md
    static let modulePageMap = ArtifactPath.modulePageMap      // 02-structure/模块-页面映射表.md
    static let prototypeFamily = "03-prototypes/"              // 原型家族（可点击原型/分端/方案槽）
    static let prd = ArtifactPath.prd                          // 04-prd/PRD文档.md
    static let competitiveAnalysis = ArtifactPath.competitiveAnalysis  // 05-analysis/竞品分析.md

    /// 用户可见产物名（与产物 chip 同词汇表——界面文案不露内部路径，design.md v0.9.12 文案原则）。
    static let displayNames: [String: String] = [
        clarification: "澄清要点表",
        architecture: "功能架构图",
        coreFlows: "核心流程图",
        businessFlows: "业务流程图",
        modulePageMap: "模块-页面映射表",
        prototypeFamily: "交互原型",
        prd: "产品需求文档",
        competitiveAnalysis: "竞品分析报告",
    ]

    // MARK: - 边（upstream → 直接依赖者；只收严格锚点）

    static let dependents: [String: [String]] = [
        clarification: [architecture, coreFlows, businessFlows, modulePageMap],
        modulePageMap: [prototypeFamily, prd],
        coreFlows: [prototypeFamily, prd],
        prototypeFamily: [prd],
        competitiveAnalysis: [prd],
        architecture: [],   // 信息性参考非锚点——② 回退整段重推，不在此按产物级展开
        businessFlows: [],
        prd: [],
    ]

    /// 目录前缀 → 该目录的全部产物节点（impacts 引用「02-structure/…」时视为引用整组）。
    static let directoryBuckets: [String: [String]] = [
        "01-requirements": [clarification],
        "02-structure": [architecture, coreFlows, businessFlows, modulePageMap],
        "03-prototypes": [prototypeFamily],
        "04-prd": [prd],
        "05-analysis": [competitiveAnalysis],
    ]

    /// 展示名词干 → 节点（impacts 允许写「核心流程图 · 支付模块」这类不带路径的引用）。
    static let stemMatchers: [(node: String, stem: String)] = [
        (clarification, "澄清要点表"),
        (clarification, "要点表"),
        (architecture, "功能架构图"),
        (architecture, "架构图"),
        (coreFlows, "核心流程图"),
        (businessFlows, "业务流程图"),
        (modulePageMap, "模块-页面映射表"),
        (modulePageMap, "映射表"),
        (prototypeFamily, "原型"),
        (prd, "需求文档"),
        (competitiveAnalysis, "竞品"),
    ]

    // MARK: - 引用解析（LLM 自由文本 → 已知产物节点）

    /// 单条引用解析：具体引用优先（带路径文件名 / 展示名词干 / PRD 大小写不敏感），
    /// 目录级引用（「02-structure 整体重排」——提到目录未点名具体产物）仅作回退，
    /// 避免路径里的目录前缀把具体引用污染成整组。
    /// 解析不出 → 空集（调用方按「列不出具体影响」口径处置，不猜）。
    static func resolveReference(_ text: String) -> Set<String> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var hits: Set<String> = []
        for node in dependents.keys where t.contains(node) {
            hits.insert(node)
        }
        for (node, stem) in stemMatchers where t.contains(stem) {
            hits.insert(node)
        }
        if t.lowercased().contains("prd") {
            hits.insert(prd)
        }
        if hits.isEmpty {
            for (dir, nodes) in directoryBuckets where t.contains(dir) {
                hits.formUnion(nodes)
            }
        }
        return hits
    }

    /// 影响清单批量解析（逐条取并集）。
    static func resolveImpacts(_ impacts: [String]?) -> Set<String> {
        guard let impacts, !impacts.isEmpty else { return [] }
        return impacts.reduce(into: Set<String>()) { acc, ref in
            acc.formUnion(resolveReference(ref))
        }
    }

    // MARK: - 下游闭包（产物级变更 → 连带失效集合，BFS 传递）

    /// 具体产物路径归一到图节点（原型家族内的具体槽位文件归并到家族节点）。
    static func normalize(_ path: String) -> String? {
        if path.hasPrefix(prototypeFamily) { return prototypeFamily }
        return dependents.keys.contains(path) ? path : nil
    }

    /// seeds（产物路径或引用文本）的全部下游依赖者（不含 seeds 自身）。
    static func downstream(ofSeeds seeds: [String]) -> Set<String> {
        var frontier = seeds.reduce(into: Set<String>()) { acc, seed in
            // 先按引用文本解析，再按路径归一（兼容两种入参形态）
            let resolved = resolveReference(seed)
            if resolved.isEmpty, let node = normalize(seed) {
                acc.insert(node)
            } else {
                acc.formUnion(resolved)
            }
        }
        var closure: Set<String> = []
        while let node = frontier.popFirst() {
            for next in dependents[node] ?? [] where !closure.contains(next) {
                closure.insert(next)
                frontier.insert(next)
            }
        }
        return closure
    }

    // MARK: - 重规划循环（计划 → 执行 → 重生成 → 过期清除）

    nonisolated struct Step: Equatable {
        let node: String
        let display: String
    }

    /// 回退到 target 后将依次重生成的产物链（显示顺序 = 重生成顺序）。
    /// 业务流程图不入链——重生成回合按「全部三项结构产物」走（复杂产品另出，非固定项）。
    static func replanSteps(target: Stage) -> [Step] {
        let nodes: [String]
        switch target {
        case .clarify:
            nodes = [clarification, architecture, coreFlows, modulePageMap, prototypeFamily, prd]
        case .structure:
            nodes = [architecture, coreFlows, modulePageMap, prototypeFamily, prd]
        case .prototype:
            nodes = [prototypeFamily, prd]
        case .prd:
            nodes = []   // 无下游重做（prd 不是合法回退目标）
        }
        return nodes.map { Step(node: $0, display: displayNames[$0] ?? $0) }
    }

    /// 重规划行尾（折叠进「🔄 已回到」行——**不新发独立系统行**：
    /// 新前缀会切断快速通道链游走判定，bugs.md B004 同教训）。
    /// 以「；」起始，拼接后行前缀匹配不受影响；只含产物中文名，无内部路径。
    /// backfill（补做）不产计划——被补做的阶段本无产物，无「失效重做」可言。
    static func replanSuffix(target: Stage, mode: String) -> String? {
        let steps = replanSteps(target: target)
        guard !steps.isEmpty else { return nil }
        let chain = steps.map(\.display).joined(separator: " → ")
        let verb: String
        switch target {
        case .clarify:
            verb = "依次更新"
        default:
            verb = mode == "redo" ? "推翻后依次重做" : "依次修订重做"
        }
        return "；重规划：\(verb) \(chain)"
    }

    // MARK: - impacts 纪律（防轻描淡写，提案卡降级）

    /// 采纳前的回退目标核验：②/③ 回退建议必须至少引用一个可解析的具体产物；
    /// 解析为零 → 返回 nil（调用方降级为仅登记，想法级纳入走 ① 增补澄清兜底）。
    /// ① 澄清目标豁免——增补澄清是对话式判断，不依赖产物级影响清单。
    static func verifiedTarget(_ target: Stage, impacts: [String]?) -> Stage? {
        guard target != .clarify else { return target }
        return resolveImpacts(impacts).isEmpty ? nil : target
    }
}
