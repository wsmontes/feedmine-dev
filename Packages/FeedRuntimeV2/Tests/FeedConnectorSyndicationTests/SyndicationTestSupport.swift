import Foundation
import XCTest
import FeedDomain
@testable import FeedConnectorSyndication

/// Deterministic test support: a transport that answers from a script and records every request, a
/// frozen clock, and synthetic RSS/Atom/JSON documents. No test in this target opens a socket, and
/// no byte of a real publisher is used.

/// An actor, so recording requests needs no `@unchecked Sendable` conformance anywhere.
actor ScriptedTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]
        var failureClass: SyndicationTransportFailureClass?

        static func ok(
            _ xml: String,
            headers: [String: String] = [:]
        ) -> Reply {
            Reply(status: 200, body: Data(xml.utf8), headers: headers, failureClass: nil)
        }

        static func status(
            _ status: Int,
            body: String = "",
            headers: [String: String] = [:]
        ) -> Reply {
            Reply(status: status, body: Data(body.utf8), headers: headers, failureClass: nil)
        }

        static func response(_ status: Int, body: Data, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: body, headers: headers, failureClass: nil)
        }

        static func failure(_ failureClass: SyndicationTransportFailureClass) -> Reply {
            Reply(status: 0, body: Data(), headers: [:], failureClass: failureClass)
        }
    }

    private var script: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ script: [Reply]) {
        self.script = script
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !script.isEmpty else { throw URLError(.badServerResponse) }
        let reply = script.removeFirst()
        if let failureClass = reply.failureClass {
            throw Self.urlError(failureClass)
        }
        guard let url = request.url else { throw URLError(.badURL) }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        ) else {
            throw URLError(.badServerResponse)
        }
        return (reply.body, response)
    }

    var requestCount: Int { requests.count }

    var requestedURLs: [URL] { requests.compactMap(\.url) }

    func header(_ field: String, ofRequest index: Int) -> String? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: field)
    }

    private static func urlError(_ failureClass: SyndicationTransportFailureClass) -> URLError {
        switch failureClass {
        case .timedOut: return URLError(.timedOut)
        case .offline: return URLError(.notConnectedToInternet)
        case .connectionLost: return URLError(.networkConnectionLost)
        case .cannotConnect: return URLError(.cannotConnectToHost)
        case .secureConnectionFailed: return URLError(.secureConnectionFailed)
        case .cancelled: return URLError(.cancelled)
        case .other: return URLError(URLError.Code.unknown)
        }
    }
}

struct FixedClock: EditorialClock {
    let now: Date
}

enum TestFixtures {
    /// Every test uses this instant instead of reading a clock.
    static let observedAt: Date = ISO8601DateFormatter().date(from: "2026-09-14T10:00:00Z")
        ?? Date(timeIntervalSince1970: 0)

    static func url(_ raw: String) throws -> URL {
        try XCTUnwrap(URL(string: raw))
    }

