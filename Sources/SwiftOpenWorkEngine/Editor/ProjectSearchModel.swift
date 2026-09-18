import Foundation
import Combine
import SwiftOpenWorkCore

/// State for Find in Project, kept outside the view so a search survives switching inspector tabs.
@MainActor
public final class ProjectSearchModel: ObservableObject {

    public static let shared = ProjectSearchModel()

    @Published public var options = ProjectSearch.Options(query: "") {
        didSet { if options != oldValue { scheduleSearch() } }
    }
    @Published public var replacement = ""
    @Published public var showsReplace = false
    @Published public var showsFilters = false
    @Published public private(set) var result = ProjectSearch.Result.empty
    @Published public private(set) var isSearching = false
    @Published public private(set) var error: String?
    @Published public var collapsedFiles: Set<String> = []

    /// The folder searched; set by the panel from the current workspace.
    public var root = "" {
        didSet { if root != oldValue { scheduleSearch() } }
    }

    private var pending: Task<Void, Never>?

    public init() {}

    public func scheduleSearch(delay: UInt64 = 250_000_000) {
        pending?.cancel()
        let options = self.options
        let root = self.root
        guard !options.query.isEmpty, !root.isEmpty else {
            result = .empty
            error = nil
            isSearching = false
            return
        }
        // Unsaved editor text is what the person is looking at, so it is what gets searched.
        let open = Dictionary(EditorWorkspace.shared.documents.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
        isSearching = true
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let outcome: Swift.Result<ProjectSearch.Result, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try ProjectSearch.search(options, root: root, openDocuments: open)) }
                catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.isSearching = false
            switch outcome {
            case .success(let found):
                self.result = found
                self.error = nil
            case .failure(let failure):
                self.result = .empty
                self.error = failure.localizedDescription
            }
        }
    }

    public func setResultForTesting(_ result: ProjectSearch.Result) {
        pending?.cancel()
        self.result = result
        isSearching = false
    }

    /// Files Replace All would change, capped so one click cannot open hundreds of tabs.
    public static let replaceFileLimit = 40

    public enum ReplaceOutcome: Equatable {
        case replaced(matches: Int, files: Int, skipped: [String])
        case tooManyFiles(Int)
        case failed(String)
    }

    /// Replace every match by opening each file in the editor and editing it there, unsaved.
    ///
    /// Nothing is written to disk: each file becomes a dirty tab with one undo step, so the change
    /// can be reviewed, undone file by file, and saved with Save All. The agent may be editing the
    /// same files, and the editor's conflict handling covers exactly that.
    public func replaceAll(workspaceRoot: String) -> ReplaceOutcome {
        let files = result.files
        guard files.count <= Self.replaceFileLimit else { return .tooManyFiles(files.count) }
        var matches = 0
        var changed = 0
        var skipped: [String] = []
        let prefix = workspaceRoot.hasSuffix("/") ? workspaceRoot : workspaceRoot + "/"
        let editors = EditorWorkspace.shared
        let previouslyActive = editors.activeDocumentId
        for file in files {
            do {
                let document = try editors.open(path: prefix + file.path, workspaceRoot: workspaceRoot)
                let replaced = try ProjectSearch.replacing(in: document.text, options: options, with: replacement)
                guard replaced.count > 0 else { continue }
                document.applyEdit(replaced.text, actionName: "Replace All")
                matches += replaced.count
                changed += 1
            } catch let failure as ProjectSearch.SearchError {
                return .failed(failure.localizedDescription)
            } catch {
                skipped.append(file.path)
            }
        }
        if let previouslyActive { editors.activeDocumentId = previouslyActive }
        scheduleSearch(delay: 0)
        return .replaced(matches: matches, files: changed, skipped: skipped)
    }
}
