import Foundation

/// Editorial use case categories for local models matching Osaurus and GrizzyClaw.
public enum ModelUseCase: String, Codable, Sendable, CaseIterable {
    case general = "General"
    case vision = "Vision"
    case reasoning = "Reasoning"
    case coding = "Coding"
    case fast = "Fast"

    public var displayName: String { rawValue }

    public var iconName: String {
        switch self {
        case .general: return "text.bubble"
        case .vision: return "eye"
        case .reasoning: return "brain"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .fast: return "bolt"
        }
    }
}

/// Hardware compatibility assessment for local MLX models on Apple Silicon.
public enum ModelCompatibility: String, Codable, Sendable, CaseIterable {
    case runsWell = "Runs well"
    case tight = "Memory may be tight"
    case notRecommended = "Not recommended"
    case unknown = "Unknown"

    public var displayName: String { rawValue }

    public var colorName: String {
        switch self {
        case .runsWell: return "green"
        case .tight: return "orange"
        case .notRecommended: return "red"
        case .unknown: return "gray"
        }
    }
}

/// Rich metadata for an MLX-compatible local model (curated catalog or on-device discovered).
public struct LocalMLXModel: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let sizeBytes: Int64?
    public let parameterCount: String?
    public let quantization: String?
    public let modelType: String?
    public let contextWindow: Int?
    public let isDownloaded: Bool
    public let localDirectory: String?
    public let isVLM: Bool
    public let useCase: ModelUseCase
    public let compatibility: ModelCompatibility
    public let estimatedRAMGB: Double
    public let tags: [String]
    public let isTopPick: Bool
    public let releasedAt: Date?
    public let downloadCount: Int?

    public init(
        id: String,
        name: String,
        description: String,
        sizeBytes: Int64? = nil,
        parameterCount: String? = nil,
        quantization: String? = nil,
        modelType: String? = nil,
        contextWindow: Int? = nil,
        isDownloaded: Bool = false,
        localDirectory: String? = nil,
        isVLM: Bool = false,
        useCase: ModelUseCase = .general,
        compatibility: ModelCompatibility = .runsWell,
        estimatedRAMGB: Double = 4.0,
        tags: [String] = [],
        isTopPick: Bool = false,
        releasedAt: Date? = nil,
        downloadCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sizeBytes = sizeBytes
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.modelType = modelType
        self.contextWindow = contextWindow
        self.isDownloaded = isDownloaded
        self.localDirectory = localDirectory
        self.isVLM = isVLM
        self.useCase = useCase
        self.compatibility = compatibility
        self.estimatedRAMGB = estimatedRAMGB
        self.tags = tags
        self.isTopPick = isTopPick
        self.releasedAt = releasedAt
        self.downloadCount = downloadCount
    }

    /// Formatted download size (e.g. "4.2 GB").
    public var formattedSize: String {
        guard let sizeBytes, sizeBytes > 0 else {
            if estimatedRAMGB > 0 {
                return String(format: "~%.1f GB", estimatedRAMGB * 0.75)
            }
            return "Size unknown"
        }
        let gb = Double(sizeBytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(sizeBytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    /// Formatted RAM requirement (e.g. "8.5 GB RAM").
    public var formattedRAM: String {
        String(format: "%.1f GB RAM", estimatedRAMGB)
    }

    /// Clean model family name (e.g. "Qwen", "Llama", "Gemma", "Ornith").
    public var familyName: String {
        let lower = id.lowercased()
        if lower.contains("ornith") { return "Ornith" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") { return "Gemma" }
        if lower.contains("llama") { return "Llama" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("mistral") || lower.contains("ministral") || lower.contains("codestral") || lower.contains("pixtral") { return "Mistral" }
        if lower.contains("phi") { return "Phi" }
        if lower.contains("smollm") { return "SmolLM" }
        if lower.contains("starcoder") { return "StarCoder" }
        return "Other"
    }
}

/// Result of checking whether a directory on disk is a loadable MLX model package.
public enum MLXModelFolderValidation: Sendable, Equatable {
    case ok(modelType: String)
    case missingConfig
    case unreadableConfig
    case gitLFSPointer
    case missingModelType
    case invalidJSON

    public var isLoadable: Bool {
        if case .ok = self { return true }
        return false
    }

    public var userMessage: String {
        switch self {
        case .ok:
            return "OK"
        case .missingConfig:
            return "Missing config.json — select a full MLX model directory."
        case .unreadableConfig:
            return "Cannot read config.json."
        case .gitLFSPointer:
            return "config.json is a Git LFS pointer (incomplete download)."
        case .missingModelType:
            return "config.json is missing model_type."
        case .invalidJSON:
            return "config.json is not valid JSON."
        }
    }
}
