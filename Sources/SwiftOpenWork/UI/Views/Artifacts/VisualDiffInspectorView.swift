import SwiftUI
import AppKit
import SwiftOpenWorkCore

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
    /// nil when there is nothing to apply, which is the case wherever the change is already on
    /// disk. An always-present "Apply & Save" that saves nothing teaches people to distrust it.
    let onAccept: (() -> Void)?
    let acceptTitle: String
    let onReject: () -> Void
    let rejectTitle: String

    @AppStorage("diffViewMode") private var viewModeRaw: String = DiffViewMode.split.rawValue

    private var viewMode: DiffViewMode {
        DiffViewMode(rawValue: viewModeRaw) ?? .split
    }

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
        onAccept: (() -> Void)? = nil,
        acceptTitle: String = "Apply & Save Changes",
        onReject: @escaping () -> Void,
        rejectTitle: String = "Reject Changes"
    ) {
        self.appState = appState
        self.filePath = filePath
        self.originalText = originalText
        self.modifiedText = modifiedText
        self.onAccept = onAccept
        self.acceptTitle = acceptTitle
        self.onReject = onReject
        self.rejectTitle = rejectTitle
    }

    private var diffLines: [DiffLine] {
        computeDiff(old: originalText, new: modifiedText)
    }

    /// Both sides padded to line up, so an insertion on one side leaves a gap on the other rather
    /// than shunting every later line out of step with its counterpart.
    private var alignedRows: [(id: Int, left: DiffLine?, right: DiffLine?)] {
        var rows: [(Int, DiffLine?, DiffLine?)] = []
        var index = 0
        var pendingRemovals: [DiffLine] = []
        var pendingAdditions: [DiffLine] = []

        func flush() {
            for offset in 0..<max(pendingRemovals.count, pendingAdditions.count) {
                rows.append((
                    index,
                    offset < pendingRemovals.count ? pendingRemovals[offset] : nil,
                    offset < pendingAdditions.count ? pendingAdditions[offset] : nil
                ))
                index += 1
            }
            pendingRemovals.removeAll()
            pendingAdditions.removeAll()
        }

        for line in diffLines {
            switch line.kind {
            case .deleted:
                pendingRemovals.append(line)
            case .added:
                pendingAdditions.append(line)
            case .unchanged:
                flush()
                rows.append((index, line, line))
                index += 1
            }
        }
        flush()
        return rows.map { (id: $0.0, left: $0.1, right: $0.2) }
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

                // Split / Unified toggle. This drove nothing for as long as it existed: the body
                // always rendered unified, while the picker sat on "Side-by-Side" by default and
                // said so.
                Picker("", selection: $viewModeRaw) {
                    ForEach(DiffViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                // Action Buttons
                Button(rejectTitle, role: .destructive) {
                    onReject()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let onAccept {
                    Button(acceptTitle) {
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            // Diff Scroll Area
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if viewMode == .split {
                        splitBody
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(diffLines) { line in
                                diffLineRow(line: line)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: "#11111B"))
        }
    }

    private var splitBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(alignedRows, id: \.id) { row in
                HStack(spacing: 0) {
                    splitPane(row.left, isOriginal: true)
                    Divider()
                    splitPane(row.right, isOriginal: false)
                }
            }
        }
    }

    @ViewBuilder
    private func splitPane(_ line: DiffLine?, isOriginal: Bool) -> some View {
        let number = isOriginal ? line?.oldLineNumber : line?.newLineNumber
        HStack(spacing: 6) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .frame(width: 36, alignment: .trailing)
            Text(line?.text.isEmpty == false ? line!.text : " ")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(splitTint(line))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(splitBackground(line))
    }

    private func splitTint(_ line: DiffLine?) -> Color {
        switch line?.kind {
        case .added: return Color(hex: "#A6E3A1")
        case .deleted: return Color(hex: "#F38BA8")
        case .unchanged: return Color(hex: "#CDD6F4")
        case nil: return .clear
        }
    }

    /// A missing counterpart is shaded rather than left blank, so the eye can tell "nothing here"
    /// from "an empty line here".
    private func splitBackground(_ line: DiffLine?) -> Color {
        switch line?.kind {
        case .added: return Color.green.opacity(0.12)
        case .deleted: return Color.red.opacity(0.12)
        case .unchanged: return .clear
        case nil: return Color.white.opacity(0.03)
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

    /// Shares the tool cards' diff so the sheet and the card cannot disagree about a file.
    ///
    /// The version that lived here advanced both sides in lockstep whenever they differed, which
    /// pairs every line after an insertion with the wrong counterpart and reports a one-line
    /// addition as a rewrite of the rest of the file.
    private func computeDiff(old: String, new: String) -> [DiffLine] {
        InlineFileDiff.diff(
            old: old.isEmpty ? [] : old.components(separatedBy: "\n"),
            new: new.isEmpty ? [] : new.components(separatedBy: "\n")
        ).compactMap { line in
            let kind: DiffLineKind
            switch line.kind {
            case .added: kind = .added
            case .removed: kind = .deleted
            case .context: kind = .unchanged
            case .gap: return nil
            }
            return DiffLine(
                oldLineNumber: line.oldNumber,
                newLineNumber: line.newNumber,
                text: line.text,
                kind: kind
            )
        }
    }
}
