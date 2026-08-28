import SwiftUI

public struct ToolsView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools & Extensions Inventory")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Built-in system tools, MCP servers, and installed extensions connected to OpenWork")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()

                Button {
                    appState.settingsTab = "extensions"
                    appState.navigationDestination = .settings
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "puzzlepiece.extension")
                        Text("Manage Extensions & Plugins")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(appState.tools) { tool in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: tool.category.icon)
                                .font(.system(size: 16))
                                .foregroundColor(tool.isEnabled ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)
                                .frame(width: 32, height: 32)
                                .background(ThemeColors.border(for: appState.settings.theme))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(tool.displayName)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                    Text(tool.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                    Text(tool.category.displayName)
                                        .font(.system(size: 9.5))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(ThemeColors.border(for: appState.settings.theme))
                                        .cornerRadius(4)
                                }

                                Text(tool.description)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { tool.isEnabled },
                                set: { val in
                                    if let idx = appState.tools.firstIndex(where: { $0.id == tool.id }) {
                                        appState.tools[idx].isEnabled = val
                                        PersistenceManager.shared.saveTools(appState.tools)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .padding(14)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                        )
                        .cornerRadius(10)
                    }
                }
                .padding(16)
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
