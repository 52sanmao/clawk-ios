import Foundation
import Combine
import UIKit

struct ClawkMessage: Identifiable, Codable {
    let id: String
    let type: String
    let message: String
    let actions: [String]
    let timestamp: TimeInterval
    var responded: Bool
    var response: String?
}

// MARK: - Dashboard Models

struct DashboardSnapshot: Codable {
    var agents: [DashboardAgent]?
    var sessions: [DashboardSession]?
    var totalCost: Double?
    var lastUpdated: String?
}

struct DashboardAgent: Codable, Identifiable {
    let id: String
    let name: String
    let emoji: String?
    let color: String?
    let model: String?
    let status: String?
    let skills: [AgentSkill]?
    let activeSkills: [String]?
}

struct AgentSkill: Codable, Identifiable {
    let id: String
    let name: String
    let icon: String?
    let category: String?
}

struct DashboardSession: Codable, Identifiable {
    let id: String
    let agentId: String?
    let agentName: String?
    let agentEmoji: String?
    let agentColor: String?
    let model: String?
    let messageCount: Int?
    let totalCost: Double?
    let tokensUsed: TokenUsage?
    let updatedAt: String?
    let startedAt: String?
    let projectPath: String?
    let source: String?
    let status: String?
    let folderTrail: [FolderTrailItem]?
}

struct TokenUsage: Codable {
    let input: Int?
    let output: Int?
    let cached: Int?
}

struct FolderTrailItem: Codable {
    let path: String
    let timestamp: String?
    let source: String?
}

struct OpenClawStatus: Codable {
    let cronJobs: [CronJob]?
    let heartbeats: [Heartbeat]?
    let summary: OpenClawSummary?
    let generatedAt: String?
}

struct CronJob: Codable, Identifiable {
    let id: String
    let name: String
    let agentId: String?
    let enabled: Bool
    let status: String
    let schedule: String
    let isHeartbeat: Bool
    let lastRunAtMs: TimeInterval?
    let nextRunAtMs: TimeInterval?
}

struct Heartbeat: Codable, Identifiable {
    let agentId: String
    let enabled: Bool
    let status: String
    let every: String?
    let model: String?
    let lastRunAtMs: TimeInterval?
    let nextRunAtMs: TimeInterval?
    
    var id: String { agentId }
}

struct OpenClawSummary: Codable {
    let totalCronJobs: Int
    let enabledCronJobs: Int
    let cronErrors: Int
    let heartbeatCount: Int
    let staleHeartbeats: Int
    let nextRunAtMs: TimeInterval?
    let lastRunAtMs: TimeInterval?
}

struct DashboardUpdate: Codable {
    let type: String
    let dashboardType: String
    let data: DashboardUpdateData
    let timestamp: TimeInterval
}

struct DashboardUpdateData: Codable {
    // Snapshot data
    let agents: [DashboardAgent]?
    let sessions: [DashboardSession]?
    let totalCost: Double?
    
    // OpenClaw status data
    let cronJobs: [CronJob]?
    let heartbeats: [Heartbeat]?
    let summary: OpenClawSummary?
    let generatedAt: String?
    
    // Tasks data
    let tasks: [DashboardTask]?
    let stats: TaskStats?
}

struct DashboardTask: Codable, Identifiable {
    let id: String
    let title: String
    let agent_id: String?
    let agent_name: String?
    let agent_emoji: String?
    let status: String
    let started_at: String?
    let completed_at: String?
}

struct TaskStats: Codable {
    let pending: Int?
    let active: Int?
    let completed: Int?
    let blocked: Int?
}

// MARK: - Session Messages

struct SessionMessage: Codable, Identifiable {
    let id: String
    let role: String
    let content: String
    let timestamp: String?
    let cost: Double?
    let model: String?
    let toolCalls: [SessionToolCall]?
    let toolResults: [SessionToolResult]?

