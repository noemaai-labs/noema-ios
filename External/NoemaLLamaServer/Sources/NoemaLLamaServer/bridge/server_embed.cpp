#include <cstring>

// Include the upstream HTTP server implementation copied into our package
// Path is relative to this file: Noema/NoemaLLamaServer/Sources/NoemaLLamaServer/bridge
#include "../upstream/tools/server/server.cpp"

// Rename main() from upstream server so we can call it as a function.
#define main llama_server_main
#include "../upstream/tools/server/main.cpp"
#undef main
