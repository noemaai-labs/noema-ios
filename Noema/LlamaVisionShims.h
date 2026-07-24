#pragma once

#include <stdbool.h>
#include <stdint.h>

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#elif __has_include(<LlamaFramework/llama.h>)
#include <LlamaFramework/llama.h>
#else
#include "llama.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Returns true and sets params->mmproj when the linked llama.cpp exposes that field.
// Returns false when the build does not support external projectors via model params.
bool noema_model_params_set_mmproj(struct llama_model_params *params, const char *mmproj_path);

// Encodes a single sRGB, non-premultiplied RGBA8 image into the given llama context.
// Internally bridges to the vision path exposed by the linked llama.cpp (e.g., LLaVA/MTMD).
// Returns true on success.
bool noema_encode_image_rgba8_into_ctx(struct llama_context *ctx,
                                       const void *rgba,
                                       int32_t width,
                                       int32_t height,
                                       int32_t stride);

#ifdef __cplusplus
}
#endif

