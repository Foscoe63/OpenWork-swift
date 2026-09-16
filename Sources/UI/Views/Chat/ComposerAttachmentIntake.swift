import Foundation
import AppKit
import UniformTypeIdentifiers

/// Build `MessageAttachment`s from Finder drops, pasteboard files, and pasted images.
public enum ComposerAttachmentIntake {

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]

    public static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "pdf": return "application/pdf"
        case "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "rb", "java", "kt",
             "md", "txt", "json", "yml", "yaml", "toml", "csv", "html", "css", "xml":
            return "text/plain"
        default:
            if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
                return type.preferredMIMEType ?? "image/png"
            }
            return "application/octet-stream"
        }
    }

    public static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func attachment(fromFileURL url: URL) -> MessageAttachment? {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let size = ImageTransport.fileSize(atPath: path)
        let mime = mimeType(forPath: path)
        let preview: String? = {
            if mime.hasPrefix("text/") || mime == "application/json" {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return nil
        }()
        return MessageAttachment(
            name: url.lastPathComponent,
            path: path,
            sizeBytes: size,
            mimeType: mime,
            previewText: preview.map { String($0.prefix(2_000)) }
        )
    }

    /// Persist clipboard/drag image bytes so `ImageTransport` can load them like a normal attachment.
    public static func attachment(fromImage image: NSImage, preferredName: String = "paste.png") -> MessageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return attachment(fromPNGData: png, preferredName: preferredName)
    }

    public static func attachment(fromPNGData data: Data, preferredName: String = "paste.png") -> MessageAttachment? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftOpenWorkPastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = preferredName.hasSuffix(".png") ? preferredName : preferredName + ".png"
        let url = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return MessageAttachment(
            name: name,
            path: url.path,
            sizeBytes: Int64(data.count),
            mimeType: "image/png",
            previewText: nil
        )
    }

    public static func attachments(fromPasteboard pasteboard: NSPasteboard) -> [MessageAttachment] {
        var out: [MessageAttachment] = []
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] {
            for url in urls {
                if let att = attachment(fromFileURL: url) {
                    out.append(att)
                }
            }
        }
        if out.isEmpty, let image = NSImage(pasteboard: pasteboard),
           let att = attachment(fromImage: image) {
            out.append(att)
        }
        return out
    }
}
