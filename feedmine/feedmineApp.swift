import SwiftUI
import FeedRuntime

@MainActor
final class SmartFeedBackgroundScheduler {
    static let shared = SmartFeedBackgroundScheduler()
    static let taskIdentifier = "com.feedmine.app.smart-feed-refresh"

    /// The system scheduler, injectable so the invariants this class owns — registered or not, one
    /// pending request, exactly one completion — are testable without a live `BGTaskScheduler`.
    private let backend: any BackgroundTaskRegistering
    /// The device conditions the demand's budget is derived from. A closure so a test injects signals
    /// instead of changing the device (plan §14 PR-15).
    private var conditions: @MainActor () -> AcquisitionConditions
    /// Where the task finds the process's one acquisition owner.
    ///
    /// A provider, not a reference the app hands over: a background launch can deliver the task before the
    /// app's stored properties exist (measured 2026-09-18 — every test-host launch did), and the answer
    /// must then be the same owner the foreground will use rather than nil or a second one.
    private var ownerProvider: @MainActor () -> (any BackgroundRefreshOwning)?

    private(set) var isRegistered = false
    /// True while a request is pending with BGTaskScheduler. A request carrying the identifier
    /// of a pending one replaces it rather than adding a second, so re-submitting the same work
    /// is pure churn. Cleared when the handler runs and when a submit fails.
    private var hasPendingSchedule = false
    /// Requests actually handed to BGTaskScheduler (submits that did not throw).
    private(set) var pendingScheduleCount = 0

    /// How many times registration was asked for, and what the last answer was. Registration is the
    /// one thing this slice exists to make real, so its outcome is observable rather than inferred.
    private(set) var registrationAttempts = 0
    private(set) var lastRegistrationSucceeded = false
    /// Tasks the system launched, and the completion bookkeeping the exactly-once contract rests on.
    private(set) var taskRunCount = 0
    private(set) var completionsForwarded = 0
    private(set) var completionsIgnored = 0
    private(set) var lastOutcome: BackgroundRefreshOutcome?
    /// The last demand computed, so the budget matrix is observable without a live task.
    private(set) var lastDemand: BackgroundRefreshDemand?
    /// The work of the task in flight, so a test can await the same task the system would.
    private(set) var currentTask: Task<Void, Never>?

    /// Whether a request is currently pending. This app-side flag is the only record: `BGTaskScheduler`
    /// exposes no readable pending state.
    var hasPendingRequest: Bool { hasPendingSchedule }

    init(backend: (any BackgroundTaskRegistering)? = nil) {
        self.backend = backend ?? SystemBackgroundTaskScheduler()
        self.conditions = { SystemDeviceConditions.current() }
        self.ownerProvider = { FeedLoaderProvider.shared }
    }

