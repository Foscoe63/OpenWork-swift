import Foundation

/// A checklist item the agent maintains with `todo_write` so long vibe sessions keep a plan visible.
public struct SessionTodoItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var content: String
    public var status: Status

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done

        public init(raw: String) {
            switch raw.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "done", "completed", "complete":
                self = .done
            case "in_progress", "inprogress", "active", "running":
                self = .inProgress
            default:
                self = .pending
            }
        }

        public var label: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In progress"
            case .done: return "Done"
            }
        }

        public var icon: String {
            switch self {
            case .pending: return "circle"
            case .inProgress: return "circle.lefthalf.filled"
            case .done: return "checkmark.circle.fill"
            }
        }
    }

    public init(id: String = UUID().uuidString, content: String, status: Status = .pending) {
        self.id = id
        self.content = content
        self.status = status
    }

    public static func parse(from items: [[String: Any]]) -> [SessionTodoItem] {
        items.prefix(40).compactMap { item in
            let content = (item["content"] as? String)
                ?? (item["text"] as? String)
                ?? (item["title"] as? String)
                ?? ""
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let statusRaw = (item["status"] as? String) ?? "pending"
            let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            return SessionTodoItem(id: id, content: trimmed, status: Status(raw: statusRaw))
        }
    }
}
