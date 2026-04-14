import SwiftUI
import SwiftData

@main
struct ClawkApp: App {
    @StateObject private var gateway = GatewayConnection()
    @StateObject private var dashboardAPI = DashboardAPIClient()
    @StateObject private var messageStore = MessageStore()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(gateway)
                .environmentObject(dashboardAPI)
                .environmentObject(messageStore)
                .onAppear {
                    Task {
                        // Check dashboard health first
                        await dashboardAPI.checkHealth()

                        print("[App] Gateway token from UserDefaults: \(gateway.gatewayToken.isEmpty ? "EMPTY" : String(gateway.gatewayToken.prefix(8)) + "...")")

                        // Auto-discover gateway config from dashboard if no token saved
                        if gateway.gatewayToken.isEmpty {
                            do {
                                let config = try await dashboardAPI.fetchGatewayConfig()
                                if let url = config.url {
                                    var host = "wss://kishs-mac-mini-1.tail6e4c16.ts.net/ws"
                                    var port = 18790
                                    if let components = URLComponents(string: url) {
                                        host = components.host ?? host
                                        port = components.port ?? port
                                    }
                                    let token = config.token ?? ""
                                    gateway.updateConnection(host: host, port: port, token: token)
                                    return
                                }
                            } catch {
                                print("[App] Auto-discover failed: \(error)")
                            }
                        }

                        // Connect with existing config
                        if !gateway.isConnected && !gateway.isConnecting {
                            gateway.connect()
                        }
                    }
                }
        }
        .modelContainer(for: [PersistedMessage.self, PersistedSession.self, AgentIdentityRecord.self])
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var gateway: GatewayConnection
    @EnvironmentObject var dashboardAPI: DashboardAPIClient
    @EnvironmentObject var messageStore: MessageStore
    @State private var selectedMainTab = 0

    var body: some View {
        TabView(selection: $selectedMainTab) {
            // 1. Home (overview + snapshots + more)
            HomeView(selectedTab: $selectedMainTab)
                .tag(0)
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .badge(gateway.pendingApprovals.count)

            // 2. Chat (list view → detail)
            ChatListView()
                .tag(1)
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
                }

            // 3. Cron
            CronTab()
                .tag(2)
                .tabItem {
                    Label("定时任务", systemImage: "clock.arrow.circlepath")
                }

            // 4. Memory
            MemoryTab()
                .tag(3)
                .tabItem {
                    Label("记忆", systemImage: "brain.head.profile")
                }
        }
    }
}

// MARK: - Cron Tab

struct CronTab: View {
    @EnvironmentObject var gateway: GatewayConnection

    var body: some View {
        NavigationStack {
            CronManagementView(gateway: gateway)
                .navigationTitle("定时任务")
        }
    }
}

// MARK: - Memory Tab

struct MemoryTab: View {
    @EnvironmentObject var dashboardAPI: DashboardAPIClient

    var body: some View {
        NavigationStack {
            MemoryView(dashboardAPI: dashboardAPI)
                .navigationTitle("记忆")
        }
    }
}

// MARK: - Chat Error View

struct ChatErrorView: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text("重试")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundColor(.blue)
                )

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(dotOpacity(for: index)))
                        .frame(width: 8, height: 8)
                        .scaleEffect(dotScale(for: index))
                        .animation(.easeInOut(duration: 0.3), value: dotCount)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            Spacer()
        }
        .padding(.horizontal, 16)
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let active = dotCount % 3
        return index == active ? 1.0 : 0.4
    }

    private func dotScale(for index: Int) -> CGFloat {
        let active = dotCount % 3
        return index == active ? 1.2 : 0.8
    }
}

// MARK: - Debug Log View (used as sheet from ChatDetailView)

struct GatewayDebugLogView: View {
    @ObservedObject var gateway: GatewayConnection
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(gateway.debugLog.enumerated()), id: \.offset) { index, entry in
                        Text(entry)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(entryColor(entry))
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
        .navigationTitle("网关调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("清除") {
                    gateway.debugLog.removeAll()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func entryColor(_ entry: String) -> Color {
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
