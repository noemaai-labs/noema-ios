#import "LlamaRunner.h"
#import <Foundation/Foundation.h>
#include <vector>
#include <string>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <type_traits>
// Build-time configuration for llama.cpp capabilities
#import "NoemaLlamaConfig.h"
#import "LlamaBackendManager.h"
#include <dlfcn.h>
#if __has_include(<llama/llama.h>)
#import <llama/llama.h>
#elif __has_include(<LlamaFramework/llama.h>)
#import <LlamaFramework/llama.h>
#else
#import "llama.h"
#endif

// Avoid hard-linking against ggml backend symbols. Some builds intentionally hide ggml
// exports (e.g. the loopback server framework) to prevent collisions with an in-process
// llama framework. Resolve at runtime when available and gracefully fall back when not.
static ggml_backend_dev_t noema_try_ggml_backend_dev_by_type(enum ggml_backend_dev_type type) {
  using fn_t = ggml_backend_dev_t (*)(enum ggml_backend_dev_type);
  static fn_t fn = (fn_t) dlsym(RTLD_DEFAULT, "ggml_backend_dev_by_type");
  if (!fn) { return NULL; }
  return fn(type);
}

// Intentionally avoid including example vision headers (llava/clip/mtmd). We rely solely on
// the public C API in llama.h. If vision is needed, higher layers should prefer the server
// route that accepts base64 image URLs.

// Compatibility shims for clearing the KV cache across llama.cpp versions.
#if defined(__APPLE__)
extern "C" {
__attribute__((weak_import)) LLAMA_API llama_memory_t llama_get_memory(const struct llama_context * ctx);
__attribute__((weak_import)) LLAMA_API void llama_memory_clear(llama_memory_t mem, bool data);
__attribute__((weak_import)) LLAMA_API bool llama_memory_seq_rm(llama_memory_t mem, llama_seq_id seq_id, llama_pos p0, llama_pos p1);
}
#else
extern "C" {
LLAMA_API llama_memory_t llama_get_memory(const struct llama_context * ctx);
LLAMA_API void llama_memory_clear(llama_memory_t mem, bool data);
LLAMA_API bool llama_memory_seq_rm(llama_memory_t mem, llama_seq_id seq_id, llama_pos p0, llama_pos p1);
}
#endif

static inline void noema_llama_kv_cache_clear(struct llama_context * ctx, bool clearData) {
#if defined(__APPLE__)
  using llama_get_memory_fn = llama_memory_t (*)(const struct llama_context *);
  using llama_memory_clear_fn = void (*)(llama_memory_t, bool);
  using llama_memory_seq_rm_fn = bool (*)(llama_memory_t, llama_seq_id, llama_pos, llama_pos);

  llama_get_memory_fn p_get_memory = (llama_get_memory_fn)llama_get_memory;
  llama_memory_clear_fn p_memory_clear = (llama_memory_clear_fn)llama_memory_clear;
  llama_memory_seq_rm_fn p_memory_seq_rm = (llama_memory_seq_rm_fn)llama_memory_seq_rm;

  if (p_memory_seq_rm && p_get_memory) {
    (void)p_memory_seq_rm(p_get_memory(ctx), 0, -1, -1);
  } else if (p_memory_clear && p_get_memory) {
    p_memory_clear(p_get_memory(ctx), clearData);
  }
#else
  llama_memory_t mem = llama_get_memory(ctx);
  (void)llama_memory_seq_rm(mem, 0, -1, -1);
  if (clearData) {
    llama_memory_clear(mem, /*data=*/true);
  }
#endif
}

// (Removed) Legacy helper functions for batch operations; using direct batch API instead

// --- KV cache type mappers ---
static inline bool noema_equals_ci(const char *a, const char *b) {
  if (!a || !b) return false;
  while (*a && *b) {
    char ca = (*a >= 'a' && *a <= 'z') ? (char)(*a - 32) : *a;
    char cb = (*b >= 'a' && *b <= 'z') ? (char)(*b - 32) : *b;
    if (ca != cb) return false;
    ++a;
    ++b;
  }
  return *a == 0 && *b == 0;
}

static inline ggml_type noema_map_kv_type(NOEMAKVCacheType t) {
  switch (t) {
    case NOEMAKVCacheTypeF32:   return GGML_TYPE_F32;
    case NOEMAKVCacheTypeF16:   return GGML_TYPE_F16;
    case NOEMAKVCacheTypeQ8_0:  return GGML_TYPE_Q8_0;
    case NOEMAKVCacheTypeQ5_0:  return GGML_TYPE_Q5_0;
    case NOEMAKVCacheTypeQ5_1:  return GGML_TYPE_Q5_1;
    case NOEMAKVCacheTypeQ4_0:  return GGML_TYPE_Q4_0;
    case NOEMAKVCacheTypeQ4_1:  return GGML_TYPE_Q4_1;
    case NOEMAKVCacheTypeIQ4_NL:return GGML_TYPE_IQ4_NL;
  }
  return GGML_TYPE_F16;
}

static inline const char * noema_kv_type_name(ggml_type t) {
  switch (t) {
    case GGML_TYPE_F32:   return "f32";
    case GGML_TYPE_F16:   return "f16";
    case GGML_TYPE_Q8_0:  return "q8_0";
    case GGML_TYPE_Q5_0:  return "q5_0";
    case GGML_TYPE_Q5_1:  return "q5_1";
    case GGML_TYPE_Q4_0:  return "q4_0";
    case GGML_TYPE_Q4_1:  return "q4_1";
    case GGML_TYPE_IQ4_NL:return "iq4_nl";
    default:              return "unknown";
  }
}

