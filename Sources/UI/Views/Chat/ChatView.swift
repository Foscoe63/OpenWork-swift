import SwiftUI

public struct ChatView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Main Chat Stream or Hero Empty State
            if let session = appState.currentSession, !session.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(session.messages) { msg in
                                MessageBubbleView(message: msg, appState: appState)
                                    .id(msg.id)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onMessageCountChanged(count: session.messages.count) {
                        if let last = session.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                emptyStateHero
            }

            // Composer Dock
            ComposerView(appState: appState)
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            // Title & Status
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.currentSession?.title ?? "New Session")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isGenerating ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(appState.isGenerating ? "Agent executing..." : "Agent ready")
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
            }

            Spacer()

            // Header Toolbar Actions
            HStack(spacing: 6) {
                // Export Session Menu
                Menu {
                    Button("Export as Markdown (.md)") {
                        appState.exportCurrentSession(as: .markdown)
                    }
                    Button("Export as JSON (.json)") {
                        appState.exportCurrentSession(as: .json)
                    }
                    Button("Export as HTML / Printable Report") {
                        appState.exportCurrentSession(as: .html)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
                .help("Export Chat Session")

                // Clear Session
                Button {
                    appState.sendMessage(text: "/clear")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.plain)
                .help("Clear Session Messages")

                // Toggle Side Inspector
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.isInspectorOpen.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13))
                        .foregroundColor(appState.isInspectorOpen ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.plain)
                .help("Toggle Sub-Agent Inspector Panel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Empty State Hero
    private var emptyStateHero: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 48))
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

            VStack(spacing: 6) {
                Text("OpenWork AI Agent Workspace")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Text("Autonomous, local & cloud agent orchestrator powered by Swift")
                    .font(.system(size: 13))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            // Quick Starter Prompt Cards (Centered with clean constrained responsive grid)
            VStack {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 12)
                ], spacing: 12) {
                    starterCard(
                        title: "Multi-Agent System",
                        subtitle: "Spawn sub-agents to collaborate on complex software architecture",
                        icon: "person.3.fill",
                        prompt: "Design and implement a multi-agent workflow for continuous code quality inspection with specialized sub-agents."
                    )
                    starterCard(
                        title: "Local Ollama Inference",
                        subtitle: "Execute offline with locally installed models (Llama 3, DeepSeek R1)",
                        icon: "desktopcomputer",
                        prompt: "Write a high performance Swift concurrency pipeline using async algorithms and structured concurrency."
                    )
                    starterCard(
                        title: "Deep Code Analysis",
                        subtitle: "Scan workspace files, detect bottlenecks, and refactor",
                        icon: "curlybraces",
                        prompt: "Analyze the current workspace files, check for memory leaks and race conditions, and recommend optimizations."
                    )
                    starterCard(
                        title: "Automations & Tools",
                        subtitle: "Execute safe shell commands and scheduled task triggers",
                        icon: "bolt.badge.clock.fill",
                        prompt: "Explain how OpenWork-Swift automations trigger recurring agent workflows."
                    )
                }
                .frame(maxWidth: 880)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func starterCard(title: String, subtitle: String, icon: String, prompt: String) -> some View {
        Button {
            appState.sendMessage(text: prompt)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 95, alignment: .topLeading)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
