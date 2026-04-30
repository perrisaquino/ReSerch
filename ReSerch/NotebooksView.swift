import SwiftUI

/// Notebooks tab — top-level list of user-created notebooks plus an Unfiled bucket.
/// Reuses the existing card aesthetic (rounded corners, soft white-opacity fills).
struct NotebooksView: View {
    var vm: TranscriptViewModel
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.notebooks.isEmpty && vm.unfiledTranscripts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("Notebooks")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateNotebookSheet(vm: vm)
            }
            .navigationDestination(for: Notebook.self) { notebook in
                NotebookDetailView(notebook: notebook, vm: vm)
            }
            .navigationDestination(for: UnfiledDestination.self) { _ in
                UnfiledView(vm: vm)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(vm.notebooks) { notebook in
                    NavigationLink(value: notebook) {
                        notebookRow(notebook)
                    }
                    .buttonStyle(.plain)
                }

                // Unfiled is always present at the bottom so users can find loose transcripts.
                NavigationLink(value: UnfiledDestination()) {
                    unfiledRow
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private func notebookRow(_ notebook: Notebook) -> some View {
        let count = vm.transcripts(in: notebook).count
        return HStack(spacing: 14) {
            Capsule()
                .fill(notebook.color)
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(notebook.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(count == 1 ? "1 transcript" : "\(count) transcripts")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var unfiledRow: some View {
        let count = vm.unfiledTranscripts.count
        return HStack(spacing: 14) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfiled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(count == 1 ? "1 transcript" : "\(count) transcripts")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 84, height: 84)
                    .blur(radius: 16)
                Image(systemName: "books.vertical")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("Create your first notebook")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("Group transcripts by topic. Move them in from the Feed.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                showCreate = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Notebook").fontWeight(.semibold)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Marker type used by `NavigationStack`'s `.navigationDestination(for:)` so
/// the Unfiled destination is type-distinct from `Notebook`.
struct UnfiledDestination: Hashable {}
