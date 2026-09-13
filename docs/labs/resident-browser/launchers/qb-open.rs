// qb-open: qutebrowser 快速客户端（毫秒级）—— qb-open.c 的 Rust 移植。
//
// 直接向常驻实例（qb-server）的 IPC socket 写 JSON，不启动 Python/Qt。
// 无参数 = 按配置 new_instance_open_target（默认 tab）打开，无窗口则新建。
// 常驻 server 未运行（socket 不存在）时回退 exec /usr/bin/qutebrowser 冷启动。
//
// socket 路径: $XDG_RUNTIME_DIR/qutebrowser/ipc-*（扫描目录取第一个 ipc-* 文件，
// 不依赖 qutebrowser 的 md5(用户名) 命名算法，将来算法变更也不受影响）
//
// 构建（std only，零外部 crate）:
//   rustc -O -o qb-open-rust-dyn qb-open.rs
//   rustc -O -C target-feature=+crt-static -o qb-open-rust-static qb-open.rs
//
// 用法: qb-open [URL...]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{Cursor, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{self, Command};

// libc 里本来就有的东西，直接 extern 声明，不引入任何 crate。
extern "C" {
    fn getuid() -> u32;
    fn signal(signum: i32, handler: usize) -> usize;
}

const LAUNCHER: &str = "/usr/bin/qutebrowser";
const SOCK_DIR: &[u8] = b"qutebrowser";
const SOCK_PREFIX: &[u8] = b"ipc-";
const PATH_MAX: usize = 4096; // Linux PATH_MAX，对应 C 的 char path[PATH_MAX]
const JSON_CAP: usize = 8192; // 对应 C 的 static char json[8192]
const APPEND_CAP: usize = JSON_CAP - 2; // 对应 C 的 sizeof(json) - 2
const SIGPIPE: i32 = 13;
const SIG_DFL: usize = 0;

const JSON_HEAD: &[u8] = b"{\"args\":[";
const JSON_TAIL: &[u8] =
    b"],\"target_arg\":null,\"version\":\"3.7.0\",\"protocol_version\":1";
const CWD_KEY: &[u8] = b",\"cwd\":";
const HEX: &[u8; 16] = b"0123456789abcdef";

// 对应 C 的 static char json[8192] + size_t pos
struct Json {
    buf: [u8; JSON_CAP],
    pos: usize,
}

impl Json {
    fn new() -> Json {
        Json {
            buf: [0u8; JSON_CAP],
            pos: 0,
        }
    }

    // 追加原始字节。limit 是绝对上界，语义同 C 里 snprintf 的
    // 「json + pos / sizeof(json) - pos」组合，即最多写到 buf[limit]。
    fn push(&mut self, bytes: &[u8], limit: usize) -> Result<(), ()> {
        if self.pos > limit || bytes.len() > limit - self.pos {
            return Err(());
        }
        self.buf[self.pos..self.pos + bytes.len()].copy_from_slice(bytes);
        self.pos += bytes.len();
        Ok(())
    }

    // 对应 C 的 json_append：加引号 + JSON 转义后追加。
    fn push_json_string(&mut self, s: &[u8], limit: usize) -> Result<(), ()> {
        self.push(b"\"", limit)?;
        for &b in s {
            if self.pos >= limit {
                return Err(());
            }
            if b == 0 {
                break; // C 的 for (; *s; s++) 遇 NUL 终止
            }
            match b {
                b'"' => self.push(b"\\\"", limit)?,
                b'\\' => self.push(b"\\\\", limit)?,
                b'\n' => self.push(b"\\n", limit)?,
                b'\r' => self.push(b"\\r", limit)?,
                b'\t' => self.push(b"\\t", limit)?,
                0x00..=0x1f => {
                    // C: snprintf("\\u%04x") 需要 6 字节，放不下就返回 -1
                    if self.pos + 6 > limit {
                        return Err(());
                    }
                    self.buf[self.pos] = b'\\';
                    self.buf[self.pos + 1] = b'u';
                    self.buf[self.pos + 2] = b'0';
                    self.buf[self.pos + 3] = b'0';
                    self.buf[self.pos + 4] = HEX[(b >> 4) as usize];
                    self.buf[self.pos + 5] = HEX[(b & 0x0f) as usize];
                    self.pos += 6;
                }
                _ => {
                    self.buf[self.pos] = b;
                    self.pos += 1;
                }
            }
        }
        self.push(b"\"", limit)
    }
}

