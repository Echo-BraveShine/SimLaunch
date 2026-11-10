import XCTest
@testable import SimLaunchCore

final class SandboxFileTests: XCTestCase {
    private let app = InstalledApplication(id: "dev.simlaunch.fixture")

    func testSandboxImportRejectsDirectoriesAndDoesNotSendOnCollision() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("existing file.txt")
        try Data([1, 2, 3]).write(to: file)
        let appID = app.id
        let device = Device(platform: .HarmonyOS, key: "fixture", name: "Fixture", state: .running)
        let service = ApplicationService(device: device, connector: {
            DeviceToolConnection(path: "/fixture/hdc", target: "selected-target")
        }, execute: { _, arguments, _, _ in
            if arguments.contains("bm") { return "ID: 100:\n\(appID)\n" }
            XCTAssertEqual(Array(arguments.dropLast()), ["-t", "selected-target", "shell", "-b", appID])
            let command = try XCTUnwrap(arguments.last)
            let encoded = try XCTUnwrap(command.split(separator: " ").dropFirst().first)
            let script = String(decoding: try XCTUnwrap(Data(base64Encoded: String(encoded))), as: UTF8.self)
            XCTAssertTrue(script.contains("existing file.txt"))
            if script.contains("SIMLAUNCH_IMPORT_READY") { return "SIMLAUNCH_IMPORT_EXISTS\n" }
            XCTAssertTrue(script.contains("rmdir"))
            return ""
        })
        for (source, message) in [
            (folder, "Choose a regular local file to import."),
            (file, "A file or folder with this name already exists.")
        ] {
            do {
                try await service.importSandboxFile(source, into: ["files"], app: app, user: "100")
                XCTFail("Expected the import to stop before the file transfer")
            } catch {
                XCTAssertEqual(error.localizedDescription, L10n.text(message))
            }
        }
    }

    func testAndroidTransferKeepsBinaryBytesSeparateFromDiagnosticsAndExportsAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("adb")
        try #"""
        #!/bin/sh
        test "$1 $2 $3 $4" = "-s selected-target shell -T" || exit 1
        case "$5" in "run-as dev.simlaunch.fixture --user 0 "*cat*) ;; *) exit 2;; esac
        printf '\377\000\200'
        printf 'diagnostic' >&2
        """#.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let service = ApplicationService(
            device: Device(platform: .Android, key: "fixture", name: "Fixture", state: .running),
            connector: { DeviceToolConnection(path: tool.path, target: "selected-target") },
            execute: { _, arguments, _, _ in
                if arguments.contains("get-current-user") { return "0\n" }
                XCTAssertEqual(Array(arguments.dropLast()), ["-s", "selected-target", "shell", "-T"])
                XCTAssertTrue(arguments.last?.contains("stat -c %s") == true)
                return "3\n"
            }
        )
        let name = "icon ' 1.png"
        let file = try await service.downloadSandboxFile(for: app, user: "0", components: ["images"], name: name, forPreview: true)
        let binary = Data([255, 0, 128])
        XCTAssertEqual(file.url.lastPathComponent, name)
        XCTAssertEqual(try Data(contentsOf: file.url), binary)

        let destination = directory.appendingPathComponent("export.png")
        try await file.export(to: destination, replacingExisting: false)
        XCTAssertEqual(try Data(contentsOf: destination), binary)
        let existing = Data("existing".utf8)
        try existing.write(to: destination)
        do {
            try await file.export(to: destination, replacingExisting: false)
            XCTFail("Export should not replace a file without approval")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), existing)
        }
        try await file.export(to: destination, replacingExisting: true)
        XCTAssertEqual(try Data(contentsOf: destination), binary)
    }

    func testHarmonyRequiresScopedSuccessAndCompleteSize() async throws {
        let device = Device(platform: .HarmonyOS, key: "fixture", name: "Fixture", state: .running)
        let appID = app.id
        let binary = Data([255, 0, 128])
        for (receipt, expectedSize, success) in [
            ("FileTransfer finish, Size:3, File count = 1", 3, true),
            ("[Fail]File unavailable", 3, false),
            ("FileTransfer finish, Size:3, File count = 1", 4, false)
        ] {
            let service = ApplicationService(device: device, connector: {
                DeviceToolConnection(path: "/fixture/hdc", target: "selected-target")
            }, execute: { _, arguments, _, _ in
                if arguments.contains("bm") { return "ID: 100:\n\(appID)\n" }
                if arguments.contains("shell") {
                    XCTAssertEqual(Array(arguments.dropLast()), ["-t", "selected-target", "shell", "-b", appID])
                    return "\(expectedSize)\r\n"
                }
                XCTAssertEqual(Array(arguments.dropLast()), ["-t", "selected-target", "file", "recv", "-b", appID,
                                                               "./data/storage/el2/base/images/icon 1.png"])
                try binary.write(to: URL(fileURLWithPath: XCTUnwrap(arguments.last)))
                return receipt
            })
            do {
                let file = try await service.downloadSandboxFile(for: app, user: "100", components: ["images"], name: "icon 1.png", forPreview: false)
                XCTAssertTrue(success)
                XCTAssertEqual(try Data(contentsOf: file.url), binary)
            } catch {
                XCTAssertFalse(success, error.localizedDescription)
            }
        }
    }
}
