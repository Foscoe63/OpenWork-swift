import XCTest
import AppKit
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkLocalInference
@testable import SwiftOpenWorkEngine

final class InlineSuggestionLogicTests: XCTestCase {

    private func request(_ text: String, caretMarker: String = "|") -> InlineSuggestionRequest {
        let caret = (text as NSString).range(of: caretMarker).location
        let clean = text.replacingOccurrences(of: caretMarker, with: "") as NSString
        return InlineSuggestionRequest(path: "/w/App.swift", language: .swift, text: clean, caret: caret)
    }

    func testWhenToAsk() {
        func ask(_ text: String, selection: Int = 0) -> Bool {
            let caret = (text as NSString).range(of: "|").location
            let clean = text.replacingOccurrences(of: "|", with: "") as NSString
            return InlineSuggestionPolicy.shouldRequest(text: clean, caret: caret, selectionLength: selection, language: .swift)
        }
        XCTAssertTrue(ask("let total = items.|"))
        XCTAssertTrue(ask("print(|)"), "before closing brackets is fine")
        XCTAssertFalse(ask("let va|lue = 1"), "never inside a word")
        XCTAssertFalse(ask("let total = items.|", selection: 3), "never over a selection")
        XCTAssertTrue(ask("func render() {\n    let list = document.body\n    |"), "a blank line inside something begun")
        XCTAssertFalse(ask("\n|"), "not in an empty file")
    }

    func testPromptMarksTheCursorAndCutsOnLines() {
        let long = (0..<400).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let text = (long + "\nlet next = ") as NSString
        let built = InlineSuggestionRequest(path: "/w/a.swift", language: .swift, text: text, caret: text.length)
        XCTAssertTrue(built.userPrompt.hasSuffix("let next = <CURSOR>"))
        XCTAssertLessThanOrEqual(built.prefix.utf16.count, InlineSuggestionRequest.prefixLimit)
        XCTAssertTrue(built.prefix.hasPrefix("let line"), "the window starts at a whole line")
        XCTAssertEqual(built.linePrefix, "let next = ")
    }

    func testCleanerStripsFencesThinkingAndRepeats() {
        let r = request("let total = items.|\n}")
        XCTAssertEqual(InlineSuggestionCleaner.clean("```swift\nreduce(0, +)\n```", request: r), "reduce(0, +)")
        XCTAssertEqual(InlineSuggestionCleaner.clean("<think>hmm</think>reduce(0, +)", request: r), "reduce(0, +)")
        XCTAssertEqual(InlineSuggestionCleaner.clean("let total = items.reduce(0, +)", request: r), "reduce(0, +)",
                       "a model restating the line keeps only what is new")
        XCTAssertEqual(InlineSuggestionCleaner.clean("items.reduce(0, +)", request: r), "reduce(0, +)",
                       "overlap with the end of the line is dropped")
        XCTAssertNil(InlineSuggestionCleaner.clean("   \n\n", request: r))
    }

    /// The real reply from Ornith-1.5-35B, continuing `sum +`.
    func testRepeatedOperatorIsNotDoubled() {
        let r = request("  return list.reduce((sum, item) => sum +|\n}")
        XCTAssertEqual(InlineSuggestionCleaner.clean("+ item.amount, 0);\n", request: r), " item.amount, 0);")
        let dot = request("items.|")
        XCTAssertEqual(InlineSuggestionCleaner.clean(".count", request: dot), "count")
        let word = request("let name = user|")
        XCTAssertEqual(InlineSuggestionCleaner.clean("r.name", request: word), "r.name", "a one-letter coincidence is not an overlap")
    }

    func testCleanerDoesNotDuplicateWhatFollows() {
        let r = request("print(|)")
        XCTAssertEqual(InlineSuggestionCleaner.clean("\"hello\")", request: r), "\"hello\"")
    }

