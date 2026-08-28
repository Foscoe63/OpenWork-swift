import SwiftUI
import AppKit

public struct ComposerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var voiceEngine = VoiceSpeechEngine.shared
    @State private var attachments: [MessageAttachment] = []
    @State private var showingSlashCommands = false

    private var matchingPromptTemplates: [PromptTemplate] {
        let trimmed = appState.composerText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let query = String(trimmed.dropFirst()).lowercased()
        if query.isEmpty {
            return PromptCatalog.sharedTemplates
        }
        return PromptCatalog.sharedTemplates.filter {
            $0.command.lowercased().contains(query) ||
            $0.title.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Slash Command Autocomplete Popover / Overlay
            if !matchingPromptTemplates.isEmpty && appState.composerText.hasPrefix("/") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text("PROMPT TEMPLATES & SLASH COMMANDS")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matchingPromptTemplates) { template in
                                Button {
                                    appState.composerText = template.prompt
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: template.category.icon)
                                            .font(.system(size: 11))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                            .frame(width: 18)

                                        Text(template.command)
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

                                        Text(template.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                        Spacer()

                                        Text(template.category.rawValue)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.06))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 180)
                }
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 6, y: -2)
                .padding(.horizontal, 16)
            }

            // Attachments Preview Row
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { att in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 10))
                                Text(att.name)
                                    .font(.system(size: 11))
                                Button {
                                    attachments.removeAll(where: { $0.id == att.id })
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            // Input Box
            HStack(alignment: .bottom, spacing: 8) {
                // Attach File Button
                Button {
                    chooseFileAttachment()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .frame(width: 28, height: 28)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Attach file from workspace")

                // Voice Dictation Button
                Button {
                    voiceEngine.toggleDictation { spokenText in
                        appState.composerText = spokenText
                    }
                } label: {
                    Image(systemName: voiceEngine.isRecording ? "waveform.circle.fill" : "mic.fill")
                        .font(.system(size: 14))
                        .foregroundColor(voiceEngine.isRecording ? .red : ThemeColors.textSecondary(for: appState.settings.theme))
                        .frame(width: 28, height: 28)
                        .background(voiceEngine.isRecording ? Color.red.opacity(0.15) : ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(voiceEngine.isRecording ? "Stop Dictation" : "Dictate with Voice (macOS STT)")

                // Text Input Field
                ZStack(alignment: .topLeading) {
                    if appState.composerText.isEmpty {
                        Text("Type a prompt, or / for slash commands...")
                            .font(.system(size: 13))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }

                    TextEditor(text: $appState.composerText)
                        .font(.system(size: 13))
                        .frame(minHeight: 36, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }

                // Send or Stop Button
                if appState.isGenerating {
                    Button {
                        appState.isGenerating = false
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop Generation")
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(appState.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.4) : ThemeColors.accent(for: appState.settings.accentColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send Message (Return)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
            )
            .cornerRadius(10)

            // Bottom Sub-Bar: Quick Controls (Agent pill, Model selector, reasoning toggle)
            HStack(spacing: 8) {
                // Agent Picker Pill
                Menu {
                    ForEach(appState.agents) { ag in
                        Button {
                            appState.selectedAgentId = ag.id
                        } label: {
                            HStack {
                                Image(systemName: ag.avatar)
                                Text(ag.name)
                                if ag.id == appState.selectedAgentId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.currentAgent.avatar)
                            .font(.system(size: 10))
                        Text(appState.currentAgent.name)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)

                // Model Picker Pill
                Menu {
                    ForEach(appState.providers.filter { $0.isEnabled }) { prov in
                        Section(prov.name) {
                            ForEach(prov.models) { m in
                                Button {
                                    appState.selectedProviderId = prov.id
                                    appState.selectedModelId = m.id
                                } label: {
                                    HStack {
                                        Text(m.name)
                                        if m.supportsReasoning {
                                            Text("🧠")
                                        }
                                        if m.id == appState.selectedModelId && prov.id == appState.selectedProviderId {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.currentProvider.kind.icon)
                            .font(.system(size: 10))
                        Text(appState.currentModel.name)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)

                // Reasoning Effort Switch
                Button {
                    appState.isReasoningEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.system(size: 10))
                        Text(appState.isReasoningEnabled ? "Reasoning: On" : "Reasoning: Off")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(appState.isReasoningEnabled ? Color.purple.opacity(0.2) : Color.clear)
                    .foregroundColor(appState.isReasoningEnabled ? Color.purple : ThemeColors.textSecondary(for: appState.settings.theme))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("OpenWork-Swift Standalone")
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func sendMessage() {
        let text = appState.composerText
        let atts = attachments
        attachments.removeAll()
        appState.sendMessage(text: text, attachments: atts)
    }

    private func chooseFileAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                let name = url.lastPathComponent
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let preview = try? String(contentsOf: url, encoding: .utf8)
                let att = MessageAttachment(name: name, path: url.path, sizeBytes: size, previewText: preview)
                attachments.append(att)
            }
        }
    }
}
