import Foundation
import SwiftOpenWorkCore

/// JSON-RPC over stdio to one language server process.
///
/// This layer knows the wire protocol and nothing about any particular server: Content-Length
/// framing, request/response matching, answering the server's own requests, and turning every way
/// a server can go away into an error a caller sees. Three rules it exists to keep:
/// - **A waiting request always ends.** It resolves with the response, a timeout, cancellation of
///   the calling task, or the server exiting — never an indefinite hang.
/// - **Garbage on the wire is fatal, not skipped.** A malformed header means the stream is out of
///   step, and every later message would be misread. The connection fails loudly instead.
/// - **Failures say why.** The tail of the server's stderr is kept and quoted, because
///   "sourcekit-lsp exited" alone is not something anyone can act on.
public final class LSPConnection: @unchecked Sendable {

    public enum Failure: Error, LocalizedError, Equatable {
        /// The server could not be started, or has exited. The string says why.
        case unavailable(String)
        case timedOut(method: String, seconds: Int)
        case server(code: Int, message: String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return reason
            case .timedOut(let method, let seconds):
                return "\(method) did not answer within \(seconds)s."
            case .server(_, let message):
                return message
            case .cancelled:
                return "The request was cancelled."
            }
        }

        /// JSON-RPC's MethodNotFound: the server does not implement the request.
        public var isMethodNotFound: Bool {
            if case .server(-32601, _) = self { return true }
            return false
        }
    }

    /// Answers a request the server sent us. Return `.success(result)` or `.failure((code, message))`.
    public typealias ServerRequestHandler = @Sendable (_ method: String, _ params: Any?) -> Result<Any, ServerRequestError>
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: [String: Any]?) -> Void

    public struct ServerRequestError: Error {
        public var code: Int
        public var message: String
        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }
        public static func methodNotFound(_ method: String) -> ServerRequestError {
            ServerRequestError(code: -32601, message: "Unhandled method \(method)")
        }
    }

    /// Used in error messages: the server's executable name.
    public let name: String
    private let process: Process?
    private let toServer: FileHandle
    private let onServerRequest: ServerRequestHandler
    private let onNotification: NotificationHandler

    private let lock = NSLock()
    /// Separate from `lock`: frames written from the reader thread and a caller must not interleave.
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextId = 0
    /// Waiting requests. A response crosses from the reader thread as its JSON bytes, which are
    /// Sendable, and is decoded again by the task that asked; the parsed `Any` never changes threads.
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    /// Requests whose task was cancelled before the continuation was registered.
    private var cancelledBeforeSend = Set<Int>()
    private var failure: Failure?
    private var stderrTail = Data()
    private static let stderrLimit = 8_000

    // MARK: - Lifecycle

    /// Launch `executable` and connect to its stdio.
    public static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        onServerRequest: @escaping ServerRequestHandler,
        onNotification: @escaping NotificationHandler
    ) throws -> LSPConnection {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let connection = LSPConnection(
            name: executable.lastPathComponent,
            process: process,
            toServer: stdin.fileHandleForWriting,
            fromServer: stdout.fileHandleForReading,
            onServerRequest: onServerRequest,
            onNotification: onNotification
        )
        stderr.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            connection?.appendStderr(chunk)
        }
        process.terminationHandler = { [weak connection] process in
            connection?.fail(.unavailable("\(executable.lastPathComponent) exited with status \(process.terminationStatus)."))
        }
        do {
            try process.run()
        } catch {
            throw Failure.unavailable("\(executable.lastPathComponent) could not be started: \(error.localizedDescription)")
        }
        LiveConnections.add(connection)
        return connection
    }

    /// Connect to already-open streams. `launch` uses this; tests use it with pipes and no process.
    public init(
        name: String,
        process: Process?,
        toServer: FileHandle,
        fromServer: FileHandle,
        onServerRequest: @escaping ServerRequestHandler,
        onNotification: @escaping NotificationHandler
    ) {
        self.name = name
        self.process = process
        self.toServer = toServer
        self.onServerRequest = onServerRequest
        self.onNotification = onNotification
        fromServer.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.fail(.unavailable("\(self.name) closed its output."))
            } else {
                self.receive(chunk)
            }
        }
    }

    public var isAlive: Bool {
        lock.withLock { failure == nil }
    }

    /// Why the connection is dead, or nil while it is alive.
    public var terminationReason: String? {
        lock.withLock { failure?.localizedDescription }
    }

    public var processIdentifier: Int32? {
        process?.processIdentifier
    }

    /// Ask the server to exit, then make sure it does.
    public func shutdown() async {
        if isAlive {
            _ = try? await request("shutdown", nil, timeout: 3)
            notify("exit", nil)
        }
        terminateNow()
    }

    /// Stop the process without the protocol handshake. For app termination and crashed servers.
    public func terminateNow() {
        fail(.unavailable("\(name) was shut down."))
        try? toServer.close()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            // A server that ignores SIGTERM must not outlive us.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        LiveConnections.remove(self)
    }

    // MARK: - Messages

    public func request(_ method: String, _ params: sending Any?, timeout: TimeInterval) async throws -> sending Any? {
        let id: Int = lock.withLock {
            nextId += 1
            return nextId
        }
        let body: Data? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let refusal: Failure? = lock.withLock {
                    if let failure { return failure }
                    if cancelledBeforeSend.remove(id) != nil { return .cancelled }
                    pending[id] = continuation
                    return nil
                }
                if let refusal {
                    continuation.resume(throwing: refusal)
                    return
                }
                write(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? NSNull()])
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.resolve(id, with: .failure(Failure.timedOut(method: method, seconds: Int(timeout)))) else { return }
                    self.notify("$/cancelRequest", ["id": id])
                }
            }
        } onCancel: {
            let wasPending: Bool = lock.withLock {
                if pending[id] != nil { return true }
                cancelledBeforeSend.insert(id)
                return false
            }
            if wasPending, resolve(id, with: .failure(Failure.cancelled)) {
                notify("$/cancelRequest", ["id": id])
            }
        }
        guard let body else { return nil }
        return try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
    }

    public func notify(_ method: String, _ params: Any?) {
        write(["jsonrpc": "2.0", "method": method, "params": params ?? NSNull()])
    }

    /// Resume a pending request exactly once. False if something else already resolved it.
    @discardableResult
    private func resolve(_ id: Int, with result: Result<Data?, Error>) -> Bool {
        guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return false }
        continuation.resume(with: result)
        return true
    }

    private func write(_ message: [String: Any]) {
        guard isAlive else { return }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: message)
        } catch {
            AppLog.verbose(.tools, "lsp \(name): unencodable message \(message["method"] ?? "")")
            return
        }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        do {
            try writeLock.withLock { try toServer.write(contentsOf: frame) }
        } catch {
            fail(.unavailable("Could not write to \(name): \(error.localizedDescription)"))
        }
    }

    /// Split the byte stream into messages. Internal so the framing can be tested directly.
    public func receive(_ chunk: Data) {
        var messages: [[String: Any]] = []
        var violation: String?
        lock.withLock {
            guard failure == nil else { return }
            buffer.append(chunk)
            let separator = Data("\r\n\r\n".utf8)
            while let headerEnd = buffer.range(of: separator) {
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                guard let length = Self.contentLength(inHeader: header) else {
                    violation = "\(name) sent a message without a valid Content-Length header."
                    return
                }
                let bodyStart = headerEnd.upperBound
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
                let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                guard let object = try? JSONSerialization.jsonObject(with: buffer[bodyStart..<bodyEnd]) as? [String: Any] else {
                    violation = "\(name) sent a message that is not a JSON object."
                    return
                }
                messages.append(object)
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            }
        }
        messages.forEach(handle)
        if let violation {
            fail(.unavailable(violation))
            if let process, process.isRunning { process.terminate() }
        }
    }

    public static func contentLength(inHeader header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            guard let value = Int(parts[1].trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            return value
        }
        return nil
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                // The server is waiting on this answer; an unanswered request can stall it.
                switch onServerRequest(method, message["params"]) {
                case .success(let result):
                    write(["jsonrpc": "2.0", "id": id, "result": result])
                case .failure(let error):
                    write(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
                }
            } else {
                onNotification(method, message["params"] as? [String: Any])
            }
            return
        }

        guard let id = message["id"] as? Int else { return }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? 0
            let text = (error["message"] as? String) ?? "unknown error"
            resolve(id, with: .failure(Failure.server(code: code, message: text)))
        } else {
            let result = message["result"]
            guard let result, !(result is NSNull) else {
                resolve(id, with: .success(nil))
                return
            }
            // It was parsed from JSON a moment ago, so it serialises again.
            do {
                resolve(id, with: .success(try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)))
            } catch {
                resolve(id, with: .failure(Failure.server(code: 0, message: "\(name) sent a result that could not be read: \(error.localizedDescription)")))
            }
        }
    }

    private func appendStderr(_ chunk: Data) {
        lock.withLock {
            stderrTail.append(chunk)
            if stderrTail.count > Self.stderrLimit {
                stderrTail = Data(stderrTail.suffix(Self.stderrLimit))
            }
        }
    }

    /// Mark the connection dead and fail every waiting request. The first reason wins.
    private func fail(_ reason: Failure) {
        let (waiting, final): ([CheckedContinuation<Data?, Error>], Failure) = lock.withLock {
            if let failure { return ([], failure) }
            let tail = String(decoding: stderrTail, as: UTF8.self)
                .split(separator: "\n").suffix(6).joined(separator: "\n")
            var final = reason
            if case .unavailable(let text) = reason, !tail.isEmpty {
                final = .unavailable("\(text) Last output:\n\(tail)")
            }
            failure = final
            let all = Array(pending.values)
            pending.removeAll()
            return (all, final)
        }
        waiting.forEach { $0.resume(throwing: final) }
    }
}

/// Every running server, so the app can stop them all when it quits.
public enum LiveConnections {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connections: [ObjectIdentifier: LSPConnection] = [:]

    public static func add(_ connection: LSPConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    public static func remove(_ connection: LSPConnection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    public static func terminateAll() {
        let all = lock.withLock { Array(connections.values) }
        all.forEach { $0.terminateNow() }
    }
}
