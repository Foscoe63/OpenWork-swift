import SwiftUI

public enum SpotlightResultType: String, CaseIterable {
    case session = "Chat Session"
    case agent = "AI Agent"
    case provider = "Model Provider"
    case file = "Workspace File"
    case skill = "Agent Skill"
    case setting = "Settings Tab"

    public var icon: String {
        switch self {
        case .session: return "bubble.left.and.bubble.right"
        case .agent: return "person.crop.circle.badge.checkmark"
        case .provider: return "server.rack"
        case .file: return "doc.text"
        case .skill: return "sparkles"
        case .setting: return "gearshape"
        }
    }
}

public struct SpotlightItem: Identifiable, Hashable {
    public let id = UUID()
    public let title: String
    public let subtitle: String
    public let type: SpotlightResultType
    public let action: () -> Void

    public static func == (lhs: SpotlightItem, rhs: SpotlightItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct SpotlightSearchView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var query: String = ""

    public var results: [SpotlightItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultQuickItems
        }
        let q = query.lowercased()
        var list: [SpotlightItem] = []

        // 1. Sessions
        for s in appState.sessions where s.title.lowercased().contains(q) {
            list.append(SpotlightItem(title: s.title, subtitle: "Session • \(s.messages.count) messages", type: .session) {
                appState.selectSession(s)
                appState.navigationDestination = .chat
                isPresented = false
            })
        }

        // 2. Agents
        for a in appState.agents where a.name.lowercased().contains(q) || a.role.lowercased().contains(q) {
            list.append(SpotlightItem(title: a.name, subtitle: "Agent • \(a.role)", type: .agent) {
                appState.selectedAgentId = a.id
                appState.navigationDestination = .chat
                isPresented = false
            })
        }

        // 3. Providers
        for p in appState.providers where p.name.lowercased().contains(q) || p.kind.displayName.lowercased().contains(q) {
            list.append(SpotlightItem(title: p.name, subtitle: "Provider • \(p.baseUrl)", type: .provider) {
                appState.selectedProviderId = p.id
                appState.navigationDestination = .providers
                isPresented = false
            })
        }

        // 4. Skills
        for sk in appState.skills where sk.name.lowercased().contains(q) || sk.description.lowercased().contains(q) {
            list.append(SpotlightItem(title: sk.name, subtitle: "Skill • \(sk.category)", type: .skill) {
                appState.navigationDestination = .settings
                appState.settingsTab = "skills"
                isPresented = false
            })
        }

        // 5. Settings Tabs
        let settingsTabs = [
            ("general", "General Settings", "Core application defaults"),
            ("preferences", "Preferences", "Inference parameters & reasoning"),
            ("permissions", "Permissions & Folders", "Terminal policies & folder access"),
            ("ai", "AI Providers", "LLM endpoints & model credentials"),
            ("skills", "Skills & MCP", "Model Context Protocol & Custom Skills"),
            ("appearance", "Appearance & Theming", "Theme colors and editor scale")
        ]
        for (tabId, tabName, desc) in settingsTabs where tabName.lowercased().contains(q) || desc.lowercased().contains(q) {
            list.append(SpotlightItem(title: tabName, subtitle: "Settings • \(desc)", type: .setting) {
                appState.navigationDestination = .settings
                appState.settingsTab = tabId
                isPresented = false
            })
        }

        // 6. Workspace Files
        let files = (try? FileManager.default.contentsOfDirectory(atPath: appState.currentWorkspace.folderPath)) ?? []
        for f in files where f.lowercased().contains(q) && !f.hasPrefix(".") {
            list.append(SpotlightItem(title: f, subtitle: "Workspace File • \(appState.currentWorkspace.name)", type: .file) {
                appState.navigationDestination = .artifacts
                isPresented = false
            })
        }

        return list
    }

    private var defaultQuickItems: [SpotlightItem] {
        [
            SpotlightItem(title: "New Chat Session", subtitle: "Start clean conversational turn", type: .session) {
                appState.createNewSession()
                appState.navigationDestination = .chat
                isPresented = false
            },
            SpotlightItem(title: "Multi-Agent Collaboration Room", subtitle: "Round-robin autonomous problem solving", type: .agent) {
                appState.navigationDestination = .agents
                isPresented = false
            },
            SpotlightItem(title: "Model Providers & Catalog", subtitle: "Download Ollama models or connect cloud keys", type: .provider) {
                appState.navigationDestination = .providers
                isPresented = false
            },
            SpotlightItem(title: "Workspace Artifacts Explorer", subtitle: "Browse & edit project files", type: .file) {
                appState.navigationDestination = .artifacts
                isPresented = false
            },
            SpotlightItem(title: "Skills & Model Context Protocol", subtitle: "Manage stdio/SSE tools and agent skills", type: .skill) {
                appState.navigationDestination = .settings
                appState.settingsTab = "skills"
                isPresented = false
            }
        ]
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

                TextField("Search sessions, agents, skills, files, or settings (Cmd+K)...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))

                Button {
                    isPresented = false
                } label: {
                    Text("ESC")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(ThemeColors.border(for: appState.settings.theme))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            // Results List
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(results) { item in
                        Button {
                            item.action()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.type.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                    Text(item.subtitle)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                }

                                Spacer()

                                Text(item.type.rawValue)
                                    .font(.system(size: 9.5))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.6))
                                    .cornerRadius(4)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 580, height: 420)
        .background(ThemeColors.bg(for: appState.settings.theme))
        .cornerRadius(12)
        .shadow(radius: 20)
    }
}
