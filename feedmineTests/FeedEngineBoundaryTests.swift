import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import feedmine

final class FeedEngineBoundaryTests: XCTestCase {
    func testSourceIDsAreStableNumericValues() {
        let first = SourceID(rawValue: 42)
        let same = SourceID(rawValue: 42)
        let different = SourceID(rawValue: 43)

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, different)
        XCTAssertEqual(first.rawValue, 42)
        XCTAssertEqual(CatalogNodeID.root.rawValue, 0)
    }

    func testCatalogCursorRoundTripsAsOpaqueTokenPayload() throws {
        let cursor = CatalogCursor(catalogVersion: 7, sortKey: "global/science", entityID: 99)

        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(CatalogCursor.self, from: data)

        XCTAssertEqual(decoded, cursor)
    }

    func testPageLimitBoundsUnlimitedRequests() {
        XCTAssertEqual(FeedEnginePageLimit.bounded(0), 1)
        XCTAssertEqual(FeedEnginePageLimit.bounded(50), 50)
        XCTAssertEqual(FeedEnginePageLimit.bounded(10_000), FeedEnginePageLimit.maximumLimit)
    }

    func testQueriesRepresentEmptyAndCompoundInputs() {
        let emptyBrowse = CatalogBrowseQuery()
        XCTAssertNil(emptyBrowse.parentID)
        XCTAssertTrue(emptyBrowse.includeSources)

        let compoundSearch = CatalogSearchQuery(
            text: "acoustics",
            filters: CatalogSearchFilters(kind: .subcategory, language: "en", region: "global/science")
        )
        XCTAssertEqual(compoundSearch.text, "acoustics")
        XCTAssertEqual(compoundSearch.filters.kind, .subcategory)
        XCTAssertEqual(compoundSearch.filters.language, "en")
        XCTAssertEqual(compoundSearch.filters.region, "global/science")

        let content = ContentQuery(
            scope: .nodes([CatalogNodeID(rawValue: 10), CatalogNodeID(rawValue: 11)]),
            mediaKinds: [.text, .audio],
            languages: ["en", "pt"],
            searchText: "waves"
        )
        XCTAssertEqual(content.scope, .nodes([CatalogNodeID(rawValue: 10), CatalogNodeID(rawValue: 11)]))
        XCTAssertEqual(content.mediaKinds, [.text, .audio])
        XCTAssertEqual(content.languages, ["en", "pt"])
        XCTAssertEqual(content.searchText, "waves")
    }

    func testSourceSummaryAndDetailsStaySeparated() throws {
        let sourceID = SourceID(rawValue: 501)
        let summary = SourceSummary(
            id: sourceID,
            title: "Acoustics Today",
            displayHost: "acousticstoday.org",
            mediaKind: .text,
            language: "en"
        )
        let details = SourceDetails(
            id: sourceID,
            title: "Acoustics Today",
            declaredURL: try XCTUnwrap(URL(string: "https://acousticstoday.org/feed/")),
            requestURL: try XCTUnwrap(URL(string: "https://acousticstoday.org/feed/")),
            mediaKind: .text,
            language: "en",
            placements: []
        )

        XCTAssertEqual(summary.id, details.id)
        XCTAssertEqual(summary.title, details.title)
        XCTAssertEqual(summary.displayHost, "acousticstoday.org")
        XCTAssertTrue(details.placements.isEmpty)
    }

    func testSingleSourceCanAppearInMultipleCatalogNodes() throws {
        let sourceID = SourceID(rawValue: 700)
        let details = SourceDetails(
            id: sourceID,
            title: "Startupi",
            declaredURL: try XCTUnwrap(URL(string: "https://startupi.com.br/feed/")),
            requestURL: try XCTUnwrap(URL(string: "https://startupi.com.br/feed/")),
            mediaKind: .text,
            language: "pt",
            placements: [
                SourcePlacementSummary(
                    id: 1,
                    nodeID: CatalogNodeID(rawValue: 10),
                    nodeName: "Brazil",
                    opmlFile: "countries/brazil/brazil.opml",
                    sortOrder: 12,
                    titleOverride: nil,
                    languageOverride: "pt",
                    mediaKindOverride: nil
                ),
                SourcePlacementSummary(
                    id: 2,
                    nodeID: CatalogNodeID(rawValue: 20),
                    nodeName: "Portuguese Entrepreneurship",
                    opmlFile: "languages/pt/entrepreneurship.opml",
                    sortOrder: 3,
                    titleOverride: nil,
                    languageOverride: "pt",
                    mediaKindOverride: nil
                ),
            ]
        )

        XCTAssertEqual(details.id, sourceID)
        XCTAssertEqual(details.placements.count, 2)
        XCTAssertEqual(Set(details.placements.map(\.nodeID)).count, 2)
        XCTAssertEqual(Set(details.placements.map(\.opmlFile)).count, 2)
    }

    func testFeedEngineProtocolReturnsBoundedPages() async throws {
        let engine = BoundedMockFeedEngine()
        let page = try await engine.browseCatalog(
            query: CatalogBrowseQuery(parentID: .root),
            cursor: nil,
            limit: 10_000
        )

        XCTAssertEqual(page.sources.count, FeedEnginePageLimit.maximumLimit)
        XCTAssertNotNil(page.nextCursor)
    }

    func testBundledYouTubeLanguageOverridesAreAppliedAtSourceLevel() throws {
        let expectedLanguages = [
            "UC2p1nohpGOnK7u_3JgDpvog": "ko",
            "UC371icpvZj2oQaocL0i9L-g": "pt",
            "UC48h7Dst_hX82HxOf3xJw_w": "th",
            "UC4LHNX8d8RqnDX0OezgmCTg": "es",
            "UCAy_KEOjhjKP7BETzJrsaxg": "es",
            "UCC9h3H-sGrvqd2otknZntsQ": "de",
            "UCEeEQxm6qc_qaTE7qTV5aLQ": "ur",
            "UCJg19noZp7-BYIGvypu_cow": "hi",
            "UCLYqpLGnCoQfcD7BdDKsSxQ": "es",
            "UCSiDGb0MnHFGjs4E2WKvShw": "hi",
            "UCj-SWZSE0AmotGSQ3apROHw": "hi",
            // UClgRkhTL3_hImCAmdLfDE4g is retained in editorial staging: it
            // did not complete corpus analysis and is intentionally not bundled.
            "UCw7xjxzbMwgBSmbeYwqYRMg": "hi",
            "UCx8Z14PpntdaxCt2hakbQLQ": "hi",
            "UCxtLc0Jqq3SKBWlIXM_OC9g": "ko",
            "UCyoXW-Dse7fURq30EWl_CUA": "hi",
            "UCzw-C7fNfs018R1FzIKnlaA": "ko",
        ]
        let feedsURL = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("Feeds", isDirectory: true),
            "The installed app bundle must contain the Feeds resource directory"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: feedsURL.path),
            "Bundled Feeds directory does not exist at \(feedsURL.path)"
        )
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: feedsURL, includingPropertiesForKeys: nil)
        )
        var counts = Dictionary(uniqueKeysWithValues: expectedLanguages.keys.map { ($0, 0) })
        var mismatches: [String] = []
        var misplacedLanguageElements: [String] = []
        var sourcesMissingLanguage: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "opml" {
            let relativePath = fileURL.path.replacingOccurrences(of: feedsURL.path + "/", with: "")
            let delegate = BundledOPMLLanguageAuditDelegate(
                expectedLanguages: expectedLanguages,
                relativePath: relativePath
            )
            let parser = try XCTUnwrap(XMLParser(contentsOf: fileURL))
            parser.delegate = delegate

            XCTAssertTrue(parser.parse(), "Failed to parse \(relativePath): \(String(describing: parser.parserError))")
            misplacedLanguageElements.append(contentsOf: delegate.misplacedLanguageElements)
            sourcesMissingLanguage.append(contentsOf: delegate.sourcesMissingLanguage)
            for occurrence in delegate.occurrences {
                counts[occurrence.channelID, default: 0] += 1
                if occurrence.language != occurrence.expectedLanguage {
                    mismatches.append(
                        "\(occurrence.relativePath): \(occurrence.channelID) language=\(occurrence.language ?? "nil"), expected=\(occurrence.expectedLanguage)"
                    )
                }
            }
        }

        let missingChannels = counts
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted()
        XCTAssertTrue(missingChannels.isEmpty, "No OPML occurrence found for channels: \(missingChannels)")
        XCTAssertTrue(misplacedLanguageElements.isEmpty, misplacedLanguageElements.sorted().joined(separator: "\n"))
        XCTAssertTrue(sourcesMissingLanguage.isEmpty, sourcesMissingLanguage.sorted().joined(separator: "\n"))
        XCTAssertTrue(mismatches.isEmpty, mismatches.sorted().joined(separator: "\n"))
    }
}

