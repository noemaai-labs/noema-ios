// Vendored llama.cpp calls only this hook surface; disabled paging is identity.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ggml_context;
struct ggml_tensor;

// Internal configuration handed from the server bridge to the paged runtime
// before llama_server_main starts. Mirrors the paged_* fields of the public
// noema_llama_server_configuration.
typedef struct noema_paged_config_c {
    int32_t mode;            /* 0 off, 1 resident-bank parity, 2 streamed, 3 trace-only */
    const char *manifest_path;
    int32_t slots_per_layer;
    int32_t bank_budget_mib;
    int32_t io_threads;
    int32_t io_depth;
    int32_t io_timeout_ms;
    int32_t prefetch;
    int32_t oracle_all_hit;
    int32_t trace;
    const char *trace_path;
    int32_t verify_checksums;
    int32_t telemetry_interval_ms;
    int32_t waves;
    int32_t expert_major;
} noema_paged_config_c;


// Configures the process-global paged runtime. Must be called before the
// server thread starts. Returns 1 on success; on failure returns 0 and points
// *err_out at a thread-local message. mode 0 resets the runtime to off.
int noema_paged_configure(const noema_paged_config_c *cfg, const char **err_out);

// Largest prefill micro-batch the configured streamed bank (mode 2) can serve
// without route pins exhausting the slot bank: floor((n_slots - 2) /
// n_expert_used), never below 1. Valid after a successful configure (the
// bridge clamps its --ubatch-size to this before building argv). Every other
// mode returns 0, meaning "no clamp" — as does streamed mode with wave-split
// prefill on: waves bound per-wave residency by the
// expert-group width, independent of the micro-batch.
int32_t noema_paged_max_ubatch(void);

// Largest helper-draft length the configured streamed bank can verify without
// wave splitting. Verification routes the sampled token plus every draft
// token, so this is max_ubatch - 1 (and may legitimately be 0). Streamed mode
// with waves enabled and all non-streamed modes return -1, meaning "no paged
// draft clamp".
int32_t noema_paged_max_draft_tokens(void);

// Called by the bridge immediately before spawning the server thread. Until
// noema_paged_on_server_exit runs, shutdown requests are deferred instead of
// tearing state down under a live (possibly detached) server thread.
void noema_paged_mark_server_started(void);

// Called from the server thread after llama_server_main returns (both the
// joined and the detached-on-failure paths). Marks the model and all graph
// resources dead so a deferred shutdown can complete.
void noema_paged_on_server_exit(void);

// Tears the runtime down (close payload fds, drop bank/trace state). Safe to
// call multiple times. If the server thread is still alive (detached startup
// failure), teardown is deferred until noema_paged_on_server_exit runs.
void noema_paged_shutdown(void);


// 1 while a paged model load is in effect (modes 1 and 2).
int noema_paged_active(void);

// 1 while the route-rewrite node should be inserted (modes 1, 2 and 3).
int noema_paged_route_active(void);

// Explicit target execution phase. The server brackets every target
// llama_decode() call with one of these values; route callbacks and I/O
// requests retain the phase so multi-token speculative verification is never
// inferred to be prompt prefill. set returns the previous value for scoped
// restoration. UNKNOWN is also the idle/default value.
typedef enum noema_paged_execution_phase {
    NOEMA_PAGED_PHASE_UNKNOWN            = 0,
    NOEMA_PAGED_PHASE_PROMPT_PREFILL     = 1,
    NOEMA_PAGED_PHASE_ORDINARY_DECODE    = 2,
    NOEMA_PAGED_PHASE_SPECULATIVE_VERIFY = 3,
    NOEMA_PAGED_PHASE_CHECKPOINT_RESTORE = 4,
} noema_paged_execution_phase;

int32_t noema_paged_set_execution_phase(int32_t phase);
int32_t noema_paged_get_execution_phase(void);

