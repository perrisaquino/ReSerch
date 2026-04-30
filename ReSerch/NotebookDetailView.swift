import SwiftUI

/// Detail view for a single notebook: shows all transcripts assigned to it.
/// Reuses `TranscriptRow` from ContentView for visual consistency with the Feed.
struct NotebookDetailView: View {
    /// Stored as ID, not the Notebook value, so renames/recolors propagate via vm
    /// without leaving this view holding a stale snapshot.
    private let notebookID: UUID
    var vm: TranscriptViewModel

    @State private var selectedEntry: TranscriptEntry? = nil
    @State private var showRename = false
    @State private var showColorPicker = false
    @State private var showDeleteConfirm = false
    @State private var showDescriptionEditor = false
    @State private var renameText: String = ""
    @State private var singleMoveEntry: TranscriptEntry? = nil

    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBulkMoveSheet = false
    @State private var showBulkDeleteConfirm = false

    init(notebook: Notebook, vm: TranscriptViewModel) {
        self.notebookID = notebook.id
        self.vm = vm
    }

    /// Always reads the latest notebook state from the VM. Returns nil if the notebook
    /// was just deleted; the body falls back to a blank background and the parent
    /// NavigationStack pops on the next render.
    private var liveNotebook: Notebook? {
        vm.notebook(for: notebookID)
    }

