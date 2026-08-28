import SwiftUI

public struct PlanApprovalCardView: View {
    @ObservedObject var appState: AppState
    let proposedPlanText: String
    @State private var isApproved: Bool = false
    @State private var isRejected: Bool = false

    public init(appState: AppState, proposedPlanText: String) {
        self.appState = appState
        self.proposedPlanText = proposedPlanText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.clipboard.fill")
                    .foregroundColor(.orange)
                Text("Autonomous Agent Execution Plan")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Spacer()

                if isApproved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Plan Approved")
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.green)
                } else if isRejected {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Plan Rejected")
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.red)
                }
            }

            Text("Review proposed file modifications and autonomous tool steps before execution:")
                .font(.system(size: 10.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

            VStack(alignment: .leading, spacing: 4) {
                Text(proposedPlanText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThemeColors.bg(for: appState.settings.theme))
                    .cornerRadius(6)
            }

            if !isApproved && !isRejected {
                HStack(spacing: 8) {
                    Button {
                        isRejected = true
                        appState.showToast("Plan rejected. Agent instructed to halt.")
                    } label: {
                        Text("Reject / Edit")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        isApproved = true
                        appState.showToast("Plan approved. Executing tool pipeline.")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Approve & Execute Plan")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}
