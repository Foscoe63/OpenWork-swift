import SwiftUI
import AppKit

public enum DiffLineKind {
    case unchanged
    case added
    case deleted
}

public struct DiffLine: Identifiable {
    public let id = UUID()
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String
    public let kind: DiffLineKind
}

public struct VisualDiffInspectorView: View {
    @ObservedObject var appState: AppState
    let filePath: String
    let originalText: String
    let modifiedText: String
    let onAccept: () -> Void
    let onReject: () -> Void

    @State private var viewMode: DiffViewMode = .split

    public enum DiffViewMode: String, CaseIterable, Identifiable {
        case split = "Side-by-Side"
        case unified = "Unified Diff"

        public var id: String { rawValue }
    }

    public init(
        appState: AppState,
        filePath: String,
        originalText: String,
        modifiedText: String,
        onAccept: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        self.appState = appState
        self.filePath = filePath
        self.originalText = originalText
        self.modifiedText = modifiedText
        self.onAccept = onAccept
        self.onReject = onReject
    }

    private var diffLines: [DiffLine] {
        computeDiff(old: originalText, new: modifiedText)
    }

    private var additionsCount: Int {
        diffLines.filter { $0.kind == .added }.count
    }

    private var deletionsCount: Int {
        diffLines.filter { $0.kind == .deleted }.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Text(filePath)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                    HStack(spacing: 4) {
                        Text("+\(additionsCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.green)
                        Text("-\(deletionsCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                }

                Spacer()

                // Split / Unified toggle
                Picker("", selection: $viewMode) {
                    ForEach(DiffViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                // Action Buttons
                Button("Reject Changes", role: .destructive) {
                    onReject()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Apply & Save Changes") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            // Diff Scroll Area
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { line in
                        diffLineRow(line: line)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: "#11111B"))
        }
    }

    @ViewBuilder
    private func diffLineRow(line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // Line numbers
            HStack(spacing: 4) {
                Text(line.oldLineNumber != nil ? "\(line.oldLineNumber!)" : "")
                    .frame(width: 32, alignment: .trailing)
                    .foregroundColor(.secondary.opacity(0.6))
                Text(line.newLineNumber != nil ? "\(line.newLineNumber!)" : "")
                    .frame(width: 32, alignment: .trailing)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 6)

            // Indicator
            Text(line.kind == .added ? "+" : (line.kind == .deleted ? "-" : " "))
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundColor(line.kind == .added ? .green : (line.kind == .deleted ? .red : .secondary))
                .frame(width: 16)

            // Text content
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(line.kind == .added ? Color(hex: "#A6E3A1") : (line.kind == .deleted ? Color(hex: "#F38BA8") : Color(hex: "#CDD6F4")))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 4)
        .background(
            line.kind == .added ? Color.green.opacity(0.12) :
            (line.kind == .deleted ? Color.red.opacity(0.12) : Color.clear)
        )
    }

    private func computeDiff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        var result: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            if oldIdx < oldLines.count && newIdx < newLines.count {
                if oldLines[oldIdx] == newLines[newIdx] {
                    result.append(DiffLine(
                        oldLineNumber: oldIdx + 1,
                        newLineNumber: newIdx + 1,
                        text: oldLines[oldIdx],
                        kind: .unchanged
                    ))
                    oldIdx += 1
                    newIdx += 1
                } else {
                    // Check if old line was replaced or deleted
                    result.append(DiffLine(
                        oldLineNumber: oldIdx + 1,
                        newLineNumber: nil,
                        text: oldLines[oldIdx],
                        kind: .deleted
                    ))
                    result.append(DiffLine(
                        oldLineNumber: nil,
                        newLineNumber: newIdx + 1,
                        text: newLines[newIdx],
                        kind: .added
                    ))
                    oldIdx += 1
                    newIdx += 1
                }
            } else if oldIdx < oldLines.count {
                result.append(DiffLine(
                    oldLineNumber: oldIdx + 1,
                    newLineNumber: nil,
                    text: oldLines[oldIdx],
                    kind: .deleted
                ))
                oldIdx += 1
            } else if newIdx < newLines.count {
                result.append(DiffLine(
                    oldLineNumber: nil,
                    newLineNumber: newIdx + 1,
                    text: newLines[newIdx],
                    kind: .added
                ))
                newIdx += 1
            }
        }

        return result
    }
}
