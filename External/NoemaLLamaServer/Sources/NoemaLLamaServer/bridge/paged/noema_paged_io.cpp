#include "noema_paged_io.h"

#include "noema_paged_xxh64.h"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace noema_paged {

static std::atomic<int64_t> g_live_threads{0};
static std::atomic<int64_t> g_live_buffers{0};

bool pread_full(int fd, void * dst, uint64_t length, uint64_t offset, std::string & err) {
    uint8_t * p = (uint8_t *) dst;
    uint64_t done = 0;
    while (done < length) {
        const ssize_t got = pread(fd, p + done, (size_t) (length - done), (off_t) (offset + done));
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            err = std::string("pread failed: ") + strerror(errno);
            return false;
        }
        if (got == 0) {
            err = "pread hit end of file before record end";
            return false;
        }
        done += (uint64_t) got;
    }
    return true;
}

int64_t io_service::live_threads() { return g_live_threads.load(std::memory_order_acquire); }
int64_t io_service::live_buffers() { return g_live_buffers.load(std::memory_order_acquire); }

size_t io_service::record_key_hash::operator()(const record_key & key) const {
    // 64-bit hash-combine; fd participates because payload descriptors are
    // stable and unique for one io_service lifetime.
    uint64_t h = (uint64_t) (uint32_t) key.fd + 0x9e3779b97f4a7c15ull;
    for (uint64_t value : { key.offset, key.length, key.xxh64 }) {
        h ^= value + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2);
    }
    return (size_t) h;
}

bool io_service::checksum_needed(const io_part & part) {
    if (!params_.verify_checksums) {
        return false;
    }
    const record_key key{part.fd, part.offset, part.length, part.xxh64};
    std::lock_guard<std::mutex> lock(verified_mu_);
    if (verified_records_.find(key) != verified_records_.end()) {
        checksum_cache_hits_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    return true;
}

void io_service::remember_verified(const io_part & part) {
    const record_key key{part.fd, part.offset, part.length, part.xxh64};
    std::lock_guard<std::mutex> lock(verified_mu_);
    verified_records_.insert(key);
}

bool io_service::start(const start_params & params, std::string & err) {
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (running_) {
            err = "io service already running";
            return false;
        }
        params_ = params;
        params_.threads = std::min<int32_t>(std::max<int32_t>(params.threads, 1), 4);
        params_.depth   = std::min<int32_t>(std::max<int32_t>(params.depth, 1), 16);
        if (params_.staging_bytes == 0) {
            err = "io staging size is zero";
            return false;
        }
        const long page = sysconf(_SC_PAGESIZE);
        size_t align = std::max(params_.alignment, page > 0 ? (size_t) page : (size_t) 4096);
        // Both operands are powers of two (manifest validation + page size),
        // so the max is too; posix_memalign additionally needs >= sizeof(void*).
        align = std::max(align, sizeof(void *));
        auto free_buffers_locked = [this]() {
            for (std::vector<uint8_t *> * pool : { &all_staging_, &scratch_ }) {
                for (uint8_t * b : *pool) {
                    free(b);
                    g_live_buffers.fetch_sub(1, std::memory_order_acq_rel);
                }
                pool->clear();
            }
            free_staging_.clear();
        };
        auto alloc_aligned = [align](size_t bytes) -> uint8_t * {
            void * buf = nullptr;
            const size_t rounded = ((bytes + align - 1) / align) * align;
            if (posix_memalign(&buf, align, rounded) != 0 || buf == nullptr) {
                return nullptr;
            }
            g_live_buffers.fetch_add(1, std::memory_order_acq_rel);
            return (uint8_t *) buf;
        };
        for (int32_t i = 0; i < params_.depth; ++i) {
            uint8_t * buf = alloc_aligned(params_.staging_bytes);
            if (buf == nullptr) {
                free_buffers_locked();
                err = "io staging allocation failed";
                return false;
            }
            all_staging_.push_back(buf);
            free_staging_.push_back(buf);
        }
        // Merged-read scratch: one buffer per worker, bounding any coalesced
        // span to its size (hard cap 64 MiB).
        coalesce_on_   = params_.coalesce_bytes > 0;
        coalesce_gap_  = params_.alignment;
        scratch_bytes_ = std::min(params_.coalesce_bytes, (size_t) (64ull << 20));
        if (coalesce_on_) {
            for (int32_t i = 0; i < params_.threads; ++i) {
                uint8_t * buf = alloc_aligned(scratch_bytes_);
                if (buf == nullptr) {
                    free_buffers_locked();
                    err = "io scratch allocation failed";
                    return false;
                }
                scratch_.push_back(buf);
            }
        }
        total_reads_.store(0, std::memory_order_relaxed);
        coalesced_reads_.store(0, std::memory_order_relaxed);
        coalesced_bytes_.store(0, std::memory_order_relaxed);
        direct_reads_.store(0, std::memory_order_relaxed);
        direct_bytes_.store(0, std::memory_order_relaxed);
        checksum_verifications_.store(0, std::memory_order_relaxed);
        checksum_cache_hits_.store(0, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> verified_lock(verified_mu_);
            verified_records_.clear();
        }
        stopping_ = false;
        in_flight_ = 0;
        running_ = true;
    }
    // Spawn outside the lock: workers take mu_ immediately, and a throwing
    // std::thread constructor must not leave the mutex held.
    try {
        for (int32_t i = 0; i < params_.threads; ++i) {
            threads_.emplace_back(&io_service::worker_loop, this, (size_t) i);
            g_live_threads.fetch_add(1, std::memory_order_acq_rel);
        }
    } catch (...) {
        stop_and_join();
        err = "io worker spawn failed";
        return false;
    }
    return true;
}

