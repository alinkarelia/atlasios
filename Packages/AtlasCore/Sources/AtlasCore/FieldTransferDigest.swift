import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Portable streaming SHA-256. Large mesh originals are read in bounded chunks;
/// no Apple-only crypto framework or full-file Data allocation is required.
public enum FieldTransferDigest {
    /// Hashes the exact chunks a caller reads or writes. Finalization uses a
    /// copy, so inspecting the digest does not consume the stream's state.
    public struct Stream {
        #if canImport(CryptoKit)
        private var state = CryptoKit.SHA256()
        #else
        private var state = SHA256State()
        #endif
        public init() {}

        public mutating func update(_ data: Data) {
            #if canImport(CryptoKit)
            state.update(data: data)
            #else
            state.update(data)
            #endif
        }

        public func finalize() -> String {
            #if canImport(CryptoKit)
            return state.finalize().map { String(format: "%02x", $0) }.joined()
            #else
            var copy = state
            return copy.finish()
            #endif
        }
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var hash = SHA256State()
        hash.update(data)
        return hash.finish()
        #endif
    }

    public static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hash = Stream()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data) }
        return hash.finalize()
    }

    /// Asset descriptors retain the immutable identity while validation binds
    /// them to the actual bytes in the managed root.
    public static func describe(id: UUID = UUID(), materialID: UUID, relativePath: String,
                                root: URL, mediaType: String, kind: FieldAssetKind) throws -> FieldAsset {
        let url = try FieldTransferPaths.resolve(relativePath: relativePath, root: root)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
        catch { throw FieldTransferError.missingAsset(relativePath) }
        guard values.isRegularFile == true, let byteCount = values.fileSize, byteCount <= 536_870_912 else {
            throw FieldTransferError.invalidManifest
        }
        return FieldAsset(id: id, materialID: materialID, relativePath: relativePath, mediaType: mediaType,
                          byteCount: Int64(byteCount), sha256: try sha256(fileURL: url), kind: kind)
    }
}

private struct SHA256State {
    private var words: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var count: UInt64 = 0
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    mutating func update(_ data: Data) {
        count &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            compress(pending, offset: offset)
            offset += 64
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    mutating func finish() -> String {
        let bitCount = count &* 8
        pending.append(0x80)
        while pending.count % 64 != 56 { pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { pending.append(UInt8(truncatingIfNeeded: bitCount >> shift)) }
        let tail = pending
        for offset in stride(from: 0, to: tail.count, by: 64) { compress(tail, offset: offset) }
        return words.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(_ bytes: [UInt8], offset: Int) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = offset + index * 4
            schedule[index] = (UInt32(bytes[base]) << 24) | (UInt32(bytes[base + 1]) << 16)
                | (UInt32(bytes[base + 2]) << 8) | UInt32(bytes[base + 3])
        }
        for index in 16..<64 {
            let x = schedule[index - 15], y = schedule[index - 2]
            let a = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
            let b = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
            schedule[index] = schedule[index - 16] &+ a &+ schedule[index - 7] &+ b
        }
        var a = words[0], b = words[1], c = words[2], d = words[3]
        var e = words[4], f = words[5], g = words[6], h = words[7]
        for index in 0..<64 {
            let sigma1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choice = (e & f) ^ ((~e) & g)
            let temporary1 = h &+ sigma1 &+ choice &+ Self.constants[index] &+ schedule[index]
            let sigma0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sigma0 &+ majority
            h = g; g = f; f = e; e = d &+ temporary1
            d = c; c = b; b = a; a = temporary1 &+ temporary2
        }
        words[0] &+= a; words[1] &+= b; words[2] &+= c; words[3] &+= d
        words[4] &+= e; words[5] &+= f; words[6] &+= g; words[7] &+= h
    }

    private func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 { (value >> bits) | (value << (32 - bits)) }
}
