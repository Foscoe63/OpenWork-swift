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

    /// The same model with its compatibility verdict re-judged against `budgetRatio`.
    ///
    /// The curated catalog is a `static` built without access to settings, so it bakes a verdict
    /// at the shipped default ratio. Anything actually shown to the user is re-judged here
    /// against the ratio the user set, because a "Runs well" badge measured against a budget the
    /// user has since halved is the same kind of confident-but-unbacked number the GPU budget
    /// readout used to be.
    public func judged(atBudgetRatio budgetRatio: Double) -> LocalMLXModel {
        LocalMLXModel(
            id: id,
            name: name,
            description: description,
            sizeBytes: sizeBytes,
            parameterCount: parameterCount,
            quantization: quantization,
            modelType: modelType,
            contextWindow: contextWindow,
            isDownloaded: isDownloaded,
            localDirectory: localDirectory,
            isVLM: isVLM,
            useCase: useCase,
            compatibility: MLXMemoryBudget.assessCompatibility(
                requiredRAMGB: estimatedRAMGB,
                budgetRatio: budgetRatio
            ),
            estimatedRAMGB: estimatedRAMGB,
            tags: tags,
            isTopPick: isTopPick,
            releasedAt: releasedAt,
            downloadCount: downloadCount
        )
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

// MARK: - Memory budget

/// Whether a model fits in this Mac's GPU memory budget. Lives beside the model type so that
/// `LocalMLXModel.judged(atBudgetRatio:)` does not need the engine; `LocalMLXEngine` forwards here.
public enum MLXMemoryBudget {
    public static var physicalRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    /// The user's "GPU Memory Budget Ratio", clamped to something a machine can survive.
    ///
    /// The slider offers 0.5...0.9, but settings.json is hand-editable and a stored 0 or 5 is a
    /// wedged or swapping machine rather than a preference.
    public static func clampedBudgetRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return AppSettings.default.mlxGpuMemoryBudgetRatio }
        return min(max(ratio, 0.1), 0.95)
    }

    /// Whether a model of `requiredRAMGB` fits inside the GPU memory budget.
    ///
    /// `budgetRatio` is the user's "GPU Memory Budget Ratio". It used to be a hardcoded 0.75 —
    /// one of two separate hardcodes (the other being MLX's own cache limit at 0.5) behind a
    /// settings slider that the MLX page rendered as "Safe GPU Memory Budget: N GB" in green.
    /// Nothing read the setting, and 0.75 is its default, so the readout agreed with the verdict
    /// right up until someone moved the slider.
    ///
    /// The default here exists so `curatedModels` — a `static` with no access to settings, read
    /// from SwiftUI bodies where a disk read would be wrong — can still be built. Every verdict
    /// actually shown to the user is re-judged against the stored ratio in `scanInstalledModels`.
    public static func assessCompatibility(
        requiredRAMGB: Double,
        budgetRatio: Double = AppSettings.default.mlxGpuMemoryBudgetRatio
    ) -> ModelCompatibility {
        let ratio = clampedBudgetRatio(budgetRatio)
        let budget = physicalRAMGB * ratio
        // "Tight" is the band between the budget and what the machine can physically hold. At the
        // top of the clamp that band is empty, which is correct: there is no headroom left to
        // call tight.
        let ceiling = physicalRAMGB * max(ratio, 0.95)
        if requiredRAMGB <= budget {
            return .runsWell
        } else if requiredRAMGB <= ceiling {
            return .tight
        } else {
            return .notRecommended
        }
    }

}
