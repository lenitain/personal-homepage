# A browser that is already open

qutebrowser takes about 1.2 seconds to start. A window appears, then a page. It
is not a slow program, but 1.2 seconds is long enough to notice, every time,
twenty times a day.

This series is a record of getting that down to 232 ms — and of what it actually
cost. None of it was about making the browser faster. The whole thing turned out
to be three decisions:

1. **[Is this worth daemonizing at all?](when-to-daemonize.md)** — a test, not a
   stopwatch. Most slow programs fail it, and the ones that pass are not the
   slowest ones.
2. **[Who kills it?](process-lifecycle.md)** — the half that is easy to skip and
   expensive to get wrong. Includes the PID namespace mistake I made, and the
   input method it took down with it.
3. **[What deserves RAM, and what doesn't?](qutebrowser-split.md)** — a browser
   profile is mostly dead bytes. Paying memory for all of it is the obvious move
   and the wrong one.
4. **[What should the fast half be written in?](qb-open-launcher.md)** — the same
   launcher in nine builds across five languages, measured for latency, syscall
   count, address space and size. Also: the buffer overflow that writing five of
   them uncovered in the one I had been shipping.

The one-line version: **keep the expensive part warm, give its lifecycle to
something that already understands lifecycles, and push everything dead back to
disk.**

## The result

|                        | before  | after   |
| ---------------------- | ------- | ------- |
| Time to open a page    | 1227 ms | 232 ms  |
| Resident cost          | 0       | 140 MiB |
| Processes in the tree  | 1       | 2–5     |
| Launcher cost          | —       | 317 µs  |
| Lifecycle guarantee    | none    | pid 1   |

## The code

All of it is in my dotfiles:

- **[qutebrowser config](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/qutebrowser/config.py)**
  — the cache decisions, in comments
- **[`qb-server`](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.local/bin/scripts/qb-server)**
  — qutebrowser, patched to stay alive at zero windows
- **[`qb-open`](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.local/bin/scripts/qb-open.c)**
  — the C launcher, 191 lines
- **[`qb-server.service`](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/systemd/user/qb-server.service)**
  — the lifecycle, delegated
