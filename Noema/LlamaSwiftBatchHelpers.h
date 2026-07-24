#pragma once

#include <stdbool.h>

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#elif __has_include("llama.h")
#include "llama.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Clear logits flags for the first n entries in the batch.
void noema_batch_clear_logits(struct llama_batch *batch, int n);

// Populate the batch entry at index i with token, position, sequence id, and logits flag.
void noema_batch_set(struct llama_batch *batch,
                     int i,
                     llama_token tok,
                     int pos,
                     int seq_id,
                     bool want_logits);

#ifdef __cplusplus
}
#endif

