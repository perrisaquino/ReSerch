import SwiftUI

/// Detail view for a single notebook: shows all transcripts assigned to it.
/// Reuses `TranscriptRow` from ContentView for visual consistency with the Feed.
struct NotebookDetailView: View {
    let notebook: Notebook
    var vm: TranscriptViewModel

    @State private var selectedEntry: TranscriptEntry? = nil
    @State private var showRename = false
    @State private var showColorPicker = false
    @State private var showDeleteConfirm = false
    @State private var renameText: String = ""

    private var entries: [TranscriptEntry] {
        vm.transcripts(in: notebook)
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Color stripe + count header
                        header
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        ForEach(entries) { entry in
                            TranscriptRow(
                                entry: entry,
                                isSelected: false,
                                selectionMode: false,
                                onTap: { selectedEntry = entry },
                                onCopy: { copyMarkdown(for: entry) },
                                onDelete: { vm.deleteEntry(entry) },
                                onRename: { vm.renameEntry(entry, to: $0) }
                            )
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
        .navigationTitle(notebook.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = notebook.name
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
                        exportAll()
                    } label: {
                        Label("Copy Combined Markdown", systemImage: "doc.on.doc")
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
        .alert("Rename notebook", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                vm.renameNotebook(notebook, to: renameText)
            }
        }
        .sheet(isPresented: $showColorPicker) {
            NotebookColorPickerSheet(notebook: notebook, vm: vm)
                .presentationDetents([.height(220)])
        }
        .confirmationDialog(
            "Delete \"\(notebook.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                vm.deleteNotebook(notebook)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transcripts in this notebook will move back to Unfiled. They won't be deleted.")
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(notebook.color)
                .frame(height: 2)
                .clipShape(Capsule())
            HStack {
                Text(entries.count == 1 ? "1 transcript" : "\(entries.count) transcripts")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("No transcripts in \(notebook.name) yet")
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

    // MARK: - Actions

    private func copyMarkdown(for entry: TranscriptEntry) {
        let md = vm.markdownFor(entry)
        UIPasteboard.general.string = md
    }

    private func exportAll() {
        let combined = vm.combinedMarkdown(for: notebook)
        UIPasteboard.general.string = combined
    }
}

/// Lightweight color picker sheet used from NotebookDetailView's "..." menu.
private struct NotebookColorPickerSheet: View {
    let notebook: Notebook
    var vm: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("Notebook Color")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 16)

            HStack(spacing: 14) {
                ForEach(Notebook.presetColors, id: \.self) { hex in
                    Button {
                        vm.recolorNotebook(notebook, to: hex)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        notebook.colorHex == hex ? Color.white : Color.clear,
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
                                onTap: { selectedEntry = entry },
                                onCopy: { copyMarkdown(for: entry) },
                                onDelete: { vm.deleteEntry(entry) },
                                onRename: { vm.renameEntry(entry, to: $0) }
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
        .preferredColorScheme(.dark)
    }

    private func copyMarkdown(for entry: TranscriptEntry) {
        let md = vm.markdownFor(entry)
        UIPasteboard.general.string = md
    }
}
