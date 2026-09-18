import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

/// Rewinding is the safety net the whole "let the agent run" posture rests on, so these tests are
/// about the two ways it could betray that: putting back the wrong contents, and claiming success
/// for a file it did not actually restore.
final class SessionCheckpointStoreTests: XCTestCase {

    private var work: URL!
    private var storeRoot: URL!
    private var store: SessionCheckpointStore!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ow-ckpt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        work = base.appendingPathComponent("work", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store = SessionCheckpointStore(root: storeRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func path(_ name: String) -> String {
        work.appendingPathComponent(name).path
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOfFile: path(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(name))
    }

    /// Seal a turn that was about to change `name` from its current state.
    @discardableResult
    private func seal(
        session: String = "s1",
        message: String,
        label: String = "turn",
        _ baselines: [FileBaseline]
    ) async -> SessionCheckpointStore.Checkpoint? {
        await store.record(sessionId: session, messageId: message, label: label, baselines: baselines)
    }

    private func baseline(_ name: String) -> FileBaseline {
        let current = read(name)
        return FileBaseline(path: path(name), previousContents: current, existedBefore: current != nil)
    }

    // MARK: - Recording

    func testATurnThatChangedNothingIsNotRecorded() async {
        let checkpoint = await store.record(sessionId: "s1", messageId: "m1", label: "noop", baselines: [])
        XCTAssertNil(checkpoint)
        let all = await store.checkpoints(forSession: "s1")
        XCTAssertTrue(all.isEmpty)
    }

    func testCheckpointsAreSequencedInOrder() async throws {
        try write("a.txt", "one")
        await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "two")
        await seal(message: "m2", [baseline("a.txt")])

        let all = await store.checkpoints(forSession: "s1")
        XCTAssertEqual(all.map(\.sequence), [1, 2])
        XCTAssertEqual(all.map(\.messageId), ["m1", "m2"])
    }

    // MARK: - Restoring

    func testRestoringPutsContentBackAsItWasBeforeTheTurn() async throws {
        try write("a.txt", "original")
        let checkpoint = await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "agent wrote this")

        let outcome = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(outcome.restored, [path("a.txt")])
        XCTAssertEqual(read("a.txt"), "original")
    }

    /// The point of rewinding several turns: the oldest baseline wins, not the most recent one.
    func testRestoringAcrossTurnsUsesTheOldestBaselineNotTheLast() async throws {
        try write("a.txt", "v1")
        let first = await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "v2")
        await seal(message: "m2", [baseline("a.txt")])
        try write("a.txt", "v3")
        await seal(message: "m3", [baseline("a.txt")])
        try write("a.txt", "v4")

