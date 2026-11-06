import XCTest
import CoreGraphics
import ImageIO
@testable import SimLaunchCore

final class ApplicationIconTests: XCTestCase {
    private func image(red: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(IconRasterizer.png(context.makeImage()!))
    }
    func testNativeProtocolRejectsMissingDuplicateAndInvalidImages() throws {
        let png = try image(red: 1), encoded = png.base64EncodedString()
        let result = try RuntimeApplicationIcon.parse("diagnostic\nSIMLAUNCH_ICON:\(encoded)\nSIMLAUNCH_LABEL:\(Data("设置".utf8).base64EncodedString())\n")
        XCTAssertEqual(result.label, "设置"); XCTAssertNotNil(IconRasterizer.image(result.png))
        for text in ["", "SIMLAUNCH_ICON:bad", "SIMLAUNCH_ICON:\(encoded)\nSIMLAUNCH_ICON:\(encoded)"] { XCTAssertThrowsError(try RuntimeApplicationIcon.parse(text)) }
        XCTAssertTrue(try Data(contentsOf: ApplicationService.iconHelper("android-icon.dex")).starts(with: Data("dex\n".utf8)))
        XCTAssertGreaterThan(try Data(contentsOf: ApplicationService.iconHelper("ios-simulator-icon")).count, 10000)
    }
    func testBatchProtocolKeepsIDsAndAcceptsIndividualFailures() throws {
        let png = try image(red: 1)
        func line(_ row: [String: Any]) throws -> String { "SIMLAUNCH_RECORD:" + (try JSONSerialization.data(withJSONObject: row)).base64EncodedString() }
        let good = try line(["id": "a", "png": png.base64EncodedString(), "label": "New name"])
        let bad = try line(["id": "b", "error": "unavailable"])
        let result = try RuntimeApplicationIcon.parseBatch(good + "\n" + bad, expected: ["a", "b"])
        XCTAssertEqual(result["a"]?.label, "New name"); XCTAssertNil(result["b"])
        XCTAssertThrowsError(try RuntimeApplicationIcon.parseBatch(good, expected: ["a", "b"]))
        XCTAssertThrowsError(try RuntimeApplicationIcon.parseBatch(good + "\n" + good, expected: ["a"]))
        XCTAssertThrowsError(try RuntimeApplicationIcon.parseBatch(good, expected: ["other"]))
    }
    func testPersistentCacheRevisionAndRefreshOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try image(red: 0), updated = try image(red: 1), now = Date()
        let first = ApplicationIconCache(directory: directory)
        await first.set(old, key: "device|package|build1|update1", label: "Old", created: now)
        let second = ApplicationIconCache(directory: directory)
        let restored = await second.record("device|package|build1|update1")
        XCTAssertEqual(restored?.png, old); XCTAssertEqual(restored?.label, "Old")
        let changed = await second.get("device|package|build1|update2")
        XCTAssertNil(changed, "An update with the same build number must miss the old revision")
        await second.set(updated, key: "same", label: "New", created: now)
        await second.set(old, key: "same", label: "Old", created: now.addingTimeInterval(-1))
        let refreshed = await second.record("same")
        XCTAssertEqual(refreshed?.png, updated); XCTAssertEqual(refreshed?.label, "New")
        await second.set(old, key: "expired", created: now.addingTimeInterval(-2_592_001))
        let expired = await second.get("expired")
        XCTAssertNil(expired)
    }
    func testLateIconRequestCannotOverwriteNewerDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try image(red: 0), updated = try image(red: 1), now = Date()
        let first = ApplicationIconCache(directory: directory)
        await first.set(updated, key: "same-revision", label: "New", created: now)
        // Simulate a disk-only record, as after memory eviction or reopening the cache.
        let reopened = ApplicationIconCache(directory: directory)
        await reopened.set(old, key: "same-revision", label: "Old", created: now.addingTimeInterval(-1))
        let restored = await reopened.record("same-revision")
        XCTAssertEqual(restored?.png, updated)
        XCTAssertEqual(restored?.label, "New")
    }
    func testIOSIconResourceChangeInvalidatesSameBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = ["CFBundleIdentifier": "dev.test.icon", "CFBundleVersion": "1", "CFBundleIconFile": "Icon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        let url = directory.appendingPathComponent("Icon.png")
        try image(red: 0).write(to: url)
        var app = InstalledApplication(id: "dev.test.icon")
        app.bundlePath = directory.path
        let first = ApplicationService.iosMetadata(app)
        XCTAssertNotNil(first.icon)
        try image(red: 1).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let updated = ApplicationService.iosMetadata(first, loadIcon: false)
        XCTAssertEqual(updated.build, first.build); XCTAssertNotEqual(updated.revision, first.revision)
        XCTAssertNil(updated.icon)
    }
    func testAndroidBatchFailureFallsBackToIndividualNativeReader() async throws {
        let png = try image(red: 1), id = "dev.test.recovery"
        let device = Device(platform: .Android, key: "fixture", name: "Test", state: .running)
        let connection = DeviceToolConnection(path: "/fixture", target: "serial")
        let service = ApplicationService(device: device, connector: { connection }, execute: { _, args, _, _ in
            if args.contains("--batch") { throw CLIError("batch unsupported") }
            if args.contains("dumpsys") { return "Package [\(id)] (a):\n  versionCode=1\n  lastUpdateTime=2026-11-03\n  codePath=/data/app/test" }
            if args.contains("app_process") { return "SIMLAUNCH_ICON:" + png.base64EncodedString() + "\nSIMLAUNCH_LABEL:" + Data("Recovered".utf8).base64EncodedString() }
            return ""
        })
        let app = InstalledApplication(id: id)
        let result = await service.icons([app], snapshot: .init(applications: [app], user: "0"), connection: connection, force: true)
        XCTAssertNotNil(result.first?.icon); XCTAssertEqual(result.first?.name, "Recovered")
    }
    func testHarmonyHAPRejectsWrongBundleVersionAndModule() throws {
        var app = InstalledApplication(id: "dev.test.app", version: "1.0"); app.build = "1"
        func module(_ id: String, _ build: Int, _ name: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["app": ["bundleName": id, "versionName": "1.0", "versionCode": build], "module": ["name": name]])
        }
        XCTAssertTrue(ApplicationService.matchingHarmonyModule(try module(app.id, 1, "entry"), app: app, module: "entry"))
        XCTAssertFalse(ApplicationService.matchingHarmonyModule(try module("other.app", 1, "entry"), app: app, module: "entry"))
        XCTAssertFalse(ApplicationService.matchingHarmonyModule(try module(app.id, 2, "entry"), app: app, module: "entry"))
        XCTAssertFalse(ApplicationService.matchingHarmonyModule(try module(app.id, 1, "other"), app: app, module: "entry"))
    }
    func testHarmonyResourceIDsNamesModuleAndTraversal() throws {
        let json = #"{"bundleName":"com.test.app","moduleName":"phone","resource":[{"id":100,"name":"icon","type":"media","entryValues":[{"value":"phone/resources/base/media/icon.json"}]},{"id":101,"name":"bad","type":"media","entryValues":[{"value":"../secret.png"}]}]}"#
        let table = try HarmonyIconResourceTable(json, bundle: "com.test.app", module: "phone")
        XCTAssertEqual(table.path(reference: "$media:100"), "resources/base/media/icon.json")
        XCTAssertEqual(table.path(reference: "$media:icon"), table.path(reference: "100"))
        XCTAssertNil(table.path(reference: "101")); XCTAssertNil(table.path(reference: "missing"))
        XCTAssertThrowsError(try HarmonyIconResourceTable(json, bundle: "wrong.app", module: "phone"))
        XCTAssertThrowsError(try HarmonyIconResourceTable(json, bundle: "com.test.app", module: "wrong"))
    }
    func testLayeredImagesAreCompositedAndNormalized() throws {
        let back = try image(red: 0), front = try image(red: 1)
        let combined = try XCTUnwrap(IconRasterizer.composite(background: back, foreground: front))
        let cg = try XCTUnwrap(IconRasterizer.image(combined))
        XCTAssertEqual(cg.width, 128); XCTAssertEqual(cg.height, 128)
        XCTAssertNotEqual(combined, IconRasterizer.normalized(back))
    }
    @MainActor func testSVGAndExternalResources() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" fill="#ff0000"/></svg>"##.utf8)
        XCTAssertNotNil(IconRasterizer.normalized(svg))
        let external = Data(##"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/icon.png"/></svg>"##.utf8)
        XCTAssertNil(IconRasterizer.normalized(external))
    }
    private func ext4Fixture() -> Data {
        var bytes = Data(count: 65536)
        func u16(_ offset: Int, _ value: UInt16) { bytes[offset] = UInt8(value & 255); bytes[offset + 1] = UInt8(value >> 8) }
        func u32(_ offset: Int, _ value: UInt32) { u16(offset, UInt16(value & 65535)); u16(offset + 2, UInt16(value >> 16)) }
        u32(1024, 64); u16(1024 + 56, 0xEF53); u32(1024 + 24, 2); u32(1024 + 40, 64); u16(1024 + 88, 256); u32(1024 + 96, 0xC0); u16(1024 + 254, 64)
        u32(4096 + 8, 2)
        func inode(_ n: Int, mode: UInt16, size: UInt32, block: UInt32) {
            let p = 8192 + (n - 1) * 256
            u16(p, mode); u32(p + 4, size); u32(p + 32, 0x80000)
            u16(p + 40, 0xF30A); u16(p + 42, 1); u16(p + 44, 4); u16(p + 56, 1); u32(p + 60, block)
        }
        inode(2, mode: 0x41ED, size: 4096, block: 6); inode(3, mode: 0x81A4, size: 4, block: 7)
        func entry(_ offset: Int, inode: UInt32, length: UInt16, name: String, type: UInt8) {
            u32(offset, inode); u16(offset + 4, length); bytes[offset + 6] = UInt8(name.utf8.count); bytes[offset + 7] = type
            bytes.replaceSubrange((offset + 8)..<(offset + 8 + name.utf8.count), with: name.utf8)
        }
        entry(24576, inode: 2, length: 12, name: ".", type: 2); entry(24588, inode: 2, length: 12, name: "..", type: 2)
        entry(24600, inode: 3, length: 4072, name: "icon.hap", type: 1)
        bytes.replaceSubrange(28672..<28676, with: Data([1,2,3,4]))
        return bytes
    }
    func testReadOnlyExt4LookupLimitsAndCorruptExtents() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let original = ext4Fixture(); try original.write(to: path)
        let reader = try Ext4ImageReader(url: path)
        XCTAssertEqual(try reader.file(at: "/icon.hap"), Data([1,2,3,4]))
        XCTAssertThrowsError(try reader.file(at: "/icon.hap", limit: 3))
        XCTAssertThrowsError(try reader.file(at: "/../icon.hap"))
        XCTAssertThrowsError(try reader.file(at: "/missing"))
        XCTAssertEqual(try Data(contentsOf: path), original, "Reading must never modify the SDK image")
        var corrupt = original; let block = 8192 + 2 * 256 + 60
        corrupt[block] = 255; corrupt[block + 1] = 255; try corrupt.write(to: path)
        XCTAssertThrowsError(try Ext4ImageReader(url: path).file(at: "/icon.hap"))
    }
}

