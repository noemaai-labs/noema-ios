
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <math.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <TargetConditionals.h>

#if __has_include(<llama/gguf.h>)
#include <llama/gguf.h>
#define GGUF_SCANNER_HAS_GGUF_HEADER 1
#elif __has_include(<LlamaFramework/gguf.h>)
#include <LlamaFramework/gguf.h>
#define GGUF_SCANNER_HAS_GGUF_HEADER 1
#elif __has_include("gguf.h")
#include "gguf.h"
#define GGUF_SCANNER_HAS_GGUF_HEADER 1
#endif

#ifndef GGUF_SCANNER_HAS_GGUF_HEADER
enum gguf_type {
    GGUF_TYPE_UINT8   = 0,
    GGUF_TYPE_INT8    = 1,
    GGUF_TYPE_UINT16  = 2,
    GGUF_TYPE_INT16   = 3,
    GGUF_TYPE_UINT32  = 4,
    GGUF_TYPE_INT32   = 5,
    GGUF_TYPE_FLOAT32 = 6,
    GGUF_TYPE_BOOL    = 7,
    GGUF_TYPE_STRING  = 8,
    GGUF_TYPE_ARRAY   = 9,
    GGUF_TYPE_UINT64  = 10,
    GGUF_TYPE_INT64   = 11,
    GGUF_TYPE_FLOAT64 = 12,
};
#endif

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

static uint32_t read_u32(FILE *f) {
    uint32_t v = 0;
    if (fread(&v, sizeof(v), 1, f) != 1) {
        clearerr(f);
        return 0;
    }
    return v;
}

static uint64_t read_u64(FILE *f) {
    uint64_t v = 0;
    if (fread(&v, sizeof(v), 1, f) != 1) {
        clearerr(f);
        return 0;
    }
    return v;
}

#if defined(GGUF_TYPE_COUNT)
static int has_suffix(const char *value, const char *suffix) {
    if (value == NULL || suffix == NULL) { return 0; }
    size_t value_len = strlen(value);
    size_t suffix_len = strlen(suffix);
    if (suffix_len == 0 || value_len < suffix_len) { return 0; }
    return strcmp(value + (value_len - suffix_len), suffix) == 0;
}

