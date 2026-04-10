import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var prefs = MarkdownStylePrefs.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Formatting Colors") {
                    ColorPicker("Bold", selection: colorBinding(
                        get: { prefs.boldColor },
                        set: { prefs.boldColor = $0 }
                    ))
                    ColorPicker("Highlight", selection: colorBinding(
                        get: { prefs.highlightColor },
                        set: { prefs.highlightColor = $0 }
                    ))
                    ColorPicker("Wikilink", selection: colorBinding(
                        get: { prefs.wikilinkColor },
                        set: { prefs.wikilinkColor = $0 }
                    ))
                }

                Section {
                    Toggle("Save Video to Camera Roll", isOn: Binding(
                        get: { prefs.saveVideoToCameraRoll },
                        set: { prefs.saveVideoToCameraRoll = $0; prefs.save() }
                    ))
                } header: {
                    Text("Video")
                } footer: {
                    Text("When transcribing TikTok or Instagram, saves the video to your Photos library.")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        prefs.resetToDefaults()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.accentColor)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func colorBinding(
        get: @escaping () -> UIColor,
        set: @escaping (UIColor) -> Void
    ) -> Binding<Color> {
        Binding(
            get: { get().swiftUIColor },
            set: { set(UIColor($0)); prefs.save() }
        )
    }
}
