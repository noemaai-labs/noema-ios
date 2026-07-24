// Modes 1 and 2 use resident and streamed expert banks; mode 3 is trace-only.
// Bank slots change only in GPU-quiescent route callbacks.
#pragma once

#include "noema_paged_hooks.h"
#include "noema_paged_io.h"
#include "noema_paged_manifest.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

struct ggml_context;
struct ggml_tensor;

namespace noema_paged {

enum class run_mode : int32_t {
    off           = 0,
    resident_bank = 1,
    streamed      = 2,
    trace_only    = 3,
};

// Streamed-bank spare slots kept free of route pins so inbound loads always
// have somewhere to land. Feeds both the configure floor (n_expert_used +
// spare) and the prefill micro-batch clamp floor((n_slots - spare) / K).
constexpr int32_t STREAM_SPARE_SLOTS = 2;

// Hot-expert protection (streamed bank). Every streamed route call counts one
// hit per unique routed expert into per-layer saturating uint16 counters; an
// expert strictly above hot_threshold = max_hits / HOT_THRESHOLD_DIVISOR earns
// one extra CLOCK second-chance via a separate protected bit. Counters halve
// every HOT_HITS_DECAY_INTERVAL route calls of their layer so the threshold
// tracks the recent trace instead of all-time history.
constexpr uint32_t HOT_HITS_DECAY_INTERVAL = 4096;
constexpr int32_t  HOT_THRESHOLD_DIVISOR   = 4;

struct runtime_config {
    run_mode    mode = run_mode::off;
    std::string manifest_path;
    int32_t     slots_per_layer = 0;
    int32_t     bank_budget_mib = 0;
    int32_t     io_threads = 2;
    int32_t     io_depth = 4;
    int32_t     io_timeout_ms = 30000;
    bool        prefetch = false;
    bool        oracle_all_hit = false;
    bool        trace = false;
    std::string trace_path;
    bool        verify_checksums = true;
    int32_t     telemetry_interval_ms = 0;
    // Diagnostic/test overrides read from the environment at configure time:
    //   NOEMA_PAGED_NO_COALESCE=1    -> io_coalesce = false (A/B testing)
    //   NOEMA_PAGED_NOCACHE=1        -> io_nocache = true (F_NOCACHE payload fds)
    //   NOEMA_PAGED_NO_HOT_PROTECT=1 -> hot_protect = false (A/B testing)
    //   NOEMA_PAGED_WAVES=0/1        -> override the v4 wave policy
    //   NOEMA_PAGED_EXPERT_MAJOR=1   -> force sparse expert-major execution
    //   NOEMA_PAGED_NO_EXPERT_MAJOR=1 -> old placeholder-wave fallback
    //   NOEMA_PAGED_NO_FUSED_DECODE=1 -> old weight/mul/view/add reduction
    //   NOEMA_PAGED_WAVES_FORCE_G=n  -> waves_force_g = n (test-only group override)
    bool        io_coalesce = true;
    bool        io_nocache = false;
    bool        direct_io = true;
    bool        gpu_route_hit_path = true;
    bool        fused_decode = true;
    bool        hot_protect = true;
    bool        history_prefetch = true;
    // Wave-split expert-major prefill (mode 2). When on, prefill graphs split
    // each MoE layer's routed compute
    // into expert-group waves and the micro-batch clamp lifts (max_ubatch()
    // reports 0). Out-of-wave rows borrow per-token-distinct placeholder
    // slots (lazily zero-filled), so the bank keeps its full capacity.
    bool        waves = false;
    bool        expert_major = false;
    int32_t     waves_force_g = 0;
};

struct layer_bank {
    std::array<ggml_tensor *, FAMILY_COUNT> tensors{};
    int32_t n_slots = 0;
    // Wave-split prefill: 1 once a slot has ever held verified bytes (an
    // expert commit or a lazy zero-fill). Out-of-wave route rows borrow slots
    // as placeholders — Metal's mul_mm_id row map requires every slot id to
    // appear at most once per token, so each token's placeholder rows use
    // DISTINCT slots — and a never-written slot could decode as NaN, which
    // the graph-side 0.0 mask would keep (NaN * 0 = NaN). First placeholder
    // use of an untouched slot therefore zero-fills it. Route thread only.
    std::vector<uint8_t> slot_written;
    // Streamed (mode 2) slot state, sized at finalize. Residency of expert e
    // means expert_slot[e] >= 0 AND that slot's loading flag is clear; a set
    // loading flag marks a slot claimed by an in-flight (unverified) read.
    // Touched only by the route thread and post-join teardown.
    std::vector<int32_t> slot_expert;  // slot -> occupying/incoming expert, -1 empty
    std::vector<uint8_t> slot_loading; // 1 while an io request targets the slot
    std::vector<uint8_t> slot_ref;     // CLOCK second-chance bit
    std::vector<int32_t> expert_slot;  // expert -> slot (resident or incoming), -1 otherwise
    int32_t clock_hand = 0;
    // Hot-expert protection state (route thread only, like the slot maps).
    // slot_protected is the extra CLOCK second-chance bit; protected_count
    // mirrors the number of set bits so the grant cap check stays O(1).
    // max_hits is exact between decays (counters only grow there) and is
    // recomputed at each halving — "lazy" only in that no lookup rescans.
    std::vector<uint16_t> expert_hits;    // per-expert saturating hit counters
    std::vector<uint8_t>  slot_protected; // hot-expert extra second-chance bit
    int32_t  protected_count = 0;
    uint16_t max_hits = 0;
    uint32_t hits_route_calls = 0; // this layer's route calls since the last halving
    // Prefill sweep-prefetch (mode 2, prefetch flag): one sequential pass over
    // the expert-id space per prefill. The cursor is armed (reset to 0) at the
    // decode->prefill transition, holds on an expert it cannot issue yet (no
    // slot / no staging) and parks at n_expert when the pass completes.
    int32_t sweep_cursor = 0;
    int32_t last_phase = NOEMA_PAGED_PHASE_UNKNOWN;
    // Ordinary-decode route set from the preceding token at this exact
    // layer. Expert labels are layer-local, so this is a stronger predictor
    // than copying the current layer's ids into the next layer.
    std::vector<int32_t> last_decode_experts;
};

// Hot-expert protection primitives, free functions on layer_bank so the
// debug-only test hooks can drive the exact threshold/decay/CLOCK math on a
// synthetic bank without booting a server. The route thread is the only
// caller in production.
void    bank_note_route_hit(layer_bank & bank, int32_t expert);
void    bank_decay_tick(layer_bank & bank);
int32_t bank_hot_threshold(const layer_bank & bank);
int32_t bank_clock_select(layer_bank & bank, const std::vector<uint8_t> & pinned,
                          bool hot_protect, uint64_t & protected_skips);

class runtime;

// Stable-address userdata for the route-rewrite custom node. Lives in a deque
// owned by the runtime so op_params stay byte-identical across graph rebuilds
// (a requirement for llama.cpp graph reuse). group == -1 is the classic
// whole-route node; group >= 0 identifies one wave of a wave-split prefill
// layer (n_groups waves of `width` consecutive expert ids each).
struct route_handle {
    runtime * rt = nullptr;
    int32_t   il = -1;
    int32_t   group = -1;
    int32_t   n_groups = 1;
    int32_t   width = 0;
};

// Defined in noema_paged_runtime.cpp; forward-declared here only so the
// verdict recorder can be a member.
enum class wave_reason : int32_t;

class runtime {
public:
    // Process-global instance driven by the server bridge / loader hooks.
    static runtime & global();
    // Loader hooks route through current(): a thread-bound planning instance
    // (no-alloc sizing) when set, else the global one.
    static runtime & current();
    static void set_planning(runtime * rt);

