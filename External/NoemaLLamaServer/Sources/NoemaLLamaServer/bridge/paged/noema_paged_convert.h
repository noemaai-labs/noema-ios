// Native converter API; output must match scripts/make_paged_package.py.
#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace noema_paged {

// Return codes shared with the exported C API (noema_paged_convert):
// 0 = success, 1 = failure (error carries the reason), 2 = cancelled.
struct convert_result {
    int32_t code = 1;
    std::string error;
};

// Progress observer. `stage` is one of "preparing", "resident", "experts",
// "verifying", "finishing"; `progress` is monotonic in [0, 1] across the whole
// conversion. Returning nonzero cancels the build: the staging directory is
// deleted and convert_package returns code 2.
using convert_progress_fn = std::function<int32_t(float progress, const char *stage)>;

// Converts the GGUF at `src_gguf_path` (a single file, or the FIRST shard of
// an llama.cpp split — sibling shards are located automatically) into a
// .noema-paged package at `dst_package_dir` (the final package directory
// itself; it must not exist yet). `alignment` <= 0 selects the default 16384.
// The build is staged in "<dst>.building-<pid>" and renamed into place only
// after full verification (record re-read + xxh64 + byte-compare vs source,
// file sha256s, fingerprint). `progress` may be an empty function.
convert_result convert_package(const std::string & src_gguf_path,
                               const std::string & dst_package_dir,
                               int64_t alignment,
                               const convert_progress_fn & progress);

} // namespace noema_paged
