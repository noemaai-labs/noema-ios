// Bounded async reads return verified expert groups; only the route thread
// writes bank slots during GPU-quiescent windows.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

namespace noema_paged {

// Shared with the mode-1 preload path.
bool pread_full(int fd, void * dst, uint64_t length, uint64_t offset, std::string & err);

// One family of an expert's record group. `fd` is borrowed from the runtime
// (which owns payload lifetimes); the service never closes it.
struct io_part {
    int      fd = -1;
    int32_t  fam = 0;
    uint64_t offset = 0;
    uint64_t length = 0;
    uint64_t xxh64 = 0;
    uint64_t staging_offset = 0;
    // Optional final bank address. The runtime only supplies this for a
    // CPU-addressable Metal shared buffer and while the destination slot is
    // unpublished/loading. A lone record preads here directly; a coalesced
    // run verifies in scratch and copies here once.
    uint8_t * direct_dst = nullptr;
};

struct io_request {
    uint64_t generation = 0; // service-assigned at submit
    int32_t  layer = -1;
    int32_t  expert = -1;
    int32_t  phase = 0;       // noema_paged_execution_phase at issue time
    bool     prefetch = false;
    std::vector<io_part> parts;
    // service-owned staging buffer while the request is live; the consumer
    // returns it via release() after committing (or discarding) the bytes.
    uint8_t *staging = nullptr;
    bool     ok = false;
    bool     checksum_failed = false;
    uint64_t read_ns = 0;
    uint64_t checksum_ns = 0;
    uint64_t staging_copy_ns = 0; // coalesced scratch -> request staging
    uint64_t direct_bytes = 0;    // verified bytes landed in final bank memory
    std::string error;
};

class io_service {
public:
    struct start_params {
        int32_t threads = 2;          // clamped to [1, 4]
        int32_t depth = 4;            // staging buffers, clamped to [1, 16]
        size_t  staging_bytes = 0;    // per buffer: largest per-expert group
        size_t  alignment = 4096;     // floored to the VM page size
        // Verify each immutable manifest record the first time it is read in
        // this service lifetime. Re-reads skip the hash after the exact
        // fd/offset/length/expected-hash identity has passed once.
        bool    verify_checksums = true;
        // Read coalescing: when records of co-queued same-layer requests sit
        // adjacent-or-near in a payload file (gap <= the manifest alignment,
        // carried in `alignment` above), a worker merges them into one pread
        // through a per-worker scratch buffer of this size, then splits and
        // verifies per record. 0 disables coalescing; the service caps the
        // scratch (and thus any merged span) at 64 MiB.
        size_t  coalesce_bytes = 0;
    };

    io_service() = default;
    ~io_service() { stop_and_join(); }
    io_service(const io_service &) = delete;
    io_service & operator=(const io_service &) = delete;

    bool start(const start_params & params, std::string & err);

    // Cancels queued requests, waits for in-flight reads, joins workers and
    // frees the staging pool. Safe to call repeatedly and on a never-started
    // service; the object may be start()ed again afterwards.
    void stop_and_join();

    bool running() const;

    // Invalidates every queued and in-flight request. Stale requests are
    // dropped both at dequeue and at completion; parked completions are
    // recycled on the next take_completed()/advance call.
    void advance_generation();

    // Mirrors the runtime pressure level: >=2 allows a single in-flight read,
    // >=3 additionally drops queued prefetch requests.
    void set_pressure(int32_t level);

    // Claims one free staging buffer per request and queues the accepted
    // prefix of `reqs` in a single lock hold, so co-submitted requests are
    // co-queued — the property worker-side read coalescing keys off. Returns
    // how many were accepted (fewer only when staging ran out mid-batch or
    // the service is stopping); rejected requests keep their contents and the
    // caller unwinds their bookkeeping. Callers bound the batch with
    // free_staging_count() first: the route thread is the only submitter, so
    // the count is a stable lower bound.
    size_t submit_batch(std::vector<io_request> & reqs);

    // Free staging buffers right now. Only the route thread submits, so the
    // value can only grow underneath it (releases/recycles add buffers).
    size_t free_staging_count() const;