    /// The identifiers the bundle permits, read from `Info.plist`.
    ///
    /// Registration can only succeed when this list names `taskIdentifier`, so the list is read and
    /// logged with the outcome: a bundle that permits nothing is a silent never-runs, which is the
    /// state this PR is undoing.
    static func permittedIdentifiers(bundle: Bundle = .main) -> [String] {
        bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    /// Registers the app-refresh handler. Called once, before the app finishes launching.
    @discardableResult
    func register() -> Bool {
        guard !isRegistered else { return true }
        registrationAttempts += 1
        let registered = backend.register(identifier: Self.taskIdentifier) { [weak self] task in
            // Logged before the handler runs so a *system* delivery is distinguishable in a device log
            // from a test driving the handler directly: this closure is reached only from
            // `BGTaskScheduler`, and nothing else logs this line.
            Log.feed.info("app-refresh task delivered by the system")
            self?.handle(task)
        }
        isRegistered = registered
        lastRegistrationSucceeded = registered
        let permitted = Self.permittedIdentifiers()
        if registered {
            Log.feed.info(
                "smart-feed background refresh registered id=\(Self.taskIdentifier, privacy: .public) permitted=\(permitted.joined(separator: ","), privacy: .public)"
            )
        } else {
            Log.feed.error(
                "Could not register Smart Feed background refresh id=\(Self.taskIdentifier, privacy: .public) permitted=\(permitted.joined(separator: ","), privacy: .public)"
            )
        }
        return registered
    }

    /// Replaces the owner provider. Production uses the default (`FeedLoaderProvider.shared`); tests
    /// inject one so a demand is driven without a process-wide loader, including a nil one for the
    /// no-owner path.
    func configure(ownerProvider: @escaping @MainActor () -> (any BackgroundRefreshOwning)?) {
        self.ownerProvider = ownerProvider
    }

    /// Replaces the conditions source. Tests inject signals here instead of changing the device.
    func configure(conditions: @escaping @MainActor () -> AcquisitionConditions) {
        self.conditions = conditions
    }

    func schedule() {
        guard isRegistered else { return }
        guard !hasPendingSchedule else { return }
        do {
            try backend.submitAppRefresh(
                identifier: Self.taskIdentifier,
                earliestBeginDate: Date(timeIntervalSinceNow: 15 * 60)
            )
            hasPendingSchedule = true
            pendingScheduleCount += 1
        } catch {
            hasPendingSchedule = false
            Log.feed.warning(
                "Smart Feed background refresh was not scheduled: \(error.localizedDescription)"
            )
        }
    }

    /// Runs one launch of the background task.
    ///
    /// The three paths — success, failure, expiry — all reach the same completion object, which
    /// forwards exactly one `setTaskCompleted` between them.
    func handle(_ task: any BackgroundTaskHandle) {
        // The queued request has fired, so nothing is pending any more.
        hasPendingSchedule = false
        // Re-enqueue first so a process termination during this slice does not break the persistent
        // refresh chain.
        schedule()

        taskRunCount += 1
        let completion = BackgroundTaskCompletion { success in
            task.setTaskCompleted(success: success)
        }
        completion.onForward = { [weak self] in self?.completionsForwarded += 1 }
        completion.onIgnore = { [weak self] in self?.completionsIgnored += 1 }

        let work = Task { @MainActor [weak self] in
            guard let self else {
                completion.complete(success: false)
                return
            }
            let outcome = await self.performDemand()
            self.lastOutcome = outcome
            completion.complete(success: outcome.isSuccess)
            // Logged after the completion so the counts are the ones this run produced: a device log
            // then shows the same exactly-once contract the tests assert.
            Log.feed.info(
                "background refresh finished outcome=\(String(describing: outcome), privacy: .public) forwarded=\(self.completionsForwarded, privacy: .public) ignored=\(self.completionsIgnored, privacy: .public)"
            )
        }
        completion.onExpire = { work.cancel() }
        currentTask = work
        task.expirationHandler = {
            // The system calls this off the main actor; the expiry itself belongs to the main actor,
            // which is where the work task's cancellation is observed.
            Task { @MainActor in completion.expire() }
        }
    }

    /// The bounded demand one background refresh creates, through the common pipeline.
    private func performDemand() async -> BackgroundRefreshOutcome {
        let demand = BackgroundRefreshBudget.demand(for: conditions())
        lastDemand = demand
        guard demand.isAllowed else {
            let signals = demand.appliedSignals.map(\.rawValue).joined(separator: ",")
            Log.feed.info("background refresh skipped: acquisition not allowed (\(signals, privacy: .public))")
            return .nothingToDo(reason: "acquisition is not allowed (\(signals))")
        }
        guard let owner = ownerProvider() else {
            // No second tree. The handler used to build `loader ?? FeedLoader()`, which meant a second
            // `FeedStore`, `RSSFetcher`, OPML parse and taxonomy load for the same work the foreground
            // was doing. With no owner the task ends and says why.
            Log.feed.error("background refresh has no acquisition owner: completing without fetching")
            return .failed(reason: "no shared acquisition owner is available")
        }
        let report = await owner.runBackgroundRefresh(demand)
        return Self.outcome(for: report)
    }

    /// Maps a demand's counts to the outcome, so "cancelled before commit" and "committed then
    /// cancelled" are told apart by the store's own numbers.
    static func outcome(for report: BackgroundRefreshDemandReport) -> BackgroundRefreshOutcome {
        if report.cancelled {
            return report.committedWork
                ? .cancelledAfterCommit(sources: report.committed, newItems: report.newItems)
                : .cancelledBeforeCommit
        }
        if report.smartFeedsRefreshed > 0 {
            return .committed(sources: report.smartFeedsRefreshed, newItems: report.newItems)
        }
        if report.led == 0 && report.attempted == 0 {
            return report.shared + report.servedFresh > 0
                ? .sharedWithForeground(sources: report.shared)
                : .nothingToDo(reason: "no endpoint was eligible")
        }
        return .committed(sources: report.committed, newItems: report.newItems)
    }
}

/// The SwiftUI app. The process entry point is `FeedmineEntryPoint`, which installs the launch
/// instruments that must exist before this type's stored properties build their transports.
struct FeedmineApp: App {
    /// The process's one acquisition owner, obtained from the provider so the background task is served by
    /// the same instance the scene renders (P9). A plain `let`, not `@State`: a reference read out of an
    /// uninstalled `@State` was released before the first background task ran (measured 2026-09-18).
    private let loader = FeedLoaderProvider.shared
    @State private var localeManager = LocaleManager.shared
    @State private var circadianEngine = CircadianEngine.shared
    @State private var audioPlayer = AudioPlayerManager.shared
    @State private var contentFilters = ContentFilterStore.shared
    /// The launch's Runtime V2 decision and composition, resolved once, here (plan §13). Nothing else
    /// in the app may re-resolve the mode: a request written later applies on the next launch.
    @State private var runtime = MainFeedRuntime.launch()

