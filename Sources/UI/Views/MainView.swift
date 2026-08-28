import SwiftUI

public struct MainView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ZStack {
            if appState.navigationDestination == .settings {
                // Dedicated Full Settings Shell View
                SettingsView(appState: appState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Primary Workspace Layout (Sidebar + Center Content + Optional Inspector)
                HSplitView {
                    // Left Sidebar
                    AppSidebar(appState: appState)

                    // Center Content Area
                    centerContent
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)

                    // Right Side Inspector (collapsible for chat session)
                    if appState.isInspectorOpen && appState.navigationDestination == .chat {
                        SideInspectorView(appState: appState)
                    }
                }
            }

            // Floating Toast Notification Overlay
            if let toast = appState.toastMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(20)
                    .shadow(radius: 8)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Global Spotlight Search Overlay (Cmd+K)
            if appState.isSearchDialogOpen {
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            appState.isSearchDialogOpen = false
                        }

                    SpotlightSearchView(appState: appState, isPresented: $appState.isSearchDialogOpen)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
    }

    // MARK: - Center Content by Destination
    @ViewBuilder
    private var centerContent: some View {
        switch appState.navigationDestination {
        case .chat:
            ChatView(appState: appState)
        case .agents:
            AgentsView(appState: appState)
        case .providers:
            ProvidersView(appState: appState)
        case .automations:
            AutomationsView(appState: appState)
        case .artifacts:
            ArtifactsView(appState: appState)
        case .memory:
            MemoryView(appState: appState)
        case .tools:
            ToolsView(appState: appState)
        case .dashboard:
            DashboardView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        }
    }
}
