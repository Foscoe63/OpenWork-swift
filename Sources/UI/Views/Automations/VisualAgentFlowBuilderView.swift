import SwiftUI

public enum FlowNodeType: String, CaseIterable, Identifiable {
    case trigger = "Trigger Node"
    case agent = "Agent Specialist"
    case tool = "Tool Execution"
    case condition = "Decision Gate"
    case notification = "Alert / Output"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .trigger: return "bolt.circle.fill"
        case .agent: return "person.crop.circle.badge.checkmark"
        case .tool: return "wrench.and.screwdriver.fill"
        case .condition: return "arrow.triangle.branch"
        case .notification: return "bell.badge.fill"
        }
    }

    public var color: Color {
        switch self {
        case .trigger: return .orange
        case .agent: return .purple
        case .tool: return .blue
        case .condition: return .yellow
        case .notification: return .green
        }
    }
}

public struct FlowNode: Identifiable {
    public let id: UUID
    public var title: String
    public var type: FlowNodeType
    public var subtitle: String
    public var position: CGPoint

    public init(id: UUID = UUID(), title: String, type: FlowNodeType, subtitle: String, position: CGPoint) {
        self.id = id
        self.title = title
        self.type = type
        self.subtitle = subtitle
        self.position = position
    }
}

public struct VisualAgentFlowBuilderView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var nodes: [FlowNode] = [
        FlowNode(title: "Webhook / Cron Trigger", type: .trigger, subtitle: "Runs every 30 mins on commit", position: CGPoint(x: 100, y: 160)),
        FlowNode(title: "Deep Research Agent", type: .agent, subtitle: "Queries codebase via RAG", position: CGPoint(x: 340, y: 160)),
        FlowNode(title: "Senior Coder Agent", type: .agent, subtitle: "Generates patch & fixes", position: CGPoint(x: 580, y: 160)),
        FlowNode(title: "Code Review Critic", type: .agent, subtitle: "Audits diff for edge cases", position: CGPoint(x: 820, y: 160)),
        FlowNode(title: "Desktop Notification", type: .notification, subtitle: "Sends summary alert", position: CGPoint(x: 1060, y: 160))
    ]

    @State private var selectedNodeId: UUID? = nil
    @State private var isExecutingFlow: Bool = false
    @State private var executionStep: Int = 0

    public init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 16))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Text("Visual Multi-Agent Workflow Pipeline Builder")
                        .font(.system(size: 14, weight: .bold))
                }

                Spacer()

                Button {
                    addNode()
                } label: {
                    Label("Add Node", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    runWorkflowSimulation()
                } label: {
                    Label(isExecutingFlow ? "Running Flow..." : "Execute Pipeline", systemImage: isExecutingFlow ? "rays" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isExecutingFlow)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            // Interactive Flow Canvas
            ZStack {
                // Grid Background
                Color(hex: "#0F0F17")
                    .ignoresSafeArea()

                // Flow connector lines
                Canvas { context, size in
                    guard nodes.count > 1 else { return }
                    for i in 0..<(nodes.count - 1) {
                        let start = nodes[i].position
                        let end = nodes[i + 1].position

                        var path = Path()
                        path.move(to: CGPoint(x: start.x + 80, y: start.y + 40))
                        let control1 = CGPoint(x: start.x + 140, y: start.y + 40)
                        let control2 = CGPoint(x: end.x - 60, y: end.y + 40)
                        path.addCurve(to: CGPoint(x: end.x, y: end.y + 40), control1: control1, control2: control2)

                        let isActive = isExecutingFlow && (executionStep == i)
                        context.stroke(
                            path,
                            with: .color(isActive ? Color.green : Color.purple.opacity(0.6)),
                            lineWidth: isActive ? 3 : 2
                        )
                    }
                }

                // Drag-and-drop Nodes
                ForEach($nodes) { $node in
                    flowNodeCard(node: $node)
                }
            }
            .frame(minWidth: 900, minHeight: 480)
        }
    }

    @ViewBuilder
    private func flowNodeCard(node: Binding<FlowNode>) -> some View {
        let isSelected = selectedNodeId == node.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: node.type.wrappedValue.icon)
                    .foregroundColor(node.type.wrappedValue.color)
                Text(node.type.wrappedValue.rawValue)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            Text(node.title.wrappedValue)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)

            Text(node.subtitle.wrappedValue)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 170, height: 84)
        .background(Color(hex: "#1E1E2E"))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.purple : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .position(node.position.wrappedValue)
        .gesture(
            DragGesture()
                .onChanged { value in
                    node.position.wrappedValue = value.location
                }
        )
        .onTapGesture {
            selectedNodeId = node.id
        }
    }

    private func addNode() {
        let count = nodes.count
        let newNode = FlowNode(
            title: "Custom Step Agent",
            type: .agent,
            subtitle: "Autonomous processor",
            position: CGPoint(x: 120 + (count * 60) % 600, y: 280)
        )
        nodes.append(newNode)
    }

    private func runWorkflowSimulation() {
        isExecutingFlow = true
        executionStep = 0

        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { timer in
            DispatchQueue.main.async {
                if self.executionStep < self.nodes.count - 1 {
                    self.executionStep += 1
                } else {
                    timer.invalidate()
                    self.isExecutingFlow = false
                    self.appState.showToast("Multi-Agent Pipeline executed successfully!")
                }
            }
        }
    }
}
