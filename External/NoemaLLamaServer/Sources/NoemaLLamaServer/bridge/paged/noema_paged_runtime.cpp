#include "noema_paged_runtime.h"

#include "noema_paged_xxh64.h"

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-metal.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace noema_paged {

using json = nlohmann::ordered_json;

// Total int32 route ids the trace buffer may hold before dropping (32 MiB).
static constexpr size_t MAX_TRACE_IDS = 8ull * 1024 * 1024;

static thread_local runtime * t_planning = nullptr;

static const char * phase_name(int32_t phase) {
    switch (phase) {
        case NOEMA_PAGED_PHASE_PROMPT_PREFILL:     return "promptPrefill";
        case NOEMA_PAGED_PHASE_ORDINARY_DECODE:    return "ordinaryDecode";
        case NOEMA_PAGED_PHASE_SPECULATIVE_VERIFY: return "speculativeVerify";
        case NOEMA_PAGED_PHASE_CHECKPOINT_RESTORE: return "checkpointRestore";
        default:                                   return "unknown";
    }
}

void runtime::phase_counters::reset() {
    route_calls.store(0, std::memory_order_relaxed);
    ids_seen.store(0, std::memory_order_relaxed);
    hits.store(0, std::memory_order_relaxed);
    misses.store(0, std::memory_order_relaxed);
    bytes_read.store(0, std::memory_order_relaxed);
    read_ns.store(0, std::memory_order_relaxed);
    checksum_ns.store(0, std::memory_order_relaxed);
    staging_copy_ns.store(0, std::memory_order_relaxed);
    commit_ns.store(0, std::memory_order_relaxed);
    stall_ns.store(0, std::memory_order_relaxed);
    max_route_stall_ns.store(0, std::memory_order_relaxed);
    route_cpu_ns.store(0, std::memory_order_relaxed);
    wave_count.store(0, std::memory_order_relaxed);
    wave_stalls.store(0, std::memory_order_relaxed);
    checkpoint_restore_ns.store(0, std::memory_order_relaxed);
    layer_executions.store(0, std::memory_order_relaxed);
    all_hit_layer_executions.store(0, std::memory_order_relaxed);
}

bool runtime::phase_counters::empty() const {
    return route_calls.load(std::memory_order_relaxed) == 0 &&
           ids_seen.load(std::memory_order_relaxed) == 0 &&
           hits.load(std::memory_order_relaxed) == 0 &&
           misses.load(std::memory_order_relaxed) == 0 &&
           bytes_read.load(std::memory_order_relaxed) == 0 &&
           layer_executions.load(std::memory_order_relaxed) == 0 &&
           checkpoint_restore_ns.load(std::memory_order_relaxed) == 0;
}

int32_t runtime::normalize_phase(int32_t phase) {
    return phase >= NOEMA_PAGED_PHASE_UNKNOWN && phase <= NOEMA_PAGED_PHASE_CHECKPOINT_RESTORE
        ? phase : NOEMA_PAGED_PHASE_UNKNOWN;
}

runtime::phase_counters & runtime::phase_total(int32_t phase) {
    return phase_totals_[(size_t) normalize_phase(phase)];
}

const runtime::phase_counters & runtime::phase_total(int32_t phase) const {
    return phase_totals_[(size_t) normalize_phase(phase)];
}

runtime::phase_counters * runtime::phase_layer(int32_t phase, int32_t il) {
    if (il < 0 || (uint32_t) il >= phase_layer_count_) {
        return nullptr;
    }
    return &phase_layers_[(size_t) normalize_phase(phase) * phase_layer_count_ + (uint32_t) il];
}

const runtime::phase_counters * runtime::phase_layer(int32_t phase, int32_t il) const {
    if (il < 0 || (uint32_t) il >= phase_layer_count_) {
        return nullptr;
    }
    return &phase_layers_[(size_t) normalize_phase(phase) * phase_layer_count_ + (uint32_t) il];
}

runtime & runtime::global() {
    static runtime instance;
    return instance;
}

runtime & runtime::current() {
    return t_planning ? *t_planning : global();
}

void runtime::set_planning(runtime * rt) {
    t_planning = rt;
}

int32_t runtime::set_execution_phase(int32_t phase) {
    return execution_phase_.exchange(normalize_phase(phase), std::memory_order_acq_rel);
}

int32_t runtime::execution_phase() const {
    return normalize_phase(execution_phase_.load(std::memory_order_acquire));
}

void runtime::note_checkpoint_restore(uint64_t elapsed_ns) {
    phase_total(NOEMA_PAGED_PHASE_CHECKPOINT_RESTORE).checkpoint_restore_ns.fetch_add(
        elapsed_ns, std::memory_order_relaxed);
}

bool runtime::configure(const noema_paged_config_c * cfg, bool planning, std::string & err) {
    std::lock_guard<std::mutex> lock(mu_);
    if (server_started_ && !server_exited_) {
        err = "paged runtime is busy: server still running";
        return false;
    }
    teardown_locked();

    if (cfg == nullptr || cfg->mode == 0) {
        return true; // paging off; runtime stays reset
    }

    runtime_config rc;
    switch (cfg->mode) {
        case 1: rc.mode = run_mode::resident_bank; break;
        case 2: rc.mode = run_mode::streamed;      break;
        case 3: rc.mode = run_mode::trace_only;    break;
        default:
            err = "invalid paged mode";
            return false;
    }

    rc.manifest_path   = cfg->manifest_path ? cfg->manifest_path : "";
    rc.slots_per_layer = cfg->slots_per_layer;
    rc.bank_budget_mib = cfg->bank_budget_mib;
    rc.io_threads      = cfg->io_threads  > 0 ? std::min<int32_t>(cfg->io_threads, 4)  : 2;
    rc.io_depth        = cfg->io_depth    > 0 ? std::min<int32_t>(cfg->io_depth, 16)   : 4;
    rc.io_timeout_ms   = cfg->io_timeout_ms > 0 ? cfg->io_timeout_ms : 30000;
    rc.prefetch        = cfg->prefetch != 0;
    rc.oracle_all_hit  = cfg->oracle_all_hit != 0;
    rc.trace           = cfg->trace != 0;
    rc.trace_path      = cfg->trace_path ? cfg->trace_path : "";
    rc.verify_checksums = cfg->verify_checksums != 0;
    rc.telemetry_interval_ms = cfg->telemetry_interval_ms;
    // Internal diagnostic/test knobs. Production policy is carried by the
    // versioned public configuration rather than process-global state.
    const char * no_coalesce = getenv("NOEMA_PAGED_NO_COALESCE");
    rc.io_coalesce = !(no_coalesce != nullptr && strcmp(no_coalesce, "1") == 0);
    const char * nocache = getenv("NOEMA_PAGED_NOCACHE");
    rc.io_nocache = nocache != nullptr && strcmp(nocache, "1") == 0;
    const char * no_direct_io = getenv("NOEMA_PAGED_NO_DIRECT_IO");
    rc.direct_io = !(no_direct_io != nullptr && strcmp(no_direct_io, "1") == 0);
    const char * gpu_hit_path = getenv("NOEMA_GPU_ROUTE_HIT_PATH");
    rc.gpu_route_hit_path = gpu_hit_path == nullptr || strcmp(gpu_hit_path, "0") != 0;
    const char * no_fused_decode = getenv("NOEMA_PAGED_NO_FUSED_DECODE");
    rc.fused_decode = !(no_fused_decode != nullptr && strcmp(no_fused_decode, "1") == 0);
    const char * no_hot = getenv("NOEMA_PAGED_NO_HOT_PROTECT");
    rc.hot_protect = !(no_hot != nullptr && strcmp(no_hot, "1") == 0);
    const char * no_history_prefetch = getenv("NOEMA_PAGED_NO_HISTORY_PREFETCH");
    rc.history_prefetch = !(no_history_prefetch != nullptr && strcmp(no_history_prefetch, "1") == 0);
    // Wave-split expert-major prefill (mode 2 only). v4 callers carry the
    // production policy explicitly. The environment remains a live test/A-B
    // override: a present NOEMA_PAGED_WAVES wins in both directions, while
    // the legacy =1 test shape still implies expert-major unless its dedicated
    // kill switch is present.
    const char * waves = getenv("NOEMA_PAGED_WAVES");
    const char * expert_major = getenv("NOEMA_PAGED_EXPERT_MAJOR");
    const bool waves_forced_off = waves != nullptr && strcmp(waves, "1") != 0;
    bool waves_requested = cfg->waves != 0 || cfg->expert_major != 0;
    if (waves != nullptr) {
        waves_requested = strcmp(waves, "1") == 0;
    }
    if (!waves_forced_off && expert_major != nullptr && strcmp(expert_major, "1") == 0) {
        waves_requested = true;
    }
    rc.waves = rc.mode == run_mode::streamed && waves_requested;
    const char * no_expert_major = getenv("NOEMA_PAGED_NO_EXPERT_MAJOR");
    const bool legacy_env_default = waves != nullptr && strcmp(waves, "1") == 0;
    const bool expert_major_requested = !waves_forced_off && (cfg->expert_major != 0 || legacy_env_default ||
        (expert_major != nullptr && strcmp(expert_major, "1") == 0));
    rc.expert_major = rc.waves && expert_major_requested &&
        !(no_expert_major != nullptr && strcmp(no_expert_major, "1") == 0);
    const char * force_g = getenv("NOEMA_PAGED_WAVES_FORCE_G");
    if (rc.waves && force_g != nullptr && force_g[0] != '\0') {
        const long v = strtol(force_g, nullptr, 10);
        if (v > 0 && v <= INT32_MAX) {
            rc.waves_force_g = (int32_t) v;
        }
    }

    const bool needs_manifest = rc.mode == run_mode::resident_bank || rc.mode == run_mode::streamed;
    if (needs_manifest && rc.manifest_path.empty()) {
        err = "paged mode requires a manifest path";
        return false;
    }
    if (!rc.manifest_path.empty()) {
        if (!parse_and_validate(rc.manifest_path, vm_, err)) {
            vm_ = validated_manifest();
            return false;
        }
        has_manifest_ = true;

        // Slot-count resolution. Modes 1/3 keep a full bank; mode 2 resolves
        // the streamed bank size and fails closed when it cannot hold a whole
        // route (n_expert_used) plus two spare slots for inbound loads.
        int32_t n_slots = (int32_t) vm_.mf.n_expert;
        if (rc.mode == run_mode::streamed) {
            const int32_t floor_slots = (int32_t) vm_.mf.n_expert_used + STREAM_SPARE_SLOTS;
            int64_t resolved = 0;
            if (rc.slots_per_layer > 0) {
                resolved = rc.slots_per_layer;
            } else if (rc.bank_budget_mib > 0) {
                uint64_t max_group = 0;
                for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
                    uint64_t group = 0;
                    for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
                        const family_geometry * g = vm_.geometry_for(l, (family) fi);
                        if (g != nullptr) {
                            group += g->record_length;
                        }
                    }
                    max_group = std::max(max_group, group);
                }
                const uint64_t per_slot = max_group * (uint64_t) vm_.mf.moe_layer_count;
                if (per_slot > 0) {
                    resolved = (int64_t) (((uint64_t) rc.bank_budget_mib << 20) / per_slot);
                }
            } else {
                err = "streamed paged mode requires paged_slots_per_layer or paged_bank_budget_mib";
                vm_ = validated_manifest();
                has_manifest_ = false;
                return false;
            }
            if (resolved > (int64_t) vm_.mf.n_expert) {
                resolved = (int64_t) vm_.mf.n_expert;
            }
            if (resolved < floor_slots) {
                err = "streamed bank needs at least " + std::to_string(floor_slots) +
                      " slots per layer (n_expert_used + " + std::to_string(STREAM_SPARE_SLOTS) +
                      "); resolved " + std::to_string(resolved);
                vm_ = validated_manifest();
                has_manifest_ = false;
                return false;
            }
            n_slots = (int32_t) resolved;
        }

        banks_.assign(vm_.mf.total_layer_count, layer_bank());
        for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
            if (vm_.layer_is_paged(l)) {
                banks_[l].n_slots = n_slots;
            }
        }
    }

    phase_layer_count_ = has_manifest_ ? vm_.mf.total_layer_count : 0;
    for (int32_t phase = 0; phase < PHASE_COUNT; ++phase) {
        phase_totals_[(size_t) phase].reset();
        for (uint32_t il = 0; il < phase_layer_count_; ++il) {
            phase_layers_.emplace_back();
        }
    }

    cfg_ = std::move(rc);
    planning_ = planning;
    configured_ = true;
    active_.store(cfg_.mode == run_mode::resident_bank || cfg_.mode == run_mode::streamed,
                  std::memory_order_release);
    route_active_.store(true, std::memory_order_release);
    stream_cancellable_.store(cfg_.mode == run_mode::streamed && !planning,
                              std::memory_order_release);
    return true;
}

void runtime::mark_server_started() {
    std::lock_guard<std::mutex> lock(mu_);
    server_started_ = true;
    server_exited_  = false;
}

