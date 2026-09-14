import Foundation

/// Per-repository instructions, loaded from a file at the workspace root.
///
/// Skills are global to the app; a repo needs its own standing rules — build commands, house
/// style, things not to touch. Without this the user has to restate them every session, and the
/// agent has no way to learn them from the checkout itself.
public enum ProjectInstructions {

    /// Recognised filenames, most specific first. The first one found wins, so a repo can carry
    /// files for several tools without them being concatenated.
    public static let candidateNames = [
        "OPENWORK.md",
        "AGENTS.md",
        "CLAUDE.md",
        ".openwork.md",
        ".cursorrules",
    ]

    /// Instructions past this are clipped — a runaway file must not crowd out the conversation.
    public static let maxCharacters = 16_000

    public struct Loaded: Sendable, Equatable {
        public var name: String
        public var content: String
        public var clipped: Bool

        public init(name: String, content: String, clipped: Bool = false) {
            self.name = name
            self.content = content
            self.clipped = clipped
        }
    }

    public static func load(
        folderPath: String,
        fileManager: FileManager = .default
    ) -> Loaded? {
        guard !folderPath.isEmpty else { return nil }
        for name in candidateNames {
            let full = (folderPath as NSString).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: full),
                  let raw = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count > maxCharacters {
                return Loaded(
                    name: name,
                    content: String(trimmed.prefix(maxCharacters)),
                    clipped: true
                )
            }
            return Loaded(name: name, content: trimmed)
        }
        return nil
    }

    /// Render for the system prompt. Empty when there is no file, so callers can interpolate
    /// unconditionally.
    public static func promptBlock(_ loaded: Loaded?) -> String {
        guard let loaded else { return "" }
        var block = """

        ### Project instructions (\(loaded.name))
        These come from the repository and take precedence over general habits. Follow them.

        \(loaded.content)
        """
        if loaded.clipped {
            block += "\n\n[\(loaded.name) was longer than \(maxCharacters) characters and has been clipped.]"
        }
        return block
    }
}
