import Foundation

/// Output from agent-run commands, while they are still running.
///
/// `runProcess` and `executeShell` already drain their pipes as bytes arrive — they have to, or a
/// chatty build deadlocks on a full pipe buffer. Until now those bytes went straight into a private
/// buffer and were shown only once the process exited, so a four-minute `xcodebuild` was four
/// minutes of spinner. This publishes the same chunks as they land, for the tool card that is
/// running and for the terminal panel.
///
/// The tail is bounded rather than complete: this is for watching, not for reading. The full
/// output still arrives in the tool result, which is what the model and the transcript get.
@MainActor
public final class LiveToolOutput: ObservableObject {
    public static let shared = LiveToolOutput()

    static let maxTailLines = 24
    static let maxTailCharacters = 4_000

    /// Live tail per tool call id. Empty once the call finishes and its result takes over.
    @Published public private(set) var tails: [String: String] = [:]

    private init() {}

    public func begin(callId: String) {
        tails[callId] = ""
    }

    public func append(callId: String, chunk: String) {
        guard !chunk.isEmpty else { return }
        var text = (tails[callId] ?? "") + chunk
        if text.count > Self.maxTailCharacters {
            text = String(text.suffix(Self.maxTailCharacters))
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.maxTailLines {
            text = lines.suffix(Self.maxTailLines).joined(separator: "\n")
        }
        tails[callId] = text
    }

    /// Drop the tail once the finished result is on screen, so the card stops showing both.
    public func finish(callId: String) {
        tails.removeValue(forKey: callId)
    }

    public func tail(for callId: String) -> String? {
        guard let text = tails[callId], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// Route a chunk from a background pipe handler to both live surfaces.
    ///
    /// Called from `readabilityHandler`, which is not on the main actor, so the hop happens here
    /// rather than at each of the call sites.
    nonisolated static func publish(chunk: String, callId: String?) {
        guard !chunk.isEmpty else { return }
        Task { @MainActor in
            if let callId { shared.append(callId: callId, chunk: chunk) }
            WorkspaceTerminalSession.shared.appendAgentOutput(chunk)
        }
    }

    nonisolated static func announce(command: String, callId: String?) {
        Task { @MainActor in
            if let callId { shared.begin(callId: callId) }
            WorkspaceTerminalSession.shared.announceAgentCommand(command)
        }
    }

    nonisolated static func conclude(callId: String?, exitCode: Int32) {
        Task { @MainActor in
            if let callId { shared.finish(callId: callId) }
            WorkspaceTerminalSession.shared.concludeAgentCommand(exitCode: exitCode)
        }
    }
}
