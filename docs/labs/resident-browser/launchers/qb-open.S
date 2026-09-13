/* qb-open, in x86-64 assembly. Free-standing: no libc, no dynamic loader,
 * no runtime of any kind. Talks to the kernel through syscall(2) directly.
 *
 * This exists to answer one question with a measurement instead of an opinion:
 * of the ~2-4 ms the C version costs, how much is the *language* and how much
 * is the *libc*? A static musl C build still drags in a libc; this drags in
 * nothing. Whatever is left is the irreducible cost of being a process.
 *
 * Every syscall number and struct offset below is from the x86-64 Linux ABI:
 *   struct linux_dirent64 { u64 d_ino; s64 d_off; u16 d_reclen;
 *                           u8 d_type; char d_name[]; }
 *   offsets:                  0          8           16        18      19
 *
 * Register contract, held for the whole program:
 *   r13 = argc          r14 = argv          r15 = envp
 *   rbx = jsonbuf base  r12 = json write cursor
 * Helpers may clobber rax, rcx, rdx, rsi, rdi, r8-r11 and nothing else.
 *
 * Build:
 *   as -o qb-open.o qb-open.S
 *   ld -o qb-open qb-open.o
 */

.intel_syntax noprefix

.set SYS_write,       1
.set SYS_close,       3
.set SYS_socket,     41
.set SYS_connect,    42
.set SYS_execve,     59
.set SYS_exit,       60
.set SYS_getcwd,     79
.set SYS_getuid,    102
.set SYS_getdents64, 217
.set SYS_openat,    257

.set AT_FDCWD,       -100
.set O_RDONLY,          0
.set O_DIRECTORY,  0x10000
.set AF_UNIX,           1
.set SOCK_STREAM,       1

.set D_RECLEN_OFF,     16
.set D_NAME_OFF,       19
.set MIN_RECLEN,       23

/* Mirrors the C version's `sizeof(json) - 2` overflow guard. */
.set JSON_CAP,       8180
.set DIRENT_CAP,    32768

.section .bss
.align 16
runtime_ptr:  .skip 8
dirfd:        .skip 8
sockfd:       .skip 8
socklen:      .skip 8
scan_bytes:   .skip 8
scan_cursor:  .skip 8
numtmp:       .skip 32
runtime:      .skip 64
dirpath:      .skip 4096
sockaddr:     .skip 128
cwdbuf:       .skip 4096
jsonbuf:      .skip 8192
dirent:       .skip DIRENT_CAP

.section .rodata
hexdigits:      .ascii "0123456789abcdef"
env_xdg:        .asciz "XDG_RUNTIME_DIR="
run_user:       .asciz "/run/user/"
slash_qb:       .asciz "/qutebrowser"
slash_qb_slash: .asciz "/qutebrowser/"
qb_path:        .asciz "/usr/bin/qutebrowser"

json_head:      .ascii "{\"args\":["
json_head_end:
json_empty:     .ascii "\"\""
json_empty_end:
json_mid:       .ascii "],\"target_arg\":null,\"version\":\"3.7.0\",\"protocol_version\":1"
json_mid_end:
json_cwd_pre:   .ascii ",\"cwd\":\""
json_cwd_pre_end:
json_tail:      .ascii "}\n"
json_tail_end:

.set JSON_HEAD_LEN,    json_head_end - json_head
.set JSON_EMPTY_LEN,   json_empty_end - json_empty
.set JSON_MID_LEN,     json_mid_end - json_mid
.set JSON_CWD_PRE_LEN, json_cwd_pre_end - json_cwd_pre
.set JSON_TAIL_LEN,    json_tail_end - json_tail

.section .text
.global _start

/* ---------------------------------------------------------------------------
 * Entry. The kernel hands us: [rsp] = argc, [rsp+8] = argv[], then envp[],
 * both NULL-terminated. DF is clear at process entry per the psABI, but cld
 * costs one cycle and every string primitive below assumes forward direction.
 * ------------------------------------------------------------------------ */
_start:
    cld
    mov r13, [rsp]                  /* argc */
    lea r14, [rsp + 8]              /* argv */
    lea r15, [r14 + r13*8 + 8]      /* envp = argv + (argc + 1) * 8 */

/* --- locate XDG_RUNTIME_DIR, else synthesise /run/user/<uid> -------------- */
    mov rbx, r15
.Lenv_loop:
    mov rsi, [rbx]
    test rsi, rsi
    jz .Lenv_miss
    lea rdi, [rip + env_xdg]
    call starts_with
    test eax, eax
    jz .Lenv_next
    lea rax, [rsi + 16]             /* strlen("XDG_RUNTIME_DIR=") */
    mov [rip + runtime_ptr], rax
    jmp .Lhave_runtime
.Lenv_next:
    add rbx, 8
    jmp .Lenv_loop

.Lenv_miss:
    lea rdi, [rip + runtime]
    lea rsi, [rip + run_user]
    call copy_cstr_adv
    mov eax, SYS_getuid
    syscall                         /* uid comes back in eax */
    call utoa                       /* rdi comes back past the digits */
    mov byte ptr [rdi], 0
    lea rax, [rip + runtime]
    mov [rip + runtime_ptr], rax

