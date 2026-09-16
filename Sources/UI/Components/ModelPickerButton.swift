import SwiftUI

/// Searchable model picker used on the main chat header (and composer).
/// Replaces `Menu` so we can put a real search field at the top.
public struct ModelPickerButton: View {
    @ObservedObject var appState: AppState
    /// Compact = composer pill; default = header chip.
    public var style: Style = .header

    @State private var isOpen = false
    @State private var query = ""

    public enum Style {
        case header
        case composer
    }

    public init(appState: AppState, style: Style = .header) {
        self.appState = appState
        self.style = style
    }

    private var isMLXSelection: Bool {
        appState.currentProvider.kind == .omlx
            || appState.currentProvider.kind == .vmlx
            || appState.localMLXModels.contains(where: { $0.id == appState.selectedModelId })
    }

    public var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            labelContent
        }
        .buttonStyle(.hitTestable)
        .popover(isPresented: $isOpen, arrowEdge: style == .header ? .bottom : .top) {
            ModelPickerPopoverContent(
                appState: appState,
                query: $query,
                onSelect: { isOpen = false }
            )
            .frame(width: 360, height: 420)
        }
        .onChange(of: isOpen) { _, open in
            if !open { query = "" }
        }
        .help("Choose model")
    }

    @ViewBuilder
    private var labelContent: some View {
        HStack(spacing: style == .header ? 5 : 4) {
            Image(systemName: isMLXSelection ? "cpu.fill" : appState.currentProvider.kind.icon)
                .font(.system(size: 10))
                .foregroundColor(
                    isMLXSelection
                        ? Color(hex: "#C084FC")
                        : (style == .header
                           ? ThemeColors.accent(for: appState.settings.accentColor)
                           : ThemeColors.textSecondary(for: appState.settings.theme))
                )

            Text(appState.currentModel.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                .lineLimit(1)

            Image(systemName: style == .header ? "chevron.down" : "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, style == .header ? 4 : 3.5)
        .background(
            style == .header
                ? ThemeColors.sidebarBg(for: appState.settings.theme)
                : ThemeColors.cardBg(for: appState.settings.theme)
        )
        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
        .cornerRadius(6)
        .overlay(
            Group {
                if style == .header {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.8), lineWidth: 1)
                }
            }
        )
    }
}

private struct ModelPickerPopoverContent: View {
    @ObservedObject var appState: AppState
    @Binding var query: String
    var onSelect: () -> Void

    @FocusState private var searchFocused: Bool
    /// Section ids that are currently expanded. Default: MLX + provider that owns the selection.
    @State private var expandedSectionIds: Set<String> = []

    private let localSectionId = "local-mlx"

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearching: Bool { !normalizedQuery.isEmpty }

    private var downloadedLocal: [LocalMLXModel] {
        let base = appState.localMLXModels.filter(\.isDownloaded)
        let source = base.isEmpty ? Array(LocalMLXEngine.curatedModels.prefix(12)) : base
        return filterLocal(source)
    }

