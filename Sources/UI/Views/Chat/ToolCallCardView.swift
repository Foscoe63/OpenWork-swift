import SwiftUI

public struct ToolCallCardView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded: Bool = false

    public init(toolCall: ToolCallInfo) {
        self.toolCall = toolCall
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
                        .lineLimit(1)

                    Spacer()

                    if toolCall.durationMs > 0 {
                        Text("\(Int(toolCall.durationMs))ms")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

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

    private var statusColor: Color {
        switch toolCall.status {
        case .running, .waitingApproval: return .orange
        case .success: return .green
        case .error: return .red
        }
    }
}
