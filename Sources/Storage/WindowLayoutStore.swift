import Foundation
import AppKit
import CoreGraphics
import SwiftUI

/// Persists main-window chrome: nav destination, inspector, split widths, and window frame.
public enum WindowLayoutStore {
    private static let prefix = "swiftopenwork.windowLayout.v1."

    private enum Key {
        static let navigation = prefix + "navigation"
        static let inspectorOpen = prefix + "inspectorOpen"
        static let inspectorTab = prefix + "inspectorTab"
        static let settingsTab = prefix + "settingsTab"
        static let sidebarWidth = prefix + "sidebarWidth"
        static let inspectorWidth = prefix + "inspectorWidth"
        static let sessionId = prefix + "sessionId"
        static let workspaceId = prefix + "workspaceId"
        static let windowFrame = prefix + "windowFrame" // NSStringFromRect
        static let windowIsZoomed = prefix + "windowIsZoomed"
    }

    public static let defaultSidebarWidth: Double = 260
    public static let defaultInspectorWidth: Double = 320
    public static let minSidebarWidth: Double = 200
    public static let maxSidebarWidth: Double = 450
    public static let minInspectorWidth: Double = 260
    public static let maxInspectorWidth: Double = 650
    public static let minWindowWidth: CGFloat = 920
    public static let minWindowHeight: CGFloat = 620

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
            let raw = UserDefaults.standard.string(forKey: Key.inspectorTab) ?? InspectorTab.tools.rawValue
            return InspectorTab(rawValue: raw) ?? .tools
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.inspectorTab) }
    }

    static let removedSettingsTabs: Set<String> = ["cloud", "connect"]

    public static var settingsTab: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Key.settingsTab) ?? "general"
            // Pages that were removed. Restoring onto one would highlight nothing in the sidebar.
            return removedSettingsTabs.contains(stored) ? "general" : stored
        }
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
            guard abs(clamped - sidebarWidth) > 0.5 else { return }
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
            guard abs(clamped - inspectorWidth) > 0.5 else { return }
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

    // MARK: - Explicit window frame (more reliable than SwiftUI + setFrameAutosaveName races)

    public static var savedWindowFrame: NSRect? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.windowFrame), !raw.isEmpty else { return nil }
            let rect = NSRectFromString(raw)
            guard rect.width >= minWindowWidth * 0.5, rect.height >= minWindowHeight * 0.5 else { return nil }
            return rect
        }
        set {
            if let newValue {
                UserDefaults.standard.set(NSStringFromRect(newValue), forKey: Key.windowFrame)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.windowFrame)
            }
        }
    }

    public static var windowIsZoomed: Bool {
        get { UserDefaults.standard.bool(forKey: Key.windowIsZoomed) }
        set { UserDefaults.standard.set(newValue, forKey: Key.windowIsZoomed) }
    }

    public static func saveWindowFrame(from window: NSWindow) {
        windowIsZoomed = window.isZoomed
        // Persist the un-zoomed frame when zoomed so restore can re-zoom cleanly.
        let frame = window.isZoomed ? window.frame // still useful as screen placement
            : window.frame
        savedWindowFrame = frame
        UserDefaults.standard.synchronize()
    }

    public static func restoreWindowFrame(on window: NSWindow) {
        guard let saved = savedWindowFrame else { return }
        var frame = saved
        // Keep the window on a visible screen after display changes.
        if let screen = screenContaining(frame) ?? NSScreen.main {
            frame = frame.intersection(screen.visibleFrame)
            if frame.width < minWindowWidth { frame.size.width = min(minWindowWidth, screen.visibleFrame.width) }
            if frame.height < minWindowHeight { frame.size.height = min(minWindowHeight, screen.visibleFrame.height) }
            if frame.origin.x < screen.visibleFrame.minX { frame.origin.x = screen.visibleFrame.minX }
            if frame.origin.y < screen.visibleFrame.minY { frame.origin.y = screen.visibleFrame.minY }
        }
        window.setFrame(frame, display: true)
        if windowIsZoomed, !window.isZoomed {
            window.zoom(nil)
        }
    }

    private static func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(frame) }
    }

    public static let mainWindowAutosaveName = "SwiftOpenWorkMainWindow"

    private static var didObserve = false

    public static func observeMainWindowAutosave() {
        guard !didObserve else { return }
        didObserve = true

        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { note in
            guard let window = note.object as? NSWindow, shouldManage(window) else { return }
            applyFrameAutosave(to: window)
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler)
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main, using: handler)
        center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, shouldManage(window) else { return }
            saveWindowFrame(from: window)
        }
        center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, shouldManage(window) else { return }
            // Avoid saving mid-animation noise; live resize has its own event.
            if !window.inLiveResize {
                saveWindowFrame(from: window)
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, shouldManage(window) else { return }
            saveWindowFrame(from: window)
        }
    }

    public static func configureMainWindowAutosave() {
        for window in NSApp.windows where shouldManage(window) {
            applyFrameAutosave(to: window)
        }
    }

    private static func shouldManage(_ window: NSWindow) -> Bool {
        if window.level != .normal { return false }
        if window.styleMask.contains(.utilityWindow) { return false }
        if window.isSheet { return false }
        return window.styleMask.contains(.titled) && window.styleMask.contains(.resizable)
    }

    private static var restoredWindowIds = Set<ObjectIdentifier>()

    private static func applyFrameAutosave(to window: NSWindow) {
        window.setFrameAutosaveName(mainWindowAutosaveName)
        window.isRestorable = true
        window.minSize = NSSize(width: minWindowWidth, height: minWindowHeight)

        let id = ObjectIdentifier(window)
        // Restore our explicit frame once per window instance (beats SwiftUI defaultSize).
        if !restoredWindowIds.contains(id), savedWindowFrame != nil {
            restoredWindowIds.insert(id)
            restoreWindowFrame(on: window)
        }
    }
}

// MARK: - Installer view (hooks the hosting NSWindow as soon as SwiftUI attaches)

struct WindowFramePersistenceInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowFrameProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowFrameProbeView: NSView {
    private var didConfigure = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureIfNeeded()
    }

    override func layout() {
        super.layout()
        configureIfNeeded()
    }

    private func configureIfNeeded() {
        guard window != nil, !didConfigure else { return }
        didConfigure = true
        DispatchQueue.main.async {
            WindowLayoutStore.observeMainWindowAutosave()
            WindowLayoutStore.configureMainWindowAutosave()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            WindowLayoutStore.configureMainWindowAutosave()
        }
    }
}
