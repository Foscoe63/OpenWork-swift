import XCTest
@testable import SwiftOpenWork

/// The shipped default must name the engine that ships in the binary.
///
/// These two sources of truth disagreed: `defaultProviders` marked the built-in Apple Silicon MLX
/// provider `isDefault: true`, while `AppSettings.default` named `ollama-local` — a separate app
/// that may not be installed. On the machine where this was found that Ollama provider was also
/// disabled, so selection fell through to "first enabled in array order" and landed on a *cloud*
/// provider, answering turns the user believed were running locally.
final class BuiltInProviderDefaultTests: XCTestCase {

    private var seeded: [ModelProvider] { PersistenceManager.shared.defaultProviders }

    /// Exactly one seeded provider claims to be the default, and it is the in-process MLX engine.
    func testTheSeededDefaultProviderIsTheBuiltInMLXEngine() {
        let defaults = seeded.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1, "exactly one provider should be marked isDefault")
        XCTAssertEqual(defaults.first?.kind, .omlx, "the built-in engine should be the default")
    }

    /// `AppSettings.default` must agree with that, or a fresh install ignores the built-in engine.
    func testSettingsDefaultNamesTheSeededDefaultProvider() {
        let settings = AppSettings.default
        guard let marked = seeded.first(where: \.isDefault) else {
            return XCTFail("no seeded provider is marked isDefault")
        }
        XCTAssertEqual(
            settings.defaultProviderId, marked.id,
            "AppSettings.default and defaultProviders must name the same provider"
        )
        XCTAssertTrue(
            marked.models.contains { $0.id == settings.defaultModelId },
            "the default model should belong to the default provider"
        )
    }

    /// Nothing may fall back to a cloud provider on a fresh, unconfigured install.
    func testAFreshInstallResolvesToTheBuiltInEngine() {
        let resolved = ProviderSelection.resolve(
            providers: seeded,
            selectedId: AppSettings.default.defaultProviderId
        )
        XCTAssertEqual(resolved?.provider.kind, .omlx)
        XCTAssertEqual(resolved?.provider.type, .local, "a fresh install must not resolve to a cloud provider")
        XCTAssertNil(resolved?.overrodeDisabled, "the default should not need overriding")
    }

    /// The last-resort id, used when no provider list is available at all, is the built-in engine.
    func testLastResortFallbackIsNotAThirdPartyApp() {
        XCTAssertEqual(
            ProviderSelection.correctedSelectionId(providers: [], selectedId: "gone"),
            AppSettings.default.defaultProviderId
        )
    }
}

/// The test suite must not rewrite the running app's own configuration.
///
/// `SandboxContainmentTests` saved a fresh `AppSettings.default` through the real
/// `PersistenceManager.shared`, so every full run reset the developer's settings to stock. The
/// handoff recorded the symptom — "`settings.json` had reverted to an Ollama default at some
/// point and was set back" — without ever finding the cause, and set it back by hand twice.
final class SettingsAreNotClobberedByTestsTests: XCTestCase {

    func testRunningTheSuiteLeavesRealSettingsIntact() throws {
        let store = PersistenceManager.shared
        let original = store.loadSettings()

        // A value no default would produce, so a stock overwrite is unmistakable.
        let sentinel = "sentinel-\(UUID().uuidString)"
        var marked = original
        marked.defaultModelId = sentinel
        store.saveSettings(marked)
        defer { store.saveSettings(original) }

        // Stand in for any test that needs a settings field flipped: read, modify, restore.
        let borrowed = store.loadSettings()
        var flipped = borrowed
        flipped.sandboxAgentFileSystem = !borrowed.sandboxAgentFileSystem
        store.saveSettings(flipped)
        store.saveSettings(borrowed)

        XCTAssertEqual(
            store.loadSettings().defaultModelId, sentinel,
            "a test borrowed the real settings and handed back stock defaults"
        )
    }
}

