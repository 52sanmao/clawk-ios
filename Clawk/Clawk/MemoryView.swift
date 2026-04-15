import SwiftUI

// MARK: - Memory View

struct MemoryView: View {
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @State private var files: [DashboardAPIClient.MemoryFile] = []
    @State private var isLoading = true
    @State private var selectedFile: DashboardAPIClient.MemoryFile?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading memory files...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                EmptyStateView(icon: "brain.head.profile", message: "No memory files found")
            } else {
                List(files) { file in
                    MemoryFileRow(file: file)
                        .onTapGesture { selectedFile = file }
                }
                .listStyle(.plain)
            }
        }
        .refreshable {
            await loadFiles()
        }
        .sheet(item: $selectedFile) { file in
            MemoryFileDetailView(file: file, dashboardAPI: dashboardAPI)
        }
        .onAppear {
            Task { await loadFiles() }
        }
        .overlay {
            if let error = errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.cornerRadius(8))
                        .padding()
                }
            }
        }
    }

    private func loadFiles() async {
        isLoading = files.isEmpty
        do {
            let fetched = try await dashboardAPI.fetchMemoryFiles()
            await MainActor.run {
                files = fetched
                isLoading = false
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Memory File Row

struct MemoryFileRow: View {
    let file: DashboardAPIClient.MemoryFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconForFile(file.path))
                .foregroundColor(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(file.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let size = file.size {
                Text(formatBytes(size))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var fileName: String {
        (file.path as NSString).lastPathComponent
    }

    private func iconForFile(_ path: String) -> String {
        if path.hasSuffix(".md") { return "doc.text" }
        if path.hasSuffix(".json") { return "curlybraces" }
        if path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return "list.bullet.indent" }
        return "doc"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
        return "\(bytes) B"
    }
}

// MARK: - Memory File Detail View

struct MemoryFileDetailView: View {
    let file: DashboardAPIClient.MemoryFile
    @ObservedObject var dashboardAPI: DashboardAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var originalContent = ""
    @State private var mtime: Double?
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveSuccess = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEditing {
                    TextEditor(text: $content)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(8)
                } else {
                    ScrollView {
                        Text(content)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                }

                // Footer
                HStack {
                    if let mtime = mtime {
                        Text("修改时间：\(formatMtime(mtime))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if hasChanges {
                        Text("有未保存更改")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if saveSuccess {
                        Text("已保存")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if isEditing && hasChanges {
                            Button(action: { saveFile() }) {
                                if isSaving {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Text("保存")
                                        .fontWeight(.medium)
                                }
                            }
                            .disabled(isSaving)
                        }
                        Button(isEditing ? "查看" : "编辑") {
                            isEditing.toggle()
                        }
                    }
                }
            }
            .onAppear { loadContent() }
        }
    }

    private var fileName: String {
        (file.path as NSString).lastPathComponent
    }

    private var hasChanges: Bool {
        content != originalContent
    }

    private func formatMtime(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadContent() {
        Task {
            do {
                let result = try await dashboardAPI.readMemoryFile(path: file.path)
                await MainActor.run {
                    content = result.content
                    originalContent = result.content
                    mtime = result.mtime
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func saveFile() {
        isSaving = true
        saveSuccess = false
        Task {
            do {
                let result = try await dashboardAPI.updateMemoryFile(
                    path: file.path,
                    content: content,
                    expectedMtime: mtime
                )
                await MainActor.run {
                    mtime = result.mtime
                    originalContent = content
                    isSaving = false
                    saveSuccess = true
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                }
                // Clear success indicator
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { saveSuccess = false }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
