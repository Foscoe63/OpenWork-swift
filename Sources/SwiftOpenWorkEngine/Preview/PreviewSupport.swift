import Foundation

/// The parts of the live preview that are plain logic, kept apart so they can be tested without
/// launching a server or a web view.

// MARK: - Finding the URL a dev server is on

public enum DevServerURLDetector {

    /// The URL a line of dev-server output announces, if it announces one.
    ///
    /// Servers print their address in many shapes — Vite's `➜  Local:   http://localhost:5173/`,
    /// Next's `- Local: http://localhost:3000`, Python's `Serving HTTP on :: port 8000
    /// (http://[::]:8000/)`, Rails' `Listening on http://127.0.0.1:3000` — often wrapped in colour
    /// codes. Wildcard binds (`0.0.0.0`, `[::]`) are not addresses a browser can open, so they are
    /// rewritten to `localhost`. Only loopback-style hosts count: a `Network:` line naming the LAN
    /// address is the same server, and a docs link in a banner is not the server at all.
    public static func detect(in line: String) -> URL? {
        let clean = ANSI.strip(line)
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\[::\]|[A-Za-z0-9-]+\.localhost)(?::\d{2,5})?(?:/[^\s"'<>)\]]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let range = Range(match.range, in: clean) else {
            return nil
        }
        var raw = String(clean[range])
        while let last = raw.last, ".,;:".contains(last) { raw.removeLast() }
        raw = raw
            .replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
            .replacingOccurrences(of: "://[::]", with: "://localhost")
            .replacingOccurrences(of: "://[::1]", with: "://localhost")
        return URL(string: raw)
    }

    /// A port named in prose with no URL: `Listening on port 8080`, `running at port 4000`.
    public static func detectPort(in line: String) -> Int? {
        let clean = ANSI.strip(line)
        let pattern = #"(?i)\b(?:listening|running|serving|started|available)\b[^\n]{0,40}?\bport\s*:?\s*(\d{2,5})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let range = Range(match.range(at: 1), in: clean),
              let port = Int(clean[range]), (1...65535).contains(port) else {
            return nil
        }
        return port
    }
}

public enum ANSI {
    /// Remove terminal colour and cursor sequences, so logs read as text and regexes match.
    public static func strip(_ text: String) -> String {
        guard text.utf16.contains(27) else { return text }
        let pattern = #"\x{1B}(?:\[[0-?]*[ -/]*[@-~]|\][^\x{07}]*\x{07}|[@-Z\\-_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

// MARK: - Knowing how to start a project

public struct DevServerPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A command that runs the project's own server.
        case command(String)
        /// Plain files served by the app itself — no toolchain needed.
        case staticFiles(root: String, entry: String)
    }

    public var kind: Kind
    /// Why this was chosen, in a sentence a person can check.
    public var reason: String
    /// Something to know first, such as dependencies not being installed.
    public var caveat: String?

    public var command: String? {
        if case .command(let command) = kind { return command }
        return nil
    }
    public init(
        kind: Kind,
        reason: String,
        caveat: String? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.caveat = caveat
    }
}

public enum DevServerCommandDetector {

    /// How to preview the project at `root`, or nil when nothing recognisable is there.
    public static func plan(root: String, fileManager: FileManager = .default) -> DevServerPlan? {
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: (root as NSString).appendingPathComponent(name))
        }

        if exists("package.json"),
           let data = fileManager.contents(atPath: (root as NSString).appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = json["scripts"] as? [String: String] ?? [:]
            let runner: (install: String, run: (String) -> String) = {
                if exists("bun.lockb") || exists("bun.lock") { return ("bun install", { "bun run \($0)" }) }
                if exists("pnpm-lock.yaml") { return ("pnpm install", { "pnpm \($0)" }) }
                if exists("yarn.lock") { return ("yarn install", { "yarn \($0)" }) }
                return ("npm install", { "npm run \($0)" })
            }()
            for script in ["dev", "start", "serve", "preview", "develop"] {
                guard let body = scripts[script] else { continue }
                // `start` in a library is often `node dist/index.js`, not a server; still the
                // best guess, and the reason says which script it is so it can be checked.
                let caveat = exists("node_modules")
                    ? nil
                    : "Dependencies are not installed (no node_modules). Run `\(runner.install)` first, or start with `\(runner.install) && \(runner.run(script))`."
                return DevServerPlan(
                    kind: .command(runner.run(script)),
                    reason: "package.json script \"\(script)\": \(body)",
                    caveat: caveat
                )
            }
        }

        if exists("manage.py") {
            return DevServerPlan(kind: .command("python3 manage.py runserver"), reason: "Django project (manage.py)", caveat: nil)
        }
        if exists("bin/rails") {
            return DevServerPlan(kind: .command("bin/rails server"), reason: "Rails project (bin/rails)", caveat: nil)
        }
        if exists("config.ru") {
            return DevServerPlan(kind: .command("bundle exec rackup"), reason: "Rack application (config.ru)", caveat: nil)
        }
        if exists("hugo.toml") || exists("hugo.yaml") || (exists("config.toml") && exists("content")) {
            return DevServerPlan(kind: .command("hugo server"), reason: "Hugo site", caveat: nil)
        }
        if exists("_config.yml"), exists("Gemfile") {
            return DevServerPlan(kind: .command("bundle exec jekyll serve"), reason: "Jekyll site", caveat: nil)
        }

        for folder in ["", "public", "dist", "build", "docs", "site", "www"] {
            let entry = folder.isEmpty ? "index.html" : "\(folder)/index.html"
            if exists(entry) {
                let servedRoot = folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder)
                return DevServerPlan(
                    kind: .staticFiles(root: servedRoot, entry: "index.html"),
                    reason: "Static site (\(entry)), served by SwiftOpenWork",
                    caveat: nil
                )
            }
        }
        return nil
    }
}

