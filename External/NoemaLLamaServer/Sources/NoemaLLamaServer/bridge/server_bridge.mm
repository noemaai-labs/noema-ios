#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
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
#include <sys/time.h>
#include <thread>
#include <fcntl.h>
#include <sys/resource.h>
#include <unistd.h>
#include <vector>

#include "noema_llama_server.h"

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
static std::string g_last_start_options_json;
// Keep loopback HTTP read/write timeouts effectively unbounded for very long
// generations and large multimodal prompts.
static constexpr int kNoemaLoopbackServerTimeoutSeconds = 315360000; // ~10 years

enum class noema_start_failure_code {
  none,
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

static void append_cache_type_argument(std::vector<std::string> &args,
                                       const char *env_name,
                                       const char *flag_name) {
  const char *raw_value = getenv(env_name);
  if (raw_value == nullptr) {
    return;
  }

  const std::string trimmed = trim_copy(raw_value);
  if (trimmed.empty()) {
    fprintf(stderr,
            "[NoemaLLamaServer] ignoring blank %s cache type override\n",
            env_name);
    return;
  }

  const auto normalized = normalize_cache_type_value(trimmed);
  if (!normalized.has_value()) {
    fprintf(stderr,
            "[NoemaLLamaServer] ignoring unsupported %s cache type: %s\n",
            env_name, trimmed.c_str());
    return;
  }

  args.emplace_back(flag_name);
  args.emplace_back(*normalized);
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
                                 const char *gguf_path, const char *mmproj_path,
                                 const char *mtp_path, const char *spec_type,
                                 int spec_draft_n_max, int spec_draft_n_min,
                                 float spec_draft_p_min) {
  std::string json = "{";
  json += "\"port\":" + std::to_string(port);
  json += ",\"ggufPath\":\"" + json_escape(gguf_path ? gguf_path : "") + "\"";
  json += ",\"mmprojPath\":\"" + json_escape(mmproj_path ? mmproj_path : "") + "\"";
  json += ",\"mtpPath\":\"" + json_escape(mtp_path ? mtp_path : "") + "\"";
  json += ",\"speculativeType\":\"" + json_escape(spec_type ? spec_type : "") + "\"";
  if (spec_draft_n_max == INT32_MIN) {
    json += ",\"specDraftNMax\":null";
  } else {
    json += ",\"specDraftNMax\":" + std::to_string(spec_draft_n_max);
  }
  if (spec_draft_n_min == INT32_MIN) {
    json += ",\"specDraftNMin\":null";
  } else {
    json += ",\"specDraftNMin\":" + std::to_string(spec_draft_n_min);
  }
  if (spec_draft_p_min < 0.0f) {
    json += ",\"specDraftPMin\":null";
  } else {
    json += ",\"specDraftPMin\":" + std::to_string(spec_draft_p_min);
  }
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

int noema_llama_server_start_with_options(const char *host, int preferred_port,
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
                                          float spec_draft_p_min) {
  std::lock_guard<std::mutex> lock(g_server_mutex);

  const char *bind_host = (host && host[0]) ? host : "127.0.0.1";

  clear_start_diagnostics();
  g_last_ready_status.store(-1);
  g_last_ready_elapsed_ms.store(0);

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
      preferred_port > 0 ? preferred_port : find_free_port_ipv4(bind_host);
  if (port <= 0) {
    record_start_failure(noema_start_failure_code::port_allocation_failed);
    return 0;
  }

  // Build argv for llama_server_main
  std::vector<std::string> args;
  args.reserve(32);
  args.emplace_back("llama-server");
  args.emplace_back("-m");
  args.emplace_back(gguf_path ? gguf_path : "");
  args.emplace_back("--host");
  args.emplace_back(bind_host);
  args.emplace_back("--port");
  args.emplace_back(std::to_string(port));
  // keep the API private and simple
  // Avoid passing unsupported boolean values as separate argv tokens.
  // Leave metrics/public at their defaults to prevent parser errors.
  if (mmproj_path && mmproj_path[0]) {
    args.emplace_back("--mmproj");
    args.emplace_back(mmproj_path);
  }
  if (spec_type && spec_type[0]) {
    args.emplace_back("--spec-type");
    args.emplace_back(spec_type);
    if (mtp_path && mtp_path[0]) {
      args.emplace_back("--spec-draft-model");
      args.emplace_back(mtp_path);
    }
    if (spec_draft_n_max != INT32_MIN) {
      args.emplace_back("--spec-draft-n-max");
      args.emplace_back(std::to_string(spec_draft_n_max));
    }
    if (spec_draft_n_min != INT32_MIN) {
      args.emplace_back("--spec-draft-n-min");
      args.emplace_back(std::to_string(spec_draft_n_min));
    }
    if (spec_draft_p_min >= 0.0f) {
      args.emplace_back("--spec-draft-p-min");
      args.emplace_back(std::to_string(spec_draft_p_min));
    }
  }
  if (use_jinja) {
    args.emplace_back("--jinja");
  }
  if (chat_template_file && chat_template_file[0]) {
    args.emplace_back("--chat-template-file");
    args.emplace_back(chat_template_file);
  }
  if (reasoning_budget != INT32_MIN) {
    args.emplace_back("--reasoning-budget");
    args.emplace_back(std::to_string(reasoning_budget));
  }
  if (cache_ram_mib != INT32_MIN) {
    args.emplace_back("--cache-ram");
    args.emplace_back(std::to_string(cache_ram_mib));
  }
  if (ctx_checkpoints != INT32_MIN) {
    args.emplace_back("--ctx-checkpoints");
    args.emplace_back(std::to_string(ctx_checkpoints));
  }

  // Disable automatic parameter fitting to avoid architecture detection bugs
  // in llama_params_fit (e.g., "jamba.expert_used_count" error for Gemma3)
  args.emplace_back("--fit");
  args.emplace_back("off");

  // Respect process environment for GPU/threads so the app can steer server
  // behavior
  if (const char *v = getenv("LLAMA_N_GPU_LAYERS")) {
    if (v[0]) {
      args.emplace_back("--n-gpu-layers");
      args.emplace_back(v);
    }
  }
  // KV cache offload is ON by default in llama.cpp. Honor app intent:
  //  - when LLAMA_KV_OFFLOAD == "0" => pass --no-kv-offload to keep KV on CPU
  //  - when LLAMA_KV_OFFLOAD == "1" or unset => do not pass any flag (use
  //  default ON)
  if (const char *kv = getenv("LLAMA_KV_OFFLOAD")) {
    if (kv[0] == '0') {
      args.emplace_back("--no-kv-offload");
    }
  }
  if (const char *ta = getenv("LLAMA_FLASH_ATTENTION")) {
    // Newer llama.cpp parses --flash-attn as a string option: [on|off|auto].
    // Keep accepting the app's legacy boolean env var.
    if (ta[0] == '1') {
      args.emplace_back("--flash-attn");
      args.emplace_back("on");
    } else if (ta[0] == '0') {
      args.emplace_back("--flash-attn");
      args.emplace_back("off");
    }
  }
  append_cache_type_argument(args, "LLAMA_K_QUANT", "--cache-type-k");
  append_cache_type_argument(args, "LLAMA_V_QUANT", "--cache-type-v");
  if (const char *th = getenv("LLAMA_THREADS")) {
    if (th[0]) {
      args.emplace_back("--threads");
      args.emplace_back(th);
    }
  }
  if (const char *tb = getenv("LLAMA_THREADS_BATCH")) {
    if (tb[0]) {
      args.emplace_back("--threads-batch");
      args.emplace_back(tb);
    }
  }
  if (const char *ctx = getenv("LLAMA_CONTEXT_SIZE")) {
    if (ctx[0]) {
      args.emplace_back("--ctx-size");
      args.emplace_back(ctx);
    }
  }
  if (const char *warmup = getenv("LLAMA_WARMUP")) {
    if (warmup[0] == '0') {
      args.emplace_back("--no-warmup");
    } else if (warmup[0] == '1') {
      args.emplace_back("--warmup");
    }
  }
  // Override llama.cpp server's 600s default read/write timeout.
  args.emplace_back("--timeout");
  args.emplace_back(std::to_string(kNoemaLoopbackServerTimeoutSeconds));
  // Keep long generations from hard-stopping when prompt + output reaches n_ctx.
  // Default to enabled; allow explicit override via environment.
  if (const char *cs = getenv("LLAMA_CONTEXT_SHIFT")) {
    if (cs[0] == '0') {
      args.emplace_back("--no-context-shift");
    } else if (cs[0] == '1') {
      args.emplace_back("--context-shift");
    }
  } else {
    args.emplace_back("--context-shift");
  }

  record_start_options(args, port, gguf_path, mmproj_path, mtp_path, spec_type,
                       spec_draft_n_max, spec_draft_n_min, spec_draft_p_min);
  fprintf(stderr, "[NoemaLLamaServer] start options: %s\n",
          g_last_start_options_json.c_str());

  g_running.store(true);
  g_port.store(port);
  g_is_loading_model.store(true);
  g_load_progress.store(0.0f);
  g_http_ready.store(false);

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
    g_running.store(false);
    g_port.store(0);
    g_is_loading_model.store(false);
    g_http_ready.store(false);
  });