// Parse a KV quant string (e.g., "F16", "Q4_1", "IQ4_NL") into a ggml_type.
// Returns true if recognized; false otherwise.
static inline bool noema_parse_kv_string(const char * s, ggml_type * out) {
  if (s == NULL || out == NULL) return false;
  if (noema_equals_ci(s, "F32"))      { *out = GGML_TYPE_F32;   return true; }
  if (noema_equals_ci(s, "F16"))      { *out = GGML_TYPE_F16;   return true; }
  if (noema_equals_ci(s, "Q8_0"))     { *out = GGML_TYPE_Q8_0;  return true; }
  if (noema_equals_ci(s, "Q5_0"))     { *out = GGML_TYPE_Q5_0;  return true; }
  if (noema_equals_ci(s, "Q5_1"))     { *out = GGML_TYPE_Q5_1;  return true; }
  if (noema_equals_ci(s, "Q4_0"))     { *out = GGML_TYPE_Q4_0;  return true; }
  if (noema_equals_ci(s, "Q4_1"))     { *out = GGML_TYPE_Q4_1;  return true; }
  if (noema_equals_ci(s, "IQ4_NL"))   { *out = GGML_TYPE_IQ4_NL;return true; }
  // Also accept lowercase llama.cpp spellings
  if (noema_equals_ci(s, "iq4_nl"))   { *out = GGML_TYPE_IQ4_NL;return true; }
  return false;
}

static inline llama_flash_attn_type noema_parse_flash_string(const char *s) {
  if (s == NULL) return LLAMA_FLASH_ATTN_TYPE_AUTO;
  if (noema_equals_ci(s, "auto"))     return LLAMA_FLASH_ATTN_TYPE_AUTO;
  if (noema_equals_ci(s, "enabled"))  return LLAMA_FLASH_ATTN_TYPE_ENABLED;
  if (noema_equals_ci(s, "on"))       return LLAMA_FLASH_ATTN_TYPE_ENABLED;
  if (noema_equals_ci(s, "disabled")) return LLAMA_FLASH_ATTN_TYPE_DISABLED;
  if (noema_equals_ci(s, "off"))      return LLAMA_FLASH_ATTN_TYPE_DISABLED;
  int val = atoi(s);
  if (val < 0) return LLAMA_FLASH_ATTN_TYPE_AUTO;
  if (val > 0) return LLAMA_FLASH_ATTN_TYPE_ENABLED;
  return LLAMA_FLASH_ATTN_TYPE_DISABLED;
}

namespace {

template <typename T, typename = void>
struct noema_has_member_type_k : std::false_type {};

template <typename T>
struct noema_has_member_type_k<T, std::void_t<decltype(((T *)nullptr)->type_k)>>
    : std::true_type {};

template <typename T, typename = void>
struct noema_has_member_type_v : std::false_type {};

template <typename T>
struct noema_has_member_type_v<T, std::void_t<decltype(((T *)nullptr)->type_v)>>
    : std::true_type {};

}  // namespace

static inline void noema_apply_flash_and_kv_params(struct llama_context_params &cparams,
                                                   NOEMAKVCacheConfig cfg,
                                                   ggml_type *resolvedK,
                                                   ggml_type *resolvedV,
                                                   bool *usedMergedFallback,
                                                   ggml_type *mergedOut) {
  if (usedMergedFallback) { *usedMergedFallback = false; }
  if (mergedOut) { *mergedOut = GGML_TYPE_F16; }
  const char *env_fa = getenv("LLAMA_FLASH_ATTENTION");
  cparams.flash_attn_type = noema_parse_flash_string(env_fa);

  ggml_type kType = GGML_TYPE_F16;
  ggml_type vType = GGML_TYPE_F16;
  const char *env_k = getenv("LLAMA_K_QUANT");
  const char *env_v = getenv("LLAMA_V_QUANT");
  ggml_type parsed;
  if (env_k && noema_parse_kv_string(env_k, &parsed)) { kType = parsed; }
  if (env_v && noema_parse_kv_string(env_v, &parsed)) { vType = parsed; }
  if (cfg.enabled) {
    kType = noema_map_kv_type(cfg.typeK);
    vType = noema_map_kv_type(cfg.typeV);
  }

  if (resolvedK) { *resolvedK = kType; }
  if (resolvedV) { *resolvedV = vType; }

  constexpr bool hasSeparateKVTypes =
      noema_has_member_type_k<llama_context_params>::value &&
      noema_has_member_type_v<llama_context_params>::value;
  if constexpr (hasSeparateKVTypes) {
    cparams.type_k = kType;
    cparams.type_v = vType;
  } else {
    ggml_type merged = (kType == GGML_TYPE_F32 || vType == GGML_TYPE_F32) ? GGML_TYPE_F32 :
                       (kType == GGML_TYPE_F16 || vType == GGML_TYPE_F16) ? GGML_TYPE_F16 :
                       (kType == GGML_TYPE_Q8_0 || vType == GGML_TYPE_Q8_0) ? GGML_TYPE_Q8_0 :
                       (kType == GGML_TYPE_Q5_1 || vType == GGML_TYPE_Q5_1) ? GGML_TYPE_Q5_1 :
                       (kType == GGML_TYPE_Q5_0 || vType == GGML_TYPE_Q5_0) ? GGML_TYPE_Q5_0 :
                       (kType == GGML_TYPE_IQ4_NL || vType == GGML_TYPE_IQ4_NL) ? GGML_TYPE_IQ4_NL :
                       GGML_TYPE_Q4_0;

    cparams.type_k = merged;
    cparams.type_v = merged;

    if (usedMergedFallback) { *usedMergedFallback = true; }
    if (mergedOut) { *mergedOut = merged; }
  }
}

// Preprocess provided images and prime the llama context with vision embeddings.
// Returns the number of image prefix tokens appended to the context (pos offset for subsequent text), or -1 on error.
static int noema_llava_prime_with_images(
    llama_model * model,
    llama_context * ctx,
    const std::vector<std::string> & image_paths,
    int n_threads) {
    (void)model; (void)ctx; (void)image_paths; (void)n_threads;
    // No in-process vision in this build; handled at app layer via server mode.
    return -1;
}

