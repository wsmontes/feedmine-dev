import XCTest
@testable import FeedConnectorSyndication

final class EndpointPolicyTests: XCTestCase {
    func testHTTPIsUpgradedToHTTPS() throws {
        let result = EndpointPolicy.validate(URL(string: "http://example.com/feed.xml")!)
        let endpoint = try XCTUnwrap(try? result.get())
        XCTAssertEqual(endpoint.url.scheme, "https")
        XCTAssertTrue(endpoint.upgraded)
    }

    func testHTTPSIsKeptAsIs() throws {
        let result = EndpointPolicy.validate(URL(string: "https://example.com/feed.xml?a=1")!)
        let endpoint = try XCTUnwrap(try? result.get())
        XCTAssertEqual(endpoint.url.absoluteString, "https://example.com/feed.xml?a=1")
        XCTAssertFalse(endpoint.upgraded)
    }

    func testNonHTTPSchemesAreRefused() {
        for raw in ["file:///etc/passwd", "data:text/plain,hello", "ftp://example.com/feed"] {
            guard let url = URL(string: raw) else { continue }
            XCTAssertEqual(
                EndpointPolicy.validate(url),
                .failure(.unsupportedScheme(url.scheme ?? "")),
                raw
            )
        }
    }

    func testCredentialsInTheURLAreRefused() {
        let url = URL(string: "https://user:secret@example.com/feed.xml")!
        XCTAssertEqual(EndpointPolicy.validate(url), .failure(.embeddedCredentials))
    }

    func testValidatorMayNotFollowARedirectToAnotherHostOrResource() {
        let source = URL(string: "https://a.example.com/feed")!
        // The same resource, spelled the same way: the validator belongs to it.
        XCTAssertTrue(EndpointPolicy.allowsValidatorTransfer(from: source, to: source))
        // A query string is not part of an endpoint's identity, so two spellings of one endpoint are one
        // endpoint (ADR-005 D14).
        XCTAssertTrue(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://a.example.com/feed?page=2")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://b.example.com/feed")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://sub.a.example.com/feed")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "http://a.example.com/feed")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://a.example.com:8443/feed")!))
        // Another resource on the same host never issued this validator, so a `304` there would confirm a
        // baseline this runtime never read (ADR-005 D12, `invariant 7`).
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://a.example.com/other")!))
    }
}
