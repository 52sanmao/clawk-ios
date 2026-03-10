import SwiftUI

// MARK: - Chat Detail View

struct ChatDetailView: View {
    @EnvironmentObject var gateway: GatewayConnection
    @EnvironmentObject var dashboardAPI: DashboardAPIClient
    let session: GatewaySession?

    @State private var messageText = ""
    @State private var showingDebugLog = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // Date header for first message
                        if let first = gateway.messages.first {
                            DateHeader(date: first.timestamp)
                                .padding(.top, 8)
                        }

                        ForEach(gateway.messages) { message in
                            ChatMessageView(
                                message: message,
                                agentIdentity: gateway.agentIdentity,
                                isCurrentUser: message.role == "user"
                            )
                            .id(message.id)
                        }

                        // Typing indicator
                        if gateway.isWaitingForResponse && gateway.thinkingSteps.isEmpty {
                            TypingBubble(status: gateway.chatStatus)
                                .id("typing")
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        // Error
                        if let error = gateway.chatError {
                            ChatErrorView(error: error, onRetry: {
                                if let lastUserMsg = gateway.messages.last(where: { $0.role == "user" }) {
                                    gateway.chatError = nil
                                    gateway.sendMessage(lastUserMsg.content)
                                }
                            })
                            .id("error")
                        }

                        // Thinking steps
                        if !gateway.thinkingSteps.isEmpty {
                            ThinkingStepsView(steps: gateway.thinkingSteps)
                                .id("thinking")
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: gateway.messages.count) { scrollToBottom(proxy) }
                .onChange(of: gateway.thinkingSteps.count) { scrollToBottom(proxy) }
                .onChange(of: gateway.chatError) { scrollToBottom(proxy) }
            }

            // Input bar
            ChatInputBar(
                text: $messageText,
                isConnected: gateway.isConnected,
                isWaiting: gateway.isWaitingForResponse,
                onSend: sendMessage
            )
            .focused($isInputFocused)
        }
        .background(Color(.systemBackground))
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatNavHeader(
                    title: navTitle,
                    isConnected: gateway.isConnected,
                    isConnecting: gateway.isConnecting
                )
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingDebugLog = true }) {
                    Image(systemName: "ant.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingDebugLog) {
            NavigationView {
                GatewayDebugLogView(gateway: gateway)
            }
        }
        .onAppear {
            if let session = session {
                gateway.switchToSession(session)
                loadSessionHistory(sessionId: session.id)
            } else {
                gateway.startNewChat()
            }
        }
    }

    private var navTitle: String {
        if let session = session {
            return session.agentName ?? session.agentId ?? "Chat"
        }
        return gateway.agentIdentity?.name ?? "New Chat"
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            gateway.sendMessage(text)
        }
        messageText = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !gateway.thinkingSteps.isEmpty {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if gateway.chatError != nil {
                proxy.scrollTo("error", anchor: .bottom)
            } else if gateway.isWaitingForResponse {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let lastMessage = gateway.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private func loadSessionHistory(sessionId: String) {
        Task {
            do {
                let messages = try await dashboardAPI.fetchSessionMessages(sessionId: sessionId)
                let recent = messages.count > 100 ? Array(messages.suffix(100)) : messages
                gateway.loadMessages(from: recent)
            } catch {
                print("[Chat] Failed to load session history: \(error)")
            }
        }
    }
}

// MARK: - Chat Nav Header (inline title with connection dot)

struct ChatNavHeader: View {
    let title: String
    let isConnected: Bool
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : (isConnecting ? Color.orange : Color.red))
                .frame(width: 7, height: 7)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
    }
}

// MARK: - Date Header

struct DateHeader: View {
    let date: Date

    var body: some View {
        Text(formatted)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.vertical, 4)
    }

    private var formatted: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        return fmt.string(from: date)
    }
}

// MARK: - Typing Bubble

struct TypingBubble: View {
    let status: String?
    @State private var phase = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Small avatar placeholder
            Circle()
                .fill(Color(.systemGray4))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .scaleEffect(i == phase % 3 ? 1.2 : 0.7)
                            .opacity(i == phase % 3 ? 1 : 0.4)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: phase)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .clipShape(BubbleShape(isUser: false))

                if let status = status {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(Color(.tertiaryLabel))
                        .padding(.leading, 10)
                }
            }

            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
        .onReceive(timer) { _ in phase += 1 }
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    @Binding var text: String
    let isConnected: Bool
    let isWaiting: Bool
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                // Text field
                TextField("Message", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .disabled(!isConnected)

                // Send button
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.blue : Color(.systemGray4))
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private var canSend: Bool {
        isConnected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWaiting
    }
}
