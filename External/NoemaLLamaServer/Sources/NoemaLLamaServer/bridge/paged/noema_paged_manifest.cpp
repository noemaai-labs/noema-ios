#include "noema_paged_manifest.h"

#include "ggml.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <set>
#include <utility>

namespace noema_paged {

using json = nlohmann::ordered_json;

static constexpr uint64_t MAX_MANIFEST_BYTES   = 256ull * 1024 * 1024;
static constexpr uint32_t MAX_EXPERTS          = 1024;
static constexpr uint32_t MAX_LAYERS           = 4096;
static constexpr uint64_t MIN_ALIGNMENT        = 8;
static constexpr uint64_t MAX_ALIGNMENT        = 1ull << 24;
static constexpr size_t   MAX_PAYLOAD_FILES    = 4096;

static const char * const ARCH_WHITELIST[] = { "qwen3moe", "qwen35moe", "gemma4" };

const char * family_name(family f) {
    switch (f) {
        case family::gate:    return "gate";
        case family::up:      return "up";
        case family::down:    return "down";
        case family::gate_up: return "gate_up";
    }
    return "?";
}

static bool family_from_name(const std::string & s, family & out) {
    if (s == "gate")    { out = family::gate;    return true; }
    if (s == "up")      { out = family::up;      return true; }
    if (s == "down")    { out = family::down;    return true; }
    if (s == "gate_up") { out = family::gate_up; return true; }
    return false;
}

// Flat file names only: the manifest must never name anything outside its
// own package directory.
static bool is_safe_flat_name(const std::string & name) {
    if (name.empty() || name.size() > 255) {
        return false;
    }
    if (name.front() == '.') {
        return false;
    }
    for (char c : name) {
        if (c == '/' || c == '\\' || c == '\0') {
            return false;
        }
    }
    if (name.find("..") != std::string::npos) {
        return false;
    }
    return true;
}

static bool parse_hex_u64(const std::string & s, uint64_t & out) {
    if (s.empty() || s.size() > 16) {
        return false;
    }
    uint64_t v = 0;
    for (char c : s) {
        uint64_t d;
        if (c >= '0' && c <= '9') { d = (uint64_t) (c - '0'); }
        else if (c >= 'a' && c <= 'f') { d = (uint64_t) (c - 'a' + 10); }
        else if (c >= 'A' && c <= 'F') { d = (uint64_t) (c - 'A' + 10); }
        else { return false; }
        v = (v << 4) | d;
    }
    out = v;
    return true;
}

static std::string dir_of(const std::string & path) {
    const size_t pos = path.find_last_of('/');
    if (pos == std::string::npos) {
        return ".";
    }
    if (pos == 0) {
        return "/";
    }
    return path.substr(0, pos);
}

const expert_record * validated_manifest::record_for(uint32_t layer, family f, uint32_t expert) const {
    if (layer >= mf.total_layer_count || expert >= mf.n_expert) {
        return nullptr;
    }
    const size_t idx = ((size_t) layer * FAMILY_COUNT + (size_t) f) * mf.n_expert + expert;
    if (idx >= record_index.size()) {
        return nullptr;
    }
    const int64_t r = record_index[idx];
    if (r < 0) {
        return nullptr;
    }
    return &mf.records[(size_t) r];
}

const family_geometry * validated_manifest::geometry_for(uint32_t layer, family f) const {
    if (layer >= geometry.size()) {
        return nullptr;
    }
    const family_geometry & g = geometry[layer][(size_t) f];
    return g.present ? &g : nullptr;
}

bool validated_manifest::layer_is_paged(uint32_t layer) const {
    if (layer >= geometry.size()) {
        return false;
    }
    for (int f = 0; f < FAMILY_COUNT; ++f) {
        if (geometry[layer][f].present) {
            return true;
        }
    }
    return false;
}

static bool fail(std::string & err, const std::string & msg) {
    err = msg;
    return false;
}

bool parse_and_validate(const std::string & manifest_path,
                        validated_manifest & out,
                        std::string & err) {
    out = validated_manifest();
    out.dir = dir_of(manifest_path);

    FILE * f = fopen(manifest_path.c_str(), "rb");
    if (!f) {
        return fail(err, "manifest open failed: " + std::string(strerror(errno)));
    }
    std::string text;
    {
        fseek(f, 0, SEEK_END);
        const long sz = ftell(f);
        if (sz < 0 || (uint64_t) sz > MAX_MANIFEST_BYTES) {
            fclose(f);
            return fail(err, "manifest size out of range");
        }
        fseek(f, 0, SEEK_SET);
        text.resize((size_t) sz);
        const size_t got = sz > 0 ? fread(&text[0], 1, (size_t) sz, f) : 0;
        fclose(f);
        if (got != (size_t) sz) {
            return fail(err, "manifest short read");
        }
    }

    json j;
    try {
        j = json::parse(text);
    } catch (const std::exception & e) {
        return fail(err, std::string("manifest JSON parse failed: ") + e.what());
    }

    manifest & mf = out.mf;
    try {
        mf.format_version = j.at("formatVersion").get<int32_t>();
        if (mf.format_version != 1) {
            return fail(err, "unsupported manifest formatVersion");
        }

        const json & model = j.at("model");
        mf.architecture      = model.at("architecture").get<std::string>();
        mf.n_expert          = model.at("expertCount").get<uint32_t>();
        mf.n_expert_used     = model.at("expertsUsedDefault").get<uint32_t>();
        mf.moe_layer_count   = model.at("moeLayerCount").get<uint32_t>();
        mf.total_layer_count = model.at("totalLayerCount").get<uint32_t>();
        mf.fused_gate_up     = model.value("fusedGateUp", false);

        mf.alignment = j.at("alignment").get<uint64_t>();

        const json & resident = j.at("resident");
        mf.resident_path       = resident.at("path").get<std::string>();
        mf.resident_size_bytes = resident.at("sizeBytes").get<uint64_t>();

        mf.fingerprint = j.at("fingerprint").get<std::string>();

        for (const json & jf : j.at("expertFiles")) {
            payload_file pf;
            pf.path       = jf.at("path").get<std::string>();
            pf.size_bytes = jf.at("sizeBytes").get<uint64_t>();
            pf.sha256     = jf.value("sha256", std::string());
            mf.expert_files.push_back(std::move(pf));
        }

        for (const json & jr : j.at("records")) {
            expert_record r;
            r.layer  = jr.at("layer").get<uint32_t>();
            r.expert = jr.at("expert").get<uint32_t>();
            std::string fam = jr.at("family").get<std::string>();
            if (!family_from_name(fam, r.fam)) {
                return fail(err, "record has unknown family '" + fam + "'");
            }
            r.file   = jr.at("file").get<uint32_t>();
            r.offset = jr.at("offset").get<uint64_t>();
            r.length = jr.at("length").get<uint64_t>();
            const std::string hex = jr.at("xxh64").get<std::string>();
            if (!parse_hex_u64(hex, r.xxh64)) {
                return fail(err, "record has malformed xxh64 checksum");
            }
            r.ggml_type = jr.at("ggmlType").get<int32_t>();
            const json & ne = jr.at("ne");
            if (!ne.is_array() || ne.size() != 2) {
                return fail(err, "record ne must be a 2-element array");
            }
            r.ne0 = ne.at(0).get<int64_t>();
            r.ne1 = ne.at(1).get<int64_t>();
            mf.records.push_back(r);
        }
    } catch (const std::exception & e) {
        return fail(err, std::string("manifest field error: ") + e.what());
    }

    // --- structural validation, all fail-closed ---

    bool arch_ok = false;
    for (const char * a : ARCH_WHITELIST) {
        if (mf.architecture == a) {
            arch_ok = true;
            break;
        }
    }
    if (!arch_ok) {
        return fail(err, "architecture '" + mf.architecture + "' is not paged-whitelisted");
    }

    if (mf.n_expert == 0 || mf.n_expert > MAX_EXPERTS) {
        return fail(err, "expertCount out of range");
    }
    if (mf.n_expert_used == 0 || mf.n_expert_used > mf.n_expert) {
        return fail(err, "expertsUsedDefault out of range");
    }
    if (mf.total_layer_count == 0 || mf.total_layer_count > MAX_LAYERS) {
        return fail(err, "totalLayerCount out of range");
    }
    if (mf.moe_layer_count == 0 || mf.moe_layer_count > mf.total_layer_count) {
        return fail(err, "moeLayerCount out of range");
    }
    if (mf.alignment < MIN_ALIGNMENT || mf.alignment > MAX_ALIGNMENT ||
        (mf.alignment & (mf.alignment - 1)) != 0) {
        return fail(err, "alignment must be a power of two in range");
    }
    if (!is_safe_flat_name(mf.resident_path)) {
        return fail(err, "resident path is not a safe flat file name");
    }
    if (mf.fingerprint.empty() || mf.fingerprint.size() > 128) {
        return fail(err, "fingerprint missing or malformed");
    }
    if (mf.expert_files.empty() || mf.expert_files.size() > MAX_PAYLOAD_FILES) {
        return fail(err, "expertFiles count out of range");
    }
    {
        std::set<std::string> names;
        names.insert(mf.resident_path);
        names.insert("manifest.json");
        for (const payload_file & pf : mf.expert_files) {
            if (!is_safe_flat_name(pf.path)) {
                return fail(err, "expert file path is not a safe flat file name");
            }
            if (pf.size_bytes == 0) {
                return fail(err, "expert file '" + pf.path + "' declares zero size");
            }
            if (!names.insert(pf.path).second) {
                return fail(err, "duplicate file name '" + pf.path + "' in package");
            }
        }
    }

    const size_t expected_per_family = (size_t) mf.moe_layer_count * mf.n_expert;
    if (mf.records.empty() || mf.records.size() > expected_per_family * 3) {
        return fail(err, "records count out of range for declared geometry");
    }

    out.geometry.assign(mf.total_layer_count, std::vector<family_geometry>(FAMILY_COUNT));
    out.record_index.assign((size_t) mf.total_layer_count * FAMILY_COUNT * mf.n_expert, -1);

    for (size_t i = 0; i < mf.records.size(); ++i) {
        const expert_record & r = mf.records[i];
        if (r.layer >= mf.total_layer_count) {
            return fail(err, "record layer index out of range");
        }
        if (r.expert >= mf.n_expert) {
            return fail(err, "record expert index out of range");
        }
        if (r.file >= mf.expert_files.size()) {
            return fail(err, "record file index out of range");
        }
        const payload_file & pf = mf.expert_files[r.file];
        if (r.length == 0) {
            return fail(err, "record has zero length");
        }
        if (r.offset % mf.alignment != 0) {
            return fail(err, "record offset violates package alignment");
        }
        if (r.offset > pf.size_bytes || r.length > pf.size_bytes - r.offset) {
            return fail(err, "record range exceeds payload file bounds");
        }
        if (r.ggml_type < 0 || r.ggml_type >= GGML_TYPE_COUNT) {
            return fail(err, "record ggml type out of range");
        }
        const ggml_type t = (ggml_type) r.ggml_type;
        const int64_t blck = ggml_blck_size(t);
        if (r.ne0 <= 0 || r.ne1 <= 0 || blck <= 0 || (r.ne0 % blck) != 0) {
            return fail(err, "record dimensions incompatible with quant block size");
        }
        const uint64_t row_bytes = (uint64_t) ggml_row_size(t, r.ne0);
        if (row_bytes == 0 || r.ne1 > (int64_t) (UINT64_MAX / row_bytes)) {
            return fail(err, "record byte size overflows");
        }
        if (r.length != row_bytes * (uint64_t) r.ne1) {
            return fail(err, "record length disagrees with quant geometry");
        }

        family_geometry & g = out.geometry[r.layer][(size_t) r.fam];
        if (!g.present) {
            g.present       = true;
            g.ggml_type     = r.ggml_type;
            g.ne0           = r.ne0;
            g.ne1           = r.ne1;
            g.record_length = r.length;
        } else if (g.ggml_type != r.ggml_type || g.ne0 != r.ne0 || g.ne1 != r.ne1 ||
                   g.record_length != r.length) {
            return fail(err, "records are not uniform within a layer family");
        }

        const size_t idx = ((size_t) r.layer * FAMILY_COUNT + (size_t) r.fam) * mf.n_expert + r.expert;
        if (out.record_index[idx] != -1) {
            return fail(err, "duplicate record for layer/family/expert");
        }
        out.record_index[idx] = (int64_t) i;
    }

    // Overlap detection within each payload file.
    {
        std::vector<std::vector<std::pair<uint64_t, uint64_t>>> ranges(mf.expert_files.size());
        for (const expert_record & r : mf.records) {
            ranges[r.file].emplace_back(r.offset, r.length);
        }
        for (auto & v : ranges) {
            std::sort(v.begin(), v.end());
            for (size_t i = 1; i < v.size(); ++i) {
                if (v[i].first < v[i - 1].first + v[i - 1].second) {
                    return fail(err, "records overlap inside a payload file");
                }
            }
        }
    }

    // Per-layer family-set and coverage validation.
    uint32_t paged_layers = 0;
    for (uint32_t layer = 0; layer < mf.total_layer_count; ++layer) {
        const bool has_gate    = out.geometry[layer][(size_t) family::gate].present;
        const bool has_up      = out.geometry[layer][(size_t) family::up].present;
        const bool has_down    = out.geometry[layer][(size_t) family::down].present;
        const bool has_gate_up = out.geometry[layer][(size_t) family::gate_up].present;

        if (!has_gate && !has_up && !has_down && !has_gate_up) {
            continue; // non-MoE layer
        }
        paged_layers++;

        const bool separate = has_gate && has_up && has_down && !has_gate_up;
        const bool fused    = has_gate_up && has_down && !has_gate && !has_up;
        if (!separate && !fused) {
            return fail(err, "layer has inconsistent expert family set");
        }
        if (fused != mf.fused_gate_up) {
            return fail(err, "fusedGateUp flag disagrees with record families");
        }

        for (int fi = 0; fi < FAMILY_COUNT; ++fi) {
            if (!out.geometry[layer][fi].present) {
                continue;
            }
            for (uint32_t e = 0; e < mf.n_expert; ++e) {
                const size_t idx = ((size_t) layer * FAMILY_COUNT + fi) * mf.n_expert + e;
                if (out.record_index[idx] < 0) {
                    return fail(err, "missing expert record in a covered layer family");
                }
            }
        }
    }
    if (paged_layers != mf.moe_layer_count) {
        return fail(err, "moeLayerCount disagrees with layers present in records");
    }

    return true;
}

} // namespace noema_paged
