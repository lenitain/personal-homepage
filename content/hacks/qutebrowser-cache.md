# Caching by hand: how my qutebrowser opens in milliseconds

## Why this is about caching, not speed

Opening qutebrowser builds the whole stack from scratch every time: Python interpreter → Qt → QtWebEngine (Chromium) → adblock parse → profile load. So the real question isn't "speed up qutebrowser" but what deserves to stay warm, and where? That's a caching decision.

## The first move: keep the browser warm

Run the browser once, push links to it over a Unix socket. Opening a link = a message, not a reboot.

- **`qb-server`** — qutebrowser itself, launched once at login with `--nowindow -R`, patched to stay alive (`on_last_window_closed`) and open windows on demand (`get_window`).
- **`qb-open`** — A script written in C. It writes one JSON line to the IPC socket and exits. No socket → falls back to cold start.

## Cost and benefit

~700 MB–1 GB resident, even at zero windows. Here's what that memory buys:

| Scenario                   | median  | min     | max     |
| -------------------------- | ------- | ------- | ------- |
| Cold start (`qutebrowser`) | 1227 ms | 1167 ms | 1263 ms |
| Resident (`qb-open`)       | 232 ms  | 221 ms  | 254 ms  |

Time was measured from the launch command to the page being loaded and visible, not just a window appearing. Same URL (a local page, real HTTP, no network jitter), 8 runs each.

The ~1 s that vanishes is the whole Python → Qt → WebEngine chain, rebuilt every time. The ~230 ms left is the cost of creating a window and loading the page.

## What deserves memory, and what doesn't

**Live data → RAM. Dead cache → disk.**

| Kind        | Example                         | Where          | Why                      |
| ----------- | ------------------------------- | -------------- | ------------------------ |
| Live        | running browser, profile writes | RAM            | hot, small, must persist |
| Dead cached | shader cache, HTTP cache        | disk           | rebuildable, large, cold |
| Page state  | DOM, JS, media, connections     | freed on close | belongs to the page      |

### Live data: the profile in RAM

The profile's hot writes (history, cookies, localStorage) are small, frequent, and persistent, so they belong in RAM. To get them there, profile-sync-daemon (PSD) puts the profile on an overlayfs.

overlayfs shows two directories as one: a read-only layer on disk underneath and a writable layer on tmpfs above. Files you never touch are still read from disk; the first time you write one, it's copied up into the tmpfs layer.

PSD can't mount the kernel overlayfs directly, because that needs root and the profile lives under `$HOME`. So it uses fuse-overlayfs, a user-space version of the same idea running over FUSE.

PSD builds the overlay from the on-disk backup (read-only, below) and a tmpfs (writable, above), then points the profile at it. Hot writes land in the tmpfs, and an hourly resync writes them back to the disk backup.

The result is that only files you actually write ever reach RAM, so it's a small delta, not the whole 70 MB profile.

### Dead cached: kept on disk

- **GPU shader cache (~16 MB)** — rewritten every start; in PSD's overlay it gets copied up into unreclaimable RAM for nothing. `c.qt.args = ['disable-gpu-shader-disk-cache']`.
- **HTTP disk cache** — can balloon to GB (video segments), rebuildable, LRU-evicted. Disk + reclaimable page cache, not RAM. `c.content.cache.size = 320 * 1024 * 1024`.

### Page state: freed on close

DOM / JS / media / connections die with the tab. The lingering renderer isn't a leak — it's shared across tabs. Nothing holds a closed page.

## Why a Python server, a C launcher

The server is qutebrowser, kept resident. It's Python because that's what qutebrowser is.

The launcher sits on the hot path. A Python version has to start the interpreter and import `socket` and `json` before it can reach the socket: about 25 ms. A C binary has no interpreter or imports to pay: it just lists the socket and does one write, in about 2–4 ms.

## The takeaway

"Fast" isn't "everything in RAM." It's deciding what's alive (RAM) and what's dead (disk), and paying memory only where it buys speed.

It's all in my dotfiles:

- **qutebrowser config** — [dotfiles/.config/qutebrowser/config.py](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/qutebrowser/config.py)
- **`qb-server`** (resident server) — [scripts/qb-server](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/niri/scripts/qb-server)
- **`qb-open`** (the C client) — [scripts/qb-open.C](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/niri/scripts/qb-open.C)

## The same pattern elsewhere

Ghostty uses a similar resident-process + fast-client architecture, but routes through D-Bus and systemd instead of a raw Unix socket: [Ghostty: Linux systemd integration](https://ghostty.org/docs/linux/systemd). The idea is the same — start the heavy process once, pay startup cost once, send IPC messages to create windows. The difference is the plumbing: D-Bus adds a broker layer for process discovery and message routing, while `qb-open` connects to the socket directly.
