// Independent implementation of the XXH64 hash algorithm for Noema Overfit
// sidecar record verification. Algorithm by Yann Collet (Cyan4973), spec:
// https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md (BSD 2-Clause).
// This file implements the algorithm from the specification; it does not copy
// the reference sources. Known-answer tests live in NoemaLLamaServerTests.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline uint64_t noema_xxh64_rotl_(uint64_t v, unsigned r) {
    return (v << r) | (v >> (64 - r));
}

static inline uint64_t noema_xxh64_read64_(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, sizeof(v));
    return v; // Apple targets are little-endian; the spec reads little-endian lanes.
}

static inline uint32_t noema_xxh64_read32_(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline uint64_t noema_xxh64_round_(uint64_t acc, uint64_t lane) {
    const uint64_t P1 = 11400714785074694791ULL;
    const uint64_t P2 = 14029467366897019727ULL;
    acc += lane * P2;
    acc  = noema_xxh64_rotl_(acc, 31);
    acc *= P1;
    return acc;
}

static inline uint64_t noema_xxh64_merge_round_(uint64_t h, uint64_t acc) {
    const uint64_t P1 = 11400714785074694791ULL;
    const uint64_t P4 = 9650029242287828579ULL;
    h ^= noema_xxh64_round_(0, acc);
    h  = h * P1 + P4;
    return h;
}

static inline uint64_t noema_xxh64(const void *data, size_t len, uint64_t seed) {
    const uint64_t P1 = 11400714785074694791ULL;
    const uint64_t P2 = 14029467366897019727ULL;
    const uint64_t P3 = 1609587929392839161ULL;
    const uint64_t P4 = 9650029242287828579ULL;
    const uint64_t P5 = 2870177450012600261ULL;

    const uint8_t *p   = (const uint8_t *) data;
    const uint8_t *end = p + len;
    uint64_t h;

    if (len >= 32) {
        uint64_t acc1 = seed + P1 + P2;
        uint64_t acc2 = seed + P2;
        uint64_t acc3 = seed + 0;
        uint64_t acc4 = seed - P1;

        const uint8_t *limit = end - 32;
        do {
            acc1 = noema_xxh64_round_(acc1, noema_xxh64_read64_(p));      p += 8;
            acc2 = noema_xxh64_round_(acc2, noema_xxh64_read64_(p));      p += 8;
            acc3 = noema_xxh64_round_(acc3, noema_xxh64_read64_(p));      p += 8;
            acc4 = noema_xxh64_round_(acc4, noema_xxh64_read64_(p));      p += 8;
        } while (p <= limit);

        h = noema_xxh64_rotl_(acc1, 1) + noema_xxh64_rotl_(acc2, 7) +
            noema_xxh64_rotl_(acc3, 12) + noema_xxh64_rotl_(acc4, 18);
        h = noema_xxh64_merge_round_(h, acc1);
        h = noema_xxh64_merge_round_(h, acc2);
        h = noema_xxh64_merge_round_(h, acc3);
        h = noema_xxh64_merge_round_(h, acc4);
    } else {
        h = seed + P5;
    }

    h += (uint64_t) len;

    while (p + 8 <= end) {
        h ^= noema_xxh64_round_(0, noema_xxh64_read64_(p));
        h  = noema_xxh64_rotl_(h, 27) * P1 + P4;
        p += 8;
    }
    if (p + 4 <= end) {
        h ^= (uint64_t) noema_xxh64_read32_(p) * P1;
        h  = noema_xxh64_rotl_(h, 23) * P2 + P3;
        p += 4;
    }
    while (p < end) {
        h ^= (uint64_t) (*p) * P5;
        h  = noema_xxh64_rotl_(h, 11) * P1;
        p += 1;
    }

    h ^= h >> 33;
    h *= P2;
    h ^= h >> 29;
    h *= P3;
    h ^= h >> 32;
    return h;
}

#ifdef __cplusplus
}
#endif
