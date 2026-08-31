import Foundation

public enum WorkspaceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case general = "general"
    case research = "research"
    case project = "project"
    case agent = "agent"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: return "Main / General"
        case .research: return "AI & Agent Research"
        case .project: return "Project / Repository"
        case .agent: return "Dedicated Agent Workspace"
        }
    }

    public var icon: String {
        switch self {
        case .general: return "briefcase.fill"
        case .research: return "brain.head.profile"
        case .project: return "folder.fill"
        case .agent: return "person.crop.circle.badge.checkmark"
        }
    }
}

public struct Workspace: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var color: String
    public var folderPath: String
    public var category: WorkspaceCategory
    public var assignedAgentId: String?
    public var isRemote: Bool
    public var remoteUrl: String
    public var apiKey: String
    public var isPipelineStagingEnabled: Bool
    public var inputFolderPath: String
    public var outputFolderPath: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "Default Workspace",
        icon: String = "folder.fill",
        color: String = "#8B5CF6",
        folderPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        category: WorkspaceCategory = .general,
        assignedAgentId: String? = nil,
        isRemote: Bool = false,
        remoteUrl: String = "",
        apiKey: String = "",
        isPipelineStagingEnabled: Bool = false,
        inputFolderPath: String = "",
        outputFolderPath: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.folderPath = folderPath
        self.category = category
        self.assignedAgentId = assignedAgentId
        self.isRemote = isRemote
        self.remoteUrl = remoteUrl
        self.apiKey = apiKey
        self.isPipelineStagingEnabled = isPipelineStagingEnabled
        self.inputFolderPath = inputFolderPath
        self.outputFolderPath = outputFolderPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, color, folderPath, category, assignedAgentId
        case isRemote, remoteUrl, apiKey, isPipelineStagingEnabled, inputFolderPath, outputFolderPath
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Workspace"
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "folder.fill"
        self.color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#8B5CF6"
        self.folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath) ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.category = try container.decodeIfPresent(WorkspaceCategory.self, forKey: .category) ?? .general
        self.assignedAgentId = try container.decodeIfPresent(String.self, forKey: .assignedAgentId)
        self.isRemote = try container.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        self.remoteUrl = try container.decodeIfPresent(String.self, forKey: .remoteUrl) ?? ""
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.isPipelineStagingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isPipelineStagingEnabled) ?? false
        self.inputFolderPath = try container.decodeIfPresent(String.self, forKey: .inputFolderPath) ?? ""
        self.outputFolderPath = try container.decodeIfPresent(String.self, forKey: .outputFolderPath) ?? ""
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public static let `default` = Workspace(
        id: "default-workspace",
        name: "Main Workspace",
        icon: "briefcase.fill",
        color: "#6366F1",
        folderPath: (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Documents/OpenWork/Workspaces/Main"),
        category: .general,
        assignedAgentId: "lead-assistant",
        isPipelineStagingEnabled: true,
        inputFolderPath: "input",
        outputFolderPath: "output"
    )
}