// Adds time spent restoring target/draft checkpoint state. This operation has
// no routed graph of its own, but belongs in the same phase telemetry surface.
void noema_paged_note_checkpoint_restore(uint64_t elapsed_ns);

// Asks whether `name` (e.g. "blk.7.ffn_gate_exps.weight") is a routed-expert
// tensor this runtime intercepts. `ne`/`n_dims` are the dimensions the
// architecture code expects for the full tensor; they are cross-checked
// against the manifest. On success returns 1 and fills the bank tensor's
// ggml type and dimensions (out_ne[2] is the slot count).
int noema_paged_bank_tensor_request(const char *name,
                                    const int64_t *ne,
                                    int n_dims,
                                    int32_t *out_ggml_type,
                                    int64_t out_ne[4]);

// Registers the materialized bank tensor for `name`. Returns 0 on duplicate
// or unknown names (the loader treats that as a fatal load error).
int noema_paged_register_bank_tensor(const char *name, struct ggml_tensor *t);

// Called at the end of llama_model::load_tensors (after tensor data loaded,
// never on the no-alloc sizing path). Cross-checks the manifest against the
// model architecture and registered banks, then (mode 1) preloads and
// checksum-verifies every expert record into its bank slot. Returns 1 on
// success; on failure returns 0 and points *err_out at a thread-local
// message (the loader converts that into a normal model-load failure).
// The first successful finalize latches the bank: later model loads in the
// same configuration window (the resident helper-draft model of streamed
// speculation) are bystanders — finalize no-ops and bank tensor
// request/registration refuse, so a second paged-looking model fails its
// load instead of clobbering the live bank.
int noema_paged_finalize_load(const char *arch_name, const char **err_out);


// Returns the ids tensor build_lora_mm_id should consume. When the layer is
// paged this is a CPU custom node that rewrites expert ids to slot ids (and
// records traces); otherwise `selected_experts` is returned unchanged and no
// node is inserted. `expert_weights` is one of the routed-expert weight
// tensors the ids will index (the down projection): banks are identified by
// tensor identity, so a second resident MoE model in the same process (e.g. a
// helper draft under streamed speculation) is a bystander and keeps its real
// expert ids even when its layer indices alias paged layers.
struct ggml_tensor *noema_paged_build_route_rewrite(struct ggml_context *ctx,
                                                    struct ggml_tensor *selected_experts,
                                                    const struct ggml_tensor *expert_weights,
                                                    int il);

//
// When enabled in the v4 launch contract, prefill graphs split each paged MoE
// layer's routed computation into G expert-group branches so at most
// ceil(n_expert / G) experts must be resident per branch — lifting the
// (n_slots - 2) / n_expert_used micro-batch clamp. Decode graphs
// (n_tokens == 1), modes 0/1/3 and non-bank models keep the single-call path
// byte-identical. NOEMA_PAGED_WAVES remains a diagnostic/test override.
//
// Returns 0 for "keep today's single mul_mat_id path" and G >= 1 for "build G
// wave branches" (G == 1 only under the NOEMA_PAGED_WAVES_FORCE_G test knob;
// its wave graph must stay bit-exact with the single-call path). Only returns
// nonzero when `expert_weights` is a registered bank tensor of paged layer
// `il` and `n_expert` matches the manifest.
int32_t noema_paged_prefill_waves(const struct ggml_tensor *expert_weights,
                                  int il, int64_t n_tokens, int64_t n_expert);

// True only for an eligible registered bank layer when sparse expert-major
// wave execution is enabled. The graph marks every routed matmul in that
// branch to skip negative (out-of-wave) ids; the legacy placeholder-wave
// graph remains available through NOEMA_PAGED_NO_EXPERT_MAJOR=1.
int noema_paged_expert_major_active(const struct ggml_tensor *expert_weights,
                                    int il);

