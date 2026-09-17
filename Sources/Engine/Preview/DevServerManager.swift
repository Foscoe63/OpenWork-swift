import Foundation
import Combine

/// A long-running development server the preview is showing.
@MainActor
public final class DevServer: ObservableObject, Identifiable {

    public enum Status: Equatable {
        case starting
        /// Answering HTTP requests.
        case running
        case exited(code: Int32)
        case failed(String)
        case stopped

        public var isLive: Bool { self == .starting || self == .running }

        public var label: String {
            switch self {
            case .starting: return "Starting"
            case .running: return "Running"
            case .exited(let code): return "Exited (\(code))"
            case .failed: return "Failed"
            case .stopped: return "Stopped"
            }
        }
    }

    public let id = UUID()
    /// What was run, or a description of the built-in static server.
    public let command: String
    public let workingDirectory: String
    public let isStaticServer: Bool
    public let startedAt = Date()

    @Published public internal(set) var status: Status = .starting
    @Published public internal(set) var url: URL?
    @Published public internal(set) var logLines: [String] = []

    var process: Process?
    var staticServer: StaticFileServer?
    private var partialLine = ""
    static let maxLogLines = 2_000

    init(command: String, workingDirectory: String, isStaticServer: Bool) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.isStaticServer = isStaticServer
    }

    public var pid: Int32? { process?.processIdentifier }

    /// The last `count` lines of output.
    public func logTail(_ count: Int) -> String {
        logLines.suffix(count).joined(separator: "\n")
    }

    func ingest(_ chunk: String) {
        let text = partialLine + ANSI.strip(chunk).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        // Progress bars redraw with a bare carriage return; keep only what they settled on.
        let settled = lines.map { $0.components(separatedBy: "\r").last ?? $0 }
        append(settled)
    }

    func flushPartialLine() {
        guard !partialLine.isEmpty else { return }
        append([partialLine])
        partialLine = ""
    }

    func note(_ line: String) {
        append(["[SwiftOpenWork] \(line)"])
    }

    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        logLines.append(contentsOf: lines)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
        if url == nil {
            for line in lines {
                if let found = DevServerURLDetector.detect(in: line) {
                    url = found
                    break
                }
                if let port = DevServerURLDetector.detectPort(in: line) {
                    url = URL(string: "http://localhost:\(port)/")
                    break
                }
            }
        }
    }
}

/// Starts, watches and stops the development servers the preview shows.
///
/// `terminal_command` cannot run a dev server: it waits for the command to exit and kills it after
/// two minutes, so an agent that ran `npm run dev` either hung its turn or killed the server it
/// wanted to look at. Servers live here instead, outside any one tool call, until they are stopped
/// or the app quits.
@MainActor
public final class DevServerManager: ObservableObject {

    public static let shared = DevServerManager()

    @Published public private(set) var servers: [DevServer] = []
    /// The server the preview pane follows.
    @Published public var activeServerId: UUID?

    private var loginShellPath: String?
    private var loginShellPathResolved = false

    public init() {}

    public var activeServer: DevServer? {
        servers.first { $0.id == activeServerId } ?? servers.last
    }

    public var liveServers: [DevServer] { servers.filter { $0.status.isLive } }

    // MARK: Starting

