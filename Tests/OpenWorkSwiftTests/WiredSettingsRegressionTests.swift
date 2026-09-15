import XCTest
import AVFoundation
@testable import OpenWorkSwift

/// The GPU memory budget slider used to move a number nothing read.
///
/// `mlxGpuMemoryBudgetRatio` was rendered in green on the MLX settings page as "Safe GPU Memory
/// Budget: N GB" and repeated in ProvidersView, while the runtime capped MLX's buffer cache at a
/// hardcoded 0.5 and judged model compatibility against a *different* hardcoded 0.75. The
/// setting's default is 0.75, so the compatibility verdict agreed with the readout exactly until
/// someone moved the slider — which is why this went unnoticed.
final class GPUMemoryBudgetRatioTests: XCTestCase {

    private var ram: Double { LocalMLXEngine.physicalRAMGB }

    /// A model just inside the budget at a generous ratio must fall outside a stingy one.
    func testTheRatioDecidesWhatFits() {
        let generous = LocalMLXEngine.assessCompatibility(requiredRAMGB: ram * 0.7, budgetRatio: 0.9)
        let stingy = LocalMLXEngine.assessCompatibility(requiredRAMGB: ram * 0.7, budgetRatio: 0.5)
        XCTAssertEqual(generous, .runsWell)
        XCTAssertNotEqual(stingy, .runsWell, "halving the budget must change the verdict")
    }

    /// Nothing larger than the machine can ever be recommended, at any ratio.
    func testAModelBiggerThanTheMachineIsNeverRecommended() {
        for ratio in [0.5, 0.75, 0.9] {
            XCTAssertEqual(
                LocalMLXEngine.assessCompatibility(requiredRAMGB: ram * 2, budgetRatio: ratio),
                .notRecommended
            )
        }
    }

    /// settings.json is hand-editable; a stored 0 or 50 is a wedged machine, not a preference.
    func testAnOutOfRangeRatioIsClamped() {
        XCTAssertEqual(LocalMLXEngine.clampedBudgetRatio(0), 0.1)
        XCTAssertEqual(LocalMLXEngine.clampedBudgetRatio(50), 0.95)
        XCTAssertEqual(LocalMLXEngine.clampedBudgetRatio(0.75), 0.75)
        XCTAssertEqual(
            LocalMLXEngine.clampedBudgetRatio(.nan),
            AppSettings.default.mlxGpuMemoryBudgetRatio,
            "a non-finite stored value must not become the cache limit"
        )
    }

    /// The verdicts shown to the user come from `judged(atBudgetRatio:)`, not from the verdict the
    /// static curated catalog baked in at the shipped default.
    func testACatalogEntryIsRejudgedAgainstTheStoredRatio() {
        let model = LocalMLXModel(
            id: "test/model",
            name: "Test",
            description: "",
            compatibility: .runsWell,
            estimatedRAMGB: ram * 0.8
        )
        XCTAssertEqual(model.compatibility, .runsWell, "baked in at construction")
        XCTAssertNotEqual(
            model.judged(atBudgetRatio: 0.5).compatibility, .runsWell,
            "a stale badge must not survive a ratio the user lowered"
        )
        XCTAssertEqual(model.judged(atBudgetRatio: 0.9).compatibility, .runsWell)
    }

    /// Every field except the verdict survives a re-judge.
    func testRejudgingChangesNothingElse() {
        let model = LocalMLXModel(
            id: "test/model", name: "Test", description: "d",
            sizeBytes: 123, parameterCount: "7B", quantization: "4-bit",
            modelType: "llama", contextWindow: 4096, isDownloaded: true,
            localDirectory: "/tmp/x", isVLM: true, useCase: .coding,
            compatibility: .runsWell, estimatedRAMGB: 4.0,
            tags: ["a"], isTopPick: true, downloadCount: 9
        )
        let rejudged = model.judged(atBudgetRatio: 0.75)
        XCTAssertEqual(rejudged.id, model.id)
        XCTAssertEqual(rejudged.localDirectory, model.localDirectory)
        XCTAssertEqual(rejudged.isDownloaded, model.isDownloaded)
        XCTAssertEqual(rejudged.tags, model.tags)
        XCTAssertEqual(rejudged.isTopPick, model.isTopPick)
        XCTAssertEqual(rejudged.downloadCount, model.downloadCount)
        XCTAssertEqual(rejudged.estimatedRAMGB, model.estimatedRAMGB)
    }
}

/// The voice toggles gated nothing: the mic button in the composer and the speak button on every
/// assistant message were drawn whatever they said, and `speechVoiceIdentifier` was never read.
final class VoiceSettingsTests: XCTestCase {

