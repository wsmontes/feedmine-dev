import SwiftUI

struct FilterSheetView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var draftContentType: FeedLoader.ContentType = .all
    @State private var draftLanguages: Set<String> = []
    @State private var draftMood: FeedLoader.MoodFilter = .all
    @State private var draftPreset: PresetSelector = .everything
    @State private var presetIsDirty = false
    @State private var overlayFiltersAreDirty = false
    @State private var availableCollections: [SourceCollection] = []
    @State private var availableSmartFeeds: [SmartFeed] = []
    @State private var availableCuratedFeeds: [CuratedFeed] = []

    private var hasDraftFilters: Bool {
        draftContentType != .all
            || !draftLanguages.isEmpty
            || draftMood != .all
            || draftPreset != .everything
            || loader.hasRegionSelection
            || loader.hasTaxonomySelection
    }

    var body: some View {
        let countries = loader.availableCountries
        NavigationStack {
            List {
                // Clear at top
                Section {
                    Button(role: .destructive) {
                        draftContentType = .all
                        draftLanguages = []
                        draftMood = .all
                        presetIsDirty = false
                        overlayFiltersAreDirty = false
                        // While composing a search, "Clear All Filters" clears
                        // its context but keeps the committed term tags alive.
                        loader.clearAllFilters(preservingSearch: loader.isSearching)
                        dismiss()
                    } label: {
                        Label("Clear All Filters", systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("filter-clear-all")
                    .disabled(!hasDraftFilters && loader.searchQuery.isEmpty)
                }

                Section("Feeds") {
                    Picker(selection: $draftPreset) {
                        Label("Everything", systemImage: "circle.grid.3x3.fill")
                            .tag(PresetSelector.everything)
                            .accessibilityIdentifier("preset-option-everything")
                        Label("Last clicked", systemImage: "clock.arrow.circlepath")
                            .tag(PresetSelector.lastClicked)
                            .accessibilityIdentifier("preset-option-last-clicked")

                        Section("Editorial") {
                            ForEach(FeedPreset.allCases.filter { $0 != .everything }) { preset in
                                Label(preset.rawValue, systemImage: preset.icon)
                                    .tag(PresetSelector.editorial(preset))
                                    .accessibilityIdentifier("preset-option-\(preset.rawValue.identifierSlug)")
                            }
                        }

                        if !availableCuratedFeeds.isEmpty {
                            Section("Curated Feeds") {
                                ForEach(availableCuratedFeeds) { curatedFeed in
                                    Label(
                                        curatedFeed.name,
                                        systemImage: "slider.horizontal.3"
                                    )
                                    .tag(PresetSelector.curatedFeed(
                                        curatedFeedID: curatedFeed.id,
                                        curatedFeedName: curatedFeed.name
                                    ))
                                }
                            }
                        }

                        if !availableCollections.isEmpty {
                            Section("Collections") {
                                ForEach(availableCollections) { collection in
                                    Label(collection.name, systemImage: "folder.fill")
                                        .tag(PresetSelector.collection(
                                            collectionID: collection.id,
                                            collectionName: collection.name
                                        ))
                                }
                            }
                        }

                        if !availableSmartFeeds.isEmpty {
                            Section("Smart Bookmarks") {
                                ForEach(availableSmartFeeds) { smartFeed in
                                    Label(
                                        smartFeed.name,
                                        systemImage: "sparkles.rectangle.stack.fill"
                                    )
                                    .tag(PresetSelector.smartFeed(
                                        smartFeedID: smartFeed.id,
                                        smartFeedName: smartFeed.name
                                    ))
                                }
                            }
                        }
                    } label: {
                        Label("Preset", systemImage: "sparkles")
                    }
                    .pickerStyle(.menu)
                    // The option Labels above carry identifiers of their own, but a `.menu` Picker hands its
                    // content to UIKit, which rebuilds each option as a `UIMenu` item: the option's identifier
                    // does not survive into the presented menu. The picker row itself is identified here and
                    // the sweep opens it and taps the option by its label — the same thing a person does — so
                    // no option is unreachable from a test even though UIKit drops the per-option ids.
                    .accessibilityIdentifier("preset-picker")
                    .onChange(of: draftPreset) { _, _ in
                        presetIsDirty = true
                    }

                    NavigationLink {
                        CountriesListScreen()
                    } label: {
                        HStack {
                            Label("Countries", systemImage: "globe")
                            Spacer()
                            let enabled = countries.filter { loader.isRegionEnabled($0.region) }.count
                            Text("\(enabled) on")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("countries-link")
                }

                Section("Content Type") {
                    ForEach(FeedLoader.ContentType.allCases) { type in
                        Button {
                            draftContentType = draftContentType == type ? .all : type
                            overlayFiltersAreDirty = true
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack {
                                Label(type.rawValue, systemImage: type.icon)
                                Spacer()
                                if draftContentType == type {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .accessibilityIdentifier("content-type-\(type.rawValue.lowercased())-selected")
                                }
                            }
                        }
                        .accessibilityIdentifier("content-type-\(type.rawValue.lowercased())")
                        .accessibilityValue(draftContentType == type ? "selected" : "not selected")
                    }
                }

                Section("Topics") {
                    NavigationLink {
                        TaxonomyBrowseView()
                    } label: {
                        HStack {
                            Label("Browse Topics", systemImage: "list.bullet.rectangle")
                            Spacer()
                            if !loader.selectedNodeNames.isEmpty {
                                Text(loader.selectedNodeNames.prefix(3).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("browse-topics")
                    .accessibilityValue("\(loader.selectedNodeIDs.count)")
                }

                Section("Language") {
                    let languages = loader.availableLanguages
                    if languages.isEmpty {
                        Text("No language data available")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(languages) { lang in
                            Button {
                                if draftLanguages.contains(lang.code) {
                                    draftLanguages.remove(lang.code)
                                } else {
                                    draftLanguages.insert(lang.code)
                                }
                                overlayFiltersAreDirty = true
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                HStack {
                                    Text(lang.flag)
                                    Text(lang.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if draftLanguages.contains(lang.code) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text("\(lang.feedCount) on")
                                        if lang.totalFeedCount > lang.feedCount {
                                            Text("\(lang.totalFeedCount) total")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                            }
                            .accessibilityIdentifier("language-\(lang.code)")
                            .accessibilityValue(draftLanguages.contains(lang.code) ? "selected" : "not selected")
                        }
                    }
                }

                Section("Mood") {
                    ForEach(FeedLoader.MoodFilter.allCases) { mood in
                        Button {
                            draftMood = draftMood == mood ? .all : mood
                            overlayFiltersAreDirty = true
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack {
                                Label(mood.rawValue, systemImage: mood.icon)
                                Spacer()
                                if draftMood == mood { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }
                        .accessibilityIdentifier("mood-\(mood.rawValue.lowercased())")
                        .accessibilityValue(draftMood == mood ? "selected" : "not selected")
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("filter-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Keep the filter controls legible over visual content and in store
        // screenshots; the default material sheet can otherwise show the feed
        // through the form on newer iOS releases.
        .presentationBackground(Color(uiColor: .systemBackground))
        .onAppear {
            draftContentType = loader.selectedContentType
            draftLanguages = loader.selectedLanguages
            draftMood = loader.selectedMood
            draftPreset = loader.activePreset
            presetIsDirty = false
            overlayFiltersAreDirty = false
            loader.beginFilterEditing()
            Task {
                async let collections = loader.loadSourceCollections()
                async let smartFeeds = loader.loadSmartFeeds()
                async let curatedFeeds = loader.loadCuratedFeeds()
                availableCollections = (try? await collections) ?? []
                availableSmartFeeds = (try? await smartFeeds) ?? []
                availableCuratedFeeds = (try? await curatedFeeds) ?? []
            }
        }
        .onDisappear {
            // Apply preset and filter changes independently so a preset-only
            // switch does not trigger a generic filter reload that would flush
            // correctly-hydrated collection content (see scheduleFilterReload).
            if presetIsDirty {
                loader.setActivePreset(draftPreset)
            }
            if overlayFiltersAreDirty {
                loader.applyFilterDraft(
                    type: draftContentType,
                    mood: draftMood,
                    languages: draftLanguages
                )
            }
            loader.endFilterEditing()
        }
    }

}

private extension String {
    /// Lowercase, hyphen-joined form of a display name, for stable accessibility identifiers
    /// ("Tech & Science" → "tech-science"). Identifiers only: nothing here changes behaviour or styling.
    var identifierSlug: String {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
