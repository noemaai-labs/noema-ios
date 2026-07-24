#include "ui.h"

// Empty asset table: server-http.cpp registers no UI routes and returns 404 for
// asset lookups. Noema clients talk to the server's JSON API directly.
const std::vector<llama_ui_asset> & llama_ui_get_assets() {
    static const std::vector<llama_ui_asset> assets;
    return assets;
}

const llama_ui_asset * llama_ui_find_asset(const std::string &) {
    return nullptr;
}
