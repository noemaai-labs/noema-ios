#pragma once

#if defined(__GNUC__) || defined(__clang__)
#define NOEMA_LLAMA_SERVER_API __attribute__((visibility("default")))
#else
#define NOEMA_LLAMA_SERVER_API
#endif

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION 4u

// Byte size of the v2 configuration struct on LP64 targets. The bridge accepts
// v2 callers by copying exactly this prefix and zeroing every v3 field; a
// static_assert in server_bridge.mm pins offsetof(paged_mode) to this value.
#define NOEMA_LLAMA_SERVER_CONFIGURATION_V2_SIZE 224u

// Byte size of the v3 configuration struct on LP64 targets. v3 ends after
// paged_telemetry_interval_ms; v4 appends explicit wave/expert-major policy.
// The bridge accepts v3 callers by copying this prefix and zeroing the v4
// fields, preserving the former opt-in-only behavior exactly.
#define NOEMA_LLAMA_SERVER_CONFIGURATION_V3_SIZE 288u

// Immutable, versioned startup contract. The bridge validates version/size and
// copies every value before starting the server thread. Optional strings may be
// NULL or empty. Negative optional integer/double values keep upstream defaults.
typedef struct noema_llama_server_configuration {
    uint32_t version;
    uint32_t size;
    const char *host;
    int32_t preferred_port;
    const char *gguf_path;
    const char *mmproj_path;
    const char *draft_model_path;
    const char *chat_template_file;
    int32_t reasoning_budget;
    int32_t use_jinja;
    int32_t context_size;
    int32_t context_shift;
    int32_t gpu_layers;
    int32_t threads;
    int32_t threads_batch;
    int32_t batch_size;
    int32_t ubatch_size;
    int32_t use_mmap;
    int32_t use_mlock;
    int32_t warmup;
    int32_t kv_offload;
    int32_t flash_attention;
    const char *cache_type_k;
    const char *cache_type_v;
    int32_t parallel_slots;
    const char *tensor_override;
    int32_t cpu_moe;
    int32_t moe_expert_count;
    double yarn_scale;
    int32_t yarn_original_context;
    double yarn_beta_fast;
    double yarn_beta_slow;
    int32_t cache_ram_mib;
    int32_t ctx_checkpoints;
    const char *speculative_type;
    int32_t spec_draft_n_max;
    int32_t spec_draft_n_min;
    double spec_draft_p_min;
    int32_t spec_dynamic;
    int32_t kv_unified;
    /* v3 — Noema Overfit paged MoE execution. Zero values keep paging off and
       reproduce v2 behavior exactly. Modes 1 and 2 fail closed against
       conflicting options; the one speculative shape mode 2 admits is
       speculative_type "draft-simple" with a draft_model_path, whose helper
       model loads resident beside the paged target (spec_draft_n_max is
       clamped to the streamed micro-batch bound). */
    int32_t paged_mode;                  /* 0 off, 1 resident-bank parity, 2 streamed, 3 trace-only */
    const char *paged_manifest_path;     /* .noema-paged manifest.json; required for modes 1 and 2 */
    int32_t paged_slots_per_layer;       /* <=0: derive from paged_bank_budget_mib */
    int32_t paged_bank_budget_mib;       /* <=0: paged_slots_per_layer must be set (modes 2/3) */
    int32_t paged_io_threads;            /* <=0: default 2; clamped to [1,4] */
    int32_t paged_io_depth;              /* <=0: default 4 staging buffers; clamped to [1,16] */
    int32_t paged_io_timeout_ms;         /* <=0: default 30000 */
    int32_t paged_prefetch;              /* 0/1: temporal prefetch (performance only, never correctness) */
    int32_t paged_oracle_all_hit;        /* 0/1: any bank miss poisons the run (canary oracle) */
    int32_t paged_trace;                 /* 0/1: record per-token route traces */
    const char *paged_trace_path;        /* optional route-trace dump target */
    int32_t paged_verify_checksums;      /* 0 headers only, 1 verify each record once per boot (default) */
    int32_t paged_telemetry_interval_ms; /* 0 = stats snapshot on demand only */
    /* v4 — explicit wave-split/expert-major prefill policy. Keeping these in
       the immutable launch contract ensures app-visible configuration and
       native behavior cannot drift through process-global environment state.
       Environment overrides remain available only as diagnostic/test kill
       switches. */
    int32_t paged_waves;                 /* 0/1: wave-split streamed prefill */
    int32_t paged_expert_major;          /* 0/1: skip inactive wave assignments */
} noema_llama_server_configuration;