    /// Run `command` in `directory` as a long-lived server.
    ///
    /// A server already running the same command in the same folder is returned rather than
    /// started twice — two copies would fight over the port, and the second would pick another
    /// one the preview is not showing.
    public func start(command: String, in directory: String, settings: AppSettings) async -> DevServer {
        if let existing = servers.first(where: {
            $0.command == command && $0.workingDirectory == directory && $0.status.isLive
        }) {
            activeServerId = existing.id
            return existing
        }

        let server = DevServer(command: command, workingDirectory: directory, isStaticServer: false)
        servers.append(server)
        activeServerId = server.id

        var environment = ToolExecutionEngine.defaultEnvironment(custom: settings.customEnvironmentVariables)
        if let path = await resolvedLoginShellPath() {
            environment["PATH"] = Self.mergePaths(primary: path, secondary: environment["PATH"] ?? "")
        }
        // Keep servers from opening a browser window of their own, and from colouring output the
        // log view would show as escape codes.
        environment["BROWSER"] = "none"
        environment["FORCE_COLOR"] = "0"
        environment["NO_COLOR"] = "1"

        let shell = settings.terminalShell.isEmpty ? "/bin/zsh" : settings.terminalShell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        // No terminal to answer a prompt from. EOF on stdin makes "port in use, try another?" fail
        // loudly in the log instead of hanging silently.
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak server] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in server?.ingest(text) }
        }
        process.terminationHandler = { [weak server] finished in
            let code = finished.terminationStatus
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let server else { return }
                if !rest.isEmpty { server.ingest(String(decoding: rest, as: UTF8.self)) }
                server.flushPartialLine()
                if server.status != .stopped {
                    server.status = .exited(code: code)
                    server.note("The server exited with code \(code).")
                }
            }
        }

        server.process = process
        server.note("$ \(command)   (in \(directory))")
        do {
            try process.run()
        } catch {
            server.status = .failed("Could not launch \(shell): \(error.localizedDescription)")
            server.note("Could not launch: \(error.localizedDescription)")
        }
        return server
    }

    /// Serve `root` with the built-in static server.
    public func startStatic(root: String) async -> DevServer {
        if let existing = servers.first(where: { $0.isStaticServer && $0.workingDirectory == root && $0.status.isLive }) {
            activeServerId = existing.id
            return existing
        }
        let server = DevServer(command: "Built-in static server", workingDirectory: root, isStaticServer: true)
        servers.append(server)
        activeServerId = server.id
        let files = StaticFileServer(root: URL(fileURLWithPath: root))
        server.staticServer = files
        do {
            let url = try await files.start()
            server.url = url
            server.status = .running
            server.note("Serving \(root) at \(url.absoluteString)")
        } catch {
            server.status = .failed(error.localizedDescription)
            server.note("Could not start: \(error.localizedDescription)")
        }
        return server
    }

    /// Wait until `server` answers HTTP, exits, or `timeout` passes.
    ///
    /// Returns nil when ready, otherwise why not. A server that prints no URL is found by the
    /// ports its process tree is listening on.
    public func waitUntilReady(_ server: DevServer, timeout: TimeInterval = 90) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPortScan = Date.distantPast
        while Date() < deadline {
            switch server.status {
            case .running:
                return nil
            case .exited(let code):
                return "The server exited with code \(code) before it was reachable."
            case .failed(let reason):
                return reason
            case .stopped:
                return "The server was stopped."
            case .starting:
                break
            }
            if server.url == nil, Date().timeIntervalSince(lastPortScan) > 2, let pid = server.pid {
                lastPortScan = Date()
                if let port = await Self.listeningPorts(ofProcessTree: pid).first {
                    server.url = URL(string: "http://localhost:\(port)/")
                    server.note("Found it listening on port \(port).")
                }
            }
            if let url = server.url, await Self.responds(url) {
                server.status = .running
                server.note("Reachable at \(url.absoluteString)")
                return nil
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return server.url == nil
            ? "No URL appeared in the output within \(Int(timeout))s, and the process is not listening on any port."
            : "\(server.url!.absoluteString) did not answer within \(Int(timeout))s."
    }

    // MARK: Stopping

    /// Stop a server and everything it started.
    public func stop(_ server: DevServer) {
        server.status = .stopped
        if let files = server.staticServer {
            files.stop()
            server.note("Stopped.")
            return
        }
        guard let process = server.process, process.isRunning else { return }
        let pid = process.processIdentifier
        let tree = Self.processTree(of: pid)
        // Children first would leave the shell to respawn nothing — order does not matter for
        // SIGTERM, but every process in the tree has to receive it: signalling only the shell
        // leaves node holding the port.
        for member in [pid] + tree { kill(member, SIGTERM) }
        server.note("Stopping (sent SIGTERM to \(tree.count + 1) processes)…")
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for member in [pid] + tree where kill(member, 0) == 0 {
                kill(member, SIGKILL)
            }
        }
    }

    public func stopAll() {
        for server in servers where server.status.isLive { stop(server) }
    }

    /// Stop everything synchronously, for app termination, where no later task will run.
    public func terminateAllNow() {
        for server in servers where server.status.isLive {
            server.staticServer?.stop()
            guard let process = server.process, process.isRunning else { continue }
            let pid = process.processIdentifier
            for member in [pid] + Self.processTree(of: pid) { kill(member, SIGKILL) }
        }
    }

    public func remove(_ server: DevServer) {
        if server.status.isLive { stop(server) }
        servers.removeAll { $0.id == server.id }
        if activeServerId == server.id { activeServerId = servers.last?.id }
    }

    // MARK: System helpers

    nonisolated static func processTree(of pid: Int32) -> [Int32] {
        let output = runQuick("/bin/ps", ["-A", "-o", "pid=,ppid="]) ?? ""
        return ProcessTree.descendants(of: pid, in: ProcessTree.parse(psOutput: output))
    }

    nonisolated static func listeningPorts(ofProcessTree pid: Int32) async -> [Int] {
        await Task.detached(priority: .utility) {
            let pids = ([pid] + processTree(of: pid)).map(String.init).joined(separator: ",")
            let output = runQuick("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pids]) ?? ""
            return parseListeningPorts(lsofOutput: output)
        }.value
    }

    /// Ports from `lsof -nP -iTCP -sTCP:LISTEN` output, in order of appearance. Pure, for tests.
    nonisolated static func parseListeningPorts(lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        let regex = try? NSRegularExpression(pattern: #":(\d{2,5}) \(LISTEN\)"#)
        for line in lsofOutput.split(separator: "\n") {
            let text = String(line)
            guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let port = Int(text[range]), !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    nonisolated static func responds(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Run a short command and return its output, killing it at `timeout`.
    ///
    /// Reading is asynchronous: a blocking read would wait forever on a process that hangs without
    /// printing — an interactive shell stuck in its startup files — and the timeout would never
    /// be checked.
    nonisolated static func runQuick(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        final class Buffer: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
        }
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            buffer.lock.lock(); buffer.data.append(chunk); buffer.lock.unlock()
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        buffer.lock.lock(); buffer.data.append(rest); let data = buffer.data; buffer.lock.unlock()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Login shell PATH

    /// The PATH an interactive login shell has, where nvm, asdf, volta and Homebrew put `node`.
    ///
    /// An app launched from the Dock inherits launchd's minimal PATH, so `npm run dev` fails with
    /// "command not found" on exactly the machines where it works in Terminal. Asked once, with a
    /// timeout, because an interactive shell can block on its own startup files.
    private func resolvedLoginShellPath() async -> String? {
        if loginShellPathResolved { return loginShellPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolved = await Task.detached(priority: .userInitiated) { () -> String? in
            let output = Self.runQuick(shell, ["-ilc", #"printf "__SOW_PATH__%s__SOW_END__" "$PATH""#], timeout: 6) ?? ""
            return Self.extractMarkedPath(output)
        }.value
        loginShellPath = resolved
        loginShellPathResolved = true
        return resolved
    }

    nonisolated static func extractMarkedPath(_ output: String) -> String? {
        guard let start = output.range(of: "__SOW_PATH__"),
              let end = output.range(of: "__SOW_END__", range: start.upperBound..<output.endIndex) else { return nil }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    nonisolated static func mergePaths(primary: String, secondary: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for entry in (primary.split(separator: ":") + secondary.split(separator: ":")).map(String.init)
        where !entry.isEmpty && seen.insert(entry).inserted {
            result.append(entry)
        }
        return result.joined(separator: ":")
    }
}