    /// An instant from an ISO 8601 literal, for comparing declared dates without re-deriving them
    /// with the code under test.
    static func instant(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    static func limit(
        maxItems: Int = 200,
        maxBytes: Int = 1_048_576,
        deadline: Date = TestFixtures.observedAt.addingTimeInterval(3600)
    ) -> AcquisitionLimit {
        AcquisitionLimit(maxItems: maxItems, maxBytes: maxBytes, deadline: deadline)
    }

    static let feedEndpoint = "https://a.example.com/feed.xml"
    static let otherEndpoint = "https://b.example.com/feed.xml"

    /// Two RSS items with declared GUIDs, dates and links.
    static let rssTwoItems = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Synthetic Feed</title>
        <link>https://example.com/</link>
        <description>A synthetic feed for deterministic tests</description>
        <item>
          <title>First</title>
          <link>https://example.com/first</link>
          <guid isPermaLink="false">tag:example.com,2026:first</guid>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <description>First excerpt</description>
        </item>
        <item>
          <title>Second</title>
          <link>https://example.com/second</link>
          <guid isPermaLink="false">https://example.com/second?utm_source=feed&amp;id=2</guid>
          <pubDate>Mon, 14 Sep 2026 11:00:00 GMT</pubDate>
          <description>Second excerpt</description>
        </item>
      </channel>
    </rss>
    """

    /// The GUID spelled like a URL, verbatim, including its query.
    static let urlSpelledGUID = "https://example.com/second?utm_source=feed&id=2"

    /// A feed that declares an item with no identifier, no link and no content at all.
    static let rssWithEmptyItem = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Broken Feed</title>
        <link>https://example.com/</link>
        <description>Declares one item that carries nothing</description>
        <item/>
      </channel>
    </rss>
    """

    /// A recognized feed that declares no item element at all, with feed metadata.
    static let rssEmptyChannel = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Quiet Feed</title>
        <link>https://example.com/</link>
        <description>Nothing today</description>
      </channel>
    </rss>
    """

    /// A recognized feed with nothing recognizable in it: not distinguishable from a document whose
    /// entries the parser could not map.
    static let rssBareChannel = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel></channel></rss>
    """

    static let rssWithEnclosure = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Podcast Feed</title>
        <link>https://example.com/</link>
        <description>Enclosures live in evidence</description>
        <item>
          <title>Episode one</title>
          <link>https://example.com/episode-one</link>
          <guid isPermaLink="false">episode-one</guid>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <enclosure url="https://cdn.example.com/audio/episode-one.mp3" length="1234" type="audio/mpeg"/>
        </item>
      </channel>
    </rss>
    """

    static let rssUnparsableDate = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Undated Feed</title>
        <link>https://example.com/</link>
        <description>Declares a date the format does not parse</description>
        <item>
          <title>Undated</title>
          <guid isPermaLink="false">undated</guid>
          <pubDate>not a date at all</pubDate>
          <description>Excerpt</description>
        </item>
      </channel>
    </rss>
    """

    /// An item that declares no identifier and no link, so the fallback scheme must produce the key.
    static let rssWithoutAnyIdentifier = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Anonymous Feed</title>
        <link>https://example.com/</link>
        <description>No identifier anywhere</description>
        <item>
          <title>Anonymous one</title>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <description>Twin content</description>
        </item>
        <item>
          <title>Anonymous one</title>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <description>Different content under the same title and date</description>
        </item>
      </channel>
    </rss>
    """

    /// One item with no headline: admissible input, never a synthesised title.
    static let rssWithoutHeadline = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Sparse Feed</title>
        <link>https://example.com/</link>
        <description>Missing headline</description>
        <item>
          <link>https://example.com/sparse</link>
          <guid isPermaLink="false">sparse-1</guid>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <description>Excerpt without a headline</description>
        </item>
      </channel>
    </rss>
    """

    /// One item with no declared link: admissible input, never a synthesised URL.
    static let rssWithoutLink = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Linkless Feed</title>
        <link>https://example.com/</link>
        <description>Missing link</description>
        <item>
          <title>Linkless</title>
          <guid isPermaLink="false">linkless-1</guid>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <description>Headline without a link</description>
        </item>
      </channel>
    </rss>
    """

    /// One item with a declared link and no GUID: the link is the key, at full confidence.
    static let rssWithoutGUID = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Guidless Feed</title>
        <link>https://example.com/</link>
        <description>No GUID anywhere</description>
        <item>
          <title>Link only</title>
          <link>https://example.com/link-only</link>
          <pubDate>Mon, 14 Sep 2026 10:00:00 GMT</pubDate>
          <description>The declared link is the key</description>
        </item>
      </channel>
    </rss>
    """

    static func rssSingleItem(pubDate: String, title: String, description: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Mutable Feed</title>
            <link>https://example.com/</link>
            <description>One item, so a change is unambiguous</description>
            <item>
              <title>\(title)</title>
              <link>https://example.com/mutable</link>
              <guid isPermaLink="false">mutable-1</guid>
              <pubDate>\(pubDate)</pubDate>
              <description>\(description)</description>
            </item>
          </channel>
        </rss>
        """
    }

    /// An Atom feed whose entry declares `atom:updated`, an `atom:published`, an alternate link and
    /// an enclosure link.
    static let atomEntry = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Synthetic Atom</title>
      <id>urn:uuid:synthetic-feed</id>
      <updated>2026-09-14T10:00:00Z</updated>
      <link href="https://example.com/"/>
      <entry>
        <title>Atom first</title>
        <id>urn:uuid:entry-1</id>
        <updated>2026-09-14T10:00:00Z</updated>
        <published>2026-09-13T09:00:00Z</published>
        <link rel="alternate" type="text/html" href="https://example.com/atom-first"/>
        <link rel="alternate" type="text/html" href="https://example.com/atom-first?amp=1"/>
        <link rel="enclosure" type="audio/mpeg" href="https://cdn.example.com/atom.mp3" length="999"/>
        <summary>Atom summary</summary>
        <content type="html">&lt;p&gt;Body&lt;/p&gt;</content>
      </entry>
    </feed>
    """

    static func atomEntry(updated: String, title: String, summary: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Synthetic Atom</title>
          <id>urn:uuid:synthetic-feed</id>
          <updated>\(updated)</updated>
          <entry>
            <title>\(title)</title>
            <id>urn:uuid:entry-1</id>
            <updated>\(updated)</updated>
            <link rel="alternate" href="https://example.com/atom-mutable"/>
            <summary>\(summary)</summary>
          </entry>
        </feed>
        """
    }

    static let notAFeed = "<html><body><p>this is a web page, not a feed</p></body></html>"

    static let truncatedFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Truncated</title>
    """

    static let jsonFeed = """
    {"version": "https://jsonfeed.org/version/1", "title": "Synthetic JSON", "items": []}
    """
}

extension SyndicationTarget {
    static func fixture(
        targetID: String = "target-1",
        endpoint: String = TestFixtures.feedEndpoint,
        generation: UInt64 = 7,
        sourceKey: String = "binding-fingerprint-1"
    ) throws -> SyndicationTarget {
        try SyndicationTarget(
            targetID: AcquisitionTargetID(targetID),
            endpoint: try TestFixtures.url(endpoint),
            generation: generation,
            sourceKey: sourceKey
        )
    }
}

extension SyndicationConnector {
    /// A connector wired for the deterministic tests: frozen clock, fixed jitter, scripted transport.
    static func fixture(
        target: SyndicationTarget,
        transport: ScriptedTransport,
        limits: SyndicationHTTPLimits = SyndicationHTTPLimits(),
        backoff: SyndicationBackoffPolicy = SyndicationBackoffPolicy(defaultDelay: 30, maxDelay: 600, jitterFraction: 0),
        translator: SyndicationTranslator = SyndicationTranslator(),
        hostGate: SyndicationHostGate = SyndicationHostGate()
    ) -> SyndicationConnector {
        SyndicationConnector(
            target: target,
            transport: transport,
            clock: FixedClock(now: TestFixtures.observedAt),
            translator: translator,
            limits: limits,
            backoff: backoff,
            jitter: FixedSyndicationJitter(value: 0.5),
            hostGate: hostGate
        )
    }
}
