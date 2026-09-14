import Foundation

/// Per-tool enablement inside an enabled MCP server.
///
/// The server's `isEnabled` remains the parent switch; `disabledTools` turns off individual
/// advertised tools underneath it. Recording *disabled* names rather than enabled ones means a
/// server that later advertises new tools exposes them by default instead of silently hiding them.
public enum MCPToolGate: Sendable {
    public static func isToolEnabled(server: MCPServerConfig, toolName: String) -> Bool {
        guard server.isEnabled else { return false }
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return !server.disabledTools.contains(trimmed)
    }

    public static func setTool(_ enabled: Bool, named toolName: String, in server: inout MCPServerConfig) {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if enabled {
            server.disabledTools.removeAll { $0 == trimmed }
        } else if !server.disabledTools.contains(trimmed) {
            server.disabledTools.append(trimmed)
        }
    }

    public static func setAllTools(_ enabled: Bool, advertised: [String], in server: inout MCPServerConfig) {
        server.disabledTools = enabled ? [] : advertised
    }

    /// Model-facing refusal. Says what to do instead so the turn can continue.
    public static func disabledMessage(server: MCPServerConfig, toolName: String) -> String {
        """
        Tool '\(toolName)' on MCP server '\(server.name)' is turned off for this workspace. \
        Nothing was executed. Do not ask the user to enable it mid-task — use a different tool that \
        does the same job, or tell the user it is unavailable.
        """
    }
}
