import Foundation

/// Radiant `ask_user` parity — pause the agent loop until the user answers in chat UI.
@MainActor
public final class UserChoiceManager: ObservableObject {
    public static let shared = UserChoiceManager()

    public struct PendingChoice: Identifiable, Equatable {
        public let id: String
        public let question: String
        public let options: [String]
        public let requestedAt: Date
    }

    @Published public private(set) var pending: PendingChoice?

    private var continuation: CheckedContinuation<String, Never>?

    private init() {}

    public func request(question: String, options: [String], callId: String) async -> String {
        pending = PendingChoice(id: callId, question: question, options: options, requestedAt: Date())
        return await withCheckedContinuation { cont in
            continuation = cont
        }
    }

    public func resolve(answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pending = nil
        continuation?.resume(returning: text)
        continuation = nil
    }

    public func cancelAll() {
        pending = nil
        continuation?.resume(returning: "(user cancelled)")
        continuation = nil
    }
}
