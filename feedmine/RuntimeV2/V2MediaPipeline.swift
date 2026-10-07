import CoreGraphics
import FeedDomain
import FeedMedia
import FeedRuntime
import FeedStorage
import Foundation
import UIKit

/// The app-layer bridge across the three package boundaries involved in one published visual.
///
/// FeedRuntime only knows `FeedCompositionMediaPreparing`; FeedStorage owns canonical candidate URLs;
/// FeedMedia owns transport/decode/content-addressed bytes. This file is deliberately in the app
/// composition layer so none of those packages has to import a sibling in the wrong direction.
struct V2MediaPipeline: Sendable {
    let assets: LocalAssetStore
    let cache: DecodedImageCache
    let broker: ImageBroker
    let governor: ResourceGovernor
    let preparer: V2MediaPreparer

    init(
        database: RuntimeDatabase,
        transport: any HTTPTransport,
        rootDirectory: URL,
        clock: any EditorialClock
    ) {
        let assets = LocalAssetStore(rootDirectory: rootDirectory)
        let cache = DecodedImageCache(
            limits: MediaCacheLimits(
                decodedBytes: 32 * 1024 * 1024,
                unpublishedBytes: 64 * 1024 * 1024,
                unpublishedMaxAge: 60 * 60
            ),
            clock: clock,
            reclaim: { await assets.reclaim($0) }
        )
        let pressure = MediaCachePressureHandlers(
            discardDecodedMaterial: {
                await cache.discardDecodedCache().freedBytes
            },
            trimUnpublishedDownloads: {
                await cache.trimUnpublishedDownloads().freedBytes
            },
            runRetentionCollection: { now in
                let expired = await cache.evictExpired(asOf: now)
                let unpinned = await cache.collectUnpinnedEntries()
                return expired.freedBytes + unpinned.freedBytes
            }
        )
        let governor = ResourceGovernor(
            limits: ResourceLimits(
                downloadConcurrency: 2,
                decodeConcurrency: 2,
                pressureDownloadConcurrency: 1,
                pressureDecodeConcurrency: 1,
                diskBudgetBytes: 256 * 1024 * 1024
            ),
            clock: clock,
            mediaCache: pressure
        )
        let limiter = V2MediaWorkLimiter(governor: governor)
        let preparation = MediaPreparation(
            transport: transport,
            budget: .current,
            decoder: ImageIODecoder(),
            store: assets,
            cache: cache,
            clock: clock,
            limiter: limiter
        )

        self.assets = assets
        self.cache = cache
        self.governor = governor
        self.broker = ImageBroker(preparation: preparation, cache: cache)
        self.preparer = V2MediaPreparer(
            candidates: MediaCandidateRepository(database: database),
            publication: PublicationRepository(database: database),
            preparation: preparation,
            assets: assets
        )
    }

    /// Turns one frozen media identity into pixels before the snapshot is exposed to SwiftUI.
    ///
    /// The broker can only use memory/disk here. A missing/corrupt asset returns nil and the published
    /// placeholder remains the renderer's deterministic fallback.
    func prewarm(card: PublishedCardRecord) async -> RenderImage? {
        guard let media = card.payload.media.primary else { return nil }
        guard let digest = try? LocalAssetStore.digest(hex: media.contentDigest),
              let recipe = try? MediaRecipeVersion(media.recipeVersion)
        else { return nil }

        let identity = MediaAssetIdentity(
            assetVersionID: AssetVersionID(contentDigest: digest, recipeVersion: recipe),
            pixelWidth: media.pixelWidth,
            pixelHeight: media.pixelHeight,
            mimeType: media.mimeType
        )
        let materialized = await broker.prewarmLocal(identity)
        guard let decoded = materialized.decodedImage,
              let image = Self.uiImage(decoded)
        else { return nil }

        await broker.markPublished(
            identity.assetVersionID,
            pinnedBy: MediaPinOwner(kind: .edition, ownerID: card.payload.editionID.description)
        )
        return RenderImage(cacheKey: media.reference, image: image)
    }

