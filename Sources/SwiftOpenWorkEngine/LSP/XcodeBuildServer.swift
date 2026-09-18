import Foundation

/// Code intelligence for Xcode projects that have no `Package.swift`.
///
/// sourcekit-lsp cannot read an `.xcodeproj`. Without build settings it answers from one file at a
/// time, which looks complete and is not. `xcode-build-server` bridges the gap. It writes a
/// `buildServer.json` next to the project, and sourcekit-lsp then asks it for each file's compiler
/// arguments, which it takes from Xcode's latest build log.
///
/// It does not index. References and callers come from the index Xcode wrote during its last build,
/// so anything edited since is missing from them. That is why every answer for such a project says
/// how old its index is, and why a rename refuses while files have changed since the build.
public enum XcodeBuildServer {

    /// What `xcode-build-server config` wrote.
    public struct Configuration: Equatable, Sendable {
        /// DerivedData for this project, where the build logs and the index live.
        public var buildRoot: String?
        public var scheme: String?
    }

    /// `buildServer.json` in `root`, when it was written by xcode-build-server.
    public static func configuration(at root: String) -> Configuration? {
        let path = (root as NSString).appendingPathComponent("buildServer.json")
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["kind"] as? String) == "xcode" || (object["name"] as? String) == "xcode build server"
        else { return nil }
        return Configuration(buildRoot: object["build_root"] as? String, scheme: object["scheme"] as? String)
    }

    /// Whether the index behind a project's answers is out of date.
    public struct Freshness: Equatable, Sendable {
        /// When Xcode last wrote a build log, or nil when the project has never been built.
        public var lastBuild: Date?
        /// Source files modified after that build, relative to the root. Capped.
        public var changedSinceBuild: [String]
        public var changedCount: Int

        public var isStale: Bool { lastBuild == nil || changedCount > 0 }
    }

    public static let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "metal"]

    public static func freshness(root: String, configuration: Configuration, fileManager: FileManager = .default) -> Freshness {
        let lastBuild = configuration.buildRoot.flatMap { latestBuildLog(buildRoot: $0, fileManager: fileManager) }
        guard let lastBuild else { return Freshness(lastBuild: nil, changedSinceBuild: [], changedCount: 0) }

        var changed: [String] = []
        var count = 0
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return Freshness(lastBuild: lastBuild, changedSinceBuild: [], changedCount: 0)
        }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            // A bound on the walk: a checkout with a vendored tree must not stall every answer.
            if visited > 50_000 { break }
            let name = url.lastPathComponent
            if name == "node_modules" || name == "DerivedData" || name == "Pods" || name == "build" {
                walker.skipDescendants()
                continue
            }
            guard sourceExtensions.contains(url.pathExtension.lowercased()),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > lastBuild else { continue }
            count += 1
            if changed.count < 10 {
                // The walk may spell the root /private/var where the caller wrote /var.
                changed.append(CodeIntelligence.relativePath(url.path, workspaceRoot: root))
            }
        }
        return Freshness(lastBuild: lastBuild, changedSinceBuild: changed.sorted(), changedCount: count)
    }

    /// The newest `.xcactivitylog` under `buildRoot/Logs/Build`.
    public static func latestBuildLog(buildRoot: String, fileManager: FileManager = .default) -> Date? {
        let logs = (buildRoot as NSString).appendingPathComponent("Logs/Build")
        let names = (try? fileManager.contentsOfDirectory(atPath: logs)) ?? []
        return names
            .filter { $0.hasSuffix(".xcactivitylog") }
            .compactMap { try? fileManager.attributesOfItem(atPath: (logs as NSString).appendingPathComponent($0))[.modificationDate] as? Date }
            .max()
    }

    /// The line an answer carries so its reader knows what the index covers.
    public static func note(for freshness: Freshness, now: Date = Date()) -> String {
        guard let lastBuild = freshness.lastBuild else {
            return "This Xcode project has not been built, so there is no index: references, callers and cross-file definitions will be missing. Run build_project, then ask again."
        }
        let age = describe(now.timeIntervalSince(lastBuild))
        guard freshness.changedCount > 0 else {
            return "Index from the last Xcode build (\(age) ago); no source files have changed since."
        }
        let listed = freshness.changedSinceBuild.joined(separator: ", ")
        let more = freshness.changedCount > freshness.changedSinceBuild.count ? " and \(freshness.changedCount - freshness.changedSinceBuild.count) more" : ""
        return "Index from the last Xcode build (\(age) ago). \(freshness.changedCount) source file\(freshness.changedCount == 1 ? " has" : "s have") changed since (\(listed)\(more)), so references and callers may miss or misplace uses in them. Run build_project to refresh."
    }

    public static func describe(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 90 { return "\(seconds)s" }
        if seconds < 90 * 60 { return "\(seconds / 60) min" }
        if seconds < 36 * 3600 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) days"
    }

    /// Notes for an answer from the server rooted at `root`; empty for any other kind of project.
    public static func notes(forRoot root: String) -> [String] {
        guard let configuration = configuration(at: root) else { return [] }
        return [note(for: freshness(root: root, configuration: configuration))]
    }

    // MARK: - Setup

    /// Where an Xcode project without a Package.swift lives, walking up from `file` to the workspace.
    public static func xcodeProjectDirectory(containing file: String, workspaceRoot: String, listDirectory: (String) -> [String]) -> String? {
        let root = LanguageServerCatalog.standardized(workspaceRoot)
        var directory = (LanguageServerCatalog.standardized(file) as NSString).deletingLastPathComponent
        guard directory == root || directory.hasPrefix(root + "/") else { return nil }
        while true {
            if listDirectory(directory).contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return directory
            }
            if directory == root || directory == "/" { return nil }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    /// The shell command that writes `buildServer.json` for a container.
    public static func configCommand(executable: String, developerDirectory: String?, flag: String, container: String, scheme: String) -> String {
        var parts: [String] = []
        if let developerDirectory { parts.append("DEVELOPER_DIR=\(BuildDiagnostics.quoted(developerDirectory))") }
        parts += [BuildDiagnostics.quoted(executable), "config", flag, BuildDiagnostics.quoted(container), "-scheme", BuildDiagnostics.quoted(scheme)]
        return parts.joined(separator: " ")
    }

    public static func buildCommand(developerDirectory: String?, flag: String, container: String, scheme: String) -> String {
        var parts: [String] = []
        if let developerDirectory { parts.append("DEVELOPER_DIR=\(BuildDiagnostics.quoted(developerDirectory))") }
        parts += ["xcodebuild", flag, BuildDiagnostics.quoted(container), "-scheme", BuildDiagnostics.quoted(scheme), "-quiet", "build"]
        return parts.joined(separator: " ")
    }

    public static let installHint = "Install it with: brew install xcode-build-server"
}
