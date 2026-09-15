import Foundation
import AppKit

/// Launch a built app, watch it, and report what happened.
///
/// `build_project` and `run_tests` told the agent whether code *compiled* and whether assertions
/// held. Neither answers "does it run", which is the question that matters most when the change
/// was to a view. Closing that loop by hand is also easy to get wrong: a child process started
/// from a shell dies when that shell exits, so the app appears to launch and is gone by the time
/// anything looks at it.
public enum AppRunner {

    public struct Outcome: Sendable {
        public var launched: Bool
        public var stillRunningAtDeadline: Bool
        public var exitCode: Int32?
        public var stdout: String
        public var stderr: String
        public var crashReport: String?
        public var pid: Int32?
    }

    /// Launch `appBundle`, let it settle for `observeSeconds`, and report.
    ///
    /// Detached via `nohup`-equivalent semantics (`Process` outlives this scope), because the
    /// point is to observe a *running* app rather than to race its startup.
    public static func run(
        appBundle: URL,
        arguments: [String] = [],
        observeSeconds: Double = 8,
        terminateAfter: Bool = true
    ) async throws -> Outcome {
        let binary = try executable(in: appBundle)

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let crashesBefore = recentCrashReports(for: appBundle)

        try process.run()
        let pid = process.processIdentifier

        // Drain concurrently: a filled pipe buffer blocks the child, and an app that logs
        // steadily would otherwise appear to hang rather than run.
        let outBox = OutputBox(), errBox = OutputBox()
        outPipe.fileHandleForReading.readabilityHandler = { outBox.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errBox.append($0.availableData) }

        let deadline = Date().addingTimeInterval(observeSeconds)
        while Date() < deadline && process.isRunning {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let stillRunning = process.isRunning
        var exitCode: Int32?
        if !stillRunning {
            exitCode = process.terminationStatus
        } else if terminateAfter {
            process.terminate()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // A crash report can take a moment to be written after the process dies.
        var crash: String?
        if !stillRunning {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            crash = newCrashReport(for: appBundle, excluding: crashesBefore)
        }

        return Outcome(
            launched: true,
            stillRunningAtDeadline: stillRunning,
            exitCode: exitCode,
            stdout: outBox.text,
            stderr: errBox.text,
            crashReport: crash,
            pid: pid
        )
    }

    /// The `Contents/MacOS` binary inside an `.app`, or the path itself if it is already one.
    public static func executable(in bundle: URL) throws -> URL {
        if bundle.pathExtension == "app" {
            guard let appBundle = Bundle(url: bundle),
                  let exec = appBundle.executableURL,
                  FileManager.default.isExecutableFile(atPath: exec.path) else {
                throw NSError(domain: "AppRunner", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(bundle.lastPathComponent) has no runnable executable in Contents/MacOS."
                ])
            }
            return exec
        }
        guard FileManager.default.isExecutableFile(atPath: bundle.path) else {
            throw NSError(domain: "AppRunner", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(bundle.path) is not executable."
            ])
        }
        return bundle
    }

    /// Newest `.app` under a DerivedData-style build products directory, for when the caller did
    /// not name one. Most recently modified wins, which is what "the build I just made" means.
    public static func newestBuiltApp(under root: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return items
            .filter { $0.pathExtension == "app" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
    }

    // MARK: - Crash reports

    private static var crashDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    private static func recentCrashReports(for bundle: URL) -> Set<String> {
        let prefix = bundle.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: crashDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    private static func newCrashReport(for bundle: URL, excluding known: Set<String>) -> String? {
        let prefix = bundle.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: crashDirectory.path)) ?? []
        guard let fresh = names.filter({ $0.hasPrefix(prefix) && !known.contains($0) }).sorted().last else {
            return nil
        }
        let text = (try? String(contentsOf: crashDirectory.appendingPathComponent(fresh), encoding: .utf8)) ?? ""
        // The head carries the exception type and the crashing thread, which is the part that
        // identifies the fault; the rest is every other thread's backtrace.
        return "\(fresh)\n" + text.split(separator: "\n").prefix(60).joined(separator: "\n")
    }
}

/// Thread-safe accumulator for a pipe being drained off the main actor.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
