import SwiftUI
import SwiftOpenWorkEngine

/// Review everything this session changed on disk, across every turn.
///
/// The per-turn review reads the checkpoint store, which holds real before/after contents and can
/// therefore offer undo — but only for the current turn, by design. A session-wide view is built
/// from the transcript's tool calls instead, so it knows *what* was touched and *when* but holds no
/// prior contents. It shows git's diff and offers no revert, and says so plainly: a view that
/// looked like the turn review but silently could not restore anything would be worse than none.
public struct SessionChangeReviewView: View {
    @ObservedObject var appState: AppState
    let root: String

    @State private var files: [SessionChangeSummary.ChangedFile] = []
    @State private var selected: SessionChangeSummary.ChangedFile?
    @State private var diffText: String = ""
    @State private var isRepository = true

    public init(appState: AppState, root: String) {
        self.appState = appState
        self.root = root
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
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
                Text("Read-only. Undo covers the current turn only — use the turn review, or git.")
                    .font(.system(size: 10.5))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            Spacer()
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
            selected = first
            loadDiff(for: first)
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