// MARK: - Process trees

public enum ProcessTree {
    /// `(pid, parentPid)` pairs from `ps -A -o pid=,ppid=`.
    public static func parse(psOutput: String) -> [(pid: Int32, parent: Int32)] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, parent)
        }
    }

    /// Every descendant of `root`, deepest last. `npm run dev` is a shell running npm running
    /// node running esbuild; stopping only the shell leaves the server holding its port.
    public static func descendants(of root: Int32, in pairs: [(pid: Int32, parent: Int32)]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for pair in pairs { children[pair.parent, default: []].append(pair.pid) }
        var result: [Int32] = []
        var queue = children[root] ?? []
        var seen = Set<Int32>([root])
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}

// MARK: - What the preview may load

public enum PreviewURLPolicy {

    /// Whether the preview pane loads `url` itself, rather than handing it to the default browser.
    ///
    /// The pane is for looking at what you are building: loopback servers and files inside the
    /// workspace. Anything else — a docs link, an OAuth redirect — opens in the browser, where the
    /// person's own sessions and extensions are.
    public static func loadsInPane(_ url: URL, workspaceRoot: String?) -> Bool {
        switch url.scheme?.lowercased() {
        case "about", "blob", "data":
            return true
        case "file":
            guard let root = workspaceRoot else { return false }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let rootPath = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        case "http", "https", "ws", "wss":
            return isLoopback(host: url.host)
        default:
            return false
        }
    }

    public static func isLoopback(host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
            || host.hasSuffix(".localhost") || host.hasPrefix("127.")
    }

    /// Accept what a person types into the address field: `5173`, `localhost:3000/about`, a full URL.
    public static func normalize(typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let port = Int(trimmed), (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)/")
        }
        if trimmed.hasPrefix(":"), let port = Int(trimmed.dropFirst()), (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)/")
        }
        if trimmed.contains("://") { return URL(string: trimmed) }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return URL(string: "http://" + trimmed)
    }
}

// MARK: - What the page said

public struct PreviewConsoleEntry: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case log, info, debug, warn, error
        /// An uncaught exception or unhandled rejection.
        case exception
        /// A request that failed or returned an error status.
        case network
        /// A script, stylesheet or image that failed to load.
        case resource

        public var isProblem: Bool {
            switch self {
            case .error, .exception, .network, .resource: return true
            case .warn, .log, .info, .debug: return false
            }
        }
    }

    public let id: UUID
    public var level: Level
    public var message: String
    public var pageURL: String
    public var timestamp: Date

    public init(level: Level, message: String, pageURL: String = "", timestamp: Date = Date()) {
        self.id = UUID()
        self.level = level
        self.message = message
        self.pageURL = pageURL
        self.timestamp = timestamp
    }

    /// A workspace-relative source location named in the message — `http://localhost:5173/src/App.tsx:12:5`
    /// or `.../src/App.tsx?t=1712:12` — for jumping to it. Only paths that exist under `root`.
    public func sourceLocation(workspaceRoot root: String, fileManager: FileManager = .default) -> (path: String, line: Int)? {
        let pattern = #"https?://[^/\s]+/([^\s?:#)]+)(?:\?[^\s:)]*)?:(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        for match in regex.matches(in: message, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: message),
                  let lineRange = Range(match.range(at: 2), in: message),
                  let line = Int(message[lineRange]) else { continue }
            let relative = String(message[pathRange]).removingPercentEncoding ?? String(message[pathRange])
            // Vite serves sources under /@fs/ with an absolute path.
            let candidates = relative.hasPrefix("@fs/")
                ? ["/" + relative.dropFirst(4)]
                : [(root as NSString).appendingPathComponent(relative)]
            for candidate in candidates where fileManager.fileExists(atPath: candidate) {
                return (candidate, line)
            }
        }
        return nil
    }
}

