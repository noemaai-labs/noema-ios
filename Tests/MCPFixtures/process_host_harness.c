#include "../../NoemaMCPHost/MCPProcessSpawn.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int spawn(const char *executable, char *const argv[], int *out, int *in, int *err) {
    char *const environment[] = {"PATH=/usr/bin:/bin", "HOME=/tmp", NULL};
    int error_number = 0;
    int pid = noema_mcp_spawn(executable, argv, environment, NULL, out, in, err, &error_number);
    if (pid < 1) { fprintf(stderr, "spawn failed: %s\n", strerror(error_number)); exit(2); }
    return pid;
}

static ssize_t read_text(int fd, char *buffer, size_t size) {
    ssize_t count = read(fd, buffer, size - 1);
    if (count < 0) return count;
    buffer[count] = 0;
    return count;
}

int main(void) {
    int out, in, err, status;
    char buffer[512];

    const char *marker = "/tmp/noema-mcp-shell-evaluation-marker";
    unlink(marker);
    char literal[256];
    snprintf(literal, sizeof(literal), "$(touch %s)", marker);
    char *echo_args[] = {"/bin/echo", literal, NULL};
    int echo_pid = spawn("/bin/echo", echo_args, &out, &in, &err);
    close(in); read_text(out, buffer, sizeof(buffer)); waitpid(echo_pid, &status, 0);
    if (access(marker, F_OK) == 0 || strstr(buffer, "$(touch") == NULL) return 10;

    char *split_args[] = {"/bin/sh", "-c", "printf json-rpc; printf server-noise >&2", NULL};
    int split_pid = spawn("/bin/sh", split_args, &out, &in, &err);
    close(in); read_text(out, buffer, sizeof(buffer));
    if (strcmp(buffer, "json-rpc") != 0) return 11;
    read_text(err, buffer, sizeof(buffer)); waitpid(split_pid, &status, 0);
    if (strcmp(buffer, "server-noise") != 0) return 12;

    char *tree_args[] = {"/bin/sh", "-c", "sleep 30 & echo $!; wait", NULL};
    int tree_pid = spawn("/bin/sh", tree_args, &out, &in, &err);
    close(in); read_text(out, buffer, sizeof(buffer));
    int child_pid = atoi(buffer);
    if (child_pid < 2) return 13;
    kill(-tree_pid, SIGTERM); waitpid(tree_pid, &status, 0);
    for (int attempt = 0; attempt < 100 && kill(child_pid, 0) == 0; attempt++) usleep(20 * 1000);
    if (kill(child_pid, 0) == 0 || errno != ESRCH) return 14;

    puts("MCP process host harness passed");
    return 0;
}