    // `planning` marks a sizing-only configuration: finalize_load must never
    // run and no payload file is touched.
    bool configure(const noema_paged_config_c * cfg, bool planning, std::string & err);

    void mark_server_started();
    void on_server_exit();
    void shutdown();

    bool active() const { return active_.load(std::memory_order_acquire); }
    bool route_active() const { return route_active_.load(std::memory_order_acquire); }

    bool bank_tensor_request(const char * name, const int64_t * ne, int n_dims,
                             int32_t * out_type, int64_t out_ne[4]);
    bool register_bank_tensor(const char * name, ggml_tensor * t);
    bool finalize_load(const char * arch_name, std::string & err);

    ggml_tensor * build_route_rewrite(ggml_context * ctx, ggml_tensor * selected_experts,
                                      const ggml_tensor * expert_weights, int il);

    // Wave-split prefill graph surface (all no-ops / zeros unless mode 2 with
    // the waves knob on). prefill_waves returns 0 for "keep the single-call
    // path" and G >= 1 for "build G expert-group wave branches".
    int32_t prefill_waves(const ggml_tensor * expert_weights, int il,
                          int64_t n_tokens, int64_t n_expert);
    bool expert_major_active(const ggml_tensor * expert_weights, int il);
    bool fused_reduce_active(const ggml_tensor * expert_weights, int il);
    // Telemetry: latest wave-gate verdict for a multi-token prefill layer.
    // prefill_waves records its own verdicts; llama-graph reports tensor-shape
    // ineligibility ("biases"/"scales"/"weightBeforeFFN") through this before
    // prefill_waves is ever called. `expert_weights` identifies the graph:
    // only registered bank tensors may write a verdict, so bystander
    // (helper-draft) graphs never mask it. Exposed as
    // stream.wavesRejectedReason; "engaged" is sticky until teardown.
    void note_wave_ineligible(const ggml_tensor * expert_weights, const char * reason);
    ggml_tensor * build_route_rewrite_wave(ggml_context * ctx, ggml_tensor * selected_experts,
                                           const ggml_tensor * expert_weights, int il,
                                           int32_t group, int32_t n_groups, ggml_tensor * dep);
    ggml_tensor * build_wave_mask(ggml_context * ctx, ggml_tensor * selected_experts,
                                  int il, int32_t group, int32_t n_groups);

