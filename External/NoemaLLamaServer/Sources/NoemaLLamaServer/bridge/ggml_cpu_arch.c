// Noema-owned architecture selector. SwiftPM compiles one translation unit per
// target architecture while the complete upstream arch directory stays excluded.
#if defined(__aarch64__) || defined(__arm64__)
#include "../upstream/ggml/src/ggml-cpu/arch/arm/quants.c"
#elif defined(__x86_64__) || defined(__i386__)
#include "../upstream/ggml/src/ggml-cpu/arch/x86/quants.c"
#else
#error "NoemaLLamaServer: unsupported CPU architecture"
#endif
