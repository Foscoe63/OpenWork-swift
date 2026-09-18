import Foundation
import Combine
import SwiftOpenWorkCore

/// Ghost-text suggestions in the editor: what to ask, when to ask, which model answers, and how
/// to turn a chat model's reply into text that can be inserted at the cursor.
///
/// Nothing here runs per keystroke. A suggestion is requested after typing pauses, the request is
/// cancelled the moment typing resumes, and the local engine is only used when it is idle — so a
/// 35B model that needs a second or two per suggestion never slows typing or an agent turn. It
/// feels like a collaborator who speaks when you stop, not autocomplete that races your fingers.
public enum InlineSuggestionPolicy {

    /// How long typing must pause before a suggestion is requested.
    public static let pauseBeforeRequest: TimeInterval = 0.5

    /// Tokens a suggestion may use. Enough to restate the line and finish a short block; the
    /// stopper usually ends generation well before this.
    public static let maxTokens = 80

    /// Whether the cursor is somewhere a suggestion makes sense.
    ///
    /// Only with nothing selected, and only where inserting cannot split a word: at the end of a
    /// line, or before closing brackets, quotes and whitespace. In the middle of an identifier a
    /// suggestion would have to guess what the rest of the word already says.
    public static func shouldRequest(text: NSString, caret: Int, selectionLength: Int, language: SyntaxLanguage) -> Bool {
        guard selectionLength == 0, caret >= 0, caret <= text.length, text.length > 0 else { return false }
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        var end = NSMaxRange(lineRange)
        if end > lineRange.location, end <= text.length, text.character(at: end - 1) == 10 { end -= 1 }
        let afterCaret = text.substring(with: NSRange(location: caret, length: max(0, end - caret)))
        let allowedAfter = CharacterSet(charactersIn: ")]}>\"'`;,. \t")
        guard afterCaret.unicodeScalars.allSatisfy({ allowedAfter.contains($0) }) else { return false }

        let beforeCaret = text.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        if beforeCaret.trimmingCharacters(in: .whitespaces).isEmpty {
            // A blank line is worth a suggestion only inside something already begun.
            return caret > 0 && text.substring(to: caret).trimmingCharacters(in: .whitespacesAndNewlines).count > 20
        }
        return true
    }
}

/// The prompt: the file around the cursor, with the cursor marked.
public struct InlineSuggestionRequest: Equatable, Sendable {
    public var path: String
    public var language: SyntaxLanguage
    public var prefix: String
    public var suffix: String

    public static let cursorMarker = "<CURSOR>"
    static let prefixLimit = 3_000
    static let suffixLimit = 1_000

    public init(path: String, language: SyntaxLanguage, text: NSString, caret: Int) {
        self.path = path
        self.language = language
        let clamped = max(0, min(caret, text.length))
        // Cut on line boundaries so the model never sees half a line at either edge.
        var prefixStart = max(0, clamped - Self.prefixLimit)
        if prefixStart > 0 {
            let lineStart = text.lineRange(for: NSRange(location: prefixStart, length: 0))
            prefixStart = min(clamped, NSMaxRange(lineStart))
        }
        prefix = text.substring(with: NSRange(location: prefixStart, length: clamped - prefixStart))
        var suffixEnd = min(text.length, clamped + Self.suffixLimit)
        if suffixEnd < text.length {
            suffixEnd = text.lineRange(for: NSRange(location: suffixEnd, length: 0)).location
            suffixEnd = max(suffixEnd, clamped)
        }
        suffix = text.substring(with: NSRange(location: clamped, length: suffixEnd - clamped))
    }