void runtime::on_server_exit() {
    std::lock_guard<std::mutex> lock(mu_);
    server_exited_ = true;
    if (shutdown_requested_) {
        teardown_locked();
    }
}

void runtime::shutdown() {
    std::lock_guard<std::mutex> lock(mu_);
    if (server_started_ && !server_exited_) {
        // Detached server thread may still touch banks; defer to on_server_exit.
        shutdown_requested_ = true;
        return;
    }
    teardown_locked();
}

void runtime::teardown_locked() {
    // Streamed teardown ordering: invalidate the generation (queued + parked
    // requests become stale), cancel the queue, wait out in-flight reads and
    // join workers, then close payload fds. Banks are cleared only after no
    // io thread can exist, and all counters freeze at their reset values.
    io_.advance_generation();
    io_.stop_and_join();
    for (int fd : payload_fds_) {
        if (fd >= 0) {
            close(fd);
        }
    }
    payload_fds_.clear();

    wave_zeros_.clear();
    cfg_ = runtime_config();
    configured_ = false;
    planning_ = false;
    vm_ = validated_manifest();
    has_manifest_ = false;
    bank_finalized_ = false;
    banks_.clear();
    handles_.clear();
    phase_layers_.clear();
    phase_layer_count_ = 0;
    for (phase_counters & counters : phase_totals_) {
        counters.reset();
    }
    active_.store(false, std::memory_order_release);
    route_active_.store(false, std::memory_order_release);
    execution_phase_.store(NOEMA_PAGED_PHASE_UNKNOWN, std::memory_order_release);
    pressure_.store(0, std::memory_order_release);
    stream_cancellable_.store(false, std::memory_order_release);
    server_started_ = false;
    server_exited_ = false;
    shutdown_requested_ = false;
    {
        std::lock_guard<std::mutex> elock(err_mu_);
        err_msg_.clear();
        poisoned_.store(false, std::memory_order_release);
    }
    {
        std::lock_guard<std::mutex> tlock(trace_mu_);
        trace_.clear();
        trace_seq_ = 0;
        trace_ids_recorded_ = 0;
    }
    route_calls_.store(0);
    ids_seen_.store(0);
    oob_ids_.store(0);
    preload_records_.store(0);
    preload_bytes_.store(0);
    preload_ms_.store(0);
    checksum_failures_.store(0);
    trace_dropped_.store(0);
    stream_hits_.store(0);
    stream_misses_.store(0);
    stream_commits_.store(0);
    stream_bytes_read_.store(0);
    stream_prefill_bytes_read_.store(0);
    stream_sweep_prefetch_issued_.store(0);
    stream_stall_ns_.store(0);
    stream_commit_ns_.store(0);
    stream_max_stall_ns_.store(0);
    stream_prefetch_issued_.store(0);
    stream_prefetch_evicted_.store(0);
    stream_history_predictions_.store(0);
    stream_history_prediction_matches_.store(0);
    stream_protected_skips_.store(0);
    stream_wave_calls_.store(0);
    stream_wave_stalls_.store(0);
    stream_expert_major_assignments_.store(0);
    stream_expert_major_skipped_.store(0);
    stream_wave_reason_.store(0);
    stream_hot_threshold_.store(0);
    stream_layer_executions_.store(0);
    stream_all_hit_layer_executions_.store(0);
    for (auto & bucket : stream_stall_hist_) {
        bucket.store(0);
    }
}

bool runtime::parse_expert_tensor_name(const char * name, uint32_t & layer, family & fam) const {
    // Canonical llama.cpp names: blk.<n>.ffn_{gate,up,down,gate_up}_exps.weight
    if (name == nullptr || strncmp(name, "blk.", 4) != 0) {
        return false;
    }
    const char * p = name + 4;
    char * endp = nullptr;
    const unsigned long l = strtoul(p, &endp, 10);
    if (endp == p || l > 0xFFFFFFFFul) {
        return false;
    }
    static const struct { const char * suffix; family fam; } TABLE[] = {
        { ".ffn_gate_up_exps.weight", family::gate_up },
        { ".ffn_gate_exps.weight",    family::gate    },
        { ".ffn_up_exps.weight",      family::up      },
        { ".ffn_down_exps.weight",    family::down    },
    };
    for (const auto & entry : TABLE) {
        if (strcmp(endp, entry.suffix) == 0) {
            layer = (uint32_t) l;
            fam = entry.fam;
            return true;
        }
    }
    return false;
}

bool runtime::bank_tensor_request(const char * name, const int64_t * ne, int n_dims,
                                  int32_t * out_type, int64_t out_ne[4]) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || !has_manifest_ || bank_finalized_ ||
        (cfg_.mode != run_mode::resident_bank && cfg_.mode != run_mode::streamed)) {
        // A finalized bank never re-materializes: a later model load that is
        // missing expert tensors (a paged resident GGUF passed as the helper
        // draft) fails as an ordinary missing-tensor load error.
        return false;
    }
    uint32_t layer = 0;
    family fam = family::gate;
    if (!parse_expert_tensor_name(name, layer, fam)) {
        return false;
    }
    const family_geometry * g = vm_.geometry_for(layer, fam);
    if (g == nullptr) {
        return false;
    }
    // Cross-check the architecture's expected full-tensor dimensions against
    // the manifest. A mismatch means the package was built for a different
    // model; fail closed by not answering (the loader reports a missing
    // required tensor and the load stops).
    if (n_dims != 3 || ne == nullptr ||
        ne[0] != g->ne0 || ne[1] != g->ne1 || ne[2] != (int64_t) vm_.mf.n_expert) {
        poison(std::string("bank request geometry mismatch for ") + name);
        return false;
    }
    if (out_type == nullptr || out_ne == nullptr) {
        return false;
    }
    *out_type = g->ggml_type;
    out_ne[0] = g->ne0;
    out_ne[1] = g->ne1;
    out_ne[2] = banks_[layer].n_slots;
    out_ne[3] = 1;
    return true;
}

bool runtime::register_bank_tensor(const char * name, ggml_tensor * t) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || !has_manifest_ || bank_finalized_ || t == nullptr) {
        return false;
    }
    uint32_t layer = 0;
    family fam = family::gate;
    if (!parse_expert_tensor_name(name, layer, fam)) {
        return false;
    }
    const family_geometry * g = vm_.geometry_for(layer, fam);
    if (g == nullptr || layer >= banks_.size()) {
        return false;
    }
    layer_bank & bank = banks_[layer];
    if (bank.tensors[(size_t) fam] != nullptr) {
        return false; // duplicate registration
    }
    if (t->type != (ggml_type) g->ggml_type ||
        t->ne[0] != g->ne0 || t->ne[1] != g->ne1 || t->ne[2] != bank.n_slots) {
        return false;
    }
    bank.tensors[(size_t) fam] = t;
    return true;
}

bool runtime::finalize_load(const char * arch_name, std::string & err) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_) {
        err = "paged runtime not configured";
        return false;
    }
    if (planning_) {
        err = "finalize_load must not run on a sizing-only configuration";
        return false;
    }
    if (cfg_.mode == run_mode::trace_only) {
        return true;
    }
    if (bank_finalized_) {
        // Bystander load after the paged target: the resident helper-draft
        // model of streamed speculation. Its tensors all came from its own
        // GGUF (bank request/register refuse once latched), so there is
        // nothing to cross-check and the live bank must not be re-finalized —
        // notably the arch check below would compare the DRAFT's architecture
        // against the target's manifest.
        return true;
    }
    if (!has_manifest_) {
        err = "paged finalize without a manifest";
        return false;
    }
    if (arch_name == nullptr || vm_.mf.architecture != arch_name) {
        err = std::string("model architecture '") + (arch_name ? arch_name : "?") +
              "' does not match paged package '" + vm_.mf.architecture + "'";
        return false;
    }

    // Every covered (layer, family) must have a registered bank tensor whose
    // per-slot stride matches the record length exactly.
    for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
        for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
            const family_geometry * g = vm_.geometry_for(l, (family) fi);
            ggml_tensor * t = banks_[l].tensors[(size_t) fi];
            if (g == nullptr) {
                if (t != nullptr) {
                    err = "bank tensor registered for an uncovered layer family";
                    return false;
                }
                continue;
            }
            if (t == nullptr) {
                err = "model did not request all paged expert tensors (layer " +
                      std::to_string(l) + " " + family_name((family) fi) + ")";
                return false;
            }
            if ((uint64_t) t->nb[2] != g->record_length) {
                err = "bank tensor stride disagrees with record length";
                return false;
            }
            if (t->buffer == nullptr || t->data == nullptr) {
                err = "bank tensor was never allocated";
                return false;
            }
        }
    }

    // Open payload files, verifying declared sizes.
    std::vector<int> fds(vm_.mf.expert_files.size(), -1);
    auto close_all = [&fds]() {
        for (int & fd : fds) {
            if (fd >= 0) {
                close(fd);
                fd = -1;
            }
        }
    };
    for (size_t i = 0; i < vm_.mf.expert_files.size(); ++i) {
        const payload_file & pf = vm_.mf.expert_files[i];
        const std::string path = vm_.dir + "/" + pf.path;
        const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            err = "payload open failed for '" + pf.path + "': " + strerror(errno);
            close_all();
            return false;
        }
        struct stat st;
        if (fstat(fd, &st) != 0 || (uint64_t) st.st_size != pf.size_bytes) {
            err = "payload size mismatch for '" + pf.path + "'";
            close(fd);
            close_all();
            return false;
        }
#if defined(F_NOCACHE)
        if (cfg_.io_nocache) {
            // Best-effort page-cache bypass (NOEMA_PAGED_NOCACHE=1): expert
            // payloads are read once per residency and evicted banks re-read
            // from disk anyway, so caching them mostly pressures memory.
            fcntl(fd, F_NOCACHE, 1);
        }
#endif
        fds[i] = fd;
    }

    if (cfg_.mode == run_mode::resident_bank) {
        // Mode 1: preload and verify every expert record into its identity slot.
        uint64_t max_len = 0;
        for (const expert_record & r : vm_.mf.records) {
            max_len = std::max(max_len, r.length);
        }
        std::vector<uint8_t> staging((size_t) max_len);

        const auto t_start = std::chrono::steady_clock::now();
        for (const expert_record & r : vm_.mf.records) {
            if (!pread_full(fds[r.file], staging.data(), r.length, r.offset, err)) {
                err = "record read failed (layer " + std::to_string(r.layer) + " " +
                      family_name(r.fam) + " expert " + std::to_string(r.expert) + "): " + err;
                close_all();
                return false;
            }
            const uint64_t h = noema_xxh64(staging.data(), (size_t) r.length, 0);
            if (h != r.xxh64) {
                checksum_failures_.fetch_add(1, std::memory_order_relaxed);
                char buf[160];
                snprintf(buf, sizeof(buf),
                         "checksum mismatch (layer %u %s expert %u): expected %016" PRIx64 " got %016" PRIx64,
                         r.layer, family_name(r.fam), r.expert, r.xxh64, h);
                err = buf;
                close_all();
                return false;
            }
            ggml_tensor * t = banks_[r.layer].tensors[(size_t) r.fam];
            ggml_backend_tensor_set(t, staging.data(), (size_t) r.expert * t->nb[2], (size_t) r.length);
            preload_records_.fetch_add(1, std::memory_order_relaxed);
            preload_bytes_.fetch_add(r.length, std::memory_order_relaxed);
        }
        const auto t_end = std::chrono::steady_clock::now();
        preload_ms_.store((uint64_t) std::chrono::duration_cast<std::chrono::milliseconds>(t_end - t_start).count(),
                          std::memory_order_relaxed);

        // The resident bank keeps nothing streaming after preload.
        close_all();
        bank_finalized_ = true;
        return true;
    }

    // Mode 2: no preload. The payload fds move to the runtime (closed at
    // teardown), the io service spins up its worker/staging pools, and every
    // slot starts empty — the first route call on each layer faults its
    // experts in.
    io_service::start_params iop;
    iop.threads          = cfg_.io_threads;
    iop.depth            = cfg_.io_depth;
    iop.staging_bytes    = (size_t) stream_group_bytes();
    iop.alignment        = (size_t) vm_.mf.alignment;
    iop.verify_checksums = cfg_.verify_checksums;
    iop.coalesce_bytes   = cfg_.io_coalesce ? (size_t) stream_coalesce_span_bytes() : 0;
    std::string io_err;
    if (!io_.start(iop, io_err)) {
        err = "streamed io start failed: " + io_err;
        close_all();
        return false;
    }
    payload_fds_ = std::move(fds);

    for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
        layer_bank & bank = banks_[l];
        if (bank.n_slots <= 0) {
            continue;
        }
        bank.slot_expert.assign((size_t) bank.n_slots, -1);
        bank.slot_loading.assign((size_t) bank.n_slots, 0);
        bank.slot_ref.assign((size_t) bank.n_slots, 0);
        bank.expert_slot.assign((size_t) vm_.mf.n_expert, -1);
        bank.clock_hand = 0;
        bank.expert_hits.assign((size_t) vm_.mf.n_expert, 0);
        bank.slot_protected.assign((size_t) bank.n_slots, 0);
        bank.protected_count = 0;
        bank.max_hits = 0;
        bank.hits_route_calls = 0;
        bank.slot_written.assign((size_t) bank.n_slots, 0);
    }
    bank_finalized_ = true;
    return true;
}

