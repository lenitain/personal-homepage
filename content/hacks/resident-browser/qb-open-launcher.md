# What the launcher should be written in

The launcher is the least interesting program in this series. It finds a socket,
writes about a hundred bytes, and exits. There is no algorithm to speak of and
nothing to optimise.

That is exactly what makes it worth measuring. Strip the program away and what
is left is **the cost of becoming a process in a given language** — a number
that is normally impossible to isolate, because it is buried under whatever the
program was actually doing.

So I wrote the same launcher nine ways and measured it four ways.

## Method

- **Correctness gates the benchmark.** Every variant must emit byte-identical
  IPC messages to the shipped C binary across eight cases — two arguments, no
  argument, an empty argument, quotes and backslashes, newlines and tabs, C0
  control characters, raw UTF-8, and a 2000-byte argument. All eight pass on all
  nine variants. A launcher that is fast because it sends the wrong bytes is not
  a launcher.
- **Latency** is `fork` → `execve` → do the work → reaped, timed by a C harness
  with `clock_gettime` around `wait4`. Three rounds of 500 runs, pinned to one
  core, and the median of the three round-minimums is reported. The minimum is
  the run that got interfered with least, which on a machine with a desktop
  session on it is the closest thing to the intrinsic cost.
- **A floor binary.** A static binary whose entire body is `exit_group`. It does
  no work at all, so whatever it measures is what *every* variant pays just for
  being started. Without it, "300 microseconds" is uninterpretable.
- **Syscalls** from `strace`; **address space** from a `ptrace` stop immediately
  after `execve` succeeds, before the program has run a single instruction — the
  loader is done, the program has not started. Sampling `/proc` in a loop does
  not work against a process that lives for a fraction of a millisecond.

## The numbers

Times in microseconds. "Over floor" subtracts the 224 µs floor binary.

| Implementation          | min   | p50   | over floor | syscalls | VMAs | RSS at exec | size (stripped) |
| ----------------------- | ----- | ----- | ---------- | -------- | ---- | ----------- | --------------- |
| *(floor: just `exit`)*  | 224   | 246   | —          | 2        | 8    | 12 KB       | 8.5 KB          |
| x86-64 assembly         | **288** | **332** | **+63**  | **10**   | **9** | **12 KB**   | 8.9 KB          |
| C, musl, static         | 317   | 424   | +93        | 20       | 10   | 16 KB       | **46 KB**       |
| C, musl, dynamic        | 393   | 541   | +169       | 20       | 15   | 20 KB       | 14 KB           |
| Zig, static             | 442   | 562   | +218       | 15       | 9    | 12 KB       | 7.9 KB          |
| C, glibc, static        | 468   | 534   | +244       | 25       | 10   | 20 KB       | 826 KB          |
| Rust, static            | 469   | 603   | +245       | 47       | 10   | 24 KB       | 1.35 MB         |
| C, glibc, dynamic       | 586   | 759   | +362       | 42       | 15   | 20 KB       | 15 KB           |
| Rust, dynamic           | 751   | 1053  | +526       | 76       | 14   | 24 KB       | 394 KB          |
| Python 3                | 21402 | 28532 | +21178     | 862      | 14   | 20 KB       | 2.3 KB script   |

## Reading it

### The actual work costs about 63 microseconds

Assembly minus floor. Find a socket, write a message, exit — that is the entire
job, and at this scale it is a rounding error next to the cost of existing.
Everything above that line is what a language's runtime does before your code
gets to run.

Your language choice for a hot-path launcher is therefore not a choice about
syntax or expressiveness. It is a choice about **what starts up with you**.

### Static linking wins every pairing

| Pair                | dynamic | static | saved |
| ------------------- | ------- | ------ | ----- |
| C, musl             | 393     | 317    | 76 µs |
| C, glibc            | 586     | 468    | 118 µs |
| Rust                | 751     | 469    | 282 µs |

Three for three. The dynamic builds pay for `ld.so` to start, resolve symbols
and map libraries before `main` — visible in glibc's syscall trace as 8 `mmap`
calls and a pile of `openat`/`fstat` against the library cache.

But static is not free, it is *prepaid*:

- glibc static is **826 KB against 15 KB** — 56× the bytes for 118 µs.
- musl static is **46 KB**. That is the version of this trade that actually
  makes sense.

The size is not just disk. RSS at exec barely moves, but the number of mapped
pages does — which is why the glibc static build maps 1 MB of address space
before doing anything.

