/* C4Plus user program (ring 3): position-independent, runs at any load address.
 * Assembled with MinGW `as --32`, wrapped into ELF32 by mkelf.py.
 * Uses int 0x80 syscalls: 1 = write(addr, len), 2 = exit(code). */
    .code32
    .text
    .global _start
_start:
    call pic_base
pic_base:
    pop %esi
    lea (hello-pic_base)(%esi), %ebx
    mov $1, %eax
    mov $17, %ecx
    xor %edx, %edx
    int $0x80
    mov %cs, %ax
    and $3, %ax
    cmp $3, %ax
    je is_ring3
    lea (bad-pic_base)(%esi), %ebx
    mov $1, %eax
    mov $10, %ecx
    xor %edx, %edx
    int $0x80
    jmp done
is_ring3:
    lea (ok-pic_base)(%esi), %ebx
    mov $1, %eax
    mov $9, %ecx
    xor %edx, %edx
    int $0x80
done:
    mov $2, %eax
    mov $99, %ebx
    xor %ecx, %ecx
    xor %edx, %edx
    int $0x80
hello:
    .ascii "hello from ring3\n"
ok:
    .ascii "ring3 ok\n"
bad:
    .ascii "ring0 BAD\n"