void runtime::ensure_slot_written(layer_bank & bank, int32_t il, int32_t slot) {
    // Wave placeholder rows must read verified-finite bytes: uninitialized
    // backend memory could decode as NaN, and the graph-side mask keeps NaN
    // (NaN * 0 = NaN). All-zero bytes decode to zero rows for every ggml type
    // (each block's scale is zero), so a one-time zero-fill makes the slot
    // safe until a real expert commit overwrites it. Route thread only, and
    // only inside the route callback's quiescent window.
    if (slot < 0 || (size_t) slot >= bank.slot_written.size() || bank.slot_written[(size_t) slot]) {
        return;
    }
    if (wave_zeros_.empty()) {
        wave_zeros_.assign((size_t) stream_group_bytes(), 0);
    }
    for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
        const family_geometry * g = vm_.geometry_for((uint32_t) il, (family) fi);
        ggml_tensor * t = bank.tensors[(size_t) fi];
        if (g == nullptr || t == nullptr) {
            continue;
        }
        ggml_backend_tensor_set(t, wave_zeros_.data(),
                                (size_t) slot * t->nb[2], (size_t) g->record_length);
    }
    bank.slot_written[(size_t) slot] = 1;
}

ggml_tensor * runtime::build_route_rewrite(ggml_context * ctx, ggml_tensor * selected_experts,
                                           const ggml_tensor * expert_weights, int il) {
    if (!route_active() || selected_experts == nullptr) {
        return selected_experts;
    }
    route_handle * handle = nullptr;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!configured_) {
            return selected_experts;
        }
        if (cfg_.mode == run_mode::resident_bank || cfg_.mode == run_mode::streamed) {
            if (il < 0 || (size_t) il >= banks_.size() || !vm_.layer_is_paged((uint32_t) il)) {
                return selected_experts;
            }
            // Banks are identified by tensor identity, not layer index alone:
            // the resident helper-draft model of streamed speculation builds
            // MoE graphs whose layer indices alias the target's paged layers,
            // and its real expert ids must reach its own full expert tensors.
            const layer_bank & bank = banks_[(size_t) il];
            bool is_bank_weights = false;
            for (const ggml_tensor * t : bank.tensors) {
                if (t != nullptr && t == expert_weights) {
                    is_bank_weights = true;
                    break;
                }
            }
            if (!is_bank_weights) {
                return selected_experts;
            }
            // Resident banks use the identity expert->slot map. Let the
            // selected logical ids flow directly into Metal's indexed
            // matmuls, eliminating the CPU custom node and its graph fence on
            // this guaranteed all-hit path. The knob preserves the legacy
            // callback as an A/B and regression fallback.
            if (cfg_.mode == run_mode::resident_bank && cfg_.gpu_route_hit_path) {
                return selected_experts;
            }
        }
        handle = acquire_handle_locked(il, /*group =*/ -1, /*n_groups =*/ 1, /*width =*/ 0);
    }

    ggml_tensor * args[1] = { selected_experts };
    ggml_tensor * node = ggml_custom_4d(ctx, GGML_TYPE_I32,
                                        selected_experts->ne[0], selected_experts->ne[1],
                                        selected_experts->ne[2], selected_experts->ne[3],
                                        args, 1, &runtime::route_cb, 1, handle);
    ggml_set_name(node, "noema_slot_ids");
    return node;
}

route_handle * runtime::acquire_handle_locked(int32_t il, int32_t group, int32_t n_groups,
                                              int32_t width) {
    for (route_handle & h : handles_) {
        if (h.il == il && h.group == group && h.n_groups == n_groups) {
            h.width = width; // stable across rebuilds within one configuration
            return &h;
        }
    }
    handles_.push_back(route_handle{this, il, group, n_groups, width});
    return &handles_.back();
}

// Latest wave-gate verdict for stats_json.stream.wavesRejectedReason. The
// interesting decisions are multi-token prefill graphs on the paged bank;
// helper-draft layers (identity mismatch) deliberately do NOT overwrite the
// bank's verdict so a draft graph cannot mask "engaged".
enum class wave_reason : int32_t {
    none = 0,          // no multi-token routed prefill graph seen yet
    engaged,           // waves built for the last eligible prefill layer
    biases,            // llama-graph: expert bias tensors present
    scales,            // llama-graph: per-expert scale tensors present
    weight_before_ffn, // llama-graph: pre-FFN routed weighting (llama4-style)
    waves_off,         // mode 2 but NOEMA_PAGED_WAVES not enabled at configure
    layer_not_paged,   // layer outside the paged bank set
    n_expert_mismatch, // graph n_expert != manifest n_expert
    fits_single_call,  // whole-route worst-case union fits the bank; single call cheaper
    capacity,          // no usable slots above the spare floor (fail-safe)
    not_configured,    // no streamed configuration / manifest
};

static const char * wave_reason_str(int32_t v) {
    switch ((wave_reason) v) {
        case wave_reason::none:              return "none";
        case wave_reason::engaged:           return "engaged";
        case wave_reason::biases:            return "biases";
        case wave_reason::scales:            return "scales";
        case wave_reason::weight_before_ffn: return "weightBeforeFFN";
        case wave_reason::waves_off:         return "wavesOff";
        case wave_reason::layer_not_paged:   return "layerNotPaged";
        case wave_reason::n_expert_mismatch: return "nExpertMismatch";
        case wave_reason::fits_single_call:  return "fitsSingleCall";
        case wave_reason::capacity:          return "capacity";
        case wave_reason::not_configured:    return "notConfigured";
    }
    return "unknown";
}

// "engaged" is a boot-level fact ("waves built at least once"); later smaller
// batches (decode steps, speculative verify) legitimately take the single-call
// path and must not mask it in stream.wavesRejectedReason. Reset in teardown.
void runtime::record_wave_verdict_relaxed(wave_reason r) {
    if (stream_wave_reason_.load(std::memory_order_relaxed) == (int32_t) wave_reason::engaged &&
        r != wave_reason::engaged) {
        return;
    }
    stream_wave_reason_.store((int32_t) r, std::memory_order_relaxed);
}

bool runtime::is_bank_tensor_locked(const ggml_tensor * t) const {
    if (t == nullptr) {
        return false;
    }
    for (const layer_bank & bank : banks_) {
        for (const ggml_tensor * bt : bank.tensors) {
            if (bt != nullptr && bt == t) {
                return true;
            }
        }
    }
    return false;
}

void runtime::note_wave_ineligible(const ggml_tensor * expert_weights, const char * reason) {
    if (!route_active() || reason == nullptr) {
        return;
    }
    const int32_t phase = execution_phase();
    if (phase != NOEMA_PAGED_PHASE_PROMPT_PREFILL &&
        phase != NOEMA_PAGED_PHASE_SPECULATIVE_VERIFY) {
        return;
    }
    wave_reason v = wave_reason::none;
    if (strcmp(reason, "biases") == 0) {
        v = wave_reason::biases;
    } else if (strcmp(reason, "scales") == 0) {
        v = wave_reason::scales;
    } else if (strcmp(reason, "weightBeforeFFN") == 0) {
        v = wave_reason::weight_before_ffn;
    } else {
        return;
    }
    std::lock_guard<std::mutex> lock(mu_);
    // Bystander graphs (the resident helper-draft of streamed speculation
    // builds MoE layers whose shapes trip the same gate) must never mask the
    // bank's verdict with a condition the paged model does not have.
    if (!is_bank_tensor_locked(expert_weights)) {
        return;
    }
    record_wave_verdict_relaxed(v);
}

int32_t runtime::prefill_waves(const ggml_tensor * expert_weights, int il,
                               int64_t n_tokens, int64_t n_expert) {
    if (!route_active() || n_tokens <= 1) {
        return 0;
    }
    const int32_t phase = execution_phase();
    if (phase != NOEMA_PAGED_PHASE_PROMPT_PREFILL &&
        phase != NOEMA_PAGED_PHASE_SPECULATIVE_VERIFY) {
        return 0;
    }
    const auto verdict = [this](wave_reason r) {
        record_wave_verdict_relaxed(r);
    };
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || cfg_.mode != run_mode::streamed || !has_manifest_) {
        verdict(wave_reason::not_configured);
        return 0;
    }
    // Identity precedes every per-graph verdict: a bystander (helper-draft)
    // graph must neither be wave-split nor write a verdict at all.
    if (!is_bank_tensor_locked(expert_weights)) {
        return 0;
    }
    if (!cfg_.waves) {
        verdict(wave_reason::waves_off);
        return 0;
    }
    if (il < 0 || (size_t) il >= banks_.size() || !vm_.layer_is_paged((uint32_t) il)) {
        verdict(wave_reason::layer_not_paged);
        return 0;
    }
    if (n_expert != (int64_t) vm_.mf.n_expert || vm_.mf.n_expert_used == 0) {
        verdict(wave_reason::n_expert_mismatch);
        return 0;
    }
    // Tensor-identity gate, exactly like build_route_rewrite: the resident
    // helper-draft model of streamed speculation builds MoE graphs whose layer
    // indices alias paged layers and must never be wave-split. A bystander
    // graph must not overwrite the bank's own verdict either.
    const layer_bank & bank = banks_[(size_t) il];
    bool is_bank_weights = false;
    for (const ggml_tensor * t : bank.tensors) {
        if (t != nullptr && t == expert_weights) {
            is_bank_weights = true;
            break;
        }
    }
    if (!is_bank_weights) {
        return 0;
    }
    const int32_t cap = bank.n_slots - STREAM_SPARE_SLOTS;
    if (cap <= 0) {
        verdict(wave_reason::capacity);
        return 0; // configure floor makes this unreachable; fail safe to single-call
    }
    if (cfg_.waves_force_g > 0) {
        verdict(wave_reason::engaged);
        return std::min<int32_t>(cfg_.waves_force_g, (int32_t) vm_.mf.n_expert);
    }
    // A wave only ever needs its own id range resident, so W = ceil(E / G)
    // <= cap bounds per-wave residency independent of n_tokens. When the
    // whole route's worst-case union already fits the single-call path is
    // strictly cheaper (one FFN pass instead of G).
    const int64_t worst = std::min<int64_t>(n_tokens * (int64_t) vm_.mf.n_expert_used,
                                            (int64_t) vm_.mf.n_expert);
    if (worst <= (int64_t) cap) {
        verdict(wave_reason::fits_single_call);
        return 0;
    }
    verdict(wave_reason::engaged);
    return (int32_t) (((int64_t) vm_.mf.n_expert + cap - 1) / cap);
}

bool runtime::expert_major_active(const ggml_tensor * expert_weights, int il) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || cfg_.mode != run_mode::streamed || !cfg_.waves ||
        !cfg_.expert_major || il < 0 || (size_t) il >= banks_.size()) {
        return false;
    }
    for (const ggml_tensor * tensor : banks_[(size_t) il].tensors) {
        if (tensor == expert_weights) {
            return true;
        }
    }
    return false;
}

bool runtime::fused_reduce_active(const ggml_tensor * expert_weights, int il) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || !cfg_.fused_decode ||
        (cfg_.mode != run_mode::resident_bank && cfg_.mode != run_mode::streamed) ||
        il < 0 || (size_t) il >= banks_.size()) {
        return false;
    }
    for (const ggml_tensor * tensor : banks_[(size_t) il].tensors) {
        if (tensor == expert_weights) {
            return true;
        }
    }
    return false;
}

ggml_tensor * runtime::build_route_rewrite_wave(ggml_context * ctx, ggml_tensor * selected_experts,
                                                const ggml_tensor * expert_weights, int il,
                                                int32_t group, int32_t n_groups, ggml_tensor * dep) {
    (void) expert_weights;
    if (selected_experts == nullptr || group < 0 || n_groups < 1) {
        return selected_experts;
    }
    route_handle * handle = nullptr;
    {
        std::lock_guard<std::mutex> lock(mu_);
        // Total by construction: prefill_waves() vetted mode, layer and bank
        // identity within this same graph build, and configuration cannot
        // change while the server thread is building graphs. A stale node
        // (width 0 or wrong mode) fails closed at execution time instead.
        int32_t width = 0;
        if (configured_ && has_manifest_ && vm_.mf.n_expert > 0) {
            width = (int32_t) (((int64_t) vm_.mf.n_expert + n_groups - 1) / n_groups);
        }
        handle = acquire_handle_locked(il, group, n_groups, width);
    }

    ggml_tensor * args[2] = { selected_experts, dep };
    const int n_args = dep != nullptr ? 2 : 1;
    ggml_tensor * node = ggml_custom_4d(ctx, GGML_TYPE_I32,
                                        selected_experts->ne[0], selected_experts->ne[1],
                                        selected_experts->ne[2], selected_experts->ne[3],
                                        args, n_args, &runtime::route_cb, 1, handle);
    ggml_set_name(node, "noema_slot_ids_wave");
    return node;
}

