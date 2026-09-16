import Foundation

/// The app's name and identifiers, in one place.
///
/// The app was called "OpenWork" with the bundle ID `ai.openwork.OpenWorkSwift`. There is
/// already a different app called OpenWork, and `ai.openwork` is that product's domain, so as of
/// 1.2 this app is **SwiftOpenWork** with the bundle ID `io.github.foscoe63.SwiftOpenWork`,
/// based on the GitHub account it is published from.
///
/// Everything a user or the system can see goes through here. The `legacy*` values exist only so
/// `LegacyIdentityMigration` and a few readers can find data 1.1 wrote under the old names — do
/// not use them for anything new.
public enum AppIdentity {
    public static let displayName = "SwiftOpenWork"
    public static let bundleIdentifier = "io.github.foscoe63.SwiftOpenWork"

    /// Unified log subsystem: `log stream --predicate 'subsystem == "io.github.foscoe63.SwiftOpenWork"'`.
    public static let logSubsystem = bundleIdentifier
    public static let keychainService = bundleIdentifier

    /// `~/.swiftopenwork`: downloaded models and agent screenshots.
    public static var homeDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftopenwork", isDirectory: true)
    }

    /// Branches for agent worktrees are `swiftopenwork/<task>`.
    public static let worktreeBranchPrefix = "swiftopenwork/"
    public static let worktreeContainerName = ".swiftopenwork-worktrees"

    /// Standing instructions file this app writes. Legacy names are still read.
    public static let rulesFileName = "SWIFTOPENWORK.md"

    /// `~/Library/Application Support/SwiftOpenWork`: settings, sessions, agents, automations.
    public static let applicationSupportFolderName = "SwiftOpenWork"

    /// Default parent folder for new workspaces. Existing workspaces keep their stored paths.
    public static let workspacesRelativePath = "Documents/SwiftOpenWork/Workspaces"

    // MARK: - 1.1 names, for migration only

    public static let legacyBundleIdentifier = "ai.openwork.OpenWorkSwift"
    public static let legacyKeychainService = "ai.openwork.OpenWorkSwift"
    public static let legacyApplicationSupportFolderName = "OpenWorkSwift"
    public static var legacyHomeDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openwork", isDirectory: true)
    }
    public static let legacyWorktreeBranchPrefix = "openwork/"
    public static let legacyWorktreeContainerName = ".openwork-worktrees"
    public static let legacyRulesFileNames = ["OPENWORK.md", ".openwork.md"]
}
