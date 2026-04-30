import SwiftUI

/// Modal for creating a new notebook. Name field + 8-color picker.
/// Matches the SettingsView Form aesthetic (`.preferredColorScheme(.dark)`).
struct CreateNotebookSheet: View {
    var vm: TranscriptViewModel

    /// Optional callback fired with the created notebook. Used by MoveToNotebookSheet
    /// so it can immediately move selected transcripts into the just-created notebook.
    var onCreate: ((Notebook) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var selectedColorHex: String? = Notebook.presetColors.first
    @State private var notebookDescription: String = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        notebookDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notebook name", text: $name)
                        .submitLabel(.done)
                } header: {
                    Text("Name")
                }

                Section {
                    HStack(spacing: 14) {
                        ForEach(Notebook.presetColors, id: \.self) { hex in
                            Button {
                                selectedColorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .gray)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                selectedColorHex == hex ? Color.white : Color.clear,
                                                lineWidth: 2
                                            )
                                    )
                                    .scaleEffect(selectedColorHex == hex ? 1.08 : 1.0)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.7),
                                               value: selectedColorHex)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color")
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                } header: {
                    Text("Color")
                }

                Section {
                    TextField(
                        "What's this notebook for? (optional)",
                        text: $notebookDescription,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                } header: {
                    Text("Context")
                } footer: {
                    Text("Briefly describe the purpose of this notebook. Appears at the top of the notebook view and in combined exports.")
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        let nb = vm.createNotebook(
                            name: trimmedName,
                            colorHex: selectedColorHex,
                            notebookDescription: trimmedDescription.isEmpty ? nil : trimmedDescription
                        )
                        onCreate?(nb)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