ggml_tensor * runtime::build_wave_mask(ggml_context * ctx, ggml_tensor * selected_experts,
                                       int il, int32_t group, int32_t n_groups) {
    if (selected_experts == nullptr || group < 0 || n_groups < 1) {
        return nullptr;
    }
    route_handle * handle = nullptr;
    {
        std::lock_guard<std::mutex> lock(mu_);
        int32_t width = 0;
        if (configured_ && has_manifest_ && vm_.mf.n_expert > 0) {
            width = (int32_t) (((int64_t) vm_.mf.n_expert + n_groups - 1) / n_groups);
        }
        handle = acquire_handle_locked(il, group, n_groups, width);
    }

    // Shape [1, n_expert_used, n_tokens]: elementwise-multiplies the routed
    // weights tensor, zeroing every out-of-wave contribution exactly.
    ggml_tensor * args[1] = { selected_experts };
    ggml_tensor * node = ggml_custom_4d(ctx, GGML_TYPE_F32,
                                        1, selected_experts->ne[0],
                                        selected_experts->ne[1], selected_experts->ne[2],
                                        args, 1, &runtime::wave_mask_cb, 1, handle);
    ggml_set_name(node, "noema_wave_mask");
    return node;
}

void runtime::wave_mask_cb(ggml_tensor * dst, int ith, int nth, void * userdata) {
    (void) nth;
    if (ith != 0) {
        return;
    }
    route_handle * h = (route_handle *) userdata;
    ggml_tensor * ids = dst->src[0];
    if (h == nullptr || ids == nullptr || ids->type != GGML_TYPE_I32 ||
        ids->data == nullptr || dst->data == nullptr) {
        return;
    }
    // Pure function of the real expert ids: 1.0 for this wave's id range,
    // 0.0 otherwise (including out-of-range ids — the route node poisons the
    // generation for those; the mask only has to stay memory-safe). A stale
    // node (width 0) masks everything to zero.
    const int64_t lo = (int64_t) h->group * (int64_t) h->width;
    const int64_t hi = lo + (int64_t) h->width;
    const int64_t n1 = dst->ne[1], n2 = dst->ne[2], n3 = dst->ne[3];
    for (int64_t i3 = 0; i3 < n3; ++i3) {
        for (int64_t i2 = 0; i2 < n2; ++i2) {
            for (int64_t i1 = 0; i1 < n1; ++i1) {
                const int32_t e = *(const int32_t *) ((const char *) ids->data +
                    i1 * ids->nb[0] + i2 * ids->nb[1] + i3 * ids->nb[2]);
                const bool in = h->width > 0 && (int64_t) e >= lo && (int64_t) e < hi;
                *(float *) ((char *) dst->data +
                    i1 * dst->nb[1] + i2 * dst->nb[2] + i3 * dst->nb[3]) = in ? 1.0f : 0.0f;
            }
        }
    }
}

void runtime::route_cb(ggml_tensor * dst, int ith, int nth, void * userdata) {
    (void) nth;
    if (ith != 0) {
        return;
    }
    route_handle * h = (route_handle *) userdata;
    if (h == nullptr || h->rt == nullptr) {
        return;
    }
    h->rt->run_route(dst, h);
}

// Writes one slot id per element of dst, flattened in i3/i2/i1/i0 order.
// `flat == nullptr` writes the memory-safe placeholder id `i0` (the row index
// within the token) everywhere — used after a poison so the graph finishes
// without ggml aborts. The per-token ids must stay DISTINCT even here:
// Metal's mul_mm_id row map assumes the top-k invariant (a slot id appears at
// most once per token), and duplicate placeholder ids would let its `sel`
// encoding address rows past the tensor — a bounded out-of-bounds write. i0
// is always a valid slot: every bank has at least n_expert_used slots.
static void write_slot_ids(ggml_tensor * dst, const int32_t * flat) {
    const int64_t n0 = dst->ne[0], n1 = dst->ne[1], n2 = dst->ne[2], n3 = dst->ne[3];
    size_t idx = 0;
    for (int64_t i3 = 0; i3 < n3; ++i3) {
        for (int64_t i2 = 0; i2 < n2; ++i2) {
            for (int64_t i1 = 0; i1 < n1; ++i1) {
                for (int64_t i0 = 0; i0 < n0; ++i0, ++idx) {
                    *(int32_t *) ((char *) dst->data +
                        i0 * dst->nb[0] + i1 * dst->nb[1] + i2 * dst->nb[2] + i3 * dst->nb[3]) =
                        flat ? flat[idx] : (int32_t) i0;
                }
            }
        }
    }
}

void runtime::run_route(ggml_tensor * dst, route_handle * h) {
    const int32_t phase = execution_phase();
    const bool logical_call = h != nullptr && (h->group < 0 || h->group == 0);
    const uint64_t ids = logical_call && dst != nullptr
        ? (uint64_t) dst->ne[0] * (uint64_t) dst->ne[1] *
          (uint64_t) dst->ne[2] * (uint64_t) dst->ne[3]
        : 0;
    const uint64_t stall_before = stream_stall_ns_.load(std::memory_order_relaxed);
    const uint64_t commit_before = stream_commit_ns_.load(std::memory_order_relaxed);
    const auto started = std::chrono::steady_clock::now();

    run_route_impl(dst, h, phase);

    const uint64_t total_ns = (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - started).count();
    const uint64_t stall_after = stream_stall_ns_.load(std::memory_order_relaxed);
    const uint64_t commit_after = stream_commit_ns_.load(std::memory_order_relaxed);
    record_phase_route(phase, h != nullptr ? h->il : -1, logical_call, ids, total_ns,
                       stall_after - stall_before, commit_after - commit_before);
}

void runtime::record_phase_route(int32_t phase, int32_t il, bool logical_call,
                                 uint64_t ids, uint64_t total_ns,
                                 uint64_t stall_ns, uint64_t commit_ns) {
    const uint64_t excluded = std::min(total_ns, stall_ns + commit_ns);
    const uint64_t cpu_ns = total_ns - excluded;
    for (phase_counters * counters : { &phase_total(phase), phase_layer(phase, il) }) {
        if (counters == nullptr) {
            continue;
        }
        if (logical_call) {
            counters->route_calls.fetch_add(1, std::memory_order_relaxed);
            counters->ids_seen.fetch_add(ids, std::memory_order_relaxed);
        }
        counters->stall_ns.fetch_add(stall_ns, std::memory_order_relaxed);
        counters->route_cpu_ns.fetch_add(cpu_ns, std::memory_order_relaxed);
        if (stall_ns > counters->max_route_stall_ns.load(std::memory_order_relaxed)) {
            counters->max_route_stall_ns.store(stall_ns, std::memory_order_relaxed);
        }
    }
}

void runtime::run_route_impl(ggml_tensor * dst, route_handle * h, int32_t phase) {
    ggml_tensor * ids = dst->src[0];
    if (ids == nullptr || ids->type != GGML_TYPE_I32 || ids->data == nullptr || dst->data == nullptr) {
        poison("route rewrite received an invalid ids tensor");
        return;
    }

    // Wave nodes of one layer all see the same route decision; only the wave
    // head (group 0) contributes to the whole-route counters and the trace so
    // their semantics stay comparable with the single-call path.
    const bool wave = h->group >= 0;
    const bool wave_head = !wave || h->group == 0;

    if (wave_head) {
        route_calls_.fetch_add(1, std::memory_order_relaxed);
    }

    run_mode mode = run_mode::off;
    int32_t n_expert = 0;
    bool validate = false;
    bool trace = false;
    bool oracle = false;
    bool want_prefetch = false;
    bool hot_protect = false;
    bool expert_major = false;
    int32_t timeout_ms = 0;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!configured_) {
            return;
        }
        mode = cfg_.mode;
        trace = cfg_.trace;
        oracle = cfg_.oracle_all_hit;
        want_prefetch = cfg_.prefetch;
        hot_protect = cfg_.hot_protect;
        expert_major = cfg_.expert_major;
        timeout_ms = cfg_.io_timeout_ms;
        if (mode == run_mode::resident_bank || mode == run_mode::streamed) {
            validate = true;
            n_expert = (int32_t) vm_.mf.n_expert;
        }
    }

    const int64_t n0 = dst->ne[0], n1 = dst->ne[1], n2 = dst->ne[2], n3 = dst->ne[3];
    const size_t total = (size_t) (n0 * n1 * n2 * n3);
    std::vector<int32_t> flat(total);
    bool oob = false;

    size_t idx = 0;
    for (int64_t i3 = 0; i3 < n3; ++i3) {
        for (int64_t i2 = 0; i2 < n2; ++i2) {
            for (int64_t i1 = 0; i1 < n1; ++i1) {
                for (int64_t i0 = 0; i0 < n0; ++i0, ++idx) {
                    const int32_t e = *(const int32_t *) ((const char *) ids->data +
                        i0 * ids->nb[0] + i1 * ids->nb[1] + i2 * ids->nb[2] + i3 * ids->nb[3]);
                    flat[idx] = e;
                    if (validate && (e < 0 || e >= n_expert)) {
                        if (wave_head) {
                            oob_ids_.fetch_add(1, std::memory_order_relaxed);
                        }
                        oob = true;
                    }
                }
            }
        }
    }
    if (wave_head) {
        ids_seen_.fetch_add(total, std::memory_order_relaxed);
    }

    if (trace && wave_head && !flat.empty()) {
        std::lock_guard<std::mutex> lock(trace_mu_);
        if (trace_ids_recorded_ + flat.size() <= MAX_TRACE_IDS) {
            trace_ids_recorded_ += flat.size();
            trace_entry entry;
            entry.seq = trace_seq_++;
            entry.layer = h->il;
            entry.phase = phase;
            entry.ids = flat;
            trace_.push_back(std::move(entry));
        } else {
            trace_dropped_.fetch_add(flat.size(), std::memory_order_relaxed);
        }
    }

    if (oob) {
        poison("route id out of range");
    }

    if (mode != run_mode::streamed) {
        // Identity mapping: mode 1 banks hold every expert at its own index;
        // mode 3 passes ids through untouched. Out-of-range ids write the
        // slot-0 placeholder (the request fails via take_error). A wave node
        // outside streamed mode is a stale graph against a reconfigured
        // runtime; fail the generation, never the process.
        if (wave) {
            poison("wave route node executed outside streamed mode");
            write_slot_ids(dst, nullptr);
            return;
        }
        if (oob) {
            // Poisoned already; write the duplicate-free row-index
            // placeholder (a partial e -> 0 rewrite could repeat a slot id
            // within one token, tripping the mul_mm_id row-map hazard).
            write_slot_ids(dst, nullptr);
            return;
        }
        write_slot_ids(dst, flat.data());
        return;
    }

    if (oob) {
        write_slot_ids(dst, nullptr);
        return;
    }
    run_route_streamed(dst, flat, h->il, phase, oracle, want_prefetch,
                       hot_protect, expert_major, timeout_ms, h);
}

