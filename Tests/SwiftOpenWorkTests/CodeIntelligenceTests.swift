import CoreServices
import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

/// The parts of the language-server layer that need no server: which server and root a file gets,
/// where a symbol on a line is, and how answers are parsed and printed.
final class CodeIntelligenceTests: XCTestCase {

    // MARK: - Choosing a server

    private func locator(files: Set<String>, executables: Set<String> = [], environment: [String: String] = ["PATH": "/usr/bin"],
                         apps: [String] = [], versions: [String: String] = [:], selected: String? = nil) -> ExecutableLocator {
        ExecutableLocator(
            environment: environment,
            home: "/Users/test",
            isExecutable: { executables.contains($0) },
            fileExists: { files.contains($0) },
            listDirectory: { $0 == "/Applications" ? apps : [] },
            bundleVersion: { versions[$0] },
            selectedDeveloperDirectory: { selected }
        )
    }

    private let xcodeLSP = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"

    /// rustup's `rust-analyzer` proxy exists whether or not the component does. Found on the CI
    /// runner: the proxy was chosen, launched, and exited with "Unknown binary 'rust-analyzer'".
    func testAnInertRustupProxyIsNotAnInstalledServer() {
        let cargoBin = "/Users/test/.cargo/bin"
        func locator(componentInstalled: Bool) -> ExecutableLocator {
            ExecutableLocator(
                environment: ["PATH": "/usr/bin"],
                home: "/Users/test",
                isExecutable: { [cargoBin + "/rust-analyzer", cargoBin + "/rustup"].contains($0) },
                fileExists: { $0 == "/w/Cargo.toml" },
                succeeds: { executable, arguments in
                    executable == cargoBin + "/rustup" && arguments == ["which", "rust-analyzer"] && componentInstalled
                }
            )
        }
        let missing = LanguageServerCatalog.resolve(file: "/w/src/main.rs", workspaceRoot: "/w", locator: locator(componentInstalled: false))
        guard case .failure(.notInstalled(let server, let hint)) = missing else {
            return XCTFail("expected notInstalled, got \(missing)")
        }
        XCTAssertEqual(server, "rust-analyzer")
        XCTAssertTrue(hint.contains("rustup component add rust-analyzer"))

        let installed = LanguageServerCatalog.resolve(file: "/w/src/main.rs", workspaceRoot: "/w", locator: locator(componentInstalled: true))
        XCTAssertEqual(try? installed.get().executable, cargoBin + "/rust-analyzer")
    }

    /// Nested packages get their own server: the root is the nearest marker, not the workspace.
    func testTheNearestProjectRootWins() throws {
        let located = locator(files: ["/w/Package.swift", "/w/Packages/Core/Package.swift"], executables: [xcodeLSP], apps: ["Xcode.app"])
        let resolution = try LanguageServerCatalog.resolve(file: "/w/Packages/Core/Sources/Core/A.swift", workspaceRoot: "/w", locator: located).get()
        XCTAssertEqual(resolution.spec.id, "sourcekit-lsp")
        XCTAssertEqual(resolution.root, "/w/Packages/Core")
        XCTAssertEqual(resolution.environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
    }

    /// A marker above the workspace belongs to another project, and a server started there would
    /// index someone else's code.
    func testAMarkerAboveTheWorkspaceIsNotARoot() {
        let located = locator(files: ["/Package.swift", "/w/../Package.swift"], executables: [xcodeLSP], apps: ["Xcode.app"])
        let result = LanguageServerCatalog.resolve(file: "/w/A.swift", workspaceRoot: "/w", locator: located)
        guard case .failure(.noProjectRoot(let server, _)) = result else {
            return XCTFail("expected noProjectRoot, got \(result)")
        }
        XCTAssertEqual(server, "sourcekit-lsp")
    }

    /// Without a root, sourcekit-lsp answers from one file and it looks complete. Refuse, and say why.
    func testAnXcodeProjectWithoutAPackageIsRefusedWithTheReason() {
        let located = locator(files: ["/w/App.xcodeproj"], executables: [xcodeLSP], apps: ["Xcode.app"])
        let result = LanguageServerCatalog.resolve(file: "/w/App/View.swift", workspaceRoot: "/w", locator: located)
        guard case .failure(let reason) = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.localizedDescription.contains("Package.swift"), reason.localizedDescription)
    }

