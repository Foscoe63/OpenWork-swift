import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// From a real exported session: a user said "Good Day" to Llama-3.3-70B and the entire reply was
/// `<|python_tag|>`. The sanitizer knew about `<think>` and tool-call syntax but nothing about
/// chat-template control tokens, so Llama's tool-call marker landed in the answer verbatim.
final class ControlTokenLeakTests: XCTestCase {

    func testLlamaToolMarkerIsStripped() {
        XCTAssertEqual(AssistantContentSanitizer.sanitizeVisible("<|python_tag|>"), "")
    }

    func testTheWholeFamilyOfControlTokensIsStripped() {
        let raw = "<|begin_of_text|><|start_header_id|>assistant<|end_header_id|>Hello<|eot_id|>"
        XCTAssertEqual(AssistantContentSanitizer.sanitizeVisible(raw), "assistantHello")
    }

    func testQwenTokensAreStrippedToo() {
        XCTAssertEqual(
            AssistantContentSanitizer.sanitizeVisible("<|im_start|>Good day to you<|im_end|>"),
            "Good day to you"
        )
    }

    /// The pattern is `<|` identifier `|>` on purpose. Ordinary prose and code must survive —
    /// a greedy `<.*>` would eat generics, comparisons and HTML.
    func testOrdinaryTextIsUntouched() {
        let cases = [
            "if a < b || c > d { return }",
            "Array<String> and Dictionary<String, Int>",
            "The pipe | character and <angle> brackets",
            "a <| b",
        ]
        for text in cases {
            XCTAssertEqual(AssistantContentSanitizer.stripControlTokens(text), text, text)
        }
    }

    func testAnAnswerWrappedInMarkersKeepsItsContent() {
        let raw = "<|python_tag|>Good day! How can I help?<|eot_id|>"
        XCTAssertEqual(AssistantContentSanitizer.sanitizeVisible(raw), "Good day! How can I help?")
    }

    /// The export showed the token in the reasoning block as well as the answer.
    @MainActor
    func testControlTokensDoNotLeakIntoReasoning() {
        var final: ChatMessage?
        let acc = AgentStreamAccumulator(
            initialMessage: ChatMessage(sessionId: "s", role: .assistant, content: ""),
            onUpdate: { final = $0 }
        )
        acc.applyChunk(LLMStreamChunk(deltaText: "<think>weighing it up<|python_tag|></think>Done."))
        acc.finalize()

        XCTAssertEqual(final?.content, "Done.")
        XCTAssertEqual(final?.reasoning, "weighing it up")
    }
}

/// Model-load progress was filed as the model's *reasoning*. It is the app's status: it polluted
/// that transcript, and once a blank answer falls back to showing reasoning, "Loading local MLX
/// weights from /Volumes/…" would be presented to the user as the model's closing thoughts.
@MainActor
final class ProviderStatusIsNotReasoningTests: XCTestCase {

    private func accumulator(_ onUpdate: @escaping (ChatMessage) -> Void) -> AgentStreamAccumulator {
        AgentStreamAccumulator(
            initialMessage: ChatMessage(sessionId: "s", role: .assistant, content: ""),
            onUpdate: onUpdate
        )
    }

    func testStatusBecomesANoticeNotReasoning() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.applyChunk(LLMStreamChunk(deltaNotice: "Loading local MLX weights from /Volumes/Models"))
        acc.applyChunk(LLMStreamChunk(deltaText: "Good day!"))

        XCTAssertTrue(final?.notices.contains("Loading local MLX weights from /Volumes/Models") == true)
        XCTAssertNil(final?.reasoning)
    }

    func testTheLoadChipIsDroppedOnceTheAnswerLands() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.applyChunk(LLMStreamChunk(deltaNotice: "Loading local MLX weights from /Volumes/Models"))
        acc.applyChunk(LLMStreamChunk(deltaText: "Good day!"))
        acc.finalize()

        XCTAssertEqual(final?.content, "Good day!")
        XCTAssertTrue(final?.notices.isEmpty == true, "a finished answer should not still say it is loading")
    }

    /// The bad interaction this prevents: a turn with no answer must not offer infrastructure
    /// status as the model's closing thoughts.
    func testABlankAnswerDoesNotFallBackToLoadStatus() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.applyChunk(LLMStreamChunk(deltaNotice: "Loading local MLX weights from /Volumes/Models"))
        acc.applyChunk(LLMStreamChunk(deltaText: "<|python_tag|>"))
        acc.finalize()

        let content = final?.content ?? ""
        XCTAssertFalse(content.contains("Loading local MLX weights"))
        XCTAssertFalse(content.contains("python_tag"))
    }
}