void runtime::run_route_streamed(ggml_tensor * dst, const std::vector<int32_t> & flat, int32_t il,
                                 int32_t phase, bool oracle, bool want_prefetch,
                                 bool hot_protect, bool expert_major, int32_t timeout_ms,
                                 const route_handle * h) {
    // Slot maps and bank tensors are touched with mu_ released: the route
    // thread is their only writer while the server lives, and teardown only
    // runs after the server thread (and the io workers) are gone.
    if (il < 0 || (size_t) il >= banks_.size() || banks_[il].n_slots <= 0 ||
        banks_[il].expert_slot.empty()) {
        poison("streamed route hit an uninitialized layer bank");
        write_slot_ids(dst, nullptr);
        return;
    }
    layer_bank & bank = banks_[il];

    // Wave-split prefill: this node serves expert-id group `group` of
    // `n_groups` ([group*width, group*width + width)). Only that group's
    // experts are made resident and pinned; every other row borrows a
    // per-token-distinct placeholder slot whose finite contents the
    // graph-side mask multiplies away exactly.
    const bool wave = h != nullptr && h->group >= 0;
    const int64_t wave_lo = wave ? (int64_t) h->group * (int64_t) h->width : 0;
    const int64_t wave_hi = wave_lo + (wave ? (int64_t) h->width : 0);
    const bool wave_head = !wave || h->group == 0;
    if (wave && (h->width <= 0 || bank.slot_written.empty())) {
        poison("wave route node executed against a non-wave bank configuration");
        write_slot_ids(dst, nullptr);
        return;
    }
    const auto in_wave = [&](int32_t e) {
        return (int64_t) e >= wave_lo && (int64_t) e < wave_hi;
    };
    if (wave) {
        stream_wave_calls_.fetch_add(1, std::memory_order_relaxed);
        phase_total(phase).wave_count.fetch_add(1, std::memory_order_relaxed);
        if (phase_counters * counters = phase_layer(phase, il)) {
            counters->wave_count.fetch_add(1, std::memory_order_relaxed);
        }
    }

    const bool prompt_prefill = phase == NOEMA_PAGED_PHASE_PROMPT_PREFILL;
    if (prompt_prefill && bank.last_phase != NOEMA_PAGED_PHASE_PROMPT_PREFILL) {
        bank.sweep_cursor = 0; // entering prompt phase arms one sweep pass
    }
    bank.last_phase = phase;

    std::vector<int32_t> needed;
    needed.reserve(flat.size());
    for (int32_t e : flat) {
        if (wave && !in_wave(e)) {
            continue;
        }
        if (std::find(needed.begin(), needed.end(), e) == needed.end()) {
            needed.push_back(e);
        }
    }
    // Record the cache state at layer entry, before demand I/O changes it.
    // Decode never uses waves, so this is the exact natural all-hit ceiling
    // signal requested by the engine design. Single-call prefill and target
    // verification are useful diagnostics too; wave branches are excluded
    // because one branch is not a whole MoE-layer execution.
    if (!wave) {
        bool all_hit = true;
        for (int32_t e : needed) {
            const int32_t s = bank.expert_slot[e];
            if (s < 0 || bank.slot_loading[(size_t) s]) {
                all_hit = false;
                break;
            }
        }
        stream_layer_executions_.fetch_add(1, std::memory_order_relaxed);
        phase_total(phase).layer_executions.fetch_add(1, std::memory_order_relaxed);
        if (phase_counters * counters = phase_layer(phase, il)) {
            counters->layer_executions.fetch_add(1, std::memory_order_relaxed);
        }
        if (all_hit) {
            stream_all_hit_layer_executions_.fetch_add(1, std::memory_order_relaxed);
            phase_total(phase).all_hit_layer_executions.fetch_add(1, std::memory_order_relaxed);
            if (phase_counters * counters = phase_layer(phase, il)) {
                counters->all_hit_layer_executions.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
    // Replacement frequency is decode-local. Prompt sweeps and target
    // verification have their own telemetry and must not make their broad
    // route unions look like hot ordinary-decode experts.
    if (phase == NOEMA_PAGED_PHASE_ORDINARY_DECODE) {
        if (!wave && want_prefetch && cfg_.history_prefetch &&
            !bank.last_decode_experts.empty()) {
            stream_history_predictions_.fetch_add(
                bank.last_decode_experts.size(), std::memory_order_relaxed);
            uint64_t matches = 0;
            for (int32_t e : needed) {
                if (std::find(bank.last_decode_experts.begin(),
                              bank.last_decode_experts.end(), e) !=
                    bank.last_decode_experts.end()) {
                    matches++;
                }
            }
            stream_history_prediction_matches_.fetch_add(matches, std::memory_order_relaxed);
        }
        for (int32_t e : needed) {
            bank_note_route_hit(bank, e);
        }
        if (wave_head) {
            bank_decay_tick(bank);
        }
    }
    stream_hot_threshold_.store((uint64_t) bank_hot_threshold(bank), std::memory_order_relaxed);
    // The bridge clamps mode-2 ubatch to floor((n_slots - spare) / K) (waves
    // off) or the wave width bounds per-wave residency (waves on), so a route
    // call can pin at most n_slots - spare unique experts. More means the
    // scheduler handed a larger batch than the clamp allows; fail the
    // generation (never abort) before pins could exhaust the bank.
    if ((int32_t) needed.size() > bank.n_slots - STREAM_SPARE_SLOTS) {
        poison("route needs " + std::to_string(needed.size()) + " experts resident but the bank has " +
               std::to_string(bank.n_slots) + " slots (" + std::to_string(STREAM_SPARE_SLOTS) +
               " reserved for inbound loads)");
        write_slot_ids(dst, nullptr);
        return;
    }

    for (int32_t e : needed) {
        const int32_t s = bank.expert_slot[e];
        if (s >= 0 && !bank.slot_loading[s]) {
            stream_hits_.fetch_add(1, std::memory_order_relaxed);
            phase_total(phase).hits.fetch_add(1, std::memory_order_relaxed);
            if (phase_counters * counters = phase_layer(phase, il)) {
                counters->hits.fetch_add(1, std::memory_order_relaxed);
            }
        } else {
            stream_misses_.fetch_add(1, std::memory_order_relaxed);
            phase_total(phase).misses.fetch_add(1, std::memory_order_relaxed);
            if (phase_counters * counters = phase_layer(phase, il)) {
                counters->misses.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    uint64_t stall_ns = 0;
    std::vector<uint8_t> pinned((size_t) bank.n_slots, 0);
    bool timed_out = false;

    for (;;) {
        const uint64_t seq = io_.progress_seq();
        drain_stream_completions();
        if (poisoned_.load(std::memory_order_acquire)) {
            // A failed read (here or on another layer) already poisoned the
            // run; finish memory-safe without waiting out the deadline.
            write_slot_ids(dst, nullptr);
            record_stall(stall_ns);
            return;
        }

        bool all_resident = true;
        for (int32_t e : needed) {
            const int32_t s = bank.expert_slot[e];
            if (s >= 0) {
                pinned[s] = 1;
                if (bank.slot_loading[s]) {
                    all_resident = false; // inbound; wait for its commit
                } else {
                    bank.slot_ref[s] = 1;
                }
            } else {
                all_resident = false;
            }
        }
        if (all_resident) {
            break;
        }
        if (timed_out) {
            poison("expert read timed out after " + std::to_string(timeout_ms) +
                   " ms (layer " + std::to_string(il) + ")");
            write_slot_ids(dst, nullptr);
            record_stall(stall_ns);
            return;
        }

        // Batched issue: claim slots for every missing expert this pass can
        // afford, then hand the whole set to the io service in one call so the
        // requests are co-queued — adjacent records coalesce into merged
        // preads only when they can be gathered together.
        std::vector<io_request> to_submit;
        std::vector<slot_claim> claims;
        const size_t staging_budget = io_.free_staging_count();
        bool bad_group = false;
        for (int32_t e : needed) {
            if (bank.expert_slot[e] >= 0) {
                continue; // resident or already inbound
            }
            if (oracle) {
                poison("oracle miss (layer " + std::to_string(il) + " expert " + std::to_string(e) + ")");
                write_slot_ids(dst, nullptr);
                record_stall(stall_ns);
                return;
            }
            if (claims.size() >= staging_budget) {
                break; // staging exhausted; wait for a release
            }
            const int32_t victim = clock_select(bank, pinned, hot_protect);
            if (victim < 0) {
                break; // every candidate is pinned or mid-load; wait for a commit
            }
            io_request req;
            if (!make_group_request(il, e, /*prefetch =*/ false, req)) {
                bad_group = true; // corrupt package; poison already latched
                break;
            }
            req.phase = phase;
            bind_request_slot(req, victim);
            claims.push_back(slot_claim{e, victim, bank.slot_expert[victim]});
            const int32_t old_expert = bank.slot_expert[victim];
            if (old_expert >= 0) {
                bank.expert_slot[old_expert] = -1;
            }
            bank.slot_expert[victim] = e;
            bank.slot_loading[victim] = 1;
            bank.slot_ref[victim] = 0;
            bank.expert_slot[e] = victim;
            pinned[victim] = 1;
            to_submit.push_back(std::move(req));
        }
        if (bad_group) {
            for (const slot_claim & c : claims) {
                rollback_claim(bank, c, &pinned);
            }
            write_slot_ids(dst, nullptr);
            record_stall(stall_ns);
            return;
        }
        if (!to_submit.empty()) {
            const size_t accepted = io_.submit_batch(to_submit);
            for (size_t ci = accepted; ci < claims.size(); ++ci) {
                rollback_claim(bank, claims[ci], &pinned);
            }
        }

        const auto t0 = std::chrono::steady_clock::now();
        const bool progressed = io_.wait_progress(seq, deadline);
        stall_ns += (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - t0).count();
        if (!progressed) {
            timed_out = true; // one final drain pass, then fail closed
        }
    }

    std::vector<int32_t> slots(flat.size());
    if (!wave) {
        for (size_t i = 0; i < flat.size(); ++i) {
            slots[i] = bank.expert_slot[flat[i]];
        }
    } else if (expert_major) {
        for (size_t i = 0; i < flat.size(); ++i) {
            if (in_wave(flat[i])) {
                slots[i] = bank.expert_slot[flat[i]];
                stream_expert_major_assignments_.fetch_add(1, std::memory_order_relaxed);
            } else {
                // Negative ids are an internal sentinel understood by the
                // sparse mul_mat_id path. They never index bank storage.
                slots[i] = -1;
                stream_expert_major_skipped_.fetch_add(1, std::memory_order_relaxed);
            }
        }
    } else {
        // Metal's mul_mm_id row map (kernel_mul_mm_id_map0) encodes each
        // expert's rows assuming a slot id appears AT MOST ONCE PER TOKEN —
        // the top-k invariant. A shared placeholder would appear K times per
        // all-masked token and mis-map real experts' rows (silent cross-row
        // corruption). So each token's out-of-wave rows borrow DISTINCT
        // placeholder slots, skipping the token's in-wave slots; the graph
        // mask zeroes their finite contributions exactly. flat is token-major
        // (i1 tokens of i0 = n_expert_used rows each).
        const size_t k_rows = (size_t) dst->ne[0];
        for (size_t base = 0; base < flat.size(); base += k_rows) {
            const size_t row_count = std::min(k_rows, flat.size() - base);
            int32_t placeholder = 0;
            for (size_t k = 0; k < row_count; ++k) {
                const int32_t e = flat[base + k];
                if (in_wave(e)) {
                    slots[base + k] = bank.expert_slot[e];
                    continue;
                }
                // Advance past this token's in-wave slots; previously
                // assigned placeholders are strictly below the cursor.
                for (;;) {
                    bool taken = false;
                    for (size_t j = 0; j < row_count; ++j) {
                        if (in_wave(flat[base + j]) && bank.expert_slot[flat[base + j]] == placeholder) {
                            taken = true;
                            break;
                        }
                    }
                    if (!taken) {
                        break;
                    }
                    ++placeholder;
                }
                if (placeholder >= bank.n_slots) {
                    // Unreachable: n_slots >= K + spare leaves K distinct ids.
                    poison("wave placeholder assignment ran out of slots");
                    write_slot_ids(dst, nullptr);
                    record_stall(stall_ns);
                    return;
                }
                ensure_slot_written(bank, il, placeholder);
                slots[base + k] = placeholder++;
            }
        }
    }
    write_slot_ids(dst, slots.data());

    if (want_prefetch && pressure_.load(std::memory_order_acquire) < 1) {
        if (prompt_prefill) {
            // Prefill: the temporal next-layer guess is weak (whole-chunk
            // routed sets change layer to layer) and would speculate on every
            // chunk; the bounded sequential sweep warms this layer instead.
            // Under waves the sweep doubles as next-wave overlap: the cursor
            // walks the id space in group order and only this wave's slots
            // are pinned, so it fills free/cold slots with upcoming groups.
            sweep_prefetch_streamed(bank, il, pinned, phase);
        } else if (phase == NOEMA_PAGED_PHASE_ORDINARY_DECODE) {
            const int32_t next_il = il + 1;
            if (cfg_.history_prefetch && next_il >= 0 &&
                (size_t) next_il < banks_.size() &&
                !banks_[(size_t) next_il].last_decode_experts.empty()) {
                prefetch_streamed(next_il,
                                  banks_[(size_t) next_il].last_decode_experts,
                                  phase);
            } else {
                // First decoded token has no same-layer history yet.
                prefetch_streamed(next_il, needed, phase);
            }
        } else if (phase == NOEMA_PAGED_PHASE_SPECULATIVE_VERIFY) {
            prefetch_streamed(il + 1, needed, phase);
        }
    }

    if (!wave && phase == NOEMA_PAGED_PHASE_ORDINARY_DECODE) {
        bank.last_decode_experts = needed;
    }

    if (wave && stall_ns > 0) {
        stream_wave_stalls_.fetch_add(1, std::memory_order_relaxed);
        phase_total(phase).wave_stalls.fetch_add(1, std::memory_order_relaxed);
        if (phase_counters * counters = phase_layer(phase, il)) {
            counters->wave_stalls.fetch_add(1, std::memory_order_relaxed);
        }
    }
    record_stall(stall_ns);
}

void runtime::drain_stream_completions() {
    std::vector<io_request> done = io_.take_completed();
    for (io_request & req : done) {
        layer_bank * bank = (req.layer >= 0 && (size_t) req.layer < banks_.size())
                                ? &banks_[(size_t) req.layer] : nullptr;
        const int32_t s = (bank != nullptr && req.expert >= 0 &&
                           (size_t) req.expert < bank->expert_slot.size())
                              ? bank->expert_slot[req.expert] : -1;
        const bool tracked = s >= 0 && bank->slot_loading[s] && bank->slot_expert[s] == req.expert;
        for (phase_counters * counters : { &phase_total(req.phase), phase_layer(req.phase, req.layer) }) {
            if (counters != nullptr) {
                counters->read_ns.fetch_add(req.read_ns, std::memory_order_relaxed);
                counters->checksum_ns.fetch_add(req.checksum_ns, std::memory_order_relaxed);
                counters->staging_copy_ns.fetch_add(req.staging_copy_ns, std::memory_order_relaxed);
            }
        }
        if (!req.ok) {
            if (req.checksum_failed) {
                checksum_failures_.fetch_add(1, std::memory_order_relaxed);
            }
            poison("expert read failed (layer " + std::to_string(req.layer) +
                   " expert " + std::to_string(req.expert) + "): " + req.error);
            if (tracked) {
                bank->slot_expert[s] = -1;
                bank->slot_loading[s] = 0;
                bank->expert_slot[req.expert] = -1;
            }
        } else if (tracked) {
            // Full group verified by the io worker; only now does the slot
            // become resident (expert_slot stays "inbound" until this commit).
            const auto t0 = std::chrono::steady_clock::now();
            uint64_t group_bytes = 0;
            for (const io_part & part : req.parts) {
                ggml_tensor * t = bank->tensors[(size_t) part.fam];
                // Direct-I/O requests already contain checksum-verified bytes
                // at this exact final address. Staged/private-buffer requests
                // retain the existing backend copy path.
                if (part.direct_dst == nullptr) {
                    ggml_backend_tensor_set(t, req.staging + part.staging_offset,
                                            (size_t) s * t->nb[2], (size_t) part.length);
                }
                group_bytes += part.length;
            }
            const uint64_t commit_ns = (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - t0).count();
            stream_commit_ns_.fetch_add(commit_ns, std::memory_order_relaxed);
            stream_bytes_read_.fetch_add(group_bytes, std::memory_order_relaxed);
            if (req.phase == NOEMA_PAGED_PHASE_PROMPT_PREFILL) {
                // Issue-time attribution: reads born in a prefill route call
                // (demand or sweep) count as prefill even when their commit
                // drains during decode.
                stream_prefill_bytes_read_.fetch_add(group_bytes, std::memory_order_relaxed);
            }
            for (phase_counters * counters : { &phase_total(req.phase), phase_layer(req.phase, req.layer) }) {
                if (counters != nullptr) {
                    counters->bytes_read.fetch_add(group_bytes, std::memory_order_relaxed);
                    counters->commit_ns.fetch_add(commit_ns, std::memory_order_relaxed);
                }
            }
            stream_commits_.fetch_add(1, std::memory_order_relaxed);
            bank->slot_loading[s] = 0;
            bank->slot_ref[s] = 1;
            if ((size_t) s < bank->slot_written.size()) {
                bank->slot_written[s] = 1; // verified expert bytes landed
            }
        }
        io_.release(req.staging);
        req.staging = nullptr;
    }
}

void runtime::prefetch_streamed(int32_t il, const std::vector<int32_t> & experts, int32_t phase) {
    // Temporal prefetch: the caller supplies its best route prediction for
    // this layer (normally the same layer's prior-token experts). Free slots
    // are claimed first; when the bank is full a guess may
    // still replace a CLOCK-evictable resident (never pinned, never loading,
    // ref bit already clear) so steady-state prefill keeps overlapping reads
    // with compute — bounded to half the layer's non-pinned slots per route
    // call. The scan neither clears ref bits nor moves the hand; only real
    // misses run the destructive CLOCK sweep. Results park in the io service
    // until the next route callback commits them.
    if (il < 0 || (size_t) il >= banks_.size()) {
        return;
    }
    layer_bank & bank = banks_[(size_t) il];
    if (bank.n_slots <= 0 || bank.expert_slot.empty()) {
        return;
    }
    // Slots already holding experts of the incoming set are pinned for this
    // pass: evicting one guess to load another would be self-defeating.
    std::vector<uint8_t> pinned((size_t) bank.n_slots, 0);
    int32_t pinned_count = 0;
    for (int32_t e : experts) {
        const int32_t s = bank.expert_slot[e];
        if (s >= 0 && !pinned[(size_t) s]) {
            pinned[(size_t) s] = 1;
            pinned_count++;
        }
    }
    int32_t evict_budget = (bank.n_slots - pinned_count) / 2;
    // Claims accumulate and submit as one batch (co-queued guesses coalesce
    // with each other when their records are adjacent on disk).
    std::vector<io_request> to_submit;
    std::vector<slot_claim> claims;
    std::vector<uint8_t> claim_evicts;
    const size_t staging_budget = io_.free_staging_count();
    for (int32_t e : experts) {
        if (bank.expert_slot[e] >= 0) {
            continue;
        }
        if (claims.size() >= staging_budget) {
            break; // staging exhausted — prefetch is optional, never wait
        }
        int32_t slot = -1;
        bool evicts = false;
        for (int32_t s = 0; s < bank.n_slots; ++s) {
            if (bank.slot_expert[s] < 0 && !bank.slot_loading[s]) {
                slot = s;
                break;
            }
        }
        if (slot < 0) {
            if (evict_budget <= 0) {
                break;
            }
            for (int32_t step = 0; step < bank.n_slots; ++step) {
                const int32_t s = (bank.clock_hand + step) % bank.n_slots;
                // Protected slots hold hot experts; optional speculation never
                // spends their extra chance, it just looks elsewhere.
                if (pinned[(size_t) s] || bank.slot_loading[(size_t) s] ||
                    bank.slot_ref[(size_t) s] || bank.slot_protected[(size_t) s]) {
                    continue;
                }
                slot = s;
                evicts = true;
                break;
            }
            if (slot < 0) {
                break; // every candidate is hot, pinned or mid-load
            }
        }
        io_request req;
        if (!make_group_request(il, e, /*prefetch =*/ true, req)) {
            break; // corrupt package; the demand path fails the run
        }
        req.phase = phase;
        bind_request_slot(req, slot);
        claims.push_back(slot_claim{e, slot, bank.slot_expert[slot]});
        claim_evicts.push_back(evicts ? 1 : 0);
        const int32_t old_expert = bank.slot_expert[slot];
        if (old_expert >= 0) {
            bank.expert_slot[old_expert] = -1;
        }
        bank.slot_expert[slot] = e;
        bank.slot_loading[slot] = 1;
        bank.slot_ref[slot] = 0;
        bank.expert_slot[e] = slot;
        if (evicts) {
            evict_budget--;
        }
        to_submit.push_back(std::move(req));
    }
    if (to_submit.empty()) {
        return;
    }
    const size_t accepted = io_.submit_batch(to_submit);
    for (size_t ci = 0; ci < accepted; ++ci) {
        stream_prefetch_issued_.fetch_add(1, std::memory_order_relaxed);
        if (claim_evicts[ci]) {
            stream_prefetch_evicted_.fetch_add(1, std::memory_order_relaxed);
        }
    }
    for (size_t ci = accepted; ci < claims.size(); ++ci) {
        rollback_claim(bank, claims[ci], nullptr);
    }
}

void runtime::sweep_prefetch_streamed(layer_bank & bank, int32_t il,
                                      const std::vector<uint8_t> & pinned, int32_t phase) {
    // Prefill sweep-prefetch: one sequential pass over the expert-id space per
    // prefill (armed at the decode->prefill transition). A long prefill touches
    // nearly every expert repeatedly, so warming the bank in id order converts
    // a bounded number of future demand misses into reads that overlap compute
    // — and the single pass bounds speculation, unlike a per-call sweep, which
    // would chase its own evictions read after read. Strictly optional by
    // construction: only free or cold-evictable slots (never pinned, loading
    // or ref'd; the scan neither clears ref bits nor moves the CLOCK hand),
    // and an exhausted staging pool means stop, never wait — the cursor holds
    // on the blocked expert and the next prefill route call resumes the pass.
    const int32_t n_expert = (int32_t) bank.expert_slot.size();
    // Consecutive missing experts claim together and submit as one batch —
    // their records are exactly the adjacent-on-disk case read coalescing
    // merges into single preads.
    std::vector<io_request> to_submit;
    std::vector<slot_claim> claims;
    const size_t staging_budget = io_.free_staging_count();
    while (bank.sweep_cursor >= 0 && bank.sweep_cursor < n_expert) {
        const int32_t e = bank.sweep_cursor;
        if (bank.expert_slot[e] >= 0) {
            bank.sweep_cursor++; // resident or inbound; nothing to warm
            continue;
        }
        if (claims.size() >= staging_budget) {
            break; // staging exhausted — prefetch is optional, never wait
        }
        int32_t slot = -1;
        for (int32_t s = 0; s < bank.n_slots; ++s) {
            if (bank.slot_expert[s] < 0 && !bank.slot_loading[s]) {
                slot = s;
                break;
            }
        }
        if (slot < 0) {
            for (int32_t s = 0; s < bank.n_slots; ++s) {
                if (!pinned[(size_t) s] && !bank.slot_loading[s] && !bank.slot_ref[s] &&
                    !bank.slot_protected[s]) {
                    slot = s;
                    break;
                }
            }
        }
        if (slot < 0) {
            break; // every slot is hot, pinned or mid-load; resume next call
        }
        io_request req;
        if (!make_group_request(il, e, /*prefetch =*/ true, req)) {
            break; // corrupt package already poisoned; the route path fails the run
        }
        req.phase = phase;
        bind_request_slot(req, slot);
        claims.push_back(slot_claim{e, slot, bank.slot_expert[slot]});
        const int32_t old_expert = bank.slot_expert[slot];
        if (old_expert >= 0) {
            bank.expert_slot[old_expert] = -1;
        }
        bank.slot_expert[slot] = e;
        bank.slot_loading[slot] = 1;
        bank.slot_ref[slot] = 0;
        bank.expert_slot[e] = slot;
        to_submit.push_back(std::move(req));
        bank.sweep_cursor++;
    }
    if (to_submit.empty()) {
        return;
    }
    const size_t accepted = io_.submit_batch(to_submit);
    stream_sweep_prefetch_issued_.fetch_add(accepted, std::memory_order_relaxed);
    if (accepted < claims.size()) {
        // Unwind refused claims and park the cursor on the first of them so
        // the next prefill route call resumes the pass there.
        for (size_t ci = accepted; ci < claims.size(); ++ci) {
            rollback_claim(bank, claims[ci], nullptr);
        }
        bank.sweep_cursor = claims[accepted].expert;
    }
}

void bank_note_route_hit(layer_bank & bank, int32_t expert) {
    if (expert < 0 || (size_t) expert >= bank.expert_hits.size()) {
        return;
    }
    uint16_t & h = bank.expert_hits[(size_t) expert];
    if (h < UINT16_MAX) {
        h++;
    }
    // Counters only grow between decays, so raising max on the way up keeps
    // it exact without ever rescanning the counter array.
    if (h > bank.max_hits) {
        bank.max_hits = h;
    }
}

void bank_decay_tick(layer_bank & bank) {
    if (++bank.hits_route_calls < HOT_HITS_DECAY_INTERVAL) {
        return;
    }
    bank.hits_route_calls = 0;
    uint16_t max = 0;
    for (uint16_t & h : bank.expert_hits) {
        h = (uint16_t) (h >> 1);
        max = std::max(max, h);
    }
    bank.max_hits = max;
}

int32_t bank_hot_threshold(const layer_bank & bank) {
    return (int32_t) (bank.max_hits / HOT_THRESHOLD_DIVISOR);
}

int32_t bank_clock_select(layer_bank & bank, const std::vector<uint8_t> & pinned,
                          bool hot_protect, uint64_t & protected_skips) {
    // Second-chance CLOCK with trace-driven hot-expert protection. Per slot
    // visit (slots pinned by the current route call or mid-load are never
    // eligible and never mutated):
    //   1. ref bit set       -> clear it, skip (the classic second chance);
    //   2. protected bit set -> spend it and EVICT: the extra chance was the
    //      grant visit in step 3, and spend-on-sight is what makes the whole
    //      scheme livelock-free;
    //   3. resident expert strictly above the hot threshold, protected slots
    //      below half the non-pinned slots -> set the protected bit, skip
    //      (the one extra second-chance hot experts get);
    //   4. otherwise         -> evict.
    //
    // NO LIVELOCK: within one call no access can re-set a ref bit, so each
    // slot is skipped at most twice — the first visit can only clear its ref
    // bit and the second can only grant the protected bit (step 2 runs before
    // step 3, so a spent slot is evicted before it could ever be re-granted).
    // A third visit therefore lands in step 2 or 4 and returns the slot:
    // after at most one full sweep every slot the hand met is evictable, and
    // 3*n visits always produce a victim whenever at least one unpinned,
    // non-loading slot exists. When none exists the caller sees -1 exactly as
    // before. The grant cap is not needed for termination; it only bounds how
    // much of the bank protection may hold hostage from a single route call.
    const int32_t n = bank.n_slots;
    int32_t non_pinned = 0;
    for (int32_t s = 0; s < n; ++s) {
        if (!pinned[(size_t) s]) {
            non_pinned++;
        }
    }
    const int32_t protect_cap = non_pinned / 2;
    const int32_t threshold = bank_hot_threshold(bank);
    for (int32_t step = 0; step < 3 * n; ++step) {
        const int32_t s = bank.clock_hand;
        bank.clock_hand = (bank.clock_hand + 1) % n;
        if (pinned[(size_t) s] || bank.slot_loading[(size_t) s]) {
            continue;
        }
        if (bank.slot_ref[(size_t) s]) {
            bank.slot_ref[(size_t) s] = 0;
            continue;
        }
        if (bank.slot_protected[(size_t) s]) {
            bank.slot_protected[(size_t) s] = 0;
            bank.protected_count--;
            return s;
        }
        const int32_t e = bank.slot_expert[(size_t) s];
        if (hot_protect && e >= 0 && (size_t) e < bank.expert_hits.size() &&
            (int32_t) bank.expert_hits[(size_t) e] > threshold &&
            bank.protected_count < protect_cap) {
            bank.slot_protected[(size_t) s] = 1;
            bank.protected_count++;
            protected_skips++;
            continue;
        }
        return s;
    }
    return -1;
}

int32_t runtime::clock_select(layer_bank & bank, const std::vector<uint8_t> & pinned,
                              bool hot_protect) {
    uint64_t skips = 0;
    const int32_t victim = bank_clock_select(bank, pinned, hot_protect, skips);
    if (skips > 0) {
        stream_protected_skips_.fetch_add(skips, std::memory_order_relaxed);
    }
    return victim;
}

void runtime::rollback_claim(layer_bank & bank, const slot_claim & c,
                             std::vector<uint8_t> * pinned) {
    bank.expert_slot[c.expert] = -1;
    bank.slot_expert[c.slot] = c.old_expert;
    bank.slot_loading[c.slot] = 0;
    if (c.old_expert >= 0) {
        bank.expert_slot[c.old_expert] = c.slot; // untouched resident restored
    }
    if (pinned != nullptr) {
        // The demand path pinned the claimed slot; a slot is only claimable
        // when it was not pinned before, so the revert is unconditional.
        (*pinned)[(size_t) c.slot] = 0;
    }
}

bool runtime::make_group_request(int32_t il, int32_t expert, bool prefetch, io_request & out) {
    out = io_request();
    out.layer = il;
    out.expert = expert;
    out.prefetch = prefetch;
    uint64_t staging_offset = 0;
    for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
        const family_geometry * g = vm_.geometry_for((uint32_t) il, (family) fi);
        if (g == nullptr) {
            continue;
        }
        const expert_record * r = vm_.record_for((uint32_t) il, (family) fi, (uint32_t) expert);
        if (r == nullptr || r->file >= payload_fds_.size()) {
            // Validation guarantees full coverage; reaching this is corruption.
            poison("missing expert record (layer " + std::to_string(il) +
                   " " + family_name((family) fi) + " expert " + std::to_string(expert) + ")");
            return false;
        }
        io_part part;
        part.fd = payload_fds_[r->file];
        part.fam = fi;
        part.offset = r->offset;
        part.length = r->length;
        part.xxh64 = r->xxh64;
        part.staging_offset = staging_offset;
        staging_offset += r->length;
        out.parts.push_back(part);
    }
    return !out.parts.empty();
}

void runtime::bind_request_slot(io_request & req, int32_t slot) {
    // Demand routes synchronously wait for the verified completion before the
    // graph resumes, so their target slot is GPU-quiescent. Prefetches are
    // intentionally asynchronous; they must keep staging so a worker never
    // mutates a bank slot while Metal may still read that layer.
    if (!cfg_.direct_io || req.prefetch || req.layer < 0 ||
        (size_t) req.layer >= banks_.size() || slot < 0) {
        return;
    }
    layer_bank & bank = banks_[(size_t) req.layer];
    if (slot >= bank.n_slots) {
        return;
    }

    // Every family must be CPU-addressable. A mixed request would complicate
    // publication and make the telemetry ambiguous, so fall back wholesale
    // when even one tensor lives in private device storage.
    for (const io_part & part : req.parts) {
        if (part.fam < 0 || part.fam >= FAMILY_COUNT) {
            return;
        }
        ggml_tensor * t = bank.tensors[(size_t) part.fam];
        if (t == nullptr || t->buffer == nullptr || t->data == nullptr ||
            (!ggml_backend_metal_buffer_is_shared(t->buffer) &&
             !ggml_backend_buffer_is_host(t->buffer))) {
            return;
        }
    }
    for (io_part & part : req.parts) {
        ggml_tensor * t = bank.tensors[(size_t) part.fam];
        part.direct_dst = (uint8_t *) t->data + (size_t) slot * t->nb[2];
    }
}

uint64_t runtime::stream_group_bytes() const {
    uint64_t max_group = 0;
    for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
        uint64_t group = 0;
        for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
            const family_geometry * g = vm_.geometry_for(l, (family) fi);
            if (g != nullptr) {
                group += g->record_length;
            }
        }
        max_group = std::max(max_group, group);
    }
    return max_group;
}

uint64_t runtime::stream_coalesce_span_bytes() const {
    uint64_t max_rec = 0;
    for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
        for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
            const family_geometry * g = vm_.geometry_for(l, (family) fi);
            if (g != nullptr) {
                max_rec = std::max(max_rec, g->record_length);
            }
        }
    }
    // At most one queued request per staging buffer, so io_depth bounds how
    // many same-layer records could ever merge; alignment bounds each gap.
    const uint64_t m = std::min<uint64_t>((uint64_t) cfg_.io_depth, vm_.mf.n_expert);
    if (max_rec == 0 || m < 2) {
        return 0;
    }
    return std::min<uint64_t>(m * max_rec + (m - 1) * vm_.mf.alignment, 64ull << 20);
}

void runtime::record_stall(uint64_t stall_ns) {
    stream_stall_ns_.fetch_add(stall_ns, std::memory_order_relaxed);
    if (stall_ns > stream_max_stall_ns_.load(std::memory_order_relaxed)) {
        stream_max_stall_ns_.store(stall_ns, std::memory_order_relaxed); // route thread is the only writer
    }
    // log2 buckets: 0 covers < 8192 ns, each next bucket doubles, the last
    // absorbs everything >= ~8.4 ms (timeouts land there).
    int bucket = 0;
    if (stall_ns >= 8192) {
        uint64_t v = stall_ns >> 13;
        while (v > 0 && bucket < STALL_HIST_BUCKETS - 1) {
            bucket++;
            v >>= 1;
        }
    }
    stream_stall_hist_[(size_t) bucket].fetch_add(1, std::memory_order_relaxed);
}

void runtime::poison(const std::string & msg) {
    std::lock_guard<std::mutex> lock(err_mu_);
    if (err_msg_.empty()) {
        err_msg_ = msg;
    }
    poisoned_.store(true, std::memory_order_release);
}

bool runtime::take_error(std::string & out) {
    if (!poisoned_.load(std::memory_order_acquire)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(err_mu_);
        out = err_msg_;
        err_msg_.clear();
        poisoned_.store(false, std::memory_order_release);
    }
    // Consumption point of a failed generation. The server thread calls this
    // right after llama_decode returns, so no route callback is live and the
    // slot maps are safe to touch. Sweep every in-flight ("loading") slot
    // marker: after a cancel the io generation was bumped, so those requests
    // were dropped and no commit will ever clear the flags — a later route
    // call would otherwise wait on them until its io timeout. For non-cancel
    // poisons the sweep merely discards a pending read's residency (its
    // completion turns untracked and is dropped), which a healthy follow-up
    // generation simply re-fetches.
    std::lock_guard<std::mutex> lock(mu_);
    if (configured_ && cfg_.mode == run_mode::streamed) {
        for (layer_bank & bank : banks_) {
            for (size_t s = 0; s < bank.slot_loading.size(); ++s) {
                if (!bank.slot_loading[s]) {
                    continue;
                }
                const int32_t e = bank.slot_expert[s];
                if (e >= 0 && (size_t) e < bank.expert_slot.size()) {
                    bank.expert_slot[e] = -1;
                }
                bank.slot_expert[s] = -1;
                bank.slot_loading[s] = 0;
                bank.slot_ref[s] = 0;
            }
        }
    }
    return true;
}

void runtime::cancel_active() {
    // Streamed generations only. Modes 0/1/3 never wait on paged I/O
    // mid-decode, and outside the configure→teardown window there is nothing
    // to cancel — poisoning then would only fail a future healthy run. The
    // gate is a lock-free snapshot: taking mu_ here could block the calling
    // app thread behind a minutes-long mode-1 preload that holds it.
    if (!stream_cancellable_.load(std::memory_order_acquire)) {
        return;
    }
    // Order matters: latch the poison first so a route thread woken by the
    // generation bump below observes it on its next loop pass. The bump drops
    // every queued and in-flight-completion read, and its unconditional
    // progress broadcast snaps any route callback out of wait_progress
    // immediately; the route path then fails closed (placeholder slot ids),
    // the decode loop surfaces the error via take_error — which also clears
    // the latch and sweeps the orphaned in-flight slot markers — and the
    // server stays up for the next request.
    poison("generation cancelled");
    io_.advance_generation();
}

void runtime::apply_pressure(int32_t level) {
    if (level < 0) {
        level = 0;
    }
    if (level > 3) {
        level = 3;
    }
    pressure_.store(level, std::memory_order_release);
    // >=1 stops new prefetches (route thread checks pressure_); the io
    // service handles >=2 (single in-flight read) and >=3 (shed queued
    // prefetches) itself.
    io_.set_pressure(level);
}

std::string runtime::stats_json() {
    json j;
    bool streamed = false;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!configured_) {
            return "";
        }
        streamed = cfg_.mode == run_mode::streamed;
        j["mode"] = (int32_t) cfg_.mode;
        j["active"] = active();
        j["waves"] = cfg_.waves;
        j["expertMajor"] = cfg_.expert_major;
        j["fusedDecode"] = cfg_.fused_decode;
        j["directIO"] = cfg_.direct_io;
        j["gpuRouteHitPath"] = cfg_.gpu_route_hit_path;
        j["historyPrefetch"] = cfg_.history_prefetch;
        // Effective page-cache-bypass state for this boot. The env knob is
        // sampled at configure time (every start), so the app can verify a
        // per-launch setenv/unsetenv of NOEMA_PAGED_NOCACHE actually took.
#if defined(F_NOCACHE)
        j["ioNoCache"] = cfg_.io_nocache;
#else
        j["ioNoCache"] = false;
#endif
        if (has_manifest_) {
            j["architecture"] = vm_.mf.architecture;
            j["nExpert"] = vm_.mf.n_expert;
            j["nExpertUsed"] = vm_.mf.n_expert_used;
            j["moeLayerCount"] = vm_.mf.moe_layer_count;
        }
    }
    j["routeCalls"] = route_calls_.load(std::memory_order_relaxed);
    j["idsSeen"] = ids_seen_.load(std::memory_order_relaxed);
    j["oobIds"] = oob_ids_.load(std::memory_order_relaxed);
    j["preload"] = {
        {"records", preload_records_.load(std::memory_order_relaxed)},
        {"bytes",   preload_bytes_.load(std::memory_order_relaxed)},
        {"ms",      preload_ms_.load(std::memory_order_relaxed)},
    };
    j["checksumFailures"] = checksum_failures_.load(std::memory_order_relaxed);
    j["traceDroppedIds"] = trace_dropped_.load(std::memory_order_relaxed);
    j["poisoned"] = poisoned_.load(std::memory_order_acquire);
    j["pressureLevel"] = pressure_.load(std::memory_order_acquire);
    j["executionPhase"] = phase_name(execution_phase());

    const auto counters_json = [](const phase_counters & c) {
        return json{
            {"routeCalls", c.route_calls.load(std::memory_order_relaxed)},
            {"idsSeen", c.ids_seen.load(std::memory_order_relaxed)},
            {"hits", c.hits.load(std::memory_order_relaxed)},
            {"misses", c.misses.load(std::memory_order_relaxed)},
            {"bytesRead", c.bytes_read.load(std::memory_order_relaxed)},
            {"readNs", c.read_ns.load(std::memory_order_relaxed)},
            {"checksumNs", c.checksum_ns.load(std::memory_order_relaxed)},
            {"stagingCopyNs", c.staging_copy_ns.load(std::memory_order_relaxed)},
            {"commitNs", c.commit_ns.load(std::memory_order_relaxed)},
            {"stallNs", c.stall_ns.load(std::memory_order_relaxed)},
            {"maxRouteStallNs", c.max_route_stall_ns.load(std::memory_order_relaxed)},
            {"routeCpuNs", c.route_cpu_ns.load(std::memory_order_relaxed)},
            {"waveCount", c.wave_count.load(std::memory_order_relaxed)},
            {"waveStalls", c.wave_stalls.load(std::memory_order_relaxed)},
            {"checkpointRestoreNs", c.checkpoint_restore_ns.load(std::memory_order_relaxed)},
            {"layerExecutions", c.layer_executions.load(std::memory_order_relaxed)},
            {"allHitLayerExecutions", c.all_hit_layer_executions.load(std::memory_order_relaxed)},
        };
    };
    json phases = json::object();
    {
        // Atomics make live route/I/O updates safe, but the flattened layer
        // table itself is lifecycle-owned and teardown clears it. Hold mu_
        // while walking the stable records so a stats poll racing stop cannot
        // observe freed storage.
        std::lock_guard<std::mutex> lock(mu_);
        if (!configured_) {
            return "";
        }
        for (int32_t phase = 0; phase < PHASE_COUNT; ++phase) {
            json snapshot = counters_json(phase_total(phase));
            json layers = json::array();
            for (uint32_t il = 0; il < phase_layer_count_; ++il) {
                const phase_counters * layer = phase_layer(phase, (int32_t) il);
                if (layer == nullptr || layer->empty()) {
                    continue;
                }
                json layer_json = counters_json(*layer);
                layer_json["layer"] = il;
                layers.push_back(std::move(layer_json));
            }
            snapshot["layers"] = std::move(layers);
            phases[phase_name(phase)] = std::move(snapshot);
        }
    }
    j["phases"] = std::move(phases);

    if (streamed) {
        const uint64_t layer_executions = stream_layer_executions_.load(std::memory_order_relaxed);
        const uint64_t all_hit_layers = stream_all_hit_layer_executions_.load(std::memory_order_relaxed);
        json hist = json::array();
        for (const auto & bucket : stream_stall_hist_) {
            hist.push_back(bucket.load(std::memory_order_relaxed));
        }
        j["stream"] = {
            {"hits",            stream_hits_.load(std::memory_order_relaxed)},
            {"misses",          stream_misses_.load(std::memory_order_relaxed)},
            {"commits",         stream_commits_.load(std::memory_order_relaxed)},
            {"bytesRead",       stream_bytes_read_.load(std::memory_order_relaxed)},
            {"prefillBytesRead", stream_prefill_bytes_read_.load(std::memory_order_relaxed)},
            {"stallNs",         stream_stall_ns_.load(std::memory_order_relaxed)},
            {"commitNs",        stream_commit_ns_.load(std::memory_order_relaxed)},
            {"maxRouteStallNs", stream_max_stall_ns_.load(std::memory_order_relaxed)},
            {"prefetchIssued",  stream_prefetch_issued_.load(std::memory_order_relaxed)},
            {"prefetchEvicted", stream_prefetch_evicted_.load(std::memory_order_relaxed)},
            {"historyPredictions", stream_history_predictions_.load(std::memory_order_relaxed)},
            {"historyPredictionMatches", stream_history_prediction_matches_.load(std::memory_order_relaxed)},
            {"sweepPrefetchIssued", stream_sweep_prefetch_issued_.load(std::memory_order_relaxed)},
            {"protectedSkips",  stream_protected_skips_.load(std::memory_order_relaxed)},
            {"hotThreshold",    stream_hot_threshold_.load(std::memory_order_relaxed)},
            {"waveCount",       stream_wave_calls_.load(std::memory_order_relaxed)},
            {"waveStalls",      stream_wave_stalls_.load(std::memory_order_relaxed)},
            {"expertMajorAssignments", stream_expert_major_assignments_.load(std::memory_order_relaxed)},
            {"expertMajorSkippedAssignments", stream_expert_major_skipped_.load(std::memory_order_relaxed)},
            {"wavesRejectedReason",
                                wave_reason_str(stream_wave_reason_.load(std::memory_order_relaxed))},
            {"ioReads",         io_.total_reads()},
            {"coalescedReads",  io_.coalesced_reads()},
            {"coalescedBytes",  io_.coalesced_bytes()},
            {"directReads",     io_.direct_reads()},
            {"directBytes",     io_.direct_bytes()},
            {"checksumVerifications", io_.checksum_verifications()},
            {"checksumCacheHits", io_.checksum_cache_hits()},
            {"layerExecutions", layer_executions},
            {"allHitLayerExecutions", all_hit_layers},
            {"allHitLayerPercent", layer_executions > 0
                ? 100.0 * (double) all_hit_layers / (double) layer_executions
                : 0.0},
            {"stallHistogramLog2", std::move(hist)},
        };
    }
    return j.dump();
}

