import Foundation
import Combine

// MARK: - Dashboard API Client
/// Direct HTTP client for kishos-dashboard (localhost:4004)

class DashboardAPIClient: ObservableObject {

    @Published var isReachable = false
    @Published var lastError: String?
    @Published var debugLog: [String] = []

    private let session = URLSession.shared
    private var baseURL: String

    init(baseURL: String? = nil) {
        let cachedURL = UserDefaults.standard.string(forKey: "dashboardBaseURL")
        if let cached = cachedURL, (cached.contains("127.0.0.1") || cached.contains("localhost")) {
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
        return "http://100.96.61.83:4004"
    }

    func updateBaseURL(_ url: String) {
        self.baseURL = url
        UserDefaults.standard.set(url, forKey: "dashboardBaseURL")
        log("Updated Dashboard base URL to \(url)")
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

    private func noteReachable() {
        Task { @MainActor in
            self.isReachable = true
            self.lastError = nil
        }
    }

    private func noteFailure(_ error: Error) {
        Task { @MainActor in
            self.isReachable = false
            self.lastError = error.localizedDescription
        }
    }

    private func requestURL(for path: String) throws -> URL {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        logRequest(request.httpMethod ?? "GET", url: request.url!, body: request.httpBody)
        do {
            let (data, response) = try await session.data(for: request)
            logResponse(response, data: data)
            try validateResponse(response)
            noteReachable()
            return data
        } catch {
            logFailure(request.httpMethod ?? "GET", url: request.url!, error: error)
            noteFailure(error)
            throw error
        }
    }

    private func executeGET(_ url: URL) async throws -> Data {
        logRequest("GET", url: url)
        do {
            let (data, response) = try await session.data(from: url)
            logResponse(response, data: data)
            try validateResponse(response)
            noteReachable()
            return data
        } catch {
            logFailure("GET", url: url, error: error)
            noteFailure(error)
            throw error
        }
    }

    // MARK: - Agents

    func fetchAgents() async throws -> [DashboardAgent] {
        let data = try await get("/api/agents")
        // Handle both { agents: [...] } and direct array
        if let wrapper = try? JSONDecoder().decode(AgentsWrapper.self, from: data) {
            return wrapper.agents
        }
        return (try? JSONDecoder().decode([DashboardAgent].self, from: data)) ?? []
    }

    private struct AgentsWrapper: Codable {
        let agents: [DashboardAgent]
    }

    // MARK: - Sessions

    func fetchSessions(days: Int = 7, limit: Int = 50, offset: Int = 0) async throws -> SessionsResponse {
        let data = try await get("/api/sessions?days=\(days)&limit=\(limit)&offset=\(offset)")
        return try JSONDecoder().decode(SessionsResponse.self, from: data)
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

    func fetchSessionMessages(sessionId: String, limit: Int = 200) async throws -> [SessionMessage] {
        let data = try await get("/api/sessions/\(sessionId)/messages?limit=\(limit)")
        // Handle both { messages: [...] } and direct array
        if let wrapper = try? JSONDecoder().decode(MessagesWrapper.self, from: data) {
            return wrapper.messages
        }
        return (try? JSONDecoder().decode([SessionMessage].self, from: data)) ?? []
    }

    private struct MessagesWrapper: Codable {
        let messages: [SessionMessage]
    }

    // MARK: - Costs

    func fetchCosts(period: String = "week") async throws -> CostData {
        let data = try await get("/api/costs?period=\(period)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        // Parse byAgent dict: { "name": cost }
        let byAgent: [CostData.AgentCost]? = (json["byAgent"] as? [String: Any])?.compactMap { key, value in
            guard let cost = value as? Double else { return nil }
            return CostData.AgentCost(agentName: key, cost: cost)
        }

        // Parse byModel dict: { "name": cost }
        let byModel: [CostData.ModelCost]? = (json["byModel"] as? [String: Any])?.compactMap { key, value in
            guard let cost = value as? Double else { return nil }
            return CostData.ModelCost(model: key, cost: cost)
        }

        // Parse byDay dict: { "date": cost }
        let byDay: [CostData.DayCost]? = (json["byDay"] as? [String: Any])?.compactMap { key, value -> CostData.DayCost? in
            guard let cost = value as? Double else { return nil }
            return CostData.DayCost(date: key, cost: cost)
        }.sorted(by: { $0.date < $1.date })

        // Parse totalTokens
        let tokensDict = json["totalTokens"] as? [String: Any]
        let tokens: CostData.DashboardTokenUsage? = tokensDict.map {
            CostData.DashboardTokenUsage(
                input: $0["input"] as? Int,
                output: $0["output"] as? Int,
                cached: ($0["cacheRead"] as? Int) ?? ($0["cached"] as? Int)
            )
        }

        return CostData(
            totalCost: json["totalCost"] as? Double,
            byAgent: byAgent,
            byModel: byModel,
            byDay: byDay,
            sessionsCount: json["sessionCount"] as? Int,
            tokensUsed: tokens
        )
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

    private static func sessionLookbackDays(for period: String) -> Int {
        switch period {
        case "1h", "6h", "today":
            return 1
        case "week":
            return 7
        case "month":
            return 30
        case "all":
            return 3650
        default:
            return 7
        }
    }

    private static func periodStart(for period: String, now: Date = Date()) -> Date? {
        switch period {
        case "1h":
            return now.addingTimeInterval(-3600)
        case "6h":
            return now.addingTimeInterval(-(6 * 3600))
        case "today":
            return Calendar.current.startOfDay(for: now)
        case "week":
            return now.addingTimeInterval(-(7 * 24 * 3600))
        case "month":
            return now.addingTimeInterval(-(30 * 24 * 3600))
        case "all":
            return nil
        default:
            return nil
        }
    }

    private static func sessionDate(for session: DashboardSession) -> Date? {
        parseISODate(session.updatedAt)
            ?? parseISODate(session.startedAt)
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
            let adjustedCost = displayedCost(
                session.totalCost,
                model: session.model,
                source: session.source,
                preferences: preferences
            ) ?? 0

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

        let agentCosts = byAgent
            .map { CostData.AgentCost(agentName: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        let modelCosts = byModel
            .map { CostData.ModelCost(model: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        let dayCosts = byDay
            .map { CostData.DayCost(date: $0.key, cost: $0.value) }
            .sorted { $0.date < $1.date }

        return CostData(
            totalCost: totalCost,
            byAgent: agentCosts.isEmpty ? nil : agentCosts,
            byModel: modelCosts.isEmpty ? nil : modelCosts,
            byDay: dayCosts.isEmpty ? nil : dayCosts,
            sessionsCount: filteredSessions.count,
            tokensUsed: CostData.DashboardTokenUsage(
                input: inputTokens > 0 ? inputTokens : nil,
                output: outputTokens > 0 ? outputTokens : nil,
                cached: cachedTokens > 0 ? cachedTokens : nil
            )
        )
    }

    // MARK: - Memory

    func fetchMemoryFiles() async throws -> [MemoryFile] {
        let data = try await get("/api/memory/list")
        let wrapper = try JSONDecoder().decode(MemoryFilesWrapper.self, from: data)
        return wrapper.files
    }

    struct MemoryFilesWrapper: Codable {
        let files: [MemoryFile]
    }

    struct MemoryFile: Codable, Identifiable {
        let path: String
        let name: String?
        let group: String?
        let groupLabel: String?
        let size: Int?
        let mtime: Double?  // epoch ms
        var id: String { path }

        var displayName: String { name ?? path.components(separatedBy: "/").last ?? path }
    }

    func readMemoryFile(path: String) async throws -> MemoryFileContent {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let data = try await get("/api/memory/file?path=\(encoded)")
        return try JSONDecoder().decode(MemoryFileContent.self, from: data)
    }

    struct MemoryFileContent: Codable {
        let content: String
        let mtime: Double?  // epoch ms
        let path: String
    }

    func updateMemoryFile(path: String, content: String, expectedMtime: Double? = nil) async throws -> MemoryFileUpdateResult {
        var body: [String: Any] = ["path": path, "content": content]
        if let mtime = expectedMtime { body["expectedMtime"] = mtime }
        let data = try await put("/api/memory/file", body: body)
        return try JSONDecoder().decode(MemoryFileUpdateResult.self, from: data)
    }

    struct MemoryFileUpdateResult: Codable {
        let ok: Bool?
        let path: String?
        let mtime: Double?  // epoch ms
    }

    // MARK: - Tasks

    func fetchTasks() async throws -> TasksResponse {
        let data = try await get("/api/tasks")
        return try JSONDecoder().decode(TasksResponse.self, from: data)
    }

    struct TasksResponse: Codable {
        let tasks: [DashboardTask]?
        let agents: [DashboardAgent]?
        let stats: TaskStats?
    }

    func updateTaskStatus(id: String, status: String) async throws {
        let _ = try await patch("/api/tasks", body: ["id": id, "status": status])
    }

    // MARK: - Summaries

    func fetchSummaries(days: Int = 30) async throws -> SummariesResponse {
        let data = try await get("/api/summary?days=\(days)")
        return try JSONDecoder().decode(SummariesResponse.self, from: data)
    }

    struct SummariesResponse: Codable {
        let summaries: [[String: String]]?
        let totalSessions: Int?
        let summarizedCount: Int?
        let pendingCount: Int?
    }

    // MARK: - OpenClaw Status

    func fetchOpenClawStatus() async throws -> OpenClawStatus {
        let data = try await get("/api/openclaw/status/stream?format=json")
        return try JSONDecoder().decode(OpenClawStatus.self, from: data)
    }

    // MARK: - Gateway Config (auto-discover)

    func fetchGatewayConfig() async throws -> GatewayConfig {
        let data = try await get("/api/gateway-config")
        return try JSONDecoder().decode(GatewayConfig.self, from: data)
    }

    struct GatewayConfig: Codable {
        let url: String?
        let token: String?
    }

    // MARK: - Chat

    func fetchChatSessions(days: Int = 7, limit: Int = 50) async throws -> ChatSessionsResponse {
        let data = try await get("/api/chat/sessions?days=\(days)&limit=\(limit)")
        return try JSONDecoder().decode(ChatSessionsResponse.self, from: data)
    }

    struct ChatSessionsResponse: Codable {
        let sessions: [[String: Any]]?

        enum CodingKeys: String, CodingKey {
            case sessions
        }

        init(from decoder: Decoder) throws {
            sessions = nil // Will use raw JSON for flexibility
        }

        func encode(to encoder: Encoder) throws {}
    }

    func fetchChatHistory(sessionId: String, limit: Int = 100) async throws -> [SessionMessage] {
        let data = try await get("/api/chat/history?sessionId=\(sessionId)&limit=\(limit)")
        let wrapper = try? JSONDecoder().decode(MessagesWrapper.self, from: data)
        return wrapper?.messages ?? []
    }

    // MARK: - Live Files

    func fetchLiveFiles() async throws -> LiveFilesResponse {
        let data = try await get("/api/live/files")
        return try JSONDecoder().decode(LiveFilesResponse.self, from: data)
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

    // MARK: - Health Check

    func checkHealth() async {
        do {
            let _ = try await get("/api/agents")
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

    // MARK: - HTTP Helpers

    private func get(_ path: String) async throws -> Data {
        let url = try requestURL(for: path)
        return try await executeGET(url)
    }

    private func put(_ path: String, body: [String: Any]) async throws -> Data {
        let url = try requestURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request)
    }

    private func patch(_ path: String, body: [String: Any]) async throws -> Data {
        let url = try requestURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode >= 400 {
            throw URLError(URLError.Code(rawValue: http.statusCode))
        }
    }
}
