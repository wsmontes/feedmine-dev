import XCTest
import Foundation
import GRDB
import FeedConnectorSyndication
import FeedDomain
import FeedRuntime
import FeedStorage
@testable import feedmine

/// The owner swap, observed end to end: a real HTTP answer becomes a feed the UI draws.
///
/// The chain under test is this slice's acceptance criterion, and every hop is a production type:
/// `URLSession` behind `PolicyEnforcingHTTPTransport` → `SyndicationAcquisitionSource` (the production
/// checkpoint/outcome bridge) → `SyndicationConnector` + `SyndicationTranslator` → `AcquisitionCoordinator`
/// → `AdmissionEngine` → the canonical projections → `SelectionEngine` → `PublicationCoordinator` →
/// `RuntimeFeedSessionComposer` → a `FeedSession` snapshot with cards.
///
/// Nothing here asserts wiring. It asserts what a consumer can observe: that the content is *visible to
/// Selection* (the membership claim's entire reason for existing — without it the supply row is
/// invisible to the eligibility predicate), that `origin_search` was projected, that the provider and
/// media claims survived Admission, that a second episode against a `304` admits nothing and proposes
/// nothing new, and that a card reaches the snapshot the screen draws.
///
/// It drives the session directly rather than `V2FullRuntime`, which needs a whole `FeedLoader` (OPML,
/// taxonomy, the legacy store) to state its plan; that composition is exercised by the app, not here.
///
/// The last two tests belong to the durable-user-action slice and are here for the same reason: the
/// harness is the only app-test fixture that publishes a *legitimate* runtime card (Admission validates
/// eligibility, so a card cannot simply be inserted), and the two halves of that slice's proof both need
/// one. They drive the session's own port and read back the legacy databases a relaunch reopens.
@MainActor
final class OwnerSwapAcquisitionTests: XCTestCase {
    private var directory: URL!
    private var database: RuntimeDatabase!
    private var stubSession: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        stubSession = Self.stubbedSession()
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        stubSession.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The chain

