import Foundation
import os

/// Logging that the "Verbose Logging" switch actually controls.
///
/// That switch was stored, was labelled "Log raw SSE chunks and tool execution payloads", and
/// nothing read it — there was no verbose logging anywhere in the app to turn on or off. The
/// eleven `print` calls in the codebase are all error-level and unconditional.
///
/// Verbose output goes to the unified log rather than stdout, so it survives a crash, can be read
/// with `log stream --predicate 'subsystem == "io.github.foscoe63.SwiftOpenWork"'` while the app runs, and does not
/// interleave with test output. The setting is cached rather than read per line: this is called
/// once per streamed chunk, and `loadSettings()` is two file reads.
public enum AppLog {

    public enum Category: String, Sendable {
        case stream = "stream"
        case tools = "tools"
        case mcp = "mcp"
        case models = "models"
    }

    private static let subsystem = AppIdentity.logSubsystem

    private struct VerboseState {
        var cached: Bool?
        var source: (@Sendable () -> Bool)?
    }

    private static let state = OSAllocatedUnfairLock(initialState: VerboseState())

    /// Where the "Verbose Logging" setting is read from. Core cannot see the settings store, so
    /// storage registers itself here when it starts. Until then verbose logging is off.
    public static func setVerboseSource(_ source: @escaping @Sendable () -> Bool) {
        state.withLock {
            $0.source = source
            $0.cached = nil
        }
    }

    /// Whether verbose logging is on, re-read at most once until `invalidate()`.
    public static var isVerbose: Bool {
        let (cached, source) = state.withLock { ($0.cached, $0.source) }
        if let cached { return cached }
        guard let source else { return false }

        // Read outside the lock: the source does file I/O.
        let value = source()
        state.withLock { $0.cached = value }
        return value
    }

    /// Call when settings are saved, so flipping the switch takes effect without a relaunch.
    public static func invalidate() {
        state.withLock { $0.cached = nil }
    }

    /// Log `message()` only when the user has asked for verbose output.
    ///
    /// The message is an autoclosure so that interpolating a payload — the thing this is for —
    /// costs nothing when the switch is off.
    public static func verbose(_ category: Category, _ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        // Resolve before handing it to Logger: the os.Logger interpolation is @escaping, and an
        // autoclosure parameter is not.
        let text = message()
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(text, privacy: .public)")
    }

    /// Something went wrong. Always logged, regardless of the switch.
    public static func error(_ category: Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).error("\(message, privacy: .public)")
    }

    /// A payload trimmed to something a log line can hold, with the original size named.
    public static func truncated(_ text: String, limit: Int = 2000) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit) + "… (\(text.count) chars total)"
    }
}
