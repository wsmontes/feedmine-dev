import Foundation
import FeedDomain

/// Endpoint rules for the syndication connector (plan §12, ADR-005 D14).
///
/// These are the checks that must happen before a request leaves the process and before any
/// validator is attached to a redirected endpoint.
public enum EndpointRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedScheme(String)
    case missingHost
    case embeddedCredentials
    case insecureTransport

    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme): return "unsupported scheme '\(scheme)'"
        case .missingHost: return "missing host"
        case .embeddedCredentials: return "credentials embedded in the URL"
        case .insecureTransport: return "insecure transport"
        }
    }
}

public struct ValidatedEndpoint: Equatable, Sendable {
    public let url: URL
    /// True when the endpoint was upgraded from http to https.
    public let upgraded: Bool
}

public enum EndpointPolicy {
    /// Schemes this runtime will speak to. Anything else (`file`, `data`, `feed`, …) is refused:
    /// an acquisition path that can read the local filesystem is not a fetch failure, it is a
    /// different capability.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Policy for the http→https upgrade applied before the request is sent.
    public static let upgradesInsecureScheme = true

    public static func validate(_ url: URL) -> Result<ValidatedEndpoint, EndpointRejection> {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .failure(.unsupportedScheme(""))
        }
        guard allowedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard let host = url.host(), !host.isEmpty else {
            return .failure(.missingHost)
        }
        if url.user() != nil || url.password() != nil {
            // Credentials in a URL end up in logs and in redirect targets.
            return .failure(.embeddedCredentials)
        }

        if scheme == "http", upgradesInsecureScheme {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return .failure(.insecureTransport)
            }
            components.scheme = "https"
            guard let upgraded = components.url else {
                return .failure(.insecureTransport)
            }
            return .success(ValidatedEndpoint(url: upgraded, upgraded: true))
        }

        return .success(ValidatedEndpoint(url: url, upgraded: false))
    }

    /// The effective endpoint of a URL for scoping and audit: `http` upgraded to `https`, and query,
    /// fragment and userinfo removed.
    ///
    /// A query string can carry a signed URL or a token, so it never reaches a checkpoint, an
    /// evidence record or a diagnostic (ADR-005 D14; plan §1). Two spellings of one endpoint — with
    /// and without a query — are one endpoint, which is what a validator is scoped to.
    public static func effectiveEndpoint(of url: URL) -> URL {
        let validated: URL
        if case .success(let endpoint) = validate(url) {
            validated = endpoint.url
        } else {
            validated = url
        }
        guard var components = URLComponents(url: validated, resolvingAgainstBaseURL: false) else {
            return validated
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url ?? validated
    }

    /// Whether a conditional-request validator may follow a redirect.
    ///
    /// It may not move to another host: an `ETag` is scoped to the resource that produced it, and
    /// sending it to a third party leaks the request pattern (ADR-005 D12).
    ///
    /// It may not move to another *resource* either. Comparing the host alone let a validator for
    /// `/feed-a` be replayed against `/feed-b` on the same host, and a `304` is a confirmation: the
    /// endpoint that issued the validator would then answer for a feed this runtime had never read,
    /// suppressing its acquisition (ADR-005 D12, `invariant 7`). "One resource" is the same notion the
    /// checkpoint's endpoint key uses — scheme, host, port and path, with the query excluded because a
    /// query string is not persisted and two spellings of one endpoint are one endpoint (D14).
    public static func allowsValidatorTransfer(from source: URL, to destination: URL) -> Bool {
        guard let sourceHost = source.host()?.lowercased(),
              let destinationHost = destination.host()?.lowercased()
        else { return false }
        let sameScheme = source.scheme?.lowercased() == destination.scheme?.lowercased()
        return sourceHost == destinationHost
            && sameScheme
            && effectiveEndpoint(of: source) == effectiveEndpoint(of: destination)
    }
}
