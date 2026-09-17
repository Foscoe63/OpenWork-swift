import XCTest
@testable import SwiftOpenWork

/// Dev servers announce themselves in many shapes. These are copied from real output.
final class DevServerURLDetectorTests: XCTestCase {

    func testRealServerBanners() {
        let cases: [(String, String)] = [
            ("  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m", "http://localhost:5173/"),
            ("   - Local:        http://localhost:3000", "http://localhost:3000"),
            ("Serving HTTP on :: port 8000 (http://[::]:8000/) ...", "http://localhost:8000/"),
            ("* Listening on http://127.0.0.1:3000", "http://127.0.0.1:3000"),
            ("Server running at http://0.0.0.0:4321/.", "http://localhost:4321/"),
            ("  Local:            http://localhost:3000/app", "http://localhost:3000/app"),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(DevServerURLDetector.detect(in: line)?.absoluteString, expected, line)
        }
    }

    /// A LAN address is the same server under another name; a docs link is not the server.
    func testNonLoopbackURLsAreIgnored() {
        XCTAssertNil(DevServerURLDetector.detect(in: "  ➜  Network: http://192.168.1.20:5173/"))
        XCTAssertNil(DevServerURLDetector.detect(in: "Docs: https://vitejs.dev/guide/"))
    }

    func testPortsNamedInProse() {
        XCTAssertEqual(DevServerURLDetector.detectPort(in: "Express server listening on port 8080"), 8080)
        XCTAssertEqual(DevServerURLDetector.detectPort(in: "App running at port: 4000"), 4000)
        XCTAssertNil(DevServerURLDetector.detectPort(in: "Imported 3000 records"))
    }

    func testANSIIsStripped() {
        XCTAssertEqual(ANSI.strip("\u{1B}[31mred\u{1B}[0m plain \u{1B}]8;;http://x\u{07}"), "red plain ")
        XCTAssertEqual(ANSI.strip("nothing to do"), "nothing to do")
    }
}

final class DevServerCommandDetectorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ name: String, _ content: String = "") throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testPackageScriptsPreferDevAndTheRightPackageManager() throws {
        try touch("package.json", #"{"scripts":{"start":"node server.js","dev":"vite"}}"#)
        try touch("pnpm-lock.yaml")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        let plan = try XCTUnwrap(DevServerCommandDetector.plan(root: root.path))
        XCTAssertEqual(plan.command, "pnpm dev")
        XCTAssertTrue(plan.reason.contains("vite"))
        XCTAssertNil(plan.caveat)
    }

    func testMissingDependenciesAreCalledOut() throws {
        try touch("package.json", #"{"scripts":{"dev":"next dev"}}"#)
        let plan = try XCTUnwrap(DevServerCommandDetector.plan(root: root.path))
        XCTAssertEqual(plan.command, "npm run dev")
        XCTAssertTrue(plan.caveat?.contains("npm install") == true)
    }

    func testStaticSitesNeedNoToolchain() throws {
        try touch("docs/index.html", "<h1>hi</h1>")
        let plan = try XCTUnwrap(DevServerCommandDetector.plan(root: root.path))
        XCTAssertEqual(plan.kind, .staticFiles(root: root.appendingPathComponent("docs").path, entry: "index.html"))
        XCTAssertNil(plan.command)
    }

    func testFrameworks() throws {
        try touch("manage.py")
        XCTAssertEqual(DevServerCommandDetector.plan(root: root.path)?.command, "python3 manage.py runserver")
    }

    func testNothingRecognisable() {
        XCTAssertNil(DevServerCommandDetector.plan(root: root.path))
    }
}

final class PreviewPolicyAndParsingTests: XCTestCase {

    func testOnlyLoopbackAndWorkspaceFilesLoadInThePane() {
        let root = "/Users/me/Project"
        XCTAssertTrue(PreviewURLPolicy.loadsInPane(URL(string: "http://localhost:5173/x")!, workspaceRoot: root))
        XCTAssertTrue(PreviewURLPolicy.loadsInPane(URL(string: "http://127.0.0.1:8000")!, workspaceRoot: root))
        XCTAssertTrue(PreviewURLPolicy.loadsInPane(URL(string: "http://app.localhost:3000")!, workspaceRoot: root))
        XCTAssertTrue(PreviewURLPolicy.loadsInPane(URL(string: "ws://localhost:24678")!, workspaceRoot: root))
        XCTAssertTrue(PreviewURLPolicy.loadsInPane(URL(fileURLWithPath: "/Users/me/Project/index.html"), workspaceRoot: root))
        XCTAssertFalse(PreviewURLPolicy.loadsInPane(URL(fileURLWithPath: "/Users/me/ProjectOther/index.html"), workspaceRoot: root))
        XCTAssertFalse(PreviewURLPolicy.loadsInPane(URL(fileURLWithPath: "/etc/hosts"), workspaceRoot: root))
        XCTAssertFalse(PreviewURLPolicy.loadsInPane(URL(string: "https://example.com")!, workspaceRoot: root))
        XCTAssertFalse(PreviewURLPolicy.loadsInPane(URL(string: "http://localhost.evil.com")!, workspaceRoot: root))
    }

