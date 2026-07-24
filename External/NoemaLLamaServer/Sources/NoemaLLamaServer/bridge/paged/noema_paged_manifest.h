// Noema Overfit — .noema-paged manifest reader (native format authority).
// Every check here fails closed: a manifest that does not validate exactly
// never reaches the loader.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace noema_paged {

enum class family : uint8_t { gate = 0, up = 1, down = 2, gate_up = 3 };
constexpr int FAMILY_COUNT = 4;

const char * family_name(family f);

struct expert_record {
    uint32_t layer   = 0;
    family   fam     = family::gate;
    uint32_t expert  = 0;
    uint32_t file    = 0;      // index into manifest::expert_files
    uint64_t offset  = 0;
    uint64_t length  = 0;
    uint64_t xxh64   = 0;
    int32_t  ggml_type = -1;
    int64_t  ne0     = 0;      // per-expert 2D slice dimensions
    int64_t  ne1     = 0;
};

struct payload_file {
    std::string path;          // flat name inside the package directory
    uint64_t    size_bytes = 0;
    std::string sha256;        // verified Swift-side at install; carried for identity
};

// Uniform per-(layer, family) geometry derived from the records during
// validation. Bank tensors are cross-checked against this.
struct family_geometry {
    bool     present = false;
    int32_t  ggml_type = -1;
    int64_t  ne0 = 0;
    int64_t  ne1 = 0;
    uint64_t record_length = 0;
};

struct manifest {
    int32_t     format_version = 0;
    std::string architecture;
    uint32_t    n_expert = 0;
    uint32_t    n_expert_used = 0;
    uint32_t    moe_layer_count = 0;
    uint32_t    total_layer_count = 0;
    bool        fused_gate_up = false;
    uint64_t    alignment = 0;
    std::string resident_path;
    uint64_t    resident_size_bytes = 0;
    std::string fingerprint;
    std::vector<payload_file>  expert_files;
    std::vector<expert_record> records;
};

struct validated_manifest {
    manifest mf;
    std::string dir;  // directory containing manifest.json (payload paths resolve against it)
    // geometry[layer][family]
    std::vector<std::vector<family_geometry>> geometry;
    // record index by (layer, family, expert): dense map filled during validation
    // idx = (layer * FAMILY_COUNT + family) * n_expert + expert; -1 = absent
    std::vector<int64_t> record_index;

    const expert_record * record_for(uint32_t layer, family f, uint32_t expert) const;
    const family_geometry * geometry_for(uint32_t layer, family f) const;
    bool layer_is_paged(uint32_t layer) const;
};

// Parses and fully validates manifest.json at `manifest_path`. On failure
// returns false and fills `err` with a single-line reason. Filesystem access
// is limited to reading the manifest itself; payload files are stat'd and
// opened later by the runtime (finalize).
bool parse_and_validate(const std::string & manifest_path,
                        validated_manifest & out,
                        std::string & err);

} // namespace noema_paged
