import XCTest
@testable import OpenWorkSwift

/// Git was read-only here on purpose. A worktree is what makes committing safe rather than a
/// weakening of that rule: history added on a branch of its own cannot rewrite anything the user
/// wrote, which is exactly why session-wide undo was rejected and this is not the same thing.
final class AgentWorktreeTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("owt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try AgentWorktree.git(["init", "-q", "-b", "main"], in: repo)
        try AgentWorktree.git(["config", "user.email", "t@example.com"], in: repo)
        try AgentWorktree.git(["config", "user.name", "Test"], in: repo)
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try AgentWorktree.git(["add", "-A"], in: repo)
        try AgentWorktree.git(["commit", "-q", "-m", "seed"], in: repo)
    }

    override func tearDownWithError() throws {
        let container = AgentWorktree.container(for: repo)
        try? FileManager.default.removeItem(at: container)
        try? FileManager.default.removeItem(at: repo)
    }

    /// The whole safety argument in one assertion: the user's own checkout is not committable.
    func testCommittingOnTheUsersOwnCheckoutIsRefused() throws {
        try "dirty\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentWorktree.commit(worktreePath: repo.path, message: "nope")) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("committing stays yours"), "got: \(text)")
        }
        // And it really did not commit.
        let log = try AgentWorktree.git(["log", "--oneline"], in: repo)
        XCTAssertEqual(log.split(separator: "\n").count, 1, "the user's history must be untouched")
    }

    func testCreateGivesAnIsolatedTreeOnItsOwnBranch() throws {
        let info = try AgentWorktree.create(workspacePath: repo.path, name: "Dark Mode Fix!")
        XCTAssertEqual(info.branch, "openwork/dark-mode-fix")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))
        // Beside the repo, never inside it, or the parent's own status and file search see it.
        XCTAssertFalse(info.path.hasPrefix(repo.path + "/"))
        XCTAssertTrue(AgentWorktree.isAgentWorktree(info.path))
    }

    func testWorkInAWorktreeCommitsThereAndLeavesMainAlone() throws {
        let info = try AgentWorktree.create(workspacePath: repo.path, name: "feature")
        let file = URL(fileURLWithPath: info.path).appendingPathComponent("added.txt")
        try "agent wrote this\n".write(to: file, atomically: true, encoding: .utf8)

        let output = try AgentWorktree.commit(worktreePath: info.path, message: "Add a file")
        XCTAssertTrue(output.contains("openwork/feature"), "got: \(output)")

        // The worktree advanced...
        let wtLog = try AgentWorktree.git(["log", "--oneline"], in: URL(fileURLWithPath: info.path))
        XCTAssertEqual(wtLog.split(separator: "\n").count, 2)

        // ...and the user's branch did not.
        let mainLog = try AgentWorktree.git(["log", "--oneline", "main"], in: repo)
        XCTAssertEqual(mainLog.split(separator: "\n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("added.txt").path))
    }

    func testCommittingNothingIsNotReportedAsSuccess() throws {
        let info = try AgentWorktree.create(workspacePath: repo.path, name: "empty")
        XCTAssertThrowsError(try AgentWorktree.commit(worktreePath: info.path, message: "nothing"))
    }

    /// Removing a worktree is the one irreversible action here, so a dirty one needs saying twice.
    func testRemovingADirtyWorktreeNeedsForce() throws {
        let info = try AgentWorktree.create(workspacePath: repo.path, name: "dirty")
        try "uncommitted\n".write(
            to: URL(fileURLWithPath: info.path).appendingPathComponent("wip.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try AgentWorktree.remove(workspacePath: repo.path, name: "dirty", force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path), "must not have been removed")
        XCTAssertNoThrow(try AgentWorktree.remove(workspacePath: repo.path, name: "dirty", force: true))
    }

    func testCreateIsIdempotentSoARetryLandsInTheSamePlace() throws {
        let first = try AgentWorktree.create(workspacePath: repo.path, name: "retry")
        let second = try AgentWorktree.create(workspacePath: repo.path, name: "retry")
        XCTAssertEqual(first.path, second.path)
    }

    func testListOnlyReportsAgentWorktrees() throws {
        _ = try AgentWorktree.create(workspacePath: repo.path, name: "one")
        let trees = try AgentWorktree.list(workspacePath: repo.path)
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(trees.first?.branch, "openwork/one")
    }

    func testNameSanitisingCannotProduceAnInvalidRef() {
        XCTAssertEqual(AgentWorktree.sanitize("Dark Mode / Fix!!"), "dark-mode-fix")
        XCTAssertEqual(AgentWorktree.sanitize("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(AgentWorktree.sanitize(""), "task")
        XCTAssertEqual(AgentWorktree.sanitize("   "), "task")
    }
}
