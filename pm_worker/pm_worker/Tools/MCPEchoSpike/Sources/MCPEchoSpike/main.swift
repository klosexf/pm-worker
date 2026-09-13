// Task 0.4 前置踩坑：最小 stdio echo server
// 验证：mcp-swift-sdk（Vendor 本地包）在 stdio 传输下可完成
// initialize → tools/list → tools/call 完整握手（MCP Server M5 的技术底座）。

import Foundation
import MCP

@main
struct EchoServer {
    static func main() async throws {
        let server = Server(
            name: "pm-echo-spike",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [
                Tool(
                    name: "echo",
                    description: "回显输入文本（握手验证用）",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([
                            "text": .object([
                                "type": "string",
                                "description": "要回显的文本",
                            ]),
                        ]),
                        "required": .array([.string("text")]),
                    ])
                ),
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            let text = params.arguments?["text"]?.stringValue ?? "(empty)"
            return CallTool.Result(content: [.text("echo: \(text)")])
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        // 挂起主线程等待消息循环（Task.never 不存在，用无限等待替代）
        for await _ in AsyncStream<Void> { $0.onTermination = { _ in } } {}
    }
}
