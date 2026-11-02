import AppKit
import SwiftUI
import XCTest
import SimLaunchCore
@testable import SimLaunch

@MainActor final class LogScrollingTests: XCTestCase {
    final class FollowValue { var value = true }
    func entries(_ range: Range<Int>, wrapped: Bool = false) -> [DeviceLogEntry] {
        range.map { DeviceLogParser.parse("row \($0) " + (wrapped ? String(repeating: "long text ", count: 25) : "message"), platform: .Android, id: UInt64($0)) }
    }
    func view(_ entries: [DeviceLogEntry], value: FollowValue, wrap: Bool = false) -> LogTextView {
        LogTextView(entries: entries, filterID: "all", wrap: wrap, follow: Binding(get: { value.value }, set: { value.value = $0 }))
    }
    func layout(_ scroll: NSScrollView) {
        let text = scroll.documentView as! NSTextView
        scroll.tile()
        text.layoutManager?.ensureLayout(for: text.textContainer!)
    }
    func userScroll(_ scroll: NSScrollView, y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }
    func testScrollUpPausesImmediatelyAndBottomResumes() async {
        let value = FollowValue(), coordinator = LogTextView.Coordinator()
        var content = view(entries(1..<301), value: value)
        let scroll = content.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        userScroll(scroll, y: 300)
        XCTAssertEqual(coordinator.pendingFollow, false)
        // Render a new batch before the deferred SwiftUI binding write runs.
        content = view(entries(1..<351), value: value)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        XCTAssertFalse(coordinator.wasFollowing)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 300, accuracy: 1)
        await Task.yield()
        let text = scroll.documentView as! NSTextView
        text.scrollToEndOfDocument(nil)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(coordinator.pendingFollow, true)
        content = view(entries(1..<401), value: value)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        XCTAssertTrue(coordinator.wasFollowing)
        XCTAssertLessThanOrEqual(text.frame.height - scroll.contentView.bounds.maxY, 1)
    }
    func testProgrammaticAppendDoesNotDisableFollow() async {
        let value = FollowValue(), coordinator = LogTextView.Coordinator()
        var content = view(entries(1..<301), value: value)
        let scroll = content.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        content.render(scroll, coordinator: coordinator)
        for count in [400, 500, 600] {
            content = view(entries(1..<count), value: value)
            content.render(scroll, coordinator: coordinator); layout(scroll)
            XCTAssertTrue(coordinator.wasFollowing)
            XCTAssertNil(coordinator.pendingFollow)
        }
    }
    func testTrimmingOldLinesKeepsVisibleTextAnchored() async {
        for wrap in [false, true] {
            let value = FollowValue(), coordinator = LogTextView.Coordinator()
            var content = view(entries(1..<301, wrapped: wrap), value: value, wrap: wrap)
            let scroll = content.makeScrollView(coordinator: coordinator)
            scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            content.render(scroll, coordinator: coordinator); layout(scroll)
            userScroll(scroll, y: 2000)
            let text = scroll.documentView as! NSTextView
            let before = LogTextView.Coordinator.captureAnchor(text, origin: scroll.contentView.bounds.origin)!
            let oldText = text.string as NSString
            let oldVisible = oldText.substring(from: before.character).prefix(40)
            content = view(entries(11..<311, wrapped: wrap), value: value, wrap: wrap)
            content.render(scroll, coordinator: coordinator); layout(scroll)
            let after = LogTextView.Coordinator.captureAnchor(text, origin: scroll.contentView.bounds.origin)!
            XCTAssertEqual((text.string as NSString).substring(from: after.character).prefix(40), oldVisible)
            XCTAssertEqual(after.offset, before.offset, accuracy: 1)
            XCTAssertFalse(coordinator.wasFollowing)
        }
    }
    func testViewportAboveBottomPausesEvenWithoutLiveScrollNotification() async {
        let value = FollowValue(), coordinator = LogTextView.Coordinator()
        var content = view(entries(1..<301), value: value)
        let scroll = content.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        // Keyboard/scrollbar/accessibility scrolling can move the viewport
        // without delivering a gesture notification to the representable.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        content = view(entries(1..<401), value: value)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        XCTAssertFalse(coordinator.wasFollowing)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 300, accuracy: 1)
        // Returning to the bottom without a gesture notification also resumes.
        (scroll.documentView as! NSTextView).scrollToEndOfDocument(nil)
        content = view(entries(1..<501), value: value)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        XCTAssertTrue(coordinator.wasFollowing)
        XCTAssertEqual(coordinator.ids.count, 500)
    }
    func testPausedTextDoesNotChangeWhenEntireLiveBufferIsReplaced() async {
        let value = FollowValue(), coordinator = LogTextView.Coordinator()
        var content = view(entries(1..<301), value: value)
        let scroll = content.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        userScroll(scroll, y: 300)
        let text = scroll.documentView as! NSTextView
        let frozen = text.string
        for start in [1000, 2000, 3000] {
            content = view(entries(start..<(start + 300)), value: value)
            content.render(scroll, coordinator: coordinator); layout(scroll)
            await Task.yield()
            XCTAssertEqual(text.string, frozen)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 300, accuracy: 1)
        }
        text.scrollToEndOfDocument(nil)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        XCTAssertTrue(text.string.contains("row 3000 "))
        XCTAssertTrue(coordinator.wasFollowing)
    }
    func testDisplayedSnapshotTracksContentAndStaysFrozenForCopyAndExport() async throws {
        let value = FollowValue(), coordinator = LogTextView.Coordinator()
        var displayed: [DeviceLogEntry] = []
        var content = view(entries(1..<301), value: value)
        content.displayedEntriesChanged = { displayed = $0 }
        let scroll = content.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(displayed.first?.id, 1)
        userScroll(scroll, y: 300)
        content = view(entries(1000..<1300), value: value)
        content.displayedEntriesChanged = { displayed = $0 }
        content.render(scroll, coordinator: coordinator)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(displayed.first?.id, 1, "Copy/export must keep the visible historical snapshot")
        (scroll.documentView as! NSTextView).scrollToEndOfDocument(nil)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(displayed.first?.id, 1000, "A same-sized replacement must update the export snapshot after resume")
    }
    func testHorizontalScrollWhileAboveBottomDoesNotResumeFollowing() async {
        let value = FollowValue(), coordinator = LogTextView.Coordinator()
        let content = view(entries(1..<301), value: value)
        let scroll = content.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        content.render(scroll, coordinator: coordinator); layout(scroll)
        userScroll(scroll, y: 100)
        scroll.contentView.scroll(to: NSPoint(x: 20, y: 100))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(coordinator.pendingFollow, false)
    }
}
