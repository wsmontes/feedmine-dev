import CryptoKit
import Foundation

private extension Data {
    /// Decode a hex string (lowercase, no separator) into raw bytes.
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        let chars = Array(hexString)
        var bytes = Data(capacity: hexString.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = chars[i].hexDigitValue,
                  let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
        }
        self = bytes
    }
}

/// Release 1.0 deliberately ships a single catalog authority: the snapshot
/// compiled into the application bundle. The managed/remote update channel is
/// kept available in Debug so it can continue to be developed and tested, but
/// a production build neither loads a previously-installed managed snapshot nor
/// performs a network update.
enum CatalogReleasePolicy {
    #if DEBUG
    static let remoteUpdatesEnabled = true
    static let managedSnapshotsEnabled = true
    #else
    static let remoteUpdatesEnabled = false
    static let managedSnapshotsEnabled = false
    #endif
}

struct CatalogUpdateFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int
}

struct CatalogUpdateManifest: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    /// Ed25519 public key (hex-encoded) used to verify manifest signatures.
    /// The corresponding private key is held outside the repository and used
    /// only during the editorial release process.
    /// Generate a new keypair with: scripts/sign_manifest.swift --generate
    ///
    /// Release 1.0 does not use the remote update channel in production. The
    /// empty key therefore remains a development-only concern until that
    /// channel is explicitly re-enabled in a later release.
    nonisolated(unsafe) static let publicKeyHex: String = ""

    let schemaVersion: Int
    let revision: Int
    let generatedAt: String
    let sourceCount: Int
    let fileCount: Int
    let files: [CatalogUpdateFile]
    /// Ed25519 signature over the canonical JSON of all fields above.
    /// Empty string if not signed (bundled catalog during development).
    let signature: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, generatedAt, sourceCount, fileCount, files, signature
    }

    init(
        schemaVersion: Int,
        revision: Int,
        generatedAt: String,
        sourceCount: Int,
        fileCount: Int,
        files: [CatalogUpdateFile],
        signature: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generatedAt = generatedAt
        self.sourceCount = sourceCount
        self.fileCount = fileCount
        self.files = files
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        sourceCount = try container.decode(Int.self, forKey: .sourceCount)
        fileCount = try container.decode(Int.self, forKey: .fileCount)
        files = try container.decode([CatalogUpdateFile].self, forKey: .files)
        signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
    }

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CatalogUpdateError.unsupportedSchema(schemaVersion)
        }
        guard revision > 0, sourceCount > 0, fileCount == files.count, !files.isEmpty else {
            throw CatalogUpdateError.invalidManifest("invalid revision or catalog counts")
        }

        var uniquePaths = Set<String>()
        for file in files {
            guard Self.isSafeOPMLPath(file.path),
                  uniquePaths.insert(file.path).inserted,
                  file.bytes > 0,
                  file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw CatalogUpdateError.invalidManifest("invalid file entry: \(file.path)")
            }
        }

        try verifySignature()
    }

    /// The canonical payload the signature covers.
    ///
    /// It must reproduce, byte for byte, `canonicalEncoder` in `scripts/sign_manifest.swift`: compact JSON,
    /// lexicographically sorted keys, unescaped slashes. Key order is not a Codable contract and the signer's
    /// `UnsignedManifest` is a distinct type from `UnsignedFields`, so a default `JSONEncoder()` produced bytes
    /// nobody could reproduce — a signature valid in one process could be rejected in another (TOOL-24 / S16).
    /// Sorting the keys is what lets two independently declared shapes yield the same payload.
    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private func verifySignature() throws {
        let pkHex = Self.publicKeyHex
        guard !pkHex.isEmpty else {
            return
        }
        guard !signature.isEmpty else {
            throw CatalogUpdateError.invalidManifest("manifest is not signed")
        }
        guard signature.count == 128,
              signature.allSatisfy({ $0.isHexDigit }) else {
            throw CatalogUpdateError.invalidManifest("invalid signature format")
        }

        guard let publicKeyData = Data(hexString: pkHex),
              let signatureData = Data(hexString: signature) else {
            throw CatalogUpdateError.invalidManifest("invalid signature encoding")
        }

        let unsigned = CatalogUpdateManifest.UnsignedFields(
            schemaVersion: schemaVersion,
            revision: revision,
            generatedAt: generatedAt,
            sourceCount: sourceCount,
            fileCount: fileCount,
            files: files
        )
        guard let payload = try? Self.canonicalEncoder.encode(unsigned) else {
            throw CatalogUpdateError.invalidManifest("failed to re-encode manifest for verification")
        }

        guard let edPublicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw CatalogUpdateError.invalidManifest("invalid public key")
        }
        guard (try? edPublicKey.isValidSignature(signatureData, for: payload)) == true else {
            throw CatalogUpdateError.invalidManifest("manifest signature verification failed")
        }
    }

    private struct UnsignedFields: Codable {
        let schemaVersion: Int
        let revision: Int
        let generatedAt: String
        let sourceCount: Int
        let fileCount: Int
        let files: [CatalogUpdateFile]
    }

    private static func isSafeOPMLPath(_ path: String) -> Bool {
        guard path.hasPrefix("Feeds/"), path.hasSuffix(".opml"), !path.hasPrefix("/") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct CatalogSnapshot: Sendable {
    let feedsURL: URL
    let catalogURL: URL
    let manifestURL: URL
    let manifest: CatalogUpdateManifest
}

struct CatalogRuntimePaths: Sendable {
    let managedRootURL: URL
    let bundledFeedsURL: URL?
    let bundledCatalogURL: URL?
    let bundledManifestURL: URL?

    static var live: CatalogRuntimePaths {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let resources = Bundle.main.resourceURL
        return CatalogRuntimePaths(
            managedRootURL: applicationSupport.appendingPathComponent("ManagedCatalog", isDirectory: true),
            bundledFeedsURL: resources?.appendingPathComponent("Feeds", isDirectory: true),
            bundledCatalogURL: Bundle.main.url(
                forResource: "catalog",
                withExtension: "sqlite",
                subdirectory: "FeedEngine"
            ),
            bundledManifestURL: Bundle.main.url(
                forResource: "catalog-update-manifest",
                withExtension: "json",
                subdirectory: "FeedEngine"
            )
        )
    }

    var currentURL: URL {
        managedRootURL.appendingPathComponent("current", isDirectory: true)
    }

    func activeSnapshot(
        fileManager: FileManager = .default,
        includeManagedSnapshot: Bool = CatalogReleasePolicy.managedSnapshotsEnabled
    ) -> CatalogSnapshot? {
        let bundled = snapshot(
            feedsURL: bundledFeedsURL,
            catalogURL: bundledCatalogURL,
            manifestURL: bundledManifestURL,
            fileManager: fileManager
        )

        guard includeManagedSnapshot else {
            return bundled
        }

        let localRoot = currentURL
        let local = snapshot(
            feedsURL: localRoot.appendingPathComponent("Feeds", isDirectory: true),
            catalogURL: localRoot.appendingPathComponent("catalog.sqlite"),
            manifestURL: localRoot.appendingPathComponent("manifest.json"),
            fileManager: fileManager
        )

        switch (bundled, local) {
        case let (bundle?, local?):
            return local.manifest.revision >= bundle.manifest.revision ? local : bundle
        case let (bundle?, nil):
            return bundle
        case let (nil, local?):
            return local
        case (nil, nil):
            return nil
        }
    }

    private func snapshot(
        feedsURL: URL?,
        catalogURL: URL?,
        manifestURL: URL?,
        fileManager: FileManager
    ) -> CatalogSnapshot? {
        guard let feedsURL, let catalogURL, let manifestURL,
              fileManager.fileExists(atPath: feedsURL.path),
              fileManager.fileExists(atPath: catalogURL.path),
              fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CatalogUpdateManifest.self, from: data),
              (try? manifest.validate()) != nil else { return nil }
        return CatalogSnapshot(
            feedsURL: feedsURL,
            catalogURL: catalogURL,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }
}

enum CatalogRuntime {
    static func activeSnapshot() -> CatalogSnapshot? {
        CatalogRuntimePaths.live.activeSnapshot()
    }

    static func activeFeedsURL() -> URL? {
        activeSnapshot()?.feedsURL
            ?? Bundle.main.resourceURL?.appendingPathComponent("Feeds", isDirectory: true)
    }

    static func activeCatalogURL() -> URL? {
        activeSnapshot()?.catalogURL
            ?? Bundle.main.url(
                forResource: "catalog",
                withExtension: "sqlite",
                subdirectory: "FeedEngine"
            )
            ?? Bundle.main.url(forResource: "catalog", withExtension: "sqlite")
    }

    static func activeManifest() -> CatalogUpdateManifest? {
        activeSnapshot()?.manifest
    }
}

protocol CatalogUpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionCatalogUpdateTransport: CatalogUpdateTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .background
        session = URLSession(configuration: configuration)
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogUpdateError.badHTTPResponse((response as? HTTPURLResponse)?.statusCode)
        }
        return data
    }
}