// True only for an eligible registered bank layer when the specialized
// deterministic Metal weighted-reduction op is enabled. The graph keeps its
// original mul/view/add reduction as the NOEMA_PAGED_NO_FUSED_DECODE fallback.
int noema_paged_fused_reduce_active(const struct ggml_tensor *expert_weights,
                                    int il);

// Telemetry: llama-graph reports WHY a multi-token routed layer skipped the
// wave gate before ever reaching noema_paged_prefill_waves ("biases",
// "scales", "weightBeforeFFN"). `expert_weights` identifies the graph: only
// registered bank tensors may write a verdict, so a bystander (helper-draft)
// MoE graph can never mask the paged model's own. The runtime records the
// most recent verdict — prefill_waves records its own ("engaged",
// "fitsSingleCall", "wavesOff", ...; "engaged" is sticky until teardown) —
// and stats_json exposes it as stream.wavesRejectedReason so a single
// post-run snapshot explains whether waves engaged and, if not, which
// condition blocked them. No-op when paging is inactive.
void noema_paged_note_wave_ineligible(const struct ggml_tensor *expert_weights,
                                      const char *reason);

// Ids tensor for wave branch `group` of `n_groups`: expert ids inside the
// branch's id range rewrite to slot ids after ensuring residency of ONLY that
// range; every other row borrows a placeholder slot, DISTINCT within its
// token (Metal's mul_mm_id row map assumes the top-k invariant — one use of a
// slot id per token) and lazily zero-filled on first placeholder use so its
// bytes are finite. In expert-major mode the out-of-branch rows are instead
// written as -1 and skipped by every indexed matmul. `dep` (branch group-1's
// output, null for group 0) is
// attached as an extra graph dependency so the scheduler cannot run this
// branch's CPU route callback — which evicts and overwrites bank slots —
// before the previous branch's GPU reads of those slots completed.
struct ggml_tensor *noema_paged_build_route_rewrite_wave(struct ggml_context *ctx,
                                                         struct ggml_tensor *selected_experts,
                                                         const struct ggml_tensor *expert_weights,
                                                         int il, int32_t group, int32_t n_groups,
                                                         struct ggml_tensor *dep);

// F32 mask [1, n_expert_used, n_tokens] for wave branch `group`: 1.0 where the
// routed expert id belongs to the branch's range, 0.0 otherwise. Multiplied
// into the routed-weights tensor so out-of-branch contributions (computed
// against finite placeholder-slot bytes) vanish exactly: x * 0 = 0.
struct ggml_tensor *noema_paged_build_wave_mask(struct ggml_context *ctx,
                                                struct ggml_tensor *selected_experts,
                                                int il, int32_t group, int32_t n_groups);


// Returns 1 and copies the pending poison message into buf if a paged-runtime
// error (checksum mismatch, route ids out of range, I/O failure) occurred
// since the last call. The server request loop treats this as a decode
// failure; the paged runtime never aborts the host process.
int noema_paged_take_error(char *buf, size_t buflen);


// JSON snapshot of paged-runtime counters. Thread-local storage; empty string
// when the runtime is off.
const char *noema_paged_stats_json(void);

// Route-trace snapshot (JSON) collected when the trace flag is on; clears the
// buffer. Used by the parity harness via a test-hook export.
const char *noema_paged_trace_json(void);

// Memory-pressure mitigation (see noema_llama_server_paged_apply_pressure).
void noema_paged_apply_pressure(int32_t level);

// App-initiated cancellation of the active streamed (mode 2) generation.
// Poisons the runtime ("generation cancelled"), drops queued and in-flight
// paged reads and wakes any route callback blocked on expert I/O, so the
// current decode fails closed promptly instead of prefilling/paging until the
// server notices the dead connection. The server survives and serves the next
// request. Safe, lock-free no-op for modes 0/1/3 and outside a streamed
// configuration's configure→teardown window.
void noema_paged_cancel_active(void);

#ifdef __cplusplus
}
#endif