void io_service::stop_and_join() {
    std::vector<std::thread> joinable;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!running_ && threads_.empty() && all_staging_.empty() && scratch_.empty()) {
            return;
        }
        stopping_ = true;
        for (io_request & req : queue_) {
            recycle_locked(req);
        }
        queue_.clear();
        joinable.swap(threads_);
        cv_worker_.notify_all();
    }
    for (std::thread & t : joinable) {
        t.join(); // waits for in-flight reads to land
        g_live_threads.fetch_sub(1, std::memory_order_acq_rel);
    }
    {
        std::lock_guard<std::mutex> lock(mu_);
        for (io_request & req : completed_) {
            recycle_locked(req);
        }
        completed_.clear();
        for (std::vector<uint8_t *> * pool : { &all_staging_, &scratch_ }) {
            for (uint8_t * b : *pool) {
                free(b);
                g_live_buffers.fetch_sub(1, std::memory_order_acq_rel);
            }
            pool->clear();
        }
        free_staging_.clear();
        coalesce_on_ = false;
        {
            std::lock_guard<std::mutex> verified_lock(verified_mu_);
            verified_records_.clear();
        }
        in_flight_ = 0;
        running_ = false;
        stopping_ = false;
        cv_progress_.notify_all();
    }
}

bool io_service::running() const {
    std::lock_guard<std::mutex> lock(mu_);
    return running_;
}

void io_service::advance_generation() {
    std::lock_guard<std::mutex> lock(mu_);
    generation_.fetch_add(1, std::memory_order_acq_rel);
    for (io_request & req : queue_) {
        recycle_locked(req);
    }
    queue_.clear();
    for (io_request & req : completed_) {
        recycle_locked(req);
    }
    completed_.clear();
    // The bump itself counts as progress even when nothing was recycled: a
    // route thread blocked in wait_progress (e.g. behind an in-flight read the
    // cancel path just invalidated) must wake and re-check the poison latch
    // now, not at its io deadline.
    progress_seq_++;
    cv_progress_.notify_all();
    cv_worker_.notify_all();
}

void io_service::set_pressure(int32_t level) {
    pressure_.store(level, std::memory_order_release);
    std::lock_guard<std::mutex> lock(mu_);
    if (level >= 3) {
        std::deque<io_request> keep;
        for (io_request & req : queue_) {
            if (req.prefetch) {
                recycle_locked(req);
            } else {
                keep.push_back(std::move(req));
            }
        }
        queue_.swap(keep);
    }
    cv_worker_.notify_all();
}

size_t io_service::submit_batch(std::vector<io_request> & reqs) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!running_ || stopping_) {
        return 0;
    }
    const uint64_t gen = generation_.load(std::memory_order_acquire);
    size_t accepted = 0;
    for (io_request & req : reqs) {
        if (free_staging_.empty()) {
            break;
        }
        req.staging = free_staging_.back();
        free_staging_.pop_back();
        req.generation = gen;
        queue_.push_back(std::move(req));
        accepted++;
    }
    if (accepted > 0) {
        cv_worker_.notify_all();
    }
    return accepted;
}