/// The JavaScript injected into every page the preview loads, so console output, uncaught errors
/// and failed requests reach the app instead of disappearing into a web inspector nobody opened.
///
/// It forwards and then calls through, so the page behaves exactly as it would in a browser.
public enum PreviewInstrumentation {
    public static let messageHandlerName = "sowPreview"

    public static let script = #"""
    (function () {
      if (window.__sowPreview) { return; }
      window.__sowPreview = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sowPreview;
      if (!handler) { return; }
      function describe(value) {
        try {
          // WebKit's stack omits the message that V8's starts with, so both are always sent.
          if (value instanceof Error) { return value.name + ': ' + value.message + (value.stack ? '\n' + value.stack : ''); }
          if (typeof value === 'string') { return value; }
          if (value === undefined) { return 'undefined'; }
          if (typeof value === 'function') { return '[function ' + (value.name || 'anonymous') + ']'; }
          if (value instanceof Element) { return '<' + value.tagName.toLowerCase() + (value.id ? '#' + value.id : '') + '>'; }
          var seen = [];
          return JSON.stringify(value, function (k, v) {
            if (typeof v === 'object' && v !== null) { if (seen.indexOf(v) >= 0) { return '[circular]'; } seen.push(v); }
            return v;
          });
        } catch (e) { return String(value); }
      }
      function send(level, parts) {
        try {
          var message = Array.prototype.map.call(parts, describe).join(' ');
          if (message.length > 4000) { message = message.slice(0, 4000) + '…'; }
          handler.postMessage({ level: level, message: message, url: String(location.href) });
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () { send(level, arguments); return original.apply(console, arguments); };
      });
      window.addEventListener('error', function (event) {
        var target = event.target;
        if (target && target !== window && (target.src || target.href)) {
          send('resource', ['Failed to load ' + (target.src || target.href)]);
          return;
        }
        var where = event.filename ? ' (' + event.filename + ':' + event.lineno + ':' + event.colno + ')' : '';
        send('exception', [event.error ? event.error : (event.message + where)]);
      }, true);
      window.addEventListener('unhandledrejection', function (event) {
        send('exception', ['Unhandled promise rejection: ', event.reason]);
      });
      if (window.fetch) {
        var originalFetch = window.fetch;
        window.fetch = function (input, init) {
          var target = (typeof input === 'string') ? input : (input && input.url) || String(input);
          return originalFetch.apply(this, arguments).then(function (response) {
            if (!response.ok) { send('network', [response.status + ' ' + (response.statusText || '') + ' ' + (response.url || target)]); }
            return response;
          }, function (error) {
            send('network', ['fetch ' + target + ' failed: ', error]);
            throw error;
          });
        };
      }
      var open = XMLHttpRequest.prototype.open;
      var sendXHR = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__sowTarget = method + ' ' + url; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var request = this;
        request.addEventListener('loadend', function () {
          if (request.status === 0 || request.status >= 400) { send('network', [(request.status || 'failed') + ' ' + request.__sowTarget]); }
        });
        return sendXHR.apply(this, arguments);
      };
    })();
    """#
}

/// The text a preview tool hands back to the model.
public enum PreviewReport {

    public static func format(
        url: String,
        title: String?,
        httpStatus: Int?,
        loadError: String?,
        console: [PreviewConsoleEntry],
        visibleText: String?,
        serverSummary: String?,
        screenshotAttached: Bool
    ) -> String {
        var out = "Preview of \(url)\n"
        if let httpStatus { out += "HTTP status: \(httpStatus)\n" }
        if let title, !title.isEmpty { out += "Title: \(title)\n" }
        if let loadError { out += "\n**The page failed to load:** \(loadError)\n" }

        let problems = console.filter { $0.level.isProblem }
        let warnings = console.filter { $0.level == .warn }
        if problems.isEmpty && warnings.isEmpty && loadError == nil {
            out += "\nNo console errors, uncaught exceptions or failed requests.\n"
        }
        if !problems.isEmpty {
            out += "\nErrors (\(problems.count)):\n"
            for entry in problems.suffix(25) {
                out += "- [\(entry.level.rawValue)] \(entry.message.prefix(600))\n"
            }
        }
        if !warnings.isEmpty {
            out += "\nWarnings (\(warnings.count)):\n"
            for entry in warnings.suffix(10) {
                out += "- \(entry.message.prefix(300))\n"
            }
        }
        if let visibleText {
            let trimmed = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            out += trimmed.isEmpty
                ? "\nThe page rendered no visible text — it may be blank.\n"
                : "\nVisible text (start):\n\(trimmed.prefix(1_200))\n"
        }
        if let serverSummary { out += "\n\(serverSummary)\n" }
        if screenshotAttached {
            out += "\nA screenshot of the page is attached — look at it before concluding the page is right.\n"
        }
        return out
    }
}