.Lhave_runtime:
/* --- scan <runtime>/qutebrowser/ for the first ipc-* entry ---------------- */
    lea rdi, [rip + dirpath]
    mov rsi, [rip + runtime_ptr]
    call copy_cstr_adv
    lea rsi, [rip + slash_qb]
    call copy_cstr_adv

    mov eax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [rip + dirpath]
    mov edx, O_RDONLY | O_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Lfallback
    mov [rip + dirfd], rax

.Lscan:
    mov eax, SYS_getdents64
    mov rdi, [rip + dirfd]
    lea rsi, [rip + dirent]
    mov edx, DIRENT_CAP
    syscall
    test rax, rax
    jle .Lscan_fail                 /* 0 = EOF, no match; <0 = error */
    mov [rip + scan_bytes], rax
    lea rax, [rip + dirent]
    mov [rip + scan_cursor], rax

.Lscan_entry:
    mov r9, [rip + scan_bytes]
    cmp r9, MIN_RECLEN
    jb .Lscan                       /* remainder can't hold another record */
    mov r8, [rip + scan_cursor]
    movzx edx, word ptr [r8 + D_RECLEN_OFF]
    test edx, edx
    jz .Lscan_fail                  /* zero-length record: refuse to spin */
    cmp edx, MIN_RECLEN
    jb .Lscan_advance

    /* d_name must start with "ipc-" */
    movzx eax, word ptr [r8 + D_NAME_OFF]
    cmp ax, 0x7069                  /* 'i' | 'p' << 8 */
    jne .Lscan_advance
    movzx eax, word ptr [r8 + D_NAME_OFF + 2]
    cmp ax, 0x2d63                  /* 'c' | '-' << 8 */
    jne .Lscan_advance

/* --- matched: assemble sockaddr_un ---------------------------------------- */
    lea rdi, [rip + sockaddr + 2]
    mov rsi, [rip + runtime_ptr]
    call copy_cstr_adv
    lea rsi, [rip + slash_qb_slash]
    call copy_cstr_adv
    lea rsi, [r8 + D_NAME_OFF]
    call copy_cstr_adv

    lea rax, [rip + sockaddr + 2]
    mov rdx, rdi
    sub rdx, rax                    /* sun_path length */
    add rdx, 2                      /* + sun_family */
    mov [rip + socklen], rdx
    mov word ptr [rip + sockaddr], AF_UNIX

    mov eax, SYS_close
    mov rdi, [rip + dirfd]
    syscall

    mov eax, SYS_socket
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor edx, edx
    syscall
    test rax, rax
    js .Lfallback
    mov [rip + sockfd], rax

    mov eax, SYS_connect
    mov rdi, [rip + sockfd]
    lea rsi, [rip + sockaddr]
    mov rdx, [rip + socklen]
    syscall
    test rax, rax
    js .Lconnect_fail
    jmp .Lbuild_json

.Lconnect_fail:
    mov eax, SYS_close
    mov rdi, [rip + sockfd]
    syscall
    jmp .Lfallback

.Lscan_advance:
    add [rip + scan_cursor], rdx
    sub [rip + scan_bytes], rdx
    jmp .Lscan_entry

.Lscan_fail:
    mov eax, SYS_close
    mov rdi, [rip + dirfd]
    syscall
    jmp .Lfallback

/* ---------------------------------------------------------------------------
 * Build the IPC message, byte-identical to what qutebrowser's own client sends:
 *   {"args":[...],"target_arg":null,"version":"3.7.0",
 *    "protocol_version":1,"cwd":"..."}\n
 * ------------------------------------------------------------------------ */
.Lbuild_json:
    lea rbx, [rip + jsonbuf]
    mov r12, rbx

    lea rsi, [rip + json_head]
    mov edx, JSON_HEAD_LEN
    call emit

    cmp r13, 1
    jbe .Ljson_noargs
    mov r8, 1                       /* argv index */
.Ljson_argloop:
    cmp r8, r13
    jae .Ljson_args_done
    cmp r8, 1
    je .Ljson_no_comma
    mov al, ','
    call putc
.Ljson_no_comma:
    mov al, '"'
    call putc
    mov rsi, [r14 + r8*8]
    call escape
    mov al, '"'
    call putc
    inc r8
    jmp .Ljson_argloop

.Ljson_noargs:
    lea rsi, [rip + json_empty]
    mov edx, JSON_EMPTY_LEN
    call emit

.Ljson_args_done:
    lea rsi, [rip + json_mid]
    mov edx, JSON_MID_LEN
    call emit

    mov eax, SYS_getcwd
    lea rdi, [rip + cwdbuf]
    mov esi, 4096
    syscall
    test rax, rax
    js .Ljson_no_cwd
    lea rsi, [rip + json_cwd_pre]
    mov edx, JSON_CWD_PRE_LEN
    call emit
    lea rsi, [rip + cwdbuf]
    call escape
    mov al, '"'
    call putc
.Ljson_no_cwd:

    lea rsi, [rip + json_tail]
    mov edx, JSON_TAIL_LEN
    call emit

