import Foundation

/// Classifies MCP tool results so the agent loop can tell "this failed and will keep failing"
/// apart from "this failed once, retry it".
///
/// MCP servers report failures as ordinary text content far more often than as JSON-RPC errors,
/// so a result is inspected rather than trusted.
public enum MCPFailureClassifier: Sendable {
    /// How much of a result is scanned for failure signatures.
    ///
    /// Error messages are short and front-loaded; a 50KB document fetched *through* an MCP tool
    /// may legitimately contain "connection refused" on page three. Scanning only the head keeps
    /// successful reads from being misread as failures.
    private static let scanPrefix = 400

    /// The call did not do what was asked, whether or not the transport reported an error.
    public static func failed(isError: Bool = false, text: String) -> Bool {
        if isError { return true }
        let lower = text.lowercased()
        if lower.hasPrefix("error:") || lower.hasPrefix("mcp error") { return true }
        if lower.hasPrefix("failed to") { return true }
        let head = String(lower.prefix(scanPrefix))
        return signatures.contains { head.contains($0) }
    }

    private static let signatures: [String] = [
        "validation failed",
        "input validation error",
        "is a required property",
        "no route for tool",
        "tool not found",
        "unknown tool",
        "method not found",
        "unexpected argument",
        "invalid arguments",
        "unknown or expired",
        "permission denied",
        "unauthorized",
        " 401 ",
        " 403 ",
        " 422 ",
        ": 422",
        "max retries exceeded",
        "connection refused",
        "newconnectionerror",
        "could not connect",
        "wrong_version_number",
        "sslerror",
        "econnrefused",
    ]

    /// Worth exactly one automatic retry. Deliberately excludes protocol/config mismatches,
    /// which never recover: retrying an HTTPS-on-an-HTTP-port call just wastes a step.
    public static func isTransientFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("wrong_version_number") { return false }
        if lower.contains("unauthorized") || lower.contains("permission denied") { return false }
        if lower.contains("is a required property") { return false }
        return lower.contains("max retries exceeded")
            || lower.contains("connection refused")
            || lower.contains("econnrefused")
            || lower.contains("econnreset")
            || lower.contains("socket hang up")
            || lower.contains("newconnectionerror")
            || lower.contains("temporarily unavailable")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains(" 502")
            || lower.contains(" 503")
            || lower.contains("busy. please wait")
    }

    /// A failure mode that will not finish the user's job by repeating the call: a broken route,
    /// a dead server, an expired cursor, or a malformed payload the model keeps re-sending.
    public static func isDeadEnd(_ text: String) -> Bool {
        if failed(text: text) { return true }
        let lower = text.lowercased()
        return (lower.contains("cursor") && lower.contains("expired"))
            || lower.contains("[object object]")
            || lower.contains("parseerror")
            || lower.contains("has crashed")
            || lower.contains("failed to start")
            || lower.contains("returned an empty response")
            || lower.contains("communication pipes not available")
    }

    /// A specific, actionable next step for this failure — not "try again".
    public static func recoveryHint(for text: String) -> String? {
        let lower = text.lowercased()

        if lower.contains("wrong_version_number")
            || (lower.contains("sslerror") && (lower.contains("27123") || lower.contains("27124"))) {
            return """
            Protocol mismatch: that port is HTTP but the URL says https:// (or the reverse). \
            Fix the server URL scheme in Settings → Tools & MCP. Retrying will not help.
            """
        }
        if lower.contains("is a required property") || lower.contains("input validation error") {
            return """
            Required arguments were missing. Use the exact argument names from the tool's schema in \
            your tool list, pass the missing field explicitly, and retry once.
            """
        }
        if lower.contains("no route for tool") || lower.contains("tool not found") || lower.contains("unknown tool") {
            return """
            That tool name is not routed on this server. Use an exact name from your tool list \
            (mcp__<serverId>__<tool>) — do not invent tool names.
            """
        }
        if lower.contains("unauthorized") || lower.contains(" 401 ") || lower.contains(" 403 ")
            || lower.contains("permission denied") {
            return """
            The server rejected the credentials. This will not recover by retrying — tell the user \
            to check the token or headers for that server in Settings → Tools & MCP.
            """
        }
        if lower.contains("has crashed") || lower.contains("failed to start") {
            return """
            That server is not running. Do not retry this call. Use a different enabled MCP server, \
            a built-in tool, or tell the user the server failed to start.
            """
        }
        if isTransientFailure(text) {
            return """
            Transient connection failure. Retry this exact call once; if it fails again, use a \
            different tool and report the outage rather than looping.
            """
        }
        return nil
    }

    /// Append the recovery hint to a failed result so the model sees the fix in the same message.
    public static func annotate(_ text: String, isError: Bool = false) -> String {
        guard failed(isError: isError, text: text), let hint = recoveryHint(for: text) else {
            return text
        }
        if text.contains(hint) { return text }
        return "\(text)\n\n\(hint)"
    }
}