    func testStopperFinishesALineOrItsBlock() {
        let midLine = request("  return list.reduce((sum, item) => sum +|\n}")
        XCTAssertFalse(InlineSuggestionStopper.isComplete("  return list.reduce((sum, item) => sum + item.am", request: midLine))
        XCTAssertTrue(InlineSuggestionStopper.isComplete("  return list.reduce((sum, item) => sum + item.amount, 0);\n", request: midLine))

        let opener = request("function add(a, b)|")
        XCTAssertFalse(InlineSuggestionStopper.isComplete("function add(a, b) {\n  return a + b;\n", request: opener), "the block is still open")
        XCTAssertTrue(InlineSuggestionStopper.isComplete("function add(a, b) {\n  return a + b;\n}\n", request: opener))

        let blank = request("function a() {\n  const x = 1;\n  |")
        XCTAssertFalse(InlineSuggestionStopper.isComplete("return x;\n", request: blank))
        XCTAssertTrue(InlineSuggestionStopper.isComplete("return x;\n}\n", request: blank), "dedenting out of the block ends it")
    }

    func testRestatedLineIsCutToTheNewPart() {
        let r = request("  return list.reduce((sum, item) => sum +|\n}")
        XCTAssertEqual(
            InlineSuggestionCleaner.clean("  return list.reduce((sum, item) => sum + item.amount, 0);\n}\n\nfunction more() {}", request: r),
            " item.amount, 0);",
            "finishing a line that opens nothing keeps only that line"
        )
    }

    func testCleanerCapsLength() {
        let r = request("func a() {\n|")
        let raw = (0..<20).map { "    step\($0)()" }.joined(separator: "\n")
        XCTAssertEqual(InlineSuggestionCleaner.clean(raw, request: r)?.components(separatedBy: "\n").count, 8)
    }

    func testModelChoiceNeverSendsCodeToTheCloudUnasked() {
        let local = ModelProvider(id: "omlx-local", name: "Local", type: .local, kind: .omlx, baseUrl: "", apiKey: "", isEnabled: true,
                                  models: [ModelInfo(id: "m-local", name: "Local Model", providerId: "omlx-local")])
        let cloud = ModelProvider(id: "openai", name: "OpenAI", type: .cloud, kind: .openai, baseUrl: "", apiKey: "k", isEnabled: true,
                                  models: [ModelInfo(id: "gpt", name: "GPT", providerId: "openai")])
        var settings = AppSettings()

        if case .use(_, let model, let isLocal) = InlineSuggestionModelChoice.resolve(settings: settings, providers: [local, cloud], currentProvider: local, currentModel: local.models[0]) {
            XCTAssertEqual(model.id, "m-local")
            XCTAssertTrue(isLocal)
        } else { XCTFail("a local chat model is used automatically") }

        guard case .needsChoice = InlineSuggestionModelChoice.resolve(settings: settings, providers: [local, cloud], currentProvider: cloud, currentModel: cloud.models[0]) else {
            return XCTFail("a cloud chat model must not be used automatically")
        }

        settings.inlineSuggestionProviderId = "openai"
        settings.inlineSuggestionModelId = "gpt"
        if case .use(_, let model, let isLocal) = InlineSuggestionModelChoice.resolve(settings: settings, providers: [local, cloud], currentProvider: local, currentModel: local.models[0]) {
            XCTAssertEqual(model.id, "gpt")
            XCTAssertFalse(isLocal)
        } else { XCTFail("an explicit cloud choice is honoured") }

        settings.inlineSuggestionsEnabled = false
        XCTAssertEqual(InlineSuggestionModelChoice.resolve(settings: settings, providers: [local], currentProvider: local, currentModel: local.models[0]), .disabled)
    }

    func testTryAcquireNeverWaits() async throws {
        let gate = LocalGenerationGate()
        let held = try await gate.acquire(label: "agent turn")
        let attempt = await gate.tryAcquire(label: "suggestions")
        XCTAssertNil(attempt, "suggestions must not queue behind an agent")
        await gate.release(held)
        let free = await gate.tryAcquire(label: "suggestions")
        XCTAssertNotNil(free)
        if let free { await gate.release(free) }
    }
}

