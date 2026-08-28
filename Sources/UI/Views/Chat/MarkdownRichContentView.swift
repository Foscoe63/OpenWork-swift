import SwiftUI
import AppKit

public enum MarkdownSegment: Identifiable {
    public var id: String {
        switch self {
        case .text(let t, let index): return "text-\(index)-\(t.prefix(20))"
        case .code(let code, let lang, let index): return "code-\(index)-\(lang)-\(code.prefix(20))"
        }
    }

    case text(String, index: Int)
    case code(String, language: String, index: Int)
}

public struct MarkdownCodeParser {
    public static func parse(markdown: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        let pattern = "```([a-zA-Z0-9_-]*)\\n?([\\s\\S]*?)```"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(markdown, index: 0)]
        }

        let nsString = markdown as NSString
        var lastLocation = 0
        var segIndex = 0

        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            // Preceding text
            if match.range.location > lastLocation {
                let textRange = NSRange(location: lastLocation, length: match.range.location - lastLocation)
                let text = nsString.substring(with: textRange)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(text, index: segIndex))
                    segIndex += 1
                }
            }

            // Language
            var language = "text"
            if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                let langStr = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !langStr.isEmpty {
                    language = langStr
                }
            }

            // Code content
            var code = ""
            if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                code = nsString.substring(with: match.range(at: 2))
            }

            segments.append(.code(code, language: language, index: segIndex))
            segIndex += 1

            lastLocation = match.range.location + match.range.length
        }

        // Remaining text
        if lastLocation < nsString.length {
            let remRange = NSRange(location: lastLocation, length: nsString.length - lastLocation)
            let rem = nsString.substring(with: remRange)
            if !rem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(rem, index: segIndex))
            }
        }

        if segments.isEmpty && !markdown.isEmpty {
            segments.append(.text(markdown, index: 0))
        }

        return segments
    }
}

public struct FormattedCodeBlockView: View {
    let code: String
    let language: String
    @ObservedObject var appState: AppState
    @State private var isCopied: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 8, height: 8)
                    Text(language.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.leading, 6)
                }

                Spacer()

                // Copy Button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    isCopied = true
                    appState.showToast("Copied \(language) code to clipboard")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5))
                        Text(isCopied ? "Copied" : "Copy Code")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(isCopied ? .green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(hex: "#1E1E2E"))

            Divider().background(Color.white.opacity(0.08))

            // Code Content
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(hex: "#CDD6F4"))
                    .padding(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: "#181825"))
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

public struct MarkdownRichContentView: View {
    let content: String
    @ObservedObject var appState: AppState

    public var body: some View {
        let segments = MarkdownCodeParser.parse(markdown: content)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                switch segment {
                case .text(let text, _):
                    Text(LocalizedStringKey(text))
                        .font(.system(size: 13.5))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                case .code(let code, let lang, _):
                    FormattedCodeBlockView(code: code, language: lang, appState: appState)
                }
            }
        }
    }
}
