import Foundation
import FeedDomain
import FeedStorage

/// How one launch started (plan §16's warm-restore rule).
///
/// The rule has two halves and only one of them is a distribution: a restore that needs no network, no
/// Selection and no catalogue refresh is a **warm** start, and a launch with **no compatible edition**
/// must be classified as cold/recovery instead of being folded into the warm-start numbers. Folding it in
/// would hide the number that matters most — how often the runtime has nothing to show — and §16 says so
/// explicitly.
public enum StartupClassification: String, Hashable, Sendable, CaseIterable {
    /// A stored edition restored from its own rows: no composition, no Selection, no network.
    case warmRestore = "warm_restore"
    /// No compatible edition was available or decodable, so this run is not a warm start.
    case coldRecovery = "cold_recovery"
}

/// What one launch restored, and why when it restored nothing.
public struct StartupReport: Hashable, Sendable {
    public let classification: StartupClassification
    /// A short statement of the reason. Counts, identifiers and kinds only: never a URL, never content.
    public let reason: String
    /// The edition that was restored, when there was one.
    public let editionID: EditionID?
    /// The cards the restore brought with it, as a count.
    public let restoredCardCount: Int

    public init(
        classification: StartupClassification,
        reason: String,
        editionID: EditionID? = nil,
        restoredCardCount: Int = 0
    ) {
        self.classification = classification
        self.reason = reason
        self.editionID = editionID
        self.restoredCardCount = restoredCardCount
    }

    static func warm(edition: EditionSnapshot, cardCount: Int) -> StartupReport {
        StartupReport(
            classification: .warmRestore,
            reason: "the stored edition restored from its own rows",
            editionID: edition.editionID,
            restoredCardCount: cardCount
        )
    }

    static func cold(_ reason: String) -> StartupReport {
        StartupReport(classification: .coldRecovery, reason: reason)
    }
}
