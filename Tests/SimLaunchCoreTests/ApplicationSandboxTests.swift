import XCTest
@testable import SimLaunchCore

final class ApplicationSandboxTests: XCTestCase {
    private let app = InstalledApplication(id: "dev.simlaunch.fixture")

    func testAndroidAndHarmonyReadTheSelectedDebugSandbox() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = "测试 ' $; folder"
        let file = ".name\nwith spaces"
        for platform in [Platform.Android, .HarmonyOS] {
            let root = platform == .Android ? folder : folder.appendingPathComponent("data/storage/el2/base")
            let childFolder = root.appendingPathComponent(child)
            try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: true)
            try Data().write(to: childFolder.appendingPathComponent(file))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: childFolder)
            let device = Device(platform: platform, key: "fixture", name: "Fixture", state: .running)
            let service = ApplicationService(device: device, connector: {
                DeviceToolConnection(path: "/fixture/tool", target: "selected-target")
            }, execute: { _, arguments, _, _ in
                if platform == .Android {
                    if arguments == ["-s", "selected-target", "shell", "am", "get-current-user"] { return "100\n" }
                    XCTAssertEqual(Array(arguments.dropLast()), ["-s", "selected-target", "shell", "-T"])
                    let prefix = "run-as \(self.app.id) --user 100 "
                    let remote = try XCTUnwrap(arguments.last)
                    XCTAssertTrue(remote.hasPrefix(prefix))
                    return try Self.runShell(String(remote.dropFirst(prefix.count)), in: folder)
                }
                if arguments == ["-t", "selected-target", "shell", "bm", "dump", "-a"] { return "ID: 100:\n\(self.app.id)\n" }
                XCTAssertEqual(Array(arguments.dropLast()), ["-t", "selected-target", "shell", "-b", self.app.id])
                let remote = try XCTUnwrap(arguments.last)
                XCTAssertTrue(remote.hasSuffix(" | base64 -d | sh"))
                XCTAssertFalse(remote.contains("\\"))
                return try Self.runShell(remote, in: folder)
            })
            let top = try await service.sandboxDirectory(for: app, user: "100", components: [])
            XCTAssertEqual(top.entries.first?.name, child)
            XCTAssertEqual(top.entries.first?.kind, .directory)
            XCTAssertEqual(top.entries.first { $0.name == "link" }?.kind, .link)
            let nested = try await service.sandboxDirectory(for: app, user: "100", components: [child])
            XCTAssertEqual(nested.entries.map(\.name), [file])
            XCTAssertFalse(nested.truncated)
            if platform == .Android {
                for index in 0..<2000 {
                    try Data().write(to: childFolder.appendingPathComponent("entry-\(index)"))
                }
                let large = try await service.sandboxDirectory(for: app, user: "100", components: [child])
                XCTAssertEqual(large.entries.count, 2000)
                XCTAssertEqual(Set(large.entries.map(\.id)).count, 2000)
                XCTAssertTrue(large.entries.contains { $0.name == file })
                XCTAssertTrue(large.truncated)
            }
            do {
                _ = try await service.sandboxDirectory(for: app, user: "100", components: ["link"])
                XCTFail("A sandbox link must not be traversed")
            } catch {}
        }
    }

    func testHarmonyInvalidBundleDistinguishesDebugAndReleaseBuilds() async throws {
        let device = Device(platform: .HarmonyOS, key: "fixture", name: "Fixture", state: .running)
        for (provision, expected) in [
            ("debug", "Open this app in the simulator, then refresh to load its debug sandbox."),
            ("release", "This is a release-signed HarmonyOS app. Install a debug-signed build to browse its sandbox.")
        ] {
            let service = ApplicationService(device: device, connector: {
                DeviceToolConnection(path: "/fixture/hdc", target: "selected-target")
            }, execute: { _, args, _, _ in
                if args.contains("-a") { return "ID: 100:\n\(self.app.id)\n" }
                if args.contains("bm") {
                    XCTAssertEqual(args, ["-t", "selected-target", "shell", "bm", "dump", "-n", self.app.id, "-u", "100"])
                    return #"{"name":"\#(self.app.id)","applicationInfo":{"appProvisionType":"\#(provision)"}}"#
                }
                return "[Fail][E003001] Invalid bundle name: \(self.app.id)\r\n"
            })
            do {
                _ = try await service.sandboxDirectory(for: app, user: "100", components: [])
                XCTFail("An unmounted sandbox must return an actionable error")
            } catch {
                XCTAssertEqual(error.localizedDescription, L10n.text(expected))
            }
        }
    }

    func testSandboxTimeoutShowsRefreshMessageWithoutShellScript() async throws {
        let device = Device(platform: .Android, key: "fixture", name: "Fixture", state: .running)
        let service = ApplicationService(device: device, connector: {
            DeviceToolConnection(path: "/fixture/adb", target: "selected-target")
        }, execute: { _, arguments, _, _ in
            if arguments.contains("get-current-user") { return "0\n" }
            throw CLIError("Command timed out: private shell command", timedOut: true)
        })
        do {
            _ = try await service.sandboxDirectory(for: app, user: "0", components: [])
            XCTFail("Expected a folder read timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.text("The simulator took too long to list this folder. Try refreshing."))
        }
    }

    func testSandboxRejectsTraversalAndZeroExitHDCErrors() async throws {
        let device = Device(platform: .HarmonyOS, key: "fixture", name: "Fixture", state: .running)
        let service = ApplicationService(device: device, connector: {
            DeviceToolConnection(path: "/fixture/hdc", target: "selected-target")
        }, execute: { _, arguments, _, _ in
            if arguments.contains("bm") { return "ID: 100:\n\(self.app.id)\n" }
            return "[Fail]Debug app not running\r\n"
        })
        for path in [[".."], ["a/\u{0301}b"]] {
            do {
                _ = try await service.sandboxDirectory(for: app, user: "100", components: path)
                XCTFail("Invalid paths must be rejected")
            } catch {
                XCTAssertEqual(error.localizedDescription, L10n.text("The application sandbox is unavailable."))
            }
        }
        do {
            _ = try await service.sandboxDirectory(for: app, user: "100", components: [])
            XCTFail("HDC errors must not appear as an empty folder")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Debug app not running"))
        }
    }

    private static func runShell(_ command: String, in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError("Fixture shell failed") }
        return String(decoding: data, as: UTF8.self)
    }
}
