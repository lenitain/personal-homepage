// qb-open: qutebrowser 快速客户端（Zig 移植，逐字节对齐 qb-open.c 的线格式）。
//
// 直接向常驻实例（qb-server）的 IPC socket 写 JSON，不启动 Python/Qt。
// 无参数 = 按配置 new_instance_open_target（默认 tab）打开，无窗口则新建。
// 常驻 server 未运行（socket 不存在）时回退 exec /usr/bin/qutebrowser 冷启动。
//
// socket 路径: $XDG_RUNTIME_DIR/qutebrowser/ipc-*（扫描目录取第一个 ipc-* 文件，
// 不依赖 qutebrowser 的 md5(用户名) 命名算法，将来算法变更也不受影响）
//
// 实现说明（Zig 0.16）：只用 std，不链接 libc；syscall 直接走 std.os.linux，
// 全程零堆分配（不需要 allocator），main 只收 Init.Minimal，因此启动路径上没有
// std.Io.Threaded / DebugAllocator / environ map 这些 0.16 默认会做的工作。
//
// 构建（静态，无 libc，零运行时依赖）:
//   zig build-exe -O ReleaseFast -femit-bin=bin/qb-open-zig src/qb-open.zig
//
// 用法: qb-open-zig [URL...]

const std = @import("std");
const linux = std.os.linux;

const exec_path = "/usr/bin/qutebrowser";

/// 回退 exec 时预留给 argv 指针数组的栈槽位（超过则退回原始 argv，见 execArgv）。
const exec_argv_slots = 1024;

/// 与 C 版一致的静态缓冲尺寸。
const json_capacity = 8192;
const path_capacity = 4096;

/// 固定消息尾部，与 C 版 snprintf 的字面量逐字节相同。
const json_tail = "],\"target_arg\":null,\"version\":\"3.7.0\",\"protocol_version\":1";
const cwd_prefix = ",\"cwd\":";

/// syscall 返回值是否表示出错（linux.errno 把 -errno 解成 E）。
fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

/// 在 environ 块里找 name=...，返回 '=' 之后的部分（等价 getenv，但不分配）。
fn getEnv(envp: []const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    for (envp) |maybe_entry| {
        const entry = maybe_entry orelse continue;
        const line = std.mem.span(entry);
        if (line.len > name.len and line[name.len] == '=' and
            std.mem.eql(u8, line[0..name.len], name))
        {
            return line[name.len + 1 ..];
        }
    }
    return null;
}

/// JSON 字符串转义，规则与 C 版 json_append 完全一致：
/// `"` `\` `\n` `\r` `\t` 转义；0x00-0x1f 写成 \u00xx（小写十六进制）；
/// 其余字节（含 0x7f 与 0x80-0xff）原样输出。cap 是绝对上限，成功返回 true。
fn jsonAppend(buf: []u8, pos: *usize, cap: usize, s: []const u8) bool {
    const hex = "0123456789abcdef";

    if (pos.* >= cap) return false;
    buf[pos.*] = '"';
    pos.* += 1;

    for (s) |c| {
        if (pos.* >= cap) return false;
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => {
                if (pos.* + 2 > cap) return false;
                buf[pos.*] = '\\';
                buf[pos.* + 1] = switch (c) {
                    '"' => '"',
                    '\\' => '\\',
                    '\n' => 'n',
                    '\r' => 'r',
                    else => 't',
                };
                pos.* += 2;
            },
            else => {
                if (c <= 0x1f) {
                    // snprintf("\\u%04x", (unsigned char)c)：总是 6 字节
                    if (pos.* + 6 > cap) return false;
                    buf[pos.*] = '\\';
                    buf[pos.* + 1] = 'u';
                    buf[pos.* + 2] = '0';
                    buf[pos.* + 3] = '0';
                    buf[pos.* + 4] = hex[c >> 4];
                    buf[pos.* + 5] = hex[c & 0xf];
                    pos.* += 6;
                } else {
                    buf[pos.*] = c;
                    pos.* += 1;
                }
            },
        }
    }

    if (pos.* >= cap) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    return true;
}

/// 把若干片段拼进 buf，返回 NUL 结尾的 C 路径；放不下返回 null
/// （对应 C 版 snprintf 返回 >= sizeof(path) 的情形）。
fn joinPathZ(buf: []u8, parts: []const []const u8) ?[*:0]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        if (len + part.len + 1 > buf.len) return null;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

