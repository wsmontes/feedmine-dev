import SwiftUI

enum FeedEmptyMode: Equatable {
    case noSourcesEnabled
    case fetching(topic: String, fetched: Int, total: Int)
    case noResults(topic: String)
    case generic
}

/// The legacy page's own state for the empty surface: everything this view read off `FeedLoader` before
/// the surface a launch's runtime owns existed.
///
/// It is a value so the layout below reads no loader at all: `FeedEmptyDisplay.forSurface` is the one
/// place those properties are read, and only on the lane that still owns them.
struct FeedEmptyLegacyFacts: Equatable {
    let mode: FeedEmptyMode
    let isRefreshing: Bool
    let isInitial: Bool
    let sourceCount: Int
    let fetchErrorCount: Int
    let totalFetched: Int
    let hasAnySource: Bool
    let disabledSourceCount: Int
}

/// What the empty surface says, and which owner it says it from.
///
/// A launch's session owns exactly one selection. On that selection the empty surface is the runtime's
/// own statement — the variant the session published and its acquisition — and none of the legacy page's
/// reasons for being empty describe it: in this mode the legacy engine's requests are refused by
/// `LegacyAcquisitionGate` (`docs/runtime-v2/baseline.md` §8.26), so its counters describe an acquisition
/// this launch never performs. Everywhere else the surface is the legacy page's own, verbatim.
///
/// The lane is a value so the choice is assertable without a rendering, and it is the structural half of
/// "the legacy counters are not read there": the session's case carries none of them, so the layout has
/// nothing of the legacy page to interpolate.
enum FeedEmptyDisplay: Equatable {
    /// The runtime's own statement. No legacy counter is in it.
    case session(FeedEmptyStatement)
    /// The legacy page's own empty surface, with the counters it read before this slice.
    case legacy(FeedEmptyLegacyFacts)

    /// The lane for one surface.
    ///
    /// `session` is non-nil exactly on the surface a launch's runtime owns
    /// (`MainFeedRuntime.sessionEmptyStatement`), and then the loader is not read at all: the guard below
    /// is the whole of the separation. It is `@MainActor` — rather than the whole value type, which is
    /// pure — because the legacy lane reads the loader, and every call site is a view body.
    @MainActor
    static func forSurface(
        session: FeedEmptyStatement?,
        mode: FeedEmptyMode,
        loader: FeedLoader
    ) -> FeedEmptyDisplay {
        guard let session else {
            return .legacy(
                FeedEmptyLegacyFacts(
                    mode: mode,
                    isRefreshing: loader.loadingState == .refreshing,
                    isInitial: loader.loadingState == .initial,
                    sourceCount: loader.sourceCount,
                    fetchErrorCount: loader.fetchErrorCount,
                    totalFetched: loader.totalFetched,
                    hasAnySource: !loader.sources.isEmpty,
                    disabledSourceCount: loader.disabledSourceIDs.count
                )
            )
        }
        return .session(session)
    }

    /// Which lane drew this surface, for the surface's own log line: `session` or `legacy`. It is what
    /// makes the choice a production observable rather than a test-only one.
    var source: String {
        switch self {
        case .session: return "session"
        case .legacy: return "legacy"
        }
    }

    /// The variant this lane draws. Both lanes have one; only the legacy lane's came from the loader.
    private var mode: FeedEmptyMode {
        switch self {
        case .session(let statement): return statement.mode
        case .legacy(let facts): return facts.mode
        }
    }

    /// The legacy page states its own loading state and this surface shows a spinner while it refreshes.
    /// The session's lane states no refresh in flight — the app layer cannot read one today — so it draws
    /// none rather than borrowing the legacy page's.
    var isRefreshing: Bool {
        guard case .legacy(let facts) = self else { return false }
        return facts.isRefreshing
    }

    var iconName: String {
        switch mode {
        case .noSourcesEnabled: return "globe.americas.fill"
        case .fetching: return "magnifyingglass"
        case .noResults: return "tray"
        case .generic:
            // The session's `.generic` is a published edition with no cards; the legacy page's five icons
            // are its own loading state, its fetch errors and whether it has a source at all — none of
            // which the runtime states, so the session's lane takes the fallback and asks nothing.
            guard case .legacy(let facts) = self else { return "newspaper.fill" }
            if facts.isInitial {
                return "antenna.radiowaves.left.and.right"
            } else if facts.isRefreshing {
                return "line.3.horizontal.decrease.circle"
            } else if facts.fetchErrorCount > 0 && facts.totalFetched == 0 {
                return "wifi.slash"
            } else if !facts.hasAnySource {
                return "folder.badge.questionmark"
            } else {
                return "newspaper.fill"
            }
        }
    }