    /// Both features ship on, because both buttons have always been drawn. Defaulting them off
    /// now that they are honoured would amount to removing a working feature.
    func testVoiceDefaultsMatchTheBehaviourTheAppAlwaysHad() {
        XCTAssertTrue(AppSettings.default.voiceInputEnabled)
        XCTAssertTrue(AppSettings.default.voiceSynthesisEnabled)
    }

    /// A file written before the toggles were wired carries `false` from a switch that did
    /// nothing. That is not a preference, and the migration must not honour it as one.
    func testAPreMigrationFileHasItsVoiceTogglesTurnedOn() throws {
        let json = """
        {"theme":"dark","voiceInputEnabled":false,"voiceSynthesisEnabled":false}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.settingsSchemaVersion, 1, "an absent version means pre-migration")

        var migrated = decoded
        XCTAssertTrue(PersistenceManager.applyMigrations(to: &migrated))
        XCTAssertTrue(migrated.voiceInputEnabled)
        XCTAssertTrue(migrated.voiceSynthesisEnabled)
        XCTAssertEqual(migrated.settingsSchemaVersion, AppSettings.currentSchemaVersion)
    }

    /// Once migrated, turning voice off has to stick — otherwise the switch is unusable in the
    /// other direction, which is the same defect wearing a different hat.
    func testAMigratedFileKeepsTheUsersChoiceToTurnVoiceOff() throws {
        var settings = AppSettings.default
        settings.voiceInputEnabled = false
        settings.voiceSynthesisEnabled = false

        let round = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(round.settingsSchemaVersion, AppSettings.currentSchemaVersion)

        var again = round
        XCTAssertFalse(PersistenceManager.applyMigrations(to: &again), "nothing left to migrate")
        XCTAssertFalse(again.voiceInputEnabled, "the migration must not re-enable a deliberate off")
        XCTAssertFalse(again.voiceSynthesisEnabled)
    }

    /// A stored identifier naming a voice this Mac does not have must fall back, not go silent.
    @MainActor
    func testAnUnknownVoiceIdentifierFallsBack() {
        XCTAssertNotNil(
            VoiceSpeechEngine.preferredVoice(),
            "speech must still have a voice when the stored identifier resolves to nothing"
        )
    }

    /// The shipped default was `com.apple.speech.synthesis.voice.Alex` — an *NSSpeechSynthesizer*
    /// identifier. Speech goes through AVSpeechSynthesizer, whose identifiers look nothing like
    /// it, so it matched none of the installed voices. A SwiftUI Picker whose selection matches
    /// no tag renders completely blank, which is what the new control did until this was found by
    /// looking at it.
    @MainActor
    func testTheLegacyVoiceIdentifierNormalisesToTheSystemDefault() {
        XCTAssertNil(
            AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.Alex"),
            "if this ever resolves, the normalisation below is no longer needed"
        )
        XCTAssertEqual(
            VoiceSpeechEngine.resolvedVoiceIdentifier("com.apple.speech.synthesis.voice.Alex"), "",
            "an unresolvable identifier must show as System Default, not as an empty picker"
        )
        XCTAssertEqual(VoiceSpeechEngine.resolvedVoiceIdentifier(""), "")
    }

    /// A real installed voice must survive the round trip, or the picker could never hold one.
    @MainActor
    func testAnInstalledVoiceIdentifierIsKept() throws {
        let voices = VoiceSpeechEngine.installedVoices()
        try XCTSkipIf(voices.isEmpty, "no speech voices installed on this machine")
        let identifier = try XCTUnwrap(voices.first).identifier
        XCTAssertEqual(VoiceSpeechEngine.resolvedVoiceIdentifier(identifier), identifier)
    }

    /// The default must be reachable from the picker. The old one was not in the list at all.
    func testTheDefaultVoiceIdentifierIsTheSystemDefault() {
        XCTAssertEqual(AppSettings.default.speechVoiceIdentifier, "")
    }
}

/// `loadSettings()` is a read. It used to rewrite `mcp_servers.json` on every call, from 26 sites
/// including per-turn and per-tool-call paths.
final class LoadSettingsDoesNotWriteTests: XCTestCase {

    func testASecondLoadTouchesNoFiles() throws {
        let store = PersistenceManager.shared
        let original = store.loadSettings()
        defer { store.saveSettings(original) }

        // First load converges anything stale (schema migration, MCP repair, backup drift).
        _ = store.loadSettings()

        let dir = StorageService.shared.baseDirectory
        let watched = ["settings.json", "mcp_servers.json"]
        let before = try watched.map { name -> Date in
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return attrs[.modificationDate] as? Date ?? .distantPast
        }

        for _ in 0..<5 { _ = store.loadSettings() }

        let after = try watched.map { name -> Date in
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return attrs[.modificationDate] as? Date ?? .distantPast
        }

        for (index, name) in watched.enumerated() {
            XCTAssertEqual(before[index], after[index], "loadSettings() rewrote \(name)")
        }
    }
}