static int32_t gguf_read_i32_flexible(const struct gguf_context *ctx, int64_t key) {
    if (key < 0) { return 0; }
    switch (gguf_get_kv_type(ctx, key)) {
        case GGUF_TYPE_INT8:
            return (int32_t)gguf_get_val_i8(ctx, key);
        case GGUF_TYPE_UINT8:
            return (int32_t)gguf_get_val_u8(ctx, key);
        case GGUF_TYPE_INT16:
            return (int32_t)gguf_get_val_i16(ctx, key);
        case GGUF_TYPE_UINT16:
            return (int32_t)gguf_get_val_u16(ctx, key);
        case GGUF_TYPE_INT32:
            return gguf_get_val_i32(ctx, key);
        case GGUF_TYPE_UINT32:
            return (int32_t)gguf_get_val_u32(ctx, key);
        case GGUF_TYPE_INT64:
            return (int32_t)gguf_get_val_i64(ctx, key);
        case GGUF_TYPE_UINT64:
            return (int32_t)gguf_get_val_u64(ctx, key);
        case GGUF_TYPE_FLOAT32: {
            float value = gguf_get_val_f32(ctx, key);
            if (!isfinite(value)) { return 0; }
            return (int32_t)llroundf(value);
        }
        case GGUF_TYPE_FLOAT64: {
            double value = gguf_get_val_f64(ctx, key);
            if (!isfinite(value)) { return 0; }
            return (int32_t)llround(value);
        }
        case GGUF_TYPE_BOOL:
            return gguf_get_val_bool(ctx, key) ? 1 : 0;
        case GGUF_TYPE_ARRAY: {
            enum gguf_type element_type = gguf_get_arr_type(ctx, key);
            size_t count = gguf_get_arr_n(ctx, key);
            const void *data = gguf_get_arr_data(ctx, key);
            if (data == NULL || count == 0) { return 0; }
            int64_t max_value = 0;
            int found = 0;
            size_t i;
            switch (element_type) {
                case GGUF_TYPE_INT8: {
                    const int8_t *arr = (const int8_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_UINT8: {
                    const uint8_t *arr = (const uint8_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_INT16: {
                    const int16_t *arr = (const int16_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_UINT16: {
                    const uint16_t *arr = (const uint16_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_INT32: {
                    const int32_t *arr = (const int32_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_UINT32: {
                    const uint32_t *arr = (const uint32_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_INT64: {
                    const int64_t *arr = (const int64_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_UINT64: {
                    const uint64_t *arr = (const uint64_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = (int64_t)arr[i];
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_FLOAT32: {
                    const float *arr = (const float *)data;
                    for (i = 0; i < count; ++i) {
                        float value = arr[i];
                        if (!isfinite(value)) { continue; }
                        int64_t v = (int64_t)llroundf(value);
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_FLOAT64: {
                    const double *arr = (const double *)data;
                    for (i = 0; i < count; ++i) {
                        double value = arr[i];
                        if (!isfinite(value)) { continue; }
                        int64_t v = (int64_t)llround(value);
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                case GGUF_TYPE_BOOL: {
                    const int8_t *arr = (const int8_t *)data;
                    for (i = 0; i < count; ++i) {
                        int64_t v = arr[i] ? 1 : 0;
                        if (!found || v > max_value) { max_value = v; found = 1; }
                    }
                    break;
                }
                default:
                    return 0;
            }
            if (!found) { return 0; }
            return (int32_t)max_value;
        }
        default:
            return 0;
    }
}

static int parse_block_index(const char *name) {
    if (name == NULL) { return -1; }
    const struct { const char *prefix; size_t len; } prefixes[] = {
        { "blk.",   4 },
        { "layers.", 7 },
    };
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); ++i) {
        const char *prefix = prefixes[i].prefix;
        const size_t len = prefixes[i].len;
        if (strncmp(name, prefix, len) != 0) { continue; }
        const char *cursor = name + len;
        char *endptr = NULL;
        long value = strtol(cursor, &endptr, 10);
        if (endptr == cursor || value < 0) { continue; }
        return (int)value;
    }
    return -1;
}

static int is_moe_tensor_name(const char *name) {
    if (name == NULL) { return 0; }
    // MoE-related tensor suffixes used across llama.cpp architectures.
    static const char *suffixes[] = {
        ".ffn_gate_inp.weight",
        ".ffn_gate_inp_shexp.weight",
        ".ffn_gate_exps.weight",
        ".ffn_up_exps.weight",
        ".ffn_down_exps.weight",
        ".ffn_norm_exps.weight",
        ".ffn_gate_chexps.weight",
        ".ffn_up_chexps.weight",
        ".ffn_down_chexps.weight",
    };
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); ++i) {
        const char *suffix = suffixes[i];
        const char *pos = strstr(name, suffix);
        if (pos != NULL && strcmp(pos, suffix) == 0) {
            return 1;
        }
    }
    return 0;
}
#endif

int32_t gguf_layer_count(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char magic[4];
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "GGUF", 4) != 0) {
        fclose(f);
        return 0;
    }
    (void)read_u32(f); // version (ignored)
    (void)read_u64(f); // tensor count (ignored)
    uint64_t kv_count = read_u64(f);
    for (uint64_t i = 0; i < kv_count; ++i) {
        uint64_t key_len = read_u64(f);
        if (key_len > 1024) { fclose(f); return 0; }
        char key[1025];
        if (fread(key, 1, key_len, f) != key_len) {
            clearerr(f);
            fclose(f);
            return 0;
        }
        key[key_len] = '\0';
        uint32_t type = read_u32(f);
        if (strcmp(key, "hparams.n_layer") == 0 &&
            (type == GGUF_TYPE_INT32 || type == GGUF_TYPE_UINT32)) {
            int32_t val = (int32_t)read_u32(f);
            fclose(f);
            return val;
        } else {
            switch (type) {
                case GGUF_TYPE_UINT8:
                case GGUF_TYPE_INT8:
                case GGUF_TYPE_BOOL:
                    if (fseek(f, 1, SEEK_CUR) != 0) { fclose(f); return 0; } break;
                case GGUF_TYPE_UINT16:
                case GGUF_TYPE_INT16:
                    if (fseek(f, 2, SEEK_CUR) != 0) { fclose(f); return 0; } break;
                case GGUF_TYPE_UINT32:
                case GGUF_TYPE_INT32:
                case GGUF_TYPE_FLOAT32:
                    if (fseek(f, 4, SEEK_CUR) != 0) { fclose(f); return 0; } break;
                case GGUF_TYPE_UINT64:
                case GGUF_TYPE_INT64:
                case GGUF_TYPE_FLOAT64:
                    if (fseek(f, 8, SEEK_CUR) != 0) { fclose(f); return 0; } break;
                case GGUF_TYPE_STRING: {
                    uint64_t len = read_u64(f);
                    if (fseek(f, (long)len, SEEK_CUR) != 0) { fclose(f); return 0; } break; }
                case GGUF_TYPE_ARRAY: {
                    uint32_t et = read_u32(f);
                    uint64_t n = read_u64(f);
                    size_t sz;
                    switch (et) {
                        case GGUF_TYPE_UINT8:
                        case GGUF_TYPE_INT8:
                        case GGUF_TYPE_BOOL: sz = 1; break;
                        case GGUF_TYPE_UINT16:
                        case GGUF_TYPE_INT16: sz = 2; break;
                        case GGUF_TYPE_UINT32:
                        case GGUF_TYPE_INT32:
                        case GGUF_TYPE_FLOAT32: sz = 4; break;
                        case GGUF_TYPE_UINT64:
                        case GGUF_TYPE_INT64:
                        case GGUF_TYPE_FLOAT64: sz = 8; break;
                        case GGUF_TYPE_STRING: sz = 0; break;
                        default: sz = 0; break;
                    }
                    if (et == GGUF_TYPE_STRING) {
                        for (uint64_t j = 0; j < n; ++j) {
                            uint64_t len = read_u64(f);
                            if (fseek(f, (long)len, SEEK_CUR) != 0) { fclose(f); return 0; }
                        }
                    } else {
                        if (sz == 0) { fclose(f); return 0; }
                        // Guard against overflow before casting to long
                        if (n > SIZE_MAX / sz) { fclose(f); return 0; }
                        size_t bytes = sz * n;
                        if (fseek(f, (long)bytes, SEEK_CUR) != 0) { fclose(f); return 0; }
                    }
                    break; }
                default:
                    fclose(f); return 0;
            }
        }
    }
    fclose(f);
    return 0;
}

#if defined(GGUF_TYPE_COUNT)
int gguf_moe_scan(const char *path, struct gguf_moe_scan_result *out_result) {
    if (out_result == NULL || path == NULL) {
        return -1;
    }

    struct gguf_moe_scan_result result = {0};
    struct gguf_init_params params;
    params.no_alloc = true;
    params.ctx = NULL;

    struct gguf_context *ctx = gguf_init_from_file(path, params);
    if (ctx == NULL) {
        result.status = -1;
        *out_result = result;
        return -1;
    }

    result.status = 0;

    int64_t key = gguf_find_key(ctx, "llama.expert_count");
    if (key >= 0) {
        int32_t value = gguf_read_i32_flexible(ctx, key);
        if (value > 0) {
            result.is_moe = 1;
            result.expert_count = value;
        }
    } else {
        result.is_moe = 0;
    }

    key = gguf_find_key(ctx, "llama.expert_used_count");
    if (key >= 0) {
        int32_t value = gguf_read_i32_flexible(ctx, key);
        if (value > 0) {
            result.expert_used_count = value;
        }
    }

    if (result.expert_count <= 0 || result.expert_used_count <= 0) {
        const int64_t kv_total = gguf_get_n_kv(ctx);
        for (int64_t i = 0; i < kv_total; ++i) {
            const char *name = gguf_get_key(ctx, i);
            if (!name) { continue; }
            if (result.expert_count <= 0 && (
                has_suffix(name, "expert_count") ||
                strstr(name, "num_experts") != NULL ||
                has_suffix(name, "n_expert") ||
                has_suffix(name, "n_experts")
            )) {
                int32_t value = gguf_read_i32_flexible(ctx, i);
                if (value > result.expert_count) {
                    result.expert_count = value;
                }
                if (value > 0) {
                    result.is_moe = 1;
                }
            }
            if (result.expert_used_count <= 0 && (
                has_suffix(name, "expert_used_count") ||
                strstr(name, "active_experts") != NULL ||
                strstr(name, "experts_per_token") != NULL ||
                has_suffix(name, "n_expert_used")
            )) {
                int32_t value = gguf_read_i32_flexible(ctx, i);
                if (value > 0) {
                    result.expert_used_count = value;
                    if (value > 0) {
                        result.is_moe = 1;
                    }
                }
            }
        }
    }

    int32_t total_layers = 0;
    const char *layerKeys[] = {
        "llama.block_count",
        "llama.n_layer",
        "hparams.n_layer",
    };
    for (size_t i = 0; i < sizeof(layerKeys) / sizeof(layerKeys[0]); ++i) {
        key = gguf_find_key(ctx, layerKeys[i]);
        if (key >= 0) {
            total_layers = gguf_read_i32_flexible(ctx, key);
            if (total_layers > 0) { break; }
        }
    }

    if (total_layers > 0) {
        result.total_layer_count = total_layers;
    }

    key = gguf_find_key(ctx, "llama.embedding_length");
    if (key >= 0) {
        result.hidden_size = gguf_read_i32_flexible(ctx, key);
    }

    key = gguf_find_key(ctx, "llama.feed_forward_length");
    if (key >= 0) {
        result.feed_forward_size = gguf_read_i32_flexible(ctx, key);
    }

    key = gguf_find_key(ctx, "llama.vocab_size");
    if (key >= 0) {
        result.vocab_size = gguf_read_i32_flexible(ctx, key);
    }

    int *moe_blocks = NULL;
    size_t moe_blocks_count = 0;
    size_t moe_blocks_cap = 0;
    int max_block_index = -1;
    const int64_t tensor_count = gguf_get_n_tensors(ctx);
    for (int64_t i = 0; i < tensor_count; ++i) {
        const char *name = gguf_get_tensor_name(ctx, i);
        if (!name) { continue; }

        int block_index = parse_block_index(name);
        if (block_index >= 0 && block_index > max_block_index) {
            max_block_index = block_index;
        }

        if (block_index >= 0 && is_moe_tensor_name(name)) {
            int seen = 0;
            for (size_t j = 0; j < moe_blocks_count; ++j) {
                if (moe_blocks[j] == block_index) { seen = 1; break; }
            }
            if (!seen) {
                if (moe_blocks_count == moe_blocks_cap) {
                    const size_t new_cap = moe_blocks_cap == 0 ? 16 : moe_blocks_cap * 2;
                    int *new_buf = (int *)realloc(moe_blocks, new_cap * sizeof(int));
                    if (new_buf == NULL) {
                        free(moe_blocks);
                        gguf_free(ctx);
                        result.status = -1;
                        *out_result = result;
                        return -1;
                    }
                    moe_blocks = new_buf;
                    moe_blocks_cap = new_cap;
                }
                moe_blocks[moe_blocks_count++] = block_index;
            }
        }
    }

    if (result.total_layer_count <= 0 && max_block_index >= 0) {
        result.total_layer_count = max_block_index + 1;
    }

    const int moe_layers = (int)moe_blocks_count;
    free(moe_blocks);
    if (moe_layers > 0) {
        result.moe_layer_count = moe_layers;
        result.is_moe = 1;
    }

    gguf_free(ctx);
    *out_result = result;
    return 0;
}
#else
int gguf_moe_scan(const char *path, struct gguf_moe_scan_result *out_result) {
    if (out_result) {
        struct gguf_moe_scan_result result = {0};
        result.status = -1;
        *out_result = result;
    }
    (void)path;
    return -1;
}
#endif

size_t app_memory_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self_, TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return 0;
    // Use phys_footprint as approximation of current memory usage in bytes
    return (size_t)info.phys_footprint;
}

size_t app_available_memory(void) {
#if defined(TARGET_OS_OSX) && TARGET_OS_OSX
    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    kern_return_t kr = host_page_size(host, &page_size);
    size_t avail = 0;

    if (kr == KERN_SUCCESS) {
        vm_statistics64_data_t vm_stat = {0};
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        kr = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm_stat, &count);
        if (kr == KERN_SUCCESS) {
            uint64_t free_mem = (uint64_t)vm_stat.free_count * page_size;
            uint64_t inactive_mem = (uint64_t)vm_stat.inactive_count * page_size;
            avail = (size_t)(free_mem + inactive_mem);
        }
    }

    mach_port_deallocate(mach_task_self(), host);
#else
    size_t avail = os_proc_available_memory();
#endif
    return avail;
}
