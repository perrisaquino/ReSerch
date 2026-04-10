import UIKit
import SwiftUI

@Observable
final class MarkdownStylePrefs {
    static let shared = MarkdownStylePrefs()
    private init() { load() }

    var boldColor:            UIColor = UIColor(white: 0.85, alpha: 1)
    var highlightColor:       UIColor = UIColor.systemYellow
    var wikilinkColor:        UIColor = UIColor.systemBlue
    var richTextMode:         Bool    = false
    var saveVideoToCameraRoll: Bool   = false

    private enum Key {
        static let bold               = "msp.boldColor"
        static let highlight          = "msp.highlightColor"
        static let wikilink           = "msp.wikilinkColor"
        static let richTextMode       = "msp.richTextMode"
        static let saveVideo          = "msp.saveVideoToCameraRoll"
    }

    func save() {
        store(boldColor,      key: Key.bold)
        store(highlightColor, key: Key.highlight)
        store(wikilinkColor,  key: Key.wikilink)
        UserDefaults.standard.set(richTextMode,          forKey: Key.richTextMode)
        UserDefaults.standard.set(saveVideoToCameraRoll, forKey: Key.saveVideo)
    }

    func resetToDefaults() {
        boldColor             = UIColor(white: 0.85, alpha: 1)
        highlightColor        = UIColor.systemYellow
        wikilinkColor         = UIColor.systemBlue
        richTextMode          = false
        saveVideoToCameraRoll = false
        save()
    }

    private func load() {
        boldColor             = loadColor(key: Key.bold,      fallback: boldColor)
        highlightColor        = loadColor(key: Key.highlight,  fallback: highlightColor)
        wikilinkColor         = loadColor(key: Key.wikilink,   fallback: wikilinkColor)
        richTextMode          = UserDefaults.standard.bool(forKey: Key.richTextMode)
        saveVideoToCameraRoll = UserDefaults.standard.bool(forKey: Key.saveVideo)
    }

    private func store(_ color: UIColor, key: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadColor(key: String, fallback: UIColor) -> UIColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let c    = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data)
        else { return fallback }
        return c
    }
}

extension UIColor {
    var swiftUIColor: Color { Color(self) }
}
