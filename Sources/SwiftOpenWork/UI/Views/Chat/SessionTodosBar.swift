import SwiftUI
import SwiftOpenWorkCore

/// Sticky checklist driven by `todo_write`, shown above the composer during vibe sessions.
public struct SessionTodosBar: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    private var todos: [SessionTodoItem] {
        appState.currentSession?.todos ?? []
    }

    public var body: some View {
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Text("Plan")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("\(todos.filter { $0.status == .done }.count)/\(todos.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    Spacer()
                    Button {
                        appState.updateSessionTodos([])
                    } label: {
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.hitTestable)
                }

                ForEach(todos.prefix(8)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.status.icon)
                            .font(.system(size: 11))
                            .foregroundColor(color(for: item.status))
                            .frame(width: 14)
                        Text(item.content)
                            .font(.system(size: 11.5))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                            .strikethrough(item.status == .done)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                if todos.count > 8 {
                    Text("+\(todos.count - 8) more")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
            )
            .cornerRadius(8)
            .padding(.horizontal, 16)
        }
    }

    private func color(for status: SessionTodoItem.Status) -> Color {
        switch status {
        case .pending: return ThemeColors.textSecondary(for: appState.settings.theme)
        case .inProgress: return ThemeColors.accent(for: appState.settings.accentColor)
        case .done: return .green
        }
    }
}
