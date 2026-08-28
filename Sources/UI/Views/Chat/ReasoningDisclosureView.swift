import SwiftUI

public struct ReasoningDisclosureView: View {
    let reasoning: String
    let thinkingTimeMs: Double?
    @State private var isExpanded: Bool = false

    public init(reasoning: String, thinkingTimeMs: Double? = nil) {
        self.reasoning = reasoning
        self.thinkingTimeMs = thinkingTimeMs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)

                    let timeStr = (thinkingTimeMs != nil) ? " (\(String(format: "%.1f", (thinkingTimeMs ?? 0) / 1000))s)" : ""
                    Text("Thinking Process\(timeStr)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.purple)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(6)
                    .transition(.opacity)
            }
        }
    }
}
