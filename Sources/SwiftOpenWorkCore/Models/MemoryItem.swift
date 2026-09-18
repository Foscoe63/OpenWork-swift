import Foundation

public enum MemoryCategory: String, Codable, CaseIterable, Sendable {
    case fact = "fact"
    case instruction = "instruction"
    case preference = "preference"
    case projectContext = "project_context"
    case sessionSummary = "session_summary"

    public var displayName: String {
        switch self {
        case .fact: return "Fact"
        case .instruction: return "Instruction"
        case .preference: return "User Preference"
        case .projectContext: return "Project Context"
        case .sessionSummary: return "Session Summary"
        }
    }

    public var icon: String {
        switch self {
        case .fact: return "lightbulb.fill"
        case .instruction: return "list.bullet.rectangle"
        case .preference: return "heart.fill"
        case .projectContext: return "folder.badge.gearshape"
        case .sessionSummary: return "doc.plaintext"
        }
    }
}

public struct MemoryItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var key: String
    public var content: String
    public var category: MemoryCategory
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        key: String,
        content: String,
        category: MemoryCategory = .fact,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.key = key
        self.content = content
        self.category = category
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