    func testTypedAddresses() {
        XCTAssertEqual(PreviewURLPolicy.normalize(typed: "5173")?.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(PreviewURLPolicy.normalize(typed: ":3000")?.absoluteString, "http://localhost:3000/")
        XCTAssertEqual(PreviewURLPolicy.normalize(typed: "localhost:3000/about")?.absoluteString, "http://localhost:3000/about")
        XCTAssertEqual(PreviewURLPolicy.normalize(typed: "http://127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertNil(PreviewURLPolicy.normalize(typed: "   "))
    }

    func testProcessTreeFindsGrandchildren() {
        let ps = """
          100     1
          200   100
          300   200
          301   200
          400     1
        """
        let pairs = ProcessTree.parse(psOutput: ps)
        XCTAssertEqual(Set(ProcessTree.descendants(of: 100, in: pairs)), [200, 300, 301])
        XCTAssertTrue(ProcessTree.descendants(of: 400, in: pairs).isEmpty)
    }

    func testListeningPortsFromLsof() {
        let output = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        node    41234  me   23u  IPv6 0x1      0t0  TCP [::1]:5173 (LISTEN)
        node    41234  me   24u  IPv4 0x2      0t0  TCP 127.0.0.1:24678 (LISTEN)
        node    41234  me   25u  IPv4 0x3      0t0  TCP 127.0.0.1:5173 (LISTEN)
        """
        XCTAssertEqual(DevServerManager.parseListeningPorts(lsofOutput: output), [5173, 24678])
    }

    func testLoginShellPathExtraction() {
        XCTAssertEqual(
            DevServerManager.extractMarkedPath("Last login: today\n__SOW_PATH__/Users/me/.nvm/bin:/usr/bin__SOW_END__"),
            "/Users/me/.nvm/bin:/usr/bin"
        )
        XCTAssertNil(DevServerManager.extractMarkedPath("zsh: no such file"))
        XCTAssertEqual(DevServerManager.mergePaths(primary: "/a:/b", secondary: "/b:/c"), "/a:/b:/c")
    }

    func testConsoleEntriesLinkToWorkspaceSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("console-\(UUID().uuidString)")
        let file = root.appendingPathComponent("src/App.tsx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = PreviewConsoleEntry(
            level: .exception,
            message: "TypeError: undefined is not an object\n    at App (http://localhost:5173/src/App.tsx?t=1712:12:5)"
        )
        let location = try XCTUnwrap(entry.sourceLocation(workspaceRoot: root.path))
        XCTAssertEqual(location.path, file.path)
        XCTAssertEqual(location.line, 12)
        XCTAssertNil(PreviewConsoleEntry(level: .error, message: "at http://localhost:5173/node_modules/x.js:1:1")
            .sourceLocation(workspaceRoot: root.path))
    }

    func testReportLeadsWithWhatWentWrong() {
        let report = PreviewReport.format(
            url: "http://localhost:5173/",
            title: "App",
            httpStatus: 200,
            loadError: nil,
            console: [
                PreviewConsoleEntry(level: .log, message: "ready"),
                PreviewConsoleEntry(level: .exception, message: "ReferenceError: foo is not defined"),
                PreviewConsoleEntry(level: .network, message: "404 Not Found http://localhost:5173/api/items"),
            ],
            visibleText: "",
            serverSummary: nil,
            screenshotAttached: true
        )
        XCTAssertTrue(report.contains("Errors (2)"))
        XCTAssertTrue(report.contains("ReferenceError"))
        XCTAssertTrue(report.contains("404 Not Found"))
        XCTAssertTrue(report.contains("may be blank"))
        XCTAssertTrue(report.contains("screenshot"))
        XCTAssertFalse(report.contains("ready"), "plain logs are not problems")

        let clean = PreviewReport.format(url: "u", title: nil, httpStatus: 200, loadError: nil, console: [], visibleText: "Hello", serverSummary: nil, screenshotAttached: false)
        XCTAssertTrue(clean.contains("No console errors"))
    }
}

@MainActor
final class PreviewToolWiringTests: XCTestCase {

    func testToolsAreOfferedWithRealSchemas() throws {
        var tools: [Tool] = []
        _ = ToolSchemaCatalog.ensureParityTools(in: &tools)
        for name in PreviewTools.names {
            XCTAssertTrue(tools.contains { $0.name == name }, "\(name) missing")
            let schema = try JSONSerialization.jsonObject(with: Data(ToolSchemaCatalog.schemaJSON(for: name).utf8)) as? [String: Any]
            XCTAssertNotNil(schema?["properties"], "\(name) schema does not parse")
        }
    }

    /// Starting a server is a side effect; looking at the page is not.
    func testPlanModeKeepsChecksAndBlocksStarts() {
        let tools = PreviewTools.names.map { Tool(id: $0, name: $0, displayName: $0, description: "", category: .system, parametersJsonSchema: "{}") }
            + ["run_app", "git_commit"].map { Tool(id: $0, name: $0, displayName: $0, description: "", category: .system, parametersJsonSchema: "{}") }
        let names = Set(AgentRunner.filterToolsForPlanMode(tools).map(\.name))
        XCTAssertTrue(names.contains("preview_check"))
        XCTAssertTrue(names.contains("preview_logs"))
        XCTAssertFalse(names.contains("preview_start"))
        XCTAssertFalse(names.contains("run_app"))
        XCTAssertFalse(names.contains("git_commit"))
    }

    func testApprovals() {
        let settings = AppSettings()
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "preview_start", argumentsJson: #"{"command":"npm run dev"}"#, settings: settings))
        XCTAssertTrue(AgentRunner.approvalReason(toolName: "preview_start", argumentsJson: #"{"command":"npm run dev"}"#, settings: settings)?.contains("npm run dev") == true)
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "preview_start", argumentsJson: "{}", settings: settings))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "preview_start", argumentsJson: #"{"url":"3000"}"#, settings: settings),
                     "opening a server that is already running runs nothing")
        XCTAssertNil(AgentRunner.approvalReason(toolName: "preview_check", settings: settings))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "preview_stop", settings: settings))
        // These carried requiresApproval in the catalog, which nothing read.
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "run_app", settings: settings))
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "git_commit", settings: settings))
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "worktree_remove", settings: settings))
    }

    /// Every built-in tool the catalog marks as needing approval must actually be asked about.
    func testEveryCatalogApprovalFlagIsEnforced() {
        let settings = AppSettings()
        for tool in ToolSchemaCatalog.parityDefaults where tool.requiresApproval {
            let arguments = tool.name == "preview_start" ? #"{"command":"x"}"# : "{}"
            XCTAssertNotNil(
                AgentRunner.approvalReason(toolName: tool.name, argumentsJson: arguments, settings: settings),
                "\(tool.name) is marked requiresApproval but runs without asking"
            )
        }
    }
}

/// The built-in static server is reachable from a browser and from nothing outside the folder.
final class StaticFileServerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("static-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "<h1>Home</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<h1>About</h1>".write(to: root.appendingPathComponent("about.html"), atomically: true, encoding: .utf8)
        try "<h1>Docs</h1>".write(to: root.appendingPathComponent("docs/index.html"), atomically: true, encoding: .utf8)
        try "{\"ok\":true}".write(to: root.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testResolution() {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/", root: root), .file(resolvedRoot.appendingPathComponent("index.html")))
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/about", root: root), .file(resolvedRoot.appendingPathComponent("about.html")))
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/docs", root: root), .redirect("/docs/"))
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/docs/?x=1#y", root: root), .file(resolvedRoot.appendingPathComponent("docs/index.html")))
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/missing.css", root: root), .notFound("/missing.css"))
    }

    func testTraversalIsRefused() throws {
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/../etc/passwd", root: root), .forbidden)
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/%2e%2e/%2e%2e/etc/passwd", root: root), .forbidden)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertEqual(StaticFileServer.resolve(requestTarget: "/escape/hosts", root: root), .forbidden)
    }

    func testItServesOverHTTP() async throws {
        let server = StaticFileServer(root: root)
        let base = try await server.start()
        defer { server.stop() }

        let (home, homeResponse) = try await URLSession.shared.data(from: base)
        XCTAssertEqual((homeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: home, as: UTF8.self), "<h1>Home</h1>")
        XCTAssertEqual((homeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")

        let (_, json) = try await URLSession.shared.data(from: base.appendingPathComponent("data.json"))
        XCTAssertEqual((json as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("nope.js"))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }
}

/// A real server, started, found, reached and stopped — including the processes it spawned.
@MainActor
final class DevServerLifecycleTests: XCTestCase {

    func testStartDetectReachAndStopARealServer() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python),
              DevServerManager.runQuick(python, ["--version"], timeout: 5)?.contains("Python 3") == true else {
            throw XCTSkip("python3 is not usable here")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<title>Live</title><p>served</p>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let port = Int.random(in: 20_000...40_000)
        let manager = DevServerManager()
        var settings = AppSettings()
        settings.terminalShell = "/bin/zsh"
        // `exec` is deliberately absent: the server runs as a child of the shell, as `npm run dev`
        // does, so stopping has to reach past the process it launched.
        let server = await manager.start(
            command: "\(python) -u -m http.server \(port) --bind 127.0.0.1; echo done",
            in: root.path,
            settings: settings
        )
        let failure = await manager.waitUntilReady(server, timeout: 30)
        XCTAssertNil(failure, server.logTail(40))
        XCTAssertEqual(server.status, .running)
        XCTAssertEqual(server.url?.port, port)

        let (body, _) = try await URLSession.shared.data(from: try XCTUnwrap(server.url))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("served"))

        // Starting the same command again reuses the server.
        let again = await manager.start(command: server.command, in: root.path, settings: settings)
        XCTAssertTrue(again === server)

        let shellPid = try XCTUnwrap(server.pid)
        let children = DevServerManager.processTree(of: shellPid)
        XCTAssertFalse(children.isEmpty, "the server should be a child of the shell")
        manager.stop(server)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        for pid in [shellPid] + children {
            XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) survived stop")
        }
        let stillServing = await DevServerManager.responds(try XCTUnwrap(server.url))
        XCTAssertFalse(stillServing, "the port must be released")
        XCTAssertEqual(server.status, .stopped)
    }

    /// The common case: `npm run dev` from package.json, found by detection, where npm starts a
    /// shell that starts node — three processes deep, all of which must stop.
    func testNpmDevScriptEndToEnd() async throws {
        guard DevServerManager.runQuick("/bin/zsh", ["-lc", "command -v npm"], timeout: 10)?.contains("npm") == true else {
            throw XCTSkip("npm is not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("npm-dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let port = Int.random(in: 40_001...44_000)
        try #"{"name":"t","private":true,"scripts":{"dev":"node server.js"}}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try """
        const http = require('http');
        http.createServer((req, res) => { res.setHeader('content-type', 'text/html'); res.end('<h1>node ok</h1>'); })
          .listen(\(port), '127.0.0.1', () => console.log('  ➜  Local:   http://localhost:\(port)/'));
        """.write(to: root.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)

        let plan = try XCTUnwrap(DevServerCommandDetector.plan(root: root.path))
        XCTAssertEqual(plan.command, "npm run dev")

        let manager = DevServerManager()
        var settings = AppSettings()
        settings.terminalShell = "/bin/zsh"
        let server = await manager.start(command: try XCTUnwrap(plan.command), in: root.path, settings: settings)
        let failure = await manager.waitUntilReady(server, timeout: 60)
        XCTAssertNil(failure, server.logTail(40))
        XCTAssertEqual(server.url?.absoluteString, "http://localhost:\(port)/")

        let shellPid = try XCTUnwrap(server.pid)
        let tree = DevServerManager.processTree(of: shellPid)
        XCTAssertGreaterThanOrEqual(tree.count, 1, server.logTail(20))
        manager.stop(server)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        for pid in [shellPid] + tree {
            XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) survived stop")
        }
        let stillServing = await DevServerManager.responds(try XCTUnwrap(server.url))
        XCTAssertFalse(stillServing, "node must not keep the port")
    }

    func testAServerThatDiesIsReportedWithItsOutput() async throws {
        let manager = DevServerManager()
        var settings = AppSettings()
        settings.terminalShell = "/bin/zsh"
        let server = await manager.start(command: "echo 'Error: Cannot find module vite'; exit 3", in: NSTemporaryDirectory(), settings: settings)
        let failure = await manager.waitUntilReady(server, timeout: 15)
        XCTAssertEqual(failure, "The server exited with code 3 before it was reachable.")
        XCTAssertTrue(server.logTail(10).contains("Cannot find module vite"))
    }
}

/// The whole point: a page that compiles and still fails must be reported as failing, with a
/// picture. This loads a real page in a real web view.
@MainActor
final class PreviewCheckLiveTests: XCTestCase {

    func testACheckReportsErrorsFailedRequestsTextAndAScreenshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        <!doctype html>
        <html><head><title>Broken Shop</title>
        <style>body { background: #1d4ed8; color: white; font: 32px -apple-system; }</style>
        <script src="/missing.js"></script>
        </head>
        <body>
        <h1>Welcome to the shop</h1>
        <script>
          console.log('booting');
          console.warn('deprecated prop');
          fetch('/api/items').then(r => r.json()).catch(() => {});
          setTimeout(() => { undefinedFunctionCall(); }, 50);
        </script>
        </body></html>
        """.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let server = StaticFileServer(root: root)
        let url = try await server.start()
        defer { server.stop() }

        let preview = PreviewController()
        preview.workspaceRoot = root.path
        let shots = root.appendingPathComponent("shots")
        let result = await preview.check(url: url, reload: false, settleSeconds: 1.0, viewportWidth: 800, screenshotDirectory: shots)

        XCTAssertNil(result.loadError)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertEqual(result.title, "Broken Shop")
        XCTAssertTrue(result.visibleText?.contains("Welcome to the shop") == true, result.visibleText ?? "nil")

        let messages = result.console.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
        XCTAssertTrue(result.console.contains { $0.level == .exception && $0.message.contains("undefinedFunctionCall") }, messages)
        XCTAssertTrue(result.console.contains { $0.level == .network && $0.message.contains("404") && $0.message.contains("/api/items") }, messages)
        XCTAssertTrue(result.console.contains { $0.level == .resource && $0.message.contains("missing.js") }, messages)
        XCTAssertTrue(result.console.contains { $0.level == .warn && $0.message.contains("deprecated prop") }, messages)

        let path = try XCTUnwrap(result.screenshotPath, "no screenshot")
        let image = try XCTUnwrap(NSImage(contentsOfFile: path))
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertGreaterThan(bitmap.pixelsWide, 300)
        // The page is blue. A blank or white capture would mean the offscreen host did not render.
        let sample = try XCTUnwrap(bitmap.colorAt(x: 10, y: bitmap.pixelsHigh - 10)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(sample.blueComponent, 0.6, "screenshot is not the rendered page: \(sample)")
        XCTAssertLessThan(sample.redComponent, 0.4, "screenshot is not the rendered page: \(sample)")

        let report = PreviewReport.format(url: result.url, title: result.title, httpStatus: result.httpStatus, loadError: result.loadError, console: result.console, visibleText: result.visibleText, serverSummary: nil, screenshotAttached: true)
        XCTAssertTrue(report.contains("undefinedFunctionCall"))
    }

    func testAServerThatIsNotRunningIsAPlainFailure() async throws {
        let preview = PreviewController()
        let port = Int.random(in: 45_000...50_000)
        let result = await preview.check(url: URL(string: "http://127.0.0.1:\(port)/")!, reload: false, settleSeconds: 0, viewportWidth: nil, screenshotDirectory: nil)
        XCTAssertNotNil(result.loadError)
        XCTAssertTrue(result.loadError?.contains("server running") == true || result.loadError?.isEmpty == false, result.loadError ?? "")
    }
}

/// Several previews at once: each tab its own page, console and server.
@MainActor
final class PreviewSessionsTests: XCTestCase {

    func testThereIsAlwaysATab() {
        let sessions = PreviewSessions()
        XCTAssertEqual(sessions.tabs.count, 1)
        let only = sessions.active
        sessions.close(only.id)
        XCTAssertEqual(sessions.tabs.count, 1, "closing the last tab leaves an empty one")
        XCTAssertFalse(sessions.active === only)
    }

    func testNewTabsActivateAndSplitShowsTheOtherTab() {
        let sessions = PreviewSessions()
        let first = sessions.active
        XCTAssertNil(sessions.secondary, "one tab, nothing beside it")
        sessions.layout = .sideBySide
        let second = sessions.newTab()
        XCTAssertTrue(sessions.active === second)
        XCTAssertTrue(sessions.secondary === first, "the previously active tab stays in view")
        sessions.activate(first.id)
        XCTAssertTrue(sessions.secondary === second, "activating the secondary swaps the two")
        sessions.layout = .single
        XCTAssertNil(sessions.secondary)
    }

    func testTabCountIsCappedWithoutClosingWhatIsOnScreen() {
        let sessions = PreviewSessions()
        sessions.layout = .stacked
        for _ in 0..<(PreviewSessions.maxTabs + 3) { sessions.newTab() }
        XCTAssertEqual(sessions.tabs.count, PreviewSessions.maxTabs)
        XCTAssertNotNil(sessions.tabs.first { $0.id == sessions.activeId })
        XCTAssertNotNil(sessions.secondary)
    }

    func testFindingTabsByNumberTitleOrURL() {
        let sessions = PreviewSessions()
        let first = sessions.active
        first.load(URL(string: "http://localhost:5173/")!)
        let second = sessions.newTab()
        second.load(URL(string: "http://localhost:8080/admin")!)
        XCTAssertTrue(sessions.find("2") === second)
        XCTAssertTrue(sessions.find("5173") === first)
        XCTAssertTrue(sessions.find("admin") === second)
        XCTAssertNil(sessions.find("9"))
        XCTAssertTrue(sessions.find(nil) === second, "no reference means the active tab")
        XCTAssertEqual(sessions.number(of: first), 1)
    }

    func testDuplicateOpensTheSamePageInANewTab() {
        let sessions = PreviewSessions()
        let original = sessions.active
        original.load(URL(string: "http://localhost:3000/page")!)
        let copy = sessions.duplicate(original.id)
        XCTAssertEqual(sessions.tabs.count, 2)
        XCTAssertEqual(copy?.currentURL, original.currentURL)
        XCTAssertTrue(sessions.active === copy)
    }

    /// Two servers, two tabs; each tab reports only its own page's errors.
    func testTwoServersGetTwoTabsWithSeparateConsoles() async throws {
        func site(_ title: String, script: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "<title>\(title)</title><body>\(title)<script>\(script)</script></body>"
                .write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            return root
        }
        let shop = try site("Shop", script: "console.error('shop is broken')")
        let admin = try site("Admin", script: "console.log('admin fine')")
        defer {
            try? FileManager.default.removeItem(at: shop)
            try? FileManager.default.removeItem(at: admin)
        }

        let sessions = PreviewSessions()
        let settings = AppSettings()
        let first = await PreviewLauncher.start(
            plan: DevServerPlan(kind: .staticFiles(root: shop.path, entry: "index.html"), reason: "t", caveat: nil),
            workspaceRoot: shop.path, settings: settings, sessions: sessions
        )
        let second = await PreviewLauncher.start(
            plan: DevServerPlan(kind: .staticFiles(root: admin.path, entry: "index.html"), reason: "t", caveat: nil),
            workspaceRoot: admin.path, settings: settings, sessions: sessions
        )
        defer {
            if let server = first.server { DevServerManager.shared.remove(server) }
            if let server = second.server { DevServerManager.shared.remove(server) }
        }
        XCTAssertNil(first.failure)
        XCTAssertNil(second.failure)
        let shopTab = try XCTUnwrap(first.tab)
        let adminTab = try XCTUnwrap(second.tab)
        XCTAssertFalse(shopTab === adminTab, "a second live server must not replace the first one's page")
        XCTAssertEqual(sessions.tabs.count, 2)

        let shopResult = await shopTab.check(url: nil, reload: true, settleSeconds: 0.5, viewportWidth: nil, screenshotDirectory: nil)
        let adminResult = await adminTab.check(url: nil, reload: true, settleSeconds: 0.5, viewportWidth: 390, screenshotDirectory: nil)
        XCTAssertEqual(shopResult.title, "Shop")
        XCTAssertEqual(adminResult.title, "Admin")
        XCTAssertTrue(shopResult.console.contains { $0.message.contains("shop is broken") })
        XCTAssertFalse(adminResult.console.contains { $0.message.contains("shop is broken") }, "consoles must not leak between tabs")
        XCTAssertEqual(adminTab.viewportWidth, 390)
        XCTAssertNil(shopTab.viewportWidth, "viewport width is per tab")

        // Restarting the shop server's preview reuses the shop's tab.
        let again = await PreviewLauncher.start(
            plan: DevServerPlan(kind: .staticFiles(root: shop.path, entry: "index.html"), reason: "t", caveat: nil),
            workspaceRoot: shop.path, settings: settings, sessions: sessions
        )
        XCTAssertTrue(again.tab === shopTab)
        XCTAssertEqual(sessions.tabs.count, 2)
    }
}