    init() {
        if ProcessInfo.processInfo.arguments.contains("-UITestResetFilters") {
            resetFiltersForUITestLaunch()
        }
        if ProcessInfo.processInfo.arguments.contains("-UITestShowOnboarding") {
            UserDefaults.standard.set(false, forKey: Keys.hasSeenOnboarding)
        } else if ProcessInfo.processInfo.arguments.contains("-UITestSkipOnboarding") {
            UserDefaults.standard.set(true, forKey: Keys.hasSeenOnboarding)
        }
        // Journey-only instrument (review: ignored card tap). Off unless `-UITestTapTrace` is passed.
        TapTrace.installIfRequested(ProcessInfo.processInfo.arguments)
        // Nothing to hand the scheduler: the loader comes from the same provider the scheduler asks
        // (`FeedLoaderProvider`), so both see one instance with no wiring between them and no window in
        // which the task has no owner.
        FeedMetrics.event("Process.started")
        FeedMetrics.memory("processStarted")
    }

    /// UI cases must not inherit a taxonomy or language intersection from a
    /// previous case. This launch argument is only supplied by the UI target.
    private func resetFiltersForUITestLaunch() {
        Settings.filterRegion = nil
        Settings.filterTaxonomyNodes = []
        Settings.filterContentType = FeedLoader.ContentType.all.rawValue
        Settings.filterLanguages = []
        Settings.filterMood = FeedLoader.MoodFilter.all.rawValue
        Settings.filterSetAt = 0
        Settings.hasInitializedLanguageDefault = true
        TaxonomyStore.shared.clearSelection()
        UserDefaults.standard.synchronize()
    }

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(runtime)
                .environment(localeManager)
                .environment(circadianEngine)
                .environment(audioPlayer)
                .environment(contentFilters)
                .onOpenURL { url in handleIncomingURL(url) }
        }
    }

    /// Handle incoming URLs:
    /// - feedmine://import?url=https://... → import a feed
    /// - file:///.../*.opml → import OPML file
    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "feedmine" {
            if url.host == "source",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let feedURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
               !feedURL.isEmpty {
                // Open the Source View for this feed URL.
                // Post a notification — the active FeedScreen handles navigation.
                NotificationCenter.default.post(
                    name: .openSourceView,
                    object: nil,
                    userInfo: ["feedURL": feedURL]
                )
            } else if url.host == "import",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let feedURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
               !feedURL.isEmpty {
                Task {
                    let result = await loader.importFeeds(urls: [feedURL])
                    NotificationCenter.default.post(
                        name: .feedImportCompleted,
                        object: nil,
                        userInfo: ["message": result.importedCount > 0
                            ? "\(result.importedCount) feed\(result.importedCount == 1 ? "" : "s") imported"
                            : "Could not import feed"]
                    )
                }
            } else {
                NotificationCenter.default.post(
                    name: .feedImportCompleted,
                    object: nil,
                    userInfo: ["message": "Invalid import link"]
                )
            }
        } else if url.isFileURL {
            if url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml" {
                Task {
                    guard url.startAccessingSecurityScopedResource() else {
                        NotificationCenter.default.post(name: .feedImportCompleted, object: nil,
                            userInfo: ["message": "Could not access file"])
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let fileStore = ImportFileStore()
                    guard let data = try? await fileStore.read(url: url) else {
                        NotificationCenter.default.post(name: .feedImportCompleted, object: nil,
                            userInfo: ["message": "Could not read file"])
                        return
                    }
                    let fileName = url.deletingPathExtension().lastPathComponent
                    let result = await loader.importOPML(data: data, fileName: fileName)
                    NotificationCenter.default.post(
                        name: .feedImportCompleted,
                        object: nil,
                        userInfo: ["message": result.importedCount > 0
                            ? "\(result.importedCount) feed\(result.importedCount == 1 ? "" : "s") imported from \(fileName)"
                            : "Could not import feeds from \(fileName)"]
                    )
                }
            }
        }
    }
}

