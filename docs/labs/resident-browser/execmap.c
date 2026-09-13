/* execmap — snapshot a program's address space at the exact instant after
 * execve() succeeds, before it has executed a single user-space instruction.
 *
 * The naive way to get "how much memory does this launcher use" is to sample
 * /proc/<pid>/status in a loop, which does not work against a process that
 * lives for two milliseconds. The other naive way is MAXRSS from rusage, which
 * answers a different question (peak, not initial) and collapses everything
 * into one number.
 *
 * PTRACE_O_TRACEEXEC makes the kernel stop the tracee right after a successful
 * execve. At that stop the tracee is frozen with its final memory image already
 * built, so /proc/<pid>/maps is a stable, exact answer to "what did becoming
 * this program cost?" — the loader's work is done, the program's work has not
 * started.
 *
 * usage: execmap <prog> [args...]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/types.h>

static void dump_file(const char *label, const char *fmt, pid_t pid) {
    char path[64];
    snprintf(path, sizeof(path), fmt, (int)pid);

    FILE *f = fopen(path, "r");
    if (!f) {
        printf("=== %s: unavailable ===\n", label);
        return;
    }
    printf("=== %s ===\n", label);
    char line[4096];
    while (fgets(line, sizeof(line), f)) fputs(line, stdout);
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <prog> [args...]\n", argv[0]);
        return 2;
    }

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }

    if (pid == 0) {
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) < 0) { perror("TRACEME"); _exit(126); }
        raise(SIGSTOP);                 /* hand control to the tracer */
        execv(argv[1], &argv[1]);       /* stop happens immediately after this */
        _exit(127);
    }

    int status;
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid/stop"); return 2; }

    if (ptrace(PTRACE_SETOPTIONS, pid, 0, (void *)PTRACE_O_TRACEEXEC) < 0) {
        perror("SETOPTIONS"); return 2;
    }
    if (ptrace(PTRACE_CONT, pid, 0, 0) < 0) { perror("CONT"); return 2; }

    if (waitpid(pid, &status, 0) < 0) { perror("waitpid/exec"); return 2; }

    int sig = WSTOPSIG(status);
    int event = status >> 8;
    if (!WIFSTOPPED(status) || sig != SIGTRAP || event != (SIGTRAP | (PTRACE_EVENT_EXEC << 8))) {
        fprintf(stderr, "execmap: expected an exec stop, got status=0x%x\n", status);
        ptrace(PTRACE_KILL, pid, 0, 0);
        waitpid(pid, &status, 0);
        return 2;
    }

    /* The tracee is frozen here. Everything below is a photograph. */
    dump_file("maps", "/proc/%d/maps", pid);
    dump_file("smaps_rollup", "/proc/%d/smaps_rollup", pid);
    dump_file("status", "/proc/%d/status", pid);

    ptrace(PTRACE_KILL, pid, 0, 0);
    waitpid(pid, &status, 0);
    return 0;
}
