import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: MessageStore
    @State private var showLogs = false
    
    var body: some View {
        NavigationView {
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
                
                // Logs panel (expandable)
                if showLogs {
                    LogsView(logs: store.logs, onClear: { store.clearLogs() })
                        .frame(height: 150)
                }
            }
            .navigationTitle("智爪")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showLogs.toggle() }) {
                        Image(systemName: showLogs ? "doc.text.fill" : "doc.text")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: { store.manualRefresh() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isConnecting)
                    }
                }
            }
        }
    }
}

struct MessageCard: View {
    let message: ClawkMessage
    let onAction: (String) -> Void
    @State private var hasResponded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.message)
                .font(.body)
            
            if !message.responded && !hasResponded {
                FlowLayout(spacing: 8) {
                    ForEach(Array(message.actions.enumerated()), id: \.offset) { index, action in
                        ActionButton(
                            action: action,
                            isEnabled: !hasResponded,
                            onTap: { selectedAction in
                                hasResponded = true
                                onAction(selectedAction)
                            }
                        )
                    }
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已回复: \(message.response ?? "")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct ConnectionStatus: View {
    let isConnected: Bool
    let isConnecting: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            if isConnecting {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                Text("连接中...")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("在线")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("离线")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
}

struct ActionButton: View {
    let action: String
    let isEnabled: Bool
    let onTap: (String) -> Void
    
    var body: some View {
        Button(action: { 
            if isEnabled {
                onTap(action)
            }
        }) {
            Text(action)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isEnabled ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .disabled(!isEnabled)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无消息")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("下拉刷新或等待新消息")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

struct ConnectingState: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在连接服务器...")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("请确保 Config.swift 中的URL正确")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct LogsView: View {
    let logs: [String]
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("调试日志")
                    .font(.caption.bold())
                Spacer()
                Button("清除", action: onClear)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground))
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .onChange(of: logs.count) {
                    if let last = logs.indices.last {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }
}

