#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <mutex>
#include <netinet/in.h>
#include <optional>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <thread>
#include <fcntl.h>
#include <sys/resource.h>
#include <unistd.h>
#include <vector>

#include "noema_llama_server.h"
#include "common.h"
#include "fit.h"
#include "mtmd.h"
#include "speculative.h"

#include "noema_paged_hooks.h"
#include "noema_paged_runtime.h"

#include <cstddef>
#include <memory>

static_assert(offsetof(noema_llama_server_configuration, paged_mode) ==
                  NOEMA_LLAMA_SERVER_CONFIGURATION_V2_SIZE,
              "noema_llama_server_configuration v2 prefix layout drifted");
static_assert(offsetof(noema_llama_server_configuration, paged_waves) ==
                  NOEMA_LLAMA_SERVER_CONFIGURATION_V3_SIZE,
              "noema_llama_server_configuration v3 prefix layout drifted");

// Forward declaration for the renamed upstream entry point (C++ linkage)
int llama_server_main(int argc, char **argv);

// Externs from upstream (defined in server.cpp)
extern std::function<void(int)> shutdown_handler;

static std::thread g_server_thread;
static std::atomic<bool> g_running{false};
static std::atomic<int> g_port{0};
static std::atomic<bool> g_is_loading_model{false};
static std::atomic<float> g_load_progress{0.0f};
static std::atomic<bool> g_http_ready{false};
static std::atomic<int> g_last_ready_status{-1};
static std::atomic<int> g_last_ready_elapsed_ms{0};
static std::mutex g_server_mutex;
static std::mutex g_diagnostics_mutex;
static std::mutex g_start_options_mutex;
static std::mutex g_memory_estimate_mutex;
static std::string g_last_start_options_json;
// Keep loopback HTTP read/write timeouts effectively unbounded for very long
// generations and large multimodal prompts.
static constexpr int kNoemaLoopbackServerTimeoutSeconds = 315360000; // ~10 years

enum class noema_start_failure_code {
  none,
  invalid_configuration,
  port_allocation_failed,
  listener_timeout,
  ready_timeout,
  http_init_failed,
  model_load_failed,
  server_exited_early,
};

struct noema_start_diagnostics {
  noema_start_failure_code code = noema_start_failure_code::none;
  std::string message;
};

static noema_start_diagnostics g_last_start_diagnostics;

enum class wait_result {
  ready,
  timeout,
  exited,
};

static float clamp_progress(float value) {
  if (value < 0.0f)
    return 0.0f;
  if (value > 1.0f)
    return 1.0f;
  return value;
}

static const char *failure_code_name(noema_start_failure_code code) {
  switch (code) {
  case noema_start_failure_code::none:
    return "none";
  case noema_start_failure_code::invalid_configuration:
    return "invalid_configuration";
  case noema_start_failure_code::port_allocation_failed:
    return "port_allocation_failed";
  case noema_start_failure_code::listener_timeout:
    return "listener_timeout";
  case noema_start_failure_code::ready_timeout:
    return "ready_timeout";
  case noema_start_failure_code::http_init_failed:
    return "http_init_failed";
  case noema_start_failure_code::model_load_failed:
    return "model_load_failed";
  case noema_start_failure_code::server_exited_early:
    return "server_exited_early";
  }
  return "none";
}

static std::string trim_copy(const std::string &input) {
  size_t start = 0;
  while (start < input.size() &&
         std::isspace(static_cast<unsigned char>(input[start]))) {
    start++;
  }
  size_t end = input.size();
  while (end > start &&
         std::isspace(static_cast<unsigned char>(input[end - 1]))) {
    end--;
  }
  return input.substr(start, end - start);
}

static bool is_supported_cache_type(const std::string &value) {
  static const char *kSupportedCacheTypes[] = {
      "f32", "f16", "bf16", "q8_0", "q5_0",
      "q5_1", "q4_0", "q4_1", "iq4_nl",
  };
  for (const char *supported : kSupportedCacheTypes) {
    if (value == supported) {
      return true;
    }
  }
  return false;
}

static std::optional<std::string>
normalize_cache_type_value(std::string raw_value) {
  std::string trimmed = trim_copy(raw_value);
  if (trimmed.empty()) {
    return std::nullopt;
  }
  std::transform(trimmed.begin(), trimmed.end(), trimmed.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  if (!is_supported_cache_type(trimmed)) {
    return std::nullopt;
  }
  return trimmed;
}

static std::optional<ggml_type> ggml_cache_type(const char *raw_value) {
  const auto normalized =
      normalize_cache_type_value(raw_value ? raw_value : "");
  if (!normalized.has_value()) {
    return std::nullopt;
  }
  const std::string &value = *normalized;
  if (value == "f32") return GGML_TYPE_F32;
  if (value == "f16") return GGML_TYPE_F16;
  if (value == "bf16") return GGML_TYPE_BF16;
  if (value == "q8_0") return GGML_TYPE_Q8_0;
  if (value == "q5_0") return GGML_TYPE_Q5_0;
  if (value == "q5_1") return GGML_TYPE_Q5_1;
  if (value == "q4_0") return GGML_TYPE_Q4_0;
  if (value == "q4_1") return GGML_TYPE_Q4_1;
  if (value == "iq4_nl") return GGML_TYPE_IQ4_NL;
  return std::nullopt;
}

struct noema_memory_estimate {
  uint64_t model = 0;
  uint64_t context = 0;
  uint64_t compute = 0;
  uint64_t projector = 0;
  uint64_t speculative = 0;

  uint64_t total() const {
    uint64_t value = model;
    auto add = [&value](uint64_t bytes) {
      value = UINT64_MAX - value < bytes ? UINT64_MAX : value + bytes;
    };
    add(context);
    add(compute);
    add(projector);
    add(speculative);
    return value;
  }
};

static void add_device_memory(const common_device_memory_data_vec &memory,
                              noema_memory_estimate &estimate,
                              bool include_model,
                              bool speculative) {
  auto add = [](uint64_t &total, uint64_t bytes) {
    total = UINT64_MAX - total < bytes ? UINT64_MAX : total + bytes;
  };
  for (const auto &device : memory) {
    if (speculative) {
      if (include_model) {
        add(estimate.speculative, device.model);
      }
      add(estimate.speculative, device.context);
      add(estimate.speculative, device.compute);
    } else {
      add(estimate.model, device.model);
      add(estimate.context, device.context);
      add(estimate.compute, device.compute);
    }
  }
}

static common_params noema_memory_params(
    const char *model_path, int context_size, int batch_size, int ubatch_size,
    ggml_type cache_k, ggml_type cache_v, int n_gpu_layers,
    int flash_attention, int parallel_slots, int kv_offload,
    int spec_draft_n_max, int kv_unified) {
  common_params params;
  params.model.path = model_path ? model_path : "";
  params.n_ctx = std::max(1, context_size);
  params.n_batch = std::max(1, batch_size);
  params.n_ubatch = std::max(1, std::min(ubatch_size, params.n_batch));
  params.n_parallel = std::max(1, parallel_slots);
  params.n_gpu_layers = n_gpu_layers;
  params.cache_type_k = cache_k;
  params.cache_type_v = cache_v;
  params.flash_attn_type = flash_attention > 0
                               ? LLAMA_FLASH_ATTN_TYPE_ENABLED
                               : LLAMA_FLASH_ATTN_TYPE_DISABLED;
  params.no_kv_offload = kv_offload <= 0;
  params.kv_unified = kv_unified > 0;
  params.fit_params = false;
  params.n_outputs_max = std::max(
      1, std::min(params.n_batch,
                  params.n_parallel * (1 + std::max(0, spec_draft_n_max))));
  return params;
}

// Test-only seam for deterministic cache-type normalization coverage.
// Intentionally not declared in the public header.
#if defined(NOEMA_LLAMA_SERVER_TEST_HOOKS)
extern "C" NOEMA_LLAMA_SERVER_API const char *
noema_llama_server_normalize_cache_type_for_test(const char *raw_value) {
  static thread_local std::string normalized_value;
  const auto normalized = normalize_cache_type_value(raw_value ? raw_value : "");
  if (!normalized.has_value()) {
    return nullptr;
  }
  normalized_value = *normalized;
  return normalized_value.c_str();
}

extern "C" NOEMA_LLAMA_SERVER_API int32_t
noema_llama_server_effective_mtp_cap_for_test(
    int32_t configured_n_max, int32_t round_n_max,
    int32_t n_mtp_layers, int32_t chain_heads) {
  return common_speculative_effective_mtp_cap(
      configured_n_max, round_n_max, n_mtp_layers, chain_heads > 0);
}
#endif

static std::string json_escape(const std::string &input) {
  std::string out;
  out.reserve(input.size() + 16);
  for (const unsigned char ch : input) {
    switch (ch) {
    case '\\':
      out += "\\\\";
      break;
    case '"':
      out += "\\\"";
      break;
    case '\b':
      out += "\\b";
      break;
    case '\f':
      out += "\\f";
      break;
    case '\n':
      out += "\\n";
      break;
    case '\r':
      out += "\\r";
      break;
    case '\t':
      out += "\\t";
      break;
    default:
      if (ch < 0x20) {
        char buf[7];
        std::snprintf(buf, sizeof(buf), "\\u%04x", ch);
        out += buf;
      } else {
        out.push_back(static_cast<char>(ch));
      }
      break;
    }
  }
  return out;
}

static void clear_start_diagnostics_locked(void) {
  g_last_start_diagnostics = noema_start_diagnostics{};
}

static void clear_start_diagnostics(void) {
  std::lock_guard<std::mutex> lock(g_diagnostics_mutex);
  clear_start_diagnostics_locked();
}

static void append_start_error_message_locked(const std::string &message) {
  const std::string trimmed = trim_copy(message);
  if (trimmed.empty()) {
    return;
  }
  if (g_last_start_diagnostics.message.empty()) {
    g_last_start_diagnostics.message = trimmed;
    return;
  }
  if (g_last_start_diagnostics.message.find(trimmed) != std::string::npos) {
    return;
  }
  if (g_last_start_diagnostics.message.size() < 1024) {
    g_last_start_diagnostics.message += " | ";
    g_last_start_diagnostics.message += trimmed;
  }
}

static bool message_has_any_token(const std::string &message,
                                  std::initializer_list<const char *> tokens) {
  std::string lower = message;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  for (const char *token : tokens) {
    if (token && lower.find(token) != std::string::npos) {
      return true;
    }
  }
  return false;
}

static noema_start_failure_code classify_listener_failure(
    const std::string &message,
    wait_result result) {
  if (message_has_any_token(message, {"http server", "bind http server socket",
                                      "failed to start http server"})) {
    return noema_start_failure_code::http_init_failed;
  }
  if (result == wait_result::timeout) {
    return noema_start_failure_code::listener_timeout;
  }
  if (message_has_any_token(message, {"load model", "failed to create context",
                                      "chat template", "jinja", "reasoning"})) {
    return noema_start_failure_code::model_load_failed;
  }
  return noema_start_failure_code::server_exited_early;
}

static noema_start_failure_code classify_ready_failure(
    const std::string &message,
    wait_result result) {
  if (message_has_any_token(message, {"http server", "bind http server socket",
                                      "failed to start http server"})) {
    return noema_start_failure_code::http_init_failed;
  }
  if (message_has_any_token(message, {"load model", "failed to create context",
                                      "chat template", "jinja", "reasoning"})) {
    return noema_start_failure_code::model_load_failed;
  }
  if (result == wait_result::timeout) {
    return noema_start_failure_code::ready_timeout;
  }
  return noema_start_failure_code::model_load_failed;
}

static std::string fallback_message_for_code(noema_start_failure_code code) {
  switch (code) {
  case noema_start_failure_code::invalid_configuration:
    return "The loopback server configuration is invalid.";
  case noema_start_failure_code::port_allocation_failed:
    return "Failed to allocate a loopback port.";
  case noema_start_failure_code::listener_timeout:
    return "Loopback server did not begin listening in time.";
  case noema_start_failure_code::ready_timeout:
    return "Loopback server never became ready.";
  case noema_start_failure_code::http_init_failed:
    return "Failed to initialize the loopback HTTP server.";
  case noema_start_failure_code::model_load_failed:
    return "Loopback server failed while loading the model.";
  case noema_start_failure_code::server_exited_early:
    return "Loopback server exited before startup completed.";
  case noema_start_failure_code::none:
    return "";
  }
  return "";
}

static void record_start_failure(noema_start_failure_code code) {
  std::lock_guard<std::mutex> lock(g_diagnostics_mutex);
  g_last_start_diagnostics.code = code;
  if (g_last_start_diagnostics.message.empty()) {
    g_last_start_diagnostics.message = fallback_message_for_code(code);
  }
}

static std::string json_string_array(const std::vector<std::string> &values) {
  std::string out = "[";
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) {
      out += ",";
    }
    out += "\"";
    out += json_escape(values[i]);
    out += "\"";
  }
  out += "]";
  return out;
}

