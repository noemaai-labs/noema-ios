// Output must remain byte-compatible with scripts/make_paged_package.py.
// Tensor payloads stream from source files without materializing tensor memory.

#include "noema_paged_convert.h"

#include "ggml.h"
#include "gguf.h"
#include "noema_llama_server.h"
#include "noema_paged_xxh64.h"

#include <nlohmann/json.hpp>

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <map>
#include <memory>
#include <regex>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>

static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
              "the paged converter assumes a little-endian host");

namespace noema_paged {
namespace {

using json = nlohmann::ordered_json;

constexpr const char * TOOL_NAME               = "noema_paged_convert";
constexpr const char * TOOL_VERSION            = "1";
constexpr int          NATIVE_CONTRACT_VERSION = NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION;
constexpr int          FORMAT_VERSION          = 1;
constexpr int64_t      DEFAULT_ALIGNMENT       = 16384;
constexpr uint64_t     MAX_PAYLOAD_FILE_BYTES  = 16ull * 1024 * 1024 * 1024; // 16 GiB
constexpr size_t       COPY_CHUNK              = 8 * 1024 * 1024;
constexpr size_t       HASH_CHUNK              = 1024 * 1024;

const char * const FAMILY_ORDER[4] = { "gate", "up", "down", "gate_up" };

// Same expressions as the Python converter; std::regex ECMAScript alternation
// is leftmost-first like Python's re, so gate_up wins over gate.
const std::regex EXPERT_RE("^blk\\.([0-9]+)\\.ffn_(gate_up|gate|up|down)_exps\\.weight$");
// Per-expert `.scale` vectors stay in resident.gguf and the graph gathers
// them with real expert ids. Only the large weight tensors use slot ids.
const std::regex FORBIDDEN_RE("^blk\\.[0-9]+\\.ffn_.*_exps\\.(input_scale|bias)$");
const std::regex SPLIT_SHARD_RE("^(.+)-([0-9]{5})-of-([0-9]{5})\\.gguf$");
const char * const SPLIT_KV_KEYS[3] = { "split.no", "split.count", "split.tensors.count" };

struct convert_error {
    std::string message;
    explicit convert_error(std::string m) : message(std::move(m)) {}
};

struct cancelled_error {};

[[noreturn]] void fail(const std::string & msg) {
    throw convert_error(msg);
}

uint64_t align_up(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) / alignment * alignment;
}

std::string base_name(const std::string & path) {
    const size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string dir_name(const std::string & path) {
    const size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) {
        return ".";
    }
    if (slash == 0) {
        return "/";
    }
    return path.substr(0, slash);
}

bool is_regular_file(const std::string & path, uint64_t * size_out = nullptr) {
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
        return false;
    }
    if (size_out != nullptr) {
        *size_out = uint64_t(st.st_size);
    }
    return true;
}

bool path_exists(const std::string & path) {
    struct stat st {};
    return ::lstat(path.c_str(), &st) == 0;
}

void make_directories(const std::string & path) {
    std::string partial;
    size_t pos = 0;
    while (pos < path.size()) {
        size_t next = path.find('/', pos);
        if (next == std::string::npos) {
            next = path.size();
        }
        partial = path.substr(0, next);
        pos = next + 1;
        if (partial.empty()) {
            continue;
        }
        if (::mkdir(partial.c_str(), 0755) != 0 && errno != EEXIST) {
            fail("cannot create directory " + partial + ": " + std::strerror(errno));
        }
    }
}

// Removes the flat staging directory (only regular files are ever created in
// it). Best-effort: the caller is already failing or cancelling.
void remove_staging_directory(const std::string & dir) {
    DIR * handle = ::opendir(dir.c_str());
    if (handle != nullptr) {
        while (const dirent * entry = ::readdir(handle)) {
            const std::string name = entry->d_name;
            if (name == "." || name == "..") {
                continue;
            }
            ::unlink((dir + "/" + name).c_str());
        }
        ::closedir(handle);
    }
    ::rmdir(dir.c_str());
}

std::string hex_lower(const unsigned char * bytes, size_t count) {
    static const char * digits = "0123456789abcdef";
    std::string out(count * 2, '0');
    for (size_t i = 0; i < count; ++i) {
        out[i * 2]     = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 0xF];
    }
    return out;
}

std::string xxh64_hex(const void * data, size_t length) {
    const uint64_t digest = noema_xxh64(data, length, 0);
    char buf[17];
    snprintf(buf, sizeof(buf), "%016" PRIx64, digest);
    return std::string(buf);
}

struct sha256_stream {
    CC_SHA256_CTX ctx;
    sha256_stream() { CC_SHA256_Init(&ctx); }
    void update(const void * data, size_t length) {
        const uint8_t * p = static_cast<const uint8_t *>(data);
        while (length > 0) {
            const size_t chunk = std::min<size_t>(length, 1u << 30);
            CC_SHA256_Update(&ctx, p, CC_LONG(chunk));
            p += chunk;
            length -= chunk;
        }
    }
    std::string finish() {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &ctx);
        return hex_lower(digest, sizeof(digest));
    }
};

std::string sha256_of_string(const std::string & value) {
    sha256_stream h;
    h.update(value.data(), value.size());
    return h.finish();
}


struct progress_tracker {
    const convert_progress_fn & cb;
    const char * stage = "preparing";
    float base = 0.0f;
    float span = 0.0f;
    uint64_t done = 0;
    uint64_t total = 1;

    explicit progress_tracker(const convert_progress_fn & cb) : cb(cb) {}