final class ApplicationIconLiveTests: XCTestCase {
    func testInstalledAndroidUserApplicationIcons() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_USER_ICONS"] == "1" else { throw XCTSkip("Opt in with running Android user applications") }
        let provider = AndroidProvider(Configuration(), launches: LaunchManager())
        let devices = try await provider.list(), device = try XCTUnwrap(devices.first { $0.state == .running })
        let service = ApplicationService(device: device, configuration: Configuration()), snapshot = try await service.list()
        let connection = try await service.metadataConnection()
        let users = Array(snapshot.applications.filter { $0.kind == .user }.prefix(8))
        XCTAssertFalse(users.isEmpty)
        var basic: [InstalledApplication] = []
        for app in users { basic.append(try await service.metadata(app, snapshot: snapshot, connection: connection, loadIcon: false, bypassIconCache: true)) }
        let rendered = await service.icons(basic, snapshot: snapshot, connection: connection, force: true)
        for app in rendered {
            XCTAssertNotNil(app.icon, "Missing user icon: " + app.id + " " + (app.notes ?? []).joined(separator: ";"))
            print("User icon: " + app.id + ", bytes=" + String(app.icon?.count ?? 0))
        }
    }
    func testAndroidBatchPreservesIndividualNativeIcons() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_ICON_BATCH"] == "1" else { throw XCTSkip("Opt in with a running Android simulator") }
        let config = Configuration(), provider = AndroidProvider(Configuration(), launches: LaunchManager())
        let devices = try await provider.list()
        let device = try XCTUnwrap(devices.first { $0.state == .running })
        let service = ApplicationService(device: device, configuration: config), snapshot = try await service.list()
        let connection = try await service.metadataConnection(), user = try XCTUnwrap(snapshot.user)
        let apps = Array(snapshot.applications.prefix(16))
        var successes = 0
        for offset in stride(from: 0, to: apps.count, by: 8) {
            let chunk = Array(apps[offset..<min(offset + 8, apps.count)])
            let batch = try await service.androidRuntimeIcons(chunk, user: user, connection: connection)
            for app in chunk {
                if let _ = try? await service.androidRuntimeIcon(app, user: user, connection: connection) {
                    successes += 1
                    XCTAssertNotNil(batch[app.id], "Batch lost an individually readable icon: " + app.id)
                }
            }
        }
        XCTAssertGreaterThan(successes, 0)
        print("Android batch comparison: \(apps.count) packages, \(successes) individually readable icons retained")
    }
    func testThreePlatformsReadOnlyIcons() async throws {
        guard ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APP_ICONS"] == "1" else { throw XCTSkip("Opt in with running simulators") }
        let config = Configuration()
        let providers: [(String, any DeviceProvider, String)] = [("iOS", IOSProvider(config), "com.apple.Preferences"), ("Android", AndroidProvider(config, launches: LaunchManager()), "com.android.settings"), ("HarmonyOS", HarmonyProvider(config, launches: LaunchManager()), "com.huawei.hmos.filemanager")]
        var checked = 0
        for (name, provider, id) in providers {
            if let only = ProcessInfo.processInfo.environment["SIMLAUNCH_TEST_APP_ICON_PLATFORM"], only != name { continue }
            let devices = try await provider.list(), device = try XCTUnwrap(devices.first { $0.state == .running })
            let service = ApplicationService(device: device, configuration: config), snapshot = try await service.list()
            let app = try XCTUnwrap(snapshot.applications.first { $0.id == id })
            let c = try await service.metadataConnection()
            let basic = try await service.metadata(app, snapshot: snapshot, connection: c, loadIcon: false, bypassIconCache: true)
            let split = await service.icons([basic], snapshot: snapshot, connection: c, force: true)
            XCTAssertNotNil(split.first?.icon, "List pipeline failed for " + name + ": " + (split.first?.notes ?? []).joined(separator: "; "))
            var detail = try await service.details(app, snapshot: snapshot)
            if name == "iOS" {
                detail.icon = nil
                let connection = try await service.metadataConnection()
                detail = await service.iosRuntimeIcon(detail, connection: connection)
                XCTAssertEqual(detail.extra?["Icon source"], "Simulator UIKit")
            }
            XCTAssertNotNil(detail.icon, "\(name): \(detail.notes ?? [])")
            if let icon = detail.icon { try icon.write(to: URL(fileURLWithPath: "/tmp/simlaunch-verified-icon-\(name).png")) }
            print("Icon verified: \(name), source=\(detail.extra?["Icon source"] ?? "unknown"), bytes=\(detail.icon?.count ?? 0)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
