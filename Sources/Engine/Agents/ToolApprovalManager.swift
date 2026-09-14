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

/// How an approval request ended.
///
/// `rejected` and `refusedUnattended` both stop the call, but they are not the same event and must
/// not be reported as the same one: a person said no, versus nobody was asked.
public enum ToolApprovalOutcome: Sendable, Equatable {
    case approved
    case rejected
    case refusedUnattended

    public var isApproved: Bool { self == .approved }
}

/// Gates sensitive autonomous tool calls behind a real, interactive user decision.
///
/// `AgentRunner` calls `requestApproval` and suspends the ReAct loop until the chat UI
/// (`ToolCallCardView`) calls `resolve` in response to the user tapping Approve/Reject.
///
/// That suspension is correct only while somebody is actually looking at the chat. A run started
/// from a Shortcut, Siri or a schedule has no such observer, so the same request would hang until
/// the caller gave up — leaving a half-finished turn and no explanation. Unattended runs therefore
/// declare themselves, and an approval inside one is refused immediately and recorded, so the
/// caller can say which action it stopped on rather than silently doing less than asked.
///
/// Refuse-and-report is the deliberate default. The alternative — auto-approving because no one is
/// watching — grants *more* power precisely when there is least oversight.
@MainActor
public final class ToolApprovalManager: ObservableObject {
    public static let shared = ToolApprovalManager()

    @Published public private(set) var pendingApprovals: [PendingToolApproval] = []

    /// Approvals refused because the run had no one to ask. Cleared when a scope begins.
    @Published public private(set) var refusedWhileUnattended: [PendingToolApproval] = []

    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    /// Nesting depth rather than a flag, so overlapping unattended runs cannot have the inner one
    /// clear the outer one's policy when it finishes.
    private var unattendedDepth = 0

    public var isUnattended: Bool { unattendedDepth > 0 }

    private init() {}

    /// Run `body` with approvals refused rather than awaited.
    public func withUnattendedApprovals<T>(_ body: () async throws -> T) async rethrows -> T {
        beginUnattended()
        defer { endUnattended() }
        return try await body()
    }

    public func beginUnattended() {
        if unattendedDepth == 0 { refusedWhileUnattended.removeAll() }
        unattendedDepth += 1
    }

    public func endUnattended() {
        unattendedDepth = max(0, unattendedDepth - 1)
    }

    /// Suspends until the user approves or rejects the call identified by `callId` — unless the run
    /// is unattended, in which case it is refused at once.
    public func requestApproval(
        callId: String,
        toolName: String,
        argumentsJson: String,
        reason: String
    ) async -> ToolApprovalOutcome {
        let request = PendingToolApproval(
            id: callId,
            toolName: toolName,
            argumentsJson: argumentsJson,
            reason: reason
        )

        if isUnattended {
            // Do not enqueue it: nothing is going to resolve a queue no one can see, and a stale
            // entry would appear as a live prompt the next time the user opens the app.
            refusedWhileUnattended.append(request)
            return .refusedUnattended
        }

        pendingApprovals.append(request)
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            continuations[callId] = continuation
        }
        return approved ? .approved : .rejected
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
