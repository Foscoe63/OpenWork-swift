import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Edit the workspace's `SWIFTOPENWORK.md` (or create it). Loaded into the agent system prompt.
public struct WorkspaceRulesCard: View {
    @ObservedObject var appState: AppState
    @State private var draft: String = ""
    @State private var sourceName: String = AppIdentity.rulesFileName
    /// The file the text came from, when there is one. Decides where Save writes.
    @State private var loadedName: String?
    @State private var status: String?
    @State private var didLoad = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        SettingsCard(
            title: "Project Rules",
            description: "Standing instructions for this workspace. Saved as SWIFTOPENWORK.md and injected into every agent turn.",
            icon: "doc.badge.gearshape"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(sourceName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let status {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Button("Reload") { reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160, maxHeight: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                    )

                Text("Also recognised at the workspace root: OPENWORK.md, AGENTS.md, CLAUDE.md, .openwork.md, .cursorrules — first found wins. Save writes back to an OPENWORK file if that is what was loaded, otherwise creates SWIFTOPENWORK.md; it never writes another tool's file.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear {
                if !didLoad {
                    didLoad = true
                    reload()
                }
            }
            .onValueChanged(of: appState.activeWorkspaceId) {
                reload()
            }
        }
    }

    private func reload() {
        let folder = appState.currentWorkspace.folderPath
        if let loaded = ProjectInstructions.load(folderPath: folder) {
            sourceName = loaded.name
            loadedName = loaded.name
            draft = loaded.content
            status = loaded.clipped ? "Clipped for agent (editing full file)" : "Loaded"
            if loaded.clipped, let full = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(loaded.name), encoding: .utf8) {
                draft = full
            }
        } else {
            loadedName = nil
            sourceName = "\(AppIdentity.rulesFileName) (new)"
            draft = """
            # Project instructions

            - Prefer small, reviewable changes.
            - Run build/tests after code edits.
            - Do not commit on the user's checkout; use agent worktrees when committing.
            """
            status = "No rules file yet"
        }
    }

    private func save() {
        let folder = appState.currentWorkspace.folderPath
        guard !folder.isEmpty else {
            status = "No workspace folder"
            return
        }
        let target = ProjectInstructions.saveTarget(loadedName: loadedName)
        let path = (folder as NSString).appendingPathComponent(target)
        do {
            try draft.write(toFile: path, atomically: true, encoding: .utf8)
            sourceName = target
            loadedName = target
            status = "Saved"
            appState.showToast("Saved \(target)")
        } catch {
            status = error.localizedDescription
        }
    }
}
