import SwiftUI
import Combine

// MARK: - Agent Logs View

struct AgentLogsView: View {
    @ObservedObject var gateway: GatewayConnection
    @State private var logEntries: [GatewayLogEntry] = []
    @State private var filterLevel: LogLevel = .all
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var cancellable: AnyCancellable?

    enum LogLevel: String, CaseIterable {
        case all = "全部"
        case info = "info"
        case warn = "warn"
        case error = "error"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            LogFilterBar(filterLevel: $filterLevel, searchText: $searchText, autoScroll: $autoScroll)

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: logEntries.count) {
                    if autoScroll, let last = filteredLogs.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Bottom bar
            HStack {
                Text("\(filteredLogs.count) 条记录")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { logEntries.removeAll() }) {
                    Text("清除")
                        .font(.caption)
                }
                Button(action: { refreshLogs() }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
        }
        .onAppear {
            subscribeToLogs()
            refreshLogs()
        }
        .onDisappear {
            cancellable?.cancel()
        }
    }

    private var filteredLogs: [GatewayLogEntry] {
        logEntries.filter { entry in
            let matchesLevel = filterLevel == .all || entry.level == filterLevel.rawValue
            let matchesSearch = searchText.isEmpty ||
                entry.message.localizedCaseInsensitiveContains(searchText) ||
                (entry.source?.localizedCaseInsensitiveContains(searchText) ?? false)
            return matchesLevel && matchesSearch
        }
    }

    private func subscribeToLogs() {
        cancellable = gateway.logSubject
            .receive(on: DispatchQueue.main)
            .sink { entry in
                logEntries.append(entry)
                // Cap at 500 entries
                if logEntries.count > 500 {
                    logEntries.removeFirst(logEntries.count - 500)
                }
            }
    }

    private func refreshLogs() {
        gateway.logsTail(sinceMs: 300000)
    }
}

// MARK: - Log Filter Bar

struct LogFilterBar: View {
    @Binding var filterLevel: AgentLogsView.LogLevel
    @Binding var searchText: String
    @Binding var autoScroll: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Level filter
                Picker("等级", selection: $filterLevel) {
                    ForEach(AgentLogsView.LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                // Auto-scroll toggle
                Button(action: { autoScroll.toggle() }) {
                    Image(systemName: autoScroll ? "arrow.down.to.line.compact" : "pause")
                        .font(.caption)
                        .padding(6)
                        .background(autoScroll ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                        .cornerRadius(6)
                }
            }

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("搜索日志...", text: $searchText)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: GatewayLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Level indicator
            Text(levelIcon)
                .font(.system(size: 10))

            // Timestamp
            Text(formatTimestamp(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            // Source
            if let source = entry.source {
                Text(source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(1)
            }

            // Message
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(levelColor)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var levelIcon: String {
        switch entry.level {
        case "error": return "🔴"
        case "warn": return "🟡"
        case "info": return "🔵"
        case "debug": return "⚪"
        default: return "⚪"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case "error": return .red
        case "warn": return .orange
        default: return .primary
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