        let outcome = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(first).id)
        XCTAssertEqual(outcome.turnsUndone, 3)
        XCTAssertEqual(read("a.txt"), "v1", "undoing three turns must land on v1, not v3")
    }

    func testRestoringDeletesFilesTheTurnCreated() async throws {
        let checkpoint = await seal(message: "m1", [baseline("new.txt")])
        try write("new.txt", "created by the agent")
        XCTAssertTrue(exists("new.txt"))

        let outcome = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(outcome.deleted, [path("new.txt")])
        XCTAssertFalse(exists("new.txt"))
    }

    func testRestoringRecreatesAFileTheTurnDeleted() async throws {
        try write("gone.txt", "still needed")
        let checkpoint = await seal(message: "m1", [baseline("gone.txt")])
        try FileManager.default.removeItem(atPath: path("gone.txt"))

        _ = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(read("gone.txt"), "still needed")
    }

    /// A turn can remove the directory along with the file; restoring has to rebuild the path.
    func testRestoringRebuildsMissingParentDirectories() async throws {
        let nested = work.appendingPathComponent("deep/nest", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("deep/nest/file.txt", "keep me")
        let checkpoint = await seal(message: "m1", [baseline("deep/nest/file.txt")])
        try FileManager.default.removeItem(at: work.appendingPathComponent("deep"))

        let outcome = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(read("deep/nest/file.txt"), "keep me")
    }

    /// Later turns must go too — leaving them would offer a restore with no baseline behind it.
    func testRestoringDropsTheUndoneCheckpoints() async throws {
        try write("a.txt", "v1")
        let first = await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "v2")
        await seal(message: "m2", [baseline("a.txt")])

        _ = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(first).id)
        let remaining = await store.checkpoints(forSession: "s1")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRestoringOneTurnLeavesEarlierTurnsAvailable() async throws {
        try write("a.txt", "v1")
        await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "v2")
        let second = await seal(message: "m2", [baseline("a.txt")])
        try write("a.txt", "v3")

        _ = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(second).id)
        XCTAssertEqual(read("a.txt"), "v2")
        let remaining = await store.checkpoints(forSession: "s1")
        XCTAssertEqual(remaining.map(\.messageId), ["m1"])
    }

    // MARK: - The plan shown before anything is written

    func testPlanNamesEveryFileAndWritesNothing() async throws {
        try write("edited.txt", "before")
        let checkpoint = await seal(message: "m1", [
            baseline("edited.txt"),
            baseline("created.txt"),
        ])
        try write("edited.txt", "after")
        try write("created.txt", "new")

        let plan = await store.plan(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(plan.restore, [path("edited.txt")])
        XCTAssertEqual(plan.delete, [path("created.txt")])
        XCTAssertEqual(plan.turnsUndone, 1)
        XCTAssertEqual(plan.affectedCount, 2)

        // Nothing moved just because we asked.
        XCTAssertEqual(read("edited.txt"), "after")
        XCTAssertTrue(exists("created.txt"))
    }

    func testPlanForAnUnknownCheckpointIsEmpty() async {
        let plan = await store.plan(sessionId: "s1", checkpointId: "nope")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.turnsUndone, 0)
    }

    // MARK: - Honesty about what could not be kept

    /// A file too large to snapshot must be reported, not silently skipped: a restore the user
    /// believes was total, but wasn't, is worse than one that admits a gap.
    func testAFileTooLargeToSnapshotIsReportedAsUnrecoverable() async throws {
        let huge = String(repeating: "x", count: SessionCheckpointStore.maxBlobBytes + 1)
        try write("big.bin", huge)
        let checkpoint = await seal(message: "m1", [baseline("big.bin")])
        try write("big.bin", "clobbered")

        let plan = await store.plan(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(plan.unrecoverable, [path("big.bin")])
        XCTAssertTrue(plan.restore.isEmpty)

        let outcome = await store.restore(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(outcome.unrecoverable, [path("big.bin")])
        XCTAssertEqual(read("big.bin"), "clobbered", "the file is left as it is rather than half-restored")
    }

    @MainActor
    func testTheSummaryNamesUnrecoverableFiles() {
        let outcome = SessionCheckpointStore.RestoreOutcome(
            restored: ["/a"], deleted: [], failed: [], unrecoverable: ["/b"], turnsUndone: 1
        )
        let text = AppState.describeRestore(outcome)
        XCTAssertTrue(text.contains("Restored 1 file(s)"), text)
        XCTAssertTrue(text.contains("could not be snapshotted"), text)
    }

    // MARK: - Durability

    /// The whole reason this exists: quitting the app must not throw the history away.
    func testHistorySurvivesANewStoreOverTheSameDirectory() async throws {
        try write("a.txt", "original")
        let checkpoint = await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "changed")

        let reopened = SessionCheckpointStore(root: storeRoot)
        let all = await reopened.checkpoints(forSession: "s1")
        XCTAssertEqual(all.count, 1)

        _ = await reopened.restore(sessionId: "s1", checkpointId: try XCTUnwrap(checkpoint).id)
        XCTAssertEqual(read("a.txt"), "original")
    }

    func testRestorableMessageIdsCoverEveryRecordedTurn() async throws {
        try write("a.txt", "v1")
        await seal(message: "m1", [baseline("a.txt")])
        try write("a.txt", "v2")
        await seal(message: "m2", [baseline("a.txt")])

        let ids = await store.restorableMessageIds(forSession: "s1")
        XCTAssertEqual(ids, ["m1", "m2"])
    }

    func testDeletingASessionRemovesItsSnapshots() async throws {
        try write("a.txt", "v1")
        await seal(message: "m1", [baseline("a.txt")])
        await store.deleteAll(forSession: "s1")
        let all = await store.checkpoints(forSession: "s1")
        XCTAssertTrue(all.isEmpty)
    }

    func testSessionsDoNotSeeEachOthersCheckpoints() async throws {
        try write("a.txt", "v1")
        await seal(session: "s1", message: "m1", [baseline("a.txt")])
        let other = await store.checkpoints(forSession: "s2")
        XCTAssertTrue(other.isEmpty)
    }

    // MARK: - Bounds

    func testOldCheckpointsArePrunedOldestFirst() async throws {
        for index in 1...(SessionCheckpointStore.maxCheckpointsPerSession + 5) {
            try write("a.txt", "v\(index)")
            await seal(message: "m\(index)", [baseline("a.txt")])
        }
        let all = await store.checkpoints(forSession: "s1")
        XCTAssertEqual(all.count, SessionCheckpointStore.maxCheckpointsPerSession)
        XCTAssertEqual(all.first?.messageId, "m6", "the five oldest turns should have been dropped")
    }

    /// Twenty turns over one file should cost twenty digests, not twenty copies of the file.
    func testIdenticalContentIsStoredOnce() async throws {
        for index in 1...5 {
            try write("a.txt", "same every time")
            await seal(message: "m\(index)", [baseline("a.txt")])
        }
        let blobs = try FileManager.default.contentsOfDirectory(
            atPath: storeRoot.appendingPathComponent("s1/blobs").path
        )
        XCTAssertEqual(blobs.count, 1)
    }

    func testPruningCollectsBlobsNoCheckpointStillNeeds() async throws {
        for index in 1...(SessionCheckpointStore.maxCheckpointsPerSession + 3) {
            try write("a.txt", "unique-\(index)")
            await seal(message: "m\(index)", [baseline("a.txt")])
        }
        let blobs = try FileManager.default.contentsOfDirectory(
            atPath: storeRoot.appendingPathComponent("s1/blobs").path
        )
        XCTAssertEqual(
            blobs.count,
            SessionCheckpointStore.maxCheckpointsPerSession,
            "blobs belonging to pruned checkpoints should have been collected"
        )
    }
}
