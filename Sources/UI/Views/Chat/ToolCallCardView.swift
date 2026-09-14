import SwiftUI

public struct ToolCallCardView: View {
    let toolCall: ToolCallInfo
    let preferExpanded: Bool
    @State private var isExpanded: Bool

    public init(toolCall: ToolCallInfo, preferExpanded: Bool = false) {
        self.toolCall = toolCall
        self.preferExpanded = preferExpanded
        let needsApproval = toolCall.status == .waitingApproval || toolCall.status == .pendingApproval
        _isExpanded = State(initialValue: preferExpanded || needsApproval)
    }

    private var needsApproval: Bool {
        toolCall.status == .waitingApproval || toolCall.status == .pendingApproval
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolCall.status.icon)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)

                    Text(toolCall.toolName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)

                    Text("(\(toolCall.argumentsJson))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(needsApproval ? 3 : 1)

                    Spacer()

                    if toolCall.durationMs > 0 {
                        Text("\(Int(toolCall.durationMs))ms")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    if !needsApproval {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            if needsApproval {
                approvalPrompt
            }

            if isExpanded, let output = toolCall.resultOutput {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
            }
        }
    }

    private var approvalPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = toolCall.approvalReason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    ToolApprovalManager.shared.resolve(callId: toolCall.id, approved: true)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    ToolApprovalManager.shared.resolve(callId: toolCall.id, approved: false)
                } label: {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .running, .waitingApproval, .pendingApproval: return .orange
        case .success, .completed: return .green
        case .error, .failed: return .red
        }
    }
}
