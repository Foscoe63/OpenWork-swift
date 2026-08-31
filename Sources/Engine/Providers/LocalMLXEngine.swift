import Foundation

/// Discovers, validates, and runs local Apple Silicon MLX models directly on-device.
/// Parity with Osaurus / GrizzyClaw local MLX scanners and Hugging Face hub caches.
public final class LocalMLXEngine: @unchecked Sendable {
    public static let shared = LocalMLXEngine()

    public static var physicalRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    public static var freeRAMGB: Double {
        let hostPort = mach_host_self()
        let size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        var mutableSize = size
        
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &mutableSize)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let freeBytes = (UInt64(vmStats.free_count) + UInt64(vmStats.inactive_count)) * pageSize
            return Double(freeBytes) / (1024 * 1024 * 1024)
        }
        return physicalRAMGB * 0.45 // Fallback estimate
    }

    public static var totalStorageGB: Double {
        let home = NSHomeDirectory()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home),
           let totalBytes = attrs[.systemSize] as? NSNumber {
            return totalBytes.doubleValue / (1024 * 1024 * 1024)
        }
        return 1000.0
    }

    public static var freeStorageGB: Double {
        let home = NSHomeDirectory()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home),
           let freeBytes = attrs[.systemFreeSize] as? NSNumber {
            return freeBytes.doubleValue / (1024 * 1024 * 1024)
        }
        return 500.0
    }

    public static func assessCompatibility(requiredRAMGB: Double) -> ModelCompatibility {
        let budget = physicalRAMGB * 0.75
        if requiredRAMGB <= budget {
            return .runsWell
        } else if requiredRAMGB <= (physicalRAMGB * 0.95) {
            return .tight
        } else {
            return .notRecommended
        }
    }

    /// Curated presets of recommended MLX models matching Osaurus and GrizzyClaw.
    public static let curatedModels: [LocalMLXModel] = [
        LocalMLXModel(
            id: "mlx-community/Ornith-1.5-35B-A3B-8bit",
            name: "Ornith 1.5 35B A3B 8bit",
            description: "High-precision 35B MoE (~3B active) hybrid reasoning model. Exceptional coding, tool use, and 256K context.",
            sizeBytes: 40_500_000_000,
            parameterCount: "35B",
            quantization: "8-bit",
            modelType: "qwen3_5_moe",
            contextWindow: 262_144,
            useCase: .reasoning,
            compatibility: assessCompatibility(requiredRAMGB: 43.9),
            estimatedRAMGB: 43.9,
            tags: ["Recommended", "MoE", "Tool Use", "256K Context"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3-Coder-Next-MLX-5bit",
            name: "Qwen3 Coder Next MLX 5bit",
            description: "Advanced coding next-gen model with multi-agent orchestration and fill-in-the-middle support.",
            sizeBytes: 58_800_000_000,
            parameterCount: "48B",
            quantization: "5-bit",
            modelType: "qwen3_coder",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 63.8),
            estimatedRAMGB: 63.8,
            tags: ["Coding", "131K Context", "Top Coder"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit",
            name: "Qwen3 Coder Next REAP 48B A3B mlx 8Bit",
            description: "Frontier coding model with MoE sparse execution and deep tool invocation proficiency.",
            sizeBytes: 55_730_000_000,
            parameterCount: "48B",
            quantization: "8-bit",
            modelType: "qwen3_coder",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 60.4),
            estimatedRAMGB: 60.4,
            tags: ["Coding", "MoE", "8-bit"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3.6-35B-A3B-8bit",
            name: "Qwen3.6 35B A3B 8bit",
            description: "Flagship hybrid dense/MoE intelligence with multilingual knowledge and swift token generation.",
            sizeBytes: 39_550_000_000,
            parameterCount: "35B",
            quantization: "8-bit",
            modelType: "qwen3",
            contextWindow: 131_072,
            useCase: .general,
            compatibility: assessCompatibility(requiredRAMGB: 42.9),
            estimatedRAMGB: 42.9,
            tags: ["General", "Fast", "MoE"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3.8-27B-8bit",
            name: "Qwen3.8 27B 8bit",
            description: "High-capability reasoning and general-purpose intelligence balanced for 32GB+ Apple Silicon.",
            sizeBytes: 30_690_000_000,
            parameterCount: "27B",
            quantization: "8-bit",
            modelType: "qwen3",
            contextWindow: 131_072,
            useCase: .general,
            compatibility: assessCompatibility(requiredRAMGB: 33.3),
            estimatedRAMGB: 33.3,
            tags: ["General", "Balanced"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3.8-27B-MLX-8bit",
            name: "Qwen3.8 27B MLX 8bit",
            description: "Multimodal visual reasoning model for screenshot reading, chart diagnostics, and code generation.",
            sizeBytes: 31_670_000_000,
            parameterCount: "27B",
            quantization: "8-bit",
            modelType: "qwen3_vl",
            contextWindow: 131_072,
            isVLM: true,
            useCase: .vision,
            compatibility: assessCompatibility(requiredRAMGB: 34.3),
            estimatedRAMGB: 34.3,
            tags: ["Vision", "Multimodal", "8-bit"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "mlx-community/Ornith-1.5-35B-A3B-4bit",
            name: "Ornith 1.5 35B A3B 4bit",
            description: "Fast 35B MoE (~3B active) reasoning model. Low memory footprint with strong instruction following and tool use.",
            sizeBytes: 19_800_000_000,
            parameterCount: "35B",
            quantization: "4-bit",
            modelType: "qwen3_5_moe",
            contextWindow: 262_144,
            useCase: .reasoning,
            compatibility: assessCompatibility(requiredRAMGB: 21.0),
            estimatedRAMGB: 21.0,
            tags: ["MoE", "Fast", "256K Context"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
            name: "Qwen 2.5 Coder 32B (4-bit)",
            description: "State-of-the-art open-source code generation, repository analysis, and refactoring model. 128K context.",
            sizeBytes: 18_500_000_000,
            parameterCount: "32B",
            quantization: "4-bit",
            modelType: "qwen2",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 20.0),
            estimatedRAMGB: 20.0,
            tags: ["Coding", "128K Context", "Top Coder"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            name: "Qwen 2.5 Coder 7B (4-bit)",
            description: "Lightweight and fast coding assistant. Fits on all Macs with 8 GB or 16 GB RAM.",
            sizeBytes: 4_400_000_000,
            parameterCount: "7B",
            quantization: "4-bit",
            modelType: "qwen2",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 5.5),
            estimatedRAMGB: 5.5,
            tags: ["Coding", "Fast", "Low RAM"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/gemma-4-E4B-it-4bit",
            name: "Gemma 4 E4B (4-bit)",
            description: "Google's lightweight multimodal edge model with native vision and speech capabilities.",
            sizeBytes: 3_200_000_000,
            parameterCount: "4B",
            quantization: "4-bit",
            modelType: "gemma4",
            contextWindow: 131_072,
            isVLM: true,
            useCase: .vision,
            compatibility: assessCompatibility(requiredRAMGB: 4.5),
            estimatedRAMGB: 4.5,
            tags: ["Vision", "Google", "Low RAM"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
            name: "DeepSeek R1 Distill 14B (4-bit)",
            description: "Reasoning and chain-of-thought powerhouse distilled from DeepSeek-R1 into Qwen architecture.",
            sizeBytes: 8_900_000_000,
            parameterCount: "14B",
            quantization: "4-bit",
            modelType: "qwen2",
            contextWindow: 131_072,
            useCase: .reasoning,
            compatibility: assessCompatibility(requiredRAMGB: 10.5),
            estimatedRAMGB: 10.5,
            tags: ["Reasoning", "Chain of Thought"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            name: "Llama 3.2 3B (4-bit)",
            description: "Meta's ultra-compact edge model. Instant response times, ideal for local formatting and fast chats.",
            sizeBytes: 2_100_000_000,
            parameterCount: "3B",
            quantization: "4-bit",
            modelType: "llama",
            contextWindow: 131_072,
            useCase: .fast,
            compatibility: assessCompatibility(requiredRAMGB: 3.0),
            estimatedRAMGB: 3.0,
            tags: ["Meta", "Ultra Fast", "Low RAM"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit",
            name: "Mistral Small 24B (4-bit)",
            description: "Mistral's powerful 24B dense model. Excellent reasoning, function calling, and structured JSON output.",
            sizeBytes: 14_200_000_000,
            parameterCount: "24B",
            quantization: "4-bit",
            modelType: "mistral",
            contextWindow: 32_768,
            useCase: .general,
            compatibility: assessCompatibility(requiredRAMGB: 16.0),
            estimatedRAMGB: 16.0,
            tags: ["Mistral", "Tool Use"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "mlx-community/Codestral-22B-v0.1-4bit",
            name: "Codestral 22B (4-bit)",
            description: "Mistral's dedicated code generation and fill-in-the-middle model supporting 80+ programming languages.",
            sizeBytes: 13_100_000_000,
            parameterCount: "22B",
            quantization: "4-bit",
            modelType: "mistral",
            contextWindow: 32_768,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 15.0),
            estimatedRAMGB: 15.0,
            tags: ["Coding", "Mistral", "FIM"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "mlx-community/SmolLM2-1.7B-Instruct-4bit",
            name: "SmolLM2 1.7B (4-bit)",
            description: "Ultra-compact Hugging Face sub-2B model. Blazing fast inference with near-zero memory footprint.",
            sizeBytes: 1_100_000_000,
            parameterCount: "1.7B",
            quantization: "4-bit",
            modelType: "llama",
            contextWindow: 8_192,
            useCase: .fast,
            compatibility: assessCompatibility(requiredRAMGB: 2.0),
            estimatedRAMGB: 2.0,
            tags: ["Ultra Fast", "Sub-2B", "Low RAM"],
            isTopPick: false
        )
    ]

    private init() {}

    /// Validates an MLX model directory on disk.
    public func validateModelFolder(directory: URL) -> MLXModelFolderValidation {
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .missingConfig
        }
        guard let data = try? Data(contentsOf: configURL) else {
            return .unreadableConfig
        }
        if let prefix = String(data: data.prefix(128), encoding: .utf8), prefix.hasPrefix("version https://git-lfs") {
            return .gitLFSPointer
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidJSON
        }
        guard let modelType = object["model_type"] as? String, !modelType.isEmpty else {
            return .missingModelType
        }
        return .ok(modelType: modelType)
    }

    /// Scans all configured locations (custom paths, Hugging Face cache, LM Studio libraries, Osaurus/GrizzyClaw paths).
    public func scanInstalledModels(settings: AppSettings) -> [LocalMLXModel] {
        var directoriesToScan: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. App default MLX folder
        let appMlx = home.appendingPathComponent(".openwork/mlx_models", isDirectory: true)
        try? FileManager.default.createDirectory(at: appMlx, withIntermediateDirectories: true)
        directoriesToScan.append(appMlx)

        // 2. Custom MLX folder from settings
        if !settings.customMLXModelsDirectory.isEmpty {
            let expanded = (settings.customMLXModelsDirectory as NSString).expandingTildeInPath
            directoriesToScan.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }

        // 3. Hugging Face Cache
        if settings.scanHuggingFaceCache {
            let hfCache = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            if FileManager.default.fileExists(atPath: hfCache.path) {
                directoriesToScan.append(hfCache)
            }
            if !settings.customHFCachePath.isEmpty {
                let customHf = URL(fileURLWithPath: (settings.customHFCachePath as NSString).expandingTildeInPath, isDirectory: true)
                directoriesToScan.append(customHf)
            }
        }

        // 4. LM Studio Models
        if settings.scanLMStudioModels {
            let lm1 = home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true)
            let lm2 = home.appendingPathComponent("Library/Application Support/LM Studio/models", isDirectory: true)
            if FileManager.default.fileExists(atPath: lm1.path) { directoriesToScan.append(lm1) }
            if FileManager.default.fileExists(atPath: lm2.path) { directoriesToScan.append(lm2) }
        }

        // 5. GrizzyClaw & Osaurus caches
        let gcDir = home.appendingPathComponent(".grizzyclaw/mlx_models", isDirectory: true)
        if FileManager.default.fileExists(atPath: gcDir.path) { directoriesToScan.append(gcDir) }

        var foundInstalled: [String: LocalMLXModel] = [:]

        for root in directoriesToScan {
            scanDirectoryRecursively(root: root, current: root, depth: 0, results: &foundInstalled)
        }

        // Merge with curated catalog
        var finalCatalog: [LocalMLXModel] = []
        for curated in Self.curatedModels {
            if let installed = foundInstalled[curated.id] {
                let merged = LocalMLXModel(
                    id: curated.id,
                    name: curated.name,
                    description: curated.description,
                    sizeBytes: installed.sizeBytes ?? curated.sizeBytes,
                    parameterCount: curated.parameterCount,
                    quantization: curated.quantization,
                    modelType: installed.modelType ?? curated.modelType,
                    contextWindow: curated.contextWindow,
                    isDownloaded: true,
                    localDirectory: installed.localDirectory,
                    isVLM: curated.isVLM,
                    useCase: curated.useCase,
                    compatibility: curated.compatibility,
                    estimatedRAMGB: curated.estimatedRAMGB,
                    tags: curated.tags,
                    isTopPick: curated.isTopPick,
                    releasedAt: curated.releasedAt,
                    downloadCount: curated.downloadCount
                )
                finalCatalog.append(merged)
                foundInstalled.removeValue(forKey: curated.id)
            } else {
                finalCatalog.append(curated)
            }
        }

        // Add any additional discovered models from disk
        for (_, remaining) in foundInstalled {
            finalCatalog.append(remaining)
        }

        return finalCatalog
    }

    private func scanDirectoryRecursively(root: URL, current: URL, depth: Int, results: inout [String: LocalMLXModel]) {
        guard depth < 6 else { return }
        let validation = validateModelFolder(directory: current)
        if validation.isLoadable {
            let repoId = deriveRepoId(root: root, modelDir: current)
            if results[repoId] == nil {
                results[repoId] = buildModel(repoId: repoId, directory: current)
            }
            return
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for item in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                scanDirectoryRecursively(root: root, current: item, depth: depth + 1, results: &results)
            }
        }
    }

    private func deriveRepoId(root: URL, modelDir: URL) -> String {
        let name = modelDir.lastPathComponent
        if name.hasPrefix("models--") {
            let stripped = String(name.dropFirst(8))
            let parts = stripped.components(separatedBy: "--")
            if parts.count >= 2 {
                return "\(parts[0])/\(parts.dropFirst().joined(separator: "-"))"
            }
        }
        let parentName = modelDir.deletingLastPathComponent().lastPathComponent
        if !parentName.isEmpty && parentName != root.lastPathComponent && parentName != "models" && parentName != "snapshots" {
            return "\(parentName)/\(name)"
        }
        return name
    }

    private func buildModel(repoId: String, directory: URL) -> LocalMLXModel {
        var sizeBytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    sizeBytes += Int64(size)
                }
            }
        }

        var modelType = "mlx"
        var isVLM = false
        var contextWindow: Int? = 131_072

        let configURL = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let mt = json["model_type"] as? String {
                modelType = mt
                let lower = mt.lowercased()
                if lower.contains("vl") || lower.contains("vision") || lower.contains("pixtral") || lower.contains("mllama") || lower.contains("gemma4") {
                    isVLM = true
                }
            }
            if let maxPos = json["max_position_embeddings"] as? Int {
                contextWindow = maxPos
            } else if let maxSeq = json["max_seq_len"] as? Int {
                contextWindow = maxSeq
            }
        }

        let cleanName = repoId.split(separator: "/").last.map(String.init) ?? repoId
        let ramEstimate = sizeBytes > 0 ? (Double(sizeBytes) / (1024 * 1024 * 1024)) * 1.15 : 6.0
        let comp = Self.assessCompatibility(requiredRAMGB: ramEstimate)

        return LocalMLXModel(
            id: repoId,
            name: cleanName,
            description: "Locally installed MLX model at \(directory.lastPathComponent).",
            sizeBytes: sizeBytes > 0 ? sizeBytes : nil,
            parameterCount: extractParams(from: repoId),
            quantization: extractQuant(from: repoId),
            modelType: modelType,
            contextWindow: contextWindow,
            isDownloaded: true,
            localDirectory: directory.path,
            isVLM: isVLM,
            useCase: isVLM ? .vision : .general,
            compatibility: comp,
            estimatedRAMGB: ramEstimate,
            tags: ["Installed", "Local MLX"],
            isTopPick: false
        )
    }

    private func extractParams(from id: String) -> String? {
        let pattern = #"(?i)\b(\d+(?:\.\d+)?)\s*b\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(id.startIndex..., in: id)
        if let match = regex.firstMatch(in: id, range: range),
           let matchRange = Range(match.range, in: id) {
            return String(id[matchRange]).uppercased()
        }
        return nil
    }

    private func extractQuant(from id: String) -> String? {
        let lower = id.lowercased()
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("5bit") || lower.contains("5-bit") { return "5-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        if lower.contains("2bit") || lower.contains("2-bit") { return "2-bit" }
        if lower.contains("3bit") || lower.contains("3-bit") { return "3-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") { return "6-bit" }
        if lower.contains("mxfp8") { return "MXFP8" }
        if lower.contains("mxfp4") { return "MXFP4" }
        if lower.contains("bf16") { return "bf16" }
        if lower.contains("fp16") { return "fp16" }
        return nil
    }

    /// Pulls an MLX model via python / huggingface-cli or download directory.
    public func pullModel(repoId: String, onProgress: @Sendable @escaping (Double, String) -> Void) async throws {
        onProgress(0.05, "Starting download for \(repoId)...")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let targetDir = home.appendingPathComponent(".openwork/mlx_models", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let sanitizedFolder = repoId.replacingOccurrences(of: "/", with: "--")
        let destinationDir = "\(targetDir.path)/\(sanitizedFolder)"
        let script = "huggingface-cli download \"\(repoId)\" --local-dir \"\(destinationDir)\" --local-dir-use-symlinks False"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.environment = ToolExecutionEngine.defaultEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        
        onProgress(0.4, "Downloading model weights & tokenizer...")
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            onProgress(1.0, "Completed!")
        } else {
            throw NSError(
                domain: "LocalMLXEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Download failed. Please ensure 'huggingface-cli' is installed or clone to ~/.cache/huggingface."]
            )
        }
    }

    /// Removes a downloaded model from disk.
    public func deleteModel(model: LocalMLXModel) throws {
        if let dir = model.localDirectory, FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - Daemon Server Lifecycle
    private var serverProcess: Process? = nil
    private var isServerStarting: Bool = false

    /// Checks if a local MLX server is reachable on a specific host and port.
    public func isServerRunning(host: String = "127.0.0.1", port: Int = 8000) async -> Bool {
        let endpoint = (port == 11434) ? "http://\(host):\(port)/api/tags" : "http://\(host):\(port)/v1/models"
        guard let url = URL(string: endpoint) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return (200...499).contains(http.statusCode)
            }
        } catch {}
        return false
    }

    /// Automatically starts or connects to the local Apple Silicon MLX inference server.
    /// Checks ports 8000 (oMLX/standard), 1337 (Osaurus), 11434 (Ollama), 1234 (LM Studio), 8080 (vMLX), and 5243 (GrizzyClaw).
    /// If none are running, auto-spawns standard `mlx_lm.server`, `omlx`, or `python3 -m mlx_lm.server`.
    public func ensureServerRunning(modelId: String? = nil, settings: AppSettings? = nil) async -> (success: Bool, message: String, activePort: Int) {
        // 1. First probe if any compatible MLX / local server is already running
        let probePorts = [8000, 1337, 11434, 1234, 8080, 5243]
        for p in probePorts {
            if await isServerRunning(port: p) {
                return (true, "Local inference server active on port \(p)", p)
            }
        }

        guard !isServerStarting else {
            // Wait up to 15 seconds for start in progress
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                for p in probePorts {
                    if await isServerRunning(port: p) {
                        return (true, "MLX server started successfully on port \(p)", p)
                    }
                }
            }
            return (false, "MLX server startup in progress...", 8000)
        }

        isServerStarting = true
        defer { isServerStarting = false }

        // Find binary or Python mlx-lm module
        let targetModel = modelId ?? "mlx-community/Qwen3.6-35B-A3B-8bit"
        
        // Comprehensive path search for Python/Homebrew/Conda/MLX environments
        let launchCommands = [
            "/opt/homebrew/bin/omlx serve --port 8000 --host 127.0.0.1 --hf-cache",
            "/usr/local/bin/omlx serve --port 8000 --host 127.0.0.1 --hf-cache",
            "omlx serve --port 8000 --host 127.0.0.1 --hf-cache",
            "/opt/homebrew/bin/mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "/opt/homebrew/bin/python3 -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "/usr/local/bin/python3 -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "python3 -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "python -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1"
        ]

        for cmd in launchCommands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", cmd]
            process.environment = ToolExecutionEngine.defaultEnvironment()
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                self.serverProcess = process

                // Poll until server port opens (up to 20 seconds per attempt to allow model loading into memory)
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    for p in probePorts {
                        if await isServerRunning(port: p) {
                            return (true, "MLX server launched successfully on port \(p)", p)
                        }
                    }
                }
            } catch {
                continue
            }
        }

        // Final check across all probe ports
        for p in probePorts {
            if await isServerRunning(port: p) {
                return (true, "MLX server is running on port \(p)", p)
            }
        }

        return (false, "Could not start local MLX server automatically. Please ensure `omlx` or `mlx-lm` is installed (`pip install mlx-lm`), or run Osaurus in the background.", 8000)
    }
}
