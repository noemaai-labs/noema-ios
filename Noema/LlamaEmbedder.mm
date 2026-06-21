// LlamaEmbedder.mm
#import "LlamaEmbedder.h"
#import "LlamaBackendManager.h"
#import "Noema-Bridging.h"
#include <vector>
#include <string>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <dlfcn.h>

// Backwards-compatible define for pooling types in case headers are older
#ifndef LLAMA_POOLING_NONE
#define LLAMA_POOLING_NONE 0
#endif
#ifndef LLAMA_POOLING_MEAN
#define LLAMA_POOLING_MEAN 1
#endif
#ifndef LLAMA_POOLING_CLS
#define LLAMA_POOLING_CLS 2
#endif
#ifndef LLAMA_POOLING_LAST
#define LLAMA_POOLING_LAST 3
#endif

// The declarations are now provided by the bridging header,
// so this block is no longer needed.

// Avoid hard-linking against ggml backend symbols. Some builds intentionally hide ggml
// exports (e.g. the loopback server framework) to prevent collisions with an in-process
// llama framework. Resolve at runtime when available and gracefully fall back when not.
static ggml_backend_dev_t noema_try_ggml_backend_dev_by_type(enum ggml_backend_dev_type type) {
  using fn_t = ggml_backend_dev_t (*)(enum ggml_backend_dev_type);
  static fn_t fn = (fn_t) dlsym(RTLD_DEFAULT, "ggml_backend_dev_by_type");
  if (!fn) { return NULL; }
  return fn(type);
}

static inline void noema_llama_kv_cache_clear(struct llama_context *ctx) {
#if defined(__APPLE__)
  using llama_get_memory_fn = llama_memory_t (*)(struct llama_context *);
  using llama_memory_clear_fn = void (*)(llama_memory_t, bool);
  using llama_memory_seq_rm_fn = bool (*)(llama_memory_t, llama_seq_id, llama_pos, llama_pos);

  llama_get_memory_fn p_get_memory = (llama_get_memory_fn)llama_get_memory;
  llama_memory_clear_fn p_memory_clear = (llama_memory_clear_fn)llama_memory_clear;
  llama_memory_seq_rm_fn p_memory_seq_rm = (llama_memory_seq_rm_fn)llama_memory_seq_rm;

  if (p_memory_seq_rm && p_get_memory) {
    (void)p_memory_seq_rm(p_get_memory(ctx), 0, -1, -1);
  } else if (p_memory_clear && p_get_memory) {
    p_memory_clear(p_get_memory(ctx), /*data*/false);
  }
#else
  // Assume modern llama.cpp providing llama_memory_seq_rm
  (void)llama_memory_seq_rm(llama_get_memory(ctx), 0, -1, -1);
#endif
}

typedef NS_ENUM(NSInteger, NoemaEmbeddingEvalMode) {
  NoemaEmbeddingEvalModeUnsupported = 0,
  NoemaEmbeddingEvalModeEncode,
  NoemaEmbeddingEvalModeDecode,
};

static const char * noema_embedding_eval_mode_name(NoemaEmbeddingEvalMode mode) {
  switch (mode) {
    case NoemaEmbeddingEvalModeEncode:
      return "encode";
    case NoemaEmbeddingEvalModeDecode:
      return "decode";
    case NoemaEmbeddingEvalModeUnsupported:
    default:
      return "unsupported";
  }
}

@implementation LlamaEmbedder {
  llama_model *_model;
  llama_context *_ctx;
  int _dim;
  NoemaEmbeddingEvalMode _evalMode;
}

- (instancetype)initWithModelPath:(NSString *)modelPath
                          threads:(int)threads
                       nGpuLayers:(int)nGpuLayers
                    contextLength:(int)contextLength
                       poolingType:(int)poolingType {
  self = [super init];
  if (!self) return nil;
    noema_llama_backend_addref();
    struct llama_model_params mp = llama_model_default_params();
    static ggml_backend_dev_t cpu_devices[2];
    mp.n_gpu_layers = nGpuLayers;
    if (nGpuLayers <= 0) {
      ggml_backend_dev_t cpu = noema_try_ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
      if (cpu) {
        cpu_devices[0] = cpu;
        cpu_devices[1] = NULL;
        mp.devices = cpu_devices;
      } else {
        mp.devices = NULL;
      }
    }
    _model = llama_load_model_from_file(modelPath.UTF8String, mp);
    if (!_model) { noema_llama_backend_release(); return self; }
    const BOOL hasEncoder = llama_model_has_encoder(_model);
    const BOOL hasDecoder = llama_model_has_decoder(_model);
    if (hasDecoder) {
      _evalMode = NoemaEmbeddingEvalModeDecode;
    } else if (hasEncoder) {
      _evalMode = NoemaEmbeddingEvalModeEncode;
    } else {
      _evalMode = NoemaEmbeddingEvalModeUnsupported;
    }
    NSLog(@"[Embed] selected embedding API mode=%s hasEncoder=%d hasDecoder=%d",
          noema_embedding_eval_mode_name(_evalMode),
          (int) hasEncoder,
          (int) hasDecoder);
    if (_evalMode == NoemaEmbeddingEvalModeUnsupported) {
      NSLog(@"[Embed] unsupported embedding model capabilities for path=%@", modelPath);
      llama_model_free(_model);
      _model = NULL;
      noema_llama_backend_release();
      return self;
    }
    struct llama_context_params cp = llama_context_default_params();
    cp.embeddings = true;
    // manage batches and outputs manually.
    cp.n_threads = threads > 0 ? threads : 2;
    cp.n_threads_batch = cp.n_threads;
    const int resolvedContextLength = contextLength > 0 ? contextLength : 2048;
    cp.n_ctx = resolvedContextLength;
    // Configure batching for single-sequence processing. We embed one text at a time
    // but allow up to `n_ctx` tokens per batch.
    cp.n_batch = resolvedContextLength;
    cp.n_ubatch = cp.n_batch;
    cp.n_seq_max = 1;
    int resolvedPoolingType = poolingType;
    if (resolvedPoolingType < 0) {
      resolvedPoolingType = LLAMA_POOLING_MEAN;
    }
    cp.pooling_type = (enum llama_pooling_type)resolvedPoolingType;
    // Keep flash attention disabled in this wrapper for embedding compatibility.
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    // Decoder-style embedders (e.g. Qwen3-Embedding) need the KV cache on GPU
    // when weights are offloaded; otherwise attention ops run on CPU. For
    // CPU-only loads, keep KV on CPU explicitly.
    if (nGpuLayers <= 0) {
      cp.offload_kqv = false;
    }
  // Initialize context using modern API
  _ctx = llama_init_from_model(_model, cp);
  if (!_ctx) { llama_model_free(_model); _model = NULL; noema_llama_backend_release(); return self; }
  llama_set_n_threads(_ctx, cp.n_threads, cp.n_threads);
  _dim = _model ? llama_n_embd(_model) : 0;
  return self;
}

