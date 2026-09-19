import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Real servers against throwaway projects. What these prove only exists with a real index: that
/// references mean *that* declaration, that a long-lived server keeps up with edits it did not
/// make, and that a killed server comes back and says so.
final class LanguageServerIntegrationTests: XCTestCase {

    private var root: String!
    private var pool: LanguageServerPool!

    override func setUpWithError() throws {
        root = LanguageServerCatalog.standardized(NSTemporaryDirectory()) + "/ow-lsp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        pool = LanguageServerPool()
    }

    override func tearDown() async throws {
        await pool.shutdownAll()
        await LanguageServerPool.shared.shutdown(under: root)
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func target(_ path: String, _ line: Int, _ symbol: String) -> CodeIntelligence.Target {
        CodeIntelligence.Target(path: path, line: line, symbol: symbol, column: nil)
    }

    // MARK: - sourcekit-lsp

    func testSourceKitAnswersEachQueryAndKeepsUpWithTheDisk() async throws {
        guard ExecutableLocator().locate(LanguageServerCatalog.sourceKit) != nil else {
            throw XCTSkip("sourcekit-lsp is not installed")
        }
        try write("Package.swift", """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Toy", targets: [.target(name: "Toy")])
        """)
        try write("Sources/Toy/Types.swift", """
        public struct Alpha {
            public init() {}
            public func value() -> Int { 1 }
        }
        public struct Beta {
            public init() {}
            public func value() -> Int { 2 }
        }
        """)
        try write("Sources/Toy/Use.swift", """
        let x = Alpha().value()
        let y = Beta().value()
        func total() -> Int { x + y }
        func report() -> Int { total() }
        """)

        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
        }
        let progress = Lines()
        let asked = Date()
        let definition = try await CodeIntelligence.definition(
            target("Sources/Toy/Use.swift", 1, "value"), workspaceRoot: root, pool: pool,
            onProgress: { line in progress.lock.withLock { progress.all.append(line) } }
        )
        XCTAssertTrue(definition.hasPrefix("[sourcekit-lsp]"), definition)
        let waited = Date().timeIntervalSince(asked)
        let reported = progress.lock.withLock { progress.all }
        // A wait longer than the reporter's 2s announcement delay must have said something. An
        // index that finishes sooner has nothing to report, which is what made this flaky.
        if waited > 3 {
            XCTAssertFalse(reported.isEmpty, "the first query waited \(Int(waited))s for indexing and said nothing")
        }
        XCTAssertTrue(reported.allSatisfy { $0.contains("sourcekit-lsp") }, "\(reported)")
        XCTAssertTrue(definition.contains("Sources/Toy/Types.swift:3:17: public func value() -> Int { 1 }"), definition)

        // Alpha.value: its declaration and one use. Beta.value is a different symbol.
        let references = try await CodeIntelligence.references(target("Sources/Toy/Use.swift", 1, "value"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(references.contains("2 references"), references)
        XCTAssertTrue(references.contains("Sources/Toy/Types.swift:3:17:"), references)
        XCTAssertTrue(references.contains("Sources/Toy/Use.swift:1:17:"), references)
        XCTAssertFalse(references.contains("Types.swift:7:"), "Beta.value must not be listed:\n\(references)")

        let info = try await CodeIntelligence.symbolInfo(target("Sources/Toy/Use.swift", 2, "value"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(info.contains("func value() -> Int"), info)
        XCTAssertTrue(info.contains("Sources/Toy/Types.swift:7:"), "declared on Beta:\n\(info)")

        let outline = try await CodeIntelligence.documentSymbols(path: "Sources/Toy/Types.swift", workspaceRoot: root, pool: pool)
        XCTAssertTrue(outline.contains("1: struct Alpha"), outline)
        XCTAssertTrue(outline.contains("  3: method value()"), outline)

        let callers = try await CodeIntelligence.callHierarchy(target("Sources/Toy/Use.swift", 3, "total"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(callers.contains("Sources/Toy/Use.swift:4:24: report()"), callers)

        let clean = try await CodeIntelligence.diagnostics(path: "Sources/Toy/Use.swift", workspaceRoot: root, pool: pool)
        XCTAssertTrue(clean.contains("No problems"), clean)

        // Edited behind the server's back, the way a shell command or another editor would.
        try write("Sources/Toy/Use.swift", """
        let x = Alpha().value()
        let y = Beta().value()
        func total() -> Int { x + y }
        func report() -> Int { total() }
        let broken: Int = "oops"
        """)
        let broken = try await CodeIntelligence.diagnostics(path: "Sources/Toy/Use.swift", workspaceRoot: root, pool: pool)
        XCTAssertTrue(broken.contains("Sources/Toy/Use.swift:5:19: error:"), broken)
        XCTAssertFalse(DiagnosticLinkParser.links(in: broken).isEmpty, "diagnostics are in the form the chat turns into links")

        // A new file the server has never opened reaches the index through file-system events.
        try write("Sources/Toy/More.swift", "let again = Alpha().value()\n")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let grown = try await CodeIntelligence.references(target("Sources/Toy/Types.swift", 3, "value"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(grown.contains("3 references"), grown)
        XCTAssertTrue(grown.contains("Sources/Toy/More.swift:1:21:"), grown)

        // Killed outright: the next question restarts it, says so, and still gets an answer.
        let lease = try await pool.session(for: root + "/Sources/Toy/Use.swift", workspaceRoot: root)
        let pid = try XCTUnwrap(lease.session.connection.processIdentifier)
        kill(pid, SIGKILL)
        for _ in 0..<50 where lease.session.isAlive {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(lease.session.isAlive)
        let afterCrash = try await CodeIntelligence.definition(target("Sources/Toy/Use.swift", 1, "value"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(afterCrash.contains("was restarted"), afterCrash)
        XCTAssertTrue(afterCrash.contains("Sources/Toy/Types.swift:3:17:"), afterCrash)
        let running = await pool.runningServers
        XCTAssertEqual(running.count, 1, "the dead server was replaced, not joined by a second")
    }

    /// `func scale(scale: Int)` names the symbol twice on the declaration line. The keyword picks
    /// the function, so the parameter and argument label are left alone.
    func testRenameStartsFromTheDeclaredNameWhenTheLineRepeatsIt() async throws {
        guard ExecutableLocator().locate(LanguageServerCatalog.sourceKit) != nil else {
            throw XCTSkip("sourcekit-lsp is not installed")
        }
        try write("Package.swift", """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Toy", targets: [.target(name: "Toy")])
        """)
        try write("Sources/Toy/Scale.swift", """
        public struct Ruler {
            public init() {}
            public func scale(scale: Int) -> Int { scale * 2 }
        }
        let doubled = Ruler().scale(scale: 3)
        """)

        let outcome = try await SymbolRename.rename(
            oldName: "scale", newName: "grow", root: root,
            pathHint: "Sources/Toy/Scale.swift", mode: .semantic, declarationLine: 3
        )
        XCTAssertEqual(outcome.method, "compiler")
        XCTAssertEqual(try String(contentsOfFile: root + "/Sources/Toy/Scale.swift", encoding: .utf8), """
        public struct Ruler {
            public init() {}
            public func grow(scale: Int) -> Int { scale * 2 }
        }
        let doubled = Ruler().grow(scale: 3)
        """)
    }

    // MARK: - Through the tool engine

    /// The path an agent takes: JSON arguments (with the line as a string, as local models send
    /// it), a workspace-relative path, the sandbox check, and the shared pool.
    func testAgentToolCallsReachTheServer() async throws {
        let clangd = LanguageServerCatalog.all.first { $0.id == "clangd" }!
        guard ExecutableLocator().locate(clangd) != nil else {
            throw XCTSkip("clangd is not installed")
        }
        try write("compile_flags.txt", "-std=c11\n")
        try write("src/math.c", """
        int add(int a, int b) { return a + b; }
        int twice(int a) { return add(a, a); }
        """)
        let workspace = Workspace(name: "LSP", folderPath: root)
        let agent = Agent(name: "Runner", role: "executor")
        func run(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
            let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
            return await ToolExecutionEngine.shared.execute(toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent)
        }

        let definition = await run("go_to_definition", ["path": "src/math.c", "line": "2", "symbol": "add"])
        XCTAssertTrue(definition.success, definition.error ?? "")
        XCTAssertTrue(definition.output.contains("src/math.c:1:5:"), definition.output)

        let outline = await run("document_symbols", ["path": "src/math.c"])
        XCTAssertTrue(outline.output.contains("1: function add"), outline.output)

        let missing = await run("find_references", ["path": "src/math.c", "line": 2])
        XCTAssertFalse(missing.success)
        XCTAssertTrue(missing.error?.contains("symbol") ?? false, missing.error ?? "")

        let unsupported = await run("symbol_info", ["path": "notes.txt", "line": 1, "symbol": "x"])
        XCTAssertFalse(unsupported.success)
        XCTAssertTrue(unsupported.error?.contains("No language server handles .txt") ?? false, unsupported.error ?? "")
    }

    /// An edit reports what a warm server makes of it, so the model sees its own error at once.
    func testEditsCarryErrorsFromAServerThatIsAlreadyRunning() async throws {
        guard ExecutableLocator().locate(LanguageServerCatalog.sourceKit) != nil else {
            throw XCTSkip("sourcekit-lsp is not installed")
        }
        try write("Package.swift", """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Toy", targets: [.target(name: "Toy")])
        """)
        try write("Sources/Toy/Math.swift", "func double(_ x: Int) -> Int { x * 2 }\nlet four = double(2)\n")
        let workspace = Workspace(name: "LSP", folderPath: root)
        let agent = Agent(name: "Runner", role: "executor")
        func run(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
            let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
            return await ToolExecutionEngine.shared.execute(toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent)
        }

        // Nothing running for this root yet: the edit reports only itself and does not wait.
        let cold = await run("edit_file", ["path": "Sources/Toy/Math.swift", "old_string": "double(2)", "new_string": "double(3)"])
        XCTAssertTrue(cold.success, cold.error ?? "")
        XCTAssertFalse(cold.output.contains("sourcekit-lsp"), cold.output)

        // Warm the server the way an agent would, then break the file.
        let warm = await run("code_diagnostics", ["path": "Sources/Toy/Math.swift"])
        XCTAssertTrue(warm.success, warm.error ?? "")
        let broken = await run("edit_file", ["path": "Sources/Toy/Math.swift", "old_string": "double(3)", "new_string": "double(\"three\")"])
        XCTAssertTrue(broken.success, broken.error ?? "")
        XCTAssertTrue(broken.output.contains("sourcekit-lsp reports 1 error in Sources/Toy/Math.swift"), broken.output)
        XCTAssertTrue(broken.output.contains("Sources/Toy/Math.swift:2:19: error:"), broken.output)

        let fixed = await run("edit_file", ["path": "Sources/Toy/Math.swift", "old_string": "double(\"three\")", "new_string": "double(3)"])
        XCTAssertTrue(fixed.output.contains("sourcekit-lsp reports no errors in Sources/Toy/Math.swift."), fixed.output)
    }

    // MARK: - Other servers

    private func resolvable(_ file: String) -> Bool {
        if case .success = LanguageServerCatalog.resolve(file: root + "/" + file, workspaceRoot: root) { return true }
        return false
    }

    /// Runs when TypeScript 7+ (`tsc --lsp`) or typescript-language-server is on the search path.
    func testTypeScriptAnswersThroughTheGenericPath() async throws {
        try write("tsconfig.json", #"{"compilerOptions":{"strict":true,"target":"es2022","module":"esnext"},"include":["src"]}"#)
        try write("src/math.ts", "export function add(a: number, b: number): number { return a + b; }\n")
        try write("src/use.ts", """
        import { add } from "./math";
        export const three = add(1, 2);
        export const broken: number = "oops";
        """)
        guard resolvable("src/use.ts") else { throw XCTSkip("no TypeScript language server is installed") }

        let definition = try await CodeIntelligence.definition(target("src/use.ts", 2, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(definition.contains("src/math.ts:1:17:"), definition)
        let references = try await CodeIntelligence.references(target("src/math.ts", 1, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(references.contains("src/use.ts:2:22:"), references)
        let info = try await CodeIntelligence.symbolInfo(target("src/use.ts", 2, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(info.contains("add(a: number, b: number): number"), info)
        let diagnostics = try await CodeIntelligence.diagnostics(path: "src/use.ts", workspaceRoot: root, pool: pool)
        XCTAssertTrue(diagnostics.contains("src/use.ts:3:14: error:"), diagnostics)
    }

    /// Runs when pyright or basedpyright is on the search path.
    func testPyrightAnswersThroughTheGenericPath() async throws {
        try write("pyproject.toml", "[project]\nname = \"demo\"\nversion = \"0.1\"\n")
        try write("pkg/__init__.py", "")
        try write("pkg/math.py", "def add(a: int, b: int) -> int:\n    return a + b\n")
        try write("pkg/use.py", """
        from pkg.math import add

        three = add(1, 2)
        broken: int = "oops"
        """)
        guard resolvable("pkg/use.py") else { throw XCTSkip("pyright is not installed") }

        let definition = try await CodeIntelligence.definition(target("pkg/use.py", 3, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(definition.contains("pkg/math.py:1:5:"), definition)
        let references = try await CodeIntelligence.references(target("pkg/math.py", 1, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(references.contains("pkg/use.py:3:9:"), references)
        let diagnostics = try await CodeIntelligence.diagnostics(path: "pkg/use.py", workspaceRoot: root, pool: pool)
        XCTAssertTrue(diagnostics.contains("pkg/use.py:4:15: error:"), diagnostics)
    }

    /// Runs when rust-analyzer and cargo are installed.
    func testRustAnalyzerAnswersThroughTheGenericPath() async throws {
        try write("Cargo.toml", "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
        try write("src/math.rs", "pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n")
        try write("src/main.rs", """
        mod math;

        fn main() {
            let three = math::add(1, 2);
            let broken: i32 = "oops";
            println!("{three} {broken}");
        }
        """)
        guard resolvable("src/main.rs") else { throw XCTSkip("rust-analyzer is not installed") }

        let definition = try await CodeIntelligence.definition(target("src/main.rs", 4, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(definition.hasPrefix("[rust-analyzer]"), definition)
        XCTAssertTrue(definition.contains("src/math.rs:1:8:"), definition)
        let references = try await CodeIntelligence.references(target("src/math.rs", 1, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(references.contains("src/main.rs:4:23:"), references)
        let diagnostics = try await CodeIntelligence.diagnostics(path: "src/main.rs", workspaceRoot: root, pool: pool)
        XCTAssertTrue(diagnostics.contains("src/main.rs:5:23: error:"), diagnostics)
    }

    /// Runs when gopls and go are installed.
    func testGoplsAnswersThroughTheGenericPath() async throws {
        try write("go.mod", "module example.com/demo\n\ngo 1.21\n")
        try write("math.go", "package main\n\nfunc add(a, b int) int {\n\treturn a + b\n}\n")
        try write("main.go", """
        package main

        import "fmt"

        func main() {
        \tthree := add(1, 2)
        \tvar broken int = "oops"
        \tfmt.Println(three, broken)
        }
        """)
        guard resolvable("main.go") else { throw XCTSkip("gopls is not installed") }

        let definition = try await CodeIntelligence.definition(target("main.go", 6, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(definition.hasPrefix("[gopls]"), definition)
        XCTAssertTrue(definition.contains("math.go:3:6:"), definition)
        let references = try await CodeIntelligence.references(target("math.go", 3, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(references.contains("main.go:6:11:"), references)
        let diagnostics = try await CodeIntelligence.diagnostics(path: "main.go", workspaceRoot: root, pool: pool)
        XCTAssertTrue(diagnostics.contains("main.go:7:19: error:"), diagnostics)
    }

    // MARK: - A second server

    /// clangd has no `workspace/synchronize` and no pull diagnostics, so this is the generic path:
    /// progress-based readiness and published diagnostics.
    func testClangdAnswersThroughTheGenericPath() async throws {
        let clangd = LanguageServerCatalog.all.first { $0.id == "clangd" }!
        guard ExecutableLocator().locate(clangd) != nil else {
            throw XCTSkip("clangd is not installed")
        }
        try write("compile_flags.txt", "-std=c11\n")
        // The error sits on its own line: clang drops an expression it cannot type, so `add`
        // inside `add(1, 2) + missing` would have no definition to find.
        try write("main.c", """
        int add(int a, int b) { return a + b; }
        int main(void) { return add(1, 2); }
        int broken(void) { return missing; }
        """)

        let definition = try await CodeIntelligence.definition(target("main.c", 2, "add"), workspaceRoot: root, pool: pool)
        XCTAssertTrue(definition.hasPrefix("[clangd]"), definition)
        XCTAssertTrue(definition.contains("main.c:1:5: int add(int a, int b)"), definition)

        let diagnostics = try await CodeIntelligence.diagnostics(path: "main.c", workspaceRoot: root, pool: pool)
        XCTAssertTrue(diagnostics.contains("main.c:3:27: error:"), diagnostics)
        XCTAssertTrue(diagnostics.contains("missing"), diagnostics)
    }
}
