import XCTest
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Tests used to run against the developer's real Application Support folder: `xcodebuild test`
/// launches the real app as host, and tests save settings through the shared store. A test that
/// crashed before restoring left real settings changed.
final class TestDataIsolationTests: XCTestCase {

    private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory())

    func testThisTestProcessIsNotUsingApplicationSupport() {
        let base = StorageService.shared.baseDirectory.path
        XCTAssertFalse(base.contains("Library/Application Support"), base)
        XCTAssertTrue(base.hasSuffix("-tests-\(ProcessInfo.processInfo.processIdentifier)"), base)
    }

    func testTheAppItselfStillUsesApplicationSupport() {
        let base = StorageService.resolveBaseDirectory(environment: [:], hostedByTests: false,
                                                       applicationSupport: support, temporaryDirectory: temporary, processIdentifier: 7)
        XCTAssertEqual(base.path, "/Users/someone/Library/Application Support/SwiftOpenWork")
    }

    /// A deliberate run against real data, such as a real agent turn, names the folder.
    func testAnExplicitDataFolderWinsEvenUnderTests() {
        let base = StorageService.resolveBaseDirectory(environment: [StorageService.dataDirectoryEnvironmentKey: "~/Data"],
                                                       hostedByTests: true, applicationSupport: support,
                                                       temporaryDirectory: temporary, processIdentifier: 7)
        XCTAssertEqual(base.path, NSHomeDirectory() + "/Data")
    }

    func testFoldersOfFinishedTestRunsAreRemovedAndLiveOnesKept() throws {
        let parent = temporary.appendingPathComponent("isolation-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: parent) }
        let finished = parent.appendingPathComponent(StorageService.testDirectoryPrefix + "111")
        let running = parent.appendingPathComponent(StorageService.testDirectoryPrefix + "222")
        let unrelated = parent.appendingPathComponent("SomethingElse-333")
        for url in [finished, running, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        StorageService.removeFinishedTestDirectories(in: parent, isRunning: { $0 == 222 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
