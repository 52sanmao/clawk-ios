import SwiftUI

// MARK: - Live Overview Tab (pulls from Gateway + Dashboard API)

struct LiveOverviewTab: View {
    @ObservedObject var gateway: GatewayConnection
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false
    @State private var costData: DashboardAPIClient.CostData?
    @State private var sessionCount: Int = 0
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 16) {
            // Stats Cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatCard(
                    title: "代理",
                    value: "\(gateway.agents.count)",
                    icon: "person.2.fill",
                    color: .green
                )

                StatCard(
                    title: "定时任务",
                    value: "\(gateway.cronJobs.count)",
                    icon: "clock.arrow.circlepath",
                    color: .purple
                )

                StatCard(
                    title: "会话",
                    value: "\(sessionCount)",
                    icon: "bubble.left.and.bubble.right.fill",
                    color: .blue
                )

                StatCard(
                    title: costPreferences.appliesSubscriptionCoverage ? "实际计费成本" : "总成本",
                    value: costString,
                    icon: "dollarsign.circle.fill",
                    color: .orange
                )
            }

            // Approvals pending
            if !gateway.pendingApprovals.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("\(gateway.pendingApprovals.count) 个待处理审批")
                        .font(.subheadline)
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            // Token usage summary
            if let tokens = costData?.tokensUsed {
                HStack(spacing: 16) {
                    TokenMini(label: "输入", value: tokens.input ?? 0, color: .blue)
                    TokenMini(label: "输出", value: tokens.output ?? 0, color: .green)
                    TokenMini(label: "缓存", value: tokens.cached ?? 0, color: .orange)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            // Active agents
            if !gateway.agents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("代理")
                        .font(.headline)
                    ForEach(gateway.agents) { agent in
                        HStack(spacing: 8) {
                            Text(agent.emoji ?? "🤖")
                            Text(agent.name ?? agent.id)
                                .font(.subheadline)
                            Spacer()
                            if let status = agent.status {
                                StatusDot(status: status)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
        }
        .onAppear { loadData() }
        .onChange(of: costDisplayModeRaw) { loadData() }
        .onChange(of: openAISubscription) { loadData() }
        .onChange(of: anthropicSubscription) { loadData() }
    }

    private var costString: String {
        guard let cost = costData?.totalCost else { return "--" }
        return formatCurrency(cost, precision: cost >= 100 ? 0 : 2)
    }

    private func loadData() {
        Task {
            // Load cost data from dashboard API
            if let costs = try? await dashboardAPI.fetchDisplayCosts(period: "week", preferences: costPreferences) {
                await MainActor.run {
                    costData = costs
                    sessionCount = costs.sessionsCount ?? 0
                }
            }
            // Try to get session count from gateway if available
            if let sessions = try? await gateway.sessionsList() {
                await MainActor.run { sessionCount = sessions.count }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}

struct TokenMini: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(formatTokens(value))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live Agents Tab

struct LiveAgentsTab: View {
    @ObservedObject var gateway: GatewayConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if gateway.agents.isEmpty {
                EmptyStateView(icon: "person.2.slash", message: "未找到代理")
            } else {
                ForEach(gateway.agents) { agent in
                    LiveAgentCard(agent: agent)
                }
            }
        }
    }
}

struct LiveAgentCard: View {
    let agent: GatewayAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(agentColor)
                        .frame(width: 48, height: 48)
                    Text(agent.emoji ?? "🤖")
                        .font(.title2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name ?? agent.id)
                        .font(.headline)
                    if let model = agent.model {
                        Text(model)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    if let skills = agent.skills, !skills.isEmpty {
                        Text("\(skills.count) 个技能")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let status = agent.status {
                    StatusDot(status: status)
                }
            }

            if let skills = agent.skills, !skills.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(skills.prefix(8), id: \.stableId) { skill in
                        HStack(spacing: 2) {
                            Text(skill.icon ?? "🔹")
                                .font(.caption)
                            Text(skill.name)
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(6)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var agentColor: Color {
        guard let colorString = agent.color else { return Color.gray }
        return Color(hex: colorString) ?? Color.gray
    }
}

// MARK: - Live Sessions Tab

struct LiveSessionsTab: View {
    @ObservedObject var gateway: GatewayConnection
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @State private var sessions: [GatewaySession] = []
    @State private var dashboardSessions: [DashboardSession] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("正在加载会话...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allSessions.isEmpty {
                EmptyStateView(icon: "bubble.left.and.bubble.right.slash", message: "未找到会话")
            } else {
                // Stats header
                HStack(spacing: 16) {
                    StatBadge(count: allSessions.count, label: "总数", color: .blue)
                    Spacer()
                }
                .padding()

                List(allSessions, id: \.id) { session in
                    LiveSessionRow(session: session)
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await loadSessions() }
        .onAppear { Task { await loadSessions() } }
    }

    private var allSessions: [SessionDisplayItem] {
        // Prefer gateway sessions if available, fall back to dashboard
        if !sessions.isEmpty {
            return sessions.map { SessionDisplayItem(from: $0) }
        }
        return dashboardSessions.map { SessionDisplayItem(from: $0) }
    }

    private func loadSessions() async {
        isLoading = sessions.isEmpty && dashboardSessions.isEmpty
        // Try gateway first
        if let gw = try? await gateway.sessionsList() {
            await MainActor.run { sessions = gw }
        }
        // Also try dashboard API
        if let resp = try? await dashboardAPI.fetchSessions() {
            await MainActor.run { dashboardSessions = resp.sessions ?? [] }
        }
        await MainActor.run { isLoading = false }
    }
}

struct SessionDisplayItem: Identifiable {
    let id: String
    let agentName: String?
    let model: String?
    let source: String?
    let messageCount: Int?
    let totalCost: Double?
    let updatedAt: String?
    let status: String?
    let projectPath: String?

    init(from gw: GatewaySession) {
        self.id = gw.id
        self.agentName = gw.agentName ?? gw.agentId
        self.model = gw.model
        self.source = nil
        self.messageCount = gw.messageCount
        self.totalCost = gw.totalCost
        self.updatedAt = gw.updatedAt
        self.status = gw.status
        self.projectPath = gw.projectPath
    }

    init(from db: DashboardSession) {
        self.id = db.id
        self.agentName = db.agentName ?? db.agentId
        self.model = db.model
        self.source = db.source
        self.messageCount = db.messageCount
        self.totalCost = db.totalCost
        self.updatedAt = db.updatedAt
        self.status = db.status
        self.projectPath = db.projectPath
    }
}

struct LiveSessionRow: View {
    let session: SessionDisplayItem
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.agentName ?? String(session.id.prefix(8)))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let costText = costDisplayText(
                    session.totalCost,
                    model: session.model,
                    source: session.source,
                    precision: 3,
                    preferences: costPreferences
                ) {
                    Text(costText)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            HStack(spacing: 12) {
                if let model = session.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                if let count = session.messageCount, count > 0 {
                    Label("\(count) msgs", systemImage: "message.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let status = session.status {
                    StatusDot(status: status)
                }
            }

            if let project = session.projectPath {
                Text(project.components(separatedBy: "/").last ?? project)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}
