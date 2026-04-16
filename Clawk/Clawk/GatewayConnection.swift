import Foundation
import Combine
import os.log

private let gatewayLog = Logger(subsystem: "com.kishparikh.clawk", category: "Gateway")

// MARK: - IronClaw Connection

/// IronClaw 原生 HTTP 连接层，兼容现有 Clawk 视图所需的数据接口。
final class GatewayConnection: NSObject, ObservableObject {
    static func normalizeGatewayEndpoint(_ rawValue: String, fallbackPort: Int) -> (host: String, port: Int) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (rawValue, fallbackPort)
        }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                let resolvedPort = components.port ?? (scheme == "https" ? 443 : 80)
                return (trimmed, resolvedPort)
            }

            if scheme == "ws" || scheme == "wss" {
                var normalized = components
                normalized.scheme = (scheme == "wss") ? "https" : "http"
                let resolvedPort = components.port ?? (scheme == "wss" ? 443 : 80)
                if normalized.path.isEmpty {
                    normalized.path = "/"
                }
                if let urlString = normalized.string {
                    return (urlString, resolvedPort)
                }
            }
        }

        return (trimmed, fallbackPort)
    }

    // MARK: - Published State

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String?

    @Published var messages: [GatewayChatMessage] = []
    @Published var thinkingSteps: [GatewayThinkingStep] = []
    @Published var currentSessionId: String?
    @Published var currentSessionKey: String?
    @Published var previousResponseId: String?
    @Published var isWaitingForResponse = false
    @Published var chatError: String?
    @Published var chatStatus: String?
    @Published var debugLog: [String] = []

    @Published var agentIdentity: GatewayAgentIdentity?
    @Published var agents: [GatewayAgent] = []
    @Published var sessions: [GatewaySession] = []
    @Published var cronJobs: [GatewayCronJob] = []
    @Published var cronStatus: GatewayCronStatus?
    @Published var pendingApprovals: [GatewayApproval] = []
    @Published var gatewayStatus: GatewayStatusResponse?

    var publicDeviceToken: String { deviceToken }

    let eventSubject = PassthroughSubject<(GatewayEventType, [String: Any]), Never>()
    let logSubject = PassthroughSubject<GatewayLogEntry, Never>()

    private let urlSession = URLSession(configuration: .default)
    private var responseTask: Task<Void, Never>?
    private(set) var gatewayHost: String
    private(set) var gatewayPort: Int
    private(set) var gatewayToken: String
    private var deviceToken: String

    init(host: String? = nil, port: Int? = nil, token: String? = nil) {
        self.gatewayHost = host ?? UserDefaults.standard.string(forKey: "gatewayHost") ?? "http://127.0.0.1:8642"
        self.gatewayPort = port ?? UserDefaults.standard.integer(forKey: "gatewayPort").nonZero ?? 8642
        self.gatewayToken = token ?? UserDefaults.standard.string(forKey: "gatewayToken") ?? ""
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
            if self.debugLog.count > 200 {
                self.debugLog.removeFirst()
            }
        }
        gatewayLog.debug("\(msg, privacy: .public)")
    }

    // MARK: - Connection Management

    func connect() {
        guard !isConnecting else { return }

        responseTask?.cancel()
        connectionError = nil
        isConnecting = true
        debugAppend("Connecting to IronClaw…")

        Task {
            do {
                let models = try await fetchModels()
                await MainActor.run {
                    self.isConnected = true
                    self.isConnecting = false
                    self.connectionError = nil
                    self.agentIdentity = GatewayAgentIdentity(name: "IronClaw", creature: "AI", vibe: "Native", emoji: "🤖", color: "#6B7280")
                    self.agents = self.makeAgents(from: models)
                }
                debugAppend("Connected to IronClaw")
                await loadInitialData()
            } catch {
                let message = userFacingErrorMessage(error.localizedDescription)
                debugAppend("Connect failed: \(message)")
                await MainActor.run {
                    self.isConnected = false
                    self.isConnecting = false
                    self.connectionError = message
                }
            }
        }
    }

    func disconnect() {
        responseTask?.cancel()
        responseTask = nil
        isConnected = false
        isConnecting = false
        isWaitingForResponse = false
        chatStatus = nil
        debugAppend("Disconnected from IronClaw")
    }

    func updateConnection(host: String, port: Int, token: String = "") {
        let normalized = Self.normalizeGatewayEndpoint(host, fallbackPort: port)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(normalized.host, forKey: "gatewayHost")
        UserDefaults.standard.set(normalized.port, forKey: "gatewayPort")
        UserDefaults.standard.set(trimmedToken, forKey: "gatewayToken")

        gatewayHost = normalized.host
        gatewayPort = normalized.port
        gatewayToken = trimmedToken

        disconnect()
        connect()
    }

    private func loadInitialData() async {
        async let sessionsTask: Void = loadSessions()
        async let cronTask: Void = loadCronJobs()
        async let healthTask: Void = loadHealthStatus()
        async let approvalsTask: Void = loadApprovals()
        _ = await (sessionsTask, cronTask, healthTask, approvalsTask)
    }

    // MARK: - Chat Methods

    func sendMessage(_ content: String, sessionKey: String? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(GatewayChatMessage(role: "user", content: trimmed))
        isWaitingForResponse = true
        chatError = nil
        chatStatus = "发送中..."
        thinkingSteps.removeAll()

        let requestedThreadId = sessionKey ?? currentSessionKey ?? currentSessionId
        responseTask?.cancel()
        responseTask = Task { [weak self] in
            guard let self else { return }
            await self.sendThreadMessage(trimmed, requestedThreadId: requestedThreadId)
        }
    }

    func startNewChat(agentId: String = "main") {
        responseTask?.cancel()
        messages.removeAll()
        thinkingSteps.removeAll()
        currentSessionKey = nil
        currentSessionId = nil
        previousResponseId = nil
        isWaitingForResponse = false
        chatError = nil
        chatStatus = nil
    }

    func switchToSession(_ session: GatewaySession) {
        responseTask?.cancel()
        messages.removeAll()
        thinkingSteps.removeAll()
        currentSessionKey = session.sessionKey ?? session.id
        currentSessionId = session.id
        previousResponseId = nil
        isWaitingForResponse = false
        chatError = nil
        chatStatus = nil

        guard isLikelyThreadID(session.id) else { return }
        Task {
            try? await loadThreadHistoryIntoMessages(session.id)
        }
    }

    func loadMessages(from sessionMessages: [SessionMessage]) {
        let chatMessages = sessionMessages.compactMap { msg -> GatewayChatMessage? in
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty,
                  msg.role == "user" || msg.role == "assistant" else { return nil }
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
        debugAppend("Loaded \(chatMessages.count) messages from dashboard history")
    }

    func chatAbort() async throws {
        responseTask?.cancel()
        await MainActor.run {
            self.isWaitingForResponse = false
            self.chatStatus = nil
        }
    }

    func chatHistory(sessionId: String? = nil, sessionKey: String? = nil) async throws -> [[String: Any]] {
        let resolved = sessionKey ?? currentSessionKey ?? sessionId ?? currentSessionId
        guard let resolved else { return [] }

        if isLikelyThreadID(resolved) {
            let history = try await fetchThreadHistory(threadId: resolved)
            return history.turns.flatMap { turn -> [[String: Any]] in
                var rows: [[String: Any]] = []
                let user = turn.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !user.isEmpty {
                    rows.append(["role": "user", "content": user])
                }
                let reply = (turn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty {
                    rows.append(["role": "assistant", "content": reply])
                }
                return rows
            }
        }

        let payload = try await invokeTool(name: "sessions_history", arguments: [
            "session_key": resolved,
            "limit": 200,
            "include_tools": false,
        ])
        return payload["messages"] as? [[String: Any]] ?? []
    }

    // MARK: - Session Methods

    func sessionsList(limit: Int = 50, offset: Int = 0) async throws -> [GatewaySession] {
        let payload = try await invokeTool(name: "sessions_list", arguments: [
            "limit": limit,
            "offset": offset,
            "includeDerivedTitles": true,
            "includeLastMessage": true,
        ])
        let items = payload["sessions"] as? [[String: Any]] ?? payload["items"] as? [[String: Any]] ?? []
        let mapped = items.compactMap(mapSession)
        await MainActor.run { self.sessions = mapped }
        return mapped
    }

    func sessionsGet(id: String) async throws -> [String: Any] {
        ["id": id]
    }

    func sessionsDelete(id: String) async throws {
        throw GatewayError.invalidRequest("IronClaw 当前未提供会话删除接口")
    }

    func sessionsReset(id: String) async throws {
        throw GatewayError.invalidRequest("IronClaw 当前未提供会话重置接口")
    }

    func sessionsCompact(id: String) async throws {
        throw GatewayError.invalidRequest("IronClaw 当前未提供会话压缩接口")
    }

    // MARK: - Agent Methods

    func agentsList() async throws -> [GatewayAgent] {
        let models = try await fetchModels()
        let mapped = makeAgents(from: models)
        await MainActor.run { self.agents = mapped }
        return mapped
    }

    func getAgentIdentity() async throws -> GatewayAgentIdentity {
        let identity = GatewayAgentIdentity(name: "IronClaw", creature: "AI", vibe: "Native", emoji: "🤖", color: "#6B7280")
        await MainActor.run { self.agentIdentity = identity }
        return identity
    }

    // MARK: - Cron Methods

    func cronList(includeDisabled: Bool = true) async throws -> [GatewayCronJob] {
        let payload = try await invokeTool(name: "cron_list", arguments: [
            "include_disabled": includeDisabled,
        ])
        let items = payload["jobs"] as? [[String: Any]] ?? payload["items"] as? [[String: Any]] ?? []
        let jobs = items.compactMap { GatewayCronJob.from($0) }
        await MainActor.run { self.cronJobs = jobs }
        return jobs
    }

    func cronUpdate(id: String, enabled: Bool? = nil, name: String? = nil) async throws {
        var args: [String: Any] = ["id": id]
        if let enabled { args["enabled"] = enabled }
        if let name { args["name"] = name }
        _ = try await invokeTool(name: "cron_update", arguments: args)
        _ = try await cronList()
    }

    func cronRun(id: String, mode: String = "force") async throws -> GatewayCronRunResult {
        let payload = try await invokeTool(name: "cron_run", arguments: ["id": id, "mode": mode])
        return GatewayCronRunResult(
            ok: payload["ok"] as? Bool,
            ran: payload["ran"] as? Bool,
            reason: payload["reason"] as? String
        )
    }

    func cronRemove(id: String) async throws {
        throw GatewayError.invalidRequest("IronClaw 当前未提供定时任务删除接口")
    }

    func cronGetStatus() async throws -> GatewayCronStatus {
        let jobs = try await cronList()
        let nextWake = jobs.compactMap { $0.nextRunAtMs }.min()
        let status = GatewayCronStatus(enabled: !jobs.isEmpty, jobs: jobs.count, nextWakeAtMs: nextWake, storePath: nil)
        await MainActor.run { self.cronStatus = status }
        return status
    }

    func cronRunsRead(jobId: String, limit: Int = 20) async throws -> [GatewayCronRun] {
        let payload = try await invokeTool(name: "cron_runs_read", arguments: ["job_id": jobId, "limit": limit])
        let items = payload["runs"] as? [[String: Any]] ?? payload["items"] as? [[String: Any]] ?? []
        return items.map { GatewayCronRun.from($0) }
    }

    // MARK: - Log Methods

    func logsTail(sinceMs: Int = 60000) {
        let entry = GatewayLogEntry(
            timestamp: Date(),
            level: "info",
            message: "IronClaw 原生 API 当前未提供日志尾流，日志页面仅显示此提示。",
            source: "ironclaw"
        )
        logSubject.send(entry)
    }

    // MARK: - Gateway Status Methods

    func getGatewayStatus() async throws -> GatewayStatusResponse {
        let details = try await fetchHealthDetails()
        let status = GatewayStatusResponse(
            uptime: details.uptimeSeconds,
            version: details.version ?? serverHostDisplay,
            agents: agents.count,
            sessions: sessions.count,
            connectedDevices: nil
        )
        await MainActor.run { self.gatewayStatus = status }
        return status
    }

    func getGatewayHealth() async throws -> GatewayHealthResponse {
        let details = try await fetchHealthDetails()
        return GatewayHealthResponse(
            status: details.status ?? "ok",
            uptime: details.uptimeSeconds,
            memory: GatewayMemoryInfo(
                rss: details.memory?.rss,
                heapUsed: details.memory?.heapUsed,
                heapTotal: details.memory?.heapTotal
            )
        )
    }

    // MARK: - Approval Methods

    func approvalsGet() async throws -> [GatewayApproval] {
        await MainActor.run { self.pendingApprovals = [] }
        return []
    }

    func approvalsResolve(id: String, decision: String) async throws {
        throw GatewayError.invalidRequest("IronClaw 当前未提供执行审批接口")
    }

    // MARK: - Utility

    func clearMessages() {
        messages.removeAll()
        thinkingSteps.removeAll()
        previousResponseId = nil
        currentSessionId = nil
        currentSessionKey = nil
        chatError = nil
        chatStatus = nil
    }

    // MARK: - Internal loaders

    private func loadSessions() async {
        _ = try? await sessionsList(limit: 100)
    }

    private func loadCronJobs() async {
        _ = try? await cronList()
        _ = try? await cronGetStatus()
    }

    private func loadHealthStatus() async {
        _ = try? await getGatewayStatus()
    }

    private func loadApprovals() async {
        _ = try? await approvalsGet()
    }

    // MARK: - Thread Chat

    private func sendThreadMessage(_ message: String, requestedThreadId: String?) async {
        do {
            let threadId = try await ensureThreadID(requestedThreadId)
            let baselineHistory = try await fetchThreadHistory(threadId: threadId)
            let baselineTurnCount = baselineHistory.turns.count

            await MainActor.run {
                self.currentSessionId = threadId
                self.currentSessionKey = threadId
                self.previousResponseId = nil
                self.isWaitingForResponse = true
                self.chatStatus = "等待 IronClaw 响应..."
            }

            debugAppend("POST /api/chat/send → thread_id=\(threadId)")
            try await postThreadMessage(message, threadId: threadId)
            let poll = try await waitForThreadTurn(threadId: threadId, afterTurnCount: baselineTurnCount)

            await MainActor.run {
                self.replaceMessagesFromThreadHistory(poll.history, threadId: threadId)
                self.isWaitingForResponse = false
                self.chatStatus = nil
                let responseText = (poll.latestTurn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if responseText.isEmpty {
                    self.chatError = "IronClaw 未返回可显示内容"
                }
            }
        } catch is CancellationError {
            await MainActor.run {
                self.isWaitingForResponse = false
                self.chatStatus = nil
            }
        } catch {
            let message = userFacingErrorMessage(error.localizedDescription)
            debugAppend("Chat failed: \(message)")
            await MainActor.run {
                self.isWaitingForResponse = false
                self.chatStatus = nil
                self.chatError = "发送失败：\(message)"
            }
        }
    }

    private func ensureThreadID(_ requestedThreadId: String?) async throws -> String {
        if let requestedThreadId,
           !requestedThreadId.isEmpty,
           isLikelyThreadID(requestedThreadId) {
            return requestedThreadId
        }

        if let currentSessionId,
           !currentSessionId.isEmpty,
           isLikelyThreadID(currentSessionId) {
            return currentSessionId
        }

        let thread = try await createThread()
        await MainActor.run {
            self.currentSessionId = thread.id
            self.currentSessionKey = thread.id
            self.previousResponseId = nil
        }
        return thread.id
    }

    private func postThreadMessage(_ content: String, threadId: String) async throws {
        let url = try endpointURL(path: "/api/chat/send")
        let body = try JSONEncoder().encode(IronClawSendRequest(
            content: content,
            threadId: threadId,
            timezone: TimeZone.current.identifier
        ))
        let request = authorizedRequest(url: url, method: "POST", body: body)
        let (_, response) = try await urlSession.data(for: request)
        try validateHTTP(response)
    }

    private func waitForThreadTurn(threadId: String, afterTurnCount: Int, timeoutSeconds: TimeInterval = 45) async throws -> IronClawThreadPollResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let history = try await fetchThreadHistory(threadId: threadId)
            if let latestTurn = history.turns.last,
               history.turns.count > afterTurnCount,
               latestTurn.isTerminal {
                return IronClawThreadPollResult(history: history, latestTurn: latestTurn)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw GatewayError.serverError(code: "timeout", message: "等待 IronClaw 对话结果超时")
    }

    private func fetchThreadHistory(threadId: String) async throws -> IronClawThreadHistoryResponse {
        let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadId
        let url = try endpointURL(path: "/api/chat/history?thread_id=\(encoded)")
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response)
        return try JSONDecoder.snakeCase.decode(IronClawThreadHistoryResponse.self, from: data)
    }

    private func createThread() async throws -> IronClawThreadInfo {
        let url = try endpointURL(path: "/api/chat/thread/new")
        let request = authorizedRequest(url: url, method: "POST")
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response)
        return try JSONDecoder.snakeCase.decode(IronClawThreadInfo.self, from: data)
    }

    private func loadThreadHistoryIntoMessages(_ threadId: String) async throws {
        let history = try await fetchThreadHistory(threadId: threadId)
        await MainActor.run {
            self.replaceMessagesFromThreadHistory(history, threadId: threadId)
        }
    }

    private func replaceMessagesFromThreadHistory(_ history: IronClawThreadHistoryResponse, threadId: String) {
        messages = mapThreadMessages(history)
        currentSessionId = threadId
        currentSessionKey = threadId
        previousResponseId = nil
    }

    private func mapThreadMessages(_ history: IronClawThreadHistoryResponse) -> [GatewayChatMessage] {
        history.turns.flatMap { turn -> [GatewayChatMessage] in
            var items: [GatewayChatMessage] = []
            let user = turn.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty {
                items.append(GatewayChatMessage(role: "user", content: user))
            }
            let assistant = (turn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !assistant.isEmpty {
                items.append(GatewayChatMessage(role: "assistant", content: assistant))
            }
            return items
        }
    }

    private func isLikelyThreadID(_ value: String?) -> Bool {
        guard let value else { return false }
        return UUID(uuidString: value) != nil
    }

    // MARK: - HTTP Helpers

    private var serverHostDisplay: String {
        if let url = URL(string: gatewayHost), let host = url.host {
            return host
        }
        return gatewayHost
    }

    private func endpointURL(path: String) throws -> URL {
        let normalized = Self.normalizeGatewayEndpoint(gatewayHost, fallbackPort: gatewayPort)
        let rawBase = normalized.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseString: String
        if rawBase.lowercased().hasPrefix("http://") || rawBase.lowercased().hasPrefix("https://") {
            baseString = rawBase
        } else {
            baseString = "http://\(rawBase):\(normalized.port)"
        }

        guard var components = URLComponents(string: baseString), let scheme = components.scheme else {
            throw GatewayError.invalidRequest("IronClaw 地址无效")
        }

        if components.host != nil && components.port == nil {
            let defaultPort = (scheme.lowercased() == "https") ? 443 : 80
            if normalized.port != defaultPort {
                components.port = normalized.port
            }
        }

        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path == "/" ? "" : components.path
        components.path = basePath + suffix

        guard let url = components.url else {
            throw GatewayError.invalidRequest("IronClaw 地址无效")
        }
        return url
    }

    private func authorizedRequest(url: URL, method: String, body: Data? = nil, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let trimmedToken = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func validateHTTP(_ response: URLResponse, data: Data? = nil, endpoint: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GatewayError.serverError(code: "invalid_response", message: "IronClaw 返回了无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 404, endpoint == "/tools/invoke" {
                throw GatewayError.serverError(code: "tool_unavailable", message: "当前 IronClaw 部署未启用工具接口（/tools/invoke）。该功能在此服务器上不可用。")
            }
            throw GatewayError.serverError(code: "http_\(http.statusCode)", message: "IronClaw 请求失败（HTTP \(http.statusCode)）")
        }
    }

    private func fetchModels() async throws -> [IronClawModel] {
        let url = try endpointURL(path: "/v1/models")
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response)
        let decoded = try JSONDecoder().decode(IronClawModelsResponse.self, from: data)
        return decoded.data
    }

    private func fetchHealthDetails() async throws -> IronClawHealthResponse {
        let candidatePaths = ["/api/gateway/status", "/health/detailed", "/health"]
        var lastError: Error?

        for path in candidatePaths {
            do {
                let url = try endpointURL(path: path)
                let request = authorizedRequest(url: url, method: "GET")
                let (data, response) = try await urlSession.data(for: request)
                try validateHTTP(response)
                if let direct = try? JSONDecoder.snakeCase.decode(IronClawHealthResponse.self, from: data) {
                    return direct
                }
                if let envelope = try? JSONDecoder.snakeCase.decode(IronClawGatewayStatusEnvelope.self, from: data) {
                    return IronClawHealthResponse(
                        status: envelope.status,
                        version: envelope.version,
                        uptimeSeconds: envelope.uptimeSeconds,
                        memory: envelope.memory
                    )
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? GatewayError.serverError(code: "status_unavailable", message: "无法读取 IronClaw 状态")
    }

    private func invokeTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let url = try endpointURL(path: "/tools/invoke")
        let body = try JSONSerialization.data(withJSONObject: [
            "tool": name,
            "args": arguments,
        ])
        let request = authorizedRequest(url: url, method: "POST", body: body)
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response, data: data, endpoint: "/tools/invoke")

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ok = json["ok"] as? Bool, !ok {
                let error = json["error"] as? [String: Any]
                throw GatewayError.serverError(
                    code: error?["code"] as? String ?? "tool_failed",
                    message: error?["message"] as? String ?? "IronClaw 工具调用失败"
                )
            }

            if let result = json["result"] as? [String: Any],
               let content = result["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String,
               let nestedData = text.data(using: .utf8),
               let nestedJSON = try JSONSerialization.jsonObject(with: nestedData) as? [String: Any] {
                return nestedJSON
            }

            return json["payload"] as? [String: Any] ?? json
        }

        throw GatewayError.decodingError("无法解析 IronClaw 工具调用结果")
    }

    // MARK: - Mapping

    private func makeAgents(from models: [IronClawModel]) -> [GatewayAgent] {
        if models.isEmpty {
            return [GatewayAgent(id: "main", name: "IronClaw", emoji: "🤖", color: "#6B7280", model: nil, status: "idle", skills: nil)]
        }

        return models.enumerated().map { index, model in
            GatewayAgent(
                id: index == 0 ? "main" : model.id,
                name: index == 0 ? "IronClaw" : model.id,
                emoji: index == 0 ? "🤖" : nil,
                color: "#6B7280",
                model: model.id,
                status: "idle",
                skills: nil
            )
        }
    }

    private func mapSession(_ dict: [String: Any]) -> GatewaySession? {
        let key = dict["key"] as? String ?? dict["sessionKey"] as? String
        guard let key else { return nil }
        let sessionID = dict["id"] as? String ?? key
        let title = dict["derivedTitle"] as? String ?? dict["label"] as? String
        let startedAt = isoString(from: dict["startedAt"])
        let updatedAt = isoString(from: dict["updatedAt"])

        return GatewaySession(
            id: sessionID,
            agentId: parseAgentId(from: key),
            agentName: title,
            model: dict["model"] as? String,
            messageCount: dict["messageCount"] as? Int,
            totalCost: dict["totalCost"] as? Double,
            tokensUsed: GatewayTokenUsage(
                input: dict["inputTokens"] as? Int,
                output: dict["outputTokens"] as? Int,
                cached: dict["cachedTokens"] as? Int
            ),
            updatedAt: updatedAt,
            startedAt: startedAt,
            projectPath: dict["cwd"] as? String,
            status: dict["kind"] as? String ?? "direct",
            sessionKey: key
        )
    }

    private func parseAgentId(from sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":")
        guard parts.count > 1 else { return "main" }
        return String(parts[1])
    }

    private func isoString(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let ms = value as? Double {
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        if let ms = value as? Int {
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        return nil
    }

    private func userFacingErrorMessage(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("401") || normalized.contains("unauthorized") {
            return "IronClaw Bearer Token 缺失或无效。"
        }
        if normalized.contains("403") || normalized.contains("forbidden") {
            return "当前令牌没有访问 IronClaw 的权限。"
        }
        if normalized.contains("failed to connect") || normalized.contains("offline") || normalized.contains("could not connect") {
            return "无法连接到 IronClaw 服务。"
        }
        return message
    }
}

// MARK: - DTOs

private struct IronClawModelsResponse: Decodable {
    let data: [IronClawModel]
}

private struct IronClawModel: Decodable {
    let id: String
}

private struct IronClawHealthResponse: Decodable {
    let status: String?
    let version: String?
    let uptimeSeconds: Double?
    let memory: IronClawMemory?
}

private struct IronClawGatewayStatusEnvelope: Decodable {
    let status: String?
    let version: String?
    let uptimeSeconds: Double?
    let memory: IronClawMemory?
}

private struct IronClawMemory: Decodable {
    let rss: Int?
    let heapUsed: Int?
    let heapTotal: Int?
}

private struct IronClawThreadInfo: Decodable {
    let id: String
}

private struct IronClawThreadHistoryResponse: Decodable {
    let threadId: String
    let turns: [IronClawThreadTurn]
    let hasMore: Bool
}

private struct IronClawThreadTurn: Decodable {
    let turnNumber: Int?
    let userInput: String
    let response: String?
    let state: String
    let startedAt: String?
    let completedAt: String?

    var isTerminal: Bool {
        let normalized = state.lowercased()
        return normalized.contains("completed") || normalized.contains("failed") || normalized.contains("accepted")
    }
}

private struct IronClawSendRequest: Encodable {
    let content: String
    let threadId: String?
    let timezone: String?
}

private struct IronClawThreadPollResult {
    let history: IronClawThreadHistoryResponse
    let latestTurn: IronClawThreadTurn
}

private extension JSONDecoder {
    static let snakeCase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
