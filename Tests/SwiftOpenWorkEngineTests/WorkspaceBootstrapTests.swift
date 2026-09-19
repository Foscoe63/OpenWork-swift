import XCTest
@testable import SwiftOpenWorkEngine

final class WorkspaceBootstrapTests: XCTestCase {

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-bootstrap-\(UUID().uuidString)", isDirectory: true)
    }

    func testNewFolderGetsStarterFilesAndARepository() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let outcome = await WorkspaceBootstrap.bootstrap(
            folder: folder.path,
            template: .staticSite,
            projectName: "My Site"
        )

        XCTAssertEqual(Set(outcome.writtenFiles), [".gitignore", "AGENTS.md", "index.html", "script.js", "style.css"])
        XCTAssertTrue(outcome.initialisedRepository)
        XCTAssertTrue(GitTools.isRepository(folder.path))
        let html = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<title>My Site</title>"))
        // The first commit needs a git identity, which a CI machine may not have; then it says so.
        if outcome.committed {
            XCTAssertTrue(GitTools.status(in: folder.path).text.contains("Working tree clean"))
        } else {
            XCTAssertNotNil(outcome.note)
        }
    }

    func testFolderWithFilesIsLeftAlone() async throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "mine".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let outcome = await WorkspaceBootstrap.bootstrap(folder: folder.path, template: .viteReact, projectName: "X")

        XCTAssertTrue(outcome.writtenFiles.isEmpty)
        XCTAssertFalse(outcome.initialisedRepository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("package.json").path))
    }

    func testFinderMetadataAndStagingFoldersStillCountAsEmpty() throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("input"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))

        XCTAssertFalse(WorkspaceBootstrap.isEmptyFolder(folder.path))
        XCTAssertTrue(WorkspaceBootstrap.isEmptyFolder(folder.path, ignoring: ["input", "output"]))
        XCTAssertTrue(WorkspaceBootstrap.isEmptyFolder(folder.appendingPathComponent("missing").path))
    }

    func testFolderInsideARepositoryGetsFilesButNoNestedRepository() async throws {
        let repo = temporaryFolder()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try await AgentWorktree.git(["init", "--quiet"], in: repo)
        let folder = repo.appendingPathComponent("site")

        let outcome = await WorkspaceBootstrap.bootstrap(folder: folder.path, template: .pythonScript, projectName: "Tool")

        XCTAssertTrue(outcome.writtenFiles.contains("main.py"))
        XCTAssertFalse(outcome.initialisedRepository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
    }

    func testEveryTemplateHasAgentInstructionsAndAGitignore() {
        for template in WorkspaceBootstrap.StarterTemplate.allCases {
            let files = template.files(projectName: "Demo")
            XCTAssertNotNil(files[".gitignore"], "\(template)")
            if template != .empty {
                XCTAssertNotNil(files["AGENTS.md"], "\(template)")
            }
        }
    }

    func testNamesAreMadeSafeForTheLanguagesTheyLandIn() {
        XCTAssertEqual(WorkspaceBootstrap.packageName("My Café App!"), "my-caf-app")
        XCTAssertEqual(WorkspaceBootstrap.swiftIdentifier("my cool-app"), "MyCoolApp")
        XCTAssertEqual(WorkspaceBootstrap.swiftIdentifier("2048 game"), "App2048Game")
        let files = WorkspaceBootstrap.StarterTemplate.swiftUIApp.files(projectName: #"Say "hi" \ <b>"#)
        let view = files["Sources/SayHiB/ContentView.swift"] ?? ""
        XCTAssertTrue(view.contains(#"Text("Say hi  b")"#), view)
    }
}

final class SessionCommitTests: XCTestCase {

    private func makeRepository() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await AgentWorktree.git(["init", "--quiet"], in: repo)
        try await AgentWorktree.git(["config", "user.email", "t@example.com"], in: repo)
        try await AgentWorktree.git(["config", "user.name", "Test"], in: repo)
        try "a".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: repo.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        try await AgentWorktree.git(["add", "-A"], in: repo)
        try await AgentWorktree.git(["commit", "--quiet", "-m", "base"], in: repo)
        return repo
    }

    func testCommitsOnlyTheSessionFilesAndLeavesOtherStagedWorkStaged() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "b".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "new".write(to: repo.appendingPathComponent("src/new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        // The user's own staged work, not part of the session.
        try "mine".write(to: repo.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await AgentWorktree.git(["add", "mine.txt"], in: repo)

        let session = ["kept.txt", "src/new.txt", "gone.txt", "unchanged.txt", "/elsewhere/x.txt"]
        let pending = SessionCommit.pendingPaths(session, in: repo.path)
        XCTAssertEqual(pending, ["kept.txt", "src/new.txt", "gone.txt"])

        let hash = try await SessionCommit.commit(paths: pending, message: "Session work", in: repo.path)
        XCTAssertFalse(hash.isEmpty)

        let committed = try await AgentWorktree.git(["show", "--name-status", "--format=%s", "HEAD"], in: repo)
        XCTAssertTrue(committed.hasPrefix("Session work"))
        XCTAssertTrue(committed.contains("M\tkept.txt"))
        XCTAssertTrue(committed.contains("A\tsrc/new.txt"))
        XCTAssertTrue(committed.contains("D\tgone.txt"))
        XCTAssertFalse(committed.contains("mine.txt"))
        let staged = try await AgentWorktree.git(["diff", "--staged", "--name-only"], in: repo)
        XCTAssertEqual(staged.trimmingCharacters(in: .whitespacesAndNewlines), "mine.txt")
        XCTAssertTrue(SessionCommit.pendingPaths(session, in: repo.path).isEmpty)
    }

    func testRefusesAnEmptyMessage() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        do {
            _ = try await SessionCommit.commit(paths: ["kept.txt"], message: "  \n", in: repo.path)
            XCTFail("An empty message must not commit")
        } catch let error as SessionCommit.CommitError {
            XCTAssertEqual(error, .emptyMessage)
        }
    }

    func testSuggestedMessage() {
        XCTAssertEqual(SessionCommit.suggestedMessage(sessionTitle: "Add dark mode", paths: ["a", "b"]), "Add dark mode")
        XCTAssertEqual(SessionCommit.suggestedMessage(sessionTitle: "New Session", paths: ["src/App.jsx"]), "Update App.jsx")
        XCTAssertEqual(SessionCommit.suggestedMessage(sessionTitle: nil, paths: ["a", "b", "c"]), "Update 3 files")
    }
}
