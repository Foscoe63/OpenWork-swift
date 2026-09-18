import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

final class MCPCatalogPromoteTests: XCTestCase {

    private let macuse = MCPServerConfig(id: "srv-macuse", name: "macuse", command: "macuse")

    func testHarvestsToolsFromWrappedCatalog() {
        let payload = """
        {"tools": [
          {"name": "mail_search_messages", "description": "Search mail",
           "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}}},
          {"name": "mail_send_message", "description": "Send mail"}
        ]}
        """
        let harvested = MCPCatalogPromote.harvest(
            server: macuse,
            executeTool: "call_tool_by_name",
            resultText: payload
        )

        XCTAssertEqual(harvested.count, 2)
        XCTAssertEqual(harvested[0].chatName, "mcp__srv-macuse__mail_search_messages")
        XCTAssertEqual(harvested[0].injectName, "mail_search_messages")
        XCTAssertEqual(harvested[0].executeTool, "call_tool_by_name")
        XCTAssertTrue(harvested[0].inputSchemaJson.contains("limit"))
    }

    func testHarvestsToolsFromBareArray() {
        let payload = #"[{"name": "list_windows"}, {"name": "app_click"}]"#
        let harvested = MCPCatalogPromote.harvest(
            server: macuse,
            executeTool: "call_tool_by_name",
            resultText: payload
        )
        XCTAssertEqual(harvested.map(\.injectName), ["list_windows", "app_click"])
    }

    func testHarvestsFromNestedPayload() {
        let payload = #"{"result": {"definitions": [{"name": "notes_create_note"}]}}"#
        let harvested = MCPCatalogPromote.harvest(
            server: macuse,
            executeTool: "call_tool_by_name",
            resultText: payload
        )
        XCTAssertEqual(harvested.map(\.injectName), ["notes_create_note"])
    }

    /// Promoting the dispatcher would just recreate the wrapper the model is trying to escape.
    func testDispatchersAreNeverPromoted() {
        let payload = #"{"tools": [{"name": "call_tool_by_name"}, {"name": "get_tool_definitions"}, {"name": "mail_get_thread"}]}"#
        let harvested = MCPCatalogPromote.harvest(
            server: macuse,
            executeTool: "call_tool_by_name",
            resultText: payload
        )
        XCTAssertEqual(harvested.map(\.injectName), ["mail_get_thread"])
    }

    func testFallsBackToBacktickNamesInProse() {
        let text = "Available: `mail_list_accounts`, `mail_search_messages`. Ignore `x`."
        let harvested = MCPCatalogPromote.harvest(
            server: macuse,
            executeTool: "call_tool_by_name",
            resultText: text
        )
        XCTAssertEqual(harvested.map(\.injectName), ["mail_list_accounts", "mail_search_messages"])
    }

    func testCatalogSourceDetection() {
        XCTAssertTrue(MCPCatalogPromote.isCatalogSource("mcp__srv__get_tool_definitions"))
        XCTAssertTrue(MCPCatalogPromote.isCatalogSource("mcp__srv__toolport_search_tools"))
        XCTAssertFalse(MCPCatalogPromote.isCatalogSource("mcp__srv__mail_send_message"))
    }

    func testDispatchArgumentsNestUnderCatalogName() {
        let promoted = MCPPromotedTool(
            chatName: "mcp__srv-macuse__mail_search_messages",
            serverId: "srv-macuse",
            serverName: "macuse",
            executeTool: "call_tool_by_name",
            injectName: "mail_search_messages"
        )
        let args = MCPCatalogPromote.dispatchArguments(for: promoted, raw: ["limit": 50])

        XCTAssertEqual(args["name"] as? String, "mail_search_messages")
        XCTAssertEqual((args["arguments"] as? [String: Any])?["limit"] as? Int, 50)
    }