NOEMA_LLAMA_SERVER_API int noema_llama_server_start_with_configuration(
    const noema_llama_server_configuration *configuration);

// Starts the in-process llama.cpp HTTP server.
// Returns the bound port (>0) on success, or 0 on failure.
NOEMA_LLAMA_SERVER_API int noema_llama_server_start(const char *host,
                                                    int preferred_port,
                                                    const char *gguf_path,
                                                    const char *mmproj_path);

// Extended startup API with optional chat-template and reasoning controls.
// Pass NULL or an empty string for optional string values.
// Pass INT32_MIN for reasoning_budget to keep llama.cpp defaults.
// Pass 0 for use_jinja to keep current startup behavior.
// Pass INT32_MIN for cache_ram_mib / ctx_checkpoints to keep llama.cpp defaults.
// Pass NULL or an empty string for mtp_path / spec_type to disable MTP.
// Pass INT32_MIN for spec_draft_n_max / spec_draft_n_min to keep llama.cpp
// defaults.
// Pass a negative value for spec_draft_p_min to keep the llama.cpp default
// (valid p_min values are in [0, 1]).
// Pass 1 for spec_dynamic to let the server adapt the draft length at runtime
// (spec_draft_n_max then acts as the upper bound); 0 keeps static drafting.
NOEMA_LLAMA_SERVER_API int noema_llama_server_start_with_options(
    const char *host,
    int preferred_port,
    const char *gguf_path,
    const char *mmproj_path,
    const char *chat_template_file,
    int reasoning_budget,
    int use_jinja,
    int cache_ram_mib,
    int ctx_checkpoints,
    const char *mtp_path,
    const char *spec_type,
    int spec_draft_n_max,
    int spec_draft_n_min,
    float spec_draft_p_min,
    int spec_dynamic);

// Requests a graceful shutdown. Safe to call multiple times.
NOEMA_LLAMA_SERVER_API void noema_llama_server_stop(void);

// Returns the last bound port from start(), or 0 if not running.
NOEMA_LLAMA_SERVER_API int noema_llama_server_port(void);

// Returns whether a model load is currently in progress (1 = yes, 0 = no).
NOEMA_LLAMA_SERVER_API int noema_llama_server_is_loading(void);

// Returns current model loading progress in [0, 1].
NOEMA_LLAMA_SERVER_API float noema_llama_server_load_progress(void);

// Returns a JSON object describing the most recent startup failure, or an
// empty string if no failure is recorded.
NOEMA_LLAMA_SERVER_API const char *noema_llama_server_last_start_diagnostics_json(void);

// Returns a JSON object with the effective argv/options used for the most
// recent server start, or an empty string if no start has been attempted.
NOEMA_LLAMA_SERVER_API const char *noema_llama_server_last_start_options_json(void);

// Runs llama.cpp's no-allocation sizing path for the exact server parameters
// Noema will use for a launch. The returned JSON contains the model, context,
// compute, projector, and speculative-draft byte counts plus their total.
//
// Optional paths may be NULL or empty. `speculative_type` may be empty,
// "draft-mtp", or "draft-simple". MTP without `mtp_path` measures the embedded
// head in `gguf_path`; helper speculation requires its model in `mtp_path`.
// The returned pointer is thread-local and remains valid until the next sizing
// call on the same thread.
NOEMA_LLAMA_SERVER_API const char *noema_llama_server_memory_estimate_json(
    const char *gguf_path,
    const char *mmproj_path,
    const char *mtp_path,
    int context_size,
    int batch_size,
    int ubatch_size,
    const char *cache_type_k,
    const char *cache_type_v,
    int n_gpu_layers,
    int flash_attention,
    int parallel_slots,
    int kv_offload,
    const char *speculative_type,
    int spec_draft_n_max,
    int kv_unified);

