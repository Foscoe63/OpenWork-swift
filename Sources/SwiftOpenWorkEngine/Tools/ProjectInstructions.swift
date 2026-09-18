import Foundation
import SwiftOpenWorkCore

/// Per-repository instructions, loaded from a file at the workspace root.
///
/// Skills are global to the app; a repo needs its own standing rules — build commands, house
/// style, things not to touch. Without this the user has to restate them every session, and the
/// agent has no way to learn them from the checkout itself.
public enum ProjectInstructions {

    /// Recognised filenames, most specific first. The first one found wins, so a repo can carry
    /// files for several tools without them being concatenated.
    ///
    /// `OPENWORK.md` and `.openwork.md` are the names from before the app was renamed
    /// SwiftOpenWork; repos that already carry them keep working.
    public static let candidateNames = [
        AppIdentity.rulesFileName,
        "OPENWORK.md",
        "AGENTS.md",
        "CLAUDE.md",
        ".swiftopenwork.md",
        ".openwork.md",
        ".cursorrules",
    ]

    /// The file Save should write: an existing file of this app's own (so a 1.1 `OPENWORK.md`
    /// is edited in place rather than shadowed by a new copy), otherwise `SWIFTOPENWORK.md`.
    /// Files owned by other tools — AGENTS.md, CLAUDE.md, .cursorrules — are never written.
    public static func saveTarget(loadedName: String?) -> String {
        let ours = [AppIdentity.rulesFileName, ".swiftopenwork.md"] + AppIdentity.legacyRulesFileNames
        if let loadedName, ours.contains(loadedName) { return loadedName }
        return AppIdentity.rulesFileName
    }

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
