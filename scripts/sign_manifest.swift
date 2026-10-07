#!/usr/bin/env swift

import CryptoKit
import Foundation

// MARK: - Types

struct UnsignedManifest: Codable {
    let schemaVersion: Int
    let revision: Int
    let generatedAt: String
    let sourceCount: Int
    let fileCount: Int
    let files: [CatalogFile]

    struct CatalogFile: Codable {
        let path: String
        let sha256: String
        let bytes: Int
    }
}

struct SignedManifest: Codable {
    let schemaVersion: Int
    let revision: Int
    let generatedAt: String
    let sourceCount: Int
    let fileCount: Int
    let files: [CatalogFile]
    let signature: String

    struct CatalogFile: Codable {
        let path: String
        let sha256: String
        let bytes: Int
    }
}

// MARK: - Helpers

/// Canonical form of the signed payload: compact JSON with lexicographically
/// sorted keys and unescaped slashes. Signing and verification must use exactly
/// these bytes — the same encoder on the same `UnsignedManifest` shape — or a
/// valid signature can be rejected in another process or build. Any other
/// verifier (the app's CatalogUpdateService) must reproduce this canonical form.
let canonicalEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

func printUsage() {
    let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "sign_manifest.swift"
    print("Usage:")
    print("  \(name) --generate                           Create a new Ed25519 keypair")
    print("  \(name) --sign <manifest.json> <private.hex>  Sign a manifest")
    print("  \(name) --verify <manifest.json> <public.hex>  Verify a signed manifest")
}

func generateKeypair() {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey
    print("Private key (keep secret — do NOT commit):")
    print(privateKey.rawRepresentation.hexString)
    print("")
    print("Public key (embed in app — CatalogUpdateManifest.publicKeyHex):")
    print(publicKey.rawRepresentation.hexString)
}

func signManifest(_ url: URL, privateKeyHex: String) throws {
    guard let privateKeyData = Data(hexString: privateKeyHex) else {
        throw AppError.invalidHex("private key")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)

    let data = try Data(contentsOf: url)
    let unsigned = try JSONDecoder().decode(UnsignedManifest.self, from: data)

    // Sign the unsigned payload (excludes signature field)
    let payload = try canonicalEncoder.encode(unsigned)
    let signature = try privateKey.signature(for: payload)
    // Self-check: the canonical bytes must verify with the matching public key,
    // otherwise the manifest is signed over a payload nobody can reproduce.
    guard privateKey.publicKey.isValidSignature(signature, for: payload) else {
        throw AppError.verificationFailed("self-check failed for the canonical payload")
    }

    let signed = SignedManifest(
        schemaVersion: unsigned.schemaVersion,
        revision: unsigned.revision,
        generatedAt: unsigned.generatedAt,
        sourceCount: unsigned.sourceCount,
        fileCount: unsigned.fileCount,
        files: unsigned.files.map {
            SignedManifest.CatalogFile(path: $0.path, sha256: $0.sha256, bytes: $0.bytes)
        },
        signature: signature.hexString
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let signedJSON = try encoder.encode(signed)
    print(String(data: signedJSON, encoding: .utf8)!)
}

func verifyManifest(_ url: URL, publicKeyHex: String) throws {
    guard let publicKeyData = Data(hexString: publicKeyHex) else {
        throw AppError.invalidHex("public key")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

    let data = try Data(contentsOf: url)
    let signed = try JSONDecoder().decode(SignedManifest.self, from: data)

    guard signed.signature.count == 128 else {
        throw AppError.verificationFailed("missing or invalid signature")
    }
    guard let sigData = Data(hexString: signed.signature) else {
        throw AppError.verificationFailed("invalid signature hex")
    }

    // Re-encode unsigned fields for verification
    let unsigned = UnsignedManifest(
        schemaVersion: signed.schemaVersion,
        revision: signed.revision,
        generatedAt: signed.generatedAt,
        sourceCount: signed.sourceCount,
        fileCount: signed.fileCount,
        files: signed.files.map {
            UnsignedManifest.CatalogFile(path: $0.path, sha256: $0.sha256, bytes: $0.bytes)
        }
    )
    let payload = try canonicalEncoder.encode(unsigned)

    guard publicKey.isValidSignature(sigData, for: payload) else {
        throw AppError.verificationFailed("signature is INVALID — manifest may be tampered")
    }
    print("✅ Signature valid — manifest is authentic.")
}

// MARK: - Data helpers

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        let chars = Array(hexString)
        var bytes = Data(capacity: hexString.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(hi << 4 | lo))
        }
        self = bytes
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum AppError: LocalizedError {
    case invalidHex(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHex(let what): return "Invalid hex string: \(what)"
        case .verificationFailed(let reason): return "Verification failed: \(reason)"
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else { printUsage(); exit(1) }

do {
    switch args[1] {
    case "--generate":
        generateKeypair()

    case "--sign":
        guard args.count == 4 else { printUsage(); exit(1) }
        try signManifest(URL(fileURLWithPath: args[2]), privateKeyHex: args[3])

    case "--verify":
        guard args.count == 4 else { printUsage(); exit(1) }
        try verifyManifest(URL(fileURLWithPath: args[2]), publicKeyHex: args[3])

    default:
        printUsage()
        exit(1)
    }
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