    void begin_stage(const char * name, float stage_base, float stage_span, uint64_t stage_total) {
        stage = name;
        base  = stage_base;
        span  = stage_span;
        done  = 0;
        total = std::max<uint64_t>(1, stage_total);
        report();
    }

    void add(uint64_t bytes) {
        done = std::min(total, done + bytes);
        report();
    }

    void report() {
        if (!cb) {
            return;
        }
        // Clamped to stay monotonic across stage boundaries despite float
        // rounding in base + span sums.
        const float fraction = base + span * (float(done) / float(total));
        last_reported = std::min(1.0f, std::max(last_reported, fraction));
        if (cb(last_reported, stage) != 0) {
            throw cancelled_error{};
        }
    }

private:
    float last_reported = 0.0f;
};


struct file_handle {
    FILE * f = nullptr;
    ~file_handle() { close(); }
    void close() {
        if (f != nullptr) {
            fclose(f);
            f = nullptr;
        }
    }
};

void read_exact(FILE * f, uint64_t offset, void * dst, size_t length, const std::string & what) {
    if (fseeko(f, off_t(offset), SEEK_SET) != 0) {
        fail("seek failed while reading " + what);
    }
    if (length > 0 && fread(dst, 1, length, f) != length) {
        fail("short read while reading " + what);
    }
}

struct file_writer {
    FILE * f = nullptr;
    uint64_t written = 0;
    std::string path;

    void open(const std::string & p) {
        path = p;
        written = 0;
        f = fopen(p.c_str(), "wb");
        if (f == nullptr) {
            fail("cannot open " + p + " for writing: " + std::strerror(errno));
        }
    }
    void close() {
        if (f != nullptr) {
            const bool flush_ok = fflush(f) == 0 && ferror(f) == 0;
            fclose(f);
            f = nullptr;
            if (!flush_ok) {
                fail("write failed for " + path);
            }
        }
    }
    ~file_writer() {
        if (f != nullptr) {
            fclose(f);
        }
    }
    void bytes(const void * data, size_t length) {
        if (length > 0 && fwrite(data, 1, length, f) != length) {
            fail("write failed for " + path);
        }
        written += length;
    }
    template <typename T>
    void pod(const T & value) {
        bytes(&value, sizeof(value));
    }
    void u8(uint8_t v)   { pod(v); }
    void u32(uint32_t v) { pod(v); }
    void u64(uint64_t v) { pod(v); }
    void str(const char * data, size_t length) {
        u64(uint64_t(length));
        bytes(data, length);
    }
    void str(const std::string & s) { str(s.data(), s.size()); }
    void zeros(uint64_t count) {
        static const char zero[4096] = {};
        while (count > 0) {
            const size_t chunk = size_t(std::min<uint64_t>(count, sizeof(zero)));
            bytes(zero, chunk);
            count -= chunk;
        }
    }
    void pad_to(uint64_t alignment) {
        const uint64_t target = align_up(written, alignment);
        zeros(target - written);
    }
};

// Declared-dimension sidecar scan
//
// gguf-py preserves each tensor's declared dimension count and echoes it into
// resident.gguf; the vendored C reader pads ne to GGML_MAX_DIMS and loses the
// original count. This scan re-reads only the source header to recover it.

struct header_scanner {
    FILE * f;
    const std::string & path;

    void read(void * dst, size_t length) {
        if (length > 0 && fread(dst, 1, length, f) != length) {
            fail("header scan: short read in " + path);
        }
    }
    template <typename T>
    T pod() {
        T value {};
        read(&value, sizeof(value));
        return value;
    }
    void skip(uint64_t length) {
        if (length > 0 && fseeko(f, off_t(length), SEEK_CUR) != 0) {
            fail("header scan: seek failed in " + path);
        }
    }
    std::string str(uint64_t max_length) {
        const uint64_t length = pod<uint64_t>();
        if (length > max_length) {
            fail("header scan: unreasonable string length in " + path);
        }
        std::string out(size_t(length), '\0');
        read(out.data(), size_t(length));
        return out;
    }
    void skip_str() {
        const uint64_t length = pod<uint64_t>();
        skip(length);
    }
};

size_t gguf_scalar_type_size(uint32_t type) {
    switch (type) {
        case GGUF_TYPE_UINT8:
        case GGUF_TYPE_INT8:
        case GGUF_TYPE_BOOL:    return 1;
        case GGUF_TYPE_UINT16:
        case GGUF_TYPE_INT16:   return 2;
        case GGUF_TYPE_UINT32:
        case GGUF_TYPE_INT32:
        case GGUF_TYPE_FLOAT32: return 4;
        case GGUF_TYPE_UINT64:
        case GGUF_TYPE_INT64:
        case GGUF_TYPE_FLOAT64: return 8;
        default:                return 0;
    }
}

