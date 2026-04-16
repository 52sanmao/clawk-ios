import Foundation
import Combine

final class DashboardAPIClient: ObservableObject {
    @Published var isReachable = false
    @Published var lastError: String?
    @Published var debugLog: [String] = []

    private let session = URLSession.shared
    private var baseURL: String

    init(baseURL: String? = nil) {
        let cachedURL = UserDefaults.standard.string(forKey: "dashboardBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedURL, (cachedURL.contains("127.0.0.1") || cachedURL.contains("localhost")) {
            UserDefaults.standard.removeObject(forKey: "dashboardBaseURL")
        }
        self.baseURL = baseURL ?? Self.resolvedBaseURL()
    }

    private static func resolvedBaseURL() -> String {
        if let stored = UserDefaults.standard.string(forKey: "dashboardBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        if let gateway = UserDefaults.standard.string(forKey: "gatewayHost")?.trimmingCharacters(in: .whitespacesAndNewlines), !gateway.isEmpty {
            return gateway
        }
        return Config.defaultGatewayBaseURL
    }

    func updateBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = trimmed.isEmpty ? Config.defaultGatewayBaseURL : trimmed
        UserDefaults.standard.set(baseURL, forKey: "dashboardBaseURL")
        log("Updated Dashboard base URL to \(baseURL)")
    }

    var debugLogExportSection: String {
        let lines: [String] = [
            "模块: Dashboard API",
            "Base URL: \(baseURL)",
            "可访问: \(isReachable ? "是" : "否")",
            "lastError: \(lastError ?? "无")",
            "日志:",
        ]
        let logLines = debugLog.isEmpty ? ["<empty>"] : debugLog
        return (lines + logLines).joined(separator: "\n")
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    func fetchAgents() async throws -> [DashboardAgent] {
        [
            DashboardAgent(
                id: "ironclaw",
                name: "IronClaw",
                emoji: "🤖",
                color: "#6B7280",
                model: nil,
                status: isReachable ? "online" : nil,
                skills: nil,
                activeSkills: nil
            )
        ]
    }

    func fetchSessions(days: Int = 7, limit: Int = 50, offset: Int = 0) async throws -> SessionsResponse {
        let response = try await getThreadList()
        let allThreads = ([response.assistantThread].compactMap { $0 } + response.threads)
            .sorted { $0.updatedAt > $1.updatedAt }
        let safeLimit = min(max(limit, 1), 200)
        let slice = Array(allThreads.dropFirst(offset).prefix(safeLimit))
        let sessions = slice.map(mapThreadInfoToDashboardSession)
        return SessionsResponse(
            sessions: sessions,
            pagination: SessionsResponse.Pagination(total: allThreads.count, limit: safeLimit, offset: offset)
        )
    }

    func fetchSessionMessages(sessionId: String, limit: Int = 200) async throws -> [SessionMessage] {
        let history = try await getThreadHistory(threadId: sessionId, limit: min(max(limit, 1), 500))
        return mapTurnsToSessionMessages(history)
    }

    func fetchCosts(period: String = "week") async throws -> CostData {
        CostData(totalCost: nil, byAgent: nil, byModel: nil, byDay: nil, sessionsCount: nil, tokensUsed: nil)
    }

    func fetchAllSessions(days: Int, batchSize: Int = 200) async throws -> [DashboardSession] {
        var allSessions: [DashboardSession] = []
        var offset = 0

        while true {
            let response = try await fetchSessions(days: days, limit: batchSize, offset: offset)
            let page = response.sessions ?? []
            allSessions.append(contentsOf: page)

            if page.isEmpty || page.count < batchSize {
                break
            }
            if let total = response.pagination?.total, allSessions.count >= total {
                break
            }
            offset += page.count
        }

        return allSessions
    }

    func fetchDisplayCosts(period: String = "week", preferences: CostDisplayPreferences) async throws -> CostData {
        guard preferences.appliesSubscriptionCoverage else {
            return try await fetchCosts(period: period)
        }

        let sessions = try await fetchAllSessions(days: Self.sessionLookbackDays(for: period))
        return Self.makeDisplayCostData(from: sessions, period: period, preferences: preferences)
    }

    func fetchMemoryFiles() async throws -> [MemoryFile] {
        let data = try await get("/api/memory/list")
        let response = try JSONDecoder().decode(MemoryListResponse.self, from: data)
        return response.entries.filter { !$0.isDir }.map {
            MemoryFile(
                path: $0.path,
                name: $0.name,
                group: nil,
                groupLabel: nil,
                size: nil,
                mtime: Self.mtimeEpoch(from: $0.updatedAt)
            )
        }
    }

    func readMemoryFile(path: String) async throws -> MemoryFileContent {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let data = try await get("/api/memory/read?path=\(encoded)")
        let response = try JSONDecoder().decode(MemoryReadResponse.self, from: data)
        return MemoryFileContent(content: response.content, mtime: Self.mtimeEpoch(from: response.updatedAt), path: response.path)
    }

    func updateMemoryFile(path: String, content: String, expectedMtime: Double? = nil) async throws -> MemoryFileUpdateResult {
        let data = try await post("/api/memory/write", body: ["path": path, "content": content])
        if let decoded = try? JSONDecoder().decode(MemoryFileUpdateResult.self, from: data) {
            return decoded
        }
        return MemoryFileUpdateResult(ok: true, path: path, mtime: expectedMtime, status: "written")
    }

    func fetchTasks() async throws -> TasksResponse {
        let data = try await get("/api/routines")
        let response = try JSONDecoder().decode(RoutinesResponse.self, from: data)
        let tasks = response.routines.map(mapRoutineToTask)
        return TasksResponse(tasks: tasks, agents: nil, stats: nil)
    }

    func updateTaskStatus(id: String, status: String) async throws {
        let enabled = ["enabled", "active", "running", "in_progress"].contains(status.lowercased())
        _ = try await post("/api/routines/\(id)/toggle", body: ["enabled": enabled])
    }

    func fetchSummaries(days: Int = 30) async throws -> SummariesResponse {
        SummariesResponse(
            summaries: [["title": "最近 \(days) 天摘要暂未在 iOS 客户端映射", "source": "gateway"]],
            totalSessions: nil,
            summarizedCount: nil,
            pendingCount: nil
        )
    }

    func fetchOpenClawStatus() async throws -> OpenClawStatus {
        do {
            let data = try await get("/api/gateway/status")
            if let response = try? JSONDecoder().decode(GatewayStatusSummary.self, from: data) {
                return mapGatewayStatusToOpenClawStatus(response)
            }
        } catch {
            log("GET /api/gateway/status unavailable, falling back to empty status")
        }

        return OpenClawStatus(
            cronJobs: nil,
            heartbeats: nil,
            summary: OpenClawSummary(
                totalCronJobs: 0,
                enabledCronJobs: 0,
                cronErrors: 0,
                heartbeatCount: 0,
                staleHeartbeats: 0,
                nextRunAtMs: nil,
                lastRunAtMs: nil
            ),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func fetchGatewayConfig() async throws -> GatewayConfig {
        GatewayConfig(url: baseURL, token: normalizedGatewayToken)
    }

    func fetchChatSessions(days: Int = 7, limit: Int = 50) async throws -> ChatSessionsResponse {
        let response = try await fetchSessions(days: days, limit: limit, offset: 0)
        let sessions = (response.sessions ?? []).map { session in
            [
                "id": session.id,
                "agentName": session.agentName ?? "聊天会话",
                "updatedAt": session.updatedAt ?? session.startedAt ?? "",
                "status": session.status ?? "Idle"
            ]
        }
        return ChatSessionsResponse(sessions: sessions)
    }

    func fetchChatHistory(sessionId: String, limit: Int = 100) async throws -> [SessionMessage] {
        try await fetchSessionMessages(sessionId: sessionId, limit: limit)
    }

    func fetchLiveFiles() async throws -> LiveFilesResponse {
        LiveFilesResponse(generatedAt: ISO8601DateFormatter().string(from: Date()), files: nil)
    }

    func checkHealth() async {
        do {
            try await checkGatewayOnlyHealth()
            await MainActor.run {
                self.isReachable = true
                self.lastError = nil
            }
        } catch {
            await MainActor.run {
                self.isReachable = false
                self.lastError = error.localizedDescription
            }
        }
    }

    struct SessionsResponse: Codable {
        let sessions: [DashboardSession]?
        let pagination: Pagination?

        struct Pagination: Codable {
            let total: Int?
            let limit: Int?
            let offset: Int?
        }
    }

    struct CostData {
        let totalCost: Double?
        let byAgent: [AgentCost]?
        let byModel: [ModelCost]?
        let byDay: [DayCost]?
        let sessionsCount: Int?
        let tokensUsed: DashboardTokenUsage?

        struct AgentCost: Identifiable {
            let agentName: String
            let cost: Double
            var id: String { agentName }
        }

        struct ModelCost: Identifiable {
            let model: String
            let cost: Double
            var id: String { model }
        }

        struct DayCost: Identifiable {
            let date: String
            let cost: Double
            var id: String { date }
        }

        struct DashboardTokenUsage {
            let input: Int?
            let output: Int?
            let cached: Int?
        }
    }

    struct MemoryFile: Codable, Identifiable {
        let path: String
        let name: String?
        let group: String?
        let groupLabel: String?
        let size: Int?
        let mtime: Double?
        var id: String { path }

        var displayName: String { name ?? path.components(separatedBy: "/").last ?? path }
    }

    struct MemoryFileContent: Codable {
        let content: String
        let mtime: Double?
        let path: String
    }

    struct MemoryFileUpdateResult: Codable {
        let ok: Bool?
        let path: String?
        let mtime: Double?
        let status: String?
    }

    struct TasksResponse: Codable {
        let tasks: [DashboardTask]?
        let agents: [DashboardAgent]?
        let stats: TaskStats?
    }

    struct SummariesResponse: Codable {
        let summaries: [[String: String]]?
        let totalSessions: Int?
        let summarizedCount: Int?
        let pendingCount: Int?
    }

    struct GatewayConfig: Codable {
        let url: String?
        let token: String?
    }

    struct ChatSessionsResponse: Codable {
        let sessions: [[String: String]]?
    }

    struct LiveFilesResponse: Codable {
        let generatedAt: String?
        let files: [LiveFile]?

        struct LiveFile: Codable, Identifiable {
            let path: String
            let status: String?
            let additions: Int?
            let deletions: Int?
            let preview: String?
            var id: String { path }
        }
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        DispatchQueue.main.async {
            self.debugLog.append(entry)
            if self.debugLog.count > 300 {
                self.debugLog.removeFirst()
            }
        }
    }

    private func logRequest(_ method: String, url: URL, body: Data? = nil) {
        if let body, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            log("\(method) \(url.absoluteString) body=\(text)")
        } else {
            log("\(method) \(url.absoluteString)")
        }
    }

    private func logResponse(_ response: URLResponse, data: Data? = nil) {
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

    private func logFailure(_ method: String, url: URL, error: Error) {
        log("\(method) \(url.absoluteString) failed: \(error.localizedDescription)")
    }

    private var normalizedGatewayToken: String? {
        let trimmed = UserDefaults.standard.string(forKey: "gatewayToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func requestURL(for path: String) throws -> URL {
        guard var baseComponents = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }

        let incoming = URLComponents(string: path)
        let incomingPath = incoming?.path ?? path
        let normalizedIncomingPath = incomingPath.hasPrefix("/") ? incomingPath : "/\(incomingPath)"

        let trimmedBasePath = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedIncomingPath = normalizedIncomingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combined = [trimmedBasePath, trimmedIncomingPath].filter { !$0.isEmpty }.joined(separator: "/")
        baseComponents.path = "/\(combined)"
        baseComponents.percentEncodedQuery = incoming?.percentEncodedQuery

        guard let url = baseComponents.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func makeRequest(url: URL, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = normalizedGatewayToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        logRequest(request.httpMethod ?? "GET", url: request.url!, body: request.httpBody)
        do {
            let (data, response) = try await session.data(for: request)
            logResponse(response, data: data)
            try validateResponse(response, data: data)
            await MainActor.run {
                self.isReachable = true
                self.lastError = nil
            }
            return data
        } catch {
            logFailure(request.httpMethod ?? "GET", url: request.url!, error: error)
            await MainActor.run {
                self.isReachable = false
                self.lastError = error.localizedDescription
            }
            throw error
        }
    }

    private func get(_ path: String) async throws -> Data {
        let url = try requestURL(for: path)
        let request = makeRequest(url: url, method: "GET")
        return try await execute(request)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        let url = try requestURL(for: path)
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = makeRequest(url: url, method: "POST", body: data)
        return try await execute(request)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(400...599).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (body?.isEmpty == false ? body! : HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            throw NSError(domain: "DashboardAPIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func getThreadList() async throws -> ThreadListResponse {
        let data = try await get("/api/chat/threads")
        return try JSONDecoder().decode(ThreadListResponse.self, from: data)
    }

    private func getThreadHistory(threadId: String, limit: Int = 200) async throws -> HistoryResponse {
        let encodedThreadId = threadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadId
        let data = try await get("/api/chat/history?thread_id=\(encodedThreadId)&limit=\(limit)")
        return try JSONDecoder().decode(HistoryResponse.self, from: data)
    }

    private func mapThreadInfoToDashboardSession(_ thread: ThreadInfo) -> DashboardSession {
        DashboardSession(
            id: thread.id,
            agentId: thread.channel,
            agentName: buildSessionLabel(for: thread),
            agentEmoji: thread.threadType == "assistant" ? "🧠" : "💬",
            agentColor: nil,
            model: nil,
            messageCount: thread.turnCount,
            totalCost: nil,
            tokensUsed: nil,
            updatedAt: thread.updatedAt,
            startedAt: thread.createdAt,
            projectPath: nil,
            source: thread.channel ?? "gateway",
            status: thread.state,
            folderTrail: nil
        )
    }

    private func mapTurnsToSessionMessages(_ history: HistoryResponse) -> [SessionMessage] {
        history.turns.enumerated().flatMap { index, turn in
            var items: [SessionMessage] = []

            let userInput = turn.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userInput.isEmpty {
                items.append(SessionMessage(
                    id: "\(history.threadId)-user-\(index)",
                    role: "user",
                    content: userInput,
                    timestamp: turn.startedAt,
                    cost: nil,
                    model: nil,
                    toolCalls: nil,
                    toolResults: nil
                ))
            }

            let response = (turn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !response.isEmpty {
                items.append(SessionMessage(
                    id: "\(history.threadId)-assistant-\(index)",
                    role: "assistant",
                    content: response,
                    timestamp: turn.completedAt ?? turn.startedAt,
                    cost: nil,
                    model: nil,
                    toolCalls: nil,
                    toolResults: nil
                ))
            }

            return items
        }
    }

    private func buildSessionLabel(for thread: ThreadInfo) -> String {
        if let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return thread.threadType == "assistant" ? "Assistant" : "聊天会话"
    }

    private func mapRoutineToTask(_ routine: RoutineInfo) -> DashboardTask {
        DashboardTask(
            id: routine.id,
            title: routine.name,
            agent_id: nil,
            agent_name: nil,
            agent_emoji: nil,
            status: routine.status ?? (routine.enabled == true ? "enabled" : "disabled"),
            started_at: routine.lastRunAt,
            completed_at: routine.nextRunAt
        )
    }

    private func mapGatewayStatusToOpenClawStatus(_ status: GatewayStatusSummary) -> OpenClawStatus {
        OpenClawStatus(
            cronJobs: nil,
            heartbeats: nil,
            summary: OpenClawSummary(
                totalCronJobs: status.sessions ?? 0,
                enabledCronJobs: status.agents ?? 0,
                cronErrors: 0,
                heartbeatCount: status.connectedDevices ?? 0,
                staleHeartbeats: 0,
                nextRunAtMs: nil,
                lastRunAtMs: nil
            ),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func checkGatewayOnlyHealth() async throws {
        for path in ["/api/health", "/v1/models"] {
            do {
                let _ = try await get(path)
                return
            } catch {
                continue
            }
        }
        throw URLError(.badServerResponse)
    }

    private static func sessionLookbackDays(for period: String) -> Int {
        switch period {
        case "1h", "6h", "today": return 1
        case "week": return 7
        case "month": return 30
        case "all": return 3650
        default: return 7
        }
    }

    private static func periodStart(for period: String, now: Date = Date()) -> Date? {
        switch period {
        case "1h": return now.addingTimeInterval(-3600)
        case "6h": return now.addingTimeInterval(-(6 * 3600))
        case "today": return Calendar.current.startOfDay(for: now)
        case "week": return now.addingTimeInterval(-(7 * 24 * 3600))
        case "month": return now.addingTimeInterval(-(30 * 24 * 3600))
        case "all": return nil
        default: return nil
        }
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func mtimeEpoch(from isoString: String?) -> Double? {
        parseISODate(isoString)?.timeIntervalSince1970 * 1000
    }

    private static func sessionDate(for session: DashboardSession) -> Date? {
        parseISODate(session.updatedAt) ?? parseISODate(session.startedAt)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func makeDisplayCostData(from sessions: [DashboardSession], period: String, preferences: CostDisplayPreferences) -> CostData {
        let cutoff = periodStart(for: period)
        let filteredSessions = sessions.filter { session in
            guard let cutoff else { return true }
            guard let date = sessionDate(for: session) else { return false }
            return date >= cutoff
        }

        var totalCost = 0.0
        var byAgent: [String: Double] = [:]
        var byModel: [String: Double] = [:]
        var byDay: [String: Double] = [:]
        var inputTokens = 0
        var outputTokens = 0
        var cachedTokens = 0

        for session in filteredSessions {
            let adjustedCost = displayedCost(session.totalCost, model: session.model, source: session.source, preferences: preferences) ?? 0
            totalCost += adjustedCost

            if adjustedCost > 0 {
                let agentName = session.agentName ?? session.agentId ?? "Unknown"
                byAgent[agentName, default: 0] += adjustedCost

                let modelName = session.model ?? "Unknown"
                byModel[modelName, default: 0] += adjustedCost

                if let date = sessionDate(for: session) {
                    byDay[dayKey(for: date), default: 0] += adjustedCost
                }
            }

            inputTokens += session.tokensUsed?.input ?? 0
            outputTokens += session.tokensUsed?.output ?? 0
            cachedTokens += session.tokensUsed?.cached ?? 0
        }

        return CostData(
            totalCost: totalCost,
            byAgent: byAgent.isEmpty ? nil : byAgent.map { CostData.AgentCost(agentName: $0.key, cost: $0.value) }.sorted { $0.cost > $1.cost },
            byModel: byModel.isEmpty ? nil : byModel.map { CostData.ModelCost(model: $0.key, cost: $0.value) }.sorted { $0.cost > $1.cost },
            byDay: byDay.isEmpty ? nil : byDay.map { CostData.DayCost(date: $0.key, cost: $0.value) }.sorted { $0.date < $1.date },
            sessionsCount: filteredSessions.count,
            tokensUsed: CostData.DashboardTokenUsage(
                input: inputTokens > 0 ? inputTokens : nil,
                output: outputTokens > 0 ? outputTokens : nil,
                cached: cachedTokens > 0 ? cachedTokens : nil
            )
        )
    }

    private struct ThreadListResponse: Codable {
        let assistantThread: ThreadInfo?
        let threads: [ThreadInfo]
        let activeThread: String?

        enum CodingKeys: String, CodingKey {
            case assistantThread = "assistant_thread"
            case threads
            case activeThread = "active_thread"
        }
    }

    private struct ThreadInfo: Codable {
        let id: String
        let state: String
        let turnCount: Int
        let createdAt: String
        let updatedAt: String
        let title: String?
        let threadType: String?
        let channel: String?

        enum CodingKeys: String, CodingKey {
            case id, state, title, channel
            case turnCount = "turn_count"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case threadType = "thread_type"
        }
    }

    private struct HistoryResponse: Codable {
        let threadId: String
        let turns: [ThreadTurn]

        enum CodingKeys: String, CodingKey {
            case threadId = "thread_id"
            case turns
        }
    }

    private struct ThreadTurn: Codable {
        let userInput: String
        let response: String?
        let state: String
        let startedAt: String
        let completedAt: String?

        enum CodingKeys: String, CodingKey {
            case state, response
            case userInput = "user_input"
            case startedAt = "started_at"
            case completedAt = "completed_at"
        }
    }

    private struct MemoryListResponse: Codable {
        let path: String
        let entries: [MemoryListEntry]
    }

    private struct MemoryListEntry: Codable {
        let name: String
        let path: String
        let isDir: Bool
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case name, path
            case isDir = "is_dir"
            case updatedAt = "updated_at"
        }
    }

    private struct MemoryReadResponse: Codable {
        let path: String
        let content: String
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case path, content
            case updatedAt = "updated_at"
        }
    }

    private struct RoutinesResponse: Codable {
        let routines: [RoutineInfo]
    }

    private struct RoutineInfo: Codable {
        let id: String
        let name: String
        let enabled: Bool?
        let status: String?
        let schedule: String?
        let lastRunAt: String?
        let nextRunAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, enabled, status, schedule
            case lastRunAt = "last_run_at"
            case nextRunAt = "next_run_at"
        }
    }

    private struct GatewayStatusSummary: Codable {
        let uptime: Double?
        let version: String?
        let agents: Int?
        let sessions: Int?
        let connectedDevices: Int?

        enum CodingKeys: String, CodingKey {
            case uptime, version, agents, sessions
            case connectedDevices = "connected_devices"
        }
    }
}

private extension SessionMessage {
    init(
        id: String,
        role: String,
        content: String,
        timestamp: String?,
        cost: Double?,
        model: String?,
        toolCalls: [SessionToolCall]?,
        toolResults: [SessionToolResult]?
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.cost = cost
        self.model = model
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

private func displayedCost(
    _ rawCost: Double?,
    model: String?,
    source: String?,
    preferences: CostDisplayPreferences
) -> Double? {
    guard let rawCost else { return nil }
    guard preferences.mode == .effectiveBilled else { return rawCost }
    guard !preferences.shouldZeroOut(model: model, source: source) else { return 0 }
    return rawCost
}

private extension CostDisplayPreferences {
    func shouldZeroOut(model: String?, source: String?) -> Bool {
        let normalizedModel = model?.lowercased() ?? ""
        let normalizedSource = source?.lowercased() ?? ""

        if openAISubscription {
            let openAIIndicators = ["gpt", "o1", "o3", "o4", "openai"]
            if openAIIndicators.contains(where: { normalizedModel.contains($0) || normalizedSource.contains($0) }) {
                return true
            }
        }

        if anthropicSubscription {
            let anthropicIndicators = ["claude", "anthropic"]
            if anthropicIndicators.contains(where: { normalizedModel.contains($0) || normalizedSource.contains($0) }) {
                return true
            }
        }

        return false
    }
}
