import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// The app was renamed from OpenWork to SwiftOpenWork, with a new bundle ID. These pin the
/// migration that carries 1.1 data across, and sweep the sources so the old name cannot creep
/// back into anything a user sees.
final class RenameToSwiftOpenWorkTests: XCTestCase {

    // MARK: - Identity

    /// `AppIdentity` and the built bundle must agree, or the Keychain service, log subsystem and
    /// preferences domain would each quietly name a different app.
    func testTheBuiltBundleMatchesAppIdentity() throws {
        // SwiftPM hosts tests in `xctest` (bundle ID `com.apple.dt.xctest.tool`), not the app.
        guard Bundle.main.bundleURL.pathExtension == "app", let id = Bundle.main.bundleIdentifier else {
            throw XCTSkip("Not hosted by the app bundle; run under xcodebuild test to check the identity.")
        }
        XCTAssertEqual(id, AppIdentity.bundleIdentifier)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, AppIdentity.displayName)
    }

    // MARK: - Preferences

    func testOwnPreferenceKeysAreRenamedAndOthersCopiedAsIs() {
        XCTAssertEqual(LegacyIdentityMigration.renamedKey("openwork.windowLayout.v1.sidebarWidth"), "swiftopenwork.windowLayout.v1.sidebarWidth")
        XCTAssertEqual(LegacyIdentityMigration.renamedKey("OpenWork.updates.lastAutomaticCheck"), "SwiftOpenWork.updates.lastAutomaticCheck")
        XCTAssertEqual(LegacyIdentityMigration.renamedKey("NSWindow Frame OpenWorkMainWindow"), "NSWindow Frame SwiftOpenWorkMainWindow")
        XCTAssertEqual(LegacyIdentityMigration.renamedKey("diffViewMode"), "diffViewMode")
    }

    /// The migration runs once, before the first real launch, when anything under the new name
    /// can only have been written by a test host. The 1.1 value is the user's.
    func testOldPreferencesReplaceTestHostLeftoversUnderTheNewName() {
        let migrated = LegacyIdentityMigration.migratedPreferences(
            legacy: ["openwork.windowLayout.v1.sidebarWidth": 300.0, "diffViewMode": "unified"]
        )
        XCTAssertEqual(migrated["swiftopenwork.windowLayout.v1.sidebarWidth"] as? Double, 300.0)
        XCTAssertEqual(migrated["diffViewMode"] as? String, "unified")
        XCTAssertNil(migrated["openwork.windowLayout.v1.sidebarWidth"])
    }

    // MARK: - Folders

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ow-rename-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testTheLegacyFolderMovesIntoPlace() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("OpenWorkSwift")
        let current = base.appendingPathComponent("SwiftOpenWork")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "real".write(to: legacy.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)

        XCTAssertNil(LegacyIdentityMigration.adoptLegacyDirectory(from: legacy, to: current))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("sessions.json"), encoding: .utf8), "real")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    /// The case that would have looked like total data loss: test runs had already created a
    /// `SwiftOpenWork` folder full of seed files. The real data must win, and the other folder
    /// must survive, renamed, in case it held anything.
    func testALeftoverFolderUnderTheNewNameIsMovedAsideNotDeletedOrMerged() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("OpenWorkSwift")
        let current = base.appendingPathComponent("SwiftOpenWork")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "real".write(to: legacy.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)
        try "seed".write(to: current.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)

        let aside = try XCTUnwrap(LegacyIdentityMigration.adoptLegacyDirectory(
            from: legacy, to: current, now: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertEqual(aside.lastPathComponent, "SwiftOpenWork.before-migration-1000")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("sessions.json"), encoding: .utf8), "real")
        XCTAssertEqual(try String(contentsOf: aside.appendingPathComponent("sessions.json"), encoding: .utf8), "seed")
    }

    func testNothingHappensWithoutALegacyFolder() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let current = base.appendingPathComponent("SwiftOpenWork")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        XCTAssertNil(LegacyIdentityMigration.adoptLegacyDirectory(from: base.appendingPathComponent("OpenWorkSwift"), to: current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testRulesFilesFromBeforeTheRenameAreStillReadAndEditedInPlace() {
        XCTAssertEqual(ProjectInstructions.candidateNames.first, "SWIFTOPENWORK.md")
        XCTAssertTrue(ProjectInstructions.candidateNames.contains("OPENWORK.md"))
        XCTAssertTrue(ProjectInstructions.candidateNames.contains(".openwork.md"))

        // A 1.1 file is written back to, not shadowed by a new copy that would win next time.
        XCTAssertEqual(ProjectInstructions.saveTarget(loadedName: "OPENWORK.md"), "OPENWORK.md")
        XCTAssertEqual(ProjectInstructions.saveTarget(loadedName: nil), "SWIFTOPENWORK.md")
        // Another tool's file is never written.
        XCTAssertEqual(ProjectInstructions.saveTarget(loadedName: "AGENTS.md"), "SWIFTOPENWORK.md")
    }

    func testWorktreesFromBeforeTheRenameAreStillRecognised() {
        XCTAssertTrue(AgentWorktree.isAgentBranch("swiftopenwork/fix"))
        XCTAssertTrue(AgentWorktree.isAgentBranch("openwork/fix"))
        XCTAssertFalse(AgentWorktree.isAgentBranch("main"))
        XCTAssertTrue(AgentWorktree.container(for: URL(fileURLWithPath: "/tmp/repo")).path.contains(".swiftopenwork-worktrees"))
    }

    func testTheSeededLeadAgentIsRenamedOnceAndEditsAreLeftAlone() {
        let renamed = PersistenceManager.renamedSeedAgentText("You are OpenWork Lead Agent, a capable assistant.")
        XCTAssertEqual(renamed, "You are SwiftOpenWork Lead Agent, a capable assistant.")
        // The new name contains the old one; a naive replace would prepend "Swift" every launch.
        XCTAssertNil(PersistenceManager.renamedSeedAgentText(renamed!), "running twice must change nothing")
        XCTAssertNil(PersistenceManager.renamedSeedAgentText("My own lead agent"))
        // The short-lived intermediate name, already written to one machine by test runs.
        XCTAssertEqual(PersistenceManager.renamedSeedAgentText("OpenWork-Swift Lead Agent"), "SwiftOpenWork Lead Agent")
    }

    // MARK: - Sweep

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// The old name in a string literal is almost always something a user reads. The exemptions
    /// are the places that must name 1.1 to find its data.
    func testTheOldNameAppearsInNoStringOutsideTheMigration() throws {
        let exemptFiles: Set<String> = ["AppIdentity.swift", "LegacyIdentityMigration.swift"]
        let exemptLines = [
            "Lead Agent\"#",                 // the pattern that finds the seed's old wording
            "\"OPENWORK.md\"",              // legacy rules file, still read
            "\".openwork.md\"",
            "Also recognised at the workspace root", // lists the legacy file names on purpose
        ]
        // Any "OpenWork" not part of "SwiftOpenWork", in any case, inside a string literal.
        let literal = try NSRegularExpression(pattern: #""[^"\n]*((?<!Swift)OpenWork|(?<!swift)openwork|(?<!SWIFT)OPENWORK)[^"\n]*""#)

        var offenders: [String] = []
        let walker = FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", !exemptFiles.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if exemptLines.contains(where: { line.contains($0) }) { continue }
                let range = NSRange(line.startIndex..., in: line)
                if literal.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(url.lastPathComponent):\(number + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "The old name is still in these strings:\n" + offenders.joined(separator: "\n"))
    }
}
