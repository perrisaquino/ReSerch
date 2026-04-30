import Foundation

/// A single video surfaced by a playlist scrape. Enough info to render a preview row
/// and to hand off to `fetchTranscript` later — the full per-video metadata is
/// re-fetched at transcription time via VideoExtractor.
struct PlaylistVideoEntry: Identifiable, Hashable {
    let id: String              // TikTok video numeric ID
    let videoPageURL: URL       // Canonical `https://www.tiktok.com/@user/video/{id}`
    let captionPreview: String  // First ~80 chars of the caption if available
    let thumbnailURL: URL?
    let durationSeconds: Int?
    let author: String          // Display name of creator (often the playlist owner)
    let handle: String          // `@handle`
}

struct TikTokPlaylistSummary {
    let playlistID: String
    let playlistName: String
    let ownerHandle: String
    let videos: [PlaylistVideoEntry]
}
