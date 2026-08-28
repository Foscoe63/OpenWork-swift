import SwiftUI

public struct SubAgentExecutionCardView: View {
    let task: SubAgentTask
    @State private var isExpanded: Bool = false

    public init(task: SubAgentTask) {
        self.task = task
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: task.subAgentAvatar)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: task.status.colorHex))

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(task.subAgentName)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.primary)

                            Text(task.status.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color(hex: task.status.colorHex).opacity(0.15))
                                .foregroundColor(Color(hex: task.status.colorHex))
                                .cornerRadius(4)
                        }

                        Text(task.taskTitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if task.tokensUsed > 0 {
                        Text("\(task.tokensUsed) tok")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: task.status.colorHex).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: task.status.colorHex).opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.taskDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)

                    if !task.resultSummary.isEmpty {
                        Text(task.resultSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            }
        }
    }
}
