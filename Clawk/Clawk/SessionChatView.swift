import SwiftUI

// MARK: - Session Chat View

struct SessionChatView: View {
    let session: DashboardSession
    @EnvironmentObject var store: MessageStore
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [SessionMessage] = []
    @State private var isLoading = true
    @State private var showingCopiedAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Session header
                SessionHeader(session: session)
                    .padding()
                    .background(Color(.secondarySystemBackground))

                // Messages list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            SessionMessageBubble(message: message)
                        }
                    }
                    .padding()
                }

                // Action buttons
                HStack(spacing: 16) {
                    Button(action: { copySessionId() }) {
                        Label("复制 ID", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button(action: { refreshMessages() }) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("会话聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                refreshMessages()
            }
            .alert("会话 ID 已复制", isPresented: $showingCopiedAlert) {
                Button("确定", role: .cancel) {}
            }
        }
    }

    private func refreshMessages() {
        isLoading = true
        store.fetchSessionMessages(sessionId: session.id) { fetchedMessages in
            messages = fetchedMessages
            isLoading = false
            // Haptic feedback on refresh
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }

    private func copySessionId() {
        UIPasteboard.general.string = session.id
        showingCopiedAlert = true
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

// MARK: - Session Header

struct SessionHeader: View {
    let session: DashboardSession
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.agentEmoji ?? "🤖")
                    .font(.largeTitle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.agentName ?? session.agentId ?? "未知代理")
                        .font(.headline)

                    if let model = session.model {
                        Text(model)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                StatusBadge(status: session.status ?? "idle")
            }

            HStack(spacing: 16) {
                StatItem(icon: "message.fill", value: "\(session.messageCount ?? 0)")
                StatItem(icon: "dollarsign.circle.fill", value: sessionCostValue)
                if let tokens = session.tokensUsed?.input ?? session.tokensUsed?.output {
                    StatItem(icon: "cylinder.split.1x2", value: formatTokens(tokens))
                }
            }

            if let path = session.projectPath {
                Label(path, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let startedAt = session.startedAt {
                Label("开始于：\(timeAgo(from: startedAt))", systemImage: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var sessionCostValue: String {
        if let costText = costDisplayText(
            session.totalCost,
            model: session.model,
            source: session.source,
            precision: 3,
            preferences: costPreferences
        ) {
            return costText
        }

        let adjustedValue = displayedCost(
            session.totalCost,
            model: session.model,
            source: session.source,
            preferences: costPreferences
        ) ?? 0
        return formatCurrency(adjustedValue, precision: 3)
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}

struct StatItem: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Session Message Bubble

struct SessionMessageBubble: View {
    let message: SessionMessage
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false

    var body: some View {
        HStack {
            if isUser {
                Spacer()
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(12)
                    .background(isUser ? Color.blue : Color(.secondarySystemBackground))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(16)

                HStack(spacing: 8) {
                    Text(message.role.capitalized)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let costText = costDisplayText(
                        message.cost,
                        model: message.model,
                        precision: 4,
                        preferences: costPreferences
                    ) {
                        Text(costText)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    if let timestamp = message.timestamp {
                        Text(formatTime(timestamp))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Tool calls indicator
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    HStack {
                        Image(systemName: "wrench.fill")
                            .font(.caption2)
                        Text("\(toolCalls.count) 次工具调用")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 2)
                }
            }

            if !isUser {
                Spacer()
            }
        }
    }

    private var isUser: Bool {
        message.role == "user"
    }

    private func formatTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}

// MARK: - Enhanced Session Row (for Sessions Tab)

struct EnhancedSessionRow: View {
    let session: DashboardSession
    @EnvironmentObject var store: MessageStore
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false
    @State private var showingChat = false
    @State private var showingCopiedAlert = false

    var body: some View {
        Button(action: { showingChat = true }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.agentEmoji ?? "🤖")
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.agentName ?? session.agentId ?? "未知")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if let model = session.model {
                            Text(model)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }

                    Spacer()

                    StatusDot(status: session.status ?? "idle")
                }

                HStack(spacing: 12) {
                    if let costText = costDisplayText(
                        session.totalCost,
                        model: session.model,
                        source: session.source,
                        precision: 3,
                        preferences: costPreferences
                    ) {
                        Label(costText, systemImage: "dollarsign.circle")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if let tokens = session.tokensUsed?.input ?? session.tokensUsed?.output {
                        Label(formatTokens(tokens), systemImage: "cylinder.split.1x2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let count = session.messageCount, count > 0 {
                        Label("\(count)", systemImage: "message")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let updatedAt = session.updatedAt {
                        Label(timeAgo(from: updatedAt), systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let path = session.projectPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showingChat) {
            SessionChatView(session: session)
                .environmentObject(store)
        }
        .contextMenu {
            Button(action: { copySessionId() }) {
                Label("复制会话 ID", systemImage: "doc.on.doc")
            }

            if let agentId = session.agentId {
                Button(action: { /* Ping agent action */ }) {
                    Label("Ping \(agentId)", systemImage: "waveform")
                }
            }

            if let path = session.projectPath {
                Button(action: { UIPasteboard.general.string = path }) {
                    Label("复制项目路径", systemImage: "folder")
                }
            }
        }
        .alert("已复制", isPresented: $showingCopiedAlert) {
            Button("确定", role: .cancel) {}
        }
    }

    private func copySessionId() {
        UIPasteboard.general.string = session.id
        showingCopiedAlert = true
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}

// MARK: - Preview

struct SessionChatView_Previews: PreviewProvider {
    static var previews: some View {
        SessionChatView(session: DashboardSession(
            id: "test-session-id",
            agentId: "engineer",
            agentName: "Engineer",
            agentEmoji: "⚙️",
            agentColor: "#FCD34D",
            model: "claude-sonnet-4-6",
            messageCount: 15,
            totalCost: 0.456,
            tokensUsed: TokenUsage(input: 5000, output: 2000, cached: 1000),
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
            projectPath: "/Users/kishparikh/Projects/test",
            source: "codex",
            status: "active",
            folderTrail: nil
        ))
        .environmentObject(MessageStore())
    }
}
