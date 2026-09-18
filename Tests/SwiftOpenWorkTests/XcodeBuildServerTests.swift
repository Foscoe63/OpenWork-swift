import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

/// Xcode projects get code intelligence through xcode-build-server, whose index is only as new as
/// the last build. The pure half pins how that age is judged and reported; the integration test
/// builds a real throwaway project.
final class XcodeBuildServerTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = LanguageServerCatalog.standardized(NSTemporaryDirectory()) + "/ow-xbs-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await LanguageServerPool.shared.shutdown(under: root)
        // The build lands in the real DerivedData; only this test's own project is removed.
        if let buildRoot = XcodeBuildServer.configuration(at: root)?.buildRoot,
           (buildRoot as NSString).lastPathComponent.hasPrefix("XToy-") {
            try? FileManager.default.removeItem(atPath: buildRoot)
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relative: String, _ text: String, modified: Date? = nil) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
    }

    // MARK: - Pure

    func testOnlyAConfigurationWrittenByXcodeBuildServerCounts() throws {
        try write("buildServer.json", #"{"name":"xcode build server","kind":"xcode","build_root":"/DD/App-abc","scheme":"App"}"#)
        XCTAssertEqual(XcodeBuildServer.configuration(at: root), .init(buildRoot: "/DD/App-abc", scheme: "App"))
        try write("buildServer.json", #"{"name":"some other bsp","argv":["x"]}"#)
        XCTAssertNil(XcodeBuildServer.configuration(at: root))
    }

    /// The index is from the last build, so a file saved after it is what an answer may miss.
    func testFilesSavedAfterTheLastBuildMakeTheIndexStale() throws {
        let buildTime = Date().addingTimeInterval(-600)
        try write("DD/Logs/Build/one.xcactivitylog", "", modified: buildTime)
        try write("App/Old.swift", "", modified: buildTime.addingTimeInterval(-60))
        let configuration = XcodeBuildServer.Configuration(buildRoot: root + "/DD", scheme: "App")

        let fresh = XcodeBuildServer.freshness(root: root + "/App", configuration: configuration)
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(XcodeBuildServer.note(for: fresh).contains("no source files have changed"))

        try write("App/New.swift", "", modified: buildTime.addingTimeInterval(60))
        try write("App/notes.txt", "", modified: buildTime.addingTimeInterval(60))
        let stale = XcodeBuildServer.freshness(root: root + "/App", configuration: configuration)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.changedSinceBuild, ["New.swift"], "only source files count")
        let note = XcodeBuildServer.note(for: stale)
        XCTAssertTrue(note.contains("1 source file has changed since (New.swift)"), note)
        XCTAssertTrue(note.contains("build_project"), note)
    }

    func testAProjectThatWasNeverBuiltHasNoIndex() {
        let never = XcodeBuildServer.freshness(root: root, configuration: .init(buildRoot: root + "/missing", scheme: nil))
        XCTAssertNil(never.lastBuild)
        XCTAssertTrue(never.isStale)
        XCTAssertTrue(XcodeBuildServer.note(for: never).contains("has not been built"))
    }

    /// Before setup, the tools say what to run instead of the generic "needs Package.swift".
    func testAnXcodeProjectWithoutSetupIsToldToRunTheSetupTool() {
        let located = ExecutableLocator(
            environment: ["DEVELOPER_DIR": "/X"], home: "/Users/test",
            isExecutable: { $0 == "/X/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp" },
            fileExists: { _ in false },
            listDirectory: { $0 == "/w/App" ? ["App.xcodeproj", "Sources"] : [] }
        )
        let result = LanguageServerCatalog.resolve(file: "/w/App/Sources/View.swift", workspaceRoot: "/w", locator: located)
        XCTAssertEqual(result, .failure(.xcodeProjectNeedsSetup(directory: "App")))
        if case .failure(let reason) = result {
            XCTAssertTrue(reason.localizedDescription.contains("setup_xcode_language_server"))
        }
    }

    func testCommandsQuoteAndPinTheDeveloperDirectory() {
        XCTAssertEqual(
            XcodeBuildServer.configCommand(executable: "/opt/homebrew/bin/xcode-build-server", developerDirectory: "/Applications/Xcode.app/Contents/Developer",
                                           flag: "-project", container: "My App.xcodeproj", scheme: "My App"),
            "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /opt/homebrew/bin/xcode-build-server config -project 'My App.xcodeproj' -scheme 'My App'"
        )
        XCTAssertEqual(
            XcodeBuildServer.buildCommand(developerDirectory: nil, flag: "-workspace", container: "App.xcworkspace", scheme: "App"),
            "xcodebuild -workspace App.xcworkspace -scheme App -quiet build"
        )
    }

    /// It writes a file and runs a build, so it is gated like every other writing tool.
    @MainActor
    func testTheSetupToolNeedsApprovalAndIsNotAvailableInPlanMode() throws {
        let tool = try XCTUnwrap(ToolSchemaCatalog.parityDefaults.first { $0.name == "setup_xcode_language_server" })
        XCTAssertTrue(tool.requiresApproval)
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: tool.name, settings: AppSettings()))
        XCTAssertFalse(AgentRunner.filterToolsForPlanMode([tool]).map(\.name).contains(tool.name))
    }

    // MARK: - A real Xcode project

    func testAnXcodeProjectGetsCompilerAnswersAfterSetupAndSaysWhenTheyAreStale() async throws {
        let locator = ExecutableLocator()
        guard locator.executable(named: "xcode-build-server") != nil, let xcodegen = locator.executable(named: "xcodegen"),
              let developer = locator.sourceKitInXcode()?.1 else {
            throw XCTSkip("needs Xcode, xcodegen and xcode-build-server")
        }
        try write("project.yml", """
        name: XToy
        options:
          bundleIdPrefix: dev.example
        targets:
          XToy:
            type: framework
            platform: macOS
            deploymentTarget: "14.0"
            sources: [Toy]
            settings:
              GENERATE_INFOPLIST_FILE: YES
              CODE_SIGNING_ALLOWED: NO
        """)
        try write("Toy/Types.swift", """
        public struct Alpha {
            public init() {}
            public func value() -> Int { 1 }
        }
        public struct Beta {
            public init() {}
            public func value() -> Int { 2 }
        }
        """)
        try write("Toy/Use.swift", "let x = Alpha().value()\nlet y = Beta().value()\n")
        func generate() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: xcodegen)
            process.arguments = ["generate", "--quiet"]
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": developer]) { $1 }
            try process.run()
            process.waitUntilExit()
        }
        try generate()

        let workspace = Workspace(name: "XToy", folderPath: root)
        let agent = Agent(name: "Runner", role: "executor")
        func run(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
            let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
            return await ToolExecutionEngine.shared.execute(toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent)
        }
        let valueInUse: [String: Any] = ["path": "Toy/Use.swift", "line": 1, "symbol": "value"]

        let before = await run("find_references", valueInUse)
        XCTAssertFalse(before.success)
        XCTAssertTrue(before.error?.contains("setup_xcode_language_server") ?? false, before.error ?? "")

        let setup = await run("setup_xcode_language_server", ["scheme": "XToy"])
        XCTAssertTrue(setup.success, (setup.error ?? "") + "\n" + setup.output)
        XCTAssertTrue(setup.output.contains("Wrote buildServer.json for scheme 'XToy'"), setup.output)
        XCTAssertNotNil(XcodeBuildServer.configuration(at: root))

        let references = await run("find_references", valueInUse)
        XCTAssertTrue(references.success, references.error ?? "")
        XCTAssertTrue(references.output.contains("2 references"), references.output)
        XCTAssertTrue(references.output.contains("Toy/Types.swift:3:17:"), references.output)
        XCTAssertFalse(references.output.contains("Types.swift:7:"), "Beta.value is another symbol:\n\(references.output)")
        XCTAssertTrue(references.output.contains("no source files have changed"), references.output)

        // Edited after the build: answers say so, and a compiler rename refuses rather than
        // renaming only the uses the old index knows.
        try write("Toy/More.swift", "let again = Alpha().value()\n")
        try generate()
        let stale = await run("find_references", valueInUse)
        XCTAssertTrue(stale.output.contains("changed since (Toy/More.swift)"), stale.output)
        do {
            _ = try await SymbolRename.rename(oldName: "value", newName: "count", root: root,
                                              pathHint: "Toy/Types.swift", mode: .semantic, declarationLine: 3)
            XCTFail("a rename from a stale index must be refused")
        } catch SymbolRename.Failure.compilerRenameUnavailable(let reason) {
            XCTAssertTrue(reason.contains("not attempted"), reason)
        }
        XCTAssertTrue(try String(contentsOfFile: root + "/Toy/More.swift", encoding: .utf8).contains("value()"), "nothing was renamed")

        let rebuilt = await run("setup_xcode_language_server", ["scheme": "XToy", "build": true])
        XCTAssertTrue(rebuilt.success, (rebuilt.error ?? "") + "\n" + rebuilt.output)
        let fresh = await run("find_references", valueInUse)
        XCTAssertTrue(fresh.output.contains("3 references"), fresh.output)
        XCTAssertTrue(fresh.output.contains("Toy/More.swift:1:21:"), fresh.output)
    }
}