    func testARealFetchBecomesASupplyRowSelectionCanSeeAndASnapshotTheUIShows() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))

        let refusalsBefore = LegacyAcquisitionGate.refusedRequestCount
        let harness = try makeHarness(endpoint: endpoint)
        await harness.session.start()
        await harness.session.drainPendingWork()

        // 1. The wire was read through the one policy-enforcing transport, by one owner.
        //
        //    The episode pulls a target *more than once*: `AcquisitionCoordinator`'s work-item loop keeps
        //    pulling until the item's observation budget is met or the frontier degrades — the live log
        //    for a cold launch reads `pulls=4 admitted=3`, and a refresh reads `pulls=2 admitted=2`. So
        //    "one request" was never the invariant, and asserting it made this test describe a runtime
        //    this codebase does not have (measured: requests=2, admitted=1, one row per canonical table,
        //    the extra pull answering as a duplicate with no canonical effect). The invariant that
        //    matters — and the one the acceptance criterion is about — is *one owner and one record*:
        //    every request goes to the one endpoint this target serves, and the canonical cardinalities
        //    below are all exactly 1.
        //
        //    Repeating the same endpoint inside a bounded, budgeted episode is not the double acquisition
        //    the owner swap exists to prevent: that is two *owners* drawing the same URL, which the model
        //    gate refuses and `LegacyAcquisitionGate.refusedRequestCount` counts.
        let requests = StubURLProtocol.requests()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertEqual(
            Set(requests.compactMap { $0.url?.absoluteString }),
            [endpoint.absoluteString],
            "one target, one endpoint, one owner"
        )
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
        }

        // 2. Admission admitted the batch and projected the canonical content index.
        //
        //    The table is one row per *attempt* (`admission_batch.result` distinguishes an admitted
        //    batch from a refused or duplicate one), and the admitted count is deliberately not pinned to
        //    one: the episode pulls the target more than once, and the connector re-proposes the page it
        //    just fetched under a caught-up instruction — what it first called `makeCurrent` it now calls
        //    `duplicate` — which ADR-006 D2 makes a different batch. It is admitted, its observations
        //    replay, and the canon is untouched: the cardinalities below are all exactly 1, and that is
        //    the invariant. (Before §8.55 this second pull was a `batchConflict` — a refusal that ended
        //    the episode and committed nothing.)
        let admittedBatches: Int = try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM admission_batch WHERE result = 'admitted'") ?? 0
        }
        let refusedBatches: Int = try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM admission_batch WHERE result = 'batchConflict'") ?? 0
        }
        let batchShape: String = (try? describeBatches()) ?? "unreadable"
        let requestCount = StubURLProtocol.requests().count
        print("OWNER-SWAP-DIAG requests=\(requestCount) admitted=\(admittedBatches) rows=\(batchShape)")
        XCTAssertGreaterThanOrEqual(
            admittedBatches,
            1,
            "the fetch is admitted — requests=\(requestCount) rows=\(batchShape)"
        )
        XCTAssertEqual(refusedBatches, 0, "and nothing is refused — rows=\(batchShape)")
        XCTAssertEqual(try count("origin_search"), 1, "ingestion must populate the canonical index")
        XCTAssertEqual(try count("origin_record"), 1)

        // 3. The supply row is attributed to a source: without the membership the row exists but
        //    Selection's eligibility predicate cannot see it.
        let sources: [String] = try database.read { try String.fetchAll($0, sql: "SELECT source_id FROM selection_supply") }
        XCTAssertEqual(sources.count, 1)
        XCTAssertNotEqual(sources.first, "nil", "a supply row with no source enrolls nothing")

        // 4. Selection sees the candidate, with the claims that survived Admission.
        let page = try SelectionSupplyRepository().page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 64),
            in: database
        )
        XCTAssertEqual(page.candidates.count, 1)
        XCTAssertEqual(
            page.candidates.first?.providerKey,
            ProviderStableKey(namespace: SyndicationNamespace.connector, providerKey: "https://example.test/"),
            "the attribution the channel declared must survive Admission"
        )
        XCTAssertEqual(page.candidates.first?.mediaRoles, [.audio], "the enclosure was classified from its MIME type")

        // 5. The composer published, and the session delivered a snapshot with the card in it.
        XCTAssertEqual(try count("published_card"), 1)
        let delivered = await harness.session.currentSnapshot()
        let snapshot = try XCTUnwrap(delivered)
        XCTAssertEqual(snapshot.cards.count, 1)
        let card = try XCTUnwrap(snapshot.cards.first)
        XCTAssertEqual(card.title, "First post")
        XCTAssertEqual(card.sourceTitle, "Example Channel")
        XCTAssertEqual(card.link?.absoluteString, "https://example.test/first")
        XCTAssertEqual(card.absoluteOrdinal, 0)
        XCTAssertEqual(snapshot.contextKey, harness.contextKey.canonicalSerialization)

        // 6. One acquisition, not two: one episode, one endpoint, one owner. The admitted-batch count is
        //    deliberately not pinned, for the reason step 2 records (§8.55) — what this step adds is that
        //    the owner drew the *one* endpoint, through *one* episode, and refused nothing.
        let ownerState = await harness.owner.state()
        XCTAssertEqual(ownerState.episodes, 1)
        XCTAssertGreaterThanOrEqual(ownerState.last?.admittedBatches ?? 0, 1)
        XCTAssertEqual(ownerState.last?.refusedBatches, 0, "a warm episode refuses nothing")
        XCTAssertEqual(
            LegacyAcquisitionGate.refusedRequestCount,
            refusalsBefore,
            "this harness never asks the legacy path, and the gate's counter is process-wide"
        )
    }

    func testASecondEpisodeAgainstA304AdmitsNothingAndProposesNothingNew() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let harness = try makeHarness(endpoint: endpoint)
        await harness.session.start()
        await harness.session.drainPendingWork()

        let before = try XCTUnwrap(
            AcquisitionTargetStore().snapshot(for: Self.targetID, in: database)
        )
        let admittedBefore: Int = try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM admission_batch WHERE result = 'admitted'") ?? 0
        }

        // The endpoint now confirms the baseline the conditional request carries.
        StubURLProtocol.answer(status: 304, headers: ["ETag": "\"v1\""], body: Data())
        let second = await harness.coordinator.run(
            AcquisitionDemand(
                purpose: .bootstrap,
                holderID: "second-episode",
                deficit: SupplyDeficit(items: 24),
                deadline: Date().addingTimeInterval(20)
            ),
            catalogue: harness.catalogue,
            in: database
        )

        // `answer` resets the stub's log, so what is counted here is what this episode asked — one
        // conditional request, which is the whole point of the round trip.
        let requests = StubURLProtocol.requests()
        XCTAssertEqual(
            requests.count,
            1,
            "the second episode decided \(V2Acquisition.describe(second.stop)) with \(second.pulls) pull(s)"
        )
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "If-None-Match"),
            "\"v1\"",
            "a 304 is only meaningful on the conditional request the checkpoint authorises"
        )
        XCTAssertEqual(second.admittedBatches, 0)
        XCTAssertEqual(second.pulls, 1)
        let admittedAfter: Int = try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM admission_batch WHERE result = 'admitted'") ?? 0
        }
        XCTAssertEqual(admittedAfter, admittedBefore, "a 304 writes no admitted row")

        let after = try XCTUnwrap(AcquisitionTargetStore().snapshot(for: Self.targetID, in: database))
        XCTAssertEqual(after.checkpointRevision, before.checkpointRevision, "a 304 must not advance the checkpoint")
        XCTAssertEqual(after.checkpoint?.blob, before.checkpoint?.blob)
        XCTAssertEqual(try count("published_card"), 1, "an episode that admits nothing publishes nothing")
    }

    /// A second episode against an upstream that answers `200` with the same page is a replay, not a
    /// refusal.
    ///
    /// This is what a warm launch does, and it is the case the live log showed: `pulls=2 admitted=1
    /// stop=refused(batchConflict)` inside one episode, the same lease epoch, one deficit into the run.
    /// The connector re-fetches, the upstream is unchanged, and its own representation stamps have
    /// caught up — so what it first proposed as `makeCurrent` it now proposes as `duplicate`. That is a
    /// different body under the same lease, and the ledger key the connector built covered neither the
    /// instruction nor the lease: Admission answered `batchConflict`, a *refusal* that marks the target
    /// degraded, ends the episode and — the part that matters most — commits nothing. A checkpoint that
    /// never advances is why every launch re-fetched the same page unconditionally, forever.
    ///
    /// With the key covering the instruction as the digest does, the re-delivery is admitted, its
    /// observations replay without touching the canon, and the checkpoint advances — which is what lets
    /// the *next* launch see a `304`.
    func testASecondEpisodeAgainstAnUnchangedPageIsAReplayNotARefusal() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let harness = try makeHarness(endpoint: endpoint)
        await harness.session.start()
        await harness.session.drainPendingWork()
        XCTAssertEqual(try count("origin_record"), 1)
        let before = try XCTUnwrap(AcquisitionTargetStore().snapshot(for: Self.targetID, in: database))

        // The next episode, on the epoch the launch carries, with the same page upstream.
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let second = await harness.coordinator.run(
            AcquisitionDemand(
                purpose: .bootstrap,
                holderID: "second-episode",
                deficit: SupplyDeficit(items: 24),
                deadline: Date().addingTimeInterval(20)
            ),
            catalogue: harness.catalogue,
            in: database
        )

        if case .refused(let result) = second.stop {
            XCTFail("a re-delivery of unchanged content is not a refusal: \(result)")
        }
        XCTAssertEqual(second.refusedBatches, 0, "nothing was refused")
        XCTAssertEqual(try count("origin_record"), 1, "the canon is not duplicated")
        XCTAssertEqual(try count("origin_revision"), 1, "a re-delivery appends no revision")
        XCTAssertEqual(try count("published_card"), 1, "and publishes no second card")

        // The episode has nothing to commit — the content *and* the instruction are already known — so
        // it must not move the checkpoint either. What matters for the loop is the other half, asserted
        // at the top: it must not refuse. A refusal commits nothing *and* marks the target degraded, so
        // the connector's own validators never persist and the next launch re-fetches unconditionally.
        // Here the first episode already committed them, which is what makes the *next* fetch conditional.
        let after = try XCTUnwrap(AcquisitionTargetStore().snapshot(for: Self.targetID, in: database))
        XCTAssertEqual(
            after.checkpointRevision, before.checkpointRevision,
            "a replay is not a commit: the revision belongs to the batch that first carried the content"
        )
        XCTAssertNotNil(after.checkpoint, "the checkpoint the next launch resumes from is durable")
    }

    // MARK: - Durable user actions on a runtime card

    /// A bookmark taken on a runtime card is durable and reversible through the app's own bookmark
    /// surface.
    ///
    /// That surface is the legacy one (`FeedLoader.loadBookmarkedItems` → `FeedStore.bookmarkedItems` →
    /// `BookmarkStore.bookmarkedItems`), and it answers by joining `user.sqlite.bookmark_item.item_id` to
    /// `feedmine.sqlite.feed_item`. Neither database alone makes it answer: with no authority row the join
    /// has nothing to select, and with no content row it hydrates nothing. Both halves are asserted
    /// through that join, so removing either write fails this test.
    func testABookmarkOnARuntimeCardIsVisibleAndReversibleThroughTheBookmarkSurface() async throws {
        let container = try LegacyContainer(under: directory)
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let harness = try makeHarness(endpoint: endpoint, bookmarks: container.bookmarks)
        await harness.session.start()
        await harness.session.drainPendingWork()
        let published = await harness.session.currentSnapshot()
        let card = try XCTUnwrap(published?.cards.first)
        let link = try XCTUnwrap(card.link).absoluteString

        await harness.session.send(.toggleBookmark(cardID: card.id, wanted: true, operationID: "op-save"))
        await harness.session.drainPendingWork()

        // 1. The reader's own bookmark surface shows it, hydrated from content and not from the snapshot.
        let saved = try await container.bookmarks.bookmarkedItems()
        XCTAssertEqual(saved.count, 1, "a bookmark on a runtime card must reach the bookmark surface")
        let item = try XCTUnwrap(saved.first)
        XCTAssertEqual(item.title, card.title)
        XCTAssertEqual(item.url, link)
        XCTAssertEqual(item.sourceTitle, card.sourceTitle)
        XCTAssertEqual(item.sourceURL, endpoint.absoluteString)
        let hydration = try await container.bookmarks.hydration()
        XCTAssertEqual(hydration.items.map(\.id), [item.id])
        XCTAssertTrue(
            hydration.snapshotOnly.isEmpty,
            "the content row hydrated it; the snapshot stands in only when that row is gone"
        )

        // 2. The runtime's own projection and the durable alias agree with the authority.
        let projections = UserStateProjectionStore(database: harness.database)
        XCTAssertEqual(try projections.savedSubjects(), [item.id])
        let alias = try XCTUnwrap(
            try LegacyMappingStore().itemMapping(forLegacyItemID: item.id, in: harness.database),
            "a saved subject must resolve to canonical content (ADR-004 invariant 11)"
        )
        let cardRecord = try XCTUnwrap(try harness.repository.card(card.id))
        XCTAssertEqual(alias.record?.rawValue, cardRecord.payload.origin.originRecordID.rawValue)
        XCTAssertEqual(alias.revision?.rawValue, cardRecord.payload.origin.originRevisionID.rawValue)
        XCTAssertEqual(
            alias.confidence,
            .high,
            "the card froze an article link, so the legacy id is not a low-confidence fallback"
        )

        // 3. The session's own card carries the confirmed state.
        let afterSave = await harness.session.currentSnapshot()
        let confirmed = try XCTUnwrap(afterSave?.cards.first { $0.id == card.id })
        XCTAssertTrue(confirmed.isBookmarked)

        // 4. Reversible: the removal is absolute and takes the retention pin with it.
        await harness.session.send(.toggleBookmark(cardID: card.id, wanted: false, operationID: "op-unsave"))
        await harness.session.drainPendingWork()
        let afterRemoval = try await container.bookmarks.bookmarkedItems()
        let hydrationAfterRemoval = try await container.bookmarks.hydration()
        let stillSaved = try await container.bookmarks.isBookmarked(itemID: item.id)
        let pins = try await container.bookmarks.contentDB.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bookmark_item")
        }
        XCTAssertTrue(afterRemoval.isEmpty)
        XCTAssertTrue(hydrationAfterRemoval.snapshotOnly.isEmpty)
        XCTAssertTrue(try projections.savedSubjects().isEmpty)
        XCTAssertFalse(stillSaved)
        XCTAssertEqual(pins, 0, "the legacy retention pin is removed with the bookmark")
        let removalSnapshot = await harness.session.currentSnapshot()
        XCTAssertFalse(try XCTUnwrap(removalSnapshot?.cards.first { $0.id == card.id }).isBookmarked)
    }

    /// The rollback half: a legacy relaunch hydrates the bookmark with its content.
    ///
    /// The relaunch is modelled the way it happens — new connections over the two files, and nothing
    /// carried over from the process that wrote them: no runtime database, no card id, no snapshot. What
    /// answers is the join build 17 performs. The fixture publishes two cards and the reader acts on one,
    /// so "nothing is written for content the reader did not act on" is measured rather than assumed.
    func testALegacyRelaunchHydratesABookmarkTakenOnARuntimeCard() async throws {
        let container = try LegacyContainer(under: directory)
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.twoItemRSS.utf8))
        let harness = try makeHarness(endpoint: endpoint, bookmarks: container.bookmarks)
        await harness.session.start()
        await harness.session.drainPendingWork()

        let published = await harness.session.currentSnapshot()
        let cards = try XCTUnwrap(published?.cards)
        XCTAssertEqual(cards.count, 2, "the fixture publishes two cards, so the negative below is not vacuous")
        let acted = try XCTUnwrap(cards.first)
        let actedLink = try XCTUnwrap(acted.link).absoluteString
        let actedDate = try XCTUnwrap(acted.publishedAt)

        await harness.session.send(.toggleBookmark(cardID: acted.id, wanted: true, operationID: "op-save"))
        await harness.session.drainPendingWork()

        // Only the acted-on card gets a legacy row: the projection is not an eager mirror of the feed.
        let projected = try await container.bookmarks.contentDB.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_item")
        }
        XCTAssertEqual(projected, 1, "the untouched card must leave the legacy database alone")

        // A relaunch: new connections over the same two files, and no runtime database to consult.
        let relaunched = try container.relaunched()
        let hydrated = try await relaunched.bookmarkedItems()
        XCTAssertEqual(hydrated.count, 1)
        let saved = try XCTUnwrap(hydrated.first)
        XCTAssertEqual(saved.title, acted.title)
        XCTAssertEqual(saved.url, actedLink)
        XCTAssertEqual(saved.sourceTitle, acted.sourceTitle)
        XCTAssertEqual(saved.excerpt, acted.subtitle ?? "", "the excerpt is the text the card froze")
        XCTAssertEqual(saved.publishedAt, actedDate)
        let markedBookmarked = try await relaunched.isBookmarked(itemID: saved.id)
        XCTAssertTrue(markedBookmarked)

        // The subject the runtime wrote is the one the authority holds, and it is not a runtime id: the
        // display id the presentation synthesizes (`card:<cardID>`) is a row nothing can hydrate.
        let subjects = try await container.bookmarks.userDB.read {
            try String.fetchAll($0, sql: "SELECT item_id FROM bookmark_item")
        }
        XCTAssertEqual(subjects, [saved.id])
        XCTAssertNotEqual(saved.id, "card:\(acted.id)")

        // The pin the legacy retention pass consults, so a relaunch does not have to beat the GC to see it.
        let pins = try await container.bookmarks.contentDB.read {
            try String.fetchAll($0, sql: "SELECT item_id FROM bookmark_item")
        }
        XCTAssertEqual(pins, [saved.id])
    }

    /// A box's plan states its list, and the unboxed feed states no selection at all.
    ///
    /// This is the app half of the screen step §2.5 ordered: the box is a *selection* of the same screen,
    /// its cards are the saved subjects filed under that list, and the plan is where that is declared —
    /// the runtime's selection reads it (`SubjectSelection`, `baseline.md` §8.59) and the same key spells
    /// the list that the save path files (`UserStateBridge.listKey(for:)`, §8.60). A plan that stated a
    /// list for the unboxed feed would compose the whole saved set under the feed's title.
    func testABookmarkBoxStatesItsListAndTheUnboxedFeedStatesNothing() throws {
        let store = try FeedStore(inMemory: true)
        let loader = FeedLoader(store: store)
        let contexts = SurfaceContextAdapters()

        XCTAssertNil(
            contexts.mainFeedInputs(loader: loader).subjectSelection,
            "the ordinary feed selects on its sources and on nothing else"
        )

        store.selectedBookmarkListID = 7
        XCTAssertEqual(
            contexts.mainFeedInputs(loader: loader).subjectSelection,
            .savedSubjects(kind: .bookmark, listKey: UserStateBridge.listKey(for: 7)),
            "the box's plan names the list in the one spelling the save path uses"
        )
        XCTAssertEqual(
            contexts.mainFeedInputs(loader: loader).scopeKey,
            "preset=everything|box=7",
            "and the key carries the box, so the plan and the selection cannot disagree"
        )
    }

    /// A bookmark files its list membership, and the launch pass restores one that is missing.
    ///
    /// A box's content is its list's membership (`baseline.md` §8.59), and the projection that answers
    /// the runtime's selection is written by the same port that writes the whole-set projection. The
    /// second half is the reason the pass exists: a card saved before this projection existed has no
    /// membership row, and its box would show only what was saved since — a wrong page rather than a
    /// missing one.
    func testABookmarkFilesItsListMembershipAndTheLaunchPassRestoresAMissingOne() async throws {
        let container = try LegacyContainer(under: directory)
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.twoItemRSS.utf8))
        let harness = try makeHarness(endpoint: endpoint, bookmarks: container.bookmarks)
        await harness.session.start()
        await harness.session.drainPendingWork()
        let delivered = await harness.session.currentSnapshot()
        let cards = try XCTUnwrap(delivered?.cards)
        XCTAssertEqual(cards.count, 2, "the fixture publishes two cards, so the negative below is not vacuous")

        // Both saved through the runtime, which is the path this test is about.
        for (index, card) in cards.enumerated() {
            await harness.session.send(
                .toggleBookmark(cardID: card.id, wanted: true, operationID: "op-save-\(index)")
            )
        }
        await harness.session.drainPendingWork()

        let defaultListID = await container.bookmarks.defaultListID()
        let listKey = UserStateBridge.listKey(for: defaultListID)
        let projections = UserStateProjectionStore(database: harness.database)
        let subjects = try projections.savedSubjects(kind: .bookmark).sorted()
        XCTAssertEqual(subjects.count, 2)
        for subject in subjects {
            let membership = try XCTUnwrap(
                try projections.listMembership(listKey: listKey, subjectID: subject),
                "a save through the runtime files the card into the list the store chose"
            )
            XCTAssertTrue(membership.wanted)
        }

        // One membership removed, which is what a save predating the projection looks like: the
        // authority and the whole-set projection still hold it.
        let removed = try XCTUnwrap(subjects.first)
        let bridge = UserStateBridge(bookmarks: container.bookmarks, projections: projections)
        try harness.database.write { database in
            try database.execute(
                sql: "DELETE FROM user_list_membership WHERE list_key = ? AND subject_id = ?",
                arguments: [listKey, removed]
            )
        }
        XCTAssertNil(try projections.listMembership(listKey: listKey, subjectID: removed))

        let report = await bridge.reconcileListMemberships()
        XCTAssertGreaterThanOrEqual(report.applied, 1, "the pass restores the missing membership")
        XCTAssertEqual(report.failed, 0)
        let restored = try XCTUnwrap(try projections.listMembership(listKey: listKey, subjectID: removed))
        XCTAssertTrue(restored.wanted)
        XCTAssertNotNil(try projections.projection(kind: .bookmark, subjectID: removed))

        // Idempotent: a second pass has nothing to do, because the operation id it keys on is the same.
        let again = await bridge.reconcileListMemberships()
        XCTAssertEqual(again.applied, 0, "a membership the pass already projected is not written twice")
        XCTAssertEqual(again.failed, 0)
    }

    /// An open on a runtime card becomes the runtime's own durable read state, through the same port a
    /// bookmark travels — and never under the display id.
    ///
    /// Every assertion is stored state: the runtime's projection of the read intent (keyed by the legacy
    /// subject the port derives), the `read` fact under the operation id ADR-007 D7 keys it by,
    /// `history_projection.read_at_ms` for that card and scope, and the card the session publishes. The
    /// legacy databases are read too, and what they must *not* hold is the point of the last block: the
    /// content row per opened card and the legacy `feed_item.is_read` write are the durable-state policy
    /// decision `docs/runtime-v2/read-state-report.md` names and leaves to the owner, so this slice takes
    /// neither and an open changes nothing the legacy page or the unread badge reads.
    func testAnOpenOnARuntimeCardIsDurablyReadInsideTheRuntimeAndNeverUnderItsDisplayID() async throws {
        let container = try LegacyContainer(under: directory)
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let harness = try makeHarness(endpoint: endpoint, bookmarks: container.bookmarks)
        await harness.session.start()
        await harness.session.drainPendingWork()
        let published = await harness.session.currentSnapshot()
        let card = try XCTUnwrap(published?.cards.first)

        await harness.session.send(.opened(cardID: card.id, operationID: "op-read"))
        await harness.session.drainPendingWork()

        // 1. The session's own card carries the confirmed state, which is what the screen draws.
        let afterOpen = await harness.session.currentSnapshot()
        XCTAssertTrue(
            try XCTUnwrap(afterOpen?.cards.first { $0.id == card.id }).isRead,
            "the card the session publishes is the one the port confirmed as read"
        )

        // 2. The runtime's own projection of the read intent, under the durable subject — never the
        //    display id the presentation synthesizes (`card:<cardID>`), which names no row anywhere.
        let projections = UserStateProjectionStore(database: harness.database)
        let subjects = try projections.savedSubjects(kind: .read)
        let subject = try XCTUnwrap(subjects.first, "the read reaches the runtime's own projection")
        XCTAssertEqual(subjects.count, 1)
        XCTAssertNotEqual(subject, "card:\(card.id)")
        let projection = try XCTUnwrap(try projections.projection(kind: .read, subjectID: subject))
        XCTAssertTrue(projection.wanted)
        XCTAssertEqual(projection.lastOperationID, "op-read")

        let scope = await harness.session.currentState().historyScope
        let edition = try XCTUnwrap(published?.editionID)
        await harness.session.teardown()

        // 3. The `read` fact, keyed by the operation that owns it, and the history projection it folds
        //    into for that card and scope.
        let facts = ExposureFactStore(database: harness.database)
        let read = try XCTUnwrap(try facts.fact(forKey: ExposureFact.key(
            type: .read,
            editionID: edition,
            cardID: card.id,
            scope: scope,
            visitOrdinal: 0,
            direction: nil,
            userStateOperationID: "op-read"
        )))
        XCTAssertEqual(read.eventType, .read)
        XCTAssertEqual(read.userStateOperationID, "op-read")
        let history = try XCTUnwrap(
            try HistoryProjectionStore(database: harness.database).projection(scope: scope, cardID: card.id)
        )
        XCTAssertNotNil(history.readAtMs, "read_at_ms is the read state a reader comes back to")
        XCTAssertNil(history.readClearedAtMs)

        // 4. What the named decision leaves untouched: no content row for the opened card, and no legacy
        //    read-state write. `feed_item` is read through the container that a legacy relaunch reopens.
        let legacyRows = try await container.bookmarks.contentDB.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_item")
        }
        let legacyRead = try await container.bookmarks.contentDB.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_item WHERE is_read = 1")
        }
        XCTAssertEqual(
            legacyRows,
            0,
            "an open projects no legacy content row: that projection is the owner's decision (read-state-report.md §5)"
        )
        XCTAssertEqual(
            legacyRead,
            0,
            "no legacy read state is written here, and never under the display id"
        )
    }

    // MARK: - The local content search

    /// The local content search reads the canonical index and returns what Admission admitted.
    ///
    /// This is PR-14's clause two end to end: a real HTTP answer becomes a canonical record, Admission
    /// projects it into `origin_search`, and the app's own search path — `FeedStore.search` →
    /// `SearchEngine.unifiedSearch` → `CanonicalContentSearch` — answers with that record's title,
    /// address, source and media. Every assertion below is a fact about the admitted content, not about
    /// wiring: the canonical record is the only content in either database, so a result can only have
    /// come from the runtime's index.
    ///
    /// The index is read through the same installation the `v2Full` composition performs
    /// (`FeedStore.useCanonicalContentSearch`), because the mode decision — which index a launch reads —
    /// is what `SurfacePlanMigrationTests` pins directly.
    func testTheLocalContentSearchReturnsTheAdmittedCanonicalContent() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let harness = try makeHarness(endpoint: endpoint)
        await harness.session.start()
        await harness.session.drainPendingWork()

        // Precondition from the database rather than from the search: admission indexed one record.
        XCTAssertEqual(try count("origin_search"), 1)

        let store = try FeedStore(inMemory: true)
        store.registry.sources = [FeedSource(
            title: "Example Channel",
            url: endpoint.absoluteString,
            category: "News",
            region: "global",
            mediaKind: .text,
            language: "en"
        )]
        store.useCanonicalContentSearch(
            CanonicalContentSearch(database: database, registry: store.registry)
        )

        store.search("First", includeSources: false, includeContents: true, demandOnlineContent: false)
        await waitForSearch(store)

        let items = store.unifiedSearchResults.localItems
        XCTAssertEqual(items.count, 1, "the admitted record is the only content in either database")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "First post")
        XCTAssertEqual(item.url, "https://example.test/first")
        XCTAssertEqual(item.sourceURL, endpoint.absoluteString)
        XCTAssertEqual(item.sourceTitle, "Example Channel")
        XCTAssertEqual(item.audioURL, "https://example.test/episode.mp3")
        XCTAssertEqual(item.id, CanonicalContentSearch.canonicalItemIDPrefix + "1")
        XCTAssertFalse(store.activeSearchDemandsOnlineContent, "a local index answer is not a network demand")
        XCTAssertEqual(store.sourceDemandCounters.demands, 0)
    }

    // MARK: - The catalogue bridge

    /// The `legacy_source_map` row the acquiring composition is the only writer of (ADR-003 D18), with
    /// the catalogue's own compact id as its key.
    ///
    /// The id is asserted by value, not by the row's existence: `catalog_source_id` is what D2's only
    /// translation (`LegacySourceMap.runtimeSource(forCatalogSource:)`) looks a runtime source up by, so
    /// a row written with any placeholder is a row that cannot resolve. Before the fix this test failed
    /// with no row at all — the composition wrote the catalogue's `none` (0), the table's
    /// `catalog_source_id > 0` check refused it, and the `try?` discarded the refusal.
    func testAProductionAdmissionWritesTheCatalogueSourceBridgeRow() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        StubURLProtocol.answer(status: 200, headers: ["ETag": "\"v1\""], body: Data(Self.rss.utf8))
        let source = FeedSource(
            title: "Example Channel",
            url: endpoint.absoluteString,
            category: "News",
            region: "global"
        )

        // The production owner and the production descriptors, exactly as `v2Full` composes them.
        let clock = SystemEditorialClock()
        let acquisition = V2Acquisition(
            database: database,
            transport: PolicyEnforcingHTTPTransport(session: stubSession),
            clock: clock
        )
        let watched = await acquisition.watch(V2AcquisitionSourceDescriptor.descriptors(for: [source]))
        XCTAssertEqual(watched.watched, 1, "the composition refused the source: \(watched.refused)")

        let plan = try FeedSurfaceCatalog.resolvedPlan(
            .main,
            inputs: FeedSurfaceCatalog.Inputs(scopeKey: "preset=latest|box=-", planIdentity: "MainFeedPlan"),
            clock: clock
        )
        let acquired = await acquisition.acquire(for: plan, reason: .cold, at: Date())
        let summary = try XCTUnwrap(acquired, "the composition acquired no episode")
        XCTAssertGreaterThanOrEqual(
            summary.admittedBatches,
            1,
            "the fixture must admit for this proof to be about admitted content: stop=\(V2Acquisition.describe(summary.stop))"
        )
        XCTAssertEqual(summary.refusedBatches, 0, "nothing may be refused here: \(V2Acquisition.describe(summary.stop))")
        XCTAssertEqual(try count("origin_record"), 1)

        // The catalogue's own compact id for the key: the value `SQLiteCatalogStore` inserts as
        // `catalog_source.id`, from the same normalized key the descriptor carries.
        let catalogSourceID = CatalogIdentity.sourceID(for: SourceKey(source.id))
        let row = try XCTUnwrap(try database.read { database in
            try Row.fetchOne(database, sql: """
                SELECT catalog_source_key, catalog_source_id, canonicalization_version,
                       runtime_source_id, legacy_url
                FROM legacy_source_map
                """)
        })
        XCTAssertEqual(row["catalog_source_key"] as String, source.id)
        XCTAssertEqual(
            row["catalog_source_id"] as Int64,
            Int64(catalogSourceID.rawValue),
            "the row must be keyed by the catalogue's compact id (\(catalogSourceID.rawValue)), not by a placeholder"
        )
        XCTAssertEqual(
            row["canonicalization_version"] as Int64,
            Int64(LegacySourceMapper.defaultCanonicalizationVersion)
        )
        XCTAssertEqual(row["legacy_url"] as String, source.id)

        // And it resolves: the catalogue id reaches the `source` row the composition allocated, through
        // the persisted mapping and not through any derivation (ADR-003 D2).
        let sourceRowID: Int64 = try database.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT id FROM source WHERE editorial_key = ?",
                arguments: [source.id]
            ) ?? 0
        }
        XCTAssertGreaterThan(sourceRowID, 0, "the composition resolves a runtime source before it writes the bridge")
        XCTAssertEqual(row["runtime_source_id"] as Int64, sourceRowID)
        let mapping = try XCTUnwrap(try LegacyMappingStore().sourceMapping(
            for: LegacySourceMapper.editorialKey(for: LegacySourceMapper.catalogIdentity(
                key: source.id,
                normalizedURL: source.id,
                compactID: CatalogSourceID(catalogSourceID.rawValue)
            )),
            in: database
        ))
        XCTAssertEqual(
            try LegacySourceMap([mapping]).runtimeSource(
                forCatalogSource: CatalogSourceID(catalogSourceID.rawValue),
                canonicalizationVersion: LegacySourceMapper.defaultCanonicalizationVersion
            ),
            try FeedDomain.SourceID(UInt64(sourceRowID))
        )
    }

    /// A bridge write the schema refuses is a refusal, not silence.
    ///
    /// The value below is the catalogue's `none` — what the composition used to write — which
    /// `legacy_source_map.catalog_source_id > 0` refuses. Before the fix the `try?` swallowed it and the
    /// source was composed anyway; now the write's failure refuses the source and says which one.
    func testABridgeWriteTheSchemaRefusesRefusesTheSourceInsteadOfBeingSwallowed() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://feeds.example.test/tech.xml"))
        let acquisition = V2Acquisition(
            database: database,
            transport: PolicyEnforcingHTTPTransport(session: stubSession),
            clock: SystemEditorialClock()
        )
        let report = await acquisition.watch([
            V2AcquisitionSourceDescriptor(
                catalogKey: "https://feeds.example.test/tech.xml",
                compactID: CatalogSourceID(0),
                endpoint: endpoint,
                title: "Example Channel"
            )
        ])

        XCTAssertEqual(report.watched, 0, "a source whose bridge row cannot be written must not be composed")
        XCTAssertEqual(report.refused.count, 1, "the failed write has to be reported")
        XCTAssertTrue(
            report.refused.first?.contains("https://feeds.example.test/tech.xml") ?? false,
            "the refusal names the source it could not map: \(report.refused)"
        )
        XCTAssertEqual(try count("legacy_source_map"), 0)
    }

    // MARK: - The transport

    func testThePolicyRefusesAnEndpointAndNeverPutsTheURLInTheFailure() async throws {
        let transport = PolicyEnforcingHTTPTransport(session: stubSession)
        let url = try XCTUnwrap(URL(string: "https://user:token@feeds.example.test/tech.xml?signature=abc"))

        do {
            _ = try await transport.data(for: URLRequest(url: url))
            XCTFail("credentials embedded in a URL must be refused before the request exists")
        } catch let error as HTTPTransportError {
            guard case .transport(let description) = error else {
                return XCTFail("expected a policy refusal, got \(error)")
            }
            XCTAssertTrue(description.contains("credentials"), description)
            XCTAssertFalse(description.contains("signature"), "a query string is personal data: \(description)")
            XCTAssertFalse(description.contains("token"), description)
        }
        XCTAssertTrue(StubURLProtocol.requests().isEmpty, "a refused endpoint is never requested")
    }

    func testARedirectIsReturnedToTheCallerRatherThanFollowed() async throws {
        let transport = PolicyEnforcingHTTPTransport(session: stubSession)
        StubURLProtocol.answer(status: 302, headers: ["Location": "https://elsewhere.example.test/moved.xml"], body: Data())
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/redirect.xml"))
        let (_, response) = try await transport.data(for: URLRequest(url: url))
        XCTAssertEqual(
            response.statusCode,
            302,
            "a followed redirect would hide the hop from the connector's per-hop policy and its chain"
        )
    }

    // MARK: - The gate

    func testAClosedGateRefusesTheLegacyRequestWithoutCountingIt() async throws {
        let source = Self.source(url: "https://feeds.example.test/legacy.xml")
        let transport = RecordingFeedTransport()
        let fetcher = RSSFetcher(transport: transport, starterTransport: transport)

        LegacyAcquisitionGate.close()
        defer { LegacyAcquisitionGate.open() }
        let before = LegacyAcquisitionGate.refusedRequestCount

        let result = await fetcher.fetch(source)
        guard case .legacyProducerClosed = result.outcome else {
            return XCTFail("a closed producer must report its own outcome, got \(result.outcome)")
        }
        let attempts = await fetcher.fetchAttemptCount()
        let requested = await transport.requestedURLs()
        XCTAssertEqual(attempts, 0, "a request that was never meant to happen is not an attempt")
        XCTAssertTrue(requested.isEmpty, "no request may leave the process")
        XCTAssertEqual(LegacyAcquisitionGate.refusedRequestCount, before + 1)
    }

    func testAnOpenGateFetchesExactlyAsBefore() async throws {
        let source = Self.source(url: "https://feeds.example.test/legacy.xml")
        let transport = RecordingFeedTransport(body: Self.rss)
        let fetcher = RSSFetcher(transport: transport, starterTransport: transport)
        LegacyAcquisitionGate.open()

        let result = await fetcher.fetch(source)
        let attempts = await fetcher.fetchAttemptCount()
        let requested = await transport.requestedURLs()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(requested, [source.url])
        XCTAssertFalse(result.items.isEmpty, "the legacy path is unchanged in every mode that keeps it")
    }

    /// The batch aggregation must not report a closed producer as a refill or as a failure.
    func testAClosedGateKeepsGatedSourcesOutOfThePerSourceOutcomes() async throws {
        let sources = [
            Self.source(url: "https://feeds.example.test/a.xml"),
            Self.source(url: "https://feeds.example.test/b.xml"),
        ]
        let transport = RecordingFeedTransport(body: Self.rss)
        let fetcher = RSSFetcher(transport: transport, starterTransport: transport)
        LegacyAcquisitionGate.close()
        defer { LegacyAcquisitionGate.open() }

        let batch = await fetcher.fetchAll(sources)
        XCTAssertEqual(batch.gatedSourceCount, 2)
        XCTAssertTrue(
            batch.sourceOutcomes.isEmpty,
            "a request that was never issued is neither a success nor a failure"
        )
        XCTAssertEqual(batch.failedSourceCount, 0)
        XCTAssertTrue(batch.items.isEmpty)
    }

    // MARK: - Harness

    private nonisolated static let targetID = AcquisitionTargetID("syndication:source:test")

    private struct Harness {
        let session: FeedSession
        let coordinator: AcquisitionCoordinator
        let owner: EpisodeOwner
        let catalogue: [AcquisitionTarget]
        let contextKey: ContextKey
        let database: RuntimeDatabase
        let repository: PublicationRepository
        /// The legacy store the session's durable actions write through, so a test can read back what the
        /// app's own bookmark surface would show.
        let bookmarks: BookmarkStore
    }

    /// A `FeedCompositionAcquiring` step over the real coordinator: the same call `V2Acquisition` makes,
    /// with the catalogue handed in rather than resolved from the loader's catalogue.
    private actor EpisodeOwner: FeedCompositionAcquiring {
        private let coordinator: AcquisitionCoordinator
        private let catalogue: [AcquisitionTarget]
        private let database: RuntimeDatabase
        private(set) var episodes = 0
        private(set) var last: AcquisitionRunSummary?

        init(coordinator: AcquisitionCoordinator, catalogue: [AcquisitionTarget], database: RuntimeDatabase) {
            self.coordinator = coordinator
            self.catalogue = catalogue
            self.database = database
        }

        func acquire(
            for plan: ResolvedFeedPlan,
            reason: FeedSessionCompositionReason,
            at: Date
        ) async -> AcquisitionRunSummary? {
            episodes += 1
            let summary = await coordinator.run(
                AcquisitionDemand(
                    purpose: .bootstrap,
                    holderID: "owner-swap-test",
                    deficit: SupplyDeficit(items: 24),
                    deadline: at.addingTimeInterval(20)
                ),
                catalogue: catalogue,
                in: database
            )
            last = summary
            return summary
        }

        func state() -> (episodes: Int, last: AcquisitionRunSummary?) { (episodes, last) }
    }

    /// - Parameter bookmarks: the legacy store the session's durable actions write through. A test that
    ///   only reads the acquisition chain can leave it nil; the two durable-action tests pass the on-disk
    ///   container a legacy relaunch reopens.
    private func makeHarness(endpoint: URL, bookmarks: BookmarkStore? = nil) throws -> Harness {
        let clock = SystemEditorialClock()
        let legacyBookmarks: BookmarkStore
        if let bookmarks {
            legacyBookmarks = bookmarks
        } else {
            legacyBookmarks = try FeedStore(inMemory: true).bookmarkStore
        }
        let catalogIdentity = LegacySourceMapper.catalogIdentity(
            key: endpoint.absoluteString,
            normalizedURL: endpoint.absoluteString,
            compactID: CatalogSourceID(0)
        )
        let editorialKey = try LegacySourceMapper.editorialKey(for: catalogIdentity)
        let sourceID = try RuntimeSourceRegistry(clock: clock).sourceID(
            for: editorialKey,
            displayTitle: "Example Channel",
            kind: "syndication",
            in: database
        )
        // The alias store the durable-action projection writes through. `V2Acquisition` also writes the
        // source mapping here in production, but with the catalogue's `none` compact id — which that
        // table's `catalog_source_id > 0` check refuses — so this harness does not pretend to have one:
        // the source URL comes from the allocated `source` row, which is what exists in both places.
        let mappings = LegacyMappingStore()
        let binding = try LegacySourceMapper.binding(
            for: catalogIdentity,
            runtimeSourceID: sourceID,
            endpoint: endpoint.absoluteString
        )
        let enrollment = try SyndicationSourceEnrollment(
            sourceID: sourceID,
            binding: binding.key,
            bindingGeneration: binding.generation
        )

        let targetStore = AcquisitionTargetStore(clock: clock)
        try targetStore.register(
            Self.targetID,
            connectorKind: SyndicationNamespace.connector.rawValue,
            connectorVersion: SyndicationNamespace.connector.rawValue,
            in: database
        )
        let target = AcquisitionTarget(
            id: Self.targetID,
            connectorKind: SyndicationNamespace.connector.rawValue
        )
        let source = SyndicationAcquisitionSource(
            ingredient: SyndicationAcquisitionIngredient(
                target: SyndicationTarget(
                    targetID: Self.targetID,
                    endpoint: endpoint,
                    generation: 1,
                    scope: LegacySourceMapper.objectScope(for: catalogIdentity)
                ),
                transport: PolicyEnforcingHTTPTransport(session: stubSession),
                enrollment: enrollment,
                limits: SyndicationHTTPLimits(),
                backoff: SyndicationBackoffPolicy(),
                clock: clock
            ),
            hostGate: SyndicationHostGateStore()
        )
        let coordinator = AcquisitionCoordinator(
            resolver: AcquisitionSourceResolver { requested in
                requested.id == Self.targetID ? source : nil
            },
            clock: clock
        )
        let owner = EpisodeOwner(coordinator: coordinator, catalogue: [target], database: database)

        let repository = PublicationRepository(database: database)
        let plan = try FeedSurfaceCatalog.resolvedPlan(
            .main,
            inputs: FeedSurfaceCatalog.Inputs(scopeKey: "preset=latest|box=-", planIdentity: "MainFeedPlan"),
            clock: clock
        )
        let contextKey = plan.context
        let compositionPlan = FeedCompositionPlan(
            plan: plan,
            projections: .empty,
            seed: Data("seed-owner-swap-0000000000000".utf8)
        )
        let composer = RuntimeFeedSessionComposer(
            database: database,
            repository: repository,
            plans: FeedPlanSource { context in context == contextKey ? compositionPlan : nil },
            coordinator: PublicationCoordinator(repository: repository, clock: clock),
            acquisition: owner
        )
        let session = FeedSession(
            state: FeedSessionState(
                stamp: SessionStamp(UInt64(Date().timeIntervalSince1970 * 1000)),
                context: contextKey,
                historyScope: plan.historyPolicy.scope,
                historyPolicy: plan.historyPolicy,
                renderEnvironment: try RenderEnvironmentRevision(
                    layoutWidthClass: "compact",
                    dynamicTypeSize: "large",
                    localeIdentifier: "pt_BR",
                    textDirection: "ltr",
                    displayScale: 3
                )
            ),
            repository: repository,
            checkpoints: SessionCheckpointStore(database: database),
            facts: ExposureFactStore(database: database),
            composer: composer,
            userActions: RuntimeCardUserActions(
                cards: repository,
                userState: UserStateBridge(
                    bookmarks: legacyBookmarks,
                    projections: UserStateProjectionStore(database: database)
                ),
                legacy: LegacyContentProjection(
                    bookmarks: legacyBookmarks,
                    mappings: mappings,
                    database: database
                )
            ),
            clock: SystemMonotonicClock(),
            editorialClock: clock
        )
        return Harness(
            session: session,
            coordinator: coordinator,
            owner: owner,
            catalogue: [target],
            contextKey: contextKey,
            database: database,
            repository: repository,
            bookmarks: legacyBookmarks
        )
    }

    /// Every batch row this run wrote, with the fields that distinguish a real second admission from a
    /// no-op receipt, so an unexpected count names itself instead of needing another run to explain it.
    private func describeBatches() throws -> String {
        try database.read { database in
            try String.fetchAll(database, sql: """
                SELECT batch_id || ' result=' || result
                    || ' expected=' || checkpoint_expected
                    || ' written=' || COALESCE(CAST(checkpoint_written AS TEXT), '-')
                    || ' observations=' || observation_count
                    || ' fingerprint=' || substr(fingerprint, 1, 12)
                FROM admission_batch ORDER BY batch_id
                """).joined(separator: " | ")
        }
    }

    private func count(_ table: String) throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    /// Waits for the store's search task to publish, the way the search UI does.
    private func waitForSearch(_ store: FeedStore, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isSearchLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let rss = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Example Channel</title>
          <link>https://example.test/</link>
          <description>A channel</description>
          <item>
            <title>First post</title>
            <link>https://example.test/first</link>
            <guid isPermaLink="false">post-1</guid>
            <pubDate>Mon, 15 Sep 2026 10:00:00 GMT</pubDate>
            <description>An excerpt</description>
            <enclosure url="https://example.test/episode.mp3" length="1234" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """

    private static let twoItemRSS = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Example Channel</title>
          <link>https://example.test/</link>
          <description>A channel</description>
          <item>
            <title>Saved post</title>
            <link>https://example.test/saved</link>
            <pubDate>Mon, 15 Sep 2026 10:00:00 GMT</pubDate>
            <description>The article the reader saves</description>
          </item>
          <item>
            <title>Untouched post</title>
            <link>https://example.test/untouched</link>
            <pubDate>Sun, 14 Sep 2026 10:00:00 GMT</pubDate>
            <description>An article nobody acted on</description>
          </item>
        </channel></rss>
        """

    private static func source(url: String) -> FeedSource {
        FeedSource(title: "Legacy", url: url, category: "News", region: "global")
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }
}

