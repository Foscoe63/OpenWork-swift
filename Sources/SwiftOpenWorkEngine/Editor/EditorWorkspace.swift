import Foundation
import AppKit
import Combine
import SwiftOpenWorkCore

/// What to do when a file open in the editor changes underneath it.
///
/// The agent writes files while you are looking at them — that is the point of the app — so this
/// is the common case, not an edge. Pure, for tests.
public enum EditorDiskSync {

    public enum Action: Equatable, Sendable {
        /// Nothing on disk changed that matters.
        case none
        /// Disk moved on and the editor had nothing unsaved: take the new text quietly.
        case reload
        /// Both sides changed. Neither may be thrown away without asking.
        case conflict
        /// The file is gone. Unsaved or not, the editor keeps the text so it can be saved again.
        case deleted
    }

    public static func decide(
        exists: Bool,
        diskTextMatchesLastSeen: Bool,
        hasUnsavedEdits: Bool
    ) -> Action {
        guard exists else { return .deleted }
        if diskTextMatchesLastSeen { return .none }
        return hasUnsavedEdits ? .conflict : .reload
    }
}

/// A file open in the editor.
@MainActor
public final class EditorDocument: ObservableObject, Identifiable {

    public enum DiskState: Equatable {
        case inSync
        /// Changed on disk while there were unsaved edits.
        case conflict
        /// Removed from disk.
        case deleted
    }

    public let id = UUID()
    /// Absolute and standardised, so two routes to the same file open one tab.
    public let path: String
    public let language: SyntaxLanguage

    /// The live text. Owned here rather than by a view so undo history, colours and unsaved edits
    /// survive switching tabs.
    public let storage = NSTextStorage()
    public let undoManager = UndoManager()

    @Published public private(set) var isDirty = false
    @Published public private(set) var diskState: DiskState = .inSync
    /// Set when the file was reloaded because something else changed it, for a brief notice.
    @Published public private(set) var lastExternalReload: Date?
    /// Bumped whenever the text is replaced from outside the text view (a reload).
    @Published public private(set) var externalRevision = 0

    public private(set) var lineEnding: EditorText.LineEnding
    public private(set) var indentation: EditorText.Indentation

    /// What was last read from or written to disk, newlines normalised.
    private var lastSeenDiskText: String
    private var lastSeenStamp: DiskStamp?

    /// Where the view was, restored when the tab comes back.
    public var selectedRange = NSRange(location: 0, length: 0)
    public var scrollOrigin: CGPoint = .zero
    /// A line the view should scroll to and select on its next update.
    @Published public var pendingReveal: Int?
    /// A range within the revealed line to select: UTF-16 column and length, for search results.
    public var pendingRevealSelection: (column: Int, length: Int)?

    /// Colour ranges for the current text, cached so switching tabs does not re-lex.
    public var tokens: [SyntaxToken] = []
    public var tokensRevision = -1
    /// Incremented on every edit.
    public private(set) var textRevision = 0

    public struct DiskStamp: Equatable {
        public var modified: Date
        public var size: Int
    }

    public init(path: String, text: String) {
        self.path = path
        self.language = SyntaxLanguage.detect(path: path)
        self.lineEnding = EditorText.detectLineEnding(text)
        let normalized = EditorText.normalizeNewlines(text)
        self.indentation = EditorText.detectIndentation(normalized)
        self.lastSeenDiskText = normalized
        self.lastSeenStamp = Self.stamp(path)
        storage.setAttributedString(NSAttributedString(string: normalized))
    }

    public var text: String { storage.string }

    public var fileName: String { (path as NSString).lastPathComponent }

    /// Called by the text view after every edit.
    public func textDidChange() {
        textRevision += 1
        let dirty = storage.string != lastSeenDiskText
        if dirty != isDirty { isDirty = dirty }
    }

    // MARK: Saving