    /// Asks for the current line *restated*, then the rest.
    ///
    /// Measured on Ornith-1.5-35B: asked for "only the text at the cursor", a chat model continued
    /// `sum +` with ` .amount` — it loses its place at a marker in the middle of a line. Asked to
    /// write the line out in full, it wrote `sum + item.amount, 0);`, and the known part is cut off
    /// again by `InlineSuggestionCleaner`.
    public static let systemPrompt = """
    You are a code completion engine inside an editor. You are shown a file with the cursor marked \
    <CURSOR>. Write out the cursor's whole line exactly as it is up to the cursor, then continue it \
    with the code that belongs there. Finish that line; if it opens a block, finish the block. At \
    most 8 lines, in the file's indentation and style. No explanation, no markdown, no code fences, \
    and nothing that already comes after the cursor. If nothing obviously belongs there, reply with \
    nothing at all.
    """

    public var userPrompt: String {
        "File: \((path as NSString).lastPathComponent) (\(language.displayName))\n\n\(prefix)\(Self.cursorMarker)\(suffix)"
    }

    /// The part of the current line before the cursor.
    public var linePrefix: String {
        prefix.components(separatedBy: "\n").last ?? ""
    }
}

/// Decides when a streaming suggestion is complete, so generation stops instead of running on to
/// write the rest of the file. Pure, for tests.
public enum InlineSuggestionStopper {

    /// Whether `raw` (the reply so far, which restates the cursor's line first) is a complete
    /// suggestion.
    ///
    /// A line that is being finished stops at its end, unless it opens a block — then it stops when
    /// the block closes back to the line's indentation. A suggestion begun on a blank line stops at
    /// the next blank line or when it dedents out of the block it started in. Always by 8 lines.
    public static func isComplete(_ raw: String, request: InlineSuggestionRequest) -> Bool {
        let text = raw.hasPrefix("```") ? String(raw.drop { $0 != "\n" }.dropFirst()) : raw
        let lines = text.components(separatedBy: "\n")
        // The last element is still being written.
        let finished = Array(lines.dropLast())
        guard let firstLine = finished.first else { return false }
        if finished.count >= 9 { return true }

        let baseIndent = request.linePrefix.prefix { $0 == " " || $0 == "\t" }.count
        func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        func opensBlock(_ line: String) -> Bool {
            guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
            return "{([:".contains(last)
        }

        if !request.linePrefix.trimmingCharacters(in: .whitespaces).isEmpty {
            // Finishing a line.
            guard opensBlock(firstLine) else { return true }
            for line in finished.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if indent(line) <= baseIndent { return true }
            }
            return false
        }
        // Started on a blank line.
        for (index, line) in finished.enumerated() {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && index > 0 { return true }
            if !blank && index > 0 && indent(line) < baseIndent { return true }
        }
        return false
    }
}

/// Turn a chat model's reply into insertable text. Pure, for tests.
public enum InlineSuggestionCleaner {

    public static func clean(_ raw: String, request: InlineSuggestionRequest) -> String? {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")

        // Stray reasoning and fences — models add them however clearly they are told not to.
        if let thinkEnd = text.range(of: "</think>") {
            text = String(text[thinkEnd.upperBound...])
        }
        text = text.replacingOccurrences(of: InlineSuggestionRequest.cursorMarker, with: "")
        let trimmedStart = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedStart.hasPrefix("```") {
            var lines = trimmedStart.components(separatedBy: "\n")
            lines.removeFirst()
            if let closing = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                lines.removeSubrange(closing...)
            }
            text = lines.joined(separator: "\n")
        }

        // A model that restates the line it was asked to continue: keep only what is new.
        let linePrefix = request.linePrefix
        let trimmedLinePrefix = linePrefix.trimmingCharacters(in: .whitespaces)
        if !trimmedLinePrefix.isEmpty {
            let leading = text.drop { $0 == " " || $0 == "\t" }
            if leading.hasPrefix(trimmedLinePrefix) {
                text = String(leading.dropFirst(trimmedLinePrefix.count))
            } else {
                text = dropOverlap(of: linePrefix, from: text)
            }
        }

