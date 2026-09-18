import Foundation
import Observation
import FeedDomain
import FeedRuntime
import FeedStorage
import FeedUIBridge

/// Joins `FeedScreenStore` to the runtime that owns the consequences of an intent.
///
/// The store takes its handler at init and the runtime that owns the store builds it, so the two are
/// joined through one indirection instead of a reference cycle. The store stays a plain transport: it
/// reduces nothing and performs nothing (plan §11).
@MainActor
final class MainFeedIntentRouter {
    private var handler: ((FeedSessionIntent) -> Void)?

    func connect(_ handler: @escaping (FeedSessionIntent) -> Void) {
        self.handler = handler
    }

    func send(_ intent: FeedSessionIntent) {
        handler?(intent)
    }
}

/// What the session did when this launch started it.
///
/// It is the runtime's own statement rather than a log string, because the surface state below reads
/// it: "there was nothing to acquire from" is an answer the reader has to be given, not a message only
/// the log carries.
enum MainFeedSessionState: Equatable {
    /// `attach` has not run, or the catalogue has not been read yet: this launch is still in its
    /// bootstrap and the acquisition owner has been given nothing to watch.
    case notStarted
    /// The catalogue was read and the acquisition owner took on the sources this launch watches: the
    /// session is acquiring from them.
    case acquiring(sources: Int)
    /// The session refused to start because this launch had no catalogue to acquire from.
    case noCatalogue

    var diagnostic: String {
        switch self {
        case .notStarted: return "session=none"
        case .acquiring(let sources): return "session=acquiring(sources=\(sources))"
        case .noCatalogue: return "session=no-catalogue"
        }
    }
}

/// The page the screen draws in a launch whose runtime owns acquisition (plan §17: the feed UI receives
/// exclusively the session boundary's snapshots and intents).
///
/// It answers the three questions the screen used to ask the legacy loader — which phase the feed is
/// in, whether there is a page to draw, and which empty surface to show — from the session's own
/// publication. It has no access to `FeedLoader` by construction: the store keeps running in this mode
/// (hydration, filters, taxonomy, the cached page) and it is still the page for every selection the
/// session's plan was not built for, but it is not *this* surface's source of truth.
enum MainFeedSessionSurface: Equatable {
    /// The session has not published a snapshot yet: the screen shows the preparing surface.
    case preparing
    /// The session published an edition with cards: the screen draws the snapshot's rows.
    case content
    /// The session published an edition with no cards — or refused to start because this launch had no
    /// catalogue at all — and the screen draws the empty surface in the variant the runtime can state.
    case empty(FeedEmptyMode)

    /// The state one session's publication states.
    ///
    /// There is no `FeedLoader` in this function, and that is the property this slice exists to keep:
    /// the answer cannot be the legacy page's phase, its item count or its filters.
    static func forSession(
        snapshot: FeedPresentationSnapshot?,
        state: MainFeedSessionState
    ) -> MainFeedSessionSurface {
        switch state {
        case .noCatalogue:
            // Nothing to acquire from is a definitive answer, not a wait: the legacy store has no
            // sources either, and the reader is shown the surface that says so.
            return .empty(.noSourcesEnabled)
        case .notStarted, .acquiring:
            guard let snapshot else { return .preparing }
            return snapshot.cards.isEmpty ? .empty(.generic) : .content
        }
    }
}

/// What the loading surface says on a launch whose runtime owns acquisition (plan §17, DoD2).
///
/// The legacy loading chrome reads the startup runway's counters — how many source fetches the *legacy*
/// engine has completed against its own target — and in the acquiring mode that engine's requests are
/// refused by the gate (`baseline.md` §8.26), so the number it showed was not this launch's acquisition
/// at all. This is the runtime's own statement instead.
///
/// There is no fraction in it, and that is the point: the legacy chrome filled a bar and printed
/// `Int(progressFraction * 100)%`, and the runtime has no measurement for "how much of the feed is
/// loaded". Plan §16's rule is that no figure is stated without one (`sem inventar números "aprovados"`),
/// so the surface states what the session did — the catalogue it is acquiring from and how many sources
/// the acquisition owner took on — rather than a percentage.
enum MainFeedLoadingStatement: Equatable {
    /// The catalogue has not been read yet, so the session states nothing about sources: the launch is
    /// in its bootstrap (OPML, taxonomy, the first page) and the acquisition owner has not been given
    /// anything to watch.
    case readingCatalogue
    /// The session is acquiring: `catalogueSources` sources were offered to the acquisition owner, which
    /// took on `watched` of them.
    case acquiring(catalogueSources: Int, watched: WatchedSources)
    /// Nothing to acquire from: this launch had no catalogue. The screen draws the empty surface for it
    /// (`MainFeedSessionSurface.empty(.noSourcesEnabled)`), never this one; the case exists so the
    /// mapping is total and so a surface that ever did draw it could not fall into the legacy lane.
    case noCatalogue

    /// The acquisition owner's own watch report in the surface's terms: how many of the catalogue's
    /// sources this launch watches, and how many of them no target could be composed for
    /// (`V2AcquisitionReport.watched` / `.refused`, `V2Acquisition.launchWindow`).
    struct WatchedSources: Equatable {
        let count: Int
        let refused: Int
    }