    func testDispatchArgumentsUnwrapAlreadyNestedArguments() {
        let promoted = MCPPromotedTool(
            chatName: "mcp__srv-macuse__mail_search_messages",
            serverId: "srv-macuse",
            serverName: "macuse",
            executeTool: "call_tool_by_name",
            injectName: "mail_search_messages"
        )
        let args = MCPCatalogPromote.dispatchArguments(
            for: promoted,
            raw: ["arguments": ["limit": 10]]
        )
        XCTAssertEqual((args["arguments"] as? [String: Any])?["limit"] as? Int, 10)
        XCTAssertEqual(args["name"] as? String, "mail_search_messages")
    }

    func testPromotedWriteToolRequiresApproval() {
        let promoted = MCPPromotedTool(
            chatName: "mcp__srv-macuse__mail_send_message",
            serverId: "srv-macuse",
            serverName: "macuse",
            executeTool: "call_tool_by_name",
            injectName: "mail_send_message"
        )
        let model = MCPCatalogPromote.toolModel(for: promoted, effect: .write)
        XCTAssertTrue(model.requiresApproval)
        XCTAssertEqual(model.category, .mcp)
    }

    func testRegistryReportsOnlyNewcomers() async {
        let registry = MCPPromotedToolRegistry.shared
        await registry.reset()

        let tool = MCPPromotedTool(
            chatName: "mcp__srv__a_tool",
            serverId: "srv",
            serverName: "srv",
            executeTool: "call_tool_by_name",
            injectName: "a_tool"
        )
        let first = await registry.register([tool])
        let second = await registry.register([tool])

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        let found = await registry.lookup("mcp__srv__a_tool")
        XCTAssertEqual(found?.injectName, "a_tool")

        await registry.reset()
        let afterReset = await registry.lookup("mcp__srv__a_tool")
        XCTAssertNil(afterReset)
    }

    // MARK: - Regressions found by probing the real MacUse server

    /// MacUse wraps its catalog as `{actions: [...], data: {tools: [...]}}` — an `actions` array
    /// of example calls sits alongside the real catalog. Preferring whichever array was found
    /// first made the outcome depend on dictionary ordering, so the same payload could promote
    /// the catalog on one run and four examples on the next.
    func testPicksTheRealCatalogNotTheExamples() throws {
        let payload = """
        {"actions":[{"instruction":"Call calendar_cancel_event","tool_call":{"tool":"call_tool_by_name","arguments":{"name":"calendar_cancel_event","arguments":{}}}}],
         "data":{"tools":[
           {"name":"mail_search_messages","description":"Search mail","inputSchema":{"type":"object"}},
           {"name":"mail_list_accounts","description":"List accounts","inputSchema":{"type":"object"}},
           {"name":"notes_create_note","description":"Create note","inputSchema":{"type":"object"}}
         ]}}
        """
        let harvested = MCPCatalogPromote.harvest(
            server: macuse, executeTool: "call_tool_by_name", resultText: payload
        )
        let names = Set(harvested.map(\.injectName))
        XCTAssertTrue(names.contains("mail_search_messages"))
        XCTAssertTrue(names.contains("mail_list_accounts"))
        XCTAssertTrue(names.contains("notes_create_note"))
        XCTAssertFalse(names.contains("calendar_cancel_event"), "the examples array must not win")
    }

    /// The catalog used to be truncated to 40,000 characters before it was parsed, which left
    /// invalid JSON and silently downgraded promotion to scraping backticked names out of prose.
    func testLargeCatalogSurvivesTheResultBound() throws {
        let tools = (1...400).map {
            "{\"name\":\"tool_\($0)\",\"description\":\"\(String(repeating: "x", count: 120))\",\"inputSchema\":{\"type\":\"object\"}}"
        }.joined(separator: ",")
        let payload = "{\"data\":{\"tools\":[\(tools)]}}"
        XCTAssertGreaterThan(payload.count, 40_000, "fixture must exceed the old bound")

        let harvested = MCPCatalogPromote.harvest(
            server: macuse, executeTool: "call_tool_by_name", resultText: payload
        )
        XCTAssertEqual(harvested.count, MCPCatalogPromote.maxPromoted)
        XCTAssertTrue(harvested.allSatisfy { $0.injectName.hasPrefix("tool_") },
                      "names must come from JSON, not from scraped prose")
    }
}
