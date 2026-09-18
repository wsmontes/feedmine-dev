import Foundation

/// Process-level network block, installed only when a launch asks for no connectivity (PR-13).
///
/// The offline proof has to be stronger than "the device had no Wi-Fi": it must be *this process*
/// that cannot reach the network, so that "the Main Feed presents content" and "no request is made"
/// are about the same run. This is a `URLProtocol` rather than a switch inside a transport because the
/// app builds sessions in several places (feed HTTP, media, article images) and a transport-level
/// switch would only cover the one it lives in.
///
/// It is installed from the process entry point, before `FeedmineApp`'s stored properties build their
/// sessions — `URLSessionConfiguration.default` copies the registered protocol list when a session is
/// created, so a session that already exists would never see this guard. Nothing installs it without
/// the launch argument: production carries the type and never registers it.
final class OfflineNetworkGuard: URLProtocol {
    /// Requests this process tried to make while blocked. Zero is the proof; a non-zero count says
    /// which part of the app tried, and every attempt still failed.
    private nonisolated(unsafe) static var blockedRequestCount = 0
    private static let lock = NSLock()

    static var blockedRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return blockedRequestCount
    }

    /// The launch argument the UI suite already passes for "no connectivity"
    /// (`AppLauncher.launch(networkProfile: "offline")`).
    static let profileArgument = "-network-profile"
    static let offlineProfile = "offline"

    /// Registers the guard when this launch asked for the offline profile. Parsed here rather than
    /// through a configuration type because the app's launch-argument instruments are all this shape
    /// (`FeedmineApp.init` reads its own), and this one has to be read before the app exists.
    @discardableResult
    static func installIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: profileArgument),
              index + 1 < arguments.count,
              arguments[index + 1] == offlineProfile
        else { return false }
        URLProtocol.registerClass(OfflineNetworkGuard.self)
        Log.feed.info("network offline guard installed: every request this process makes will fail")
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.blockedRequestCount += 1
        let attempt = Self.blockedRequestCount
        Self.lock.unlock()
        Log.feed.info("network offline guard blocked \(self.request.url?.host ?? "-", privacy: .public) (attempt \(attempt))")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
