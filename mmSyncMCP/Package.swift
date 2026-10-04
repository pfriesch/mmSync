// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mmSyncMCP",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MoneyMoneyMCP"),
        .executableTarget(name: "mmsync-mcp", dependencies: ["MoneyMoneyMCP"]),
        .testTarget(name: "MoneyMoneyMCPTests", dependencies: ["MoneyMoneyMCP"]),
    ]
)
