#pragma once

// Noema's loopback server is API-only and does not serve the llama.cpp web UI,
// so the embedded asset table is empty. This header matches the asset API that
// tools/server/server-http.cpp expects (upstream b9940): a get-all accessor and
// a by-name lookup over `llama_ui_asset` records.

#include <cstddef>
#include <string>
#include <vector>

struct llama_ui_asset {
    std::string           name;
    const unsigned char * data = nullptr;
    size_t                size = 0;
    std::string           type;   // MIME type
    std::string           etag;
};

const std::vector<llama_ui_asset> & llama_ui_get_assets();
const llama_ui_asset * llama_ui_find_asset(const std::string & name);