std::unordered_map<std::string, std::vector<int64_t>> scan_declared_dims(const std::string & path) {
    file_handle fh;
    fh.f = fopen(path.c_str(), "rb");
    if (fh.f == nullptr) {
        fail("cannot open " + path + ": " + std::strerror(errno));
    }
    header_scanner scan { fh.f, path };

    char magic[4];
    scan.read(magic, sizeof(magic));
    if (std::memcmp(magic, "GGUF", 4) != 0) {
        fail("header scan: " + path + " is not a GGUF file");
    }
    const uint32_t version = scan.pod<uint32_t>();
    if (version < 2 || version > 3) {
        fail("header scan: unsupported GGUF version in " + path);
    }
    const int64_t n_tensors = scan.pod<int64_t>();
    const int64_t n_kv      = scan.pod<int64_t>();
    if (n_tensors < 0 || n_kv < 0) {
        fail("header scan: negative counts in " + path);
    }

    for (int64_t i = 0; i < n_kv; ++i) {
        scan.skip_str(); // key
        const uint32_t type = scan.pod<uint32_t>();
        if (type == GGUF_TYPE_ARRAY) {
            const uint32_t sub = scan.pod<uint32_t>();
            const uint64_t count = scan.pod<uint64_t>();
            if (sub == GGUF_TYPE_STRING) {
                for (uint64_t j = 0; j < count; ++j) {
                    scan.skip_str();
                }
            } else if (const size_t size = gguf_scalar_type_size(sub)) {
                scan.skip(count * size);
            } else {
                fail("header scan: unsupported array element type in " + path);
            }
        } else if (type == GGUF_TYPE_STRING) {
            scan.skip_str();
        } else if (const size_t size = gguf_scalar_type_size(type)) {
            scan.skip(size);
        } else {
            fail("header scan: unsupported KV type in " + path);
        }
    }

    std::unordered_map<std::string, std::vector<int64_t>> dims_by_name;
    dims_by_name.reserve(size_t(n_tensors));
    for (int64_t i = 0; i < n_tensors; ++i) {
        std::string name = scan.str(4096);
        const uint32_t n_dims = scan.pod<uint32_t>();
        if (n_dims > GGML_MAX_DIMS) {
            fail("header scan: tensor " + name + " has too many dimensions");
        }
        std::vector<int64_t> dims(n_dims);
        for (uint32_t j = 0; j < n_dims; ++j) {
            dims[j] = scan.pod<int64_t>();
        }
        scan.pod<uint32_t>(); // type
        scan.pod<uint64_t>(); // offset
        dims_by_name.emplace(std::move(name), std::move(dims));
    }
    return dims_by_name;
}


struct shard_source {
    std::string path;
    uint64_t file_size = 0;
    gguf_context * ctx = nullptr;
    FILE * data_file = nullptr;
    uint64_t data_offset = 0;
    std::unordered_map<std::string, std::vector<int64_t>> declared_dims;

    ~shard_source() {
        if (ctx != nullptr) {
            gguf_free(ctx);
        }
        if (data_file != nullptr) {
            fclose(data_file);
        }
    }
    shard_source() = default;
    shard_source(const shard_source &) = delete;
    shard_source & operator=(const shard_source &) = delete;
};

struct src_tensor {
    std::string name;
    shard_source * shard = nullptr;
    std::vector<int64_t> dims;   // declared ne, ne0 first
    int32_t type = -1;
    uint64_t nbytes = 0;
    uint64_t abs_offset = 0;     // absolute file offset of the tensor payload
};

// Ordered shard paths for the input: a plain GGUF maps to itself; the first
// shard of NAME-00001-of-0000N.gguf expands to every sibling.
std::vector<std::string> resolve_input_shards(const std::string & input_path) {
    const std::string name = base_name(input_path);
    std::smatch m;
    if (!std::regex_match(name, m, SPLIT_SHARD_RE)) {
        return { input_path };
    }
    const long no    = std::strtol(m[2].str().c_str(), nullptr, 10);
    const long count = std::strtol(m[3].str().c_str(), nullptr, 10);
    if (no != 1) {
        fail("pass the first shard of the split (…-00001-of-" + m[3].str() + ".gguf), not " + name);
    }
    if (count < 1) {
        fail("invalid shard count in " + name);
    }
    const std::string dir = dir_name(input_path);
    std::vector<std::string> shards;
    shards.reserve(size_t(count));
    for (long i = 1; i <= count; ++i) {
        char suffix[32];
        snprintf(suffix, sizeof(suffix), "-%05ld-of-%05ld.gguf", i, count);
        const std::string shard = dir + "/" + m[1].str() + suffix;
        if (!is_regular_file(shard)) {
            fail("missing split shard: " + shard);
        }
        shards.push_back(shard);
    }
    return shards;
}

int64_t require_kv_index(const gguf_context * ctx, const std::string & key) {
    const int64_t idx = gguf_find_key(ctx, key.c_str());
    if (idx < 0) {
        fail("input GGUF is missing required KV '" + key + "'");
    }
    return idx;
}

int64_t kv_int(const gguf_context * ctx, const std::string & key) {
    const int64_t idx = require_kv_index(ctx, key);
    switch (gguf_get_kv_type(ctx, idx)) {
        case GGUF_TYPE_UINT8:  return gguf_get_val_u8(ctx, idx);
        case GGUF_TYPE_INT8:   return gguf_get_val_i8(ctx, idx);
        case GGUF_TYPE_UINT16: return gguf_get_val_u16(ctx, idx);
        case GGUF_TYPE_INT16:  return gguf_get_val_i16(ctx, idx);
        case GGUF_TYPE_UINT32: return gguf_get_val_u32(ctx, idx);
        case GGUF_TYPE_INT32:  return gguf_get_val_i32(ctx, idx);
        case GGUF_TYPE_UINT64: return int64_t(gguf_get_val_u64(ctx, idx));
        case GGUF_TYPE_INT64:  return gguf_get_val_i64(ctx, idx);
        default:
            fail("KV '" + key + "' is not an integer");
    }
}

// Resident writer (byte-exact gguf-py GGUFWriter mirror)

