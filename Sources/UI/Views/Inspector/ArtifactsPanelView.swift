import SwiftUI

public struct ArtifactsPanelView: View {
    @ObservedObject var appState: AppState
    @State private var files: [String] = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WORKSPACE ARTIFACTS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
                        Text(appState.currentWorkspace.folderPath)
                            .font(.system(size: 10))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .lineLimit(1)
                    }
                    Spacer()

                    Button {
                        refreshFiles()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh File Tree")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 24))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.5))
                        Text("Click refresh to load workspace files.")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files, id: \.self) { file in
                            HStack(spacing: 6) {
                                Image(systemName: fileIcon(for: file))
                                    .font(.system(size: 11))
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                Text(file)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            refreshFiles()
        }
    }

    private func refreshFiles() {
        let path = appState.currentWorkspace.folderPath
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        files = items.filter { !$0.hasPrefix(".") }
    }

    private func fileIcon(for file: String) -> String {
        if file.hasSuffix(".swift") { return "swift" }
        if file.hasSuffix(".json") { return "curlybraces" }
        if file.hasSuffix(".md") { return "doc.plaintext" }
        return "doc"
    }
}