    /// The statement one session's state and the acquisition owner's watch report produce.
    ///
    /// There is no `FeedLoader` in this function, the same way there is none in
    /// `MainFeedSessionSurface.forSession`: the answer cannot be the legacy runway's counters. The
    /// report is nil in exactly one combination — a session that has not reached the owner — and that
    /// combination is `.readingCatalogue`'s, because the runtime writes the state and the report in the
    /// same turn (`MainFeedRuntime.startSession`).
    static func forSession(
        state: MainFeedSessionState,
        report: V2AcquisitionReport?
    ) -> MainFeedLoadingStatement {
        switch state {
        case .notStarted:
            return .readingCatalogue
        case .noCatalogue:
            return .noCatalogue
        case .acquiring(let sources):
            return .acquiring(
                catalogueSources: sources,
                watched: WatchedSources(
                    count: report?.watched ?? 0,
                    refused: report?.refused.count ?? 0
                )
            )
        }
    }
}

/// What the empty surface says on a launch whose runtime owns acquisition (plan §17, DoD2).
///
/// The legacy empty surface read six pieces of the legacy loader — the loading state, the source count,
/// the fetch error count, the total fetched, whether its page has any source at all and how many of them
/// are disabled — to choose between its variants and to fill their figures. On the surface a launch's
/// runtime owns, none of them describe this launch: in the acquiring mode the legacy engine's requests
/// are refused by the gate (`baseline.md` §8.26), so its error and fetch figures count an acquisition
/// that never happens, and the page it holds for this selection is the cached one.
///
/// This is the runtime's own statement instead, and it has no `FeedLoader` in it. It carries the empty
/// variant the session can state and, where the legacy wording stated a source count, the session's own
/// acquisition statement — which is `MainFeedLoadingStatement`, the loading surface's own value, so the
/// two surfaces on one launch cannot state its acquisition differently.
struct FeedEmptyStatement: Equatable {
    /// The empty variant. `MainFeedSessionSurface.empty` produces `.generic` (a published edition with
    /// no cards) and `.noSourcesEnabled` (nothing to acquire from) — never the legacy page's `.fetching`
    /// or `.noResults`, which are that page's filters' answers and not the session's.
    let mode: FeedEmptyMode
    /// The acquisition this launch states, as the loading surface states it too. No legacy counter is in
    /// it: the figures are the catalogue the session was offered and how many sources the acquisition
    /// owner took on.
    let acquisition: MainFeedLoadingStatement

    /// The statement one session's surface and acquisition state produce.
    ///
    /// There is no `FeedLoader` here, the same way there is none in `MainFeedSessionSurface.forSession`:
    /// the answer cannot be the legacy page's loading state or its source count.
    static func forSession(
        surface: MainFeedSessionSurface,
        state: MainFeedSessionState,
        report: V2AcquisitionReport?
    ) -> FeedEmptyStatement? {
        guard case .empty(let mode) = surface else { return nil }
        return FeedEmptyStatement(
            mode: mode,
            acquisition: MainFeedLoadingStatement.forSession(state: state, report: report)
        )
    }
}

/// The Main Feed's runtime for one launch (plan §13, §14 PR-13).
///
/// It owns three things and delegates the rest:
///
/// * **the mode decision** — resolved once, at launch, through `RuntimeModeLaunch`, with the reason for
///   any fallback logged. Nothing here re-resolves it: a request written after launch takes effect on
///   the next launch, because a live transfer between modes does not exist yet;
/// * **the composition it authorizes** — the shadow is installed only when the resolved mode says so,
///   so a legacy launch (which the test host also performs) leaves `ShadowMirrorRegistry` empty;
/// * **the screen's observations and intents** — the viewport, a card's visibility, an opening, a
///   bookmark and a refresh travel as small values. In a V2 mode they go through `FeedScreenStore`;
///   effects are still legacy, which is what "acquisition stays legacy" means in this slice.
///
/// It also states which page the screen draws: the session's surface for the selection its plan was
/// built for (`sessionSurface`), the legacy page for every other selection and every other mode.
@MainActor
@Observable
final class MainFeedRuntime {
    let decision: RuntimeLaunchDecision
    /// Nil when composing the launch's mode failed; the reason is in `compositionFailure`.
    let composition: RuntimeCompositionRoot?
    let presentation: MainFeedPresentation
    /// The per-surface plans and the materialization identities every surface is given.
    ///
    /// The runtime owns it so the screen, the presentation and a card's action all read the same
    /// context: a card presented under one surface's identity cannot execute against another's.
    let surfaceContexts: SurfaceContextAdapters
    /// Why the composition is absent, when it is.
    let compositionFailure: String?