void write_kv_value(file_writer & out, const gguf_context * ctx, int64_t idx) {
    const gguf_type type = gguf_get_kv_type(ctx, idx);
    if (type == GGUF_TYPE_ARRAY) {
        const gguf_type sub = gguf_get_arr_type(ctx, idx);
        const uint64_t count = gguf_get_arr_n(ctx, idx);
        if (count == 0) {
            // gguf-py's _pack_val raises on empty arrays; refuse cleanly.
            fail(std::string("KV '") + gguf_get_key(ctx, idx) + "' is an empty array and cannot be copied");
        }
        out.u32(uint32_t(GGUF_TYPE_ARRAY));
        out.u32(uint32_t(sub));
        out.u64(count);
        if (sub == GGUF_TYPE_STRING) {
            for (uint64_t i = 0; i < count; ++i) {
                const char * element = gguf_get_arr_str(ctx, idx, size_t(i));
                out.str(element, std::strlen(element));
            }
        } else if (sub == GGUF_TYPE_BOOL) {
            const int8_t * raw = static_cast<const int8_t *>(gguf_get_arr_data(ctx, idx));
            for (uint64_t i = 0; i < count; ++i) {
                out.u8(raw[i] != 0 ? 1 : 0);
            }
        } else if (const size_t size = gguf_scalar_type_size(uint32_t(sub))) {
            out.bytes(gguf_get_arr_data(ctx, idx), size_t(count) * size);
        } else {
            fail(std::string("KV '") + gguf_get_key(ctx, idx) + "' has an unsupported array element type");
        }
        return;
    }

    out.u32(uint32_t(type));
    if (type == GGUF_TYPE_STRING) {
        const char * value = gguf_get_val_str(ctx, idx);
        out.str(value, std::strlen(value));
    } else if (type == GGUF_TYPE_BOOL) {
        out.u8(gguf_get_val_bool(ctx, idx) ? 1 : 0);
    } else if (const size_t size = gguf_scalar_type_size(uint32_t(type))) {
        out.bytes(gguf_get_val_data(ctx, idx), size);
    } else {
        fail(std::string("KV '") + gguf_get_key(ctx, idx) + "' has an unsupported type");
    }
}

void write_resident(const shard_source & primary,
                    const std::string & arch,
                    const std::vector<src_tensor> & tensors,
                    const std::string & path,
                    uint64_t data_alignment,
                    progress_tracker & progress) {
    const gguf_context * ctx = primary.ctx;

    // KV plan: architecture first, then every source KV in order minus the
    // architecture itself and the split.* bookkeeping keys.
    std::vector<int64_t> copied;
    const int64_t n_kv = gguf_get_n_kv(ctx);
    for (int64_t i = 0; i < n_kv; ++i) {
        const char * key = gguf_get_key(ctx, i);
        if (std::strcmp(key, "general.architecture") == 0) {
            continue;
        }
        bool is_split_key = false;
        for (const char * split_key : SPLIT_KV_KEYS) {
            if (std::strcmp(key, split_key) == 0) {
                is_split_key = true;
                break;
            }
        }
        if (is_split_key) {
            continue;
        }
        copied.push_back(i);
    }

    file_writer out;
    out.open(path);
    out.bytes("GGUF", 4);
    out.u32(3); // GGUF_VERSION, as written by gguf-py
    out.u64(uint64_t(tensors.size()));
    out.u64(uint64_t(copied.size() + 1));

    out.str("general.architecture", std::strlen("general.architecture"));
    out.u32(uint32_t(GGUF_TYPE_STRING));
    out.str(arch);
    for (const int64_t idx : copied) {
        const char * key = gguf_get_key(ctx, idx);
        out.str(key, std::strlen(key));
        write_kv_value(out, ctx, idx);
    }

    // Tensor infos: declared dims echoed ne0-first, offsets cumulative and
    // aligned to the data alignment.
    uint64_t offset = 0;
    for (const src_tensor & tensor : tensors) {
        out.str(tensor.name);
        out.u32(uint32_t(tensor.dims.size()));
        for (const int64_t dim : tensor.dims) {
            out.u64(uint64_t(dim));
        }
        out.u32(uint32_t(tensor.type));
        out.u64(offset);
        offset += align_up(tensor.nbytes, data_alignment);
    }

    out.pad_to(data_alignment);

    std::vector<uint8_t> buffer(COPY_CHUNK);
    for (const src_tensor & tensor : tensors) {
        uint64_t remaining = tensor.nbytes;
        uint64_t cursor = tensor.abs_offset;
        while (remaining > 0) {
            const size_t chunk = size_t(std::min<uint64_t>(remaining, buffer.size()));
            read_exact(tensor.shard->data_file, cursor, buffer.data(), chunk, "tensor " + tensor.name);
            out.bytes(buffer.data(), chunk);
            cursor += chunk;
            remaining -= chunk;
            progress.add(chunk);
        }
        out.pad_to(data_alignment);
    }
    out.close();
}

// Payload writer (mirrors the Python PayloadWriter exactly)

struct payload_writer {
    std::string build_dir;
    uint64_t alignment = 0;
    std::vector<std::string> paths; // flat file names
    file_writer out;

    payload_writer(std::string dir, uint64_t align) : build_dir(std::move(dir)), alignment(align) {
        open_next();
    }

    void open_next() {
        out.close();
        char name[32];
        snprintf(name, sizeof(name), "experts-%03zu.bin", paths.size());
        paths.emplace_back(name);
        out.open(build_dir + "/" + name);
    }

