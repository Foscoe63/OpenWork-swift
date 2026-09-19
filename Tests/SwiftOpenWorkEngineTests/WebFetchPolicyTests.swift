import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// `fetch_url` was the one unguarded way out: these pin when it asks.
final class WebFetchPolicyTests: XCTestCase {

    private func reason(_ url: String, allowed: Set<String> = [], ports: Set<Int> = []) -> String? {
        WebFetchPolicy.approvalReason(for: URL(string: url)!, allowedHosts: allowed, previewPorts: ports)
    }

    func testLocalAndPrivateAddresses() {
        for host in ["localhost", "app.localhost", "127.0.0.1", "127.8.9.10", "10.0.0.5", "172.16.0.1", "172.31.255.255",
                     "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "printer.local", "nas.lan",
                     "::1", "fd12::1", "fe80::1", "::ffff:192.168.0.1",
                     "2130706433", "0x7f000001", "0x7f.1", "0177.0.0.1", "127.1"] {
            XCTAssertTrue(WebFetchPolicy.isLocal(host: host), host)
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "192.169.0.1", "100.128.0.1", "2606:4700::1111", "docs.swift.org"] {
            XCTAssertFalse(WebFetchPolicy.isLocal(host: host), host)
        }
    }

    func testPublicSitesAskOnceAndThenAreAllowed() {
        XCTAssertNotNil(reason("https://docs.swift.org/x"))
        XCTAssertNil(reason("https://docs.swift.org/x", allowed: ["docs.swift.org"]))
        XCTAssertNil(reason("https://DOCS.swift.org./y", allowed: ["docs.swift.org"]), "hosts are compared normalised")
        XCTAssertNotNil(reason("https://evil.example/?d=secret", allowed: ["docs.swift.org"]), "another site still asks")
    }

    func testLocalAddressesAlwaysAskExceptOwnPreviewServers() {
        XCTAssertNotNil(reason("http://192.168.1.1/admin", allowed: ["192.168.1.1"]), "never remembered")
        XCTAssertNotNil(reason("http://localhost:8080/"))
        XCTAssertNil(reason("http://localhost:5173/", ports: [5173]))
        XCTAssertNil(reason("http://127.0.0.1:5173/", ports: [5173]))
        XCTAssertNotNil(reason("http://192.168.1.20:5173/", ports: [5173]), "a preview port is only trusted on loopback")
    }

    func testRedirectsFromPublicPagesIntoTheLocalNetworkAreRefused() {
        let page = URL(string: "https://example.com/start")
        XCTAssertFalse(WebFetchPolicy.allowsRedirect(from: page, to: URL(string: "http://192.168.1.1/")!))
        XCTAssertFalse(WebFetchPolicy.allowsRedirect(from: page, to: URL(string: "http://localhost:631/")!))
        XCTAssertTrue(WebFetchPolicy.allowsRedirect(from: page, to: URL(string: "https://www.example.com/")!))
        XCTAssertTrue(WebFetchPolicy.allowsRedirect(from: URL(string: "http://localhost:3000/"), to: URL(string: "http://localhost:3000/login")!))
    }

    @MainActor
    func testApprovingAPublicFetchAllowsThatSiteForTheChatOnly() {
        var settings = AppSettings.default
        settings.allowWebAccess = true
        settings.askBeforeFetchingNewSites = true
        let session = "chat-\(UUID().uuidString)"
        let args = #"{"url":"https://api.example.org/v1"}"#

        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "fetch_url", argumentsJson: args, settings: settings, sessionId: session))
        AgentRunner.rememberApprovedFetch(toolName: "fetch_url", argumentsJson: args, sessionId: session)
        XCTAssertNil(AgentRunner.approvalReason(toolName: "fetch_url", argumentsJson: #"{"url":"https://api.example.org/v2"}"#, settings: settings, sessionId: session))
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "fetch_url", argumentsJson: args, settings: settings, sessionId: "another-chat"))

        let local = #"{"url":"http://10.0.0.1/"}"#
        AgentRunner.rememberApprovedFetch(toolName: "fetch_url", argumentsJson: local, sessionId: session)
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "fetch_url", argumentsJson: local, settings: settings, sessionId: session))
    }

    @MainActor
    func testTheSettingAndWebAccessTurnTheQuestionOff() {
        var settings = AppSettings.default
        let args = #"{"url":"https://example.net/"}"#
        settings.askBeforeFetchingNewSites = false
        XCTAssertNil(AgentRunner.approvalReason(toolName: "fetch_url", argumentsJson: args, settings: settings, sessionId: "s"))
        settings.askBeforeFetchingNewSites = true
        settings.allowWebAccess = false
        XCTAssertNil(AgentRunner.approvalReason(toolName: "fetch_url", argumentsJson: args, settings: settings, sessionId: "s"),
                     "with web access off the tool refuses by itself")
    }

    func testNewInstallsAskAndOldSettingsFilesGetTheDefault() throws {
        XCTAssertTrue(AppSettings.default.askBeforeFetchingNewSites)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.askBeforeFetchingNewSites)
    }
}

/// Chat history is written in the background, in order, newest snapshot wins.
final class SessionWriteTests: XCTestCase {

    func testABurstOfSavesEndsWithTheLastOneOnDisk() {
        let persistence = PersistenceManager.shared
        let original = persistence.loadSessions()
        defer {
            persistence.saveSessions(original)
            persistence.flushSessionWrites()
        }
        let marker = "burst-\(UUID().uuidString)"
        for i in 0..<200 {
            let session = Session(id: marker, workspaceId: "w", title: "\(marker)-\(i)", agentId: "a", providerId: "p", modelId: "m")
            persistence.saveSessions(original + [session])
        }
        let loaded = persistence.loadSessions()
        XCTAssertEqual(loaded.first { $0.id == marker }?.title, "\(marker)-199")
    }
}