/// The built-in Apple Silicon provider runs in this process, or it fails. It never hands the turn
/// to something else.
///
/// It used to probe ports 1337, 8000, 8080, 11434, 1234 and 5243 on any in-process failure and
/// let whatever answered serve the turn — reported as if the built-in engine had produced it. So
/// a "local MLX" answer could come from Ollama, and a build with MLX missing looked like it was
/// working.
final class BuiltInMLXIsInProcessOnlyTests: XCTestCase {

    /// A model that cannot load fails with the in-process reason, not a server's.
    func testAFailedLoadDoesNotFallThroughToAServer() async {
        let provider = ModelProvider(
            id: "omlx-local", name: "Apple Silicon (Built-in)", type: .local, kind: .omlx,
            // A base URL is stored on this provider historically; nothing may dial it.
            baseUrl: "http://127.0.0.1:8000/v1", apiKey: "", isEnabled: true, models: []
        )
        let model = ModelInfo(id: "nobody/Not-A-Real-Model", name: "missing", providerId: "omlx-local")

        var streamed = ""
        do {
            try await NativeMLXService.shared.streamChat(
                provider: provider, model: model,
                systemPrompt: "", messages: [ChatMessage(role: .user, content: "hi")],
                temperature: 0.2, maxTokens: 8, reasoningEffort: .medium, tools: []
            ) { chunk in streamed += chunk.deltaText }

            XCTFail("a model the in-process engine cannot load must not be answered by anything else")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("is not downloaded on this Mac"),
                "expected the in-process reason, got: \(message)"
            )
            for port in ["1337", "8000", "8080", "11434", "1234", "5243"] {
                XCTAssertFalse(
                    message.contains(port),
                    "the failure should not mention probing port \(port)"
                )
            }
        }
        XCTAssertTrue(streamed.isEmpty, "no other backend should have produced tokens")
    }

    /// `.omlx` and `.vmlx` are the only kinds routed to the in-process engine, and they are the
    /// only ones that must never be answered over HTTP.
    func testOnlyTheInProcessKindsRouteToTheMLXService() {
        for kind in ProviderKind.allCases {
            let provider = ModelProvider(name: kind.rawValue, type: .local, kind: kind)
            let isMLXService = ProviderRouter.shared.client(for: provider) is NativeMLXService
            XCTAssertEqual(
                isMLXService, kind == .omlx || kind == .vmlx,
                "\(kind.rawValue) routed to the wrong client"
            )
        }
    }
}

/// The suite must never read or write the real app data.
final class TestDataIsolationTests: XCTestCase {

    func testThisProcessDoesNotUseTheRealDataFolder() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true)
        guard ProcessInfo.processInfo.environment["SWIFTOPENWORK_DATA_DIRECTORY"] == nil else { return }
        XCTAssertNotEqual(StorageService.shared.baseDirectory.standardizedFileURL, real.standardizedFileURL,
                          "tests are writing the user's real settings and sessions")
    }

    func testResolution() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        let temp = URL(fileURLWithPath: "/tmp/t")
        XCTAssertEqual(
            StorageService.resolveBaseDirectory(environment: [:], isTestProcess: false, applicationSupport: support, temporaryDirectory: temp, processIdentifier: 7).path,
            "/Users/me/Library/Application Support/\(AppIdentity.applicationSupportFolderName)"
        )
        XCTAssertEqual(
            StorageService.resolveBaseDirectory(environment: [:], isTestProcess: true, applicationSupport: support, temporaryDirectory: temp, processIdentifier: 7).path,
            "/tmp/t/SwiftOpenWork-tests-7"
        )
        XCTAssertEqual(
            StorageService.resolveBaseDirectory(environment: ["SWIFTOPENWORK_DATA_DIRECTORY": "/data/x"], isTestProcess: true, applicationSupport: support, temporaryDirectory: temp, processIdentifier: 7).path,
            "/data/x"
        )
    }
}
