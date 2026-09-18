import Foundation
import GRDB
import FeedDomain

/// The failing input of one deterministic check, written where it can be **re-run** instead of
/// re-derived (plan §15.1's property/replay class, and §8.11: the seeds exist but nothing captured the
/// one that failed).
///
/// A seed alone does not reproduce a decision — plan §8 says so explicitly — so an artifact carries
/// what the check read: which edition, under which context, with which editorial revision, and the
/// identities of the frozen cards. It carries no URL, no payload text and no asset bytes: an artifact
/// is kept next to a run's diagnostics, and the plan forbids publisher content and signed URLs in
/// anything a run leaves behind.
public struct CapturedFailure: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let check: FailureSeedCheck
    public let observedAtMilliseconds: Int64
    /// Where the failure happened: a filesystem path, never a URL. The replay opens it by location.
    public let databasePath: String
    public let surface: String?
    public let scopeKey: String?
    public let planIdentity: String?
    public let editionID: Int64?
    public let epoch: Int64?
    /// The seed the composition ran under, base64: the reproduction key this class exists for.
    public let seedBase64: String
    public let editorialRevision: String?
    public let publicationSchemaVersion: Int?
    /// Stable identities of the frozen cards the check looked at, never their content.
    public let cardIdentities: [String]
    /// What the check requires, and what it observed, both as kind names so a comparison never
    /// depends on the wording of a message.
    public let expected: String
    public let observed: String
    public let detail: String

    public init(
        check: FailureSeedCheck,
        observedAtMilliseconds: Int64,
        databasePath: String,
        surface: String? = nil,
        scopeKey: String? = nil,
        planIdentity: String? = nil,
        editionID: Int64? = nil,
        epoch: Int64? = nil,
        seed: Data,
        editorialRevision: String? = nil,
        publicationSchemaVersion: Int? = nil,
        cardIdentities: [String] = [],
        expected: String,
        observed: String,
        detail: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.check = check
        self.observedAtMilliseconds = observedAtMilliseconds
        self.databasePath = databasePath
        self.surface = surface
        self.scopeKey = scopeKey
        self.planIdentity = planIdentity
        self.editionID = editionID
        self.epoch = epoch
        self.seedBase64 = seed.base64EncodedString()
        self.editorialRevision = editorialRevision
        self.publicationSchemaVersion = publicationSchemaVersion
        self.cardIdentities = cardIdentities
        self.expected = expected
        self.observed = observed
        self.detail = detail
    }

    public var seed: Data { Data(base64Encoded: seedBase64) ?? Data() }
}

/// Which deterministic check failed. One case per check the runtime can observe failing in production;
/// a check that no code path can detect belongs here only when it is implemented, never as a name for
/// a future slice.
public enum FailureSeedCheck: String, Hashable, Sendable, Codable, CaseIterable {
    /// A stored edition must restore from its own rows (ADR-002 D8 R1–R3). A refusal is the failure,
    /// and the edition's seed is what its composition ran under.
    case editionRestoreIsReproducible = "edition_restore_is_reproducible"
}

public enum FailureSeedError: Error, Equatable, Sendable {
    case unwritable(String)
    case unreadable(String)
    case unsupportedSchemaVersion(Int)
}

/// The write half: one failing input, written next to the run's artifacts.
///
/// The file name carries the check and the instant, so several captures from one run sort in order
/// instead of overwriting each other.
public struct FailureSeedCapture: Sendable {
    public static let fileNamePrefix = "failure-seed-"
    /// The environment variable the replay command sets, and the only thing the replay test needs.
    public static let environmentKey = "FEEDMINE_REPLAY_SEED"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func record(_ failure: CapturedFailure) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FailureSeedError.unwritable("\(error)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(failure)
        } catch {
            throw FailureSeedError.unwritable("\(error)")
        }
        let url = directory.appendingPathComponent(
            "\(Self.fileNamePrefix)\(failure.check.rawValue)-\(failure.observedAtMilliseconds).json",
            isDirectory: false
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw FailureSeedError.unwritable("\(error)")
        }
        return url
    }

    /// Every artifact this directory holds, oldest first.
    public func artifacts() throws -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.fileNamePrefix) && $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    public static func load(_ url: URL) throws -> CapturedFailure {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FailureSeedError.unreadable("\(error)")
        }
        let failure: CapturedFailure
        do {
            failure = try JSONDecoder().decode(CapturedFailure.self, from: data)
        } catch {
            throw FailureSeedError.unreadable("\(error)")
        }
        guard failure.schemaVersion == CapturedFailure.currentSchemaVersion else {
            throw FailureSeedError.unsupportedSchemaVersion(failure.schemaVersion)
        }
        return failure
    }

    /// The command that replays one artifact. It is a command, not a description: running it passes
    /// the artifact to the replay test through the environment, which is why the artifact and the
    /// command are produced together instead of documented separately.
    public static func replayCommand(artifact: URL, packagePath: String = "Packages/FeedRuntimeV2") -> String {
        // `--filter` is matched against `Target.Class/method`, so the separator between the test target
        // and the class is a dot. A command that selects nothing exits 0, which is the false green this
        // spelling avoids: `FeedStorageTests/FailureSeedReplayTests` runs zero tests and passes.
        "\(environmentKey)=\(artifact.path) swift test --package-path \(packagePath) "
            + "--filter FeedStorageTests.FailureSeedReplayTests"
    }
}