// MARK: - The legacy container a relaunch reopens

/// The two databases the legacy reader opens, on disk.
///
/// On disk rather than in memory because the rollback half of the proof is a *relaunch*: an in-memory
/// queue cannot be reopened, and a second `BookmarkStore` over the same queue object would prove nothing
/// about what survives a process. The schema is the app's own — `FeedStore.migrate` is the legacy
/// content migrator and `UserStateStore(databaseURL:)` is the initializer the migration path itself uses
/// — and the configuration mirrors the one legacy opens with (`FeedStore.dbConfig`: WAL, foreign keys on).
@MainActor
private struct LegacyContainer {
    let userDatabaseURL: URL
    let contentDatabaseURL: URL
    /// The live reader: the same object the session's durable actions write through.
    let bookmarks: BookmarkStore

    init(under directory: URL) throws {
        let root = directory.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        userDatabaseURL = root.appendingPathComponent("user.sqlite")
        contentDatabaseURL = root.appendingPathComponent("feedmine.sqlite")
        let content = try DatabaseQueue(
            path: contentDatabaseURL.path,
            configuration: Self.legacyConfiguration()
        )
        try FeedStore.migrate(content)
        let user = try UserStateStore(databaseURL: userDatabaseURL)
        bookmarks = BookmarkStore(userDB: user.db, contentDB: content)
    }

