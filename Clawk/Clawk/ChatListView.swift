import SwiftUI

// MARK: - Chat List View (messaging app style)

struct ChatListView: View {
    @EnvironmentObject var gateway: GatewayConnection
    @EnvironmentObject var dashboardAPI: DashboardAPIClient
    @State private var gatewaySessions: [GatewaySession] = []
    @State private var dashboardSessions: [DashboardSession] = []
    @State private var isLoading = true
    @State private var navigateToNewChat = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading && allSessions.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView("Loading sessions...")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if allSessions.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No conversations yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Start a new chat to begin")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button(action: { navigateToNewChat = true }) {
                            Label("New Chat", systemImage: "square.and.pencil")
                                .font(.body.weight(.medium))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(allSessions) { item in
                            NavigationLink(value: item) {
                                ChatSessionRow(item: item)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { navigateToNewChat = true }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(for: ChatSessionItem.self) { item in
                ChatDetailView(session: item.toGatewaySession())
            }
            .navigationDestination(isPresented: $navigateToNewChat) {
                ChatDetailView(session: nil)
            }
            .refreshable {
                await loadSessions()
            }
            .onAppear {
                Task { await loadSessions() }
            }
            .onChange(of: gateway.isConnected) { _, connected in
                if connected {
                    Task { await loadSessions() }
                }
            }
        }
    }

    private var allSessions: [ChatSessionItem] {
        // Prefer gateway sessions if available
        if !gatewaySessions.isEmpty {
            return gatewaySessions.map { ChatSessionItem(from: $0) }
        }
        return dashboardSessions.map { ChatSessionItem(from: $0) }
    }

    private func loadSessions() async {
        // Try gateway first
        if let gw = try? await gateway.sessionsList(limit: 100) {
            await MainActor.run {
                gatewaySessions = gw.sorted { s1, s2 in
                    (s1.updatedAt ?? s1.startedAt ?? "") > (s2.updatedAt ?? s2.startedAt ?? "")
                }
            }
        }
        // Also try dashboard API as fallback/supplement
        if let resp = try? await dashboardAPI.fetchSessions(limit: 100) {
            await MainActor.run {
                dashboardSessions = (resp.sessions ?? []).sorted { s1, s2 in
                    (s1.updatedAt ?? s1.startedAt ?? "") > (s2.updatedAt ?? s2.startedAt ?? "")
                }
            }
        }
        await MainActor.run { isLoading = false }
    }
}

// MARK: - Chat Session Item (unified model for list)

struct ChatSessionItem: Identifiable, Hashable {
    let id: String
    let agentId: String?
    let agentName: String?
    let agentEmoji: String?
    let model: String?
    let source: String?
    let messageCount: Int?
    let totalCost: Double?
    let updatedAt: String?
    let startedAt: String?
    let projectPath: String?
    let status: String?
    let sessionKey: String?
    let tokensUsed: GatewayTokenUsage?

    init(from gw: GatewaySession) {
        self.id = gw.id
        self.agentId = gw.agentId
        self.agentName = gw.agentName
        self.agentEmoji = nil
        self.model = gw.model
        self.source = nil
        self.messageCount = gw.messageCount
        self.totalCost = gw.totalCost
        self.updatedAt = gw.updatedAt
        self.startedAt = gw.startedAt
        self.projectPath = gw.projectPath
        self.status = gw.status
        self.sessionKey = gw.sessionKey
        self.tokensUsed = gw.tokensUsed
    }

    init(from db: DashboardSession) {
        self.id = db.id
        self.agentId = db.agentId
        self.agentName = db.agentName
        self.agentEmoji = db.agentEmoji
        self.model = db.model
        self.source = db.source
        self.messageCount = db.messageCount
        self.totalCost = db.totalCost
        self.updatedAt = db.updatedAt
        self.startedAt = db.startedAt
        self.projectPath = db.projectPath
        self.status = db.status
        self.sessionKey = nil
        self.tokensUsed = nil
    }

    func toGatewaySession() -> GatewaySession {
        GatewaySession(
            id: id,
            agentId: agentId,
            agentName: agentName,
            model: model,
            messageCount: messageCount,
            totalCost: totalCost,
            tokensUsed: tokensUsed,
            updatedAt: updatedAt,
            startedAt: startedAt,
            projectPath: projectPath,
            status: status,
            sessionKey: sessionKey
        )
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ChatSessionItem, rhs: ChatSessionItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Chat Session Row

struct ChatSessionRow: View {
    let item: ChatSessionItem
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false

    var body: some View {
        HStack(spacing: 12) {
            // Agent emoji
            Text(emoji)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.agentName ?? item.agentId ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Spacer()

                    if let time = item.updatedAt ?? item.startedAt {
                        Text(timeAgo(from: time))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    if let model = item.model {
                        Text(shortModelName(model))
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    if let count = item.messageCount, count > 0 {
                        Text("\(count) msgs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let costText = costDisplayText(
                        item.totalCost,
                        model: item.model,
                        source: item.source,
                        precision: 2,
                        preferences: costPreferences
                    ) {
                        Text(costText)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }

                if let path = item.projectPath {
                    Text(path.components(separatedBy: "/").last ?? path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var emoji: String {
        if let e = item.agentEmoji { return e }
        switch item.agentId {
        case "main": return "🧠"
        case "claude-code": return "🔮"
        case "codex": return "🧬"
        case "archived": return "📦"
        default: return "🤖"
        }
    }

    private func shortModelName(_ model: String) -> String {
        // Shorten model names for compact display
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("opus") { return "Opus" }
        if model.contains("haiku") { return "Haiku" }
        return String(model.prefix(20))
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}