    var title: String {
        switch mode {
        case .noSourcesEnabled:
            return String(localized: "No sources enabled", comment: "Empty state title")
        case .fetching(let topic, _, _):
            return String(localized: "Searching for \(topic)...", comment: "Empty state title — fetching")
        case .noResults(let topic):
            return String(localized: "No articles found for \(topic)", comment: "Empty state title — no results")
        case .generic:
            // "No articles yet" is the one branch of the legacy wording that states no legacy figure: the
            // session published an empty edition, and its own acquisition is stated on the line below
            // rather than in a count the legacy page used to supply.
            guard case .legacy(let facts) = self else {
                return String(localized: "No articles yet", comment: "Empty state title")
            }
            if facts.isInitial {
                return String(localized: "Loading your feed...", comment: "Empty state title")
            } else if facts.isRefreshing {
                return String(localized: "Filtering articles...", comment: "Empty state title — filter in progress")
            } else if facts.fetchErrorCount > 0 && facts.totalFetched == 0 {
                return String(localized: "Couldn't load feeds", comment: "Empty state title")
            } else if !facts.hasAnySource {
                return String(localized: "No sources found", comment: "Empty state title")
            } else {
                return String(localized: "No articles yet", comment: "Empty state title")
            }
        }
    }

    /// The description line. `circadian` is the view's own circadian text (`CircadianEngine`), which the
    /// legacy lane's last branch and the session's `.generic` variant both fall back to: it reads no
    /// loader and no runtime fact, so both lanes state it identically.
    func description(circadian: String) -> String {
        switch mode {
        case .noSourcesEnabled:
            return String(localized: "Enable some countries or topics in Filters to start seeing content.", comment: "Empty state description")
        case .fetching(let topic, _, let total):
            return String(localized: "We're fetching the latest articles from \(total) sources in \(topic). They'll appear here as they arrive.", comment: "Empty state description — fetching")
        case .noResults:
            return String(localized: "These sources may not have published recently. Try a different topic or check back later.", comment: "Empty state description — no results")
        case .generic:
            guard case .legacy(let facts) = self else { return circadian }
            if facts.isInitial {
                return String(localized: "Fetching articles from \(facts.sourceCount) sources.", comment: "Empty state description")
            } else if facts.fetchErrorCount > 0 && facts.totalFetched == 0 {
                return String(localized: "All \(facts.fetchErrorCount) sources failed to load. Check your internet connection and pull to refresh.", comment: "Empty state description")
            } else if !facts.hasAnySource {
                return String(localized: "Add .opml files to the Resources/Feeds folder in Xcode and rebuild the app.", comment: "Empty state description")
            } else {
                return circadian
            }
        }
    }

    /// The line drawn where the legacy page prints "Fetched N of M sources…".
    ///
    /// The legacy lane prints its own counters there. The session's lane states the runtime's own
    /// acquisition instead, in the loading surface's own vocabulary — `FeedLoadingDisplay` is the single
    /// source of that wording, so the two surfaces cannot describe the same launch differently: the legacy
    /// figure is a count of the legacy engine's fetches, which this launch never performs. The
    /// `.noSourcesEnabled` variant states no count at all.
    var progressText: String? {
        if case .legacy(let facts) = self, case .fetching(_, let fetched, let total) = facts.mode {
            return String(localized: "Fetched \(fetched) of \(total) sources...")
        }
        guard case .session(let statement) = self, case .generic = statement.mode else { return nil }
        guard case .noCatalogue = statement.acquisition else {
            return FeedLoadingDisplay.session(statement.acquisition).detail
        }
        return nil
    }

    var showOpenFilters: Bool {
        if case .noSourcesEnabled = mode { return true }
        return false
    }

    /// Whether the refresh/filters actions are drawn.
    ///
    /// The legacy page hides them while it is in `.initial` or `.refreshing`, because its own work is in
    /// flight. The session's lane is a statement about what the session did (a published edition, or
    /// nothing to acquire from), so its actions are always available — and it states no refresh in flight
    /// to hide them for.
    var showActions: Bool {
        guard case .legacy(let facts) = self else { return true }
        if case .noSourcesEnabled = facts.mode { return true }
        return !facts.isInitial && !facts.isRefreshing
    }