    // Appends one aligned record; returns (file_index, offset).
    std::pair<uint32_t, uint64_t> append(const uint8_t * data, uint64_t length) {
        const uint64_t pos = out.written;
        uint64_t padded = align_up(pos, alignment);
        if (padded + length > MAX_PAYLOAD_FILE_BYTES && pos > 0) {
            open_next();
            padded = 0;
        }
        if (padded > out.written) {
            out.zeros(padded - out.written);
        }
        out.bytes(data, size_t(length));
        return { uint32_t(paths.size() - 1), padded };
    }

    void close() { out.close(); }
};

struct expert_record {
    uint32_t layer = 0;
    const char * family = nullptr;
    uint32_t expert = 0;
    uint32_t file = 0;
    uint64_t offset = 0;
    uint64_t length = 0;
    std::string xxh64;
    int32_t ggml_type = -1;
    int64_t ne0 = 0;
    int64_t ne1 = 0;
};


std::string sha256_of_file(const std::string & path, progress_tracker * progress) {
    file_handle fh;
    fh.f = fopen(path.c_str(), "rb");
    if (fh.f == nullptr) {
        fail("cannot open " + path + " for hashing: " + std::strerror(errno));
    }
    sha256_stream hash;
    std::vector<uint8_t> buffer(HASH_CHUNK);
    size_t n = 0;
    while ((n = fread(buffer.data(), 1, buffer.size(), fh.f)) > 0) {
        hash.update(buffer.data(), n);
        if (progress != nullptr) {
            progress->add(n);
        }
    }
    if (ferror(fh.f)) {
        fail("read failed while hashing " + path);
    }
    return hash.finish();
}

