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
    /// Loads already running. A load that overran its deadline keeps going, and the next turn
    /// waits on the same task instead of starting a second copy of a 48GB read.
    private var inFlightLoads: [String: Task<ModelContainer, Error>] = [:]
    /// The live chat session and what it has already consumed, so a continuing conversation
    /// reuses its KV cache instead of re-prefilling the whole transcript every turn.
    private var cachedSession: ChatSession?
    private var cachedSessionKey: MLXSessionReuse.Key?
    private var cachedConsumed: [MLXSessionReuse.Fingerprint] = []
    private let lock = NSLock()

    /// Don't retry a doomed load on every subsequent message.
    private static let failureCooldown: TimeInterval = 300

    /// How long a load may make *no progress at all* before this turn gives up on it.
    ///
    /// This used to be a total budget, and that was measurably wrong in both directions. A 46GB
    /// Llama-3.3-70B on an external volume loaded in ~220s and answered — then the next turn gave
    /// up on the same load at 180s and reported the model unavailable, abandoning work it had
    /// already proved it could finish. A multi-gigabyte *download* fares worse still: it cannot
    /// possibly finish inside any fixed budget, so the turn always failed while the download was
    /// working perfectly.
    ///
    /// Time the silence instead. Loading and downloading both report progress continuously, so
    /// work that is moving is never abandoned however long it takes, and a load that is genuinely
    /// wedged still fails the turn rather than hanging it. The load keeps running either way and
    /// populates the cache, so the next turn is fast.
    private static let loadStallSeconds: TimeInterval = 180

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
            // A status chip, not reasoning. Loading a 50GB checkpoint needs to be visible so a
            // first run does not look like a hang, but it is the app's status, not the model's
            // thinking — and filed as reasoning it both polluted that transcript and could be
            // surfaced as the answer when a turn produced nothing else.
            onChunk(LLMStreamChunk(deltaNotice: status))
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
                // The merge above already labels tool output; this path only sees a stray
                // .tool message that never went through it.
                return Chat.Message(
                    role: .user,
                    content: cleanContent.hasPrefix("[Tool output]") ? cleanContent : "[Tool output]\n" + cleanContent
                )
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

        let toolSpecs = Self.mlxToolSpecs(from: tools)
        let key = MLXSessionReuse.Key(
            modelId: model.id,
            instructions: sanitizedInstructions,
            toolNames: tools.map(\.name)
        )
        let fingerprints = mlxMessages.map {
            MLXSessionReuse.Fingerprint(
                role: String(describing: $0.role),
                content: $0.content,
                hasAttachments: !$0.images.isEmpty || !$0.videos.isEmpty || !$0.audios.isEmpty
            )
        }

        let decision = lock.withLock {
            MLXSessionReuse.decide(
                cachedKey: cachedSession == nil ? nil : cachedSessionKey,
                cachedConsumed: cachedConsumed,
                incomingKey: key,
                incoming: fingerprints
            )
        }

        let session: ChatSession
        let stream: AsyncThrowingStream<Generation, Error>

        switch decision {
        case .advance(let new):
            // Continue the live session: only the messages it has not seen are prefilled.
            let reused = lock.withLock { cachedSession }!
            session = reused
            let appended = Array(mlxMessages[new.startIndex...])
            stream = reused.streamDetails(to: appended)
            lock.withLock { cachedConsumed = fingerprints }

        case .rebuild(let reason):
            if reason != "no cached session" {
                onChunk(LLMStreamChunk(deltaNotice: "Context cache reset: \(reason)"))
            }
            let history = Array(mlxMessages.dropLast())
            let fresh = ChatSession(
                container,
                instructions: sanitizedInstructions,
                history: history,
                generateParameters: Self.generateParameters(
                    maxTokens: maxTokens,
                    temperature: temperature
                ),
                tools: toolSpecs.isEmpty ? nil : toolSpecs
                // No toolDispatch — AgentRunner owns approval + MCP execution (Radiant shape).
                // streamDetails surfaces .toolCall for the outer loop.
            )
            session = fresh
            stream = fresh.streamDetails(
                to: last.content,
                role: last.role,
                images: last.images,
                videos: [],
                audios: []
            )
            lock.withLock {
                cachedSession = fresh
                cachedSessionKey = key
                cachedConsumed = fingerprints
            }
        }
        _ = session

        var totalTokens = 0
        var emittedToolCalls: [ToolCallInfo] = []
        // What the model produced this turn. MLX appends its own reply to the session's cache,
        // so the reply has to be recorded as consumed too — otherwise the next turn re-sends it
        // and the conversation gains a duplicate the user never wrote.
        var assistantText = ""
        var completedNormally = false
        defer {
            lock.withLock {
                guard cachedSession != nil else { return }
                if completedNormally {
                    cachedConsumed.append(
                        MLXSessionReuse.Fingerprint(
                            role: "assistant",
                            content: assistantText,
                            isGeneratedReply: true
                        )
                    )
                } else {
                    // Cancelled or thrown mid-generation: the session holds a partial reply we
                    // cannot describe, so the cache can no longer be trusted to match.
                    cachedSession = nil
                    cachedSessionKey = nil
                    cachedConsumed = []
                }
            }
        }

        for try await generation in stream {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let piece):
                if !piece.isEmpty {
                    totalTokens += 1
                    assistantText += piece
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
        completedNormally = !Task.isCancelled

        onChunk(LLMStreamChunk(
            isFinished: true,
            completionTokens: totalTokens,
            toolCalls: emittedToolCalls
        ))
    }

    /// Map OpenWork `Tool` models into mlx-swift-lm `ToolSpec` dictionaries.
    /// Sampling parameters for the in-process path.
    ///
    /// This path previously passed only maxTokens and temperature, so every penalty setting was
    /// silently inert — including `autoAdjustPenaltiesForLocalModels`, which exists precisely for
    /// local models and which the Ollama and OpenAI paths both honour. Repetition penalties are
    /// what stop a local model looping, so the one path most in need of them had none.
    static func generateParameters(
        maxTokens: Int,
        temperature: Double,
        settings: AppSettings? = nil
    ) -> GenerateParameters {
        let s = settings ?? PersistenceManager.shared.loadSettings()
        let boost = s.autoAdjustPenaltiesForLocalModels
        // Same floors the Ollama path applies for local endpoints.
        let repetition = boost ? max(1.20, s.defaultRepeatPenalty) : s.defaultRepeatPenalty
        let presence = boost ? max(0.30, s.defaultPresencePenalty) : s.defaultPresencePenalty
        let frequency = boost ? max(0.30, s.defaultFrequencyPenalty) : s.defaultFrequencyPenalty

        return GenerateParameters(
            maxTokens: maxTokens > 0 ? maxTokens : 4096,
            temperature: Float(temperature),
            topP: Float(s.defaultTopP > 0 ? s.defaultTopP : 1.0),
            // A penalty of 1.0 / 0.0 is a no-op; pass nil so MLX skips the processor entirely.
            repetitionPenalty: repetition > 1.0 ? Float(repetition) : nil,
            presencePenalty: presence > 0 ? Float(presence) : nil,
            frequencyPenalty: frequency > 0 ? Float(frequency) : nil
        )
    }

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

    /// Start loading `modelId` into memory without waiting for it.
    ///
    /// The first turn against a large local model pays the whole load — minutes, for a 35GB
    /// checkpoint — while the user watches a spinner. Doing it at launch, when they are not
    /// waiting on an answer, moves that cost somewhere it does not block anything.
    ///
    /// Fire-and-forget on purpose: a failure here is not worth surfacing, because nothing has been
    /// asked for yet, and the real request will report it properly. `getOrLoadContainer` already
    /// shares one in-flight load per model, so a turn starting mid-preload joins it rather than
    /// loading a second copy.
    public func preload(modelId: String) {
        guard !modelId.isEmpty else { return }
        guard lock.withLock({ loadedContainers[modelId] == nil && inFlightLoads[modelId] == nil }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            _ = try? await self?.getOrLoadContainer(modelId: modelId, onProgress: { _ in })
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

        // One load per model, shared by every caller. MLX's loader never checks for cancellation,
        // so racing it inside a task group blocked on the load it was meant to abandon: the
        // "falling back for this turn" message could not be honoured, and a 48GB read hung the
        // turn instead. The load now runs on its own task, outlives the deadline, and caches
        // itself when it finishes — so overrunning once makes the next turn fast rather than
        // starting over.
        // Every progress report resets the watchdog, so a load that is moving is never abandoned.
        let clock = AsyncDeadline.ProgressClock()
        let trackedProgress: @Sendable (String) -> Void = { status in
            clock.tick()
            onProgress(status)
        }

        let task: Task<ModelContainer, Error> = lock.withLock {
            if let existing = inFlightLoads[modelId] { return existing }
            let created = Task<ModelContainer, Error> {
                let container = try await self.loadContainerFromDiskOrDownload(
                    modelId: modelId, onProgress: trackedProgress
                )
                self.lock.withLock {
                    self.loadedContainers[modelId] = container
                    self.recentLoadFailures[modelId] = nil
                    self.inFlightLoads[modelId] = nil
                }
                NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
                return container
            }
            inFlightLoads[modelId] = created
            return created
        }

        do {
            return try await AsyncDeadline.wait(
                for: task,
                stalledAfter: Self.loadStallSeconds,
                clock: clock
            )
        } catch is AsyncDeadline.TimedOut {
            // Deliberately not recorded as a failure: the load is still running and will be
            // waiting in the cache shortly.
            throw NSError(
                domain: "NativeMLXService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Loading '\(modelId)' in-process has reported no progress for \(Int(Self.loadStallSeconds))s. It is still running in the background — this turn falls back; try again once it finishes."]
            )
        } catch {
            lock.withLock {
                recentLoadFailures[modelId] = Date()
                inFlightLoads[modelId] = nil
            }
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

        do {
            return try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: ModelConfiguration(id: modelId, revision: "main"),
                progressHandler: { progress in
                    let pct = Int((progress.fractionCompleted * 100).rounded())
                    onProgress("Loading MLX weights: \(pct)%")
                }
            )
        } catch {
            throw Self.describeDownloadFailure(error, modelId: modelId)
        }
    }

    /// Turn a Hugging Face download failure into something the user can act on.
    ///
    /// The raw error is `The operation couldn't be completed. (HuggingFace.HTTPClientError error
    /// 1.)`, which names neither the repo nor the reason. In the case that produced it, the repo
    /// simply did not exist — the app's own curated catalog held an id that 401s — and the user had
    /// no way to tell that from a network problem or a half-finished download.
    static func describeDownloadFailure(_ error: Error, modelId: String) -> Error {
        let raw = error.localizedDescription
        let nsError = error as NSError

        // Hugging Face answers 401 for a repo that does not exist as well as one that is private,
        // so both possibilities have to be offered rather than asserting the wrong one.
        let looksLikeMissingRepo = raw.contains("HTTPClientError")
            || nsError.code == 401 || nsError.code == 403 || nsError.code == 404

        let offline = (error as? URLError)?.code == .notConnectedToInternet
            || (error as? URLError)?.code == .cannotFindHost

        let explanation: String
        if offline {
            explanation = "This Mac appears to be offline, so the weights could not be fetched."
        } else if looksLikeMissingRepo {
            explanation = """
            Hugging Face would not serve `\(modelId)`. That repo is either missing, renamed, or \
            private — Hugging Face answers the same way for all three.

            Check the id at https://huggingface.co/\(modelId), or pick a model that is already \
            downloaded in Local Models.
            """
        } else {
            explanation = "The download failed: \(raw)"
        }

        return NSError(
            domain: "NativeMLXService",
            code: 13,
            userInfo: [
                NSLocalizedDescriptionKey: explanation,
                NSUnderlyingErrorKey: error
            ]
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

    /// Render tool results as their own user messages.
    ///
    /// Chat templates have no `tool` role, so results must arrive as user turns. They are emitted
    /// standalone and never folded into the message that follows, which is what makes the
    /// rendered transcript **append-only**: a result reads identically whether or not something
    /// comes after it.
    ///
    /// The previous version merged a run of tool results into the *next* user message, so the
    /// same result rendered one way while trailing and another once a user message landed after
    /// it. That silently rewrote earlier entries on every call, which defeated KV cache reuse
    /// (`MLXSessionReuse` correctly saw the prefix change and rebuilt) and made prompt caching
    /// impossible in principle, not just here.
    ///
    /// Consecutive results are still combined with each other — that run is complete once it ends,
    /// so combining them does not depend on anything later.
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
            out.append(ChatMessage(role: .user, content: "[Tool output]\n" + combined))
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
    public func preload(modelId: String) {}

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