uint64_t runtime::bank_bytes_total() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (!has_manifest_) {
        return 0;
    }
    uint64_t total = 0;
    for (uint32_t l = 0; l < vm_.mf.total_layer_count; ++l) {
        for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
            const family_geometry * g = vm_.geometry_for(l, (family) fi);
            if (g != nullptr && l < banks_.size()) {
                total += g->record_length * (uint64_t) banks_[l].n_slots;
            }
        }
    }
    return total;
}

uint64_t runtime::staging_bytes_total() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (!has_manifest_) {
        return 0;
    }
    if (cfg_.mode == run_mode::streamed) {
        // The streamed pool holds io_depth buffers, each sized for the
        // largest per-expert family group (one request per whole group),
        // plus one merged-read scratch per io worker when coalescing is on.
        uint64_t total = stream_group_bytes() * (uint64_t) cfg_.io_depth;
        if (cfg_.io_coalesce) {
            total += stream_coalesce_span_bytes() * (uint64_t) cfg_.io_threads;
        }
        return total;
    }
    uint64_t max_len = 0;
    for (const expert_record & r : vm_.mf.records) {
        max_len = std::max(max_len, r.length);
    }
    return max_len; // mode 1 preloads through a single staging buffer
}

int32_t runtime::bank_slots() const {
    std::lock_guard<std::mutex> lock(mu_);
    for (const layer_bank & b : banks_) {
        if (b.n_slots > 0) {
            return b.n_slots;
        }
    }
    return 0;
}

