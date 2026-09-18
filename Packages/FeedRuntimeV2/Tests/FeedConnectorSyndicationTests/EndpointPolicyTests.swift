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

    func testValidatorMayNotFollowARedirectToAnotherHost() {
        let source = URL(string: "https://a.example.com/feed")!
        XCTAssertTrue(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://a.example.com/other")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://b.example.com/feed")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "https://sub.a.example.com/feed")!))
        XCTAssertFalse(EndpointPolicy.allowsValidatorTransfer(from: source, to: URL(string: "http://a.example.com/feed")!))
    }
}
