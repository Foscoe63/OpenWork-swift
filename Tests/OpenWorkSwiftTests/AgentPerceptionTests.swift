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
