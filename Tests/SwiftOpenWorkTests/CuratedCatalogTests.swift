import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkLocalInference

/// The curated catalog is a list of download targets. Five of fifteen ids pointed at Hugging Face
/// repos that do not exist, so the app offered models it could never fetch. Whether a repo exists
/// can only be answered over the network — `Scripts/check-curated-models.sh` does that, and CI
/// must not fail because Hugging Face is slow. These pin the parts that are checkable offline.
final class CuratedCatalogTests: XCTestCase {

    private var models: [LocalMLXModel] { LocalMLXEngine.curatedModels }

    func testEveryIdIsAnOrgSlashNameRepoPath() {
        for model in models {
            let parts = model.id.split(separator: "/")
            XCTAssertEqual(parts.count, 2, "\(model.id) is not a Hugging Face repo path")
            XCTAssertFalse(parts.contains { $0.isEmpty }, model.id)
        }
    }

    /// Two entries with the same id render as duplicate rows and download over each other.
    func testIdsAreUnique() {
        let ids = models.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate id in the curated catalog")
    }

    /// Repo paths are case-sensitive; one entry 307'd purely on capitalisation.
    func testIdsHaveNoSurroundingWhitespaceOrTrailingSlash() {
        for model in models {
            XCTAssertEqual(model.id, model.id.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(model.id.hasSuffix("/"), model.id)
        }
    }

    /// The size drives the compatibility badge and the storage warning, so a placeholder is a
    /// number the user makes a decision on.
    func testEveryEntryDeclaresAPlausibleSize() {
        for model in models {
            let size = try? XCTUnwrap(model.sizeBytes, "\(model.id) declares no size")
            XCTAssertGreaterThan(size ?? 0, 100_000_000, "\(model.id) claims an implausible size")
        }
    }

    func testNamesAndDescriptionsArePresent() {
        for model in models {
            XCTAssertFalse(model.name.trimmingCharacters(in: .whitespaces).isEmpty, model.id)
            XCTAssertFalse(model.description.trimmingCharacters(in: .whitespaces).isEmpty, model.id)
        }
    }
}

/// `The operation couldn't be completed. (HuggingFace.HTTPClientError error 1.)` names neither the
/// repo nor the reason. It was shown for a repo that did not exist, and the user could not tell
/// that from a network fault.
final class DownloadFailureMessageTests: XCTestCase {

    private func describe(_ error: Error, id: String = "mlx-community/Nope-7B") -> String {
        NativeMLXService.describeDownloadFailure(error, modelId: id).localizedDescription
    }

    func testAMissingRepoNamesTheRepoAndSaysWhatToCheck() {
        let raw = NSError(
            domain: "HuggingFace.HTTPClientError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (HuggingFace.HTTPClientError error 1.)"]
        )
        let message = describe(raw)
        XCTAssertTrue(message.contains("mlx-community/Nope-7B"), "the message must name the repo")
        XCTAssertTrue(message.contains("huggingface.co"), "and where to check it")
    }

    /// Hugging Face answers identically for missing, renamed and private repos, so the message
    /// must offer all three rather than asserting one.
    func testItDoesNotClaimToKnowWhichOfTheThreeItIs() {
        let raw = NSError(domain: "HuggingFace.HTTPClientError", code: 1)
        let message = describe(raw).lowercased()
        XCTAssertTrue(message.contains("missing"))
        XCTAssertTrue(message.contains("renamed"))
        XCTAssertTrue(message.contains("private"))
    }

    func testBeingOfflineIsReportedAsBeingOffline() {
        let message = describe(URLError(.notConnectedToInternet))
        XCTAssertTrue(message.lowercased().contains("offline"))
        XCTAssertFalse(message.contains("huggingface.co"), "this is not a bad-id problem")
    }

    /// An unrecognised failure must pass the original through rather than inventing a diagnosis.
    func testAnUnknownFailureKeepsItsOwnText() {
        let raw = NSError(
            domain: "Disk", code: 28,
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
        XCTAssertTrue(describe(raw).contains("No space left on device"))
    }

    func testTheOriginalErrorIsKeptForDebugging() {
        let raw = NSError(domain: "Disk", code: 28)
        let wrapped = NativeMLXService.describeDownloadFailure(raw, modelId: "a/b") as NSError
        XCTAssertNotNil(wrapped.userInfo[NSUnderlyingErrorKey])
    }
}
