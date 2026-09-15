import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

/// Letting the agent see what it built.
///
/// The app could describe a UI it had just written and never look at it. This session's own
/// evidence: a settings picker rendered completely blank because its selection matched no tag,
/// and 402 passing tests plus a clean compile said nothing was wrong. Only launching the app and
/// looking found it.
///
/// Two channels, deliberately. `captureWindow` is pixels, for layout, colour and anything drawn
/// rather than described. `accessibilityTree` is text — roughly twenty times cheaper in tokens,
/// it states control *values* that a screenshot only implies, and, decisively, **it works with a
/// text-only model**. A vision-only feedback loop would abandon local MLX exactly where this app
/// is supposed to be strongest.
public enum ScreenPerception {

    public enum PerceptionError: LocalizedError {
        case screenRecordingDenied
        case accessibilityDenied
        case appNotRunning(String)
        case noWindows(String)
        case captureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return """
                Screen Recording permission is not granted, so no window can be captured.
                Grant it in System Settings › Privacy & Security › Screen & System Audio Recording, \
                then relaunch OpenWork — macOS only re-reads this permission at launch.
                """
            case .accessibilityDenied:
                return """
                Accessibility permission is not granted, so the accessibility tree cannot be read.
                Grant it in System Settings › Privacy & Security › Accessibility, then try again.
                """
            case .appNotRunning(let app):
                return "No running application matches '\(app)'. Launch it first, or use run_app."
            case .noWindows(let app):
                return "'\(app)' is running but has no on-screen windows to capture."
            case .captureFailed(let reason):
                return "Capture failed: \(reason)"
            }
        }
    }

    // MARK: - Locating an app

    /// Resolve a bundle id, bundle-id fragment, or localized name to a running application.
    public static func runningApplication(matching query: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let needle = query.lowercased()
        // Exact bundle id first, so "com.foo.Bar" never matches "com.foo.BarHelper" by accident.
        if let exact = apps.first(where: { $0.bundleIdentifier?.lowercased() == needle }) { return exact }
        if let byName = apps.first(where: { $0.localizedName?.lowercased() == needle }) { return byName }
        return apps.first {
            ($0.bundleIdentifier?.lowercased().contains(needle) ?? false)
                || ($0.localizedName?.lowercased().contains(needle) ?? false)
        }
    }

    public static func runningApplicationNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
    }

    // MARK: - Pixels

    /// Capture `app`'s frontmost window to a PNG and return the file URL.
    ///
    /// Captures without raising or focusing the app: the point is to observe what is there, not
    /// to disturb what the user is doing.
    public static func captureWindow(appQuery: String, to directory: URL) async throws -> URL {
        guard let app = runningApplication(matching: appQuery) else {
            throw PerceptionError.appNotRunning(appQuery)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            // SCShareableContent is the permission gate; a denial surfaces here, not at capture.
            throw PerceptionError.screenRecordingDenied
        }

        let windows = content.windows
            .filter { $0.owningApplication?.processID == app.processIdentifier }
            .filter { $0.frame.width > 120 && $0.frame.height > 120 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

        guard let window = windows.first else {
            throw PerceptionError.noWindows(app.localizedName ?? appQuery)
        }

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw PerceptionError.captureFailed(error.localizedDescription)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PerceptionError.captureFailed("could not encode PNG")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "screenshot-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png"
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    // MARK: - Structure

    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Ask for Accessibility once, with the system prompt, rather than failing silently.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// A readable dump of `app`'s frontmost window's accessibility tree.
    ///
    /// Depth-limited and node-limited on purpose: a real window is thousands of elements, and an
    /// unbounded dump would swamp the context it is meant to inform.
    public static func accessibilityTree(
        appQuery: String,
        maxDepth: Int = 14,
        maxNodes: Int = 400
    ) throws -> String {
        guard hasAccessibilityPermission else { throw PerceptionError.accessibilityDenied }
        guard let app = runningApplication(matching: appQuery) else {
            throw PerceptionError.appNotRunning(appQuery)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else {
            throw PerceptionError.noWindows(app.localizedName ?? appQuery)
        }

        var lines: [String] = ["\(app.localizedName ?? appQuery) — frontmost window"]
        var visited = 0
        describe(window, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, into: &lines)
        if visited >= maxNodes {
            lines.append("… truncated at \(maxNodes) elements. Narrow with a higher maxDepth budget or inspect a subview.")
        }
        return lines.joined(separator: "\n")
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func describe(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        visited: inout Int,
        into lines: inout [String]
    ) {
        guard depth <= maxDepth, visited < maxNodes else { return }
        visited += 1

        let role = copyAttribute(element, kAXRoleAttribute) as? String ?? "?"
        let title = copyAttribute(element, kAXTitleAttribute) as? String
        let value = copyAttribute(element, kAXValueAttribute)
        let desc = copyAttribute(element, kAXDescriptionAttribute) as? String
        let enabled = copyAttribute(element, kAXEnabledAttribute) as? Bool

        // Roles that carry no information of their own and only nest — collapsing them keeps the
        // dump about controls rather than about layout scaffolding.
        let isPlainContainer = (role == "AXGroup" || role == "AXSplitGroup" || role == "AXScrollArea")
            && title == nil && desc == nil && value == nil

        if !isPlainContainer {
            var parts = [role]
            if let title, !title.isEmpty { parts.append("\"\(title)\"") }
            if let desc, !desc.isEmpty, desc != title { parts.append("(\(desc))") }
            if let value { parts.append("= \(format(value))") }
            if enabled == false { parts.append("[disabled]") }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
        }

        if let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                describe(
                    child,
                    depth: isPlainContainer ? depth : depth + 1,
                    maxDepth: maxDepth, maxNodes: maxNodes,
                    visited: &visited, into: &lines
                )
            }
        }
    }

    private static func format(_ value: Any) -> String {
        if let s = value as? String { return s.count > 120 ? "\"\(s.prefix(120))…\"" : "\"\(s)\"" }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value).prefix(80).description
    }
}
