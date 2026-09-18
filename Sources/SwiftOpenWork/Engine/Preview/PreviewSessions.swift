import Foundation
import Combine

/// The preview's tabs, and how many are on screen at once.
///
/// One preview was not enough in practice: a frontend and its admin app, the same page at phone and
/// desktop widths, or the page before and after a change. Each tab is its own `PreviewController` —
/// its own web view, history, console and viewport — so looking at one never reloads another.
@MainActor
public final class PreviewSessions: ObservableObject {

    public static let shared = PreviewSessions()

    public enum Layout: String, CaseIterable, Identifiable {
        case single = "One at a Time"
        case sideBySide = "Side by Side"
        case stacked = "Stacked"
        public var id: String { rawValue }
    }

    @Published public private(set) var tabs: [PreviewController] = []
    /// The tab the toolbar, console and agent tools act on.
    @Published public var activeId: UUID?
    /// The second tab shown in a split layout.
    @Published public var secondaryId: UUID?
    @Published public var layout: Layout = .single

    /// Tab count ceiling. Every tab is a WebKit content process.
    public static let maxTabs = 6

    private var forwarders: [UUID: AnyCancellable] = [:]

    /// There is always at least one tab, so reading `active` never has to create one — creating it
    /// during a SwiftUI render would publish a change mid-update.
    public init() {
        let first = PreviewController()
        tabs = [first]
        activeId = first.id
        forwarders[first.id] = first.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The active tab, created on first use so callers always have somewhere to load a page.
    public var active: PreviewController {
        if let found = tabs.first(where: { $0.id == activeId }) { return found }
        if let first = tabs.first {
            activeId = first.id
            return first
        }
        return newTab()
    }

    /// The tab shown beside the active one, when the layout shows two.
    public var secondary: PreviewController? {
        guard layout != .single, tabs.count > 1 else { return nil }
        if let found = tabs.first(where: { $0.id == secondaryId && $0.id != activeId }) { return found }
        return tabs.first { $0.id != activeId }
    }

    @discardableResult
    public func newTab(workspaceRoot: String? = nil, activate: Bool = true) -> PreviewController {
        if tabs.count >= Self.maxTabs, let oldest = tabs.first(where: { $0.id != activeId && $0.id != secondaryId }) {
            close(oldest.id)
        }
        let tab = PreviewController()
        tab.workspaceRoot = workspaceRoot ?? tabs.last?.workspaceRoot
        tabs.append(tab)
        // A tab's title and URL are shown in the strip, so its changes are the strip's changes.
        forwarders[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if activate {
            if let current = activeId, layout != .single { secondaryId = current }
            activeId = tab.id
        }
        return tab
    }

    /// A new tab on the same page — the usual way to compare widths.
    @discardableResult
    public func duplicate(_ id: UUID) -> PreviewController? {
        guard let source = tabs.first(where: { $0.id == id }) else { return nil }
        let copy = newTab(workspaceRoot: source.workspaceRoot)
        copy.serverId = source.serverId
        copy.reloadOnSave = source.reloadOnSave
        if let url = source.currentURL { copy.load(url) }
        return copy
    }

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        forwarders[id] = nil
        tab.tearDown()
        if tabs.isEmpty {
            // Closing the last tab leaves an empty one, never none.
            let replacement = PreviewController()
            replacement.workspaceRoot = tab.workspaceRoot
            tabs = [replacement]
            forwarders[replacement.id] = replacement.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            activeId = replacement.id
            secondaryId = nil
            return
        }
        if activeId == id {
            activeId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if secondaryId == id || secondaryId == activeId {
            secondaryId = tabs.first { $0.id != activeId }?.id
        }
    }

    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if layout != .single, id == secondaryId { secondaryId = activeId }
        activeId = id
    }

    /// The tab a new preview of `server` should load into: one already showing it, else the active
    /// tab if it is empty or showing nothing live, else a new tab — so starting a second server
    /// never replaces the page of the first.
    public func tab(forServer server: DevServer, workspaceRoot: String) -> PreviewController {
        if let showing = tabs.first(where: { $0.serverId == server.id }) {
            activate(showing.id)
            return showing
        }
        let current = active
        let currentServerIsLive = current.serverId.flatMap { id in
            DevServerManager.shared.servers.first { $0.id == id }
        }?.status.isLive ?? false
        if current.currentURL == nil || !currentServerIsLive {
            current.workspaceRoot = workspaceRoot
            return current
        }
        return newTab(workspaceRoot: workspaceRoot)
    }

    /// Resolve a tab named by the agent: a 1-based number, or text found in its title or URL.
    public func find(_ reference: String?) -> PreviewController? {
        guard let reference = reference?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
            return tabs.isEmpty ? nil : active
        }
        // A number is a tab number only when such a tab exists: "5173" is a port, not tab 5173.
        if let number = Int(reference), tabs.indices.contains(number - 1) {
            return tabs[number - 1]
        }
        let needle = reference.lowercased()
        return tabs.first {
            $0.displayTitle.lowercased().contains(needle)
                || ($0.currentURL?.absoluteString.lowercased().contains(needle) ?? false)
        }
    }

    public func number(of tab: PreviewController) -> Int? {
        tabs.firstIndex { $0 === tab }.map { $0 + 1 }
    }
}