    private var remoteProviders: [ModelProvider] {
        appState.providers.filter { $0.isEnabled && $0.kind != .omlx && $0.kind != .vmlx }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search at the top
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                TextField("Search models…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.hitTestable)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ThemeColors.cardBg(for: appState.settings.theme))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    collapsibleSection(
                        id: localSectionId,
                        title: "Local Apple Silicon (MLX)",
                        icon: "bolt.fill",
                        iconColor: Color(hex: "#EAB308"),
                        count: downloadedLocal.count
                    ) {
                        if downloadedLocal.isEmpty {
                            emptyRow(isSearching
                                     ? "No local models match “\(query)”"
                                     : "No local models downloaded yet")
                        } else {
                            ForEach(downloadedLocal) { model in
                                localRow(model)
                            }
                        }

                        Button {
                            appState.navigationDestination = .localModels
                            onSelect()
                        } label: {
                            Label("Manage Local Models…", systemImage: "cube.fill")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    }

                    ForEach(remoteProviders) { provider in
                        let models = filterRemote(provider.models, providerName: provider.name)
                        if !models.isEmpty || (!isSearching && !provider.models.isEmpty) {
                            collapsibleSection(
                                id: provider.id,
                                title: provider.name,
                                icon: provider.kind.icon,
                                iconColor: ThemeColors.accent(for: appState.settings.accentColor),
                                count: models.count
                            ) {
                                if models.isEmpty {
                                    emptyRow("No models match “\(query)”")
                                } else {
                                    ForEach(models) { model in
                                        remoteRow(provider: provider, model: model)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .onAppear {
            seedExpandedSections()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            // While searching, expand every section that still has matches.
            if isSearching {
                var ids: Set<String> = []
                if !downloadedLocal.isEmpty { ids.insert(localSectionId) }
                for provider in remoteProviders {
                    let models = filterRemote(provider.models, providerName: provider.name)
                    if !models.isEmpty { ids.insert(provider.id) }
                }
                expandedSectionIds = ids
            } else if expandedSectionIds.isEmpty {
                seedExpandedSections()
            }
        }
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        id: String,
        title: String,
        icon: String,
        iconColor: Color,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = isSectionExpanded(id)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                toggleSection(id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .frame(width: 10)

                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(iconColor)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.55))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if expanded {
            content()
        }
    }

    private func isSectionExpanded(_ id: String) -> Bool {
        // Searching forces open so matches are never hidden behind a closed header.
        if isSearching { return true }
        return expandedSectionIds.contains(id)
    }

    private func toggleSection(_ id: String) {
        if expandedSectionIds.contains(id) {
            expandedSectionIds.remove(id)
        } else {
            expandedSectionIds.insert(id)
        }
    }

    private func seedExpandedSections() {
        var ids: Set<String> = [localSectionId]
        // Expand the provider that owns the current selection so the checkmark is visible.
        if let selectedProvider = remoteProviders.first(where: { $0.id == appState.selectedProviderId }) {
            ids.insert(selectedProvider.id)
        } else if let match = remoteProviders.first(where: { prov in
            prov.models.contains(where: { $0.id == appState.selectedModelId })
        }) {
            ids.insert(match.id)
        }
        expandedSectionIds = ids
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func localRow(_ model: LocalMLXModel) -> some View {
        let selected = model.id == appState.selectedModelId
        return Button {
            appState.selectLocalMLXModel(model)
            onSelect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#C084FC"))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let q = model.quantization {
                            Text(q)
                                .font(.system(size: 9.5, design: .monospaced))
                        }
                        if model.isVLM {
                            Text("Vision")
                                .font(.system(size: 9.5))
                        }
                        if model.useCase == .reasoning {
                            Text("Reasoning")
                                .font(.system(size: 9.5))
                        }
                    }
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func remoteRow(provider: ModelProvider, model: ModelInfo) -> some View {
        let selected = model.id == appState.selectedModelId && provider.id == appState.selectedProviderId
        return Button {
            appState.selectProviderModel(providerId: provider.id, modelId: model.id)
            onSelect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: provider.kind.icon)
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)
                    if model.supportsReasoning {
                        Text("Reasoning")
                            .font(.system(size: 9.5))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func filterLocal(_ models: [LocalMLXModel]) -> [LocalMLXModel] {
        guard !normalizedQuery.isEmpty else { return models }
        return models.filter { model in
            model.name.lowercased().contains(normalizedQuery)
                || model.id.lowercased().contains(normalizedQuery)
                || (model.quantization?.lowercased().contains(normalizedQuery) ?? false)
        }
    }

    private func filterRemote(_ models: [ModelInfo], providerName: String = "") -> [ModelInfo] {
        guard !normalizedQuery.isEmpty else { return models }
        if providerName.lowercased().contains(normalizedQuery) {
            return models
        }
        return models.filter { model in
            model.name.lowercased().contains(normalizedQuery)
                || model.id.lowercased().contains(normalizedQuery)
        }
    }
}
