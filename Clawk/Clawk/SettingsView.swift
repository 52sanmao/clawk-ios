import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var gateway: GatewayConnection
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @ObservedObject var messageStore: MessageStore
    @Environment(\.dismiss) private var dismiss

    @State private var gatewayHost: String = ""
    @State private var gatewayPort: String = ""
    @State private var gatewayToken: String = ""
    @State private var dashboardURL: String = ""
    @State private var relayURL: String = ""
    @State private var isAutoDiscovering = false
    @State private var autoDiscoverResult: String?

    var body: some View {
        NavigationView {
            Form {
                // Gateway connection
                Section {
                    TextField("Host / WebSocket URL", text: $gatewayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Port", text: $gatewayPort)
                        .keyboardType(.numberPad)

                    Text("Supports a full ws:// or wss:// gateway URL, including path prefixes such as /f5gxy9/.")
                        .font(.caption)
                        .foregroundColor(.secondary)

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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { loadCurrentSettings() }
        }
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
        gateway.updateConnection(host: gatewayHost, port: port, token: gatewayToken)
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
                        // Parse URL into host:port
                        if let components = URLComponents(string: url) {
                            gatewayHost = components.host ?? gatewayHost
                            if let port = components.port {
                                gatewayPort = "\(port)"
                            }
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
}
