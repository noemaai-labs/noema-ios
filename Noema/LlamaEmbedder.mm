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

  if (p_memory_clear && p_get_memory) {
    p_memory_clear(p_get_memory(ctx), /*data*/false);
  } else if (p_memory_seq_rm && p_get_memory) {
    for (llama_seq_id seq = 0; seq < 8; ++seq) {
      (void)p_memory_seq_rm(p_get_memory(ctx), seq, -1, -1);
    }
  }
#else
  // Assume modern llama.cpp providing llama_memory_seq_rm
  llama_memory_clear(llama_get_memory(ctx), /*data*/false);
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
  int _threads;
  int _maxContextLength;
  int _poolingType;
  int _perSequenceCapacity;
  int _packedTokenCapacity;
  int _sequenceCapacity;
  llama_batch _batch;
  BOOL _hasBatch;
  std::vector<std::vector<llama_token>> _tokenScratch;
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
    _threads = threads > 0 ? threads : 2;
    _maxContextLength = contextLength > 0 ? contextLength : 2048;
    _poolingType = poolingType < 0 ? LLAMA_POOLING_MEAN : poolingType;
    _perSequenceCapacity = 0;
    _packedTokenCapacity = 0;
    _sequenceCapacity = 0;
    _batch = {};
    _hasBatch = NO;
    _tokenScratch.resize(8);
    // Context and batch are allocated lazily from observed token lengths.
    _ctx = NULL;
  _dim = _model ? llama_n_embd(_model) : 0;
  return self;
}

- (BOOL)isReady { return _model && _dim > 0 && _evalMode != NoemaEmbeddingEvalModeUnsupported; }
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

- (BOOL)ensureCapacityForMaxTokens:(int)maxTokens
                       packedTokens:(int)packedTokens
                      sequenceCount:(int)sequenceCount {
  const int perSequence = ((maxTokens + 31) / 32) * 32;
  const int packed = ((packedTokens + 31) / 32) * 32;
  const int sequences = std::max(1, sequenceCount);
  if (_ctx &&
      perSequence <= _perSequenceCapacity &&
      packed <= _packedTokenCapacity &&
      sequences <= _sequenceCapacity) {
    return YES;
  }
  _perSequenceCapacity = std::max(_perSequenceCapacity, perSequence);
  _packedTokenCapacity = std::max(_packedTokenCapacity, packed);
  _sequenceCapacity = std::max(_sequenceCapacity, sequences);
  if (_ctx) { llama_free(_ctx); _ctx = NULL; }
  if (_hasBatch) { llama_batch_free(_batch); _hasBatch = NO; }

  struct llama_context_params cp = llama_context_default_params();
  cp.embeddings = true;
  cp.n_threads = _threads;
  cp.n_threads_batch = _threads;
  cp.n_ctx = _perSequenceCapacity * _sequenceCapacity;
  cp.n_batch = _packedTokenCapacity;
  if (_evalMode == NoemaEmbeddingEvalModeDecode && _poolingType == LLAMA_POOLING_LAST) {
    // The two-pass LAST-pooling path emits one final row per sequence. Keep
    // llama.cpp's output and prompt-processing graph reservations bounded to
    // that invariant instead of the packed token count.
    cp.n_outputs_max = _sequenceCapacity;
  }
  cp.n_ubatch = _evalMode == NoemaEmbeddingEvalModeEncode
      ? cp.n_batch
      : std::min(cp.n_batch, (uint32_t)_perSequenceCapacity);
  cp.n_seq_max = _sequenceCapacity;
  cp.pooling_type = (enum llama_pooling_type)_poolingType;
  cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
  _ctx = llama_init_from_model(_model, cp);
  if (!_ctx) return NO;
  llama_set_n_threads(_ctx, _threads, _threads);
  _batch = llama_batch_init(_packedTokenCapacity, 0, 1);
  _hasBatch = _batch.token != NULL;
  return _hasBatch;
}

- (BOOL)evaluateCurrentBatch {
  switch (_evalMode) {
    case NoemaEmbeddingEvalModeEncode:
      return llama_encode(_ctx, _batch) == 0;
    case NoemaEmbeddingEvalModeDecode:
      return llama_decode(_ctx, _batch) == 0;
    case NoemaEmbeddingEvalModeUnsupported:
    default:
      return NO;
  }
}

- (BOOL)copyEmbeddingForSequence:(llama_seq_id)sequence
                      intoBuffer:(float *)buffer {
  const float *emb = llama_get_embeddings_seq(_ctx, sequence);
  if (!emb) return NO;
  for (int i = 0; i < _dim; ++i) {
    if (!std::isfinite(emb[i])) return NO;
  }
  memcpy(buffer, emb, sizeof(float) * _dim);
  return YES;
}