uint32_t runtime::moe_layer_count() const {
    std::lock_guard<std::mutex> lock(mu_);
    return has_manifest_ ? vm_.mf.moe_layer_count : 0;
}

int32_t runtime::max_ubatch() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || cfg_.mode != run_mode::streamed || !has_manifest_ ||
        vm_.mf.n_expert_used == 0) {
        return 0;
    }
    if (cfg_.waves) {
        // Wave-split prefill bounds per-wave residency by the group width,
        // independent of the micro-batch, so the bank imposes no clamp.
        return 0;
    }
    int32_t n_slots = 0;
    for (const layer_bank & b : banks_) {
        if (b.n_slots > 0) {
            n_slots = b.n_slots;
            break;
        }
    }
    if (n_slots <= 0) {
        return 0;
    }
    return std::max<int32_t>(
        1, (n_slots - STREAM_SPARE_SLOTS) / (int32_t) vm_.mf.n_expert_used);
}

int32_t runtime::max_draft_tokens() const {
    std::lock_guard<std::mutex> lock(mu_);
    if (!configured_ || cfg_.mode != run_mode::streamed || !has_manifest_ ||
        vm_.mf.n_expert_used == 0 || cfg_.waves) {
        return -1; // no paged draft clamp
    }
    int32_t n_slots = 0;
    for (const layer_bank & b : banks_) {
        if (b.n_slots > 0) {
            n_slots = b.n_slots;
            break;
        }
    }
    if (n_slots <= 0) {
        return -1;
    }
    const int32_t verify_tokens = std::max<int32_t>(
        1, (n_slots - STREAM_SPARE_SLOTS) / (int32_t) vm_.mf.n_expert_used);
    return std::max<int32_t>(0, verify_tokens - 1);
}