    public enum SaveError: LocalizedError {
        case conflict
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .conflict:
                return "The file changed on disk since you opened it. Reload it, or choose Keep My Version to overwrite."
            case .writeFailed(let reason):
                return reason
            }
        }
    }

    /// Write the editor's text to disk, with the file's own line endings.
    ///
    /// Refuses while a conflict is unresolved: saving then would overwrite whatever the agent just
    /// wrote without anyone having looked at it.
    public func save() throws {
        guard diskState != .conflict else { throw SaveError.conflict }
        let body = EditorText.restoreLineEndings(storage.string, to: lineEnding)
        do {
            let parent = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }
        lastSeenDiskText = storage.string
        lastSeenStamp = Self.stamp(path)
        diskState = .inSync
        isDirty = false
    }

    // MARK: Disk sync

    /// Compare against disk and act. Cheap when nothing changed: one `stat`.
    public func checkDisk() {
        let stamp = Self.stamp(path)
        if stamp != nil, stamp == lastSeenStamp, diskState != .deleted { return }

        guard stamp != nil else {
            if diskState != .deleted { diskState = .deleted }
            lastSeenStamp = nil
            return
        }
        guard case .text(let raw) = WorkspaceFileScanner.read(path: path) else { return }
        let diskText = EditorText.normalizeNewlines(raw)
        let action = EditorDiskSync.decide(
            exists: true,
            diskTextMatchesLastSeen: diskText == lastSeenDiskText,
            hasUnsavedEdits: isDirty
        )
        lastSeenStamp = stamp
        switch action {
        case .none:
            // Also ends a conflict whose other side went back to what the editor last saw.
            pendingDiskText = nil
            if diskState != .inSync { diskState = .inSync }
        case .reload:
            replaceText(with: diskText, lineEnding: EditorText.detectLineEnding(raw))
            lastExternalReload = Date()
        case .conflict:
            // Remember what disk holds now, so a later identical write is not a second conflict.
            pendingDiskText = (diskText, EditorText.detectLineEnding(raw))
            diskState = .conflict
        case .deleted:
            diskState = .deleted
        }
    }

    private var pendingDiskText: (text: String, lineEnding: EditorText.LineEnding)?

    /// The version on disk during a conflict, for Compare.
    public var conflictingDiskText: String? { pendingDiskText?.text }

    /// Resolve a conflict by taking the disk version and discarding unsaved edits.
    public func resolveByReloading() {
        if let pending = pendingDiskText {
            replaceText(with: pending.text, lineEnding: pending.lineEnding)
        } else if case .text(let raw) = WorkspaceFileScanner.read(path: path) {
            replaceText(with: EditorText.normalizeNewlines(raw), lineEnding: EditorText.detectLineEnding(raw))
        }
        pendingDiskText = nil
        lastSeenStamp = Self.stamp(path)
        diskState = .inSync
    }

    /// Resolve a conflict by keeping the editor's text. The next save overwrites disk.
    public func resolveByKeepingMine() {
        if let pending = pendingDiskText {
            lastSeenDiskText = pending.text
        }
        pendingDiskText = nil
        diskState = .inSync
        isDirty = storage.string != lastSeenDiskText
    }

    /// Replace the whole text as one undoable edit that leaves the file unsaved — for Replace All,
    /// which must be reviewable before anything reaches disk.
    public func applyEdit(_ newText: String, actionName: String) {
        let previous = storage.string
        guard newText != previous else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        undoManager.registerUndo(withTarget: self) { document in
            document.applyEdit(previous, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        externalRevision += 1
        textDidChange()
    }

    private func replaceText(with newText: String, lineEnding: EditorText.LineEnding) {
        let keepSelection = selectedRange
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        // An external rewrite makes the old undo steps describe text that is gone.
        undoManager.removeAllActions()
        self.lineEnding = lineEnding
        lastSeenDiskText = newText
        isDirty = false
        textRevision += 1
        let length = (newText as NSString).length
        selectedRange = NSRange(location: min(keepSelection.location, length), length: 0)
        externalRevision += 1
    }

    private static func stamp(_ path: String) -> DiskStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return DiskStamp(
            modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
            size: (attributes[.size] as? Int) ?? 0
        )
    }
}

/// The editor's open files, shared by every place that shows the editor.
@MainActor
public final class EditorWorkspace: ObservableObject {

    public static let shared = EditorWorkspace()

    @Published public private(set) var documents: [EditorDocument] = []
    @Published public var activeDocumentId: UUID?
    /// Whether the editor shows its Find in Project panel.
    @Published public var isSearchVisible = false
    /// Incremented to move keyboard focus into the search field.
    @Published public var searchFocusRequest = 0

    /// Show the project search, optionally searching for `text`.
    public func showProjectSearch(prefill text: String? = nil) {
        if let text, !text.isEmpty, !text.contains("\n") {
            ProjectSearchModel.shared.options.query = text
        }
        isSearchVisible = true
        searchFocusRequest += 1
    }

    /// The selected text in the active document, when it is a short single line — what ⌘⇧F
    /// should search for.
    public var selectionForSearch: String? {
        guard let document = activeDocument else { return nil }
        let range = document.selectedRange
        guard range.length > 0, range.length <= 200, NSMaxRange(range) <= document.storage.length else { return nil }
        let text = (document.text as NSString).substring(with: range)
        return text.contains("\n") ? nil : text
    }

    /// Declared names in the current workspace, for completion and go-to-definition.
    @Published public private(set) var workspaceSymbols: [String] = []

    private var pollTask: Task<Void, Never>?
    private var symbolsRoot: String?
    private var dirtyObservers: [UUID: AnyCancellable] = [:]

    public init() {}

