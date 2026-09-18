import Foundation

/// The in-process MLX engine, as code that does not link MLX sees it.
///
/// `NativeMLXService` in SwiftOpenWorkLocalInference is the one implementation. The engine
/// module reaches it only through this protocol and `LocalInferenceRegistry`, so the engine — and
/// the tests that need only the engine — build without MLX.
public protocol InProcessModelEngine: LLMProviderClient {
    /// A short, single completion on the model already loaded, for editor suggestions. Throws
    /// rather than waiting behind another generation or evicting a different resident model.
    func oneShot(
        modelId: String,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        onVisibleText: @Sendable @escaping (String) -> Void,
        shouldStop: @Sendable @escaping () -> Bool
    ) async throws
}

/// Finds or starts a local OpenAI-compatible server (LM Studio, llama.cpp, `mlx_lm.server`, …).
/// `LocalMLXEngine` is the implementation.
public protocol LocalServerLauncher: Sendable {
    func ensureServerRunning(modelId: String?, settings: AppSettings?) async -> (success: Bool, message: String, activePort: Int)
}
