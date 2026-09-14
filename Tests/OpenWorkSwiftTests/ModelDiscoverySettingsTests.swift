import XCTest
@testable import OpenWorkSwift

/// Two settings that were stored but never read. The LM Studio one had a switch that did nothing;
/// the preload one had no switch at all.
final class ModelDiscoverySettingsTests: XCTestCase {

    private var home = ""

    /// `knownMLXSearchRoots` only returns directories that exist, so the LM Studio paths have to be
    /// real for the guard to be observable at all.
    private func settings(scanLMStudio: Bool) -> AppSettings {
        var s = AppSettings()
        s.scanLMStudioModels = scanLMStudio
        s.scanHuggingFaceCache = false
        s.customMLXModelsDirectory = ""
        return s
    }

    private func lmStudioRoots(_ roots: [URL]) -> [URL] {
        roots.filter {
            let p = $0.path.lowercased()
            return p.contains("lmstudio") || p.contains("lm-studio") || p.contains("lm studio")
        }
    }

    /// The guard is only observable on a machine that actually has an LM Studio library, because
    /// `knownMLXSearchRoots` returns directories that exist. Skip explicitly elsewhere rather than
    /// passing quietly — a test that cannot fail is not evidence.
    func testDisablingLMStudioRemovesItsPaths() throws {
        let enabled = lmStudioRoots(LocalMLXEngine.knownMLXSearchRoots(settings: settings(scanLMStudio: true)))
        try XCTSkipIf(enabled.isEmpty, "no LM Studio library on this machine, so there is nothing to exclude")

        let disabled = lmStudioRoots(LocalMLXEngine.knownMLXSearchRoots(settings: settings(scanLMStudio: false)))
        XCTAssertTrue(disabled.isEmpty, "turning the switch off must actually stop the scan")
    }

    /// Holds on every machine: disabling can only ever remove paths, never add them.
    func testDisablingNeverAddsPaths() {
        let enabled = Set(LocalMLXEngine.knownMLXSearchRoots(settings: settings(scanLMStudio: true)).map(\.path))
        let disabled = Set(LocalMLXEngine.knownMLXSearchRoots(settings: settings(scanLMStudio: false)).map(\.path))
        XCTAssertTrue(disabled.isSubset(of: enabled))
        XCTAssertTrue(lmStudioRoots(disabled.map { URL(fileURLWithPath: $0) }).isEmpty)
    }

    /// Absent settings means no preference was expressed, which scans — same as the Hugging Face
    /// guard beside it.
    func testNoSettingsStillScans() {
        let roots = LocalMLXEngine.knownMLXSearchRoots(settings: nil)
        let withSettings = LocalMLXEngine.knownMLXSearchRoots(settings: settings(scanLMStudio: true))
        XCTAssertEqual(lmStudioRoots(roots).count, lmStudioRoots(withSettings).count)
    }

    func testPreloadIsOffByDefault() {
        XCTAssertFalse(AppSettings().autoLoadTopMLXModelOnLaunch,
                       "loading tens of gigabytes at launch must be opt-in")
    }

    func testPreloadSurvivesASaveAndReload() throws {
        var settings = AppSettings()
        settings.autoLoadTopMLXModelOnLaunch = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.autoLoadTopMLXModelOnLaunch)
    }
}