- (BOOL)isReady { return _model && _ctx && _dim > 0 && _evalMode != NoemaEmbeddingEvalModeUnsupported; }
- (int)dimension { return _dim; }

- (int)countTokens:(NSString *)text {
  if (!_model) return 0;
  std::string s(text.UTF8String);
  std::vector<llama_token> toks;
  toks.resize(s.size() + 8);
  const struct llama_vocab *vocab = llama_model_get_vocab(_model);
  int n = llama_tokenize(vocab, s.c_str(), (int32_t)s.length(), toks.data(), (int)toks.size(), /*add_special*/ true, /*parse_special*/ false);
  return n < 0 ? 0 : n;
}

- (BOOL)embedText:(NSString *)text intoBuffer:(float *)buffer length:(int)length {
  if (!_model || !_ctx || !buffer || length < _dim) return NO;
  if (_evalMode == NoemaEmbeddingEvalModeUnsupported) return NO;

  // Decoder-style embedding models use the KV-backed decode path, so clear state
  // before each new sequence to keep pooled outputs isolated per request.
  if (_evalMode == NoemaEmbeddingEvalModeDecode) {
    noema_llama_kv_cache_clear(_ctx);
  }
  
  std::string s(text.UTF8String);
  std::vector<llama_token> toks;
  toks.resize(s.size() + 8);
  const struct llama_vocab *vocab = llama_model_get_vocab(_model);
  int n = llama_tokenize(vocab, s.c_str(), (int32_t)s.length(), toks.data(), (int)toks.size(), /*add_special*/ true, /*parse_special*/ false);
  if (n <= 0) return NO;
  toks.resize(n);
  // Clamp tokens to context - 8 for safety
  const int ctx_max = llama_n_ctx(_ctx);
  const int limit = std::max(1, ctx_max - 8);
  if (n > limit) {
    const int start = n - limit;
    std::vector<llama_token> tail(toks.begin() + start, toks.end());
    toks.swap(tail);
    n = (int)toks.size();
  }
  // Do not truncate here; token-aware chunking in Swift ensures inputs fit.
  // Initialize batch for token IDs (embd=0): we pass token IDs, not precomputed embeddings
  llama_batch batch = llama_batch_init(n, 0, 1);
  if (!batch.token) { llama_batch_free(batch); return NO; }
  if (!batch.logits) {
    // Older llama.cpp builds may not allocate the logits buffer; allocate
    // one so we can mark tokens as graph outputs and avoid ggml asserts.
    batch.logits = (int8_t *)calloc(n, sizeof(int8_t));
    if (!batch.logits) { llama_batch_free(batch); return NO; }
  }
  batch.n_tokens = n;
  for (int i = 0; i < n; ++i) {
    batch.token[i] = toks[i];
    batch.pos[i] = i;
    batch.seq_id[i][0] = 0;
    batch.n_seq_id[i] = 1;
    // Mark all tokens as outputs so pooled embedding modes can aggregate or
    // select the appropriate token row for the whole sequence.
    batch.logits[i] = 1;
  }
  int rc = 0;
  switch (_evalMode) {
    case NoemaEmbeddingEvalModeEncode:
      rc = llama_encode(_ctx, batch);
      break;
    case NoemaEmbeddingEvalModeDecode:
      rc = llama_decode(_ctx, batch);
      break;
    case NoemaEmbeddingEvalModeUnsupported:
    default:
      llama_batch_free(batch);
      return NO;
  }
  llama_batch_free(batch);
  if (rc != 0) return NO;

  // Pooled embedding models expose one sequence embedding per sequence ID.
  const float *emb = llama_get_embeddings_seq(_ctx, 0);
  if (!emb) return NO;
  
  // Validate embeddings before copying
  for (int i = 0; i < _dim; i++) {
    if (!std::isfinite(emb[i])) {
      return NO;  // Reject NaN or Inf values
    }
  }
  
  memcpy(buffer, emb, sizeof(float) * _dim);
  return YES;
}

- (void)unload {
  if (_ctx) { llama_free(_ctx); _ctx = NULL; }
  if (_model) { llama_model_free(_model); _model = NULL; }
  noema_llama_backend_release();
}

@end
