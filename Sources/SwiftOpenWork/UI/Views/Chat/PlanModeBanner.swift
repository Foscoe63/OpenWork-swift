import SwiftUI

/// Banner when plan mode is active — the vibe ritual before writes are allowed.
public struct PlanModeBanner: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        if appState.settings.planModeEnabled {
            HStack(spacing: 8) {
                Image(systemName: "list.clipboard")
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan mode")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Writes and shell are blocked until the agent calls exit_plan_mode (or you turn this off).")
                        .font(.system(size: 10.5))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()
                Button("Exit plan") {
                    appState.settings.planModeEnabled = false
                    appState.showToast("Plan mode off")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12))
        }
    }
}
