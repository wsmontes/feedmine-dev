import Foundation

/// The process entry point.
///
/// It exists so launch-argument instruments are installed before the app's stored properties build
/// their URL sessions: `URLSessionConfiguration.default` copies the registered protocol list when a
/// session is created, so `OfflineNetworkGuard` (the offline proof of PR-13) has to be registered
/// before `FeedmineApp`'s `@State` loader builds its transport. Everything after that line is the
/// ordinary SwiftUI entry point.
@main
enum FeedmineEntryPoint {
    static func main() {
        OfflineNetworkGuard.installIfRequested()
        // The app-refresh handler must exist before the app finishes launching, and this is the one
        // place that runs before `FeedmineApp` builds anything — including its URL sessions. The
        // outcome is logged with the bundle's permitted identifiers, so a configuration that cannot
        // register is visible rather than a silent never-runs (plan §14 PR-15).
        MainActor.assumeIsolated {
            SmartFeedBackgroundScheduler.shared.register()
        }
        FeedmineApp.main()
    }
}
