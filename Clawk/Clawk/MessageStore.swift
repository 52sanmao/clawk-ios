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
            if self.logs.count > 50 {
                self.logs.removeFirst()
            }
        }
    }
    
    override init() {
        super.init()
        log("Relay channel uses \(Config.baseURL) and is optional for push notifications/action cards")
        connect()
        pairDevice()
    }
    
    func pairDevice() {
        let url = Config.apiURL.appendingPathComponent("/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "deviceToken": Config.deviceToken,
            "deviceName": UIDevice.current.name
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
    
    func connect() {
        DispatchQueue.main.async {
            self.isConnecting = true
        }
        log("Connecting to \(Config.websocketURL)...")
        
        var request = URLRequest(url: Config.websocketURL)
        request.timeoutInterval = 5
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        webSocketTask?.resume()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        reconnectTimer?.invalidate()
    }
    
    private func reconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connect()
        }
        // Start polling as fallback
        startPolling()
    }
    
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollMessages()
        }
        pollTimer?.fire()
    }
    
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    private func pollMessages() {
        let url = Config.apiURL.appendingPathComponent("/poll")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil else { return }
            
            if let messages = try? JSONDecoder().decode([ClawkMessage].self, from: data) {
                DispatchQueue.main.async {
                    for message in messages {
                        // Only add if we haven't seen this message before
                        if !(self?.receivedMessageIds.contains(message.id) ?? false) {
                            self?.receivedMessageIds.insert(message.id)
                            self?.messages.insert(message, at: 0)
                        }
                    }
                }
            }
        }.resume()
    }
    
    private func receive() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                default:
                    break
                }
                self?.receive() // Keep listening
                
            case .failure(let error):
                print("WebSocket error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.dashboardConnected = false
                }
                self?.reconnect()
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        // First try to parse as dashboard update
        guard let textData = text.data(using: .utf8) else { return }
        if let dashboardUpdate = try? JSONDecoder().decode(DashboardUpdate.self, from: textData) {
            handleDashboardUpdate(dashboardUpdate)
            return
        }
        
        // Otherwise treat as regular ClawkMessage
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ClawkMessage.self, from: data) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            // Only add if we haven't seen this message before
            guard let self = self, !self.receivedMessageIds.contains(message.id) else { return }
            self.receivedMessageIds.insert(message.id)
            self.messages.insert(message, at: 0)
        }
    }
    
    private func handleDashboardUpdate(_ update: DashboardUpdate) {
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
                }
                
            case "sessions":
                // Update sessions in existing snapshot
                if var snapshot = self?.dashboardSnapshot {
                    snapshot.sessions = update.data.sessions
                    snapshot.lastUpdated = ISO8601DateFormatter().string(from: Date())
                    self?.dashboardSnapshot = snapshot
                }
                
            case "openclaw_status":
                self?.openclawStatus = OpenClawStatus(
                    cronJobs: update.data.cronJobs,
                    heartbeats: update.data.heartbeats,
                    summary: update.data.summary,
                    generatedAt: update.data.generatedAt
                )
                
            case "tasks":
                if let tasks = update.data.tasks {
                    self?.tasks = tasks
                }
                self?.taskStats = update.data.stats
                
            case "agent_status":
                // Handle individual agent status updates
                self?.log("Agent status update received")
                
            case "costs":
                // Handle cost updates
                if var snapshot = self?.dashboardSnapshot {
                    snapshot.totalCost = update.data.totalCost
                    self?.dashboardSnapshot = snapshot
                }
                
            default:
                break
            }
        }
    }
    
    func respond(to message: ClawkMessage, with action: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let index = self.messages.firstIndex(where: { $0.id == message.id }) else { return }
            
            // Idempotent: ignore if already responded
            guard !self.messages[index].responded else {
                print("Message already responded to, ignoring")
                return
            }
            
            self.messages[index].responded = true
            self.messages[index].response = action
            
            let response: [String: Any] = [
                "messageId": message.id,
                "action": action,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                if let text = String(data: data, encoding: .utf8) {
                    self.webSocketTask?.send(.string(text)) { _ in }
                }
            }
        }
    }
    
    func manualRefresh() {
        log("Manual refresh triggered")
        pollMessages()
    }
    
    func clearLogs() {
        logs.removeAll()
    }
    
    // MARK: - Session Messages
    
    func fetchSessionMessages(sessionId: String, completion: @escaping ([SessionMessage]) -> Void) {
        let url = Config.apiURL.appendingPathComponent("/dashboard/sessions/\(sessionId)/messages")
        var request = URLRequest(url: url)
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion([])
                return
            }
            
            do {
                let messages = try JSONDecoder().decode([SessionMessage].self, from: data)
                DispatchQueue.main.async {
                    completion(messages)
                }
            } catch {
                print("Failed to decode session messages: \(error)")
                completion([])
            }
        }.resume()
    }
    
    // MARK: - Agent Actions
    
    func pingAgent(agentId: String, completion: @escaping (Bool) -> Void) {
        // Send a ping message to the agent via the backend
        let url = Config.apiURL.appendingPathComponent("/message")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.deviceToken, forHTTPHeaderField: "x-device-token")
        
        let body: [String: Any] = [
            "message": "Ping from clawk-iOS: @\(agentId) check in please",
            "type": "ping",
            "actions": []
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                completion(error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
            }
        }.resume()
    }
}

// MARK: - WebSocket Delegate

extension MessageStore: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.isConnecting = false
        }
        log("✅ WebSocket connected")
        stopPolling() // WebSocket works, no need to poll
        receive()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        log("❌ WebSocket disconnected: \(error?.localizedDescription ?? "Unknown error")")
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.dashboardConnected = false
        }
        reconnect()
    }
}
