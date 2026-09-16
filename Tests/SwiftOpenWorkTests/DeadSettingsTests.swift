import XCTest
@testable import SwiftOpenWork

/// Settings that existed in the model and the UI but that nothing ever read. A switch that does
/// nothing is worse than no switch: it reads as a guarantee. These pin the ones now wired.
@MainActor
final class WiredSettingsTests: XCTestCase {

    private func agent(canSpawn: Bool = true) -> Agent {
        Agent(name: "Lead", canSpawnSubAgents: true, isLeadAgent: true)
    }

    /// The whole point of a global off switch is that a per-agent "yes" cannot override it.
    func testSubAgentSpawningIsRefusedWhenTheGlobalSwitchIsOff() {
        var settings = AppSettings()
        settings.allowSubAgentCreation = false
        XCTAssertFalse(AgentRunner.subAgentSpawningAllowed(agent: agent(), settings: settings))
    }

    func testSubAgentSpawningIsRefusedWhenTheDepthBudgetIsZero() {
        var settings = AppSettings()
        settings.allowSubAgentCreation = true
        settings.maxGlobalSubAgentDepth = 0
        XCTAssertFalse(AgentRunner.subAgentSpawningAllowed(agent: agent(), settings: settings))
    }

    func testSubAgentSpawningIsAllowedWhenBothPermit() {
        var settings = AppSettings()
        settings.allowSubAgentCreation = true
        settings.maxGlobalSubAgentDepth = 3
        XCTAssertTrue(AgentRunner.subAgentSpawningAllowed(agent: agent(), settings: settings))
    }

    /// An agent that cannot spawn must stay unable to, whatever the settings say.
    func testAnAgentWithSpawningDisabledStillCannot() {
        var settings = AppSettings()
        settings.allowSubAgentCreation = true
        settings.maxGlobalSubAgentDepth = 3
        let quiet = Agent(name: "Solo", canSpawnSubAgents: false)
        XCTAssertFalse(AgentRunner.subAgentSpawningAllowed(agent: quiet, settings: settings))
    }

    /// A negative value in a stored settings file must not read as "unlimited".
    func testANegativeDepthBudgetIsTreatedAsZero() {
        var settings = AppSettings()
        settings.allowSubAgentCreation = true
        settings.maxGlobalSubAgentDepth = -5
        XCTAssertFalse(AgentRunner.subAgentSpawningAllowed(agent: agent(), settings: settings))
    }
}

/// Settings that were removed rather than wired. The risk of removing a stored field is that every
/// existing settings.json still contains it.
final class RemovedSettingsTests: XCTestCase {

    /// Decoding must ignore keys that no longer exist, not fail and reset the user's whole config.
    func testASettingsFileCarryingRemovedKeysStillDecodes() throws {
        let json = """
        {
          "theme": "dark",
          "streamResponses": true,
          "uiScalePercent": 110,
          "autoSaveIntervalSeconds": 45,
          "mlxContextLength": 262144,
          "sandboxAgentFileSystem": false,
          "cloudSyncEnabled": true,
          "cloudControlPlaneUrl": "https://cloud.openwork.ai/api",
          "cloudAccountEmail": "developer@openwork.local",
          "cloudOrganizationName": "Personal Workspace"
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.theme, .dark, "the keys that remain must survive")
        XCTAssertFalse(decoded.sandboxAgentFileSystem, "a stored value must still win over the default")
    }
}