final class CatalogUpdateServiceTests: XCTestCase {
    func testNewRevisionStagesAddsDeletesAndActivatesLocalSnapshot() async throws {
        let fixture = try await CatalogUpdateFixture.make(
            bundledFiles: [
                "Feeds/topic.opml": Self.opml(title: "Original", url: "https://example.com/original.xml"),
                "Feeds/old.opml": Self.opml(title: "Old", url: "https://example.com/old.xml"),
            ],
            bundledRevision: 1
        )
        defer { fixture.cleanup() }
        try fixture.writeRemote(
            files: [
                "Feeds/topic.opml": Self.opml(title: "Updated", url: "https://example.com/updated.xml"),
                "Feeds/new.opml": Self.opml(title: "New", url: "https://example.com/new.xml"),
            ],
            revision: 2,
            sourceCount: 2
        )

        let service = CatalogUpdateService(
            paths: fixture.paths,
            remoteRootURL: fixture.remoteURL,
            transport: LocalCatalogUpdateTransport()
        )
        let outcome = try await service.updateIfAvailable()

        XCTAssertEqual(
            outcome,
            .updated(fromRevision: 1, toRevision: 2, changedFiles: 2, deletedFiles: 1)
        )
        let active = try XCTUnwrap(fixture.paths.activeSnapshot())
        XCTAssertEqual(active.manifest.revision, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.feedsURL.appendingPathComponent("new.opml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.feedsURL.appendingPathComponent("old.opml").path))
        let report = try await SQLiteCatalogRepository(databaseURL: active.catalogURL).compileReport(
            mode: .full,
            changedFileCount: 0,
            deletedFileCount: 0,
            elapsed: 0
        )
        XCTAssertEqual(report.sourceCount, 2)
    }

    func testChecksumFailureKeepsBundledSnapshotActive() async throws {
        let fixture = try await CatalogUpdateFixture.make(
            bundledFiles: [
                "Feeds/topic.opml": Self.opml(title: "Original", url: "https://example.com/original.xml"),
            ],
            bundledRevision: 1
        )
        defer { fixture.cleanup() }
        try fixture.writeRemote(
            files: [
                "Feeds/topic.opml": Self.opml(title: "Changed", url: "https://example.com/changed.xml"),
            ],
            revision: 2,
            sourceCount: 1,
            corruptChecksum: true
        )
        let service = CatalogUpdateService(
            paths: fixture.paths,
            remoteRootURL: fixture.remoteURL,
            transport: LocalCatalogUpdateTransport()
        )

        do {
            _ = try await service.updateIfAvailable()
            XCTFail("Expected checksum validation to fail")
        } catch let error as CatalogUpdateError {
            XCTAssertEqual(error, .checksumMismatch("Feeds/topic.opml"))
        }
        XCTAssertEqual(fixture.paths.activeSnapshot()?.manifest.revision, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.currentURL.path))
    }

    func testMatchingRevisionPerformsNoCatalogCopy() async throws {
        let fixture = try await CatalogUpdateFixture.make(
            bundledFiles: [
                "Feeds/topic.opml": Self.opml(title: "Original", url: "https://example.com/original.xml"),
            ],
            bundledRevision: 3
        )
        defer { fixture.cleanup() }
        try fixture.copyBundledManifestAndFilesToRemote()
        let service = CatalogUpdateService(
            paths: fixture.paths,
            remoteRootURL: fixture.remoteURL,
            transport: LocalCatalogUpdateTransport()
        )

        let outcome = try await service.updateIfAvailable()
        XCTAssertEqual(outcome, .current(revision: 3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.currentURL.path))
    }

    func testManifestRejectsPathTraversal() {
        let manifest = CatalogUpdateManifest(
            schemaVersion: 1,
            revision: 1,
            generatedAt: "2026-07-20T00:00:00Z",
            sourceCount: 1,
            fileCount: 1,
            files: [CatalogUpdateFile(path: "Feeds/../escape.opml", sha256: String(repeating: "a", count: 64), bytes: 1)],
            signature: ""
        )
        XCTAssertThrowsError(try manifest.validate())
    }

    /// P0-02: A manifest without `signature` must decode with an empty default.
    func testManifestDecodesWithoutSignatureField() throws {
        let json = """
        {
            "schemaVersion": 1,
            "revision": 5,
            "generatedAt": "2026-08-03T00:00:00Z",
            "sourceCount": 100,
            "fileCount": 2,
            "files": [
                {"path": "Feeds/topic.opml", "sha256": "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111", "bytes": 1024},
                {"path": "Feeds/other.opml", "sha256": "2222222233333333444444445555555566666666777777778888888899999999", "bytes": 2048}
            ]
        }
        """
        let data = Data(json.utf8)
        let manifest = try JSONDecoder().decode(CatalogUpdateManifest.self, from: data)
        XCTAssertEqual(manifest.revision, 5)
        XCTAssertEqual(manifest.sourceCount, 100)
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.signature, "", "Missing signature should default to empty string")
        // validate() should pass (no public key configured, so signature check skipped)
        XCTAssertNoThrow(try manifest.validate())
    }

