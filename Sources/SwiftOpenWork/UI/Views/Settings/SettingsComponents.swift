import SwiftUI

public struct SettingsCard<Content: View>: View {
    let title: String?
    let description: String?
    let icon: String?
    let content: Content

    public init(
        title: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || description != nil {
                HStack(spacing: 8) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ThemeColors.accent(for: AppState.shared.settings.accentColor))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if let title = title {
                            Text(title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(ThemeColors.textPrimary(for: AppState.shared.settings.theme))
                        }
                        if let description = description {
                            Text(description)
                                .font(.system(size: 11))
                                .foregroundColor(ThemeColors.textSecondary(for: AppState.shared.settings.theme))
                        }
                    }
                    Spacer()
                }

                Divider()
                    .background(ThemeColors.border(for: AppState.shared.settings.theme))
            }

            content
        }
        .padding(16)
        .background(ThemeColors.cardBg(for: AppState.shared.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ThemeColors.border(for: AppState.shared.settings.theme), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

public struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let trailing: Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(ThemeColors.accent(for: AppState.shared.settings.accentColor))
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(ThemeColors.textPrimary(for: AppState.shared.settings.theme))

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: AppState.shared.settings.theme))
                }
            }

            Spacer()

            trailing
        }
        .padding(.vertical, 3)
    }
}
