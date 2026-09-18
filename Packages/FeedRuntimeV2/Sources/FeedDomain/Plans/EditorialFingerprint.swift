import Foundation

/// Canonical serialization and digest for editorial fingerprints (ADR-002 D2–D5, plan §8).
///
/// The encoding is explicit and positional: a field is `name` `=` `tag` `:` `len` `:` `bytes` plus a
/// single `\n`, where `len` is the byte count of the payload and `tag` is a fixed type tag. Array
/// payloads carry their element count and each element its own byte length, so two different value
/// sequences can never serialize to the same bytes and no field boundary is ambiguous.
///
/// Nothing in this file uses `Swift.Hasher`, `hashValue`, `ObjectIdentifier`, `String.hashValue`,
/// `Date.description`, `Locale.current` or `TimeZone.current`: a persisted fingerprint must be
/// recomputable in another process and another launch (D3), and the repository has already paid for
/// a per-process hash once (`feedmine/Services/FeedDisplayState.swift:427-437`).
struct CanonicalSerialization {
    private(set) var data = Data()

    mutating func string(_ name: String, _ value: String) {
        field(name, tag: "str", payload: Data(value.utf8))
    }

    mutating func integer(_ name: String, _ value: Int64) {
        field(name, tag: "int", payload: Data(String(value).utf8))
    }

    mutating func boolean(_ name: String, _ value: Bool) {
        field(name, tag: "bool", payload: value ? Data([0x31]) : Data([0x30]))
    }

    /// Elements are already-serialized byte strings; each is framed by its own byte length.
    mutating func list(_ name: String, _ elements: [Data]) {
        var payload = Data(String(elements.count).utf8)
        payload.append(0x3A)
        for element in elements {
            payload.append(Data(String(element.count).utf8))
            payload.append(0x3A)
            payload.append(element)
        }
        field(name, tag: "list", payload: payload)
    }

    /// A nested structure is serialized with the same framing as a field payload, so a nested change
    /// is a byte change and the whole scheme stays versioned by `EditorialRevisionSchemeVersion`.
    static func element(_ body: (inout CanonicalSerialization) -> Void) -> Data {
        var writer = CanonicalSerialization()
        body(&writer)
        return writer.data
    }

    private mutating func field(_ name: String, tag: String, payload: Data) {
        data.append(Data("\(name)=\(tag):\(payload.count):".utf8))
        data.append(payload)
        data.append(0x0A)
    }
}

/// SHA-256 (FIPS 180-4) in lowercase hex.
///
/// Implemented here rather than imported because `FeedDomain` imports Foundation only (plan §3:
/// "[FeedDomain] Pode depender de: Foundation e value types Sendable"), and a persisted fingerprint
/// must be reproducible by any build of the runtime. It is a fingerprint, never a security primitive.
/// Public because four identities that must be reproducible from their inputs are derived from it
/// and nothing else: the editorial revision, the frozen payload digest, the deterministic
/// exploration bias, and — since PR-14 — the stable `ActionID` the Interaction boundary addresses an
/// offer by.
public enum EditorialSHA256 {
    public static func hex(of message: Data) -> String {
        hexString(digest(message))
    }

    public static func digest(_ message: Data) -> [UInt8] {
        var state: [UInt32] = [
            0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
            0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
        ]
        var padded = [UInt8](message)
        let bitLength = UInt64(padded.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < padded.count {
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] = UInt32(padded[base]) << 24
                    | UInt32(padded[base + 1]) << 16
                    | UInt32(padded[base + 2]) << 8
                    | UInt32(padded[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], 7)
                    ^ rotateRight(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], 17)
                    ^ rotateRight(schedule[index - 2], 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choice &+ Self.roundConstants[index] &+ schedule[index]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
            offset += 64
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for word in state {
            output.append(UInt8(truncatingIfNeeded: word >> 24))
            output.append(UInt8(truncatingIfNeeded: word >> 16))
            output.append(UInt8(truncatingIfNeeded: word >> 8))
            output.append(UInt8(truncatingIfNeeded: word))
        }
        return output
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        let shift = count % 32
        guard shift != 0 else { return value }
        return (value >> shift) | (value << (32 - shift))
    }

    private static func hexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]
}

/// Deterministic exploration bias in `0...weight` for one candidate and one edition seed.
///
/// The seed is per-edition randomness that ADR-002 D4 excludes from the digest: it is an *input* the
/// caller passes (Blueprint §58), never a per-process value, so a replay with the same seed produces
/// the same order. `weight == 0` is the default policy and makes the bias exactly zero, which is why
/// the default order is seed-independent.
public enum EditorialBias {
    public static func value(seed: Data, stableKey: String, weight: Int) -> Int {
        guard weight > 0 else { return 0 }
        var material = seed
        material.append(0x00)
        material.append(Data(stableKey.utf8))
        var prefix: UInt64 = 0
        for byte in EditorialSHA256.digest(material).prefix(8) {
            prefix = (prefix << 8) | UInt64(byte)
        }
        return Int(prefix % UInt64(weight + 1))
    }
}
