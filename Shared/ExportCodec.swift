import Foundation
import CryptoKit
import CommonCrypto
import Security

enum ExportError: LocalizedError {
    case passphraseRequired
    case wrongPassphrase
    case unreadable
    case cryptoFailure
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .passphraseRequired: return "This file is locked. Enter its passphrase."
        case .wrongPassphrase: return "Wrong passphrase (or the file is damaged)."
        case .unreadable: return "No location points found. Supported: Pos XY, Google Takeout / Timeline, GPX."
        case .cryptoFailure: return "Encryption failed."
        case .nothingToExport: return "No points recorded in that range."
        }
    }
}

/// What gets exported: plain JSON, optionally wrapped in a passphrase-locked container.
struct ExportFile: Codable {
    var format: String = "pos-xy"
    var version: Int = 1
    var exportedAt: Date
    var points: [TrackPoint]
    /// Motion-coprocessor history (optional; omitted when empty). See docs/FORMAT.md §2.1.
    var motion: [MotionSpan]?
}

/// What a file contained.
struct ExportContents {
    var points: [TrackPoint]
    var motion: [MotionSpan] = []
}

/// Locked file layout (`.pxy`):
///
///     "PXYENC01"            8 bytes  magic
///     salt                 16 bytes  random
///     iterations            4 bytes  big-endian UInt32 (PBKDF2-HMAC-SHA256)
///     nonce|ciphertext|tag   …       AES-256-GCM "combined" box, header bytes as AAD
///
/// The plaintext is the JSON above, compressed with raw DEFLATE (RFC 1951, no zlib/gzip header).
/// Apple's `.zlib` algorithm produces exactly that, and browsers read it with
/// `DecompressionStream("deflate-raw")`. Full spec: docs/FORMAT.md.
enum ExportCodec {
    static let magic = Data("PXYENC01".utf8)
    static let defaultIterations: UInt32 = 600_000
    private static var headerLength: Int { magic.count + 16 + 4 }

    static func makeJSON(_ points: [TrackPoint], motion: [MotionSpan] = []) throws -> Data {
        try TrackJSON.encoder().encode(ExportFile(exportedAt: Date(), points: points, motion: motion.isEmpty ? nil : motion))
    }

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func encrypt(_ plain: Data, passphrase: String, iterations: UInt32 = defaultIterations) throws -> Data {
        let compressed = try (plain as NSData).compressed(using: .zlib) as Data

        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        guard rc == errSecSuccess else { throw ExportError.cryptoFailure }

        var header = magic
        header.append(salt)
        header.append(contentsOf: [UInt8(truncatingIfNeeded: iterations >> 24),
                                   UInt8(truncatingIfNeeded: iterations >> 16),
                                   UInt8(truncatingIfNeeded: iterations >> 8),
                                   UInt8(truncatingIfNeeded: iterations)])

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(compressed, using: key, authenticating: header)
        guard let combined = box.combined else { throw ExportError.cryptoFailure }
        return header + combined
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        let bytes = [UInt8](data)
        let h = headerLength
        guard isEncrypted(data), bytes.count > h + 28 else { throw ExportError.unreadable }
        let salt = Data(bytes[magic.count ..< magic.count + 16])
        let iterations = bytes[magic.count + 16 ..< h].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard iterations >= 1_000, iterations <= 50_000_000 else { throw ExportError.unreadable }
        let header = Data(bytes[0 ..< h])
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(bytes[h...]))
            let compressed = try AES.GCM.open(box, using: key, authenticating: header)
            return try (compressed as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw ExportError.wrongPassphrase
        }
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // Normalise so the same passphrase typed on iPhone and Mac gives the same bytes.
        let pw = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        guard !pw.isEmpty else { throw ExportError.passphraseRequired }
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedCount = derived.count
        let status: Int32 = pw.withUnsafeBufferPointer { pwBuf in
            pwBuf.withMemoryRebound(to: CChar.self) { pwChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwChars.baseAddress, pwChars.count,
                                     saltBytes, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     iterations,
                                     &derived, derivedCount)
            }
        }
        guard status == Int32(kCCSuccess) else { throw ExportError.cryptoFailure }
        return SymmetricKey(data: derived)
    }

    /// Reads any of: locked `.pxy`, exported JSON, a bare JSON array, a raw `.jsonl` day file,
    /// or a foreign format (Google Takeout / Timeline, GPX: see Importers).
    static func decode(_ data: Data, passphrase: String?) throws -> ExportContents {
        var json = data
        if isEncrypted(data) {
            guard let pw = passphrase, !pw.isEmpty else { throw ExportError.passphraseRequired }
            json = try decrypt(data, passphrase: pw)
        }
        if let foreign = Importers.importForeign(json) {
            if foreign.points.isEmpty { throw ExportError.unreadable }
            return ExportContents(points: foreign.points)
        }
        let dec = TrackJSON.decoder()
        if let file = try? dec.decode(ExportFile.self, from: json) {
            return ExportContents(points: file.points, motion: MotionSpans.normalized(file.motion ?? []))
        }
        if let pts = try? dec.decode([TrackPoint].self, from: json) { return ExportContents(points: pts) }
        var out: [TrackPoint] = []
        for line in json.split(separator: UInt8(ascii: "\n")) {
            if let p = try? dec.decode(TrackPoint.self, from: Data(line)) { out.append(p) }
        }
        if out.isEmpty { throw ExportError.unreadable }
        return ExportContents(points: out)
    }
    /// Points only (see `decode` for motion history too).
    static func decodePoints(_ data: Data, passphrase: String?) throws -> [TrackPoint] {
        try decode(data, passphrase: passphrase).points
    }

}
