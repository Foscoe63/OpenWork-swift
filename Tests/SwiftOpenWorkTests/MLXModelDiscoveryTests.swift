import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

/// Finding the weights that are already on this Mac, and failing usefully when they are not.
///
/// The bug these pin: the search roots named `/Volumes/Storage/Models` literally, which exists on
/// no machine. A complete 35GB checkpoint on an attached volume was therefore invisible, and the
/// chat turn quietly fell through to re-downloading it from Hugging Face — 37GB behind a status
/// chip reading "Loading MLX weights: 20%", indistinguishable from a hang.
final class MLXModelDiscoveryTests: XCTestCase {

    /// Every model library on an attached volume is searched.
    func testModelLibrariesOnAttachedVolumesAreSearched() {
        let roots = Set(
            LocalMLXEngine.knownMLXSearchRoots(settings: .default)
                .map(\.standardizedFileURL.path)
        )
        let fm = FileManager.default

        for volume in LocalMLXEngine.mountedVolumes() {
            for name in ["Models", "models"] {
                let library = volume.appendingPathComponent(name, isDirectory: true)
                for candidate in [library, library.appendingPathComponent(name, isDirectory: true)] {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else { continue }
                    XCTAssertTrue(
                        roots.contains(candidate.standardizedFileURL.path),
                        "\(candidate.path) exists but is never searched, so models in it are invisible"
                    )
                }
            }
        }
    }

    /// A root that does not exist is not offered as a place that was searched.
    func testNonExistentRootsAreNotListed() {
        for root in LocalMLXEngine.knownMLXSearchRoots(settings: .default) {
            var isDir: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue,
                "\(root.path) is listed as a search root but is not a directory"
            )
        }
    }

    /// The "not downloaded" message names every place that was searched.
    ///
    /// Without this the user sees only that a model did not work, with no way to discover that
    /// the folder holding it was never on the list.
    func testMissingModelErrorNamesTheRootsItSearched() {
        let settings = AppSettings.default
        let message = (NativeMLXService.modelNotDownloadedError(
            modelId: "nobody/Definitely-Not-Present",
            settings: settings
        ) as NSError).localizedDescription

        XCTAssertTrue(message.contains("nobody/Definitely-Not-Present"))
        XCTAssertTrue(message.contains("Searched:"))
        for root in LocalMLXEngine.knownMLXSearchRoots(settings: settings) {
            XCTAssertTrue(message.contains(root.path), "the message should name \(root.path)")
        }
    }

    /// The wait a turn allows for a load scales with the weights it has to read.
    ///
    /// `loadContainer(from:)` reports no progress, so a silence-based watchdog had nothing to
    /// measure and called every load longer than 180s wedged — including a 46GB bundle that
    /// loads in ~220s and works.
    func testLoadBudgetScalesWithBundleSize() throws {
        let root = NSTemporaryDirectory() + "budget-\(UUID().uuidString)"
        let dir = root + "/org/Big-Model"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"model_type":"qwen3"}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // A 20GB shard (sparse — no bytes are written). At the assumed read rate that is well
        // past the floor, which 2GB would not be: the floor alone covers 4.5GB.
        let shard = URL(fileURLWithPath: dir + "/model.safetensors")
        FileManager.default.createFile(atPath: shard.path, contents: nil)
        let handle = try FileHandle(forWritingTo: shard)
        try handle.truncate(atOffset: 20_000_000_000)
        try handle.close()

        var settings = AppSettings.default
        settings.customMLXModelsDirectory = root

        XCTAssertEqual(NativeMLXService.weightBytes(in: URL(fileURLWithPath: dir)), 20_000_000_000)

        let big = NativeMLXService.loadBudgetSeconds(modelId: "org/Big-Model", settings: settings)
        XCTAssertEqual(big, 800, accuracy: 1, "20GB at the assumed read rate is 800s")

        let missing = NativeMLXService.loadBudgetSeconds(modelId: "org/Not-Here", settings: settings)
        XCTAssertEqual(missing, 180, "an unresolvable model falls back to the floor")
    }

    /// A chat turn against a model that is not on disk fails promptly and says so — it does not
    /// start a multi-gigabyte download while the user waits for an answer.
    func testUnresolvableModelFailsFastInsteadOfDownloading() async {
        let provider = ModelProvider(
            id: "omlx-local", name: "Local MLX", type: .local, kind: .omlx,
            baseUrl: "", apiKey: "", isEnabled: true, models: []
        )
        let model = ModelInfo(id: "nobody/Definitely-Not-Present", name: "missing", providerId: "omlx-local")

        let started = Date()
        do {
            try await NativeMLXService.shared.streamChat(
                provider: provider, model: model,
                systemPrompt: "", messages: [ChatMessage(role: .user, content: "hi")],
                temperature: 0.2, maxTokens: 8, reasoningEffort: .medium, tools: []
            ) { _ in }
            XCTFail("a model that is not on disk must not appear to run")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("is not downloaded on this Mac"),
                "expected the not-downloaded explanation, got: \(error.localizedDescription)"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 30,
            "the turn should fail immediately rather than begin downloading weights"
        )
    }
}
