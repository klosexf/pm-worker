// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MCPEchoSpike",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(path: "../../Vendor/mcp-swift-sdk"),
    ],
    targets: [
        .executableTarget(
            name: "MCPEchoSpike",
            dependencies: [.product(name: "MCP", package: "mcp-swift-sdk")]
        ),
    ]
)
