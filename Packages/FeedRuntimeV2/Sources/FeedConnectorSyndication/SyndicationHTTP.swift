import Foundation
import FeedDomain

/// HTTP semantics for the syndication connector: a bounded fetch that never logs a query string,
/// never attaches a credential, and never moves a validator to another endpoint (plan §12;
/// ADR-005 D12, D13, D14).
///
/// The transport is injected, so every rule below is provable without a network: the deterministic
/// tests only ever see synthetic XML behind a fake transport.

/// Hard request limits, enforced before and during the request (ADR-005 D14; plan §12).
public struct SyndicationHTTPLimits: Hashable, Sendable {
    /// How many redirects may be followed before the work stops with a checkpoint.
    public let maxRedirects: Int
    /// Ceiling on the response as it arrives on the wire (`Content-Length`, when declared).
    public let maxCompressedBytes: Int
    /// Ceiling on the response the connector reads after the transport decompressed it.
    public let maxDecompressedBytes: Int
    /// Bodies larger than this are not copied into evidence; the digest is still recorded.
    public let evidenceBodyCeiling: Int

    public init(
        maxRedirects: Int = 5,
        maxCompressedBytes: Int = 20 * 1024 * 1024,
        maxDecompressedBytes: Int = 20 * 1024 * 1024,
        evidenceBodyCeiling: Int = 64 * 1024
    ) {
        self.maxRedirects = maxRedirects
        self.maxCompressedBytes = maxCompressedBytes
        self.maxDecompressedBytes = maxDecompressedBytes
        self.evidenceBodyCeiling = evidenceBodyCeiling
    }
}

/// Why a transport call failed. A class, not a message: the description of a URL error can carry
/// the URL, and a query string is personal data (ADR-005 D14).
public enum SyndicationTransportFailureClass: String, Hashable, Sendable, Codable, CaseIterable {
    case timedOut
    case offline
    case connectionLost
    case cannotConnect
    case secureConnectionFailed
    case cancelled
    case other

    /// Whether a retry can plausibly succeed without a change in policy.
    public var isRetryable: Bool {
        switch self {
        case .timedOut, .offline, .connectionLost, .cannotConnect: return true
        case .secureConnectionFailed, .cancelled, .other: return false
        }
    }

    /// Classifies an injected transport error without quoting any part of the request.
    public static func classify(_ error: any Error) -> SyndicationTransportFailureClass {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .other }
        switch urlError.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .networkConnectionLost: return .connectionLost
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse: return .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return .secureConnectionFailed
        case .cancelled: return .cancelled
        default: return .other
        }
    }
}

public enum SyndicationHTTPError: Error, Equatable, Sendable {
    case invalidEndpoint(EndpointRejection)
    case invalidRedirectTarget(EndpointRejection)
    case missingLocation(status: Int)
    case redirectLimitExceeded(limit: Int)
    case compressedBodyTooLarge(limit: Int, declared: Int)
    case decompressedBodyTooLarge(limit: Int, received: Int)
    case transport(SyndicationTransportFailureClass)
    /// A 304 that no conditional request could have produced. It is never trusted: without a
    /// baseline the body must be fetched unconditionally (ADR-005 D12).
    case notModifiedWithoutConditionalRequest
}

/// Stable per-target jitter (ADR-005 D13; plan §20.3). Injected so a test can pin it, and never
/// derived from the wall clock or from a per-process seed.
public protocol SyndicationJitterSource: Sendable {
    /// A fraction in `[0, 1)` for the given stable inputs.
    func fraction(salt: String, targetID: AcquisitionTargetID, bucket: Int) -> Double
}

/// The default source: a deterministic function of the local salt, the target and the cadence
/// bucket. Two targets never wake together by construction.
public struct StableSyndicationJitter: SyndicationJitterSource {
    public init() {}

    public func fraction(salt: String, targetID: AcquisitionTargetID, bucket: Int) -> Double {
        let material = Data("\(salt)|\(targetID.rawValue)|\(bucket)".utf8)
        let digest = SyndicationFingerprint.fingerprint128(material)
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Double(value) / (Double(UInt64.max) + 1)
    }
}

/// A fixed fraction, for tests and for a caller that wants an unjittered floor.
public struct FixedSyndicationJitter: SyndicationJitterSource {
    public let value: Double

    public init(value: Double) {
        self.value = value
    }

    public func fraction(salt: String, targetID: AcquisitionTargetID, bucket: Int) -> Double { value }
}

