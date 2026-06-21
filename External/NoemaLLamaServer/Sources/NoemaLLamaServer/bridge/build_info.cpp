// Minimal definitions to satisfy upstream common/common.h externs.
// In CMake builds these come from a generated build-info.cpp.

#include <string>

int LLAMA_BUILD_NUMBER = 9592;
const char * LLAMA_COMMIT = "ac4cdde";
const char * LLAMA_COMPILER = "AppleClang (SPM)";
const char * LLAMA_BUILD_TARGET = "apple";

int llama_build_number(void) {
    return LLAMA_BUILD_NUMBER;
}

const char * llama_commit(void) {
    return LLAMA_COMMIT;
}

const char * llama_compiler(void) {
    return LLAMA_COMPILER;
}

const char * llama_build_target(void) {
    return LLAMA_BUILD_TARGET;
}

const char * llama_build_info(void) {
    static std::string info = "b9592-ac4cdde";
    return info.c_str();
}
