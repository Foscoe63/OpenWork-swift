import XCTest
@testable import OpenWorkSwift

#if canImport(MLXLMCommon) && canImport(MLXLLM) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
final class NativeMLXServiceTests: XCTestCase {

    private func makeTempModelDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ string: String, to url: URL) throws {
        try string.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ count: Int, to url: URL) throws {
        try Data(repeating: 0, count: count).write(to: url)
    }

    func testMissingConfigJsonIsIncomplete() throws {
        let dir = try makeTempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(NativeMLXService.isModelDirectoryComplete(dir))
    }

    func testShardedModelMissingWeightFilesIsIncomplete() throws {
        // Mirrors a download interrupted after config.json + the index but before most shards —
        // exactly what a killed/timed-out download leaves behind.
        let dir = try makeTempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{}", to: dir.appendingPathComponent("config.json"))
        try write(#"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#, to: dir.appendingPathComponent("model.safetensors.index.json"))
        try writeBytes(1024, to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
        // model-00002-of-00002.safetensors intentionally missing

        XCTAssertFalse(NativeMLXService.isModelDirectoryComplete(dir))
    }

    func testShardedModelWithAllShardsPresentIsComplete() throws {
        let dir = try makeTempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{}", to: dir.appendingPathComponent("config.json"))
        try write(#"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#, to: dir.appendingPathComponent("model.safetensors.index.json"))
        try writeBytes(1024, to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
        try writeBytes(1024, to: dir.appendingPathComponent("model-00002-of-00002.safetensors"))

        XCTAssertTrue(NativeMLXService.isModelDirectoryComplete(dir))
    }

    func testShardedModelWithZeroByteShardIsIncomplete() throws {
        let dir = try makeTempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{}", to: dir.appendingPathComponent("config.json"))
        try write(#"{"weight_map": {"a": "model-00001-of-00001.safetensors"}}"#, to: dir.appendingPathComponent("model.safetensors.index.json"))
        try writeBytes(0, to: dir.appendingPathComponent("model-00001-of-00001.safetensors"))

        XCTAssertFalse(NativeMLXService.isModelDirectoryComplete(dir))
    }

    func testSingleFileCheckpointWithWeightsIsComplete() throws {
        let dir = try makeTempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{}", to: dir.appendingPathComponent("config.json"))
        try writeBytes(2048, to: dir.appendingPathComponent("model.safetensors"))

        XCTAssertTrue(NativeMLXService.isModelDirectoryComplete(dir))
    }

    func testConfigOnlyWithNoWeightsAtAllIsIncomplete() throws {
        let dir = try makeTempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{}", to: dir.appendingPathComponent("config.json"))

        XCTAssertFalse(NativeMLXService.isModelDirectoryComplete(dir))
    }
}
#endif