    private static func uiImage(_ decoded: DecodedImage) -> UIImage? {
        guard let provider = CGDataProvider(data: decoded.pixels as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = CGImage(
            width: decoded.pixelWidth,
            height: decoded.pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: decoded.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Adapts FeedRuntime's governor to FeedMedia without creating a forbidden package dependency.
private struct V2MediaWorkLimiter: MediaWorkLimiter {
    let governor: ResourceGovernor

    func withDownloadPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await governor.withDownloadPermit(body)
    }

    func withDecodePermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await governor.withDecodePermit(body)
    }
}

/// Media plans for the exact cards Selection chose.
///
/// Only one renderable representation is fetched per card. All other media remains explicit
/// `.noMedia`, and a failed preferred candidate becomes a deterministic placeholder. This keeps
/// bootstrap bounded while guaranteeing that publication never asks the renderer to fetch.
struct V2MediaPreparer: FeedCompositionMediaPreparing {
    private let candidates: MediaCandidateRepository
    private let publication: PublicationRepository
    private let preparation: MediaPreparation
    private let assets: LocalAssetStore

    init(
        candidates: MediaCandidateRepository,
        publication: PublicationRepository,
        preparation: MediaPreparation,
        assets: LocalAssetStore
    ) {
        self.candidates = candidates
        self.publication = publication
        self.preparation = preparation
        self.assets = assets
    }

    func prepareMedia(
        for sequence: EditorialSequence,
        at: Date
    ) async -> [PublishedCardMediaPlan] {
        await withTaskGroup(of: (Int, PublishedCardMediaPlan).self) { group in
            for card in sequence.cards {
                group.addTask {
                    (
                        card.ordinal,
                        await plan(
                            revision: card.choice.originRevisionID,
                            deadline: at.addingTimeInterval(6)
                        )
                    )
                }
            }

            var ordered: [(Int, PublishedCardMediaPlan)] = []
            ordered.reserveCapacity(sequence.cards.count)
            for await value in group { ordered.append(value) }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func plan(
        revision: OriginRevisionID,
        deadline: Date
    ) async -> PublishedCardMediaPlan {
        guard let declared = try? candidates.candidates(originRevisionID: revision),
              !declared.isEmpty
        else {
            return PublishedCardMediaPlan(originRevisionID: revision, entries: [])
        }

        let preferred = Self.preferredIndex(in: declared)
        var entries: [PublishedCardMediaPlan.Entry] = []
        entries.reserveCapacity(declared.count)

        for (index, candidate) in declared.enumerated() {
            guard PublishedMediaPlacement.isRenderable(candidate.role) else {
                entries.append(.noMedia(candidateKey: candidate.candidateKey, role: candidate.role))
                continue
            }
            guard index == preferred else {
                entries.append(.noMedia(candidateKey: candidate.candidateKey, role: candidate.role))
                continue
            }

            if let reused = reusable(candidate) {
                entries.append(.prepared(reused))
                continue
            }

            guard let url = URL(string: candidate.resourceURL), url.scheme != nil else {
                entries.append(placeholder(candidate))
                continue
            }

            do {
                let prepared = try await preparation.prepareCandidate(
                    MediaCandidatePreparationRequest(
                        url: url,
                        role: candidate.role,
                        targetWidth: 1200,
                        mediaTypeHint: candidate.mediaTypeHint,
                        deadline: deadline
                    )
                )
                guard let bytes = try assets.storedBytes(for: prepared.descriptor.assetVersionID) else {
                    entries.append(placeholder(candidate))
                    continue
                }
                entries.append(.prepared(try PublishedAssetRequest(
                    candidateKey: candidate.candidateKey,
                    role: candidate.role,
                    bytes: bytes,
                    contentDigest: prepared.descriptor.contentDigest.hex,
                    recipeVersion: prepared.descriptor.recipeVersion.rawValue,
                    mimeType: prepared.descriptor.mimeType ?? candidate.mediaTypeHint ?? "application/octet-stream",
                    pixelWidth: prepared.descriptor.pixelWidth,
                    pixelHeight: prepared.descriptor.pixelHeight
                )))
            } catch {
                entries.append(placeholder(candidate))
            }
        }

        return PublishedCardMediaPlan(originRevisionID: revision, entries: entries)
    }

    private func reusable(_ candidate: MediaCandidateSnapshot) -> PublishedAssetRequest? {
        guard let rows = try? publication.mediaPreparations(originRevisionID: candidate.originRevisionID),
              let row = rows.first(where: {
                  $0.candidateKey == candidate.candidateKey
                      && $0.role == candidate.role
                      && $0.state == .prepared
              }),
              let digestText = row.contentDigest,
              let recipeValue = row.recipeVersion,
              let asset = try? publication.assetVersion(
                  contentDigest: digestText,
                  recipeVersion: recipeValue
              ),
              let asset,
              let digest = try? LocalAssetStore.digest(hex: digestText),
              let recipe = try? MediaRecipeVersion(recipeValue),
              let bytes = try? assets.storedBytes(
                  for: AssetVersionID(contentDigest: digest, recipeVersion: recipe)
              ),
              let bytes
        else {
            return nil
        }

        return try? PublishedAssetRequest(
            candidateKey: candidate.candidateKey,
            role: candidate.role,
            bytes: bytes,
            contentDigest: digestText,
            recipeVersion: recipeValue,
            mimeType: asset.mimeType,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private func placeholder(_ candidate: MediaCandidateSnapshot) -> PublishedCardMediaPlan.Entry {
        .placeholder(
            candidateKey: candidate.candidateKey,
            role: candidate.role,
            declaredAspectRatio: candidate.declaredAspectRatio
        )
    }

    /// Prefer a full image, then poster, then thumbnail; connector position breaks ties.
    private static func preferredIndex(in candidates: [MediaCandidateSnapshot]) -> Int? {
        candidates.indices
            .filter { PublishedMediaPlacement.isRenderable(candidates[$0].role) }
            .min { lhs, rhs in
                let left = priority(candidates[lhs].role)
                let right = priority(candidates[rhs].role)
                return left == right
                    ? candidates[lhs].position < candidates[rhs].position
                    : left < right
            }
    }

    private static func priority(_ role: MediaRole) -> Int {
        switch role {
        case .image: return 0
        case .poster: return 1
        case .thumbnail: return 2
        case .waveform: return 3
        case .audio, .video: return 4
        }
    }
}