- (BOOL)embedTexts:(NSArray<NSString *> *)texts
         intoBuffer:(float *)buffer
          rowStride:(int)rowStride {
  if (!_model || !buffer || rowStride < _dim || texts.count == 0 || texts.count > 8) return NO;
  if (_evalMode == NoemaEmbeddingEvalModeUnsupported) return NO;
  const struct llama_vocab *vocab = llama_model_get_vocab(_model);
  int maxTokens = 0;
  int packedTokens = 0;
  for (NSUInteger seq = 0; seq < texts.count; ++seq) {
    std::string s(texts[seq].UTF8String ?: "");
    auto &tokens = _tokenScratch[seq];
    tokens.resize(s.size() + 8);
    int n = llama_tokenize(vocab, s.c_str(), (int32_t)s.length(), tokens.data(),
                           (int)tokens.size(), true, false);
    if (n <= 0 || n > _maxContextLength) return NO;
    tokens.resize(n);
    maxTokens = std::max(maxTokens, n);
    packedTokens += n;
  }

  // Decoder embedders that use LAST pooling only need the final hidden state
  // from each sequence. Decode the prefixes without per-token outputs, then
  // evaluate the final tokens together with embeddings enabled. llama.cpp's
  // output buffer otherwise includes a full vocabulary-logit row for every
  // input token (more than 5 GiB for 8 x 1,200-token Qwen3 inputs).
  if (_evalMode == NoemaEmbeddingEvalModeDecode && _poolingType == LLAMA_POOLING_LAST) {
    if (![self ensureCapacityForMaxTokens:maxTokens
                              packedTokens:packedTokens
                             sequenceCount:(int)texts.count]) return NO;
    noema_llama_kv_cache_clear(_ctx);

    llama_set_embeddings(_ctx, false);
    _batch.n_tokens = 0;
    for (NSUInteger seq = 0; seq < texts.count; ++seq) {
      const auto &tokens = _tokenScratch[seq];
      for (int pos = 0; pos + 1 < (int)tokens.size(); ++pos) {
        const int row = _batch.n_tokens++;
        _batch.token[row] = tokens[pos];
        _batch.pos[row] = pos;
        _batch.seq_id[row][0] = (llama_seq_id)seq;
        _batch.n_seq_id[row] = 1;
        _batch.logits[row] = 0;
      }
    }
    if (_batch.n_tokens > 0) {
      // Keep one ignored output so the regular decoder graph never has to
      // represent a zero-row output tensor. This remains bounded to one
      // vocabulary row instead of one row per prefix token.
      _batch.logits[_batch.n_tokens - 1] = 1;
      if (![self evaluateCurrentBatch]) {
        llama_set_embeddings(_ctx, true);
        return NO;
      }
    }

    llama_set_embeddings(_ctx, true);
    _batch.n_tokens = 0;
    for (NSUInteger seq = 0; seq < texts.count; ++seq) {
      const auto &tokens = _tokenScratch[seq];
      const int pos = (int)tokens.size() - 1;
      const int row = _batch.n_tokens++;
      _batch.token[row] = tokens[pos];
      _batch.pos[row] = pos;
      _batch.seq_id[row][0] = (llama_seq_id)seq;
      _batch.n_seq_id[row] = 1;
      _batch.logits[row] = 1;
    }
    if (![self evaluateCurrentBatch]) return NO;

    for (NSUInteger seq = 0; seq < texts.count; ++seq) {
      if (![self copyEmbeddingForSequence:(llama_seq_id)seq
                               intoBuffer:buffer + seq * rowStride]) return NO;
    }
    return YES;
  }

  // Mean/CLS pooling and encoder models require the complete token matrix.
  // Keep those requests single-sequence so their unavoidable vocabulary-logit
  // output cannot be multiplied by the eight-document Swift batch.
  for (NSUInteger seq = 0; seq < texts.count; ++seq) {
    const auto &tokens = _tokenScratch[seq];
    const int tokenCount = (int)tokens.size();
    if (![self ensureCapacityForMaxTokens:tokenCount
                              packedTokens:tokenCount
                             sequenceCount:1]) return NO;
    if (_evalMode == NoemaEmbeddingEvalModeDecode) noema_llama_kv_cache_clear(_ctx);
    llama_set_embeddings(_ctx, true);

    _batch.n_tokens = tokenCount;
    for (int pos = 0; pos < tokenCount; ++pos) {
      _batch.token[pos] = tokens[pos];
      _batch.pos[pos] = pos;
      _batch.seq_id[pos][0] = 0;
      _batch.n_seq_id[pos] = 1;
      _batch.logits[pos] = 1;
    }
    if (![self evaluateCurrentBatch]) return NO;
    if (![self copyEmbeddingForSequence:0
                             intoBuffer:buffer + seq * rowStride]) return NO;
  }
  return YES;
}

- (void)unload {
  if (_hasBatch) { llama_batch_free(_batch); _hasBatch = NO; }
  if (_ctx) { llama_free(_ctx); _ctx = NULL; }
  if (_model) { llama_model_free(_model); _model = NULL; }
  noema_llama_backend_release();
}

@end