    /// P0-03: With the default empty key, unsigned manifest validation is
    /// skipped. A production key must be compiled in before distribution.
    func testManifestValidatesWithEmptyKeyAndEmptySignature() throws {
        let manifest = CatalogUpdateManifest(
            schemaVersion: 1,
            revision: 1,
            generatedAt: "2026-08-03T00:00:00Z",
            sourceCount: 1,
            fileCount: 1,
            files: [CatalogUpdateFile(path: "Feeds/t.opml", sha256: String(repeating: "a", count: 64), bytes: 1)],
            signature: ""
        )
        XCTAssertNoThrow(try manifest.validate())
    }

    /// P0-02: A manifest WITH signature must decode it correctly.
    func testManifestDecodesWithSignatureField() throws {
        let json = """
        {
            "schemaVersion": 1,
            "revision": 1,
            "generatedAt": "2026-08-03T00:00:00Z",
            "sourceCount": 50,
            "fileCount": 1,
            "files": [
                {"path": "Feeds/test.opml", "sha256": "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111", "bytes": 512}
            ],
            "signature": "deadbeef"
        }
        """
        let data = Data(json.utf8)
        let manifest = try JSONDecoder().decode(CatalogUpdateManifest.self, from: data)
        XCTAssertEqual(manifest.signature, "deadbeef")
    }

