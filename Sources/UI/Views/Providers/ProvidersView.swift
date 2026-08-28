import SwiftUI

public struct ProvidersView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddProvider = false
    @State private var editingProvider: ModelProvider? = nil
    @State private var pullModelName: String = "llama3:latest"
    @State private var fetchingProviderIds: Set<String> = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Ollama Quick Pull Box (if Ollama exists)
                    ollamaPullCard

                    // Local Providers Section
                    sectionHeader(title: "LOCAL MODEL PROVIDERS", subtitle: "Zero-latency, 100% private inference on your Apple Silicon Mac")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 14)], spacing: 14) {
                        ForEach(appState.providers.filter { $0.type == .local }) { provider in
                            providerCard(provider: provider)
                        }
                    }

                    // Cloud Providers Section
                    sectionHeader(title: "CLOUD MODEL PROVIDERS", subtitle: "Connect state-of-the-art hosted frontier models")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 14)], spacing: 14) {
                        ForEach(appState.providers.filter { $0.type == .cloud }) { provider in
                            providerCard(provider: provider)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddProvider) {
            ProviderEditModalView(
                provider: ModelProvider(name: "OpenAI", type: .cloud, kind: .openai),
                appState: appState,
                isNewProvider: true
            ) { updated in
                appState.saveProvider(updated)
                showingAddProvider = false
            } onCancel: {
                showingAddProvider = false
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditModalView(
                provider: provider,
                appState: appState,
                isNewProvider: false
            ) { updated in
                appState.saveProvider(updated)
                editingProvider = nil
            } onCancel: {
                editingProvider = nil
            }
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Providers & Catalog")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Text("Manage local Ollama / LM Studio endpoints and cloud LLM providers")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Button {
                showingAddProvider = true
            } label: {
                Label("Add Provider", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
        }
    }

    // MARK: - Ollama Quick Pull Box
    private var ollamaPullCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                Text("Download / Pull Local Ollama Model")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Spacer()
            }

            HStack {
                TextField("e.g. llama3, deepseek-r1:8b, mistral, qwen2.5-coder", text: $pullModelName)
                    .textFieldStyle(.roundedBorder)

                Button {
                    appState.pullOllamaModel(name: pullModelName)
                } label: {
                    HStack(spacing: 4) {
                        if appState.isPullingModel {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "arrow.down")
                        }
                        Text(appState.isPullingModel ? "Pulling..." : "Pull Model")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeColors.accent(for: appState.settings.accentColor))
                .disabled(appState.isPullingModel || pullModelName.isEmpty)
            }

            if appState.isPullingModel {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: appState.pullModelProgress)
                    Text(appState.pullModelStatusText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Provider Card
    private func providerCard(provider: ModelProvider) -> some View {
        let isFetching = fetchingProviderIds.contains(provider.id)
        let isCurrentProvider = (provider.id == appState.selectedProviderId)
        
        return VStack(alignment: .leading, spacing: 10) {
            // Header Row
            HStack(spacing: 10) {
                Image(systemName: provider.kind.icon)
                    .font(.system(size: 18))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    .frame(width: 36, height: 36)
                    .background(ThemeColors.border(for: appState.settings.theme))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        Text(provider.kind.displayName)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(ThemeColors.border(for: appState.settings.theme))
                            .cornerRadius(4)

                        if provider.isDefault {
                            Text("DEFAULT")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.2))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                .cornerRadius(3)
                        }
                    }

                    Text(provider.baseUrl)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { val in
                        var updated = provider
                        updated.isEnabled = val
                        appState.saveProvider(updated)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.5))

            // Model Selection Dropdown Box
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Selected Model:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    Spacer()
                    Text("\(provider.models.count) available")
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
                }

                if provider.models.isEmpty {
                    Text("No models discovered. Click 'Fetch Models' to load catalog.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                } else {
                    let activeModelId = isCurrentProvider ? appState.selectedModelId : (provider.models.first(where: { $0.isDefault })?.id ?? provider.models.first?.id ?? "")
                    
                    Menu {
                        ForEach(provider.models) { m in
                            Button {
                                appState.selectedProviderId = provider.id
                                appState.selectedModelId = m.id
                                appState.showToast("Selected \(m.name) for \(provider.name)")
                            } label: {
                                HStack {
                                    Text(m.name)
                                    if m.supportsReasoning {
                                        Text("🧠 Reasoning")
                                    }
                                    if m.id == activeModelId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            let selectedModel = provider.models.first(where: { $0.id == activeModelId }) ?? provider.models.first
                            Text(selectedModel?.name ?? "Select Model")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                .lineLimit(1)
                            
                            if selectedModel?.supportsReasoning == true {
                                Text("🧠")
                                    .font(.system(size: 10))
                            }
                            
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ThemeColors.bg(for: appState.settings.theme))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            // Actions Row: Fetch Models & Configure
            HStack(spacing: 8) {
                Button {
                    fetchModelsForProvider(provider)
                } label: {
                    HStack(spacing: 4) {
                        if isFetching {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(isFetching ? "Fetching..." : "Fetch Models")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetching)

                Button("Test Ping") {
                    Task {
                        let ok = (try? await ProviderRouter.shared.client(for: provider).testConnection(provider: provider)) ?? false
                        appState.showToast(ok ? "\(provider.name): Connected!" : "\(provider.name): Connection Failed")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))

                Spacer()

                Button("Configure...") {
                    editingProvider = provider
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrentProvider ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private func fetchModelsForProvider(_ provider: ModelProvider) {
        fetchingProviderIds.insert(provider.id)
        Task {
            do {
                let models = try await ProviderRouter.shared.client(for: provider).listModels(provider: provider)
                await MainActor.run {
                    fetchingProviderIds.remove(provider.id)
                    if let idx = appState.providers.firstIndex(where: { $0.id == provider.id }) {
                        if !models.isEmpty {
                            appState.providers[idx].models = models
                            PersistenceManager.shared.saveProviders(appState.providers)
                            appState.showToast("Fetched \(models.count) models for \(provider.name)")
                        } else {
                            appState.showToast("No models returned by \(provider.name) endpoint (\(provider.baseUrl))")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    fetchingProviderIds.remove(provider.id)
                    appState.showToast("Could not fetch models: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Provider Configure & Add Modal
public struct ProviderEditModalView: View {
    @State var draft: ModelProvider
    @ObservedObject var appState: AppState
    var isNewProvider: Bool
    var onSave: (ModelProvider) -> Void
    var onCancel: () -> Void

    @State private var isFetching: Bool = false
    @State private var fetchStatusMessage: String? = nil
    @State private var selectedModelId: String = ""
    @State private var newCustomModelName: String = ""
    @State private var isApiKeyVisible: Bool = false

    public init(
        provider: ModelProvider,
        appState: AppState,
        isNewProvider: Bool = false,
        onSave: @escaping (ModelProvider) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._draft = State(initialValue: provider)
        self.appState = appState
        self.isNewProvider = isNewProvider
        self.onSave = onSave
        self.onCancel = onCancel
        
        let initialModel = provider.models.first(where: { $0.isDefault })?.id ?? provider.models.first?.id ?? ""
        self._selectedModelId = State(initialValue: initialModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: draft.kind.icon)
                        .font(.system(size: 16))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Text(isNewProvider ? "Add Model Provider" : "Configure \(draft.name)")
                        .font(.system(size: 14, weight: .bold))
                }
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 1. Provider Kind & Type
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Provider Platform / Type")
                            .font(.system(size: 11.5, weight: .semibold))

                        Picker("", selection: Binding(
                            get: { draft.kind },
                            set: { newKind in
                                draft.kind = newKind
                                draft.type = newKind.type
                                if isNewProvider || draft.name.isEmpty || ProviderKind.allCases.map({ $0.displayName }).contains(draft.name) {
                                    draft.name = newKind.displayName
                                }
                                draft.baseUrl = newKind.defaultBaseUrl
                            }
                        )) {
                            ForEach(ProviderKind.allCases) { kind in
                                HStack {
                                    Image(systemName: kind.icon)
                                    Text(kind.displayName)
                                }
                                .tag(kind)
                            }
                        }
                    }

                    // 2. Name & Base URL
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display Name")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. OpenAI Production, Local Ollama, OpenRouter", text: $draft.name)
                            .textFieldStyle(.roundedBorder)

                        Text("Base API Endpoint URL")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("https://api.openai.com/v1", text: $draft.baseUrl)
                            .textFieldStyle(.roundedBorder)

                        // API Key / Authorization Token input for all providers (cloud or local secured with Bearer tokens)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("API Key / Authorization Token")
                                    .font(.system(size: 11.5, weight: .semibold))
                                if draft.type == .local && draft.kind != .custom {
                                    Text("(Optional)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack {
                                if isApiKeyVisible {
                                    TextField(draft.type == .local ? "Bearer token or key (if required)" : "sk-...", text: $draft.apiKey)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField(draft.type == .local ? "Bearer token or key (if required)" : "sk-...", text: $draft.apiKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Button {
                                    isApiKeyVisible.toggle()
                                } label: {
                                    Image(systemName: isApiKeyVisible ? "eye.slash" : "eye")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .help(isApiKeyVisible ? "Hide Key" : "Show Key")
                            }
                        }
                    }

                    Divider()

                    // 3. Model Management & Selection
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Model Catalog (\(draft.models.count) Available)")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Fetch models from API or select the active default model")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Fetch Models Button
                            Button {
                                performFetchModels()
                            } label: {
                                HStack(spacing: 4) {
                                    if isFetching {
                                        ProgressView().scaleEffect(0.5)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    Text(isFetching ? "Fetching..." : "Fetch Models")
                                }
                                .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isFetching)
                        }

                        if let status = fetchStatusMessage {
                            Text(status)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(status.contains("Failed") || status.contains("Error") ? .red : .green)
                                .padding(.vertical, 2)
                        }

                        // Model Dropdown Box / Picker
                        if !draft.models.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Select Model from Dropdown:")
                                    .font(.system(size: 11, weight: .medium))

                                Picker("", selection: $selectedModelId) {
                                    ForEach(draft.models) { m in
                                        HStack {
                                            Text(m.name)
                                            if m.supportsReasoning {
                                                Text("🧠 (Reasoning)")
                                            }
                                        }
                                        .tag(m.id)
                                    }
                                }
                                .pickerStyle(.menu)

                                // Selected Model Details Card
                                if let selected = draft.models.first(where: { $0.id == selectedModelId }) {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Model ID: \(selected.id)")
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            Text("Context: \(selected.contextWindow / 1000)k tokens • Speed: \(selected.speedTier)")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }

                                        Spacer()

                                        Button(selected.isDefault ? "Default Model ✓" : "Set as Default") {
                                            for idx in 0..<draft.models.count {
                                                draft.models[idx].isDefault = (draft.models[idx].id == selected.id)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                    .padding(8)
                                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                                    .cornerRadius(6)
                                }
                            }
                        } else {
                            Text("No models loaded. Click 'Fetch Models' to query \(draft.name) API, or add custom models below.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        }

                        // Add Custom Model Input Row
                        HStack(spacing: 6) {
                            TextField("Add custom model ID (e.g. gpt-4o, claude-3-5-sonnet)", text: $newCustomModelName)
                                .textFieldStyle(.roundedBorder)

                            Button("Add") {
                                guard !newCustomModelName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                let id = newCustomModelName.trimmingCharacters(in: .whitespaces)
                                let newModel = ModelInfo(
                                    id: id,
                                    name: id,
                                    providerId: draft.id,
                                    contextWindow: 128000,
                                    supportsReasoning: id.contains("r1") || id.contains("o1") || id.contains("o3")
                                )
                                draft.models.append(newModel)
                                selectedModelId = newModel.id
                                newCustomModelName = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled(newCustomModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Test Connection") {
                    Task {
                        let ok = (try? await ProviderRouter.shared.client(for: draft).testConnection(provider: draft)) ?? false
                        await MainActor.run {
                            appState.showToast(ok ? "Connection to \(draft.name) Successful!" : "Connection Failed")
                        }
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Provider") {
                    guard !draft.name.isEmpty else { return }
                    // Ensure at least one model is default if models exist
                    if !draft.models.isEmpty && !draft.models.contains(where: { $0.isDefault }) {
                        if let firstIdx = draft.models.firstIndex(where: { $0.id == selectedModelId }) ?? draft.models.indices.first {
                            draft.models[firstIdx].isDefault = true
                        }
                    }
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.isEmpty || draft.baseUrl.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
        .background(ThemeColors.bg(for: appState.settings.theme))
        .onAppear {
            if selectedModelId.isEmpty, let first = draft.models.first {
                selectedModelId = first.id
            }
        }
    }

    private func performFetchModels() {
        isFetching = true
        fetchStatusMessage = "Connecting to \(draft.baseUrl)..."
        Task {
            do {
                let models = try await ProviderRouter.shared.client(for: draft).listModels(provider: draft)
                await MainActor.run {
                    isFetching = false
                    if !models.isEmpty {
                        draft.models = models
                        if !models.contains(where: { $0.id == selectedModelId }) {
                            selectedModelId = models.first(where: { $0.isDefault })?.id ?? models.first?.id ?? ""
                        }
                        fetchStatusMessage = "Successfully fetched \(models.count) models from server!"
                    } else {
                        fetchStatusMessage = "No models returned by server at \(draft.baseUrl). Check your endpoint URL or add model IDs below."
                    }
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    fetchStatusMessage = "Fetch Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
