import XCTest
import GRDB
import FeedDomain
import FeedRuntime
import FeedStorage

/// PR-06, publication: the single append path, single-flight, the tail compare-and-swap, the successor
/// edition and the minimal local media commit (plan §9/§10, ADR-001, ADR-006 D14).
///
/// Supply is built through the real Admission path and the segment through the real Selection and
/// sequencer, so the composition under test is the one the runtime actually produces. `FeedRuntime` may
/// not import `FeedMedia` (plan §3), so the media side is exercised through the `PublishedAssetCommitting`
/// port: the store's own identity and durability rules are proven in `FeedMediaTests/LocalAssetStoreTests`.
final class PublicationCoordinatorTests: SelectionTestCase {
    /// A durable-bytes double: it writes the bytes to a real file and answers with the commit the
    /// publication references. It never touches the database — that is the coordinator's job.
    actor FileWritingAssetCommitter: PublishedAssetCommitting {
        private let root: URL
        private var digests: [String] = []
        private var failures = 0

        init(root: URL) {
            self.root = root
        }

        func failNextCommits(_ count: Int) {
            failures = count
        }

        func commit(_ request: PublishedAssetRequest) async throws -> PublishedAssetCommit {
            if failures > 0 {
                failures -= 1
                throw PublishedAssetCommitError.durabilityFailed("injected")
            }
            let path = "\(request.contentDigest.prefix(2))/\(request.contentDigest)_r\(request.recipeVersion)"
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try request.bytes.write(to: url)
            digests.append(request.contentDigest)
            return PublishedAssetCommit(
                contentDigest: request.contentDigest,
                byteCount: request.bytes.count,
                recipeVersion: request.recipeVersion,
                mimeType: request.mimeType,
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight,
                relativePath: path
            )
        }

        func committedDigests() -> [String] { digests }

        func fileExists(forDigest digest: String, recipeVersion: Int) -> Bool {
            let path = "\(digest.prefix(2))/\(digest)_r\(recipeVersion)"
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
    }

    /// The same double, but the first commit blocks until the test releases it, so the in-flight state
    /// of a composition can be observed without sleeping.
    actor GatedAssetCommitter: PublishedAssetCommitting {
        private var holding = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func holdNextCommit() { holding = true }

        func release() {
            holding = false
            let pending = held
            held = []
            for continuation in pending { continuation.resume() }
        }

        /// Waits until a commit has entered, without polling.
        func waitUntilHolding() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in waiters.append(continuation) }
        }

