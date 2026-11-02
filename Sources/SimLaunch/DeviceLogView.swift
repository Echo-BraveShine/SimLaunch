import SwiftUI
import AppKit
import SimLaunchCore

struct DeviceLogView: View {
    @ObservedObject var session: LogSession
    @AppStorage("appLanguage") private var language = "system"
    @State private var showFilters = false
    @State private var displayedEntries: [DeviceLogEntry] = []
    @State private var displayedFilter = DeviceLogFilter()
    private var displayedCount: Int { displayedEntries.count }
    private var statusColor: Color {
        switch session.state { case .capturing: return .green; case .connecting, .stopping: return .orange; case .disconnected: return .red; default: return .secondary }
    }
    var body: some View {
        let currentFilter = session.filter
        let hasDisplayedLogs = displayedEntries.contains { !$0.isMarker }
        let hasRetainedLogs = session.entries.contains { !$0.isMarker }
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                PlatformIcon(platform: session.device.platform, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.device.name).font(.title3.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(session.state.title)
                        Text("· " + session.device.platform.rawValue).foregroundStyle(.secondary)
                    }.font(.caption)
                }
                Spacer()
                if displayedCount > 0 {
                    if session.follow {
                        Label(L10n.text("Following latest"), systemImage: "arrow.down.to.line").foregroundStyle(.secondary).font(.callout)
                    } else {
                        Button { session.follow = true } label: {
                            Label(L10n.text("Back to latest"), systemImage: "arrow.down.to.line")
                        }.help(L10n.text("Scrolling up pauses automatic scrolling; collection continues."))
                    }
                }
                Button {
                    if session.state.active { session.stop() } else { session.start() }
                } label: {
                    Label(session.state.actionTitle, systemImage: session.state.active ? "stop.fill" : "play.fill")
                }.disabled(session.state == .stopping || (!session.state.active && !session.deviceReady))
                .help(L10n.text(session.deviceReady || session.state.active ? "Control log collection without stopping the simulator." : "Start the simulator and wait until it is connected before collecting logs."))
            }.padding(14).modifier(AdaptiveGlass(radius: 14))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.text("Search retained logs"), text: $session.filter.keyword)
                            .textFieldStyle(.plain).accessibilityLabel(L10n.text("Log search"))
                        if !session.filter.keyword.isEmpty {
                            Button { session.filter.keyword = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).help(L10n.text("Clear search"))
                        }
                    }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    Button { showFilters.toggle() } label: {
                        Label(L10n.text("Filters"), systemImage: "line.3.horizontal.decrease.circle")
                    }.help(L10n.text("Filter retained logs by level and process."))
                    Menu {
                        Toggle(L10n.text("Ignore case"), isOn: $session.filter.ignoreCase)
                        Toggle(L10n.text("Wrap lines"), isOn: $session.wrap)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        .help(L10n.text("Log display options"))
                    Divider().frame(height: 20)
                    Button { session.clear() } label: { Image(systemName: "trash") }
                        .help(L10n.text("Clear panel only; device logs are unchanged."))
                        .accessibilityLabel(L10n.text("Clear panel"))
                        .disabled(session.entries.isEmpty && displayedEntries.isEmpty)
                    Menu {
                        Button(L10n.text("Copy displayed logs")) { session.copyDisplayed(displayedEntries) }.disabled(!hasDisplayedLogs)
                        Button(L10n.text("Export displayed logs…")) { session.export(displayed: displayedEntries, filter: displayedFilter) }.disabled(!hasDisplayedLogs)
                        Button(L10n.text("Export all retained logs…")) { session.export() }.disabled(!hasRetainedLogs)
                    } label: { Label(L10n.text("Export"), systemImage: "square.and.arrow.up") }
                        .fixedSize().disabled(!hasDisplayedLogs && !hasRetainedLogs)
                }
                if showFilters {
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(LogLevel.allCases, id: \.self) { level in
                                Toggle(level.title, isOn: Binding(get: { session.filter.levels.contains(level) }, set: { value in
                                    if value { session.filter.levels.insert(level) } else { session.filter.levels.remove(level) }
                                }))
                            }
                        } label: { Label(L10n.text("Log levels"), systemImage: "line.3.horizontal.decrease") }.fixedSize()
                        TextField("PID", text: $session.filter.pid).frame(width: 100)
                            .accessibilityLabel(L10n.text("Exact process ID"))
                            .disabled(!session.entries.contains { $0.pid != nil })
                            .help(L10n.text("Only matches a parsed PID. A restarted process may have a different PID."))
                        if session.device.platform == .iOS {
                            TextField(L10n.text("Process name"), text: $session.filter.process).frame(maxWidth: 240)
                                .accessibilityLabel(L10n.text("Process name"))
                                .disabled(!session.entries.contains { $0.process != nil })
                                .help(L10n.text("Only matches process names present in the source. Use keyword search for tags or package names."))
                        }
                        Spacer()
                        Button(L10n.text("Reset filters")) { session.resetFilter() }.buttonStyle(.link)
                            .disabled(session.filter == DeviceLogFilter())
                    }.textFieldStyle(.roundedBorder)
                }
            }.padding(12).modifier(AdaptiveCard(radius: 12))

            if !session.diagnostic.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: session.state == .disconnected ? "exclamationmark.triangle" : "info.circle")
                    Text(session.diagnostic).textSelection(.enabled).lineLimit(3)
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .help(session.diagnostic)
            }

            ZStack {
                LogTextView(entries: session.visible, filterID: session.filter.summary + "|" + String(session.clearRevision), wrap: session.wrap, follow: $session.follow, displayedEntriesChanged: { displayedEntries = $0; displayedFilter = currentFilter })
                if displayedCount == 0 {
                    VStack(spacing: 10) {
                        Image(systemName: "text.alignleft").font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
                        Text(L10n.text(session.entries.allSatisfy(\.isMarker) ? "Device logs appear here" : "No matching logs"))
                            .font(.headline).foregroundStyle(.secondary)
                        Text(L10n.text(session.entries.allSatisfy(\.isMarker) ? "Start collection on a running simulator. No IDE is needed." : "Change or reset the filters to see retained logs."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false).padding()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))

            HStack(spacing: 12) {
                Text(L10n.format("%d shown · %d retained", displayedCount, session.entries.count))
                if session.dropped > 0 { Text(L10n.format("%d earlier lines discarded", session.dropped)) }
                if session.truncated > 0 { Text(L10n.format("%d long lines truncated", session.truncated)) }
                Spacer()
                Text(L10n.text("Local collection · Up to 10,000 lines / 10 MiB"))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(minWidth: 800, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(AppAppearanceModifier())
        .environment(\.locale, Locale(identifier: language == "system" ? L10n.language : language))
        .alert(L10n.text("操作失败"), isPresented: Binding(get: { session.exportError != nil }, set: { if !$0 { session.exportError = nil } })) {
            Button(L10n.text("好")) { session.exportError = nil }
        } message: { Text(session.exportError ?? "") }
    }
}

/// Native selectable text with incremental append/trim rather than rebuilding thousands
/// of SwiftUI rows on every batch. Scrolling and copy shortcuts keep normal macOS behavior.
struct LogTextView: NSViewRepresentable {
    let entries: [DeviceLogEntry]
    let filterID: String
    let wrap: Bool
    @Binding var follow: Bool
    var displayedEntriesChanged: (([DeviceLogEntry]) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { makeScrollView(coordinator: context.coordinator) }
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        // TextKit 1 avoids TextKit 2's paragraph-fragment invalidation cost when
        // the rolling buffer trims thousands of paragraphs during logcat bursts.
        let scroll = NSScrollView()
        let text = NSTextView(usingTextLayoutManager: false)
        text.isVerticallyResizable = true
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = text
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor
        text.setAccessibilityLabel(L10n.text("Device log output"))
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak coordinator, weak scroll] _ in
            guard let coordinator, let scroll, !coordinator.updating else { return }
            let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
            // Track both directions. Only user scrolling changes follow mode;
            // appends, layout and our own scroll-to-bottom must not change it.
            coordinator.pendingFollow = bottom <= 1
            coordinator.setFollowing?(bottom <= 1)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        render(scroll, coordinator: context.coordinator)
    }
    func render(_ scroll: NSScrollView, coordinator c: Coordinator) {
        c.setFollowing = { [weak c] value in
            guard let c else { return }
            c.scrollRevision &+= 1
            let revision = c.scrollRevision
            DispatchQueue.main.async { [weak c] in
                guard let c, c.scrollRevision == revision else { return }
                if follow != value { follow = value }
            }
        }
        // A user scroll takes effect immediately, even before SwiftUI consumes
        // the deferred binding update or another log batch reaches this view.
        if c.pendingFollow == follow { c.pendingFollow = nil }
        var shouldFollow = c.pendingFollow ?? follow
        let text = scroll.documentView as! NSTextView
        text.setAccessibilityLabel(L10n.text("Device log output"))
        // The viewport is authoritative, including keyboard, scrollbar and
        // accessibility scrolling that may not produce a live-scroll notification.
        if !c.ids.isEmpty {
            let atBottom = text.frame.height - scroll.contentView.bounds.maxY <= 1
            if shouldFollow && c.wasFollowing && !atBottom {
                shouldFollow = false
                c.pendingFollow = false
                c.setFollowing?(false)
            } else if !shouldFollow && !c.wasFollowing && atBottom {
                shouldFollow = true
                c.pendingFollow = true
                c.setFollowing?(true)
            }
        }
        c.updating = true; defer { c.updating = false }
        let appearance = text.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let style = filterID + "|" + appearance + "|" + String(wrap)
        if !shouldFollow, c.style == style, !c.ids.isEmpty {
            // Do not mutate NSTextStorage while reading history. Even restoring
            // the clip origin cannot prevent later AppKit layout/selection
            // adjustments, and the live ring buffer can evict every visible row.
            // The existing (bounded) rendered text stays until resume/filter/clear.
            c.wasFollowing = false
            return
        }
        let originalOrigin = scroll.contentView.bounds.origin
        let originalSelection = text.selectedRange()
        let oldFollow = c.wasFollowing
        let changed = c.ids != entries.map(\.id) || c.style != style
        let anchor = !shouldFollow && changed ? Coordinator.captureAnchor(text, origin: originalOrigin) : nil
        if changed, let storage = text.textStorage {
            text.isHorizontallyResizable = !wrap
            text.autoresizingMask = wrap ? [.width] : []
            text.textContainer?.widthTracksTextView = wrap
            text.textContainer?.containerSize = NSSize(width: wrap ? max(1, scroll.contentSize.width - 24) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if wrap { text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height)) }
            storage.beginEditing()
            var start = 0, removedCharacters = 0
            var retainedPrefix = false
            if c.style == style, let last = c.ids.last, let lastIndex = entries.firstIndex(where: { $0.id == last }),
               let first = entries.first?.id, let oldFirstIndex = c.ids.firstIndex(of: first) {
                retainedPrefix = true
                removedCharacters = c.lengths.prefix(oldFirstIndex).reduce(0, +)
                if removedCharacters > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: min(removedCharacters, storage.length))) }
                start = lastIndex + 1
                c.ids.removeFirst(oldFirstIndex); c.lengths.removeFirst(oldFirstIndex)
            } else {
                storage.setAttributedString(NSAttributedString(string: "")); c.ids = []; c.lengths = []
            }
            let appended = NSMutableAttributedString(string: "")
            for entry in entries.dropFirst(start) {
                let line = entry.raw + "\n"
                let color: NSColor
                if entry.isMarker { color = .secondaryLabelColor }
                else { switch entry.level { case .error, .fault: color = .systemRed; case .warning: color = .systemOrange; default: color = .labelColor } }
                appended.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: color]))
                c.ids.append(entry.id); c.lengths.append((line as NSString).length)
            }
            storage.append(appended)
            storage.endEditing(); c.style = style
            if !shouldFollow {
                let location = min(max(0, originalSelection.location - removedCharacters), storage.length)
                text.setSelectedRange(NSRange(location: location, length: min(originalSelection.length, storage.length - location)))
                var origin = originalOrigin
                if removedCharacters > 0, let anchor, retainedPrefix {
                    // Keep the same line and pixel offset on screen when the
                    // bounded buffer removes text above the viewport.
                    origin.y = Coordinator.restoredY(text, anchor: anchor, removed: removedCharacters)
                } else if !retainedPrefix { origin.y = 0 }
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentSize)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if changed, let layout = text.layoutManager, let container = text.textContainer {
            // Resolve geometry before scrolling, rather than letting deferred
            // text layout move the bottom after our viewport check next time.
            layout.ensureLayout(for: container)
            let height = max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)
            text.setFrameSize(NSSize(width: text.frame.width, height: height))
        }
        if shouldFollow && (changed || !oldFollow) { text.scrollToEndOfDocument(nil) }
        if changed {
            let snapshot = entries
            DispatchQueue.main.async { displayedEntriesChanged?(snapshot) }
        }
        c.wasFollowing = shouldFollow
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.setFollowing = nil
    }
    final class Coordinator {
        var ids: [UInt64] = []
        var lengths: [Int] = []
        var style = ""
        var updating = false
        var wasFollowing = true
        var setFollowing: ((Bool) -> Void)?
        var observer: NSObjectProtocol?
        var pendingFollow: Bool?
        var scrollRevision: UInt64 = 0
        var displayedCount = -1
        struct Anchor { let character: Int; let offset: CGFloat }
        static func captureAnchor(_ text: NSTextView, origin: NSPoint) -> Anchor? {
            guard let layout = text.layoutManager, let container = text.textContainer, layout.numberOfGlyphs > 0 else { return nil }
            let point = NSPoint(x: 0, y: max(0, origin.y - text.textContainerInset.height))
            let glyph = layout.glyphIndex(for: point, in: container)
            guard glyph < layout.numberOfGlyphs else { return nil }
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return Anchor(character: layout.characterIndexForGlyph(at: glyph), offset: origin.y - rect.minY - text.textContainerInset.height)
        }
        static func restoredY(_ text: NSTextView, anchor: Anchor, removed: Int) -> CGFloat {
            guard anchor.character >= removed, let layout = text.layoutManager, text.textContainer != nil, !text.string.isEmpty else { return 0 }
            let character = min(anchor.character - removed, (text.string as NSString).length - 1)
            // Layout through the anchor gives stable coordinates for wrapped rows.
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: character + 1))
            let glyph = layout.glyphIndexForCharacter(at: character)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return max(0, rect.minY + text.textContainerInset.height + anchor.offset)
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