    public var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentId }
    }

    public var unsavedDocuments: [EditorDocument] {
        documents.filter(\.isDirty)
    }

    public enum OpenError: LocalizedError {
        case notFound(String)
        case notEditable(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path): return "No file at \(path)"
            case .notEditable(let reason): return reason
            }
        }
    }

    /// Open `path` (absolute, or relative to `workspaceRoot`) and make it active, optionally
    /// revealing a 1-based line. Opening a file that is already open switches to its tab.
    @discardableResult
    public func open(path: String, line: Int? = nil, selecting selection: (column: Int, length: Int)? = nil, workspaceRoot: String? = nil) throws -> EditorDocument {
        let absolute = Self.resolve(path, root: workspaceRoot)
        if let existing = documents.first(where: { $0.path == absolute }) {
            activeDocumentId = existing.id
            if let line {
                existing.pendingRevealSelection = selection
                existing.pendingReveal = line
            }
            existing.checkDisk()
            return existing
        }
        guard FileManager.default.fileExists(atPath: absolute) else { throw OpenError.notFound(absolute) }
        switch WorkspaceFileScanner.read(path: absolute) {
        case .text(let text):
            let document = EditorDocument(path: absolute, text: text)
            if let line {
                document.pendingRevealSelection = selection
                document.pendingReveal = line
            }
            documents.append(document)
            // Forward each document's dirty flag, so views watching the workspace (the tab strip,
            // the composer's unsaved-files chip) redraw when a file becomes unsaved.
            dirtyObservers[document.id] = document.$isDirty
                .removeDuplicates()
                .sink { [weak self] _ in self?.objectWillChange.send() }
            activeDocumentId = document.id
            startPollingIfNeeded()
            if let workspaceRoot { refreshSymbols(root: workspaceRoot) }
            return document
        case .binary(let bytes):
            throw OpenError.notEditable("\((absolute as NSString).lastPathComponent) is a binary file (\(WorkspaceFileScanner.humanReadableSize(bytes))) and cannot be edited as text.")
        case .tooLarge(let bytes):
            throw OpenError.notEditable("\((absolute as NSString).lastPathComponent) is \(WorkspaceFileScanner.humanReadableSize(bytes)), over the editor's \(WorkspaceFileScanner.humanReadableSize(WorkspaceFileScanner.maxEditableBytes)) limit.")
        case .unreadable(let reason):
            throw OpenError.notEditable(reason)
        }
    }

    /// Close a tab. Unsaved edits are the caller's to confirm first.
    public func close(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: index)
        dirtyObservers[id] = nil
        if activeDocumentId == id {
            activeDocumentId = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
        if documents.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    public func closeOthers(keeping id: UUID) {
        for document in documents where document.id != id && !document.isDirty {
            close(document.id)
        }
    }

    /// Save every unsaved file. Returns the ones that could not be saved, with why.
    @discardableResult
    public func saveAll() -> [(fileName: String, reason: String)] {
        var failures: [(String, String)] = []
        for document in unsavedDocuments {
            do {
                try document.save()
            } catch {
                failures.append((document.fileName, error.localizedDescription))
            }
        }
        return failures
    }

    /// Check every open file against disk now — after an agent turn, rather than waiting for the
    /// next poll.
    public func checkAllAgainstDisk() {
        for document in documents { document.checkDisk() }
    }

    public func refreshSymbols(root: String) {
        symbolsRoot = root
        Task.detached(priority: .utility) {
            let names = await SymbolIndex.shared.declaredNames(root: root)
            await MainActor.run {
                guard self.symbolsRoot == root else { return }
                self.workspaceSymbols = names
            }
        }
    }

    /// Where `name` is declared in the workspace, for Cmd-click.
    public func definition(of name: String, workspaceRoot: String) async -> (path: String, line: Int)? {
        let found = await SymbolIndex.shared.lookup(name: name, root: workspaceRoot, limit: 5)
        guard let first = found.first(where: { $0.name == name }) else { return nil }
        let root = workspaceRoot.hasSuffix("/") ? workspaceRoot : workspaceRoot + "/"
        return (first.path.hasPrefix("/") ? first.path : root + first.path, first.line)
    }

    /// The path relative to `root` when it is inside it, for display and for chat mentions.
    public static func relativePath(_ path: String, root: String) -> String {
        for candidate in [root, resolve(root, root: nil)] {
            let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }

    public static func resolve(_ path: String, root: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else if let root {
            absolute = (root as NSString).appendingPathComponent(expanded)
        } else {
            absolute = expanded
        }
        return URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Polling rather than file-system events: agents and formatters write through atomic
    /// renames, which replace the inode a vnode watcher is attached to, and the watcher then goes
    /// silent. A `stat` per open file every second and a half costs nothing and cannot miss that.
    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                for document in self.documents { document.checkDisk() }
            }
        }
    }
}
