import XCTest
import AppKit
@testable import OpenWorkSwift

/// The agent could write a view and never look at it. These cover the transport that carries
/// what it sees back to the model.
final class AgentPerceptionTests: XCTestCase {
    /// Build a real PNG on disk, then prove it survives the whole transport.
    func testImageTransportCarriesARealPNG() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/claude-501/-Volumes-Storage-Projects-OpenWork-Swift/dff16346-1e86-4e93-8f86-dee4b729f671/scratchpad/shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("synthetic.png").path

        // 2400px wide, so the downscale path is exercised too.
        let image = NSImage(size: NSSize(width: 2400, height: 1200))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 2400, height: 1200).fill()
        image.unlockFocus()
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: path))

        let att = MessageAttachment(name: "synthetic.png", path: path, mimeType: "image/png")
        XCTAssertTrue(ImageTransport.isImage(att))

        let data = try XCTUnwrap(ImageTransport.pngData(for: att))
        let decoded = try XCTUnwrap(NSImage(data: data).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) })
        XCTAssertLessThanOrEqual(CGFloat(decoded.width), ImageTransport.maxPixelWidth,
                                 "a retina window grab must be downscaled or cloud providers reject it")

        let msg = ChatMessage(role: .user, content: "what is this", attachments: [att])
        XCTAssertTrue(ImageTransport.messagesCarryImages([msg]))
        XCTAssertEqual(ImageTransport.imageAttachments(in: msg).count, 1)

        // OpenAI shape
        let openai = ImageTransport.openAIContent(text: "what is this", images: [att])
        let blocks = try XCTUnwrap(openai as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        XCTAssertEqual(blocks.last?["type"] as? String, "image_url")
        let url = try XCTUnwrap((blocks.last?["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))

        // Anthropic shape — image first, then the question about it
        let anthropic = ImageTransport.anthropicContent(text: "what is this", images: [att])
        let ablocks = try XCTUnwrap(anthropic as? [[String: Any]])
        XCTAssertEqual(ablocks.first?["type"] as? String, "image")
        XCTAssertEqual((ablocks.first?["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        XCTAssertEqual(ablocks.last?["type"] as? String, "text")

        // Ollama shape
        XCTAssertEqual(ImageTransport.ollamaImages([att]).count, 1)

        // A blind model must be told, not silently handed nothing.
        let notice = ImageTransport.blindModelNotice(count: 1, modelName: "some-text-model")
        XCTAssertTrue(notice.contains("no vision capability"))
        XCTAssertTrue(notice.contains("accessibility_tree"))
    }

    /// Permissions are per-binary, so the test runner has neither. What matters is that the
    /// failure names the exact System Settings pane instead of returning an empty string.
    func testPerceptionFailsWithAnActionableMessage() async {
        do {
            _ = try ScreenPerception.accessibilityTree(appQuery: "Finder")
            // If permission happens to be granted, that is fine too.
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("System Settings"),
                          "got: \(error.localizedDescription)")
        }
        XCTAssertNil(ScreenPerception.runningApplication(matching: "definitely-not-an-app-xyz"))
        XCTAssertFalse(ScreenPerception.runningApplicationNames().isEmpty)
    }
}

/// `run_app` exists to feed `accessibility_tree` and `screenshot_window`. It used to terminate
/// the app it launched, which made that pairing structurally impossible — a real model hit it
/// within one turn of the feature shipping, launched the app, read "then terminated", and
/// concluded it would have to relaunch before it could inspect anything.
final class RunAppLeavesTheAppInspectableTests: XCTestCase {

    /// The default has to be "still running", or the perception tools have nothing to look at.
    func testTheDefaultLeavesTheAppRunning() throws {
        let schema = ToolSchemaCatalog.schemaJSON(for: "run_app")
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        )
        let properties = try XCTUnwrap(parsed["properties"] as? [String: Any])
        let keepRunning = try XCTUnwrap(properties["keep_running"] as? [String: Any])
        let description = try XCTUnwrap(keepRunning["description"] as? String)
        XCTAssertTrue(description.contains("Default true"), "got: \(description)")
        XCTAssertTrue(description.contains("quit_app"), "the cleanup partner must be named")
    }

    /// A tool the model is told to call must exist to call.
    func testQuitAppIsAvailableToCleanUp() {
        var tools: [Tool] = []
        _ = ToolSchemaCatalog.ensureParityTools(in: &tools)
        let names = Set(tools.map(\.name))
        for expected in ["run_app", "quit_app", "screenshot_window", "accessibility_tree"] {
            XCTAssertTrue(names.contains(expected), "\(expected) is missing from the parity set")
        }
    }

    /// Every perception tool ships with a real parameter schema — an empty one breaks tool
    /// calling on local models, which is the whole reason ToolSchemaCatalog exists.
    func testPerceptionToolsHaveRealSchemas() throws {
        for name in ["run_app", "quit_app", "screenshot_window", "accessibility_tree",
                     "worktree_create", "git_commit"] {
            let schema = ToolSchemaCatalog.schemaJSON(for: name)
            XCTAssertNotEqual(schema, #"{"type":"object","properties":{}}"#, "\(name) has no schema")
            let parsed = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
            XCTAssertNotNil(parsed?["properties"], "\(name) schema does not parse")
        }
    }
}

/// A failing tool used to be reduced to `"Error: \(error)"` with `output` discarded, so any tool
/// that fails *and* explains why lost the explanation. Found live: `run_app` on an app that
/// exited immediately reported "Error: unknown error" and threw away the exit code, stdout and
/// stderr — the only things that would have identified the fault.
@MainActor
final class FailingToolsKeepTheirDiagnosticsTests: XCTestCase {

    func testAFailureKeepsTheOutputThatExplainsIt() {
        let result = ToolExecutionResult(
            success: false,
            output: "Exited after less than 8s with code 1.\nstderr:\ndyld: missing symbol",
            error: "the app exited immediately with code 1"
        )
        let described = AgentRunner.describeToolResult(result)
        XCTAssertTrue(described.contains("the app exited immediately"), "the reason must survive")
        XCTAssertTrue(described.contains("dyld: missing symbol"), "the diagnostics must survive")
    }

    /// The literal string a model received before this was fixed.
    func testAFailureWithNoReasonSaysSoRatherThanSayingUnknown() {
        let described = AgentRunner.describeToolResult(
            ToolExecutionResult(success: false, output: "", error: nil)
        )
        XCTAssertFalse(described.contains("unknown error"))
        XCTAssertTrue(described.contains("without giving a reason"), "got: \(described)")
    }

    func testASuccessIsPassedThroughUnchanged() {
        let described = AgentRunner.describeToolResult(
            ToolExecutionResult(success: true, output: "all good")
        )
        XCTAssertEqual(described, "all good")
    }
}
