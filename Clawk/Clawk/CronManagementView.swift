import SwiftUI
import Combine

// MARK: - Cron Management View (Protocol v3)

struct CronManagementView: View {
    @ObservedObject var gateway: GatewayConnection
    @State private var selectedJob: GatewayCronJob?
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status summary
                CronStatusHeader(gateway: gateway)

                // Cron jobs
                if !regularJobs.isEmpty {
                    SectionHeader(title: "定时任务", count: regularJobs.count)
                    ForEach(regularJobs) { job in
                        CronJobCard(job: job, gateway: gateway)
                            .onTapGesture { selectedJob = job }
                    }
                }

                // Heartbeats
                if !heartbeatJobs.isEmpty {
                    SectionHeader(title: "心跳", count: heartbeatJobs.count)
                    ForEach(heartbeatJobs) { job in
                        CronJobCard(job: job, gateway: gateway)
                            .onTapGesture { selectedJob = job }
                    }
                }

                if gateway.cronJobs.isEmpty && !isRefreshing {
                    if !gateway.isConnected {
                        EmptyStateView(icon: "wifi.slash", message: "网关离线 — 请连接以加载定时任务")
                    } else {
                        EmptyStateView(icon: "clock.arrow.2.circlepath", message: "未找到定时任务")
                    }
                }
            }
            .padding()
        }
        .refreshable {
            if !gateway.isConnected && !gateway.isConnecting {
                gateway.connect()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await refreshCronJobs()
        }
        .sheet(item: $selectedJob) { job in
            CronJobDetailView(job: job, gateway: gateway)
        }
        .onAppear {
            Task { await refreshCronJobs() }
        }
        .onChange(of: gateway.isConnected) { _, connected in
            if connected {
                Task { await refreshCronJobs() }
            }
        }
    }

    private var regularJobs: [GatewayCronJob] {
        gateway.cronJobs.filter { !$0.isHeartbeat }
    }

    private var heartbeatJobs: [GatewayCronJob] {
        gateway.cronJobs.filter { $0.isHeartbeat }
    }

    private func refreshCronJobs() async {
        isRefreshing = true
        do {
            let jobs = try await gateway.cronList()
            await MainActor.run { gateway.cronJobs = jobs }
            let _ = try await gateway.cronGetStatus()
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
        isRefreshing = false
    }
}

// MARK: - Cron Status Header

struct CronStatusHeader: View {
    @ObservedObject var gateway: GatewayConnection

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(
                title: "总任务数",
                value: "\(gateway.cronJobs.count)",
                icon: "clock.badge.checkmark",
                color: .blue
            )
            StatCard(
                title: "已启用",
                value: "\(gateway.cronJobs.filter { $0.enabled ?? false }.count)",
                icon: "checkmark.circle.fill",
                color: .green
            )
            StatCard(
                title: "心跳",
                value: "\(gateway.cronJobs.filter { $0.isHeartbeat }.count)",
                icon: "heart.fill",
                color: .pink
            )
            if let status = gateway.cronStatus {
                StatCard(
                    title: "下次唤醒",
                    value: status.nextWakeAtMs.map { formatRelativeTime($0) } ?? "—",
                    icon: "alarm",
                    color: .orange
                )
            } else {
                StatCard(
                    title: "状态",
                    value: gateway.isConnected ? "OK" : "—",
                    icon: "antenna.radiowaves.left.and.right",
                    color: gateway.isConnected ? .green : .gray
                )
            }
        }
    }
}

// MARK: - Cron Job Card

