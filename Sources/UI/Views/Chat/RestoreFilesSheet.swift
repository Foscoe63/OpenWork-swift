import SwiftUI

/// Confirmation for rewinding the working tree to a point in the transcript.
///
/// Restoring overwrites files the user may have edited by hand since, so it names every path
/// before it touches anything. The list is the whole point of the sheet — a bare "are you sure?"
/// would make this exactly the kind of blind undo the turn-scoped store exists to avoid.
public struct RestoreFilesSheet: View {
    @ObservedObject var appState: AppState
    let pending: AppState.PendingRestore

    public init(appState: AppState, pending: AppState.PendingRestore) {
        self.appState = appState
        self.pending = pending
    }

    private var theme: AppTheme { appState.settings.theme }

    private var root: String {
        let path = appState.currentWorkspace.folderPath
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        title: "Content put back",
                        systemImage: "arrow.uturn.backward",
                        tint: ThemeColors.accent(for: appState.settings.accentColor),
                        paths: pending.plan.restore
                    )
                    section(
                        title: "Deleted (created after this point)",
                        systemImage: "trash",
                        tint: .red,
                        paths: pending.plan.delete
                    )
                    section(
                        title: "Left alone — no snapshot was kept",
                        systemImage: "exclamationmark.triangle",
                        tint: .orange,
                        paths: pending.plan.unrecoverable
                    )
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .background(ThemeColors.bg(for: theme))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Restore files to before this turn")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: theme))
            Text(pending.label)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundColor(ThemeColors.textSecondary(for: theme))
            Text("Undoes \(pending.plan.turnsUndone) turn(s) of file changes. The conversation is left as it is.")
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private func section(title: String, systemImage: String, tint: Color, paths: [String]) -> some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundColor(tint)
                    Text("\(title) (\(paths.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                }
                ForEach(paths, id: \.self) { path in
                    Text(relative(path))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !pending.plan.unrecoverable.isEmpty {
                Text("Files with no snapshot stay as they are on disk.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Spacer()
            Button("Cancel") { appState.cancelPendingRestore() }
                .keyboardShortcut(.cancelAction)
            Button("Restore \(pending.plan.affectedCount) File(s)") {
                appState.confirmPendingRestore()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pending.plan.affectedCount == 0)
        }
        .padding(16)
    }
}
