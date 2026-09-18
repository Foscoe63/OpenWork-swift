import Foundation
import os
import SwiftOpenWorkCore

/// Carries 1.1 data across the rename from OpenWork (`ai.openwork.OpenWorkSwift`) to
/// SwiftOpenWork (`io.github.foscoe63.SwiftOpenWork`).
///
/// A new bundle ID is a new app to macOS: a fresh preferences domain, and no claim on the old
/// one's files. What moves, once, before anything is loaded:
///
/// - **Application Support/OpenWorkSwift → SwiftOpenWork**: settings, sessions, agents,
///   automations. This is the one that matters.
/// - **`~/.openwork` → `~/.swiftopenwork`**: downloaded models and screenshots.
/// - **Preferences** from the old domain, with this app's own keys renamed.
///
/// **Before the first real launch, the 1.1 data wins.** The unit tests run inside the app, on the
/// real home folder and preferences domain, so a developer's machine already has a
/// `SwiftOpenWork` folder full of seed files and test window positions before the renamed app
/// has ever been opened. Keeping those and leaving the real data behind would look like every
/// session had been lost. So a folder already under the new name is moved aside, never deleted,
/// and the 1.1 folder takes its place. After the migration has run once it never runs again, so
/// nothing a real launch wrote can be displaced.
///
/// What deliberately does not move:
///
/// - **Keychain secrets** migrate lazily in `KeychainManager`, one item at a time as it is read,
///   so macOS asks about only the credentials actually in use.
/// - **Existing workspaces under `~/Documents/OpenWork`** keep their stored paths. Moving a
///   user's project folders is not a rename's business.
/// - **Accessibility and Screen Recording grants** belong to the bundle ID and cannot be carried
///   over by an app; they have to be granted again once.
public enum LegacyIdentityMigration {

    public static let completedKey = "SwiftOpenWork.migration.legacyIdentity.v1"

    /// Old key → new key, for keys this app wrote itself. Anything else is copied unchanged.
    public static func renamedKey(_ key: String) -> String {
        if key.hasPrefix("openwork.windowLayout.v1.") {
            return "swiftopenwork.windowLayout.v1." + key.dropFirst("openwork.windowLayout.v1.".count)
        }
        switch key {
        case "OpenWork.updates.lastAutomaticCheck":
            return "SwiftOpenWork.updates.lastAutomaticCheck"
        case "NSWindow Frame OpenWorkMainWindow":
            return "NSWindow Frame SwiftOpenWorkMainWindow"
        default:
            return key
        }
    }

    /// The preferences to write from the old domain. Pure, for tests.
    ///
    /// Old values replace anything already under the new name: this only runs before the renamed
    /// app's first real launch, when the new domain can hold nothing but test-host leftovers.
    public static func migratedPreferences(legacy: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in legacy {
            result[renamedKey(key)] = value
        }
        return result
    }

    private static let didRun = OSAllocatedUnfairLock(initialState: false)

    /// Safe to call from anywhere and more than once; the work happens once per install.
    public static func runIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        let shouldRun: Bool = didRun.withLock { didRun in
            if didRun { return false }
            didRun = true
            return true
        }
        guard shouldRun, !AppIdentity.isHostedByTests else { return }
        guard !defaults.bool(forKey: completedKey) else { return }

        if let legacy = defaults.persistentDomain(forName: AppIdentity.legacyBundleIdentifier) {
            for (key, value) in migratedPreferences(legacy: legacy) {
                defaults.set(value, forKey: key)
            }
        }

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            adoptLegacyDirectory(
                from: appSupport.appendingPathComponent(AppIdentity.legacyApplicationSupportFolderName, isDirectory: true),
                to: appSupport.appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true),
                fileManager: fileManager
            )
        }
        adoptLegacyDirectory(
            from: AppIdentity.legacyHomeDataDirectory,
            to: AppIdentity.homeDataDirectory,
            fileManager: fileManager
        )

        defaults.set(true, forKey: completedKey)
    }

    /// Puts the 1.1 folder where the renamed app looks. A folder already there is renamed
    /// `<name>.before-migration-<timestamp>` rather than deleted or merged — merging two copies of
    /// `sessions.json` has no right answer, and deleting is not a migration's call.
    ///
    /// Returns the path the displaced folder was moved to, if there was one.
    @discardableResult
    public static func adoptLegacyDirectory(
        from legacy: URL,
        to current: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> URL? {
        guard fileManager.fileExists(atPath: legacy.path) else { return nil }
        var displaced: URL?
        if fileManager.fileExists(atPath: current.path) {
            let stamp = Int(now.timeIntervalSince1970)
            let aside = current.deletingLastPathComponent()
                .appendingPathComponent("\(current.lastPathComponent).before-migration-\(stamp)", isDirectory: true)
            do {
                try fileManager.moveItem(at: current, to: aside)
                displaced = aside
            } catch {
                return nil // Leave both alone rather than half-move.
            }
        }
        do {
            try fileManager.moveItem(at: legacy, to: current)
        } catch {
            // Put the displaced folder back, so a failed move changes nothing.
            if let displaced { try? fileManager.moveItem(at: displaced, to: current) }
            return nil
        }
        return displaced
    }
}