    /// C is handled by sourcekit-lsp inside a package and by clangd with a compilation database.
    func testCFilesFallThroughToClangdWhenThereIsNoPackage() throws {
        let clangd = "/opt/homebrew/bin/clangd"
        let located = locator(files: ["/w/compile_flags.txt"], executables: [xcodeLSP, clangd], apps: ["Xcode.app"])
        let resolution = try LanguageServerCatalog.resolve(file: "/w/src/main.c", workspaceRoot: "/w", locator: located).get()
        XCTAssertEqual(resolution.spec.id, "clangd")
        XCTAssertEqual(resolution.executable, clangd, "Homebrew is searched even when PATH does not include it")
        XCTAssertTrue(resolution.environment["PATH"]?.contains("/opt/homebrew/bin") ?? false,
                      "the server inherits the search path, which Node-based servers need to find node")
    }

    /// TypeScript 7 has its own server and no `tsserver`; typescript-language-server needs an older one.
    func testTheTypeScriptVersionDecidesWhichServerRuns() throws {
        let typescript = LanguageServerCatalog.all.first { $0.id == "typescript" }!
        let projectTsc = "/w/node_modules/.bin/tsc"
        let globalTLS = "/opt/homebrew/bin/typescript-language-server"
        func located(projectVersion: String?) -> ExecutableLocator {
            ExecutableLocator(
                environment: ["PATH": "/usr/bin"], home: "/Users/test",
                isExecutable: { [projectTsc, globalTLS].contains($0) },
                fileExists: { $0 == "/w/tsconfig.json" },
                packageVersion: { path in
                    // bin/tsc resolves into the package, whose package.json holds the version.
                    path == "/w/node_modules/typescript/package.json" ? projectVersion : nil
                },
                resolveSymlinks: { $0 == projectTsc ? "/w/node_modules/typescript/bin/tsc" : $0 }
            )
        }

        let seven = try LanguageServerCatalog.resolve(file: "/w/src/a.ts", workspaceRoot: "/w", specs: [typescript], locator: located(projectVersion: "7.0.2")).get()
        XCTAssertEqual(seven.executable, projectTsc)
        XCTAssertEqual(seven.arguments, ["--lsp", "--stdio"])

        let five = try LanguageServerCatalog.resolve(file: "/w/src/a.ts", workspaceRoot: "/w", specs: [typescript], locator: located(projectVersion: "5.9.3")).get()
        XCTAssertEqual(five.executable, globalTLS, "tsc 5 has no --lsp, so the older server is used")
        XCTAssertEqual(five.arguments, ["--stdio"])
    }

