import XCTest
import SwiftUI
import AppKit
import SimLaunchCore
@testable import SimLaunchCore
@testable import SimLaunch

@MainActor final class ApplicationManagementTests: XCTestCase {
    func testSandboxDropHighlightRendersInLightAndDarkAppearance() throws {
        func render(scheme: ColorScheme, active: Bool) throws -> NSBitmapImageRep {
            let view = Color.clear.frame(width: 80, height: 40)
                .modifier(SandboxDropHighlight(active: active, radius: 8))
                .accentColor(.blue)
                .environment(\.colorScheme, scheme)
            return NSBitmapImageRep(cgImage: try XCTUnwrap(ImageRenderer(content: view).cgImage))
        }
        let light = try render(scheme: .light, active: true)
        let dark = try render(scheme: .dark, active: true)
        let inactive = try render(scheme: .dark, active: false)
        let lightFill = try XCTUnwrap(light.colorAt(x: 40, y: 20)).alphaComponent
        let darkFill = try XCTUnwrap(dark.colorAt(x: 40, y: 20)).alphaComponent
        XCTAssertGreaterThan(lightFill, 0)
        XCTAssertGreaterThan(darkFill, lightFill)
        XCTAssertGreaterThan(try XCTUnwrap(dark.colorAt(x: 40, y: 1)).alphaComponent, darkFill)
        XCTAssertEqual(try XCTUnwrap(inactive.colorAt(x: 40, y: 20)).alphaComponent, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
    private func session(_ store: Store, device: Device) -> ApplicationManagementSession {
        ApplicationManagementSession(device: device, store: store, serviceFactory: { _ in
            ApplicationService(device: device, connector: { DeviceToolConnection(path: "/fixture", target: device.key) }, execute: { _, args, _, _ in
                if args.contains("uninstall") { throw CLIError("fixture uninstall failure") }
                return #"{ "dev.test.user" = { ApplicationType = User; CFBundleName = Test; }; }"#
            })
        })
    }
    func testDisconnectRetainsRowsAndDisablesUninstallAndReconnectionRequiresRefresh() async throws {
        let store = Store(), device = Device(platform: .iOS, key: UUID().uuidString, name: "Test", state: .running)
        store.devices = [device]
        let session = session(store, device: device)
        defer { session.close() }
        session.refresh()
        try await waitUntil { session.current && session.snapshot?.applications.count == 1 }
        let app = try XCTUnwrap(session.snapshot?.applications.first)
        XCTAssertTrue(session.canUninstall(app))
        var stopped = device; stopped.state = .stopped
        store.devices = [stopped]
        XCTAssertFalse(session.ready)
        XCTAssertFalse(session.canUninstall(app))
        XCTAssertEqual(session.snapshot?.applications.count, 1)
        store.devices = [device]
        XCTAssertTrue(session.ready)
        XCTAssertFalse(session.canUninstall(app), "Reconnect must not enable an old snapshot without refreshing")
    }
    func testDetailsRetainIdentifierAndCannotQueryAnOfflineDevice() async throws {
        let store = Store(), device = Device(platform: .iOS, key: UUID().uuidString, name: "Test", state: .running)
        store.devices = [device]
        let session = session(store, device: device)
        defer { session.close() }
        session.refresh()
        try await waitUntil { session.current && session.snapshot?.applications.count == 1 }
        let app = try XCTUnwrap(session.snapshot?.applications.first)
        let detail = try await session.details(app)
        XCTAssertEqual(detail.id, app.id)
        var stopped = device; stopped.state = .stopped; store.devices = [stopped]
        do { _ = try await session.details(app); XCTFail("Must not query offline devices") } catch {}
        XCTAssertEqual(session.snapshot?.applications.first?.id, app.id)
    }
    func testFailedUninstallKeepsTheRowAndRequiresRefresh() async throws {
        let store = Store(), device = Device(platform: .iOS, key: UUID().uuidString, name: "Test", state: .running)
        store.devices = [device]
        let session = session(store, device: device)
        defer { session.close() }
        session.refresh()
        try await waitUntil { session.current && session.snapshot?.applications.count == 1 }
        let app = try XCTUnwrap(session.snapshot?.applications.first)
        session.uninstall(app)
        try await waitUntil { session.error != nil }
        XCTAssertEqual(session.snapshot?.applications.first?.id, app.id)
        XCTAssertFalse(session.canUninstall(app))
    }
}

private actor IconQueryCounter {
    private var count = 0
    func add() { count += 1 }
    func value() -> Int { count }
}
extension ApplicationManagementTests {
    func testOffscreenIconsAreCompletedAndRetriedOnExplicitRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "dev.test.visible"
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleVersion": "1"], format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        let list = try JSONSerialization.data(withJSONObject: [id: ["ApplicationType": "User", "Path": directory.path]])
        let output = String(decoding: list, as: UTF8.self), counter = IconQueryCounter()
        let store = Store(), device = Device(platform: .iOS, key: UUID().uuidString, name: "Visible", state: .running)
        store.devices = [device]
        let session = ApplicationManagementSession(device: device, store: store, serviceFactory: { _ in
            ApplicationService(device: device, connector: { DeviceToolConnection(path: "/fixture", target: device.key) }, execute: { _, args, _, _ in
                if args.contains("spawn") { await counter.add(); return "unreadable fixture icon" }
                return output
            })
        })
        defer { session.close() }
        session.refresh()
        try await waitUntil { session.current && !session.readingDetails }
        let hiddenCount = await counter.value()
        XCTAssertEqual(hiddenCount, 1, "Background completion must not depend on SwiftUI row visibility callbacks")
        session.setVisible(id, visible: true)
        try await waitUntil { !session.readingDetails }
        let visibleCount = await counter.value()
        XCTAssertEqual(visibleCount, 1)
        session.setVisible(id, visible: false)
        session.setVisible(id, visible: true)
        let repeatedCount = await counter.value()
        XCTAssertEqual(repeatedCount, 1, "Layout changes must not repeatedly retry unreadable icons")
        session.refresh(forceIcons: true)
        try await waitUntil { session.current && !session.loading && !session.readingDetails }
        let refreshedCount = await counter.value()
        XCTAssertEqual(refreshedCount, 2)
    }
}
