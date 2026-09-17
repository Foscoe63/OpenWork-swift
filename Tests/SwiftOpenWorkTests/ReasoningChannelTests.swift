import XCTest
@testable import SwiftOpenWork

/// Reasoning reaching the user as the answer was recorded as unsolved, with the wrong fix
/// guessed at: "consume MLX's own reasoning channel where the model exposes one". There is no
/// such channel — `Generation` in this mlx-swift-lm is `.chunk`, `.info`, `.toolCall`.
///
/// The mechanism is in the chat template. Ornith's generation prompt ends with a bare
/// `{{- '<think>\n' }}`, so the model begins generating *inside* a reasoning block it never
/// opened and is meant to close with `</think>`. When it forgets, the text carries no tags at
/// all, `AssistantContentSanitizer` correctly refuses to guess, and chain-of-thought is shown as
/// the answer. Knowing the template opened the block makes it a fact rather than a guess.
final class ReasoningChannelTests: XCTestCase {

    private func templateDirectory(_ template: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try template.write(to: dir.appendingPathComponent("chat_template.jinja"), atomically: true, encoding: .utf8)
        return dir
    }

    func testATemplateThatOpensThinkingIsDetected() throws {
        let dir = try templateDirectory("""
        {%- if add_generation_prompt %}
            {{- '<|im_start|>assistant\\n' }}
            {%- if enable_thinking is defined and enable_thinking is false %}
                {{- '<think>\\n\\n</think>\\n\\n' }}
            {%- else %}
                {{- '<think>\\n' }}
            {%- endif %}
        {%- endif %}
        """)
        XCTAssertTrue(ReasoningChannel.templatePreOpensThinking(modelDirectory: dir))
    }

    func testATemplateWithNoThinkingIsNotMisdetected() throws {
        let dir = try templateDirectory("""
        {%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n' }}{%- endif %}
        """)
        XCTAssertFalse(ReasoningChannel.templatePreOpensThinking(modelDirectory: dir))
    }

    func testAModelDirectoryWithNoTemplateIsNotAssumedToThink() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertFalse(ReasoningChannel.templatePreOpensThinking(modelDirectory: missing))
    }

    func testTextBeforeTheCloseTagIsReasoningAndAfterItIsTheAnswer() {
        let splitter = ReasoningChannel.StreamSplitter(startsInsideReasoning: true)
        var visible = "", reasoning = ""
        for piece in ["Let me ", "work this out. ", "</think>", "The answer ", "is 4."] {
            let out = splitter.consume(piece)
            visible += out.visible; reasoning += out.reasoning
        }
        let tail = splitter.flush()
        visible += tail.visible; reasoning += tail.reasoning

        XCTAssertEqual(visible, "The answer is 4.")
        XCTAssertTrue(reasoning.contains("work this out"))
        XCTAssertFalse(visible.contains("</think>"), "the tag itself must never be shown")
    }

    /// The whole point: a block the model never closes is reasoning, not an answer.
    func testAnUnclosedBlockIsFiledAsReasoningRatherThanShown() {
        let splitter = ReasoningChannel.StreamSplitter(startsInsideReasoning: true)
        var visible = "", reasoning = ""
        for piece in ["Hmm, the user wants ", "me to consider the options ", "and I think"] {
            let out = splitter.consume(piece)
            visible += out.visible; reasoning += out.reasoning
        }
        let tail = splitter.flush()
        visible += tail.visible; reasoning += tail.reasoning

        XCTAssertEqual(visible, "", "unclosed chain-of-thought must not reach the user as the answer")
        XCTAssertTrue(reasoning.contains("Hmm, the user wants"))
        XCTAssertTrue(reasoning.contains("and I think"), "the held-back tail must be flushed")
    }

    /// The close tag can arrive split across chunks, one character at a time.
    func testACloseTagSplitAcrossChunksIsStillRecognised() {
        let splitter = ReasoningChannel.StreamSplitter(startsInsideReasoning: true)
        var visible = "", reasoning = ""
        for piece in ["thinking", "</", "thi", "nk", ">", "done"] {
            let out = splitter.consume(piece)
            visible += out.visible; reasoning += out.reasoning
        }
        visible += splitter.flush().visible
        XCTAssertEqual(visible, "done")
        XCTAssertFalse(visible.contains("<"), "no fragment of the tag may leak")
        XCTAssertEqual(reasoning, "thinking")
    }

    /// A model whose template does not pre-open must stream through untouched.
    func testAModelThatDoesNotPreOpenIsPassedThrough() {
        let splitter = ReasoningChannel.StreamSplitter(startsInsideReasoning: false)
        let out = splitter.consume("plain answer")
        XCTAssertEqual(out.visible, "plain answer")
        XCTAssertEqual(out.reasoning, "")
    }
}
