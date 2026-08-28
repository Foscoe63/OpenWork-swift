import Foundation

public final class OpenAIService: LLMProviderClient, @unchecked Sendable {
    public static let shared = OpenAIService()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models"
        guard let url = URL(string: endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.customHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.timeoutInterval = 8
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode == 200 || http.statusCode == 401 || http.statusCode == 403
        }
        return false
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        let trimmedBase = provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Potential model listing endpoints for OpenAI-compatible, oMLX, vMLX, and local MLX servers:
        var candidateEndpoints: [String] = []
        
        // Derive host root without /v1 or /v2
        var rootBase = trimmedBase
        if rootBase.hasSuffix("/v1") {
            rootBase = String(rootBase.dropLast(3))
        } else if rootBase.hasSuffix("/v2") {
            rootBase = String(rootBase.dropLast(3))
        }
        
        // 1. Standard OpenAI v1 endpoints
        candidateEndpoints.append("\(trimmedBase)/models")
        candidateEndpoints.append("\(rootBase)/v1/models")
        candidateEndpoints.append("\(rootBase)/models")
        
        // 2. oMLX, vMLX, and MLX-LM local server endpoints
        candidateEndpoints.append("\(rootBase)/api/models")
        candidateEndpoints.append("\(rootBase)/api/tags")
        candidateEndpoints.append("\(rootBase)/api/v1/models")
        candidateEndpoints.append("\(rootBase)/v1/models/list")
        candidateEndpoints.append("\(rootBase)/models/list")
        candidateEndpoints.append("\(rootBase)/local_models")
        candidateEndpoints.append("\(rootBase)/api/local_models")
        candidateEndpoints.append("\(rootBase)/api/downloaded_models")
        candidateEndpoints.append("\(rootBase)/downloaded_models")
        candidateEndpoints.append("\(rootBase)/api/installed_models")
        candidateEndpoints.append("\(rootBase)/installed_models")
        candidateEndpoints.append("\(rootBase)/api/available_models")
        candidateEndpoints.append("\(rootBase)/available_models")

        var lastError: Error? = nil

