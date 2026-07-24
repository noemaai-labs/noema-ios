#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LlamaTokenHandler)(NSString *token);
typedef void (^LlamaDoneHandler)(void);
typedef void (^LlamaErrorHandler)(NSError *error);

// Vision probe result codes for callers to distinguish failure reasons
typedef NS_ENUM(NSInteger, LlamaVisionProbe) {
	LlamaVisionProbeUnavailable = -1,   // vision not available in this build
	LlamaVisionProbeNoProjector = -2,   // model loaded but missing projector / not a VLM
	LlamaVisionProbeOK           =  1   // vision embeddings working
};

// --- KV-cache quantization config ---
// Default behavior (enabled == NO): both K and V use F16 (no quant)
typedef NS_ENUM(NSInteger, NOEMAKVCacheType) {
	NOEMAKVCacheTypeF32,
	NOEMAKVCacheTypeF16,   // default / “no quant”
	NOEMAKVCacheTypeQ8_0,
	NOEMAKVCacheTypeQ5_0,
	NOEMAKVCacheTypeQ5_1,
	NOEMAKVCacheTypeQ4_0,
	NOEMAKVCacheTypeQ4_1,
	NOEMAKVCacheTypeIQ4_NL
};

typedef struct {
	BOOL enabled;                 // if NO -> always use F16 for both K and V
	NOEMAKVCacheType typeK;       // ignored if enabled == NO
	NOEMAKVCacheType typeV;       // ignored if enabled == NO
} NOEMAKVCacheConfig;

@interface LlamaRunner : NSObject
// Returns YES if the current process exports known vision symbols discovered via dlsym,
// regardless of whether headers were available at compile time.
+ (BOOL)runtimeHasVisionSymbols;
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       nCtxTokens:(int)nCtx
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads;

// Designated initializer allowing callers to specify sequence parallelism
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       nCtxTokens:(int)nCtx
                          nSeqMax:(int)nSeqMax
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads;

// New initializer supporting split-projector VLMs when available in llama.cpp
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       mmprojPath:(NSString * _Nullable)mmprojPath
                       nCtxTokens:(int)nCtx
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads;

// Variant with explicit sequence parallelism for VLMs
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                       mmprojPath:(NSString * _Nullable)mmprojPath
                       nCtxTokens:(int)nCtx
                          nSeqMax:(int)nSeqMax
                       nGpuLayers:(int)nGpu
                           nThreads:(int)nThreads;

- (void)generateWithPrompt:(NSString *)prompt
                  maxTokens:(int)maxTokens
                     onToken:(LlamaTokenHandler)onToken
                      onDone:(LlamaDoneHandler)onDone
                     onError:(LlamaErrorHandler)onError;

// New API: optional image paths for multimodal prompts. In this configuration we do not
// process images in-process; callers should pass nil here and prefer routing vision
// requests through a server using the OpenAI-compatible chat API with base64 image URLs.
- (void)generateWithPrompt:(NSString *)prompt
                imagePaths:(nullable NSArray<NSString *> *)imagePaths
                 maxTokens:(int)maxTokens
                   onToken:(LlamaTokenHandler)onToken
                    onDone:(LlamaDoneHandler)onDone
                   onError:(LlamaErrorHandler)onError;

// Whether vision ops appear to be present in the linked binary (runtime symbol probe).
- (BOOL)hasVisionOps;

// Runtime probe placeholder. Without depending on example headers we cannot safely
// attempt an image embed here. This returns Unavailable in non-vendored builds.
- (LlamaVisionProbe)probeVision;

// Request cancellation of any in-flight generation. Safe to call from any thread.
- (void)cancelCurrent;

// KV-cache config (thread-safe enough for “configure before load” usage)
- (void)setKVCacheConfig:(NOEMAKVCacheConfig)config;
- (NOEMAKVCacheConfig)kvCacheConfig;

- (void)unload;
@end

NS_ASSUME_NONNULL_END