enum CatalogUpdateOutcome: Equatable, Sendable {
    case current(revision: Int)
    case updated(fromRevision: Int, toRevision: Int, changedFiles: Int, deletedFiles: Int)
}

enum CatalogUpdateError: Error, Equatable, LocalizedError, Sendable {
    case noLocalSnapshot
    case unsupportedSchema(Int)
    case invalidManifest(String)
    case badHTTPResponse(Int?)
    case revisionCollision(Int)
    case checksumMismatch(String)
    case sizeMismatch(String)
    case compiledSourceCount(expected: Int, actual: Int)
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noLocalSnapshot:
            return "No valid bundled or local catalog snapshot is available."
        case .unsupportedSchema(let version):
            return "Unsupported catalog update schema \(version)."
        case .invalidManifest(let reason):
            return "Invalid catalog update manifest: \(reason)."
        case .badHTTPResponse(let status):
            return "Catalog server returned HTTP \(status.map(String.init) ?? "unknown")."
        case .revisionCollision(let revision):
            return "Catalog revision \(revision) has conflicting contents."
        case .checksumMismatch(let path):
            return "Catalog file failed checksum validation: \(path)."
        case .sizeMismatch(let path):
            return "Catalog file failed size validation: \(path)."
        case .compiledSourceCount(let expected, let actual):
            return "Compiled catalog contains \(actual) sources; expected \(expected)."
        case .activationFailed(let reason):
            return "Catalog activation failed: \(reason)."
        }
    }
}

