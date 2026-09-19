import SwiftUI
import SwiftOpenWorkEngine

/// Review everything this session changed on disk, across every turn.
///
/// The per-turn review reads the checkpoint store, which holds real before/after contents and can
/// therefore offer undo — but only for the current turn, by design. A session-wide view is built
/// from the transcript's tool calls instead, so it knows *what* was touched and *when* but holds no
/// prior contents. It shows git's diff and offers no revert, and says so plainly: a view that
/// looked like the turn review but silently could not restore anything would be worse than none.
///
/// It can commit, though: "Commit…" stages and commits the session's files when *you* press it.
/// The agent still cannot commit on your checkout.
public struct SessionChangeReviewView: View {
    @ObservedObject var appState: AppState
    let root: String

    @State private var files: [SessionChangeSummary.ChangedFile] = []
    @State private var selected: SessionChangeSummary.ChangedFile?
    @State private var diffText: String = ""
    @State private var isRepository = true
    /// Session files git still sees as changed; what "Commit…" offers.
    @State private var pending: [String] = []
    @State private var commitSelection: Set<String> = []
    @State private var showingCommit = false
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var commitError: String?

    public init(appState: AppState, root: String) {
        self.appState = appState
        self.root = root
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if showingCommit {
                Divider()
                commitPanel
            }
            Divider()
            if files.isEmpty {
                empty
            } else {
                HSplitView {
                    fileList.frame(minWidth: 240, idealWidth: 300, maxWidth: 440)
                    detail.frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(files.isEmpty
                     ? "Changes this session"
                     : "\(files.count) file\(files.count == 1 ? "" : "s") changed this session")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Undo covers the current turn only — use the turn review, or commit what works.")
                    .font(.system(size: 10.5))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            Spacer()
            if isRepository && !pending.isEmpty && !showingCommit {
                Button("Commit…") { beginCommit() }
                    .controlSize(.small)
                    .help("Commit this session's changed files")
            }
        }
        .padding(12)
    }

    private var commitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit message")
                .font(.system(size: 11, weight: .semibold))
            TextEditor(text: $commitMessage)
                .font(.system(size: 12))
                .frame(minHeight: 44, maxHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text("Files (\(commitSelection.count) of \(pending.count))")
                .font(.system(size: 11, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pending, id: \.self) { path in
                        Toggle(isOn: Binding(
                            get: { commitSelection.contains(path) },
                            set: { on in
                                if on { commitSelection.insert(path) } else { commitSelection.remove(path) }
                            }
                        )) {
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            if let commitError {
                Text(commitError)
                    .font(.system(size: 10.5))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Only the checked files are committed. Anything else you have staged is left out.")
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                Spacer()
                Button("Cancel") {
                    showingCommit = false
                    commitError = nil
                }
                .controlSize(.small)
                .disabled(isCommitting)
                Button(isCommitting ? "Committing…" : "Commit") { performCommit() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isCommitting || commitSelection.isEmpty
                              || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text("This session has not changed any files.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(files) { file in
                    Button {
                        selected = file
                        loadDiff(for: file)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(badge(for: file))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(color(for: file))
                                    .cornerRadius(3)
                                Text(file.path)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 4)
                            }
                            Text(file.summary)
                                .font(.system(size: 10))
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selected?.path == file.path
                                ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.15)
                                : Color.clear
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            Text(diffText.isEmpty ? placeholder : diffText)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var placeholder: String {
        isRepository
            ? "Select a file to see its diff."
            : "This workspace is not a git repository, so no diff is available. The list above is still what the session's tools reported changing."
    }

    // MARK: - Helpers

    private func badge(for file: SessionChangeSummary.ChangedFile) -> String {
        if file.deleted { return "DEL" }
        if file.wrote && !file.edited { return "NEW" }
        return "MOD"
    }

    private func color(for file: SessionChangeSummary.ChangedFile) -> Color {
        if file.deleted { return .red }
        if file.wrote && !file.edited { return .green }
        return .orange
    }

    private func reload() {
        let messages = appState.currentSession?.messages ?? []
        files = SessionChangeSummary.changedFiles(in: messages, workspaceRoot: root)
        isRepository = GitTools.status(in: root).isRepository
        if let first = files.first {
            selected = selected.flatMap { current in files.first { $0.path == current.path } } ?? first
            if let selected { loadDiff(for: selected) }
        }
        refreshPending()
    }

    /// Ask git which session files still differ. One `git status` per file, so off the main thread.
    private func refreshPending() {
        guard isRepository else {
            pending = []
            return
        }
        let paths = files.map(\.path)
        let root = root
        Task {
            let result = await Task.detached { SessionCommit.pendingPaths(paths, in: root) }.value
            pending = result
            commitSelection.formIntersection(result)
        }
    }

    private func beginCommit() {
        commitSelection = Set(pending)
        commitMessage = SessionCommit.suggestedMessage(sessionTitle: appState.currentSession?.title, paths: pending)
        commitError = nil
        showingCommit = true
    }

    private func performCommit() {
        let paths = pending.filter { commitSelection.contains($0) }
        let message = commitMessage
        isCommitting = true
        commitError = nil
        Task {
            do {
                let hash = try await SessionCommit.commit(paths: paths, message: message, in: root)
                isCommitting = false
                showingCommit = false
                let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
                appState.showToast("Committed \(hash): \(firstLine)")
                reload()
            } catch {
                isCommitting = false
                commitError = error.localizedDescription
            }
        }
    }

    private func loadDiff(for file: SessionChangeSummary.ChangedFile) {
        guard isRepository else {
            diffText = ""
            return
        }
        let result = GitTools.diff(in: root, path: file.path, staged: false)
        diffText = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No uncommitted diff for \(file.path). It may have been committed, reverted, or changed outside git."
            : result.text
    }
}