void run_conversion(const std::string & src_gguf_path,
                    const std::string & dst_package_dir,
                    int64_t alignment,
                    progress_tracker & progress,
                    std::string & staging_dir_out) {
    progress.begin_stage("preparing", 0.0f, 0.02f, 1);

    if (!is_regular_file(src_gguf_path)) {
        fail("input not found: " + src_gguf_path);
    }
    if (alignment <= 0) {
        alignment = DEFAULT_ALIGNMENT;
    }

    const std::vector<std::string> shard_paths = resolve_input_shards(src_gguf_path);
    std::vector<std::unique_ptr<shard_source>> shards;
    for (const std::string & path : shard_paths) {
        auto shard = std::make_unique<shard_source>();
        shard->path = path;
        if (!is_regular_file(path, &shard->file_size)) {
            fail("input not found: " + path);
        }
        gguf_init_params params = { /*no_alloc =*/ true, /*ctx =*/ nullptr };
        shard->ctx = gguf_init_from_file(path.c_str(), params);
        if (shard->ctx == nullptr) {
            fail("cannot parse GGUF: " + path);
        }
        shard->data_file = fopen(path.c_str(), "rb");
        if (shard->data_file == nullptr) {
            fail("cannot open " + path + ": " + std::strerror(errno));
        }
        shard->data_offset = gguf_get_data_offset(shard->ctx);
        shard->declared_dims = scan_declared_dims(path);
        shards.push_back(std::move(shard));
    }
    shard_source & primary = *shards[0];

    const int64_t arch_idx = gguf_find_key(primary.ctx, "general.architecture");
    if (arch_idx < 0) {
        fail("input GGUF has no general.architecture");
    }
    if (gguf_get_kv_type(primary.ctx, arch_idx) != GGUF_TYPE_STRING) {
        fail("general.architecture is not a string");
    }
    const std::string arch = gguf_get_val_str(primary.ctx, arch_idx);
    if (arch != "qwen3moe" && arch != "qwen35moe" && arch != "gemma4") {
        fail("architecture '" + arch + "' is not one of ('qwen3moe', 'qwen35moe', 'gemma4')");
    }

    std::vector<src_tensor> all_tensors;
    std::unordered_set<std::string> seen_names;
    for (size_t shard_index = 0; shard_index < shards.size(); ++shard_index) {
        shard_source & shard = *shards[shard_index];
        const int64_t n_tensors = gguf_get_n_tensors(shard.ctx);
        for (int64_t i = 0; i < n_tensors; ++i) {
            src_tensor tensor;
            tensor.name = gguf_get_tensor_name(shard.ctx, i);
            if (!seen_names.insert(tensor.name).second) {
                fail("tensor '" + tensor.name + "' appears in more than one shard");
            }
            tensor.shard = &shard;
            tensor.type = int32_t(gguf_get_tensor_type(shard.ctx, i));
            tensor.nbytes = gguf_get_tensor_size(shard.ctx, i);
            tensor.abs_offset = shard.data_offset + gguf_get_tensor_offset(shard.ctx, i);

            const auto dims_it = shard.declared_dims.find(tensor.name);
            if (dims_it == shard.declared_dims.end()) {
                fail("header scan disagrees with the GGUF reader for tensor '" + tensor.name + "'");
            }
            tensor.dims = dims_it->second;
            const int64_t * ne = gguf_get_tensor_ne(shard.ctx, i);
            for (int d = 0; d < GGML_MAX_DIMS; ++d) {
                const int64_t declared = d < int(tensor.dims.size()) ? tensor.dims[size_t(d)] : 1;
                if (declared != ne[d]) {
                    fail("header scan disagrees with the GGUF reader for tensor '" + tensor.name + "'");
                }
            }
            all_tensors.push_back(std::move(tensor));
        }
        if (shard_index > 0) {
            const int64_t no_idx = gguf_find_key(shard.ctx, "split.no");
            if (no_idx >= 0 && kv_int(shard.ctx, "split.no") != int64_t(shard_index)) {
                fail(base_name(shard.path) + ": split.no " + std::to_string(kv_int(shard.ctx, "split.no")) +
                     " != expected " + std::to_string(shard_index));
            }
        }
    }

    for (const src_tensor & tensor : all_tensors) {
        if (std::regex_match(tensor.name, FORBIDDEN_RE)) {
            fail("unsupported expert side-tensor present: " + tensor.name);
        }
    }

    const int64_t n_expert      = kv_int(primary.ctx, arch + ".expert_count");
    const int64_t n_expert_used = kv_int(primary.ctx, arch + ".expert_used_count");
    const int64_t block_count   = kv_int(primary.ctx, arch + ".block_count");
    if (n_expert <= 0 || n_expert_used <= 0) {
        fail("expert_count (" + std::to_string(n_expert) + ") and expert_used_count (" +
             std::to_string(n_expert_used) + ") must be > 0");
    }

    std::map<uint32_t, std::map<int, const src_tensor *>> expert_tensors; // layer → family index → tensor
    std::vector<const src_tensor *> non_expert_tensors;
    for (const src_tensor & tensor : all_tensors) {
        std::smatch m;
        if (std::regex_match(tensor.name, m, EXPERT_RE)) {
            const unsigned long long layer = std::strtoull(m[1].str().c_str(), nullptr, 10);
            if (layer > UINT32_MAX) {
                fail(tensor.name + ": layer index out of range");
            }
            int family = -1;
            for (int fam = 0; fam < 4; ++fam) {
                if (m[2].str() == FAMILY_ORDER[fam]) {
                    family = fam;
                    break;
                }
            }
            expert_tensors[uint32_t(layer)][family] = &tensor;
        } else {
            non_expert_tensors.push_back(&tensor);
        }
    }
    if (expert_tensors.empty()) {
        fail("no routed expert tensors (blk.*.ffn_*_exps.weight) found");
    }
    bool fused_gate_up = false;
    for (const auto & [layer, families] : expert_tensors) {
        if (families.count(3) > 0) { // gate_up
            fused_gate_up = true;
            break;
        }
    }

    std::string dst = dst_package_dir;
    while (dst.size() > 1 && dst.back() == '/') {
        dst.pop_back();
    }
    if (path_exists(dst)) {
        fail("output already exists: " + dst);
    }
    const std::string staging = dst + ".building-" + std::to_string(getpid());
    if (path_exists(staging)) {
        fail("stale build directory exists: " + staging);
    }
    make_directories(staging);
    staging_dir_out = staging;

    uint64_t resident_bytes = 0;
    for (const src_tensor * tensor : non_expert_tensors) {
        resident_bytes += tensor->nbytes;
    }
    uint64_t expert_bytes = 0;
    for (const auto & [layer, families] : expert_tensors) {
        for (const auto & [family, tensor] : families) {
            expert_bytes += tensor->nbytes;
        }
    }
    uint64_t source_bytes = 0;
    for (const auto & shard : shards) {
        source_bytes += shard->file_size;
    }

    progress.begin_stage("resident", 0.02f, 0.28f, resident_bytes);
    const std::string resident_path = staging + "/resident.gguf";
    std::vector<src_tensor> resident_tensors;
    resident_tensors.reserve(non_expert_tensors.size());
    for (const src_tensor * tensor : non_expert_tensors) {
        resident_tensors.push_back(*tensor);
    }
    write_resident(primary, arch, resident_tensors, resident_path,
                   gguf_get_alignment(primary.ctx), progress);

    progress.begin_stage("experts", 0.30f, 0.40f, expert_bytes);
    payload_writer payload(staging, uint64_t(alignment));
    std::vector<expert_record> records;
    std::vector<uint8_t> slice;
    for (const auto & [layer, families] : expert_tensors) {
        for (int fam = 0; fam < 4; ++fam) {
            const auto it = families.find(fam);
            if (it == families.end()) {
                continue;
            }
            const src_tensor & tensor = *it->second;
            const std::vector<int64_t> & ne = tensor.dims;
            if (ne.size() != 3) {
                fail(tensor.name + ": expected 3 dims, got " + std::to_string(ne.size()));
            }
            if (ne[2] != n_expert) {
                fail(tensor.name + ": last ne dim " + std::to_string(ne[2]) +
                     " != expert_count " + std::to_string(n_expert));
            }
            if (tensor.nbytes % uint64_t(n_expert) != 0) {
                fail(tensor.name + ": " + std::to_string(tensor.nbytes) +
                     " bytes not divisible by " + std::to_string(n_expert) + " experts");
            }
            const uint64_t per_expert = tensor.nbytes / uint64_t(n_expert);
            const int64_t block_size  = ggml_blck_size(ggml_type(tensor.type));
            const size_t  type_size   = ggml_type_size(ggml_type(tensor.type));
            if (block_size <= 0 || ne[0] % block_size != 0) {
                fail(tensor.name + ": ne0 " + std::to_string(ne[0]) +
                     " not divisible by block size " + std::to_string(block_size));
            }
            const uint64_t row_size = uint64_t(ne[0] / block_size) * type_size;
            if (per_expert != row_size * uint64_t(ne[1])) {
                fail(tensor.name + ": per-expert size " + std::to_string(per_expert) +
                     " != row_size(" + std::to_string(row_size) + ") * ne1(" + std::to_string(ne[1]) + ")");
            }
            slice.resize(size_t(per_expert));
            for (int64_t expert = 0; expert < n_expert; ++expert) {
                read_exact(tensor.shard->data_file,
                           tensor.abs_offset + uint64_t(expert) * per_expert,
                           slice.data(), size_t(per_expert),
                           "tensor " + tensor.name);
                const auto [file_index, offset] = payload.append(slice.data(), per_expert);
                expert_record record;
                record.layer     = layer;
                record.family    = FAMILY_ORDER[fam];
                record.expert    = uint32_t(expert);
                record.file      = file_index;
                record.offset    = offset;
                record.length    = per_expert;
                record.xxh64     = xxh64_hex(slice.data(), size_t(per_expert));
                record.ggml_type = tensor.type;
                record.ne0       = ne[0];
                record.ne1       = ne[1];
                records.push_back(std::move(record));
                progress.add(per_expert);
            }
        }
    }
    payload.close();

    // Bytes hashed here: every source shard, the resident file, and every
    // payload file; then every record is re-read and byte-compared.
    uint64_t resident_file_size = 0;
    if (!is_regular_file(resident_path, &resident_file_size)) {
        fail("staged resident.gguf missing");
    }
    uint64_t payload_total = 0;
    std::vector<uint64_t> payload_sizes;
    for (const std::string & name : payload.paths) {
        uint64_t size = 0;
        if (!is_regular_file(staging + "/" + name, &size)) {
            fail("staged payload file missing: " + name);
        }
        payload_sizes.push_back(size);
        payload_total += size;
    }
    progress.begin_stage("verifying", 0.70f, 0.28f,
                         source_bytes + resident_file_size + payload_total + 2 * expert_bytes);

    sha256_stream source_hash;
    {
        std::vector<uint8_t> buffer(HASH_CHUNK);
        for (const auto & shard : shards) {
            file_handle fh;
            fh.f = fopen(shard->path.c_str(), "rb");
            if (fh.f == nullptr) {
                fail("cannot open " + shard->path + " for hashing: " + std::strerror(errno));
            }
            size_t n = 0;
            while ((n = fread(buffer.data(), 1, buffer.size(), fh.f)) > 0) {
                source_hash.update(buffer.data(), n);
                progress.add(n);
            }
            if (ferror(fh.f)) {
                fail("read failed while hashing " + shard->path);
            }
        }
    }

    const std::string resident_sha = sha256_of_file(resident_path, &progress);
    std::vector<std::string> payload_shas;
    for (const std::string & name : payload.paths) {
        payload_shas.push_back(sha256_of_file(staging + "/" + name, &progress));
    }

    std::string fingerprint_input = resident_sha;
    for (const std::string & sha : payload_shas) {
        fingerprint_input += "\n" + sha;
    }
    const std::string fingerprint = sha256_of_string(fingerprint_input);

    json manifest;
    manifest["formatVersion"] = FORMAT_VERSION;
    {
        json created_by;
        created_by["tool"] = TOOL_NAME;
        created_by["toolVersion"] = TOOL_VERSION;
        created_by["nativeContractVersion"] = NATIVE_CONTRACT_VERSION;
        manifest["createdBy"] = std::move(created_by);
    }
    {
        json source;
        source["fileName"] = base_name(src_gguf_path);
        source["ggufSizeBytes"] = source_bytes;
        source["ggufSha256"] = source_hash.finish();
        manifest["source"] = std::move(source);
    }
    {
        json model;
        model["architecture"] = arch;
        model["expertCount"] = n_expert;
        model["expertsUsedDefault"] = n_expert_used;
        model["moeLayerCount"] = uint64_t(expert_tensors.size());
        model["totalLayerCount"] = block_count;
        model["fusedGateUp"] = fused_gate_up;
        manifest["model"] = std::move(model);
    }
    manifest["alignment"] = alignment;
    {
        json resident;
        resident["path"] = "resident.gguf";
        resident["sizeBytes"] = resident_file_size;
        resident["sha256"] = resident_sha;
        manifest["resident"] = std::move(resident);
    }
    {
        json expert_files = json::array();
        for (size_t i = 0; i < payload.paths.size(); ++i) {
            json entry;
            entry["path"] = payload.paths[i];
            entry["sizeBytes"] = payload_sizes[i];
            entry["sha256"] = payload_shas[i];
            expert_files.push_back(std::move(entry));
        }
        manifest["expertFiles"] = std::move(expert_files);
    }
    {
        json record_array = json::array();
        for (const expert_record & record : records) {
            json entry;
            entry["layer"] = record.layer;
            entry["family"] = record.family;
            entry["expert"] = record.expert;
            entry["file"] = record.file;
            entry["offset"] = record.offset;
            entry["length"] = record.length;
            entry["xxh64"] = record.xxh64;
            entry["ggmlType"] = record.ggml_type;
            entry["ne"] = json::array({ record.ne0, record.ne1 });
            record_array.push_back(std::move(entry));
        }
        manifest["records"] = std::move(record_array);
    }
    if (shards.size() > 1) {
        json shard_names = json::array();
        for (const auto & shard : shards) {
            shard_names.push_back(base_name(shard->path));
        }
        manifest["source"]["shardFileNames"] = std::move(shard_names);
    }
    manifest["fingerprint"] = fingerprint;

    {
        file_writer out;
        out.open(staging + "/manifest.json");
        const std::string text = manifest.dump(2, ' ', true) + "\n";
        out.bytes(text.data(), text.size());
        out.close();
    }

    {
        std::vector<std::unique_ptr<file_handle>> payload_files;
        for (const std::string & name : payload.paths) {
            auto handle = std::make_unique<file_handle>();
            handle->f = fopen((staging + "/" + name).c_str(), "rb");
            if (handle->f == nullptr) {
                fail("verify: cannot reopen " + name);
            }
            payload_files.push_back(std::move(handle));
        }
        std::vector<uint8_t> staged;
        std::vector<uint8_t> original;
        for (const expert_record & record : records) {
            const std::string what = std::string(record.family) + " layer " +
                std::to_string(record.layer) + " expert " + std::to_string(record.expert);
            if (record.offset % uint64_t(alignment) != 0) {
                fail("verify: record offset " + std::to_string(record.offset) + " not aligned");
            }
            staged.resize(size_t(record.length));
            read_exact(payload_files[record.file]->f, record.offset, staged.data(),
                       size_t(record.length), "verify record " + what);
            if (xxh64_hex(staged.data(), staged.size()) != record.xxh64) {
                fail("verify: xxh64 mismatch for record " + what);
            }
            uint32_t layer_key = record.layer;
            int family_index = 0;
            for (int fam = 0; fam < 4; ++fam) {
                if (std::strcmp(record.family, FAMILY_ORDER[fam]) == 0) {
                    family_index = fam;
                    break;
                }
            }
            const src_tensor & tensor = *expert_tensors.at(layer_key).at(family_index);
            original.resize(size_t(record.length));
            read_exact(tensor.shard->data_file,
                       tensor.abs_offset + uint64_t(record.expert) * record.length,
                       original.data(), size_t(record.length), "verify source " + what);
            if (std::memcmp(staged.data(), original.data(), size_t(record.length)) != 0) {
                fail("verify: payload bytes differ from source for record " + what);
            }
            progress.add(2 * record.length);
        }
    }
    {
        // Structural re-read: the staged resident must parse and must not
        // contain any routed expert tensor.
        gguf_init_params params = { /*no_alloc =*/ true, /*ctx =*/ nullptr };
        gguf_context * resident_ctx = gguf_init_from_file(resident_path.c_str(), params);
        if (resident_ctx == nullptr) {
            fail("verify: staged resident.gguf does not parse");
        }
        const int64_t n_tensors = gguf_get_n_tensors(resident_ctx);
        bool leaked = false;
        std::string leaked_name;
        for (int64_t i = 0; i < n_tensors && !leaked; ++i) {
            const std::string name = gguf_get_tensor_name(resident_ctx, i);
            if (std::regex_match(name, EXPERT_RE)) {
                leaked = true;
                leaked_name = name;
            }
        }
        const bool tensor_count_ok = n_tensors == int64_t(non_expert_tensors.size());
        gguf_free(resident_ctx);
        if (leaked) {
            fail("verify: expert tensor " + leaked_name + " leaked into resident.gguf");
        }
        if (!tensor_count_ok) {
            fail("verify: resident.gguf tensor count mismatch");
        }
    }

    progress.begin_stage("finishing", 0.98f, 0.02f, 1);
    if (::rename(staging.c_str(), dst.c_str()) != 0) {
        fail("cannot move package into place: " + std::string(std::strerror(errno)));
    }
    staging_dir_out.clear();
    try {
        progress.add(1);
    } catch (const cancelled_error &) {
        // The package is already renamed into place; a cancel racing the
        // final progress tick must not misreport a completed build.
    }
}

} // namespace