/* --- one write, then get out of the way ----------------------------------- */
    mov rdx, r12
    sub rdx, rbx                    /* payload length */
    mov eax, SYS_write
    mov rdi, [rip + sockfd]
    mov rsi, rbx
    syscall
    mov r10, rax                    /* write() result; close() won't touch r10 */
    mov rdx, r12
    sub rdx, rbx

    mov eax, SYS_close
    mov rdi, [rip + sockfd]
    syscall

    /* A short write means the message was truncated — treat it as failure,
     * exactly like the C version does. */
    cmp r10, rdx
    jne .Lfallback

    mov eax, SYS_exit
    xor edi, edi
    syscall

/* ---------------------------------------------------------------------------
 * Fallback: hand the whole thing to the real browser, argv and environ intact.
 * ------------------------------------------------------------------------ */
.Lfallback:
    mov eax, SYS_execve
    lea rdi, [rip + qb_path]
    mov rsi, r14
    mov rdx, r15
    syscall
    mov eax, SYS_exit               /* execve failed */
    mov edi, 1
    syscall
.Ldead:
    jmp .Ldead

/* =========================== helper routines ============================== */

/* rsi = "NAME=value", rdi = "NAME=". eax = 1 when the prefix matches. */
starts_with:
    push rsi
    push rdi
.Lsw_loop:
    mov al, [rdi]
    test al, al
    jz .Lsw_yes
    cmp al, [rsi]
    jne .Lsw_no
    inc rdi
    inc rsi
    jmp .Lsw_loop
.Lsw_yes:
    pop rdi
    pop rsi
    mov eax, 1
    ret
.Lsw_no:
    pop rdi
    pop rsi
    xor eax, eax
    ret

/* rdi = dest, rsi = NUL-terminated src. Writes the NUL, returns rdi past it. */
copy_cstr_adv:
.Lcc_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .Lcc_loop
    dec rdi
    ret

/* eax = unsigned value, rdi = dest. Digits only, rdi left past the last one.
 * Emits backwards from the end of a scratch buffer so no reversal pass is
 * needed. */
utoa:
    lea rsi, [rip + numtmp + 32]
    mov ecx, 10
.Lut_loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test eax, eax
    jnz .Lut_loop
.Lut_copy:
    mov al, [rsi]
    test al, al
    jz .Lut_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .Lut_copy
.Lut_done:
    ret

/* Append the byte in al to the JSON buffer, refusing to overflow it.
 * Uses r11 for the bound so al survives — rax is not free here. */
putc:
    lea r11, [rbx + JSON_CAP]
    cmp r12, r11
    jae .Loverflow
    mov [r12], al
    inc r12
    ret

/* Append rdx bytes from rsi, same guard. */
emit:
    test rdx, rdx
    jz .Lem_done
    lea rax, [rbx + JSON_CAP]
    sub rax, r12
    cmp rax, rdx
    jb .Loverflow
.Lem_loop:
    mov al, [rsi]
    mov [r12], al
    inc rsi
    inc r12
    dec rdx
    jnz .Lem_loop
.Lem_done:
    ret

.Loverflow:
    jmp .Lfallback

/* JSON-escape the NUL-terminated string at rsi into the JSON buffer.
 * Same table as the C version: " \ \n \r \t get short escapes, the remaining
 * C0 controls become \u00xx, everything else passes through untouched. */
escape:
.Le_loop:
    mov al, [rsi]
    inc rsi
    test al, al
    jz .Le_done
    cmp al, 0x22                    /* " */
    je .Le_quote
    cmp al, 0x5c                    /* \ */
    je .Le_backslash
    cmp al, 0x0a
    je .Le_nl
    cmp al, 0x0d
    je .Le_cr
    cmp al, 0x09
    je .Le_tab
    cmp al, 0x20
    jb .Le_ctrl
    call putc
    jmp .Le_loop
.Le_quote:
    mov al, 0x5c
    call putc
    mov al, 0x22
    call putc
    jmp .Le_loop
.Le_backslash:
    mov al, 0x5c
    call putc
    call putc
    jmp .Le_loop
.Le_nl:
    mov al, 0x5c
    call putc
    mov al, 0x6e                    /* 'n' */
    call putc
    jmp .Le_loop
.Le_cr:
    mov al, 0x5c
    call putc
    mov al, 0x72                    /* 'r' */
    call putc
    jmp .Le_loop
.Le_tab:
    mov al, 0x5c
    call putc
    mov al, 0x74                    /* 't' */
    call putc
    jmp .Le_loop
.Le_ctrl:
    movzx r10d, al                  /* park the byte; putc only touches r11 */
    mov al, 0x5c
    call putc
    mov al, 0x75                    /* 'u' */
    call putc
    mov al, 0x30                    /* '0' */
    call putc
    call putc
    lea rdx, [rip + hexdigits]
    mov ecx, r10d
    shr ecx, 4
    mov al, [rdx + rcx]
    call putc
    mov ecx, r10d
    and ecx, 0x0f
    mov al, [rdx + rcx]
    call putc
    jmp .Le_loop
.Le_done:
    ret

.section .note.GNU-stack,"",@progbits
