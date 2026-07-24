#include "MCPProcessSpawn.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

static void close_pair(int pair[2]) { close(pair[0]); close(pair[1]); }

pid_t noema_mcp_spawn(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int *parent_stdout,
    int *parent_stdin,
    int *parent_stderr,
    int *error_number
) {
    int input[2] = {-1, -1};
    int output[2] = {-1, -1};
    int error[2] = {-1, -1};
    if (pipe(input) != 0 || pipe(output) != 0 || pipe(error) != 0) {
        *error_number = errno;
        if (input[0] >= 0) close_pair(input);
        if (output[0] >= 0) close_pair(output);
        if (error[0] >= 0) close_pair(error);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        *error_number = errno;
        close_pair(input); close_pair(output); close_pair(error);
        return -1;
    }
    if (pid == 0) {
        // Every server gets its own process group. npm/npx/Node grandchildren
        // inherit it, so cancellation and app exit terminate the complete tree.
        if (setpgid(0, 0) != 0) _exit(126);
        if (working_directory && chdir(working_directory) != 0) _exit(126);
        if (dup2(input[0], STDIN_FILENO) < 0 ||
            dup2(output[1], STDOUT_FILENO) < 0 ||
            dup2(error[1], STDERR_FILENO) < 0) _exit(126);
        close_pair(input); close_pair(output); close_pair(error);
        execve(executable, argv, envp);
        _exit(errno == ENOENT ? 127 : 126);
    }

    // Close the child sides. Stderr is always separate and can never be parsed
    // as JSON-RPC input.
    close(input[0]); close(output[1]); close(error[1]);
    (void)setpgid(pid, pid);
    *parent_stdin = input[1];
    *parent_stdout = output[0];
    *parent_stderr = error[0];
    *error_number = 0;
    return pid;
}
