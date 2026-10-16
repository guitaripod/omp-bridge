// swift-tools-version:6.0
import Foundation
import PackageDescription

let package = Package(
    name: "omp-bridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        Kit.dependency,
    ],
    targets: [
        .executableTarget(
            name: "omp-bridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "PairingKit", package: "CodingAgentKit"),
            ]
        ),
        .testTarget(
            name: "omp-bridgeTests",
            dependencies: ["omp-bridge"]
        ),
    ]
)

enum Kit {
    static let remote = "https://github.com/guitaripod/CodingAgentKit.git"
    static let version = Version(0, 38, 0)

    static var dependency: Package.Dependency {
        let forced = ProcessInfo.processInfo.environment["OMP_BRIDGE_KIT_REMOTE"] ?? ""
        guard forced.isEmpty || forced == "0" else {
            return .package(url: remote, from: version)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sibling = "../CodingAgentKit"
        let path = root.appendingPathComponent(sibling).standardizedFileURL.path
        if FileManager.default.fileExists(atPath: path + "/Package.swift") {
            return .package(path: sibling)
        }
        return .package(url: remote, from: version)
    }
}