// Configuration-driven sizing that supersedes the flat-argument estimate above.
// Accepts the same v2/v3/v4 struct as start_with_configuration. When paged_mode is
// 1 or 2 the JSON gains a "paged" object with bank/staging byte accounting and
// "modelBytes" reflects only the resident tensor set. The returned pointer is
// thread-local and remains valid until the next sizing call on the same thread.
NOEMA_LLAMA_SERVER_API const char *noema_llama_server_memory_estimate_json2(
    const noema_llama_server_configuration *configuration);

// Returns a JSON snapshot of Noema Overfit paged-runtime telemetry (bank
// hits/misses, bytes read, stall/commit timing, latency histograms), or an
// empty string when no paged runtime is active. Thread-local storage, same
// lifetime rules as the diagnostics JSON.
NOEMA_LLAMA_SERVER_API const char *noema_llama_server_paged_stats_json(void);

// Applies memory-pressure mitigation to an active paged runtime.
// level 1: stop issuing prefetch reads. level 2: additionally shrink in-flight
// read depth to 1. level 3: additionally cancel queued (not yet started)
// reads. Level 0 restores normal operation. Safe no-op when paging is off.
NOEMA_LLAMA_SERVER_API void noema_llama_server_paged_apply_pressure(int32_t level);

// Cancels the active Noema Overfit streamed (paged mode 2) generation without
// stopping the server. The paged runtime is poisoned ("generation cancelled"),
// queued and in-flight expert reads are dropped, and a route callback blocked
// on expert I/O wakes immediately, so the affected request fails closed within
// one decode step instead of prefilling/paging until the server notices the
// dead connection. The server survives and the next generation starts clean.
// Safe no-op when paging is off, for modes 1/3 and when no server is running.
NOEMA_LLAMA_SERVER_API void noema_llama_server_paged_cancel(void);

// Progress callback for noema_paged_convert. `progress` is monotonic in
// [0, 1]; `stage` is one of "preparing", "resident", "experts", "verifying",
// "finishing". Return 0 to continue or nonzero to cancel; on cancellation the
// staging directory is deleted and noema_paged_convert returns 2.
typedef int32_t (*noema_paged_convert_progress_cb)(float progress,
                                                   const char *stage,
                                                   void *user_data);

// Converts a supported MoE GGUF (qwen3moe, qwen35moe, or gemma4; a single
// file, or the FIRST shard of an llama.cpp split — sibling shards are read
// automatically) into a .noema-paged
// package. `dst_package_dir` is the final package directory itself (for
// example "…/Model.noema-paged") and must not exist yet. `alignment` <= 0
// selects the default 16384. The build is atomic: everything is staged in
// "<dst>.building-<pid>" and renamed into place only after full verification
// (record re-read + xxh64 + byte-compare against the source, file sha256s,
// package fingerprint). Output is byte-identical to
// scripts/make_paged_package.py for the same input; refusal rules match it
// exactly (architecture whitelist, *_exps scale/bias sidecars, split-shard
// discipline, expert geometry).
// Returns 0 on success, 1 on failure, 2 when the callback cancelled. On
// failure *err_out (optional) receives a thread-local message valid until the
// next converter call on the same thread.
NOEMA_LLAMA_SERVER_API int32_t noema_paged_convert(
    const char *src_gguf_path,
    const char *dst_package_dir,
    int32_t alignment,
    noema_paged_convert_progress_cb progress_cb,
    void *user_data,
    const char **err_out);

#ifdef __cplusplus
}
#endif
