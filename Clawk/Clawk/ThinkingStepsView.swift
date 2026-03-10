import SwiftUI

// MARK: - Thinking Steps View
/// Displays real-time thinking steps and tool calls during agent processing
struct ThinkingStepsView: View {
    let steps: [GatewayThinkingStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                ThinkingStepRow(step: step)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

struct ThinkingStepRow: View {
    let step: GatewayThinkingStep
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 8) {
            ThinkingStepIcon(step: step)
                .frame(width: 18, height: 18)

            Text(step.displayText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(isExpanded ? nil : 1)

            Spacer()

            if let duration = step.durationMs {
                Text("\(duration)ms")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.systemGray6).opacity(0.6))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

struct ThinkingStepIcon: View {
    let step: GatewayThinkingStep

    var body: some View {
        Group {
            switch step.type {
            case .thinking:
                ThinkingDots()
            case .toolCall:
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
            case .toolResult:
                Image(systemName: statusIcon)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
            }
        }
    }

    private var statusIcon: String {
        switch step.status {
        case "ok", "success": return "checkmark.circle.fill"
        case "error", "failed": return "xmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private var statusColor: Color {
        switch step.status {
        case "ok", "success": return .green
        case "error", "failed": return .red
        default: return .orange
        }
    }
}

// MARK: - Animated Thinking Dots
struct ThinkingDots: View {
    @State private var animationPhase = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue.opacity(opacity(for: index)))
                    .frame(width: 3, height: 3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                animationPhase = 3
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let base = Double(index) * 0.3
        let animated = Double(animationPhase) * 0.3
        return 0.3 + min(0.7, max(0, animated - base))
    }
}

// MARK: - Chat Message View
struct ChatMessageView: View {
    let message: GatewayChatMessage
    let agentIdentity: GatewayAgentIdentity?
    let isCurrentUser: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isCurrentUser {
                Spacer(minLength: 60)
            }

            if !isCurrentUser {
                // Agent avatar
                AgentAvatar(identity: agentIdentity)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 2) {
                // Agent name
                if !isCurrentUser, let name = agentIdentity?.name {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }

                // Message bubble
                ChatBubble(
                    content: message.content,
                    isUser: isCurrentUser
                )

                // Thinking disclosure
                if !isCurrentUser, let thinking = message.thinking, !thinking.isEmpty {
                    DisclosureGroup("Thinking") {
                        Text(thinking)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                }

                // Tool calls
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(toolCalls, id: \.id) { toolCall in
                            ToolCallBadge(toolCall: toolCall)
                        }
                    }
                    .padding(.leading, 4)
                }

                // Timestamp
                Text(formatTime(message.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(Color(.tertiaryLabel))
                    .padding(.horizontal, 4)
            }

            if !isCurrentUser {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date).lowercased()
    }
}

// MARK: - Agent Avatar
struct AgentAvatar: View {
    let identity: GatewayAgentIdentity?

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: identity?.color ?? "#6366F1") ?? .indigo,
                            (Color(hex: identity?.color ?? "#6366F1") ?? .indigo).opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(identity?.emoji ?? "🤖")
                .font(.system(size: 14))
        }
    }
}

// MARK: - Chat Bubble
struct ChatBubble: View {
    let content: String
    let isUser: Bool

    var body: some View {
        Text(content)
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .clipShape(BubbleShape(isUser: isUser))
    }

    private var backgroundColor: Color {
        if isUser {
            return Color.blue
        } else {
            return Color(.systemGray5)
        }
    }

    private var foregroundColor: Color {
        isUser ? .white : .primary
    }
}

// MARK: - Bubble Shape (iMessage-style)
struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailSize: CGFloat = 6

        var path = Path()

        if isUser {
            // User bubble: rounded with tail on bottom-right
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.move(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.maxX - tailSize, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - tailSize - 4, y: rect.maxY),
                control: CGPoint(x: rect.maxX - tailSize - 2, y: rect.maxY)
            )
        } else {
            // Agent bubble: rounded with tail on bottom-left
            path.addRoundedRect(
                in: CGRect(x: rect.minX + tailSize, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // Small tail
            path.move(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.minX + tailSize, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + tailSize + 4, y: rect.maxY),
                control: CGPoint(x: rect.minX + tailSize + 2, y: rect.maxY)
            )
        }

        return path
    }
}

// MARK: - Tool Call Badge
struct ToolCallBadge: View {
    let toolCall: GatewayToolCall
    @State private var showDetails = false

    var body: some View {
        Button(action: { showDetails.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9))
                Text(toolCall.name)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.08))
            .foregroundColor(.blue)
            .cornerRadius(6)
        }
        .sheet(isPresented: $showDetails) {
            ToolCallDetailView(toolCall: toolCall)
        }
    }
}

// MARK: - Tool Call Detail View
struct ToolCallDetailView: View {
    let toolCall: GatewayToolCall
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Tool") {
                    Text(toolCall.name)
                        .font(.headline)
                }

                Section("Arguments") {
                    if toolCall.arguments.isEmpty {
                        Text("No arguments")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(toolCall.arguments.keys.sorted()), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let value = toolCall.arguments[key] as? String {
                                    Text(value)
                                        .font(.system(size: 13, design: .monospaced))
                                        .lineLimit(5)
                                }
                            }
                        }
                    }
                }

                Section("Timestamp") {
                    Text(toolCall.timestamp, style: .date)
                    Text(toolCall.timestamp, style: .time)
                }
            }
            .navigationTitle("Tool Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview
struct ThinkingStepsView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ThinkingStepsView(steps: [
                GatewayThinkingStep(id: "1", content: "Considering options...", timestamp: Date(), type: .thinking),
                GatewayThinkingStep(id: "2", content: "Using web_search...", timestamp: Date(), type: .toolCall, toolName: "web_search"),
                GatewayThinkingStep(id: "3", content: "web_search completed", timestamp: Date(), type: .toolResult, toolName: "web_search", status: "ok", durationMs: 450)
            ])

            Divider()

            ChatMessageView(
                message: GatewayChatMessage(
                    id: "1",
                    role: "assistant",
                    content: "I found some interesting results for you!",
                    timestamp: Date(),
                    thinking: "Let me search for the latest information..."
                ),
                agentIdentity: GatewayAgentIdentity(name: "Claude", creature: "AI", vibe: "Helpful", emoji: "🧠", color: "#A78BFA"),
                isCurrentUser: false
            )
        }
        .padding()
    }
}
