import SwiftUI

// MARK: - More View (list of secondary features)

struct MoreView: View {
    @EnvironmentObject var gateway: GatewayConnection
    @EnvironmentObject var dashboardAPI: DashboardAPIClient
    @EnvironmentObject var messageStore: MessageStore

    var body: some View {
        NavigationStack {
            List {
                // Status section (inline, not navigable)
                Section {
                    HStack(spacing: 12) {
                        if let identity = gateway.agentIdentity {
                            Text(identity.emoji)
                                .font(.largeTitle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(identity.name)
                                    .font(.headline)
                                Text(identity.creature)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Image(systemName: "brain.head.profile")
                                .font(.title)
                                .foregroundColor(.secondary)
                            Text("Not connected")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(gateway.isConnected ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(gateway.isConnected ? "Gateway" : "Offline")
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
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Agents & Sessions
                Section("Agents & Sessions") {
                    NavigationLink {
                        ScrollView {
                            LiveAgentsTab(gateway: gateway)
                                .padding()
                        }
                        .navigationTitle("Agents")
                    } label: {
                        Label {
                            HStack {
                                Text("Agents")
                                Spacer()
                                Text("\(gateway.agents.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.2.fill")
                                .foregroundColor(.green)
                        }
                    }

                    NavigationLink {
                        LiveSessionsTab(gateway: gateway, dashboardAPI: dashboardAPI)
                            .navigationTitle("Sessions")
                    } label: {
                        Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        ApprovalQueueView(gateway: gateway)
                            .navigationTitle("Approvals")
                    } label: {
                        Label {
                            HStack {
                                Text("Approvals")
                                Spacer()
                                if gateway.pendingApprovals.count > 0 {
                                    Text("\(gateway.pendingApprovals.count)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange)
                                        .cornerRadius(8)
                                }
                            }
                        } icon: {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }

                // Analytics
                Section("Analytics") {
                    NavigationLink {
                        CostsView(dashboardAPI: dashboardAPI)
                            .navigationTitle("Costs")
                    } label: {
                        Label("Costs", systemImage: "dollarsign.circle.fill")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        AgentLogsView(gateway: gateway)
                            .navigationTitle("Logs")
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                            .foregroundColor(.primary)
                    }
                }

                // System
                Section("System") {
                    NavigationLink {
                        RelayMessagesView()
                            .environmentObject(messageStore)
                            .navigationTitle("Action Cards")
                    } label: {
                        Label("Action Cards", systemImage: "bell.badge.fill")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        GatewayDebugLogContent(gateway: gateway)
                            .navigationTitle("Debug Log")
                    } label: {
                        Label("Debug Log", systemImage: "ant.fill")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        SettingsFormContent(
                            gateway: gateway,
                            dashboardAPI: dashboardAPI,
                            messageStore: messageStore
                        )
                        .navigationTitle("Settings")
                    } label: {
                        Label("Settings", systemImage: "gear")
                            .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}

// MARK: - Relay Messages View (ContentView without NavigationView wrapper)

struct RelayMessagesView: View {
    @EnvironmentObject var store: MessageStore

    var body: some View {
        VStack(spacing: 0) {
            // Connection status bar
            HStack {
                ConnectionStatus(isConnected: store.isConnected, isConnecting: store.isConnecting)
                Spacer()
                if store.isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            // Messages list
            List {
                ForEach(store.messages) { message in
                    MessageCard(message: message) {
                        store.respond(to: message, with: $0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.messages.isEmpty && !store.isConnecting {
                    EmptyState()
                } else if store.isConnecting && store.messages.isEmpty {
                    ConnectingState()
                }
            }
        }
    }
}

// MARK: - Gateway Debug Log Content (without NavigationView wrapper)

struct GatewayDebugLogContent: View {
    @ObservedObject var gateway: GatewayConnection

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(gateway.debugLog.enumerated()), id: \.offset) { index, entry in
                        Text(entry)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(debugEntryColor(entry))
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: gateway.debugLog.count) {
                if let last = gateway.debugLog.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    gateway.debugLog.removeAll()
                }
            }
        }
    }

    private func debugEntryColor(_ entry: String) -> Color {
        if entry.contains("FAILED") || entry.contains("error") || entry.contains("Error") {
            return .red
        } else if entry.contains("OK") || entry.contains("succeeded") || entry.contains("connected") {
            return .green
        } else if entry.contains("chat event") || entry.contains("Agent event") {
            return .blue
        }
        return .primary
    }
}

// MARK: - Settings Form Content (without NavigationView wrapper)

struct SettingsFormContent: View {
    @ObservedObject var gateway: GatewayConnection
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @ObservedObject var messageStore: MessageStore
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false

    @State private var gatewayHost: String = ""
    @State private var gatewayPort: String = ""
    @State private var gatewayToken: String = ""
    @State private var dashboardURL: String = ""
    @State private var relayURL: String = ""
    @State private var isAutoDiscovering = false
    @State private var autoDiscoverResult: String?

    var body: some View {
        Form {
            // Gateway connection
            Section {
                TextField("Host", text: $gatewayHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Supports ws://, wss://, or control URLs like http://host:port/path and preserves path prefixes.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Port", text: $gatewayPort)
                    .keyboardType(.numberPad)

                SecureField("Token (optional)", text: $gatewayToken)
                    .textInputAutocapitalization(.never)

                HStack {
                    Circle()
                        .fill(gateway.isConnected ? Color.green : (gateway.isConnecting ? Color.orange : Color.red))
                        .frame(width: 8, height: 8)
                    Text(gateway.isConnected ? "Connected" : (gateway.isConnecting ? "Connecting..." : "Disconnected"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(gateway.isConnected ? "Disconnect" : "Connect") {
                        if gateway.isConnected {
                            gateway.disconnect()
                        } else {
                            applyGatewaySettings()
                        }
                    }
                    .font(.caption)
                }

                if let error = gateway.connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Gateway (OpenClaw)")
            } footer: {
                Text("Direct WebSocket connection to OpenClaw Gateway (Protocol v3)")
            }

            // Dashboard connection
            Section {
                TextField("Dashboard URL", text: $dashboardURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Circle()
                        .fill(dashboardAPI.isReachable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(dashboardAPI.isReachable ? "Reachable" : "Unreachable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Test") {
                        applyDashboardSettings()
                        Task { await dashboardAPI.checkHealth() }
                    }
                    .font(.caption)
                }

                if let error = dashboardAPI.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Dashboard")
            } footer: {
                Text("Direct HTTP connection to kishos-dashboard for supplementary data")
            }

            Section {
                Picker("Display Mode", selection: $costDisplayModeRaw) {
                    ForEach(CostDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Toggle("OpenAI subscription covers GPT/o-series", isOn: $openAISubscription)
                    .disabled(costDisplayMode != .effectiveBilled)

                Toggle("Anthropic subscription covers Claude", isOn: $anthropicSubscription)
                    .disabled(costDisplayMode != .effectiveBilled)

                if costPreferences.appliesSubscriptionCoverage {
                    Text("Covered providers will show as billed cost 0 or Included when the model name matches.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Cost Display")
            } footer: {
                Text("The dashboard does not report whether usage came from an API key or a subscription seat. These settings apply a local display override based on detected model/provider names.")
            }

            // Relay server (optional)
            Section {
                TextField("Relay URL", text: $relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Circle()
                        .fill(messageStore.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(messageStore.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Relay Server (Optional)")
            } footer: {
                Text("For push notifications and action cards. Not required for core functionality.")
            }

            // Auto-discover
            Section {
                Button(action: { autoDiscover() }) {
                    HStack {
                        if isAutoDiscovering {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text("Auto-Discover from Dashboard")
                    }
                }
                .disabled(isAutoDiscovering || dashboardURL.isEmpty)

                if let result = autoDiscoverResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Fetches gateway URL and token from the dashboard's /api/gateway-config endpoint")
            }

            // Agent identity
            Section("Agent Identity") {
                if let identity = gateway.agentIdentity {
                    HStack {
                        Text(identity.emoji)
                            .font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text(identity.name).font(.headline)
                            Text(identity.creature).font(.caption).foregroundColor(.secondary)
                            if let vibe = identity.vibe {
                                Text(vibe).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Not connected")
                        .foregroundColor(.secondary)
                }
            }

            // Device info
            Section("Device") {
                DetailRow(label: "Device Token", value: String(gateway.publicDeviceToken.prefix(12)) + "...")
                DetailRow(label: "Gateway Status", value: gateway.gatewayStatus?.version ?? "—")
                if let uptime = gateway.gatewayStatus?.uptime {
                    DetailRow(label: "Uptime", value: formatUptime(uptime))
                }
            }

            // Data management
            Section {
                Button("Clear Chat History", role: .destructive) {
                    gateway.clearMessages()
                }

                Button("Apply All Settings") {
                    applyAllSettings()
                }
            }
        }
        .onAppear { loadCurrentSettings() }
    }

    private func loadCurrentSettings() {
        gatewayHost = gateway.gatewayHost
        gatewayPort = "\(gateway.gatewayPort)"
        gatewayToken = UserDefaults.standard.string(forKey: "gatewayToken") ?? ""
        dashboardURL = UserDefaults.standard.string(forKey: "dashboardBaseURL") ?? "http://100.96.61.83:4004"
        relayURL = Config.baseURL
    }

    private func applyGatewaySettings() {
        let port = Int(gatewayPort) ?? 18789
        let normalized = GatewayConnection.normalizeGatewayEndpoint(gatewayHost, fallbackPort: port)
        gatewayHost = normalized.host
        gatewayPort = "\(normalized.port)"
        gateway.updateConnection(host: normalized.host, port: normalized.port, token: gatewayToken)
    }

    private func applyDashboardSettings() {
        dashboardAPI.updateBaseURL(dashboardURL)
    }

    private func applyAllSettings() {
        applyGatewaySettings()
        applyDashboardSettings()
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func autoDiscover() {
        isAutoDiscovering = true
        autoDiscoverResult = nil
        Task {
            do {
                let config = try await dashboardAPI.fetchGatewayConfig()
                await MainActor.run {
                    if let url = config.url {
                        gatewayHost = url
                        if let port = URLComponents(string: url)?.port {
                            gatewayPort = "\(port)"
                        }
                    }
                    if let token = config.token {
                        gatewayToken = token
                    }
                    autoDiscoverResult = "Found gateway config"
                    isAutoDiscovering = false
                }
            } catch {
                await MainActor.run {
                    autoDiscoverResult = "Failed: \(error.localizedDescription)"
                    isAutoDiscovering = false
                }
            }
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var costDisplayMode: CostDisplayMode {
        CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: costDisplayMode,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}
