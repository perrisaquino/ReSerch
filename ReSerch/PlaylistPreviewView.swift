import SwiftUI

/// Shown after the user pastes a TikTok playlist URL. Fetches the playlist, lets the
/// user pick which videos to transcribe (all selected by default), then hands the
/// selection off to the existing bulk queue on the view model.
struct PlaylistPreviewView: View {
    let playlistURL: URL
    @Bindable var vm: TranscriptViewModel
    var onEnqueue: () -> Void          // called once the batch is kicked off
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState = .loading
    @State private var selected: Set<String> = []   // video IDs the user wants transcribed

    enum LoadState {
        case loading
        case loaded(TikTokPlaylistSummary)
        case failed(String)
    }

    private let softCap = 50

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()
                content
            }
            .navigationTitle("Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel(); dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .preferredColorScheme(.dark)
            .task { await loadPlaylist() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("Loading playlist…")
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .failed(let msg):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(msg)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Back") { onCancel(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let summary):
            loadedBody(summary)
        }
    }

    private func loadedBody(_ summary: TikTokPlaylistSummary) -> some View {
        VStack(spacing: 0) {
            header(summary)
            if summary.videos.count > softCap {
                warningBanner(count: summary.videos.count)
            }
            List {
                ForEach(summary.videos) { video in
                    row(for: video)
                        .listRowBackground(Color(white: 0.11))
                        .listRowSeparatorTint(Color.white.opacity(0.08))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            transcribeBar(summary: summary)
        }
    }

    private func header(_ summary: TikTokPlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.playlistName)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 8) {
                if !summary.ownerHandle.isEmpty {
                    Text(summary.ownerHandle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text("•")
                    .foregroundStyle(.white.opacity(0.4))
                Text("\(summary.videos.count) video\(summary.videos.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(allSelected(summary) ? "Deselect All" : "Select All") {
                    if allSelected(summary) { selected.removeAll() }
                    else { selected = Set(summary.videos.map(\.id)) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func warningBanner(count: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.red)
            Text("\(count) videos is a lot. Transcribing all will take a while and may heat your phone. Deselect some before tapping Transcribe.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func row(for video: PlaylistVideoEntry) -> some View {
        Button {
            toggle(video.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                thumbnail(for: video)
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.captionPreview.isEmpty ? "Untitled" : video.captionPreview)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let dur = video.durationSeconds {
                        Text(formatDuration(dur))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected.contains(video.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(video.id) ? Color.accentColor : Color.white.opacity(0.4))
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(for video: PlaylistVideoEntry) -> some View {
        Group {
            if let thumb = video.thumbnailURL {
                CachedAsyncImage(url: thumb) { img in
                    if let img {
                        img.resizable().scaledToFill()
                    } else {
                        Color(white: 0.18)
                    }
                }
            } else {
                Color(white: 0.18)
            }
        }
        .frame(width: 72, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func transcribeBar(summary: TikTokPlaylistSummary) -> some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                Button("Cancel") { onCancel(); dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    kickOffBatch(summary: summary)
                } label: {
                    Text(selected.isEmpty
                         ? "Select videos"
                         : "Transcribe \(selected.count)")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.05, green: 0.07, blue: 0.10))
        }
    }

    // MARK: - Actions

    private func loadPlaylist() async {
        do {
            let summary = try await TikTokPlaylistExtractor.fetch(playlistURL: playlistURL)
            selected = Set(summary.videos.map(\.id))
            state = .loaded(summary)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func allSelected(_ summary: TikTokPlaylistSummary) -> Bool {
        selected.count == summary.videos.count && !summary.videos.isEmpty
    }

    private func kickOffBatch(summary: TikTokPlaylistSummary) {
        let urls = summary.videos
            .filter { selected.contains($0.id) }
            .map(\.videoPageURL.absoluteString)
        guard !urls.isEmpty else { return }
        onEnqueue()
        dismiss()
        Task { await vm.fetchBatch(urls: urls, playlistName: summary.playlistName) }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
