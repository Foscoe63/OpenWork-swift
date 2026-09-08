import SwiftUI
import AppKit

public struct AutomationsView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddModal = false
    @State private var showingVisualBuilder = false
    @State private var editingAutomation: Automation? = nil
    @State private var historyAutomation: Automation? = nil

    /// Grows column count as the panel widens (card min width ~300pt).
    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)]
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            ScrollView {
                if appState.automations.isEmpty {
                    emptyState
                        .padding(24)
                } else {
                    LazyVGrid(columns: adaptiveColumns, spacing: 20) {
                        ForEach(appState.automations) { auto in
                            AutomationCardView(
                                appState: appState,
                                automation: auto,
                                onEdit: { editingAutomation = auto },
                                onRunNow: { runAutomation(auto) },
                                onShowHistory: { historyAutomation = auto },
                                onExportSummary: { exportSummary(for: auto) },
                                onToggle: { enabled in
                                    setEnabled(auto, enabled: enabled)
                                },
                                onDelete: { deleteAutomation(auto) },
                                onSynthesizeArtifact: {
                                    appState.createArtifactFromAutomation(auto)
                                }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddModal) {
            AutomationEditorSheet(
                appState: appState,
                mode: .create,
                isPresented: $showingAddModal
            )
        }
        .sheet(item: $editingAutomation) { auto in
            AutomationEditorSheet(
                appState: appState,
                mode: .edit(auto),
                isPresented: Binding(
                    get: { editingAutomation != nil },
                    set: { if !$0 { editingAutomation = nil } }
                )
            )
        }
        .sheet(item: $historyAutomation) { auto in
            AutomationHistorySheet(appState: appState, automation: auto) {
                historyAutomation = nil
            }
        }
        .sheet(isPresented: $showingVisualBuilder) {
            VisualAgentFlowBuilderView(appState: appState, isPresented: $showingVisualBuilder)
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Schedules")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("\(appState.automations.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(ThemeColors.border(for: appState.settings.theme).opacity(0.7))
                        )
                }
                Text("Automate recurring AI tasks with custom schedules")
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Button {
                appState.automations = PersistenceManager.shared.loadAutomations()
                appState.showToast("Schedules refreshed")
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())

            Button {
                showingVisualBuilder = true
            } label: {
                Label("Visual Flow", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)

            Button {
                showingAddModal = true
            } label: {
                Label("Create Schedule", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No schedules yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
            Text("Create a schedule to run recurring agent tasks automatically.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingAddModal = true
            } label: {
                Label("Create Schedule", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func runAutomation(_ auto: Automation) {
        appState.showToast("Triggered: \(auto.name)")
        appState.createNewSession(agentId: auto.targetAgentId)
        appState.sendMessage(text: auto.promptTemplate)
        if let idx = appState.automations.firstIndex(where: { $0.id == auto.id }) {
            appState.automations[idx].lastRunAt = Date()
            appState.automations[idx].lastStatus = "Completed"
            appState.automations[idx].updatedAt = Date()
            PersistenceManager.shared.saveAutomations(appState.automations)
        }
    }

    private func setEnabled(_ auto: Automation, enabled: Bool) {
        guard let idx = appState.automations.firstIndex(where: { $0.id == auto.id }) else { return }
        appState.automations[idx].isEnabled = enabled
        appState.automations[idx].updatedAt = Date()
        PersistenceManager.shared.saveAutomations(appState.automations)
        appState.showToast(enabled ? "Schedule resumed" : "Schedule paused")
    }

    private func deleteAutomation(_ auto: Automation) {
        appState.automations.removeAll(where: { $0.id == auto.id })
        PersistenceManager.shared.saveAutomations(appState.automations)
        appState.showToast("Schedule deleted")
    }

    private func exportSummary(for auto: Automation) {
        let agentName = appState.agents.first(where: { $0.id == auto.targetAgentId })?.name ?? auto.targetAgentId
        let text = """
        # \(auto.name)

        - Status: \(auto.isEnabled ? "Enabled" : "Paused")
        - Schedule: \(auto.cronSchedule)
        - Trigger: \(auto.triggerType.displayName)
        - Agent: \(agentName)
        - Last run: \(auto.lastRunAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Never")
        - Last status: \(auto.lastStatus ?? "—")

        ## Instructions
        \(auto.promptTemplate)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.showToast("Schedule summary copied")
    }
}

// MARK: - Automation Card (Osaurus-style)

private struct AutomationCardView: View {
    @ObservedObject var appState: AppState
    let automation: Automation
    let onEdit: () -> Void
    let onRunNow: () -> Void
    let onShowHistory: () -> Void
    let onExportSummary: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onSynthesizeArtifact: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var agentName: String {
        appState.agents.first(where: { $0.id == automation.targetAgentId })?.name ?? "Assistant"
    }

    private var scheduleColor: Color {
        let hue = Double(abs(automation.name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    private var accent: Color {
        ThemeColors.accent(for: appState.settings.accentColor)
    }

    private var isRunning: Bool {
        (automation.lastStatus ?? "").lowercased().contains("running")
    }

    private var lastError: String? {
        if let status = automation.lastStatus?.lowercased(),
           status.contains("error") || status.contains("fail") || status.contains("cannot") {
            return automation.lastResultSummary ?? automation.lastStatus
        }
        if let summary = automation.lastResultSummary,
           summary.lowercased().contains("error")
            || summary.lowercased().contains("cannot")
            || summary.lowercased().contains("fail") {
            return summary
        }
        return nil
    }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                if !automation.promptTemplate.isEmpty {
                    Text(automation.promptTemplate)
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                nextRunRow

                if let lastError {
                    errorRow(lastError)
                }

                Spacer(minLength: 0)

                compactStats
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(ThemeColors.cardBg(for: appState.settings.theme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [
                                scheduleColor.opacity(isHovered ? 0.06 : 0),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered
                            ? scheduleColor.opacity(0.25)
                            : ThemeColors.border(for: appState.settings.theme),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .alert("Delete Schedule", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(automation.name)\"? This action cannot be undone.")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if isRunning {
                    Circle()
                        .fill(accent.opacity(0.2))
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [scheduleColor.opacity(0.15), scheduleColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Circle()
                        .strokeBorder(scheduleColor.opacity(0.4), lineWidth: 2)
                    Text(automation.name.prefix(1).uppercased())
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(scheduleColor)
                }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(automation.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)
                    statusBadge
                }
                Text(automation.cronSchedule.isEmpty ? automation.triggerType.displayName : automation.cronSchedule)
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: onRunNow) {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(isRunning)
                Button(action: onShowHistory) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button(action: onExportSummary) {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button(action: onSynthesizeArtifact) {
                    Label("Synthesize Artifact", systemImage: "sparkles")
                }
                Divider()
                Button {
                    onToggle(!automation.isEnabled)
                } label: {
                    Label(
                        automation.isEnabled ? "Pause" : "Resume",
                        systemImage: automation.isEnabled ? "pause.circle" : "play.circle"
                    )
                }
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(ThemeColors.border(for: appState.settings.theme).opacity(0.55))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isRunning {
            badgeLabel("Running", color: accent)
        } else if automation.isEnabled {
            badgeLabel("Enabled", color: Color(red: 0.25, green: 0.75, blue: 0.45))
        } else {
            badgeLabel("Paused", color: .orange)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var nextRunRow: some View {
        let preview = AutomationSchedulePreview.make(from: automation)
        return HStack(spacing: 8) {
            Image(systemName: preview.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(preview.color)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text("Next run")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.85))
                Text(preview.description)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(preview.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(preview.color.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.red)
                .frame(width: 14)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var compactStats: some View {
        HStack(spacing: 0) {
            statItem(icon: automation.triggerType.icon, text: AutomationSchedulePreview.shortFrequency(automation.cronSchedule))

            if let status = automation.lastStatus, !status.isEmpty {
                statDot
                statItem(icon: statusIcon(for: status), text: status)
            } else if automation.lastRunAt != nil {
                statDot
                statItem(icon: "checkmark.circle", text: "Completed")
            }

            statDot
            statItem(icon: "person.fill", text: agentName)

            Spacer(minLength: 0)
        }
    }

    private func statusIcon(for status: String) -> String {
        let lower = status.lowercased()
        if lower.contains("fail") || lower.contains("error") { return "xmark.circle" }
        if lower.contains("run") { return "arrow.triangle.2.circlepath" }
        return "checkmark.circle"
    }

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
    }

    private var statDot: some View {
        Circle()
            .fill(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.4))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
    }
}

// MARK: - Next-run helpers

private struct AutomationSchedulePreview {
    let description: String
    let icon: String
    let color: Color

    static func make(from automation: Automation) -> AutomationSchedulePreview {
        if !automation.isEnabled {
            return AutomationSchedulePreview(
                description: "Paused",
                icon: "pause.circle",
                color: .orange
            )
        }
        if automation.triggerType == .manual {
            return AutomationSchedulePreview(
                description: "Manual only",
                icon: "hand.tap",
                color: .secondary
            )
        }
        let next = nextRunDescription(for: automation.cronSchedule)
        return AutomationSchedulePreview(
            description: next,
            icon: "clock",
            color: Color(red: 0.55, green: 0.35, blue: 0.95)
        )
    }

    static func shortFrequency(_ schedule: String) -> String {
        let lower = schedule.lowercased()
        if lower.contains("daily") { return "Daily" }
        if lower.contains("weekly") { return "Weekly" }
        if lower.contains("hourly") || lower.contains("hour") { return "Hourly" }
        if lower.contains("month") { return "Monthly" }
        if lower.contains("minute") { return "Minutes" }
        if lower.contains("cron") { return "Cron" }
        if schedule.isEmpty { return "Manual" }
        return String(schedule.prefix(12))
    }

    static func nextRunDescription(for schedule: String) -> String {
        let lower = schedule.lowercased()
        let calendar = Calendar.current
        let now = Date()

        if let time = extractTime(from: schedule), lower.contains("daily") {
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = time.hour
            components.minute = time.minute
            guard var candidate = calendar.date(from: components) else {
                return schedule
            }
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            if calendar.isDateInTomorrow(candidate) {
                return "Tomorrow at \(formatTime(time.hour, time.minute))"
            }
            if calendar.isDateInToday(candidate) {
                return "Today at \(formatTime(time.hour, time.minute))"
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE 'at' h:mm a"
            return formatter.string(from: candidate)
        }

        if lower.contains("hourly") || lower.contains("every hour") {
            return "Within the next hour"
        }
        if lower.contains("every") && lower.contains("min") {
            return "Soon (\(schedule))"
        }
        return schedule.isEmpty ? "Not scheduled" : schedule
    }

    private static func extractTime(from schedule: String) -> (hour: Int, minute: Int)? {
        // Matches "6:00 AM", "18:30", "9am"
        let pattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let ns = schedule as NSString
        guard let match = regex.firstMatch(in: schedule, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        var hour = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let minute: Int = {
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                return Int(ns.substring(with: match.range(at: 2))) ?? 0
            }
            return 0
        }()
        if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound {
            let meridiem = ns.substring(with: match.range(at: 3)).lowercased()
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }
        return (hour, minute)
    }

    private static func formatTime(_ hour: Int, _ minute: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Editor Sheet (Create / Edit)

public enum AutomationEditorMode {
    case create
    case edit(Automation)
}

public struct AutomationEditorSheet: View {
    @ObservedObject var appState: AppState
    let mode: AutomationEditorMode
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var triggerType: AutomationTriggerType = .scheduled
    @State private var schedule: String = "Daily at 9:00 AM"
    @State private var targetAgentId: String = "lead-assistant"
    @State private var promptTemplate: String = "Scan workspace files and provide a status update."
    @State private var isEnabled: Bool = true
    @State private var editingId: String? = nil

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(titleText)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Schedule Info")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. MorningBrief", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Enabled", isOn: $isEnabled)
                        .font(.system(size: 12))

                    sectionLabel("Trigger")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trigger Type")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $triggerType) {
                            ForEach(AutomationTriggerType.allCases, id: \.self) { t in
                                HStack {
                                    Image(systemName: t.icon)
                                    Text(t.displayName)
                                }
                                .tag(t)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Frequency / Schedule")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. Daily at 6:00 AM", text: $schedule)
                            .textFieldStyle(.roundedBorder)
                        Text("Examples: Daily at 6:00 AM · Every 2 hours · Weekly on Monday")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    sectionLabel("Agent")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Assigned Agent")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $targetAgentId) {
                            ForEach(appState.agents) { ag in
                                Text(ag.name).tag(ag.id)
                            }
                        }
                    }

                    sectionLabel("Instructions")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt / Step-by-step Instructions")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextEditor(text: $promptTemplate)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(minHeight: 140)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description (optional)")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("Short note for this schedule", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(saveButtonTitle) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 680)
        .background(ThemeColors.bg(for: appState.settings.theme))
        .onAppear(perform: loadInitialValues)
    }

    private var titleText: String {
        switch mode {
        case .create: return "Create Schedule"
        case .edit: return "Edit Schedule"
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .create: return "Save Schedule"
        case .edit: return "Save Changes"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.top, 4)
    }

    private func loadInitialValues() {
        switch mode {
        case .create:
            if let first = appState.agents.first {
                targetAgentId = first.id
            }
        case .edit(let auto):
            editingId = auto.id
            name = auto.name
            description = auto.description
            triggerType = auto.triggerType
            schedule = auto.cronSchedule
            targetAgentId = auto.targetAgentId
            promptTemplate = auto.promptTemplate
            isEnabled = auto.isEnabled
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .create:
            let auto = Automation(
                workspaceId: appState.activeWorkspaceId,
                name: trimmed,
                description: description,
                triggerType: triggerType,
                cronSchedule: schedule,
                targetAgentId: targetAgentId,
                promptTemplate: promptTemplate,
                isEnabled: isEnabled
            )
            appState.automations.append(auto)
            PersistenceManager.shared.saveAutomations(appState.automations)
            appState.showToast("Schedule '\(trimmed)' created")
        case .edit(let existing):
            guard let idx = appState.automations.firstIndex(where: { $0.id == existing.id }) else { return }
            appState.automations[idx].name = trimmed
            appState.automations[idx].description = description
            appState.automations[idx].triggerType = triggerType
            appState.automations[idx].cronSchedule = schedule
            appState.automations[idx].targetAgentId = targetAgentId
            appState.automations[idx].promptTemplate = promptTemplate
            appState.automations[idx].isEnabled = isEnabled
            appState.automations[idx].updatedAt = Date()
            PersistenceManager.shared.saveAutomations(appState.automations)
            appState.showToast("Schedule '\(trimmed)' updated")
        }

        isPresented = false
    }
}

/// Backward-compatible alias used by older call sites.
public struct NewAutomationModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    public var body: some View {
        AutomationEditorSheet(appState: appState, mode: .create, isPresented: $isPresented)
    }
}

// MARK: - History Sheet

private struct AutomationHistorySheet: View {
    @ObservedObject var appState: AppState
    let automation: Automation
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History — \(automation.name)")
                        .font(.system(size: 14, weight: .bold))
                    Text(automation.cronSchedule)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    historyRow(
                        title: "Status",
                        value: automation.isEnabled ? "Enabled" : "Paused"
                    )
                    historyRow(
                        title: "Last run",
                        value: automation.lastRunAt.map {
                            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
                        } ?? "Never"
                    )
                    historyRow(
                        title: "Last status",
                        value: automation.lastStatus ?? "—"
                    )
                    historyRow(
                        title: "Last result",
                        value: automation.lastResultSummary ?? "No result recorded yet."
                    )
                    historyRow(
                        title: "Created",
                        value: DateFormatter.localizedString(from: automation.createdAt, dateStyle: .medium, timeStyle: .short)
                    )
                    historyRow(
                        title: "Updated",
                        value: DateFormatter.localizedString(from: automation.updatedAt, dateStyle: .medium, timeStyle: .short)
                    )
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    private func historyRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemeColors.cardBg(for: appState.settings.theme))
                )
        }
    }
}
