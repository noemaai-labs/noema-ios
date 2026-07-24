import Foundation

/// Swift implementation of the XXH64 hash algorithm (Yann Collet's spec,
/// BSD 2-Clause). Must stay bit-identical to the native implementation in
/// NoemaLLamaServer/bridge/paged/noema_paged_xxh64.h and the Python converter;
/// known-answer tests pin all three.
public enum PagedXXH64 {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    private static func rotl(_ v: UInt64, _ r: UInt64) -> UInt64 {
        (v << r) | (v >> (64 - r))
    }

    private static func round(_ acc: UInt64, _ lane: UInt64) -> UInt64 {
        rotl(acc &+ lane &* p2, 31) &* p1
    }

    private static func mergeRound(_ h: UInt64, _ acc: UInt64) -> UInt64 {
        (h ^ round(0, acc)) &* p1 &+ p4
    }

    public static func hash(_ data: some ContiguousBytes, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { raw in
            hash(buffer: raw, seed: seed)
        }
    }

    public static func hash(buffer raw: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let count = raw.count
        var h: UInt64
        var offset = 0

        func read64(_ at: Int) -> UInt64 {
            raw.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian
        }
        func read32(_ at: Int) -> UInt32 {
            raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian
        }

        if count >= 32 {
            var acc1 = seed &+ p1 &+ p2
            var acc2 = seed &+ p2
            var acc3 = seed
            var acc4 = seed &- p1
            while offset + 32 <= count {
                acc1 = round(acc1, read64(offset))
                acc2 = round(acc2, read64(offset + 8))
                acc3 = round(acc3, read64(offset + 16))
                acc4 = round(acc4, read64(offset + 24))
                offset += 32
            }
            h = rotl(acc1, 1) &+ rotl(acc2, 7) &+ rotl(acc3, 12) &+ rotl(acc4, 18)
            h = mergeRound(h, acc1)
            h = mergeRound(h, acc2)
            h = mergeRound(h, acc3)
            h = mergeRound(h, acc4)
        } else {
            h = seed &+ p5
        }

        h &+= UInt64(count)

        while offset + 8 <= count {
            h ^= round(0, read64(offset))
            h = rotl(h, 27) &* p1 &+ p4
            offset += 8
        }
        if offset + 4 <= count {
            h ^= UInt64(read32(offset)) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            offset += 4
        }
        while offset < count {
            h ^= UInt64(raw[offset]) &* p5
            h = rotl(h, 11) &* p1
            offset += 1
        }

        h ^= h >> 33
        h &*= p2
        h ^= h >> 29
        h &*= p3
        h ^= h >> 32
        return h
    }
}
