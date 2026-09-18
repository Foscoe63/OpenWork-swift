import XCTest
import AppKit
@testable import SwiftOpenWork

/// The window-frame observers moved from notification blocks to main-actor selector methods for
/// the Swift 6 language mode. A notification must still reach them.
@MainActor
final class WindowFrameObserverTests: XCTestCase {

    func testBecomingKeyAppliesTheMainWindowSettings() {
        WindowLayoutStore.observeMainWindowAutosave()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.minSize = .zero

        // `didBecomeKey` only applies the main-window settings and restores a saved frame; unlike
        // the move, resize and close notifications it writes nothing to the user's defaults.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        // The minimum size rather than the autosave name: AppKit gives a name to one window at a
        // time, and when the app hosts the tests its own window already has it.
        XCTAssertEqual(window.minSize, NSSize(width: WindowLayoutStore.minWindowWidth, height: WindowLayoutStore.minWindowHeight))
    }

    func testWindowsItDoesNotManageAreLeftAlone() {
        WindowLayoutStore.observeMainWindowAutosave()
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.minSize = .zero
        let untouched = panel.minSize  // AppKit keeps room for the title bar

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)

        XCTAssertEqual(panel.minSize, untouched, "a window that cannot resize is not the main window")
    }
}