// Construct a robust default sampler chain.
// Uses temperature + top-k to avoid empty candidate sets.
// Optional top-p/typical lines are left commented with min_keep = 1 for safe experimentation.
static llama_sampler * noema_make_default_sampler() {
  auto *chain = llama_sampler_chain_init(llama_sampler_chain_default_params());

  const char *envTemp = getenv("NOEMA_TEMPERATURE");
  float temp = 0.7f;
  if (envTemp && envTemp[0] != '\0') {
    temp = strtof(envTemp, nullptr);
    if (temp <= 0.0f) temp = 0.1f;
  }
  llama_sampler_chain_add(chain, llama_sampler_init_temp(temp));

  const char *envTopK = getenv("NOEMA_TOP_K");
  int top_k = 40;
  if (envTopK && envTopK[0] != '\0') {
    top_k = std::max(1, atoi(envTopK));
  }
  llama_sampler_chain_add(chain, llama_sampler_init_top_k(top_k));

  const char *envTopP = getenv("NOEMA_TOP_P");
  if (envTopP && envTopP[0] != '\0') {
    float top_p = strtof(envTopP, nullptr);
    if (top_p > 0.0f && top_p <= 1.0f) {
      llama_sampler_chain_add(chain, llama_sampler_init_top_p(top_p, 1));
    }
  }

  const char *envMinP = getenv("NOEMA_MIN_P");
  if (envMinP && envMinP[0] != '\0') {
    float min_p = strtof(envMinP, nullptr);
    if (min_p > 0.0f && min_p <= 1.0f) {
      llama_sampler_chain_add(chain, llama_sampler_init_min_p(min_p, 1));
    }
  }

  const char *envRepeatPenalty = getenv("NOEMA_REPEAT_PENALTY");
  const char *envFrequencyPenalty = getenv("NOEMA_FREQUENCY_PENALTY");
  const char *envPresencePenalty = getenv("NOEMA_PRESENCE_PENALTY");
  const char *envRepeatLastN = getenv("NOEMA_REPEAT_LAST_N");
  float repeat_penalty = envRepeatPenalty ? strtof(envRepeatPenalty, nullptr) : 1.0f;
  float frequency_penalty = envFrequencyPenalty ? strtof(envFrequencyPenalty, nullptr) : 0.0f;
  float presence_penalty = envPresencePenalty ? strtof(envPresencePenalty, nullptr) : 0.0f;
  int repeat_last_n = envRepeatLastN ? std::max(0, atoi(envRepeatLastN)) : 64;
  // Recent llama.cpp releases changed the penalty sampler signature to take penalty_last_n first
  // and removed the explicit newline toggle, so we just forward the configured values.
  llama_sampler_chain_add(chain, llama_sampler_init_penalties(
      repeat_last_n,
      repeat_penalty,
      frequency_penalty,
      presence_penalty));

  llama_sampler_chain_add(chain, llama_sampler_init_greedy());
  return chain;
}

static void noema_prepare_moe_overrides(std::vector<llama_model_kv_override> &out, bool verbose) {
  out.clear();
  const char *env = getenv("LLAMA_MOE_EXPERTS");
  if (env == nullptr || env[0] == '\0') {
    return;
  }
  int value = atoi(env);
  if (value <= 0) {
    return;
  }

  llama_model_kv_override entry = {};
  entry.tag = LLAMA_KV_OVERRIDE_TYPE_INT;
  snprintf(entry.key, sizeof(entry.key), "%s", "llama.expert_used_count");
  entry.val_i64 = value;
  out.push_back(entry);

  llama_model_kv_override terminator = {};
  terminator.tag = LLAMA_KV_OVERRIDE_TYPE_INT;
  terminator.key[0] = 0;
  out.push_back(terminator);

  if (verbose) {
    NSLog(@"[LlamaRunner] Overriding llama.expert_used_count=%d", value);
  }
}


@interface LlamaRunner ()
@property (atomic, assign) NOEMAKVCacheConfig kvConfig;
@end


@implementation LlamaRunner {
  llama_model *_model;
  llama_context *_ctx;
  bool _loaded;
  int _nThreads;
  bool _verbose;
  std::atomic<bool> _cancelRequested;
  std::vector<llama_model_kv_override> _kvOverrides;
  // Optional speculative decoding (draft model)
  llama_model *_draftModel;
  llama_context *_draftCtx;
  bool _specEnabled;
  int _specValue;
  bool _specModeMax;
}

- (instancetype)init {
  self = [super init];
  if (!self) return nil;
  // Default = disabled: use F16/F16
  NOEMAKVCacheConfig def;
  def.enabled = NO;
  def.typeK = NOEMAKVCacheTypeF16;
  def.typeV = NOEMAKVCacheTypeF16;
  _kvConfig = def;
  _draftModel = nullptr;
  _draftCtx = nullptr;
  _specEnabled = false;
  _specValue = 0;
  _specModeMax = false;
  return self;
}