static void record_start_options(const std::vector<std::string> &args, int port,
                                 const noema_llama_server_configuration &c) {
  std::string json = "{";
  json += "\"port\":" + std::to_string(port);
  json += ",\"ggufPath\":\"" + json_escape(c.gguf_path ? c.gguf_path : "") + "\"";
  json += ",\"mmprojPath\":\"" + json_escape(c.mmproj_path ? c.mmproj_path : "") + "\"";
  json += ",\"mtpPath\":\"" + json_escape(c.draft_model_path ? c.draft_model_path : "") + "\"";
  json += ",\"speculativeType\":\"" + json_escape(c.speculative_type ? c.speculative_type : "") + "\"";
  if (c.spec_draft_n_max == INT32_MIN) {
    json += ",\"specDraftNMax\":null";
  } else {
    json += ",\"specDraftNMax\":" + std::to_string(c.spec_draft_n_max);
  }
  if (c.spec_draft_n_min == INT32_MIN) {
    json += ",\"specDraftNMin\":null";
  } else {
    json += ",\"specDraftNMin\":" + std::to_string(c.spec_draft_n_min);
  }
  if (c.spec_draft_p_min < 0.0) {
    json += ",\"specDraftPMin\":null";
  } else {
    json += ",\"specDraftPMin\":" + std::to_string(c.spec_draft_p_min);
  }
  json += ",\"specDynamic\":";
  json += c.spec_dynamic > 0 ? "true" : "false";
  json += ",\"contextSize\":" + std::to_string(c.context_size);
  json += ",\"contextShift\":" + std::string(c.context_shift > 0 ? "true" : "false");
  json += ",\"gpuLayers\":" + std::to_string(c.gpu_layers);
  json += ",\"threads\":" + std::to_string(c.threads);
  json += ",\"threadsBatch\":" + std::to_string(c.threads_batch);
  json += ",\"batchSize\":" + std::to_string(c.batch_size);
  json += ",\"ubatchSize\":" + std::to_string(c.ubatch_size);
  json += ",\"useMmap\":" + std::string(c.use_mmap > 0 ? "true" : "false");
  json += ",\"useMlock\":" + std::string(c.use_mlock > 0 ? "true" : "false");
  json += ",\"warmup\":" + std::string(c.warmup > 0 ? "true" : "false");
  json += ",\"kvOffload\":" + std::string(c.kv_offload > 0 ? "true" : "false");
  json += ",\"unifiedKVCache\":" + std::string(c.kv_unified > 0 ? "true" : "false");
  json += ",\"flashAttention\":" + std::string(c.flash_attention > 0 ? "true" : "false");
  json += ",\"cacheTypeK\":\"" + json_escape(c.cache_type_k ? c.cache_type_k : "") + "\"";
  json += ",\"cacheTypeV\":\"" + json_escape(c.cache_type_v ? c.cache_type_v : "") + "\"";
  json += ",\"parallelSlots\":" + std::to_string(c.parallel_slots);
  json += ",\"tensorOverride\":\"" + json_escape(c.tensor_override ? c.tensor_override : "") + "\"";
  json += ",\"cpuMoE\":" + std::string(c.cpu_moe > 0 ? "true" : "false");
  json += c.moe_expert_count == INT32_MIN
              ? ",\"moeExpertCount\":null"
              : ",\"moeExpertCount\":" + std::to_string(c.moe_expert_count);
  auto optional_double = [&json](const char *name, double value) {
    json += ",\"" + std::string(name) + "\":";
    json += value < 0.0 ? "null" : std::to_string(value);
  };
  optional_double("yarnScale", c.yarn_scale);
  json += c.yarn_original_context == INT32_MIN
              ? ",\"yarnOriginalContext\":null"
              : ",\"yarnOriginalContext\":" + std::to_string(c.yarn_original_context);
  optional_double("yarnBetaFast", c.yarn_beta_fast);
  optional_double("yarnBetaSlow", c.yarn_beta_slow);
  json += ",\"cacheRamMiB\":" + std::to_string(c.cache_ram_mib);
  json += ",\"ctxCheckpoints\":" + std::to_string(c.ctx_checkpoints);
  // Paged fields are emitted only when paging is on so that flag-off starts
  // keep a byte-identical options snapshot (the Stage 1 equivalence gate).
  if (c.paged_mode != 0) {
    json += ",\"pagedMode\":" + std::to_string(c.paged_mode);
    json += ",\"pagedManifestPath\":\"" +
            json_escape(c.paged_manifest_path ? c.paged_manifest_path : "") + "\"";
    json += ",\"pagedSlotsPerLayer\":" + std::to_string(c.paged_slots_per_layer);
    json += ",\"pagedBankBudgetMiB\":" + std::to_string(c.paged_bank_budget_mib);
    json += ",\"pagedIOThreads\":" + std::to_string(c.paged_io_threads);
    json += ",\"pagedIODepth\":" + std::to_string(c.paged_io_depth);
    json += ",\"pagedIOTimeoutMs\":" + std::to_string(c.paged_io_timeout_ms);
    json += ",\"pagedPrefetch\":" + std::string(c.paged_prefetch > 0 ? "true" : "false");
    json += ",\"pagedOracleAllHit\":" + std::string(c.paged_oracle_all_hit > 0 ? "true" : "false");
    json += ",\"pagedTrace\":" + std::string(c.paged_trace > 0 ? "true" : "false");
    json += ",\"pagedVerifyChecksums\":" +
            std::string(c.paged_verify_checksums > 0 ? "true" : "false");
    json += ",\"pagedWaves\":" +
            std::string(c.paged_waves > 0 ? "true" : "false");
    json += ",\"pagedExpertMajor\":" +
            std::string(c.paged_expert_major > 0 ? "true" : "false");
  }
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  json += ",\"cpuNEON\":true";
#else
  json += ",\"cpuNEON\":false";
#endif
#if defined(__ARM_FEATURE_DOTPROD)
  json += ",\"cpuDotProduct\":true";
#else
  json += ",\"cpuDotProduct\":false";
#endif
#if defined(__ARM_FEATURE_MATMUL_INT8)
  json += ",\"cpuI8MM\":true";
#else
  json += ",\"cpuI8MM\":false";
#endif
#if defined(GGML_USE_CPU_REPACK)
  json += ",\"cpuRepack\":true";
#else
  json += ",\"cpuRepack\":false";
#endif
  json += ",\"argv\":" + json_string_array(args);
  json += "}";

  std::lock_guard<std::mutex> lock(g_start_options_mutex);
  g_last_start_options_json = std::move(json);
}

extern "C" void noema_llama_server_report_load_progress(float progress) {
  const float clamped = clamp_progress(progress);
  float current = g_load_progress.load();
  while (current < clamped &&
         !g_load_progress.compare_exchange_weak(current, clamped)) {
  }
  g_is_loading_model.store(clamped < 0.999f);
}

extern "C" void noema_llama_server_report_http_ready(void) {
  g_http_ready.store(true);
}

