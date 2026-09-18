import Foundation
import SwiftOpenWorkCore

/// The agent's side of the live preview: start the project, look at the page, read the logs.
///
/// `run_app` and `screenshot_window` let the agent see a native app it built. A web project had no
/// equivalent: the agent could run `npm run build` and read that it compiled, then describe a page
/// it had never loaded, whose console was full of errors nobody reported. These close that loop —
/// and they drive the same preview the user is looking at, so both see the same page.
enum PreviewTools {

    static let names: Set<String> = ["preview_start", "preview_check", "preview_logs", "preview_stop"]

    /// Tools that only read. Allowed in plan mode, never need approval.
    static let readOnly: Set<String> = ["preview_check", "preview_logs"]

    // MARK: preview_start

    @MainActor
    static func start(arguments: [String: Any], workspace: Workspace, settings: AppSettings, startTime: CFAbsoluteTime) async -> ToolExecutionResult {
        let root = workspace.folderPath
        let sessions = PreviewSessions.shared
        let newTab = arguments["new_tab"] as? Bool ?? false

        // Attaching to something already running needs no server of our own.
        if let rawURL = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespaces), !rawURL.isEmpty {
            guard let url = PreviewURLPolicy.normalize(typed: rawURL),
                  PreviewURLPolicy.loadsInPane(url, workspaceRoot: root) else {
                return ToolExecutionEngine.failure("preview_start only opens local servers (localhost, 127.0.0.1) or files inside the workspace. Use fetch_url to read a remote page.", startTime)
            }
            revealPaneIfWatched()
            let tab = newTab || sessions.active.currentURL != nil ? sessions.newTab(workspaceRoot: root) : sessions.active
            tab.workspaceRoot = root
            tab.load(url)
            return await report(tab: tab, url: url, reload: false, settle: 1.5, workspace: workspace, server: nil, preface: "Opened \(url.absoluteString) in preview tab \(sessions.number(of: tab) ?? 1).", startTime: startTime)
        }

