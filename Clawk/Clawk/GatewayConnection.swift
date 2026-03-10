import Foundation
import Combine
import os.log

private let gatewayLog = Logger(subsystem: "com.kishparikh.clawk", category: "Gateway")

// MARK: - OpenClaw Gateway Connection (Protocol v3)

/// Direct WebSocket connection to OpenClaw Gateway using Protocol v3
/// Supports full RPC methods: chat, sessions, agents, cron, logs, approvals
class GatewayConnection: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String?

    // Chat state
    @Published var messages: [GatewayChatMessage] = []
    @Published var thinkingSteps: [GatewayThinkingStep] = []
    @Published var currentSessionId: String?
    @Published var currentSessionKey: String?
    @Published var isWaitingForResponse = false
    @Published var chatError: String?
    @Published var chatStatus: String?  // Step-by-step status: "Sending...", "Waiting for agent...", etc.
    @Published var debugLog: [String] = []  // In-app debug log for gateway events
    private var responseTimeoutTimer: Timer?

    // Agent state
    @Published var agentIdentity: GatewayAgentIdentity?
    @Published var agents: [GatewayAgent] = []

    // Session state
    @Published var sessions: [GatewaySession] = []

    // Cron state
    @Published var cronJobs: [GatewayCronJob] = []
    @Published var cronStatus: GatewayCronStatus?

    // Approval state
    @Published var pendingApprovals: [GatewayApproval] = []

    // Gateway state
    @Published var gatewayStatus: GatewayStatusResponse?

    // Public token accessor
    var publicDeviceToken: String { deviceToken }

    // MARK: - Event Publishers

    let eventSubject = PassthroughSubject<(GatewayEventType, [String: Any]), Never>()
    let logSubject = PassthroughSubject<GatewayLogEntry, Never>()

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var pendingRequests: [String: PendingRequest] = [:]
    private let rpcLock = NSLock()
    private var pendingToolCalls: [String: GatewayToolCall] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var connectNonce: String?
    private var connectSent = false

    // Configuration
    private(set) var gatewayHost: String
    private(set) var gatewayPort: Int
    private(set) var gatewayToken: String
    private var deviceToken: String
    private var tickIntervalMs: Int = 15000

    // MARK: - Initialization

    init(host: String? = nil, port: Int? = nil, token: String? = nil) {
        self.gatewayHost = host ?? UserDefaults.standard.string(forKey: "gatewayHost") ?? "100.96.61.83"
        self.gatewayPort = port ?? UserDefaults.standard.integer(forKey: "gatewayPort").nonZero ?? 18789
        self.gatewayToken = token ?? UserDefaults.standard.string(forKey: "gatewayToken") ?? "b3b6e49d493b3f0f8443575ebfd9fb1caaf103a5e333d106"
        self.deviceToken = UserDefaults.standard.string(forKey: "gatewayDeviceToken") ?? UUID().uuidString
        super.init()

        if UserDefaults.standard.string(forKey: "gatewayDeviceToken") == nil {
            UserDefaults.standard.set(deviceToken, forKey: "gatewayDeviceToken")
        }
    }

    // MARK: - Debug Logging

    private func debugAppend(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(msg)"
        DispatchQueue.main.async {
            self.debugLog.append(entry)
            if self.debugLog.count > 100 {
                self.debugLog.removeFirst()
            }
        }
        NSLog("[GW] %@", msg)
    }

    // MARK: - Connection Management

    func connect() {
        guard !isConnecting && !isConnected else { return }

        DispatchQueue.main.async {
            self.isConnecting = true
            self.connectionError = nil
        }

        let urlString = "ws://\(gatewayHost):\(gatewayPort)"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.connectionError = "Invalid gateway URL"
                self.isConnecting = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        receiveMessage()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)

        // Cancel all pending requests
        rpcLock.lock()
        let allPending = pendingRequests
        pendingRequests.removeAll()
        callbackRequests.removeAll()
        rpcLock.unlock()
        for (_, request) in allPending {
            request.cancel()
        }
        connectSent = false
        connectNonce = nil

        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
        }
    }

    func updateConnection(host: String, port: Int, token: String = "") {
        UserDefaults.standard.set(host, forKey: "gatewayHost")
        UserDefaults.standard.set(port, forKey: "gatewayPort")
        UserDefaults.standard.set(token, forKey: "gatewayToken")

        self.gatewayHost = host
        self.gatewayPort = port
        self.gatewayToken = token

        disconnect()
        connect()
    }

    private func reconnect() {
        disconnect()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    // MARK: - Protocol v3 Handshake

    private func performHandshake() {
        guard !connectSent else { return }
        connectSent = true

        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "cli",
                "displayName": "Clawk iOS",
                "version": "2.0",
                "platform": "ios",
                "mode": "ui"
            ] as [String: Any],
            "role": "operator",
            "scopes": ["operator.read", "operator.write", "operator.admin", "operator.approvals"],
            "caps": ["tool-events"] as [String]
        ]

        if !gatewayToken.isEmpty {
            params["auth"] = ["token": gatewayToken]
        }

        let tokenPrefix = String(gatewayToken.prefix(8))
        print("[Gateway] Sending connect request, token=\(gatewayToken.isEmpty ? "NONE" : tokenPrefix + "..."), host=\(gatewayHost), nonce=\(connectNonce ?? "nil")")

        sendRequest(method: "connect", params: params) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let payload):
                    print("[Gateway] Connect succeeded!")
                    // Extract device token from response
                    if let auth = payload["auth"] as? [String: Any],
                       let newToken = auth["deviceToken"] as? String {
                        self?.deviceToken = newToken
                        UserDefaults.standard.set(newToken, forKey: "gatewayDeviceToken")
                    }

                    // Extract tick interval
                    if let policy = payload["policy"] as? [String: Any],
                       let tick = policy["tickIntervalMs"] as? Int {
                        self?.tickIntervalMs = tick
                    }

                    self?.isConnected = true
                    self?.isConnecting = false
                    self?.connectionError = nil

                    // Load initial data
                    self?.loadInitialData()

                case .failure(let error):
                    print("[Gateway] Connect failed: \(error)")
                    self?.connectionError = error.localizedDescription
                    self?.isConnecting = false
                }
            }
        }
    }

    private func loadInitialData() {
        Task {
            // Load agents and cron in parallel
            async let agentsResult: () = loadAgents()
            async let cronResult: () = loadCronJobs()
            async let identityResult: () = loadAgentIdentity()
            _ = await (agentsResult, cronResult, identityResult)
        }
    }

    private func loadAgents() async {
        do {
            let agents = try await agentsList()
            print("[Gateway] Loaded \(agents.count) agents: \(agents.map { $0.id })")
            await MainActor.run { self.agents = agents }
        } catch {
            print("[Gateway] Failed to load agents: \(error)")
        }
    }

    private func loadCronJobs() async {
        do {
            let jobs = try await cronList()
            print("[Gateway] Loaded \(jobs.count) cron jobs: \(jobs.map { $0.displayName })")
            await MainActor.run { self.cronJobs = jobs }
        } catch {
            print("[Gateway] Failed to load cron jobs: \(error)")
        }
    }

    private func loadAgentIdentity() async {
        do {
            let identity = try await getAgentIdentity()
            print("[Gateway] Agent identity: \(identity.name) \(identity.emoji)")
            await MainActor.run { self.agentIdentity = identity }
        } catch {
            print("[Gateway] Failed to load agent identity: \(error)")
        }
    }

    // MARK: - RPC Infrastructure

    private func nextRequestId() -> String {
        UUID().uuidString.lowercased()
    }

    /// Send an RPC request and get the response via callback
    private func sendRequest(method: String, params: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextRequestId()

        let frame: [String: Any] = [
            "type": "req",
            "id": id,
            "method": method,
            "params": params
        ]

        let pendingReq = CallbackRequest(completion: completion)
        rpcLock.lock()
        callbackRequests[id] = pendingReq
        rpcLock.unlock()

        sendJSON(frame)

        // Timeout after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self else { return }
            self.rpcLock.lock()
            let req = self.callbackRequests.removeValue(forKey: id)
            self.rpcLock.unlock()
            req?.completion(.failure(GatewayError.timeout))
        }
    }

    /// Async/await version of RPC call
    func rpc(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isConnected || method == "connect" else {
            throw GatewayError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            let id = nextRequestId()
            let pending = PendingRequest(id: id, method: method, continuation: continuation)

            rpcLock.lock()
            pendingRequests[id] = pending
            rpcLock.unlock()

            let frame: [String: Any] = [
                "type": "req",
                "id": id,
                "method": method,
                "params": params
            ]
            sendJSON(frame)

            // Timeout after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self = self else { return }
                self.rpcLock.lock()
                let req = self.pendingRequests.removeValue(forKey: id)
                self.rpcLock.unlock()
                req?.cancel()
            }
        }
    }

    private var callbackRequests: [String: CallbackRequest] = [:]

    private class CallbackRequest {
        let completion: (Result<[String: Any], Error>) -> Void
        init(completion: @escaping (Result<[String: Any], Error>) -> Void) {
            self.completion = completion
        }
    }

    // MARK: - WebSocket Send/Receive

    private func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("[Gateway] Send error: \(error)")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleWebSocketMessage(message)
                self?.receiveMessage()
            case .failure(let error):
                print("[Gateway] Receive error: \(error)")
                DispatchQueue.main.async {
                    self?.connectionError = error.localizedDescription
                    self?.isConnected = false
                    self?.isConnecting = false
                }
                self?.reconnect()
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            if case .string(let text) = message {
                gatewayLog.warning("Unparseable frame: \(text.prefix(200))")
            }
            return
        }

        // Log non-tick frames for debugging
        if type != "event" || (json["event"] as? String) != "tick" {
            let method = json["method"] as? String ?? json["event"] as? String ?? ""
            NSLog("[Gateway] Frame: type=%@ %@", type, method)
        }

        switch type {
        case "req":
            handleServerRequest(json)
        case "res":
            handleResponse(json)
        case "event":
            handleEvent(json)
        case "hello-ok":
            // Direct hello-ok response (alternative to type: "res")
            handleHelloOk(json)
        default:
            handleLegacyMessage(json)
        }
    }

    private func handleHelloOk(_ json: [String: Any]) {
        print("[Gateway] Received direct hello-ok")
        DispatchQueue.main.async { [weak self] in
            if let auth = json["auth"] as? [String: Any],
               let newToken = auth["deviceToken"] as? String {
                self?.deviceToken = newToken
                UserDefaults.standard.set(newToken, forKey: "gatewayDeviceToken")
            }
            if let policy = json["policy"] as? [String: Any],
               let tick = policy["tickIntervalMs"] as? Int {
                self?.tickIntervalMs = tick
            }
            self?.isConnected = true
            self?.isConnecting = false
            self?.connectionError = nil
            self?.loadInitialData()

            // Resolve any pending connect callback
            self?.rpcLock.lock()
            let callbacks = self?.callbackRequests ?? [:]
            self?.callbackRequests.removeAll()
            self?.rpcLock.unlock()
            for (_, callback) in callbacks {
                callback.completion(.success(json))
            }
        }
    }

    // MARK: - Response Handling

    private func handleResponse(_ json: [String: Any]) {
        // Support both string and int IDs
        let id: String
        if let strId = json["id"] as? String {
            id = strId
        } else if let intId = json["id"] as? Int {
            id = "\(intId)"
        } else {
            return
        }
        let ok = json["ok"] as? Bool ?? false
        let payload = json["payload"] as? [String: Any] ?? [:]

        // Check async pending requests first
        rpcLock.lock()
        let pending = pendingRequests.removeValue(forKey: id)
        rpcLock.unlock()

        if let pending = pending {
            if ok {
                pending.resume(with: payload)
            } else {
                let errorInfo = json["error"] as? [String: Any] ?? [:]
                let code = errorInfo["code"] as? String ?? "UNKNOWN"
                let message = errorInfo["message"] as? String ?? "Unknown error"
                pending.fail(with: GatewayError.from(code: code, message: message))
            }
            return
        }

        // Check callback requests
        rpcLock.lock()
        let callback = callbackRequests.removeValue(forKey: id)
        rpcLock.unlock()

        if let callback = callback {
            if ok {
                callback.completion(.success(payload))
            } else {
                let errorInfo = json["error"] as? [String: Any] ?? [:]
                let code = errorInfo["code"] as? String ?? "UNKNOWN"
                let message = errorInfo["message"] as? String ?? "Unknown error"
                callback.completion(.failure(GatewayError.from(code: code, message: message)))
            }
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ json: [String: Any]) {
        guard let eventName = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        // Handle connect.challenge before dispatching to event system
        if eventName == "connect.challenge" {
            let nonce = payload["nonce"] as? String
            print("[Gateway] Received connect.challenge, nonce=\(nonce ?? "nil")")
            connectNonce = nonce
            // Re-send connect with the nonce if we already sent one
            if connectSent {
                connectSent = false
                performHandshake()
            }
            return
        }

        let eventType = GatewayEventType(rawValue: eventName)

        DispatchQueue.main.async { [weak self] in
            self?.eventSubject.send((eventType, payload))

            if eventType != .tick {
                self?.debugAppend("Event: \(eventName), keys: \(Array(payload.keys).joined(separator: ","))")
            }

            switch eventType {
            case .tick:
                break // Keepalive, no action needed
            case .agent:
                self?.handleAgentEvent(payload)
            case .chat:
                // Gateway sends "chat" events with state: "delta", "final", "error"
                self?.handleChatEvent(payload)
            case .chatFinal:
                self?.handleChatFinal(payload)
            case .lifecycleStart:
                // Agent started executing — clear waiting, show thinking
                if self?.isWaitingForResponse == true {
                    self?.isWaitingForResponse = false
                    self?.chatError = nil
                    self?.cancelResponseTimeout()
                }
            case .lifecycleEnd:
                self?.isWaitingForResponse = false
                self?.cancelResponseTimeout()
                self?.thinkingSteps.removeAll()
            case .cronAdded, .cronUpdated, .cronStarted, .cronFinished, .cronRemoved:
                self?.handleCronEvent(eventType, payload: payload)
            case .approvalRequested:
                self?.handleApprovalEvent(payload)
            case .presence:
                break
            case .shutdown:
                self?.connectionError = "Gateway shutting down"
                self?.isConnected = false
            case .unknown:
                gatewayLog.debug("Unknown event: \(eventName)")
                break
            }
        }
    }

    private func handleAgentEvent(_ payload: [String: Any]) {
        guard let agentEventType = payload["type"] as? String else {
            debugAppend("agent event missing 'type', keys: \(Array(payload.keys))")
            return
        }
        debugAppend("Agent event: \(agentEventType)")

        // Any agent event means we got a response — clear waiting state
        if isWaitingForResponse {
            isWaitingForResponse = false
            chatError = nil
            chatStatus = "Agent responding..."
            cancelResponseTimeout()
        }

        switch agentEventType {
        case "text_delta", "text":
            let delta = payload["text"] as? String ?? payload["delta"] as? String ?? ""
            appendToCurrentMessage(delta: delta)

        case "thinking":
            let content = payload["content"] as? String ?? payload["text"] as? String ?? ""
            let id = payload["id"] as? String ?? UUID().uuidString
            let step = GatewayThinkingStep(id: id, content: content, timestamp: Date(), type: .thinking)
            if let index = thinkingSteps.firstIndex(where: { $0.id == id }) {
                thinkingSteps[index] = step
            } else {
                thinkingSteps.append(step)
            }

        case "tool_use", "tool_call":
            let id = payload["id"] as? String ?? UUID().uuidString
            let name = payload["name"] as? String ?? "unknown"
            let args = payload["arguments"] as? [String: Any] ?? payload["input"] as? [String: Any] ?? [:]
            let toolCall = GatewayToolCall(id: id, name: name, arguments: args)
            pendingToolCalls[id] = toolCall

            let step = GatewayThinkingStep(id: id, content: "Using \(name)...", timestamp: Date(), type: .toolCall, toolName: name)
            thinkingSteps.append(step)

        case "tool_result":
            let toolCallId = payload["toolCallId"] as? String ?? payload["tool_use_id"] as? String ?? ""
            let status = payload["status"] as? String ?? "ok"
            let duration = payload["durationMs"] as? Int

            if let index = thinkingSteps.firstIndex(where: { $0.id == toolCallId }) {
                var step = thinkingSteps[index]
                step = GatewayThinkingStep(
                    id: toolCallId,
                    content: step.content,
                    timestamp: step.timestamp,
                    type: .toolResult,
                    toolName: step.toolName,
                    status: status,
                    durationMs: duration
                )
                thinkingSteps[index] = step
            }
            pendingToolCalls.removeValue(forKey: toolCallId)

        case "message":
            // Complete message in one event
            if let content = payload["content"] as? String {
                let id = payload["id"] as? String ?? UUID().uuidString
                let role = payload["role"] as? String ?? "assistant"
                let msg = GatewayChatMessage(id: id, role: role, content: content, isStreaming: false)
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index] = msg
                } else {
                    messages.append(msg)
                }
                thinkingSteps.removeAll()
            }

        case "identity":
            agentIdentity = GatewayAgentIdentity(
                name: payload["name"] as? String ?? "Assistant",
                creature: payload["creature"] as? String ?? "AI",
                vibe: payload["vibe"] as? String,
                emoji: payload["emoji"] as? String ?? "🤖",
                color: payload["color"] as? String ?? "#6B7280"
            )

        default:
            break
        }
    }

    private func appendToCurrentMessage(delta: String) {
        isWaitingForResponse = false
        chatError = nil
        cancelResponseTimeout()
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == "assistant" && messages[lastIndex].isStreaming {
            messages[lastIndex] = GatewayChatMessage(
                id: messages[lastIndex].id,
                role: "assistant",
                content: messages[lastIndex].content + delta,
                timestamp: messages[lastIndex].timestamp,
                thinking: messages[lastIndex].thinking,
                isStreaming: true
            )
        } else {
            let msg = GatewayChatMessage(
                id: UUID().uuidString,
                role: "assistant",
                content: delta,
                isStreaming: true
            )
            messages.append(msg)
        }
    }

    /// Replace current streaming message content with full text (for chat delta events)
    private func replaceCurrentMessage(fullText: String) {
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == "assistant" && messages[lastIndex].isStreaming {
            messages[lastIndex] = GatewayChatMessage(
                id: messages[lastIndex].id,
                role: "assistant",
                content: fullText,
                timestamp: messages[lastIndex].timestamp,
                thinking: messages[lastIndex].thinking,
                isStreaming: true
            )
        } else {
            let msg = GatewayChatMessage(
                id: UUID().uuidString,
                role: "assistant",
                content: fullText,
                isStreaming: true
            )
            messages.append(msg)
        }
    }

    /// Handle "chat" events from gateway — state can be "delta", "final", or "error"
    private func handleChatEvent(_ payload: [String: Any]) {
        let state = payload["state"] as? String ?? "unknown"
        let runId = payload["runId"] as? String
        debugAppend("chat event: state=\(state), runId=\(runId ?? "nil")")

        switch state {
        case "delta":
            // Streaming text delta — content is FULL accumulated text (not incremental)
            if let message = payload["message"] as? [String: Any] {
                let fullText: String
                if let contentBlocks = message["content"] as? [[String: Any]] {
                    fullText = contentBlocks.compactMap { block -> String? in
                        if block["type"] as? String == "text" { return block["text"] as? String }
                        return nil
                    }.joined(separator: "\n")
                } else if let contentStr = message["content"] as? String {
                    fullText = contentStr
                } else {
                    return
                }

                isWaitingForResponse = false
                chatError = nil
                chatStatus = "Streaming..."
                cancelResponseTimeout()
                replaceCurrentMessage(fullText: fullText)
            }

        case "final":
            // Final complete response
            handleChatFinal(payload)

        case "error":
            // Error response
            let errorMsg = payload["errorMessage"] as? String ?? "Agent error"
            debugAppend("chat error: \(errorMsg)")
            isWaitingForResponse = false
            chatStatus = nil
            chatError = errorMsg
            cancelResponseTimeout()

        default:
            debugAppend("Unknown chat state: \(state)")
        }
    }

    private func handleChatFinal(_ payload: [String: Any]) {
        debugAppend("chat:final received")
        isWaitingForResponse = false
        chatError = nil
        chatStatus = nil
        cancelResponseTimeout()
        if let message = payload["message"] as? [String: Any] {
            let id = message["id"] as? String ?? messages.last?.id ?? UUID().uuidString
            let role = message["role"] as? String ?? "assistant"

            // Content can be a string OR an array of blocks [{ type: "text", text: "..." }]
            let content: String
            if let contentStr = message["content"] as? String {
                content = contentStr
            } else if let contentBlocks = message["content"] as? [[String: Any]] {
                content = contentBlocks.compactMap { block -> String? in
                    if block["type"] as? String == "text" {
                        return block["text"] as? String
                    }
                    return nil
                }.joined(separator: "\n")
            } else {
                content = messages.last?.content ?? ""
            }

            let finalMsg = GatewayChatMessage(id: id, role: role, content: content, isStreaming: false)
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index] = finalMsg
            } else if let lastIndex = messages.indices.last, messages[lastIndex].isStreaming {
                // Mark current streaming message as final with updated content
                messages[lastIndex] = GatewayChatMessage(
                    id: messages[lastIndex].id,
                    role: messages[lastIndex].role,
                    content: content.isEmpty ? messages[lastIndex].content : content,
                    timestamp: messages[lastIndex].timestamp,
                    isStreaming: false
                )
            } else if !content.isEmpty {
                // No streaming message exists — add as new message
                messages.append(finalMsg)
            }
        } else if let lastIndex = messages.indices.last, messages[lastIndex].isStreaming {
            // No message in payload but we have a streaming message — mark it as done
            messages[lastIndex] = GatewayChatMessage(
                id: messages[lastIndex].id,
                role: messages[lastIndex].role,
                content: messages[lastIndex].content,
                timestamp: messages[lastIndex].timestamp,
                isStreaming: false
            )
        }
        thinkingSteps.removeAll()
    }

    private func handleCronEvent(_ eventType: GatewayEventType, payload: [String: Any]) {
        // Refresh cron jobs list on any cron event
        Task {
            await loadCronJobs()
        }
    }

    private func handleApprovalEvent(_ payload: [String: Any]) {
        let approval = GatewayApproval(
            id: payload["id"] as? String ?? UUID().uuidString,
            command: payload["command"] as? String,
            tool: payload["tool"] as? String,
            arguments: payload["arguments"] as? [String: String],
            context: payload["context"] as? String,
            requestedAt: payload["requestedAt"] as? String,
            status: "pending"
        )
        pendingApprovals.append(approval)
    }

    private func handleServerRequest(_ json: [String: Any]) {
        // Handle server-initiated requests
        guard let method = json["method"] as? String else { return }
        print("[Gateway] Server request: \(method)")

        // Respond to any server requests
        let id = json["id"]
        if id != nil {
            let response: [String: Any] = ["type": "res", "id": id!, "ok": true, "payload": [:] as [String: Any]]
            sendJSON(response)
        }
    }

    private func handleLegacyMessage(_ json: [String: Any]) {
        // Handle old-style messages for backward compatibility
        guard let type = json["type"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "hello":
                self?.connectSent = false
                self?.performHandshake()
            case "message":
                self?.handleLegacyChatMessage(json)
            case "thinking":
                let id = json["id"] as? String ?? UUID().uuidString
                let content = json["content"] as? String ?? ""
                let step = GatewayThinkingStep(id: id, content: content, timestamp: Date(), type: .thinking)
                if let index = self?.thinkingSteps.firstIndex(where: { $0.id == id }) {
                    self?.thinkingSteps[index] = step
                } else {
                    self?.thinkingSteps.append(step)
                }
            case "toolCall":
                let id = json["id"] as? String ?? UUID().uuidString
                let name = json["name"] as? String ?? "unknown"
                let toolCall = GatewayToolCall(id: id, name: name, arguments: json["arguments"] as? [String: Any] ?? [:])
                self?.pendingToolCalls[id] = toolCall
                let step = GatewayThinkingStep(id: id, content: "Using \(name)...", timestamp: Date(), type: .toolCall, toolName: name)
                self?.thinkingSteps.append(step)
            case "toolResult":
                let toolCallId = json["toolCallId"] as? String ?? ""
                let status = json["status"] as? String ?? "ok"
                let duration = json["durationMs"] as? Int
                if let self = self, let index = self.thinkingSteps.firstIndex(where: { $0.id == toolCallId }) {
                    let existing = self.thinkingSteps[index]
                    self.thinkingSteps[index] = GatewayThinkingStep(
                        id: toolCallId, content: existing.content, timestamp: existing.timestamp,
                        type: .toolResult, toolName: existing.toolName, status: status, durationMs: duration
                    )
                }
                self?.pendingToolCalls.removeValue(forKey: toolCallId)
            case "identity":
                self?.agentIdentity = GatewayAgentIdentity(
                    name: json["name"] as? String ?? "Assistant",
                    creature: json["creature"] as? String ?? "AI",
                    vibe: json["vibe"] as? String,
                    emoji: json["emoji"] as? String ?? "🤖",
                    color: json["color"] as? String ?? "#6B7280"
                )
            case "error":
                self?.connectionError = json["message"] as? String
            default:
                break
            }
        }
    }

    private func handleLegacyChatMessage(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let role = json["role"] as? String,
              let content = json["content"] as? String else { return }

        let msg = GatewayChatMessage(
            id: id, role: role, content: content,
            thinking: json["thinking"] as? String,
            isStreaming: json["streaming"] as? Bool ?? false
        )

        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = msg
        } else {
            messages.append(msg)
        }

        if !(json["streaming"] as? Bool ?? false) {
            thinkingSteps.removeAll()
        }
    }

    // MARK: - Chat Methods

    func sendMessage(_ content: String, sessionKey: String? = nil) {
        // Add user message locally immediately
        let userMsg = GatewayChatMessage(id: UUID().uuidString, role: "user", content: content)
        DispatchQueue.main.async {
            self.messages.append(userMsg)
            self.isWaitingForResponse = true
            self.chatError = nil
            self.chatStatus = "Sending..."
            self.startResponseTimeout()
        }
        debugAppend("sendMessage: \(content.prefix(60))...")

        // Resolve session key: explicit param > current session key > generate new one
        let resolvedKey = sessionKey ?? currentSessionKey ?? "agent:main:ios:dm:clawk-\(Int(Date().timeIntervalSince1970 * 1000))"

        // Gateway expects { sessionKey, message, idempotencyKey }
        let idempotencyKey = "clawk-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let params: [String: Any] = [
            "sessionKey": resolvedKey,
            "message": content,
            "idempotencyKey": idempotencyKey
        ]

        debugAppend("RPC chat.send → sessionKey=\(resolvedKey)")

        Task {
            do {
                let result = try await rpc(method: "chat.send", params: params)
                let resultKeys = Array(result.keys).joined(separator: ",")
                debugAppend("chat.send OK → keys: \(resultKeys)")
                // Track the session key for subsequent messages
                await MainActor.run {
                    self.chatStatus = "Waiting for agent..."
                    if self.currentSessionKey == nil {
                        self.currentSessionKey = resolvedKey
                    }
                    // Extract session ID if returned
                    if let sessionId = result["sessionId"] as? String ?? result["resolvedSessionId"] as? String {
                        self.currentSessionId = sessionId
                    }
                }
            } catch {
                let isTimeout: Bool
                if let gwError = error as? GatewayError, case .timeout = gwError {
                    isTimeout = true
                } else {
                    isTimeout = false
                }

                if isTimeout {
                    // RPC timeout is OK — the gateway may hold the RPC open while the agent works.
                    // Events stream independently. The response timeout timer handles the "no events" case.
                    debugAppend("chat.send RPC timed out (30s) — still waiting for events")
                    await MainActor.run {
                        self.chatStatus = "Agent processing (RPC timeout, waiting for events)..."
                    }
                } else {
                    // Real errors (NOT_LINKED, UNAVAILABLE, etc.) — show to user immediately
                    debugAppend("chat.send FAILED: \(error.localizedDescription)")
                    await MainActor.run {
                        // Only show error if we haven't already received events
                        if self.isWaitingForResponse {
                            self.isWaitingForResponse = false
                            self.cancelResponseTimeout()
                            self.chatStatus = nil
                            self.chatError = "Failed to send: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func startResponseTimeout() {
        responseTimeoutTimer?.invalidate()
        responseTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.isWaitingForResponse else { return }
                self.isWaitingForResponse = false
                self.chatStatus = nil
                self.chatError = "No response from agent (timed out after 15s). Check the debug log (🐜) for details."
                self.debugAppend("TIMEOUT: No agent/chat events received within 15s")
            }
        }
    }

    private func cancelResponseTimeout() {
        responseTimeoutTimer?.invalidate()
        responseTimeoutTimer = nil
    }

    /// Start a new chat session, clearing messages and resetting the session key
    func startNewChat(agentId: String = "main") {
        cancelResponseTimeout()
        DispatchQueue.main.async {
            self.messages.removeAll()
            self.thinkingSteps.removeAll()
            self.currentSessionKey = nil
            self.currentSessionId = nil
            self.isWaitingForResponse = false
            self.chatError = nil
        }
    }

    /// Switch to an existing session by key or ID
    func switchToSession(_ session: GatewaySession) {
        DispatchQueue.main.async {
            self.messages.removeAll()
            self.thinkingSteps.removeAll()
            self.currentSessionKey = session.sessionKey
            self.currentSessionId = session.id
        }
    }

    /// Load messages from dashboard API session messages
    func loadMessages(from sessionMessages: [SessionMessage]) {
        let chatMessages = sessionMessages.compactMap { msg -> GatewayChatMessage? in
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty messages, tool-only messages, and system commands
            guard !content.isEmpty,
                  (msg.role == "user" || msg.role == "assistant"),
                  !content.hasPrefix("<local-command"),
                  !content.hasPrefix("<command-"),
                  msg.toolCalls == nil || !content.isEmpty else { return nil }
            return GatewayChatMessage(
                id: msg.id,
                role: msg.role,
                content: content,
                isStreaming: false
            )
        }
        DispatchQueue.main.async {
            self.messages = chatMessages
        }
        print("[Gateway] Loaded \(chatMessages.count) displayable messages from \(sessionMessages.count) total")
    }

    func chatAbort() async throws {
        let _ = try await rpc(method: "chat.abort")
    }

    func chatHistory(sessionId: String? = nil, sessionKey: String? = nil) async throws -> [[String: Any]] {
        var params: [String: Any] = [:]
        if let sessionKey = sessionKey ?? currentSessionKey {
            params["sessionKey"] = sessionKey
        }
        if let sessionId = sessionId {
            params["sessionId"] = sessionId
        }
        let result = try await rpc(method: "chat.history", params: params)
        return result["messages"] as? [[String: Any]] ?? []
    }

    // MARK: - Session Methods

    func sessionsList(limit: Int = 50, offset: Int = 0) async throws -> [GatewaySession] {
        let result = try await rpc(method: "sessions.list", params: ["limit": limit, "offset": offset])
        guard let sessionDicts = (result["sessions"] ?? result["items"]) as? [[String: Any]] else {
            print("[Gateway] sessions.list: no sessions array in response, keys: \(result.keys)")
            return []
        }
        return sessionDicts.compactMap { GatewaySession.from($0) }
    }

    func sessionsGet(id: String) async throws -> [String: Any] {
        return try await rpc(method: "sessions.get", params: ["id": id])
    }

    func sessionsDelete(id: String) async throws {
        let _ = try await rpc(method: "sessions.delete", params: ["id": id])
    }

    func sessionsReset(id: String) async throws {
        let _ = try await rpc(method: "sessions.reset", params: ["id": id])
    }

    func sessionsCompact(id: String) async throws {
        let _ = try await rpc(method: "sessions.compact", params: ["id": id])
    }

    // MARK: - Agent Methods

    func agentsList() async throws -> [GatewayAgent] {
        let result = try await rpc(method: "agents.list")
        guard let agentDicts = (result["agents"] ?? result["items"]) as? [[String: Any]] else {
            print("[Gateway] agents.list: no agents array in response, keys: \(result.keys)")
            return []
        }
        return agentDicts.compactMap { GatewayAgent.from($0) }
    }

    func getAgentIdentity() async throws -> GatewayAgentIdentity {
        // Gateway doesn't have a dedicated identity RPC — extract from agents.list or use default
        let result = try await rpc(method: "agents.list")
        if let agentDicts = result["agents"] as? [[String: Any]], let first = agentDicts.first {
            return GatewayAgentIdentity(
                name: first["name"] as? String ?? first["id"] as? String ?? "Assistant",
                creature: first["creature"] as? String ?? "AI",
                vibe: first["vibe"] as? String,
                emoji: first["emoji"] as? String ?? "🤖",
                color: first["color"] as? String ?? "#6B7280"
            )
        }
        return GatewayAgentIdentity()
    }

    // MARK: - Cron Methods

    func cronList(includeDisabled: Bool = true) async throws -> [GatewayCronJob] {
        let result = try await rpc(method: "cron.list", params: ["includeDisabled": includeDisabled])
        guard let jobDicts = (result["jobs"] ?? result["items"]) as? [[String: Any]] else {
            print("[Gateway] cron.list: no jobs array in response, keys: \(result.keys)")
            return []
        }
        return jobDicts.compactMap { GatewayCronJob.from($0) }
    }

    func cronUpdate(id: String, enabled: Bool? = nil, name: String? = nil) async throws {
        var patch: [String: Any] = ["id": id]
        if let enabled = enabled { patch["enabled"] = enabled }
        if let name = name { patch["name"] = name }
        let _ = try await rpc(method: "cron.update", params: patch)
        // Refresh local state
        await loadCronJobs()
    }

    func cronRun(id: String, mode: String = "force") async throws -> GatewayCronRunResult {
        let result = try await rpc(method: "cron.run", params: ["id": id, "mode": mode])
        return GatewayCronRunResult(
            ok: result["ok"] as? Bool,
            ran: result["ran"] as? Bool,
            reason: result["reason"] as? String
        )
    }

    func cronRemove(id: String) async throws {
        let _ = try await rpc(method: "cron.remove", params: ["id": id])
        await loadCronJobs()
    }

    func cronGetStatus() async throws -> GatewayCronStatus {
        let result = try await rpc(method: "cron.status")
        let status = GatewayCronStatus.from(result)
        await MainActor.run { self.cronStatus = status }
        return status
    }

    func cronRunsRead(jobId: String, limit: Int = 20) async throws -> [GatewayCronRun] {
        let result = try await rpc(method: "cron.runs.read", params: ["jobId": jobId, "limit": limit])
        guard let runDicts = (result["runs"] ?? result["items"]) as? [[String: Any]] else {
            return []
        }
        return runDicts.map { GatewayCronRun.from($0) }
    }

    // MARK: - Log Methods

    func logsTail(sinceMs: Int = 60000) {
        Task {
            do {
                let result = try await rpc(method: "logs.tail", params: ["sinceMs": sinceMs])
                if let entries = result["entries"] as? [[String: Any]] {
                    for entry in entries {
                        let logEntry = GatewayLogEntry(
                            timestamp: Date(timeIntervalSince1970: (entry["ts"] as? Double ?? 0) / 1000),
                            level: entry["level"] as? String ?? "info",
                            message: entry["message"] as? String ?? entry["msg"] as? String ?? "",
                            source: entry["source"] as? String
                        )
                        logSubject.send(logEntry)
                    }
                }
            } catch {
                print("[Gateway] logs.tail error: \(error)")
            }
        }
    }

    // MARK: - Gateway Status Methods

    func getGatewayStatus() async throws -> GatewayStatusResponse {
        let result = try await rpc(method: "gateway.status")
        let status = GatewayStatusResponse.from(result)
        await MainActor.run { self.gatewayStatus = status }
        return status
    }

    func getGatewayHealth() async throws -> GatewayHealthResponse {
        let result = try await rpc(method: "gateway.health")
        return GatewayHealthResponse.from(result)
    }

    // MARK: - Approval Methods

    func approvalsGet() async throws -> [GatewayApproval] {
        let result = try await rpc(method: "exec.approvals.get")
        guard let approvalDicts = result["approvals"] as? [[String: Any]] else {
            await MainActor.run { self.pendingApprovals = [] }
            return []
        }
        let approvals = approvalDicts.compactMap { GatewayApproval.from($0) }
        await MainActor.run { self.pendingApprovals = approvals }
        return approvals
    }

    func approvalsResolve(id: String, decision: String) async throws {
        let _ = try await rpc(method: "exec.approvals.resolve", params: ["id": id, "decision": decision])
        await MainActor.run {
            self.pendingApprovals.removeAll { $0.id == id }
        }
    }

    // MARK: - Utility

    func clearMessages() {
        messages.removeAll()
        thinkingSteps.removeAll()
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GatewayConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("[Gateway] WebSocket opened")
        connectNonce = nil
        connectSent = false

        DispatchQueue.main.async {
            self.isConnecting = true
        }
        // Queue connect with short delay to allow connect.challenge event to arrive first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performHandshake()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            if let error = error {
                self.connectionError = error.localizedDescription
            }
        }
        reconnect()
    }
}

// MARK: - Int Extension

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
