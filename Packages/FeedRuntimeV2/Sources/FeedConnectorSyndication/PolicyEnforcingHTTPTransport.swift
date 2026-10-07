import Foundation
import FeedDomain

/// The production `HTTPTransport` (plan §3, §12; ADR-005 D14).
///
/// There is exactly one of these in the process, and every production fetch goes through it: the
/// syndication connector's body reads, the media download, and anything a later slice adds. It does
/// two things and nothing else:
///
/// * **it validates every request through `EndpointPolicy` before the bytes leave the process.** The
///   policy is the runtime's own rule (`http` is upgraded to `https`, credentials in a URL, a missing
///   host, an unknown scheme and a non-HTTP URL are refused), and enforcing it *here* — at the single
///   boundary every caller shares — is what makes "every production fetch passes the policy" true by
///   construction rather than by each caller remembering. `SyndicationHTTPClient` still validates the
///   endpoint it is about to request and each redirect hop, because it also has to decide whether a
///   validator may travel to that hop (ADR-005 D12); validating twice is intended, since the two
///   checks answer different questions.
/// * **it never follows a redirect.** `URLSession` follows redirects by default and forwards the
///   request headers to the new location, which would let a conditional-request validator travel to a
///   host that never issued it — the exact transfer ADR-005 D12 forbids — and would hide every hop
///   from the connector's chain, its redirect ceiling, its evidence and the endpoint a checkpoint is
///   bound to (D10). A redirect is therefore returned as the protocol fact it is, and the caller that
///   understands the document decides what to do with it.
///
/// Nothing here decodes, caches, retries or throttles: freshness is the checkpoint's job, budgets are
/// the acquisition layer's, and a transport-level failure is classified by the caller.
public struct PolicyEnforcingHTTPTransport: HTTPTransport {
    public let session: URLSession

    /// - Parameter session: the session to perform requests with. The default is ephemeral, cookie-less
    ///   and cache-less, so a fetch never carries a credential the process did not ask for and never
    ///   answers from a cache written by another launch (ADR-005 D14).
    public init(session: URLSession = PolicyEnforcingHTTPTransport.defaultSession()) {
        self.session = session
    }

    /// The session the process uses when the caller does not supply one.
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [:]
        // Bounds on one request. The acquisition layer's own deadline is checked before a pull, so the
        // session's timers are the backstop that keeps a stalled host from holding a lease forever.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false

        let delegate = RedirectRefusingDelegate()
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let validated = try Self.validated(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: validated)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.notHTTP }
        // The status is reported, not interpreted: 304, 429 and a redirect are facts the connector's own
        // contract is written against.
        return (data, http)
    }

    /// The bounded call: the ceilings are checked as the response arrives, never after the fact.
    ///
    /// A `Content-Length` above the declared ceiling is refused from the headers, before a single body
    /// byte is read, and the received count is counted on every byte: the sequence is abandoned at the
    /// ceiling, which stops the transfer, so a response that declares nothing and streams hundreds of
    /// megabytes is never materialised (ADR-005 D4, D14).
    ///
    /// The read is deliberately the byte sequence and not the delegate-based `data(for:delegate:)`: a
    /// task delegate is not consulted for the body of a data task (measured — `didReceive` fires
    /// neither for the response nor for the data), so a ceiling built on one would be a ceiling that
    /// never triggers. Counting per byte costs about 45 ns (measured: 0.37 s for 8 MiB), which is the
    /// price of a refusal that a compressed body cannot walk around; a declared length is still refused
    /// from the headers, before any of it is paid.
    public func data(for request: URLRequest, ceiling: HTTPBodyCeiling) async throws -> (Data, HTTPURLResponse) {
        let validated = try Self.validated(request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: validated)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.notHTTP }
        if let declaredCeiling = ceiling.declaredBytes,
           let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           declared > declaredCeiling {
            throw HTTPTransportError.declaredBodyTooLarge(limit: declaredCeiling, declared: declared)
        }

        var data = Data()
        data.reserveCapacity(min(ceiling.receivedBytes, 256 * 1024))
        do {
            for try await byte in bytes {
                guard data.count < ceiling.receivedBytes else {
                    throw HTTPTransportError.receivedBodyTooLarge(
                        limit: ceiling.receivedBytes,
                        received: data.count + 1
                    )
                }
                data.append(byte)
            }
        } catch let error as HTTPTransportError {
            throw error
        }
        return (data, http)
    }

    /// The endpoint policy, applied to every request before the bytes leave the process.
    private static func validated(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url else { throw HTTPTransportError.notHTTP }

        let target: URL
        switch EndpointPolicy.validate(url) {
        case .success(let validated):
            target = validated.url
        case .failure(let rejection):
            // A refused endpoint is not a transport failure of the resource: it is a request the policy
            // never allowed to exist. The description names the rule, never the URL (ADR-005 D14).
            throw HTTPTransportError.transport(rejection.description)
        }

        var validated = request
        if target != url { validated.url = target }
        return validated
    }
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
