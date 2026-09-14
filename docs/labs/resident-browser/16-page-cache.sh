#!/bin/bash
# 实验：读过的文件占着的内存，还要得回来吗？
#
# 这是「数据该留在磁盘还是搬进内存」那个决定的前提。
# 使用者脑子里的模型是「文件在磁盘上，读它就要读盘」，于是
# 「搬进内存 = 更快」看起来天经地义。这个实验量的是另一半：
#
#   一、读过的文件会留在内存里，而且这件事不由你的程序决定。
#   二、**更重要的是**：这些内存随时可以还回来，还回来之后那个文件照样在用，
#      下次读它大不了再读一次盘 —— 这就是「放在磁盘上」的全部好处。
#   三、所以把数据从磁盘搬进 tmpfs 并没有换来什么，
#      只是把它从「可回收」改成了「钉死的」。
#
# 两遍读数，每遍都报两笔账：
#     read() 拿到多少       程序要到的字节
#     read_bytes 涨了多少   内核**真的向块设备要了**多少字节（/proc/<pid>/io）
#   中间调一次 posix_fadvise(DONTNEED)：把这份文件从页缓存里丢掉。
#
# 不需要 root，跑完不留残留。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# 素材要放在有后备存储的文件系统上 —— 这台机器的 /tmp 是 tmpfs，
# 在 tmpfs 上做这个实验等于把结论做没了。所以自己挑一个非 tmpfs 的目录。
pick_disk_dir() {
    local base
    for base in "${DISK_DIR_OVERRIDE:-}" /var/tmp "$HOME" /; do
        [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
        [ "$(findmnt -no FSTYPE -T "$base" 2>/dev/null || true)" != "tmpfs" ] || continue
        mktemp -d "$base/.pagecache-lab-XXXXXX" && return 0
    done
    return 1
}

WORK=$(pick_disk_dir) || { printf '\n  跳过：找不到一个可写的、非 tmpfs 的目录。\n\n'; exit 0; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

SIZE_MB="${1:-256}"

cat >"$WORK/cache.c" <<'EOF'
/*
 * 造素材 + 两遍读数，中间释放一次页缓存。
 *
 *   make <文件> <MB>   写一个大文件（先 fallocate 占位，免得 CoW 边写边分裂）
 *   read <文件>        读两遍，每遍报 read() 字节数与 read_bytes 差值；
 *                      两遍之间用 posix_fadvise(DONTNEED) 丢掉页缓存。
 *                      丢完之后文件还在、内容没变 —— 只是内存还回去了。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

static unsigned long long io_field(pid_t pid, const char *key) {
    char path[64], line[256];
    snprintf(path, sizeof path, "/proc/%d/io", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    unsigned long long v = 0;
    size_t klen = strlen(key);
    while (fgets(line, sizeof line, f))
        if (!strncmp(line, key, klen) && sscanf(line + klen, ": %llu", &v) == 1) break;
    fclose(f);
    return v;
}

static int make(const char *path, unsigned long long bytes) {
    static char buf[4096];
    memset(buf, 0x5a, sizeof buf);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 1; }
    if (fallocate(fd, 0, 0, (off_t)bytes) != 0)
        fprintf(stderr, "    （fallocate 不支持，按普通写继续）\n");
    for (unsigned long long done = 0; done < bytes; done += sizeof buf)
        if (write(fd, buf, sizeof buf) != (ssize_t)sizeof buf) { perror("write"); close(fd); return 1; }
    fsync(fd);
    close(fd);
    return 0;
}

static void evict(const char *path) {
    sync();                                   /* 脏页先落盘，否则丢不掉 */
    int fd = open(path, O_RDONLY);
    if (fd >= 0) { posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED); close(fd); }
}

static int read_once(const char *path, const char *tag) {
    pid_t self = getpid();
    static char buf[1 << 16];

    unsigned long long before = io_field(self, "read_bytes"), total = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) total += (unsigned long long)n;
    close(fd);
    unsigned long long after = io_field(self, "read_bytes");

    printf("    %-20s read() 拿到 %4llu MiB    真的读盘 %6llu KiB\n",
           tag, total / 1048576, (after - before) / 1024);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: cache make <文件> <MB> | cache read <文件>\n"); return 2; }
    if (!strcmp(argv[1], "make")) return make(argv[2], strtoull(argv[3], NULL, 10) << 20);
    if (!strcmp(argv[1], "read")) {
        read_once(argv[2], "读第一遍");
        evict(argv[2]);
        read_once(argv[2], "内存还回去之后");
        return 0;
    }
    return 2;
}
EOF

if ! cc -O2 -o "$WORK/cache" "$WORK/cache.c" 2>"$WORK/cc.log"; then
    printf '  编译辅助程序失败：\n'; sed 's/^/    /' "$WORK/cc.log"; printf '\n'; exit 1
fi

tmpf="$WORK/scratch"
printf '\n  这个实验要回答：读过的文件占着的内存，还要得回来吗？\n\n'
printf '  数据目录：%s（%s）\n' "$WORK" "$(findmnt -no FSTYPE -T "$WORK")"
printf '  先造一个 %s MB 的文件，读一遍，把它的缓存还回去，再读一遍。\n\n' "$SIZE_MB"

if ! "$WORK/cache" make "$tmpf" "$SIZE_MB"; then
    printf '  造素材失败。\n\n'; exit 1
fi

"$WORK/cache" read "$tmpf"
printf '\n'

cat <<'EOF'
  两遍的 read() 字节数完全一样。差别在「真的读盘」那一列 ——
  但这不重要，重要的是**中间那一步什么都没破坏**：

    posix_fadvise(DONTNEED) 把这文件的页从内存里丢了出去，
    文件还在、内容没变、下一次读它还是同样的结果。
    也就是说，那些内存是借来的，内核随时可以收走。

  这一条正是「留在磁盘上就够了」的依据：
    · 读过的东西会自动进内存（不用你写代码）
    · 内存紧张的时候它会被丢掉（不用你操心）
    · 下次要用，再读一次磁盘就行（代价是一次读，不是一次错误）

  反过来，按进 tmpfs 的那部分没有后备存储：丢了就真没了，
  所以内核丢不掉它 —— 那不是「更快」，那是「钉死」。17 量的是这一半。
EOF
