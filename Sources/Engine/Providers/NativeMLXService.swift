import Foundation
#if canImport(MLXLMCommon) && canImport(MLXLLM) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// In-process Apple Silicon Metal MLX Inference Engine.
/// Matches GrizzyClaw and Osaurus architecture using `mlx-swift-lm` directly on GPU.
public final class NativeMLXService: LLMProviderClient, @unchecked Sendable {
    public static let shared = NativeMLXService()

    private var loadedContainers: [String: ModelContainer] = [:]
    private let lock = NSLock()

    public init() {}

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        return true
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        return provider.models
    }

    public func streamChat(
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
        // If an external server is running, route to it
        if await LocalMLXEngine.shared.isServerRunning(port: 1337) {
            var fb = provider
            fb.baseUrl = "http://127.0.0.1:1337/v1"
            try await OpenAIService.shared.streamChat(
                provider: fb,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                onChunk: onChunk
            )
            return
        }

        let container = try await getOrLoadContainer(modelId: model.id) { _ in }
        let sanitizedInstructions = sanitizeForHFChatTemplate(systemPrompt)
        let preparedMessages = mergeToolMessagesIntoFollowingUser(messages)
        var mlxMessages: [Chat.Message] = preparedMessages.map { m in
            let cleanContent = sanitizeForHFChatTemplate(m.content)
            switch m.role {
            case .user:
                return Chat.Message(role: .user, content: cleanContent)
            case .assistant:
                return Chat.Message(role: .assistant, content: cleanContent)
            case .system:
                return Chat.Message(role: .system, content: cleanContent)
            case .tool:
                return Chat.Message(role: .user, content: "[Tool output]\n" + cleanContent)
            }
        }

        if !mlxMessages.contains(where: { $0.role == Chat.Message.Role.user }) {
            let fallback = preparedMessages.last(where: { $0.role == .user })?.content
                ?? preparedMessages.last?.content
                ?? "Continue."
            let insertAt = mlxMessages.firstIndex(where: { $0.role != Chat.Message.Role.system }) ?? mlxMessages.count
            mlxMessages.insert(
                Chat.Message(role: .user, content: sanitizeForHFChatTemplate(fallback)),
                at: insertAt
            )
        }

        guard let last = mlxMessages.last else {
            return
        }

        let history = Array(mlxMessages.dropLast())
        let session = ChatSession(
            container,
            instructions: sanitizedInstructions,
            history: history,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens > 0 ? maxTokens : 4096,
                temperature: Float(temperature)
            )
        )

        let stream = session.streamResponse(
            to: last.content,
            role: last.role,
            images: last.images,
            videos: [],
            audios: []
        )

        var totalTokens = 0
        for try await piece in stream {
            if Task.isCancelled { break }
            if !piece.isEmpty {
                totalTokens += 1
                onChunk(LLMStreamChunk(deltaText: piece))
            }
        }

        onChunk(LLMStreamChunk(isFinished: true, completionTokens: totalTokens))
    }

    private func getOrLoadContainer(
        modelId: String,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> ModelContainer {
        lock.lock()
        if let existing = loadedContainers[modelId] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchDirs = [
            home.appendingPathComponent(".openwork/mlx_models", isDirectory: true),
            home.appendingPathComponent(".grizzyclaw/mlx_models", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/GrizzyClaw/mlx_models", isDirectory: true),
            home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        ]

        var foundLocalDirectory: URL? = nil
        let sanitizedId = modelId.replacingOccurrences(of: "/", with: "--")
        let hubFolder = "models--" + sanitizedId

        for base in searchDirs {
            let direct = base.appendingPathComponent(modelId)
            let directSanitized = base.appendingPathComponent(sanitizedId)
            let snapshotDir = base.appendingPathComponent(hubFolder).appendingPathComponent("snapshots")

            if FileManager.default.fileExists(atPath: direct.appendingPathComponent("config.json").path) {
                foundLocalDirectory = direct
                break
            } else if FileManager.default.fileExists(atPath: directSanitized.appendingPathComponent("config.json").path) {
                foundLocalDirectory = directSanitized
                break
            } else if FileManager.default.fileExists(atPath: snapshotDir.path),
                      let snaps = try? FileManager.default.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil),
                      let first = snaps.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }) {
                foundLocalDirectory = first
                break
            }
        }

        let tokenizerLoader = #huggingFaceTokenizerLoader()
        let container: ModelContainer

        if let localDir = foundLocalDirectory {
            container = try await LLMModelFactory.shared.loadContainer(
                from: localDir,
                using: tokenizerLoader
            )
        } else {
            let cacheRoot = home.appendingPathComponent(".openwork/mlx_models/hub", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let hubClient = HubClient(cache: HubCache(cacheDirectory: cacheRoot))
            let downloader = #hubDownloader(hubClient)

            container = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: ModelConfiguration(id: modelId, revision: "main"),
                progressHandler: { progress in
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    onProgress("Loading MLX weights: \(pct)%")
                }
            )
        }

        lock.lock()
        loadedContainers[modelId] = container
        lock.unlock()

        return container
    }

    private func sanitizeForHFChatTemplate(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "{{", with: "{ {")
        s = s.replacingOccurrences(of: "{%", with: "{ %")
        return s
    }

    private func mergeToolMessagesIntoFollowingUser(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        var out: [ChatMessage] = []
        var i = messages.startIndex
        while i < messages.endIndex {
            let m = messages[i]
            if m.role != .tool {
                out.append(m)
                i = messages.index(after: i)
                continue
            }
            var combined = ""
            while i < messages.endIndex, messages[i].role == .tool {
                if !combined.isEmpty { combined += "\n\n" }
                combined += messages[i].content
                i = messages.index(after: i)
            }
            guard i < messages.endIndex, messages[i].role == .user else {
                out.append(ChatMessage(role: .user, content: "[Tool output]\n" + combined))
                continue
            }
            let u = messages[i]
            out.append(ChatMessage(role: .user, content: combined + "\n\n" + u.content))
            i = messages.index(after: i)
        }
        return out
    }
}
#else
/// Fallback client when MLX SPM packages are not linked in Xcode direct target.
public final class NativeMLXService: LLMProviderClient, @unchecked Sendable {
    public static let shared = NativeMLXService()
    public init() {}
    public func testConnection(provider: ModelProvider) async throws -> Bool { return true }
    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] { return provider.models }
    public func streamChat(
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
        try await OpenAIService.shared.streamChat(
            provider: provider,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            tools: tools,
            onChunk: onChunk
        )
    }
}
#endif
