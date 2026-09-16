import XCTest
@testable import SwiftOpenWork

/// Fail-closed effect classification, per-tool gating, and failure classification.
final class MCPSafetyTests: XCTestCase {

    private func server(_ name: String, command: String = "npx") -> MCPServerConfig {
        MCPServerConfig(id: "srv-\(name)", name: name, command: command)
    }

    // MARK: - Effect classification

    func testKnownServerReadToolIsRead() {
        let github = server("github")
        XCTAssertEqual(
            MCPEffectCatalog.classify(server: github, toolName: "search_repositories", advertised: true),
            .read
        )
    }

    func testKnownServerWriteToolIsWrite() {
        let github = server("github")
        XCTAssertEqual(
            MCPEffectCatalog.classify(server: github, toolName: "create_issue", advertised: true),
            .write
        )
    }

    /// The prefix heuristic this replaced classified these as reads because they start with
    /// `get_`/`search`, which is exactly how an unapproved mutation used to slip through.
    func testDeceptivelyNamedToolsAreWrites() {
        let github = server("github")
        for name in ["get_or_create_repository", "search_and_replace", "list_and_archive"] {
            XCTAssertEqual(
                MCPEffectCatalog.classify(server: github, toolName: name, advertised: true),
                .write,
                "\(name) must not be classified as a read"
            )
        }
    }

    func testUnknownServerIsAlwaysWrite() {
        let mystery = server("some-vendor-thing", command: "./mystery")
        XCTAssertEqual(
            MCPEffectCatalog.classify(server: mystery, toolName: "get_status", advertised: true),
            .write
        )
    }

    func testUnadvertisedToolIsWriteEvenOnKnownServer() {
        let github = server("github")
        XCTAssertEqual(
            MCPEffectCatalog.classify(server: github, toolName: "search_repositories", advertised: false),
            .write
        )
    }

    func testNilServerIsWrite() {
        XCTAssertEqual(
            MCPEffectCatalog.classify(server: nil, toolName: "list_things", advertised: true),
            .write
        )
    }

    func testUniversalReadToolsAreReadsAnywhere() {
        let mystery = server("some-vendor-thing", command: "./mystery")
        XCTAssertEqual(
            MCPEffectCatalog.classify(server: mystery, toolName: "get_tool_definitions", advertised: false),
            .read
        )
    }