- (void)setKVCacheConfig:(NOEMAKVCacheConfig)config { _kvConfig = config; }
- (NOEMAKVCacheConfig)kvCacheConfig { return _kvConfig; }

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       nCtxTokens:(int)nCtx
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads {
  return [self initWithModelPath:modelPath nCtxTokens:nCtx nSeqMax:1 nGpuLayers:nGpu nThreads:nThreads];
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       mmprojPath:(NSString * _Nullable)mmprojPath
                       nCtxTokens:(int)nCtx
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads {
  return [self initWithModelPath:modelPath mmprojPath:mmprojPath nCtxTokens:nCtx nSeqMax:1 nGpuLayers:nGpu nThreads:nThreads];
}

- (void)cancelCurrent {
  _cancelRequested.store(true);
}

// --- Speculative decoding support (lazy) ---
static inline int noema_env_int(const char *key, int defv) {
  const char *v = getenv(key);
  if (!v || v[0] == 0) return defv;
  return atoi(v);
}

static inline bool noema_env_bool(const char *key, bool defv) {
  const char *v = getenv(key);
  if (!v || v[0] == 0) return defv;
  return atoi(v) != 0 || strcasecmp(v, "true") == 0 || strcasecmp(v, "yes") == 0;
}

- (void)setupSpeculativeIfConfigured {
  if (_draftCtx != nullptr || _draftModel != nullptr) { _specEnabled = true; return; }
  const char *path = getenv("NOEMA_DRAFT_PATH");
  if (path == nullptr || path[0] == '\0') { _specEnabled = false; return; }
  const char *mode = getenv("NOEMA_DRAFT_MODE");
  _specModeMax = (mode && strcasecmp(mode, "max") == 0);
  _specValue = std::max(1, noema_env_int("NOEMA_DRAFT_VALUE", 64));

  struct llama_model_params mparams = llama_model_default_params();
  mparams.use_mmap = noema_env_bool("LLAMA_MMAP", true);
  mparams.use_mlock = false;
  mparams.n_gpu_layers = 0; // keep draft on CPU to save VRAM
  if (!_kvOverrides.empty()) mparams.kv_overrides = _kvOverrides.data();

  _draftModel = llama_load_model_from_file(path, mparams);
  if (_draftModel == nullptr) { _specEnabled = false; return; }

  struct llama_context_params cparams = llama_context_default_params();
  cparams.n_ctx = llama_n_ctx(_ctx);
  cparams.n_batch = 512;
  cparams.n_threads = _nThreads;
  cparams.n_threads_batch = _nThreads;
  ggml_type k = GGML_TYPE_F16, v = GGML_TYPE_F16, merged = GGML_TYPE_F16; bool dummy=false;
  noema_apply_flash_and_kv_params(cparams, self.kvConfig, &k, &v, &dummy, &merged);
  _draftCtx = llama_init_from_model(_draftModel, cparams);
  if (_draftCtx == nullptr) { llama_model_free(_draftModel); _draftModel = nullptr; _specEnabled = false; return; }
  if (_verbose) NSLog(@"[LlamaRunner] Speculative decoding enabled (value=%d, mode=%@)", _specValue, _specModeMax ? @"max" : @"tokens");
  _specEnabled = true;
}

// Designated initializers with explicit sequence parallelism
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       nCtxTokens:(int)nCtx
                          nSeqMax:(int)nSeqMax
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads {
  self = [super init];
  if (!self) return nil;

  const char *v = getenv("NOEMA_LLAMA_VERBOSE");
  _verbose = (v && atoi(v) != 0);

#if TARGET_OS_IPHONE
  const char *metalSafeMode = getenv("NOEMA_LLAMA_METAL_SAFE_MODE");
  if (metalSafeMode && atoi(metalSafeMode) != 0) {
    // Opt-in “safe mode” for llama.cpp Metal backends; avoids shared buffers that have regressed on some builds.
    setenv("GGML_METAL_SHARED_BUFFERS_DISABLE", "1", 1);
    if (_verbose) {
      NSLog(@"[LlamaRunner] Enabling Metal safe mode (shared buffers disabled)");
    }
  }
#endif
  noema_llama_backend_addref();

#if TARGET_OS_IPHONE || TARGET_OS_OSX
  if (nGpu > 0) {
    @autoreleasepool {
      NSBundle *bundle = [NSBundle mainBundle];
      NSString *metallibPath = [bundle pathForResource:@"default" ofType:@"metallib"];
      if (metallibPath.length > 0) {
        if (_verbose) NSLog(@"[LlamaRunner] Metal kernels found: %@", metallibPath);
        setenv("LLAMA_METAL_PATH", metallibPath.UTF8String, 1);
      } else {
        NSLog(@"[LlamaRunner] Warning: default.metallib not found in bundle. Falling back to CPU if needed.");
      }
    }
  } else {
    unsetenv("LLAMA_METAL_PATH");
  }
#endif

  struct llama_model_params mparams = llama_model_default_params();
  mparams.n_gpu_layers = nGpu;
  mparams.main_gpu = 0;
  static ggml_backend_dev_t cpu_devices[2];
  if (nGpu <= 0) {
    ggml_backend_dev_t cpu = noema_try_ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (cpu) {
      cpu_devices[0] = cpu;
      cpu_devices[1] = NULL;
      mparams.devices = cpu_devices;
    } else {
      mparams.devices = NULL;
    }
  }
  // Default to mmap on unless explicitly disabled via environment
#if defined(LLAMA_MODEL_PARAMS_HAS_USE_MMAP)
  {
    bool use_mmap = true;
    const char *env_mmap = getenv("LLAMA_MMAP");
    if (env_mmap != NULL) {
      use_mmap = (atoi(env_mmap) != 0);
    }
    mparams.use_mmap = use_mmap;
  }
#endif

  noema_prepare_moe_overrides(_kvOverrides, _verbose);
  if (!_kvOverrides.empty()) {
    mparams.kv_overrides = _kvOverrides.data();
  } else {
    mparams.kv_overrides = nullptr;
  }

  _model = llama_load_model_from_file([modelPath UTF8String], mparams);
  if (!_model) { noema_llama_backend_release(); return nil; }

  struct llama_context_params cparams = llama_context_default_params();
  int effective_n_ctx = nCtx;
  // Clamp to model's training context to avoid oversizing
  {
    const int train_ctx = llama_n_ctx_train(_model);
    if (train_ctx > 0 && effective_n_ctx > train_ctx) {
      if (_verbose) NSLog(@"[LlamaRunner] Clamping n_ctx from %d to model train ctx %d", effective_n_ctx, train_ctx);
      effective_n_ctx = train_ctx;
    }
  }
  cparams.n_ctx = effective_n_ctx;
  cparams.n_threads = nThreads;
  cparams.n_threads_batch = nThreads;
  cparams.n_seq_max = std::max(1, nSeqMax);
  // Match context batching to our batch allocations to avoid logits array mismatches
  cparams.n_batch = 512;
  cparams.n_ubatch = 512;
  ggml_type resolvedK = GGML_TYPE_F16;
  ggml_type resolvedV = GGML_TYPE_F16;
  bool usedMerged = false;
  ggml_type mergedType = GGML_TYPE_F16;
  noema_apply_flash_and_kv_params(cparams, self.kvConfig, &resolvedK, &resolvedV, &usedMerged, &mergedType);
  if (_verbose && usedMerged) {
    NSLog(@"[Noema] Warning: llama.cpp too old for separate K/V cache types. Using merged cache type=%s.", noema_kv_type_name(mergedType));
  }

  // Soft validator/warnings
  auto warn_if_shady = [](ggml_type t){
    switch (t) {
      case GGML_TYPE_F32:
        fprintf(stderr, "[Noema] Note: KV F32 is for debugging; expect 2x memory vs F16.\n");
        break;
      default: break;
    }
  };
  warn_if_shady(resolvedK);
  warn_if_shady(resolvedV);

  // Pre-flight parameter validation to avoid ggml_abort on tiny per-seq contexts
  const int n_ctx_per_seq = cparams.n_ctx / (cparams.n_seq_max > 0 ? cparams.n_seq_max : 1);
  const int n_ctx_train = llama_n_ctx_train(_model);
  const int minimum_required_ctx = 2048;
  if (n_ctx_per_seq < minimum_required_ctx) {
    NSLog(@"[LlamaRunner] Error: Per-sequence context length too small (%d). Required at least %d. Train ctx: %d.", n_ctx_per_seq, minimum_required_ctx, n_ctx_train);
      llama_model_free(_model);
    _model = nullptr;
    _loaded = false;
    noema_llama_backend_release();
    return nil;
  }

  _ctx = llama_init_from_model(_model, cparams);
  if (_ctx == nullptr) {
      llama_model_free(_model);
    _model = nullptr;
    _loaded = false;
    noema_llama_backend_release();
    return nil;
  }
  llama_set_n_threads(_ctx, nThreads, nThreads);
  _loaded = true;
  _nThreads = nThreads;

  if (_verbose) {
    NSLog(@"[LlamaRunner] Context ready. n_ctx=%d, n_seq_max=%d, n_gpu_layers=%d, threads=%d, threads_batch=%d",
          llama_n_ctx(_ctx), cparams.n_seq_max, nGpu, cparams.n_threads, cparams.n_threads_batch);
  }

  return self;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       mmprojPath:(NSString * _Nullable)mmprojPath
                       nCtxTokens:(int)nCtx
                          nSeqMax:(int)nSeqMax
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads {
  self = [super init];
  if (!self) return nil;

  const char *v = getenv("NOEMA_LLAMA_VERBOSE");
  _verbose = (v && atoi(v) != 0);
#if TARGET_OS_IPHONE
  const char *metalSafeMode = getenv("NOEMA_LLAMA_METAL_SAFE_MODE");
  if (metalSafeMode && atoi(metalSafeMode) != 0) {
    setenv("GGML_METAL_SHARED_BUFFERS_DISABLE", "1", 1);
    if (_verbose) {
      NSLog(@"[LlamaRunner] Enabling Metal safe mode (shared buffers disabled)");
    }
  }
#endif
  noema_llama_backend_addref();

#if TARGET_OS_IPHONE || TARGET_OS_OSX
  if (nGpu > 0) {
    @autoreleasepool {
      NSBundle *bundle = [NSBundle mainBundle];
      NSString *metallibPath = [bundle pathForResource:@"default" ofType:@"metallib"];
      if (metallibPath.length > 0) {
        if (_verbose) NSLog(@"[LlamaRunner] Metal kernels found: %@", metallibPath);
        setenv("LLAMA_METAL_PATH", metallibPath.UTF8String, 1);
      } else {
        NSLog(@"[LlamaRunner] Warning: default.metallib not found in bundle. Falling back to CPU if needed.");
      }
    }
  } else {
    unsetenv("LLAMA_METAL_PATH");
  }
#endif

  struct llama_model_params mparams = llama_model_default_params();
  mparams.n_gpu_layers = nGpu;
  mparams.main_gpu = 0;
  static ggml_backend_dev_t cpu_devices[2];
  if (nGpu <= 0) {
    ggml_backend_dev_t cpu = noema_try_ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (cpu) {
      cpu_devices[0] = cpu;
      cpu_devices[1] = NULL;
      mparams.devices = cpu_devices;
    } else {
      mparams.devices = NULL;
    }
  }
  // Default to mmap on unless explicitly disabled via environment
#if defined(LLAMA_MODEL_PARAMS_HAS_USE_MMAP)
  {
    bool use_mmap = true;
    const char *env_mmap = getenv("LLAMA_MMAP");
    if (env_mmap != NULL) {
      use_mmap = (atoi(env_mmap) != 0);
    }
    mparams.use_mmap = use_mmap;
  }
#endif

#if defined(LLAMA_MODEL_PARAMS_HAS_MMPROJ)
  if (mmprojPath != nil && [mmprojPath length] > 0) {
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:mmprojPath isDirectory:&isDir];
    if (!exists || isDir) {
      NSLog(@"[LlamaRunner] Projector not found or not a file: %@", mmprojPath);
    } else {
      mparams.mmproj = [mmprojPath UTF8String];
      NSLog(@"[LlamaRunner] Using external projector: %@", mmprojPath);
    }
  } else {
      // Indicate whether we expect merged projectors or none
      NSLog(@"[LlamaRunner] No external projector provided (expect merged VLM or text-only model)");
  }
#else
  if (mmprojPath != nil && [mmprojPath length] > 0) {
    NSLog(@"[Noema][info] This llama.cpp build does not expose mparams.mmproj; using merged VLMs only.");
  }
#endif

  noema_prepare_moe_overrides(_kvOverrides, _verbose);
  if (!_kvOverrides.empty()) {
    mparams.kv_overrides = _kvOverrides.data();
  } else {
    mparams.kv_overrides = nullptr;
  }

  _model = llama_load_model_from_file([modelPath UTF8String], mparams);
  if (!_model) { noema_llama_backend_release(); return nil; }

  struct llama_context_params cparams = llama_context_default_params();
  int effective_n_ctx = nCtx;
  {
    const int train_ctx = llama_n_ctx_train(_model);
    if (train_ctx > 0 && effective_n_ctx > train_ctx) {
      if (_verbose) NSLog(@"[LlamaRunner] Clamping n_ctx from %d to model train ctx %d", effective_n_ctx, train_ctx);
      effective_n_ctx = train_ctx;
    }
  }
  cparams.n_ctx = effective_n_ctx;
  cparams.n_threads = nThreads;
  cparams.n_threads_batch = nThreads;
  cparams.n_seq_max = std::max(1, nSeqMax);
  // Match context batching to our batch allocations to avoid logits array mismatches
  cparams.n_batch = 512;
  cparams.n_ubatch = 512;
  ggml_type resolvedK = GGML_TYPE_F16;
  ggml_type resolvedV = GGML_TYPE_F16;
  bool usedMerged = false;
  ggml_type mergedType = GGML_TYPE_F16;
  noema_apply_flash_and_kv_params(cparams, self.kvConfig, &resolvedK, &resolvedV, &usedMerged, &mergedType);
  // Summarize resolved KV and flash settings
  {
    const char *flashStr = nullptr;
    switch (cparams.flash_attn_type) {
      case LLAMA_FLASH_ATTN_TYPE_AUTO: flashStr = "auto"; break;
      case LLAMA_FLASH_ATTN_TYPE_ENABLED: flashStr = "on"; break;
      case LLAMA_FLASH_ATTN_TYPE_DISABLED: flashStr = "off"; break;
      default: flashStr = "auto"; break;
    }
    NSLog(@"[LlamaRunner] KV K=%s V=%s flash=%s",
          noema_kv_type_name(resolvedK), noema_kv_type_name(resolvedV), flashStr);
  }
  if (_verbose && usedMerged) {
    NSLog(@"[Noema] Warning: llama.cpp too old for separate K/V cache types. Using merged cache type=%s.", noema_kv_type_name(mergedType));
  }
  auto warn_if_shady = [](ggml_type t){
    switch (t) {
      case GGML_TYPE_F32:
        fprintf(stderr, "[Noema] Note: KV F32 is for debugging; expect 2x memory vs F16.\n");
        break;
      default: break;
    }
  };
  warn_if_shady(resolvedK);
  warn_if_shady(resolvedV);

  const int n_ctx_per_seq = cparams.n_ctx / (cparams.n_seq_max > 0 ? cparams.n_seq_max : 1);
  const int n_ctx_train = llama_n_ctx_train(_model);
  const int minimum_required_ctx = 2048;
  if (n_ctx_per_seq < minimum_required_ctx) {
    NSLog(@"[LlamaRunner] Error: Per-sequence context length too small (%d). Required at least %d. Train ctx: %d.", n_ctx_per_seq, minimum_required_ctx, n_ctx_train);
      llama_model_free(_model);
    _model = nullptr;
    _loaded = false;
    noema_llama_backend_release();
    return nil;
  }

  _ctx = llama_init_from_model(_model, cparams);
  if (_ctx == nullptr) {
      llama_model_free(_model);
    _model = nullptr;
    _loaded = false;
    noema_llama_backend_release();
    return nil;
  }
  llama_set_n_threads(_ctx, nThreads, nThreads);
  _loaded = true;
  _nThreads = nThreads;

  if (_verbose) {
    NSLog(@"[LlamaRunner] Context ready. n_ctx=%d, n_seq_max=%d, n_gpu_layers=%d, threads=%d, threads_batch=%d",
          llama_n_ctx(_ctx), cparams.n_seq_max, nGpu, cparams.n_threads, cparams.n_threads_batch);
  }

  {
    BOOL runtime = [LlamaRunner runtimeHasVisionSymbols];
    NSLog(@"[LlamaRunner] Runtime vision symbols present: %@", runtime ? @"YES" : @"NO");
  }

  return self;
}

- (BOOL)hasVisionOps {
  // Detect presence of symbols in the linked binary at runtime only.
  return [LlamaRunner runtimeHasVisionSymbols];
}

+ (BOOL)runtimeHasVisionSymbols {
  // llava + clip entry points commonly present in vision-enabled builds
  void *sym_llava = dlsym(RTLD_DEFAULT, "llava_image_embed_make_with_model");
  void *sym_clip  = dlsym(RTLD_DEFAULT, "clip_image_load_from_file");
  // Also accept MTMD path (Gemma 3 / multi-token multimodal)
  void *sym_mtmd  = dlsym(RTLD_DEFAULT, "mtmd_image_embed_make_with_model");
  return (sym_llava && sym_clip) || (sym_mtmd && sym_clip);
}

- (LlamaVisionProbe)probeVision {
  // Without vendored vision glue, we cannot probe image embedding.
  return LlamaVisionProbeUnavailable;
}

- (void)generateWithPrompt:(NSString *)prompt
                  maxTokens:(int)maxTokens
                     onToken:(LlamaTokenHandler)onToken
                      onDone:(LlamaDoneHandler)onDone
                     onError:(LlamaErrorHandler)onError {
  if (!_loaded) {
    if (onError) {
      NSError *err = [NSError errorWithDomain:@"Llama" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Model not loaded"}];
      onError(err);
    }
    return;
  }

  // Reset cancellation flag at the start of each generation
  _cancelRequested.store(false);

    // Clear memory/KV using new memory API
    noema_llama_kv_cache_clear(_ctx, /*clearData=*/true);
    // Ensure we are producing logits (not embeddings) for subsequent decodes/sampling
    llama_set_embeddings(_ctx, false);


  // Build an initial prompt (avoid duplicate BOS by disabling auto-add when control tokens are present)
  const int n_batch_alloc = 512;
  llama_batch batch = llama_batch_init(/*n_tokens_alloc*/ n_batch_alloc, /*embd*/ 0, /*n_seq_max*/ 1);
  std::string p = [prompt UTF8String];
  std::vector<llama_token> toks;
  toks.resize(p.size() * 4 + 16);
  const struct llama_vocab *vocab = llama_model_get_vocab(_model);
  // Decide whether to auto-insert BOS depending on whether the prompt already starts with control tokens
  bool addSpecial = true;
  if (!p.empty()) {
    const char c0 = p[0];
    // Common control-token prefixes in chat templates: '<' (e.g. <bos>, <|...|>) or '[' (e.g. [INST])
    if (c0 == '<' || c0 == '[') {
      addSpecial = false;
    }
  }
  // Parse special tokens (e.g., <|im_start|>, <|eot_id|>) to preserve chat templates; avoid double BOS
  int n = llama_tokenize(vocab, p.c_str(), (int32_t)p.length(), toks.data(), (int)toks.size(), /*add_special*/ addSpecial, /*parse_special*/ true);
  toks.resize(n);

  // Clamp prompt to fit into context window with headroom
  const int ctx_max = llama_n_ctx(_ctx);
  const int prompt_limit = std::max(1, ctx_max - 64);
  if (n > prompt_limit) {
    // Keep only the most recent tail of the prompt
    const int start = n - prompt_limit;
    std::vector<llama_token> tail(toks.begin() + start, toks.end());
    toks.swap(tail);
    n = (int)toks.size();
  }

  // If the prompt is empty, inject a BOS and run a single decode to produce logits
  if (n == 0) {
    batch.n_tokens = 0;
    batch.token[0]     = llama_vocab_bos(vocab);
    batch.pos[0]       = 0;
    batch.n_seq_id[0]  = 1;
    batch.seq_id[0][0] = 0;
    batch.logits[0]    = true;
    batch.n_tokens     = 1;

    if (llama_decode(_ctx, batch) != 0) {
      if (onError) {
        NSError *err = [NSError errorWithDomain:@"Llama" code:2 userInfo:@{NSLocalizedDescriptionKey:@"decode failed (BOS)"}];
        onError(err);
      }
      llama_batch_free(batch);
      return;
    }
    // Keep n at 0; we already produced logits at pos 0. We'll start generation at pos 1.
  }

  // Evaluate the entire prompt in chunks so KV positions remain consecutive
  int n_cur = 0;
  while (n_cur < n) {
    if (_cancelRequested.load()) {
      llama_batch_free(batch);
      if (onDone) onDone();
      return;
    }
    batch.n_tokens = 0;
    const int n_chunk = std::min(n - n_cur, n_batch_alloc);
    // Clear logits flags for the slice we will use, then mark the last token to return logits
    for (int j = 0; j < n_chunk; ++j) batch.logits[j] = 0;
    for (int i = 0; i < n_chunk; ++i) {
      const int pos = n_cur + i;
      batch.token[batch.n_tokens]     = toks[pos];
      batch.pos[batch.n_tokens]       = pos;
      batch.n_seq_id[batch.n_tokens]  = 1;
      batch.seq_id[batch.n_tokens][0] = 0;
      batch.logits[batch.n_tokens]    = (i == n_chunk - 1);
      batch.n_tokens++;
    }
    if (_cancelRequested.load()) {
      llama_batch_free(batch);
      if (onDone) onDone();
      return;
    }
    if (llama_decode(_ctx, batch) != 0) {
      if (onError) {
        NSError *err = [NSError errorWithDomain:@"Llama" code:2 userInfo:@{NSLocalizedDescriptionKey:@"decode failed"}];
        onError(err);
      }
      llama_batch_free(batch);
      return;
    }
    n_cur += n_chunk;
  }

  // Default sampler: temperature + top-k
  auto *smpl = noema_make_default_sampler();
  llama_sampler_reset(smpl);
  // Lazy initialize speculative decoder if configured
  [self setupSpeculativeIfConfigured];
  llama_sampler *greedy_main = llama_sampler_init_greedy();
  llama_sampler *greedy_draft = _specEnabled ? llama_sampler_init_greedy() : nullptr;
  if (greedy_draft) llama_sampler_reset(greedy_draft);
  llama_sampler_reset(greedy_main);
  // If speculation is enabled, feed the prompt into the draft context to align states
  if (_specEnabled) {
    llama_batch db = llama_batch_init(/*n_tokens_alloc*/ n_batch_alloc, /*embd*/ 0, /*n_seq_max*/ 1);
    int cur = 0;
    while (cur < n) {
      db.n_tokens = 0;
      const int n_chunk = std::min(n - cur, n_batch_alloc);
      for (int i = 0; i < n_chunk; ++i) {
        const int pos = cur + i;
        db.token[db.n_tokens]     = toks[pos];
        db.pos[db.n_tokens]       = pos;
        db.n_seq_id[db.n_tokens]  = 1;
        db.seq_id[db.n_tokens][0] = 0;
        db.logits[db.n_tokens]    = (i == n_chunk - 1);
        db.n_tokens++;
      }
      (void)llama_decode(_draftCtx, db);
      cur += n_chunk;
    }
    llama_batch_free(db);
  }
  
  const int base_pos = (n > 0 ? n : 1);
  int generated = 0;
  const bool unlimited = maxTokens <= 0;
  int pos_main = base_pos;
  int pos_draft = base_pos;
  while (unlimited || generated < maxTokens) {
    if (_cancelRequested.load()) { break; }
    if (_specEnabled) {
      // Draft proposal
      std::vector<llama_token> proposal; proposal.reserve(_specValue);
      llama_batch db = llama_batch_init(32, 0, 1);
      for (int i = 0; i < _specValue; ++i) {
        const llama_token dtok = llama_sampler_sample(greedy_draft, _draftCtx, -1);
        if (dtok < 0 || dtok == llama_vocab_eos(vocab)) break;
        proposal.push_back(dtok);
        db.n_tokens = 0;
        if (pos_draft >= ctx_max - 1) break;
        db.token[0] = dtok; db.pos[0] = pos_draft; db.n_seq_id[0] = 1; db.seq_id[0][0] = 0; db.logits[0] = 1; db.n_tokens = 1;
        (void)llama_decode(_draftCtx, db);
        pos_draft++;
      }
      llama_batch_free(db);
      bool diverged = false;
      for (size_t i = 0; i < proposal.size(); ++i) {
        const llama_token top_main = llama_sampler_sample(greedy_main, _ctx, -1);
        if (top_main == proposal[i]) {
          llama_sampler_accept(smpl, top_main);
          char buf[512]; int nout = llama_token_to_piece(vocab, top_main, buf, sizeof(buf), 0, false);
          if (nout > 0 && onToken) { NSString *piece = [[NSString alloc] initWithBytes:buf length:nout encoding:NSUTF8StringEncoding]; onToken(piece ?: @""); }
          batch.n_tokens = 0; if (pos_main >= ctx_max - 1) { diverged = true; break; }
          batch.token[0] = top_main; batch.pos[0] = pos_main; batch.n_seq_id[0] = 1; batch.seq_id[0][0] = 0; batch.logits[0] = 1; batch.n_tokens = 1;
          if (llama_decode(_ctx, batch) != 0) { diverged = true; break; }
          pos_main++; generated++; if (!unlimited && generated >= maxTokens) { diverged = true; break; }
        } else {
          const llama_token tok = llama_sampler_sample(smpl, _ctx, -1);
          if (tok < 0 || tok == llama_vocab_eos(vocab)) { diverged = true; break; }
          llama_sampler_accept(smpl, tok);
          char buf[512]; int nout = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
          if (nout > 0 && onToken) { NSString *piece = [[NSString alloc] initWithBytes:buf length:nout encoding:NSUTF8StringEncoding]; onToken(piece ?: @""); }
          batch.n_tokens = 0; if (pos_main >= ctx_max - 1) { diverged = true; break; }
          batch.token[0] = tok; batch.pos[0] = pos_main; batch.n_seq_id[0] = 1; batch.seq_id[0][0] = 0; batch.logits[0] = 1; batch.n_tokens = 1;
          if (llama_decode(_ctx, batch) != 0) { diverged = true; break; }
          pos_main++; generated++;
          // sync draft with chosen token
          llama_batch sdb = llama_batch_init(1, 0, 1); sdb.n_tokens=1; sdb.token[0]=tok; sdb.pos[0]=pos_draft++; sdb.n_seq_id[0]=1; sdb.seq_id[0][0]=0; sdb.logits[0]=1; (void)llama_decode(_draftCtx, sdb); llama_batch_free(sdb);
          diverged = true; break;
        }
      }
      if (diverged) { if (!unlimited && generated >= maxTokens) break; continue; }
      if (!unlimited && generated >= maxTokens) break;
      continue;
    } else {
      const llama_token tok = llama_sampler_sample(smpl, _ctx, -1);
      if (tok < 0 || tok == llama_vocab_eos(vocab)) break;
      llama_sampler_accept(smpl, tok);
      char buf[512]; int nout = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
      if (nout > 0 && onToken) { NSString *piece = [[NSString alloc] initWithBytes:buf length:nout encoding:NSUTF8StringEncoding]; onToken(piece ?: @""); }
      batch.n_tokens = 0; if (pos_main >= ctx_max - 1) break;
      batch.token[0]=tok; batch.pos[0]=pos_main; batch.n_seq_id[0]=1; batch.seq_id[0][0]=0; batch.logits[0]=1; batch.n_tokens=1;
      if (_cancelRequested.load()) break; if (llama_decode(_ctx, batch) != 0) break;
      pos_main++; generated++;
    }
  }

  llama_sampler_free(smpl);
  llama_sampler_free(greedy_main);
  if (greedy_draft) llama_sampler_free(greedy_draft);
  llama_batch_free(batch);
  if (onDone) onDone();
}

- (void)generateWithPrompt:(NSString *)prompt
                imagePaths:(NSArray<NSString *> * _Nullable)imagePaths
                 maxTokens:(int)maxTokens
                   onToken:(LlamaTokenHandler)onToken
                    onDone:(LlamaDoneHandler)onDone
                   onError:(LlamaErrorHandler)onError {
    if (!_loaded) {
        if (onError) {
            NSError *err = [NSError errorWithDomain:@"Llama" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Model not loaded"}];
            onError(err);
        }
        return;
    }

    // Reset cancellation flag at the start of each generation
    _cancelRequested.store(false);

    // If no images, fall back to text-only path
    if (imagePaths == nil || imagePaths.count == 0) {
        [self generateWithPrompt:prompt maxTokens:maxTokens onToken:onToken onDone:onDone onError:onError];
        return;
    }

    if (onError) {
        NSError *err = [NSError errorWithDomain:@"Llama" code:1002 userInfo:@{NSLocalizedDescriptionKey:@"In-process vision is not available in this build. Use llama.cpp's server with base64 image URLs or provide a vendored vision wrapper."}];
        onError(err);
    }
}

- (void)unload {
  if (_ctx || _model || _draftCtx || _draftModel) {
    fputs("[LlamaRunner] Unload begin\n", stderr);
  }
  if (_ctx) { llama_free(_ctx); _ctx = nullptr; }
  if (_model) { llama_model_free(_model); _model = nullptr; }
  if (_draftCtx) { llama_free(_draftCtx); _draftCtx = nullptr; }
  if (_draftModel) { llama_model_free(_draftModel); _draftModel = nullptr; }
  _loaded = false;
  noema_llama_backend_release();
  fputs("[LlamaRunner] Unload complete\n", stderr);
}

@end