        for endpoint in candidateEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if !provider.apiKey.isEmpty {
                request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
            }
            for (k, v) in provider.customHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
            request.timeoutInterval = 4

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }

                if let models = parseModelsResponse(data: data, provider: provider), !models.isEmpty {
                    return models
                }
            } catch {
                lastError = error
            }
        }

        // If dynamic endpoints didn't return models, check if server is reachable and throw or return empty
        // Don't silently return hardcoded default dummy models when the user explicitly queries their server!
        if let lastError = lastError {
            throw lastError
        }
        return []
    }

    private func parseModelsResponse(data: Data, provider: ModelProvider) -> [ModelInfo]? {
        // Attempt 1: Standard OpenAI format { "data": [ { "id": "...", ... } ] }
        struct OpenAIModelsResponse: Codable {
            struct Item: Codable {
                let id: String
                let name: String?
                let owned_by: String?
            }
            let data: [Item]?
        }
        if let parsed = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data),
           let list = parsed.data, !list.isEmpty {
            return list.map { m in
                makeModelInfo(id: m.id, name: m.name, ownedBy: m.owned_by, providerId: provider.id)
            }
        }

        // Attempt 2: Direct array at root: [ { "id": "..." } ] or [ "mlx-community/...", "..." ]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var results: [ModelInfo] = []
            for item in array {
                if let id = item["id"] as? String ?? item["name"] as? String ?? item["model"] as? String ?? item["model_name"] as? String ?? item["repo_id"] as? String ?? item["path"] as? String {
                    let name = item["name"] as? String ?? item["display_name"] as? String
                    results.append(makeModelInfo(id: id, name: name, ownedBy: item["owned_by"] as? String, providerId: provider.id))
                }
            }
            if !results.isEmpty { return results }
        }

        if let strArray = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return strArray.map { makeModelInfo(id: $0, name: nil, ownedBy: nil, providerId: provider.id) }
        }

        // Attempt 3: JSON dict with common keys ("models", "data", "result", "items", "loaded_models", "downloaded_models", "local_models", "installed_models")
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidates = ["models", "data", "result", "items", "loaded_models", "available_models", "downloaded_models", "local_models", "installed_models", "tags"]
            for key in candidates {
                if let list = dict[key] as? [[String: Any]] {
                    var results: [ModelInfo] = []
                    for item in list {
                        if let id = item["id"] as? String ?? item["name"] as? String ?? item["model"] as? String ?? item["model_name"] as? String ?? item["repo_id"] as? String ?? item["path"] as? String {
                            let name = item["name"] as? String ?? item["display_name"] as? String
                            results.append(makeModelInfo(id: id, name: name, ownedBy: item["owned_by"] as? String, providerId: provider.id))
                        }
                    }
                    if !results.isEmpty { return results }
                } else if let list = dict[key] as? [String] {
                    return list.map { makeModelInfo(id: $0, name: nil, ownedBy: nil, providerId: provider.id) }
                }
            }

            // Attempt 4: Dictionary of models as key-values: { "models": { "model_id_1": {...}, "model_id_2": {...} } } or root dictionary of model objects
            for key in candidates {
                if let map = dict[key] as? [String: Any] {
                    var results: [ModelInfo] = []
                    for (k, v) in map {
                        if let vDict = v as? [String: Any] {
                            let id = vDict["id"] as? String ?? vDict["model"] as? String ?? k
                            let name = vDict["name"] as? String ?? vDict["display_name"] as? String
                            results.append(makeModelInfo(id: id, name: name, ownedBy: vDict["owned_by"] as? String, providerId: provider.id))
                        } else {
                            results.append(makeModelInfo(id: k, name: nil, ownedBy: nil, providerId: provider.id))
                        }
                    }
                    if !results.isEmpty { return results }
                }
            }

            // Attempt 5: Single loaded model response (e.g. { "model": "...", "status": "loaded" })
            if let singleName = dict["model"] as? String ?? dict["loaded_model"] as? String ?? dict["active_model"] as? String ?? dict["model_path"] as? String ?? dict["repo_id"] as? String {
                return [makeModelInfo(id: singleName, name: nil, ownedBy: "active", providerId: provider.id)]
            }
        }

        return nil
    }

    private func makeModelInfo(id: String, name: String?, ownedBy: String?, providerId: String) -> ModelInfo {
        let isReasoning = id.contains("r1") || id.contains("o1") || id.contains("o3") || id.contains("reason")
        let displayName = name ?? id.components(separatedBy: "/").last ?? id
        return ModelInfo(
            id: id,
            name: displayName,
            providerId: providerId,
            contextWindow: 128000,
            supportsVision: id.contains("4o") || id.contains("vision") || id.contains("vl") || id.contains("claude") || id.contains("pixtral"),
            supportsReasoning: isReasoning,
            supportsStreaming: true,
            supportsTools: id.contains("coder") || id.contains("gpt") || id.contains("claude") || id.contains("qwen"),
            description: "Provider model (\(ownedBy ?? "standard"))",
            speedTier: isReasoning ? "Powerful" : "Fast"
        )
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
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "OpenAIService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.customHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        var formattedMessages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            formattedMessages.append(["role": "system", "content": systemPrompt])
        }
        for msg in messages {
            if msg.role == .tool {
                formattedMessages.append([
                    "role": "tool",
                    "content": msg.content,
                    "tool_call_id": msg.id
                ])
            } else {
                formattedMessages.append(["role": msg.role.rawValue, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": model.id,
            "messages": formattedMessages,
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        if model.supportsReasoning && reasoningEffort != .off {
            body["reasoning_effort"] = reasoningEffort.rawValue
        }

        // Add native structured tool schemas if tools are provided
        if !tools.isEmpty {
            var toolsArray: [[String: Any]] = []
            for t in tools where t.isEnabled {
                var parametersDict: [String: Any] = ["type": "object", "properties": [String: Any]()]
                if let data = t.parametersJsonSchema.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   !parsed.isEmpty {
                    parametersDict = parsed
                } else {
                    // Provide automatic typed schema based on tool type
                    switch t.name {
                    case "file_read":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Relative or absolute path to the file to read"]
                            ],
                            "required": ["path"]
                        ]
                    case "file_write":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Relative or absolute path to the file to write"],
                                "content": ["type": "string", "description": "Text or code content to write to the file"]
                            ],
                            "required": ["path", "content"]
                        ]
                    case "file_list":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Directory path to list files for"]
                            ]
                        ]
                    case "terminal_command":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "command": ["type": "string", "description": "Bash/zsh shell command to execute"],
                                "cwd": ["type": "string", "description": "Working directory path for execution"]
                            ],
                            "required": ["command"]
                        ]
                    case "web_search":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "Search engine query string"]
                            ],
                            "required": ["query"]
                        ]
                    case "calculator":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "expression": ["type": "string", "description": "Mathematical formula to evaluate"]
                            ],
                            "required": ["expression"]
                        ]
                    case "document_extract", "extract_document", "read_pdf_or_image":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "File path to PDF document or image for OCR"]
                            ],
                            "required": ["path"]
                        ]
                    case "workspace_semantic_search":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "Semantic query or concept to search across workspace code"],
                                "top_k": ["type": "integer", "description": "Number of top matches to return"]
                            ],
                            "required": ["query"]
                        ]
                    case "agent_spawn":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "task_title": ["type": "string", "description": "Short title of the delegated sub-task"],
                                "task_description": ["type": "string", "description": "Detailed instructions for the sub-agent"],
                                "subagent_id": ["type": "string", "description": "Target sub-agent identifier (e.g. coder-agent, reviewer-agent, research-agent)"],
                                "subagent_name": ["type": "string", "description": "Display name of the target sub-agent"]
                            ],
                            "required": ["task_title", "task_description"]
                        ]
                    case "agent_message":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "to_agent_id": ["type": "string", "description": "Target agent ID or 'broadcast'"],
                                "to_agent_name": ["type": "string", "description": "Target agent name"],
                                "content": ["type": "string", "description": "Message content or query to deliver to the other agent"],
                                "message_type": ["type": "string", "description": "Type: task_delegation, task_response, consultation, or broadcast"]
                            ],
                            "required": ["content"]
                        ]
                    default:
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "parameters": ["type": "string", "description": "Tool parameters in string or JSON form"]
                            ]
                        ]
                    }
                }

                toolsArray.append([
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        "parameters": parametersDict
                    ]
                ])
            }
            if !toolsArray.isEmpty {
                body["tools"] = toolsArray
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw NSError(domain: "OpenAIService", code: status, userInfo: [NSLocalizedDescriptionKey: "Provider returned HTTP status \(status)"])
        }

        // Track accumulating tool calls across streaming deltas
        var pendingToolCalls: [Int: (id: String, name: String, args: String)] = [:]

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                // Finalize any pending streamed tool calls
                var finalizedTools: [ToolCallInfo] = []
                for (_, tc) in pendingToolCalls {
                    finalizedTools.append(ToolCallInfo(
                        id: tc.id.isEmpty ? UUID().uuidString : tc.id,
                        toolName: tc.name,
                        argumentsJson: tc.args.isEmpty ? "{}" : tc.args,
                        status: .running
                    ))
                }
                onChunk(LLMStreamChunk(isFinished: true, toolCalls: finalizedTools))
                break
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            
            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                let finishReason = first["finish_reason"] as? String
                var text = ""
                var reasoning: String? = nil
                var deltaToolCalls: [ToolCallInfo] = []
                
                if let delta = first["delta"] as? [String: Any] {
                    text = delta["content"] as? String ?? ""
                    if let reason = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String {
                        reasoning = reason
                    }

                    // Native tool_calls delta parsing
                    if let tcArray = delta["tool_calls"] as? [[String: Any]] {
                        for (idx, tc) in tcArray.enumerated() {
                            let callIndex = tc["index"] as? Int ?? idx
                            let callId = tc["id"] as? String ?? ""
                            var functionName = ""
                            var argsDelta = ""

                            if let fn = tc["function"] as? [String: Any] {
                                functionName = fn["name"] as? String ?? ""
                                argsDelta = fn["arguments"] as? String ?? ""
                            }

                            let prev = pendingToolCalls[callIndex] ?? (id: callId, name: functionName, args: "")
                            let updatedId = callId.isEmpty ? prev.id : callId
                            let updatedName = functionName.isEmpty ? prev.name : functionName
                            let updatedArgs = prev.args + argsDelta
                            pendingToolCalls[callIndex] = (id: updatedId, name: updatedName, args: updatedArgs)

                            deltaToolCalls.append(ToolCallInfo(
                                id: updatedId.isEmpty ? UUID().uuidString : updatedId,
                                toolName: updatedName,
                                argumentsJson: updatedArgs,
                                status: .running
                            ))
                        }
                    }
                }
                
                let usage = json["usage"] as? [String: Any]
                let promptTok = usage?["prompt_tokens"] as? Int
                let compTok = usage?["completion_tokens"] as? Int

                onChunk(LLMStreamChunk(
                    deltaText: text,
                    deltaReasoning: reasoning,
                    isFinished: finishReason != nil && finishReason != "",
                    finishReason: finishReason,
                    promptTokens: promptTok,
                    completionTokens: compTok,
                    toolCalls: deltaToolCalls
                ))
            }
        }
    }
}
