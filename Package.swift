// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SimLaunch", defaultLocalization: "en", platforms: [.macOS(.v13)], products: [.executable(name: "SimLaunch", targets: ["SimLaunch"])], targets: [.target(name: "SimLaunchCore", resources: [.process("Resources")]), .executableTarget(name: "SimLaunch", dependencies: ["SimLaunchCore"], resources: [.process("Resources")]), .testTarget(name: "SimLaunchCoreTests", dependencies: ["SimLaunchCore"])])
