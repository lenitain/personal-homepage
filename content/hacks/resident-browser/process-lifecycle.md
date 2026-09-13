# Who kills it

A resident browser is a process that outlives the thing that started it. That is
the whole point of [keeping it warm](when-to-daemonize.md) — and it is also a
promise to clean up later. One qutebrowser process is five processes: the
browser plus a small crowd of QtWebEngine helpers, one of which is a Chromium
renderer that will happily sit on a few hundred megabytes.

So the requirement is not "start it once". It is "start it once, and make sure
it dies".

## The obvious tool, and why it is a trap

Reach for a PID namespace. `unshare --pid --fork`, put the browser inside, and
now the kernel reaps the entire namespace when its init dies. Containment and
cleanup in one primitive.

It even works, which is what makes it a trap. Two things are wrong with it.

### It is an isolation primitive, not a lifecycle primitive

A PID namespace exists to make processes *invisible to each other*. "Everything
inside dies when init dies" is a side effect of that design, not a knob you can
turn on by itself. To get the side effect you have to accept the whole
primitive — including the user namespace that an unprivileged user must create
first, because only root gets a PID namespace on its own.

And the user namespace has a price. Your uid inside it is not your uid outside
it until you say so. Create it bare and the map is empty, so `getuid()` returns
the overflow uid — **65534**.

That breaks every mechanism that identifies you by number, starting with D-Bus:

- libdbus builds its `AUTH EXTERNAL` credential from `getuid()`
- dbus-broker compares it against the uid the kernel reports for that socket
  peer — 1000
- they disagree, the broker sends `REJECTED`, and there is no session bus

The symptom was that my input method vanished from the browser. Everything else
worked — pages rendered, video played, keyboard shortcuts fired. Only typing
Chinese was gone, because Wayland is a plain `connect()` on a socket that
exchanges no credentials, while fcitx5 is reached over the session bus. One
channel needs your identity; the other does not. That asymmetry is the entire
reason the bug was hard to read.

### It does not even do its own job well

The wrapper and the tree are different processes, and nothing forwards signals
between them. Kill `unshare` and the namespace init keeps running, with
everything under it.

The patches then arrive in the usual order:

1. `--kill-child`, so the wrapper takes the tree down when it dies
2. a supervisor process, to catch `SIGTERM` the wrapper never saw
3. `prctl(PR_SET_PDEATHSIG)`, for the case where the supervisor's own parent died

By the third patch the "simple namespace" is three processes deep and I have
written more lifecycle code than the original problem had.

## What the requirement actually was

Not *contain this tree*. **Know when the main process died, then sweep up the
rest.** That is two concrete things:

- a **cgroup** — the kernel-maintained set of processes to sweep
- **main-process tracking** — something that notices the main process exited, by
  any means, and acts on it

That is a supervisor. And I already had one: pid 1 of my user session.

## Three launchers, one difference

Same resident browser, same machine, started three ways. The only variable is
whether the cgroup has main-process tracking:

| Launcher                      | Main-process tracking | Main process dies → |
| ----------------------------- | --------------------- | ------------------- |
| bare `setsid`                 | none                  | orphans survive     |
| niri's `spawn-sh` (a scope)   | none — `MainPID` is empty | orphans survive |
| a systemd **service**         | yes, `MainPID`        | whole cgroup swept  |

The middle row is the one worth staring at. niri *does* put every `spawn-sh`
into its own cgroup, with `KillMode=control-group` — which reads exactly like
the thing I wanted. But a scope is not a service. Nothing in it is designated
the main process, so there is nothing whose death can be noticed. The scope goes
inactive once the cgroup empties, which is the event you needed it to *cause*.

So the fix is not a new mechanism. It is registering the process as the right
*kind* of thing, and letting the supervisor that already exists do its job.

## What that buys

The guarantee is pid1-level, which means it does not depend on the browser
cooperating — or on QtWebEngine exiting politely, or on my launcher forwarding
the right signal. Every way the process can end now ends the same way:

- `systemctl --user stop`
- `kill -9` on the main process
- quitting the browser from inside (`:quit`)
- logging out

Each one leaves zero processes behind. And the tree got *smaller*: supervisor
plus `unshare` plus browser became just browser. One process that is genuinely
there, instead of three that exist to manage each other.

The launcher script no longer knows systemd exists. Run it by hand from a
terminal and it behaves identically — you just don't get the cleanup.

## The line

> When you need a lifecycle guarantee, find the thing that already owns
> lifecycles. Isolation primitives make bad supervisors.

Next: [where to draw the line](qutebrowser-split.md) between what stays in RAM
and what goes back to disk.
