import Foundation

// MARK: - IronClaw compatibility models

/// Error types from the IronClaw compatibility layer
enum GatewayError: Error, LocalizedError {
    case notConnected
    case notLinked
    case notPaired
    case agentTimeout
    case tokenMissing
    case originNotAllowed
    case invalidRequest(String)
    case unavailable(retryAfterMs: Int?)
    case serverError(code: String, message: String)
    case decodingError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "未连接到 IronClaw"
        case .notLinked: return "客户端未认证"
        case .notPaired: return "需要设备配对"
        case .agentTimeout: return "代理执行超时"
        case .tokenMissing: return "缺少 IronClaw Bearer Token 或令牌无效"
        case .originNotAllowed: return "当前 IronClaw 地址无效，请检查服务地址与路径前缀是否正确"
        case .invalidRequest(let msg): return "无效请求: \(msg)"
        case .unavailable(let retry): return "IronClaw 不可用\(retry.map { "，\($0)ms后重试" } ?? "")"
        case .serverError(_, let msg): return msg
        case .decodingError(let msg): return "解码错误: \(msg)"
        case .timeout: return "请求超时"
        }
    }

    static func from(code: String, message: String) -> GatewayError {
        let lowercasedMessage = message.lowercased()
        switch code {
        case "NOT_LINKED":
            return .notLinked
        case "NOT_PAIRED":
            return .notPaired
        case "AGENT_TIMEOUT":
            return .agentTimeout
        case "INVALID_REQUEST":
            if lowercasedMessage.contains("token missing") || lowercasedMessage.contains("token invalid") || lowercasedMessage.contains("unauthorized") {
                return .tokenMissing
            }
            if lowercasedMessage.contains("origin not allowed") || lowercasedMessage.contains("origin missing or invalid") {
                return .originNotAllowed
            }
            return .invalidRequest(message)
        case "UNAVAILABLE":
            return .unavailable(retryAfterMs: nil)
        default:
            return .serverError(code: code, message: message)
        }
    }
}

// MARK: - Gateway Event Types

enum GatewayEventType: String {
    case tick
    case agent
    case chat                           // Gateway sends "chat" events with state: delta/final/error
    case chatFinal = "chat:final"       // Legacy — kept for backward compat
    case lifecycleStart = "lifecycle:start"
    case lifecycleEnd = "lifecycle:end"
    case cronAdded = "cron:added"
    case cronUpdated = "cron:updated"
    case cronStarted = "cron:started"
    case cronFinished = "cron:finished"
    case cronRemoved = "cron:removed"
    case approvalRequested = "exec.approval.requested"
    case presence
    case shutdown
    case unknown

    init(rawValue: String) {
        switch rawValue {
        case "tick": self = .tick
        case "agent": self = .agent
        case "chat": self = .chat
        case "chat:final": self = .chatFinal
        case "lifecycle:start": self = .lifecycleStart
        case "lifecycle:end": self = .lifecycleEnd
        case "cron:added": self = .cronAdded
        case "cron:updated": self = .cronUpdated
        case "cron:started": self = .cronStarted
        case "cron:finished": self = .cronFinished
        case "cron:removed": self = .cronRemoved
        case "exec.approval.requested": self = .approvalRequested
        case "presence": self = .presence
        case "shutdown": self = .shutdown
        default: self = .unknown
        }
    }
}

// MARK: - Gateway Response Models

struct GatewayConnectResponse: Codable {
    let `protocol`: Int?
    let policy: GatewayPolicy?
    let auth: GatewayAuth?
}

struct GatewayPolicy: Codable {
    let tickIntervalMs: Int?
}

struct GatewayAuth: Codable {
    let deviceToken: String?
}

struct GatewayAgent: Identifiable {
    let id: String
    let name: String?
    let emoji: String?
    let color: String?
    let model: String?
    let status: String?
    let skills: [GatewayAgentSkill]?

