import SwiftUI
import UIKit

// MARK: - Design tokens (OLED dark + amber highlight system)
private extension Color {
    static let panelBg      = Color(red: 0.04, green: 0.04, blue: 0.06)   // near-black OLED
    static let cardBg       = Color(white: 0.09)                            // card surface
    static let hlTint       = Color(red: 0.96, green: 0.82, blue: 0.16).opacity(0.13) // warm amber highlight
    static let hlBorder     = Color(red: 0.96, green: 0.82, blue: 0.16).opacity(0.24) // amber border
    static let noteBg       = Color(white: 0.06)                            // note section
    static let noteAccent   = Color(red: 0.96, green: 0.65, blue: 0.12)   // amber-orange bar
    static let textPrimary  = Color(white: 0.93)
    static let textNote     = Color(white: 0.52)
    static let textLabel    = Color(white: 0.30)
}

// MARK: - AnnotationsPanel

struct AnnotationsPanel: View {
    @Binding var annotations: [Annotation]
    var transcriptText: String = ""
    @Environment(\.dismiss) private var dismiss

    // Unified display model — editor-parsed or in-app selection
    private struct DisplayAnnotation: Identifiable {
        let id = UUID()
        let text: String
        let comment: String
        let inAppId: UUID? // non-nil = swipe-delete enabled
    }

    private var allAnnotations: [DisplayAnnotation] {
        parseEditorHighlights(from: transcriptText)
        + annotations.map { DisplayAnnotation(text: $0.text, comment: $0.comment, inAppId: $0.id) }
    }

    // Parses ==text==[^N] / [^N]: comment pairs embedded in editor transcript
    private func parseEditorHighlights(from text: String) -> [DisplayAnnotation] {
        guard !text.isEmpty,
              let refRx = try? NSRegularExpression(pattern: #"==(.+?)==\[\^(\d+)\]"#, options: .dotMatchesLineSeparators),
              let defRx = try? NSRegularExpression(pattern: #"\[\^(\d+)\]: (.+)"#, options: [])
        else { return [] }

        let ns   = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var footnotes: [Int: String] = [:]
        for m in defRx.matches(in: text, range: full) {
            guard m.range(at: 1).location != NSNotFound,
                  m.range(at: 2).location != NSNotFound else { continue }
            footnotes[Int(ns.substring(with: m.range(at: 1))) ?? 0] = ns.substring(with: m.range(at: 2))
        }

        return refRx.matches(in: text, range: full).compactMap { m in
            guard m.range(at: 1).location != NSNotFound,
                  m.range(at: 2).location != NSNotFound else { return nil }
            let n = Int(ns.substring(with: m.range(at: 2))) ?? 0
            return DisplayAnnotation(
                text: ns.substring(with: m.range(at: 1)),
                comment: footnotes[n] ?? "",
                inAppId: nil
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allAnnotations.isEmpty {
                    emptyState
                } else {
                    highlightList
                }
            }
            .navigationTitle("Highlights & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .preferredColorScheme(.dark)
            .background(Color.panelBg.ignoresSafeArea())
        }
    }

    // MARK: List

    private var highlightList: some View {
        List {
            // Count header
            HStack {
                Text("\(allAnnotations.count) highlight\(allAnnotations.count == 1 ? "" : "s")")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.textLabel)
                    .tracking(0.8)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden)

            ForEach(allAnnotations) { ann in
                card(ann)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if let origId = ann.inAppId {
                            Button(role: .destructive) {
                                annotations.removeAll { $0.id == origId }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.panelBg)
    }

    // MARK: Card

    private func card(_ ann: DisplayAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Highlight block ──────────────────────────────
            Text(ann.text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.hlTint)

            // ── Note block (if present) ──────────────────────
            if !ann.comment.isEmpty {
                Rectangle()
                    .fill(Color.hlBorder)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 12) {
                    Rectangle()
                        .fill(Color.noteAccent)
                        .frame(width: 2)
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("NOTE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.noteAccent.opacity(0.75))
                            .tracking(1.2)

                        Text(ann.comment)
                            .font(.subheadline)
                            .foregroundStyle(Color.textNote)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.noteBg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.hlBorder, lineWidth: 1)
        )
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "highlighter")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color(white: 0.25))

            VStack(spacing: 6) {
                Text("No highlights yet")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(white: 0.45))

                Text("Select text in the transcript and tap\nComment or Add Note to highlight.")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.28))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.panelBg)
    }
}

// MARK: - NoteInputSheet

struct NoteInputSheet: View {
    let highlightedText: String
    let onSave: (String) -> Void

    @State private var comment = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {

                // Quote card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "highlighter")
                            .font(.caption2)
                        Text("Highlighted text")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(Color.noteAccent.opacity(0.85))

                    Text(highlightedText)
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.72))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hlTint, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.hlBorder, lineWidth: 1)
                )

                // Label
                Text("Note")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.textLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .padding(.top, 28)
                    .padding(.bottom, 10)

                // Input
                TextField("What stood out to you?", text: $comment, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(3...10)
                    .padding(14)
                    .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                focused ? Color.accentColor.opacity(0.5) : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .focused($focused)
                    .animation(.easeInOut(duration: 0.15), value: focused)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .background(Color.panelBg.ignoresSafeArea())
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color(white: 0.45))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onSave(comment)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
            }
        }
    }
}
