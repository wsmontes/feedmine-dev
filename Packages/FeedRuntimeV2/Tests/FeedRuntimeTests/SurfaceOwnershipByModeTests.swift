import XCTest
import FeedDomain
@testable import FeedRuntime

/// The support matrix's owner column, read in both modes (plan §13, §14).
///
/// The column used to be one string per row, which was true while the legacy engine was the only
/// producer. A mode now exists in which the runtime acquires, so the row has to answer per mode — and
/// the answer for the surfaces this slice did not move is "nothing acquires there", which is the honest
/// remainder rather than an omission.
final class SurfaceOwnershipByModeTests: XCTestCase {

    func testTheMainFeedIsTheOneSurfaceTheRuntimeAcquiresFor() {
        let main = FeedSurfaceCatalog.plan(for: .main)
        XCTAssertEqual(main.acquisitionOwner(legacyProducerClosed: false), "FeedStore")
        XCTAssertEqual(main.acquisitionOwner(legacyProducerClosed: true), "AcquisitionCoordinator")
    }

    func testEveryOtherSurfaceNamesNoRuntimeOwnerAndSaysSo() {
        // The remainder of the swap, as data. A surface on this list shows what has already been
        // admitted: its legacy producer is closed in a mode whose runtime acquires, and the runtime does
        // not serve it yet. Adding a runtime owner here without moving the surface would be the lie the
        // matrix exists to prevent.
        XCTAssertEqual(
            FeedSurfaceCatalog.surfacesWithoutRuntimeAcquisition.sorted { $0.rawValue < $1.rawValue },
            [
                FeedSurface.bookmarks,
                FeedSurface.lastClicked,
                FeedSurface.onboarding,
                FeedSurface.search,
                FeedSurface.smartFeed,
                FeedSurface.source,
                FeedSurface.sourceCollection,
                FeedSurface.whatsNew,
            ]
        )
        for surface in FeedSurfaceCatalog.surfacesWithoutRuntimeAcquisition {
            let row = FeedSurfaceCatalog.plan(for: surface)
            XCTAssertNil(row.runtimeOwner, surface.rawValue)
            XCTAssertEqual(
                row.acquisitionOwner(legacyProducerClosed: true),
                FeedSurfacePlan.noRuntimeOwner,
                surface.rawValue
            )
            // In the modes whose legacy producers run, nothing about the row changed.
            XCTAssertEqual(row.acquisitionOwner(legacyProducerClosed: false), "FeedStore", surface.rawValue)
        }
    }

    func testALocalOnlySurfaceKeepsItsOwnerInEveryMode() {
        // The catalogue query and the local content index are reads, not producers: closing the legacy
        // producers does not hand them to anyone else, and `FeedStore` still answers a persistent search.
        for surface in [FeedSurface.catalogueBrowse, .persistentSearch] {
            let row = FeedSurfaceCatalog.plan(for: surface)
            XCTAssertNil(row.runtimeOwner, surface.rawValue)
            XCTAssertFalse(row.acquiresOverTheNetwork, surface.rawValue)
            XCTAssertFalse(FeedSurfaceCatalog.surfacesWithoutRuntimeAcquisition.contains(surface), surface.rawValue)
            XCTAssertEqual(
                row.acquisitionOwner(legacyProducerClosed: true),
                row.owner,
                surface.rawValue
            )
        }
        XCTAssertEqual(FeedSurfaceCatalog.plan(for: .catalogueBrowse).owner, "SQLiteCatalogRepository")
    }

    func testASurfaceThatDemandsOnlineContentIsListedBecauseTheSweepIsClosed() {
        let row = FeedSurfaceCatalog.plan(for: .search)
        XCTAssertTrue(row.acquiresOverTheNetwork)
        XCTAssertEqual(row.acquisitionOwner(legacyProducerClosed: true), FeedSurfacePlan.noRuntimeOwner)
    }

    func testTheMatrixStillValidatesWithTheOwnerColumnReadPerMode() {
        XCTAssertEqual(FeedSurfaceCatalog.violations, [])
    }
}