    // Moves out every parked completion belonging to the current generation;
    // stale completions are recycled internally. The caller must release()
    // each returned request's staging buffer.
    std::vector<io_request> take_completed();

    void release(uint8_t * staging);

    // Monotonic count of service progress events (completion parked, buffer
    // freed). Snapshot before deciding to sleep so progress that lands in
    // between never turns into a missed wakeup.
    uint64_t progress_seq() const;

    // Returns false when `deadline` passed with no progress past `last_seen`.
    bool wait_progress(uint64_t last_seen, std::chrono::steady_clock::time_point deadline);

    // Read counters since start(): total payload preads issued, how many of
    // them were merged multi-record reads, and the bytes those merged reads
    // covered (span, gap padding included). Route-thread perf telemetry.
    uint64_t total_reads() const { return total_reads_.load(std::memory_order_relaxed); }
    uint64_t coalesced_reads() const { return coalesced_reads_.load(std::memory_order_relaxed); }
    uint64_t coalesced_bytes() const { return coalesced_bytes_.load(std::memory_order_relaxed); }
    uint64_t direct_reads() const { return direct_reads_.load(std::memory_order_relaxed); }
    uint64_t direct_bytes() const { return direct_bytes_.load(std::memory_order_relaxed); }
    uint64_t checksum_verifications() const {
        return checksum_verifications_.load(std::memory_order_relaxed);
    }
    uint64_t checksum_cache_hits() const {
        return checksum_cache_hits_.load(std::memory_order_relaxed);
    }

    // Process-wide live-resource accounting (teardown-completeness oracle for
    // the lifecycle tests): both must read 0 after stop_and_join.
    static int64_t live_threads();
    static int64_t live_buffers();

private:
    void worker_loop(size_t worker_idx);
    void gather_batch_locked(std::vector<io_request> & batch);
    void process_batch(std::vector<io_request> & batch, uint8_t * scratch);
    void recycle_locked(io_request & req);
    bool checksum_needed(const io_part & part);
    void remember_verified(const io_part & part);

    struct record_key {
        int fd;
        uint64_t offset;
        uint64_t length;
        uint64_t xxh64;

        bool operator==(const record_key & other) const {
            return fd == other.fd && offset == other.offset &&
                   length == other.length && xxh64 == other.xxh64;
        }
    };
    struct record_key_hash {
        size_t operator()(const record_key & key) const;
    };

    mutable std::mutex mu_;
    std::condition_variable cv_worker_;   // queue/stop/pressure changes
    std::condition_variable cv_progress_; // completions and buffer releases
    start_params params_;
    bool running_ = false;
    bool stopping_ = false;
    std::vector<std::thread> threads_;
    std::deque<io_request> queue_;
    std::vector<io_request> completed_;
    std::vector<uint8_t *> free_staging_;
    std::vector<uint8_t *> all_staging_;
    // Per-worker merged-read scratch (empty when coalescing is off). Workers
    // index it by their spawn ordinal; no locking needed past start().
    std::vector<uint8_t *> scratch_;
    bool     coalesce_on_ = false;
    size_t   scratch_bytes_ = 0;  // caps any merged run's file span
    uint64_t coalesce_gap_ = 0;   // manifest alignment: max mergeable gap
    int32_t in_flight_ = 0;
    uint64_t progress_seq_ = 0;
    std::atomic<uint64_t> generation_{1};
    std::atomic<int32_t> pressure_{0};
    std::atomic<uint64_t> total_reads_{0};
    std::atomic<uint64_t> coalesced_reads_{0};
    std::atomic<uint64_t> coalesced_bytes_{0};
    std::atomic<uint64_t> direct_reads_{0};
    std::atomic<uint64_t> direct_bytes_{0};
    // Per-boot immutable-record verification cache. A separate lock keeps
    // checksum bookkeeping out of the queue/progress critical section.
    std::mutex verified_mu_;
    std::unordered_set<record_key, record_key_hash> verified_records_;
    std::atomic<uint64_t> checksum_verifications_{0};
    std::atomic<uint64_t> checksum_cache_hits_{0};
};

} // namespace noema_paged
