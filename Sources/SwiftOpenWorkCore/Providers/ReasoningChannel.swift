import Foundation
import os

/// Whether a model's own chat template opens a reasoning block for it.
///
/// The handoff recorded this as unsolved and guessed at the wrong fix — "consume MLX's own
/// reasoning channel where the model exposes one". There is no such channel: `Generation` in
/// this `mlx-swift-lm` is `.chunk`, `.info`, `.toolCall` and nothing else.
///
/// The actual mechanism is in the template. Ornith's ends:
///
/// ```jinja
/// {%- if add_generation_prompt %}
///     {{- '<|im_start|>assistant\n' }}
///     {%- if enable_thinking is defined and enable_thinking is false %}
///         {{- '<think>\n\n</think>\n\n' }}
///     {%- else %}
///         {{- '<think>\n' }}
///     {%- endif %}
/// {%- endif %}
/// ```
///
/// So by default the prompt **already contains the opening `<think>`**. The model generates
/// reasoning with no opening tag — it was never supposed to emit one — and closes with
/// `</think>`. When it forgets to close, the text carries no tags at all, and
/// `AssistantContentSanitizer` correctly refuses to guess, so pure chain-of-thought is handed
/// to the user as the answer.
///
/// Knowing the template pre-opened the block turns that guess into a fact: generation *starts*
/// inside reasoning, and stays there until `</think>`.
public enum ReasoningChannel {

    private static let cache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Does the model at `directory` open a thinking block in its generation prompt?
    public static func templatePreOpensThinking(modelDirectory: URL) -> Bool {
        let key = modelDirectory.path
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let answer = detect(in: modelDirectory)
        cache.withLock { $0[key] = answer }
        return answer
    }

    private static func detect(in directory: URL) -> Bool {
        var template: String?
        let jinja = directory.appendingPathComponent("chat_template.jinja")
        if let text = try? String(contentsOf: jinja, encoding: .utf8) {
            template = text
        } else if let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["chat_template"] as? String {
            template = text
        }
        guard let template else { return false }

        // Only the generation-prompt branch matters: `<think>` appearing in the *history*
        // handling is the template parsing previous turns, not opening one for this turn.
        guard let marker = template.range(of: "add_generation_prompt") else { return false }
        let tail = String(template[marker.lowerBound...])

        // An opener with no closer after it in the same branch leaves generation inside a block.
        guard let opener = tail.range(of: "'<think>") else { return false }
        let afterOpener = String(tail[opener.upperBound...])
        // `'<think>\n\n</think>\n\n'` is the *disabled* form: opened and closed immediately.
        let closesImmediately = afterOpener.prefix(40).contains("</think>")
        return !closesImmediately || afterOpener.contains("'<think>\\n' }}")
    }

    /// Splits a stream that begins inside an unclosed reasoning block.
    ///
    /// Stateful because it runs per chunk: everything before `</think>` is reasoning, everything
    /// after is the answer, and the tag can arrive split across chunk boundaries.
    public final class StreamSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var insideReasoning: Bool
        private var pending = ""

        public init(startsInsideReasoning: Bool) {
            self.insideReasoning = startsInsideReasoning
        }

        public var isStillReasoning: Bool {
            lock.lock(); defer { lock.unlock() }
            return insideReasoning
        }

        /// Returns what to show and what to file as reasoning for this chunk.
        public func consume(_ piece: String) -> (visible: String, reasoning: String) {
            lock.lock(); defer { lock.unlock() }
            guard insideReasoning else { return (piece, "") }

            pending += piece
            guard let close = pending.range(of: "</think>") else {
                // Hold back a tail that could be a partial `</think>`, so the tag is never
                // emitted as visible text one character at a time.
                let keep = min(pending.count, 8)
                let emitEnd = pending.index(pending.endIndex, offsetBy: -keep)
                let reasoning = String(pending[..<emitEnd])
                pending = String(pending[emitEnd...])
                return ("", reasoning)
            }

            let reasoning = String(pending[..<close.lowerBound])
            let visible = String(pending[close.upperBound...])
            pending = ""
            insideReasoning = false
            return (visible, reasoning)
        }

        /// Anything still held back when the stream ends.
        ///
        /// If the model never closed the block, this is all reasoning — which is the whole point:
        /// it is filed as reasoning rather than shown as the answer.
        public func flush() -> (visible: String, reasoning: String) {
            lock.lock(); defer { lock.unlock() }
            let remainder = pending
            pending = ""
            return insideReasoning ? ("", remainder) : (remainder, "")
        }
    }
}