### A language with no runtime is the same process as assembly

Zig lands on **9 VMAs and 12 KB RSS**, identical to the hand-written assembly
version, with 15 syscalls against 10. There is no runtime to initialise. The
language compiles to the same kind of thing assembly does, and it shows up in the
process image.

### Rust's floor is `std`

Even stripped, static Rust is 1.35 MB and 47 syscalls, six of them `rt_sigaction`
and five `brk`. That is `std` setting up a runtime before your `main` runs — and
`main` here writes a hundred bytes to a socket. Most of the binary and most of
the syscalls are for machinery this program never uses.

### Python is 74 times the assembly version

Worth splitting apart, because "Python is slow" is not a useful statement:

| What                      | min      | added   |
| ------------------------- | -------- | ------- |
| `python3 -c pass`         | 10.6 ms  | —       |
| `+ import os`             | 10.6 ms  | ~0      |
| `+ import socket`         | 14.5 ms  | +3.9 ms |
| `+ import json`           | 18.8 ms  | +8.1 ms |
| `+ import json, socket`   | 21.9 ms  | +11.3 ms |
| the full launcher         | 22.5 ms  | +0.6 ms |

The interpreter is 10.6 ms. Importing two stdlib modules costs 11.3 ms — more
than the interpreter, and `json` alone costs twice what `socket` does. The actual
program — scan a directory, build a small object, write it to a socket — costs
**0.6 ms**. Roughly 3% of the runtime is the thing the program was written to do.

That ratio is the whole reason this project exists. The reason to write the
client in C was never that C is fast; it is that the 97% is avoidable.

## You can read each runtime off the syscall trace

The traces make the abstractions unusually concrete:

- **assembly** — 10 syscalls, and they are exactly the job: `openat`,
  `getdents64`, `socket`, `connect`, `getcwd`, `write`, `close`, `exit`.
  Nothing else happens.
- **C, musl, static** — 20: the extra 10 are libc initialising (`brk`, `mmap`,
  `set_tid_address`).
- **Zig** — 15, including `sigaltstack` and `prlimit64`. A little runtime, not
  much.
- **Rust, static** — 47. Six `rt_sigaction`, five `brk`, three `mprotect`.
- **C, glibc, dynamic** — 42, dominated by `ld.so` mapping and stat-ing
  libraries.
- **Python** — 862, and the shape of them is the import machinery: 138
  `newfstatat`, 101 `read`, 69 `openat`, 69 `fstat`, 62 `lseek`. Plus 149
  `clock_gettime`, which is Python timing its own imports.

## What I actually run

C, musl, static. 46 KB, 317 µs, 20 syscalls, no dynamic loader, and the whole
build is one `musl-gcc -static` line. The four remaining implementations exist
because I wanted the comparison to be honest, not because maintaining them is a
good idea.

The honest summary of the ranking: assembly is 37 KB smaller and 29 µs faster
than the C version, and costs 400 lines of hand-written assembly to get there.
Zig gets you assembly's process image with a language you can actually write, and
would be my choice starting from scratch — at the price of pinning the build to a
specific Zig version, which for a program this size is a bad trade against a
compiler that has been stable for decades.

## What writing five of them found

A real bug in the original C, which had been shipped and in daily use.

The code built its JSON with `snprintf` and added the return value to its write
offset. `snprintf` returns the length it *would* have written, so on truncation
the offset jumped past the end of the 8192-byte buffer, `sizeof(buf) - pos`
underflowed to `SIZE_MAX`, and the next write landed outside the array — in the
same `.bss` region as `environ`.

The consequence was not theoretical. With a single argument of about 8.1 KB or
more:

- usually the launcher scribbled past its buffer, `write()` ran off the end into
  unmapped memory, failed, and the fallback **cold-started a whole browser**
  instead of messaging the resident one
- in a narrow window around 8124–8130 bytes it clobbered `environ` with the
  ASCII of `,"cwd":`, so the fallback `execve` failed with `EFAULT` and the
  launcher exited 1 having done nothing at all

Every other port had bounds-checked appends from the start, which is the only
reason the difference showed up. The fix is a small `literal_append` helper that
shares one capacity limit with the escaping function, so no append can move the
offset past the end.

Five implementations of a ten-line program turned out to be a decent test suite.

## The line

> For a program on the hot path, you are not choosing a language. You are
> choosing what has to start up before your code does — and the answer is
> everything.

Back to [the series](index.md).