  fprintf(stderr,
          "[NoemaLLamaServer] start requested host=%s port=%d model=%s\n",
          bind_host, port, gguf_path ? gguf_path : "<empty>");

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
    g_is_loading_model.store(false);
    g_load_progress.store(0.0f);
    g_http_ready.store(false);
    fprintf(stderr,
            "[NoemaLLamaServer] start failed host=%s port=%d model=%s\n",
            bind_host, port, gguf_path ? gguf_path : "<empty>");
    return 0;
  }

  g_load_progress.store(1.0f);
  g_is_loading_model.store(false);
  clear_start_diagnostics();
  fprintf(stderr, "[NoemaLLamaServer] start ready host=%s port=%d\n", bind_host,
          port);
  return port;
}

int noema_llama_server_start(const char *host, int preferred_port,
                             const char *gguf_path,
                             const char *mmproj_path) {
  return noema_llama_server_start_with_options(
      host, preferred_port, gguf_path, mmproj_path, nullptr, INT32_MIN, 0,
      INT32_MIN, INT32_MIN, nullptr, nullptr, INT32_MIN, INT32_MIN, -1.0f);
}

void noema_llama_server_stop(void) {
  std::lock_guard<std::mutex> lock(g_server_mutex);

  if (g_running.load() && shutdown_handler) {
    shutdown_handler(SIGINT);
  }
  if (g_server_thread.joinable())
    g_server_thread.join();
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
