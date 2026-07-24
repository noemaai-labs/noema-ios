#ifndef NOEMA_LLAMA_CONFIG_H
#define NOEMA_LLAMA_CONFIG_H

// Define LLAMA_MODEL_PARAMS_HAS_MMPROJ if the linked llama.cpp headers expose
// a field `mmproj` in `struct llama_model_params`.
// By default this is OFF; your build system can -DLLAMA_MODEL_PARAMS_HAS_MMPROJ=1
// after verifying the symbol is present (e.g., grep headers for "mmproj;").
#ifndef LLAMA_MODEL_PARAMS_HAS_MMPROJ
// #define LLAMA_MODEL_PARAMS_HAS_MMPROJ 1
#endif

// Define LLAMA_MODEL_PARAMS_HAS_USE_MMAP if the linked llama.cpp exposes
// a boolean field `use_mmap` in `struct llama_model_params`.
#ifndef LLAMA_MODEL_PARAMS_HAS_USE_MMAP
// #define LLAMA_MODEL_PARAMS_HAS_USE_MMAP 1
#endif

#endif /* NOEMA_LLAMA_CONFIG_H */