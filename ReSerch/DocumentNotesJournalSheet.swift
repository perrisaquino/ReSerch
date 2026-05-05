import SwiftUI

/// Mini-journal view for a transcript's collection of `DocumentNote`s. Pushed onto
/// the parent's NavigationStack via `.navigationDestination(isPresented:)`, so it
/// slides in from the right just like a standard list-detail navigation. Lists every
/// note attached to the entry, sorted with the pinned note (if any) first and the
/// rest newest-first by `updatedAt`. Tap a row to inline-expand the editor; swipe
/// for pin/unpin and delete.
///
/// "Auto-discard empty" rule: notes added via the `+` toolbar button that are never
/// edited (text stays empty) are removed when the view dismisses, so the journal
/// doesn't accumulate orphan timestamped blanks.
struct DocumentNotesJournalSheet: View {
    @Binding var entry: TranscriptEntry
    var vm: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss

    /// IDs of notes that started empty when added in this sheet session. Used by the
    /// auto-discard sweep on dismiss — notes the user typed into get promoted out
    /// of this set and survive even if they're later trimmed back to empty.
    @State private var addedEmptyIDs: Set<UUID> = []
    /// Currently-expanded note id. Tap a row to toggle. Nil = list-only state.
    @State private var expandedID: UUID?
    /// Pending delete confirmation target. Non-empty notes ask before removal.
    @State private var pendingDelete: DocumentNote?

    /// App-wide canonical background defined in `ReSerchApp.swift` as
    /// `Color(red: 0.07, green: 0.09, blue: 0.13)`. The sheet sits one elevation
    /// step above that to read as "lifted" from the page beneath without
    /// fighting the rest of the dark-navy aesthetic.
    private static let sheetBackground = Color(red: 0.10, green: 0.12, blue: 0.16)

    var body: some View {
        ZStack {
            Self.sheetBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarBackground(Self.sheetBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("Delete this note?", isPresented: deleteConfirmationBinding) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let note = pendingDelete {
                    vm.removeDocumentNote(entry, noteID: note.id)
                    addedEmptyIDs.remove(note.id)
                    if expandedID == note.id { expandedID = nil }
                    // Pull the latest version of the entry back so the local @Binding
                    // sees the deletion.
                    if let updated = vm.history.first(where: { $0.id == entry.id }) {
                        entry = updated
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("This note has content. Deleting it can't be undone.")
        }
        .onDisappear { pruneEmptyAdded() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if entry.documentNotes.isEmpty {
            emptyState
        } else {
            List {
                ForEach(sortedNotes) { note in
                    noteRow(note)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                requestDelete(note)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                if note.isPinned {
                                    vm.unpinDocumentNote(entry, noteID: note.id)
                                } else {
                                    vm.pinDocumentNote(entry, noteID: note.id)
                                }
                                refreshLocalEntry()
                            } label: {
                                Label(
                                    note.isPinned ? "Unpin" : "Pin",
                                    systemImage: note.isPinned ? "pin.slash" : "pin"
                                )
                            }
                            .tint(.yellow)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.30))
            VStack(spacing: 6) {
                Text("Mini journal")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Capture reflections and ideas about this transcript over time. Tap + to start.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    // MARK: - Row

    @ViewBuilder
    private func noteRow(_ note: DocumentNote) -> some View {
        let expanded = expandedID == note.id
        VStack(alignment: .leading, spacing: 8) {
            // Body first — leads the row with content the way Apple Notes does. The
            // timestamp is metadata, not the headline.
            if expanded {
                editorBody(for: note)
            } else {
                Text(note.text.isEmpty ? "Empty note" : note.text)
                    .font(.system(size: 15))
                    .foregroundStyle(note.text.isEmpty ? .white.opacity(0.35) : .white.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.yellow.opacity(0.85))
                    Text("Pinned")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.yellow.opacity(0.75))
                        .textCase(.uppercase)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(timestampLabel(for: note))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    note.isPinned ? Color.yellow.opacity(0.22) : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedID = expanded ? nil : note.id
            }
        }
    }

    @ViewBuilder
    private func editorBody(for note: DocumentNote) -> some View {
        let binding = Binding<String>(
            get: {
                entry.documentNotes.first(where: { $0.id == note.id })?.text ?? ""
            },
            set: { newValue in
                vm.updateDocumentNote(entry, noteID: note.id, text: newValue)
                refreshLocalEntry()
                // First keystroke promotes the note out of the auto-discard set so
                // it survives even if the user deletes back to empty later.
                if !newValue.isEmpty { addedEmptyIDs.remove(note.id) }
            }
        )
        TextEditor(text: binding)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 110, maxHeight: 240)
            .padding(.horizontal, -4)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.92))
            .tint(Color.accentColor)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // No leading "Done" button — the navigation back chevron handles dismissal
        // now that this view is pushed via .navigationDestination instead of a sheet.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                addNewNote()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Add note")
        }
    }

    // MARK: - Actions

    private func addNewNote() {
        guard let newID = vm.addDocumentNote(entry, text: "") else { return }
        addedEmptyIDs.insert(newID)
        refreshLocalEntry()
        // Open the new note immediately for typing.
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = newID
        }
    }

    private func requestDelete(_ note: DocumentNote) {
        let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty notes delete silently — same idea as auto-discard, just user-initiated.
            vm.removeDocumentNote(entry, noteID: note.id)
            addedEmptyIDs.remove(note.id)
            if expandedID == note.id { expandedID = nil }
            refreshLocalEntry()
        } else {
            pendingDelete = note
        }
    }

    /// Sweep run on dismiss: any note added via + this session that's still empty
    /// disappears. Notes the user typed into and then deleted back to empty are
    /// preserved (they're no longer in `addedEmptyIDs`) — those are real intentional
    /// blanks the user can swipe-delete on their next visit.
    private func pruneEmptyAdded() {
        for id in addedEmptyIDs {
            if let note = entry.documentNotes.first(where: { $0.id == id }),
               note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vm.removeDocumentNote(entry, noteID: id)
            }
        }
        addedEmptyIDs.removeAll()
    }

    private func refreshLocalEntry() {
        if let updated = vm.history.first(where: { $0.id == entry.id }) {
            entry = updated
        }
    }

    // MARK: - Sorting + formatting

    private var sortedNotes: [DocumentNote] {
        let pinned = entry.documentNotes.filter { $0.isPinned }
        let unpinned = entry.documentNotes.filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
        return pinned + unpinned
    }

    private func timestampLabel(for note: DocumentNote) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        // For notes from today, the relative formatter is friendly ("3 min ago").
        // For older notes it'll fall back to e.g. "2 wk", which is fine. We use
        // `updatedAt` so editing a note resurfaces it as recent.
        return formatter.localizedString(for: note.updatedAt, relativeTo: Date())
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}
