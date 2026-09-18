import Foundation
import os
import SwiftOpenWorkCore

/// Where the engine finds the in-process MLX engine and the local-server launcher.
///
/// The engine does not link MLX; the app registers `NativeMLXService` and `LocalMLXEngine` here at
/// launch. With nothing registered, the built-in provider fails and says why. It never falls
/// through to another backend: a turn sent to "Apple Silicon (Built-in)" must not be answered by
/// whatever happens to be listening on a local port.
public enum LocalInferenceRegistry {
    private struct Entries {
        var engine: (any InProcessModelEngine)?
        var serverLauncher: (any LocalServerLauncher)?
    }

    private static let entries = OSAllocatedUnfairLock(initialState: Entries())

    public static func register(engine: any InProcessModelEngine, serverLauncher: any LocalServerLauncher) {
        entries.withLock {
            $0.engine = engine
            $0.serverLauncher = serverLauncher
        }
    }

    /// The registered engine, or one that fails every request with the reason.
    public static var engine: any InProcessModelEngine {
        entries.withLock { $0.engine } ?? UnavailableInProcessEngine()
    }

    public static var serverLauncher: (any LocalServerLauncher)? {
        entries.withLock { $0.serverLauncher }
    }
}

/// Stands in for the MLX engine in a process that never registered one.
struct UnavailableInProcessEngine: InProcessModelEngine {
    static let message = "The built-in MLX engine is not part of this build."

    private var error: NSError {
        NSError(domain: "LocalInferenceRegistry", code: 1, userInfo: [NSLocalizedDescriptionKey: Self.message])
    }

    func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        throw error
    }

    func listModels(provider: ModelProvider) async throws -> [ModelInfo] { [] }

    func testConnection(provider: ModelProvider) async throws -> Bool { false }

    func oneShot(
        modelId: String,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        onVisibleText: @Sendable @escaping (String) -> Void,
        shouldStop: @Sendable @escaping () -> Bool
    ) async throws {
        throw error
    }
}
