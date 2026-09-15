import SwiftUI
import AppKit

public struct ReasoningDisclosureView: View {
    let reasoning: String
    let thinkingTimeMs: Double?
    @State private var didCopy: Bool = false
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        // The thinking text had no way out of the app at all: not selectable,
                        // no copy button. When a turn spirals — 12,000 characters over three
                        // minutes — this panel holds the only evidence of what happened, and it
                        // could not be got at to report or diagnose.
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reasoning, forType: .string)
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                Text(didCopy ? "Copied" : "Copy")
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy the full thinking process")
                    }

                    Text(reasoning)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
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
