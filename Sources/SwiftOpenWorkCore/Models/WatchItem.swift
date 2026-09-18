import Foundation

public enum WatchType: String, Codable, CaseIterable, Identifiable, Sendable {
    case folder = "folder"
    case file = "file"
    case pattern = "pattern"
    case gitRepository = "gitRepository"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .folder: return "Directory / Folder"
        case .file: return "Single File Watch"
        case .pattern: return "File Extension Pattern"
        case .gitRepository: return "Git Repository Changes"
        }
    }

    public var icon: String {
        switch self {
        case .folder: return "folder.badge.gearshape"
        case .file: return "doc.badge.gearshape.fill"
        case .pattern: return "sparkle.magnifyingglass"
        case .gitRepository: return "arrow.triangle.branch"
        }
    }
}

public enum ArtifactOutputTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case morningBrief = "morningBrief"
    case dailyUpdate = "dailyUpdate"
    case codeReviewDigest = "codeReviewDigest"
    case documentSummary = "documentSummary"
    case fileProcessingPipeline = "fileProcessingPipeline"
    case customPrompt = "customPrompt"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .morningBrief: return "Morning Brief (Claude Co-Work Style)"
        case .dailyUpdate: return "Daily Project & Activity Update"
        case .codeReviewDigest: return "Automated Code Review Digest"
        case .documentSummary: return "Document & Research Synthesis"
        case .fileProcessingPipeline: return "Input -> Output Staged Pipeline"
        case .customPrompt: return "Custom Agent Prompt Artifact"
        }
    }

    public var icon: String {
        switch self {
        case .morningBrief: return "sun.max.fill"
        case .dailyUpdate: return "calendar.badge.clock"
        case .codeReviewDigest: return "checkmark.seal.fill"
        case .documentSummary: return "doc.text.image.fill"
        case .fileProcessingPipeline: return "arrow.triangle.swap"
        case .customPrompt: return "wand.and.stars"
        }
    }

    public var defaultPromptTemplate: String {
        switch self {
        case .morningBrief:
            return """
            Analyze the files and recent updates in this watch directory. 
            Synthesize an executive "Morning Brief" artifact structured with:
            1. 🌅 Executive Overview & Key Highlights
            2. 🎯 Priority Deliverables & Action Items for Today
            3. 📊 Project / Code Health & Recent Modifications
            4. ⚠️ Blockers, Risks, or Pending Reviews
            Format cleanly as a rich Markdown or HTML Canvas artifact.
            """
        case .dailyUpdate:
            return """
            Review all changes, logs, and artifacts created or updated in this folder over the last 24 hours.
            Produce a comprehensive "Daily Project Update" artifact detailing:
            - 📈 Progress Accomplished
            - 🛠️ Source & Document Changes
            - 📋 Outstanding Tasks
            - 💡 Recommended Next Actions
            """
        case .codeReviewDigest:
            return """
            Perform an automated static analysis and code review of changed files in this folder.
            Highlight:
            - Security, concurrency, and performance assessments
            - Architectural alignment & quality metrics
            - Suggested refactoring with concise code snippets
            """
        case .documentSummary:
            return """
            Extract and summarize the text, key takeaways, and conclusions from all newly added documents or notes.
            Synthesize into a structured knowledge brief artifact.
            """
        case .fileProcessingPipeline:
            return """
            Process all staged input files, perform the requested transformations, and generate synthesized output documents in the workspace output/ directory.
            """
        case .customPrompt:
            return "Analyze changed files in this watch directory and produce a structured artifact."
        }
    }
}

public struct WatchItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var description: String
    public var path: String
    public var watchType: WatchType
    public var fileExtensionsFilter: [String] // e.g. ["swift", "md", "json", "pdf"] or ["*"]
    public var targetAgentId: String
    public var artifactTemplate: ArtifactOutputTemplate
    public var customPrompt: String
    public var outputDestination: String // e.g. "output" or custom path
    public var isEnabled: Bool
    public var autoGenerateArtifact: Bool
    public var debounceIntervalSeconds: Double
    public var lastEventAt: Date?
    public var lastEventSummary: String?
    public var eventsCount: Int
    public var createdArtifactsCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        name: String,
        description: String = "",
        path: String = "",
        watchType: WatchType = .folder,
        fileExtensionsFilter: [String] = ["*"],
        targetAgentId: String = "lead-assistant",
        artifactTemplate: ArtifactOutputTemplate = .morningBrief,
        customPrompt: String = "",
        outputDestination: String = "output",
        isEnabled: Bool = true,
        autoGenerateArtifact: Bool = true,
        debounceIntervalSeconds: Double = 3.0,
        lastEventAt: Date? = nil,
        lastEventSummary: String? = nil,
        eventsCount: Int = 0,
        createdArtifactsCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.description = description
        self.path = path
        self.watchType = watchType
        self.fileExtensionsFilter = fileExtensionsFilter
        self.targetAgentId = targetAgentId
        self.artifactTemplate = artifactTemplate
        self.customPrompt = customPrompt.isEmpty ? artifactTemplate.defaultPromptTemplate : customPrompt
        self.outputDestination = outputDestination
        self.isEnabled = isEnabled
        self.autoGenerateArtifact = autoGenerateArtifact
        self.debounceIntervalSeconds = debounceIntervalSeconds
        self.lastEventAt = lastEventAt
        self.lastEventSummary = lastEventSummary
        self.eventsCount = eventsCount
        self.createdArtifactsCount = createdArtifactsCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
