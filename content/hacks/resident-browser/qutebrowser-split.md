# What deserves RAM

Once the browser is [resident](when-to-daemonize.md), the obvious next move is
to put its data in RAM too. That move is wrong, and it is wrong in an
interesting way: a browser profile is mostly *dead*. Copying it into memory buys
you nothing and costs you a permanent allocation.

So the real question is not "how much can I fit in RAM". It is **which bytes are
alive**.

## What the resident copy buys

Measured on my machine, same URL, same local page over real HTTP, 8 runs each,
timed from the launch command to the page being loaded and visible — not just a
window appearing:

| Scenario                   | median  | min     | max     |
| -------------------------- | ------- | ------- | ------- |
| Cold start (`qutebrowser`) | 1227 ms | 1167 ms | 1263 ms |
| Resident (`qb-open`)       | 232 ms  | 221 ms  | 254 ms  |

The vanished second is the whole Python → Qt → WebEngine chain being rebuilt.
What is left is the honest cost of the thing you actually asked for: make a
window and load a page in it.

Now the discipline is to not waste the memory that bought that second.

## Three kinds of bytes

| Kind         | Example                         | Where          | Why                      |
| ------------ | ------------------------------- | -------------- | ------------------------ |
| Live         | running browser, profile writes | RAM            | hot, small, must persist |
| Dead cached  | shader cache, HTTP cache        | disk           | rebuildable, large, cold |
| Page state   | DOM, JS, media, connections     | freed on close | belongs to the page      |

The middle row is where the money is. Both of those caches *look* like things
you would want in RAM, and both are things you should actively push out.

## Live: the profile, and only its delta

The profile is where the browser writes history, cookies and localStorage. Small,
constant, and it must survive a reboot — so RAM is the right home for it, and the
naive way to get it there is to copy the whole thing onto a tmpfs at login.

That is the wrong way, because most of a profile is never touched in a session.
You would be paying memory for files that only ever get read.

Instead, profile-sync-daemon puts the profile on an **overlayfs**: a read-only
layer on disk underneath, a writable layer on tmpfs above. Files you never write
are still read straight from disk; the first time you write one, it is copied up
into the tmpfs layer.

PSD cannot use the kernel's overlayfs for this, because mounting one needs root
and the profile lives under `$HOME`. So it uses **fuse-overlayfs** — the same
idea implemented over FUSE, which an ordinary user can mount. An hourly resync
writes the accumulated delta back to the on-disk backup.

The result is that RAM holds the *delta*, not the profile. On my machine that
profile is 12 MB, and the resident part is smaller still.

You can see how well this works by measuring the whole thing. A resident browser
with my real profile loaded and no windows open costs **140 MiB**; the same
browser with an empty profile costs 136 MiB. Four megabytes of difference for a
12 MB profile that has been in daily use — which is the overlay doing its job.
Everything above that floor is pages you actually opened.

## Dead cached: two things to evict on purpose

### The GPU shader cache

QtWebEngine writes a compiled shader cache next to the profile, and rewrites it
on every start. Under PSD's overlay, "rewritten on every start" means "copied up
into RAM on every start" — an allocation that is large, dirty, and cannot be
reclaimed, in exchange for saving work that was never going to be repeated.

So turn it off. Shaders get compiled in-process instead.

There is a catch worth noticing: that trade is only free *because* the browser is
resident. With a cold start you would be recompiling shaders on every launch and
paying real time for it. Once there is one long-lived instance, shaders are
compiled once per session and the disk cache has nothing left to save. The
[daemon decision](when-to-daemonize.md) is what makes this optimisation legal.

### The HTTP disk cache

This one genuinely does deserve to be big, and it genuinely belongs on disk. It
holds page resources and can reach hundreds of megabytes — video segments alone
will do it. All of it is rebuildable by refetching, and it is evicted LRU, so it
is a cache in the honest sense.

On disk it costs page cache, which the kernel can drop under pressure. In an
anonymous tmpfs it would cost memory that nothing can reclaim. Cap it, put it on
disk, and let the kernel decide when those pages are worth keeping.

## Page state: freed on close

DOM, JavaScript heaps, decoded media and open connections die with the tab. None
of it outlives the page that created it, and none of it needs managing.

One thing that looks like a leak and is not: after you close every window, a
QtWebEngine renderer process is still there. It is not holding a closed page. It
is shared infrastructure waiting for the next one — which is exactly the point of
the resident design.

## The line

> Fast is not "everything in RAM". It is deciding what is alive and what is
> dead, and paying memory only for the first.

Next: [what the fast half should be written
in](qb-open-launcher.md) — measured across five languages.