    void poison(const std::string & msg);
    bool take_error(std::string & out);
    void cancel_active();
    void apply_pressure(int32_t level);
    int32_t pressure_level() const { return pressure_.load(std::memory_order_acquire); }

    std::string stats_json();
    std::string trace_json_and_clear();

    // Analytic sizing for the memory-estimate path (valid after configure).
    uint64_t bank_bytes_total() const;
    uint64_t staging_bytes_total() const;
    int32_t  bank_slots() const;
    uint32_t moe_layer_count() const;
    // Largest prefill micro-batch the streamed bank can serve while keeping
    // the spare slots free: floor((n_slots - spare) / n_expert_used), min 1.
    // 0 for every non-streamed mode (no clamp).
    int32_t  max_ubatch() const;
    int32_t  max_draft_tokens() const;

    int32_t set_execution_phase(int32_t phase);
    int32_t execution_phase() const;
    void note_checkpoint_restore(uint64_t elapsed_ns);

private:
    static void route_cb(ggml_tensor * dst, int ith, int nth, void * userdata);
    static void wave_mask_cb(ggml_tensor * dst, int ith, int nth, void * userdata);
    void run_route(ggml_tensor * dst, route_handle * h);
    void run_route_impl(ggml_tensor * dst, route_handle * h, int32_t phase);
    void run_route_streamed(ggml_tensor * dst, const std::vector<int32_t> & flat, int32_t il,
                            int32_t phase, bool oracle, bool want_prefetch,
                            bool hot_protect, bool expert_major, int32_t timeout_ms,
                            const route_handle * h);
    route_handle * acquire_handle_locked(int32_t il, int32_t group, int32_t n_groups,
                                         int32_t width);
    void record_wave_verdict_relaxed(wave_reason r);
    bool is_bank_tensor_locked(const ggml_tensor * t) const;
    void ensure_slot_written(layer_bank & bank, int32_t il, int32_t slot);
    void drain_stream_completions();
    void prefetch_streamed(int32_t il, const std::vector<int32_t> & experts, int32_t phase);
    void sweep_prefetch_streamed(layer_bank & bank, int32_t il,
                                 const std::vector<uint8_t> & pinned, int32_t phase);
    int32_t clock_select(layer_bank & bank, const std::vector<uint8_t> & pinned, bool hot_protect);
    bool make_group_request(int32_t il, int32_t expert, bool prefetch, io_request & out);
    void bind_request_slot(io_request & req, int32_t slot);
    uint64_t stream_group_bytes() const; // largest per-expert family-group, bytes
    // Merged-read scratch sizing: worst-case coalesced run of min(io_depth,
    // n_expert) records plus alignment gaps, capped at 64 MiB. 0 when the
    // manifest cannot coalesce (fewer than 2 records could ever merge).
    uint64_t stream_coalesce_span_bytes() const;

