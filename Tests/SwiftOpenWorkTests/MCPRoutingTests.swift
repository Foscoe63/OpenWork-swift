import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

final class MCPRoutingTests: XCTestCase {

    private func server(_ id: String, _ name: String, command: String = "npx") -> MCPServerConfig {
        MCPServerConfig(id: id, name: name, command: command)
    }

    // MARK: - Server identity

    func testCanonicalServerMatchesIdNameAndSlug() {
        let servers = [server("srv-1", "Fast Filesystem"), server("srv-2", "GitHub")]

        XCTAssertEqual(MCPToolRouting.canonicalServer("srv-1", in: servers)?.id, "srv-1")
        XCTAssertEqual(MCPToolRouting.canonicalServer("GitHub", in: servers)?.id, "srv-2")
        XCTAssertEqual(MCPToolRouting.canonicalServer("github", in: servers)?.id, "srv-2")
        XCTAssertEqual(MCPToolRouting.canonicalServer("fast-filesystem", in: servers)?.id, "srv-1")
        XCTAssertEqual(MCPToolRouting.canonicalServer("fast_filesystem", in: servers)?.id, "srv-1")
    }

    func testCanonicalServerStripsModelDecorations() {
        let servers = [server("srv-1", "macuse")]
        XCTAssertEqual(MCPToolRouting.canonicalServer("macuse[id=123]", in: servers)?.id, "srv-1")
        XCTAssertEqual(MCPToolRouting.canonicalServer("mcp_macuse", in: servers)?.id, "srv-1")
        XCTAssertEqual(MCPToolRouting.canonicalServer("  MacUse  ", in: servers)?.id, "srv-1")
    }

    /// The regression that motivated this layer: substring matching silently picked a server.
    func testAmbiguousServerNameResolvesToNilRatherThanFirstMatch() {
        let servers = [server("a", "files"), server("b", "files")]
        XCTAssertNil(MCPToolRouting.canonicalServer("files", in: servers))
    }

    func testUnknownServerResolvesToNil() {
        let servers = [server("a", "github")]
        XCTAssertNil(MCPToolRouting.canonicalServer("gitlab", in: servers))
    }

    // MARK: - Tool ownership

    func testServerOwningPrefersNamespacedName() {
        let servers = [server("srv-1", "github"), server("srv-2", "gitlab")]
        let advertised = ["srv-1": ["search_repositories"], "srv-2": ["search_repositories"]]

        let hit = MCPToolRouting.serverOwning(
            tool: "mcp__srv-2__search_repositories",
            servers: servers,
            advertised: advertised
        )
        XCTAssertEqual(hit?.server.id, "srv-2")
        XCTAssertEqual(hit?.tool, "search_repositories")
    }

    func testServerOwningRejectsToolAdvertisedByTwoServers() {
        let servers = [server("srv-1", "github"), server("srv-2", "gitlab")]
        let advertised = ["srv-1": ["search_repositories"], "srv-2": ["search_repositories"]]

        XCTAssertNil(MCPToolRouting.serverOwning(
            tool: "search_repositories",
            servers: servers,
            advertised: advertised
        ))
    }

    func testServerOwningAcceptsUniqueAdvertisedTool() {
        let servers = [server("srv-1", "github"), server("srv-2", "ddg-search")]
        let advertised = ["srv-1": ["create_issue"], "srv-2": ["search"]]

        XCTAssertEqual(
            MCPToolRouting.serverOwning(tool: "search", servers: servers, advertised: advertised)?.server.id,
            "srv-2"
        )
    }

    func testServerOwningResolvesSlugPrefixedName() {
        let servers = [server("srv-1", "fast-filesystem"), server("srv-2", "github")]
        let advertised = ["srv-1": ["read_file"], "srv-2": ["create_issue"]]

        let hit = MCPToolRouting.serverOwning(
            tool: "fast_filesystem_read_file",
            servers: servers,
            advertised: advertised
        )
        XCTAssertEqual(hit?.server.id, "srv-1")
        XCTAssertEqual(hit?.tool, "read_file")
    }

    // MARK: - resolveServer

    func testResolveServerFailsWhenNoneEnabled() {
        guard case .failed(let message) = MCPToolRouting.resolveServer(
            requested: "github",
            enabled: []
        ) else {
            return XCTFail("Expected failure with no enabled servers")
        }
        XCTAssertTrue(message.contains("No MCP servers are enabled"))
    }

    func testResolveServerFailsRatherThanGuessingAmongMany() {
        let servers = [server("a", "github"), server("b", "ddg-search")]
        guard case .failed(let message) = MCPToolRouting.resolveServer(
            requested: "",
            toolName: "mystery_tool",
            enabled: servers,
            advertised: [:]
        ) else {
            return XCTFail("Expected failure when the server is unnamed and ambiguous")
        }
        // The message has to name the options, or the model cannot recover.
        XCTAssertTrue(message.contains("github"))
        XCTAssertTrue(message.contains("ddg-search"))
        XCTAssertTrue(message.contains("nothing was executed"))
    }

    func testResolveServerUsesSoleEnabledServerWhenUnnamed() {
        let servers = [server("a", "github")]
        guard case .resolved(let hit) = MCPToolRouting.resolveServer(
            requested: "",
            toolName: "anything",
            enabled: servers
        ) else {
            return XCTFail("Expected the only enabled server to resolve")
        }
        XCTAssertEqual(hit.id, "a")
    }

    func testResolveServerReportsUnknownName() {
        let servers = [server("a", "github")]
        guard case .failed(let message) = MCPToolRouting.resolveServer(
            requested: "notaserver",
            enabled: servers
        ) else {
            return XCTFail("Expected failure for an unknown server name")
        }
        XCTAssertTrue(message.contains("notaserver"))
        XCTAssertTrue(message.contains("github"))
    }

    // MARK: - Namespacing round-trip

    func testNamespacedToolRoundTrip() {
        let name = MCPNamespacedTool.name(serverId: "srv-1", toolName: "read_file")
        XCTAssertEqual(name, "mcp__srv-1__read_file")
        let parsed = MCPNamespacedTool.parse(name)
        XCTAssertEqual(parsed?.serverId, "srv-1")
        XCTAssertEqual(parsed?.toolName, "read_file")
    }

    func testNamespacedToolPreservesUnderscoresInLeafName() {
        let name = MCPNamespacedTool.name(serverId: "srv", toolName: "a__b")
        XCTAssertEqual(MCPNamespacedTool.parse(name)?.toolName, "a__b")
    }
}