    private static func opml(title: String, url: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>Fixture</title></head><body>
        <outline text="\(title)" title="\(title)" type="rss" xmlUrl="\(url)" language="en" />
        </body></opml>
        """.utf8)
    }
}

private struct LocalCatalogUpdateTransport: CatalogUpdateTransport {
    func data(from url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }
}

private struct CatalogUpdateFixture {
    let rootURL: URL
    let bundleURL: URL
    let remoteURL: URL
    let paths: CatalogRuntimePaths

    static func make(bundledFiles: [String: Data], bundledRevision: Int) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "feedmine-update-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try write(files: bundledFiles, below: bundle)
        let sourceCount = bundledFiles.count
        let manifest = makeManifest(
            files: bundledFiles,
            revision: bundledRevision,
            sourceCount: sourceCount
        )
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let catalogURL = bundle.appendingPathComponent("catalog.sqlite")
        _ = try await SQLiteCatalogCompiler(
            input: .opmlRoot(bundle.appendingPathComponent("Feeds", isDirectory: true)),
            databaseURL: catalogURL
        ).compileFull()
        return CatalogUpdateFixture(
            rootURL: root,
            bundleURL: bundle,
            remoteURL: remote,
            paths: CatalogRuntimePaths(
                managedRootURL: managed,
                bundledFeedsURL: bundle.appendingPathComponent("Feeds", isDirectory: true),
                bundledCatalogURL: catalogURL,
                bundledManifestURL: manifestURL
            )
        )
    }

    func writeRemote(
        files: [String: Data],
        revision: Int,
        sourceCount: Int,
        corruptChecksum: Bool = false
    ) throws {
        try Self.write(files: files, below: remoteURL)
        var manifest = Self.makeManifest(files: files, revision: revision, sourceCount: sourceCount)
        if corruptChecksum, let first = manifest.files.first {
            manifest = CatalogUpdateManifest(
                schemaVersion: manifest.schemaVersion,
                revision: manifest.revision,
                generatedAt: manifest.generatedAt,
                sourceCount: manifest.sourceCount,
                fileCount: manifest.fileCount,
                files: [CatalogUpdateFile(path: first.path, sha256: String(repeating: "0", count: 64), bytes: first.bytes)],
                signature: ""
            )
        }
        try JSONEncoder().encode(manifest).write(
            to: remoteURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    func copyBundledManifestAndFilesToRemote() throws {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        try data.write(to: remoteURL.appendingPathComponent("manifest.json"), options: .atomic)
        let feeds = remoteURL.appendingPathComponent("Feeds", isDirectory: true)
        try FileManager.default.copyItem(
            at: bundleURL.appendingPathComponent("Feeds", isDirectory: true),
            to: feeds
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func write(files: [String: Data], below root: URL) throws {
        for (relative, data) in files {
            let url = relative.split(separator: "/").reduce(root) {
                $0.appendingPathComponent(String($1))
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    private static func makeManifest(
        files: [String: Data],
        revision: Int,
        sourceCount: Int
    ) -> CatalogUpdateManifest {
        let entries = files.sorted(by: { $0.key < $1.key }).map { path, data in
            CatalogUpdateFile(
                path: path,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                bytes: data.count
            )
        }
        return CatalogUpdateManifest(
            schemaVersion: 1,
            revision: revision,
            generatedAt: "2026-07-20T00:00:00Z",
            sourceCount: sourceCount,
            fileCount: entries.count,
            files: entries,
            signature: ""
        )
    }
}

final class RSSFetcherTextSanitizerTests: XCTestCase {
    func testSanitizedHTMLTextDecodesNumericEntities() {
        let text = RSSFetcher.sanitizedHTMLText("That&#8217;s &quot;clean&quot; &amp; readable &#38; done")

        XCTAssertEqual(text, "That\u{2019}s \"clean\" & readable & done")
    }

    func testSanitizedHTMLTextDecodesTypographicNumericEntities() {
        let text = RSSFetcher.sanitizedHTMLText("She said &#8220;yes&#8221; &#8211; then left")

        XCTAssertEqual(text, "She said \u{201C}yes\u{201D} \u{2013} then left")
    }

    func testSanitizedHTMLTextDecodesNumericEntitiesWithoutSemicolon() {
        let text = RSSFetcher.sanitizedHTMLText("That&#8217s still readable")

        XCTAssertEqual(text, "That\u{2019}s still readable")
    }

    func testSanitizedHTMLTextStripsEscapedMarkup() {
        let text = RSSFetcher.sanitizedHTMLText("&lt;p&gt;A short &amp; useful summary.&lt;/p&gt;")

        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "A short & useful summary.")
    }

    func testDisplayExcerptStripsMarkupAndCapsAtAWordBoundary() {
        // One owner for "canonical text becomes display text": a payload's `primaryText` keeps the
        // publisher's HTML by design (an immutable payload is what publication protects), so the display
        // side strips it — for a session card, for the bookmark snapshot the user-state projection writes
        // into `feedmine.sqlite`, and for a canonical search row.
        XCTAssertEqual(
            FeedTextSanitizer.displayExcerpt(
                "<p>The 2026 edition of the ICC Framework for <strong>Responsible</strong> Alcohol"
                    + " Marketing &amp; more</p>"
            ),
            "The 2026 edition of the ICC Framework for Responsible Alcohol Marketing & more"
        )

        let long = "<p>" + Array(repeating: "word", count: 80).joined(separator: " ") + "</p>"
        let capped = FeedTextSanitizer.displayExcerpt(long)
        XCTAssertLessThanOrEqual(capped.count, 200)
        XCTAssertFalse(capped.hasSuffix(" "), "the cap lands on a word boundary")
        XCTAssertFalse(capped.contains("<"), "no markup survives the cap either")
    }

    func testSanitizedHTMLTextKeepsEscapedCDATAHeadline() {
        let text = RSSFetcher.sanitizedHTMLText("&lt;![CDATA[一条完整的中文标题]]&gt;")

        XCTAssertEqual(text, "一条完整的中文标题")
    }

    // MARK: - Accented Named Entities

    func testSanitizedHTMLTextDecodesAcuteAccentedNamedEntities() {
        let text = RSSFetcher.sanitizedHTMLText("caf&eacute; &amp; r&eacute;sum&eacute;")
        XCTAssertEqual(text, "caf\u{00E9} & r\u{00E9}sum\u{00E9}")
    }

    func testSanitizedHTMLTextDecodesGraveAccentedNamedEntities() {
        let text = RSSFetcher.sanitizedHTMLText("&Agrave; la carte &egrave; vero")
        XCTAssertEqual(text, "\u{00C0} la carte \u{00E8} vero")
    }

    func testSanitizedHTMLTextDecodesCircumflexAccentedNamedEntities() {
        let text = RSSFetcher.sanitizedHTMLText("h&ocirc;tel & f&ecirc;te")
        XCTAssertEqual(text, "h\u{00F4}tel & f\u{00EA}te")
    }

    func testSanitizedHTMLTextDecodesTildeAndCedillaNamedEntities() {
        let text = RSSFetcher.sanitizedHTMLText("ma&ntilde;ana &amp; a&ccedil;a&iacute;")
        XCTAssertEqual(text, "ma\u{00F1}ana & a\u{00E7}a\u{00ED}")
    }

    func testSanitizedHTMLTextDecodesUmlautNamedEntities() {
        let text = RSSFetcher.sanitizedHTMLText("M&uuml;nchen &amp; F&ouml;hr")
        XCTAssertEqual(text, "M\u{00FC}nchen & F\u{00F6}hr")
    }

    func testSanitizedHTMLTextDecodesScandinavianNamedEntities() {
        let text = RSSFetcher.sanitizedHTMLText("&Aring;rhus &amp; sm&oslash;rrebr&oslash;d")
        XCTAssertEqual(text, "\u{00C5}rhus & sm\u{00F8}rrebr\u{00F8}d")
    }

    func testSanitizedHTMLTextDecodesMixedLatinNamedEntities() {
        // Portuguese: "Açaí é ótimo"
        let text = RSSFetcher.sanitizedHTMLText("A&ccedil;a&iacute; &eacute; &oacute;timo")
        XCTAssertEqual(text, "A\u{00E7}a\u{00ED} \u{00E9} \u{00F3}timo")
    }

    func testSanitizedHTMLTextDecodesGermanSharpS() {
        let text = RSSFetcher.sanitizedHTMLText("Stra&szlig;e")
        XCTAssertEqual(text, "Stra\u{00DF}e")
    }

    func testSanitizedHTMLTextDecodesInvertedExclamationAndQuestion() {
        let text = RSSFetcher.sanitizedHTMLText("&iexcl;Hola! &iquest;Qu&eacute; tal?")
        XCTAssertEqual(text, "\u{00A1}Hola! \u{00BF}Qu\u{00E9} tal?")
    }
}

final class RSSFetcherImageExtractionTests: XCTestCase {
    override func tearDown() {
        ImageResolverURLProtocol.reset()
        super.tearDown()
    }

    func testArticleResolverNetworkPipelineIsBoundedCachedAndKeepsFallbacks() async throws {
        let articleURL = try XCTUnwrap(URL(string: "http://fixture.test/article"))
        let currentURL = try XCTUnwrap(URL(string: "http://fixture.test/thumb-32.jpg"))
        let html = """
            <html><head>
              <meta property="og:image" content="http://fixture.test/hero.jpg">
            </head><body>
              <img src="http://fixture.test/hero-320x180.jpg"
                   srcset="http://fixture.test/hero-640x360.jpg 640w,
                           http://fixture.test/hero-960x540.jpg 960w,
                           http://fixture.test/hero-2400x1350.jpg 2400w">
            </body></html>
            """ + String(repeating: " ", count: 500_000)
        ImageResolverURLProtocol.handler = { request in
            XCTAssertEqual(request.url, articleURL)
            return Self.htmlResponse(for: request, body: html)
        }
        let resolver = ArticleImageResolver(session: Self.stubbedSession())

        let first = await resolver.imageURLs(for: articleURL, replacing: currentURL)
        let second = await resolver.imageURLs(for: articleURL, replacing: currentURL)

        XCTAssertEqual(first.map(\.absoluteString), [
            "http://fixture.test/hero-960x540.jpg",
            "http://fixture.test/hero.jpg",
        ])
        XCTAssertEqual(second, first)
        XCTAssertEqual(ImageResolverURLProtocol.requestCount, 1, "Resolved article metadata should be cached")
        let htmlByteCount = await resolver.htmlByteCount(for: articleURL)
        XCTAssertEqual(htmlByteCount, 192 * 1024)
    }

    func testArticleResolverQueuesMoreThanFourConcurrentArticles() async throws {
        ImageResolverURLProtocol.handler = { request in
            Thread.sleep(forTimeInterval: 0.05)
            let index = request.url?.lastPathComponent ?? "unknown"
            let html = #"<meta property="og:image" content="/images/\#(index).jpg">"#
            return Self.htmlResponse(for: request, body: html)
        }
        let resolver = ArticleImageResolver(session: Self.stubbedSession())
        let currentURL = try XCTUnwrap(URL(string: "http://fixture.test/thumb.jpg"))
        let articleURLs = try (0..<6).map { index in
            try XCTUnwrap(URL(string: "http://fixture.test/article-\(index)"))
        }

        let results = await withTaskGroup(of: [URL].self, returning: [[URL]].self) { group in
            for articleURL in articleURLs {
                group.addTask {
                    await resolver.imageURLs(for: articleURL, replacing: currentURL)
                }
            }
            var values: [[URL]] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results.allSatisfy { !$0.isEmpty }, "Concurrency limiting must queue, not drop, cards")
        XCTAssertEqual(ImageResolverURLProtocol.requestCount, 6)
    }

    func testImageUpgradeFallsBackAndRejectsOversizedDownload() async throws {
        let firstURL = try XCTUnwrap(URL(string: "https://fixture.test/preferred.jpg"))
        let hugeURL = try XCTUnwrap(URL(string: "https://fixture.test/huge.jpg"))
        let fallbackURL = try XCTUnwrap(URL(string: "https://fixture.test/fallback.jpg"))
        let fallbackData = Self.pngData(width: 960, height: 540)
        ImageResolverURLProtocol.handler = { request in
            switch request.url {
            case firstURL:
                return Self.response(for: request, status: 404, contentType: "text/plain", body: Data())
            case hugeURL:
                return Self.response(
                    for: request,
                    status: 200,
                    contentType: "image/jpeg",
                    body: Data(repeating: 0, count: ImageUpgradePolicy.maxDownloadBytes + 1)
                )
            default:
                return Self.response(for: request, status: 200, contentType: "image/png", body: fallbackData)
            }
        }

        let result = await ImageUpgradePolicy.firstImprovement(
            from: [firstURL, hugeURL, fallbackURL],
            over: CGSize(width: 32, height: 32),
            session: Self.stubbedSession()
        )

        XCTAssertEqual(result?.url, fallbackURL)
        XCTAssertEqual(result?.data, fallbackData)
        XCTAssertEqual(ImageResolverURLProtocol.requestCount, 3)
    }

    func testAdequateImageDoesNotNeedEnrichment() {
        XCTAssertFalse(ImageUpgradePolicy.needsUpgrade(CGSize(width: 800, height: 450)))
        XCTAssertTrue(ImageUpgradePolicy.needsUpgrade(CGSize(width: 320, height: 180)))
        XCTAssertFalse(ImageUpgradePolicy.isMaterialImprovement(
            candidate: CGSize(width: 400, height: 225),
            over: CGSize(width: 320, height: 180)
        ))
        XCTAssertTrue(ImageUpgradePolicy.isMaterialImprovement(
            candidate: CGSize(width: 960, height: 540),
            over: CGSize(width: 32, height: 32)
        ))
    }

    func testMissingImageEnrichmentRejectsTinyArtworkAndUsesCardSizedCandidate() async throws {
        let tinyURL = try XCTUnwrap(URL(string: "https://fixture.test/icon.png"))
        let cardURL = try XCTUnwrap(URL(string: "https://fixture.test/card.png"))
        ImageResolverURLProtocol.handler = { request in
            let data = request.url == tinyURL
                ? Self.pngData(width: 64, height: 64)
                : Self.pngData(width: 720, height: 405)
            return Self.response(for: request, status: 200, contentType: "image/png", body: data)
        }

        let result = await ImageUpgradePolicy.firstDisplayable(
            from: [tinyURL, cardURL],
            session: Self.stubbedSession()
        )

        XCTAssertEqual(result?.url, cardURL)
        XCTAssertEqual(ImageResolverURLProtocol.requestCount, 2)
    }

    func testArticleResolverUsesJSONLDAndLazyImageWithoutSocialMetadata() throws {
        let articleURL = try XCTUnwrap(URL(string: "https://example.com/story"))
        let jsonHTML = #"<script type="application/ld+json">{"thumbnailUrl":"https:\/\/cdn.example.com\/story.jpg"}</script>"#
        let lazyHTML = #"<img src="/placeholder.gif" data-lazy-src="/images/feature.jpg">"#

        XCTAssertEqual(
            ArticleImageResolver.articleImageURLs(in: jsonHTML, baseURL: articleURL).first?.absoluteString,
            "https://cdn.example.com/story.jpg"
        )
        XCTAssertEqual(
            ArticleImageResolver.articleImageURLs(in: lazyHTML, baseURL: articleURL).first?.absoluteString,
            "https://example.com/images/feature.jpg"
        )
    }

    func testArticleResolverSkipsGoogleNewsAggregatorPages() throws {
        let googleURL = try XCTUnwrap(URL(string: "https://news.google.com/rss/articles/opaque"))
        let publisherURL = try XCTUnwrap(URL(string: "https://publisher.example/story"))

        XCTAssertFalse(ArticleImageResolver.canResolve(googleURL))
        XCTAssertTrue(ArticleImageResolver.canResolve(publisherURL))
    }

    func testSkipsDecorativeImageAndUsesLargestSrcsetCandidate() async throws {
        let feedData = feedData("""
            <rss version="2.0"><channel>
              <title>Feed</title><link>https://example.com</link><description>Test</description>
              <item><guid>item</guid><title>Article</title><link>https://example.com/article</link>
                <description><![CDATA[
                  <img src="https://example.com/favicon-32x32.png" />
                  <img src="https://example.com/photo-300.jpg"
                       srcset="https://example.com/photo-300.jpg 300w, https://example.com/photo-1200.jpg 1200w" />
                ]]></description>
              </item>
            </channel></rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())

