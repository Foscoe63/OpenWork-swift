import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

/// Inventory mode strips every tool from the turn. A false positive silently disables the agent,
/// which is what it did to a scheduled brief every morning.
final class MCPInventoryPromptTests: XCTestCase {

    func testQuestionsAboutServersAreInventory() {
        for prompt in [
            "what mcp servers do I have?",
            "which MCP servers are configured",
            "list mcp servers",
            "check mcp servers",
            "is the github mcp server available?",
        ] {
            XCTAssertTrue(MCPClientManager.isMCPInventoryPrompt(prompt), prompt)
        }
    }

    func testTasksThatUseAServerAreNot() {
        for prompt in [
            "use the macuse mcp-server and check the mail on this computer",
            "using the github mcp server, list my open pull requests",
            "search my notes via the obsidian mcp server",
        ] {
            XCTAssertFalse(MCPClientManager.isMCPInventoryPrompt(prompt), prompt)
        }
    }

    /// The prompt that ran with no tools: long, multi-step, and mentioning a configured MCP server
    /// in passing.
    func testALongTaskMentioningAConfiguredServerIsNot() {
        let brief = """
        # MorningBrief — Task Instructions
        ## 5. Create the IranNews note
        ## 6. Check email (if available)
        - If an email account or email MCP tool is configured, always use the macuse mcp-server for checking mail.
        """
        XCTAssertFalse(MCPClientManager.isMCPInventoryPrompt(brief))
    }

    func testPromptsNotAboutMCPAreNot() {
        XCTAssertFalse(MCPClientManager.isMCPInventoryPrompt("what servers are available?"))
    }
}