extern "C" void noema_llama_server_report_error(const char *message) {
  if (message == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(g_diagnostics_mutex);
  append_start_error_message_locked(message);
}

static int find_free_port_ipv4(const char *host) {
  int sock = ::socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0)
    return 0;

  int opt = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(0); // let kernel choose
  addr.sin_addr.s_addr = inet_addr(host && host[0] ? host : "127.0.0.1");

  if (::bind(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
    ::close(sock);
    return 0;
  }

  socklen_t len = sizeof(addr);
  if (getsockname(sock, reinterpret_cast<sockaddr *>(&addr), &len) != 0) {
    ::close(sock);
    return 0;
  }

  int port = ntohs(addr.sin_port);
  ::close(sock);
  return port;
}

static wait_result wait_until_listening(const char *host, int port,
                                        int timeout_ms) {
  const int step_ms = 50;
  int waited = 0;
  while (waited < timeout_ms) {
    // If the server thread has already exited (e.g., init failure), stop early.
    if (!g_running.load())
      return wait_result::exited;
    int sock = ::socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0)
      return wait_result::exited;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr(host);
    int rc = ::connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
    ::close(sock);
    if (rc == 0)
      return wait_result::ready;
    std::this_thread::sleep_for(std::chrono::milliseconds(step_ms));
    waited += step_ms;
  }
  return wait_result::timeout;
}

static int http_get_status_ipv4(const char *host, int port, const char *path) {
  int sock = ::socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0)
    return -1;

  // Log the probe socket FD once so we can tell if FDs are near FD_SETSIZE.
  static std::atomic<bool> fd_logged{false};
  if (!fd_logged.exchange(true)) {
    struct rlimit rl{};
    getrlimit(RLIMIT_NOFILE, &rl);
    int open_count = 0;
    for (int i = 0; i < (int)rl.rlim_cur && i < 4096; i++) {
      if (fcntl(i, F_GETFD) != -1) open_count++;
    }
    fprintf(stderr,
            "[NoemaLLamaServer][FDDiag] probe_sock_fd=%d open_fds=%d "
            "soft_limit=%llu hard_limit=%llu FD_SETSIZE=%d\n",
            sock, open_count, (unsigned long long)rl.rlim_cur,
            (unsigned long long)rl.rlim_max, FD_SETSIZE);
  }

  // Keep the probe snappy; this is only used against 127.0.0.1.
  timeval tv{};
  tv.tv_sec = 1;
  tv.tv_usec = 500 * 1000;
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = inet_addr(host);
  if (::connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
    ::close(sock);
    return -1;
  }

  std::string req = "GET ";
  req += (path && path[0]) ? path : "/health";
  req += " HTTP/1.1\r\nHost: ";
  req += host;
  req += "\r\nConnection: close\r\n\r\n";

  size_t sent_total = 0;
  while (sent_total < req.size()) {
    const ssize_t sent = ::send(sock, req.c_str() + sent_total,
                                req.size() - sent_total, 0);
    if (sent <= 0) {
      ::close(sock);
      return -1;
    }
    sent_total += static_cast<size_t>(sent);
  }

  std::string response;
  response.reserve(512);
  char buf[256];
  for (int i = 0; i < 8; ++i) {
    const ssize_t n = ::recv(sock, buf, sizeof(buf), 0);
    if (n <= 0) {
      break;
    }
    response.append(buf, static_cast<size_t>(n));
    if (response.find('\n') != std::string::npos) {
      break;
    }
  }
  ::close(sock);
  if (response.empty()) {
    return -1;
  }

  // Parse first status line: "HTTP/1.1 200 OK"
  const size_t line_end = response.find('\n');
  const std::string status_line =
      line_end == std::string::npos ? response : response.substr(0, line_end);
  const char *p = std::strstr(status_line.c_str(), "HTTP/");
  if (!p) {
    return -1;
  }
  const char *sp = std::strchr(p, ' ');
  if (!sp) {
    return -1;
  }
  while (*sp == ' ') {
    sp++;
  }
  const int code = std::atoi(sp);
  return code > 0 ? code : -1;
}

static std::string normalized_api_prefix_from_env(void) {
  const char *raw = std::getenv("LLAMA_ARG_API_PREFIX");
  if (!raw || !raw[0]) {
    return "";
  }
  std::string prefix(raw);
  if (prefix == "/") {
    return "";
  }
  while (!prefix.empty() && prefix.back() == '/') {
    prefix.pop_back();
  }
  if (!prefix.empty() && prefix.front() != '/') {
    prefix.insert(prefix.begin(), '/');
  }
  return prefix;
}

static int probe_ready_status_ipv4(const char *host, int port) {
  int best_status = -1;
  auto probe = [&](const std::string &path) -> bool {
    const int status = http_get_status_ipv4(host, port, path.c_str());
    if (status > best_status) {
      best_status = status;
    }
    return status == 200;
  };

  // Probe default endpoints first.
  static const char *kPaths[] = {"/health", "/v1/health", "/models",
                                 "/v1/models"};
  for (const char *path : kPaths) {
    if (probe(path)) {
      return 200;
    }
  }

  // Respect optional API prefix passed via env (e.g. LLAMA_ARG_API_PREFIX=/api).
  const std::string prefix = normalized_api_prefix_from_env();
  if (!prefix.empty()) {
    for (const char *path : kPaths) {
      if (probe(prefix + path)) {
        return 200;
      }
    }
  }

  return best_status;
}

static wait_result wait_until_ready(const char *host, int port, int timeout_ms) {
  const int step_ms = 100;
  using clock = std::chrono::steady_clock;
  const auto start = clock::now();
  const auto deadline = start + std::chrono::milliseconds(timeout_ms);
  auto next_log_at = start;
  int attempts = 0;
  int last_status = -1;

  while (clock::now() < deadline) {
    if (!g_running.load()) {
      const auto now = clock::now();
      const auto elapsed_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(now - start)
              .count();
      g_last_ready_status.store(last_status);
      g_last_ready_elapsed_ms.store((int)elapsed_ms);
      return wait_result::exited;
    }

    const int status = probe_ready_status_ipv4(host, port);
    const bool http_ready = g_http_ready.load();
    last_status = status;
    attempts += 1;

    const auto now = clock::now();
    if (now >= next_log_at) {
      const auto elapsed_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(now - start)
              .count();
      fprintf(stderr,
              "[NoemaLLamaServer][ReadyProbe] status=%d loading=%d "
              "progress=%.3f http_ready=%d elapsed_ms=%lld attempts=%d\n",
              status, g_is_loading_model.load() ? 1 : 0, g_load_progress.load(),
              http_ready ? 1 : 0, (long long)elapsed_ms, attempts);
      next_log_at = now + std::chrono::seconds(1);
    }

    if (status == 200) {
      const auto elapsed_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(now - start)
              .count();
      fprintf(stderr,
              "[NoemaLLamaServer][ReadyProbe] ready status=%d http_ready=%d "
              "elapsed_ms=%lld attempts=%d progress=%.3f\n",
              status, http_ready ? 1 : 0, (long long)elapsed_ms, attempts,
              g_load_progress.load());
      g_last_ready_status.store(status);
      g_last_ready_elapsed_ms.store((int)elapsed_ms);
      return wait_result::ready;
    }

    // If the bridge flag says the model is loaded but HTTP probes keep
    // failing, accept after a grace period so we don't block forever.
    if (http_ready && attempts >= 20) {
      const auto elapsed_ms =
          std::chrono::duration_cast<std::chrono::milliseconds>(now - start)
              .count();
      fprintf(stderr,
              "[NoemaLLamaServer][ReadyProbe] ready (bridge-fallback) "
              "status=%d http_ready=%d elapsed_ms=%lld attempts=%d "
              "progress=%.3f\n",
              status, http_ready ? 1 : 0, (long long)elapsed_ms, attempts,
              g_load_progress.load());
      g_last_ready_status.store(status);
      g_last_ready_elapsed_ms.store((int)elapsed_ms);
      return wait_result::ready;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(step_ms));
  }

  const auto done = clock::now();
  const auto elapsed_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(done - start)
          .count();
  const int status = probe_ready_status_ipv4(host, port);
  // At timeout, accept if HTTP works OR if bridge says ready (last resort).
  const bool ready = status == 200 || g_http_ready.load();
  fprintf(stderr,
          "[NoemaLLamaServer][ReadyProbe] timeout status=%d last_status=%d "
          "loading=%d progress=%.3f http_ready=%d elapsed_ms=%lld attempts=%d\n",
          status, last_status, g_is_loading_model.load() ? 1 : 0,
          g_load_progress.load(), g_http_ready.load() ? 1 : 0,
          (long long)elapsed_ms, attempts);
  g_last_ready_status.store(status);
  g_last_ready_elapsed_ms.store((int)elapsed_ms);
  return ready ? wait_result::ready : wait_result::timeout;
}

// Accepts the current v4 contract and the frozen v2/v3 prefixes (older Swift
// bridges). On success `out` holds a full v4 struct with absent tail fields
// zeroed, preserving each prior contract's behavior.
static bool normalize_versioned_configuration(
    const noema_llama_server_configuration *in,
    noema_llama_server_configuration &out) {
  if (in == nullptr) {
    return false;
  }
  memset(&out, 0, sizeof(out));
  if (in->version == NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION) {
    if (in->size < sizeof(noema_llama_server_configuration)) {
      return false;
    }
    out = *in;
    return true;
  }
  if (in->version == 3u) {
    if (in->size < NOEMA_LLAMA_SERVER_CONFIGURATION_V3_SIZE) {
      return false;
    }
    memcpy(&out, in, NOEMA_LLAMA_SERVER_CONFIGURATION_V3_SIZE);
    return true;
  }
  if (in->version == 2u) {
    if (in->size < NOEMA_LLAMA_SERVER_CONFIGURATION_V2_SIZE) {
      return false;
    }
    memcpy(&out, in, NOEMA_LLAMA_SERVER_CONFIGURATION_V2_SIZE);
    return true;
  }
  return false;
}

