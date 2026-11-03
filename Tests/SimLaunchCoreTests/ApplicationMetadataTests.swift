import XCTest
import CoreGraphics
import ImageIO
@testable import SimLaunchCore

final class ApplicationMetadataTests: XCTestCase {
    func testIOSSeparatesVersionAndBuildAndRejectsContradictingBundleID() throws {
        let apps = try ApplicationParsers.ios(#"{ "com.test.app" = { ApplicationType = User; CFBundleIdentifier = "com.test.app"; CFBundleVersion = "100"; }; }"#)
        XCTAssertNil(apps[0].version, "A build number must never be labeled as the version name")
        XCTAssertEqual(apps[0].build, "100")
        XCTAssertThrowsError(try ApplicationParsers.ios(#"{ "com.test.app" = { CFBundleIdentifier = "com.other.app"; }; }"#))
    }
    private func png(red: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    func testIOSUsesLocalizedNameAndDeclaredIconBeforeGenericFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "com.test.app", "CFBundleDisplayName": "Default name", "CFBundleShortVersionString": "2.0", "CFBundleVersion": "2026.11.3", "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["DeclaredIcon"]]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        for locale in ["en", "zh-Hans"] {
            let directory = root.appendingPathComponent(locale + ".lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #""CFBundleDisplayName" = "Localized name";"#.write(to: directory.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
        }
        let declared = try png(red: 1)
        try declared.write(to: root.appendingPathComponent("DeclaredIcon@2x.png"))
        try png(red: 0).write(to: root.appendingPathComponent("Icon.png"))
        let app = ApplicationService.iosMetadata(.init(id: "com.test.app", kind: .user, bundlePath: root.path))
        XCTAssertEqual(app.name, "Localized name"); XCTAssertEqual(app.version, "2.0"); XCTAssertEqual(app.build, "2026.11.3")
        XCTAssertEqual(app.icon, ApplicationService.normalizedIcon(declared))
        XCTAssertNil(ApplicationService.normalizedIcon(Data("not an icon".utf8)))
    }
    func testAndroidDumpSelectsExactPackageAndPreservesLongBuildNumber() {
        let app = InstalledApplication(id: "com.test.app")
        let text = """
        Package [com.dependency.lib] (abc):
          versionCode=3 minSdk=21
          versionName=Wrong
        Package [com.test.app] (def):
          versionCode=4294967301 minSdk=23 targetSdk=35
          versionName=2.0
          codePath=/data/app/new/base
          lastUpdateTime=2026-11-03 15:00:00
        Package [com.other.app] (ghi):
          versionName=Other
        """
        let parsed = ApplicationService.androidDump(text, app: app)
        XCTAssertEqual(parsed.version, "2.0"); XCTAssertEqual(parsed.build, "4294967301")
        XCTAssertTrue(parsed.revision!.contains("2026-11-03"))
        let (badged, _) = ApplicationService.badging("package: name='com.test.app' versionCode='5' versionName='2.0'", app: parsed)
        XCTAssertEqual(badged.build, "4294967301", "AAPT must not truncate the high bits from dumpsys")
        let (major, _) = ApplicationService.badging("package: name='com.test.app' versionCode='5' versionCodeMajor='1' versionName='2.0'", app: app)
        XCTAssertEqual(major.build, "4294967301")
        let (mismatch, icon) = ApplicationService.badging("package: name='com.other.app' versionCode='1' versionName='Wrong'\napplication-label:'Wrong'", app: app)
        XCTAssertNil(mismatch.name); XCTAssertNil(icon); XCTAssertTrue(mismatch.notes!.contains("Application identifier mismatch."))
    }
    func testAPKLiteralLabelUnescapesApostrophes() {
        let (app, _) = ApplicationService.badging(#"application: label='Bob\'s App' icon=''"#, app: .init(id: "com.test.app"))
        XCTAssertEqual(app.name, "Bob's App")
    }
    func testSameVersionNameWithChangedBuildCannotReusePresentation() {
        var previous = InstalledApplication(id: "com.test.app", name: "Old name", version: "1.0")
        previous.build = "10"; previous.icon = Data([1, 2, 3])
        var fresh = InstalledApplication(id: previous.id, version: "1.0"); fresh.build = "11"
        let merged = fresh.reusingPresentation(previous)
        XCTAssertNil(merged.icon); XCTAssertNil(merged.name); XCTAssertEqual(merged.build, "11")
    }
    func testHarmonyVersionCodeAndResourceLimitAreExplicit() throws {
        let app = try ApplicationParsers.harmonyDetails(#"com.test.app: {"name":"com.test.app","versionName":"3.2","versionCode":3201,"applicationInfo":{"isSystemApp":false,"removable":true,"label":"$string:app_name","iconId":123}}"#, app: .init(id: "com.test.app"))
        XCTAssertEqual(app.version, "3.2"); XCTAssertEqual(app.build, "3201"); XCTAssertNil(app.name)
        XCTAssertTrue(app.notes!.contains("Application label resources could not be resolved."))
    }
}
