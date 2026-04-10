import SwiftUI

struct DebugView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logger = DebugLogger.shared
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if logger.entries.isEmpty {
                    ContentUnavailableView(
                        "No logs yet",
                        systemImage: "ladybug",
                        description: Text("Run a transcript fetch and come back here")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(logger.entries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.level.emoji)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(entry.step)
                                                .font(.system(.caption, design: .monospaced))
                                                .fontWeight(.semibold)
                                                .foregroundStyle(stepColor(entry.step))
                                            Text(DateFormatter.logTime.string(from: entry.timestamp))
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(entry.message)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(levelColor(entry.level))
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                if entry.id != logger.entries.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        logger.clear()
                    }
                    .disabled(logger.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = logger.fullLog
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied!" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(logger.entries.isEmpty)
                }
            }
        }
    }

    private func levelColor(_ level: DebugLogger.Entry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    private func stepColor(_ step: String) -> Color {
        switch step {
        case "YouTube": return .red
        case "Extract": return .pink
        case "Download": return .blue
        case "Whisper": return .purple
        case "Platform": return .teal
        case "Error": return .red
        default: return .secondary
        }
    }
}
