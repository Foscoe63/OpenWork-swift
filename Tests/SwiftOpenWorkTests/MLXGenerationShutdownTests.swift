import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

/// A stopped generation used to keep evaluating on the GPU after `streamChat` returned. When the
/// process exited meanwhile, `exit` destroyed MLX's scheduler and compiler cache under it: SIGSEGV
/// in `CompilerCache::find`, or a Metal assertion, after every test had passed. Reproduced by
/// cancelling a real generation and exiting: 3 crashes in 3 runs before the fix, 0 in 5 after.
///
/// The crash itself happens after the test process reports, so these check the invariant that
/// prevents it: nothing is still generating once the call returns or quit has been prepared.
final class MLXGenerationShutdownTests: XCTestCase {

    private let provider = ModelProvider(id: "omlx-local", name: "Apple Silicon (Built-in)", type: .local, kind: .omlx,
                                         baseUrl: "", apiKey: "", isEnabled: true, models: [])

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func tick() { lock.withLock { count += 1 } }
        var tokens: Int { lock.withLock { count } }
    }

    /// The default model on the machine this was written on; skipped anywhere it is not installed.
    private func installedModel() throws -> ModelInfo {
        let id = "mlx-community/Ornith-1.5-35B-A3B-8bit"
        guard LocalMLXEngine.shared.resolveLocalModelDirectory(modelId: id, settings: PersistenceManager.shared.loadSettings()) != nil else {
            throw XCTSkip("\(id) is not on this machine")
        }
        return ModelInfo(id: id, name: "Ornith", providerId: provider.id)
    }

    private func startLongGeneration(_ model: ModelInfo, progress: Progress) -> Task<Void, Error> {
        let provider = self.provider
        return Task {
            try await NativeMLXService.shared.streamChat(
                provider: provider, model: model, systemPrompt: "",
                messages: [ChatMessage(role: .user, content: "Write a very long essay about the history of computing.")],
                temperature: 0.7, maxTokens: 4000, reasoningEffort: .low, tools: []
            ) { chunk in
                if !chunk.deltaText.isEmpty || !(chunk.deltaReasoning ?? "").isEmpty { progress.tick() }
            }
        }
    }

    private func waitForTokens(_ progress: Progress, atLeast count: Int) async throws {
        let deadline = Date().addingTimeInterval(600)
        while progress.tokens < count {
            guard Date() < deadline else { return XCTFail("the model produced no tokens") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testACancelledGenerationHasStoppedWhenTheCallReturns() async throws {
        let model = try installedModel()
        let progress = Progress()
        let run = startLongGeneration(model, progress: progress)
        try await waitForTokens(progress, atLeast: 5)

        run.cancel()
        _ = try? await run.value
        XCTAssertEqual(NativeMLXService.shared.activeGenerationCount, 0, "streamChat returned while MLX was still generating")
        let tokensAtReturn = progress.tokens
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(progress.tokens, tokensAtReturn, "tokens kept arriving after the call returned")
    }

    /// `applicationWillTerminate` calls this; a reply generating at quit must be stopped first.
    func testPreparingForExitStopsARunningGeneration() async throws {
        let model = try installedModel()
        let progress = Progress()
        let run = startLongGeneration(model, progress: progress)
        try await waitForTokens(progress, atLeast: 5)

        let stopped = await Task.detached { NativeMLXService.shared.prepareForExit(timeout: 30) }.value
        XCTAssertTrue(stopped, "the generation was still running when the wait gave up")
        XCTAssertLessThan(progress.tokens, 4000, "it was stopped, not run to its limit")
        _ = try? await run.value
        XCTAssertEqual(NativeMLXService.shared.activeGenerationCount, 0)
    }
}