/// 在 <runtime_dir>/qutebrowser/ 下找第一个 ipc-* 条目，返回非 NUL 结尾的路径切片。
/// 与 C 版一致：不 stat、不判断类型，目录打不开/没有 ipc-* 条目都返回 null。
fn findSocket(runtime_dir: []const u8, buf: []u8) ?[]const u8 {
    const dir_path = joinPathZ(buf, &.{ runtime_dir, "/qutebrowser" }) orelse return null;

    const open_rc = linux.openat(linux.AT.FDCWD, dir_path, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (failed(open_rc)) return null;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    var dent_buf: [4096]u8 align(@alignOf(u64)) = undefined;
    while (true) {
        const rc = linux.getdents64(fd, &dent_buf, dent_buf.len);
        if (failed(rc)) return null;
        const n: usize = rc;
        if (n == 0) return null;

        var index: usize = 0;
        while (index < n) {
            // Linux 不保证记录对齐，std 自己也用 align(1) 读。
            const entry: *align(1) const linux.dirent64 = @ptrCast(&dent_buf[index]);
            if (entry.reclen == 0) return null;
            const name_ptr: [*]const u8 = &entry.name;
            const padded = name_ptr[0 .. entry.reclen - @offsetOf(linux.dirent64, "name")];
            const name_len = std.mem.findScalar(u8, padded, 0) orelse return null;
            const name = name_ptr[0..name_len];

            if (std.mem.startsWith(u8, name, "ipc-")) {
                // C 版超长时 continue 看下一个条目，不直接回退。
                if (joinPathZ(buf, &.{ runtime_dir, "/qutebrowser/", name })) |p| {
                    return std.mem.span(p);
                }
            }
            index += entry.reclen;
        }
    }
}

/// 回退 exec 的 argv：argv[0] 换成 /usr/bin/qutebrowser，其余原样透传。
/// C 版用 malloc 失败时退回原始 argv；这里把「槽位不够」当作同一情形。
fn execArgv(
    argv: []const [*:0]const u8,
    storage: *[exec_argv_slots]?[*:0]const u8,
) [*:null]const ?[*:0]const u8 {
    if (argv.len == 0 or argv.len + 1 > storage.len) return @ptrCast(argv.ptr);
    storage[0] = exec_path;
    for (argv[1..], 1..) |arg, i| storage[i] = arg;
    storage[argv.len] = null;
    return @ptrCast(storage);
}

fn execFallback(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) u8 {
    _ = linux.execve(exec_path, argv, envp);
    return 1;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    const envp = init.environ.block.slice;

    // 回退用的 argv（先建好，任何一步失败都能直接 exec）
    var exec_argv_storage: [exec_argv_slots]?[*:0]const u8 = undefined;
    const fallback_argv = execArgv(argv, &exec_argv_storage);

    // 运行时目录：$XDG_RUNTIME_DIR，未设置则 /run/user/<uid>
    var runtime_buf: [64]u8 = undefined;
    const runtime_dir: []const u8 = getEnv(envp, "XDG_RUNTIME_DIR") orelse
        (std.fmt.bufPrint(&runtime_buf, "/run/user/{d}", .{linux.getuid()}) catch
            return execFallback(fallback_argv, envp.ptr));

    // 找 socket
    var socket_path_buf: [path_capacity]u8 = undefined;
    const sock_path = findSocket(runtime_dir, &socket_path_buf) orelse
        return execFallback(fallback_argv, envp.ptr);

    // 组装 JSON 消息（转义上限与 C 版一样是 sizeof(json) - 2）
    var json: [json_capacity]u8 = undefined;
    const escape_cap = json.len - 2;
    var pos: usize = 0;

    const head = "{\"args\":[";
    @memcpy(json[pos..][0..head.len], head);
    pos += head.len;

    if (argv.len > 1) {
        for (argv[1..], 1..) |arg, i| {
            if (i > 1) {
                json[pos] = ',';
                pos += 1;
            }
            if (!jsonAppend(&json, &pos, escape_cap, std.mem.span(arg)))
                return execFallback(fallback_argv, envp.ptr);
        }
    } else {
        @memcpy(json[pos..][0..2], "\"\"");
        pos += 2;
    }

    // 尾部拼接：C 版用 snprintf(json + pos, sizeof(json) - pos, ...)，需要多留 1 字节给 NUL，
    // 否则就是 C 版的越界写（那属于未定义行为，这里改成回退）。
    if (json_tail.len >= json.len - pos) return execFallback(fallback_argv, envp.ptr);
    @memcpy(json[pos..][0..json_tail.len], json_tail);
    pos += json_tail.len;

    // cwd：getcwd 失败就整段省略
    var cwd_buf: [path_capacity]u8 = @splat(0);
    const cwd_rc = linux.getcwd(&cwd_buf, cwd_buf.len);
    if (!failed(cwd_rc)) {
        const cwd = std.mem.sliceTo(&cwd_buf, 0);
        if (cwd_prefix.len >= json.len - pos) return execFallback(fallback_argv, envp.ptr);
        @memcpy(json[pos..][0..cwd_prefix.len], cwd_prefix);
        pos += cwd_prefix.len;
        if (!jsonAppend(&json, &pos, escape_cap, cwd))
            return execFallback(fallback_argv, envp.ptr);
    }

    if (pos + 2 > json.len) return execFallback(fallback_argv, envp.ptr);
    json[pos] = '}';
    json[pos + 1] = '\n';
    pos += 2;

    // 连接 IPC socket
    const socket_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (failed(socket_rc)) return execFallback(fallback_argv, envp.ptr);
    const fd: i32 = @intCast(socket_rc);

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = [_]u8{0} ** 108 };
    if (sock_path.len >= addr.path.len) {
        _ = linux.close(fd);
        return execFallback(fallback_argv, envp.ptr);
    }
    @memcpy(addr.path[0..sock_path.len], sock_path);
    const addr_len: linux.socklen_t =
        @offsetOf(linux.sockaddr.un, "path") + @as(linux.socklen_t, @intCast(sock_path.len));

    if (failed(linux.connect(fd, &addr, addr_len))) {
        _ = linux.close(fd);
        return execFallback(fallback_argv, envp.ptr);
    }

    const sent = linux.write(fd, &json, pos);
    _ = linux.close(fd);
    if (failed(sent) or sent != pos) return execFallback(fallback_argv, envp.ptr);

    return 0;
}
