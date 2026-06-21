#pragma once

#if defined(__GNUC__) || defined(__clang__)
#define NOEMA_LLAMA_SERVER_API __attribute__((visibility("default")))
#else
#define NOEMA_LLAMA_SERVER_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

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
    float spec_draft_p_min);

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

#ifdef __cplusplus
}
#endif