    var body: some View {
        Group {
            if let nb = liveNotebook {
                content(notebook: nb)
            } else {
                Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(notebook nb: Notebook) -> some View {
        let entries = vm.transcripts(in: nb)

        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()

            if entries.isEmpty {
                emptyState(for: nb)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header(for: nb, entryCount: entries.count)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        ForEach(entries) { entry in
                            TranscriptRow(
                                entry: entry,
                                isSelected: selectedIDs.contains(entry.id),
                                selectionMode: selectionMode,
                                notebook: nb,
                                onTap: {
                                    if selectionMode {
                                        if selectedIDs.contains(entry.id) {
                                            selectedIDs.remove(entry.id)
                                        } else {
                                            selectedIDs.insert(entry.id)
                                        }
                                    } else {
                                        selectedEntry = entry
                                    }
                                },
                                onCopy: { copyMarkdown(for: entry) },
                                onDelete: { vm.deleteEntry(entry) },
                                onRename: { vm.renameEntry(entry, to: $0) },
                                onMoveToNotebook: { singleMoveEntry = entry }
                            )
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode && !selectedIDs.isEmpty {
                bulkBar(notebook: nb)
            }
        }
        .navigationTitle(nb.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(selectionMode ? "Cancel" : "Select") {
                    selectionMode.toggle()
                    selectedIDs.removeAll()
                }
                .foregroundStyle(selectionMode ? Color.accentColor : .secondary)
                .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = nb.name
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        showColorPicker = true
                    } label: {
                        Label("Change Color", systemImage: "paintpalette")
                    }
                    Button {
                        showDescriptionEditor = true
                    } label: {
                        Label(nb.notebookDescription == nil ? "Add Description" : "Edit Description",
                              systemImage: "text.alignleft")
                    }
                    Button {
                        exportAll(notebook: nb)
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .disabled(entries.isEmpty)
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Notebook", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .sheet(item: $selectedEntry) { entry in
            TranscriptDetailView(entry: entry, vm: vm)
        }
        .sheet(item: $singleMoveEntry) { entry in
            MoveToNotebookSheet(vm: vm, selectedIDs: [entry.id])
        }
        .sheet(isPresented: $showDescriptionEditor) {
            NotebookDescriptionEditor(
                initialText: nb.notebookDescription ?? "",
                onSave: { newText in
                    vm.setNotebookDescription(nb, to: newText)
                }
            )
        }
        .sheet(isPresented: $showBulkMoveSheet) {
            MoveToNotebookSheet(
                vm: vm,
                selectedIDs: selectedIDs,
                onMoved: {
                    selectionMode = false
                    selectedIDs.removeAll()
                }
            )
        }
        .confirmationDialog(
            selectedIDs.count == 1 ? "Delete 1 transcript?" : "Delete \(selectedIDs.count) transcripts?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let toDelete = entries.filter { selectedIDs.contains($0.id) }
                toDelete.forEach { vm.deleteEntry($0) }
                selectionMode = false
                selectedIDs.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename notebook", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                vm.renameNotebook(nb, to: renameText)
            }
        }
        .sheet(isPresented: $showColorPicker) {
            NotebookColorPickerSheet(notebookID: notebookID, vm: vm)
                .presentationDetents([.height(220)])
        }
        .confirmationDialog(
            "Delete \"\(nb.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                vm.deleteNotebook(nb)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transcripts in this notebook will move back to Unfiled. They won't be deleted.")
        }
    }

    private func header(for nb: Notebook, entryCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(nb.color)
                .frame(height: 2)
                .clipShape(Capsule())
            HStack {
                Text(entryCount == 1 ? "1 transcript" : "\(entryCount) transcripts")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            if let desc = nb.notebookDescription, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            }
        }
    }

    private func emptyState(for nb: Notebook) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("No transcripts in \(nb.name) yet")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("From the Feed, tap Select, choose transcripts, then Move to Notebook.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bulk bar (multi-select)

    private func bulkBar(notebook nb: Notebook) -> some View {
        let selectedEntries = vm.transcripts(in: nb).filter { selectedIDs.contains($0.id) }
        return HStack(spacing: 12) {
            Button {
                let md = selectedEntries.map { vm.markdownFor($0) }.joined(separator: "\n\n---\n\n")
                UIPasteboard.general.string = md
                selectionMode = false
                selectedIDs.removeAll()
            } label: {
                Label("Copy \(selectedIDs.count)", systemImage: "doc.on.doc")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }

            Button {
                showBulkMoveSheet = true
            } label: {
                Image(systemName: "folder")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }

            Button {
                showBulkDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func copyMarkdown(for entry: TranscriptEntry) {
        let md = vm.markdownFor(entry)
        UIPasteboard.general.string = md
    }

    private func exportAll(notebook nb: Notebook) {
        let combined = vm.combinedMarkdown(for: nb)
        UIPasteboard.general.string = combined
    }
}

// MARK: - Notebook Description Editor

private struct NotebookDescriptionEditor: View {
    let initialText: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .background(Color(red: 0.07, green: 0.09, blue: 0.13))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What's this notebook for?")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.horizontal, 22)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(red: 0.09, green: 0.11, blue: 0.15))
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("Notebook Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                text = initialText
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focused = true
                }
            }
        }
    }
}

/// Lightweight color picker sheet used from NotebookDetailView's "..." menu.
/// Stores notebook by ID so the selected-ring updates live as the user taps swatches.
private struct NotebookColorPickerSheet: View {
    let notebookID: UUID
    var vm: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss

    private var liveNotebook: Notebook? {
        vm.notebook(for: notebookID)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Notebook Color")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 16)

            HStack(spacing: 14) {
                ForEach(Notebook.presetColors, id: \.self) { hex in
                    Button {
                        if let nb = liveNotebook {
                            vm.recolorNotebook(nb, to: hex)
                        }
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        liveNotebook?.colorHex == hex ? Color.white : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// "Unfiled" destination — same layout as NotebookDetailView but for transcripts
/// without a notebook assignment.
struct UnfiledView: View {
    var vm: TranscriptViewModel
    @State private var selectedEntry: TranscriptEntry? = nil
    @State private var singleMoveEntry: TranscriptEntry? = nil

    private var entries: [TranscriptEntry] {
        vm.unfiledTranscripts
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()

            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Nothing unfiled")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            TranscriptRow(
                                entry: entry,
                                isSelected: false,
                                selectionMode: false,
                                notebook: nil,
                                onTap: { selectedEntry = entry },
                                onCopy: { copyMarkdown(for: entry) },
                                onDelete: { vm.deleteEntry(entry) },
                                onRename: { vm.renameEntry(entry, to: $0) },
                                onMoveToNotebook: { singleMoveEntry = entry }
                            )
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
        .navigationTitle("Unfiled")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            TranscriptDetailView(entry: entry, vm: vm)
        }
        .sheet(item: $singleMoveEntry) { entry in
            MoveToNotebookSheet(vm: vm, selectedIDs: [entry.id])
        }
        .preferredColorScheme(.dark)
    }

    private func copyMarkdown(for entry: TranscriptEntry) {
        let md = vm.markdownFor(entry)
        UIPasteboard.general.string = md
    }
}
