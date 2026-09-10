import Foundation
import AppKit
import CoreGraphics
import SwiftUI

/// Persists main-window chrome: nav destination, inspector, and split widths.
/// Window frame itself uses AppKit `NSWindow` frame autosave (`OpenWorkMainWindow`).
public enum WindowLayoutStore {
    private static let prefix = "openwork.windowLayout.v1."

    private enum Key {
        static let navigation = prefix + "navigation"
        static let inspectorOpen = prefix + "inspectorOpen"
        static let inspectorTab = prefix + "inspectorTab"
        static let settingsTab = prefix + "settingsTab"
        static let sidebarWidth = prefix + "sidebarWidth"
        static let inspectorWidth = prefix + "inspectorWidth"
        static let sessionId = prefix + "sessionId"
        static let workspaceId = prefix + "workspaceId"
    }

    public static let defaultSidebarWidth: Double = 260
    public static let defaultInspectorWidth: Double = 320
    public static let minSidebarWidth: Double = 200
    public static let maxSidebarWidth: Double = 450
    public static let minInspectorWidth: Double = 260
    public static let maxInspectorWidth: Double = 650

    public static var navigationDestination: NavigationDestination {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.navigation) ?? NavigationDestination.chat.rawValue
            return NavigationDestination(rawValue: raw) ?? .chat
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.navigation) }
    }

    public static var isInspectorOpen: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.inspectorOpen) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.inspectorOpen)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.inspectorOpen) }
    }

    public static var inspectorTab: InspectorTab {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.inspectorTab) ?? InspectorTab.subagents.rawValue
            return InspectorTab(rawValue: raw) ?? .subagents
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.inspectorTab) }
    }

    public static var settingsTab: String {
        get { UserDefaults.standard.string(forKey: Key.settingsTab) ?? "general" }
        set { UserDefaults.standard.set(newValue, forKey: Key.settingsTab) }
    }

    public static var sidebarWidth: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.sidebarWidth)
            if stored < minSidebarWidth { return defaultSidebarWidth }
            return min(max(stored, minSidebarWidth), maxSidebarWidth)
        }
        set {
            let clamped = min(max(newValue, minSidebarWidth), maxSidebarWidth)
            UserDefaults.standard.set(clamped, forKey: Key.sidebarWidth)
        }
    }

    public static var inspectorWidth: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.inspectorWidth)
            if stored < minInspectorWidth { return defaultInspectorWidth }
            return min(max(stored, minInspectorWidth), maxInspectorWidth)
        }
        set {
            let clamped = min(max(newValue, minInspectorWidth), maxInspectorWidth)
            UserDefaults.standard.set(clamped, forKey: Key.inspectorWidth)
        }
    }

    public static var sessionId: String? {
        get { UserDefaults.standard.string(forKey: Key.sessionId) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sessionId) }
    }

    public static var workspaceId: String? {
        get { UserDefaults.standard.string(forKey: Key.workspaceId) }
        set { UserDefaults.standard.set(newValue, forKey: Key.workspaceId) }
    }

    // MARK: - Window frame (AppKit)

    public static let mainWindowAutosaveName = "OpenWorkMainWindow"

    /// Attach frame autosave to the main app window(s) so close/reopen restores position & size.
    public static func configureMainWindowAutosave() {
        for window in NSApp.windows where shouldManage(window) {
            applyFrameAutosave(to: window)
        }
    }

    public static func observeMainWindowAutosave() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, shouldManage(window) else { return }
            applyFrameAutosave(to: window)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, shouldManage(window) else { return }
            window.saveFrame(usingName: mainWindowAutosaveName)
        }
    }

    private static func shouldManage(_ window: NSWindow) -> Bool {
        // Skip sheets, panels, and utility windows.
        if window.level != .normal { return false }
        if window.styleMask.contains(.utilityWindow) { return false }
        if window.isSheet { return false }
        // Main OpenWork window is sizable with a title bar.
        return window.styleMask.contains(.titled) && window.styleMask.contains(.resizable)
    }

    private static func applyFrameAutosave(to window: NSWindow) {
        if window.frameAutosaveName != mainWindowAutosaveName {
            _ = window.setFrameUsingName(mainWindowAutosaveName)
            window.setFrameAutosaveName(mainWindowAutosaveName)
        }
        window.isRestorable = true
    }
}

/// Reports a view's width upward so split panes can persist divider positions.
struct SplitPaneWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

extension View {
    /// Emit continuous width updates while an `HSplitView` divider is dragged.
    func trackSplitWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: SplitPaneWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(SplitPaneWidthKey.self, perform: onChange)
    }
}
