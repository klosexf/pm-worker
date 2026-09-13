//
//  WebTool.swift
//  pm_worker
//
//  竞品分析分支（Task 3.8）：受限网页抓取 + 搜索源（SearXNG 兼容 JSON）。
//  SSRF 防护：仅允许 http/https；主机名全部 A/AAAA 记录不得落私网段；
//  响应上限 2MB（截断即停）。
//

import Foundation
import Darwin

/// nonisolated：纯网络与解析，无 UI 状态。
nonisolated enum WebTool {

    enum WebToolError: LocalizedError, Equatable {
        case invalidURL
        case schemeNotAllowed(String)
        case dnsResolutionFailed(String)
        case privateNetworkBlocked(String)
        case http(Int)
        case searchEndpointNotConfigured
        case searchAPIKeyNotConfigured
        case searchBadResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "URL 不合法"
            case .schemeNotAllowed(let scheme):
                "仅允许 http/https 协议（当前：\(scheme.isEmpty ? "未指定" : scheme)）"
            case .dnsResolutionFailed(let host): "域名解析失败：\(host)"
            case .privateNetworkBlocked(let host): "拒绝访问内网/环回地址：\(host)"
            case .http(let code): "HTTP \(code)"
            case .searchEndpointNotConfigured: "未配置搜索源"
            case .searchAPIKeyNotConfigured: "Tavily 搜索源需要 API Key（设置 → 模型 → 竞品联网搜索）"
            case .searchBadResponse(let reason): "搜索响应解析失败：\(reason)"
            }
        }
    }

    struct SearchResult: Codable, Equatable {
        var title: String
        var url: String
        var snippet: String
    }

    /// 响应体上限（截断即停）。
    static let maxResponseBytes = 2 * 1024 * 1024

    // MARK: - 抓取（SSRF 防护）

    /// 受限 GET：校验协议与私网后抓取正文，UTF-8 容错解码。
    static func fetch(url: String, timeout: TimeInterval = 15) async throws -> String {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WebToolError.invalidURL
        }
        let scheme = target.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw WebToolError.schemeNotAllowed(target.scheme ?? "")
        }
        guard let host = Self.hostname(of: target) else { throw WebToolError.invalidURL }

        // 全部 A/AAAA 记录均不得落私网段
        try validateHost(host)

        var request = URLRequest(url: target)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebToolError.http(http.statusCode)
        }

        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxResponseBytes { break }  // 截断即停
        }
        // UTF-8 容错解码（非法字节替换为 U+FFFD）
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - HTML 正文提取

    /// HTML → 纯文本（供网页正文摘录）：去 script/style/noscript 块与注释、剥全部标签、
    /// 解码常见实体、压缩空白。
    /// 背景：部分站点（如微信公众号）head 巨大（可达数 MB），对原始 HTML 裸截 prefix
    /// 全是 meta/script 噪音、一个正文字都进不了材料；先提取再截断才能保证正文可用。
    static func extractText(fromHTML html: String) -> String {
        // ① 去块级不可见内容（script/style/noscript 与注释）
        let blockless = replace(Self.invisibleBlockRegex, in: html, with: " ")
        // ② 剥全部标签（含属性；base64 内联图等随之消失）
        let tagless = replace(Self.tagRegex, in: blockless, with: " ")
        // ③ 解码 HTML 实体（此时串已很小，逐字符扫描代价可忽略）
        let decoded = decodeHTMLEntities(in: tagless)
        // ④ 压缩空白（含 nbsp 解码出的空格）
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 实体名 → 字符（覆盖中文网页常见集；未列出的按原样保留）。
    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "hellip": "…", "mdash": "—", "ndash": "–", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "middot": "·", "bull": "•",
        "copy": "©", "reg": "®", "trade": "™", "times": "×", "divide": "÷",
    ]

    private static let invisibleBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<(script|style|noscript)\b[^>]*>.*?</\1>|<!--.*?-->"#
    )
    private static let tagRegex = try! NSRegularExpression(pattern: #"(?s)<[^>]*>"#)

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }

    /// 实体解码：`&amp;` `&#20449;` `&#x5fae;` 三形态；非实体（无分号 / 超长 / 未知名）原样保留。
    private static func decodeHTMLEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            // 实体总长上限 11（& + 至多 9 位主体 + ;）；用 distance 判距，
            // index(_:offsetBy:limitedBy:) 在串尾会返回 nil 而漏解末尾实体
            guard ch == "&",
                  let semicolon = text[i...].firstIndex(of: ";"),
                  text.distance(from: i, to: semicolon) <= 10
            else {
                out.append(ch)
                i = text.index(after: i)
                continue
            }
            let body = String(text[text.index(after: i)..<semicolon])
            if let decoded = entityValue(of: body) {
                out.append(decoded)
                i = text.index(after: semicolon)
            } else {
                out.append(ch)
                i = text.index(after: i)
            }
        }
        return out
    }

    private static func entityValue(of body: String) -> String? {
        if body.hasPrefix("#") {
            let hex = body.hasPrefix("#x") || body.hasPrefix("#X")
            let digits = String(body.dropFirst(hex ? 2 : 1))
            guard let value = UInt32(digits, radix: hex ? 16 : 10),
                  let scalar = Unicode.Scalar(value)
            else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }

    // MARK: - 搜索（SearXNG / Tavily 双协议）

    /// 搜索源 API Key 的 Keychain 键（Tavily 协议用；SearXNG 无 Key）。
    static let searchAPIKeyKeychainKey = "byok.search"

    /// 搜索源可配置：endpoint 为空抛 searchEndpointNotConfigured（调用侧标「未找到（未配置搜索源）」）。
    /// 双协议按端点域名自动分流——主机名含 "tavily" 走 Tavily（POST JSON + Bearer Key，
    /// 官方 api.tavily.com 与国内中转同构）；否则按 SearXNG 兼容 GET（`{endpoint}?q={urlencoded}`）。
    /// 两者响应同为 `{"results":[{title,url,content}]}`，解析器共用。
    static func search(query: String, endpoint: String?, apiKey: String? = nil) async throws -> [SearchResult] {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw WebToolError.searchEndpointNotConfigured }

        // 端点是用户自配的受信搜索源：只校验协议，不做私网拦截
        guard let url = URL(string: trimmed) else { throw WebToolError.invalidURL }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw WebToolError.schemeNotAllowed(url.scheme ?? "")
        }

        if isTavilyEndpoint(trimmed) {
            return try await searchTavily(query: query, url: url, apiKey: apiKey)
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            throw WebToolError.invalidURL
        }
        // endpoint 已带查询参数则续接，否则新起
        let separator = trimmed.contains("?") ? "&" : "?"
        guard let searchURL = URL(string: "\(trimmed)\(separator)q=\(encoded)") else {
            throw WebToolError.invalidURL
        }

        var request = URLRequest(url: searchURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebToolError.http(http.statusCode)
        }
        return try parseSearchResults(from: data)
    }

    /// Tavily 兼容搜索（官方 / 国内中转同构）：POST `{query,max_results}` + Bearer Key。
    static private func searchTavily(query: String, url: URL, apiKey: String?) async throws -> [SearchResult] {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw WebToolError.searchAPIKeyNotConfigured }

        let body: [String: Any] = ["query": query, "max_results": 5, "search_depth": "basic"]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw WebToolError.searchBadResponse("请求体序列化失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebToolError.http(http.statusCode)
        }
        return try parseSearchResults(from: data)
    }

    /// Tavily 端点判定：主机名包含 "tavily"（api.tavily.com / tavily.sharyuke.com 等中转）。
    static func isTavilyEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host(percentEncoded: false)?.lowercased()
        else { return false }
        return host.contains("tavily")
    }

    /// SearXNG `{"results":[{title,url,content}]}`；尽力兼容数组根 / link / snippet 等变体。
    static func parseSearchResults(from data: Data) throws -> [SearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw WebToolError.searchBadResponse("响应不是合法 JSON")
        }
        let items: [[String: Any]]
        if let dict = json as? [String: Any], let results = dict["results"] as? [[String: Any]] {
            items = results
        } else if let array = json as? [[String: Any]] {
            items = array
        } else {
            throw WebToolError.searchBadResponse("无法识别的结果结构")
        }
        return items.compactMap { item in
            guard let url = (item["url"] ?? item["link"]) as? String, !url.isEmpty else { return nil }
            return SearchResult(
                title: (item["title"] ?? item["name"]) as? String ?? "",
                url: url,
                snippet: (item["content"] ?? item["snippet"] ?? item["description"]) as? String ?? ""
            )
        }
    }

    // MARK: - SSRF 防护

    /// 主机名全部 A/AAAA 记录必须可解析且不落私网段。
    static func validateHost(_ host: String) throws {
        let addresses = resolvedAddresses(for: host)
        guard !addresses.isEmpty else { throw WebToolError.dnsResolutionFailed(host) }
        for address in addresses where isPrivateAddress(address) {
            throw WebToolError.privateNetworkBlocked("\(host) → \(address)")
        }
    }

    /// getaddrinfo 解析全部 A/AAAA 记录（字面 IP 走数值解析，不发网络请求）。
    static func resolvedAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            defer { cursor = node.pointee.ai_next }
            guard let sa = node.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch node.pointee.ai_family {
            case AF_INET:
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        addresses.append(String(cString: buffer))
                    }
                }
            case AF_INET6:
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var addr = sin6.pointee.sin6_addr
                    if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        addresses.append(String(cString: buffer))
                    }
                }
            default:
                continue
            }
        }
        return addresses
    }

    /// 私网/环回/链路本地判定：IPv4 127/8、10/8、172.16/12、192.168/16、169.254/16、0/8；
    /// IPv6 ::1、fc00::/7、fe80::/10（含 IPv4 映射地址的内嵌 IPv4）。域名返回 false（走 DNS 路径）。
    static func isPrivateAddress(_ address: String) -> Bool {
        if let value = Self.ipv4Value(address) { return Self.isPrivateIPv4(value) }

        var addr = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        // ::1 环回
        if bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }
        // fc00::/7 唯一本地
        if bytes[0] & 0xFE == 0xFC { return true }
        // fe80::/10 链路本地
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        // ::ffff:a.b.c.d → 按内嵌 IPv4 判
        if bytes[0...9].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let embedded = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            return isPrivateIPv4(embedded)
        }
        return false
    }

    /// 点分十进制 → 大端 32 位值；非法返回 nil。
    static func ipv4Value(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", maxSplits: Int.max, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard part.count <= 3, let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func isPrivateIPv4(_ value: UInt32) -> Bool {
        func matches(_ network: UInt32, _ prefix: Int) -> Bool {
            value >> (32 - prefix) == network >> (32 - prefix)
        }
        return matches(0x7F00_0000, 8)    // 127/8 环回
            || matches(0x0A00_0000, 8)    // 10/8
            || matches(0xAC10_0000, 12)   // 172.16/12
            || matches(0xC0A8_0000, 16)   // 192.168/16
            || matches(0xA9FE_0000, 16)   // 169.254/16 链路本地（含云元数据）
            || matches(0x0000_0000, 8)    // 0/8
    }

    // MARK: - Private

    private static var queryValueAllowed: CharacterSet {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }

    /// 主机名（剥掉 IPv6 字面量的方括号）。
    private static func hostname(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false) else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host.isEmpty ? nil : host
    }
}