struct CronJobCard: View {
    let job: GatewayCronJob
    @ObservedObject var gateway: GatewayConnection
    @State private var isToggling = false
    @State private var isRunning = false
    @State private var runResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: job.isHeartbeat ? "heart.fill" : "clock.arrow.circlepath")
                    .foregroundColor(job.isHeartbeat ? .pink : .blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(job.scheduleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let agentId = job.agentId {
                        Text(agentId)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    // Toggle
                    Toggle("", isOn: Binding(
                        get: { job.enabled ?? false },
                        set: { newValue in toggleJob(enabled: newValue) }
                    ))
                    .labelsHidden()
                    .disabled(isToggling)

                    // Run Now button
                    Button(action: { runJob() }) {
                        HStack(spacing: 4) {
                            if isRunning {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                            }
                            Text("运行")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .disabled(isRunning)
                }
            }

            // Last run info
            HStack(spacing: 12) {
                if let lastStatus = job.lastRunStatus {
                    CronRunStatusBadge(status: lastStatus)
                }
                if let lastRunMs = job.lastRunAtMs {
                    Text(formatRelativeTime(lastRunMs))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let durationMs = job.lastRunDurationMs {
                    Text("\(Int(durationMs))ms")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let result = runResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }

            // Next run
            if let nextRunMs = job.nextRunAtMs {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text("下次: \(formatRelativeTime(nextRunMs))")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func toggleJob(enabled: Bool) {
        isToggling = true
        Task {
            do {
                try await gateway.cronUpdate(id: job.id, enabled: enabled)
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            } catch {
                print("Failed to toggle cron job: \(error)")
            }
            await MainActor.run { isToggling = false }
        }
    }

    private func runJob() {
        isRunning = true
        runResult = nil
        Task {
            do {
                let result = try await gateway.cronRun(id: job.id, mode: "force")
                await MainActor.run {
                    runResult = result.ran == true ? "运行成功" : (result.reason ?? "已跳过")
                    isRunning = false
                }
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(result.ran == true ? .success : .warning)
            } catch {
                await MainActor.run {
                    runResult = "错误"
                    isRunning = false
                }
            }
            // Clear result after delay
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { runResult = nil }
        }
    }
}

// MARK: - Cron Job Detail View

struct CronJobDetailView: View {
    let job: GatewayCronJob
    @ObservedObject var gateway: GatewayConnection
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [GatewayCronRun] = []
    @State private var isLoadingRuns = true
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationView {
            List {
                Section("详情") {
                    DetailRow(label: "名称", value: job.displayName)
                    DetailRow(label: "ID", value: job.id)
                    DetailRow(label: "计划", value: job.scheduleDescription)
                    if let agentId = job.agentId {
                        DetailRow(label: "代理", value: agentId)
                    }
                    if let target = job.sessionTarget {
                        DetailRow(label: "会话目标", value: target)
                    }
                    if let wakeMode = job.wakeMode {
                        DetailRow(label: "唤醒模式", value: wakeMode)
                    }
                    DetailRow(label: "已启用", value: (job.enabled ?? false) ? "是" : "否")
                    DetailRow(label: "类型", value: job.isHeartbeat ? "心跳" : "定时任务")
                    if job.deleteAfterRun == true {
                        DetailRow(label: "一次性", value: "运行后删除")
                    }
                }

                Section("时间") {
                    if let lastRunMs = job.lastRunAtMs {
                        DetailRow(label: "上次运行", value: formatAbsoluteTime(lastRunMs))
                    }
                    if let nextRunMs = job.nextRunAtMs {
                        DetailRow(label: "下次运行", value: formatAbsoluteTime(nextRunMs))
                    }
                    if let durationMs = job.lastRunDurationMs {
                        DetailRow(label: "上次耗时", value: "\(Int(durationMs))ms")
                    }
                    if let status = job.lastRunStatus {
                        HStack {
                            Text("上次状态")
                            Spacer()
                            CronRunStatusBadge(status: status)
                        }
                    }
                }

                Section("运行历史") {
                    if isLoadingRuns {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if runs.isEmpty {
                        Text("暂无运行记录")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(runs, id: \.stableId) { run in
                            CronRunRow(run: run)
                        }
                    }
                }

                Section {
                    Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                        Label("删除任务", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(job.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { loadRuns() }
            .alert("删除 \(job.displayName)？", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { deleteJob() }
            } message: {
                Text("此操作无法撤销。")
            }
        }
    }

    private func loadRuns() {
        Task {
            do {
                let fetchedRuns = try await gateway.cronRunsRead(jobId: job.id, limit: 20)
                await MainActor.run {
                    runs = fetchedRuns
                    isLoadingRuns = false
                }
            } catch {
                await MainActor.run { isLoadingRuns = false }
            }
        }
    }

    private func deleteJob() {
        Task {
            do {
                try await gateway.cronRemove(id: job.id)
                await MainActor.run { dismiss() }
            } catch {
                print("Failed to delete cron job: \(error)")
            }
        }
    }
}

// MARK: - Cron Run Row

struct CronRunRow: View {
    let run: GatewayCronRun

    var body: some View {
        HStack(spacing: 12) {
            CronRunStatusBadge(status: run.status ?? "unknown")

            VStack(alignment: .leading, spacing: 2) {
                if let startedAt = run.startedAt {
                    Text(startedAt)
                        .font(.caption)
                }
                if let durationMs = run.durationMs {
                    Text("\(Int(durationMs))ms")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let error = run.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Cron Run Status Badge

struct CronRunStatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .cornerRadius(4)
    }

    private var color: Color {
        switch status {
        case "ok", "success", "completed": return .green
        case "error", "failed": return .red
        case "running": return .blue
        case "skipped": return .orange
        default: return .gray
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Text("\(count)")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            Spacer()
        }
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
    }
}

// MARK: - Helpers

func formatRelativeTime(_ ms: Double) -> String {
    let date = Date(timeIntervalSince1970: ms / 1000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func formatAbsoluteTime(_ ms: Double) -> String {
    let date = Date(timeIntervalSince1970: ms / 1000)
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