/// `Retry-After` handling and the stable jitter that keeps targets out of lockstep (ADR-005 D13).
public struct SyndicationBackoffPolicy: Hashable, Sendable {
    public let defaultDelay: TimeInterval
    public let maxDelay: TimeInterval
    /// `0` disables jitter; `0.2` spreads a delay over ±20%.
    public let jitterFraction: Double
    public let salt: String

    public init(
        defaultDelay: TimeInterval = 60,
        maxDelay: TimeInterval = 6 * 3600,
        jitterFraction: Double = 0.2,
        salt: String = "syndication-backoff"
    ) {
        self.defaultDelay = defaultDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
        self.salt = salt
    }

    /// Parses `Retry-After` as RFC 7231 declares it: delta-seconds or an HTTP-date, clamped to be
    /// non-negative. `nil` means the header was absent or unusable, never "retry now".
    public static func parseRetryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds.isFinite {
            return max(seconds, 0)
        }
        for format in httpDateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(date.timeIntervalSince(now), 0)
            }
        }
        return nil
    }

    /// The instant this target may try again: the declared delay clamped into `[0, maxDelay]`, then
    /// spread by the target's stable jitter.
    public func eligibleAt(
        now: Date,
        retryAfter: TimeInterval?,
        targetID: AcquisitionTargetID,
        jitter: any SyndicationJitterSource
    ) -> Date {
        let declared = retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? defaultDelay
        let base = min(max(declared, 0), maxDelay)
        let fraction = min(max(jitter.fraction(salt: salt, targetID: targetID, bucket: Int(base)), 0), 1)
        let factor = 1 + jitterFraction * (2 * fraction - 1)
        return now.addingTimeInterval(base * factor)
    }

    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]
}

/// Per-host eligibility, the local half of the fairness rule: a throttled host must not consume the
/// budget that other eligible hosts can still use within the same global connection budget
/// (ADR-005 D13; plan §12).
///
/// The gate is caller-owned state: the connector never mutates it, so a caller records a throttle
/// where it also knows what the throttle means for its budget.
public struct SyndicationHostGate: Hashable, Sendable {
    /// Lowercased host -> the instant it becomes eligible again.
    public let backoffUntil: [String: Date]

    public init(backoffUntil: [String: Date] = [:]) {
        self.backoffUntil = backoffUntil
    }

    public static func host(of url: URL) -> String? {
        guard let host = url.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    public func isEligible(_ url: URL, at now: Date) -> Bool {
        guard let host = Self.host(of: url), let until = backoffUntil[host] else { return true }
        return now >= until
    }

    public func nextEligibleAt(_ url: URL) -> Date? {
        guard let host = Self.host(of: url) else { return nil }
        return backoffUntil[host]
    }

    /// Records a throttle for one host. Every other host's eligibility is untouched: the gate is
    /// keyed by host, so a throttled host cannot delay fair work elsewhere (D13).
    public func recording(url: URL, until: Date) -> SyndicationHostGate {
        guard let host = Self.host(of: url) else { return self }
        if let existing = backoffUntil[host], existing >= until { return self }
        var map = backoffUntil
        map[host] = until
        return SyndicationHostGate(backoffUntil: map)
    }
}

/// One response body and the endpoint it came from.
public struct SyndicationHTTPBody: Hashable, Sendable {
    /// The endpoint the body came from (the last hop), in its audit form: a query string is never
    /// reported (ADR-005 D14).
    public let endpoint: URL
    public let status: Int
    public let body: Data
    public let validators: SyndicationValidators
    public let redirectCount: Int
    /// Every endpoint requested, in request order, the original endpoint first, each in its audit
    /// form.
    public let chain: [URL]
}

public struct SyndicationNotModified: Hashable, Sendable {
    public let endpoint: URL
    public let redirectCount: Int
    public let chain: [URL]
}

public enum SyndicationHTTPOutcome: Hashable, Sendable {
    case body(SyndicationHTTPBody)
    case notModified(SyndicationNotModified)
    /// 429 or 503, with the declared `Retry-After` when the endpoint declared a usable one.
    case throttled(retryAfter: TimeInterval?)
    /// Any other status: a protocol fact for the caller, with the checkpoint left untouched.
    case unhandledStatus(Int)
}

/// The bounded, redirect-aware reader for one endpoint.
public struct SyndicationHTTPClient: Sendable {
    public let transport: any HTTPTransport
    public let limits: SyndicationHTTPLimits