    // One tentatively-claimed streamed slot: bank bookkeeping applied before
    // the batched io submit, unwound via rollback_claim for any request the
    // service refused (its slot state reverts exactly, old resident restored).
    struct slot_claim {
        int32_t expert = -1;
        int32_t slot = -1;
        int32_t old_expert = -1;
    };
    static void rollback_claim(layer_bank & bank, const slot_claim & c,
                               std::vector<uint8_t> * pinned);
    void record_stall(uint64_t stall_ns);
    static int32_t normalize_phase(int32_t phase);
    void record_phase_route(int32_t phase, int32_t il, bool logical_call,
                            uint64_t ids, uint64_t total_ns,
                            uint64_t stall_ns, uint64_t commit_ns);
    bool parse_expert_tensor_name(const char * name, uint32_t & layer, family & fam) const;
    void teardown_locked();

    struct trace_entry {
        uint64_t seq;
        int32_t  layer;
        int32_t  phase;
        std::vector<int32_t> ids;
    };

    static constexpr int32_t PHASE_COUNT = 5;
    struct phase_counters {
        std::atomic<uint64_t> route_calls{0};
        std::atomic<uint64_t> ids_seen{0};
        std::atomic<uint64_t> hits{0};
        std::atomic<uint64_t> misses{0};
        std::atomic<uint64_t> bytes_read{0};
        std::atomic<uint64_t> read_ns{0};
        std::atomic<uint64_t> checksum_ns{0};
        std::atomic<uint64_t> staging_copy_ns{0};
        std::atomic<uint64_t> commit_ns{0};
        std::atomic<uint64_t> stall_ns{0};
        std::atomic<uint64_t> max_route_stall_ns{0};
        std::atomic<uint64_t> route_cpu_ns{0};
        std::atomic<uint64_t> wave_count{0};
        std::atomic<uint64_t> wave_stalls{0};
        std::atomic<uint64_t> checkpoint_restore_ns{0};
        std::atomic<uint64_t> layer_executions{0};
        std::atomic<uint64_t> all_hit_layer_executions{0};

        void reset();
        bool empty() const;
    };

    phase_counters & phase_total(int32_t phase);
    phase_counters * phase_layer(int32_t phase, int32_t il);
    const phase_counters & phase_total(int32_t phase) const;
    const phase_counters * phase_layer(int32_t phase, int32_t il) const;

    mutable std::mutex mu_;
    runtime_config cfg_;
    bool configured_ = false;
    bool planning_   = false;
    validated_manifest vm_;
    bool has_manifest_ = false;
    // Latched by the first successful finalize_load (the paged target). Later
    // loads in the same window — the resident helper-draft model of streamed
    // speculation — are bystanders: finalize no-ops, bank request/register
    // refuse. Reset by configure/teardown.
    bool bank_finalized_ = false;
    std::vector<layer_bank> banks_;
    std::deque<route_handle> handles_;

