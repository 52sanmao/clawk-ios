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
        let storedHost = UserDefaults.standard.string(forKey: "gatewayHost")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host ?? ((storedHost?.isEmpty == false ? storedHost : nil) ?? Config.defaultGatewayBaseURL)
        let normalized = Self.normalizeGatewayEndpoint(resolvedHost, fallbackPort: port ?? 443)
        let storedToken = UserDefaults.standard.string(forKey: "gatewayToken")?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.gatewayHost = normalized.host
        self.gatewayPort = port ?? normalized.port
        self.gatewayToken = token ?? ((storedToken?.isEmpty == false ? storedToken : nil) ?? Config.defaultGatewayToken)
        self.deviceToken = UserDefaults.standard.string(forKey: "gatewayDeviceToken") ?? UUID().uuidString
        super.init()

        if UserDefaults.standard.string(forKey: "gatewayDeviceToken") == nil {
            UserDefaults.standard.set(deviceToken, forKey: "gatewayDeviceToken")
        }
        if storedHost == nil || storedHost?.isEmpty == true {
            UserDefaults.standard.set(normalized.host, forKey: "gatewayHost")
            UserDefaults.standard.set(normalized.port, forKey: "gatewayPort")
        }
        if storedToken == nil || storedToken?.isEmpty == true {
            UserDefaults.standard.set(self.gatewayToken, forKey: "gatewayToken")
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

    var debugLogExportText: String {
        let connectionState = isConnected ? "已连接" : (isConnecting ? "连接中" : "未连接")
        let lines: [String] = [
            "应用: 抓控",
            exportLine("导出时间", value: currentTimestampString()),
            exportLine("IronClaw 地址", value: gatewayHost),
            exportIntLine("端口", value: gatewayPort),
            exportLine("连接状态", value: connectionState),
            exportBoolLine("正在等待响应", value: isWaitingForResponse),
            exportLine("connectionError", value: connectionError),
            exportLine("chatStatus", value: chatStatus),
            exportLine("chatError", value: chatError),
            exportLine("当前线程", value: currentSessionId ?? currentSessionKey),
            "调试日志:",
        ]
        let logLines = debugLog.isEmpty ? ["<empty>"] : debugLog
        return (lines + logLines).joined(separator: "\n")
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
                debugAppend("GET /v1/models 验证成功；这只表示模型接口可达，聊天链路仍需通过线程接口验证")
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
        debugAppend("Refreshing routines from /api/routines")
        let summary = try? await fetchRoutineSummary()
        let routines = try await fetchRoutines()
        let jobs = routines.compactMap { routine in
            if !includeDisabled, routine.enabled == false {
                return nil
            }
            return mapRoutineToCronJob(routine)
        }
        await MainActor.run {
            self.cronJobs = jobs
            self.cronStatus = GatewayCronStatus(
                enabled: (summary?.enabled ?? jobs.filter { $0.enabled == true }.count) > 0,
                jobs: summary?.total ?? jobs.count,
                nextWakeAtMs: jobs.compactMap { $0.nextRunAtMs }.min(),
                storePath: nil
            )
        }
        debugAppend("Loaded \(jobs.count) routines from /api/routines")
        return jobs
    }

    func cronUpdate(id: String, enabled: Bool? = nil, name: String? = nil) async throws {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GatewayError.invalidRequest("IronClaw 当前未提供例行任务重命名接口")
        }
        guard let enabled else {
            _ = try await cronList()
            return
        }

        let endpoint = "/api/routines/\(id)/toggle"
        let url = try endpointURL(path: endpoint)
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        debugAppend("POST \(endpoint) body=\(String(data: body, encoding: .utf8) ?? "{}")")
        let request = authorizedRequest(url: url, method: "POST", body: body)
        let (data, response) = try await urlSession.data(for: request)
        appendHTTPStatusLog(response, endpoint: endpoint)
        try validateHTTP(response, data: data, endpoint: endpoint)
        if let preview = bodyPreview(from: data) {
            debugAppend("\(endpoint) response=\(preview)")
        }
        _ = try await cronList()
    }

    func cronRun(id: String, mode: String = "force") async throws -> GatewayCronRunResult {
        let endpoint = "/api/routines/\(id)/trigger"
        let url = try endpointURL(path: endpoint)
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode])
        debugAppend("POST \(endpoint) body=\(String(data: body, encoding: .utf8) ?? "{}")")
        let request = authorizedRequest(url: url, method: "POST", body: body)
        let (data, response) = try await urlSession.data(for: request)
        appendHTTPStatusLog(response, endpoint: endpoint)
        try validateHTTP(response, data: data, endpoint: endpoint)
        let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let preview = bodyPreview(from: data) {
            debugAppend("\(endpoint) response=\(preview)")
        }
        _ = try? await cronRunsRead(jobId: id, limit: 20)
        return GatewayCronRunResult(
            ok: true,
            ran: (payload["status"] as? String) == "triggered",
            reason: payload["status"] as? String
        )
    }

    func cronRemove(id: String) async throws {
        throw GatewayError.invalidRequest("IronClaw 当前未提供定时任务删除接口")
    }

    func cronGetStatus() async throws -> GatewayCronStatus {
        if cronJobs.isEmpty {
            _ = try await cronList()
        }
        let summary = try? await fetchRoutineSummary()
        let status = GatewayCronStatus(
            enabled: (summary?.enabled ?? cronJobs.filter { $0.enabled == true }.count) > 0,
            jobs: summary?.total ?? cronJobs.count,
            nextWakeAtMs: cronJobs.compactMap { $0.nextRunAtMs }.min(),
            storePath: nil
        )
        await MainActor.run { self.cronStatus = status }
        return status
    }

    func cronRunsRead(jobId: String, limit: Int = 20) async throws -> [GatewayCronRun] {
        let endpoint = "/api/routines/\(jobId)/runs"
        let url = try endpointURL(path: endpoint)
        debugAppend("GET \(endpoint)")
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        appendHTTPStatusLog(response, endpoint: endpoint)
        try validateHTTP(response, data: data, endpoint: endpoint)
        let decoded = try JSONDecoder.snakeCase.decode(IronClawRoutineRunsResponse.self, from: data)
        let runs = Array(decoded.runs.prefix(limit)).map(mapRoutineRun)
        if let preview = bodyPreview(from: data) {
            debugAppend("\(endpoint) response=\(preview)")
        }
        return runs
    }

    func debugLogUserAction(_ message: String) {
        debugAppend(message)
    }

    func refreshCronData(reason: String) async {
        debugAppend(reason)
        do {
            _ = try await cronList()
            _ = try await cronGetStatus()
        } catch {
            appendChatFailureLog(stage: "Routine refresh", error: error)
        }
    }

    func refreshDashboardData(reason: String) async {
        debugAppend(reason)
        async let sessionsTask: Void = loadSessions()
        async let cronTask: Void = refreshCronData(reason: "Refreshing routines from dashboard refresh")
        async let healthTask: Void = loadHealthStatus()
        async let approvalsTask: Void = loadApprovals()
        _ = await (sessionsTask, cronTask, healthTask, approvalsTask)
    }

    private func fetchRoutines() async throws -> [IronClawRoutineInfo] {
        let endpoint = "/api/routines"
        let url = try endpointURL(path: endpoint)
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        appendHTTPStatusLog(response, endpoint: endpoint)
        try validateHTTP(response, data: data, endpoint: endpoint)
        let decoded = try JSONDecoder.snakeCase.decode(IronClawRoutinesResponse.self, from: data)
        return decoded.routines
    }

    private func fetchRoutineSummary() async throws -> IronClawRoutineSummary {
        let endpoint = "/api/routines/summary"
        let url = try endpointURL(path: endpoint)
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await urlSession.data(for: request)
        appendHTTPStatusLog(response, endpoint: endpoint)
        try validateHTTP(response, data: data, endpoint: endpoint)
        return try JSONDecoder.snakeCase.decode(IronClawRoutineSummary.self, from: data)
    }

    private func mapRoutineToCronJob(_ routine: IronClawRoutineInfo) -> GatewayCronJob {
        GatewayCronJob(
            id: routine.id,
            name: routine.name,
            agentId: nil,
            enabled: routine.enabled,
            schedule: GatewayCronSchedule(
                kind: routine.triggerType,
                expr: routine.triggerSummary ?? routine.triggerRaw,
                cron: routine.triggerRaw,
                every: nil,
                at: nil,
                tz: nil
            ),
            sessionTarget: nil,
            wakeMode: routine.actionType,
            deleteAfterRun: nil,
            sessionKey: nil,
            createdAtMs: nil,
            updatedAtMs: nil,
            lastRunAtMs: epochMilliseconds(from: routine.lastRunAt),
            nextRunAtMs: epochMilliseconds(from: routine.nextFireAt),
            lastRunStatus: routine.status ?? routine.verificationStatus,
            lastRunDurationMs: nil,
            consecutiveErrors: routine.consecutiveFailures
        )
    }

    private func mapRoutineRun(_ run: IronClawRoutineRunInfo) -> GatewayCronRun {
        GatewayCronRun(
            id: run.id,
            jobId: run.jobId,
            status: run.status,
            startedAt: run.startedAt,
            finishedAt: run.completedAt,
            durationMs: durationMilliseconds(start: run.startedAt, end: run.completedAt),
            error: run.resultSummary
        )
    }

    private func epochMilliseconds(from isoString: String?) -> Double? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date.timeIntervalSince1970 * 1000
        }
        let fallback = ISO8601DateFormatter()
        guard let date = fallback.date(from: isoString) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    private func durationMilliseconds(start: String?, end: String?) -> Double? {
        guard let startMs = epochMilliseconds(from: start) else { return nil }
        guard let endMs = epochMilliseconds(from: end) else { return nil }
        return max(0, endMs - startMs)
    }

    private func currentRoutineErrorMessage(_ error: Error) -> String {
        userFacingErrorMessage(error.localizedDescription)
    }

    private func currentRoutineRefreshError(_ error: Error) -> String {
        "例行任务刷新失败：\(currentRoutineErrorMessage(error))"
    }

    private func setRoutineRefreshError(_ error: Error) {
        let message = currentRoutineRefreshError(error)
        Task { @MainActor in
            self.chatError = message
        }
    }

    private func clearRoutineRefreshError() {
        Task { @MainActor in
            if self.chatError?.hasPrefix("例行任务刷新失败：") == true {
                self.chatError = nil
            }
        }
    }

    private func recordRoutineRefreshResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            clearRoutineRefreshError()
        case .failure(let error):
            setRoutineRefreshError(error)
        }
    }

    private func refreshRoutinesWithState(reason: String) async {
        debugAppend(reason)
        do {
            _ = try await cronList()
            _ = try await cronGetStatus()
            recordRoutineRefreshResult(.success(()))
        } catch {
            appendChatFailureLog(stage: "Routine refresh", error: error)
            recordRoutineRefreshResult(.failure(error))
        }
    }

    func refreshCronDataWithState(reason: String) async {
        await refreshRoutinesWithState(reason: reason)
    }

    func refreshDashboardDataWithState(reason: String) async {
        debugAppend(reason)
        async let sessionsTask: Void = loadSessions()
        async let cronTask: Void = refreshRoutinesWithState(reason: "Refreshing routines from dashboard refresh")
        async let healthTask: Void = loadHealthStatus()
        async let approvalsTask: Void = loadApprovals()
        _ = await (sessionsTask, cronTask, healthTask, approvalsTask)
    }

    func routineRefreshMessage(_ error: Error) -> String {
        currentRoutineRefreshError(error)
    }

    func routineActionError(_ error: Error) -> String {
        currentRoutineErrorMessage(error)
    }

    func routineActionLog(_ message: String) {
        debugAppend(message)
    }

    func clearRoutineErrorIfNeeded() {
        clearRoutineRefreshError()
    }

    func setRoutineError(_ error: Error) {
        setRoutineRefreshError(error)
    }

    func recordRoutineActionFailure(stage: String, error: Error) {
        appendChatFailureLog(stage: stage, error: error)
    }

    func recordRoutineActionSuccess(_ message: String) {
        debugAppend(message)
    }

    func recordRefreshGesture(_ message: String) {
        debugAppend(message)
    }

    func refreshHomeData(reason: String) async {
        await refreshDashboardDataWithState(reason: reason)
    }

    func refreshTasksData(reason: String) async {
        await refreshCronDataWithState(reason: reason)
    }

    func refreshTaskRuns(jobId: String, limit: Int = 20) async throws -> [GatewayCronRun] {
        try await cronRunsRead(jobId: jobId, limit: limit)
    }

    func runRoutine(id: String, mode: String = "force") async throws -> GatewayCronRunResult {
        try await cronRun(id: id, mode: mode)
    }

    func toggleRoutine(id: String, enabled: Bool) async throws {
        try await cronUpdate(id: id, enabled: enabled)
    }

    func loadRoutinesOnAppear() async {
        await refreshCronDataWithState(reason: "Loading routines on appear")
    }

    func loadRoutinesAfterConnect() async {
        await refreshCronDataWithState(reason: "IronClaw connected, refreshing routines")
    }

    func loadAllDashboardDataForRefresh() async {
        await refreshDashboardDataWithState(reason: "User triggered dashboard refresh")
    }

    func logRefreshGesture(_ screen: String) {
        debugAppend("User triggered pull-to-refresh on \(screen)")
    }

    func logRoutineScreenRefresh() {
        debugAppend("User triggered routine list refresh")
    }

    func logHomeScreenRefresh() {
        debugAppend("User triggered home refresh")
    }

    func logConnectForRefresh() {
        debugAppend("Gateway was offline; reconnecting before refresh")
    }

    func logRoutineRunRequest(_ id: String) {
        debugAppend("User requested routine trigger for \(id)")
    }

    func logRoutineToggleRequest(_ id: String, enabled: Bool) {
        debugAppend("User requested routine toggle for \(id) → enabled=\(enabled)")
    }

    func logRoutineRunsRequest(_ id: String) {
        debugAppend("Loading routine runs for \(id)")
    }

    func logRoutineRefreshFailure(_ error: Error) {
        appendChatFailureLog(stage: "Routine refresh", error: error)
    }

    func logRoutineRefreshSuccess(_ count: Int) {
        debugAppend("Routine refresh succeeded with \(count) items")
    }

    func logHomeRefreshStart() {
        debugAppend("Starting home refresh")
    }

    func logHomeRefreshEnd() {
        debugAppend("Finished home refresh")
    }

    func logRoutineRefreshStart() {
        debugAppend("Starting routine refresh")
    }

    func logRoutineRefreshEnd() {
        debugAppend("Finished routine refresh")
    }

    func logDashboardFallback(_ message: String) {
        debugAppend(message)
    }

    func logTaskScreenMessage(_ message: String) {
        debugAppend(message)
    }

    func logTaskActionFailure(_ error: Error) {
        appendChatFailureLog(stage: "Routine action", error: error)
    }

    func logTaskActionSuccess(_ message: String) {
        debugAppend(message)
    }

    func logTaskRefresh(_ reason: String) {
        debugAppend(reason)
    }

    func refreshTasks(reason: String) async {
        await refreshCronDataWithState(reason: reason)
    }

    func refreshHome(reason: String) async {
        await refreshDashboardDataWithState(reason: reason)
    }

    func refreshAfterConnect() async {
        await refreshDashboardDataWithState(reason: "Gateway reconnected, refreshing dashboard")
    }

    func refreshRoutines(reason: String) async {
        await refreshCronDataWithState(reason: reason)
    }

    func fetchRoutineRuns(jobId: String, limit: Int = 20) async throws -> [GatewayCronRun] {
        try await cronRunsRead(jobId: jobId, limit: limit)
    }

    func triggerRoutine(id: String) async throws -> GatewayCronRunResult {
        try await cronRun(id: id)
    }

    func updateRoutineEnabled(id: String, enabled: Bool) async throws {
        try await cronUpdate(id: id, enabled: enabled)
    }

    func deleteRoutine(id: String) async throws {
        try await cronRemove(id: id)
    }

    func logRoutineDeleteAttempt(_ id: String) {
        debugAppend("User requested routine delete for \(id)")
    }

    func logRoutineDeleteFailure(_ error: Error) {
        appendChatFailureLog(stage: "Routine delete", error: error)
    }

    func logRoutineDeleteSuccess(_ id: String) {
        debugAppend("Routine delete is unsupported for \(id)")
    }

    func logRoutineDetailAppear(_ id: String) {
        debugAppend("Opening routine detail for \(id)")
    }

    func logRoutineDetailLoaded(_ count: Int, id: String) {
        debugAppend("Loaded \(count) runs for routine \(id)")
    }

    func logRoutineDetailFailure(_ id: String, error: Error) {
        appendChatFailureLog(stage: "Routine detail \(id)", error: error)
    }

    func logRoutineSummary(_ summary: IronClawRoutineSummary) {
        debugAppend("Routine summary total=\(summary.total) enabled=\(summary.enabled) disabled=\(summary.disabled)")
    }

    func logRoutineListPayload(_ count: Int) {
        debugAppend("Routine API returned \(count) items")
    }

    func logRoutineRunPayload(_ count: Int, id: String) {
        debugAppend("Routine runs API returned \(count) items for \(id)")
    }

    func logTaskRefreshGesture() {
        debugAppend("User pulled to refresh tasks")
    }

    func logHomeRefreshGesture() {
        debugAppend("User pulled to refresh home")
    }

    func logGatewayReconnectGesture() {
        debugAppend("Reconnect requested during refresh")
    }

    func refreshTasksAfterConnect() async {
        await refreshCronDataWithState(reason: "Gateway connected, refreshing tasks")
    }

    func refreshTasksOnAppear() async {
        await refreshCronDataWithState(reason: "Task screen appeared, refreshing tasks")
    }

    func refreshDashboardOnAppear() async {
        await refreshDashboardDataWithState(reason: "Home screen appeared, refreshing dashboard")
    }

    func refreshDashboardAfterConnect() async {
        await refreshDashboardDataWithState(reason: "Gateway connected, refreshing home dashboard")
    }

    func logTaskEmptyState(_ connected: Bool) {
        debugAppend(connected ? "Routine list is empty" : "Routine list unavailable while offline")
    }

    func logTaskCount(_ count: Int) {
        debugAppend("Routine screen showing \(count) items")
    }

    func logRoutineSummaryFailure(_ error: Error) {
        appendChatFailureLog(stage: "Routine summary", error: error)
    }

    func logRoutineListFailure(_ error: Error) {
        appendChatFailureLog(stage: "Routine list", error: error)
    }

    func logRoutineRunsFailure(_ error: Error, id: String) {
        appendChatFailureLog(stage: "Routine runs \(id)", error: error)
    }

    func logRoutineTriggerFailure(_ error: Error, id: String) {
        appendChatFailureLog(stage: "Routine trigger \(id)", error: error)
    }

    func logRoutineToggleFailure(_ error: Error, id: String) {
        appendChatFailureLog(stage: "Routine toggle \(id)", error: error)
    }

    func logRoutineTriggerSuccess(_ id: String) {
        debugAppend("Routine trigger accepted for \(id)")
    }

    func logRoutineToggleSuccess(_ id: String, enabled: Bool) {
        debugAppend("Routine toggle succeeded for \(id) → enabled=\(enabled)")
    }

    func logRoutineRunsLoaded(_ id: String, count: Int) {
        debugAppend("Routine detail loaded \(count) runs for \(id)")
    }

    func logRoutineUnsupportedDelete(_ id: String) {
        debugAppend("Routine delete requested but unsupported for \(id)")
    }

    func logTaskRefreshCompletion() {
        debugAppend("Task refresh completed")
    }

    func logHomeRefreshCompletion() {
        debugAppend("Home refresh completed")
    }

    func logTaskRefreshStart() {
        debugAppend("Task refresh started")
    }

    func logDashboardRefreshStart() {
        debugAppend("Dashboard refresh started")
    }

    func logDashboardRefreshCompletion() {
        debugAppend("Dashboard refresh completed")
    }

    func logTaskScreenAppear() {
        debugAppend("Task screen appeared")
    }

    func logTaskScreenConnect() {
        debugAppend("Task screen observed gateway connect")
    }

    func logHomeScreenAppear() {
        debugAppend("Home screen appeared")
    }

    func logHomeScreenConnect() {
        debugAppend("Home screen observed gateway connect")
    }

    func logRoutinesAPIRequest(_ endpoint: String) {
        debugAppend("Routine API request \(endpoint)")
    }

    func logRoutinesAPIResponse(_ endpoint: String, preview: String?) {
        if let preview {
            debugAppend("Routine API response \(endpoint)=\(preview)")
        } else {
            debugAppend("Routine API response \(endpoint) received")
        }
    }

    func logRoutinesAPIFailure(_ endpoint: String, error: Error) {
        appendChatFailureLog(stage: endpoint, error: error)
    }

    func logTaskRefreshReason(_ reason: String) {
        debugAppend(reason)
    }

    func logDashboardRefreshReason(_ reason: String) {
        debugAppend(reason)
    }

    func logGatewayRefreshConnect() {
        debugAppend("Gateway reconnection started for refresh")
    }

    func logGatewayRefreshConnected() {
        debugAppend("Gateway reconnection finished for refresh")
    }

    func logRefreshSleep() {
        debugAppend("Waiting briefly for gateway reconnect")
    }

    func logTaskLoadFromAppear() {
        debugAppend("Loading routines because task screen appeared")
    }

    func logTaskLoadFromConnect() {
        debugAppend("Loading routines because gateway connected")
    }

    func logHomeLoadFromAppear() {
        debugAppend("Loading dashboard because home appeared")
    }

    func logHomeLoadFromConnect() {
        debugAppend("Loading dashboard because gateway connected")
    }

    func logTaskUserError(_ error: Error) {
        setRoutineRefreshError(error)
    }

    func logTaskUserSuccess() {
        clearRoutineRefreshError()
    }

    func clearTaskUserError() {
        clearRoutineRefreshError()
    }

    func setTaskUserError(_ error: Error) {
        setRoutineRefreshError(error)
    }

    func logRoutineStatusComputation(_ jobs: Int, nextWake: Double?) {
        debugAppend("Computed routine status jobs=\(jobs) nextWake=\(nextWake.map { String(Int($0)) } ?? "nil")")
    }

    func logRoutineSummaryUnavailable() {
        debugAppend("Routine summary unavailable, using local status fallback")
    }

    func logRoutineNameUnsupported() {
        debugAppend("Routine rename requested but unsupported by current API")
    }

    func logRoutineRefreshLocalFallback() {
        debugAppend("Routine refresh using HTTP API rather than /tools/invoke")
    }

    func logTaskRefreshNoError() {
        clearRoutineRefreshError()
    }

    func logTaskRefreshError(_ error: Error) {
        setRoutineRefreshError(error)
    }

    func logTaskInteraction(_ message: String) {
        debugAppend(message)
    }

    func loadTaskData() async {
        await refreshCronDataWithState(reason: "Loading task data")
    }

    func loadDashboardData() async {
        await refreshDashboardDataWithState(reason: "Loading dashboard data")
    }

    func logTaskManualRefresh() {
        debugAppend("Manual task refresh requested")
    }

    func logDashboardManualRefresh() {
        debugAppend("Manual dashboard refresh requested")
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
            debugAppend("Chat thread ready: \(threadId)")
            let baselineHistory = try await fetchThreadHistory(threadId: threadId)
            let baselineTurnCount = baselineHistory.turns.count
            debugAppend("GET /api/chat/history → baseline turns=\(baselineTurnCount)")

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
            debugAppend("GET /api/chat/history → terminal state=\(poll.latestTurn.state)")

            await MainActor.run {
                self.replaceMessagesFromThreadHistory(poll.history, threadId: threadId)
                self.isWaitingForResponse = false
                self.chatStatus = nil
                let responseText = (poll.latestTurn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if responseText.isEmpty {
                    self.chatError = "IronClaw 未返回可显示内容"
                    self.debugAppend("Chat completed but response text was empty")
                }
            }
        } catch is CancellationError {
            debugAppend("Chat cancelled")
            await MainActor.run {
                self.isWaitingForResponse = false
                self.chatStatus = nil
            }
        } catch {
            let message = userFacingErrorMessage(error.localizedDescription)
            appendChatFailureLog(stage: "Chat", error: error)
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
            debugAppend("Reusing requested thread_id=\(requestedThreadId)")
            return requestedThreadId
        }

        if let currentSessionId,
           !currentSessionId.isEmpty,
           isLikelyThreadID(currentSessionId) {
            debugAppend("Reusing current thread_id=\(currentSessionId)")
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

    private func appendChatFailureLog(stage: String, error: Error) {
        let rawMessage = error.localizedDescription
        let userMessage = userFacingErrorMessage(rawMessage)
        debugAppend("\(stage) failed: \(userMessage) | raw=\(rawMessage)")
    }

    private func appendHTTPStatusLog(_ response: URLResponse, endpoint: String) {
        if let http = response as? HTTPURLResponse {
            debugAppend("\(http.statusCode) \(endpoint)")
        } else {
            debugAppend("Non-HTTP response from \(endpoint)")
        }
    }

    private func appendHTTPFailureLog(_ error: Error, endpoint: String) {
        let message = userFacingErrorMessage(error.localizedDescription)
        debugAppend("\(endpoint) failed: \(message)")
    }

    private func bodyPreview(from data: Data?, limit: Int = 1200) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        return text
    }

    private func appendThreadStateLog(_ state: String, turnCount: Int, endpoint: String) {
        debugAppend("\(endpoint) → turns=\(turnCount), latestState=\(state)")
    }

    private func latestThreadState(from history: IronClawThreadHistoryResponse) -> String {
        history.turns.last?.state ?? "none"
    }

    private func logThreadHistorySnapshot(_ history: IronClawThreadHistoryResponse, endpoint: String) {
        appendThreadStateLog(latestThreadState(from: history), turnCount: history.turns.count, endpoint: endpoint)
    }

    private func currentTimestampString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func exportLine(_ label: String, value: String?) -> String {
        "\(label): \((value?.isEmpty == false) ? value! : "无")"
    }

    private func exportBoolLine(_ label: String, value: Bool) -> String {
        "\(label): \(value ? "是" : "否")"
    }

    private func exportIntLine(_ label: String, value: Int) -> String {
        "\(label): \(value)"
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    private func postThreadMessage(_ content: String, threadId: String) async throws {
        let endpoint = "/api/chat/send"
        let url = try endpointURL(path: endpoint)
        let body = try JSONEncoder().encode(IronClawSendRequest(
            content: content,
            threadId: threadId,
            timezone: TimeZone.current.identifier
        ))
        if let preview = bodyPreview(from: body) {
            debugAppend("POST \(endpoint) body=\(preview)")
        }
        let request = authorizedRequest(url: url, method: "POST", body: body)
        do {
            let (data, response) = try await urlSession.data(for: request)
            appendHTTPStatusLog(response, endpoint: endpoint)
            if let preview = bodyPreview(from: data) {
                debugAppend("\(endpoint) response=\(preview)")
            }
            try validateHTTP(response, data: data, endpoint: endpoint)
        } catch {
            appendHTTPFailureLog(error, endpoint: endpoint)
            throw error
        }
    }

    private func waitForThreadTurn(threadId: String, afterTurnCount: Int, timeoutSeconds: TimeInterval = 45) async throws -> IronClawThreadPollResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let history = try await fetchThreadHistory(threadId: threadId)
            logThreadHistorySnapshot(history, endpoint: "/api/chat/history")
            if let latestTurn = history.turns.last,
               history.turns.count > afterTurnCount,
               latestTurn.isTerminal {
                return IronClawThreadPollResult(history: history, latestTurn: latestTurn)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        debugAppend("/api/chat/history polling timed out after \(Int(timeoutSeconds))s")
        throw GatewayError.serverError(code: "timeout", message: "等待 IronClaw 对话结果超时")
    }

    private func fetchThreadHistory(threadId: String) async throws -> IronClawThreadHistoryResponse {
        let endpoint = "/api/chat/history"
        let url = try endpointURL(path: endpoint, queryItems: [
            URLQueryItem(name: "thread_id", value: threadId)
        ])
        let request = authorizedRequest(url: url, method: "GET")
        do {
            let (data, response) = try await urlSession.data(for: request)
            appendHTTPStatusLog(response, endpoint: endpoint)
            try validateHTTP(response)
            return try JSONDecoder.snakeCase.decode(IronClawThreadHistoryResponse.self, from: data)
        } catch {
            appendHTTPFailureLog(error, endpoint: endpoint)
            throw error
        }
    }

    private func createThread() async throws -> IronClawThreadInfo {
        let endpoint = "/api/chat/thread/new"
        let url = try endpointURL(path: endpoint)
        let request = authorizedRequest(url: url, method: "POST")
        do {
            let (data, response) = try await urlSession.data(for: request)
            appendHTTPStatusLog(response, endpoint: endpoint)
            try validateHTTP(response)
            let thread = try JSONDecoder.snakeCase.decode(IronClawThreadInfo.self, from: data)
            debugAppend("Created thread_id=\(thread.id)")
            return thread
        } catch {
            appendHTTPFailureLog(error, endpoint: endpoint)
            throw error
        }
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

    private func endpointURL(path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
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
        if let queryItems {
            components.queryItems = queryItems
        }

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

            var message = "IronClaw 请求失败（HTTP \(http.statusCode)）"
            if let preview = bodyPreview(from: data) {
                message += "：\(preview)"
            }
            throw GatewayError.serverError(code: "http_\(http.statusCode)", message: message)
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
        return normalized.contains("completed") || normalized.contains("failed")
    }
}

private struct IronClawSendRequest: Encodable {
    let content: String
    let threadId: String?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case content
        case threadId = "thread_id"
        case timezone
    }
}

private struct IronClawThreadPollResult {
    let history: IronClawThreadHistoryResponse
    let latestTurn: IronClawThreadTurn
}

private struct IronClawRoutinesResponse: Decodable {
    let routines: [IronClawRoutineInfo]
}

private struct IronClawRoutineInfo: Decodable {
    let id: String
    let name: String
    let description: String?
    let enabled: Bool?
    let triggerType: String?
    let triggerRaw: String?
    let triggerSummary: String?
    let actionType: String?
    let lastRunAt: String?
    let nextFireAt: String?
    let runCount: Int?
    let consecutiveFailures: Int?
    let status: String?
    let verificationStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, enabled, status
        case triggerType = "trigger_type"
        case triggerRaw = "trigger_raw"
        case triggerSummary = "trigger_summary"
        case actionType = "action_type"
        case lastRunAt = "last_run_at"
        case nextFireAt = "next_fire_at"
        case runCount = "run_count"
        case consecutiveFailures = "consecutive_failures"
        case verificationStatus = "verification_status"
    }
}

