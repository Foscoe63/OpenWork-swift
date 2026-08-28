import SwiftUI

public struct ThemeColors {
    public static func bg(for theme: AppTheme) -> Color {
        switch theme {
        case .light: return Color(hex: "#F9FAFB")
        case .dark: return Color(hex: "#0F1117")
        case .midnight: return Color(hex: "#0A0E1A")
        case .cyberpunk: return Color(hex: "#05050A")
        case .monokai: return Color(hex: "#272822")
        case .system: return Color(nsColor: .windowBackgroundColor)
        }
    }

    public static func sidebarBg(for theme: AppTheme) -> Color {
        switch theme {
        case .light: return Color(hex: "#F3F4F6")
        case .dark: return Color(hex: "#161822")
        case .midnight: return Color(hex: "#0E1326")
        case .cyberpunk: return Color(hex: "#0B0B14")
        case .monokai: return Color(hex: "#1E1F1C")
        case .system: return Color(nsColor: .controlBackgroundColor)
        }
    }

    public static func cardBg(for theme: AppTheme) -> Color {
        switch theme {
        case .light: return Color.white
        case .dark: return Color(hex: "#1C1F2E")
        case .midnight: return Color(hex: "#141B33")
        case .cyberpunk: return Color(hex: "#121224")
        case .monokai: return Color(hex: "#3E3D32")
        case .system: return Color(nsColor: .textBackgroundColor)
        }
    }

    public static func border(for theme: AppTheme) -> Color {
        switch theme {
        case .light: return Color(hex: "#E5E7EB")
        case .dark: return Color(hex: "#282C3F")
        case .midnight: return Color(hex: "#1E2749")
        case .cyberpunk: return Color(hex: "#2A1B4E")
        case .monokai: return Color(hex: "#49483E")
        case .system: return Color(nsColor: .separatorColor)
        }
    }

    public static func textPrimary(for theme: AppTheme) -> Color {
        switch theme {
        case .light: return Color(hex: "#111827")
        default: return Color(hex: "#F9FAFB")
        }
    }

    public static func textSecondary(for theme: AppTheme) -> Color {
        switch theme {
        case .light: return Color(hex: "#6B7280")
        default: return Color(hex: "#9CA3AF")
        }
    }

    public static func accent(for choice: AccentColorChoice) -> Color {
        Color(hex: choice.hex)
    }
}

extension Color {
    public init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