std::string runtime::trace_json_and_clear() {
    json entries = json::array();
    uint64_t dropped = trace_dropped_.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(trace_mu_);
        for (const trace_entry & e : trace_) {
            entries.push_back({
                {"seq", e.seq},
                {"layer", e.layer},
                {"phase", phase_name(e.phase)},
                {"ids", e.ids},
            });
        }
        trace_.clear();
        trace_ids_recorded_ = 0;
    }
    json j;
    j["entries"] = std::move(entries);
    j["droppedIds"] = dropped;
    return j.dump();
}

} // namespace noema_paged


using noema_paged::runtime;

static thread_local std::string t_hook_err;
static thread_local std::string t_hook_json;

extern "C" int noema_paged_configure(const noema_paged_config_c * cfg, const char ** err_out) {
    std::string err;
    if (runtime::global().configure(cfg, /*planning =*/ false, err)) {
        return 1;
    }
    t_hook_err = err;
    if (err_out != nullptr) {
        *err_out = t_hook_err.c_str();
    }
    return 0;
}

extern "C" int32_t noema_paged_max_ubatch(void) {
    return runtime::current().max_ubatch();
}

extern "C" int32_t noema_paged_max_draft_tokens(void) {
    return runtime::current().max_draft_tokens();
}

extern "C" void noema_paged_mark_server_started(void) {
    runtime::global().mark_server_started();
}

extern "C" void noema_paged_on_server_exit(void) {
    runtime::global().on_server_exit();
}

extern "C" void noema_paged_shutdown(void) {
    runtime::global().shutdown();
}

extern "C" int noema_paged_active(void) {
    return runtime::current().active() ? 1 : 0;
}

extern "C" int noema_paged_route_active(void) {
    return runtime::current().route_active() ? 1 : 0;
}

extern "C" int32_t noema_paged_set_execution_phase(int32_t phase) {
    return runtime::global().set_execution_phase(phase);
}

extern "C" int32_t noema_paged_get_execution_phase(void) {
    return runtime::global().execution_phase();
}

extern "C" void noema_paged_note_checkpoint_restore(uint64_t elapsed_ns) {
    runtime::global().note_checkpoint_restore(elapsed_ns);
}

extern "C" int noema_paged_bank_tensor_request(const char * name,
                                               const int64_t * ne,
                                               int n_dims,
                                               int32_t * out_ggml_type,
                                               int64_t out_ne[4]) {
    return runtime::current().bank_tensor_request(name, ne, n_dims, out_ggml_type, out_ne) ? 1 : 0;
}

extern "C" int noema_paged_register_bank_tensor(const char * name, struct ggml_tensor * t) {
    return runtime::current().register_bank_tensor(name, t) ? 1 : 0;
}

extern "C" int noema_paged_finalize_load(const char * arch_name, const char ** err_out) {
    std::string err;
    if (runtime::current().finalize_load(arch_name, err)) {
        return 1;
    }
    t_hook_err = err;
    if (err_out != nullptr) {
        *err_out = t_hook_err.c_str();
    }
    return 0;
}

extern "C" struct ggml_tensor * noema_paged_build_route_rewrite(struct ggml_context * ctx,
                                                                struct ggml_tensor * selected_experts,
                                                                const struct ggml_tensor * expert_weights,
                                                                int il) {
    return runtime::current().build_route_rewrite(ctx, selected_experts, expert_weights, il);
}

extern "C" int32_t noema_paged_prefill_waves(const struct ggml_tensor * expert_weights,
                                             int il, int64_t n_tokens, int64_t n_expert) {
    return runtime::current().prefill_waves(expert_weights, il, n_tokens, n_expert);
}

extern "C" int noema_paged_expert_major_active(const struct ggml_tensor * expert_weights,
                                                int il) {
    return runtime::current().expert_major_active(expert_weights, il) ? 1 : 0;
}

extern "C" int noema_paged_fused_reduce_active(const struct ggml_tensor * expert_weights,
                                                int il) {
    return runtime::current().fused_reduce_active(expert_weights, il) ? 1 : 0;
}

extern "C" void noema_paged_note_wave_ineligible(const struct ggml_tensor * expert_weights,
                                                 const char * reason) {
    runtime::current().note_wave_ineligible(expert_weights, reason);
}

extern "C" struct ggml_tensor * noema_paged_build_route_rewrite_wave(
        struct ggml_context * ctx,
        struct ggml_tensor * selected_experts,
        const struct ggml_tensor * expert_weights,
        int il, int32_t group, int32_t n_groups,
        struct ggml_tensor * dep) {
    return runtime::current().build_route_rewrite_wave(ctx, selected_experts, expert_weights,
                                                       il, group, n_groups, dep);
}

extern "C" struct ggml_tensor * noema_paged_build_wave_mask(struct ggml_context * ctx,
                                                            struct ggml_tensor * selected_experts,
                                                            int il, int32_t group, int32_t n_groups) {
    return runtime::current().build_wave_mask(ctx, selected_experts, il, group, n_groups);
}

extern "C" int noema_paged_take_error(char * buf, size_t buflen) {
    std::string msg;
    if (!runtime::global().take_error(msg)) {
        return 0;
    }
    if (buf != nullptr && buflen > 0) {
        const size_t n = std::min(buflen - 1, msg.size());
        memcpy(buf, msg.data(), n);
        buf[n] = '\0';
    }
    return 1;
}

extern "C" const char * noema_paged_stats_json(void) {
    t_hook_json = runtime::global().stats_json();
    return t_hook_json.c_str();
}

extern "C" const char * noema_paged_trace_json(void) {
    t_hook_json = runtime::global().trace_json_and_clear();
    return t_hook_json.c_str();
}

extern "C" void noema_paged_apply_pressure(int32_t level) {
    runtime::global().apply_pressure(level);
}

extern "C" void noema_paged_cancel_active(void) {
    runtime::global().cancel_active();
}