size_t io_service::free_staging_count() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (!running_ || stopping_) {
        return 0;
    }
    return free_staging_.size();
}

std::vector<io_request> io_service::take_completed() {
    std::lock_guard<std::mutex> lock(mu_);
    std::vector<io_request> out;
    out.reserve(completed_.size());
    const uint64_t gen = generation_.load(std::memory_order_acquire);
    for (io_request & req : completed_) {
        if (req.generation == gen) {
            out.push_back(std::move(req));
        } else {
            recycle_locked(req);
        }
    }
    completed_.clear();
    return out;
}

void io_service::release(uint8_t * staging) {
    if (staging == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(mu_);
    free_staging_.push_back(staging);
    progress_seq_++;
    cv_progress_.notify_all();
}

uint64_t io_service::progress_seq() const {
    std::lock_guard<std::mutex> lock(mu_);
    return progress_seq_;
}

bool io_service::wait_progress(uint64_t last_seen, std::chrono::steady_clock::time_point deadline) {
    std::unique_lock<std::mutex> lock(mu_);
    return cv_progress_.wait_until(lock, deadline, [&] {
        return progress_seq_ != last_seen || !running_;
    });
}

void io_service::recycle_locked(io_request & req) {
    if (req.staging != nullptr) {
        free_staging_.push_back(req.staging);
        req.staging = nullptr;
    }
    progress_seq_++;
    cv_progress_.notify_all();
}

// Sorted span descriptors for run planning. A "run" is a maximal series of
// records in one file whose inter-record gap is <= the manifest alignment and
// whose total file span fits the scratch buffer; each run costs one pread.
namespace {
struct span_ref {
    int      fd;
    uint64_t offset;
    uint64_t length;
    size_t   req_idx;
    size_t   part_idx;
};

void sort_spans(std::vector<span_ref> & spans) {
    std::sort(spans.begin(), spans.end(), [](const span_ref & a, const span_ref & b) {
        return a.fd != b.fd ? a.fd < b.fd : a.offset < b.offset;
    });
}

size_t count_runs(std::vector<span_ref> spans, uint64_t gap, uint64_t max_span) {
    sort_spans(spans);
    size_t runs = 0;
    size_t i = 0;
    while (i < spans.size()) {
        uint64_t run_start = spans[i].offset;
        uint64_t run_end = spans[i].offset + spans[i].length;
        size_t j = i + 1;
        while (j < spans.size() && spans[j].fd == spans[i].fd &&
               spans[j].offset <= run_end + gap &&
               std::max(run_end, spans[j].offset + spans[j].length) - run_start <= max_span) {
            run_end = std::max(run_end, spans[j].offset + spans[j].length);
            j++;
        }
        runs++;
        i = j;
    }
    return runs;
}

std::vector<span_ref> collect_spans(const std::vector<io_request> & batch) {
    std::vector<span_ref> spans;
    for (size_t ri = 0; ri < batch.size(); ++ri) {
        for (size_t pi = 0; pi < batch[ri].parts.size(); ++pi) {
            const io_part & p = batch[ri].parts[pi];
            spans.push_back(span_ref{p.fd, p.offset, p.length, ri, pi});
        }
    }
    return spans;
}
} // namespace

// Pulls queued same-layer live requests into `batch` when merging them
// actually reduces the pread count (records adjacent-or-near on disk). Called
// with mu_ held, in the same critical section as the dequeue of batch[0]:
// requests co-queued by one submit_batch are therefore gathered by whichever
// worker dequeues first, deterministically.
void io_service::gather_batch_locked(std::vector<io_request> & batch) {
    const uint64_t gen = generation_.load(std::memory_order_acquire);
    const bool shed_prefetch = pressure_.load(std::memory_order_acquire) >= 3;
    std::vector<span_ref> base = collect_spans(batch);
    size_t base_runs = count_runs(base, coalesce_gap_, scratch_bytes_);
    for (size_t qi = 0; qi < queue_.size() && batch.size() < (size_t) params_.depth;) {
        io_request & cand = queue_[qi];
        if (cand.generation != gen || cand.layer != batch[0].layer ||
            (cand.prefetch && shed_prefetch)) {
            ++qi; // stale/shed requests drop at their own dequeue
            continue;
        }
        std::vector<span_ref> cand_spans;
        for (size_t pi = 0; pi < cand.parts.size(); ++pi) {
            const io_part & p = cand.parts[pi];
            cand_spans.push_back(span_ref{p.fd, p.offset, p.length, batch.size(), pi});
        }
        std::vector<span_ref> merged = base;
        merged.insert(merged.end(), cand_spans.begin(), cand_spans.end());
        const size_t merged_runs = count_runs(merged, coalesce_gap_, scratch_bytes_);
        const size_t solo_runs = count_runs(cand_spans, coalesce_gap_, scratch_bytes_);
        if (merged_runs >= base_runs + solo_runs) {
            ++qi; // no read is saved; leave it for a (possibly parallel) worker
            continue;
        }
        batch.push_back(std::move(cand));
        queue_.erase(queue_.begin() + (ptrdiff_t) qi);
        base = std::move(merged);
        base_runs = merged_runs;
    }
}

// Executes every part of every batch request: single-record runs pread
// straight into the owner's staging (the pre-coalescing fast path), merged
// runs pread once into `scratch` and are split per record, each record
// checksum-verified before its bytes are copied out. Runs execute
// sequentially, so one scratch bounds peak memory.
void io_service::process_batch(std::vector<io_request> & batch, uint8_t * scratch) {
    for (io_request & req : batch) {
        req.ok = true;
        req.read_ns = 0;
        req.checksum_ns = 0;
        req.staging_copy_ns = 0;
        req.direct_bytes = 0;
    }
    std::vector<span_ref> spans = collect_spans(batch);
    sort_spans(spans);
    const uint64_t gap = coalesce_on_ ? coalesce_gap_ : 0;
    const uint64_t max_span = coalesce_on_ ? scratch_bytes_ : 0;
    size_t i = 0;
    while (i < spans.size()) {
        const uint64_t run_start = spans[i].offset;
        uint64_t run_end = spans[i].offset + spans[i].length;
        size_t j = i + 1;
        if (coalesce_on_ && scratch != nullptr) {
            while (j < spans.size() && spans[j].fd == spans[i].fd &&
                   spans[j].offset <= run_end + gap &&
                   std::max(run_end, spans[j].offset + spans[j].length) - run_start <= max_span) {
                run_end = std::max(run_end, spans[j].offset + spans[j].length);
                j++;
            }
        }
        std::string perr;
        if (j == i + 1) {
            // A final-bank destination is safe here because the runtime keeps
            // the slot unpublished/loading until this verified completion is
            // drained. Otherwise retain the historical staging path.
            io_request & owner = batch[spans[i].req_idx];
            const io_part & p = owner.parts[spans[i].part_idx];
            if (owner.ok) {
                uint8_t * dst = p.direct_dst != nullptr
                    ? p.direct_dst
                    : owner.staging + p.staging_offset;
                total_reads_.fetch_add(1, std::memory_order_relaxed);
                const auto read_started = std::chrono::steady_clock::now();
                const bool read_ok = pread_full(p.fd, dst, p.length, p.offset, perr);
                owner.read_ns += (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - read_started).count();
                if (!read_ok) {
                    owner.ok = false;
                    owner.error = perr;
                } else if (checksum_needed(p)) {
                    const auto checksum_started = std::chrono::steady_clock::now();
                    const uint64_t actual = noema_xxh64(dst, (size_t) p.length, 0);
                    checksum_verifications_.fetch_add(1, std::memory_order_relaxed);
                    owner.checksum_ns += (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - checksum_started).count();
                    if (actual != p.xxh64) {
                        owner.ok = false;
                        owner.checksum_failed = true;
                        owner.error = "checksum mismatch";
                    } else {
                        remember_verified(p);
                    }
                }
                if (read_ok && owner.ok && p.direct_dst != nullptr) {
                    owner.direct_bytes += p.length;
                    direct_reads_.fetch_add(1, std::memory_order_relaxed);
                    direct_bytes_.fetch_add(p.length, std::memory_order_relaxed);
                }
            }
        } else {
            const uint64_t span = run_end - run_start;
            total_reads_.fetch_add(1, std::memory_order_relaxed);
            const auto read_started = std::chrono::steady_clock::now();
            const bool read_ok = pread_full(spans[i].fd, scratch, span, run_start, perr);
            const uint64_t read_ns = (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - read_started).count();
            uint64_t payload_bytes = 0;
            for (size_t k = i; k < j; ++k) {
                payload_bytes += spans[k].length;
            }
            for (size_t k = i; k < j; ++k) {
                io_request & owner = batch[spans[k].req_idx];
                owner.read_ns += payload_bytes > 0
                    ? (uint64_t) ((long double) read_ns * spans[k].length / payload_bytes)
                    : 0;
            }
            if (!read_ok) {
                for (size_t k = i; k < j; ++k) {
                    io_request & owner = batch[spans[k].req_idx];
                    if (owner.ok) {
                        owner.ok = false;
                        owner.error = perr;
                    }
                }
            } else {
                coalesced_reads_.fetch_add(1, std::memory_order_relaxed);
                coalesced_bytes_.fetch_add(span, std::memory_order_relaxed);
                for (size_t k = i; k < j; ++k) {
                    io_request & owner = batch[spans[k].req_idx];
                    const io_part & p = owner.parts[spans[k].part_idx];
                    if (!owner.ok) {
                        continue;
                    }
                    const uint8_t * src = scratch + (p.offset - run_start);
                    if (checksum_needed(p)) {
                        const auto checksum_started = std::chrono::steady_clock::now();
                        const uint64_t actual = noema_xxh64(src, (size_t) p.length, 0);
                        checksum_verifications_.fetch_add(1, std::memory_order_relaxed);
                        owner.checksum_ns += (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now() - checksum_started).count();
                        if (actual != p.xxh64) {
                            owner.ok = false;
                            owner.checksum_failed = true;
                            owner.error = "checksum mismatch";
                            continue;
                        }
                        remember_verified(p);
                    }
                    const auto copy_started = std::chrono::steady_clock::now();
                    uint8_t * dst = p.direct_dst != nullptr
                        ? p.direct_dst
                        : owner.staging + p.staging_offset;
                    memcpy(dst, src, (size_t) p.length);
                    owner.staging_copy_ns += (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - copy_started).count();
                    if (p.direct_dst != nullptr) {
                        owner.direct_bytes += p.length;
                        direct_bytes_.fetch_add(p.length, std::memory_order_relaxed);
                    }
                }
            }
        }
        i = j;
    }
}

void io_service::worker_loop(size_t worker_idx) {
    uint8_t * scratch = worker_idx < scratch_.size() ? scratch_[worker_idx] : nullptr;
    std::unique_lock<std::mutex> lock(mu_);
    for (;;) {
        cv_worker_.wait(lock, [&] {
            if (stopping_) {
                return true;
            }
            if (queue_.empty()) {
                return false;
            }
            const int32_t cap = pressure_.load(std::memory_order_acquire) >= 2 ? 1 : INT32_MAX;
            return in_flight_ < cap;
        });
        if (stopping_) {
            return; // stop_and_join recycles whatever is still queued
        }
        io_request req = std::move(queue_.front());
        queue_.pop_front();
        if (req.generation != generation_.load(std::memory_order_acquire) ||
            (req.prefetch && pressure_.load(std::memory_order_acquire) >= 3)) {
            recycle_locked(req); // stale (or shed prefetch) requests drop at dequeue
            continue;
        }
        std::vector<io_request> batch;
        batch.push_back(std::move(req));
        if (coalesce_on_ && scratch != nullptr) {
            gather_batch_locked(batch);
        }
        in_flight_++;
        lock.unlock();

        process_batch(batch, scratch);

        lock.lock();
        in_flight_--;
        const uint64_t gen = generation_.load(std::memory_order_acquire);
        for (io_request & done : batch) {
            if (done.generation != gen) {
                recycle_locked(done); // stale results drop at completion
            } else {
                completed_.push_back(std::move(done));
                progress_seq_++;
            }
        }
        cv_progress_.notify_all();
        cv_worker_.notify_one(); // an in-flight slot freed (pressure >= 2 gate)
    }
}

} // namespace noema_paged