    struct GatewayAgentSkill: Identifiable {
        let id: String?
        let name: String
        let icon: String?
        let category: String?

        var stableId: String { id ?? name }

        static func from(_ dict: [String: Any]) -> GatewayAgentSkill? {
            guard let name = dict["name"] as? String else { return nil }
            return GatewayAgentSkill(
                id: dict["id"] as? String,
                name: name,
                icon: dict["icon"] as? String,
                category: dict["category"] as? String
            )
        }
    }

    static func from(_ dict: [String: Any]) -> GatewayAgent? {
        guard let id = dict["id"] as? String else { return nil }
        let skillDicts = dict["skills"] as? [[String: Any]]
        return GatewayAgent(
            id: id,
            name: dict["name"] as? String,
            emoji: dict["emoji"] as? String,
            color: dict["color"] as? String,
            model: dict["model"] as? String,
            status: dict["status"] as? String,
            skills: skillDicts?.compactMap { GatewayAgentSkill.from($0) }
        )
    }
}

struct GatewaySession: Identifiable {
    let id: String
    let agentId: String?
    let agentName: String?
    let model: String?
    let messageCount: Int?
    let totalCost: Double?
    let tokensUsed: GatewayTokenUsage?
    let updatedAt: String?
    let startedAt: String?
    let projectPath: String?
    let status: String?
    let sessionKey: String?

    static func from(_ dict: [String: Any]) -> GatewaySession? {
        guard let id = dict["id"] as? String else { return nil }
        let tokensDict = dict["tokensUsed"] as? [String: Any]
        return GatewaySession(
            id: id,
            agentId: dict["agentId"] as? String,
            agentName: dict["agentName"] as? String,
            model: dict["model"] as? String,
            messageCount: dict["messageCount"] as? Int,
            totalCost: dict["totalCost"] as? Double,
            tokensUsed: tokensDict.flatMap { GatewayTokenUsage.from($0) },
            updatedAt: dict["updatedAt"] as? String,
            startedAt: dict["startedAt"] as? String,
            projectPath: dict["projectPath"] as? String,
            status: dict["status"] as? String,
            sessionKey: dict["sessionKey"] as? String
        )
    }
}

struct GatewayTokenUsage {
    let input: Int?
    let output: Int?
    let cached: Int?

    static func from(_ dict: [String: Any]) -> GatewayTokenUsage {
        GatewayTokenUsage(
            input: dict["input"] as? Int,
            output: dict["output"] as? Int,
            cached: dict["cached"] as? Int
        )
    }
}

struct GatewayCronJob: Identifiable {
    let id: String
    let name: String?
    let agentId: String?
    let enabled: Bool?
    let schedule: GatewayCronSchedule?
    let sessionTarget: String?
    let wakeMode: String?
    let deleteAfterRun: Bool?
    let sessionKey: String?
    let createdAtMs: Double?
    let updatedAtMs: Double?
    // State (flattened from nested state object)
    let lastRunAtMs: Double?
    let nextRunAtMs: Double?
    let lastRunStatus: String?
    let lastRunDurationMs: Double?
    let consecutiveErrors: Int?

    var displayName: String { name ?? id }
    var isHeartbeat: Bool { name?.lowercased().contains("heartbeat") ?? false }

    var scheduleDescription: String {
        if let sched = schedule {
            if let expr = sched.expr { return expr }
            if let cron = sched.cron { return cron }
            if let every = sched.every { return "每 \(every)" }
            if let at = sched.at { return "在 \(at)" }
        }
        return "未知"
    }

