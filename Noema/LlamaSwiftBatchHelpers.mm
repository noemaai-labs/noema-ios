#import "LlamaSwiftBatchHelpers.h"

void noema_batch_clear_logits(struct llama_batch *batch, int n) {
    if (!batch || n <= 0) return;
    for (int j = 0; j < n; ++j) {
        batch->logits[j] = 0;
    }
}

void noema_batch_set(struct llama_batch *batch,
                     int i,
                     llama_token tok,
                     int pos,
                     int seq_id,
                     bool want_logits) {
    if (!batch || i < 0) return;
    batch->token[i] = tok;
    batch->pos[i] = pos;
    batch->n_seq_id[i] = 1;
    batch->seq_id[i][0] = seq_id;
    batch->logits[i] = want_logits ? 1 : 0;
}

