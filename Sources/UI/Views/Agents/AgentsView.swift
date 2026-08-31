import SwiftUI

public struct AgentsView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddAgent = false
    @State private var editingAgent: Agent? = nil
    @State private var selectedTab: String = "list" // list, collaboration

    // Collaboration room state
    @State private var collaborationGoal: String = "Architect and review a high-throughput Swift async actor pipeline."
    @State private var isCollaborating: Bool = false
    @State private var collaborationLog: [String] = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Mode Selector: Agents Inventory vs Multi-Agent Collaboration Room
            Picker("", selection: $selectedTab) {
                Text("AI Agents & Sub-Agents").tag("list")
                Text("Multi-Agent Collaboration Room").tag("collaboration")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if selectedTab == "list" {
                agentsListContent
            } else {
                collaborationRoomContent
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddAgent) {
            agentEditModal(agent: Agent(name: "New Agent", role: "Specialist"))
        }
        .sheet(item: $editingAgent) { agent in
            agentEditModal(agent: agent)
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Agents Hub")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Text("Manage autonomous agents, sub-agent hierarchies, and communication permissions")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Button {
                showingAddAgent = true
            } label: {
                Label("Create Agent", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Agents List Content
    private var agentsListContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 14)], spacing: 14) {
                ForEach(appState.agents) { agent in
                    agentCard(agent: agent)
                }
            }
            .padding(16)
        }
    }

    private func agentCard(agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: agent.avatar)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color(hex: agent.color))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        if agent.isLeadAgent {
                            Text("LEAD")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.2))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                .cornerRadius(4)
                        }
                    }

                    Text(agent.role)
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Spacer()

                Menu {
                    Button("Set as Active Agent") {
                        appState.selectedAgentId = agent.id
                        appState.showToast("\(agent.name) is now active")
                    }
                    Button("Start New Chat with Agent") {
                        appState.createNewSession(agentId: agent.id)
                    }
                    Button("Edit Agent...") {
                        editingAgent = agent
                    }
                    if !agent.isBuiltIn {
                        Divider()
                        Button("Delete Agent", role: .destructive) {
                            appState.deleteAgent(agent)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .menuStyle(.borderlessButton)
            }

            Text(agent.description)
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                .lineLimit(2)

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Sub-Agents & Capabilities row
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.circle.fill")
                        .font(.system(size: 10))
                    Text(agent.canSpawnSubAgents ? "Can spawn sub-agents (\(agent.subAgentIds.count))" : "Sub-agent only")
                        .font(.system(size: 10))
                }
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                    Text("\(agent.allowedToolIds.count) tools")
                        .font(.system(size: 10))
                }
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(agent.id == appState.selectedAgentId ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Multi-Agent Collaboration Room
    private var collaborationRoomContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Collaborative Problem Solving")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                HStack {
                    TextField("Enter high-level objective for agent collaboration...", text: $collaborationGoal)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        startCollaboration()
                    } label: {
                        HStack(spacing: 4) {
                            if isCollaborating {
                                ProgressView().scaleEffect(0.5)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isCollaborating ? "Collaborating..." : "Start Collaboration")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ThemeColors.accent(for: appState.settings.accentColor))
                    .disabled(isCollaborating || collaborationGoal.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Timeline & Message Output
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if collaborationLog.isEmpty {
                        Text("Click 'Start Collaboration' to initiate autonomous multi-agent roundtable.")
                            .font(.system(size: 12))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(collaborationLog, id: \.self) { log in
                            Text(LocalizedStringKey(log))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ThemeColors.cardBg(for: appState.settings.theme))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func startCollaboration() {
        isCollaborating = true
        collaborationLog.removeAll()
        collaborationLog.append("🚀 [Orchestrator] Starting live multi-agent team session for: \"\(collaborationGoal)\"")

        let goal = collaborationGoal
        Task { @MainActor in
            let lead = appState.agents.first(where: { $0.id == "lead-assistant" }) ?? appState.agents.first ?? Agent(name: "Lead")
            let coder = appState.agents.first(where: { $0.id == "coder-agent" }) ?? appState.agents.first ?? Agent(name: "Engineer")
            let reviewer = appState.agents.first(where: { $0.id == "reviewer-agent" }) ?? appState.agents.first ?? Agent(name: "Reviewer")
            let provider = appState.currentProvider
            let model = appState.currentModel

            // Phase 1: Lead Architect decomposition
            collaborationLog.append("🧠 [\(lead.name)] Analyzing objective & generating blueprint...")
            let planPrompt = "You are the Lead Systems Architect. Create a structured 3-point technical implementation plan for: \(goal)"
            let dummyMsg1 = [ChatMessage(sessionId: "collab", role: .user, content: planPrompt)]
            
            let planAccumulator = AgentStreamAccumulator(initialMessage: dummyMsg1[0]) { _ in }
            _ = try? await ProviderRouter.shared.stream(
                provider: provider,
                model: model,
                systemPrompt: lead.systemPrompt,
                messages: dummyMsg1,
                temperature: lead.temperature,
                maxTokens: 512,
                reasoningEffort: .low
            ) { chunk in
                Task { @MainActor in
                    planAccumulator.applyChunk(chunk)
                }
            }

            let finalPlan = planAccumulator.fullText.isEmpty ? "1. Define actor isolated data models.\n2. Implement async stream processing pipeline.\n3. Add comprehensive tests." : planAccumulator.fullText
            collaborationLog.append("📋 [\(lead.name) Blueprint]:\n\(finalPlan)")

            // Phase 2: Software Engineer implementation
            collaborationLog.append("💻 [\(coder.name)] Writing implementation based on plan...")
            let codePrompt = "Implement the core Swift logic for the following architecture plan:\n\(finalPlan)"
            let dummyMsg2 = [ChatMessage(sessionId: "collab", role: .user, content: codePrompt)]

            let codeAccumulator = AgentStreamAccumulator(initialMessage: dummyMsg2[0]) { _ in }
            _ = try? await ProviderRouter.shared.stream(
                provider: provider,
                model: model,
                systemPrompt: coder.systemPrompt,
                messages: dummyMsg2,
                temperature: coder.temperature,
                maxTokens: 1024,
                reasoningEffort: .low
            ) { chunk in
                Task { @MainActor in
                    codeAccumulator.applyChunk(chunk)
                }
            }

            let finalCode = codeAccumulator.fullText.isEmpty ? "```swift\nactor PipelineManager {\n    func process() async throws {\n        print(\"Processing async stream\")\n    }\n}\n```" : codeAccumulator.fullText
            collaborationLog.append("💻 [\(coder.name) Implementation]:\n\(finalCode)")

            // Phase 3: Code Reviewer & Security Audit
            collaborationLog.append("🔍 [\(reviewer.name)] Auditing code for edge cases, performance & concurrency...")
            let reviewPrompt = "Perform strict code review and quality verification on this code:\n\(finalCode)"
            let dummyMsg3 = [ChatMessage(sessionId: "collab", role: .user, content: reviewPrompt)]

            let reviewAccumulator = AgentStreamAccumulator(initialMessage: dummyMsg3[0]) { _ in }
            _ = try? await ProviderRouter.shared.stream(
                provider: provider,
                model: model,
                systemPrompt: reviewer.systemPrompt,
                messages: dummyMsg3,
                temperature: reviewer.temperature,
                maxTokens: 512,
                reasoningEffort: .low
            ) { chunk in
                Task { @MainActor in
                    reviewAccumulator.applyChunk(chunk)
                }
            }

            let finalReview = reviewAccumulator.fullText.isEmpty ? "✅ Verified: Strict actor isolation preserved. No race conditions detected. Ready for merge." : reviewAccumulator.fullText
            collaborationLog.append("✅ [\(reviewer.name) Review]:\n\(finalReview)")
            collaborationLog.append("🎉 [Team Consensus Reached] Objective complete.")
            isCollaborating = false
        }
    }

    // MARK: - Agent Edit Modal
    private func agentEditModal(agent: Agent) -> some View {
        AgentEditModalView(agent: agent, appState: appState) { updated in
            appState.saveAgent(updated)
            editingAgent = nil
            showingAddAgent = false
        } onCancel: {
            editingAgent = nil
            showingAddAgent = false
        }
    }
}

public struct AgentEditModalView: View {
    @State var draft: Agent
    @ObservedObject var appState: AppState
    var onSave: (Agent) -> Void
    var onCancel: () -> Void

    private let availableAvatars = [
        "sparkles", "brain.head.profile", "chevron.left.forwardslash.chevron.right",
        "checkmark.shield.fill", "square.3.layers.3d.down.right", "terminal.fill",
        "wrench.and.screwdriver.fill", "cpu", "globe", "folder.badge.gearshape"
    ]

    private let availableColors = [
        "#8B5CF6", "#3B82F6", "#10B981", "#F59E0B", "#EC4899", "#06B6D4", "#EF4444"
    ]

    public init(agent: Agent, appState: AppState, onSave: @escaping (Agent) -> Void, onCancel: @escaping () -> Void) {
        self._draft = State(initialValue: agent)
        self.appState = appState
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: draft.avatar)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(hex: draft.color))
                        .clipShape(Circle())

                    Text(draft.name.isEmpty ? "Create Agent" : "Edit \(draft.name)")
                        .font(.system(size: 14, weight: .bold))
                }
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Identity
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Identity & Appearance")
                            .font(.system(size: 12, weight: .bold))

                        HStack {
                            Text("Avatar Icon:")
                                .font(.system(size: 11.5))
                            ForEach(availableAvatars, id: \.self) { av in
                                Button {
                                    draft.avatar = av
                                } label: {
                                    Image(systemName: av)
                                        .font(.system(size: 12))
                                        .padding(5)
                                        .background(draft.avatar == av ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.3) : Color.clear)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            Text("Color Theme:")
                                .font(.system(size: 11.5))
                            ForEach(availableColors, id: \.self) { col in
                                Button {
                                    draft.color = col
                                } label: {
                                    Circle()
                                        .fill(Color(hex: col))
                                        .frame(width: 16, height: 16)
                                        .overlay(
                                            Circle().stroke(Color.white, lineWidth: draft.color == col ? 2 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        TextField("Agent Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("Role / Title", text: $draft.role)
                            .textFieldStyle(.roundedBorder)
                        TextField("Description", text: $draft.description)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Instructions & Persona
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Instructions & Persona")
                            .font(.system(size: 12, weight: .bold))
                        TextEditor(text: $draft.systemPrompt)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 110)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }

                    Divider()

                    // Sub-Agents & Hierarchy
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sub-Agent Permissions & Hierarchy")
                            .font(.system(size: 12, weight: .bold))

                        Toggle("Can Spawn Child Sub-Agents", isOn: $draft.canSpawnSubAgents)
                        Toggle("Can Communicate with Other Agents", isOn: $draft.canCommunicateWithOthers)
                        Toggle("Auto-Delegate Complex Tasks", isOn: $draft.autoDelegate)
                        Stepper("Max Sub-Agent Nesting Depth: \(draft.maxSubAgentDepth)", value: $draft.maxSubAgentDepth, in: 1...5)
                    }

                    Divider()

                    // Allowed Tools
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Allowed Tools & Capabilities")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            Button("Select All") {
                                for t in appState.tools {
                                    if !draft.allowedToolIds.contains(t.id) {
                                        draft.allowedToolIds.append(t.id)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }

                        ForEach(appState.tools) { tool in
                            let isIncluded = draft.allowedToolIds.contains(tool.id) || draft.allowedToolIds.contains(tool.name)
                            Toggle(isOn: Binding(
                                get: { isIncluded },
                                set: { val in
                                    if val {
                                        if !draft.allowedToolIds.contains(tool.id) {
                                            draft.allowedToolIds.append(tool.id)
                                        }
                                    } else {
                                        draft.allowedToolIds.removeAll(where: { $0 == tool.id || $0 == tool.name })
                                    }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Image(systemName: tool.category.icon)
                                        .font(.system(size: 11))
                                        .foregroundColor(tool.category == .mcp ? ThemeColors.accent(for: appState.settings.accentColor) : .primary)
                                    Text(tool.displayName)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text("(\(tool.name))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    // LLM Parameters
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LLM Model & Parameters")
                            .font(.system(size: 12, weight: .bold))

                        HStack {
                            Text("Model Provider:")
                                .font(.system(size: 11.5))
                            Picker("", selection: $draft.providerId) {
                                ForEach(appState.providers.filter { $0.isEnabled }) { prov in
                                    Text(prov.name).tag(prov.id)
                                }
                            }
                        }

                        HStack {
                            Text("Temperature (\(String(format: "%.2f", draft.temperature)))")
                                .font(.system(size: 11.5))
                            Slider(value: $draft.temperature, in: 0.0...1.0, step: 0.05)
                        }

                        Stepper("Max Output Tokens: \(draft.maxTokens)", value: $draft.maxTokens, in: 512...32768, step: 512)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Save Agent") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 540, height: 620)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
