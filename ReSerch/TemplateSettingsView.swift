import SwiftUI

// MARK: - Shared preview helper

/// Renders previewMarkdown using AttributedString so bold + links show as formatted text
/// rather than raw `**syntax**`. Falls back to monospaced if parsing fails.
private struct MarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            Group {
                if let attributed = try? AttributedString(
                    markdown: markdown,
                    options: AttributedString.MarkdownParsingOptions(
                        interpretedSyntax: .inlineOnlyPreservingWhitespace
                    )
                ) {
                    Text(attributed)
                        .font(.system(size: 12))
                } else {
                    Text(markdown)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
        .frame(height: 240)
    }
}

// MARK: - Sample data (shared across preview sites)

private let sampleCapturedAt: Date = ISO8601DateFormatter().date(from: "2026-04-12T15:14:00Z") ?? Date()
private let sampleResult = TranscriptResult(
    title: "How to Build a Second Brain",
    author: "Tiago Forte",
    handle: "@tiagoforte",
    platform: "YouTube",
    url: "https://youtube.com/watch?v=example123",
    caption: "In this video I break down the full CODE method for capturing and organizing knowledge.",
    transcript: "The idea of a second brain is simple. You capture information from the world, organize it so you can find it later, distill it to the key insights, then express it in your own work.",
    viewCount: 847_200,
    likeCount: 24_800,
    commentCount: 1_043,
    shareCount: 3_210,
    duration: "18:42",
    postedDate: ISO8601DateFormatter().date(from: "2024-03-15T00:00:00Z")
)

// MARK: - Main template settings

struct TemplateSettingsView: View {
    @State private var prefs = ExportTemplatePrefs.shared

    var body: some View {
        List {
            frontmatterSection
            bodySectionsSection
            if prefs.showMetaBlock {
                metaFieldsLinkSection
            }
            highlightsSection
            previewSection
            resetSection
        }
        .navigationTitle("Export Template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    @ViewBuilder
    private var frontmatterSection: some View {
        Section {
            Toggle("YAML Frontmatter", isOn: Binding(
                get: { prefs.showYAML },
                set: { prefs.showYAML = $0; prefs.save() }
            ))
            if prefs.showYAML {
                NavigationLink("YAML Fields & Order") {
                    YAMLFieldsView()
                }
            }
        } header: {
            Text("Frontmatter")
        } footer: {
            Text("When enabled, YAML always appears first in the export.")
        }
    }

    @ViewBuilder
    private var bodySectionsSection: some View {
        Section {
            ForEach(prefs.sectionOrder, id: \.self) { section in
                Toggle(isOn: showBinding(for: section)) {
                    Label(section.displayName, systemImage: section.systemImage)
                }
            }
            .onMove { from, to in
                prefs.sectionOrder.move(fromOffsets: from, toOffset: to)
                prefs.save()
            }
        } header: {
            Text("Sections")
        } footer: {
            Text("Tap Edit above to drag and reorder sections in your export.")
        }
    }

    @ViewBuilder
    private var metaFieldsLinkSection: some View {
        Section {
            NavigationLink("Meta Block Fields") {
                MetaFieldsView()
            }
        }
    }

    @ViewBuilder
    private var highlightsSection: some View {
        Section {
            Picker("Timestamp Format", selection: Binding(
                get: { prefs.highlightDateFormat },
                set: { prefs.highlightDateFormat = $0; prefs.save() }
            )) {
                ForEach(HighlightDateFormat.allCases, id: \.self) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .pickerStyle(.menu)
            if prefs.highlightDateFormat != .obsidianLink &&
               prefs.highlightDateFormat != .isoDate &&
               prefs.highlightDateFormat != .none {
                Toggle("24-Hour Time", isOn: Binding(
                    get: { prefs.highlightUse24HourTime },
                    set: { prefs.highlightUse24HourTime = $0; prefs.save() }
                ))
            }
        } header: {
            Text("Highlights Export")
        } footer: {
            Text("Timestamp format shown above each highlight when you tap Export.")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section("Live Preview") {
            MarkdownPreviewView(markdown: previewMarkdown)
        }
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("Reset to Defaults", role: .destructive) {
                prefs.resetToDefaults()
            }
        }
    }

    // MARK: - Helpers

    private var previewMarkdown: String {
        MarkdownFormatter.format(
            sampleResult,
            notebook: nil,
            notes: [],
            template: prefs,
            capturedAt: sampleCapturedAt
        )
    }

    private func showBinding(for section: ExportSectionID) -> Binding<Bool> {
        switch section {
        case .title:
            return Binding(get: { prefs.showTitle },      set: { prefs.showTitle = $0;      prefs.save() })
        case .meta:
            return Binding(get: { prefs.showMetaBlock },  set: { prefs.showMetaBlock = $0;  prefs.save() })
        case .pinnedNote:
            return Binding(get: { prefs.showPinnedNote }, set: { prefs.showPinnedNote = $0; prefs.save() })
        case .caption:
            return Binding(get: { prefs.showCaption },    set: { prefs.showCaption = $0;    prefs.save() })
        case .transcript:
            return Binding(get: { prefs.showTranscript }, set: { prefs.showTranscript = $0; prefs.save() })
        case .notes:
            return Binding(get: { prefs.showNotes },      set: { prefs.showNotes = $0;      prefs.save() })
        }
    }
}

// MARK: - YAML Fields & Order

struct YAMLFieldsView: View {
    @State private var prefs = ExportTemplatePrefs.shared

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("title is always first and cannot be moved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(prefs.yamlFieldOrder, id: \.self) { field in
                    Toggle(field.displayName, isOn: enabledBinding(for: field))
                }
                .onMove { from, to in
                    prefs.yamlFieldOrder.move(fromOffsets: from, toOffset: to)
                    prefs.save()
                }
            } header: {
                Text("Fields")
            } footer: {
                Text("Tap Edit to reorder fields within your YAML frontmatter.")
            }
            Section("Live Preview") {
                MarkdownPreviewView(markdown: previewMarkdown)
            }
        }
        .navigationTitle("YAML Fields & Order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .preferredColorScheme(.dark)
    }

    private var previewMarkdown: String {
        MarkdownFormatter.format(
            sampleResult,
            notebook: nil,
            notes: [],
            template: prefs,
            capturedAt: sampleCapturedAt
        )
    }

    private func enabledBinding(for field: YAMLFieldID) -> Binding<Bool> {
        switch field {
        case .author:
            return Binding(get: { prefs.yamlAuthor },     set: { prefs.yamlAuthor = $0;     prefs.save() })
        case .handle:
            return Binding(get: { prefs.yamlHandle },     set: { prefs.yamlHandle = $0;     prefs.save() })
        case .platform:
            return Binding(get: { prefs.yamlPlatform },   set: { prefs.yamlPlatform = $0;   prefs.save() })
        case .source:
            return Binding(get: { prefs.yamlSource },     set: { prefs.yamlSource = $0;     prefs.save() })
        case .notebook:
            return Binding(get: { prefs.yamlNotebook },   set: { prefs.yamlNotebook = $0;   prefs.save() })
        case .savedDate:
            return Binding(get: { prefs.yamlSavedDate },  set: { prefs.yamlSavedDate = $0;  prefs.save() })
        case .postedDate:
            return Binding(get: { prefs.yamlPostedDate }, set: { prefs.yamlPostedDate = $0; prefs.save() })
        case .duration:
            return Binding(get: { prefs.yamlDuration },   set: { prefs.yamlDuration = $0;   prefs.save() })
        case .stats:
            return Binding(get: { prefs.yamlStats },      set: { prefs.yamlStats = $0;      prefs.save() })
        }
    }
}

// MARK: - Meta Block Fields

struct MetaFieldsView: View {
    @State private var prefs = ExportTemplatePrefs.shared

