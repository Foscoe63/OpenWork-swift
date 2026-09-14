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

    public var loadedModelIds: [String] {
        lock.withLock { Array(loadedContainers.keys).sorted() }
    }

    public func isModelLoaded(_ modelId: String) -> Bool {
        lock.withLock { loadedContainers[modelId] != nil }
    }

    /// Evict an in-process model from Metal/RAM so another can be loaded.
    @discardableResult
    public func unload(modelId: String) -> Bool {
        let removed = lock.withLock { () -> Bool in
            guard loadedContainers.removeValue(forKey: modelId) != nil else { return false }
            recentLoadFailures[modelId] = nil
            return true
        }
        if removed {
            NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
        }
        return removed
    }

    /// Evict every in-process MLX model currently held in memory.
    @discardableResult
    public func unloadAll() -> Int {
        let count = lock.withLock { () -> Int in
            let n = loadedContainers.count
            loadedContainers.removeAll()
            recentLoadFailures.removeAll()
            return n
        }
        if count > 0 {
            NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
        }
        return count
    }

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
        var inProcessError: Error?
        do {
            try await streamInProcess(
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                tools: tools,
                onChunk: onChunk
            )
            return
        } catch {
            inProcessError = error
            // Fall through to optional local servers.
        }

        var lastServerError: Error?
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
                    lastServerError = error
                    continue
                }
            }
        }

        let inProcessDetail = inProcessError?.localizedDescription ?? "in-process load did not run"
        let serverDetail = lastServerError?.localizedDescription ?? "no local OpenAI-compatible / Ollama server responded on common ports"
        throw NSError(
            domain: "NativeMLXService",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: """
            Could not run model `\(model.id)`.

            In-process MLX: \(inProcessDetail)
            Local server fallback: \(serverDetail)

            Download a complete model in Local Models (all weight shards present), or pick Ollama / a cloud provider in the model switcher.
            """]
        )
    }

    private func streamInProcess(
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        tools: [Tool],
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
        let toolSpecs = Self.mlxToolSpecs(from: tools)
        let session = ChatSession(
            container,
            instructions: sanitizedInstructions,
            history: history,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens > 0 ? maxTokens : 4096,
                temperature: Float(temperature)
            ),
            tools: toolSpecs.isEmpty ? nil : toolSpecs
            // No toolDispatch — AgentRunner owns approval + MCP execution (Radiant shape).
            // streamDetails surfaces .toolCall for the outer loop.
        )

        let stream = session.streamDetails(
            to: last.content,
            role: last.role,
            images: last.images,
            videos: [],
            audios: []
        )

        var totalTokens = 0
        var emittedToolCalls: [ToolCallInfo] = []
        for try await generation in stream {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let piece):
                if !piece.isEmpty {
                    totalTokens += 1
                    onChunk(LLMStreamChunk(deltaText: piece))
                }
            case .toolCall(let call):
                let argsObject = call.function.arguments.mapValues { $0.anyValue }
                let argsJson: String
                if JSONSerialization.isValidJSONObject(argsObject),
                   let data = try? JSONSerialization.data(withJSONObject: argsObject),
                   let s = String(data: data, encoding: .utf8) {
                    argsJson = s
                } else {
                    argsJson = "{}"
                }
                let info = ToolCallInfo(
                    id: call.id ?? UUID().uuidString,
                    toolName: call.function.name,
                    argumentsJson: argsJson,
                    status: .running
                )
                emittedToolCalls.append(info)
                onChunk(LLMStreamChunk(toolCalls: [info]))
            case .info:
                break
            @unknown default:
                break
            }
        }

        onChunk(LLMStreamChunk(
            isFinished: true,
            completionTokens: totalTokens,
            toolCalls: emittedToolCalls
        ))
    }

    /// Map OpenWork `Tool` models into mlx-swift-lm `ToolSpec` dictionaries.
    private static func mlxToolSpecs(from tools: [Tool]) -> [ToolSpec] {
        tools.filter(\.isEnabled).compactMap { tool -> ToolSpec? in
            var parameters: [String: any Sendable] = [
                "type": "object",
                "properties": [String: any Sendable]()
            ]
            if let data = tool.parametersJsonSchema.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               !obj.isEmpty {
                parameters = toSendableDict(obj)
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": parameters
                ] as [String: any Sendable]
            ]
        }
    }

    private static func toSendableDict(_ dict: [String: Any]) -> [String: any Sendable] {
        var out: [String: any Sendable] = [:]
        for (k, v) in dict {
            out[k] = toSendable(v)
        }
        return out
    }

    private static func toSendable(_ value: Any) -> any Sendable {
        switch value {
        case let s as String: return s
        case let i as Int: return i
        case let d as Double: return d
        case let b as Bool: return b
        case let a as [Any]: return a.map { toSendable($0) }
        case let d as [String: Any]: return toSendableDict(d)
        case let n as NSNumber:
            // Distinguish Bool boxed as NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue
            }
            if n.doubleValue.rounded() == n.doubleValue,
               abs(n.doubleValue) < Double(Int.max) {
                return n.intValue
            }
            return n.doubleValue
        default:
            return String(describing: value)
        }
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
            NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
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
        let settings = PersistenceManager.shared.loadSettings()
        let tokenizerLoader = #huggingFaceTokenizerLoader()

        // Prefer an already-complete directory from the shared Storage Models library / other known roots.
        if let localDir = LocalMLXEngine.shared.resolveLocalModelDirectory(modelId: modelId, settings: settings) {
            onProgress("Loading local MLX weights from \(localDir.path)")
            return try await LLMModelFactory.shared.loadContainer(
                from: localDir,
                using: tokenizerLoader
            )
        }

        // Detect incomplete partial downloads under known roots (same lookup, without completeness).
        if let incomplete = Self.findIncompleteModelDirectory(modelId: modelId, settings: settings) {
            throw NSError(
                domain: "NativeMLXService",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: """
                Found an incomplete download for `\(modelId)` at:
                \(incomplete.path)

                Weight shards are missing or empty. Open Local Models and resume/re-download until the model shows as ready, or choose a different model from /Volumes/Storage/Models.
                """]
            )
        }

        onProgress("Downloading MLX weights for \(modelId)…")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheRoot = home.appendingPathComponent(".openwork/mlx_models/hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let hubClient = HubClient(cache: HubCache(cacheDirectory: cacheRoot))
        let downloader = #hubDownloader(hubClient)

        return try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: ModelConfiguration(id: modelId, revision: "main"),
            progressHandler: { progress in
                let pct = Int((progress.fractionCompleted * 100).rounded())
                onProgress("Loading MLX weights: \(pct)%")
            }
        )
    }

    private static func findIncompleteModelDirectory(modelId: String, settings: AppSettings) -> URL? {
        let roots = LocalMLXEngine.knownMLXSearchRoots(settings: settings)
        let sanitizedId = modelId.replacingOccurrences(of: "/", with: "--")
        for base in roots {
            let candidates = [
                base.appendingPathComponent(modelId),
                base.appendingPathComponent(sanitizedId),
                base.appendingPathComponent("models").appendingPathComponent(modelId),
                base.appendingPathComponent("models").appendingPathComponent(sanitizedId)
            ]
            for candidate in candidates {
                let configPath = candidate.appendingPathComponent("config.json").path
                if FileManager.default.fileExists(atPath: configPath),
                   !LocalMLXEngine.isModelDirectoryComplete(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// `config.json` alone is not proof a model is usable — an interrupted or cancelled download
    /// (including one killed by our own load timeout) can leave config.json and a handful of small
    /// metadata files on disk while most or all of the multi-gigabyte weight shards are missing.
    static func isModelDirectoryComplete(_ dir: URL) -> Bool {
        LocalMLXEngine.isModelDirectoryComplete(dir)
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

    public var loadedModelIds: [String] { [] }
    public func isModelLoaded(_ modelId: String) -> Bool { false }
    @discardableResult public func unload(modelId: String) -> Bool { false }
    @discardableResult public func unloadAll() -> Int { 0 }

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

        // 2) No reachable local server and no in-process MLX (packages not linked in this build).
        throw NSError(
            domain: "NativeMLXService",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: """
            Built-in MLX packages are not linked in this build, and no local inference server was reachable \
            (checked ports 1337, 8000, 11434, 1234, 8080, 5243).

            Rebuild with MLX SPM packages linked, start Ollama/LM Studio/Osaurus, or select a cloud provider.
            """]
        )
    }
}
#endif

public extension Notification.Name {
    static let mlxLoadedModelsDidChange = Notification.Name("mlxLoadedModelsDidChange")
}