    /// True when this launch renders the feed from V2 snapshots instead of the legacy page.
    var presentsFromV2: Bool { decision.mode.usesV2Presentation }
    /// True when the shadow is installed in this process.
    var runsShadow: Bool { composition != nil && decision.mode.runsShadow }
    /// True when this launch's runtime owns acquisition, so no legacy producer may issue a request.
    var ownsAcquisition: Bool { composition?.full != nil }
    /// What the session did when this launch started it, when this launch has one.
    private(set) var sessionState: MainFeedSessionState = .notStarted
    /// The acquisition owner's own watch report, as this runtime took it when the session started.
    ///
    /// It is the screen's copy of `V2FullRuntime.report`, taken in the one callback where the runtime
    /// states it (`V2FullRuntime.start(onWatched:)`), because the acquiring runtime is not observable and
    /// a read taken any later would be a read after the first publication — the loading surface the copy
    /// exists for is gone by then.
    private(set) var acquisitionReport: V2AcquisitionReport?
    /// The session's own counters, when this launch has one, for the diagnostics line.
    var sessionDiagnostics: String { sessionState.diagnostic }

    /// What the loading surface says, when the screen is on the surface the session owns and the session
    /// has not published yet.
    ///
    /// Nil everywhere else — every mode that composes no acquiring runtime, and every selection this
    /// launch's session was not built for — and then the loading chrome reads the startup runway exactly
    /// as it did before this entry point existed. `v2Presentation` included: a store in the path is not a
    /// session that owns a surface.
    var sessionLoadingStatement: MainFeedLoadingStatement? {
        guard sessionSurface == .preparing else { return nil }
        return MainFeedLoadingStatement.forSession(state: sessionState, report: acquisitionReport)
    }

    /// What the empty surface says, when the screen is on the surface the session owns and the session
    /// states an empty page.
    ///
    /// Nil everywhere else — every mode that composes no acquiring runtime, and every selection this
    /// launch's session was not built for — and then the empty surface reads the legacy loader exactly as
    /// it did before this entry point existed. The guard is `sessionSurface`, the same value the loading
    /// statement is guarded by: the lane is selected by that value and never by a mode string.
    var sessionEmptyStatement: FeedEmptyStatement? {
        guard let surface = sessionSurface else { return nil }
        return FeedEmptyStatement.forSession(
            surface: surface,
            state: sessionState,
            report: acquisitionReport
        )
    }

    /// What the header chip states, when the screen is on the surface the session owns.
    ///
    /// The chip is drawn for the whole screen rather than for one of its content branches, so unlike the
    /// loading chrome it is the session's in **every** state of that surface — preparing, content and
    /// empty — and its guard is the surface itself rather than `sessionLoadingStatement`'s
    /// `sessionSurface == .preparing`. Nil everywhere else — every mode that composes no acquiring
    /// runtime, and every selection this launch's session was not built for — and then the chip reads the
    /// legacy startup runway exactly as it did before this entry point existed.
    ///
    /// The statement is `MainFeedLoadingStatement`, the loading surface's own value: the chip, the loading
    /// chrome and the empty surface of one launch state its acquisition in one sentence.
    var sessionChipStatement: MainFeedLoadingStatement? {
        guard sessionSurface != nil else { return nil }
        return MainFeedLoadingStatement.forSession(state: sessionState, report: acquisitionReport)
    }

    /// The page the screen draws in a launch whose runtime owns acquisition, or nil when the screen
    /// draws the legacy page.
    ///
    /// Nil is the answer in two cases, and they are different things: every mode that composes no
    /// acquiring runtime; and the acquiring mode on a selection its plan was not built for (a bookmark
    /// box, a Smart Feed, a collection — those keep their own legacy page, which the store still holds).
    ///
    /// Before the screen attaches, `pageSource` is `.none` and the launch's own facts answer instead. A
    /// runtime that owns acquisition claims the selection its plan is built for as the first thing
    /// `attach` does, and that plan comes from the loader's selectors as the reader has them — so the
    /// first frame is already that surface's, stating that nothing has been published. Answering `nil`
    /// there was the one place this screen still painted the legacy startup runway on the session's
    /// surface: 7.3 ms of every `v2Full` launch, measured by the loading-surface slice
    /// (`loading-progress-report.md` §4, §7).
    var sessionSurface: MainFeedSessionSurface? {
        switch presentation.pageSource {
        case .legacyPage:
            return nil
        case .sessionSnapshot:
            return MainFeedSessionSurface.forSession(
                snapshot: presentation.snapshot,
                state: sessionState
            )
        case .none:
            guard ownsAcquisition else { return nil }
            return MainFeedSessionSurface.forSession(snapshot: nil, state: sessionState)
        }
    }