    func testAMissingServerSaysHowToInstallIt() {
        let located = locator(files: ["/w/Cargo.toml"])
        let result = LanguageServerCatalog.resolve(file: "/w/src/main.rs", workspaceRoot: "/w", locator: located)
        guard case .failure(let reason) = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.localizedDescription.contains("rustup component add rust-analyzer"), reason.localizedDescription)
    }

    func testAnUnknownFileTypeIsRefused() {
        let result = LanguageServerCatalog.resolve(file: "/w/notes.txt", workspaceRoot: "/w", locator: locator(files: []))
        XCTAssertEqual(result, .failure(.unsupportedFileType("txt")))
    }

    /// The Command Line Tools' SwiftPM can crash compiling manifests, so any Xcode is preferred,
    /// the newest by version — not by name, which would put 26.9 above 26.10.
    func testTheNewestXcodeByVersionIsPreferredOverTheCommandLineTools() {
        let older = "/Applications/Xcode-26.9.app"
        let newer = "/Applications/Xcode-26.10.app"
        let binary = { (app: String) in app + "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp" }
        let located = locator(
            files: [],
            executables: [binary(older), binary(newer), "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp"],
            apps: ["Xcode-26.9.app", "Xcode-26.10.app"],
            versions: [older: "26.9", newer: "26.10"]
        )
        XCTAssertEqual(located.locate(LanguageServerCatalog.sourceKit)?.executable, binary(newer))
    }

    func testXcodeSelectAndDeveloperDirAreRespected() {
        let chosen = "/Applications/Xcode-beta.app/Contents/Developer"
        let binary = chosen + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let selected = locator(files: [], executables: [binary, xcodeLSP], apps: ["Xcode.app", "Xcode-beta.app"], selected: chosen)
        XCTAssertEqual(selected.locate(LanguageServerCatalog.sourceKit)?.executable, binary)

        let explicit = locator(files: [], executables: [binary, xcodeLSP], environment: ["DEVELOPER_DIR": chosen],
                               apps: ["Xcode.app"], selected: "/Library/Developer/CommandLineTools")
        XCTAssertEqual(explicit.locate(LanguageServerCatalog.sourceKit)?.environment["DEVELOPER_DIR"], chosen)
    }

    func testOnlySourceAndProjectFilesOutsideBuildOutputAreForwarded() {
        let spec = LanguageServerCatalog.sourceKit
        XCTAssertTrue(FileChangeWatcher.isRelevant("/w/Sources/A.swift", root: "/w", spec: spec))
        XCTAssertTrue(FileChangeWatcher.isRelevant("/w/Package.swift", root: "/w", spec: spec))
        XCTAssertFalse(FileChangeWatcher.isRelevant("/w/.build/checkouts/x/A.swift", root: "/w", spec: spec))
        XCTAssertFalse(FileChangeWatcher.isRelevant("/w/README.md", root: "/w", spec: spec))
        XCTAssertFalse(FileChangeWatcher.isRelevant("/other/A.swift", root: "/w", spec: spec))
    }

    /// sourcekit-lsp indexes a new file only when told it was created; "changed" is ignored.
    func testNewAndAtomicallySavedFilesAreReportedAsCreated() {
        let file = kFSEventStreamEventFlagItemIsFile
        XCTAssertEqual(FileChangeWatcher.classify(flags: file | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified, exists: true), .created)
        XCTAssertEqual(FileChangeWatcher.classify(flags: file | kFSEventStreamEventFlagItemRenamed, exists: true), .created)
        XCTAssertEqual(FileChangeWatcher.classify(flags: file | kFSEventStreamEventFlagItemModified, exists: true), .changed)
        XCTAssertEqual(FileChangeWatcher.classify(flags: file | kFSEventStreamEventFlagItemCreated, exists: false), .deleted)
    }

    /// The card shows the server's own progress while the first index runs.
    func testProgressIsSummarisedFromTheServersReports() {
        let events = SessionEvents()
        XCTAssertNil(events.progressSummary)
        events.progress(token: "indexing.1", kind: "begin", title: "Indexing", message: "Determining files", percentage: 0)
        XCTAssertEqual(events.progressSummary, "Indexing: Determining files (0%)")
        events.progress(token: "indexing.1", kind: "report", message: "12 / 40", percentage: 30)
        XCTAssertEqual(events.progressSummary, "Indexing: 12 / 40 (30%)")
        events.progress(token: "reload", kind: "begin", title: "SourceKit-LSP: Reloading Package")
        XCTAssertEqual(events.progressSummary, "Indexing: 12 / 40 (30%); SourceKit-LSP: Reloading Package")
        events.progress(token: "indexing.1", kind: "end")
        events.progress(token: "reload", kind: "end")
        XCTAssertNil(events.progressSummary)
        XCTAssertEqual(events.progressState.active, 0)
    }

    // MARK: - Finding the position

    func testASymbolThatAppearsOnceIsFound() throws {
        let position = try SymbolPosition.resolve(in: "one\n    let total = compute()\n", line: 2, symbol: "compute", column: nil)
        XCTAssertEqual(position, .init(line: 1, character: 16))
    }

    /// Guessing the first occurrence of `value` in `let value = value` points at the wrong symbol.
    func testAnAmbiguousLineIsAnErrorThatListsTheColumns() {
        XCTAssertThrowsError(try SymbolPosition.resolve(in: "let value = value", line: 1, symbol: "value", column: nil)) { error in
            XCTAssertEqual(error as? SymbolPosition.Failure, .ambiguous(symbol: "value", line: 1, columns: [5, 13]))
            XCTAssertTrue(error.localizedDescription.contains("column"))
        }
    }

    func testAColumnAnywhereInsideTheNameSelectsThatOccurrence() throws {
        let position = try SymbolPosition.resolve(in: "let value = value", line: 1, symbol: "value", column: 15)
        XCTAssertEqual(position.character, 12)
        XCTAssertThrowsError(try SymbolPosition.resolve(in: "let value = value", line: 1, symbol: "value", column: 10)) { error in
            XCTAssertEqual(error as? SymbolPosition.Failure, .symbolNotAtColumn(symbol: "value", column: 10, columns: [5, 13]))
        }
    }

    /// Renames start from a declaration line, where the keyword says which occurrence is declared.
    func testADeclarationKeywordBreaksTheTieWhenAsked() throws {
        let line = "    func value(value: Int) -> Int { value }"
        let position = try SymbolPosition.resolve(in: line, line: 1, symbol: "value", column: nil, preferDeclaration: true)
        XCTAssertEqual(position.character, 9)
        XCTAssertThrowsError(try SymbolPosition.resolve(in: line, line: 1, symbol: "value", column: nil))
    }

    func testWholeIdentifiersOnlyIncludingDollarPrefixes() {
        XCTAssertEqual(SymbolPosition.occurrences(of: "value", in: "$value + values + value_ + value").map(\.column), [28])
    }

    /// LSP characters are UTF-16 units; output columns are characters, as an editor shows them.
    func testPositionsAreUTF16OnTheWireAndCharactersInOutput() throws {
        let line = "let 👋🏽 = 1; let value = 2"
        let position = try SymbolPosition.resolve(in: line, line: 1, symbol: "value", column: nil)
        XCTAssertEqual(position.character, 18, "the emoji with its skin tone is four UTF-16 units")
        XCTAssertEqual(SymbolPosition.characterColumn(utf16Offset: 18, in: line), 16)
        let byColumn = try SymbolPosition.resolve(in: line, line: 1, symbol: nil, column: 16)
        XCTAssertEqual(byColumn.character, 18)
    }

    func testWindowsLineEndingsAndBadLinesAreHandled() throws {
        XCTAssertEqual(try SymbolPosition.resolve(in: "a\r\nlet b = c\r\n", line: 2, symbol: "c", column: nil).character, 8)
        XCTAssertThrowsError(try SymbolPosition.resolve(in: "a\nb", line: 9, symbol: "a", column: nil)) { error in
            XCTAssertEqual(error as? SymbolPosition.Failure, .lineOutOfRange(line: 9, lineCount: 2))
        }
        XCTAssertThrowsError(try SymbolPosition.resolve(in: "a", line: 1, symbol: nil, column: nil))
    }

    // MARK: - Reading answers

    func testLocationsLinksAndSingleLocationsAreAllRead() {
        let range: [String: Any] = ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 9]]
        let single: [String: Any] = ["uri": "file:///tmp/A.swift", "range": range]
        let link: [String: Any] = ["targetUri": "file:///tmp/B.swift", "targetRange": range, "targetSelectionRange": range]
        XCTAssertEqual(CodeIntelligence.parseLocations(single).map(\.line), [3])
        XCTAssertEqual(CodeIntelligence.parseLocations([link]).first?.path.hasSuffix("/B.swift"), true)
        XCTAssertEqual(CodeIntelligence.parseLocations([single, single]).count, 1, "duplicates are dropped")
        XCTAssertTrue(CodeIntelligence.parseLocations(NSNull()).isEmpty)
    }

    func testEveryHoverShapeBecomesText() {
        XCTAssertEqual(CodeIntelligence.hoverText(["contents": ["kind": "markdown", "value": "```swift\nfunc a()\n```"]]), "```swift\nfunc a()\n```")
        XCTAssertEqual(CodeIntelligence.hoverText(["contents": "plain"]), "plain")
        XCTAssertEqual(CodeIntelligence.hoverText(["contents": [["language": "c", "value": "int x"], "doc"]]), "```c\nint x\n```\n\ndoc")
        XCTAssertEqual(CodeIntelligence.hoverText(nil), "")
    }

    func testOutlinesAreIndentedByScope() {
        func range(_ line: Int) -> [String: Any] { ["start": ["line": line, "character": 0], "end": ["line": line, "character": 1]] }
        let symbols: [[String: Any]] = [[
            "name": "Alpha", "kind": 23, "range": range(0), "selectionRange": range(0),
            "children": [["name": "value()", "kind": 6, "detail": "func value() -> Int", "range": range(2), "selectionRange": range(2)]],
        ]]
        XCTAssertEqual(CodeIntelligence.formatOutline(symbols), ["1: struct Alpha", "  3: method value() — func value() -> Int"])
    }

    // MARK: - Tool arguments

    func testToolArgumentsAcceptStringNumbersAndExplainWhatIsMissing() throws {
        let target = try ToolExecutionEngine.codeTarget(from: ["path": "A.swift", "line": "12", "symbol": "value"], toolName: "find_references").get()
        XCTAssertEqual(target.line, 12)
        XCTAssertEqual(target.symbol, "value")

        guard case .failure(let missing) = ToolExecutionEngine.codeTarget(from: ["path": "A.swift", "line": 3], toolName: "find_references") else {
            return XCTFail("a call without symbol or column must be refused")
        }
        XCTAssertTrue(missing.text.contains("symbol"))
    }

    /// These only read, so plan mode keeps them and they never ask for approval.
    @MainActor
    func testCodeIntelligenceToolsAreReadOnly() {
        let names = ["go_to_definition", "find_references", "symbol_info", "code_diagnostics", "document_symbols", "call_hierarchy"]
        let tools = ToolSchemaCatalog.parityDefaults.filter { names.contains($0.name) }
        XCTAssertEqual(Set(tools.map(\.name)), Set(names), "every tool is in the default catalog")
        XCTAssertTrue(tools.allSatisfy { !$0.requiresApproval })
        XCTAssertEqual(Set(AgentRunner.filterToolsForPlanMode(tools).map(\.name)).intersection(names), Set(names))
        for name in names {
            XCTAssertNil(AgentRunner.approvalReason(toolName: name, settings: AppSettings()), name)
        }
    }
}
