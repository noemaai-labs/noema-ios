#pragma once
#include <sys/types.h>

pid_t noema_mcp_spawn(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int *parent_stdout,
    int *parent_stdin,
    int *parent_stderr,
    int *error_number
);
