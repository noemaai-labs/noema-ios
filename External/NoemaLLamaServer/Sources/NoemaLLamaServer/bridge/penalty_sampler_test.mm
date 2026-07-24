#include "noema_llama_server.h"
#include "llama.h"

#include <array>
#include <cstdint>

#if defined(NOEMA_LLAMA_SERVER_TEST_HOOKS)
namespace {

bool penalty_outputs_match(llama_sampler * lhs, llama_sampler * rhs) {
    std::array<llama_token_data, 9> lhs_data{};
    std::array<llama_token_data, 9> rhs_data{};

    for (size_t i = 0; i < lhs_data.size(); ++i) {
        const llama_token_data candidate = {
            /* .id    = */ static_cast<llama_token>(i),
            /* .logit = */ i % 2 == 0 ? 1.0f : -1.0f,
            /* .p     = */ 0.0f,
        };
        lhs_data[i] = candidate;
        rhs_data[i] = candidate;
    }

    llama_token_data_array lhs_candidates = {
        /* .data     = */ lhs_data.data(),
        /* .size     = */ lhs_data.size(),
        /* .selected = */ -1,
        /* .sorted   = */ false,
    };
    llama_token_data_array rhs_candidates = {
        /* .data     = */ rhs_data.data(),
        /* .size     = */ rhs_data.size(),
        /* .selected = */ -1,
        /* .sorted   = */ false,
    };

    llama_sampler_apply(lhs, &lhs_candidates);
    llama_sampler_apply(rhs, &rhs_candidates);

    for (size_t i = 0; i < lhs_data.size(); ++i) {
        if (lhs_data[i].logit != rhs_data[i].logit) {
            return false;
        }
    }
    return true;
}

} // namespace

// Verifies both the cloned state and the full-window rollover that previously
// produced token_count == -1 after a speculative sampler restore.
extern "C" NOEMA_LLAMA_SERVER_API int32_t
noema_llama_server_penalty_clone_consistent_for_test(void) {
    constexpr int32_t penalty_last_n = 64;
    llama_sampler * original = llama_sampler_init_penalties(
        penalty_last_n, 1.1f, 0.2f, 0.3f);
    if (original == nullptr) {
        return 0;
    }

    for (int32_t i = 0; i < penalty_last_n; ++i) {
        llama_sampler_accept(original, static_cast<llama_token>(i % 8));
    }

    llama_sampler * clone = llama_sampler_clone(original);
    if (clone == nullptr) {
        llama_sampler_free(original);
        return 0;
    }

    // Check before rollover first. With the old bug this returns false safely,
    // before accepting into the inconsistent clone can trip llama.cpp's assert.
    bool consistent = penalty_outputs_match(original, clone);
    if (consistent) {
        llama_sampler_accept(original, 8);
        llama_sampler_accept(clone, 8);
        consistent = penalty_outputs_match(original, clone);
    }

    llama_sampler_free(clone);
    llama_sampler_free(original);
    return consistent ? 1 : 0;
}
#endif
