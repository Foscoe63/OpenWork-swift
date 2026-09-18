import Foundation

public enum ArtifactCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case brief = "brief"
    case report = "report"
    case code = "code"
    case canvas = "canvas"
    case document = "document"
    case digest = "digest"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .brief: return "Executive Brief"
        case .report: return "Project Report"
        case .code: return "Code Artifact"
        case .canvas: return "Interactive Canvas"
        case .document: return "Processed Document"
        case .digest: return "Activity Digest"
        }
    }

    public var icon: String {
        switch self {
        case .brief: return "sun.max.fill"
        case .report: return "chart.bar.doc.horizontal.fill"
        case .code: return "curlybraces.square.fill"
        case .canvas: return "sparkles.tv.fill"
        case .document: return "doc.richtext.fill"
        case .digest: return "newspaper.fill"
        }
    }
}

public struct AutomationArtifact: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var watchItemId: String?
    public var automationId: String?
    public var agentId: String
    public var agentName: String
    public var title: String
    public var subtitle: String
    public var category: ArtifactCategory
    public var content: String
    public var format: String // "markdown", "html", "canvas"
    public var filePath: String?
    public var sourceTrigger: String
    public var tokenCount: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        watchItemId: String? = nil,
        automationId: String? = nil,
        agentId: String = "lead-assistant",
        agentName: String = "Lead Assistant",
        title: String,
        subtitle: String = "",
        category: ArtifactCategory = .brief,
        content: String,
        format: String = "markdown",
        filePath: String? = nil,
        sourceTrigger: String = "Watch Folder Automation",
        tokenCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.watchItemId = watchItemId
        self.automationId = automationId
        self.agentId = agentId
        self.agentName = agentName
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.content = content
        self.format = format
        self.filePath = filePath
        self.sourceTrigger = sourceTrigger
        self.tokenCount = tokenCount == 0 ? max(50, content.count / 4) : tokenCount
        self.createdAt = createdAt
    }
}