    /// Parse from a raw dictionary (avoids JSONSerialization round-trip crashes)
    static func from(_ dict: [String: Any]) -> GatewayCronJob? {
        guard let id = dict["id"] as? String else { return nil }
        let schedDict = dict["schedule"] as? [String: Any]
        let stateDict = dict["state"] as? [String: Any]
        return GatewayCronJob(
            id: id,
            name: dict["name"] as? String,
            agentId: dict["agentId"] as? String,
            enabled: dict["enabled"] as? Bool,
            schedule: schedDict.flatMap { GatewayCronSchedule.from($0) },
            sessionTarget: dict["sessionTarget"] as? String,
            wakeMode: dict["wakeMode"] as? String,
            deleteAfterRun: dict["deleteAfterRun"] as? Bool,
            sessionKey: dict["sessionKey"] as? String,
            createdAtMs: dict["createdAtMs"] as? Double,
            updatedAtMs: dict["updatedAtMs"] as? Double,
            lastRunAtMs: stateDict?["lastRunAtMs"] as? Double ?? dict["lastRunAtMs"] as? Double,
            nextRunAtMs: stateDict?["nextRunAtMs"] as? Double ?? dict["nextRunAtMs"] as? Double,
            lastRunStatus: stateDict?["lastRunStatus"] as? String ?? dict["lastRunStatus"] as? String,
            lastRunDurationMs: stateDict?["lastRunDurationMs"] as? Double ?? dict["lastRunDurationMs"] as? Double,
            consecutiveErrors: stateDict?["consecutiveErrors"] as? Int
        )
    }
}

struct GatewayCronSchedule {
    let kind: String?   // "cron", "interval", "once"
    let expr: String?   // cron expression or interval string
    let cron: String?   // legacy field
    let every: String?  // legacy field
    let at: String?     // legacy field
    let tz: String?

    static func from(_ dict: [String: Any]) -> GatewayCronSchedule {
        GatewayCronSchedule(
            kind: dict["kind"] as? String,
            expr: dict["expr"] as? String,
            cron: dict["cron"] as? String,
            every: dict["every"] as? String,
            at: dict["at"] as? String,
            tz: dict["tz"] as? String
        )
    }
}

struct GatewayCronStatus {
    let enabled: Bool?
    let jobs: Int?
    let nextWakeAtMs: Double?
    let storePath: String?

    static func from(_ dict: [String: Any]) -> GatewayCronStatus {
        GatewayCronStatus(
            enabled: dict["enabled"] as? Bool,
            jobs: dict["jobs"] as? Int,
            nextWakeAtMs: dict["nextWakeAtMs"] as? Double,
            storePath: dict["storePath"] as? String
        )
    }
}

struct GatewayCronRunResult {
    let ok: Bool?
    let ran: Bool?
    let reason: String?
}

struct GatewayCronRun: Identifiable {
    let id: String?
    let jobId: String?
    let status: String?
    let startedAt: String?
    let finishedAt: String?
    let durationMs: Double?
    let error: String?

    var stableId: String { id ?? UUID().uuidString }

    static func from(_ dict: [String: Any]) -> GatewayCronRun {
        GatewayCronRun(
            id: dict["id"] as? String,
            jobId: dict["jobId"] as? String,
            status: dict["status"] as? String,
            startedAt: dict["startedAt"] as? String,
            finishedAt: dict["finishedAt"] as? String,
            durationMs: dict["durationMs"] as? Double,
            error: dict["error"] as? String
        )
    }
}

struct GatewayApproval: Identifiable {
    let id: String
    let command: String?
    let tool: String?
    let arguments: [String: String]?
    let context: String?
    let requestedAt: String?
    let status: String?

    static func from(_ dict: [String: Any]) -> GatewayApproval? {
        guard let id = dict["id"] as? String else { return nil }
        // Convert arguments dict to [String: String]
        let argsDict = dict["arguments"] as? [String: Any]
        let stringArgs = argsDict?.compactMapValues { $0 as? String }
        return GatewayApproval(
            id: id,
            command: dict["command"] as? String,
            tool: dict["tool"] as? String,
            arguments: stringArgs,
            context: dict["context"] as? String,
            requestedAt: dict["requestedAt"] as? String,
            status: dict["status"] as? String
        )
    }
}

struct GatewayLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: String
    let message: String
    let source: String?
}

