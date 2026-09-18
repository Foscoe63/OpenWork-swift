import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Find in Project, above the editor.
struct ProjectSearchPanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model = ProjectSearchModel.shared
    @ObservedObject var editors = EditorWorkspace.shared
    @FocusState private var queryFocused: Bool
    @State private var confirmingReplace = false

    private var theme: AppTheme { appState.settings.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    model.showsReplace.toggle()
                } label: {
                    Image(systemName: model.showsReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 20)
                }
                .buttonStyle(.hitTestable)
                .help("Replace")

                TextField("Find in project", text: $model.options.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($queryFocused)
                    .onSubmit { model.scheduleSearch(delay: 0) }

                optionToggle("Aa", isOn: $model.options.caseSensitive, help: "Match case")
                optionToggle("W", isOn: $model.options.wholeWord, help: "Whole word")
                optionToggle(".*", isOn: $model.options.isRegex, help: "Regular expression")
                Button {
                    model.showsFilters.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(model.options.include.isEmpty && model.options.exclude.isEmpty ? .secondary : ThemeColors.accent(for: appState.settings.accentColor))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.hitTestable)
                .help("Files to include or exclude")
                Button {
                    editors.isSearchVisible = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 20)
                }
                .buttonStyle(.hitTestable)
                .help("Close search")
            }

            if model.showsReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 14)
                    TextField(model.options.isRegex ? "Replace ($1 for groups)" : "Replace", text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Replace All") { confirmingReplace = true }
                        .controlSize(.small)
                        .disabled(model.result.totalMatches == 0)
                }
            }

            if model.showsFilters {
                HStack(spacing: 6) {
                    Spacer().frame(width: 14)
                    TextField("Include: *.swift, Sources/", text: $model.options.include)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    TextField("Exclude: *.test.js, docs/", text: $model.options.exclude)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            summary
                .padding(.leading, 20)

            results
        }
        .padding(8)
        .background(ThemeColors.sidebarBg(for: theme))
        .onAppear {
            model.root = appState.currentWorkspace.folderPath
            queryFocused = true
        }
        .onChange(of: appState.currentWorkspace.folderPath) { _, root in model.root = root }
        .onChange(of: editors.searchFocusRequest) { _, _ in queryFocused = true }
        .confirmationDialog(
            "Replace \(model.result.totalMatches) matches in \(model.result.files.count) files?",
            isPresented: $confirmingReplace
        ) {
            Button("Replace All") { runReplace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each file opens in the editor with the change unsaved, so you can review it, undo it, and save with Save All (⌥⌘S). Nothing is written to disk yet.")
        }
    }

    private func optionToggle(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .frame(width: 24, height: 20)
                .background(isOn.wrappedValue ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.25) : Color.clear)
                .foregroundColor(isOn.wrappedValue ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)
                .cornerRadius(4)
        }
        .buttonStyle(.hitTestable)
        .help(help)
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: 6) {
            if model.isSearching {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
            } else if !model.options.query.isEmpty {
                Text(model.result.totalMatches == 0
                     ? "No results in \(model.result.filesSearched) files"
                     : "\(model.result.totalMatches) result\(model.result.totalMatches == 1 ? "" : "s") in \(model.result.files.count) file\(model.result.files.count == 1 ? "" : "s")")
                if model.result.truncated {
                    Text("— showing the first \(ProjectSearch.matchLimit); narrow the search")
                        .foregroundColor(.orange)
                }
            }
            Spacer()
        }
        .font(.system(size: 10.5))
        .foregroundColor(ThemeColors.textSecondary(for: theme))
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.result.files) { file in
                    fileHeader(file)
                    if !model.collapsedFiles.contains(file.path) {
                        ForEach(file.matches) { match in
                            matchRow(file, match)
                        }
                    }
                }
            }
        }
    }

    private func fileHeader(_ file: ProjectSearch.FileResult) -> some View {
        Button {
            if model.collapsedFiles.contains(file.path) {
                model.collapsedFiles.remove(file.path)
            } else {
                model.collapsedFiles.insert(file.path)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.collapsedFiles.contains(file.path) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                Image(systemName: "doc.text").font(.system(size: 10))
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if file.fromOpenEditor {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .help("Searched as open in the editor, including unsaved edits")
                }
                Spacer()
                Text("\(file.matches.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .background(ThemeColors.border(for: theme))
                    .cornerRadius(6)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitTestable)
    }

    private func matchRow(_ file: ProjectSearch.FileResult, _ match: ProjectSearch.LineMatch) -> some View {
        Button {
            appState.openInEditor(
                path: (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(file.path),
                line: match.line,
                selecting: (match.column, match.length)
            )
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(match.line)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Text(highlighted(match))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.leading, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitTestable)
        .help("\(file.path):\(match.line)")
    }

    private func highlighted(_ match: ProjectSearch.LineMatch) -> AttributedString {
        let ns = match.preview as NSString
        let range = match.previewRange
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return AttributedString(match.preview) }
        var before = AttributedString(ns.substring(to: range.location))
        before.foregroundColor = ThemeColors.textSecondary(for: theme)
        var hit = AttributedString(ns.substring(with: range))
        hit.backgroundColor = ThemeColors.accent(for: appState.settings.accentColor).opacity(0.35)
        hit.foregroundColor = ThemeColors.textPrimary(for: theme)
        var after = AttributedString(ns.substring(from: NSMaxRange(range)))
        after.foregroundColor = ThemeColors.textSecondary(for: theme)
        return before + hit + after
    }

    private func runReplace() {
        switch model.replaceAll(workspaceRoot: appState.currentWorkspace.folderPath) {
        case .replaced(let matches, let files, let skipped):
            let note = skipped.isEmpty ? "" : " — \(skipped.count) file(s) could not be opened"
            appState.showToast("Replaced \(matches) in \(files) files, unsaved\(note)")
        case .tooManyFiles(let count):
            appState.showToast("\(count) files match — narrow the search to \(ProjectSearchModel.replaceFileLimit) or fewer to replace")
        case .failed(let reason):
            appState.showToast(reason)
        }
    }
}