/// Ghost text in the real text view.
@MainActor
final class GhostTextBehaviourTests: XCTestCase {

    private func makeView(_ text: String) -> (CodeTextView, NSWindow) {
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 1_000_000))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, window)
    }

    func testTabAcceptsTheWholeSuggestionAsOneUndo() {
        let (view, window) = makeView("let total = items.")
        _ = window
        view.setSelectedRange(NSRange(location: 18, length: 0))
        view.ghost = .init(location: 18, text: "reduce(0, +)")
        view.insertTab(nil)
        XCTAssertEqual(view.string, "let total = items.reduce(0, +)")
        XCTAssertNil(view.ghost)
        XCTAssertEqual(view.selectedRange().location, 30)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "let total = items.", "one undo removes the whole suggestion")
    }

    func testTypingThroughKeepsTheRest() {
        let (view, window) = makeView("let total = items.")
        _ = window
        view.setSelectedRange(NSRange(location: 18, length: 0))
        view.ghost = .init(location: 18, text: "reduce(0, +)")
        view.insertText("red", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.ghost, .init(location: 21, text: "uce(0, +)"))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(view.ghost, "typing something else withdraws it")
    }

    func testMovingTheCursorOrEscapeWithdrawsIt() {
        let (view, window) = makeView("let total = items.")
        _ = window
        view.setSelectedRange(NSRange(location: 18, length: 0))
        view.ghost = .init(location: 18, text: "count")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(view.ghost)
        view.setSelectedRange(NSRange(location: 18, length: 0))
        view.ghost = .init(location: 18, text: "count")
        view.cancelOperation(nil)
        XCTAssertNil(view.ghost)
    }

    func testTabWithoutASuggestionStillIndents() {
        let (view, window) = makeView("")
        _ = window
        view.insertTab(nil)
        XCTAssertEqual(view.string, "    ")
    }
}

/// A real suggestion from the local model, with its latency.
final class InlineSuggestionLiveTests: XCTestCase {

    func testOrnithSuggestsAReasonableCompletionQuickly() async throws {
        guard ProcessInfo.processInfo.environment["SOW_LIVE_MLX"] == "1" else { throw XCTSkip("live only: SOW_LIVE_MLX=1") }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOW_LIVE_OUT"] ?? "/tmp/sow-suggest.txt")
        let modelId = "mlx-community/Ornith-1.5-35B-A3B-8bit"
        let code = """
        // Pocket Budget
        const items = [];

        function totalSpent(list) {
          return list.reduce((sum, item) => sum +
        """ as NSString
        let request = InlineSuggestionRequest(path: "/w/app.js", language: .javascript, text: code, caret: code.length)
        var log = ""
        for attempt in 1...3 {
            final class Box: @unchecked Sendable { var text = "" }
            let box = Box()
            let started = Date()
            try await NativeMLXService.shared.oneShot(
                modelId: modelId, system: InlineSuggestionRequest.systemPrompt, user: request.userPrompt,
                maxTokens: InlineSuggestionPolicy.maxTokens, temperature: 0.2, onVisibleText: { box.text += $0 },
                shouldStop: { InlineSuggestionStopper.isComplete(box.text, request: request) }
            )
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let cleaned = InlineSuggestionCleaner.clean(box.text, request: request)
            log += "attempt \(attempt): \(ms)ms line=\((request.linePrefix + (cleaned ?? "")).debugDescription) raw=\(box.text.debugDescription) cleaned=\(cleaned.debugDescription)\n"
            try log.write(to: out, atomically: true, encoding: .utf8)
            if attempt > 1 {
                XCTAssertNotNil(cleaned)
                let line = request.linePrefix + (cleaned ?? "")
                XCTAssertFalse(line.contains("++"), log)
                XCTAssertTrue(line.contains("sum + item.") || line.contains("sum + (item."), "composed line: \(line)\n\(log)")
                XCTAssertLessThan(ms, 3_000, "a warm suggestion should take well under 3s: \(log)")
            }
        }
    }
}
