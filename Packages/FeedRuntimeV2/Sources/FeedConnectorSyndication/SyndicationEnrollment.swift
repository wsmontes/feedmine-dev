import Foundation
import FeedDomain

/// The editorial source a connector's target serves (ADR-003 D15, ADR-005 D5/D10).
///
/// A target is operational work and a source is editorial identity: the connector cannot derive one
/// from the other (D2/D18), so the composition root resolves the source once — it is the only layer
/// that holds both the durable binding and the runtime database — and hands it to the connector.
///
/// The connector then declares, on every observation it translates, that the object is a member of
/// that source. Without such a claim the content enrolls no source at all: `selection_supply.source_id`
/// stays `NULL`, Selection's eligibility predicate finds no membership, and the reader is shown nothing
/// however successful the fetch was. That is why the enrollment is not optional in production.
///
/// The `membershipKind` is the connector's own name for how the membership was known, and Admission
/// stores it verbatim: the schema deliberately does not enumerate membership kinds (ADR-003 D15).
public struct SyndicationSourceEnrollment: Hashable, Sendable {
    /// The kind every enrollment through a syndication binding declares.
    public static let membershipKind = "syndication-binding"

    public let sourceID: SourceID
    public let binding: SourceBindingKey?
    public let bindingGeneration: UInt64?

    public init(
        sourceID: SourceID,
        binding: SourceBindingKey? = nil,
        bindingGeneration: UInt64? = nil
    ) throws {
        guard bindingGeneration == nil || binding != nil else {
            throw AdmissionContractError.bindingGenerationWithoutBinding
        }
        self.sourceID = sourceID
        self.binding = binding
        self.bindingGeneration = bindingGeneration
        self.claim = try MembershipClaim(
            sourceID: sourceID,
            membershipKind: Self.membershipKind,
            binding: binding,
            bindingGeneration: bindingGeneration
        )
    }

    /// The claim that travels on each observation.
    public let claim: MembershipClaim
}
