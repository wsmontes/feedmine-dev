import SwiftUI

struct CountriesListScreen: View {
    @Environment(FeedLoader.self) private var loader
    @State private var isAllCountriesChangePending = false
    @State private var pendingAllCountriesValue = false
    @State private var pendingRegionIDs = Set<String>()
    @State private var enabledPendingRegionIDs = Set<String>()

    var body: some View {
        let countries = loader.availableCountries
        List {
            Section {
                HStack {
                    Label("All Countries", systemImage: "globe.americas.fill")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isAllCountriesChangePending ? pendingAllCountriesValue : loader.isAnyCountryEnabled },
                        set: { setAllCountriesEnabled($0) }
                    ))
                    .labelsHidden()
                    .tint(.green)
                    .accessibilityIdentifier("country-toggle-all")
                }
            }

            Section {
                ForEach(countries) { country in
                    NavigationLink {
                        CountryDetailScreen(country: country)
                    } label: {
                        HStack(spacing: 12) {
                            Text(country.flag).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(country.name).font(.body)
                                Text("\(country.feedCount) feeds")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: {
                                    pendingRegionIDs.contains(country.region)
                                        ? enabledPendingRegionIDs.contains(country.region)
                                        : loader.isRegionEnabled(country.region)
                                },
                                set: { setRegionEnabled(country.region, enabled: $0) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                            .accessibilityIdentifier("country-toggle-\(country.slug)")
                        }
                    }
                    .accessibilityIdentifier("country-\(country.slug)")
                    .accessibilityValue(loader.isRegionEnabled(country.region) ? "selected" : "not selected")
                }
            } footer: {
                let total = countries.map(\.feedCount).reduce(0, +)
                Text("\(countries.count) countries · \(total) feeds")
            }
        }
        .navigationTitle("Countries")
    }

    private func setAllCountriesEnabled(_ enabled: Bool) {
        pendingAllCountriesValue = enabled
        isAllCountriesChangePending = true
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        // Give SwiftUI one turn to draw the switch before the store starts
        // pruning or reloading content.
        DispatchQueue.main.async {
            guard isAllCountriesChangePending, pendingAllCountriesValue == enabled else { return }
            loader.setAllCountriesEnabled(enabled)
            if pendingAllCountriesValue == enabled {
                isAllCountriesChangePending = false
            }
        }
    }

    private func setRegionEnabled(_ region: String, enabled: Bool) {
        pendingRegionIDs.insert(region)
        if enabled {
            enabledPendingRegionIDs.insert(region)
        } else {
            enabledPendingRegionIDs.remove(region)
        }
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        DispatchQueue.main.async {
            guard pendingRegionIDs.contains(region), enabledPendingRegionIDs.contains(region) == enabled else { return }
            loader.setRegionEnabled(region, enabled: enabled)
            if enabledPendingRegionIDs.contains(region) == enabled {
                pendingRegionIDs.remove(region)
            }
        }
    }
}
