// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Release builds opt into Sparkle; offline development remains dependency-free.
let withSparkle = ProcessInfo.processInfo.environment["SIMLAUNCH_ENABLE_SPARKLE"] == "1"
let package = Package(
    name: "SimLaunch", defaultLocalization: "en", platforms: [.macOS(.v13)],
    products: [.executable(name: "SimLaunch", targets: ["SimLaunch"])],
    dependencies: withSparkle ? [.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")] : [],
    targets: [
        .target(name: "SimLaunchCore", resources: [.process("Resources")]),
        .executableTarget(name: "SimLaunch", dependencies: [.target(name: "SimLaunchCore")] + (withSparkle ? [.product(name: "Sparkle", package: "Sparkle")] : []), resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "SimLaunchCoreTests", dependencies: ["SimLaunchCore"]),
        .testTarget(name: "SimLaunchUITests", dependencies: ["SimLaunch", "SimLaunchCore"])
    ]
)
