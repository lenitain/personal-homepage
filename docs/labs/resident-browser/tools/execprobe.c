/* execprobe — 在 execve 成功的那一刻把进程停住，报告它准备从哪里开始执行。
 *
 * 为什么需要它：第一章有一句核心断言 ——「有 PT_INTERP 的文件，内核跳转的不是它，
 * 而是那个解释器」。这句话没法用 strace 验证：execve 是个系统调用，
 * 内核在里面做的所有事都不产生新的系统调用记录，外部只看得到 execve(...) = 0。
 *
 * 唯一的办法是让内核在「exec 刚做完、第一条指令还没执行」时把进程停住，
 * 然后读它的 RIP（下一条要执行的指令地址），再看这个地址落在哪个映射里。
 *
 *   - 静态链接的程序：RIP 应该落在主程序自己的可执行段里
 *   - 动态链接的程序：RIP 应该落在 ld.so 的可执行段里
 *
 * 这样那句话就从「断言」变成「量出来的事实」。
 *
 * 用法: execprobe <prog> [args...]
 * 输出: 一段可解析的键值对 + 完整 maps
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <sys/types.h>

/* 在 maps 里找 addr 落在哪一行，把那一行抄进 out。找不到返回 0。 */
static int mapping_of(pid_t pid, unsigned long addr, char *out, size_t cap) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/maps", (int)pid);

    FILE *f = fopen(path, "r");
    if (!f) return 0;

    char line[1024];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned long lo, hi;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2) continue;
        if (addr >= lo && addr < hi) {
            snprintf(out, cap, "%s", line);
            found = 1;
            break;
        }
    }
    fclose(f);
    return found;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <prog> [args...]\n", argv[0]);
        return 2;
    }

    /* argv[1] 的绝对路径，用来在 maps 里认出「主程序自己」 */
    char self_path[4096];
    if (!realpath(argv[1], self_path)) {
        perror("realpath");
        return 2;
    }

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }

    if (pid == 0) {
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) < 0) { perror("TRACEME"); _exit(126); }
        raise(SIGSTOP);
        execv(argv[1], &argv[1]);
        _exit(127);
    }

    int status;
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); return 2; }
    if (ptrace(PTRACE_SETOPTIONS, pid, 0, (void *)PTRACE_O_TRACEEXEC) < 0) {
        perror("SETOPTIONS"); return 2;
    }
    if (ptrace(PTRACE_CONT, pid, 0, 0) < 0) { perror("CONT"); return 2; }
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid/exec"); return 2; }

    if (!WIFSTOPPED(status) ||
        (status >> 8) != (SIGTRAP | (PTRACE_EVENT_EXEC << 8))) {
        fprintf(stderr, "execprobe: 没有停在 exec 事件上 (status=0x%x)\n", status);
        ptrace(PTRACE_KILL, pid, 0, 0);
        waitpid(pid, &status, 0);
        return 2;
    }

    struct user_regs_struct regs;
    if (ptrace(PTRACE_GETREGS, pid, 0, &regs) < 0) { perror("GETREGS"); return 2; }

    char where[1024] = {0};
    int found = mapping_of(pid, (unsigned long)regs.rip, where, sizeof where);

    /* 那一行里最后一段是文件路径（内核给映射标的），取出来 */
    char file[512] = "（匿名映射，没有对应文件）";
    if (found) {
        char *p = where;
        char *last = NULL;
        while (*p) {
            while (*p == ' ') p++;
            if (!*p) break;
            last = p;
            while (*p && *p != ' ') p++;
        }
        if (last) snprintf(file, sizeof file, "%s", last);
    }

    /* 主程序自己有没有被映射进来 —— 动态链接时内核仍然会映射它，
     * 只是不从这里开始跑 */
    char selfmap[1024] = {0};
    int self_mapped = 0;
    {
        char path[64];
        snprintf(path, sizeof path, "/proc/%d/maps", (int)pid);
        FILE *f = fopen(path, "r");
        char line[1024];
        while (f && fgets(line, sizeof line, f)) {
            if (strstr(line, self_path)) { snprintf(selfmap, sizeof selfmap, "%s", line); self_mapped = 1; break; }
        }
        if (f) fclose(f);
    }

    printf("prog\t%s\n", self_path);
    printf("entry_rip\t0x%llx\n", (unsigned long long)regs.rip);
    printf("entry_file\t%s\n", file);
    printf("entry_mapping\t%s", where);
    printf("self_mapped\t%d\n", self_mapped);
    if (self_mapped) printf("self_mapping\t%s", selfmap);

    ptrace(PTRACE_KILL, pid, 0, 0);
    waitpid(pid, &status, 0);
    return 0;
}
