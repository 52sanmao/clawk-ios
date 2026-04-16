import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var gateway: GatewayConnection
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @ObservedObject var messageStore: MessageStore
    @Environment(\.dismiss) private var dismiss

    @State private var gatewayHost: String = ""
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
                    TextField("IronClaw 地址", text: $gatewayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("只需要填写一次完整的 IronClaw 地址，App 会让聊天和 Dashboard 默认跟随这个地址；Relay 默认关闭，只有单独填写时才启用。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SecureField("IronClaw Bearer Token", text: $gatewayToken)
                        .textInputAutocapitalization(.never)

                    Text("聊天主链路使用 /api/chat/thread/new、/api/chat/send 与 /api/chat/history；其它模块默认共用同一地址。")
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
                    Text("IronClaw")
                } footer: {
                    Text("直接连接 IronClaw 原生 HTTP API，聊天通过线程接口轮询历史结果，不再依赖旧的 /v1/responses 主链路。")
                }

                // Dashboard connection
                Section {
                    TextField("Dashboard 地址（留空时跟随 IronClaw）", text: $dashboardURL)
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
                    Text("默认复用 IronClaw 地址；只有在服务实际拆开部署时才需要单独覆盖。")
                }

                // Relay server (optional)
                Section {
                    TextField("Relay 地址（留空则禁用）", text: $relayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Circle()
                            .fill(messageStore.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(messageStore.isConnected ? "已连接" : "未连接")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("应用") {
                            applyRelaySettings()
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("Relay 服务（可选）")
                } footer: {
                    Text("留空表示完全禁用旧 Relay 推送链路；只有推送服务单独部署时才需要填写。")
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
                    Text("从 Dashboard 的 /api/gateway-config 接口拉取 IronClaw 地址和令牌。")
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
                    DetailRow(label: "IronClaw 状态", value: gateway.gatewayStatus?.version ?? "—")
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
        gatewayHost = gateway.gatewayHost.isEmpty ? Config.defaultGatewayBaseURL : gateway.gatewayHost
        gatewayToken = {
            let stored = UserDefaults.standard.string(forKey: "gatewayToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false ? stored : nil) ?? Config.defaultGatewayToken
        }()

        let storedDashboard = UserDefaults.standard.string(forKey: "dashboardBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        dashboardURL = storedDashboard == gateway.gatewayHost ? "" : storedDashboard

        let storedRelay = UserDefaults.standard.string(forKey: "relayBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        relayURL = storedRelay == gateway.gatewayHost ? "" : storedRelay
    }

    private func applyGatewaySettings() {
        let normalized = GatewayConnection.normalizeGatewayEndpoint(gatewayHost, fallbackPort: 443)
        gatewayHost = normalized.host

        let previousGateway = gateway.gatewayHost
        let storedDashboard = UserDefaults.standard.string(forKey: "dashboardBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedRelay = UserDefaults.standard.string(forKey: "relayBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldFollowGatewayForDashboard = dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || storedDashboard.isEmpty
            || storedDashboard == previousGateway
        let shouldDisableRelay = relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || storedRelay.isEmpty
            || storedRelay == previousGateway
            || Config.usesLegacyLocalRelayDefault

        gateway.updateConnection(host: normalized.host, port: normalized.port, token: gatewayToken)

        if shouldFollowGatewayForDashboard {
            dashboardURL = ""
            dashboardAPI.updateBaseURL(normalized.host)
        }

        if shouldDisableRelay {
            relayURL = ""
            Config.persistRelayBaseURL("")
            messageStore.reloadConfiguration()
        }
    }

    private func applyDashboardSettings() {
        let trimmed = dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? gateway.gatewayHost : trimmed
        dashboardURL = trimmed.isEmpty ? "" : resolved
        dashboardAPI.updateBaseURL(resolved)
    }

    private func applyRelaySettings() {
        let trimmed = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            relayURL = ""
            Config.persistRelayBaseURL("")
        } else {
            relayURL = trimmed
            Config.persistRelayBaseURL(trimmed)
        }
        messageStore.reloadConfiguration()
    }

    private func applyAllSettings() {
        applyGatewaySettings()
        applyDashboardSettings()
        applyRelaySettings()
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
                    }
                    if let token = config.token {
                        gatewayToken = token
                    }
                    autoDiscoverResult = "已获取到 IronClaw 配置"
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
