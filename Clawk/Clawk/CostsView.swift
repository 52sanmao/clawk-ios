import SwiftUI

// MARK: - Costs View

struct CostsView: View {
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @AppStorage(CostDisplayPreferences.modeKey) private var costDisplayModeRaw = CostDisplayMode.apiEquivalent.rawValue
    @AppStorage(CostDisplayPreferences.openAISubscriptionKey) private var openAISubscription = false
    @AppStorage(CostDisplayPreferences.anthropicSubscriptionKey) private var anthropicSubscription = false
    @State private var costData: DashboardAPIClient.CostData?
    @State private var selectedPeriod: CostPeriod = .week
    @State private var isLoading = true

    enum CostPeriod: String, CaseIterable {
        case hour = "1h"
        case sixHours = "6h"
        case today = "today"
        case week = "week"
        case month = "month"
        case all = "all"

        var label: String {
            switch self {
            case .hour: return "1小时"
            case .sixHours: return "6小时"
            case .today: return "今天"
            case .week: return "本周"
            case .month: return "本月"
            case .all: return "全部"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Period selector
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CostPeriod.allCases, id: \.self) { period in
                            Button(action: { selectPeriod(period) }) {
                                Text(period.label)
                                    .font(.caption)
                                    .fontWeight(selectedPeriod == period ? .bold : .regular)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedPeriod == period ? Color.blue : Color(.tertiarySystemBackground))
                                    .foregroundColor(selectedPeriod == period ? .white : .primary)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let data = costData {
                    if costPreferences.appliesSubscriptionCoverage {
                        CostModeNotice()
                    }

                    // Total cost card
                    TotalCostCard(
                        title: costPreferences.appliesSubscriptionCoverage ? "实际账单费用" : "API等效费用",
                        cost: data.totalCost ?? 0,
                        sessions: data.sessionsCount ?? 0,
                        tokens: data.tokensUsed
                    )

                    // Cost by agent
                    if let byAgent = data.byAgent, !byAgent.isEmpty {
                        CostBreakdownSection(title: "按代理", items: byAgent.map {
                            CostBreakdownItem(name: $0.agentName, cost: $0.cost)
                        })
                    }

                    // Cost by model
                    if let byModel = data.byModel, !byModel.isEmpty {
                        CostBreakdownSection(title: "按模型", items: byModel.map {
                            CostBreakdownItem(name: $0.model, cost: $0.cost)
                        })
                    }

                    // Daily breakdown bar chart
                    if let byDay = data.byDay, !byDay.isEmpty {
                        DailyCostChart(data: byDay)
                    }

                    // Token usage
                    if let tokens = data.tokensUsed {
                        TokenUsageCard(tokens: tokens)
                    }
                } else {
                    EmptyStateView(icon: "dollarsign.circle", message: "暂无费用数据")
                }
            }
            .padding()
        }
        .refreshable {
            await loadCosts()
        }
        .onAppear {
            Task { await loadCosts() }
        }
        .onChange(of: costDisplayModeRaw) {
            Task { await loadCosts() }
        }
        .onChange(of: openAISubscription) {
            Task { await loadCosts() }
        }
        .onChange(of: anthropicSubscription) {
            Task { await loadCosts() }
        }
    }

    private func selectPeriod(_ period: CostPeriod) {
        selectedPeriod = period
        Task { await loadCosts() }
    }

    private func loadCosts() async {
        isLoading = costData == nil
        do {
            let data = try await dashboardAPI.fetchDisplayCosts(
                period: selectedPeriod.rawValue,
                preferences: costPreferences
            )
            await MainActor.run {
                costData = data
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private var costPreferences: CostDisplayPreferences {
        CostDisplayPreferences(
            mode: CostDisplayMode(rawValue: costDisplayModeRaw) ?? .apiEquivalent,
            openAISubscription: openAISubscription,
            anthropicSubscription: anthropicSubscription
        )
    }
}

// MARK: - Total Cost Card

struct TotalCostCard: View {
    let title: String
    let cost: Double
    let sessions: Int
    let tokens: DashboardAPIClient.CostData.DashboardTokenUsage?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("$\(String(format: "%.4f", cost))")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption)
                    Text("\(sessions) 个会话")
                        .font(.caption)
                }
                .foregroundColor(.secondary)

                if let tokens = tokens, let total = tokenTotal(tokens) {
                    HStack(spacing: 4) {
                        Image(systemName: "cylinder.split.1x2")
                            .font(.caption)
                        Text(formatTokens(total))
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private func tokenTotal(_ t: DashboardAPIClient.CostData.DashboardTokenUsage) -> Int? {
        let input = t.input ?? 0
        let output = t.output ?? 0
        return input + output > 0 ? input + output : nil
    }
}

struct CostModeNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
            Text("订阅调整已启用。以下费用反映的是基于模型名称推断的本地账单费用覆盖，而非原始API等效定价。")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .cornerRadius(12)
    }
}

// MARK: - Cost Breakdown

struct CostBreakdownItem {
    let name: String
    let cost: Double
}

struct CostBreakdownSection: View {
    let title: String
    let items: [CostBreakdownItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            ForEach(items.sorted(by: { $0.cost > $1.cost }), id: \.name) { item in
                CostBreakdownRow(item: item, maxCost: items.map(\.cost).max() ?? 1)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct CostBreakdownRow: View {
    let item: CostBreakdownItem
    let maxCost: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("$\(String(format: "%.2f", item.cost))")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            // Bar
            GeometryReader { geometry in
                let fraction = maxCost > 0 ? item.cost / maxCost : 0
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue.opacity(0.6))
                    .frame(width: geometry.size.width * CGFloat(fraction), height: 4)
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Daily Cost Chart

struct DailyCostChart: View {
    let data: [DashboardAPIClient.CostData.DayCost]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日费用")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(data.suffix(14), id: \.id) { day in
                    VStack(spacing: 4) {
                        // Bar
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue)
                            .frame(width: barWidth, height: barHeight(for: day.cost))

                        // Label
                        Text(dayLabel(day.date))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var barWidth: CGFloat { 16 }

    private var maxCost: Double {
        data.map(\.cost).max() ?? 1
    }

    private func barHeight(for cost: Double) -> CGFloat {
        let fraction = maxCost > 0 ? cost / maxCost : 0
        return max(2, CGFloat(fraction) * 80)
    }

    private func dayLabel(_ date: String) -> String {
        let components = date.split(separator: "-")
        if components.count >= 3 {
            return "\(components[1])/\(components[2])"
        }
        return String(date.suffix(5))
    }
}

// MARK: - Token Usage Card

struct TokenUsageCard: View {
    let tokens: DashboardAPIClient.CostData.DashboardTokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("令牌使用量")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                TokenStat(label: "输入", value: tokens.input ?? 0, color: .blue)
                TokenStat(label: "输出", value: tokens.output ?? 0, color: .green)
                TokenStat(label: "缓存", value: tokens.cached ?? 0, color: .orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct TokenStat: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(formatTokens(value))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
