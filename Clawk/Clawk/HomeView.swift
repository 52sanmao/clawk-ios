import SwiftUI

// MARK: - Home View (Overview + Snapshots + More)

struct HomeView: View {
    @EnvironmentObject var gateway: GatewayConnection
    @EnvironmentObject var dashboardAPI: DashboardAPIClient
    @EnvironmentObject var messageStore: MessageStore
    @Binding var selectedTab: Int
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false

    @State private var costData: DashboardAPIClient.CostData?
    @State private var recentSessions: [ChatSessionItem] = []
    @State private var memoryFiles: [DashboardAPIClient.MemoryFile] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection status
                    connectionHeader

                    // Overview stats
                    overviewSection

                    // Chat snapshot
                    chatSnapshot

                    // Cron snapshot
                    cronSnapshot

                    // Memory snapshot
                    memorySnapshot

                    // More items
                    moreSection
                }
                .padding()
            }
            .refreshable {
                // Force reconnect on pull-to-refresh if disconnected
                if !gateway.isConnected && !gateway.isConnecting {
                    gateway.connect()
                    // Wait briefly for connection to establish
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                await loadAllData()
            }
            .navigationTitle("Home")
            .onAppear {
                // Trigger gateway connect if not already connected
                if !gateway.isConnected && !gateway.isConnecting {
                    gateway.connect()
                }
                Task { await loadAllData() }
            }
            .onChange(of: gateway.isConnected) { _, connected in
                if connected {
                    // Gateway just connected — reload gateway-dependent data
                    Task { await loadAllData() }
                }
            }
        }
    }

    // MARK: - Connection Header

    private var connectionHeader: some View {
        Button(action: {
            if !gateway.isConnected && !gateway.isConnecting {
                gateway.connect()
            }
        }) {
            HStack(spacing: 12) {
                if let identity = gateway.agentIdentity {
                    Text(identity.emoji)
                        .font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(identity.creature)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(gateway.isConnected ? .green : (gateway.isConnecting ? .orange : .red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gateway.isConnecting ? "Connecting..." : (gateway.isConnected ? "Connected" : "Tap to reconnect"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(gateway.gatewayHost.hasPrefix("ws") ? gateway.gatewayHost : "\(gateway.gatewayHost):\(gateway.gatewayPort)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(gateway.isConnected ? Color.green : (gateway.isConnecting ? Color.orange : Color.red))
                            .frame(width: 8, height: 8)
                        Text(gateway.isConnected ? "Live" : (gateway.isConnecting ? "Connecting" : "Offline"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(dashboardAPI.isReachable ? Color.blue : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Dashboard")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let error = gateway.connectionError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Overview Stats

    private var overviewSection: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(
                title: "Agents",
                value: "\(gateway.agents.count)",
                icon: "person.2.fill",
                color: .green
            )
            StatCard(
                title: "Sessions",
                value: "\(recentSessions.count)",
                icon: "bubble.left.and.bubble.right.fill",
                color: .blue
            )
            StatCard(
                title: "Cron Jobs",
                value: "\(gateway.cronJobs.count)",
                icon: "clock.arrow.circlepath",
                color: .purple
            )
            StatCard(
                title: costPreferences.appliesSubscriptionCoverage ? "Billed Cost" : "Total Cost",
                value: costString,
                icon: "dollarsign.circle.fill",
                color: .orange
            )
        }
    }

    // MARK: - Chat Snapshot

    private var chatSnapshot: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: { selectedTab = 1 }) {
                HStack {
                    Label("Recent Chats", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("See all")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if recentSessions.isEmpty {
                HStack {
                    Text("No recent sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentSessions.prefix(3)) { session in
                        Button(action: { selectedTab = 1 }) {
                            HStack(spacing: 10) {
                                Text(sessionEmoji(session))
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.agentName ?? session.agentId ?? "Unknown")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    HStack(spacing: 6) {
                                        if let model = session.model {
                                            Text(shortModel(model))
                                                .font(.caption2)
                                                .foregroundColor(.blue)
                                        }
                                        if let count = session.messageCount, count > 0 {
                                            Text("\(count) msgs")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                if let time = session.updatedAt ?? session.startedAt {
                                    Text(timeAgo(from: time))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        if session.id != recentSessions.prefix(3).last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Cron Snapshot

    private var cronSnapshot: some View {
        VStack(spacing: 0) {
            Button(action: { selectedTab = 2 }) {
                HStack {
                    Label("Cron Jobs", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("See all")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if gateway.cronJobs.isEmpty {
                HStack {
                    Text("No cron jobs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            } else {
                let enabledJobs = gateway.cronJobs.filter { $0.enabled ?? false }
                let heartbeats = gateway.cronJobs.filter { $0.isHeartbeat }

                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text("\(enabledJobs.count)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("Enabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text("\(gateway.cronJobs.count - enabledJobs.count)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.gray)
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text("\(heartbeats.count)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.pink)
                        Text("Heartbeats")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)

                // Show next run if available
                if let status = gateway.cronStatus, let nextWake = status.nextWakeAtMs {
                    HStack(spacing: 4) {
                        Image(systemName: "alarm")
                            .font(.caption2)
                        Text("Next: \(formatRelativeTime(nextWake))")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Memory Snapshot

    private var memorySnapshot: some View {
        VStack(spacing: 0) {
            Button(action: { selectedTab = 3 }) {
                HStack {
                    Label("Memory", systemImage: "brain.head.profile")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("See all")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if memoryFiles.isEmpty {
                HStack {
                    Text("No memory files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(memoryFiles.prefix(4), id: \.path) { file in
                        Button(action: { selectedTab = 3 }) {
                            HStack(spacing: 10) {
                                Image(systemName: fileIcon(file.path))
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                    .frame(width: 20)

                                Text(file.path.components(separatedBy: "/").last ?? file.path)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Spacer()

                                if let size = file.size {
                                    Text(formatFileSize(size))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                        if file.path != memoryFiles.prefix(4).last?.path {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - More Section

    private var moreSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("More")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                NavigationLink {
                    ScrollView {
                        LiveAgentsTab(gateway: gateway)
                            .padding()
                    }
                    .navigationTitle("Agents")
                } label: {
                    moreRow(icon: "person.2.fill", color: .green, title: "Agents", detail: "\(gateway.agents.count)")
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    LiveSessionsTab(gateway: gateway, dashboardAPI: dashboardAPI)
                        .navigationTitle("Sessions")
                } label: {
                    moreRow(icon: "bubble.left.and.bubble.right", color: .blue, title: "Sessions")
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    ApprovalQueueView(gateway: gateway)
                        .navigationTitle("Approvals")
                } label: {
                    moreRow(icon: "checkmark.shield.fill", color: .orange, title: "Approvals",
                            badge: gateway.pendingApprovals.count > 0 ? "\(gateway.pendingApprovals.count)" : nil)
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    CostsView(dashboardAPI: dashboardAPI)
                        .navigationTitle("Costs")
                } label: {
                    moreRow(icon: "dollarsign.circle.fill", color: .green, title: "Costs")
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    AgentLogsView(gateway: gateway)
                        .navigationTitle("Logs")
                } label: {
                    moreRow(icon: "doc.text.magnifyingglass", color: .indigo, title: "Logs")
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    RelayMessagesView()
                        .environmentObject(messageStore)
                        .navigationTitle("Action Cards")
                } label: {
                    moreRow(icon: "bell.badge.fill", color: .red, title: "Action Cards")
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    GatewayDebugLogContent(gateway: gateway)
                        .navigationTitle("Debug Log")
                } label: {
                    moreRow(icon: "ant.fill", color: .gray, title: "Debug Log")
                }

                Divider().padding(.leading, 48)

                NavigationLink {
                    SettingsFormContent(
                        gateway: gateway,
                        dashboardAPI: dashboardAPI,
                        messageStore: messageStore
                    )
                    .navigationTitle("Settings")
                } label: {
                    moreRow(icon: "gear", color: .gray, title: "Settings")
                }
            }
            .padding(.bottom, 8)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - More Row Helper

    private func moreRow(icon: String, color: Color, title: String, detail: String? = nil, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
                .frame(width: 24)

            Text(title)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            if let badge = badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .cornerRadius(8)
            }

            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Data Loading

    private func loadAllData() async {
        // Load sessions
        if let gw = try? await gateway.sessionsList(limit: 100) {
            let sorted = gw.sorted { ($0.updatedAt ?? $0.startedAt ?? "") > ($1.updatedAt ?? $1.startedAt ?? "") }
            await MainActor.run {
                recentSessions = sorted.map { ChatSessionItem(from: $0) }
            }
        } else if let resp = try? await dashboardAPI.fetchSessions(limit: 20) {
            let sorted = (resp.sessions ?? []).sorted { ($0.updatedAt ?? $0.startedAt ?? "") > ($1.updatedAt ?? $1.startedAt ?? "") }
            await MainActor.run {
                recentSessions = sorted.map { ChatSessionItem(from: $0) }
            }
        }

        // Load costs
        if let costs = try? await dashboardAPI.fetchDisplayCosts(period: "week", preferences: costPreferences) {
            await MainActor.run { costData = costs }
        }

        // Load memory files
        if let files = try? await dashboardAPI.fetchMemoryFiles() {
            await MainActor.run { memoryFiles = files }
        }

        // Load cron
        if let jobs = try? await gateway.cronList() {
            await MainActor.run { gateway.cronJobs = jobs }
        }
        let _ = try? await gateway.cronGetStatus()

        await MainActor.run { isLoading = false }
    }

    // MARK: - Helpers

    private var costString: String {
        guard let cost = costData?.totalCost else { return "--" }
        return formatCurrency(cost, precision: cost >= 100 ? 0 : 2)
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }

    private func sessionEmoji(_ session: ChatSessionItem) -> String {
        if let e = session.agentEmoji { return e }
        switch session.agentId {
        case "main": return "🧠"
        case "claude-code": return "🔮"
        case "codex": return "🧬"
        default: return "🤖"
        }
    }

    private func shortModel(_ model: String) -> String {
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("opus") { return "Opus" }
        if model.contains("haiku") { return "Haiku" }
        return String(model.prefix(15))
    }

    private func fileIcon(_ path: String) -> String {
        if path.hasSuffix(".md") { return "doc.text" }
        if path.hasSuffix(".json") { return "curlybraces" }
        if path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return "list.bullet" }
        return "doc"
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