int noema_llama_server_start_with_configuration(
    const noema_llama_server_configuration *configuration) {
  noema_llama_server_configuration versioned;
  if (!normalize_versioned_configuration(configuration, versioned) ||
      versioned.gguf_path == nullptr || versioned.gguf_path[0] == '\0') {
    return 0;
  }

  // Own all pointed-to data before any asynchronous work begins.
  const std::string owned_host = versioned.host ? versioned.host : "127.0.0.1";
  const std::string owned_gguf = versioned.gguf_path;
  const std::string owned_mmproj = versioned.mmproj_path ? versioned.mmproj_path : "";
  const std::string owned_draft = versioned.draft_model_path ? versioned.draft_model_path : "";
  const std::string owned_template = versioned.chat_template_file ? versioned.chat_template_file : "";
  const std::string owned_cache_k = versioned.cache_type_k ? versioned.cache_type_k : "f16";
  const std::string owned_cache_v = versioned.cache_type_v ? versioned.cache_type_v : "f16";
  const std::string normalized_cache_k =
      normalize_cache_type_value(owned_cache_k).value_or("f16");
  const std::string normalized_cache_v =
      normalize_cache_type_value(owned_cache_v).value_or("f16");
  const std::string owned_tensor = versioned.tensor_override ? versioned.tensor_override : "";
  const std::string owned_spec = versioned.speculative_type ? versioned.speculative_type : "";
  const std::string owned_paged_manifest =
      versioned.paged_manifest_path ? versioned.paged_manifest_path : "";
  const std::string owned_paged_trace_path =
      versioned.paged_trace_path ? versioned.paged_trace_path : "";
  noema_llama_server_configuration c = versioned;
  c.host = owned_host.c_str();
  c.gguf_path = owned_gguf.c_str();
  c.mmproj_path = owned_mmproj.c_str();
  c.draft_model_path = owned_draft.c_str();
  c.chat_template_file = owned_template.c_str();
  c.cache_type_k = normalized_cache_k.c_str();
  c.cache_type_v = normalized_cache_v.c_str();
  c.tensor_override = owned_tensor.c_str();
  c.speculative_type = owned_spec.c_str();
  c.context_size = std::max(1, c.context_size);
  c.threads = std::max(1, c.threads);
  c.threads_batch = std::max(1, c.threads_batch);
  c.batch_size = std::max(1, c.batch_size);
  c.ubatch_size = std::max(1, std::min(c.ubatch_size, c.batch_size));
  c.parallel_slots = std::max(1, c.parallel_slots);
  c.use_jinja = c.use_jinja > 0 ? 1 : 0;
  c.context_shift = c.context_shift > 0 ? 1 : 0;
  c.use_mmap = c.use_mmap > 0 ? 1 : 0;
  c.use_mlock = c.use_mlock > 0 ? 1 : 0;
  c.warmup = c.warmup > 0 ? 1 : 0;
  c.kv_offload = c.kv_offload > 0 ? 1 : 0;
  c.kv_unified = c.kv_unified > 0 ? 1 : 0;
  c.flash_attention = c.flash_attention > 0 ? 1 : 0;
  c.cpu_moe = c.cpu_moe > 0 ? 1 : 0;
  c.cache_ram_mib = std::max(0, c.cache_ram_mib);
  c.ctx_checkpoints = std::max(0, c.ctx_checkpoints);
  c.moe_expert_count = c.moe_expert_count > 0
                           ? c.moe_expert_count
                           : INT32_MIN;
  c.yarn_scale = std::isfinite(c.yarn_scale) && c.yarn_scale > 0.0
                     ? c.yarn_scale
                     : -1.0;
  c.yarn_original_context = c.yarn_original_context > 0
                                ? c.yarn_original_context
                                : INT32_MIN;
  c.yarn_beta_fast = std::isfinite(c.yarn_beta_fast) && c.yarn_beta_fast >= 0.0
                         ? c.yarn_beta_fast
                         : -1.0;
  c.yarn_beta_slow = std::isfinite(c.yarn_beta_slow) && c.yarn_beta_slow >= 0.0
                         ? c.yarn_beta_slow
                         : -1.0;
  c.spec_draft_n_max = c.spec_draft_n_max > 0
                           ? c.spec_draft_n_max
                           : INT32_MIN;
  c.spec_draft_n_min = c.spec_draft_n_min >= 0
                           ? c.spec_draft_n_min
                           : INT32_MIN;
  c.spec_draft_p_min = std::isfinite(c.spec_draft_p_min) &&
                               c.spec_draft_p_min >= 0.0 &&
                               c.spec_draft_p_min <= 1.0
                           ? c.spec_draft_p_min
                           : -1.0;
  c.spec_dynamic = c.spec_dynamic > 0 ? 1 : 0;
  c.paged_manifest_path = owned_paged_manifest.c_str();
  c.paged_trace_path = owned_paged_trace_path.c_str();
  c.paged_slots_per_layer = std::max(0, c.paged_slots_per_layer);
  c.paged_bank_budget_mib = std::max(0, c.paged_bank_budget_mib);
  c.paged_io_threads = c.paged_io_threads > 0 ? std::min(c.paged_io_threads, 4) : 0;
  c.paged_io_depth = c.paged_io_depth > 0 ? std::min(c.paged_io_depth, 16) : 0;
  c.paged_io_timeout_ms = std::max(0, c.paged_io_timeout_ms);
  c.paged_prefetch = c.paged_prefetch > 0 ? 1 : 0;
  c.paged_oracle_all_hit = c.paged_oracle_all_hit > 0 ? 1 : 0;
  c.paged_trace = c.paged_trace > 0 ? 1 : 0;
  c.paged_verify_checksums = c.paged_verify_checksums > 0 ? 1 : 0;
  c.paged_telemetry_interval_ms = std::max(0, c.paged_telemetry_interval_ms);
  c.paged_waves = c.paged_waves > 0 ? 1 : 0;
  c.paged_expert_major = c.paged_expert_major > 0 ? 1 : 0;

  std::lock_guard<std::mutex> lock(g_server_mutex);

  const char *bind_host = c.host[0] ? c.host : "127.0.0.1";

  clear_start_diagnostics();
  g_last_ready_status.store(-1);
  g_last_ready_elapsed_ms.store(0);

  if (c.spec_draft_n_min != INT32_MIN &&
      c.spec_draft_n_max != INT32_MIN &&
      c.spec_draft_n_min > c.spec_draft_n_max) {
    {
      std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
      g_last_start_diagnostics.code = noema_start_failure_code::invalid_configuration;
      g_last_start_diagnostics.message =
          "spec_draft_n_min must not exceed spec_draft_n_max";
    }
    return 0;
  }

  // Noema Overfit: paged modes are fail-closed against every configuration
  // that would interact with slot rewriting or expert residency.
  if (c.paged_mode < 0 || c.paged_mode > 3) {
    std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
    g_last_start_diagnostics.code = noema_start_failure_code::invalid_configuration;
    g_last_start_diagnostics.message = "invalid paged mode";
    return 0;
  }
  if (c.paged_mode == 1 || c.paged_mode == 2) {
    // Streamed mode (2) admits exactly one speculative shape: a helper draft
    // model ("draft-simple"), which loads resident beside the paged target
    // (bank finalize latch + tensor-identity route gate keep it out of the
    // paged hooks). Everything else stays rejected: draft-mtp's MTP block is
    // MoE and untested under paging, and mode 1 admits no speculation at all.
    const bool draft_simple_ok =
        c.paged_mode == 2 && owned_spec == "draft-simple" && !owned_draft.empty();
    std::string paged_conflict;
    if (owned_paged_manifest.empty()) {
      paged_conflict = "paged mode requires a manifest path";
    } else if (c.cpu_moe) {
      paged_conflict = "cpu_moe conflicts with paged mode";
    } else if (!owned_tensor.empty()) {
      paged_conflict = "tensor_override conflicts with paged mode";
    } else if ((!owned_spec.empty() || !owned_draft.empty()) && !draft_simple_ok) {
      paged_conflict = owned_spec == "draft-mtp"
          ? "draft-mtp speculative decoding conflicts with paged mode"
          : "speculative decoding conflicts with paged mode";
    } else if (!owned_mmproj.empty()) {
      paged_conflict = "multimodal projector conflicts with paged mode";
    } else if (c.parallel_slots > 1) {
      paged_conflict = "paged mode requires a single inference slot";
    } else if (c.moe_expert_count != INT32_MIN) {
      paged_conflict = "expert-count override conflicts with paged mode";
    }
    if (!paged_conflict.empty()) {
      std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
      g_last_start_diagnostics.code = noema_start_failure_code::invalid_configuration;
      g_last_start_diagnostics.message = std::move(paged_conflict);
      return 0;
    }
    // The mmap host-pointer path would hand Metal a buffer spanning the file;
    // paged residency requires explicitly loaded dense tensors only.
    c.use_mmap = 0;
    c.use_mlock = 0;
    // Mode 2's micro-batch is clamped after noema_paged_configure resolves
    // the slot bank (see the adaptive clamp below the port allocation).
  }

  if (g_running.load()) {
    const int running_port = g_port.load();
    if (running_port > 0 && !g_http_ready.load()) {
      const wait_result ready_result =
          wait_until_ready(bind_host, running_port, 120000);
      if (ready_result != wait_result::ready) {
        std::string message;
        {
          std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
          message = g_last_start_diagnostics.message;
        }
        record_start_failure(classify_ready_failure(message, ready_result));
        return 0;
      }
    }
    clear_start_diagnostics();
    return running_port;
  }

  // If the previous run exited on its own (e.g., model load error), the thread
  // remains joinable. Starting a new one without joining would call
  // std::terminate.
  if (g_server_thread.joinable()) {
    g_server_thread.join();
  }

  int port =
      c.preferred_port > 0 ? c.preferred_port : find_free_port_ipv4(bind_host);
  if (port <= 0) {
    record_start_failure(noema_start_failure_code::port_allocation_failed);
    return 0;
  }

  // Configure (or reset, for mode 0) the paged runtime before the server
  // thread exists — and before the argv build, because the streamed
  // micro-batch clamp depends on the resolved slot bank. Failures surface as
  // ordinary invalid-configuration starts.
  {
    noema_paged_config_c pcfg{};
    pcfg.mode = c.paged_mode;
    pcfg.manifest_path = c.paged_manifest_path;
    pcfg.slots_per_layer = c.paged_slots_per_layer;
    pcfg.bank_budget_mib = c.paged_bank_budget_mib;
    pcfg.io_threads = c.paged_io_threads;
    pcfg.io_depth = c.paged_io_depth;
    pcfg.io_timeout_ms = c.paged_io_timeout_ms;
    pcfg.prefetch = c.paged_prefetch;
    pcfg.oracle_all_hit = c.paged_oracle_all_hit;
    pcfg.trace = c.paged_trace;
    pcfg.trace_path = c.paged_trace_path;
    pcfg.verify_checksums = c.paged_verify_checksums;
    pcfg.telemetry_interval_ms = c.paged_telemetry_interval_ms;
    pcfg.waves = c.paged_waves;
    pcfg.expert_major = c.paged_expert_major;
    const char *paged_err = nullptr;
    if (!noema_paged_configure(&pcfg, &paged_err)) {
      {
        std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
        g_last_start_diagnostics.code = noema_start_failure_code::invalid_configuration;
        g_last_start_diagnostics.message =
            std::string("paged: ") +
            (paged_err && paged_err[0] ? paged_err : "configure failed");
      }
      return 0;
    }
  }

  // Adaptive prefill micro-batch for the streamed bank: every routed token
  // pins up to n_expert_used slots, so the largest safe ubatch is
  // floor((n_slots - spare) / n_expert_used). Honor the caller's request up
  // to that bound instead of pinning prefill to one token per graph. With
  // wave-split prefill enabled in the v4 launch contract, the runtime reports
  // 0 — no clamp: per-wave residency is bounded by the expert-group width
  // instead of the micro-batch.
  if (c.paged_mode == 2) {
    const int32_t max_ubatch = noema_paged_max_ubatch();
    if (max_ubatch > 0) {
      c.ubatch_size = std::max(1, std::min(c.ubatch_size, max_ubatch));
    }
    if (c.speculative_type[0]) {
      // Target verification routes the sampled token plus all N drafted
      // tokens. The safe no-wave cap is therefore max_ubatch - 1, not the
      // prefill clamp itself. A 0 cap means this bank cannot safely run even a
      // one-token helper draft; fail the requested configuration explicitly.
      const int32_t max_draft = noema_paged_max_draft_tokens();
      if (max_draft == 0) {
        {
          std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
          g_last_start_diagnostics.code = noema_start_failure_code::invalid_configuration;
          g_last_start_diagnostics.message =
              "paged bank cannot safely verify a helper draft token (verification routes N + 1 tokens)";
        }
        noema_paged_shutdown();
        return 0;
      }
      const int32_t requested_n_max = c.spec_draft_n_max != INT32_MIN
                                          ? c.spec_draft_n_max
                                          : common_params_speculative_draft().n_max;
      c.spec_draft_n_max = max_draft > 0
                               ? std::max(1, std::min(requested_n_max, max_draft))
                               : std::max(1, requested_n_max);
      if (c.spec_draft_n_min != INT32_MIN &&
          c.spec_draft_n_min > c.spec_draft_n_max) {
        c.spec_draft_n_min = c.spec_draft_n_max;
      }
    }
  }

  // Build argv for llama_server_main
  std::vector<std::string> args;
  args.reserve(32);
  args.emplace_back("llama-server");
  args.emplace_back("-m");
  args.emplace_back(c.gguf_path);
  args.emplace_back("--host");
  args.emplace_back(bind_host);
  args.emplace_back("--port");
  args.emplace_back(std::to_string(port));
  // keep the API private and simple
  // Avoid passing unsupported boolean values as separate argv tokens.
  // Leave metrics/public at their defaults to prevent parser errors.
  if (c.mmproj_path[0]) {
    args.emplace_back("--mmproj");
    args.emplace_back(c.mmproj_path);
  }
  if (c.speculative_type[0]) {
    args.emplace_back("--spec-type");
    args.emplace_back(c.speculative_type);
    if (c.draft_model_path[0]) {
      args.emplace_back("--spec-draft-model");
      args.emplace_back(c.draft_model_path);
    }
    if (c.spec_draft_n_max != INT32_MIN) {
      args.emplace_back("--spec-draft-n-max");
      args.emplace_back(std::to_string(c.spec_draft_n_max));
    }
    if (c.spec_draft_n_min != INT32_MIN) {
      args.emplace_back("--spec-draft-n-min");
      args.emplace_back(std::to_string(c.spec_draft_n_min));
    }
    if (c.spec_draft_p_min >= 0.0) {
      args.emplace_back("--spec-draft-p-min");
      args.emplace_back(std::to_string(c.spec_draft_p_min));
    }
    if (c.spec_dynamic > 0) {
      args.emplace_back("--spec-draft-dynamic");
    }
  }
  if (c.use_jinja) {
    args.emplace_back("--jinja");
  }
  if (c.chat_template_file[0]) {
    args.emplace_back("--chat-template-file");
    args.emplace_back(c.chat_template_file);
  }
  if (c.reasoning_budget != INT32_MIN) {
    args.emplace_back("--reasoning-budget");
    args.emplace_back(std::to_string(c.reasoning_budget));
  }
  args.emplace_back("--cache-ram");
  args.emplace_back(std::to_string(std::max(0, c.cache_ram_mib)));
  args.emplace_back("--ctx-checkpoints");
  args.emplace_back(std::to_string(std::max(0, c.ctx_checkpoints)));

  // Disable automatic parameter fitting to avoid architecture detection bugs
  // in llama_params_fit (e.g., "jamba.expert_used_count" error for Gemma3)
  args.emplace_back("--fit");
  args.emplace_back("off");

  args.emplace_back("--n-gpu-layers"); args.emplace_back(std::to_string(c.gpu_layers));
  if (!c.kv_offload) args.emplace_back("--no-kv-offload");
  args.emplace_back(c.kv_unified ? "--kv-unified" : "--no-kv-unified");
  args.emplace_back("--flash-attn"); args.emplace_back(c.flash_attention ? "on" : "off");
  const auto cache_k = normalize_cache_type_value(c.cache_type_k);
  const auto cache_v = normalize_cache_type_value(c.cache_type_v);
  args.emplace_back("--cache-type-k"); args.emplace_back(cache_k.value_or("f16"));
  args.emplace_back("--cache-type-v"); args.emplace_back(cache_v.value_or("f16"));
  args.emplace_back("--threads"); args.emplace_back(std::to_string(std::max(1, c.threads)));
  args.emplace_back("--threads-batch"); args.emplace_back(std::to_string(std::max(1, c.threads_batch)));
  args.emplace_back("--ctx-size"); args.emplace_back(std::to_string(std::max(1, c.context_size)));
  args.emplace_back("--batch-size"); args.emplace_back(std::to_string(std::max(1, c.batch_size)));
  args.emplace_back("--ubatch-size"); args.emplace_back(std::to_string(std::max(1, std::min(c.ubatch_size, c.batch_size))));
  args.emplace_back(c.use_mmap ? "--mmap" : "--no-mmap");
  if (c.use_mlock) args.emplace_back("--mlock");
  args.emplace_back(c.warmup ? "--warmup" : "--no-warmup");
  // Single inference slot. The loopback server backs a single-user local chat, so one
  // slot means every follow-up turn reuses the previous turn's KV cache: llama.cpp
  // matches the longest common prefix of the new prompt against the slot and only
  // processes the new tokens. With the default auto n_parallel (>1), new requests
  // round-robin onto fresh empty slots (selected by LRU), so a large stable prefix —
  // e.g. a full injected document in the system prompt — is re-processed from scratch
  // every turn (slot picks an empty slot, sim=0). Overridable for multi-client relay use.
  args.emplace_back("--parallel");
  args.emplace_back(std::to_string(std::max(1, c.parallel_slots)));
  if (c.cpu_moe) args.emplace_back("--cpu-moe");
  if (c.tensor_override[0]) {
    args.emplace_back("--override-tensor");
    args.emplace_back(c.tensor_override);
  }
  if (c.moe_expert_count != INT32_MIN && c.moe_expert_count > 0) {
    args.emplace_back("--override-kv");
    args.emplace_back("llama.expert_used_count=int:" + std::to_string(c.moe_expert_count));
  }
  if (c.yarn_scale > 0.0) {
    args.emplace_back("--rope-scaling"); args.emplace_back("yarn");
    args.emplace_back("--rope-scale"); args.emplace_back(std::to_string(c.yarn_scale));
    if (c.yarn_original_context > 0) {
      args.emplace_back("--yarn-orig-ctx"); args.emplace_back(std::to_string(c.yarn_original_context));
    }
    if (c.yarn_beta_fast >= 0.0) {
      args.emplace_back("--yarn-beta-fast"); args.emplace_back(std::to_string(c.yarn_beta_fast));
    }
    if (c.yarn_beta_slow >= 0.0) {
      args.emplace_back("--yarn-beta-slow"); args.emplace_back(std::to_string(c.yarn_beta_slow));
    }
  }
  // Override llama.cpp server's 600s default read/write timeout.
  args.emplace_back("--timeout");
  args.emplace_back(std::to_string(kNoemaLoopbackServerTimeoutSeconds));
  // Keep long generations from hard-stopping when prompt + output reaches n_ctx.
  // The immutable start configuration controls this explicitly.
  args.emplace_back(c.context_shift ? "--context-shift" : "--no-context-shift");
  if (c.paged_mode != 0) {
    // Internal (env-gated, no public-struct change): enable the upstream
    // POST /slots/{id}?action=save|restore endpoints so paged launches can
    // persist prompt KV across app runs. The KV cache is ordinary llama
    // state — banks are weights, orthogonal — and arg.cpp hard-fails a
    // missing directory, so validate here and fail open by skipping.
    const char *slot_save_dir = std::getenv("NOEMA_PAGED_SLOT_SAVE_DIR");
    if (slot_save_dir && slot_save_dir[0]) {
      struct stat st {};
      if (stat(slot_save_dir, &st) == 0 && S_ISDIR(st.st_mode)) {
        args.emplace_back("--slot-save-path");
        args.emplace_back(slot_save_dir);
      } else {
        fprintf(stderr,
                "[NoemaLLamaServer] NOEMA_PAGED_SLOT_SAVE_DIR is not a "
                "directory, ignoring: %s\n",
                slot_save_dir);
      }
    }
  }

  record_start_options(args, port, c);
  fprintf(stderr, "[NoemaLLamaServer] start options: %s\n",
          g_last_start_options_json.c_str());

  g_running.store(true);
  g_port.store(port);
  g_is_loading_model.store(true);
  g_load_progress.store(0.0f);
  g_http_ready.store(false);

  noema_paged_mark_server_started();
  g_server_thread = std::thread([args = std::move(args)]() mutable {
    std::vector<char *> argv;
    argv.reserve(args.size());
    for (auto &s : args)
      argv.push_back(const_cast<char *>(s.c_str()));
    int argc = (int)argv.size();
    try {
      (void)llama_server_main(argc, argv.data());
    } catch (const std::exception &e) {
      fprintf(stderr, "[NoemaLLamaServer] llama_server_main threw: %s\n",
              e.what());
    } catch (...) {
      fprintf(stderr,
              "[NoemaLLamaServer] llama_server_main threw an unknown "
              "exception\n");
    }
    noema_paged_on_server_exit();
    g_running.store(false);
    g_port.store(0);
    g_is_loading_model.store(false);
    g_http_ready.store(false);
  });

  fprintf(stderr,
          "[NoemaLLamaServer] start requested host=%s port=%d model=%s\n",
          bind_host, port, c.gguf_path);

  // Wait until the server is actually ready (model loaded), not just bound.
  // The upstream server listens first and then loads the model; returning early
  // causes callers to believe vision is available even when model load fails.
  const wait_result listening_result =
      wait_until_listening(bind_host, port, 60000);
  const wait_result ready_result =
      listening_result == wait_result::ready
          ? wait_until_ready(bind_host, port, 120000)
          : wait_result::timeout;
  if (listening_result != wait_result::ready ||
      ready_result != wait_result::ready) {
    std::string message;
    {
      std::lock_guard<std::mutex> diag_lock(g_diagnostics_mutex);
      message = g_last_start_diagnostics.message;
    }
    const noema_start_failure_code code =
        listening_result != wait_result::ready
            ? classify_listener_failure(message, listening_result)
            : classify_ready_failure(message, ready_result);
    record_start_failure(code);
    // Listener failed to bind or model failed to load; stop and join so callers
    // can retry safely.
    g_running.store(false);
    g_port.store(0);
    if (shutdown_handler) {
      shutdown_handler(SIGINT);
      if (g_server_thread.joinable()) {
        g_server_thread.join();
      }
    } else {
      // shutdown_handler is not yet assigned (server still initializing, e.g.
      // Metal library compilation). Joining would deadlock because the server
      // thread will eventually enter start_loop() with no way to terminate it.
      // Give the thread a brief grace period to exit on its own (e.g. if init
      // failed), then detach to avoid blocking forever.
      for (int i = 0; i < 30 && g_server_thread.joinable(); i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
      if (g_server_thread.joinable()) {
        fprintf(stderr,
                "[NoemaLLamaServer] detaching server thread to avoid deadlock "
                "(shutdown_handler not yet set)\n");
        g_server_thread.detach();
      }
    }
    // Paged teardown; deferred internally while a detached server thread may
    // still be alive (completes when noema_paged_on_server_exit fires).
    noema_paged_shutdown();
    g_is_loading_model.store(false);
    g_load_progress.store(0.0f);
    g_http_ready.store(false);
    fprintf(stderr,
            "[NoemaLLamaServer] start failed host=%s port=%d model=%s\n",
            bind_host, port, c.gguf_path);
    return 0;
  }

  g_load_progress.store(1.0f);
  g_is_loading_model.store(false);
  clear_start_diagnostics();
  fprintf(stderr, "[NoemaLLamaServer] start ready host=%s port=%d\n", bind_host,
          port);
  return port;
}

int noema_llama_server_start_with_options(const char *host, int preferred_port,
                                          const char *gguf_path,
                                          const char *mmproj_path,
                                          const char *chat_template_file,
                                          int reasoning_budget, int use_jinja,
                                          int cache_ram_mib, int ctx_checkpoints,
                                          const char *mtp_path,
                                          const char *spec_type,
                                          int spec_draft_n_max,
                                          int spec_draft_n_min,
                                          float spec_draft_p_min,
                                          int spec_dynamic) {
  noema_llama_server_configuration c{};
  c.version = NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION;
  c.size = sizeof(c);
  c.host = host;
  c.preferred_port = preferred_port;
  c.gguf_path = gguf_path;
  c.mmproj_path = mmproj_path;
  c.draft_model_path = mtp_path;
  c.chat_template_file = chat_template_file;
  c.reasoning_budget = reasoning_budget;
  c.use_jinja = use_jinja;
  c.context_size = 4096;
  c.context_shift = 1;
  c.gpu_layers = -1;
  c.threads = std::max(1, (int)std::thread::hardware_concurrency() - 2);
  c.threads_batch = c.threads;
  c.batch_size = 2048;
  c.ubatch_size = 512;
  c.use_mmap = 1;
  c.warmup = 1;
  c.kv_offload = 1;
  c.flash_attention = 1;
  c.cache_type_k = "f16";
  c.cache_type_v = "f16";
  c.parallel_slots = 1;
  c.moe_expert_count = INT32_MIN;
  c.yarn_scale = -1;
  c.yarn_original_context = INT32_MIN;
  c.yarn_beta_fast = -1;
  c.yarn_beta_slow = -1;
  c.cache_ram_mib = cache_ram_mib == INT32_MIN ? 0 : cache_ram_mib;
  c.ctx_checkpoints = ctx_checkpoints == INT32_MIN ? 0 : ctx_checkpoints;
  c.speculative_type = spec_type;
  c.spec_draft_n_max = spec_draft_n_max;
  c.spec_draft_n_min = spec_draft_n_min;
  c.spec_draft_p_min = spec_draft_p_min;
  c.spec_dynamic = spec_dynamic;
  return noema_llama_server_start_with_configuration(&c);
}

int noema_llama_server_start(const char *host, int preferred_port,
                             const char *gguf_path,
                             const char *mmproj_path) {
  return noema_llama_server_start_with_options(
      host, preferred_port, gguf_path, mmproj_path, nullptr, INT32_MIN, 0,
      INT32_MIN, INT32_MIN, nullptr, nullptr, INT32_MIN, INT32_MIN, -1.0f, 0);
}

void noema_llama_server_stop(void) {
  std::lock_guard<std::mutex> lock(g_server_mutex);

  if (g_running.load() && shutdown_handler) {
    shutdown_handler(SIGINT);
  }
  if (g_server_thread.joinable())
    g_server_thread.join();
  noema_paged_shutdown();
  g_running.store(false);
  g_port.store(0);
  g_is_loading_model.store(false);
  g_load_progress.store(0.0f);
  g_http_ready.store(false);
  g_last_ready_status.store(-1);
  g_last_ready_elapsed_ms.store(0);
}

int noema_llama_server_port(void) { return g_port.load(); }

int noema_llama_server_is_loading(void) {
  return g_is_loading_model.load() ? 1 : 0;
}

float noema_llama_server_load_progress(void) { return g_load_progress.load(); }

const char *noema_llama_server_last_start_diagnostics_json(void) {
  thread_local std::string json;

  std::lock_guard<std::mutex> lock(g_diagnostics_mutex);
  if (g_last_start_diagnostics.code == noema_start_failure_code::none &&
      g_last_start_diagnostics.message.empty()) {
    json.clear();
    return json.c_str();
  }

  const std::string message = g_last_start_diagnostics.message.empty()
                                  ? fallback_message_for_code(
                                        g_last_start_diagnostics.code)
                                  : g_last_start_diagnostics.message;
  const int last_status = g_last_ready_status.load();
  const int elapsed_ms = g_last_ready_elapsed_ms.load();
  const double progress =
      std::max(0.0, std::min(1.0, (double)g_load_progress.load()));

  json = "{";
  json += "\"code\":\"";
  json += failure_code_name(g_last_start_diagnostics.code);
  json += "\",\"message\":\"";
  json += json_escape(message);
  json += "\",\"lastHTTPStatus\":";
  if (last_status >= 0) {
    json += std::to_string(last_status);
  } else {
    json += "null";
  }
  json += ",\"elapsedMs\":";
  json += std::to_string(std::max(0, elapsed_ms));
  json += ",\"progress\":";
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.3f", progress);
  json += buf;
  json += ",\"httpReady\":";
  json += g_http_ready.load() ? "true" : "false";
  json += "}";
  return json.c_str();
}

const char *noema_llama_server_last_start_options_json(void) {
  static thread_local std::string json;
  std::lock_guard<std::mutex> lock(g_start_options_mutex);
  json = g_last_start_options_json;
  return json.c_str();
}

// Shared sizing body. `extra_json` is appended verbatim before the closing
// brace of a successful result (used for the paged accounting object).
static const char *memory_estimate_impl(
    const char *gguf_path, const char *mmproj_path, const char *mtp_path,
    int context_size, int batch_size, int ubatch_size,
    const char *cache_type_k, const char *cache_type_v, int n_gpu_layers,
    int flash_attention, int parallel_slots, int kv_offload,
    const char *speculative_type,
    int spec_draft_n_max, int kv_unified,
    const std::string &extra_json) {
  thread_local std::string json;
  std::lock_guard<std::mutex> lock(g_memory_estimate_mutex);

  auto fail = [&](const std::string &message) -> const char * {
    json = "{\"status\":\"error\",\"message\":\"" +
           json_escape(message) + "\"}";
    return json.c_str();
  };

  if (g_running.load()) {
    return fail("runtime_busy");
  }
  if (gguf_path == nullptr || gguf_path[0] == '\0') {
    return fail("missing_model_path");
  }
  const auto cache_k = ggml_cache_type(cache_type_k);
  const auto cache_v = ggml_cache_type(cache_type_v);
  if (!cache_k.has_value() || !cache_v.has_value()) {
    return fail("unsupported_cache_type");
  }
  const std::string spec_type = speculative_type ? speculative_type : "";
  const bool has_speculation = !spec_type.empty();
  const bool spec_mtp = spec_type == "draft-mtp";
  const bool spec_simple = spec_type == "draft-simple";
  const int effective_spec_n_max = has_speculation
      ? (spec_draft_n_max > 0
             ? spec_draft_n_max
             : common_params_speculative_draft().n_max)
      : 0;
  if (has_speculation && !spec_mtp && !spec_simple) {
    return fail("unsupported_speculative_type");
  }
  if (spec_simple && (mtp_path == nullptr || mtp_path[0] == '\0')) {
    return fail("missing_helper_model_path");
  }

  noema_memory_estimate estimate;
  bool backend_initialized = false;
  try {
    common_init();
    llama_backend_init();
    backend_initialized = true;

    common_params params = noema_memory_params(
        gguf_path, context_size, batch_size, ubatch_size, *cache_k, *cache_v,
        n_gpu_layers, flash_attention, parallel_slots, kv_offload,
        effective_spec_n_max, kv_unified);
    if (spec_simple || spec_mtp) {
      params.speculative.types = {
          spec_simple ? COMMON_SPECULATIVE_TYPE_DRAFT_SIMPLE
                      : COMMON_SPECULATIVE_TYPE_DRAFT_MTP};
      params.speculative.draft.n_max = effective_spec_n_max;
    }
    auto mparams = common_model_params_to_llama(params);
    auto cparams = common_context_params_to_llama(params);

    std::vector<ggml_backend_dev_t> devices;
    uint32_t hp_ngl = 0;
    uint32_t hp_n_ctx_train = 0;
    uint32_t hp_n_expert = 0;
    const auto main_memory = common_get_device_memory_data(
        gguf_path, &mparams, &cparams, devices, hp_ngl, hp_n_ctx_train,
        hp_n_expert, GGML_LOG_LEVEL_ERROR);
    add_device_memory(main_memory, estimate, true, false);

    if (mmproj_path != nullptr && mmproj_path[0] != '\0') {
      mtmd_context_params mmparams = mtmd_context_params_default();
      mmparams.use_gpu = true;
      mmparams.print_timings = false;
      mmparams.flash_attn_type = params.flash_attn_type;
      mmparams.warmup = params.warmup;
      const auto projector_memory =
          mtmd_get_memory_usage(mmproj_path, mmparams);
      if (projector_memory.empty()) {
        throw std::runtime_error("failed_to_measure_projector");
      }
      for (const auto &[device, bytes] : projector_memory) {
        (void)device;
        estimate.projector += bytes;
      }
    }

    if (has_speculation) {
      const bool has_draft_model = mtp_path != nullptr && mtp_path[0] != '\0';
      common_params draft_params = noema_memory_params(
          has_draft_model ? mtp_path : gguf_path, context_size, batch_size,
          ubatch_size, GGML_TYPE_F16, GGML_TYPE_F16,
          has_draft_model ? -1 : n_gpu_layers, flash_attention, parallel_slots,
          kv_offload, effective_spec_n_max, kv_unified);
      // The server mirrors the target's verify batches into the draft context
      // (server-context.cpp load_model reserves target + speculative outputs
      // for it), so the draft is sized with the same output budget —
      // noema_memory_params above already computed 1 + spec_draft_n_max.
      auto draft_mparams = common_model_params_to_llama(draft_params);
      auto draft_cparams = common_context_params_to_llama(draft_params);
      if (spec_mtp) {
        draft_cparams.ctx_type = LLAMA_CONTEXT_TYPE_MTP;
      }
      // A hybrid Qwen helper also receives target verification batches and
      // needs the same bounded recurrent rollback window. MTP uses a separate
      // dense-attention head, so only draft-simple reserves these snapshots.
      draft_cparams.n_rs_seq =
          spec_simple ? static_cast<uint32_t>(effective_spec_n_max) : 0;

      std::vector<ggml_backend_dev_t> draft_devices;
      uint32_t draft_ngl = 0;
      uint32_t draft_n_ctx_train = 0;
      uint32_t draft_n_expert = 0;
      const auto draft_memory = common_get_device_memory_data(
          has_draft_model ? mtp_path : gguf_path, &draft_mparams, &draft_cparams,
          draft_devices, draft_ngl, draft_n_ctx_train, draft_n_expert,
          GGML_LOG_LEVEL_ERROR);
      // Embedded MTP reuses the target weights. Sidecars and helper models are
      // separately loaded and therefore contribute their model buffers too.
      add_device_memory(draft_memory, estimate, has_draft_model, true);
    }

    llama_backend_free();
    backend_initialized = false;

    json = "{\"status\":\"ok\",\"modelBytes\":" +
           std::to_string(estimate.model) +
           ",\"contextBytes\":" + std::to_string(estimate.context) +
           ",\"computeBytes\":" + std::to_string(estimate.compute) +
           ",\"projectorBytes\":" + std::to_string(estimate.projector) +
           ",\"speculativeBytes\":" +
           std::to_string(estimate.speculative) +
           ",\"totalBytes\":" + std::to_string(estimate.total()) +
           extra_json + "}";
    return json.c_str();
  } catch (const std::exception &error) {
    if (backend_initialized) {
      llama_backend_free();
    }
    return fail(error.what());
  } catch (...) {
    if (backend_initialized) {
      llama_backend_free();
    }
    return fail("unknown_sizing_error");
  }
}

const char *noema_llama_server_memory_estimate_json(
    const char *gguf_path, const char *mmproj_path, const char *mtp_path,
    int context_size, int batch_size, int ubatch_size,
    const char *cache_type_k, const char *cache_type_v, int n_gpu_layers,
    int flash_attention, int parallel_slots, int kv_offload,
    const char *speculative_type,
    int spec_draft_n_max, int kv_unified) {
  return memory_estimate_impl(gguf_path, mmproj_path, mtp_path, context_size,
                              batch_size, ubatch_size, cache_type_k,
                              cache_type_v, n_gpu_layers, flash_attention,
                              parallel_slots, kv_offload, speculative_type,
                              spec_draft_n_max, kv_unified, std::string());
}

const char *noema_llama_server_memory_estimate_json2(
    const noema_llama_server_configuration *configuration) {
  thread_local std::string json2;
  noema_llama_server_configuration v;
  if (!normalize_versioned_configuration(configuration, v) ||
      v.gguf_path == nullptr || v.gguf_path[0] == '\0') {
    json2 = "{\"status\":\"error\",\"message\":\"invalid_configuration\"}";
    return json2.c_str();
  }

  if (v.paged_mode == 1 || v.paged_mode == 2) {
    noema_paged_config_c pcfg{};
    pcfg.mode = v.paged_mode;
    pcfg.manifest_path = v.paged_manifest_path;
    pcfg.slots_per_layer = v.paged_slots_per_layer;
    pcfg.bank_budget_mib = v.paged_bank_budget_mib;
    pcfg.io_threads = v.paged_io_threads;
    pcfg.io_depth = v.paged_io_depth;
    pcfg.io_timeout_ms = v.paged_io_timeout_ms;
    pcfg.prefetch = v.paged_prefetch;
    pcfg.oracle_all_hit = v.paged_oracle_all_hit;
    pcfg.trace = v.paged_trace;
    pcfg.trace_path = v.paged_trace_path;
    pcfg.verify_checksums = v.paged_verify_checksums;
    pcfg.telemetry_interval_ms = v.paged_telemetry_interval_ms;
    pcfg.waves = v.paged_waves;
    pcfg.expert_major = v.paged_expert_major;

    // The planning instance is bound to this thread only; the process-global
    // runtime (a possibly-active server) is never touched.
    auto planning = std::make_unique<noema_paged::runtime>();
    std::string paged_err;
    if (!planning->configure(&pcfg, /*planning =*/ true, paged_err)) {
      json2 = "{\"status\":\"error\",\"message\":\"paged: " +
              json_escape(paged_err) + "\"}";
      return json2.c_str();
    }

    std::string extra = ",\"paged\":{\"bankBytes\":" +
                        std::to_string(planning->bank_bytes_total()) +
                        ",\"stagingBytes\":" +
                        std::to_string(planning->staging_bytes_total()) +
                        ",\"slotsPerLayer\":" +
                        std::to_string(planning->bank_slots()) +
                        ",\"moeLayerCount\":" +
                        std::to_string(planning->moe_layer_count()) + "}";

    // Size mode 2 at the same clamped micro-batch the start path will use
    // (max_ubatch() == 0 means no clamp, e.g. wave-split prefill).
    const int32_t plan_clamp = planning->max_ubatch();
    const int32_t planned_ubatch =
        v.paged_mode == 2 && plan_clamp > 0
            ? std::max(1, std::min(v.ubatch_size, plan_clamp))
            : v.ubatch_size;

    // Streamed helper-draft speculation loads the draft resident; size it with
    // the same clamped draft budget the start path materializes. Every other
    // speculative shape is rejected at start, so it is not sized here.
    const std::string plan_spec = v.speculative_type ? v.speculative_type : "";
    const char *plan_draft = v.draft_model_path ? v.draft_model_path : "";
    const bool plan_draft_simple =
        v.paged_mode == 2 && plan_spec == "draft-simple" && plan_draft[0] != '\0';
    const int32_t plan_draft_clamp = planning->max_draft_tokens();
    if (plan_draft_simple && plan_draft_clamp == 0) {
      json2 = "{\"status\":\"error\",\"message\":\"paged bank cannot safely verify a helper draft token (verification routes N + 1 tokens)\"}";
      return json2.c_str();
    }
    const int32_t plan_requested_n_max = v.spec_draft_n_max != INT32_MIN
                                             ? v.spec_draft_n_max
                                             : common_params_speculative_draft().n_max;
    const int32_t plan_n_max = plan_draft_simple
        ? (plan_draft_clamp > 0
               ? std::max(1, std::min(plan_requested_n_max, plan_draft_clamp))
               : std::max(1, plan_requested_n_max))
        : 0;

    noema_paged::runtime::set_planning(planning.get());
    const char *result = memory_estimate_impl(
        v.gguf_path, "", plan_draft_simple ? plan_draft : "", v.context_size,
        v.batch_size, planned_ubatch,
        v.cache_type_k ? v.cache_type_k : "f16",
        v.cache_type_v ? v.cache_type_v : "f16",
        v.gpu_layers, v.flash_attention, v.parallel_slots, v.kv_offload,
        plan_draft_simple ? "draft-simple" : "", plan_n_max, v.kv_unified,
        extra);
    noema_paged::runtime::set_planning(nullptr);
    return result;
  }

  return memory_estimate_impl(
      v.gguf_path, v.mmproj_path, v.draft_model_path, v.context_size,
      v.batch_size, v.ubatch_size,
      v.cache_type_k ? v.cache_type_k : "f16",
      v.cache_type_v ? v.cache_type_v : "f16",
      v.gpu_layers, v.flash_attention, v.parallel_slots, v.kv_offload,
      v.speculative_type, v.spec_draft_n_max, v.kv_unified, std::string());
}

const char *noema_llama_server_paged_stats_json(void) {
  return noema_paged_stats_json();
}

void noema_llama_server_paged_apply_pressure(int32_t level) {
  noema_paged_apply_pressure(level);
}

void noema_llama_server_paged_cancel(void) {
  noema_paged_cancel_active();
}

// Noema Overfit test hooks
#if defined(NOEMA_LLAMA_SERVER_TEST_HOOKS)

#include "noema_paged_xxh64.h"

extern "C" NOEMA_LLAMA_SERVER_API uint64_t
noema_paged_xxh64_for_test(const uint8_t *data, size_t len, uint64_t seed) {
  return noema_xxh64(data, len, seed);
}

extern "C" NOEMA_LLAMA_SERVER_API const char *
noema_paged_validate_package_for_test(const char *manifest_path) {
  static thread_local std::string validate_error;
  noema_paged::validated_manifest vm;
  std::string err;
  if (noema_paged::parse_and_validate(manifest_path ? manifest_path : "", vm, err)) {
    validate_error.clear();
  } else {
    validate_error = err;
  }
  return validate_error.c_str();
}

extern "C" NOEMA_LLAMA_SERVER_API const char *noema_paged_trace_json_for_test(void) {
  return noema_paged_trace_json();
}

extern "C" NOEMA_LLAMA_SERVER_API const char *noema_paged_stats_json_for_test(void) {
  return noema_paged_stats_json();
}

// Streamed micro-batch clamp math on a planning-only configure (the
// process-global runtime is never touched). Returns the clamp for the
// resolved bank, 0 for modes without one, -1 when configure refuses.
extern "C" NOEMA_LLAMA_SERVER_API int32_t
noema_paged_max_ubatch_for_test(const char *manifest_path, int32_t mode,
                                int32_t slots_per_layer) {
  noema_paged_config_c pcfg{};
  pcfg.mode = mode;
  pcfg.manifest_path = manifest_path;
  pcfg.slots_per_layer = slots_per_layer;
  auto planning = std::make_unique<noema_paged::runtime>();
  std::string err;
  if (!planning->configure(&pcfg, /*planning =*/ true, err)) {
    return -1;
  }
  return planning->max_ubatch();
}

extern "C" NOEMA_LLAMA_SERVER_API int32_t
noema_paged_max_draft_tokens_for_test(const char *manifest_path, int32_t mode,
                                      int32_t slots_per_layer) {
  noema_paged_config_c pcfg{};
  pcfg.mode = mode;
  pcfg.manifest_path = manifest_path;
  pcfg.slots_per_layer = slots_per_layer;
  auto planning = std::make_unique<noema_paged::runtime>();
  std::string err;
  if (!planning->configure(&pcfg, /*planning =*/ true, err)) {
    return -2;
  }
  return planning->max_draft_tokens();
}

// Hot-expert protection math, driven on a synthetic streamed bank (no server
// boot): saturating hit counters, the max/4 threshold, the 4096-route-call
// halving, and the CLOCK drill proving the protected bit cannot livelock —
// with every slot hot, ref'd and unpinned, n_slots consecutive selects must
// evict n_slots distinct victims.
extern "C" NOEMA_LLAMA_SERVER_API const char *
noema_paged_hot_protect_math_for_test(void) {
  static thread_local std::string hot_json;
  using noema_paged::layer_bank;
  constexpr int32_t n_expert = 8;
  constexpr int32_t n_slots = 6;
  layer_bank bank;
  bank.n_slots = n_slots;
  bank.slot_expert.assign(n_slots, -1);
  bank.slot_loading.assign(n_slots, 0);
  bank.slot_ref.assign(n_slots, 0);
  bank.slot_protected.assign(n_slots, 0);
  bank.expert_slot.assign(n_expert, -1);
  bank.expert_hits.assign(n_expert, 0);

  // Saturation + threshold: 70,000 hits pin expert 0 at UINT16_MAX.
  for (int i = 0; i < 70000; ++i) {
    noema_paged::bank_note_route_hit(bank, 0);
  }
  const uint32_t saturated = bank.expert_hits[0];
  for (int i = 0; i < 100; ++i) {
    noema_paged::bank_note_route_hit(bank, 1);
  }
  const int32_t threshold_saturated = noema_paged::bank_hot_threshold(bank);

  // Decay cadence: count ticks until the first halving lands.
  uint32_t ticks_to_decay = 0;
  while (bank.expert_hits[0] == saturated && ticks_to_decay < 1000000) {
    noema_paged::bank_decay_tick(bank);
    ticks_to_decay++;
  }
  const uint32_t decayed_hit = bank.expert_hits[0];
  const uint32_t decayed_low = bank.expert_hits[1];
  const int32_t decayed_threshold = noema_paged::bank_hot_threshold(bank);

  // CLOCK drill helper: occupy every slot with a distinct hot expert
  // (equal counters -> all strictly above max/4) and set every ref bit.
  auto reset_drill = [&bank]() {
    bank.expert_hits.assign(n_expert, 0);
    bank.max_hits = 0;
    bank.hits_route_calls = 0;
    bank.expert_slot.assign(n_expert, -1);
    bank.slot_protected.assign(n_slots, 0);
    bank.protected_count = 0;
    bank.clock_hand = 0;
    for (int32_t s = 0; s < n_slots; ++s) {
      bank.slot_expert[s] = s;
      bank.expert_slot[s] = s;
      bank.slot_ref[s] = 1;
      bank.slot_loading[s] = 0;
      for (int i = 0; i < 100; ++i) {
        noema_paged::bank_note_route_hit(bank, s);
      }
    }
  };
  const std::vector<uint8_t> pinned(n_slots, 0);
  auto drill = [&bank, &pinned](bool hot_protect, uint64_t &skips) {
    std::vector<int32_t> victims;
    for (int32_t i = 0; i < n_slots; ++i) {
      const int32_t v =
          noema_paged::bank_clock_select(bank, pinned, hot_protect, skips);
      victims.push_back(v);
      if (v >= 0) {
        bank.slot_loading[v] = 1; // mimic the demand claim
      }
    }
    return victims;
  };

  reset_drill();
  uint64_t skips_protected = 0;
  const std::vector<int32_t> victims = drill(true, skips_protected);
  // Every grant must have been spent by the end of the full drill: a nonzero
  // residue would mean a protected slot the hand can no longer evict.
  const int32_t protected_count_after = bank.protected_count;
  reset_drill();
  uint64_t skips_plain = 0;
  const std::vector<int32_t> victims_plain = drill(false, skips_plain);

  auto join = [](const std::vector<int32_t> &v) {
    std::string out;
    for (size_t i = 0; i < v.size(); ++i) {
      out += (i ? "," : "") + std::to_string(v[i]);
    }
    return out;
  };
  hot_json = "{\"saturated\":" + std::to_string(saturated) +
             ",\"thresholdSaturated\":" + std::to_string(threshold_saturated) +
             ",\"ticksToDecay\":" + std::to_string(ticks_to_decay) +
             ",\"decayedHit\":" + std::to_string(decayed_hit) +
             ",\"decayedLow\":" + std::to_string(decayed_low) +
             ",\"decayedThreshold\":" + std::to_string(decayed_threshold) +
             ",\"victims\":[" + join(victims) + "]" +
             ",\"protectedSkips\":" + std::to_string(skips_protected) +
             ",\"victimsNoProtect\":[" + join(victims_plain) + "]" +
             ",\"noProtectSkips\":" + std::to_string(skips_plain) +
             ",\"protectedCountAfter\":" + std::to_string(protected_count_after) +
             "}";
  return hot_json.c_str();
}

// Teardown-completeness oracle: both counts must be zero after a stop.
extern "C" NOEMA_LLAMA_SERVER_API const char *noema_paged_io_live_for_test(void) {
  static thread_local std::string io_live_json;
  io_live_json = "{\"threads\":" +
                 std::to_string(noema_paged::io_service::live_threads()) +
                 ",\"buffers\":" +
                 std::to_string(noema_paged::io_service::live_buffers()) + "}";
  return io_live_json.c_str();
}

#endif // NOEMA_LLAMA_SERVER_TEST_HOOKS