    std::atomic<bool> active_{false};
    std::atomic<bool> route_active_{false};
    std::atomic<int32_t> execution_phase_{NOEMA_PAGED_PHASE_UNKNOWN};
    std::atomic<int32_t> pressure_{0};
    // Lock-free gate for cancel_active: set by a successful non-planning
    // streamed (mode 2) configure, cleared at teardown. The cancel entry point
    // must never take mu_ (a mode-1 preload holds it for the whole load).
    std::atomic<bool> stream_cancellable_{false};

    // lifecycle
    bool server_started_ = false;
    bool server_exited_  = false;
    bool shutdown_requested_ = false;

    // poison latch
    std::mutex err_mu_;
    std::string err_msg_;
    std::atomic<bool> poisoned_{false};

    // trace
    std::mutex trace_mu_;
    std::vector<trace_entry> trace_;
    uint64_t trace_seq_ = 0;
    size_t trace_ids_recorded_ = 0;

    // streamed I/O (mode 2); payload fds stay open until teardown
    io_service io_;
    std::vector<int> payload_fds_;
    // Lazy zero-fill scratch for wave placeholder slots (route thread only).
    std::vector<uint8_t> wave_zeros_;

    // counters
    std::atomic<uint64_t> route_calls_{0};
    std::atomic<uint64_t> ids_seen_{0};
    std::atomic<uint64_t> oob_ids_{0};
    std::atomic<uint64_t> preload_records_{0};
    std::atomic<uint64_t> preload_bytes_{0};
    std::atomic<uint64_t> preload_ms_{0};
    std::atomic<uint64_t> checksum_failures_{0};
    std::atomic<uint64_t> trace_dropped_{0};

    // streamed counters (route thread writes, stats thread reads)
    static constexpr int STALL_HIST_BUCKETS = 12;
    std::atomic<uint64_t> stream_hits_{0};
    std::atomic<uint64_t> stream_misses_{0};
    std::atomic<uint64_t> stream_commits_{0};
    std::atomic<uint64_t> stream_bytes_read_{0};         // total committed group bytes
    std::atomic<uint64_t> stream_prefill_bytes_read_{0}; // subset issued from prefill route calls
    std::atomic<uint64_t> stream_sweep_prefetch_issued_{0};
    std::atomic<uint64_t> stream_stall_ns_{0};
    std::atomic<uint64_t> stream_commit_ns_{0};
    std::atomic<uint64_t> stream_max_stall_ns_{0};
    std::atomic<uint64_t> stream_prefetch_issued_{0};
    std::atomic<uint64_t> stream_prefetch_evicted_{0};
    std::atomic<uint64_t> stream_history_predictions_{0};
    std::atomic<uint64_t> stream_history_prediction_matches_{0};
    std::atomic<uint64_t> stream_protected_skips_{0};
    // Wave-split prefill: wave route-node executions, and how many of them
    // had to stall on expert I/O.
    std::atomic<uint64_t> stream_wave_calls_{0};
    std::atomic<uint64_t> stream_wave_stalls_{0};
    std::atomic<uint64_t> stream_expert_major_assignments_{0};
    std::atomic<uint64_t> stream_expert_major_skipped_{0};
    // Latest wave-gate verdict for a multi-token prefill layer (graph-build
    // thread writes, stats thread reads); wave_reason enum in the .cpp.
    std::atomic<int32_t> stream_wave_reason_{0};
    // Stats-only snapshot of the most recently routed layer's hot threshold
    // (per-layer counters live in the banks, which stats readers must not
    // touch while the route thread owns them).
    std::atomic<uint64_t> stream_hot_threshold_{0};
    std::atomic<uint64_t> stream_layer_executions_{0};
    std::atomic<uint64_t> stream_all_hit_layer_executions_{0};
    std::array<std::atomic<uint64_t>, STALL_HIST_BUCKETS> stream_stall_hist_{};

    // Phase totals plus a flattened [phase][layer] table. Atomics keep the
    // diagnostics reader independent of the route/I/O threads; deque gives
    // stable storage for the non-copyable counter records.
    std::array<phase_counters, PHASE_COUNT> phase_totals_{};
    std::deque<phase_counters> phase_layers_;
    uint32_t phase_layer_count_ = 0;
};

} // namespace noema_paged
