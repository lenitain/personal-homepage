# Daemonize the separable, not the slow

Every guide to making a slow program feel fast eventually suggests the same
trick: start it once, keep it running, talk to it over a socket. It works. It is
also usually the wrong default, because it is sold as a *speed* trick when it is
actually a *memory* trade.

You are not deleting the startup cost. You are paying it once and then renting
the result forever. Whether that is a good deal depends on something much more
specific than "is this program slow".

## The question that actually decides it

Not *how slow is it* — but **is the slow part separable from the part that
depends on what I asked for?**

Concretely, is there a large body of work that:

- happens *before* the program knows what you want, and
- produces the same result every single time?

For a browser, yes. Python interpreter, Qt, the Chromium engine, the adblock
rules, the profile: all of that is identical whether you are about to open one
tab or fifty. It is pure preamble. About a second of it, on my machine.

For a compiler, no. Startup is a rounding error. The time goes into reading
*your* source and emitting *your* binary — work that cannot begin until you say
what to build. There is nothing to keep warm, because nothing is repeated.

That distinction, not the stopwatch, is what separates the two.

## The bill

I assumed this would be the deciding factor, and I had the price written down as
"700 MB to 1 GB, even at zero windows". Both halves of that turned out to be
wrong. Measured on my machine:

| State                                     | Memory  |
| ----------------------------------------- | ------- |
| Resident, zero windows, my real profile   | 140 MiB |
| Resident, with a few tabs open            | 2.1 GiB |

The floor is seven times smaller than I had assumed — and it barely moved when I
swapped an empty profile for my real one (136 MiB against 140 MiB), so the
profile is not what you are paying for either.

What pushes it into the gigabytes is *use*: page renderers and their JavaScript
heaps accumulate as you browse. Those are not the daemon's fault, because a
non-resident browser pays exactly the same once it has those tabs open. The
resident design only adds the floor.

So the frequency argument is far weaker than the memory cost suggested it would
be:

- Open the browser 20 times a day: ~20 s/day bought back, for 140 MiB.
- Open it once a month: 140 MiB held to save one second.

On any machine that can run the browser at all, the second line is not obviously
a bad deal. Which means **separability is doing nearly all of the work** in this
decision. Memory is a real cost but a small one; what actually disqualifies a
program is not being expensive, it is having nothing separable to keep.

## The costs nobody mentions

Memory is the visible price. There are two quieter ones.

**A resident process is a snapshot of your config from the moment it started.**
Every edit now needs a second step — restart it — and forgetting that step looks
exactly like a bug in the config. You have traded "slow to start" for "silently
stale", which is a worse failure mode.

**A process you start once and never stop is a process you have to be able to
kill.** Get this wrong and you do not get a slow browser back; you get orphaned
renderer processes holding memory until you reboot. This is the part that
actually bit me, and it has [its own article](process-lifecycle.md).

## Same pattern, different plumbing

Ghostty does the same thing for terminals: a resident process, fast clients,
new windows created by IPC ([Ghostty: Linux systemd
integration](https://ghostty.org/docs/linux/systemd)). Internally it looks quite
different from what I do — D-Bus and systemd rather than a raw Unix socket — but
the shape is identical, because the shape is dictated by the criteria above, not
by taste. Start the heavy process once, pay the preamble once, send a message
per window.

The idea is portable. The plumbing is where the interesting mistakes live.

## The line

> Daemonize the part of a program whose cost is constant and repeated. Leave
> everything that depends on the request as slow as it needs to be.

For a browser that line falls between the engine and the window, which is what
the rest of this series is about:

- [Who kills it](process-lifecycle.md) — the lifecycle half, and why a PID
  namespace is the wrong tool for it
- [What deserves RAM](qutebrowser-split.md) — where exactly to draw the line
- [The launcher's language](qb-open-launcher.md) — what the fast half should be
  written in, measured
