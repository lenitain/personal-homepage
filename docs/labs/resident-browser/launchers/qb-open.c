// qb-open: qutebrowser 快速客户端（毫秒级）。
//
// 直接向常驻实例（qb-server）的 IPC socket 写 JSON，不启动 Python/Qt。
// 无参数 = 按配置 new_instance_open_target（默认 tab）打开，无窗口则新建。
// 常驻 server 未运行（socket 不存在）时回退 exec /usr/bin/qutebrowser 冷启动。
//
// socket 路径: $XDG_RUNTIME_DIR/qutebrowser/ipc-*（扫描目录取第一个 ipc-* 文件，
// 不依赖 qutebrowser 的 md5(用户名) 命名算法，将来算法变更也不受影响）
//
// 构建（静态 musl，零运行时依赖）:
//   musl-gcc -O2 -Wall -Wextra -static -o qb-open qb-open.c
//
// 用法: qb-open [URL...]

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

extern char **environ;

// JSON 字符串转义，追加到缓冲区
static int json_append(char *buf, size_t *pos, size_t cap, const char *s) {
    if (*pos >= cap) return -1;
    buf[(*pos)++] = '"';
    for (; *s; s++) {
        if (*pos >= cap) return -1;
        switch (*s) {
            case '"':
                if (*pos + 2 > cap) return -1;
                buf[(*pos)++] = '\\';
                buf[(*pos)++] = '"';
                break;
            case '\\':
                if (*pos + 2 > cap) return -1;
                buf[(*pos)++] = '\\';
                buf[(*pos)++] = '\\';
                break;
            case '\n':
                if (*pos + 2 > cap) return -1;
                buf[(*pos)++] = '\\';
                buf[(*pos)++] = 'n';
                break;
            case '\r':
                if (*pos + 2 > cap) return -1;
                buf[(*pos)++] = '\\';
                buf[(*pos)++] = 'r';
                break;
            case '\t':
                if (*pos + 2 > cap) return -1;
                buf[(*pos)++] = '\\';
                buf[(*pos)++] = 't';
                break;
            default:
                if (*s >= 0x00 && *s <= 0x1f) {
                    int n = snprintf(buf + *pos, cap - *pos, "\\u%04x", (unsigned char)*s);
                    if (n < 0 || (size_t)n >= cap - *pos) return -1;
                    *pos += n;
                } else {
                    buf[(*pos)++] = *s;
                }
        }
    }
    if (*pos >= cap) return -1;
    buf[(*pos)++] = '"';
    return 0;
}

// 追加一段不需要转义的固定文本，与 json_append 共用同一个上限。
//
// 存在的理由：snprintf 返回的是"本该写入的长度"，被截断时它比实际写入的多。
// 直接把这个返回值加进偏移量，pos 就会冲过缓冲区末尾，紧接着 `sizeof(buf) - pos`
// 下溢成 SIZE_MAX，再往后每一次写入都落在数组之外。宁可写这么个小函数。
static int literal_append(char *buf, size_t *pos, size_t cap, const char *s) {
    if (*pos > cap) return -1;
    size_t len = strlen(s);
    if (len > cap - *pos) return -1;
    memcpy(buf + *pos, s, len);
    *pos += len;
    return 0;
}

// 在 $XDG_RUNTIME_DIR/qutebrowser/ 下找第一个 ipc-* 文件
static char *find_socket(const char *runtime_dir) {
    static char path[PATH_MAX];
    int n = snprintf(path, sizeof(path), "%s/qutebrowser", runtime_dir);
    if (n < 0 || (size_t)n >= sizeof(path)) return NULL;

    DIR *dir = opendir(path);
    if (!dir) return NULL;

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (strncmp(ent->d_name, "ipc-", 4) != 0) continue;
        int m = snprintf(path, sizeof(path), "%s/qutebrowser/%s", runtime_dir, ent->d_name);
        if (m < 0 || (size_t)m >= sizeof(path)) continue;
        closedir(dir);
        return path;
    }
    closedir(dir);
    return NULL;
}

int main(int argc, char *argv[]) {
    // 回退 exec 用的 argv
    char **exec_argv = malloc((argc + 2) * sizeof(char *));
    if (!exec_argv) goto fallback;
    exec_argv[0] = "/usr/bin/qutebrowser";
    for (int i = 1; i < argc; i++) exec_argv[i] = argv[i];
    exec_argv[argc] = NULL;

    // 运行时目录
    const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
    char runtime_buf[64];
    if (!runtime_dir) {
        snprintf(runtime_buf, sizeof(runtime_buf), "/run/user/%d", getuid());
        runtime_dir = runtime_buf;
    }

    // 找 socket
    const char *sock_path = find_socket(runtime_dir);
    if (!sock_path) goto fallback;

    // 组装 JSON 消息。正文一律走 json_append / literal_append，上限统一为
    // sizeof(json) - 2 —— 剩下 2 字节留给收尾的 "}\n"，于是 pos 永远不会越界。
    static char json[8192];
    const size_t cap = sizeof(json) - 2;
    size_t pos = 0;
    if (literal_append(json, &pos, cap, "{\"args\":[") < 0) goto fallback;
    if (argc > 1) {
        for (int i = 1; i < argc; i++) {
            if (i > 1) {
                if (pos >= cap) goto fallback;
                json[pos++] = ',';
            }
            if (json_append(json, &pos, cap, argv[i]) < 0) goto fallback;
        }
    } else {
        if (literal_append(json, &pos, cap, "\"\"") < 0) goto fallback;
    }
    // 追加 target_arg, version, protocol_version
    if (literal_append(json, &pos, cap,
        "],\"target_arg\":null,\"version\":\"3.7.0\",\"protocol_version\":1") < 0) goto fallback;

    // 追加 cwd
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd))) {
        if (literal_append(json, &pos, cap, ",\"cwd\":") < 0) goto fallback;
        if (json_append(json, &pos, cap, cwd) < 0) goto fallback;
    }
    // 上面两个函数成功返回时保证 pos <= cap，这 2 字节一定放得下
    json[pos++] = '}';
    json[pos++] = '\n';

    // 连接 IPC socket
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) goto fallback;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t path_len = strlen(sock_path);
    if (path_len >= sizeof(addr.sun_path)) {
        close(fd);  // 别把这个 fd 留给 fallback 里 execve 出来的浏览器
        goto fallback;
    }
    memcpy(addr.sun_path, sock_path, path_len);
    socklen_t addr_len = offsetof(struct sockaddr_un, sun_path) + path_len;

    if (connect(fd, (struct sockaddr *)&addr, addr_len) < 0) {
        close(fd);
        goto fallback;
    }

    ssize_t sent = write(fd, json, pos);
    close(fd);
    if (sent != (ssize_t)pos) goto fallback;

    free(exec_argv);
    return 0;

fallback:
    execve("/usr/bin/qutebrowser", exec_argv ? exec_argv : argv, environ);
    return 1;
}
