import Foundation
import SwiftUI

/// A user-named collection of transcripts, organized by topic.
/// Stored as part of `notebooks.json` alongside `history.json`.
/// Transcripts reference notebooks by `notebookID` so renames/color changes
/// don't require re-encoding every transcript.
struct Notebook: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var colorHex: String?
    let createdAt: Date
    /// Bumped whenever a transcript is assigned to or removed from this notebook.
    /// Drives the "Recently Edited" sort in the Notebooks tab and the Move-to-Notebook sheet.
    var updatedAt: Date
    /// User-defined position when the Notebooks tab is in Custom Order mode.
    /// nil for notebooks that predate manual sorting; initialized lazily on first switch.
    var manualOrder: Int?
    /// Optional context note describing the notebook's purpose.
    /// Surfaces as a subtitle in NotebookDetailView and in combined-markdown exports.
    var notebookDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, createdAt, updatedAt, manualOrder, notebookDescription
    }

    init(name: String, colorHex: String? = nil, notebookDescription: String? = nil) {
        let now = Date()
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = now
        self.updatedAt = now
        self.manualOrder = nil
        self.notebookDescription = notebookDescription
    }

    // Custom decode so notebooks saved before these fields existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        let created = try c.decode(Date.self, forKey: .createdAt)
        createdAt = created
        updatedAt = (try c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? created
        manualOrder = try c.decodeIfPresent(Int.self, forKey: .manualOrder)
        notebookDescription = try c.decodeIfPresent(String.self, forKey: .notebookDescription)
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

    /// Resolves the notebook's stored hex string to a SwiftUI Color.
    /// Falls back to the app accent color when colorHex is nil or unparseable.
    var color: Color {
        Color(hex: colorHex) ?? .accentColor
    }
}

extension Color {
    /// Initializes a Color from a 6-char hex string (no `#`). Returns nil if unparseable.
    /// Used by `Notebook.color`.
    init?(hex: String?) {
        guard let hex, hex.count == 6,
              let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