    func testVerbTokensAreMatchedOnWordBoundariesNotSubstrings() {
        // `list_commits` contains "commit" as a substring but is a read.
        XCTAssertFalse(MCPEffectCatalog.nameSuggestsWrite("list_commits"))
        XCTAssertFalse(MCPEffectCatalog.nameSuggestsWrite("get_settings"))
        XCTAssertFalse(MCPEffectCatalog.nameSuggestsWrite("search_repositories"))

        XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite("commit_changes"))
        XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite("set_config"))
    }

    func testVerbDetectionHandlesCamelCase() {
        XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite("createJiraIssue"))
        XCTAssertFalse(MCPEffectCatalog.nameSuggestsWrite("getJiraIssue"))
    }

    // MARK: - Meta-tool nesting

    func testNestedReadTargetIsRead() {
        let macuse = server("macuse")
        XCTAssertEqual(
            MCPEffectCatalog.classifyNested(server: macuse, nestedToolName: "mail_search_messages"),
            .read
        )
    }

    func testNestedWriteTargetIsWrite() {
        let macuse = server("macuse")
        XCTAssertEqual(
            MCPEffectCatalog.classifyNested(server: macuse, nestedToolName: "mail_send_message"),
            .write
        )
    }

    /// A dispatcher call whose target cannot be read is the most dangerous case — it must ask.
    func testUnreadableNestedTargetIsWrite() {
        let macuse = server("macuse")
        XCTAssertEqual(MCPEffectCatalog.classifyNested(server: macuse, nestedToolName: nil), .write)
        XCTAssertEqual(MCPEffectCatalog.classifyNested(server: macuse, nestedToolName: "  "), .write)
    }

    // MARK: - Per-tool gate

    func testAllToolsEnabledByDefault() {
        let config = server("github")
        XCTAssertTrue(MCPToolGate.isToolEnabled(server: config, toolName: "create_issue"))
    }

    func testDisablingOneToolLeavesSiblingsOn() {
        var config = server("github")
        MCPToolGate.setTool(false, named: "create_issue", in: &config)

        XCTAssertFalse(MCPToolGate.isToolEnabled(server: config, toolName: "create_issue"))
        XCTAssertTrue(MCPToolGate.isToolEnabled(server: config, toolName: "search_repositories"))
    }

    func testReEnablingRemovesTheGate() {
        var config = server("github")
        MCPToolGate.setTool(false, named: "create_issue", in: &config)
        MCPToolGate.setTool(true, named: "create_issue", in: &config)

        XCTAssertTrue(config.disabledTools.isEmpty)
        XCTAssertTrue(MCPToolGate.isToolEnabled(server: config, toolName: "create_issue"))
    }

    func testDisabledServerDisablesEveryTool() {
        var config = server("github")
        config.isEnabled = false
        XCTAssertFalse(MCPToolGate.isToolEnabled(server: config, toolName: "search_repositories"))
    }

    /// Storing disabled names (not enabled ones) means a newly advertised tool is not hidden.
    func testToolsAddedAfterGatingAreEnabled() {
        var config = server("github")
        MCPToolGate.setAllTools(false, advertised: ["create_issue"], in: &config)
        XCTAssertTrue(MCPToolGate.isToolEnabled(server: config, toolName: "brand_new_tool"))
    }

    // MARK: - Failure classification

    func testPlainTextFailuresAreDetected() {
        let failures = [
            "Error: MCP Server 'x' has crashed.",
            "Input validation error: 'path' is a required property",
            "no route for tool ''",
            "MaxRetriesExceeded: connection refused",
            "HTTP 422 from server",
        ]
        for text in failures {
            XCTAssertTrue(MCPFailureClassifier.failed(text: text), "Expected failure for: \(text)")
        }
    }

    func testSuccessfulOutputIsNotAFailure() {
        XCTAssertFalse(MCPFailureClassifier.failed(text: "Found 12 repositories matching 'swift'."))
        XCTAssertFalse(MCPFailureClassifier.failed(text: "{\"results\": []}"))
    }

    /// A document fetched through an MCP tool may quote an error without being one.
    func testLongSuccessfulPayloadMentioningAnErrorIsNotAFailure() {
        let log = String(repeating: "2026-09-14 request ok\n", count: 200) + "connection refused"
        XCTAssertFalse(MCPFailureClassifier.failed(text: log))
    }

    func testFrontLoadedErrorStillDetectedInLongOutput() {
        let text = "connection refused\n" + String(repeating: "trace line\n", count: 200)
        XCTAssertTrue(MCPFailureClassifier.failed(text: text))
    }

    func testTransientFailuresAreRetryable() {
        XCTAssertTrue(MCPFailureClassifier.isTransientFailure("connection refused"))
        XCTAssertTrue(MCPFailureClassifier.isTransientFailure("request timed out"))
        XCTAssertTrue(MCPFailureClassifier.isTransientFailure("socket hang up"))
    }

    /// A protocol mismatch or a rejected token never recovers — retrying just wastes a step.
    func testPermanentFailuresAreNotRetryable() {
        XCTAssertFalse(MCPFailureClassifier.isTransientFailure("SSLError: WRONG_VERSION_NUMBER"))
        XCTAssertFalse(MCPFailureClassifier.isTransientFailure("401 unauthorized"))
        XCTAssertFalse(MCPFailureClassifier.isTransientFailure("'path' is a required property"))
    }

    func testDeadEndDetection() {
        XCTAssertTrue(MCPFailureClassifier.isDeadEnd("cursor has expired"))
        XCTAssertTrue(MCPFailureClassifier.isDeadEnd("Error: MCP Server 'x' has crashed."))
        XCTAssertFalse(MCPFailureClassifier.isDeadEnd("Wrote 3 files."))
    }

    func testRecoveryHintsAreActionable() {
        let missingArg = MCPFailureClassifier.recoveryHint(for: "'filepath' is a required property")
        XCTAssertNotNil(missingArg)
        XCTAssertTrue(missingArg!.contains("retry once"))

        let auth = MCPFailureClassifier.recoveryHint(for: "401 unauthorized")
        XCTAssertNotNil(auth)
        XCTAssertTrue(auth!.contains("not recover"))

        XCTAssertNil(MCPFailureClassifier.recoveryHint(for: "Everything worked."))
    }

    func testAnnotateAppendsHintOnlyToFailures() {
        let failure = MCPFailureClassifier.annotate("Error: connection refused")
        XCTAssertTrue(failure.contains("Retry this exact call once"))

        let success = "Listed 4 files."
        XCTAssertEqual(MCPFailureClassifier.annotate(success), success)
    }
}

/// Argument shims for dispatcher servers, pinned from a real local-model turn.
final class MCPArgumentShimTests: XCTestCase {
    private func normalized(_ args: [String: Any]) -> [String: Any] {
        MCPToolArgumentDefaults.normalizeArguments(
            serverName: "MacUse", toolName: "get_tool_definitions", arguments: args
        )
    }

    /// Observed in a real turn: the model sent names as a string and MacUse replied
    /// "invalid type: string … expected a sequence", costing a wasted step.
    func testNamesGivenAsAStringIsWrappedInAList() {
        let out = normalized(["names": "mail_list_accounts"])
        XCTAssertEqual(out["names"] as? [String], ["mail_list_accounts"])
    }

    func testMissingOrEmptyNamesBecomesWildcard() {
        XCTAssertEqual(normalized([:])["names"] as? [String], ["*"])
        XCTAssertEqual(normalized(["names": [String]()])["names"] as? [String], ["*"])
        XCTAssertEqual(normalized(["names": "  "])["names"] as? [String], ["*"])
    }

    func testAListOfNamesIsLeftAlone() {
        let out = normalized(["names": ["mail_list_accounts", "mail_search_messages"]])
        XCTAssertEqual(out["names"] as? [String], ["mail_list_accounts", "mail_search_messages"])
    }
}