    var body: some View {
        List {
            Section {
                Toggle("Creator (with profile link)", isOn: Binding(
                    get: { prefs.metaCreator },
                    set: { prefs.metaCreator = $0; prefs.save() }
                ))
                Toggle("Author", isOn: Binding(
                    get: { prefs.metaAuthor },
                    set: { prefs.metaAuthor = $0; prefs.save() }
                ))
                Toggle("Platform", isOn: Binding(
                    get: { prefs.metaPlatform },
                    set: { prefs.metaPlatform = $0; prefs.save() }
                ))
                Toggle("Notebook", isOn: Binding(
                    get: { prefs.metaNotebook },
                    set: { prefs.metaNotebook = $0; prefs.save() }
                ))
            } header: {
                Text("Identity")
            }
            Section {
                Toggle("Captured Date", isOn: Binding(
                    get: { prefs.metaCapturedDate },
                    set: { prefs.metaCapturedDate = $0; prefs.save() }
                ))
                Toggle("Posted Date", isOn: Binding(
                    get: { prefs.metaPostedDate },
                    set: { prefs.metaPostedDate = $0; prefs.save() }
                ))
            } header: {
                Text("Dates")
            } footer: {
                Text("Captured = when you saved this to ReSerch. Posted = when the creator published.")
            }
            Section {
                Toggle("Duration", isOn: Binding(
                    get: { prefs.metaDuration },
                    set: { prefs.metaDuration = $0; prefs.save() }
                ))
                Toggle("Stats (views, likes, etc.)", isOn: Binding(
                    get: { prefs.metaStats },
                    set: { prefs.metaStats = $0; prefs.save() }
                ))
                Toggle("Source Link", isOn: Binding(
                    get: { prefs.metaSource },
                    set: { prefs.metaSource = $0; prefs.save() }
                ))
            } header: {
                Text("Media & Source")
            }
            Section("Live Preview") {
                MarkdownPreviewView(markdown: previewMarkdown)
            }
        }
        .navigationTitle("Meta Block Fields")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private var previewMarkdown: String {
        MarkdownFormatter.format(
            sampleResult,
            notebook: nil,
            notes: [],
            template: prefs,
            capturedAt: sampleCapturedAt
        )
    }
}