    /// A reader that has just launched over the same two files: new connections, and no object — no card,
    /// no snapshot, no runtime projection — carried over from the process that wrote them.
    func relaunched() throws -> BookmarkStore {
        BookmarkStore(
            userDB: try DatabaseQueue(
                path: userDatabaseURL.path,
                configuration: Self.legacyConfiguration()
            ),
            contentDB: try DatabaseQueue(
                path: contentDatabaseURL.path,
                configuration: Self.legacyConfiguration()
            )
        )
    }

    private static func legacyConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }
}

// MARK: - Doubles

/// One scripted HTTP answer, recording every request the transport actually made.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static func answer(status: Int, headers: [String: String], body: Data) {
        lock.lock()
        responder = { _ in (status, headers, body) }
        log = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    static func reset() {
        lock.lock()
        responder = nil
        log = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.responder
        let answer: (Int, [String: String], Data)
        if let current {
            Self.lock.lock()
            Self.log.append(request)
            Self.lock.unlock()
            answer = current(request)
        } else {
            answer = (500, [:], Data())
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: answer.0,
                httpVersion: "HTTP/1.1",
                headerFields: answer.1
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.2.isEmpty { client?.urlProtocol(self, didLoad: answer.2) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Counts legacy requests without reaching the network.
actor RecordingFeedTransport: FeedHTTPTransport {
    private var log: [String] = []
    private let body: String?

    init(body: String? = nil) { self.body = body }

    func requestedURLs() -> [String] { log }

    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult {
        log.append(source.url)
        guard let body else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(URLError(.cannotConnectToHost)),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }
        let data = Data(body.utf8)
        return FetchHTTPResult(
            data: data,
            outcome: .success(data),
            updatedValidators: validators,
            canonicalURL: source.url
        )
    }
}
