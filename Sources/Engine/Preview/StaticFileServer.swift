import Foundation
import Network
import os
import UniformTypeIdentifiers

/// Serves a folder over HTTP on the loopback interface, for previewing plain HTML sites.
///
/// A page opened from `file://` is not the page a browser sees: `fetch` of a relative JSON file
/// fails, ES modules refuse to load, and absolute paths like `/styles.css` point at the disk root.
/// Previewing a static site through `python3 -m http.server` would fix that, but on a Mac without
/// the command line tools `python3` is a stub that opens an installer. This needs nothing.
///
/// Deliberately minimal: GET and HEAD, one request per connection, loopback only, and nothing
/// outside the served folder — `..` and symlinks that escape it are refused.
public final class StaticFileServer: @unchecked Sendable {

    public let root: URL
    public private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "SwiftOpenWork.StaticFileServer")
    private let connections = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: NWConnection]())

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    deinit {
        stop()
    }

    public var url: URL? {
        port == 0 ? nil : URL(string: "http://localhost:\(port)/")
    }

    /// Start listening on a free loopback port. Returns once the port is known.
    public func start() async throws -> URL {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        enum Once {
            case idle
            case pending(CheckedContinuation<URL, Error>)
            case finished
        }
        let once = OSAllocatedUnfairLock(initialState: Once.idle)

        func takePending() -> CheckedContinuation<URL, Error>? {
            once.withLock { state in
                if case .pending(let continuation) = state {
                    state = .finished
                    return continuation
                }
                return nil
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                once.withLock { $0 = .pending(continuation) }
                if Task.isCancelled {
                    takePending()?.resume(throwing: CancellationError())
                    self.stop()
                    return
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let self else {
                            takePending()?.resume(throwing: CancellationError())
                            return
                        }
                        self.port = listener.port?.rawValue ?? 0
                        if let url = self.url {
                            takePending()?.resume(returning: url)
                        } else {
                            takePending()?.resume(throwing: URLError(.cannotConnectToHost))
                            self.stop()
                        }
                    case .failed(let error):
                        takePending()?.resume(throwing: error)
                        self?.stop()
                    case .cancelled:
                        takePending()?.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        } onCancel: { [weak self] in
            takePending()?.resume(throwing: CancellationError())
            self?.stop()
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let open = connections.withLock { held -> [NWConnection] in
            let values = Array(held.values)
            held.removeAll()
            return values
        }
        open.forEach { $0.cancel() }
        port = 0
    }

    // MARK: Requests

    private func handle(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections.withLock { $0[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.withLock { $0[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                return
            }
            if error != nil || isComplete || accumulated.count > 65_536 {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: 400, reason: "Bad Request", body: Data("Bad Request".utf8), type: "text/plain", on: connection)
            return
        }
        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            send(status: 405, reason: "Method Not Allowed", body: Data(), type: "text/plain", on: connection)
            return
        }
        let resolution = Self.resolve(requestTarget: String(parts[1]), root: root)
        switch resolution {
        case .file(let fileURL):
            guard let body = try? Data(contentsOf: fileURL) else {
                send(status: 403, reason: "Forbidden", body: Data("Cannot read file".utf8), type: "text/plain", on: connection)
                return
            }
            send(status: 200, reason: "OK", body: body, type: Self.mimeType(for: fileURL),
                 headOnly: method == "HEAD", on: connection)
        case .redirect(let location):
            send(status: 301, reason: "Moved Permanently", body: Data(), type: "text/plain",
                 extraHeaders: ["Location": location], on: connection)
        case .forbidden:
            send(status: 403, reason: "Forbidden", body: Data("Forbidden".utf8), type: "text/plain", on: connection)
        case .notFound(let path):
            let body = Data("Not found: \(path)".utf8)
            send(status: 404, reason: "Not Found", body: body, type: "text/plain", on: connection)
        }
    }

    private func send(
        status: Int,
        reason: String,
        body: Data,
        type: String,
        headOnly: Bool = false,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        // Always fresh: this is a preview of files being edited, and a cached stylesheet is a bug
        // report about a change that did work.
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n"
        for (name, value) in extraHeaders { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        var payload = Data(header.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Pure helpers

    public enum Resolution: Equatable {
        case file(URL)
        case redirect(String)
        case forbidden
        case notFound(String)
    }

    /// Map a request target onto a file under `root`. Pure, for tests.
    public static func resolve(requestTarget: String, root: URL, fileManager: FileManager = .default) -> Resolution {
        let pathPart = requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let withoutFragment = pathPart.split(separator: "#", maxSplits: 1).first.map(String.init) ?? "/"
        guard let decoded = withoutFragment.removingPercentEncoding, decoded.hasPrefix("/") else {
            return .forbidden
        }
        let components = decoded.split(separator: "/").map(String.init)
        if components.contains("..") { return .forbidden }

        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = rootURL
        for component in components { candidate.appendPathComponent(component) }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolved.path == rootURL.path || resolved.path.hasPrefix(rootPath) else { return .forbidden }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // `/docs` → `/docs/`, so relative links inside its index resolve correctly.
                if !decoded.hasSuffix("/") { return .redirect(withoutFragment + "/") }
                let index = resolved.appendingPathComponent("index.html")
                return fileManager.fileExists(atPath: index.path) ? .file(index) : .notFound(decoded)
            }
            return .file(resolved)
        }
        // `/about` → `about.html`, as most static hosts do.
        let html = resolved.appendingPathExtension("html")
        if (resolved.pathExtension.isEmpty), fileManager.fileExists(atPath: html.path) {
            return .file(html)
        }
        return .notFound(decoded)
    }

    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs", "cjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
