import AppIntents
import Foundation

/// Shortcuts and Siri entry points.
///
/// These run the same `AgentRunner` the chat window runs — there is no second, simpler execution
/// path — with one difference: approvals are refused rather than awaited, because nothing is on
/// screen to grant them. Each intent therefore reports what it skipped alongside what it did. See
/// `ToolApprovalManager` for why refusing beats auto-approving.
///
/// Every run is recorded as a session, so "what did Siri just do to my repo" has an answer.

// MARK: - Ask

struct AskSwiftOpenWorkIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask SwiftOpenWork"
    static var description = IntentDescription(
        "Run a prompt through your current SwiftOpenWork agent and return its reply.",
        categoryName: "Agents"
    )

    /// The app must be running: the agent needs its MCP servers, loaded model and workspace.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", requestValueDialog: "What should the agent do?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SwiftOpenWorkIntentError.emptyPrompt
        }

        let result = await HeadlessAgentTurn.run(
            prompt: trimmed,
            title: String(trimmed.prefix(35)),
            appState: AppState.shared
        )
        return .result(value: result.spoken, dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

// MARK: - Automations

/// An automation, as Shortcuts sees it: a thing the user picks from a list.
struct AutomationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Automation"
    static var defaultQuery = AutomationQuery()

    var id: String
    var name: String
    var details: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(details)")
    }
}

struct AutomationQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AutomationEntity] {
        AppState.shared.automations
            .filter { identifiers.contains($0.id) }
            .map(AutomationEntity.init(automation:))
    }

    @MainActor
    func suggestedEntities() async throws -> [AutomationEntity] {
        AppState.shared.automations.map(AutomationEntity.init(automation:))
    }
}

extension AutomationEntity {
    init(automation: Automation) {
        self.id = automation.id
        self.name = automation.name
        self.details = automation.description.isEmpty
            ? automation.triggerType.displayName
            : automation.description
    }
}

struct RunAutomationIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Automation"
    static var description = IntentDescription(
        "Run one of your SwiftOpenWork automations and return what it produced.",
        categoryName: "Agents"
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Automation")
    var automation: AutomationEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let stored = AppState.shared.automations.first(where: { $0.id == automation.id }) else {
            // The automation was deleted after Shortcuts captured it. Say so rather than running
            // something else that happens to be nearby.
            throw SwiftOpenWorkIntentError.automationNotFound(automation.name)
        }
        guard stored.isEnabled else {
            throw SwiftOpenWorkIntentError.automationDisabled(stored.name)
        }

        AppState.shared.recordAutomationRunStarted(id: stored.id, summary: "Started from Shortcuts…")
        let storedId = stored.id
        // The automation's own agent, as a scheduled run uses. Without it a Shortcut ran the
        // prompt against whichever agent was last selected in the window.
        let result = await HeadlessAgentTurn.run(
            prompt: stored.promptTemplate,
            title: stored.name,
            appState: AppState.shared,
            agentId: stored.targetAgentId,
            onSessionStarted: { sessionId in
                AppState.shared.recordAutomationSession(id: storedId, sessionId: sessionId)
            }
        )
        AppState.shared.recordAutomationRun(
            id: stored.id,
            succeeded: result.skipped.isEmpty && !result.reply.isEmpty,
            summary: result.skipped.isEmpty
                ? "Ran from Shortcuts."
                : "Ran from Shortcuts; \(result.skipped.count) action(s) skipped for want of approval."
        )
        return .result(value: result.spoken, dialog: IntentDialog(stringLiteral: result.spoken))
    }
}

// MARK: - Errors

enum SwiftOpenWorkIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case emptyPrompt
    case automationNotFound(String)
    case automationDisabled(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyPrompt:
            return "There was no prompt to run."
        case .automationNotFound(let name):
            return "The automation “\(name)” no longer exists in SwiftOpenWork."
        case .automationDisabled(let name):
            return "The automation “\(name)” is turned off in SwiftOpenWork."
        }
    }
}

// MARK: - Siri phrases

struct SwiftOpenWorkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskSwiftOpenWorkIntent(),
            // Only entity and enum parameters may appear in a phrase, so Siri asks for the
            // prompt after the phrase rather than capturing it inside one.
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask SwiftOpenWork",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: RunAutomationIntent(),
            phrases: [
                "Run \(.applicationName) automation",
                "Run \(\.$automation) in \(.applicationName)"
            ],
            shortTitle: "Run Automation",
            systemImageName: "bolt.badge.clock"
        )
    }
}
