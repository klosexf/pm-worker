//
//  AnalysisTests.swift
//  pm_workerTests
//
//  Task 3.8 竞品分析分支：WebTool SSRF 防护 / 搜索源 / 意图识别 / prompt 协议
//  / LLMSettings 旧存量兼容。单测不依赖网络：对公网不发真实请求。
//

import XCTest
@testable import pm_worker

final class AnalysisTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmagent-analysis-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        PMAgentStore.rootOverride = tempRoot
    }

    override func tearDown() {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
        PMAgentStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: SSRF：私网 / 环回 / 链路本地拦截（字面 IP 与 localhost 不发真实请求）

    func testFetchBlocksPrivateNetworks() async {
        // 字面 IP：getaddrinfo 数值解析，无网络
        let literalBlocked: [String] = [
            "http://127.0.0.1/x",
            "http://127.1.2.3/",
            "http://10.0.0.5/",
            "http://172.16.0.9/",
            "http://172.31.255.255/",
            "http://192.168.1.1/admin",
            "http://169.254.169.254/latest/meta-data",  // 云元数据端点
            "http://0.0.0.0/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fd12:3456::1]/",
        ]
        for url in literalBlocked {
            do {
                _ = try await WebTool.fetch(url: url, timeout: 3)
                XCTFail("应当拦截私网请求：\(url)")
            } catch let error as WebTool.WebToolError {
                guard case .privateNetworkBlocked = error else {
                    return XCTFail("字面私网 IP 应命中 privateNetworkBlocked：\(url) → \(error)")
                }
            } catch {
                XCTFail("错误类型不符：\(url) → \(error)")
            }
        }

        // localhost：经 /etc/hosts 解析到 127.0.0.1 / ::1（解析失败也视为拦截通过）
        do {
            _ = try await WebTool.fetch(url: "http://localhost:8080/", timeout: 3)
            XCTFail("应当拦截 localhost")
        } catch let error as WebTool.WebToolError {
            switch error {
            case .privateNetworkBlocked, .dnsResolutionFailed: break
            default: XCTFail("localhost 应被拦截：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testFetchInternalDomainThrows() async {
        // .internal 为保留 TLD：解析失败或私网命中即过（不应对公网发真实请求）
        do {
            _ = try await WebTool.fetch(url: "http://nonexistent-probe-7f3a.internal/page", timeout: 3)
            XCTFail("不应成功请求 .internal 域名")
        } catch let error as WebTool.WebToolError {
            switch error {
            case .dnsResolutionFailed, .privateNetworkBlocked: break
            default: XCTFail(".internal 期望解析失败或私网拦截，实际：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: 非 http 协议拒绝

    func testFetchRejectsNonHTTPScheme() async {
        for url in ["ftp://example.com/file", "file:///etc/passwd", "gopher://example.com/x"] {
            do {
                _ = try await WebTool.fetch(url: url, timeout: 3)
                XCTFail("应当拒绝非 http/https 协议：\(url)")
            } catch let error as WebTool.WebToolError {
                guard case .schemeNotAllowed = error else {
                    return XCTFail("应命中 schemeNotAllowed：\(url) → \(error)")
                }
            } catch {
                XCTFail("错误类型不符：\(url) → \(error)")
            }
        }

        // 无协议 URL（新 Foundation 解析容错：可能落在 invalidURL 或 schemeNotAllowed）
        do {
            _ = try await WebTool.fetch(url: "not a url", timeout: 3)
            XCTFail("无协议 URL 应被拒绝")
        } catch let error as WebTool.WebToolError {
            switch error {
            case .invalidURL, .schemeNotAllowed: break
            default: XCTFail("错误类型不符：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: 搜索源未配置

    func testSearchRequiresEndpoint() async {
        for endpoint: String? in [nil, "", "   "] {
            do {
                _ = try await WebTool.search(query: "竞品", endpoint: endpoint)
                XCTFail("endpoint 为空应抛 searchEndpointNotConfigured")
            } catch let error as WebTool.WebToolError {
                XCTAssertEqual(error, .searchEndpointNotConfigured)
            } catch {
                XCTFail("错误类型不符：\(error)")
            }
        }
    }

    // MARK: Tavily 双协议分流

    func testIsTavilyEndpoint() {
        // 官方与国内中转（host 含 "tavily"）
        XCTAssertTrue(WebTool.isTavilyEndpoint("https://api.tavily.com/search"))
        XCTAssertTrue(WebTool.isTavilyEndpoint("https://tavily.sharyuke.com/api/proxy/search"))
        XCTAssertTrue(WebTool.isTavilyEndpoint("  https://TAVILY.sharyuke.com/api/proxy/search  "))
        // SearXNG / 本机端点不误判
        XCTAssertFalse(WebTool.isTavilyEndpoint("https://searxng.example.com/search?format=json"))
        XCTAssertFalse(WebTool.isTavilyEndpoint("http://localhost:8888/search?format=json"))
        XCTAssertFalse(WebTool.isTavilyEndpoint("https://example.com/tavily/search"))
        XCTAssertFalse(WebTool.isTavilyEndpoint(""))
        XCTAssertFalse(WebTool.isTavilyEndpoint("not a url"))
    }

    func testTavilySearchRequiresKey() async {
        // Tavily 端点缺 Key：抛错点在发请求之前（不发网络）
        for key: String? in [nil, "", "   "] {
            do {
                _ = try await WebTool.search(
                    query: "竞品",
                    endpoint: "https://tavily.sharyuke.com/api/proxy/search",
                    apiKey: key
                )
                XCTFail("Tavily 源缺 Key 应抛 searchAPIKeyNotConfigured")
            } catch let error as WebTool.WebToolError {
                XCTAssertEqual(error, .searchAPIKeyNotConfigured)
            } catch {
                XCTFail("错误类型不符：\(error)")
            }
        }
    }

    func testParseTavilyResponse() throws {
        // Tavily 真实响应形态：results 根键 + title/url/content + 额外字段（score/raw_content）应被忽略
        let json = """
        {"query": "AI 笔记应用", "results": [
            {"title": "Notion", "url": "https://notion.so",
             "content": "All-in-one workspace", "raw_content": "全文……", "score": 0.987},
            {"title": "Obsidian", "url": "https://obsidian.md",
             "content": "本地优先笔记", "raw_content": null, "score": 0.95}
        ], "response_time": 1.25}
        """
        let results = try WebTool.parseSearchResults(from: Data(json.utf8))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Notion")
        XCTAssertEqual(results[0].url, "https://notion.so")
        XCTAssertEqual(results[0].snippet, "All-in-one workspace")
        XCTAssertEqual(results[1].snippet, "本地优先笔记")
    }

    // MARK: HTML 正文提取（巨型 head 页防噪音）

    func testExtractTextFromWeChatLikePage() throws {
        // 模拟公众号形态：巨大 head（重复的 script/style 噪音）+ 正文在页尾
        let noise = String(
            repeating: "<script>var x=1;console.log('noise');</script><style>.a{color:#fff}</style>",
            count: 200
        )
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>微信存储空间解读</title>\(noise)</head>
        <body><div id="js_content"><p>微信的存储空间话题&nbsp;&amp;用户误解，请看&nbsp;<b>正文</b>说明。</p></div></body></html>
        """
        let text = WebTool.extractText(fromHTML: html)
        // 正文（页尾、噪音之后）必须被提取到——这正是裸截 prefix 拿不到的部分
        XCTAssertTrue(text.contains("用户误解"))
        XCTAssertTrue(text.contains("正文"))
        // 标题保留（<title> 文本非属性，剥标签后留存）
        XCTAssertTrue(text.contains("微信存储空间解读"))
        // script/style 内容与标签本体剔除
        XCTAssertFalse(text.contains("console.log"))
        XCTAssertFalse(text.contains("color:#fff"))
        XCTAssertFalse(text.contains("<"))
        // &nbsp; 解码为空白并被压缩；&amp; 解码为 &
        XCTAssertTrue(text.contains("&"))
        XCTAssertFalse(text.contains("nbsp"))
    }

    func testExtractTextNumericEntities() throws {
        // 十进制 &#20449;（0x4FE1 信）与十六进制 &#x5fae;（微）
        XCTAssertEqual(WebTool.extractText(fromHTML: "<p>&#x5fae;&#20449;</p>"), "微信")
    }

    func testExtractTextEdgeCases() {
        XCTAssertEqual(WebTool.extractText(fromHTML: ""), "")
        // 纯文本原样返回；未知名实体原样保留
        XCTAssertEqual(WebTool.extractText(fromHTML: "plain text"), "plain text")
        XCTAssertEqual(WebTool.extractText(fromHTML: "a &unknown; b"), "a &unknown; b")
        // HTML 注释剔除
        XCTAssertEqual(WebTool.extractText(fromHTML: "<!-- comment -->正文"), "正文")
        // 多空白压缩为单空格（含换行）
        XCTAssertEqual(WebTool.extractText(fromHTML: "<p>第一段</p>\n\n  <p>第二段</p>"), "第一段 第二段")
    }

    // MARK: 搜索结果解析（SearXNG 及变体，无网络）

    func testParseSearXNGFormat() throws {
        let json = """
        {"results": [
            {"title": "Notion", "url": "https://notion.so", "content": "All-in-one workspace"},
            {"title": "飞书", "url": "https://feishu.cn", "content": "协作平台"},
            {"title": "无链接条目", "url": "", "content": "应被丢弃"}
        ]}
        """
        let results = try WebTool.parseSearchResults(from: Data(json.utf8))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Notion")
        XCTAssertEqual(results[0].url, "https://notion.so")
        XCTAssertEqual(results[0].snippet, "All-in-one workspace")
        XCTAssertEqual(results[1].url, "https://feishu.cn")
    }

    func testParseSearchVariants() throws {
        // 数组根 + name/link/snippet 键名容错
        let json = """
        [{"name": "Obsidian", "link": "https://obsidian.md", "snippet": "本地优先笔记"}]
        """
        let results = try WebTool.parseSearchResults(from: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Obsidian")
        XCTAssertEqual(results[0].url, "https://obsidian.md")
        XCTAssertEqual(results[0].snippet, "本地优先笔记")
    }

    // MARK: 意图识别

    func testIsAnalysisIntent() {
        XCTAssertTrue(AnalysisRunner.isAnalysisIntent("帮我做一份竞品分析"))
        XCTAssertTrue(AnalysisRunner.isAnalysisIntent("对标 Notion 的产品有哪些"))
        XCTAssertTrue(AnalysisRunner.isAnalysisIntent("列一下这个方向的竞争对手"))
        XCTAssertTrue(AnalysisRunner.isAnalysisIntent("竞品调研一下"))
        XCTAssertTrue(AnalysisRunner.isAnalysisIntent("做个 competitive analysis"))
        XCTAssertFalse(AnalysisRunner.isAnalysisIntent("写一份 PRD"))
        XCTAssertFalse(AnalysisRunner.isAnalysisIntent("这个功能怎么设计"))
        XCTAssertFalse(AnalysisRunner.isAnalysisIntent(""))
    }

    // MARK: prompt 协议（五要素 + artifact:analysis）

    func testPromptContainsProtocol() {
        let material = "【搜索结果 1】Notion\nURL: https://notion.so\n摘要：workspace"
        let prompt = CompetitiveAnalysisAgent.prompt(
            topic: "AI 笔记应用",
            searchResults: [material]
        )
        // artifact 协议
        XCTAssertTrue(prompt.contains("artifact:analysis"))
        // 五要素
        XCTAssertTrue(prompt.contains("竞品名"))
        XCTAssertTrue(prompt.contains("定位"))
        XCTAssertTrue(prompt.contains("核心功能"))
        XCTAssertTrue(prompt.contains("差异点"))
        XCTAssertTrue(prompt.contains("出处"))
        // 查不到标「未找到」+ 主题与材料注入
        XCTAssertTrue(prompt.contains("未找到"))
        XCTAssertTrue(prompt.contains("AI 笔记应用"))
        XCTAssertTrue(prompt.contains("https://notion.so"))

        // 空材料 → 标注「未联网检索」
        let offline = CompetitiveAnalysisAgent.prompt(topic: "AI 笔记应用", searchResults: [])
        XCTAssertTrue(offline.contains("未联网检索"))
        XCTAssertFalse(offline.contains("https://notion.so"))
    }

    // MARK: 私网判定纯函数

    func testPrivateAddressPredicate() {
        XCTAssertTrue(WebTool.isPrivateAddress("127.0.0.1"))
        XCTAssertTrue(WebTool.isPrivateAddress("10.1.2.3"))
        XCTAssertTrue(WebTool.isPrivateAddress("172.16.0.1"))
        XCTAssertTrue(WebTool.isPrivateAddress("172.31.255.255"))
        XCTAssertFalse(WebTool.isPrivateAddress("172.32.0.1"))
        XCTAssertTrue(WebTool.isPrivateAddress("192.168.0.1"))
        XCTAssertTrue(WebTool.isPrivateAddress("169.254.1.1"))
        XCTAssertTrue(WebTool.isPrivateAddress("0.0.0.0"))
        XCTAssertFalse(WebTool.isPrivateAddress("8.8.8.8"))
        XCTAssertFalse(WebTool.isPrivateAddress("1.1.1.1"))
        // IPv6
        XCTAssertTrue(WebTool.isPrivateAddress("::1"))
        XCTAssertTrue(WebTool.isPrivateAddress("fd12:3456::1"))
        XCTAssertTrue(WebTool.isPrivateAddress("fe80::a"))
        XCTAssertTrue(WebTool.isPrivateAddress("::ffff:127.0.0.1"))
        XCTAssertFalse(WebTool.isPrivateAddress("2606:4700::1"))
        // 非地址（域名走 DNS 路径，谓词返回 false）
        XCTAssertFalse(WebTool.isPrivateAddress("example.com"))
    }

    // MARK: LLMSettings 旧存量兼容

    func testLLMSettingsBackwardCompatibleDecode() throws {
        // 造一份「Task 3.8 之前的存量」：用工程编码器写出真实线格式，再剥掉 searchEndpoint 字段
        // （注：该工具链把 enum-key 字典编码为交替数组形式，手写对象形式会解码失败）
        var legacySource = LLMSettings.default
        legacySource.searchEndpoint = "http://localhost:8888/search?format=json"
        var encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacySource)
        ) as! [String: Any]
        encoded.removeValue(forKey: "searchEndpoint")
        let legacyData = try JSONSerialization.data(withJSONObject: encoded)

        let settings = try JSONDecoder().decode(LLMSettings.self, from: legacyData)
        XCTAssertEqual(settings.searchEndpoint, "")
        XCTAssertEqual(settings.stages[.research]?.model, "deepseek-flash")
        XCTAssertEqual(settings.stages[.analysis]?.model, "deepseek-flash")

        // 旧存量缺 .analysis 阶段：decode 不报错（回填在 load()）
        var older = legacySource
        older.stages.removeValue(forKey: .analysis)
        var olderEncoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(older)
        ) as! [String: Any]
        olderEncoded.removeValue(forKey: "searchEndpoint")
        let olderSettings = try JSONDecoder().decode(
            LLMSettings.self, from: try JSONSerialization.data(withJSONObject: olderEncoded)
        )
        XCTAssertEqual(olderSettings.searchEndpoint, "")
        XCTAssertNil(olderSettings.stages[.analysis])

        // round-trip 保留 searchEndpoint
        var roundTrip = settings
        roundTrip.searchEndpoint = "http://localhost:8888/search?format=json"
        let decoded = try JSONDecoder().decode(
            LLMSettings.self, from: JSONEncoder().encode(roundTrip)
        )
        XCTAssertEqual(decoded.searchEndpoint, "http://localhost:8888/search?format=json")

        // 缺省配置含竞品分析阶段
        XCTAssertTrue(LLMStage.allCases.contains(.analysis))
        XCTAssertNotNil(LLMSettings.default.stages[.analysis])
        XCTAssertEqual(LLMSettings.default.searchEndpoint, "")
    }

    // MARK: 统一 AI 配置入口（对话八阶段共用一份，embedding 独立）

    func testChatConfigWritesAllChatStages() {
        var settings = LLMSettings.default
        settings.chatConfig = StageModelConfig(provider: "openai", model: "gpt-4o", baseURL: nil)

        // 八个对话阶段全部跟随统一入口
        for stage in LLMStage.chatStages {
            XCTAssertEqual(settings.stages[stage]?.provider, "openai")
            XCTAssertEqual(settings.stages[stage]?.model, "gpt-4o")
        }
        // embedding 不受统一入口影响
        XCTAssertEqual(settings.stages[.embedding]?.provider, "zhipu")
        XCTAssertEqual(settings.stages[.embedding]?.model, "embedding-3")
    }

    func testNormalizedToUnifiedChatMigratesLegacyPerStageSettings() {
        // 分阶段时代的存量：research 是智谱、prd 是 anthropic 网关
        var legacy = LLMSettings.default
        legacy.stages[.research] = StageModelConfig(provider: "zhipu", model: "glm-4.6", baseURL: nil)
        legacy.stages[.prd] = StageModelConfig(
            provider: "anthropic-compat", model: "claude-sonnet-4", baseURL: nil
        )

        let unified = LLMSettings.normalizedToUnifiedChat(legacy)
        // 全部对话阶段收敛为 classify 一份（deepseek）
        for stage in LLMStage.chatStages {
            XCTAssertEqual(unified.stages[stage]?.provider, "deepseek")
            XCTAssertEqual(unified.stages[stage]?.model, "deepseek-flash")
        }
        // embedding 保持独立
        XCTAssertEqual(unified.stages[.embedding]?.model, "embedding-3")
    }

    func testDefaultModelPresetsForProviderSwitch() {
        XCTAssertEqual(StageModelConfig.defaultModel(for: "deepseek"), "deepseek-flash")
        XCTAssertEqual(StageModelConfig.defaultModel(for: "zhipu"), "glm-4.6")
        XCTAssertEqual(StageModelConfig.defaultModel(for: "openai"), "gpt-4o")
        XCTAssertEqual(StageModelConfig.defaultModel(for: "anthropic-compat"), "claude-sonnet-4")
        XCTAssertEqual(StageModelConfig.defaultModel(for: "ollama"), "qwen2.5")
        XCTAssertEqual(StageModelConfig.defaultModel(for: "unknown"), "")
    }
}
