import FeedDomain
import Foundation
import GRDB

/// Canonical media work read by the composition root before publication.
///
/// The publication repository deliberately does not expose resource URLs: a published payload may only
/// know immutable asset identity. This repository sits on the preparation side of that boundary and
/// exposes exactly what FeedMedia needs to turn a remote candidate into local bytes.
public struct MediaCandidateSnapshot: Hashable, Sendable {
    public let originRevisionID: OriginRevisionID
    public let candidateKey: String
    public let role: MediaRole
    public let resourceURL: String
    public let mediaTypeHint: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let position: Int

    public init(
        originRevisionID: OriginRevisionID,
        candidateKey: String,
        role: MediaRole,
        resourceURL: String,
        mediaTypeHint: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        position: Int
    ) {
        self.originRevisionID = originRevisionID
        self.candidateKey = candidateKey
        self.role = role
        self.resourceURL = resourceURL
        self.mediaTypeHint = mediaTypeHint
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.position = position
    }

    public var declaredAspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

public struct MediaCandidateRepository: Sendable {
    private let database: RuntimeDatabase

    public init(database: RuntimeDatabase) {
        self.database = database
    }

    /// Candidates for one exact immutable revision, in connector-declared order.
    public func candidates(originRevisionID: OriginRevisionID) throws -> [MediaCandidateSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT role, resource_url, media_type_hint, pixel_width, pixel_height, position
                    FROM media_candidate
                    WHERE origin_revision_id = ?
                    ORDER BY position, id
                    """,
                arguments: [originRevisionID.rawValue]
            ).compactMap { row in
                guard let role = MediaRole(rawValue: row["role"]) else { return nil }
                let position: Int = row["position"]
                return MediaCandidateSnapshot(
                    originRevisionID: originRevisionID,
                    candidateKey: "\(role.rawValue)#\(position)",
                    role: role,
                    resourceURL: row["resource_url"],
                    mediaTypeHint: row["media_type_hint"],
                    pixelWidth: row["pixel_width"],
                    pixelHeight: row["pixel_height"],
                    position: position
                )
            }
        }
    }
}
