/* floor.S — the absolute floor: a static binary whose entire job is to exit.
 *
 * Without this, "qb-open-asm takes 500 microseconds" is uninterpretable. Some
 * of that is the launcher's work (openat/getdents64/socket/connect/write) and
 * some is the irreducible cost of fork+execve+waitpid, which the harness pays
 * for every variant equally. This binary isolates the second part: it is too
 * small to have a first part.
 *
 * Build: as -o floor.o floor.S && ld -o floor floor.o
 */
.intel_syntax noprefix
.section .text
.global _start
_start:
    mov eax, 60          /* exit_group */
    xor edi, edi
    syscall
    hlt
.section .note.GNU-stack,"",@progbits
