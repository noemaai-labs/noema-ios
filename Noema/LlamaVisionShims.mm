#import "LlamaVisionShims.h"
#import <dlfcn.h>
#import "NoemaLlamaConfig.h"

bool noema_model_params_set_mmproj(struct llama_model_params *params, const char *mmproj_path) {
#if defined(LLAMA_MODEL_PARAMS_HAS_MMPROJ)
    if (!params || !mmproj_path) return false;
    params->mmproj = mmproj_path;
    return true;
#else
    (void)params; (void)mmproj_path;
    return false;
#endif
}

// Minimal stub that checks for vision symbols and returns false if missing.
// A future revision can wire the actual llava/mtmd+clip calls without changing Swift code.
bool noema_encode_image_rgba8_into_ctx(struct llama_context *ctx,
                                       const void *rgba,
                                       int32_t width,
                                       int32_t height,
                                       int32_t stride) {
    (void)rgba; (void)width; (void)height; (void)stride;
    if (!ctx) return false;
    void *sym_llava = dlsym(RTLD_DEFAULT, "llava_image_embed_make_with_model");
    void *sym_clip  = dlsym(RTLD_DEFAULT, "clip_image_load_from_file");
    void *sym_mtmd  = dlsym(RTLD_DEFAULT, "mtmd_image_embed_make_with_model");
    if (!( (sym_llava && sym_clip) || (sym_mtmd && sym_clip) )) {
        return false;
    }
    // Vision symbols exist, but this shim intentionally avoids binding to private headers.
    // Returning false lets Swift report a clear error and keeps the surface stable.
    return false;
}

