#import <Foundation/Foundation.h>
#import <stdint.h>

// Use the embedded llama.cpp sources from NoemaLLamaServer (no XCFramework).
#import "llama.h"
#import "ggml-backend.h"

#ifdef __cplusplus
extern "C" {
#endif

int32_t gguf_layer_count(const char *path);
size_t app_memory_footprint(void);

struct gguf_moe_scan_result {
    int32_t status;
    int32_t is_moe;
    int32_t expert_count;
    int32_t expert_used_count;
    int32_t total_layer_count;
    int32_t moe_layer_count;
    int32_t hidden_size;
    int32_t feed_forward_size;
    int32_t vocab_size;
};

int gguf_moe_scan(const char *path, struct gguf_moe_scan_result *out_result);

#ifdef __cplusplus
}
#endif

// Expose minimal Objective-C++ bridges to Swift
#if __has_include("LlamaEmbedder.h")
#import "LlamaEmbedder.h"
#endif
#if __has_include("LlamaBackendManager.h")
#import "LlamaBackendManager.h"
#endif
#if __has_include("EmbeddedPythonBridge.h")
#import "EmbeddedPythonBridge.h"
#endif
#if __has_include("WhisperCpp.h")
#import "WhisperCpp.h"
#endif
#if __has_include("ToolbarObserverCrashGuard.h")
#import "ToolbarObserverCrashGuard.h"
#endif
