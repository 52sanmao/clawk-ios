import SwiftUI
import SwiftData

// MARK: - Gateway Chat View
/// Native chat interface using IronClaw HTTP/SSE.
struct GatewayChatView: View {
    @StateObject private var gateway = GatewayConnection()
    @State private var messageText = ""
    @State private var showingSettings = false
    @State private var scrollToBottom = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection status
                GatewayStatusBar(connection: gateway)
                
                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(gateway.messages) { message in
                                ChatMessageView(
                                    message: message,
                                    agentIdentity: gateway.agentIdentity,
                                    isCurrentUser: message.role == "user"
                                )
                                .id(message.id)
                            }
                            
                            // Thinking steps (show while processing)
                            if !gateway.thinkingSteps.isEmpty {
                                ThinkingStepsView(steps: gateway.thinkingSteps)
                                    .id("thinking")
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: gateway.messages.count) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: gateway.thinkingSteps.count) {
                        scrollToBottom(proxy)
                    }
                    .onAppear {
                        // Auto-scroll to bottom on appear
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                
                // Input area
                MessageInputBar(
                    text: $messageText,
                    isEnabled: gateway.isConnected,
                    onSend: sendMessage
                )
                .focused($isInputFocused)
            }
            .navigationTitle(gateway.agentIdentity?.name ?? "聊天")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionIndicator(isConnected: gateway.isConnected)
                }
            }
            .sheet(isPresented: $showingSettings) {
                GatewaySettingsView(gateway: gateway)
            }
            .onAppear {
                if !gateway.isConnected && !gateway.isConnecting {
                    gateway.connect()
                }
            }
            .onDisappear {
                // Don't disconnect - keep connection for background
            }
        }
    }
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        gateway.sendMessage(text)
        messageText = ""
    }
    
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let lastMessage = gateway.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else if !gateway.thinkingSteps.isEmpty {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("thinking", anchor: .bottom)
            }
        }
    }
}

// MARK: - Gateway Status Bar
struct GatewayStatusBar: View {
    @ObservedObject var connection: GatewayConnection
    
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let error = connection.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
            
            if !connection.isConnected {
                Button("重新连接") {
                    connection.connect()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }
    
    private var statusColor: Color {
        if connection.isConnected { return .green }
        if connection.isConnecting { return .orange }
        return .red
    }
    
    private var statusText: String {
        if connection.isConnected { return "在线" }
        if connection.isConnecting { return "连接中..." }
        return "离线"
    }
}

// MARK: - Connection Indicator
struct ConnectionIndicator: View {
    let isConnected: Bool
    
    var body: some View {
        Circle()
            .fill(isConnected ? Color.green : Color.red)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
    }
}

// MARK: - Message Input Bar
struct MessageInputBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let onSend: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            TextField("消息...", text: $text, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(1...5)
                .disabled(!isEnabled)
            
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(isEnabled && !text.isEmpty ? .blue : .gray)
            }
            .disabled(!isEnabled || text.isEmpty)
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

// MARK: - Gateway Settings View
struct GatewaySettingsView: View {
    @ObservedObject var gateway: GatewayConnection
    @Environment(\.dismiss) private var dismiss
    
    @State private var host = Config.defaultGatewayBaseURL
    @State private var showClearConfirmation = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("IronClaw 连接") {
                    TextField("IronClaw 地址", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("IronClaw Bearer Token", text: .constant(Config.defaultGatewayToken))
                        .disabled(true)

                    Text("只需要完整地址和令牌，不需要单独填写端口；如需修改令牌，请前往主设置页。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(gateway.isConnected ? "断开连接" : "连接") {
                        if gateway.isConnected {
                            gateway.disconnect()
                        } else {
                            // Reinitialize with new settings
                            dismiss()
                        }
                    }
                    .foregroundColor(gateway.isConnected ? .red : .blue)
                }
                
                Section("代理身份") {
                    if let identity = gateway.agentIdentity {
                        HStack {
                            Text("名称")
                            Spacer()
                            Text(identity.name)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("生物")
                            Spacer()
                            Text(identity.creature)
                                .foregroundColor(.secondary)
                        }
                        
                        if let vibe = identity.vibe {
                            HStack {
                                Text("风格")
                                Spacer()
                                Text(vibe)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("表情")
                            Spacer()
                            Text(identity.emoji)
                        }
                    } else {
                        Text("尚未同步身份")
                            .foregroundColor(.secondary)
                    }
                }

                Section("聊天记录") {
                    Button("清除消息") {
                        showClearConfirmation = true
                    }
                    .foregroundColor(.red)
                    
                    Text("\(gateway.messages.count) 条消息")
                        .foregroundColor(.secondary)
                }
                
                Section("调试") {
                    Text("设备令牌: \(gateway.publicDeviceToken.prefix(8))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("IronClaw 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("清除消息？", isPresented: $showClearConfirmation) {
                Button("取消", role: .cancel) { }
                Button("清除", role: .destructive) {
                    gateway.clearMessages()
                }
            } message: {
                Text("这将删除当前会话中的所有消息。")
            }
        }
    }
}

// MARK: - Preview
struct GatewayChatView_Previews: PreviewProvider {
    static var previews: some View {
        GatewayChatView()
    }
}