actor CatalogUpdateService {
    static let shared = CatalogUpdateService()

    private static let defaultRemoteRoot = URL(
        string: "https://raw.githubusercontent.com/wawasoft/feed-repository/main/"
    )!

    private let paths: CatalogRuntimePaths
    private let remoteRootURL: URL
    private let transport: any CatalogUpdateTransport
    private let fileManager: FileManager
    private let remoteUpdatesEnabled: Bool
    private let managedSnapshotsEnabled: Bool

    init(
        paths: CatalogRuntimePaths = .live,
        remoteRootURL: URL = CatalogUpdateService.defaultRemoteRoot,
        transport: any CatalogUpdateTransport = URLSessionCatalogUpdateTransport(),
        fileManager: FileManager = .default,
        remoteUpdatesEnabled: Bool = CatalogReleasePolicy.remoteUpdatesEnabled,
        managedSnapshotsEnabled: Bool = CatalogReleasePolicy.managedSnapshotsEnabled
    ) {
        self.paths = paths
        self.remoteRootURL = remoteRootURL
        self.transport = transport
        self.fileManager = fileManager
        self.remoteUpdatesEnabled = remoteUpdatesEnabled
        self.managedSnapshotsEnabled = managedSnapshotsEnabled
    }

    func updateIfAvailable() async throws -> CatalogUpdateOutcome {
        guard let active = paths.activeSnapshot(
            fileManager: fileManager,
            includeManagedSnapshot: managedSnapshotsEnabled
        ) else {
            throw CatalogUpdateError.noLocalSnapshot
        }

        // Release 1.0 is bundled-only. Returning the bundled revision here is
        // intentionally a successful no-op: callers do not need a separate
        // release-only control path and, critically, no request leaves the app.
        guard remoteUpdatesEnabled else {
            return .current(revision: active.manifest.revision)
        }

        let manifestData = try await transport.data(from: remoteRootURL.appendingPathComponent("manifest.json"))
        guard manifestData.count <= 5_000_000 else {
            throw CatalogUpdateError.invalidManifest("manifest exceeds 5 MB")
        }
        let remote = try JSONDecoder().decode(CatalogUpdateManifest.self, from: manifestData)
        try remote.validate()

        if remote.revision < active.manifest.revision {
            return .current(revision: active.manifest.revision)
        }
        if remote.revision == active.manifest.revision {
            guard remote == active.manifest else {
                throw CatalogUpdateError.revisionCollision(remote.revision)
            }
            return .current(revision: remote.revision)
        }

        try fileManager.createDirectory(at: paths.managedRootURL, withIntermediateDirectories: true)
        let stagingURL = paths.managedRootURL.appendingPathComponent(
            "staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let stagedFeedsURL = stagingURL.appendingPathComponent("Feeds", isDirectory: true)
        try fileManager.copyItem(at: active.feedsURL, to: stagedFeedsURL)

        let expectedPaths = Set(remote.files.map(\.path))
        try removeFilesNotPresent(in: expectedPaths, stagingURL: stagingURL)

        var changedFileCount = 0
        for entry in remote.files.sorted(by: { $0.path < $1.path }) {
            let destination = Self.appending(relativePath: entry.path, to: stagingURL)
            if try fileMatches(entry, at: destination) {
                continue
            }

            let data = try await transport.data(from: Self.appending(relativePath: entry.path, to: remoteRootURL))
            guard data.count == entry.bytes else {
                throw CatalogUpdateError.sizeMismatch(entry.path)
            }
            guard Self.sha256(data) == entry.sha256.lowercased() else {
                throw CatalogUpdateError.checksumMismatch(entry.path)
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            changedFileCount += 1
        }

        for entry in remote.files {
            let fileURL = Self.appending(relativePath: entry.path, to: stagingURL)
            guard try fileMatches(entry, at: fileURL) else {
                throw CatalogUpdateError.checksumMismatch(entry.path)
            }
        }

        let catalogURL = stagingURL.appendingPathComponent("catalog.sqlite")
        let report = try await SQLiteCatalogCompiler(
            input: .opmlRoot(stagedFeedsURL),
            databaseURL: catalogURL
        ).compileFull()
        guard report.sourceCount == remote.sourceCount else {
            throw CatalogUpdateError.compiledSourceCount(
                expected: remote.sourceCount,
                actual: report.sourceCount
            )
        }

        try manifestData.write(
            to: stagingURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let deletedFileCount = max(0, active.manifest.fileCount - expectedPaths.intersection(
            Set(active.manifest.files.map(\.path))
        ).count)
        try activate(stagingURL: stagingURL)
        shouldRemoveStaging = false

        return .updated(
            fromRevision: active.manifest.revision,
            toRevision: remote.revision,
            changedFiles: changedFileCount,
            deletedFiles: deletedFileCount
        )
    }

    private func removeFilesNotPresent(in expectedPaths: Set<String>, stagingURL: URL) throws {
        let feedsURL = stagingURL.appendingPathComponent("Feeds", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: feedsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var obsolete: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = "Feeds/" + fileURL.path.replacingOccurrences(of: feedsURL.path + "/", with: "")
            if !expectedPaths.contains(relative) {
                obsolete.append(fileURL)
            }
        }
        for fileURL in obsolete {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func fileMatches(_ entry: CatalogUpdateFile, at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == entry.bytes else { return false }
        return try Self.sha256(Data(contentsOf: url)) == entry.sha256.lowercased()
    }

    private func activate(stagingURL: URL) throws {
        let currentURL = paths.currentURL
        let backupURL = paths.managedRootURL.appendingPathComponent("backup", isDirectory: true)
        try? fileManager.removeItem(at: backupURL)

        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.moveItem(at: currentURL, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: currentURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path),
               !fileManager.fileExists(atPath: currentURL.path) {
                try? fileManager.moveItem(at: backupURL, to: currentURL)
            }
            throw CatalogUpdateError.activationFailed(error.localizedDescription)
        }
    }

    private static func appending(relativePath: String, to root: URL) -> URL {
        relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
