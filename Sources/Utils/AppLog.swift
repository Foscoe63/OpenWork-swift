import Foundation
import os

/// Logging that the "Verbose Logging" switch actually controls.
///
/// That switch was stored, was labelled "Log raw SSE chunks and tool execution payloads", and
/// nothing read it — there was no verbose logging anywhere in the app to turn on or off. The
/// eleven `print` calls in the codebase are all error-level and unconditional.
///
/// Verbose output goes to the unified log rather than stdout, so it survives a crash, can be read
/// with `log stream --predicate 'subsystem == "ai.openwork"'` while the app runs, and does not
/// interleave with test output. The setting is cached rather than read per line: this is called
/// once per streamed chunk, and `loadSettings()` is two file reads.
public enum AppLog {

    public enum Category: String {
        case stream = "stream"
        case tools = "tools"
        case mcp = "mcp"
        case models = "models"
    }

    private static let subsystem = "ai.openwork"
    private static let lock = NSLock()
    private static var cachedVerbose: Bool?

    /// Whether verbose logging is on, re-read at most once until `invalidate()`.
    public static var isVerbose: Bool {
        lock.lock()
        if let cachedVerbose {
            lock.unlock()
            return cachedVerbose
        }
        lock.unlock()

        let value = PersistenceManager.shared.loadSettings().verboseLogging
        lock.lock()
        cachedVerbose = value
        lock.unlock()
        return value
    }

    /// Call when settings are saved, so flipping the switch takes effect without a relaunch.
    public static func invalidate() {
        lock.lock()
        cachedVerbose = nil
        lock.unlock()
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
