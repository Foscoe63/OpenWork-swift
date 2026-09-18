import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

final class ProviderSelectionTests: XCTestCase {

    private func provider(_ id: String, enabled: Bool) -> ModelProvider {
        var p = ModelProvider(name: id, type: .local, kind: .ollama)
        p.id = id
        p.isEnabled = enabled
        return p
    }

    func testSelectedEnabledProviderIsUsed() {
        let providers = [provider("a", enabled: true), provider("b", enabled: true)]
        let result = ProviderSelection.resolve(providers: providers, selectedId: "b")
        XCTAssertEqual(result?.provider.id, "b")
        XCTAssertNil(result?.overrodeDisabled)
    }

    /// The reported bug: settings named lmstudio-local, which was switched off, and every turn
    /// went to a server that was not running instead of falling back.
    func testDisabledSelectionFallsBackToAnEnabledProvider() {
        let providers = [provider("lmstudio-local", enabled: false), provider("openrouter", enabled: true)]
        let result = ProviderSelection.resolve(providers: providers, selectedId: "lmstudio-local")
        XCTAssertEqual(result?.provider.id, "openrouter")
        XCTAssertEqual(result?.overrodeDisabled, "lmstudio-local", "the override should be reportable")
    }

    func testUnknownSelectionFallsBackWithoutClaimingAnOverride() {
        let providers = [provider("a", enabled: true)]
        let result = ProviderSelection.resolve(providers: providers, selectedId: "ghost")
        XCTAssertEqual(result?.provider.id, "a")
        XCTAssertNil(result?.overrodeDisabled, "nothing was overridden — the id simply does not exist")
    }

    /// With nothing enabled, returning the named provider beats an unrelated placeholder.
    func testAllDisabledReturnsTheSelectedOne() {
        let providers = [provider("a", enabled: false), provider("b", enabled: false)]
        XCTAssertEqual(ProviderSelection.resolve(providers: providers, selectedId: "b")?.provider.id, "b")
    }

    func testEmptyListResolvesToNil() {
        XCTAssertNil(ProviderSelection.resolve(providers: [], selectedId: "a"))
    }

    // MARK: - Startup correction

    func testStaleDisabledSelectionIsCorrected() {
        let providers = [provider("lmstudio-local", enabled: false), provider("openrouter", enabled: true)]
        XCTAssertEqual(
            ProviderSelection.correctedSelectionId(providers: providers, selectedId: "lmstudio-local"),
            "openrouter"
        )
    }

    func testEnabledSelectionIsLeftAlone() {
        let providers = [provider("a", enabled: true), provider("b", enabled: true)]
        XCTAssertEqual(ProviderSelection.correctedSelectionId(providers: providers, selectedId: "a"), "a")
    }

    func testCorrectionFallsBackToTheDefaultIdWhenThereAreNoProviders() {
        XCTAssertEqual(
            ProviderSelection.correctedSelectionId(providers: [], selectedId: "x", fallback: "ollama-local"),
            "ollama-local"
        )
    }
}
