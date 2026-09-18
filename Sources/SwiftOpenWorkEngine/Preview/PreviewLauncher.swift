import Foundation
import SwiftOpenWorkCore

/// Starting a preview, shared by the pane and the agent's `preview_start` tool so both do exactly
/// the same thing.
@MainActor
public enum PreviewLauncher {

    public struct Outcome {
        public var server: DevServer?
        /// The tab showing it.
        public var tab: PreviewController?
        /// Why the preview is not showing, when it is not.
        public var failure: String?
    }

    /// Start `plan` (or reuse the server already running it), wait until it answers, and load it
    /// into a tab: the one already showing that server, an idle one, or a new one — never over the
    /// page of another server that is still running.
    public static func start(
        plan: DevServerPlan,
        workspaceRoot: String,
        settings: AppSettings,
        sessions: PreviewSessions? = nil,
        forceNewTab: Bool = false
    ) async -> Outcome {
        let manager = DevServerManager.shared
        let sessions = sessions ?? .shared

        let server: DevServer
        let entryPath: String
        let reloadOnSave: Bool
        switch plan.kind {
        case .command(let command):
            server = await manager.start(command: command, in: workspaceRoot, settings: settings)
            entryPath = ""
            // Dev servers reload the page themselves (HMR); a second reload on every save would
            // throw away the state HMR exists to keep.
            reloadOnSave = false
        case .staticFiles(let root, let entry):
            server = await manager.startStatic(root: root)
            entryPath = entry == "index.html" ? "" : entry
            reloadOnSave = true
        }

        let tab = forceNewTab
            ? sessions.newTab(workspaceRoot: workspaceRoot)
            : sessions.tab(forServer: server, workspaceRoot: workspaceRoot)
        tab.workspaceRoot = workspaceRoot
        tab.serverId = server.id
        tab.reloadOnSave = reloadOnSave

        if let failure = await manager.waitUntilReady(server, timeout: 90) {
            return Outcome(server: server, tab: tab, failure: failure)
        }
        guard let base = server.url else {
            return Outcome(server: server, tab: tab, failure: "The server started but its address is unknown.")
        }
        tab.load(entryPath.isEmpty ? base : base.appendingPathComponent(entryPath))
        return Outcome(server: server, tab: tab, failure: nil)
    }
}
