// Minimal definitions to satisfy upstream common/common.h externs.
// In CMake builds these come from a generated build-info.cpp.

#include <string>

int LLAMA_BUILD_NUMBER = 10018;
const char * LLAMA_COMMIT = "22b208b1";
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
    static std::string info = "b10018-22b208b1";
    return info.c_str();
}
