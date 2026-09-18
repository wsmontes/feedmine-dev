import XCTest
@testable import FeedDomain

final class RuntimeIDTests: XCTestCase {
    func testZeroIsNotAPersistableSourceIdentifier() throws {
        XCTAssertThrowsError(try SourceID(0)) { error in
            XCTAssertEqual(error as? RuntimeIDError, .reservedZero(SourceID.self))
        }
    }

    func testRowIdentifiersRejectNonPositiveValues() throws {
        XCTAssertThrowsError(try OriginRecordID(0)) { error in
            XCTAssertEqual(error as? RuntimeIDError, .nonPositiveRowID(OriginRecordID.self, 0))
        }
        XCTAssertThrowsError(try EditionID(-7)) { error in
            XCTAssertEqual(error as? RuntimeIDError, .nonPositiveRowID(EditionID.self, -7))
        }
    }

    func testCheckedConversionRefusesValuesOutsideTheRuntimeRange() throws {
        XCTAssertEqual(try RuntimeRowID.checked(1), 1)
        XCTAssertEqual(try RuntimeRowID.checked(Int64.max), Int64.max)
        XCTAssertThrowsError(try RuntimeRowID.checked(0))
        XCTAssertThrowsError(try RuntimeRowID.checked(-1))
    }

    /// The runtime identifier space is checked against the width the legacy catalogue uses, so a
    /// `UInt32` catalogue row id can never be passed off as a runtime identity.
    func testRuntimeRowIdentifiersAreWiderThanTheCatalogueNamespace() throws {
        let wide = try OriginRecordID(Int64(UInt32.max) + 1)
        XCTAssertEqual(wide.rawValue, 4_294_967_296)
    }

    func testDifferentIdentityKindsDoNotCompareEqual() throws {
        let source = try SourceID(1)
        let provider = try ProviderID(1)
        XCTAssertNotEqual(AnyHashable(source), AnyHashable(provider))
    }

    func testDescriptionsExposeTheKindNotJustTheNumber() throws {
        XCTAssertEqual(try SourceID(3).description, "source:3")
        XCTAssertEqual(try PublicationCardID(9).description, "card:9")
    }
}

final class PrecedenceInstructionTests: XCTestCase {
    func testOnlyMakeCurrentIsACurrentRequest() throws {
        XCTAssertFalse(PrecedenceInstruction.historicalOnly.isCurrentRequest)
        XCTAssertFalse(PrecedenceInstruction.duplicate.isCurrentRequest)
        let revision = try OriginRevisionID(4)
        XCTAssertTrue(PrecedenceInstruction.makeCurrent(expectedRevision: revision).isCurrentRequest)
        XCTAssertTrue(PrecedenceInstruction.makeCurrent(expectedRevision: nil).isCurrentRequest)
    }

    func testExternalKeyUniquenessUsesTheWholeKey() throws {
        let feedOne = ExternalScopeKey(namespace: ConnectorNamespace("rss"), scopeKey: "feed:1")
        let feedTwo = ExternalScopeKey(namespace: ConnectorNamespace("rss"), scopeKey: "feed:2")
        let anotherNamespace = ExternalScopeKey(namespace: ConnectorNamespace("jsonfeed"), scopeKey: "feed:1")
        let a = try ExternalObjectKey(scope: feedOne, text: "post-1")
        let b = try ExternalObjectKey(scope: feedTwo, text: "post-1")
        let c = try ExternalObjectKey(scope: anotherNamespace, text: "post-1")
        XCTAssertNotEqual(a, b, "the same key in another scope is a different object")
        XCTAssertNotEqual(a, c, "the same key in another namespace is a different object")
        XCTAssertEqual(a.keyKind, .object)
        XCTAssertEqual(try ExternalVersionKey(scope: feedOne, text: "post-1").keyKind, .version)
    }
}