convert_result convert_package(const std::string & src_gguf_path,
                               const std::string & dst_package_dir,
                               int64_t alignment,
                               const convert_progress_fn & progress) {
    std::string staging_dir;
    progress_tracker tracker(progress);
    try {
        run_conversion(src_gguf_path, dst_package_dir, alignment, tracker, staging_dir);
        return { 0, std::string() };
    } catch (const cancelled_error &) {
        if (!staging_dir.empty()) {
            remove_staging_directory(staging_dir);
        }
        return { 2, "cancelled" };
    } catch (const convert_error & error) {
        if (!staging_dir.empty()) {
            remove_staging_directory(staging_dir);
        }
        return { 1, error.message };
    } catch (const std::exception & error) {
        if (!staging_dir.empty()) {
            remove_staging_directory(staging_dir);
        }
        return { 1, std::string(error.what()) };
    }
}

} // namespace noema_paged

extern "C" NOEMA_LLAMA_SERVER_API int32_t noema_paged_convert(
    const char * src_gguf_path,
    const char * dst_package_dir,
    int32_t alignment,
    noema_paged_convert_progress_cb progress_cb,
    void * user_data,
    const char ** err_out) {
    static thread_local std::string error_storage;
    error_storage.clear();

    if (src_gguf_path == nullptr || src_gguf_path[0] == '\0' ||
        dst_package_dir == nullptr || dst_package_dir[0] == '\0') {
        error_storage = "src_gguf_path and dst_package_dir are required";
        if (err_out != nullptr) {
            *err_out = error_storage.c_str();
        }
        return 1;
    }

    noema_paged::convert_progress_fn progress;
    if (progress_cb != nullptr) {
        progress = [progress_cb, user_data](float fraction, const char * stage) -> int32_t {
            return progress_cb(fraction, stage, user_data);
        };
    }

    const noema_paged::convert_result result =
        noema_paged::convert_package(src_gguf_path, dst_package_dir, alignment, progress);
    error_storage = result.error;
    if (err_out != nullptr) {
        *err_out = error_storage.c_str();
    }
    return result.code;
}
