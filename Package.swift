// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ResourceWatch", platforms: [.macOS(.v14)], products: [.executable(name: "ResourceWatch", targets: ["ResourceWatch"])], targets: [.executableTarget(name: "ResourceWatch"), .testTarget(name: "ResourceWatchTests", dependencies: ["ResourceWatch"])])