        // Do not re-insert what already follows the cursor.
        let suffixStart = request.suffix.drop { $0 == " " || $0 == "\t" }
        if !suffixStart.isEmpty {
            for length in stride(from: min(text.count, suffixStart.count), through: 1, by: -1) {
                let tail = String(text.suffix(length))
                if suffixStart.hasPrefix(tail), tail.trimmingCharacters(in: .whitespacesAndNewlines).count >= 1 {
                    text = String(text.dropLast(length))
                    break
                }
            }
        }

        // Keep it small, and drop trailing blank lines.
        var lines = text.components(separatedBy: "\n")
        let blankLineStart = request.linePrefix.trimmingCharacters(in: .whitespaces).isEmpty
        if !blankLineStart, lines.count > 1,
           let first = lines.first?.trimmingCharacters(in: .whitespaces).last, !"{([:".contains(first) {
            // Finishing a line that opens nothing: the line is the suggestion.
            lines = [lines[0]]
        }
        if lines.count > 8 { lines = Array(lines.prefix(8)) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n")
        // A suggestion that starts a new line keeps its newline; trailing spaces never help.
        while text.hasSuffix(" ") || text.hasSuffix("\t") { text.removeLast() }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Remove the longest end of `linePrefix` that the text starts with, when it is a
    /// restatement rather than a coincidence: four or more characters, or punctuation of any
    /// length. Measured on Ornith: continuing `sum +`, it replied `+ item.amount, 0);` — inserted
    /// as given that is `sum ++ item.amount`.
    static func dropOverlap(of linePrefix: String, from text: String) -> String {
        let prefixEnd = Array(linePrefix.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let leadingSpace = text.prefix { $0 == " " || $0 == "\t" }
        let body = Array(text.dropFirst(leadingSpace.count))
        let maxLength = min(prefixEnd.count, body.count)
        guard maxLength >= 1 else { return text }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let tail = Array(prefixEnd.suffix(length))
            guard tail == Array(body.prefix(length)) else { continue }
            let isPunctuation = !tail.contains { $0.isLetter || $0.isNumber || $0 == "_" }
            guard length >= 4 || isPunctuation else { continue }
            var rest = String(body.dropFirst(length))
            // Keep the spacing the line already has: `sum +` continues with ` item`, not `item`.
            if let last = linePrefix.last, last != " ", last != "\t", let first = rest.first, first != " " {
                if isPunctuation, !"([.".contains(tail.last!) { rest = " " + rest }
            }
            return rest
        }
        return text
    }
}

/// Which model writes suggestions. Pure, for tests.
public enum InlineSuggestionModelChoice: Equatable {
    case disabled
    case use(provider: ModelProvider, model: ModelInfo, isLocal: Bool)
    /// Nothing is chosen, and the automatic choice would send code to the cloud.
    case needsChoice(String)

    public static func resolve(
        settings: AppSettings,
        providers: [ModelProvider],
        currentProvider: ModelProvider,
        currentModel: ModelInfo
    ) -> InlineSuggestionModelChoice {
        guard settings.inlineSuggestionsEnabled else { return .disabled }
        if !settings.inlineSuggestionProviderId.isEmpty {
            guard let provider = providers.first(where: { $0.id == settings.inlineSuggestionProviderId }), provider.isEnabled else {
                return .needsChoice("The model chosen for suggestions is no longer available. Choose another.")
            }
            let model = provider.models.first { $0.id == settings.inlineSuggestionModelId }
                ?? ModelInfo(id: settings.inlineSuggestionModelId, name: settings.inlineSuggestionModelId, providerId: provider.id)
            guard !model.id.isEmpty else { return .needsChoice("Choose a model for suggestions.") }
            return .use(provider: provider, model: model, isLocal: provider.type == .local)
        }
        guard currentProvider.type == .local, currentProvider.isEnabled, !currentModel.id.isEmpty else {
            return .needsChoice("Your chat model runs in the cloud. Choose a model for suggestions — code is only sent to the cloud if you pick a cloud model.")
        }
        return .use(provider: currentProvider, model: currentModel, isLocal: true)
    }
}

/// Requests suggestions, one at a time, newest wins.
@MainActor
public final class InlineSuggestionEngine: ObservableObject {