    public init(transport: any HTTPTransport, limits: SyndicationHTTPLimits = SyndicationHTTPLimits()) {
        self.transport = transport
        self.limits = limits
    }

    /// Performs one logical fetch: at most `limits.maxRedirects` redirects, conditional headers only
    /// where a validator is legal, and byte ceilings before any body is returned.
    ///
    /// - Parameters:
    ///   - endpoint: the target's configured endpoint. Conditional headers come from `checkpoint`
    ///     only for this endpoint.
    ///   - generation: the target generation the checkpoint must match (ADR-005 D10).
    ///   - checkpoint: the last checkpoint, or `nil` for an unconditional first fetch.
    ///   - byteCeiling: the caller's own ceiling; the effective ceiling is the smaller of the two.
    ///   - now: the local instant, used only to turn an HTTP-date `Retry-After` into a duration.
    public func fetch(
        endpoint: URL,
        generation: UInt64,
        checkpoint: SyndicationCheckpoint?,
        byteCeiling: Int,
        now: Date
    ) async throws -> SyndicationHTTPOutcome {
        let requested = endpoint
        let effectiveCeiling = min(byteCeiling, limits.maxDecompressedBytes)

        var current = endpoint
        var chain: [URL] = []
        var redirects = 0
        var conditionalRequestSent = false

        while true {
            let target: URL
            switch EndpointPolicy.validate(current) {
            case .success(let validated):
                target = validated.url
            case .failure(let rejection):
                throw chain.isEmpty
                    ? SyndicationHTTPError.invalidEndpoint(rejection)
                    : SyndicationHTTPError.invalidRedirectTarget(rejection)
            }
            // The chain and the reported endpoint are audit forms: the request keeps its query, the
            // record never does (ADR-005 D14).
            let auditEndpoint = EndpointPolicy.effectiveEndpoint(of: target)
            chain.append(auditEndpoint)

            // A validator may only travel where the endpoint policy allows it: a hop that changes
            // host or scheme is requested unconditionally, and the previous endpoint's validator is
            // discarded rather than attached to a resource that never issued it (ADR-005 D12,
            // `invariant 7`).
            let headers: [String: String]
            if EndpointPolicy.allowsValidatorTransfer(from: requested, to: target) {
                headers = checkpoint?.conditionalHeaders(for: requested, generation: generation) ?? [:]
            } else {
                headers = [:]
            }
            if !headers.isEmpty { conditionalRequestSent = true }

            var request = URLRequest(url: target)
            request.httpMethod = "GET"
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }

            let pair: (Data, HTTPURLResponse)
            do {
                pair = try await transport.data(for: request)
            } catch {
                throw SyndicationHTTPError.transport(SyndicationTransportFailureClass.classify(error))
            }
            let body = pair.0
            let response = pair.1

            switch response.statusCode {
            case 200...299:
                if let declared = declaredLength(response), declared > limits.maxCompressedBytes {
                    throw SyndicationHTTPError.compressedBodyTooLarge(limit: limits.maxCompressedBytes, declared: declared)
                }
                guard body.count <= effectiveCeiling else {
                    throw SyndicationHTTPError.decompressedBodyTooLarge(limit: effectiveCeiling, received: body.count)
                }
                return .body(SyndicationHTTPBody(
                    endpoint: auditEndpoint,
                    status: response.statusCode,
                    body: body,
                    validators: Self.validators(from: response),
                    redirectCount: redirects,
                    chain: chain
                ))

            case 304:
                guard conditionalRequestSent else {
                    throw SyndicationHTTPError.notModifiedWithoutConditionalRequest
                }
                return .notModified(SyndicationNotModified(
                    endpoint: auditEndpoint,
                    redirectCount: redirects,
                    chain: chain
                ))

            case 301, 302, 303, 307, 308:
                guard redirects < limits.maxRedirects else {
                    throw SyndicationHTTPError.redirectLimitExceeded(limit: limits.maxRedirects)
                }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: target)?.absoluteURL
                else {
                    throw SyndicationHTTPError.missingLocation(status: response.statusCode)
                }
                redirects += 1
                current = next

            case 429, 503:
                return .throttled(retryAfter: SyndicationBackoffPolicy.parseRetryAfter(
                    response.value(forHTTPHeaderField: "Retry-After"),
                    now: now
                ))

            default:
                return .unhandledStatus(response.statusCode)
            }
        }
    }

    private static func validators(from response: HTTPURLResponse) -> SyndicationValidators {
        SyndicationValidators(
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    private func declaredLength(_ response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
    }
}
