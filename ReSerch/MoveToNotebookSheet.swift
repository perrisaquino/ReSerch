import SwiftUI

/// Modal triggered from the multi-select bulkBar to move selected transcripts
/// into a notebook. Shows existing notebooks plus a "New Notebook" shortcut.
/// If any of the selected entries already live in a notebook, also surfaces
/// a "Remove from Notebook" action that moves them back to Unfiled.
struct MoveToNotebookSheet: View {
    var vm: TranscriptViewModel
    let selectedIDs: Set<UUID>
    var onMoved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var pendingMessage: String? = nil

    private var selectedEntries: [TranscriptEntry] {
        vm.history.filter { selectedIDs.contains($0.id) }
    }

    /// True if any selected transcript currently belongs to a notebook.
    /// Drives the "Remove from Notebook" affordance.
    private var anyAssigned: Bool {
        selectedEntries.contains { $0.notebookID != nil }
    }

    /// The single notebook every selected entry currently lives in, or nil if
    /// the selection is mixed (across notebooks or some unfiled). Used to mark
    /// the current row with a checkmark and to show the "Currently in" header.
    private var commonCurrentNotebook: Notebook? {
        let ids = Set(selectedEntries.compactMap { $0.notebookID })
        guard ids.count == 1, let id = ids.first else { return nil }
        return vm.notebooks.first(where: { $0.id == id })
    }

    private var countLabel: String {
        let n = selectedIDs.count
        return n == 1 ? "1 transcript" : "\(n) transcripts"
    }

    /// Most-recently-touched notebook first (touched on transcript assign/remove).
    /// Stable tiebreakers so notebooks with identical timestamps don't shuffle.
    private var sortedNotebooks: [Notebook] {
        vm.notebooks.sorted { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let current = commonCurrentNotebook {
                        currentlyInHeader(current)
                    }

                    newNotebookRow

                    if !vm.notebooks.isEmpty {
                        ForEach(sortedNotebooks) { notebook in
                            Button {
                                move(to: notebook)
                            } label: {
                                notebookRow(notebook)
                            }
                            .buttonStyle(.plain)
                            .disabled(notebook.id == commonCurrentNotebook?.id)
                        }
                    }

                    if anyAssigned {
                        Button {
                            move(to: nil)
                        } label: {
                            removeRow
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("Move \(countLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateNotebookSheet(vm: vm) { newNotebook in
                    move(to: newNotebook)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Rows

    private var newNotebookRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            Text("New Notebook")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture { showCreate = true }
    }

    private func notebookRow(_ notebook: Notebook) -> some View {
        let count = vm.transcripts(in: notebook).count
        let isCurrent = (notebook.id == commonCurrentNotebook?.id)
        return HStack(spacing: 14) {
            Capsule()
                .fill(notebook.color)
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(notebook.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(count == 1 ? "1 transcript" : "\(count) transcripts")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(notebook.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isCurrent ? notebook.color.opacity(0.10) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isCurrent ? notebook.color.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    /// Banner above the list showing which notebook the selection currently lives
    /// in. Tinted with the notebook's color so the visual identity matches the
    /// transcript-detail toolbar icon tint.
    private func currentlyInHeader(_ notebook: Notebook) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notebook.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Currently in")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                Text(notebook.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(notebook.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(notebook.color.opacity(0.30), lineWidth: 1)
        )
    }

    private var removeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24)
            Text("Remove from Notebook")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func move(to notebook: Notebook?) {
        vm.assignNotebook(selectedEntries, to: notebook)
        onMoved?()
        dismiss()
    }
}
