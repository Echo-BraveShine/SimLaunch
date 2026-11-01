import XCTest
@testable import SimLaunchCore

private actor PropertyReader {
    var calls = 0
    func read() -> String {
        calls += 1
        return "[ro.build.version.release]: [15]\n[ro.build.version.sdk]: [35]\n[ro.product.cpu.abi]: [arm64-v8a]\n"
    }
}

final class SystemVersionTests: XCTestCase {
    func testIOSUsesReadableRuntimeAndRetainsUnavailableReason() throws {
        let devices = try Parsers.ios(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"udid":"id","name":"Phone","state":"Shutdown","isAvailable":true},{"udid":"old","name":"Old","state":"Shutdown","isAvailable":false,"availabilityError":"Missing runtime"}]}}"#)
        XCTAssertEqual(devices[0].detail, "iOS 18.5")
        XCTAssertEqual(devices[1].detail, "iOS 18.5 · Missing runtime")
        XCTAssertEqual(Parsers.iosRuntime("iOS 26"), "iOS 26")
        XCTAssertEqual(Parsers.iosRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-0-1"), "iOS 26.0.1")
    }

    func testAndroidPropertiesAndUnknownVersions() {
        let output = "[ro.build.version.release]: [17]\r\n[ro.build.version.sdk]: [37]\r\n[ro.build.version.sdk_full]: [37.1]\r\n[ro.product.cpu.abi]: [arm64-v8a]\r\n"
        XCTAssertEqual(AndroidSystemInfo.fromProperties(AndroidSystemInfo.properties(output)).detail, "Android 17 · API 37.1 · arm64")
        XCTAssertEqual(AndroidSystemInfo(api: "999", architecture: "x86_64").detail, "API 999 · x86_64")
        XCTAssertEqual(AndroidSystemInfo(api: "35", architecture: "arm64").detail, "Android 15 · API 35 · arm64")
        let encoded = AndroidSystemInfo.fromProperties(["ro.build.version.sdk_full": "3700001", "ro.build.version.sdk": "37"])
        XCTAssertEqual(encoded.api, "37")
        let local = AndroidSystemInfo(release: "17", api: "37.1", architecture: "arm64")
        XCTAssertEqual(AndroidSystemInfo(api: "37").overriding(local).detail, local.detail)
        XCTAssertEqual(AndroidSystemInfo(api: "34").overriding(local).detail, "Android 14 · API 34 · arm64")
    }

    func testStoppedAVDUsesActualImageMetadataAndInvalidatesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("custom devices/Phone.avd")
        let image = root.appendingPathComponent("sdk/system-images/android-37.1/google_apis/arm64-v8a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try "image.sysdir.1=system-images/android-37.1/google_apis/arm64-v8a/\r\nabi.type=arm64-v8a\r\ntarget=android-37.1\r\n".write(to: directory.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        try "AndroidVersion.ApiLevel=37.1\nSystemImage.Abi=arm64-v8a\n".write(to: image.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
        let build = image.appendingPathComponent("build.prop")
        try "ro.build.version.release=17\nro.build.version.sdk_full=37.1\n".write(to: build, atomically: true, encoding: .utf8)
        let cache = AndroidMetadataCache()
        let first = await cache.info(directory: directory.path, sdkRoots: [root.appendingPathComponent("sdk").path])
        XCTAssertEqual(first.detail, "Android 17 · API 37.1 · arm64")
        try "ro.build.version.release=17.1\nro.build.version.sdk_full=37.1\n".write(to: build, atomically: true, encoding: .utf8)
        let updated = await cache.info(directory: directory.path, sdkRoots: [root.appendingPathComponent("sdk").path])
        XCTAssertEqual(updated.release, "17.1")
    }

    func testAbsoluteImageAndMissingMetadataFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("AVD")
        let image = root.appendingPathComponent("external image")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config.ini")
        try "image.sysdir.1=\(image.path)\nabi.type=x86_64\ntarget=android-999\n".write(to: config, atomically: true, encoding: .utf8)
        let cache = AndroidMetadataCache()
        let missing = await cache.info(directory: directory.path, sdkRoots: [])
        XCTAssertEqual(missing.detail, "API 999 · x86_64")
        try "ro.build.version.release=FuturePreview\n".write(to: image.appendingPathComponent("build.prop"), atomically: true, encoding: .utf8)
        let discovered = await cache.info(directory: directory.path, sdkRoots: [])
        XCTAssertEqual(discovered.detail, "Android FuturePreview · API 999 · x86_64")
    }

    func testRunningVersionLookupIsCachedAndPrunedOnDisconnect() async {
        let reader = PropertyReader()
        let cache = AndroidMetadataCache()
        for _ in 0..<2 {
            let info = await cache.info(directory: nil, sdkRoots: [], runtimeKey: "adb:emulator-5554", readRuntime: { await reader.read() })
            XCTAssertEqual(info.detail, "Android 15 · API 35 · arm64")
        }
        let before = await reader.calls
        XCTAssertEqual(before, 1)
        await cache.retainRuntimeKeys([])
        _ = await cache.info(directory: nil, sdkRoots: [], runtimeKey: "adb:emulator-5554", readRuntime: { await reader.read() })
        let after = await reader.calls
        XCTAssertEqual(after, 2)
    }

    func testRuntimeFailureDoesNotFailDeviceMetadata() async {
        let cache = AndroidMetadataCache()
        let info = await cache.info(directory: nil, sdkRoots: [], runtimeKey: "adb:emulator-5554", readRuntime: { throw CLIError("offline") })
        XCTAssertEqual(info.detail, "")
    }
}
