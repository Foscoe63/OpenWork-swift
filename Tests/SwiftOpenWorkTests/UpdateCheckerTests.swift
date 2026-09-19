import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

/// The Updates page had a disabled button and a disabled switch because nothing could be asked.
/// These pin the rules of the real check: newer is newer numerically, and nothing unverified is
/// ever reported as "up to date".
final class UpdateCheckerTests: XCTestCase {

    private func release(_ tag: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/Foscoe63/SwiftOpenWork/releases/tag/\#(tag)"}"#.utf8)
    }

    func testVersionsCompareNumericallyNotAsStrings() {
        XCTAssertLessThan(UpdateChecker.Version("1.9.3")!, UpdateChecker.Version("1.10.0")!)
        XCTAssertEqual(UpdateChecker.Version("1.1")!, UpdateChecker.Version("1.1.0")!)
        XCTAssertEqual(UpdateChecker.Version("v2.0.0")!.description, "2.0.0")
    }

    func testTagsThatAreNotVersionsAreRefusedRatherThanGuessed() {
        XCTAssertNil(UpdateChecker.Version("SWIFTOPENWORK"))
        XCTAssertNil(UpdateChecker.Version("1.2-beta"))
        XCTAssertNil(UpdateChecker.Version(""))
    }

    func testANewerReleaseIsReportedWithItsPage() {
        let outcome = UpdateChecker.evaluate(releaseJSON: release("1.2.0"), currentVersion: "1.1.0")
        guard case let .available(current, latest, url) = outcome else {
            return XCTFail("expected an available update, got \(outcome)")
        }
        XCTAssertEqual(current, "1.1.0")
        XCTAssertEqual(latest, "1.2.0")
        XCTAssertTrue(url.absoluteString.hasSuffix("/1.2.0"))
    }

    func testTheSameOrOlderReleaseIsUpToDate() {
        XCTAssertEqual(UpdateChecker.evaluate(releaseJSON: release("1.1.0"), currentVersion: "1.1.0"), .upToDate(current: "1.1.0"))
        XCTAssertEqual(UpdateChecker.evaluate(releaseJSON: release("1.0.2"), currentVersion: "1.1.0"), .upToDate(current: "1.1.0"))
    }

    /// GitHub's rate-limit reply is JSON with a `message` and no tag. That is a failure to check,
    /// not a confirmation that nothing is newer.
    func testARateLimitReplyIsAFailureNotUpToDate() {
        let body = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        guard case let .failed(reason) = UpdateChecker.evaluate(releaseJSON: body, currentVersion: "1.1.0") else {
            return XCTFail("a reply with no tag must not read as up to date")
        }
        XCTAssertTrue(reason.contains("rate limit"))
    }

    func testAnUnreadableTagOrMissingVersionIsAFailure() {
        if case .failed = UpdateChecker.evaluate(releaseJSON: release("SWIFTOPENWORK"), currentVersion: "1.1.0") {} else {
            XCTFail("a non-version tag must not be compared")
        }
        if case .failed = UpdateChecker.evaluate(releaseJSON: release("9.9.9"), currentVersion: nil) {} else {
            XCTFail("with no version of our own there is nothing to compare")
        }
    }

    func testAutomaticChecksAreThrottledToOnceADayAndRespectTheSwitch() {
        let now = Date()
        XCTAssertFalse(UpdateChecker.automaticCheckIsDue(enabled: false, lastCheck: nil, now: now))
        XCTAssertTrue(UpdateChecker.automaticCheckIsDue(enabled: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateChecker.automaticCheckIsDue(enabled: true, lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateChecker.automaticCheckIsDue(enabled: true, lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    }

    /// The Cloud Account and Connect pages were removed; a window closed on one must not reopen
    /// onto a tab the sidebar no longer has.
    func testRemovedSettingsTabsAreKnownToTheLayoutStore() {
        XCTAssertTrue(WindowLayoutStore.removedSettingsTabs.contains("cloud"))
        XCTAssertTrue(WindowLayoutStore.removedSettingsTabs.contains("connect"))
    }
}
