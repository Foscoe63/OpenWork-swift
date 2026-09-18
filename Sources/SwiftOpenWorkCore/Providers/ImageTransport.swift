import Foundation
import AppKit

/// Getting an image from a `ChatMessage` to a model.
///
/// `supportsVision` was on every `ModelInfo`, `isVLM` was detected from each model's
/// `config.json` during discovery, every `ChatMessage` carried `attachments` with a `mimeType`,
/// and the app shipped a "Vision OCR" extension — while every provider serialized
/// `msg.content`, a `String`, and nothing else. `MLXSessionReuse` even conceded the point in a
/// comment: "attachments are not compared, so reuse is unsafe". You could attach a screenshot
/// and the model would never see it.
public enum ImageTransport {

    /// Cap per image. Cloud providers reject oversized payloads outright, and a 4K retina window
    /// grab is comfortably over the line before any of them complain usefully.
    public static let maxPixelWidth: CGFloat = 1600

    /// Size on disk, or 0 if it cannot be read.
    ///
    /// `attributesOfItem` throws and its subscript returns `Any?`, so the obvious inline
    /// spelling is a `try?` wrapped around an `as?` — which yields a doubly-optional that
    /// invites exactly the redundant `?? 0 ?? 0` this replaces in two call sites.
    public static func fileSize(atPath path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    public static func isImage(_ attachment: MessageAttachment) -> Bool {
        attachment.mimeType.hasPrefix("image/")
            || ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(
                (attachment.path as NSString).pathExtension.lowercased()
            )
    }

    public static func imageAttachments(in message: ChatMessage) -> [MessageAttachment] {
        message.attachments.filter(isImage)
    }

    public static func messagesCarryImages(_ messages: [ChatMessage]) -> Bool {
        messages.contains { !imageAttachments(in: $0).isEmpty }
    }

    /// PNG bytes for `attachment`, downscaled to `maxPixelWidth` if needed.
    public static func pngData(for attachment: MessageAttachment) -> Data? {
        guard let image = NSImage(contentsOfFile: attachment.path) else { return nil }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = CGFloat(cg.width)
        guard width > maxPixelWidth else {
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }

        let scale = maxPixelWidth / width
        let target = NSSize(width: width * scale, height: CGFloat(cg.height) * scale)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        resized.unlockFocus()
        guard let rcg = resized.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: rcg).representation(using: .png, properties: [:])
    }

    public static func base64PNG(for attachment: MessageAttachment) -> String? {
        pngData(for: attachment)?.base64EncodedString()
    }

    /// OpenAI-compatible content blocks: text first, then each image as a data URL.
    public static func openAIContent(text: String, images: [MessageAttachment]) -> Any {
        guard !images.isEmpty else { return text }
        var blocks: [[String: Any]] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for image in images {
            guard let b64 = base64PNG(for: image) else { continue }
            blocks.append([
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(b64)"]
            ])
        }
        return blocks.isEmpty ? text : blocks
    }

    /// Anthropic content blocks. Same shape, different spelling.
    public static func anthropicContent(text: String, images: [MessageAttachment]) -> Any {
        guard !images.isEmpty else { return text }
        var blocks: [[String: Any]] = []
        for image in images {
            guard let b64 = base64PNG(for: image) else { continue }
            blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/png", "data": b64]
            ])
        }
        // Anthropic reads images better when they precede the question about them.
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        return blocks.isEmpty ? text : blocks
    }

    /// Ollama carries images as a sibling array of bare base64 strings.
    public static func ollamaImages(_ images: [MessageAttachment]) -> [String] {
        images.compactMap { base64PNG(for: $0) }
    }

    /// What to say when a model cannot see, instead of dropping the image silently.
    ///
    /// Silently discarding is how the old behaviour looked from the outside: the agent would
    /// confidently discuss a screenshot it had never received.
    public static func blindModelNotice(count: Int, modelName: String) -> String {
        let noun = count == 1 ? "image was" : "\(count) images were"
        return """

        [\(noun) attached to this message, but \(modelName) has no vision capability, so \
        \(count == 1 ? "it was" : "they were") not sent. Use accessibility_tree for a textual \
        view of a window, which works with any model, or switch to a vision-capable model.]
        """
    }
}