    public static let shared = InlineSuggestionEngine()

    public enum Status: Equatable {
        case off
        case ready(String)
        case thinking
        case unavailable(String)
    }

    @Published public private(set) var status: Status = .off
    /// How long the last suggestion took, for the status bar.
    @Published public private(set) var lastLatencyMs: Int?

    private var current: Task<String?, Never>?

    public init() {}

    public func cancel() {
        current?.cancel()
        current = nil
        if status == .thinking { refreshStatus() }
    }

    public func refreshStatus() {
        switch Self.choice() {
        case .disabled: status = .off
        case .needsChoice(let why): status = .unavailable(why)
        case .use(_, let model, let isLocal): status = .ready("\(model.name)\(isLocal ? "" : " (cloud)")")
        }
    }

    static func choice() -> InlineSuggestionModelChoice {
        let app = AppState.shared
        return InlineSuggestionModelChoice.resolve(
            settings: app.settings,
            providers: app.providers,
            currentProvider: app.currentProvider,
            currentModel: app.currentModel
        )
    }

    /// Ask for a suggestion. Returns nil when there is none, when the engine is busy, or when a
    /// newer request replaced this one.
    public func suggest(_ request: InlineSuggestionRequest) async -> String? {
        current?.cancel()
        guard case .use(let provider, let model, _) = Self.choice() else {
            refreshStatus()
            return nil
        }
        status = .thinking
        let started = Date()
        let task = Task<String?, Never> {
            final class Buffer: @unchecked Sendable {
                private let lock = NSLock()
                private var text = ""
                func append(_ piece: String) { lock.lock(); text += piece; lock.unlock() }
                var value: String { lock.lock(); defer { lock.unlock() }; return text }
            }
            let buffer = Buffer()
            do {
                if provider.kind == .omlx || provider.kind == .vmlx {
                    try await NativeMLXService.shared.oneShot(
                        modelId: model.id,
                        system: InlineSuggestionRequest.systemPrompt,
                        user: request.userPrompt,
                        maxTokens: InlineSuggestionPolicy.maxTokens,
                        temperature: 0.2,
                        onVisibleText: { buffer.append($0) },
                        shouldStop: { InlineSuggestionStopper.isComplete(buffer.value, request: request) }
                    )
                } else {
                    try await ProviderRouter.shared.client(for: provider).streamChat(
                        provider: provider,
                        model: model,
                        systemPrompt: InlineSuggestionRequest.systemPrompt,
                        messages: [ChatMessage(role: .user, content: request.userPrompt)],
                        temperature: 0.2,
                        maxTokens: InlineSuggestionPolicy.maxTokens,
                        reasoningEffort: .off,
                        tools: []
                    ) { chunk in
                        if !chunk.deltaText.isEmpty { buffer.append(chunk.deltaText) }
                    }
                    // Remote providers stream the whole budget; the completeness rule is applied
                    // afterwards by trimming to it.
                    let full = buffer.value
                    let lines = full.components(separatedBy: "\n")
                    for count in 1...max(1, lines.count) {
                        let partial = lines.prefix(count).joined(separator: "\n") + "\n"
                        if InlineSuggestionStopper.isComplete(partial, request: request) {
                            return InlineSuggestionCleaner.clean(lines.prefix(count).joined(separator: "\n"), request: request)
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return nil }
                await MainActor.run {
                    if let oneShot = error as? NativeMLXService.OneShotError {
                        self.status = .unavailable(oneShot.localizedDescription)
                    } else {
                        self.status = .unavailable(error.localizedDescription)
                    }
                }
                return nil
            }
            guard !Task.isCancelled else { return nil }
            return InlineSuggestionCleaner.clean(buffer.value, request: request)
        }
        current = task
        let result = await task.value
        if !task.isCancelled {
            lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
            if status == .thinking { refreshStatus() }
        }
        return task.isCancelled ? nil : result
    }
}
