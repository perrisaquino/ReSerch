import Foundation

/// A user-named collection of transcripts, organized by topic.
/// Stored as part of `notebooks.json` alongside `history.json`.
/// Transcripts reference notebooks by `notebookID` so renames/color changes
/// don't require re-encoding every transcript.
struct Notebook: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var colorHex: String?
    let createdAt: Date

    init(name: String, colorHex: String? = nil) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Notebook, rhs: Notebook) -> Bool { lhs.id == rhs.id }

    /// Eight curated accent colors users can pick from when creating a notebook.
    /// Hex strings (no `#`) so they encode cleanly.
    static let presetColors: [String] = [
        "FF6B6B", // red
        "FFA94D", // orange
        "FFD43B", // yellow
        "51CF66", // green
        "4DABF7", // blue
        "9775FA", // purple
        "F783AC", // pink
        "868E96", // gray
    ]
}