private struct IronClawRoutineSummary: Decodable {
    let total: Int
    let enabled: Int
    let disabled: Int
    let unverified: Int?
    let failing: Int?
    let runsToday: Int?

    enum CodingKeys: String, CodingKey {
        case total, enabled, disabled, unverified, failing
        case runsToday = "runs_today"
    }
}

private struct IronClawRoutineRunsResponse: Decodable {
    let routineId: String
    let runs: [IronClawRoutineRunInfo]

    enum CodingKeys: String, CodingKey {
        case routineId = "routine_id"
        case runs
    }
}

private struct IronClawRoutineRunInfo: Decodable {
    let id: String
    let triggerType: String?
    let startedAt: String?
    let completedAt: String?
    let status: String?
    let resultSummary: String?
    let tokensUsed: Int?
    let jobId: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case triggerType = "trigger_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case resultSummary = "result_summary"
        case tokensUsed = "tokens_used"
        case jobId = "job_id"
    }
}

private extension JSONDecoder {

private struct IronClawRoutineSummary: Decodable {
    let total: Int
    let enabled: Int
    let disabled: Int
    let unverified: Int?
    let failing: Int?
    let runsToday: Int?
}

private struct IronClawRoutineRunsResponse: Decodable {
    let routineId: String
    let runs: [IronClawRoutineRunInfo]
}

private struct IronClawRoutineRunInfo: Decodable {
    let id: String
    let triggerType: String?
    let startedAt: String?
    let completedAt: String?
    let status: String?
    let resultSummary: String?
    let tokensUsed: Int?
    let jobId: String?
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
