/* bench — measure the wall-clock cost of launching a program, N times.
 *
 * Written in C with fork/execve/wait4 directly so the harness contributes
 * nothing measurable to what it is measuring: the number reported is
 * (clock_gettime before fork) -> (clock_gettime after waitpid), which is the
 * full cost of becoming a process, doing the work, and being reaped.
 *
 * wait4 also hands back rusage, so max RSS and page-fault counts come from the
 * kernel's own accounting rather than from sampling /proc and hoping to catch a
 * process that lives for two milliseconds.
 *
 * usage: bench <iters> <warmup> <prog> [args...]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>

static int cmp_u64(const void *a, const void *b) {
    unsigned long long x = *(const unsigned long long *)a;
    unsigned long long y = *(const unsigned long long *)b;
    return (x > y) - (x < y);
}

static unsigned long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ULL + (unsigned long long)ts.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <iters> <warmup> <prog> [args...]\n", argv[0]);
        return 2;
    }
    int iters = atoi(argv[1]);
    int warmup = atoi(argv[2]);
    char *prog = argv[3];
    char **child_argv = &argv[3];

    unsigned long long *samples = calloc(iters, sizeof(*samples));
    if (!samples) return 2;

    long max_rss_kb = 0;
    long minflt = 0, majflt = 0, nvcsw = 0, nivcsw = 0;
    int failures = 0;

    for (int i = 0; i < warmup + iters; i++) {
        unsigned long long t0 = now_ns();

        pid_t pid = fork();
        if (pid < 0) { perror("fork"); return 2; }
        if (pid == 0) {
            execv(prog, child_argv);
            _exit(127);
        }

        int status;
        struct rusage ru;
        if (wait4(pid, &status, 0, &ru) < 0) { perror("wait4"); return 2; }
        unsigned long long dt = now_ns() - t0;

        if (i < warmup) continue;
        samples[i - warmup] = dt;

        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) failures++;
        if (ru.ru_maxrss > max_rss_kb) max_rss_kb = ru.ru_maxrss;
        minflt += ru.ru_minflt;
        majflt += ru.ru_majflt;
        nvcsw += ru.ru_nvcsw;
        nivcsw += ru.ru_nivcsw;
    }

    qsort(samples, iters, sizeof(*samples), cmp_u64);

    unsigned long long sum = 0;
    for (int i = 0; i < iters; i++) sum += samples[i];

    printf("runs\t%d\n", iters);
    printf("failures\t%d\n", failures);
    printf("min_us\t%.1f\n", samples[0] / 1000.0);
    printf("p50_us\t%.1f\n", samples[iters / 2] / 1000.0);
    printf("p90_us\t%.1f\n", samples[(int)(iters * 0.90)] / 1000.0);
    printf("p99_us\t%.1f\n", samples[(int)(iters * 0.99)] / 1000.0);
    printf("max_us\t%.1f\n", samples[iters - 1] / 1000.0);
    printf("mean_us\t%.1f\n", (double)sum / iters / 1000.0);
    printf("maxrss_kb\t%ld\n", max_rss_kb);
    printf("minflt_per_run\t%.1f\n", (double)minflt / iters);
    printf("majflt_per_run\t%.1f\n", (double)majflt / iters);
    printf("nvcsw_per_run\t%.1f\n", (double)nvcsw / iters);
    printf("nivcsw_per_run\t%.1f\n", (double)nivcsw / iters);
    return 0;
}
