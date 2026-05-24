import UIKit

/// Single share item that vends either plain markdown OR rich `NSAttributedString`
/// depending on the destination activity type. Lets rich-text destinations
/// (Apple Notes, Mail, Messages, system pasteboard) receive tappable hyperlinks
/// while plain-text destinations still get clean markdown.
///
/// Why a single `UIActivityItemSource` instead of `[mdString, nsAttrString]`:
/// passing both as two `activityItems` makes `UIActivityViewController` treat
/// them as TWO separate shared payloads, which duplicates content in Notes/Mail.
/// This source returns ONE representation per call, picked by destination.
final class MarkdownShareItem: NSObject, UIActivityItemSource {

    let markdown: String

    /// Activity types known to render rich text well. Conservative allowlist —
    /// anything not in the set receives plain markdown so we never silently
    /// degrade a text editor's experience with attributed-string artifacts.
    private static let richHosts: Set<String> = [
        "com.apple.mobilenotes.SharingExtension",    // Apple Notes
        "com.apple.UIKit.activity.Mail",              // Mail
        "com.apple.UIKit.activity.Message",           // Messages
        "com.apple.UIKit.activity.CopyToPasteboard"   // System copy (pasteboard preserves rich)
    ]

    init(markdown: String) {
        self.markdown = markdown
    }

    /// Built lazily and once — the AttributedString conversion has some cost and
    /// we don't want to pay it for plain-text shares that never use it.
    private lazy var attributed: NSAttributedString = Self.makeAttributed(from: markdown)

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        // Placeholder used by the system to decide which activities to show.
        // Returning a String keeps every activity available (including text-only).
        markdown
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        guard let type = activityType?.rawValue else { return markdown }
        return Self.richHosts.contains(type) ? attributed : markdown
    }

    // MARK: - Markdown → AttributedString

    /// Strips the YAML frontmatter block (if any) then converts the remaining
    /// markdown to an `NSAttributedString` that preserves `[text](url)` as
    /// tappable `.link` attributes. Frontmatter is stripped because it renders
    /// as literal `---\nkey: value\n---` noise in Notes/Mail — the human-readable
    /// meta block already carries the same info in tappable form.
    private static func makeAttributed(from markdown: String) -> NSAttributedString {
        let stripped = stripFrontmatter(markdown)
        // `.full` interpretation: needed for the meta block's `  \n` hard line
        // breaks and `\n\n` paragraph breaks to render as actual breaks in
        // Apple Notes. `.inlineOnlyPreservingWhitespace` would keep newlines
        // as literal whitespace and collapse the meta block visually. Block
        // syntax like `# Heading` becomes a heading-attributed run — Apple
        // Notes renders this fine. Inline `**bold**` and `[text](url)` work
        // identically in both modes.
        guard let attr = try? AttributedString(
            markdown: stripped,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return NSAttributedString(string: stripped)
        }
        return NSAttributedString(attr)
    }

    /// Removes a leading `---\n...\n---` YAML frontmatter block. No-op if the
    /// input doesn't start with `---` on its own line.
    private static func stripFrontmatter(_ md: String) -> String {
        let prefix = "---\n"
        guard md.hasPrefix(prefix) else { return md }
        let afterOpen = md.index(md.startIndex, offsetBy: prefix.count)
        // Look for the closing `---` on its own line.
        guard let closeRange = md.range(of: "\n---\n", range: afterOpen..<md.endIndex)
                ?? md.range(of: "\n---", range: afterOpen..<md.endIndex)
        else {
            return md
        }
        var rest = String(md[closeRange.upperBound...])
        // Trim leading blank lines so the body doesn't start with empty space
        // where the frontmatter used to live.
        while rest.hasPrefix("\n") { rest.removeFirst() }
        return rest
    }
}