// 组装 JSON 消息，成功返回写入长度（json.pos）。
fn build_message(json: &mut Json, args: &[OsString]) -> Result<(), ()> {
    json.push(JSON_HEAD, APPEND_CAP)?;
    if args.is_empty() {
        json.push(b"\"\"", APPEND_CAP)?; // 无参数 -> [""]
    } else {
        for (i, arg) in args.iter().enumerate() {
            if i > 0 {
                json.push(b",", APPEND_CAP)?;
            }
            json.push_json_string(arg.as_bytes(), APPEND_CAP)?;
        }
    }
    // 追加 target_arg, version, protocol_version
    // （对应 snprintf(..., sizeof(json) - pos, ...)：绝对上界是 JSON_CAP - 1，
    //  因为 snprintf 还要给结尾的 NUL 留一格）
    json.push(JSON_TAIL, JSON_CAP - 1)?;

    // 追加 cwd；getcwd 失败就整段省略
    if let Ok(cwd) = env::current_dir() {
        json.push(CWD_KEY, JSON_CAP - 1)?;
        json.push_json_string(cwd.as_os_str().as_bytes(), APPEND_CAP)?;
    }
    json.push(b"}\n", JSON_CAP)?;
    Ok(())
}

// 在 $XDG_RUNTIME_DIR/qutebrowser/ 下找第一个 ipc-* 文件。
fn find_socket(runtime_dir: &[u8]) -> Option<Vec<u8>> {
    let mut dir = Vec::with_capacity(runtime_dir.len() + 1 + SOCK_DIR.len());
    dir.extend_from_slice(runtime_dir);
    dir.push(b'/');
    dir.extend_from_slice(SOCK_DIR);
    if dir.len() >= PATH_MAX {
        return None; // C: snprintf 截断 -> NULL
    }

    // readdir 顺序 = 目录顺序，不排序：第一个 ipc-* 就是结果。
    for ent in fs::read_dir(OsStr::from_bytes(&dir)).ok()? {
        let name = match ent {
            Ok(e) => e.file_name(),
            Err(_) => break, // C: readdir 返回 NULL 即结束循环
        };
        let name = name.as_bytes();
        if !name.starts_with(SOCK_PREFIX) {
            continue;
        }
        let mut full = Vec::with_capacity(dir.len() + 1 + name.len());
        full.extend_from_slice(&dir);
        full.push(b'/');
        full.extend_from_slice(name);
        if full.len() >= PATH_MAX {
            continue; // C: 路径太长就跳过这一项，继续扫
        }
        return Some(full);
    }
    None
}

// 连 socket、写 JSON、关闭。只有「一次写全」才算成功（同 C 的单次 write）。
fn send_json(sock_path: &[u8], msg: &[u8]) -> bool {
    let mut stream = match UnixStream::connect(OsStr::from_bytes(sock_path)) {
        Ok(s) => s,
        Err(_) => return false, // socket() 或 connect() 失败
    };
    let sent = stream.write(msg);
    drop(stream); // close(fd)
    matches!(sent, Ok(n) if n == msg.len())
}

// 对应 C 的 fallback: execve("/usr/bin/qutebrowser", exec_argv, environ);
// exec_argv = {"/usr/bin/qutebrowser", argv[1..], NULL}
fn fallback(args: &[OsString]) -> ! {
    let _ = Command::new(LAUNCHER).args(args).exec();
    process::exit(1);
}

fn main() {
    // C 版本从不碰 SIGPIPE 的处置（默认 SIG_DFL）；Rust 运行时默认改成 SIG_IGN，
    // 这里恢复默认，保证「对端已关闭 -> 被 SIGPIPE 杀掉」这一行为与 C 一致。
    unsafe {
        signal(SIGPIPE, SIG_DFL);
    }

    // 回退 exec 用的 argv（不含 argv[0]）
    let args: Vec<OsString> = env::args_os().skip(1).collect();

    // 组装 JSON 消息
    let mut json = Json::new();
    if build_message(&mut json, &args).is_err() {
        fallback(&args); // C: json_append 失败也是 goto fallback
    }
    let msg = &json.buf[..json.pos];

    // 运行时目录：$XDG_RUNTIME_DIR，未设置时 /run/user/<uid>
    let xdg = env::var_os("XDG_RUNTIME_DIR");
    let mut uid_buf = [0u8; 64]; // C: char runtime_buf[64]
    let runtime_dir: &[u8] = match xdg.as_deref() {
        Some(dir) => dir.as_bytes(),
        None => {
            let mut cur = Cursor::new(&mut uid_buf[..]);
            // C 用 "%d" 打印 uid_t，这里保持同样的有符号语义
            let _ = write!(cur, "/run/user/{}", unsafe { getuid() } as i32);
            let n = cur.position() as usize;
            &uid_buf[..n]
        }
    };

    // 找 socket 并发送
    if let Some(sock_path) = find_socket(runtime_dir) {
        if send_json(&sock_path, msg) {
            return; // 成功：exit 0
        }
    }

    fallback(&args);
}