        let plan: DevServerPlan
        if let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            plan = DevServerPlan(kind: .command(command), reason: "command given", caveat: nil)
        } else if let detected = DevServerCommandDetector.plan(root: root) {
            plan = detected
        } else {
            return ToolExecutionEngine.failure(
                "Could not tell how to run this project: no package.json dev script, framework entry point, or index.html in \(root). Pass `command` (e.g. \"npm run dev\"), or `url` for a server that is already running.",
                startTime
            )
        }

        revealPaneIfWatched()
        let outcome = await PreviewLauncher.start(plan: plan, workspaceRoot: root, settings: settings, forceNewTab: newTab)
        let server = outcome.server
        if let failure = outcome.failure {
            var message = "The preview did not start: \(failure)"
            if let caveat = plan.caveat { message += "\n\nNote: \(caveat)" }
            if let server {
                message += "\n\nServer output (last 60 lines):\n```\n\(server.logTail(60))\n```"
            }
            return ToolExecutionResult(
                success: false,
                output: message,
                error: failure,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let tab = outcome.tab ?? sessions.active
        let preface = [
            "Started \(server?.command ?? "the preview") (\(plan.reason)) in preview tab \(sessions.number(of: tab) ?? 1).",
            server?.url.map { "Serving at \($0.absoluteString). It keeps running after this call; stop it with preview_stop." },
        ].compactMap { $0 }.joined(separator: " ")
        return await report(tab: tab, url: nil, reload: false, settle: 2, workspace: workspace, server: server, preface: preface, startTime: startTime)
    }

    // MARK: preview_check

    @MainActor
    static func check(arguments: [String: Any], workspace: Workspace, startTime: CFAbsoluteTime) async -> ToolExecutionResult {
        let sessions = PreviewSessions.shared
        let tabReference = (arguments["tab"] as? String) ?? (arguments["tab"] as? Int).map(String.init)
        guard let preview = tabReference == nil ? sessions.active : sessions.find(tabReference) else {
            let names = sessions.tabs.enumerated().map { "\($0.offset + 1): \($0.element.displayTitle) — \($0.element.currentURL?.absoluteString ?? "empty")" }
            return ToolExecutionEngine.failure("No preview tab matches '\(tabReference ?? "")'. Open tabs:\n\(names.joined(separator: "\n"))", startTime)
        }
        if preview.workspaceRoot == nil { preview.workspaceRoot = workspace.folderPath }

        var target: URL?
        if let raw = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let url = PreviewURLPolicy.normalize(typed: raw), PreviewURLPolicy.loadsInPane(url, workspaceRoot: workspace.folderPath) else {
                return ToolExecutionEngine.failure("preview_check only loads local servers or workspace files. Use fetch_url for remote pages.", startTime)
            }
            target = url
        } else if let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            guard let base = preview.currentURL ?? DevServerManager.shared.activeServer?.url,
                  var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                return ToolExecutionEngine.failure("Nothing is being previewed yet, so there is no server to resolve '\(path)' against. Call preview_start first.", startTime)
            }
            let parts = path.split(separator: "?", maxSplits: 1)
            components.path = parts.first.map { $0.hasPrefix("/") ? String($0) : "/" + $0 } ?? "/"
            components.query = parts.count > 1 ? String(parts[1]) : nil
            target = components.url
        }

        if target == nil, preview.currentURL == nil {
            if let url = preview.serverId.flatMap({ id in DevServerManager.shared.servers.first { $0.id == id } })?.url
                ?? DevServerManager.shared.activeServer?.url {
                target = url
            } else {
                return ToolExecutionEngine.failure("Nothing is being previewed. Call preview_start first (it detects how to run the project), or pass a local `url`.", startTime)
            }
        }

        let reload = arguments["reload"] as? Bool ?? true
        let settle = (arguments["wait_seconds"] as? Double) ?? (arguments["wait_seconds"] as? Int).map(Double.init) ?? 1.5
        if let width = (arguments["viewport_width"] as? Int) ?? (arguments["viewport_width"] as? Double).map({ Int($0) }) {
            preview.viewportWidth = CGFloat(min(max(width, 320), 2_560))
        }
        let server = preview.serverId.flatMap { id in DevServerManager.shared.servers.first { $0.id == id } }
        return await report(
            tab: preview,
            url: target,
            reload: reload,
            settle: settle,
            workspace: workspace,
            server: server,
            preface: nil,
            startTime: startTime,
            screenshot: arguments["screenshot"] as? Bool ?? true
        )
    }

    // MARK: preview_logs

    @MainActor
    static func logs(arguments: [String: Any], startTime: CFAbsoluteTime) -> ToolExecutionResult {
        let lines = min(max((arguments["lines"] as? Int) ?? 80, 5), 400)
        let manager = DevServerManager.shared
        let sessions = PreviewSessions.shared
        var out = ""
        if manager.servers.isEmpty {
            out += "No dev server has been started.\n"
        }
        for server in manager.servers.suffix(4) {
            out += "\(server.id == manager.activeServer?.id ? "▶︎ " : "")\(server.command) — \(server.status.label)"
            if let url = server.url { out += " — \(url.absoluteString)" }
            out += "\n```\n\(server.logTail(lines))\n```\n"
        }
        if sessions.tabs.isEmpty {
            out += "\nNo preview tabs are open.\n"
        }
        for (index, tab) in sessions.tabs.enumerated() {
            let marker = tab.id == sessions.activeId ? " (active)" : ""
            out += "\nPreview tab \(index + 1)\(marker): \(tab.displayTitle) — \(tab.currentURL?.absoluteString ?? "empty")\n"
            let console = tab.console.suffix(sessions.tabs.count > 1 ? 20 : 40)
            if console.isEmpty {
                out += "Browser console: empty.\n"
            } else {
                for entry in console {
                    out += "- [\(entry.level.rawValue)] \(entry.message.prefix(400))\n"
                }
            }
            if arguments["clear_console"] as? Bool == true {
                tab.clearConsole()
            }
        }
        return ToolExecutionResult(success: true, output: out, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
    }

    // MARK: preview_stop

    @MainActor
    static func stop(startTime: CFAbsoluteTime) -> ToolExecutionResult {
        let manager = DevServerManager.shared
        let live = manager.liveServers
        guard !live.isEmpty else {
            return ToolExecutionResult(success: true, output: "No dev server was running.", durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
        manager.stopAll()
        let names = live.map { "- \($0.command)" }.joined(separator: "\n")
        return ToolExecutionResult(success: true, output: "Stopped:\n\(names)", durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
    }

    // MARK: Helpers

    @MainActor
    private static func report(
        tab: PreviewController,
        url: URL?,
        reload: Bool,
        settle: Double,
        workspace: Workspace,
        server: DevServer?,
        preface: String?,
        startTime: CFAbsoluteTime,
        screenshot: Bool = true
    ) async -> ToolExecutionResult {
        let result = await tab.check(
            url: url,
            reload: reload,
            settleSeconds: settle,
            viewportWidth: nil,
            screenshotDirectory: screenshot ? ToolExecutionEngine.perceptionDirectory(for: workspace) : nil
        )
        var serverSummary: String?
        if let server {
            let tail = server.logTail(25)
            serverSummary = "Server (\(server.status.label)) output, last lines:\n```\n\(tail)\n```"
        }
        var output = PreviewReport.format(
            url: result.url,
            title: result.title,
            httpStatus: result.httpStatus,
            loadError: result.loadError,
            console: result.console,
            visibleText: result.visibleText,
            serverSummary: serverSummary,
            screenshotAttached: result.screenshotPath != nil
        )
        if let preface { output = preface + "\n\n" + output }
        let sessions = PreviewSessions.shared
        if sessions.tabs.count > 1, let number = sessions.number(of: tab) {
            output += "\n(Preview tab \(number) of \(sessions.tabs.count). Pass `tab` to preview_check to look at another.)\n"
        }
        let failed = result.loadError != nil || (result.httpStatus ?? 200) >= 500
        return ToolExecutionResult(
            success: !failed,
            output: output,
            error: failed ? (result.loadError ?? "HTTP \(result.httpStatus ?? 0)") : nil,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
            producedImages: result.screenshotPath.map { [$0] } ?? []
        )
    }

    /// Show the preview when someone is at the window to see it; an unattended run looks offscreen.
    @MainActor
    private static func revealPaneIfWatched() {
        guard !ToolApprovalManager.shared.isUnattended else { return }
        let app = AppState.shared
        if app.navigationDestination != .chat && app.navigationDestination != .tools { return }
        app.revealInspector(tab: .preview, minimumWidth: 560)
    }

    /// The approval prompt for `preview_start`, or nil when it runs nothing.
    static func approvalReason(argumentsJson: String) -> String? {
        let dict = (try? JSONSerialization.jsonObject(with: Data(argumentsJson.utf8))) as? [String: Any] ?? [:]
        if let url = dict["url"] as? String, !url.trimmingCharacters(in: .whitespaces).isEmpty,
           (dict["command"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }
        if let command = (dict["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return "Starts a long-running server on your Mac: `\(command)`. It keeps running until stopped."
        }
        return "Starts the project's dev server (the command is detected from the workspace, e.g. `npm run dev`). It keeps running until stopped."
    }
}