        func commit(_ request: PublishedAssetRequest) async throws -> PublishedAssetCommit {
            entered = true
            let waiting = waiters
            waiters = []
            for continuation in waiting { continuation.resume() }
            if holding {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    held.append(continuation)
                }
            }
            return PublishedAssetCommit(
                contentDigest: request.contentDigest,
                byteCount: request.bytes.count,
                recipeVersion: request.recipeVersion,
                mimeType: request.mimeType,
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight,
                relativePath: "\(request.contentDigest.prefix(2))/\(request.contentDigest)_r\(request.recipeVersion)"
            )
        }
    }

    struct Prepared {
        let plan: ResolvedFeedPlan
        let sequence: EditorialSequence
        let edition: EditionSnapshot
    }

    // MARK: - Fixtures

    private func coordinator(
        assets: (any PublishedAssetCommitting)? = nil,
        singleFlight: PublicationSingleFlight = PublicationSingleFlight(),
        pins: DraftPins = DraftPins(),
        in runtime: SelectionRuntime? = nil
    ) -> PublicationCoordinator {
        PublicationCoordinator(
            repository: PublicationRepository(database: fixtureRuntime(runtime).database),
            clock: clock,
            assets: assets,
            singleFlight: singleFlight,
            draftPins: pins
        )
    }

    private func fixtureRuntime(_ runtime: SelectionRuntime?) -> SelectionRuntime {
        runtime ?? primary
    }

    /// Admits supply, selects it and sequences it, then opens the first edition and captures its token:
    /// everything a real publication does before the long work starts.
    private func prepare(
        count: Int = 3,
        cardLimit: Int = 2,
        mediaRoles: [MediaRole] = [],
        objectPrefix: String = "item",
        into runtime: SelectionRuntime? = nil
    ) throws -> Prepared {
        let runtime = fixtureRuntime(runtime)
        let source = try insertSource("catalog:alpha", into: runtime)
        try admitItems(
            count,
            prefix: objectPrefix,
            source: source,
            mediaRoles: mediaRoles,
            into: runtime
        )
        let key = try sourceKey("catalog:alpha")
        let projections = projections(catalogKeys: [key])
        let plan = try makePlan(
            sourceSelection: [SourceSelection(sourceKey: key, enabled: true)],
            budget: try makeBudget(cardLimit: cardLimit, poolLimit: 8, providerQuota: 8)
        )
        let resolved = try resolver.resolve(plan, projections: projections)
        let draft = try engine.draft(
            plan: resolved,
            projections: projections,
            seed: Data("seed-0000000000000000000000000000".utf8),
            in: runtime.database
        )
        let sequence = sequencer.sequence(draft: draft, plan: resolved)
        let opening = try coordinator(in: runtime).openEdition(
            .first(epoch: 1),
            plan: resolved,
            seed: sequence.seed,
            at: clockDate
        )
        return Prepared(plan: resolved, sequence: sequence, edition: opening.edition)
    }

    private func request(
        _ prepared: Prepared,
        token: PublicationToken,
        media: [PublishedCardMediaPlan] = [],
        activation: SegmentActivation? = nil
    ) -> PublicationRequest {
        PublicationRequest(
            plan: prepared.plan,
            sequence: prepared.sequence,
            token: token,
            media: media,
            activation: activation
        )
    }

    /// A media plan whose single entry is prepared bytes for `role`.
    private func preparedMedia(
        revision: OriginRevisionID,
        role: MediaRole = .image,
        bytes: Data = Data("synthetic-asset-bytes".utf8),
        digest: String = String(repeating: "ab", count: 32),
        in runtime: SelectionRuntime? = nil
    ) throws -> PublishedCardMediaPlan {
        let content = try XCTUnwrap(
            try PublicationRepository(database: fixtureRuntime(runtime).database)
                .cardContent(originRevisionID: revision)
        )
        let position = content.mediaCandidates.first { $0.role == role }?.position ?? 0
        let asset = try PublishedAssetRequest(
            candidateKey: "\(role.rawValue)#\(position)",
            role: role,
            bytes: bytes,
            contentDigest: digest,
            recipeVersion: 1,
            mimeType: "image/png",
            pixelWidth: 600,
            pixelHeight: 200
        )
        return PublishedCardMediaPlan(originRevisionID: revision, entries: [.prepared(asset)])
    }

    private func repository(in runtime: SelectionRuntime? = nil) -> PublicationRepository {
        PublicationRepository(database: fixtureRuntime(runtime).database)
    }

    /// Closes the pool and opens the database from disk again, as the next launch of the process would.
    private func reopenPrimaryDatabase() throws -> (RuntimeDatabase, PublicationRepository) {
        try primary.database.pool.close()
        let reopened = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        return (reopened, PublicationRepository(database: reopened))
    }

    private func assertPublicationIntegrity(label: String, in database: RuntimeDatabase? = nil) throws {
        let report = try PublicationRepository(database: database ?? primary.database).integrityReport()
        XCTAssertTrue(report.isHealthy, "\(label): \(report.summary)")
    }

    // MARK: - Reads used as evidence

    /// The tables only `PublicationCoordinator` may append to.
    static let publicationTables = [
        "feed_edition",
        "feed_segment",
        "published_card",
        "published_asset_ref",
        "asset_version",
        "media_preparation",
    ]

    private func scalar(_ sql: String, in database: RuntimeDatabase? = nil) throws -> Int64 {
        try (database ?? primary.database).read { try Int64.fetchOne($0, sql: sql) ?? 0 }
    }

    private func string(_ sql: String, in database: RuntimeDatabase? = nil) throws -> String? {
        try (database ?? primary.database).read { try String.fetchOne($0, sql: sql) }
    }

    private func rowCount(_ table: String, in database: RuntimeDatabase? = nil) throws -> Int {
        Int(try scalar("SELECT COUNT(*) FROM \(table)", in: database))
    }

    /// One card's whole row as a comparable value: a byte-level check that nothing was rewritten.
    private func cardRow(_ cardID: PublicationCardID) throws -> String? {
        try primary.database.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT * FROM published_card WHERE publication_card_id = ?",
                arguments: [cardID.rawValue]
            ).map { row in
                Array(zip(row.columnNames, row.databaseValues))
                    .map { "\($0.0)=\($0.1)" }
                    .joined(separator: ",")
            }
        }
    }

    /// Every row of the given tables, ordered by their first column, so two dumps compare as values.
    private func dump(_ tables: [String], in database: RuntimeDatabase? = nil) throws -> [String] {
        try (database ?? primary.database).read { database in
            var lines: [String] = []
            for table in tables {
                let rows = try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY 1")
                lines.append("\(table)=\(rows.count)")
                for row in rows {
                    lines.append(
                        Array(zip(row.columnNames, row.databaseValues))
                            .map { "\($0.0)=\($0.1)" }
                            .joined(separator: ",")
                    )
                }
            }
            return lines
        }
    }

    // MARK: - Single writer

    /// `connectorAndMediaCannotAppendSegments` (plan §19 #26; ADR-001 D1, I-04/I-10, INV-4).
    ///
    /// The three components that could plausibly want to append — the connector-side Admission path,
    /// Selection and media preparation — fill every other table and leave the published log empty. Only
    /// `PublicationCoordinator.publish` appends, and it appends exactly what it was given.
    func testConnectorAndMediaCannotAppendSegments() async throws {
        let committer = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets"))
        let prepared = try prepare(count: 3, cardLimit: 2, mediaRoles: [.image])
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID

        // Media preparation commits bytes and no publication row: a store has no insert path at all.
        _ = try await committer.commit(
            try PublishedAssetRequest(
                candidateKey: "image#0",
                role: .image,
                bytes: Data("bytes".utf8),
                contentDigest: String(repeating: "cd", count: 32),
                recipeVersion: 1,
                mimeType: "image/png"
            )
        )
        for table in ["feed_segment", "published_card", "published_asset_ref", "asset_version", "media_preparation"] {
            XCTAssertEqual(
                try rowCount(table),
                0,
                "\(table) must stay empty: no component but PublicationCoordinator appends"
            )
        }
        // The only edition row is the draft the coordinator itself opened, and it has no history yet.
        XCTAssertEqual(try rowCount("feed_edition"), 1)
        XCTAssertEqual(try string("SELECT state FROM feed_edition"), "draft")
        XCTAssertEqual(try scalar("SELECT version FROM feed_edition"), 0)
        XCTAssertEqual(try scalar("SELECT tail_segment_ordinal FROM feed_edition"), -1)
        XCTAssertEqual(try rowCount("origin_record"), 3, "the connector's content is canonical supply")
        XCTAssertEqual(try rowCount("selection_supply"), 3, "Selection read a complete pool")
        XCTAssertFalse(prepared.sequence.cards.isEmpty)

        // An append needs a token the coordinator issued. A fabricated one names no edition, so the
        // repository refuses it and the log stays exactly as it was.
        let logBefore = try dump(Self.publicationTables)
        let fabricated = PublicationToken(
            editionID: try EditionID(9_999),
            epoch: 1,
            editorialRevision: prepared.plan.editorialRevision,
            tail: .empty
        )
        XCTAssertThrowsError(
            try PublicationRepository(database: database).commit(
                SegmentCommitRequest(
                    token: fabricated,
                    segmentOrdinal: 0,
                    absoluteOrdinalStart: 0,
                    segmentSeed: Data("seed".utf8),
                    policyRevision: fabricated.editorialRevision.digest,
                    committedAt: clockDate,
                    activation: .activate(successorOf: nil),
                    cards: [],
                    assets: [],
                    mediaPreparations: [],
                    pinnedRevisions: []
                )
            )
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .emptySequence(fabricated.editionID))
        }
        XCTAssertEqual(try dump(Self.publicationTables), logBefore)

        // The append happens here and nowhere else.
        let outcome = await coordinator(assets: committer).publish(
            request(
                prepared,
                token: prepared.edition.token,
                media: [try preparedMedia(revision: revision, role: .image, digest: String(repeating: "cd", count: 32))]
            )
        )
        let receipt = try XCTUnwrap(outcome.receipt, "publish must append")
        XCTAssertEqual(receipt.segmentOrdinal, 0)
        XCTAssertEqual(receipt.cardIDs.count, prepared.sequence.cards.count)
        XCTAssertEqual(try rowCount("feed_segment"), 1)
        XCTAssertEqual(try rowCount("published_card"), prepared.sequence.cards.count)
        XCTAssertEqual(try rowCount("feed_edition"), 1)
        try assertPublicationIntegrity(label: "after the only append")
    }

    /// `twoCoordinatorsCannotCommitSameTail` (plan §19 #27; ADR-001 D3, ADR-006 D14, INV-5).
    ///
    /// The name is the contract: of two coordinator instances that captured the same tail, at most one
    /// commits, the other is refused with a *typed* refusal, nothing partial is written and the database
    /// stays integral. The reason is asserted precisely only where the scenario makes it inevitable —
    /// round two races on an edition whose state cannot change, so the loser can only be refused by the
    /// tail.
    func testTwoCoordinatorsCannotCommitSameTail() async throws {
        let prepared = try prepare(count: 4, cardLimit: 3)
        let coordinatorA = coordinator()
        let coordinatorB = coordinator()
        let cardsPerSegment = prepared.sequence.cards.count
        let draftToken = try coordinatorA.token(for: prepared.edition.editionID)
        XCTAssertEqual(
            try coordinatorB.token(for: prepared.edition.editionID),
            draftToken,
            "both instances captured the same tail, which is the case the CAS exists for"
        )

        // Round one: the edition is a draft, so whichever commit wins also activates it. The loser's
        // refusal may therefore be reported either by the tail (the winner's version moved) or by the
        // state (the winner's commit is what made the edition active) — both are honest typed refusals,
        // so the assertion is on the set, not on one literal classification.
        let draftRequest = request(prepared, token: draftToken)
        async let first = coordinatorA.publish(draftRequest)
        async let second = coordinatorB.publish(draftRequest)
        let outcomes = [await first, await second]

        XCTAssertEqual(outcomes.compactMap(\.receipt).count, 1, "at most one commit wins a tail")
        let refusal = try XCTUnwrap(outcomes.compactMap(\.failure).first)
        XCTAssertEqual(outcomes.compactMap(\.failure).count, 1, "the other instance is refused")
        switch refusal {
        case .tailMismatch, .editionNotActive:
            break
        default:
            XCTFail("the loser must be refused by the tail or by the edition's state, got \(refusal)")
        }
        let winner = try XCTUnwrap(outcomes.compactMap(\.receipt).first)
        XCTAssertTrue(winner.activated, "the winner's segment is what makes the edition visible")

        // Nothing partial was written: exactly the winner's segment and cards, and no duplicate ordinal.
        XCTAssertEqual(try rowCount("feed_segment"), 1, "one segment, whichever instance won")
        XCTAssertEqual(try rowCount("published_card"), cardsPerSegment)
        XCTAssertEqual(
            try scalar("""
                SELECT COUNT(*) FROM (
                    SELECT edition_id, absolute_ordinal FROM published_card
                    GROUP BY edition_id, absolute_ordinal HAVING COUNT(*) > 1
                )
                """),
            0,
            "no duplicate absolute_ordinal: the schema's uniqueness is the backstop"
        )
        try assertPublicationIntegrity(label: "after the first race")

        // Round two: the edition is active and an append changes no state, so the loser's refusal can
        // only be the tail it no longer holds.
        let activeToken = try coordinatorA.token(for: prepared.edition.editionID)
        XCTAssertEqual(activeToken.tail.version, draftToken.tail.version + 1)
        XCTAssertEqual(activeToken.tail.nextSegmentOrdinal, 1)
        let appendRequest = request(prepared, token: activeToken)
        async let third = coordinatorA.publish(appendRequest)
        async let fourth = coordinatorB.publish(appendRequest)
        let secondRound = [await third, await fourth]

        XCTAssertEqual(secondRound.compactMap(\.receipt).count, 1, "still at most one winner per tail")
        guard case let .tailMismatch(expected, actual) = try XCTUnwrap(secondRound.compactMap(\.failure).first) else {
            return XCTFail("an append race must be refused by the tail, got \(secondRound)")
        }
        XCTAssertEqual(expected, activeToken.tail)
        XCTAssertEqual(actual.version, activeToken.tail.version + 1)
        XCTAssertEqual(try rowCount("feed_segment"), 2)
        XCTAssertEqual(try rowCount("published_card"), 2 * cardsPerSegment)
        try assertPublicationIntegrity(label: "after the append race")

        // The loser recomposes against the tail the winner left; the discarded composition is never
        // renumbered into the gap it would have filled.
        let fresh = try coordinatorB.token(for: prepared.edition.editionID)
        XCTAssertEqual(fresh.tail.version, activeToken.tail.version + 1)
        XCTAssertEqual(fresh.tail.nextSegmentOrdinal, 2)
        let retry = await coordinatorB.publish(request(prepared, token: fresh))
        let receipt = try XCTUnwrap(retry.receipt, "the loser must be able to publish against the new tail")
        XCTAssertEqual(receipt.segmentOrdinal, 2)
        XCTAssertEqual(receipt.absoluteOrdinalStart, 2 * cardsPerSegment)
        XCTAssertEqual(try rowCount("feed_segment"), 3)
        XCTAssertEqual(try rowCount("published_card"), 3 * cardsPerSegment)
        try assertPublicationIntegrity(label: "after the loser retried")
    }

    /// Single-flight: a second composition for the edition already in flight is refused in this
    /// coordinator, and the tail is what protects two independent coordinators (ADR-006 D14).
    func testSingleFlightRefusesASecondCompositionForTheSameEdition() async throws {
        let committer = GatedAssetCommitter()
        await committer.holdNextCommit()
        let pins = DraftPins()
        let singleFlight = PublicationSingleFlight()
        let prepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.image])
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID
        let coordinator = coordinator(assets: committer, singleFlight: singleFlight, pins: pins)
        let media = [try preparedMedia(revision: revision, role: .image)]

        let inFlightRequest = request(prepared, token: prepared.edition.token, media: media)
        async let inFlightPublish = coordinator.publish(inFlightRequest)
        await committer.waitUntilHolding()
        let inFlight = await singleFlight.inFlightEditions()
        XCTAssertEqual(inFlight, [prepared.edition.editionID], "the composition holds the edition")
        let pinnedWhilePreparing = await pins.pinnedCount()
        XCTAssertEqual(pinnedWhilePreparing, prepared.sequence.cards.count)

        let second = await coordinator.publish(request(prepared, token: prepared.edition.token))
        XCTAssertEqual(second, .alreadyInFlight(prepared.edition.editionID))

        await committer.release()
        let outcome = await inFlightPublish
        XCTAssertNotNil(outcome.receipt)
        let afterSuccess = await singleFlight.inFlightEditions()
        XCTAssertEqual(afterSuccess, [], "the flight ends with the composition")
        let pinsAfterSuccess = await pins.pinnedCount()
        XCTAssertEqual(pinsAfterSuccess, 0, "every exit path releases the draft pins")
    }

    /// Draft pins are held across media preparation and released when the commit is refused
    /// (ADR-002 D11): eviction must not remove a revision a composition is about to freeze.
    func testDraftPinsAreHeldAcrossMediaPreparationAndReleasedOnRefusal() async throws {
        let committer = GatedAssetCommitter()
        await committer.holdNextCommit()
        let pins = DraftPins()
        let prepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.image])
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID
        let coordinator = coordinator(assets: committer, pins: pins)

        let media = [try preparedMedia(revision: revision, role: .image)]
        async let publish = coordinator.publish(
            PublicationRequest(
                plan: prepared.plan,
                sequence: prepared.sequence,
                token: prepared.edition.token,
                media: media
            )
        )
        await committer.waitUntilHolding()

        let pinned = await pins.pinnedRevisions()
        XCTAssertEqual(pinned.count, prepared.sequence.cards.count)
        XCTAssertEqual(
            pinned,
            prepared.sequence.cards.map(\.choice.originRevisionID).sorted { $0.rawValue < $1.rawValue }
        )
        let isPinned = await pins.isPinned(revision)
        XCTAssertTrue(isPinned)

        await committer.release()
        let committed = await publish
        XCTAssertNotNil(committed.receipt)
        let pinsAfterSuccess = await pins.pinnedCount()
        XCTAssertEqual(pinsAfterSuccess, 0)

        // A refused composition releases its pins too: a tail conflict discards the composition.
        let refusedRequest = PublicationRequest(
            plan: prepared.plan,
            sequence: prepared.sequence,
            token: prepared.edition.token,
            media: media
        )
        async let refused = coordinator.publish(refusedRequest)
        let outcome = await refused
        guard case .tailMismatch = try XCTUnwrap(outcome.failure) else {
            return XCTFail("the stale token must be refused, got \(outcome)")
        }
        let pinsAfterRefusal = await pins.pinnedCount()
        XCTAssertEqual(pinsAfterRefusal, 0, "a discarded composition leaves no pin behind")
    }

    // MARK: - Successor editions

    /// `failedRefreshKeepsPreviousEditionVisible` (plan §19 #25; ADR-001 D7, INV-14).
    ///
    /// A refresh that fails at each stage — media, storage, tail — leaves exactly one active edition:
    /// the previous one, still navigable, with its cards intact.
    func testFailedRefreshKeepsPreviousEditionVisible() async throws {
        let prepared = try prepare(count: 3, cardLimit: 2, mediaRoles: [.image])
        let visible = coordinator()
        let firstOutcome = await visible.publish(request(prepared, token: prepared.edition.token))
        let firstReceipt = try XCTUnwrap(firstOutcome.receipt)
        let activeBefore = try XCTUnwrap(repository().activeEdition(for: prepared.plan.context))
        let cardsBefore = try repository().cards(in: prepared.edition.editionID).map(\.payload)
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID

        // Stage 1: media preparation fails. Stage 2: storage fails inside the commit.
        let failingMedia = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets"))
        await failingMedia.failNextCommits(1)
        let media = [try preparedMedia(revision: revision, role: .image)]
        let openSuccessor = try visible.openEdition(
            .successor,
            plan: prepared.plan,
            seed: prepared.sequence.seed,
            at: clockDate
        )
        XCTAssertTrue(openSuccessor.created)
        XCTAssertEqual(openSuccessor.edition.epoch, activeBefore.epoch + 1)

        let mediaFailure = await coordinator(assets: failingMedia).publish(
            request(prepared, token: openSuccessor.edition.token, media: media)
        )
        guard case .assetCommitFailed = try XCTUnwrap(mediaFailure.failure) else {
            return XCTFail("a failed media commit must refuse the publication, got \(mediaFailure)")
        }
        try assertRefreshKeptThePreviousEdition(prepared: prepared, activeBefore: activeBefore, cardsBefore: cardsBefore)

        // Stage 3: a storage failure with no retry left. The previous edition is still the visible one.
        let interrupted = PublicationCoordinator(
            repository: PublicationRepository(
                database: database,
                faults: PublicationRepository.Faults(point: .storageFailureAtCommit)
            ),
            clock: clock,
            configuration: PublicationCoordinator.Configuration(commitRetryLimit: 0)
        )
        let storageFailure = await interrupted.publish(
            request(prepared, token: openSuccessor.edition.token)
        )
        XCTAssertNotNil(storageFailure.failure, "a storage failure keeps the previous edition visible")
        try assertRefreshKeptThePreviousEdition(prepared: prepared, activeBefore: activeBefore, cardsBefore: cardsBefore)

        // Stage 4: the successor's first segment commits, but the activation swap dies with it, so the
        // whole successor rolls back — a successor is visible only with its first segment (INV-14).
        let activationFails = PublicationCoordinator(
            repository: PublicationRepository(
                database: database,
                faults: PublicationRepository.Faults(point: .beforeActivation)
            ),
            clock: clock
        )
        let activationFailure = await activationFails.publish(
            request(prepared, token: openSuccessor.edition.token)
        )
        XCTAssertNotNil(activationFailure.failure)
        try assertRefreshKeptThePreviousEdition(prepared: prepared, activeBefore: activeBefore, cardsBefore: cardsBefore)

        // A token that no longer names the tail is refused by the CAS, not renumbered.
        let winner = try repository().token(for: prepared.edition.editionID)
        XCTAssertNotEqual(openSuccessor.edition.token, winner)
        XCTAssertNotEqual(firstReceipt.tail.version, openSuccessor.edition.token.tail.version)
        let conflict = await visible.publish(request(prepared, token: prepared.edition.token))
        guard case .tailMismatch = try XCTUnwrap(conflict.failure) else {
            return XCTFail("a moved tail must be refused, got \(conflict)")
        }
        try assertRefreshKeptThePreviousEdition(prepared: prepared, activeBefore: activeBefore, cardsBefore: cardsBefore)

        // The uncommitted successor is not history: abandoning it changes nothing visible.
        XCTAssertTrue(try visible.abandonUncommittedEdition(openSuccessor.edition.editionID))
        XCTAssertEqual(try repository().activeEdition(for: prepared.plan.context), activeBefore)
        XCTAssertTrue(firstReceipt.activated)
    }

    private func assertRefreshKeptThePreviousEdition(
        prepared: Prepared,
        activeBefore: EditionSnapshot,
        cardsBefore: [PublishedCardPayload],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let repository = repository()
        XCTAssertEqual(
            try repository.activeEditions().count,
            1,
            "a failed refresh leaves exactly one active edition",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try repository.activeEdition(for: prepared.plan.context),
            activeBefore,
            "the previous edition is still the visible one, unchanged",
            file: file,
            line: line
        )
        guard case let .restored(_, records) = try repository.restore(context: prepared.plan.context) else {
            return XCTFail("the previous edition must stay restorable", file: file, line: line)
        }
        XCTAssertEqual(records.map(\.payload), cardsBefore, file: file, line: line)
    }

    /// A successor is built first and swapped in one transaction, so the previous edition keeps its
    /// history and the new one becomes visible only with content (ADR-001 D7).
    func testRefreshBuildsTheSuccessorSegmentBeforeTheSwap() async throws {
        let prepared = try prepare(count: 3, cardLimit: 2)
        let coordinator = self.coordinator()
        _ = await coordinator.publish(request(prepared, token: prepared.edition.token))

        let successor = try coordinator.openEdition(
            .successor,
            plan: prepared.plan,
            seed: prepared.sequence.seed,
            at: clockDate
        )
        XCTAssertEqual(successor.edition.state, .draft)
        XCTAssertEqual(try repository().activeEditions().count, 1, "a draft is not visible")

        // Reopening the successor returns the same draft instead of stacking editions.
        let reopened = try coordinator.openEdition(
            .successor,
            plan: prepared.plan,
            seed: prepared.sequence.seed,
            at: clockDate
        )
        XCTAssertFalse(reopened.created)
        XCTAssertEqual(reopened.edition.editionID, successor.edition.editionID)

        let swapOutcome = await coordinator.publish(
            request(
                prepared,
                token: successor.edition.token,
                activation: .activate(successorOf: prepared.edition.editionID)
            )
        )
        let receipt = try XCTUnwrap(swapOutcome.receipt)
        XCTAssertTrue(receipt.activated)
        XCTAssertEqual(try repository().activeEditions().count, 1)
        XCTAssertEqual(
            try repository().activeEdition(for: prepared.plan.context)?.editionID,
            successor.edition.editionID
        )
        XCTAssertEqual(try string("SELECT state FROM feed_edition WHERE edition_id = 1"), "superseded")
        XCTAssertEqual(
            try repository().cards(in: prepared.edition.editionID).count,
            prepared.sequence.cards.count,
            "the previous edition keeps every card it published"
        )
        try assertPublicationIntegrity(label: "after the swap")
    }

    // MARK: - Media

    /// `offlineCardDoesNotRequireRemotePlaybackAsset` (plan §19 #22; ADR-001 D10, D14, INV-11).
    ///
    /// A card whose revision declares playback media and a still image, with nothing prepared, publishes
    /// deterministic text, a placeholder that keeps the declared geometry, and no asset bytes at all: the
    /// card renders offline, and no published column names a URL.
    func testOfflineCardDoesNotRequireRemotePlaybackAsset() async throws {
        let prepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.audio, .video, .thumbnail])
        let outcome = await coordinator().publish(request(prepared, token: prepared.edition.token))
        let receipt = try XCTUnwrap(outcome.receipt, "publication must not need media bytes")
        XCTAssertEqual(receipt.cardIDs.count, prepared.sequence.cards.count)

        XCTAssertEqual(try rowCount("asset_version"), 0, "no remote playback asset was needed")
        XCTAssertEqual(try rowCount("published_asset_ref"), 0)
        for record in try repository().cards(in: prepared.edition.editionID) {
            let payload = record.payload
            XCTAssertNil(payload.media.primary, "an integral audio/video asset is never a prerequisite")
            XCTAssertFalse(payload.media.requiresMediaBytes)
            XCTAssertEqual(payload.renderContract.kind, RenderKind.thumb)
            XCTAssertEqual(payload.renderContract.mediaSlot, MediaSlot.thumbnail)
            XCTAssertFalse(payload.renderContract.isTextOnly)
            let placeholder = try XCTUnwrap(payload.media.placeholder)
            XCTAssertEqual(placeholder.slot, MediaSlot.thumbnail)
            XCTAssertEqual(placeholder.recipeVersion, PublishedPlaceholder.currentRecipeVersion)
            XCTAssertEqual(placeholder.seed, PublishedPlaceholder(
                originRevisionID: payload.origin.originRevisionID,
                slot: .thumbnail,
                aspectRatio: placeholder.aspectRatio
            ).seed)
            XCTAssertNil(payload.primaryAction, "no action is synthesized")
            XCTAssertFalse(
                String(describing: payload).contains("http"),
                "a published payload names no URL"
            )
        }
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM published_card WHERE primary_action_kind = 'externalURL'"),
            0
        )

        // The media decision is recorded per candidate, and integral media is recorded as not needed.
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID
        let preparations = try repository().mediaPreparations(originRevisionID: revision)
        XCTAssertEqual(preparations.count, 3)
        XCTAssertEqual(
            preparations.filter { $0.state == .noMedia }.map(\.role).sorted { $0.rawValue < $1.rawValue },
            [.audio, .video]
        )
        XCTAssertEqual(preparations.filter { $0.state == .placeholder }.map(\.role), [.thumbnail])

        // Text only is reachable too: a revision that declares nothing renderable needs no media slot,
        // and the card is complete without one.
        let textRuntime = try makeSecondary(named: "text-only")
        let textOnly = try prepare(count: 1, cardLimit: 1, mediaRoles: [], objectPrefix: "text", into: textRuntime)
        let textOutcome = await coordinator(in: textRuntime).publish(
            request(textOnly, token: textOnly.edition.token)
        )
        XCTAssertNotNil(textOutcome.receipt)
        let textPayload = try XCTUnwrap(
            repository(in: textRuntime).cards(in: textOnly.edition.editionID).first?.payload
        )
        XCTAssertTrue(textPayload.renderContract.isTextOnly)
        XCTAssertEqual(textPayload.renderContract.mediaSlot, MediaSlot.none)
        XCTAssertEqual(textPayload.media, PublishedMediaSet.none)
        XCTAssertNil(textPayload.media.placeholder)

        // Prepared bytes for integral media are made durable but never referenced: a card does not need
        // them, and no `asset_version` row claims they were published (ADR-001 D10, ADR-004 D13).
        let integralRuntime = try makeSecondary(named: "integral-media")
        let committer = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets-integral"))
        let integral = try prepare(count: 1, cardLimit: 1, mediaRoles: [.audio], objectPrefix: "audio", into: integralRuntime)
        let integralRevision = try XCTUnwrap(integral.sequence.cards.first).choice.originRevisionID
        let integralOutcome = await coordinator(assets: committer, in: integralRuntime).publish(
            request(
                integral,
                token: integral.edition.token,
                media: [try preparedMedia(revision: integralRevision, role: .audio, in: integralRuntime)]
            )
        )
        let integralReceipt = try XCTUnwrap(integralOutcome.receipt)
        XCTAssertEqual(try rowCount("asset_version", in: integralRuntime.database), 0)
        XCTAssertEqual(try rowCount("published_asset_ref", in: integralRuntime.database), 0)
        let bytesWereCommitted = await committer.committedDigests().count
        XCTAssertEqual(bytesWereCommitted, 1, "the bytes were made durable, they are simply not referenced")
        let integralPayload = try XCTUnwrap(
            repository(in: integralRuntime).card(integralReceipt.cardIDs[0])?.payload
        )
        XCTAssertTrue(integralPayload.renderContract.isTextOnly)
        XCTAssertEqual(
            try repository(in: integralRuntime).mediaPreparations(originRevisionID: integralRevision)
                .map(\.state),
            [.noMedia]
        )
    }

    /// A published payload keeps its geometry when the bytes were never prepared: the placeholder is a
    /// deterministic function of the copied revision identity, the slot and the declared aspect ratio.
    func testPlaceholderPublicationIsDeterministicAcrossLaunches() async throws {
        let prepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.thumbnail])
        _ = await coordinator().publish(request(prepared, token: prepared.edition.token))
        let before = try repository().cards(in: prepared.edition.editionID)

        // Two independent databases built from the same fixture, and a reopen of the first: the
        // placeholder must not move in any of them (no per-process hash, no clock, no URL).
        let secondary = try makeSecondary(named: "determinism")
        let other = try prepare(count: 2, cardLimit: 2, mediaRoles: [.thumbnail], into: secondary)
        _ = await coordinator(in: secondary).publish(request(other, token: other.edition.token))
        let otherCards = try repository(in: secondary).cards(in: other.edition.editionID)

        XCTAssertEqual(
            before.map { $0.payload.media.placeholder },
            otherCards.map { $0.payload.media.placeholder },
            "the same card and recipe produce the same placeholder in an independent run"
        )
        XCTAssertEqual(
            before.map(\.payload.renderContract),
            otherCards.map(\.payload.renderContract)
        )
        XCTAssertEqual(
            before.map { $0.payload.frozenDigest() },
            otherCards.map { $0.payload.frozenDigest() },
            "the frozen bytes of the card agree too"
        )

        // A later composition of the same content in the same database agrees too.
        let again = try repository().cards(in: prepared.edition.editionID)
        XCTAssertEqual(again.map(\.payload), before.map(\.payload))
    }

    /// `lateMediaResolutionDoesNotRewritePublishedCard` (ADR-001 named test; D4, Blueprint §55).
    ///
    /// Bytes that arrive after the card was published become a *new* card in a new segment; the card
    /// that is already visible keeps its payload, its media identity and its ordinal.
    func testLateMediaResolutionDoesNotRewritePublishedCard() async throws {
        let committer = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets"))
        let prepared = try prepare(count: 3, cardLimit: 2, mediaRoles: [.image])
        let coordinator = coordinator(assets: committer)
        let first = await coordinator.publish(request(prepared, token: prepared.edition.token))
        let firstReceipt = try XCTUnwrap(first.receipt)
        let earlier = try repository().card(firstReceipt.cardIDs[0])
        let earlierRow = try cardRow(firstReceipt.cardIDs[0])
        XCTAssertNil(earlier?.payload.media.primary, "the card was published without its bytes")

        // The bytes resolve later. The publication of the *next* segment references them.
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID
        let fresh = try coordinator.token(for: prepared.edition.editionID)
        let later = await coordinator.publish(
            request(
                prepared,
                token: fresh,
                media: [try preparedMedia(revision: revision, role: .image)]
            )
        )
        let receipt = try XCTUnwrap(later.receipt)
        XCTAssertEqual(receipt.segmentOrdinal, 1)
        XCTAssertEqual(receipt.absoluteOrdinalStart, 2)

        // The card that was already visible is byte-identical: no late upgrade, ever.
        let unchanged = try repository().card(firstReceipt.cardIDs[0])
        XCTAssertEqual(unchanged?.payload, earlier?.payload)
        XCTAssertEqual(unchanged?.payloadDigest, earlier?.payloadDigest)
        XCTAssertEqual(unchanged?.payload.absoluteOrdinal, 0)
        XCTAssertNil(unchanged?.payload.media.primary)
        XCTAssertEqual(
            try cardRow(firstReceipt.cardIDs[0]),
            earlierRow,
            "every frozen column of the earlier card is unchanged: the log grew, it was not rewritten"
        )

        // The new card carries the asset identity, and the bytes are referenced exactly once.
        let newest = try repository().card(receipt.cardIDs[0])
        XCTAssertEqual(newest?.payload.media.primary?.contentDigest, String(repeating: "ab", count: 32))
        XCTAssertEqual(newest?.payload.media.primary?.recipeVersion, 1)
        XCTAssertEqual(try rowCount("published_asset_ref"), 1)
        XCTAssertEqual(try rowCount("asset_version"), 1)
        let committedDigests = await committer.committedDigests()
        XCTAssertEqual(committedDigests.count, 1, "one identity, committed once")
    }

    /// A prepared asset must be durable *before* the reference exists. A publish that dies between the
    /// file write and the commit leaves no row naming it, and the bytes are a collectable orphan
    /// (ADR-001 D11, ADR-004 D10, INV-7).
    func testCrashBetweenFileWriteAndCommitLeavesNoReference() async throws {
        let committer = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets"))
        let prepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.image])
        let revision = try XCTUnwrap(prepared.sequence.cards.first).choice.originRevisionID
        let digest = String(repeating: "ab", count: 32)
        let media = [try preparedMedia(revision: revision, role: .image, digest: digest)]

        let interrupted = PublicationCoordinator(
            repository: PublicationRepository(
                database: database,
                faults: PublicationRepository.Faults(point: .afterSegmentInsert)
            ),
            clock: clock,
            assets: committer
        )
        let outcome = await interrupted.publish(
            request(prepared, token: prepared.edition.token, media: media)
        )
        XCTAssertNotNil(outcome.failure)

        // The bytes really were written before the transaction, and nothing names them.
        let fileWasWritten = await committer.fileExists(forDigest: digest, recipeVersion: 1)
        XCTAssertTrue(fileWasWritten, "the asset was made durable before the commit, as ADR-001 D11 requires")
        XCTAssertEqual(try rowCount("asset_version"), 0, "the transaction rolled the row back")
        XCTAssertEqual(try rowCount("published_asset_ref"), 0)
        XCTAssertEqual(try rowCount("published_card"), 0)
        XCTAssertEqual(try repository().unreferencedAssetVersionIDs(), [], "there is no row to collect")
        XCTAssertEqual(
            try scalar("""
                SELECT COUNT(*) FROM published_asset_ref r
                LEFT JOIN asset_version a ON a.asset_version_id = r.asset_version_id
                WHERE a.asset_version_id IS NULL
                """),
            0,
            "no reference can name bytes that were never committed"
        )

        let (reopened, repository) = try reopenPrimaryDatabase()
        try assertPublicationIntegrity(label: "after the crash between the file and the commit", in: reopened)
        XCTAssertEqual(try rowCount("asset_version", in: reopened), 0)

        // The orphan is reused, never adopted retroactively: the same identity is committed once.
        _ = try await committer.commit(
            try PublishedAssetRequest(
                candidateKey: "image#0",
                role: .image,
                bytes: Data("synthetic-asset-bytes".utf8),
                contentDigest: digest,
                recipeVersion: 1,
                mimeType: "image/png"
            )
        )
        let retry = await PublicationCoordinator(repository: repository, clock: clock, assets: committer)
            .publish(request(prepared, token: prepared.edition.token, media: media))
        XCTAssertNotNil(retry.receipt)
        XCTAssertEqual(try rowCount("asset_version", in: reopened), 1)
        XCTAssertEqual(try rowCount("published_asset_ref", in: reopened), 1)
    }

    /// `mediaCommitFailurePublishesNoReference` (ADR-001 named test; D11, ADR-004 D10, INV-7).
    ///
    /// Failure at each step of the asset commit — the temporary write and the digest validation, the
    /// durability step, and the publication transaction that would carry the reference — never yields a
    /// card naming bytes that were never committed. The third case is the contrast that makes the
    /// negative ones mean something: when the bytes *are* committed, the reference is exactly one row.
    func testMediaCommitFailurePublishesNoReference() async throws {
        let digest = String(repeating: "ab", count: 32)

        func assertNoReference(in runtime: SelectionRuntime, label: String) throws {
            XCTAssertEqual(
                try rowCount("published_asset_ref", in: runtime.database),
                0,
                "\(label): no card references bytes that were never committed"
            )
            XCTAssertEqual(try rowCount("asset_version", in: runtime.database), 0, label)
            XCTAssertEqual(try rowCount("published_card", in: runtime.database), 0, label)
            let report = try PublicationRepository(database: runtime.database).integrityReport()
            XCTAssertTrue(report.isHealthy, "\(label): \(report.summary)")
        }

        // Step 1: the bytes never become an asset (temporary write / digest validation refuses).
        let unwritten = try makeSecondary(named: "asset-unwritten")
        let refusing = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets-unwritten"))
        await refusing.failNextCommits(1)
        let unwrittenPrepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.image], into: unwritten)
        let unwrittenRevision = try XCTUnwrap(unwrittenPrepared.sequence.cards.first).choice.originRevisionID
        let unwrittenOutcome = await coordinator(assets: refusing, in: unwritten).publish(
            request(
                unwrittenPrepared,
                token: unwrittenPrepared.edition.token,
                media: [
                    try preparedMedia(
                        revision: unwrittenRevision,
                        role: .image,
                        digest: digest,
                        in: unwritten
                    )
                ]
            )
        )
        guard case .assetCommitFailed = try XCTUnwrap(unwrittenOutcome.failure) else {
            return XCTFail("a refused asset commit must refuse the publication, got \(unwrittenOutcome)")
        }
        try assertNoReference(in: unwritten, label: "the asset was never committed")

        // Step 2: the bytes are durable but the publication transaction dies before the reference.
        let durable = try makeSecondary(named: "reference-rolled-back")
        let committer = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets-durable"))
        let durablePrepared = try prepare(count: 2, cardLimit: 2, mediaRoles: [.image], into: durable)
        let durableRevision = try XCTUnwrap(durablePrepared.sequence.cards.first).choice.originRevisionID
        let durableMedia = [
            try preparedMedia(revision: durableRevision, role: .image, digest: digest, in: durable)
        ]
        let interrupted = PublicationCoordinator(
            repository: PublicationRepository(
                database: durable.database,
                faults: PublicationRepository.Faults(point: .storageFailureAtCommit)
            ),
            clock: clock,
            assets: committer,
            configuration: PublicationCoordinator.Configuration(commitRetryLimit: 0)
        )
        let durableOutcome = await interrupted.publish(
            request(durablePrepared, token: durablePrepared.edition.token, media: durableMedia)
        )
        guard case .storageFailure = try XCTUnwrap(durableOutcome.failure) else {
            return XCTFail("a storage failure must not publish, got \(durableOutcome)")
        }
        let fileWasWritten = await committer.fileExists(forDigest: digest, recipeVersion: 1)
        XCTAssertTrue(fileWasWritten, "the bytes were made durable before the transaction")
        try assertNoReference(in: durable, label: "the reference was rolled back")
        XCTAssertEqual(
            try PublicationRepository(database: durable.database).unreferencedAssetVersionIDs(),
            [],
            "an orphan file has no row to collect, which is what makes it safe"
        )

        // Step 3: the bytes are committed and the reference is written in the same transaction.
        let committed = try makeSecondary(named: "reference-committed")
        let committing = FileWritingAssetCommitter(root: directory.appendingPathComponent("assets-committed"))
        let committedPrepared = try prepare(count: 1, cardLimit: 1, mediaRoles: [.image], into: committed)
        let committedRevision = try XCTUnwrap(committedPrepared.sequence.cards.first).choice.originRevisionID
        let committedOutcome = await coordinator(assets: committing, in: committed).publish(
            request(
                committedPrepared,
                token: committedPrepared.edition.token,
                media: [
                    try preparedMedia(
                        revision: committedRevision,
                        role: .image,
                        digest: digest,
                        in: committed
                    )
                ]
            )
        )
        XCTAssertNotNil(committedOutcome.receipt)
        XCTAssertEqual(try rowCount("asset_version", in: committed.database), 1)
        XCTAssertEqual(try rowCount("published_asset_ref", in: committed.database), 1)
        XCTAssertEqual(
            try string("SELECT content_digest FROM asset_version", in: committed.database),
            digest
        )
        XCTAssertEqual(try rowCount("published_card", in: committed.database), 1)
        let report = try PublicationRepository(database: committed.database).integrityReport()
        XCTAssertTrue(report.isHealthy, report.summary)
    }

    /// A storage failure is the one failure a bounded retry may repeat, and it repeats with the *same*
    /// token: if the tail moved instead, the composition is refused rather than renumbered.
    func testStorageFailureIsRetriedWithTheSameToken() async throws {
        let prepared = try prepare(count: 2, cardLimit: 2)
        let attemptOneFails = PublicationCoordinator(
            repository: PublicationRepository(
                database: database,
                faults: PublicationRepository.Faults(point: .storageFailureAtCommit, attempt: 1)
            ),
            clock: clock
        )
        let outcome = await attemptOneFails.publish(request(prepared, token: prepared.edition.token))
        let receipt = try XCTUnwrap(outcome.receipt, "the retry must commit")
        XCTAssertEqual(receipt.attempts, 2, "the first attempt failed at storage, the second committed")
        XCTAssertEqual(try rowCount("feed_segment"), 1)
        XCTAssertEqual(try rowCount("published_card"), prepared.sequence.cards.count)
        try assertPublicationIntegrity(label: "after the retried commit")
    }
}
