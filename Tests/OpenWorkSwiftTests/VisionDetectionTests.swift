import XCTest
@testable import OpenWorkSwift

/// Whether a model can see was decided by matching `model_type` against a list of names — "vl",
/// "vision", "pixtral", "mllama", "gemma4". Ornith reports `qwen3_5_moe` and carries a
/// `vision_config`, an `image_token_id` and a `text_config`. It is a vision model that this check
/// called blind, so every screenshot sent to it would have been refused as unviewable by the one
/// model on this machine that could actually have read it.
final class VisionDetectionTests: XCTestCase {

    func testAVisionTowerIsEnoughWhateverTheModelTypeIsCalled() {
        XCTAssertTrue(LocalMLXEngine.declaresVisionSupport(config: [
            "model_type": "qwen3_5_moe",
            "vision_config": ["depth": 24],
            "image_token_id": 151655,
            "text_config": ["hidden_size": 4096]
        ]), "this is Ornith, and it was being treated as text-only")
    }

    func testAnImageTokenAloneIsEnough() {
        XCTAssertTrue(LocalMLXEngine.declaresVisionSupport(config: [
            "model_type": "some_new_arch", "image_token_index": 32000
        ]))
    }

    func testAVisionArchitectureNameIsEnough() {
        XCTAssertTrue(LocalMLXEngine.declaresVisionSupport(config: [
            "model_type": "whatever", "architectures": ["LlavaForConditionalGeneration"]
        ]))
    }

    /// The old name list still works for checkpoints that declare nothing structural.
    func testTheNameFallbackStillCatchesTheObviousOnes() {
        XCTAssertTrue(LocalMLXEngine.declaresVisionSupport(config: ["model_type": "qwen2_vl"]))
        XCTAssertTrue(LocalMLXEngine.declaresVisionSupport(config: ["model_type": "pixtral"]))
        XCTAssertTrue(LocalMLXEngine.declaresVisionSupport(config: ["model_type": "mllama"]))
    }

    /// A text-only model must not be told it can see — it would fail inside the chat template
    /// rather than politely ignore the image.
    func testATextOnlyModelIsNotMisdetected() {
        XCTAssertFalse(LocalMLXEngine.declaresVisionSupport(config: [
            "model_type": "llama", "hidden_size": 4096
        ]))
        XCTAssertFalse(LocalMLXEngine.declaresVisionSupport(config: ["model_type": "qwen2"]))
        XCTAssertFalse(LocalMLXEngine.declaresVisionSupport(config: [:]))
    }

    /// The real config on this machine, if it is here.
    func testTheInstalledDefaultModelIsDetectedCorrectly() throws {
        let settings = PersistenceManager.shared.loadSettings()
        guard let dir = LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: settings.defaultModelId, settings: settings
        ) else { throw XCTSkip("default model not on this machine") }

        let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let declared = LocalMLXEngine.declaresVisionSupport(config: config)
        let structural = config["vision_config"] != nil || config["image_token_id"] != nil
        XCTAssertEqual(declared, structural || declared,
                       "detection must agree with what the checkpoint actually carries")
    }
}