    /// The line under "Refresh Now".
    ///
    /// The legacy page states how many of its sources the user has disabled. The session's lane has no
    /// such fact — the runtime's plan is built from the loader's selectors, and it does not carry the
    /// toggled-off count — so it states nothing rather than borrowing the legacy page's figure.
    var disabledSourcesTip: String? {
        guard case .legacy(let facts) = self, facts.disabledSourceCount > 0 else { return nil }
        let count = facts.disabledSourceCount
        let verb = count == 1 ? " is" : "s are"
        return String(localized: "Tip: \(count) source\(verb) disabled")
    }
}

struct FeedEmptyStateView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared

    var mode: FeedEmptyMode = .generic
    /// The refresh the empty surface performs, when the surface drawing it has its own.
    ///
    /// Nil keeps the view's legacy action (`loader.refresh()`), which is what an empty surface on a
    /// legacy page still uses. A surface drawn from session snapshots passes the runtime's refresh: in
    /// that mode the legacy store acquires nothing — its requests are refused by `LegacyAcquisitionGate`
    /// (`docs/runtime-v2/baseline.md` §8.26) — so the legacy call would be a button that does nothing.
    var onRefresh: (() async -> Void)? = nil
    /// The runtime's own statement, on the surface a launch's runtime owns (plan §17, DoD2).
    ///
    /// Nil everywhere else — `FeedEmptyStateView(mode:)` is the legacy lane — and then this surface is
    /// the empty one it was before the slice: `FeedEmptyDisplay.forSurface` is where the two lanes split.
    /// When it is present the legacy `mode` is not read either.
    var session: FeedEmptyStatement? = nil

    /// What this surface says. It is the only thing the body reads, so the legacy properties are read on
    /// exactly one lane and the session's lane cannot read them at all.
    private var display: FeedEmptyDisplay {
        FeedEmptyDisplay.forSurface(session: session, mode: mode, loader: loader)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Progress spinner during refresh — shows work is happening
            if display.isRefreshing {
                ProgressView()
                    .tint(engine.accent)
                    .scaleEffect(1.2)
            }

            // Icon
            ZStack {
                Circle()
                    .fill(engine.accent.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: display.iconName)
                    .font(.system(size: 40))
                    .foregroundStyle(engine.accent)
            }

            // Title
            Text(display.title)
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("feed-empty-title")

            // Description
            Text(display.description(circadian: circadianNoArticlesMessage))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.9)
                .padding(.horizontal, 32)

            // Fetching progress
            if let progressText = display.progressText {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            // Action buttons
            if display.showActions {
                VStack(spacing: 12) {
                    if display.showOpenFilters {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            showFilters = true
                        } label: {
                            HStack {
                                Image(systemName: "line.3.horizontal.decrease")
                                Text("Open Filters")
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(engine.accent)
                        .controlSize(.large)
                    } else {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            Task {
                                if let onRefresh {
                                    await onRefresh()
                                } else {
                                    await loader.refresh()
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh Now")
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(engine.accent)
                        .controlSize(.large)

                        if let tip = display.disabledSourcesTip {
                            Text(tip)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 40)
        .accessibilityIdentifier("feed-empty-state")
        // Same reason as `InitialFeedLoadingView`: this is the other no-feed surface (it is what a `ready`-but-empty
        // feed renders, and its title reads "Loading your feed..." while `loadingState == .initial`), and the test-side
        // sampler cannot see the window before `launch()` returns. The title says which variant, and which lane, the
        // user was shown.
        .onAppear { Log.ui.info("surface[empty-state] appear source=\(display.source) title=\(display.title)") }
        .onDisappear { Log.ui.info("surface[empty-state] disappear") }
        .sheet(isPresented: $showFilters) {
            FilterSheetView()
        }
    }

    @State private var showFilters = false

    private var circadianNoArticlesMessage: String {
        switch engine.period {
        case .dawn:    return String(localized: "The world's still quiet. Stories are on their way.", comment: "Empty state — dawn")
        case .morning: return String(localized: "Nothing here yet. Good time to add a source?", comment: "Empty state — morning")
        case .afternoon: return String(localized: "All caught up. Quick and clean.", comment: "Empty state — afternoon")
        case .evening: return String(localized: "All caught up. These are worth the slow read — come back soon.", comment: "Empty state — evening")
        case .night:   return String(localized: "All caught up. Sleep well. The news will be here tomorrow.", comment: "Empty state — night")
        }
    }
}