/// Journey-only touch observer, installed **only** when `-UITestTapTrace` is passed.
///
/// Why it exists: a journey run showed a card that was hittable, fully visible below the header, and still in place 20 s
/// after a synthesized tap — and the app logged no `card tap`, so the gesture never reached `FeedItemView.onTapGesture`.
/// The evidence localises the miss to event delivery but cannot say *where* it was lost: the touch may never have reached
/// the process (harness/HID) or it may have reached the window and been consumed by something above the card.
///
/// One window-level observer splits exactly that: `window tap` present with `card tap` absent means the app received the
/// touch and the card's gesture did not fire; both absent means it never arrived. The recognizer is a pure observer —
/// `cancelsTouchesInView = false` and simultaneous recognition — so the app's gesture graph behaves as if it were not
/// there. It is never installed outside a journey, so production carries no extra recognizer.
@MainActor
final class TapTrace: NSObject, UIGestureRecognizerDelegate {
    private static var installer: TapTrace?
    private static var recognizer: UITapGestureRecognizer?

    static func installIfRequested(_ arguments: [String]) {
        guard arguments.contains("-UITestTapTrace"), installer == nil else { return }
        let tracer = TapTrace()
        let tap = UITapGestureRecognizer(target: tracer, action: #selector(TapTrace.handle(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = tracer
        installer = tracer
        recognizer = tap
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { TapTrace.attach(to: window) }
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { attach(to: window) }
        }
        Log.ui.info("tap trace installed")
    }

    private static func attach(to window: UIWindow) {
        guard let recognizer, window.gestureRecognizers?.contains(recognizer) != true else { return }
        window.addGestureRecognizer(recognizer)
    }

    @objc private func handle(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: recognizer.view)
        Log.ui.info("window tap x=\(Int(point.x), privacy: .public) y=\(Int(point.y), privacy: .public)")
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
