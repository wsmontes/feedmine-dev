import Foundation
import XCTest

// MARK: - App Launcher

/// Centralized app launch configuration for UI tests.
/// Uses the typed `TestConfiguration` launch arguments.
enum AppLauncher {
    /// Standard UI test launch with filters reset and onboarding skipped.
    static func launch(
        app: XCUIApplication,
        fixtureProfile: String? = nil,
        fixtureSeed: Int? = nil,
        networkProfile: String? = nil,
        fixedTheme: String? = nil,
        showOnboarding: Bool = false,
        locale: String? = "en"
    ) {
        app.launchArguments = buildArguments(
            fixtureProfile: fixtureProfile,
            fixtureSeed: fixtureSeed,
            networkProfile: networkProfile,
            fixedTheme: fixedTheme,
            showOnboarding: showOnboarding,
            locale: locale
        )
        app.launch()
    }

    /// Performance-test launch arguments, *without* launching.
    ///
    /// A launch measured with `XCTApplicationLaunchMetric` must call `app.launch()` itself inside the
    /// `measure` block, so the arguments have to be obtainable separately from the launch. Passing a
    /// nil `fixtureProfile` is the clean-install lane; `networkProfile: "offline"` is the only profile
    /// `OfflineNetworkGuard` implements.
    static func performanceArguments(
        fixtureProfile: String? = "heavy",
        fixtureSeed: Int = 42001,
        fixedTheme: String = "afternoon",
        networkProfile: String? = nil
    ) -> [String] {
        var args: [String] = [
            "-performance-testing",
            "-fixed-theme", fixedTheme,
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        if let profile = fixtureProfile {
            args.append(contentsOf: ["-fixture-profile", profile, "-fixture-seed", "\(fixtureSeed)"])
        }
        if let net = networkProfile {
            args.append(contentsOf: ["-network-profile", net])
        }
        return args
    }

    /// Performance test launch — always skips onboarding, uses fixed data.
    static func launchPerformance(
        app: XCUIApplication,
        fixtureProfile: String = "heavy",
        fixtureSeed: Int = 42001,
        fixedTheme: String = "afternoon"
    ) {
        app.launchArguments = performanceArguments(
            fixtureProfile: fixtureProfile,
            fixtureSeed: fixtureSeed,
            fixedTheme: fixedTheme
        )
        app.launch()
    }

    /// Accessibility-audit launch arguments, *without* launching.
    ///
    /// `networkProfile` is how a test reaches a deterministic terminal state without connectivity
    /// (`offline` is the only profile `OfflineNetworkGuard` implements); passing nil keeps the old
    /// behaviour of a normal networked launch.
    static func accessibilityArguments(
        locale: String = "en",
        showOnboarding: Bool = false,
        networkProfile: String? = nil
    ) -> [String] {
        var args: [String] = [
            "-ui-testing",
            "-AppleLanguages", "(\(locale))",
            showOnboarding ? "-UITestShowOnboarding" : "-UITestSkipOnboarding",
            "-UITestResetFilters",
        ]
        if let net = networkProfile {
            args.append(contentsOf: ["-network-profile", net])
        }
        return args
    }

    /// Launch for accessibility audit — respects locale and Dynamic Type.
    static func launchAccessibility(
        app: XCUIApplication,
        locale: String = "en",
        showOnboarding: Bool = false,
        networkProfile: String? = nil
    ) {
        app.launchArguments = accessibilityArguments(
            locale: locale,
            showOnboarding: showOnboarding,
            networkProfile: networkProfile
        )
        app.launch()
    }

    // MARK: - Helpers

    private static func buildArguments(
        fixtureProfile: String?,
        fixtureSeed: Int?,
        networkProfile: String?,
        fixedTheme: String?,
        showOnboarding: Bool,
        locale: String?
    ) -> [String] {
        var args: [String] = ["-ui-testing", "-UITestResetFilters"]

        if showOnboarding {
            args.append("-UITestShowOnboarding")
        } else {
            args.append("-UITestSkipOnboarding")
        }

        if let profile = fixtureProfile {
            args.append(contentsOf: ["-fixture-profile", profile])
        }
        if let seed = fixtureSeed {
            args.append(contentsOf: ["-fixture-seed", "\(seed)"])
        }
        if let net = networkProfile {
            args.append(contentsOf: ["-network-profile", net])
        }
        if let theme = fixedTheme {
            args.append(contentsOf: ["-fixed-theme", theme])
        }
        if let loc = locale {
            args.append(contentsOf: ["-AppleLanguages", "(\(loc))"])
        }

        return args
    }
}