/// The port a runtime component holds to record a failure.
///
/// Recording is a diagnostic *effect*, and the component that detects the failure must not own a
/// directory: a composition with no diagnostic directory (every test, and the shadow lane) passes
/// `nil` and the failure is simply not written.
public protocol FailureSeedCapturing: Sendable {
    func capture(_ failure: CapturedFailure) throws -> URL
}

extension FailureSeedCapture: FailureSeedCapturing {
    public func capture(_ failure: CapturedFailure) throws -> URL {
        try record(failure)
    }
}

/// The read half: re-run the check the artifact names, from the same inputs.
///
/// It answers `.reproduced` or `.diverged`, and never throws for a divergence: a failure that no
/// longer reproduces is the interesting result, not an error.
public struct FailureSeedReplay: Sendable {
    public enum Outcome: Hashable, Sendable {
        case reproduced(String)
        case diverged(String)

        public var isReproduced: Bool {
            if case .reproduced = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case let .reproduced(detail): return "reproduced: \(detail)"
            case let .diverged(detail): return "diverged: \(detail)"
            }
        }
    }

    public init() {}

    public func replay(_ failure: CapturedFailure) throws -> Outcome {
        switch failure.check {
        case .editionRestoreIsReproducible:
            return try replayEditionRestore(failure)
        }
    }

    private func replayEditionRestore(_ failure: CapturedFailure) throws -> Outcome {
        let directory = URL(fileURLWithPath: failure.databasePath, isDirectory: true)
        let location = RuntimeDatabaseLocation(directory: directory)
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
            return .diverged("the database the failure came from is gone: \(failure.databasePath)")
        }
        guard let surfaceRaw = failure.surface,
              let surface = ContextKey.Surface(rawValue: surfaceRaw),
              let scopeKey = failure.scopeKey,
              let planIdentity = failure.planIdentity
        else {
            return .diverged("the artifact does not name a context")
        }
        guard let rawEditionID = failure.editionID, let editionID = try? EditionID(rawEditionID) else {
            return .diverged("the artifact does not name an edition")
        }
        let context = try ContextKey(surface: surface, scopeKey: scopeKey, planIdentity: planIdentity)
        let repository = PublicationRepository(database: try RuntimeDatabase(location: location))
        guard let edition = try repository.edition(editionID) else {
            return .diverged("edition \(rawEditionID) is no longer stored")
        }
        guard edition.seed == failure.seed else {
            return .diverged(
                "the recorded seed is not the edition's seed: this artifact does not describe this edition"
            )
        }
        let outcome = try repository.restore(context: context)
        let kind = Self.kind(of: outcome)
        guard kind == failure.observed else {
            return .diverged("the check now answers \(kind), and the artifact recorded \(failure.observed)")
        }
        return .reproduced(
            "edition \(rawEditionID) still answers \(kind) under seed \(failure.seedBase64)"
        )
    }

    /// The kind name of a restore outcome. The artifact records kinds rather than messages, so a
    /// comparison never depends on the wording of a diagnostic.
    public static func kind(of outcome: EditionRestoreOutcome) -> String {
        switch outcome {
        case .restored: return "restored"
        case .noEdition: return "noEdition"
        case .unsupportedPublicationSchemaVersion: return "unsupportedPublicationSchemaVersion"
        case .payloadCorrupted: return "payloadCorrupted"
        }
    }
}
