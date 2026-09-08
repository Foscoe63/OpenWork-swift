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
    private var recentLoadFailures: [String: Date] = [:]
    private let lock = NSLock()

    /// A model with no local weights on disk yet requires a Hugging Face download, which can be
    /// multiple gigabytes. Bound that attempt so a slow/offline network fails a chat turn quickly
    /// instead of hanging it, and don't retry the same doomed download on every subsequent message.
    private static let loadTimeoutSeconds: TimeInterval = 180
    private static let failureCooldown: TimeInterval = 300

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
        // Built-in path: run MLX in-process first (same as Osaurus / GrizzyClaw).
        // External HTTP servers are only a secondary option — never required.
        do {
            try await streamInProcess(
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                onChunk: onChunk
            )
            return
        } catch {
            // Fall through to optional local servers, then mock.
        }

        for port in [1337, 8000, 8080, 11434, 1234, 5243] {
            if await LocalMLXEngine.shared.isServerRunning(port: port) {
                var fb = provider
                fb.baseUrl = port == 11434
                    ? "http://127.0.0.1:11434"
                    : "http://127.0.0.1:\(port)/v1"
                let client: LLMProviderClient = port == 11434
                    ? OllamaService.shared
                    : OpenAIService.shared
                do {
                    try await client.streamChat(
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
                } catch {
                    continue
                }
            }
        }

        try await MockLLMService.shared.streamChat(
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

    private func streamInProcess(
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        let container = try await getOrLoadContainer(modelId: model.id) { status in
            // Surface download/load progress as reasoning so a first-run model fetch is visible
            // instead of looking like a hang; it never pollutes the final answer text.
            onChunk(LLMStreamChunk(deltaReasoning: status + "\n"))
        }
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
        if let existing = lock.withLock({ loadedContainers[modelId] }) {
            return existing
        }

        if let failedAt = lock.withLock({ recentLoadFailures[modelId] }),
           Date().timeIntervalSince(failedAt) < Self.failureCooldown {
            throw NSError(
                domain: "NativeMLXService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Skipping in-process MLX for '\(modelId)': a load attempt failed or timed out recently. Download it from the Local Models tab, or wait a few minutes before retrying."]
            )
        }

        do {
            let container = try await withThrowingTaskGroup(of: ModelContainer.self) { group in
                group.addTask {
                    try await self.loadContainerFromDiskOrDownload(modelId: modelId, onProgress: onProgress)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.loadTimeoutSeconds * 1_000_000_000))
                    throw NSError(
                        domain: "NativeMLXService",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Loading '\(modelId)' in-process took longer than \(Int(Self.loadTimeoutSeconds))s (likely still downloading weights). Falling back for this turn."]
                    )
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
            lock.withLock {
                loadedContainers[modelId] = container
                recentLoadFailures[modelId] = nil
            }
            return container
        } catch {
            lock.withLock { recentLoadFailures[modelId] = Date() }
            throw error
        }
    }

    private func loadContainerFromDiskOrDownload(
        modelId: String,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> ModelContainer {
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

            if Self.isModelDirectoryComplete(direct) {
                foundLocalDirectory = direct
                break
            } else if Self.isModelDirectoryComplete(directSanitized) {
                foundLocalDirectory = directSanitized
                break
            } else if FileManager.default.fileExists(atPath: snapshotDir.path),
                      let snaps = try? FileManager.default.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil),
                      let first = snaps.first(where: { Self.isModelDirectoryComplete($0) }) {
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

        return container
    }

    /// `config.json` alone is not proof a model is usable — an interrupted or cancelled download
    /// (including one killed by our own load timeout) can leave config.json and a handful of small
    /// metadata files on disk while most or all of the multi-gigabyte weight shards are missing.
    /// Treating that as "found locally" makes loadContainer fail on missing files instead of
    /// falling through to the downloader, which would otherwise resume the incomplete cache.
    static func isModelDirectoryComplete(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }

        func nonEmptyFileExists(_ path: String) -> Bool {
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int else { return false }
            return size > 0
        }

        let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: String] else {
                return false
            }
            let requiredShards = Set(weightMap.values)
            guard !requiredShards.isEmpty else { return false }
            return requiredShards.allSatisfy { nonEmptyFileExists(dir.appendingPathComponent($0).path) }
        }

        // No shard index: expect a single-file checkpoint alongside config.json.
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let weightFiles = contents.filter { $0.hasSuffix(".safetensors") }
        guard !weightFiles.isEmpty else { return false }
        return weightFiles.allSatisfy { nonEmptyFileExists(dir.appendingPathComponent($0).path) }
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
/// Fallback client when MLX SPM packages are not linked in the Xcode app target.
/// Prefers any already-running local OpenAI-compatible server; otherwise uses MockLLMService
/// so prompts still complete (tools/automations) instead of failing with a connection error.
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
        // 1) Prefer an already-running local server (Osaurus / oMLX / Ollama / LM Studio / vMLX)
        let probePorts = [1337, 8000, 11434, 1234, 8080, 5243]
        for port in probePorts {
            if await LocalMLXEngine.shared.isServerRunning(port: port) {
                var fb = provider
                fb.baseUrl = port == 11434
                    ? "http://127.0.0.1:11434"
                    : "http://127.0.0.1:\(port)/v1"
                let client: LLMProviderClient = port == 11434
                    ? OllamaService.shared
                    : OpenAIService.shared
                try await client.streamChat(
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
        }

        // 2) No reachable local server and no in-process MLX (packages not linked in Xcode).
        //    Keep chat usable instead of failing with "Could not connect to the server."
        try await MockLLMService.shared.streamChat(
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
