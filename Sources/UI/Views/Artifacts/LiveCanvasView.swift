import SwiftUI
import WebKit
import AppKit

/// Native WebKit wrapper for live interactive rendering of HTML5, React builds, SVGs, charts, and Mermaid diagrams
public struct InteractiveLiveWebView: NSViewRepresentable {
    public let htmlContent: String
    public let baseURL: URL?

    public init(htmlContent: String, baseURL: URL? = nil) {
        self.htmlContent = htmlContent
        self.baseURL = baseURL
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(htmlContent, baseURL: baseURL)
    }
}

public struct LiveArtifactWorkbenchView: View {
    @ObservedObject var appState: AppState
    let fileName: String
    let content: String

    @State private var previewMode: PreviewMode = .auto
    @State private var isInteractiveConsoleOpen: Bool = false

    public enum PreviewMode: String, CaseIterable, Identifiable {
        case auto = "Auto Detect"
        case liveWeb = "Live Web App"
        case markdown = "Rendered Doc"
        case codeEditor = "Raw Source"

        public var id: String { rawValue }
    }

    private var isWebRenderable: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["html", "htm", "svg", "jsx", "tsx", "js", "vue", "canvas"].contains(ext) || content.contains("<!DOCTYPE html>") || content.contains("<html") || content.contains("<svg")
    }

    private var isMarkdown: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["md", "markdown", "txt"].contains(ext)
    }

    private var synthesizedHtml: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<html") || trimmed.hasPrefix("<!DOCTYPE html>") {
            return content
        } else if trimmed.hasPrefix("<svg") {
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>
            body { margin: 0; padding: 40px; display: flex; justify-content: center; align-items: center; min-height: 80vh; background: #0e0e16; }
            svg { max-width: 95%; height: auto; filter: drop-shadow(0 10px 20px rgba(0,0,0,0.5)); }
            </style>
            </head>
            <body>
            \(content)
            </body>
            </html>
            """
        } else {
            // Embed in interactive Tailwind / Babel / Chart.js environment
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <script src="https://cdn.tailwindcss.com"></script>
            <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #11111b; color: #cdd6f4; margin: 0; padding: 24px; }
            pre { background: #181825; padding: 16px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); overflow-x: auto; }
            </style>
            </head>
            <body>
            <div class="max-w-4xl mx-auto">
                <div class="mb-4 flex items-center justify-between border-b border-gray-800 pb-3">
                    <span class="text-xs font-mono text-purple-400 font-bold">⚡ Live Agent Canvas: \(fileName)</span>
                    <span class="text-xs text-gray-500 font-mono">Dynamic Preview</span>
                </div>
                <div id="root">\(content)</div>
            </div>
            </body>
            </html>
            """
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Mode Toolbar
            HStack(spacing: 12) {
                Picker("", selection: $previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)

                Spacer()

                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Live Preview")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .cornerRadius(12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme).opacity(0.7))

            Divider()

            // Viewport
            switch effectiveMode {
            case .liveWeb:
                InteractiveLiveWebView(
                    htmlContent: synthesizedHtml,
                    baseURL: URL(fileURLWithPath: appState.currentWorkspace.folderPath)
                )
            case .markdown:
                ScrollView {
                    MarkdownRichContentView(content: content, appState: appState)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(ThemeColors.bg(for: appState.settings.theme))
            case .codeEditor, .auto:
                Text("Render mode selected")
            }
        }
    }

    private var effectiveMode: PreviewMode {
        if previewMode != .auto { return previewMode }
        if isWebRenderable { return .liveWeb }
        if isMarkdown { return .markdown }
        return .codeEditor
    }
}
