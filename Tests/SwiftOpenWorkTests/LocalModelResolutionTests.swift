import XCTest
@testable import SwiftOpenWork

/// Finding a downloaded MLX model on disk when the requested id does not match its folder path.
final class LocalModelResolutionTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "models-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Compare paths with symlinks resolved: NSTemporaryDirectory() reports /var/... while the
    /// enumerator returns /private/var/..., so a raw string comparison fails on a correct result.
    private func assertSamePath(_ a: URL?, _ b: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            a?.resolvingSymlinksInPath().path,
            URL(fileURLWithPath: b).resolvingSymlinksInPath().path,
            message, file: file, line: line
        )
    }

    /// A directory the completeness check accepts: config plus a non-empty shard.
    private func makeModel(org: String, name: String) throws -> String {
        let dir = "\(root)/\(org)/\(name)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"model_type":"qwen3"}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        try "weights".write(toFile: dir + "/model.safetensors", atomically: true, encoding: .utf8)
        return dir
    }

    private func settings() -> AppSettings {
        var s = AppSettings.default
        s.customMLXModelsDirectory = root
        return s
    }

    /// Look only at this test's fixture directory.
    ///
    /// Without this the engine also searches every real model library on the machine running the
    /// test — the Hugging Face cache, LM Studio, attached volumes. Name matching returns nil when
    /// two roots offer the same model, so a machine that actually has `Qwen3-Coder-Next-REAP-48B`
    /// on disk made these tests fail on a correct implementation.
    private func roots() -> [URL] { [URL(fileURLWithPath: root, isDirectory: true)] }

    // MARK: - Name normalisation

    func testNormalisationIgnoresOrgCaseAndSeparators() {
        let a = LocalMLXEngine.normalizedModelName("mlx-community/Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit")
        let b = LocalMLXEngine.normalizedModelName("andosen/qwen3_coder_next_reap_48b_a3b_mlx_8bit")
        XCTAssertEqual(a, b)
    }

    func testNormalisationDropsTheOrg() {
        XCTAssertEqual(
            LocalMLXEngine.normalizedModelName("org-one/Model-X"),
            LocalMLXEngine.normalizedModelName("org-two/Model-X")
        )
    }

    // MARK: - Resolution

    func testResolvesExactPath() throws {
        let dir = try makeModel(org: "mlx-community", name: "Ornith-1.5-35B-A3B-8bit")
        let found = LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: "mlx-community/Ornith-1.5-35B-A3B-8bit", settings: settings(), roots: roots()
        )
        assertSamePath(found, dir)
    }

    /// The case that blocked the configured default model: same weights, different publisher.
    func testResolvesAcrossADifferentOrg() throws {
        let dir = try makeModel(org: "andosen", name: "Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit")
        let found = LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: "mlx-community/Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit", settings: settings(), roots: roots()
        )
        assertSamePath(found, dir)
    }

    func testResolvesABareSlugWithNoOrg() throws {
        let dir = try makeModel(org: "andosen", name: "Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit")
        let found = LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: "qwen3-coder-next-reap-48b-a3b-mlx", settings: settings(), roots: roots()
        )
        assertSamePath(found, dir, "a settings slug without the -8Bit suffix should still match")
    }

    /// Never guess between quantisations — loading a 4-bit build for an 8-bit request is wrong
    /// in a way the user would not notice until quality dropped.
    func testAmbiguousNameMatchResolvesToNil() throws {
        _ = try makeModel(org: "orgA", name: "Shared-Model-Name")
        _ = try makeModel(org: "orgB", name: "Shared-Model-Name")
        let found = LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: "somewhere-else/Shared-Model-Name", settings: settings(), roots: roots()
        )
        XCTAssertNil(found)
    }

    func testUnknownModelResolvesToNil() throws {
        _ = try makeModel(org: "mlx-community", name: "Real-Model")
        XCTAssertNil(LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: "nobody/Not-Present-At-All", settings: settings(), roots: roots()
        ))
    }

    func testVeryShortIdIsNotFuzzyMatched() throws {
        _ = try makeModel(org: "mlx-community", name: "Real-Model")
        XCTAssertNil(LocalMLXEngine.shared.resolveLocalModelDirectory(modelId: "ab", settings: settings(), roots: roots()))
    }

    // MARK: - Catalog merge

    /// A curated entry and the same model installed under another org must be one row, marked
    /// downloaded — not two, one of which offers a redundant multi-GB download.
    func testCuratedEntryMergesWithADifferentlyPublishedCopy() throws {
        guard let curated = LocalMLXEngine.curatedModels.first else {
            throw XCTSkip("no curated models to test against")
        }
        let name = curated.id.split(separator: "/").last.map(String.init) ?? curated.id
        _ = try makeModel(org: "someone-else", name: name)

        let catalog = LocalMLXEngine.shared.scanInstalledModels(settings: settings(), roots: roots())
        let matches = catalog.filter {
            LocalMLXEngine.normalizedModelName($0.id) == LocalMLXEngine.normalizedModelName(curated.id)
        }
        XCTAssertEqual(matches.count, 1, "the model should appear once, not once per org")
        XCTAssertTrue(matches.first?.isDownloaded == true)
    }
}