    // API returns camelCase (toolCalls) — support both camelCase and snake_case
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, cost, model
        case toolCalls, toolResults
    }

    // Fallback keys for snake_case responses
    private enum SnakeCaseKeys: String, CodingKey {
        case toolCalls = "tool_calls"
        case toolResults = "tool_results"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.role = try container.decode(String.self, forKey: .role)
        self.content = (try? container.decode(String.self, forKey: .content)) ?? ""
        self.timestamp = try? container.decode(String.self, forKey: .timestamp)
        self.cost = try? container.decode(Double.self, forKey: .cost)
        self.model = try? container.decode(String.self, forKey: .model)
        // Try camelCase first (dashboard API), then snake_case fallback
        if let tc = try? container.decode([SessionToolCall].self, forKey: .toolCalls) {
            self.toolCalls = tc
        } else {
            let snakeContainer = try decoder.container(keyedBy: SnakeCaseKeys.self)
            self.toolCalls = try? snakeContainer.decode([SessionToolCall].self, forKey: .toolCalls)
        }
        if let tr = try? container.decode([SessionToolResult].self, forKey: .toolResults) {
            self.toolResults = tr
        } else {
            let snakeContainer = try decoder.container(keyedBy: SnakeCaseKeys.self)
            self.toolResults = try? snakeContainer.decode([SessionToolResult].self, forKey: .toolResults)
        }
    }
}

struct SessionToolCall: Codable {
    let id: String?
    let name: String?
    let arguments: [String: String]?
}

struct SessionToolResult: Codable {
    let toolName: String?
    let status: String?
    let content: String?
}

// MARK: - Message Store

class MessageStore: NSObject, ObservableObject {
    @Published var messages: [ClawkMessage] = []
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var logs: [String] = []

    var debugLogExportSection: String {
        let lines: [String] = [
            "模块: Relay / Dashboard 推送",
            "Relay Base URL: \(Config.baseURL.isEmpty ? "<disabled>" : Config.baseURL)",
            "WebSocket URL: \(Config.websocketURL?.absoluteString ?? "<disabled>")",
            "已连接: \(isConnected ? "是" : "否")",
            "连接中: \(isConnecting ? "是" : "否")",
            "Dashboard 推送在线: \(dashboardConnected ? "是" : "否")",
            "消息数: \(messages.count)",
            "日志:",
        ]
        let logLines = logs.isEmpty ? ["<empty>"] : logs
        return (lines + logLines).joined(separator: "\n")
    }

    func appendDetailedLog(_ message: String) {
        log(message)
    }
    