struct GatewayStatusResponse {
    let uptime: Double?
    let version: String?
    let agents: Int?
    let sessions: Int?
    let connectedDevices: Int?

    static func from(_ dict: [String: Any]) -> GatewayStatusResponse {
        GatewayStatusResponse(
            uptime: dict["uptime"] as? Double,
            version: dict["version"] as? String,
            agents: dict["agents"] as? Int,
            sessions: dict["sessions"] as? Int,
            connectedDevices: dict["connectedDevices"] as? Int
        )
    }
}

struct GatewayHealthResponse {
    let status: String?
    let uptime: Double?
    let memory: GatewayMemoryInfo?

    static func from(_ dict: [String: Any]) -> GatewayHealthResponse {
        let memDict = dict["memory"] as? [String: Any]
        return GatewayHealthResponse(
            status: dict["status"] as? String,
            uptime: dict["uptime"] as? Double,
            memory: memDict.flatMap { GatewayMemoryInfo.from($0) }
        )
    }
}

struct GatewayMemoryInfo {
    let rss: Int?
    let heapUsed: Int?
    let heapTotal: Int?

    static func from(_ dict: [String: Any]) -> GatewayMemoryInfo {
        GatewayMemoryInfo(
            rss: dict["rss"] as? Int,
            heapUsed: dict["heapUsed"] as? Int,
            heapTotal: dict["heapTotal"] as? Int
        )
    }
}

// MARK: - Chat Models (used by Protocol v3 events)

struct GatewayChatMessage: Identifiable, Codable {
    let id: String
    let role: String
    let content: String
    let timestamp: Date
    var thinking: String?
    var toolCalls: [GatewayToolCall]?
    var isStreaming: Bool

    init(id: String = UUID().uuidString, role: String, content: String, timestamp: Date = Date(), thinking: String? = nil, toolCalls: [GatewayToolCall]? = nil, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
    }
}

struct GatewayToolCall: Identifiable, Codable {
    let id: String
    let name: String
    let argumentsJSON: Data?
    let timestamp: Date

    var arguments: [String: Any] {
        guard let data = argumentsJSON,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    init(id: String, name: String, arguments: [String: Any] = [:], timestamp: Date = Date()) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.argumentsJSON = try? JSONSerialization.data(withJSONObject: arguments)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, argumentsJSON, timestamp
    }
}

struct GatewayThinkingStep: Identifiable, Codable {
    let id: String
    let content: String
    let timestamp: Date
    let type: StepType
    var toolName: String?
    var status: String?
    var durationMs: Int?

    enum StepType: String, Codable {
        case thinking
        case toolCall
        case toolResult
    }

    var displayText: String {
        switch type {
        case .thinking: return content
        case .toolCall: return toolName.map { "正在使用 \($0)..." } ?? content
        case .toolResult: return toolName.map { "\($0) 已完成" } ?? content
        }
    }
}

struct GatewayAgentIdentity: Codable {
    let name: String
    let creature: String
    let vibe: String?
    let emoji: String
    let color: String

    init(name: String = "助手", creature: String = "AI", vibe: String? = nil, emoji: String = "🤖", color: String = "#6B7280") {
        self.name = name
        self.creature = creature
        self.vibe = vibe
        self.emoji = emoji
        self.color = color
    }
}

// MARK: - RPC Infrastructure

/// Pending request tracker for async/await bridging
final class PendingRequest {
    let id: String
    let method: String
    let createdAt: Date
    private var continuation: CheckedContinuation<[String: Any], Error>?

    init(id: String, method: String, continuation: CheckedContinuation<[String: Any], Error>) {
        self.id = id
        self.method = method
        self.createdAt = Date()
        self.continuation = continuation
    }

    func resume(with payload: [String: Any]) {
        continuation?.resume(returning: payload)
        continuation = nil
    }

    func fail(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: GatewayError.timeout)
        continuation = nil
    }
}