    private weak var loader: FeedLoader?
    /// Schedules replenishment for one viewport observation.
    ///
    /// Production routes it to the legacy store, which owns acquisition in every mode this build ships;
    /// the seam exists so the trigger itself is observable without publishing a page (a real
    /// publication writes the process-wide page cache — `docs/runtime-v2/baseline.md` §8.3).
    private var replenishHandler: (@MainActor (_ lastVisibleOrdinal: Int, _ publishedOrdinalCount: Int) async -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var lastCenterCardID: PublicationCardID?
    private var centerCrossingCount = 0
    private var cardVisibilityCount = 0
    /// How many opens this launch routed to the session's durable read path. `0` on a page the session
    /// does not own, where the open is the legacy store's own write (see `handle(.opened)`).
    private var sessionReadIntents = 0

    private init(
        decision: RuntimeLaunchDecision,
        composition: RuntimeCompositionRoot?,
        compositionFailure: String?,
        router: MainFeedIntentRouter,
        presentation: MainFeedPresentation? = nil,
        surfaceContexts: SurfaceContextAdapters = SurfaceContextAdapters()
    ) {
        self.decision = decision
        self.composition = composition
        self.compositionFailure = compositionFailure
        self.surfaceContexts = surfaceContexts
        // The store exists exactly when the mode puts V2 presentation in front of the user. In legacy
        // there is no store, no snapshot and no intent path: the legacy page stays the only owner.
        let store = decision.mode.usesV2Presentation
            ? FeedScreenStore(intentHandler: { intent in router.send(intent) })
            : nil
        self.presentation = presentation ?? MainFeedPresentation(store: store, contexts: surfaceContexts)
        router.connect { [weak self] intent in self?.handle(intent) }
    }

    /// Builds a runtime around an already-built presentation.
    ///
    /// Only for tests that exercise the observation and intent path: production always goes through
    /// `launch`, which is the one place the mode is decided.
    /// - Parameter router: the same router the caller gave to its `FeedScreenStore`, so intents the
    ///   store forwards arrive here.
    static func testing(
        router: MainFeedIntentRouter,
        presentation: MainFeedPresentation,
        replenisher: @escaping @MainActor (Int, Int) async -> Void
    ) -> MainFeedRuntime {
        let runtime = MainFeedRuntime(
            decision: RuntimeModeLaunch.current(in: UserDefaults(suiteName: "com.feedmine.tests.none") ?? .standard),
            composition: nil,
            compositionFailure: nil,
            router: router,
            presentation: presentation
        )
        runtime.replenishHandler = replenisher
        return runtime
    }

    /// Decides the mode, composes what it authorizes and logs what it decided.
    static func launch(
        applicationSupportDirectory: URL = MainFeedRuntime.defaultApplicationSupportDirectory,
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> MainFeedRuntime {
        let decision = RuntimeModeLaunch.decide(in: defaults, arguments: arguments)
        let router = MainFeedIntentRouter()

        var composition: RuntimeCompositionRoot?
        var failure: String?
        do {
            composition = try RuntimeCompositionRoot.compose(
                decision: decision,
                applicationSupportDirectory: applicationSupportDirectory
            )
        } catch {
            failure = "runtime-v2 composition failed: \(error.localizedDescription)"
        }

        let runtime = MainFeedRuntime(
            decision: decision,
            composition: composition,
            compositionFailure: failure,
            router: router
        )
        if decision.mode.runsShadow, let composition {
            composition.installMirrorSink()
            composition.startDraining()
        }
        // The one place the mode takes effect on the legacy producers (plan §13). It is installed here
        // and not in `RuntimeCompositionRoot.compose` because composition is also what a test drives
        // directly, and a process-wide gate installed by a test's composition would leak into every
        // other test in the same process. `stop()` reopens it.
        if decision.mode.ownsAcquisition {
            LegacyAcquisitionGate.close()
        }
        Log.feed.info("\(runtime.diagnostics)")
        return runtime
    }

    var diagnostics: String {
        let source = presentation.store == nil ? "legacy" : "v2-snapshots"
        var line = "\(decision.diagnostic) presentation=\(source)"
        if let compositionFailure { line += " composition-failed=\(compositionFailure)" }
        if let composition, case .legacyOnly(let reason) = composition.outcome {
            line += " composed=legacy-only(\(reason))"
        }
        if let composition, case .fullComposed(let directory) = composition.outcome {
            line += " composed=full(directory=\(directory.lastPathComponent))"
        }
        line += " center-crossings=\(centerCrossingCount) visibility-samples=\(cardVisibilityCount)"
        line += " read-intents=\(sessionReadIntents)"
        line += " rejected-snapshots=\(presentation.rejectedSnapshotCount)"
        // The gate's own observable: how many legacy requests the mode refused. A launch whose runtime
        // owns acquisition that reports zero refusals either issued no legacy demand at all or was not
        // gated, and the two must be distinguishable from the log.
        line += " legacy-gate=\(LegacyAcquisitionGate.isClosed ? "closed" : "open")"
        line += " legacy-requests-refused=\(LegacyAcquisitionGate.refusedRequestCount)"
        return line
    }

    // MARK: - Lifetime

    /// Follows the loader whose page this screen renders. Called once the app has its loader.
    ///
    /// In a mode whose runtime owns acquisition, the screen does **not** follow the legacy page for the
    /// selection the session's plan was built for: it follows the session. The legacy store keeps running
    /// — hydration, filters, taxonomy, the cached page — and it keeps its own pages, so every other
    /// selection (a bookmark box, a Smart Feed, a collection) still draws its own content from it while
    /// its fetches are refused by the gate.
    func attach(loader: FeedLoader) {
        self.loader = loader
        replenishHandler = { [weak self] lastVisibleOrdinal, publishedOrdinalCount in
            guard let self else { return }
            if self.ownsAcquisition {
                await self.replenishFromSession()
            } else {
                await loader.loadMoreIfNeeded(
                    viewportLastVisibleOrdinal: lastVisibleOrdinal,
                    publishedOrdinalCount: publishedOrdinalCount
                )
            }
        }
        guard let full = composition?.full else {
            presentation.attach(loader)
            return
        }
        // The session's plan is built from the loader's own selectors, so the selection it owns is known
        // before the catalogue arrives — and it is claimed before the legacy page is followed, or the
        // cached page would be materialized for a surface the session is about to own.
        let surface = surfaceContexts.mainFeed(loader: loader)
        claimedSelection = surface.contextKeyText
        claimedSelectionWasBox = loader.selectedBookmarkListID != nil
        presentation.onSelectionChanged = { [weak self] contextKey in
            self?.adoptSelectionIfNeeded(contextKey)
        }
        // The launch's own selection is the session's from the start, so the session's surface says "not
        // yet" rather than materializing the cached legacy page it is about to replace. A box the reader
        // has *opened* is not that: it is a selection whose legacy page is already theirs, and an attach
        // that runs again while it is open (the box picker's own sheet dismissing re-runs it, measured
        // 2026-09-18 - baseline §8.62) must not take that page away before the session can replace it.
        presentation.beginSession(
            contextKey: surface.contextKeyText,
            drawingLegacyUntilSnapshot: loader.selectedBookmarkListID != nil
        )
        presentation.attach(loader)
        startSession(full: full, surface: surface, loader: loader)
    }

    /// The selection the session currently owns, mirrored here because this is what decides whether a
    /// move is one the runtime serves.
    private var claimedSelection: String?
    /// Whether the claim above is a bookmark box, so closing one adopts the unboxed feed back.
    private var claimedSelectionWasBox = false

    /// The source set the launch registered, reused by every session the runtime adopts.
    ///
    /// `V2Acquisition.watch` *replaces* the one catalogue the runtime's acquisition actor holds, so a
    /// session that watched a narrower set would shrink the launch's acquisition for good (baseline §8.62:
    /// a bookmark box's session registered 1 target over the launch's 32). The launch's set is stated once,
    /// from the loader's catalogue load, and every later session states the same one.
    private var launchDescriptors: [V2AcquisitionSourceDescriptor]?

    /// Adopts a selection the reader moved to, when its cards are ones the runtime can compose.
    ///
    /// The presentation reports every move off the session's selection and this decides. A bookmark box is
    /// a selection whose cards are the reader's saved subjects, filed in that list — the runtime can state
    /// and resolve exactly that (baseline §8.59, §8.60) — so the box gets a session of its own. A *preset*
    /// move does not: a Smart Feed's, a collection's or the click history's cards are legacy rows, and a
    /// session for one would compose the canonical supply under a title that promised those rows. That is
    /// also why closing a box adopts the unboxed feed back rather than nothing: the session follows the
    /// reader instead of being left behind on the box they dismissed.
    private func adoptSelectionIfNeeded(_ contextKey: String) {
        guard ownsAcquisition, let full = composition?.full, let loader else { return }
        guard contextKey != claimedSelection else { return }
        let box = loader.selectedBookmarkListID
        guard box != nil || claimedSelectionWasBox else { return }
        let surface = surfaceContexts.mainFeed(loader: loader)
        claimedSelection = surface.contextKeyText
        claimedSelectionWasBox = box != nil
        presentation.beginSession(contextKey: surface.contextKeyText, drawingLegacyUntilSnapshot: true)
        startSession(full: full, surface: surface, loader: loader)
    }

    /// Composes the launch's session and starts following its snapshots.
    ///
    /// The plan comes from the loader's own selectors (`SurfaceContextAdapters`), which is why this is
    /// where the session is built rather than at launch: a plan that named no context would be a plan
    /// for no screen.
    private func startSession(full: V2FullRuntime, surface: FeedSurfaceContext, loader: FeedLoader) {
        // The mode's read path for local content search (plan §14 PR-14 clause two): a launch whose
        // runtime owns acquisition searches the index Admission fills, and the two are installed
        // together so the search cannot read an index this mode does not write. `stop()` removes it
        // again, the way it reopens the gate.
        loader.useCanonicalContentSearch(
            CanonicalContentSearch(database: full.database, registry: loader.sourceRegistry)
        )
        sessionTask?.cancel()
        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A session that was already running belongs to the selection the reader has left. Its
            // intervals flush, its tasks are cancelled and its pins are released (plan §11) before the
            // next one opens; on the first start there is nothing to end, which is why this needs no
            // guard of its own.
            await full.teardown()
            // The catalogue first. `attach` runs before `loader.start()` — the screen attaches its
            // runtime and only then starts the loader — and the sources arrive with the OPML load,
            // which is the slow part of bootstrap. A session started at attach time states a plan with
            // no sources, registers no acquisition target, and delivers an empty first edition; that is
            // exactly what a simulator launch showed (an edition and zero `acquisition_target` rows,
            // 35 s before `progressiveFetch starting`).
            // The launch's source set is the launch's. A session the runtime *adopts* must not re-register
            // the catalogue from whatever the loader's enabled set happens to be at that moment: the
            // acquisition actor holds one catalogue for the runtime (`V2Acquisition.watch` replaces it), so
            // a box's session registered 1 target over the launch's 32 and every later episode - the Main
            // Feed's included - ran against that one (measured 2026-09-18, baseline §8.62: `catalogue=1`
            // in the box's cold episode, where the launch's own episodes read `catalogue=32`).
            let descriptors: [V2AcquisitionSourceDescriptor]
            if let launchDescriptors {
                descriptors = launchDescriptors
            } else {
                let sources = await self.catalogue(loader)
                guard !sources.isEmpty else {
                    self.sessionState = .noCatalogue
                    Log.feed.error("runtime-v2 v2Full: no catalogue sources to acquire from; the session is not started")
                    return
                }
                descriptors = V2AcquisitionSourceDescriptor.descriptors(for: sources)
                self.launchDescriptors = descriptors
            }
            await full.start(
                plan: surface,
                descriptors: descriptors,
                renderEnvironment: MainFeedPresentation.renderEnvironment(),
                userActions: Self.durableUserActions(full: full, loader: loader),
                onWatched: { [weak self] report in
                    guard let self else { return }
                    // Together, in one turn: the state and the report the loading surface's statement is
                    // built from. A state that arrived without its report would make the surface state a
                    // watch that has not happened (see `MainFeedLoadingStatement.forSession`).
                    self.acquisitionReport = report
                    self.sessionState = .acquiring(sources: descriptors.count)
                },
                onSnapshot: { [weak self] snapshot in
                    self?.presentation.applySnapshot(snapshot)
                }
            )
            // A session the runtime *adopts* composes on its own: opening one whose context has no stored
            // edition asks the reducer for a `.cold` composition, and one whose context has one restores
            // it (`FeedSession.start` -> `.opened` -> `.restore`). What was measured here on 2026-09-18
            // (baseline §8.62) is that an *extra* refresh is worse than useless on a bookmark box: a
            // successor edition composes under the repetition policy and excludes the cards the box has
            // already presented - which is the whole saved set - so `decision=empty` replaced the box's
            // four cards with none. The refresh the Main Feed gets from its viewport is not a mechanism a
            // local selection wants.
        }
    }

    /// The app's durable user-state port for a runtime card: the two databases a bookmark has to be
    /// readable in, and the runtime that projects it.
    ///
    /// It is built here rather than at launch because both halves need the loader's own store — the
    /// legacy `BookmarkStore` owns `user.sqlite` and the content database, and neither exists before the
    /// loader does. The plan requires that a bookmark taken on a runtime card stay readable through the
    /// app's own bookmark surface *and* be hydratable by the legacy reader after a rollback (ADR-004 D6,
    /// D12; `rollout.md` §6), so both databases are handed to the port instead of the runtime inventing
    /// an identity of its own.
    @MainActor
    private static func durableUserActions(
        full: V2FullRuntime,
        loader: FeedLoader
    ) -> RuntimeCardUserActions {
        let bookmarks = loader.bookmarkStore
        let bridge = UserStateBridge(
            bookmarks: bookmarks,
            projections: UserStateProjectionStore(database: full.database)
        )
        // The launch pass for the list membership. It is fired here, at the one moment the bridge and
        // the loader exist together, and it is fire-and-forget because nothing waits on it: a box that
        // opens before the pass finishes shows what the save path wrote, and the pass makes it whole.
        // The whole-set `reconcile()` is *not* wired: it has no caller today, which §8.60 records.
        Task { @MainActor in
            _ = await bridge.reconcileListMemberships()
        }
        return RuntimeCardUserActions(
            cards: full.repository,
            userState: bridge,
            legacy: LegacyContentProjection(
                bookmarks: bookmarks,
                mappings: LegacyMappingStore(),
                database: full.database
            )
        )
    }

    /// Waits until the loader has a catalogue, bounded and cancellable.
    ///
    /// Polling is deliberate here and is not the page's rule: the page waits on `withObservationTracking`
    /// because it must not take a second copy of a value that changes under it, while this waits for a
    /// *precondition* — "the catalogue exists" — that is monotone (a load fills it and nothing empties it
    /// mid-launch). The interval is coarse because the wait is on the order of the OPML load, and the
    /// deadline is what keeps a launch that never loads a catalogue from hanging on a spinning task.
    private func catalogue(_ loader: FeedLoader, within timeout: Duration = .seconds(30)) async -> [FeedSource] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let sources = loader.enabledSources
            if !sources.isEmpty { return sources }
            if Task.isCancelled { return [] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return loader.enabledSources
    }

    /// The session's reply to a viewport observation: the composition runs again through the plan's own
    /// acquisition step, so replenishment is a demand rather than a second owner.
    private func replenishFromSession() async {
        await composition?.full?.refresh()
    }

    private var sessionTask: Task<Void, Never>?

    /// Releases the mode's process-wide state: the mirror sink and the drain loop.
    ///
    /// Production has no caller yet — the process is the lifetime — and tests use it to leave the
    /// registry as they found it.
    func stop() {
        composition?.removeMirrorSink()
        composition?.stopDraining()
        sessionTask?.cancel()
        // The mode's process-wide state goes back the way it was found: the mirror sink, the drain
        // loop and the acquisition gate. Production never calls this (the process is the lifetime);
        // tests do, and a closed gate left behind would refuse the next test's legacy fetches.
        LegacyAcquisitionGate.open()
        // The mode's search read path goes back too: a store left pointing at a runtime database the
        // next launch does not compose would search an index nothing writes.
        loader?.useCanonicalContentSearch(nil)
        presentation.detach()
        refreshTask?.cancel()
    }

    // MARK: - Observations

    /// One viewport observation from the scroll surface.
    ///
    /// It carries identities, not pixels and not work: the ordinals are dictionary hits and the
    /// callback starts no selection, no fetch and no decode (ADR-007 H-16).
    ///
    /// In a launch whose runtime owns acquisition the reader may be on a selection the session's plan
    /// was not built for; those rows are the legacy page's, their ordinals are that page's own, and they
    /// mean nothing in the session's window — so the session is not told where the reader is on a page it
    /// does not own.
    func viewportChanged(visibleItemIDs: [String]) {
        if ownsAcquisition, presentation.pageSource != .sessionSnapshot { return }
        var first: (id: String, ordinal: Int)?
        var last: (id: String, ordinal: Int)?
        for id in visibleItemIDs {
            guard let ordinal = presentation.ordinalByItemID[id] else { continue }
            if first == nil || ordinal < first!.ordinal { first = (id, ordinal) }
            if last == nil || ordinal > last!.ordinal { last = (id, ordinal) }
        }
        guard let first, let last else { return }

        let anchor = presentation.viewportAnchor(firstVisibleItemID: first.id)
        let sent = presentation.sendViewport(
            firstVisibleOrdinal: first.ordinal,
            lastVisibleOrdinal: last.ordinal,
            anchor: anchor
        )
        if !sent {
            replenish(lastVisibleOrdinal: last.ordinal)
        }
        reportCenterCrossing(firstVisibleOrdinal: first.ordinal, lastVisibleOrdinal: last.ordinal)
    }

    /// The fraction a card must be visible for this screen to report it.
    ///
    /// `onScrollVisibilityChange` fires with a Bool: the view knows a row crossed a threshold, and
    /// nothing about how much of it was on screen. This is that threshold, and it is the policy's own
    /// `minVisibleFraction`, so the observation below states the bound the view actually crossed instead
    /// of inventing a fraction — the screen passes this number as its scroll threshold, and the number
    /// the callback fires under and the number the observation declares are one by construction.
    static let cardVisibilityThreshold = ExposurePolicy.baseline.minVisibleFraction

    /// One row becoming visible, from the per-card visibility callback (ADR-007 D2).
    ///
    /// The callback fires on a transition, so the one thing it can state about a card is that it crossed
    /// the threshold and is now at least `cardVisibilityThreshold` visible. The observation carries
    /// exactly that: `edge: .entered`, the contract's own name for the crossing, and the declared bound
    /// as the fraction — never a measurement the renderer does not have. It is telemetry and not a
    /// request: it selects nothing, fetches nothing and decodes nothing, and no work is done in the
    /// callback (ADR-007 H-16). A row that merely re-renders reports nothing, because the callback is
    /// about a transition; a repeat that does arrive is a sample the tracker coalesces at its own window.
    ///
    /// The session is told only about the page it owns, and that page is decided the way the viewport
    /// observation decides it: a runtime row's item id is the display id the bridge synthesizes
    /// (`card:<card id>`), which names no `feed_item` row, so the legacy read-state write is meaningful
    /// only on a page whose rows are the legacy store's own. On every other selection, and in every other
    /// mode, that call is the one that runs — the same call, with the same id, that the screen made
    /// before this entry point existed.
    func cardBecameVisible(itemID: String) {
        if presentation.pageSource == .sessionSnapshot, let card = presentation.cardByItemID[itemID] {
            // Both halves of the observation are validated values: the policy's own `minVisibleFraction`
            // and a direction this statement does not carry (it is not a movement across the viewport).
            if let observation = try? ViewportObservation(
                cardID: card.id,
                visibleFraction: Self.cardVisibilityThreshold,
                edge: .entered
            ) {
                presentation.send(.cardVisibility(observation))
            }
            return
        }
        loader?.markAsSeen(itemID)
    }

    // MARK: - Intents

    func opened(itemID: String) {
        guard let card = presentation.cardByItemID[itemID] else {
            loader?.markAsClicked(itemID)
            return
        }
        // The operation id is the app's, minted here like the bookmark's: the `read` fact is keyed by
        // the durable operation that owns it, and the port confirms under this same id (ADR-007 D7).
        let intent = FeedSessionIntent.opened(
            cardID: card.id,
            operationID: UUID().uuidString
        )
        if presentation.send(intent) { return }
        loader?.markAsClicked(itemID)
    }

    func toggleBookmark(itemID: String) {
        guard let card = presentation.cardByItemID[itemID] else {
            loader?.toggleBookmark(itemID)
            return
        }
        let wanted = !card.isBookmarked
        let intent = FeedSessionIntent.toggleBookmark(
            cardID: card.id,
            wanted: wanted,
            operationID: UUID().uuidString
        )
        if presentation.send(intent) { return }
        loader?.toggleBookmark(itemID)
    }

    /// Reloads the page. The intent path owns the effect when there is one.
    func refresh() async {
        if presentation.send(.refresh) {
            await refreshTask?.value
            return
        }
        await loader?.pullToRefresh()
    }

    // MARK: - Intent effects

    private func handle(_ intent: FeedSessionIntent) {
        switch intent {
        case .viewportChanged(_, let lastVisibleOrdinal, _):
            replenish(lastVisibleOrdinal: lastVisibleOrdinal)
        case .centerCrossed:
            centerCrossingCount += 1
        case .cardVisibility(let observation):
            cardVisibilityCount += 1
            // The intent's effect is the session's: exposure is its own record of the cards it showed
            // (ADR-007 D1/D6), and the tracker there owns the coalescing, the dwell and every fact that
            // results. A launch that owns no acquisition has no session to record it, and the count above
            // is then the whole of what it does — the observation is dropped by being handed to no one,
            // never written by a second owner.
            guard ownsAcquisition else { return }
            Task { [weak self] in
                await self?.composition?.full?.trackExposure(observation)
            }
        case .opened(let cardID, let operationID):
            // The page decides, exactly as it does for a card's visibility: on the surface the session
            // owns, the open is the session's durable read (mirroring the bookmark), and the display id
            // the presentation synthesizes (`card:<card id>`) — which names no `feed_item` row — never
            // reaches the legacy read state. On every other page and in every other mode the legacy call
            // runs verbatim, with the id that page's own rows carry: a legacy row's open still writes
            // `feed_item.is_read`, in the acquiring mode included, because that page is that store's.
            guard presentation.pageSource == .sessionSnapshot else {
                guard let itemID = presentation.itemIDByCardID[cardID] else { return }
                loader?.markAsClicked(itemID)
                return
            }
            // A launch that composes no acquiring runtime has no session to receive it: the intent is
            // dropped by being handed to no one, never written by a second owner.
            guard ownsAcquisition else { return }
            sessionReadIntents += 1
            Task { [weak self] in
                await self?.composition?.full?.markRead(cardID: cardID, operationID: operationID)
            }
        case .toggleBookmark(let cardID, let wanted, let operationID):
            // A mode whose runtime owns acquisition owns the durable bookmark too. The legacy store keys a
            // bookmark to the item id the *presentation* holds, and for a runtime card that id is the
            // display id the bridge synthesized (`card:<ordinal>`): a row neither the app's own bookmark
            // surface nor a legacy relaunch can hydrate, so routing the tap there would store a bookmark
            // that is invisible everywhere. The session writes it through the app's port instead, which
            // keys it to a legacy item id and projects the content row legacy reads.
            if ownsAcquisition {
                Task { [weak self] in
                    await self?.composition?.full?.setBookmarked(
                        cardID: cardID,
                        wanted: wanted,
                        operationID: operationID
                    )
                }
                return
            }
            guard let itemID = presentation.itemIDByCardID[cardID] else { return }
            loader?.toggleBookmark(itemID)
        case .refresh:
            // A mode whose runtime owns acquisition refreshes through the session: the legacy store's
            // pull-to-refresh would be a second owner asking for the same bytes (and is refused by the
            // gate anyway, so routing it there would produce a refresh that does nothing).
            refreshTask = Task { [weak self] in
                guard let self else { return }
                if self.ownsAcquisition {
                    await self.composition?.full?.refresh()
                } else {
                    await self.loader?.pullToRefresh()
                }
            }
        case .switchContext(let key):
            Log.feed.info("runtime-v2 context switch requested: \(key.canonicalSerialization)")
        }
    }

    /// Replenishment is scheduled asynchronously, never awaited by the scroll callback: the viewport
    /// reports where the reader is, the runtime decides what that costs (plan §11).
    private func replenish(lastVisibleOrdinal: Int) {
        guard let replenishHandler else { return }
        let ordinalCount = presentation.ordinalCount
        Task {
            await replenishHandler(lastVisibleOrdinal, ordinalCount)
        }
    }

    /// Center crossing is a weaker fact than dwell and is reported on both edges (ADR-007 D5).
    ///
    /// The middle of the visible set is the card at the viewport center for a single-column feed,
    /// which is the only shape this surface renders.
    private func reportCenterCrossing(firstVisibleOrdinal: Int, lastVisibleOrdinal: Int) {
        let middle = (firstVisibleOrdinal + lastVisibleOrdinal) / 2
        guard let itemID = presentation.itemIDByOrdinal[middle],
              let card = presentation.cardByItemID[itemID]
        else { return }
        guard card.id != lastCenterCardID else { return }
        let direction = (lastCenterCardID.map { presentation.ordinalByCardID[$0] ?? 0 } ?? 0) <= middle ? 1 : -1
        lastCenterCardID = card.id
        if presentation.send(.centerCrossed(cardID: card.id, direction: direction)) { return }
        centerCrossingCount += 1
    }

    static var defaultApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
    }
}
