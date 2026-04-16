import SwiftUI
import UIKit

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
                            Text("未连接")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(gateway.isConnected ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(gateway.isConnected ? "IronClaw 在线" : "离线")
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
                Section("代理与会话") {
                    NavigationLink {
                        ScrollView {
                            LiveAgentsTab(gateway: gateway)
                                .padding()
                        }
                        .navigationTitle("代理")
                    } label: {
                        Label {
                            HStack {
                                Text("代理")
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
                            .navigationTitle("会话")
                    } label: {
                        Label("会话", systemImage: "bubble.left.and.bubble.right")
                            .foregroundColor(.primary)
                    }

                }

                // Analytics
                Section("分析") {
                    NavigationLink {
                        CostsView(dashboardAPI: dashboardAPI)
                            .navigationTitle("成本")
                    } label: {
                        Label("成本", systemImage: "dollarsign.circle.fill")
                            .foregroundColor(.primary)
                    }

                }

                // System
                Section("系统") {
                    NavigationLink {
                        RelayMessagesView()
                            .environmentObject(messageStore)
                            .navigationTitle("操作卡片")
                    } label: {
                        Label("操作卡片", systemImage: "bell.badge.fill")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        GatewayDebugLogContent(
                            gateway: gateway,
                            dashboardAPI: dashboardAPI,
                            messageStore: messageStore
                        )
                        .navigationTitle("调试日志")
                    } label: {
                        Label("调试日志", systemImage: "ant.fill")
                            .foregroundColor(.primary)
                    }

                    NavigationLink {
                        SettingsFormContent(
                            gateway: gateway,
                            dashboardAPI: dashboardAPI,
                            messageStore: messageStore
                        )
                        .navigationTitle("设置")
                    } label: {
                        Label("设置", systemImage: "gear")
                            .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("更多")
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
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @ObservedObject var messageStore: MessageStore
    @State private var copyStatus: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("导出内容会包含应用名“抓控”、IronClaw、Dashboard、Relay 三个模块的连接状态、请求日志与错误信息。")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let copyStatus {
                            Text(copyStatus)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    LazyVStack(alignment: .leading, spacing: 10) {
                        debugSection(title: "IronClaw", entries: gateway.debugLog)
                        debugSection(title: "Dashboard", entries: dashboardAPI.debugLog)
                        debugSection(title: "Relay / Dashboard 推送", entries: messageStore.logs)
                        Color.clear
                            .frame(height: 1)
                            .id("debug-log-bottom")
                    }
                    .padding(8)
                }
            }
            .onChange(of: combinedLogCount) {
                withAnimation { proxy.scrollTo("debug-log-bottom", anchor: .bottom) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("复制全部") {
                    UIPasteboard.general.string = combinedDebugExportText
                    copyStatus = "已复制完整日志"
                }

                Button("清除") {
                    gateway.clearDebugLog()
                    dashboardAPI.clearDebugLog()
                    messageStore.clearDetailedLogs()
                    copyStatus = nil
                }
            }
        }
    }

    private var combinedLogCount: Int {
        gateway.debugLog.count + dashboardAPI.debugLog.count + messageStore.logs.count
    }

    private var combinedDebugExportText: String {
        [
            "应用: 抓控",
            "导出时间: \(ISO8601DateFormatter().string(from: Date()))",
            "IronClaw 已连接: \(gateway.isConnected ? "是" : "否")",
            "IronClaw 正在等待响应: \(gateway.isWaitingForResponse ? "是" : "否")",
            "Dashboard 可访问: \(dashboardAPI.isReachable ? "是" : "否")",
            "Relay 已连接: \(messageStore.isConnected ? "是" : "否")",
            "Relay 连接中: \(messageStore.isConnecting ? "是" : "否")",
            "",
            gateway.debugLogExportText,
            "",
            dashboardAPI.debugLogExportSection,
            "",
            messageStore.debugLogExportSection,
        ].joined(separator: "\n")
    }

    @ViewBuilder
    private func debugSection(title: String, entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            if entries.isEmpty {
                Text("<empty>")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(debugEntryColor(entry))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func debugEntryColor(_ entry: String) -> Color {
        if entry.contains("FAILED") || entry.contains("error") || entry.contains("Error") || entry.contains("failed") {
            return .red
        } else if entry.contains("OK") || entry.contains("succeeded") || entry.contains("connected") || entry.contains("Connected") || entry.contains("success") {
            return .green
        } else if entry.contains("/api/chat/") || entry.contains("HTTP ") || entry.contains("GET ") || entry.contains("POST ") || entry.contains("PUT ") || entry.contains("PATCH ") || entry.contains("WS ") {
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
    @State private var gatewayToken: String = ""
    @State private var dashboardURL: String = ""
    @State private var relayURL: String = ""
    @State private var isAutoDiscovering = false
    @State private var autoDiscoverResult: String?

    var body: some View {
        Form {
            // IronClaw connection
            Section {
                TextField("IronClaw 地址", text: $gatewayHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("只需要填写一次完整的 IronClaw 地址，App 会让聊天、Dashboard 和 Relay 默认跟随这个地址；支持保留 https:// 和路径前缀。")
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

            Section {
                Picker("显示模式", selection: $costDisplayModeRaw) {
                    ForEach(CostDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Toggle("OpenAI 订阅覆盖 GPT / o 系列", isOn: $openAISubscription)
                    .disabled(costDisplayMode != .effectiveBilled)

                Toggle("Anthropic 订阅覆盖 Claude", isOn: $anthropicSubscription)
                    .disabled(costDisplayMode != .effectiveBilled)

                if costPreferences.appliesSubscriptionCoverage {
                    Text("当模型名称匹配时，已被订阅覆盖的提供商会显示为计费成本 0 或“已包含”。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("成本显示")
            } footer: {
                Text("Dashboard 无法区分流量来自 API key 还是订阅席位，这里会根据识别到的模型 / 提供商名称做本地显示修正。")
            }

            // Relay server (optional)
            Section {
                TextField("Relay 地址（留空时跟随 IronClaw）", text: $relayURL)
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
                Text("默认复用 IronClaw 地址；只有推送服务单独部署时才需要单独覆盖。")
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
        .onAppear { loadCurrentSettings() }
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
        let shouldFollowGatewayForRelay = relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || storedRelay.isEmpty
            || storedRelay == previousGateway
            || Config.usesLegacyLocalRelayDefault

        gateway.updateConnection(host: normalized.host, port: normalized.port, token: gatewayToken)

        if shouldFollowGatewayForDashboard {
            dashboardURL = ""
            dashboardAPI.updateBaseURL(normalized.host)
        }

        if shouldFollowGatewayForRelay {
            relayURL = ""
            Config.persistRelayBaseURL(normalized.host)
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
        let resolved = trimmed.isEmpty ? gateway.gatewayHost : trimmed
        relayURL = trimmed.isEmpty ? "" : resolved
        Config.persistRelayBaseURL(resolved)
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
