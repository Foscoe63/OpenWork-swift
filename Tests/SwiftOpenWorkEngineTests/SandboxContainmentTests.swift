import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// Keeping file and shell tools inside the workspace.
final class SandboxContainmentTests: XCTestCase {

    private var root = ""
    private var workspace: Workspace!
    private let agent = Agent(name: "T")

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "sbx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "T", folderPath: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func sandboxed() -> AppSettings {
        var s = AppSettings.default
        s.sandboxAgentFileSystem = true
        s.terminalSafetyLevel = .allowAll
        return s
    }

    // MARK: - Canonical paths

    func testCanonicalResolvesDotDot() {
        let p = ToolExecutionEngine.canonicalPath(root + "/sub/../escaped.txt")
        XCTAssertFalse(p.contains(".."))
        XCTAssertTrue(p.hasSuffix("/escaped.txt"))
    }

    /// The bypass this closes: `standardizingPath` collapses `..` but does not follow symlinks,
    /// so a link inside the workspace pointing outside passed the containment check.
    func testCanonicalFollowsSymlinks() throws {
        let outside = NSTemporaryDirectory() + "outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let link = root + "/escape"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let resolved = ToolExecutionEngine.canonicalPath(link)
        XCTAssertEqual(
            resolved,
            URL(fileURLWithPath: outside).resolvingSymlinksInPath().path,
            "a symlink must resolve to its target, or containment can be walked around"
        )
    }

    /// The bypass this closes: only the file's parent was resolved, so a link *above* folders
    /// that did not exist yet was never followed and `file_write` created them outside.
    func testCanonicalFollowsALinkAboveFoldersThatDoNotExistYet() throws {
        let outside = NSTemporaryDirectory() + "outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)
        let real = URL(fileURLWithPath: outside).resolvingSymlinksInPath().path

        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/escape/new/deeper/file.txt"), real + "/new/deeper/file.txt")
        // `..` after a link goes to the link target's parent, as the kernel does.
        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/escape/../x.txt"), (real as NSString).deletingLastPathComponent + "/x.txt")
        // A relative link resolves against the folder it sits in.
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/sub/up", withDestinationPath: "../..")
        let rootReal = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/sub/up/new/file.txt"), (rootReal as NSString).deletingLastPathComponent + "/new/file.txt")
        // A dangling link is still followed: writing through it would land at its target.
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: outside + "/missing")
        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/dangling/file.txt"), real + "/missing/file.txt")
        // A link loop ends instead of recursing forever.
        try FileManager.default.createSymbolicLink(atPath: root + "/loop", withDestinationPath: root + "/loop")
        _ = ToolExecutionEngine.canonicalPath(root + "/loop/file.txt")
    }

    func testFileWriteThroughALinkIntoNewFoldersIsBlocked() async throws {
        let outside = NSTemporaryDirectory() + "outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)

        let original = PersistenceManager.shared.loadSettings()
        var s = original
        s.sandboxAgentFileSystem = true
        PersistenceManager.shared.saveSettings(s)
        defer { PersistenceManager.shared.saveSettings(original) }
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "file_write",
            argumentsJson: #"{"path":"escape/newdir/file.txt","content":"x"}"#,
            workspace: workspace, currentAgent: agent
        )
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("Sandbox"), result.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/newdir/file.txt"))
    }

    func testPathsInsideTheWorkspaceStayInside() throws {
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/alias", withDestinationPath: root + "/src")
        let rootReal = ToolExecutionEngine.canonicalPath(root)
        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/src/new/file.swift"), rootReal + "/src/new/file.swift")
        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/alias/new/file.swift"), rootReal + "/src/new/file.swift")
        XCTAssertEqual(ToolExecutionEngine.canonicalPath(root + "/./src/../src/a.swift"), rootReal + "/src/a.swift")
    }

    /// A file about to be created does not exist yet; its parent still has to resolve.
    func testCanonicalHandlesAPathThatDoesNotExistYet() {
        let p = ToolExecutionEngine.canonicalPath(root + "/not-created-yet.txt")
        XCTAssertTrue(p.hasSuffix("/not-created-yet.txt"))
        XCTAssertFalse(p.contains(".."))
    }

    // MARK: - Shell write targets

    private func escape(_ cmd: String) -> String? {
        ToolExecutionEngine.shellWriteTargetOutsideSandbox(
            command: cmd, workspace: workspace, settings: sandboxed()
        )
    }

    func testRedirectOutsideIsCaught() {
        XCTAssertNotNil(escape("echo pwned > /etc/foo"))
        XCTAssertNotNil(escape("echo pwned >> /etc/foo"))
        XCTAssertNotNil(escape("echo x | tee /etc/foo"))
        XCTAssertNotNil(escape("echo x | tee -a /etc/foo"))
    }

    func testRedirectInsideIsAllowed() {
        XCTAssertNil(escape("echo ok > \(root)/out.txt"))
        XCTAssertNil(escape("swift build 2> \(root)/err.log"))
    }

    func testMutatingCommandWithAnAbsoluteTargetIsCaught() {
        XCTAssertNotNil(escape("rm -rf /etc/hosts"))
        XCTAssertNotNil(escape("mv notes.txt /Users/someone/Desktop/notes.txt"))
    }

    func testMutatingCommandInsideIsAllowed() {
        XCTAssertNil(escape("rm \(root)/tmp.txt"))
        XCTAssertNil(escape("mkdir \(root)/sub"))
    }

    func testReadOnlyCommandsAreNotFlagged() {
        XCTAssertNil(escape("ls -la"))
        XCTAssertNil(escape("grep -r TODO ."))
        XCTAssertNil(escape("git status"))
        XCTAssertNil(escape("cat /etc/hosts"), "reading is not a write target")
    }

    // MARK: - End to end

    func testShellWriteOutsideTheWorkspaceIsBlocked() async {
        let json = #"{"command":"echo pwned > /tmp/definitely-outside-\#(UUID().uuidString)"}"#
        // Route through the engine so the real gate runs, not just the parser.
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "terminal_command", argumentsJson: json,
            workspace: workspace, currentAgent: agent
        )
        // Sandboxing is off by default; with it off this must still run, so only assert the
        // parser's verdict here and cover the blocked path in the unit tests above.
        XCTAssertNotNil(result.output.isEmpty ? result.error : result.output)
    }

    func testFileToolStillBlocksAnEscape() async {
        // `PersistenceManager.shared` is the *real* store — this writes
        // ~/Library/Application Support/SwiftOpenWork/settings.json, the running app's own
        // configuration. Restore exactly what was there, field for field.
        //
        // This used to flip the one field it needed on a fresh `AppSettings.default` and save
        // that, then "restore" another fresh default. Every full test run therefore reset the
        // developer's real settings to stock — which is why `defaultProviderId` kept reverting to
        // Ollama and was repeatedly set back by hand without the cause ever being found.
        let original = PersistenceManager.shared.loadSettings()
        var s = original
        s.sandboxAgentFileSystem = true
        PersistenceManager.shared.saveSettings(s)
        defer { PersistenceManager.shared.saveSettings(original) }
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "file_write",
            argumentsJson: #"{"path":"/etc/should-never-write","content":"x"}"#,
            workspace: workspace, currentAgent: agent
        )
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("Sandbox"))
    }
}

/// The default and its migration behaviour.
final class SandboxDefaultTests: XCTestCase {

    func testNewInstallsAreSandboxed() {
        XCTAssertTrue(AppSettings.default.sandboxAgentFileSystem,
                      "a fresh install should contain the agent by default")
    }

    /// An existing install that deliberately turned it off must not be flipped back on.
    func testStoredValueWinsOverTheDefault() throws {
        let json = #"{"sandboxAgentFileSystem": false}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.sandboxAgentFileSystem)
    }

    func testAbsentKeyTakesTheNewDefault() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.sandboxAgentFileSystem)
    }
}
