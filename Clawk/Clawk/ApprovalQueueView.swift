import SwiftUI

// MARK: - Approval Queue View

struct ApprovalQueueView: View {
    @ObservedObject var gateway: GatewayConnection
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            if gateway.pendingApprovals.isEmpty && !isRefreshing {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("暂无待审批项")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(gateway.pendingApprovals) { approval in
                            ApprovalCard(approval: approval, gateway: gateway)
                        }
                    }
                    .padding()
                }
            }
        }
        .refreshable {
            await refreshApprovals()
        }
        .onAppear {
            Task { await refreshApprovals() }
        }
    }

    private func refreshApprovals() async {
        isRefreshing = true
        do {
            let _ = try await gateway.approvalsGet()
        } catch {
            print("Failed to fetch approvals: \(error)")
        }
        isRefreshing = false
    }
}

// MARK: - Approval Card

struct ApprovalCard: View {
    let approval: GatewayApproval
    @ObservedObject var gateway: GatewayConnection
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.tool ?? approval.command ?? "需要操作")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let requestedAt = approval.requestedAt {
                        Text(requestedAt)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let status = approval.status {
                    StatusDot(status: status)
                }
            }

            // Context
            if let context = approval.context {
                Text(context)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            // Command/Tool details
            if let command = approval.command {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(6)
            }

            // Arguments
            if let args = approval.arguments, !args.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(args.keys.sorted()), id: \.self) { key in
                        HStack(alignment: .top, spacing: 4) {
                            Text(key + ":")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(args[key] ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(6)
            }

            // Action buttons
            if approval.status == "pending" {
                HStack(spacing: 12) {
                    Button(action: { resolve(decision: "approve") }) {
                        HStack {
                            if isResolving {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Image(systemName: "checkmark")
                            Text("批准")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(isResolving)

                    Button(action: { resolve(decision: "deny") }) {
                        HStack {
                            Image(systemName: "xmark")
                            Text("拒绝")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(isResolving)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func resolve(decision: String) {
        isResolving = true
        Task {
            do {
                try await gateway.approvalsResolve(id: approval.id, decision: decision)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(decision == "approve" ? .success : .warning)
            } catch {
                print("Failed to resolve approval: \(error)")
            }
            await MainActor.run { isResolving = false }
        }
    }
}