        XCTAssertEqual(items.first?.imageURL, "https://example.com/photo-1200.jpg")
    }

    func testRSSImageExtractionSupportsLazyLoadAttributes() async throws {
        let feedData = feedData("""
            <rss version="2.0"><channel>
              <title>Feed</title><link>https://example.com</link><description>Test</description>
              <item><guid>item</guid><title>Article</title><link>https://example.com/article</link>
                <description><![CDATA[
                  <img src="https://example.com/spacer.gif"
                       data-lazy-src="https://cdn.example.com/article-960.jpg" />
                ]]></description>
              </item>
            </channel></rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())

        XCTAssertEqual(items.first?.imageURL, "https://cdn.example.com/article-960.jpg")
    }

    func testEscapedCDATATitleDoesNotBecomeUntitled() async throws {
        let feedData = feedData("""
            <rss version="2.0"><channel>
              <title>Feed</title><link>https://example.com</link><description>Test</description>
              <item><guid>item</guid>
                <title>&amp;lt;![CDATA[一条完整的中文标题]]&amp;gt;</title>
                <link>https://example.com/article</link>
                <description><![CDATA[<p>正文摘要</p>]]></description>
              </item>
            </channel></rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())

        XCTAssertEqual(items.first?.title, "一条完整的中文标题")
        XCTAssertFalse(items.contains { $0.title == "Untitled" })
    }

    func testGoogleNewsUsesItemPublisherInsteadOfCandidateFeedTitle() async {
        let data = feedData("""
            <rss version="2.0"><channel>
              <title>Google News query</title><link>https://news.google.com</link><description>Test</description>
              <image><url>https://lh3.googleusercontent.com/google-news-logo=w256</url></image>
              <item><guid>article</guid>
                <title>咖啡的功效与副作用 - 新浪网</title>
                <link>https://news.google.com/rss/articles/article</link>
                <source url="https://blog.sina.cn">新浪网</source>
              </item>
            </channel></rss>
            """)
        let source = FeedSource(
            title: "Candidate: 咖啡 — 博客",
            url: "https://news.google.com/rss/search?q=coffee&amp;hl=zh",
            category: "Food",
            region: "global",
            language: "zh"
        )

        let items = await RSSFetcher().extractItems(fromFeedData: data, source: source)

        XCTAssertEqual(items.first?.sourceTitle, "新浪网")
        XCTAssertNil(items.first?.imageURL)
    }

    func testExtractsOpenGraphImageRegardlessOfAttributeOrder() throws {
        let articleURL = try XCTUnwrap(URL(string: "https://example.com/articles/one"))
        let html = """
            <meta content="/images/hero-large.jpg?x=1&amp;y=2" property="og:image">
            <meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
            """

        XCTAssertEqual(
            ArticleImageResolver.articleImageURLs(in: html, baseURL: articleURL).map(\.absoluteString),
            [
                "https://example.com/images/hero-large.jpg?x=1&y=2",
                "https://cdn.example.com/twitter.jpg",
            ]
        )
    }

    func testOpenGraphImageUsesSmallestSufficientRelatedSrcsetVariant() throws {
        let articleURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let html = """
            <meta property="og:image" content="https://cdn.example.com/hero.jpg">
            <img src="https://cdn.example.com/hero-320x180.jpg"
                 srcset="https://cdn.example.com/hero-640x360.jpg 640w,
                         https://cdn.example.com/hero-960x540.jpg 960w,
                         https://cdn.example.com/hero-2400x1350.jpg 2400w">
            """

        XCTAssertEqual(
            ArticleImageResolver.articleImageURLs(in: html, baseURL: articleURL).map(\.absoluteString),
            [
                "https://cdn.example.com/hero-960x540.jpg",
                "https://cdn.example.com/hero.jpg",
            ]
        )
    }

    func testRSSSrcsetUsesSmallestCandidateAtTargetWidth() async throws {
        let feedData = feedData("""
            <rss version="2.0"><channel>
              <title>Feed</title><link>https://example.com</link><description>Test</description>
              <item><guid>item</guid><title>Article</title><link>https://example.com/article</link>
                <description><![CDATA[
                  <img src="https://example.com/photo-320.jpg"
                       srcset="https://example.com/photo-640.jpg 640w,
                               https://example.com/photo-960.jpg 960w,
                               https://example.com/photo-2400.jpg 2400w" />
                ]]></description>
              </item>
            </channel></rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())

        XCTAssertEqual(items.first?.imageURL, "https://example.com/photo-960.jpg")
    }

    func testUsesEpisodeITunesImageBeforeChannelArtwork() async throws {
        let feedData = feedData("""
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
              <channel>
                <title>Podcast</title><link>https://example.com</link><description>Test</description>
                <itunes:image href="https://cdn.example.com/channel.jpg"/>
                <item>
                  <guid>episode-1</guid><title>Episode</title><link>https://example.com/episode</link>
                  <itunes:image href="https://cdn.example.com/episode.jpg"/>
                  <enclosure url="https://cdn.example.com/episode.mp3" type="audio/mpeg" length="100"/>
                </item>
              </channel>
            </rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())

        XCTAssertEqual(items.first?.imageURL, "https://cdn.example.com/episode.jpg")
    }

    func testRejectsAudioMediaContentAndUsesITunesChannelArtwork() async throws {
        let feedData = feedData("""
            <rss version="2.0"
                 xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
                 xmlns:media="http://search.yahoo.com/mrss/">
              <channel>
                <title>Podcast</title><link>https://example.com</link><description>Test</description>
                <itunes:image href="https://cdn.example.com/channel.jpg"/>
                <item>
                  <guid>episode-1</guid><title>Episode</title><link>https://example.com/episode</link>
                  <media:content url="https://cdn.example.com/episode.mp3" type="audio/mpeg" medium="audio"/>
                </item>
              </channel>
            </rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())

        XCTAssertEqual(items.first?.imageURL, "https://cdn.example.com/channel.jpg")
    }

    func testRejectsSVGEmbedTrackingAndConcatenatedImageURLs() async throws {
        let invalidURLs = [
            "https://example.com/logo.svg",
            "https://www.youtube.com/embed/video-id",
            "https://counter.example.com/story/count.gif",
            "https://example.com/image.jpghttps://other.example.com/logo.png",
        ]

        for (index, invalidURL) in invalidURLs.enumerated() {
            let feedData = feedData("""
                <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
                  <channel>
                    <title>Feed</title><link>https://example.com</link><description>Test</description>
                    <item>
                      <guid>item-\(index)</guid><title>Item</title><link>https://example.com/item</link>
                      <media:content url="\(invalidURL)" type="image/jpeg" medium="image"/>
                    </item>
                  </channel>
                </rss>
                """)
            let items = await RSSFetcher().extractItems(fromFeedData: feedData, source: source())
            XCTAssertNil(items.first?.imageURL, "Should reject \(invalidURL)")
        }
    }

    func testYouTubeThumbnailCandidatesFallBackToHQDefault() throws {
        let original = try XCTUnwrap(URL(string: "https://img.youtube.com/vi/video/sddefault.jpg"))

        XCTAssertEqual(
            ImageURLCandidates.candidates(for: original).map(\.absoluteString),
            [
                "https://img.youtube.com/vi/video/sddefault.jpg",
                "https://img.youtube.com/vi/video/hqdefault.jpg",
            ]
        )
    }

    func testPreservesImageProxyWithNestedURLInPath() async {
        let imageURL = "https://web.archive.org/web/20240101000000im_/https://example.com/image.jpg"
        let data = feedData("""
            <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
              <channel>
                <title>Feed</title><link>https://example.com</link><description>Test</description>
                <item>
                  <guid>item</guid><title>Item</title><link>https://example.com/item</link>
                  <media:content url="\(imageURL)" type="image/jpeg" medium="image"/>
                </item>
              </channel>
            </rss>
            """)

        let items = await RSSFetcher().extractItems(fromFeedData: data, source: source())

        XCTAssertEqual(items.first?.imageURL, imageURL)
    }

    private func source() -> FeedSource {
        FeedSource(
            title: "Test",
            url: "https://example.com/feed",
            category: "Podcasts",
            region: "global",
            mediaKind: .audio
        )
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageResolverURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func htmlResponse(
        for request: URLRequest,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (response, Data(body.utf8))
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        contentType: String,
        body: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(body.count),
            ]
        )!
        return (response, body)
    }

    private static func pngData(width: Int, height: Int) -> Data {
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func feedData(_ xml: String) -> Data {
        Data(xml.utf8)
    }
}

private final class ImageResolverURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var count = 0
    private static let lock = NSLock()

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        handler = nil
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct BoundedMockFeedEngine: FeedEngineProtocol {
    func browseCatalog(
        query: CatalogBrowseQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage {
        let boundedLimit = FeedEnginePageLimit.bounded(limit)
        let sources = (0..<boundedLimit).map { index in
            SourceSummary(
                id: SourceID(rawValue: UInt32(index + 1)),
                title: "Source \(index)",
                displayHost: "example.com",
                mediaKind: .text,
                language: "en"
            )
        }
        return CatalogPage(
            nodes: [],
            sources: sources,
            nextCursor: CatalogCursor(catalogVersion: 1, sortKey: "Source \(boundedLimit - 1)", entityID: UInt32(boundedLimit)),
            estimatedTotalCount: nil
        )
    }

    func searchCatalog(
        query: CatalogSearchQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage {
        CatalogPage(nodes: [], sources: [], nextCursor: nil, estimatedTotalCount: nil)
    }

    func loadSourceDetails(sourceID: SourceID) async throws -> SourceDetails {
        SourceDetails(
            id: sourceID,
            title: "Source",
            declaredURL: URL(string: "https://example.com/feed")!,
            requestURL: URL(string: "https://example.com/feed")!,
            mediaKind: .text,
            language: nil,
            placements: []
        )
    }

    func loadTimeline(
        query: ContentQuery,
        cursor: TimelineCursor?,
        limit: Int
    ) async throws -> TimelinePage {
        TimelinePage(items: [], nextCursor: nil)
    }
}

private final class BundledOPMLLanguageAuditDelegate: NSObject, XMLParserDelegate {
    struct Occurrence {
        let relativePath: String
        let channelID: String
        let language: String?
        let expectedLanguage: String
    }

    let expectedLanguages: [String: String]
    let relativePath: String
    var occurrences: [Occurrence] = []
    var misplacedLanguageElements: [String] = []
    var sourcesMissingLanguage: [String] = []

    private var elementStack: [String] = []
    private var outlinePushStack: [Bool] = []
    private var languageStack: [String?] = []
    private var fileLanguage: String?
    private var activeLanguageParent: String?
    private var languageBuffer = ""

    init(expectedLanguages: [String: String], relativePath: String) {
        self.expectedLanguages = expectedLanguages
        self.relativePath = relativePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let parentElement = elementStack.last
        if elementName == "language" {
            activeLanguageParent = parentElement
            languageBuffer = ""
            if parentElement != "head" {
                misplacedLanguageElements.append("\(relativePath): <language> parent=\(parentElement ?? "nil")")
            }
        }
        elementStack.append(elementName)

        guard elementName == "outline" else { return }

        let xmlURL = attributeDict["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = normalizedLanguage(attributeDict["language"])
        if xmlURL.isEmpty {
            languageStack.append(language ?? languageStack.last ?? fileLanguage)
            outlinePushStack.append(true)
            return
        }

        outlinePushStack.append(false)
        let resolvedLanguage = language ?? languageStack.last ?? fileLanguage
        if resolvedLanguage == nil {
            sourcesMissingLanguage.append("\(relativePath): \(attributeDict["title"] ?? attributeDict["text"] ?? xmlURL)")
        }

        for (channelID, expectedLanguage) in expectedLanguages where xmlURL.contains("channel_id=\(channelID)") {
            occurrences.append(
                Occurrence(
                    relativePath: relativePath,
                    channelID: channelID,
                    language: attributeDict["language"],
                    expectedLanguage: expectedLanguage
                )
            )
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeLanguageParent != nil else { return }
        languageBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "outline" {
            let didPushLanguage = outlinePushStack.popLast() ?? false
            if didPushLanguage, !languageStack.isEmpty {
                languageStack.removeLast()
            }
        }

        if elementName == "language" {
            if activeLanguageParent == "head" {
                fileLanguage = normalizedLanguage(languageBuffer)
            }
            activeLanguageParent = nil
            languageBuffer = ""
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
