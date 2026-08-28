import SwiftUI

public struct MemoryView: View {
    @ObservedObject var appState: AppState
    @State private var searchText: String = ""
    @State private var showingAddModal = false
    @State private var newKey = ""
    @State private var newContent = ""
    @State private var newCategory: MemoryCategory = .fact

    public init(appState: AppState) {
        self.appState = appState
    }

    public var filteredMemories: [MemoryItem] {
        if searchText.isEmpty { return appState.memories }
        return appState.memories.filter {
            $0.key.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory & Knowledge Base")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Persistent facts, user preferences, and project guidelines stored across all agent sessions")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()
                Button {
                    showingAddModal = true
                } label: {
                    Label("Add Memory", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeColors.accent(for: appState.settings.accentColor))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search memory items...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 12)], spacing: 12) {
                    ForEach(filteredMemories) { item in
                        memoryCard(item: item)
                    }
                }
                .padding(16)
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddModal) {
            addMemoryModal
        }
    }

    private func memoryCard(item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.category.icon)
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                Text(item.key)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Spacer()
                Text(item.category.displayName)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }

            Text(item.content)
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
        }
        .padding(12)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private var addMemoryModal: some View {
        VStack(spacing: 16) {
            Text("Add Memory Item")
                .font(.headline)
            TextField("Memory Key / Title", text: $newKey)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $newContent)
                .frame(height: 100)
            HStack {
                Button("Cancel") { showingAddModal = false }
                Spacer()
                Button("Save") {
                    guard !newKey.isEmpty && !newContent.isEmpty else { return }
                    let item = MemoryItem(key: newKey, content: newContent, category: newCategory)
                    appState.memories.append(item)
                    PersistenceManager.shared.saveMemories(appState.memories)
                    showingAddModal = false
                    newKey = ""
                    newContent = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
