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
                    TextField("主机 / WebSocket 地址", text: $gatewayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("也支持填写 http:// 或 https:// 控制台地址，应用会自动转换为 ws:// 或 wss://。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("端口", text: $gatewayPort)
                        .keyboardType(.numberPad)

                    Text("支持完整的 ws:// 或 wss:// 网关地址，并会保留 /f5gxy9/ 这类路径前缀。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Circle()
                            .fill(gateway.isConnected ? Color.green : (gateway.isConnecting ? Color.orange : Color.red))
                            .frame(width: 8, height: 8)
                        Text(gateway.isConnected ? "已连接" : (gateway.isConnecting ? "连接中..." : "未连接"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(gateway.isConnected ? "断开" : "连接") {
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
                    Text("网关（OpenClaw）")
                } footer: {
                    Text("直接连接 OpenClaw Gateway 的 WebSocket 主通道（协议 v3）。")
                }

                // Dashboard connection
                Section {
                    TextField("Dashboard 地址", text: $dashboardURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Circle()
                            .fill(dashboardAPI.isReachable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(dashboardAPI.isReachable ? "可访问" : "不可访问")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("测试") {
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
                    Text("通过 HTTP 连接 kishos-dashboard，用于获取补充数据和自动发现配置。")
                }

                // Relay server (optional)
                Section {
                    TextField("Relay 地址", text: $relayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Circle()
                            .fill(messageStore.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(messageStore.isConnected ? "已连接" : "未连接")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Relay 服务（可选）")
                } footer: {
                    Text("用于推送通知和操作卡片，不影响核心聊天功能。")
                }

                // Auto-discover
                Section {
                    Button(action: { autoDiscover() }) {
                        HStack {
                            if isAutoDiscovering {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text("从 Dashboard 自动发现")
                        }
                    }
                    .disabled(isAutoDiscovering || dashboardURL.isEmpty)

                    if let result = autoDiscoverResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } header: {
                    Text("配置")
                } footer: {
                    Text("从 Dashboard 的 /api/gateway-config 接口拉取网关地址和令牌。")
                }

                // Agent identity
                Section("代理身份") {
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
                        Text("未连接")
                            .foregroundColor(.secondary)
                    }
                }

                // Device info
                Section("设备") {
                    DetailRow(label: "设备令牌", value: String(gateway.publicDeviceToken.prefix(12)) + "...")
                    DetailRow(label: "网关状态", value: gateway.gatewayStatus?.version ?? "—")
                    if let uptime = gateway.gatewayStatus?.uptime {
                        DetailRow(label: "运行时长", value: formatUptime(uptime))
                    }
                }

                // Data management
                Section {
                    Button("清除聊天记录", role: .destructive) {
                        gateway.clearMessages()
                    }

                    Button("应用全部设置") {
                        applyAllSettings()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
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
                    autoDiscoverResult = "已获取到网关配置"
                    isAutoDiscovering = false
                }
            } catch {
                await MainActor.run {
                    autoDiscoverResult = "获取失败：\(error.localizedDescription)"
                    isAutoDiscovering = false
                }
            }
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)小时 \(minutes)分钟"
        }
        return "\(minutes)分钟"
    }
}