    // Dashboard data
    @Published var dashboardSnapshot: DashboardSnapshot?
    @Published var openclawStatus: OpenClawStatus?
    @Published var tasks: [DashboardTask] = []
    @Published var taskStats: TaskStats?
    @Published var lastDashboardUpdate: Date?
    @Published var dashboardConnected = false
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private var pollTimer: Timer?
    private var receivedMessageIds = Set<String>()
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.logs.append("[\(timestamp)] \(message)")
            if self.logs.count > 300 {
                self.logs.removeFirst()
            }
        }
    }

    private func logRequest(_ method: String, request: URLRequest) {
        let urlText = request.url?.absoluteString ?? "<nil>"
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            log("\(method) \(urlText) body=\(text)")
        } else {
            log("\(method) \(urlText)")
        }
    }

    private func logResponse(_ response: URLResponse?, data: Data? = nil) {
        if let http = response as? HTTPURLResponse {
            if let data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                log("HTTP \(http.statusCode) \(http.url?.absoluteString ?? "") response=\(text)")
            } else {
                log("HTTP \(http.statusCode) \(http.url?.absoluteString ?? "")")
            }
        } else {
            log("Non-HTTP response received")
        }
    }

    private func logFailure(_ action: String, error: Error) {
        log("\(action) failed: \(error.localizedDescription)")
    }

    private func logWebSocketText(_ text: String) {
        log("WS message: \(text)")
    }

    private func noteDashboardEvent(_ type: String) {
        log("Dashboard event: \(type)")
    }

    func clearDetailedLogs() {
        clearLogs()
    }

    func exportLogsSection() -> String {
        debugLogExportSection
    }

    private func sendJSONRequest(_ request: URLRequest, action: String, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        logRequest(request.httpMethod ?? "GET", request: request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                self.logFailure(action, error: error)
            } else {
                self.logResponse(response, data: data)
            }
            completion(data, response, error)
        }.resume()
    }

    private func sendWebSocketText(_ text: String) {
        log("WS send: \(text)")
        webSocketTask?.send(.string(text)) { error in
            if let error {
                self.logFailure("WS send", error: error)
            }
        }
    }

    private func dataTask(_ request: URLRequest, action: String, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        sendJSONRequest(request, action: action, completion: completion)
    }

    private func requestDescription(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")"
    }

    private func noteConnectAttempt() {
        log("Connecting to \(Config.websocketURL?.absoluteString ?? "<disabled>")...")
    }

    private func notePollingAttempt() {
        log("Polling relay messages from \(Config.apiURL?.appendingPathComponent("/poll").absoluteString ?? "<disabled>")")
    }

    private func notePairingAttempt() {
        log("Registering relay device at \(Config.apiURL?.appendingPathComponent("/pair").absoluteString ?? "<disabled>")")
    }

    private func noteSessionMessageFetch(_ sessionId: String) {
        log("Fetching relay session messages for \(sessionId)")
    }

    private func notePing(_ agentId: String) {
        log("Sending relay ping to @\(agentId)")
    }

    private func noteRespondAction(_ messageId: String, action: String) {
        log("Responding to relay message \(messageId) with action=\(action)")
    }

    private func noteReconnect() {
        log("Scheduling relay reconnect in 3 seconds")
    }

    private func notePollingStarted() {
        log("Starting relay polling fallback")
    }

    private func notePollingStopped() {
        log("Stopping relay polling fallback")
    }

    private func noteDecodeFailure(_ context: String, error: Error) {
        log("Decode failed for \(context): \(error.localizedDescription)")
    }

    private func noteReceivedMessages(_ count: Int) {
        log("Received \(count) relay messages")
    }

    private func noteDashboardSnapshotUpdate(_ kind: String) {
        log("Updated dashboard snapshot type=\(kind)")
    }

    private func noteSocketDisconnect(_ error: Error?) {
        log("❌ WebSocket disconnected: \(error?.localizedDescription ?? "Unknown error")")
    }

    private func noteSocketConnected() {
        log("✅ WebSocket connected")
    }

    private func noteWebSocketReceiveFailure(_ error: Error) {
        logFailure("WS receive", error: error)
    }

    private func noteUnexpectedWebSocketMessage() {
        log("WS received unsupported message payload")
    }

    private func noteDuplicateRelayMessage(_ id: String) {
        log("Skipped duplicate relay message \(id)")
    }

    private func noteRelayMessageStored(_ id: String) {
        log("Stored relay message \(id)")
    }

    private func noteManualRefresh() {
        log("Manual refresh triggered")
    }

    private func noteAlreadyResponded(_ id: String) {
        log("Message \(id) already responded to, ignoring")
    }

    private func noteClearLogs() {
        log("Clearing relay logs")
    }

    private func noteUnknownDashboardUpdate(_ type: String) {
        log("Unhandled dashboard update type=\(type)")
    }

    private func noteStatus(_ text: String) {
        log(text)
    }

    private func noteHTTPStatusMismatch(_ response: URLResponse?) {
        if let http = response as? HTTPURLResponse {
            log("Unexpected HTTP status \(http.statusCode) for \(http.url?.absoluteString ?? "")")
        }
    }

    private func responseOK(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return 200 ..< 300 ~= http.statusCode
    }

    private func decodeMessages(_ data: Data) -> [ClawkMessage]? {
        do {
            return try JSONDecoder().decode([ClawkMessage].self, from: data)
        } catch {
            noteDecodeFailure("relay messages", error: error)
            return nil
        }
    }

    private func decodeSessionMessages(_ data: Data) -> [SessionMessage]? {
        do {
            return try JSONDecoder().decode([SessionMessage].self, from: data)
        } catch {
            noteDecodeFailure("session messages", error: error)
            return nil
        }
    }

    private func decodeDashboardUpdate(_ data: Data) -> DashboardUpdate? {
        do {
            return try JSONDecoder().decode(DashboardUpdate.self, from: data)
        } catch {
            return nil
        }
    }

    private func decodeRelayMessage(_ data: Data) -> ClawkMessage? {
        do {
            return try JSONDecoder().decode(ClawkMessage.self, from: data)
        } catch {
            noteDecodeFailure("single relay message", error: error)
            return nil
        }
    }

    private func noteReceiveText(_ text: String) {
        logWebSocketText(text)
    }

    private func noteRequestFailure(_ request: URLRequest, error: Error) {
        logFailure(requestDescription(request), error: error)
    }

    private func noteResponse(_ response: URLResponse?, data: Data? = nil) {
        logResponse(response, data: data)
    }

    private func appendReceivedMessages(_ messages: [ClawkMessage]) {
        DispatchQueue.main.async {
            for message in messages {
                if self.receivedMessageIds.contains(message.id) {
                    self.noteDuplicateRelayMessage(message.id)
                    continue
                }
                self.receivedMessageIds.insert(message.id)
                self.messages.insert(message, at: 0)
                self.noteRelayMessageStored(message.id)
            }
        }
    }

    private func appendReceivedMessage(_ message: ClawkMessage) {
        DispatchQueue.main.async {
            guard !self.receivedMessageIds.contains(message.id) else {
                self.noteDuplicateRelayMessage(message.id)
                return
            }
            self.receivedMessageIds.insert(message.id)
            self.messages.insert(message, at: 0)
            self.noteRelayMessageStored(message.id)
        }
    }

    private func noteResponseActionSent(_ text: String) {
        log("Relay action payload=\(text)")
    }

    private func noteSocketCompletionError(_ error: Error?) {
        noteSocketDisconnect(error)
    }

    private func noteDashboardConnected(_ connected: Bool) {
        log("Dashboard push connected=\(connected ? "true" : "false")")
    }

    private func noteRelayConnectionState(_ text: String) {
        log(text)
    }

    private func notePollingResultCount(_ count: Int) {
        log("Polling returned \(count) messages")
    }

    private func noteSessionMessagesCount(_ count: Int, sessionId: String) {
        log("Fetched \(count) session messages for \(sessionId)")
    }

    private func notePingResult(_ success: Bool, agentId: String) {
        log("Ping result for @\(agentId): \(success ? "success" : "failed")")
    }

    private func noteRespondResult(_ success: Bool, messageId: String) {
        log("Relay response result for \(messageId): \(success ? "success" : "failed")")
    }

    private func notePairResult(_ success: Bool) {
        log("Relay pairing result: \(success ? "success" : "failed")")
    }

    private func noteHealth(_ text: String) {
        log(text)
    }

    private func noteInvalidTextPayload() {
        log("Received invalid UTF-8 text payload")
    }

    private func noteDashboardHandled(_ type: String) {
        log("Handled dashboard update \(type)")
    }

    private func noteMessageDecodeFallback() {
        log("Incoming WS payload was not dashboard update; trying relay message decode")
    }

    private func notePollingSkipped() {
        log("Polling skipped")
    }

    private func noteSessionFetchFailure(_ sessionId: String, error: Error) {
        log("Failed to fetch session messages for \(sessionId): \(error.localizedDescription)")
    }

    private func notePairingFailure(_ error: Error) {
        log("Relay pairing failed: \(error.localizedDescription)")
    }

    private func noteUnexpectedHTTP(_ response: URLResponse?) {
        noteHTTPStatusMismatch(response)
    }

    private func noteSocketOpenProtocol(_ `protocol`: String?) {
        if let `protocol` {
            log("WS opened with protocol=\(`protocol`)")
        }
    }

    private func notePollRequest(_ request: URLRequest) {
        logRequest(request.httpMethod ?? "GET", request: request)
    }

    private func notePairRequest(_ request: URLRequest) {
        logRequest(request.httpMethod ?? "POST", request: request)
    }

    private func noteSessionRequest(_ request: URLRequest) {
        logRequest(request.httpMethod ?? "GET", request: request)
    }

    private func notePingRequest(_ request: URLRequest) {
        logRequest(request.httpMethod ?? "POST", request: request)
    }

    private func noteReceiveCount(_ count: Int) {
        noteReceivedMessages(count)
    }

    private func noteDashboardType(_ type: String) {
        noteDashboardEvent(type)
    }

    private func noteTaskUpdate(_ count: Int) {
        log("Updated dashboard tasks count=\(count)")
    }

    private func noteOpenClawStatusUpdate() {
        log("Updated openclaw status snapshot")
    }

    private func noteSnapshotAgents(_ count: Int) {
        log("Updated dashboard agent snapshot count=\(count)")
    }

    private func noteSnapshotSessions(_ count: Int) {
        log("Updated dashboard session snapshot count=\(count)")
    }

    private func noteCostsUpdate() {
        log("Updated dashboard cost snapshot")
    }

    private func noteRefreshState(_ connected: Bool) {
        log("Manual refresh while relay connected=\(connected ? "true" : "false")")
    }

    private func noteRespondPayloadFailure() {
        log("Failed to encode relay response payload")
    }

    private func noteRequestBodyEncodingFailure(_ action: String, error: Error) {
        log("Failed to encode body for \(action): \(error.localizedDescription)")
    }

    private func notePairBodyFailure(_ error: Error) {
        noteRequestBodyEncodingFailure("pair", error: error)
    }

    private func notePingBodyFailure(_ error: Error) {
        noteRequestBodyEncodingFailure("ping", error: error)
    }

    private func noteRespondingMessage(_ id: String) {
        log("Preparing response for relay message \(id)")
    }

    private func noteDecodedDashboardUpdate(_ type: String) {
        log("Decoded dashboard WS payload type=\(type)")
    }

    private func noteDecodedRelayMessage(_ id: String) {
        log("Decoded relay WS message \(id)")
    }

    private func noteSocketResume() {
        log("Resumed WebSocket task")
    }

    private func noteSocketCancel() {
        log("Cancelled WebSocket task")
    }

    private func noteReconnectTimerInvalidated() {
        log("Invalidated relay reconnect timer")
    }

    private func notePollTimerInvalidated() {
        log("Invalidated relay poll timer")
    }

    private func notePollingFire() {
        log("Executing relay poll cycle")
    }

    private func noteEmptyPollResult() {
        log("Polling returned no new messages")
    }

    private func noteNoDashboardUpdate() {
        log("WS payload was not dashboard update")
    }

    private func noteNoRelayMessage() {
        log("WS payload was not relay message")
    }

    private func noteStateChange(_ label: String, value: String) {
        log("\(label)=\(value)")
    }

    private func notePairingSkipped() {
        log("Pairing skipped")
    }

    private func noteMessageStoreInit() {
        log("MessageStore initialized")
    }

    private func noteOpenStatus(_ text: String) {
        log(text)
    }

    private func noteDashboardTimestamp(_ ts: TimeInterval) {
        log("Dashboard update timestamp=\(ts)")
    }

    private func noteNoData(_ action: String) {
        log("No data returned for \(action)")
    }

    private func noteResponseStatus(_ response: URLResponse?) {
        logResponse(response)
    }

    private func notePairingCompletion() {
        log("Pairing request finished")
    }

    private func notePingCompletion() {
        log("Ping request finished")
    }

    private func noteSessionCompletion(_ sessionId: String) {
        log("Session message request finished for \(sessionId)")
    }

    private func notePollCompletion() {
        log("Poll request finished")
    }

    private func noteCurrentDeviceToken() {
        log("Using relay device token \(Config.deviceToken)")
    }

    private func noteRelayBaseURL() {
        log("Relay base URL \(Config.baseURL)")
    }

    private func noteWSURL() {
        log("Relay websocket URL \(Config.websocketURL?.absoluteString ?? "<disabled>")")
    }

    private func notePollURL() {
        log("Relay poll URL \(Config.apiURL?.appendingPathComponent("/poll").absoluteString ?? "<disabled>")")
    }

    private func notePairURL() {
        log("Relay pair URL \(Config.apiURL?.appendingPathComponent("/pair").absoluteString ?? "<disabled>")")
    }

    private func noteMessageURL() {
        log("Relay message URL \(Config.apiURL?.appendingPathComponent("/message").absoluteString ?? "<disabled>")")
    }

    private func noteSessionURL(_ sessionId: String) {
        log("Relay session URL \(Config.apiURL?.appendingPathComponent("/dashboard/sessions/\(sessionId)/messages").absoluteString ?? "<disabled>")")
    }

    private func noteOpenState() {
        log("Relay open state isConnected=\(isConnected) isConnecting=\(isConnecting)")
    }

    private func noteDashboardState() {
        log("Dashboard push state=\(dashboardConnected)")
    }
    
    override init() {
        super.init()
        noteMessageStoreInit()
        log("Relay channel uses \(Config.baseURL) and is optional for push notifications/action cards")
        noteRelayBaseURL()
        noteWSURL()
        noteCurrentDeviceToken()
        if Config.isRelayEnabled {
            connect()
            pairDevice()
        } else {
            log("Relay is disabled; skipping legacy websocket and pair setup")
        }
    }

    func reloadConfiguration() {
        disconnect()
        stopPolling()
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.dashboardConnected = false
        }
        log("Reloading relay configuration from current app settings")
        noteRelayBaseURL()
        noteWSURL()
        if Config.isRelayEnabled {
            connect()
            pairDevice()
        } else {
            log("Relay is disabled; skipping legacy websocket and pair setup")
        }
    }
    
    func pairDevice() {
        guard Config.isRelayEnabled else {
            log("Skipped relay pairing because relay is disabled")
            return
        }

        guard let url = Config.apiURL?.appendingPathComponent("/pair") else {
            log("Skipped relay pairing because relay URL is unavailable")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = [
            "deviceToken": Config.deviceToken,
            "deviceName": UIDevice.current.name
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            notePairBodyFailure(error)
            return
        }

        notePairingAttempt()
        notePairURL()
        notePairRequest(request)
        dataTask(request, action: "pair") { [weak self] data, response, error in
            guard let self else { return }
            defer { self.notePairingCompletion() }

            if let error {
                self.notePairingFailure(error)
                self.notePairResult(false)
                return
            }

            let ok = self.responseOK(response)
            if !ok {
                self.noteUnexpectedHTTP(response)
            }
            if data == nil {
                self.noteNoData("pair")
            }
            self.notePairResult(ok)
        }
    }
    
    func connect() {
        guard Config.isRelayEnabled else {
            log("Skipped relay websocket connect because relay is disabled")
            DispatchQueue.main.async {
                self.isConnecting = false
                self.isConnected = false
                self.dashboardConnected = false
            }
            return
        }

        DispatchQueue.main.async {
            self.isConnecting = true
        }
        noteConnectAttempt()
        noteOpenState()

        guard let websocketURL = Config.websocketURL else {
            log("Skipped relay websocket connect because relay URL is unavailable")
            DispatchQueue.main.async {
                self.isConnecting = false
                self.isConnected = false
                self.dashboardConnected = false
            }
            return
        }

        var request = URLRequest(url: websocketURL)
        request.timeoutInterval = 5
        logRequest("GET", request: request)

        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        webSocketTask?.resume()
        noteSocketResume()
    }
    
    func disconnect() {
        noteSocketCancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        reconnectTimer?.invalidate()
        noteReconnectTimerInvalidated()
    }
    
    private func reconnect() {
        guard Config.isRelayEnabled else {
            log("Relay disabled; not scheduling reconnect")
            return
        }

        noteReconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connect()
        }
        startPolling()
    }
    
    private func startPolling() {
        guard Config.isRelayEnabled else {
            log("Skipped relay polling because relay is disabled")
            return
        }

        pollTimer?.invalidate()
        notePollTimerInvalidated()
        notePollingStarted()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.notePollingFire()
            self?.pollMessages()
        }
        pollTimer?.fire()
    }
    
    private func stopPolling() {
        pollTimer?.invalidate()
        notePollTimerInvalidated()
        pollTimer = nil
        notePollingStopped()
    }
    
    private func pollMessages() {
        guard Config.isRelayEnabled else {
            log("Skipped relay poll because relay is disabled")
            return
        }

        guard let url = Config.apiURL?.appendingPathComponent("/poll") else {
            log("Skipped relay poll because relay URL is unavailable")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")

        notePollingAttempt()
        notePollURL()
        notePollRequest(request)
        dataTask(request, action: "poll") { [weak self] data, response, error in
            guard let self else { return }
            defer { self.notePollCompletion() }

            if let error {
                self.noteRequestFailure(request, error: error)
                return
            }

            guard self.responseOK(response) else {
                self.noteUnexpectedHTTP(response)
                return
            }

            guard let data else {
                self.noteNoData("poll")
                return
            }

            guard let messages = self.decodeMessages(data) else { return }
            self.notePollingResultCount(messages.count)
            if messages.isEmpty {
                self.noteEmptyPollResult()
            }
            self.appendReceivedMessages(messages)
        }
    }
    
    private func receive() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.noteReceiveText(text)
                    self?.handleMessage(text)
                default:
                    self?.noteUnexpectedWebSocketMessage()
                }
                self?.receive()

            case .failure(let error):
                self?.noteWebSocketReceiveFailure(error)
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.dashboardConnected = false
                }
                self?.reconnect()
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let textData = text.data(using: .utf8) else {
            noteInvalidTextPayload()
            return
        }

        if let dashboardUpdate = decodeDashboardUpdate(textData) {
            noteDecodedDashboardUpdate(dashboardUpdate.dashboardType)
            handleDashboardUpdate(dashboardUpdate)
            return
        }
        noteNoDashboardUpdate()

        guard let message = decodeRelayMessage(textData) else {
            noteNoRelayMessage()
            return
        }

        noteDecodedRelayMessage(message.id)
        appendReceivedMessage(message)
    }
    
    private func handleDashboardUpdate(_ update: DashboardUpdate) {
        noteDashboardType(update.dashboardType)
        noteDashboardTimestamp(update.timestamp)
        DispatchQueue.main.async { [weak self] in
            self?.dashboardConnected = true
            self?.lastDashboardUpdate = Date(timeIntervalSince1970: update.timestamp / 1000)

            switch update.dashboardType {
            case "snapshot":
                if let agents = update.data.agents {
                    self?.dashboardSnapshot = DashboardSnapshot(
                        agents: agents,
                        sessions: update.data.sessions,
                        totalCost: update.data.totalCost,
                        lastUpdated: ISO8601DateFormatter().string(from: Date())
                    )
                    self?.noteSnapshotAgents(agents.count)
                    self?.noteSnapshotSessions(update.data.sessions?.count ?? 0)
                    self?.noteDashboardSnapshotUpdate("snapshot")
                }

            case "sessions":
                if var snapshot = self?.dashboardSnapshot {
                    snapshot.sessions = update.data.sessions
                    snapshot.lastUpdated = ISO8601DateFormatter().string(from: Date())
                    self?.dashboardSnapshot = snapshot
                    self?.noteSnapshotSessions(update.data.sessions?.count ?? 0)
                    self?.noteDashboardSnapshotUpdate("sessions")
                }

            case "openclaw_status":
                self?.openclawStatus = OpenClawStatus(
                    cronJobs: update.data.cronJobs,
                    heartbeats: update.data.heartbeats,
                    summary: update.data.summary,
                    generatedAt: update.data.generatedAt
                )
                self?.noteOpenClawStatusUpdate()

            case "tasks":
                if let tasks = update.data.tasks {
                    self?.tasks = tasks
                    self?.noteTaskUpdate(tasks.count)
                }
                self?.taskStats = update.data.stats

            case "agent_status":
                self?.noteStatus("Agent status update received")

            case "costs":
                if var snapshot = self?.dashboardSnapshot {
                    snapshot.totalCost = update.data.totalCost
                    self?.dashboardSnapshot = snapshot
                    self?.noteCostsUpdate()
                }

            default:
                self?.noteUnknownDashboardUpdate(update.dashboardType)
            }

            self?.noteDashboardHandled(update.dashboardType)
        }
    }
    
    func respond(to message: ClawkMessage, with action: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let index = self.messages.firstIndex(where: { $0.id == message.id }) else { return }

            guard !self.messages[index].responded else {
                self.noteAlreadyResponded(message.id)
                return
            }

            self.noteRespondingMessage(message.id)
            self.noteRespondAction(message.id, action: action)
            self.messages[index].responded = true
            self.messages[index].response = action

            let response: [String: Any] = [
                "messageId": message.id,
                "action": action,
                "timestamp": Date().timeIntervalSince1970
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: response) else {
                self.noteRespondPayloadFailure()
                return
            }

            guard let text = String(data: data, encoding: .utf8) else {
                self.noteRespondPayloadFailure()
                return
            }

            self.noteResponseActionSent(text)
            self.sendWebSocketText(text)
        }
    }
    
    func manualRefresh() {
        noteManualRefresh()
        noteRefreshState(isConnected)
        if Config.isRelayEnabled {
            pollMessages()
        } else {
            log("Relay disabled; manual refresh only affects HTTP-backed views")
        }
    }
    
    func clearLogs() {
        noteClearLogs()
        logs.removeAll()
    }
    
    // MARK: - Session Messages
    
    func fetchSessionMessages(sessionId: String, completion: @escaping ([SessionMessage]) -> Void) {
        guard let url = Config.apiURL?.appendingPathComponent("/dashboard/sessions/\(sessionId)/messages") else {
            log("Skipped relay session fetch because relay URL is unavailable")
            DispatchQueue.main.async { completion([]) }
            return
        }
        var request = URLRequest(url: url)
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")

        noteSessionMessageFetch(sessionId)
        noteSessionURL(sessionId)
        noteSessionRequest(request)
        dataTask(request, action: "fetchSessionMessages") { [weak self] data, response, error in
            guard let self else {
                completion([])
                return
            }
            defer { self.noteSessionCompletion(sessionId) }

            if let error {
                self.noteSessionFetchFailure(sessionId, error: error)
                DispatchQueue.main.async { completion([]) }
                return
            }

            guard self.responseOK(response) else {
                self.noteUnexpectedHTTP(response)
                DispatchQueue.main.async { completion([]) }
                return
            }

            guard let data else {
                self.noteNoData("fetchSessionMessages")
                DispatchQueue.main.async { completion([]) }
                return
            }

            guard let messages = self.decodeSessionMessages(data) else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            self.noteSessionMessagesCount(messages.count, sessionId: sessionId)
            DispatchQueue.main.async {
                completion(messages)
            }
        }
    }
    
    // MARK: - Agent Actions
    
    func pingAgent(agentId: String, completion: @escaping (Bool) -> Void) {
        guard let url = Config.apiURL?.appendingPathComponent("/message") else {
            log("Skipped relay ping because relay URL is unavailable")
            DispatchQueue.main.async { completion(false) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")

        let body: [String: Any] = [
            "message": "Ping from clawk-iOS: @\(agentId) check in please",
            "type": "ping",
            "actions": []
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            notePingBodyFailure(error)
            DispatchQueue.main.async { completion(false) }
            return
        }

        notePing(agentId)
        noteMessageURL()
        notePingRequest(request)
        dataTask(request, action: "pingAgent") { [weak self] data, response, error in
            guard let self else {
                completion(false)
                return
            }
            defer { self.notePingCompletion() }

            if let error {
                self.noteRequestFailure(request, error: error)
                DispatchQueue.main.async { completion(false) }
                return
            }

            let ok = self.responseOK(response)
            if !ok {
                self.noteUnexpectedHTTP(response)
            }
            if data == nil {
                self.noteNoData("pingAgent")
            }
            self.notePingResult(ok, agentId: agentId)
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

// MARK: - WebSocket Delegate

extension MessageStore: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.isConnecting = false
        }
        noteSocketConnected()
        noteSocketOpenProtocol(protocolName)
        noteDashboardConnected(true)
        stopPolling()
        receive()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        noteSocketCompletionError(error)
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.dashboardConnected = false
        }
        noteDashboardConnected(false)
        reconnect()
    }
}
