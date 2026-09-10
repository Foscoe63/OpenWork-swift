import Foundation

/// A tool call an autonomous agent wants to run that has been paused pending human approval
/// (e.g. deleting a file, or a shell command under a "always ask" safety policy).
public struct PendingToolApproval: Identifiable, Sendable, Equatable {
    public let id: String
    public let toolName: String
    public let argumentsJson: String
    public let reason: String
    public let requestedAt: Date

    public init(id: String, toolName: String, argumentsJson: String, reason: String, requestedAt: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.argumentsJson = argumentsJson
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

/// Gates sensitive autonomous tool calls behind a real, interactive user decision.
///
/// `AgentRunner` calls `requestApproval` and suspends the ReAct loop until the chat UI
/// (`ToolCallCardView`) calls `resolve` in response to the user tapping Approve/Reject.
@MainActor
public final class ToolApprovalManager: ObservableObject {
    public static let shared = ToolApprovalManager()

    @Published public private(set) var pendingApprovals: [PendingToolApproval] = []

    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    private init() {}

    /// Suspends until the user approves or rejects the call identified by `callId`.
    public func requestApproval(callId: String, toolName: String, argumentsJson: String, reason: String) async -> Bool {
        pendingApprovals.append(PendingToolApproval(id: callId, toolName: toolName, argumentsJson: argumentsJson, reason: reason))
        return await withCheckedContinuation { continuation in
            continuations[callId] = continuation
        }
    }

    /// Called from the UI when the user taps Approve or Reject on a pending tool call.
    public func resolve(callId: String, approved: Bool) {
        pendingApprovals.removeAll { $0.id == callId }
        if let continuation = continuations.removeValue(forKey: callId) {
            continuation.resume(returning: approved)
        }
    }

    /// Rejects every outstanding approval, e.g. when a session/agent run is cancelled so no
    /// continuation is left dangling.
    public func rejectAllPending() {
        let ids = pendingApprovals.map(\.id)
        pendingApprovals.removeAll()
        for id in ids {
            continuations.removeValue(forKey: id)?.resume(returning: false)
        }
    }
}
