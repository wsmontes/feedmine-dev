import Foundation

/// Typed launch configuration for FeedMine tests.
///
/// Replaces scattered `ProcessInfo.processInfo.arguments.contains(...)` checks
/// with a single source of truth parsed once at launch.
///
/// Usage in app init:
/// ```swift
/// let config = TestConfiguration.parse()
/// if config.isUITesting {
///     // Configure test-specific state
/// }
/// ```
///
/// - Important: All properties default to production-safe values.
///   The distributed app never accepts arbitrary paths or external data
///   through these arguments — only known internal fixture profiles.
struct TestConfiguration: Sendable {
    // MARK: - Modes

    /// True when UI testing is active (XCUITest harness attached).
    let isUITesting: Bool

    /// True when performance testing is active.
    let isPerformanceTesting: Bool

    // MARK: - Fixture

    /// Named fixture profile: "empty", "smoke", "typical", "heavy", "extreme",
    /// "migration", "golden-bad-data".
    let fixtureProfile: String?

    /// Deterministic seed for fixture generation. Same seed → same data.
    let fixtureSeed: Int?

    // MARK: - Persistence

    /// Persistence profile: "empty", "typical", "heavy", "migration".
    let persistenceProfile: String?

    // MARK: - Network

    /// Network simulation profile.
    /// "offline", "fast", "slow", "timeout", "partial-failure".
    let networkProfile: String?

    // MARK: - State

    /// When true, reset all persisted state before launch.
    let resetTestState: Bool

    // MARK: - Time

    /// Fixed ISO-8601 date for reproducible time-dependent tests.
    let fixedDate: Date?

    // MARK: - Theme

    /// Fixed circadian theme: "morning", "afternoon", "evening", "night".
    let fixedTheme: String?

    // MARK: - Onboarding

    /// Skip non-deterministic onboarding flows.
    let skipOnboarding: Bool

    /// Force onboarding to appear (overrides hasSeenOnboarding flag).
    let showOnboarding: Bool

    // MARK: - Feature flags

    /// Reset content filters on launch (UITest isolation).
    let resetFilters: Bool

    // MARK: - Locale

    /// Override AppleLanguages for locale-specific testing.
    let appleLanguages: String?

    // MARK: - Init

    init(
        isUITesting: Bool = false,
        isPerformanceTesting: Bool = false,
        fixtureProfile: String? = nil,
        fixtureSeed: Int? = nil,
        persistenceProfile: String? = nil,
        networkProfile: String? = nil,
        resetTestState: Bool = false,
        fixedDate: Date? = nil,
        fixedTheme: String? = nil,
        skipOnboarding: Bool = false,
        showOnboarding: Bool = false,
        resetFilters: Bool = false,
        appleLanguages: String? = nil
    ) {
        self.isUITesting = isUITesting
        self.isPerformanceTesting = isPerformanceTesting
        self.fixtureProfile = fixtureProfile
        self.fixtureSeed = fixtureSeed
        self.persistenceProfile = persistenceProfile
        self.networkProfile = networkProfile
        self.resetTestState = resetTestState
        self.fixedDate = fixedDate
        self.fixedTheme = fixedTheme
        self.skipOnboarding = skipOnboarding
        self.showOnboarding = showOnboarding
        self.resetFilters = resetFilters
        self.appleLanguages = appleLanguages
    }

    /// Production configuration — all test flags disabled.
    static let production = TestConfiguration()

    /// The active test configuration for this launch. Set once during `App.init()`.
    /// Nil in production builds or when no test arguments are present.
    /// Not MainActor-isolated because it's written once at launch (on main thread)
    /// and read-only thereafter by any actor/thread.
    nonisolated(unsafe) static var active: TestConfiguration?

    // MARK: - Parse from ProcessInfo

    /// Parse launch arguments into a typed configuration.
    /// Call once at app init.
    static func parse(from processInfo: ProcessInfo = .processInfo) -> TestConfiguration {
        parse(
            args: processInfo.arguments,
            isXCTestProcess: processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
    }

    /// Parse an explicit argument array (for testing).
    static func parse(
        args: [String],
        isXCTestProcess: Bool = ProcessInfo.isTestMode
    ) -> TestConfiguration {
        // Production ignores the entire test-control vocabulary. XCUITest launches the app as a
        // separate process, so XCTestConfigurationFilePath is not a reliable discriminator there;
        // the explicit -ui-testing flag is. A random/deep-link launch argument must never be able to
        // reset state, inject fixtures or force deterministic network/time behavior.
        let isHarnessLaunch = isXCTestProcess || args.contains("-ui-testing")
        guard isHarnessLaunch else { return .production }

        if !args.isEmpty {
            print("🔧TestConfiguration\(TestConfiguration.parseAndPrettyPrint(args: args))")
        }

        return TestConfiguration(
            isUITesting: args.contains("-ui-testing") || args.contains("-UITestResetFilters") || args.contains("-UITestSkipOnboarding") || args.contains("-UITestShowOnboarding"),
            isPerformanceTesting: args.contains("-performance-testing"),
            fixtureProfile: extractArg(args, prefix: "-fixture-profile"),
            fixtureSeed: extractArg(args, prefix: "-fixture-seed").flatMap(Int.init),
            persistenceProfile: extractArg(args, prefix: "-persistence-profile"),
            networkProfile: extractArg(args, prefix: "-network-profile"),
            resetTestState: args.contains("-reset-test-state"),
            fixedDate: extractArg(args, prefix: "-fixed-date").flatMap(ISO8601DateFormatter().date),
            fixedTheme: extractArg(args, prefix: "-fixed-theme"),
            skipOnboarding: args.contains("-UITestSkipOnboarding"),
            showOnboarding: args.contains("-UITestShowOnboarding"),
            resetFilters: args.contains("-UITestResetFilters"),
            appleLanguages: extractAppleLanguages(args)
        )
    }

    // MARK: - Helpers

    private static func extractArg(_ args: [String], prefix: String) -> String? {
        guard let idx = args.firstIndex(of: prefix),
              idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func extractAppleLanguages(_ args: [String]) -> String? {
        guard let idx = args.firstIndex(of: "-AppleLanguages"),
              idx + 1 < args.count else { return nil }
        // Value is in parentheses: "(en)" → "en"
        let raw = args[idx + 1]
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }

    private static func parseAndPrettyPrint(args: [String]) -> String {
        let filtered = args.filter { $0.hasPrefix("-") && $0 != "-AppleLanguages" }
        guard !filtered.isEmpty else { return "" }
        return "\n  " + filtered.enumerated().map { i, arg in
            let next = (i + 1 < filtered.count) ? filtered[i + 1] : ""
            if arg.hasPrefix("-") && !next.hasPrefix("-") {
                return "\(arg) \(next)"
            } else if arg.hasPrefix("-") {
                return arg
            }
            return ""
        }.filter { !$0.isEmpty }.joined(separator: "\n  ")
    }
}

// MARK: - ProcessInfo extension

extension ProcessInfo {
    /// True when running inside any XCTest harness (unit or UI).
    /// This is a compile-time safe check — XCTest injects this environment variable.
    static var isTestMode: Bool {
        processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
