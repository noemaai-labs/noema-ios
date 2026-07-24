// Repacking kernels selected safely at compile time for device and simulator.
#if defined(__aarch64__) || defined(__arm64__)
#include "../upstream/ggml/src/ggml-cpu/arch/arm/repack.cpp"
#elif defined(__x86_64__) || defined(__i386__)
#include "../upstream/ggml/src/ggml-cpu/arch/x86/repack.cpp"
#else
#error "NoemaLLamaServer: unsupported CPU architecture"
#endif
