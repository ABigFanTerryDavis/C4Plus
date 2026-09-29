/* C4Plus ping-pong tasks (ring 3): role picked by mytid() syscall.
 * tid 1 sends 1..5 to tid 2; tid 2 prints each receipt. Both exit.
 * Assembled with MinGW `as --32`, wrapped into ELF32 by mkelf.py. */
    .code32
    .text
    .global _start
_start:
    call pic_base
pic_base:
    pop %esi
    mov $7, %eax
    xor %ebx, %ebx
    xor %ecx, %ecx
    xor %edx, %edx
    int $0x80
    cmp $1, %eax
    je pinger
    push %esi
    lea (pb-pic_base)(%esi), %ebx
    mov $1, %eax
    mov $2, %ecx
    xor %edx, %edx
    int $0x80
    pop %esi
    jmp ponger
pinger:
    push %esi
    lea (pa-pic_base)(%esi), %ebx
    mov $1, %eax
    mov $2, %ecx
    xor %edx, %edx
    int $0x80
    pop %esi
    mov $1, %edi
ploop:
    mov $5, %eax
    mov $2, %ebx
    mov %edi, %ecx
    xor %edx, %edx
    int $0x80
    inc %edi
    cmp $6, %edi
    jl ploop
    mov $2, %eax
    mov $10, %ebx
    xor %ecx, %ecx
    xor %edx, %edx
    int $0x80
    jmp .
ponger:
    mov $0, %edi
pongloop:
    mov $6, %eax
    xor %ebx, %ebx
    xor %ecx, %ecx
    xor %edx, %edx
    int $0x80
    cmp $0, %eax
    jl pongloop
    push %eax
    push %edi
    push %esi
    lea (got-pic_base)(%esi), %ebx
    mov $4, %ecx
    mov $1, %eax
    xor %edx, %edx
    int $0x80
    pop %esi
    pop %edi
    pop %eax
    call print_num
    inc %edi
    cmp $5, %edi
    jl pongloop
    mov $2, %eax
    mov $20, %ebx
    xor %ecx, %ecx
    xor %edx, %edx
    int $0x80
    jmp .
print_num:
    push %edi
    push %ebx
    push %ecx
    push %edx
    lea (numbuf-pic_base)(%esi), %edi
    mov %eax, %ebx
    cmp $0, %ebx
    jne pndigits
    movb $48, (%edi)
    inc %edi
    jmp pndone
pndigits:
    xor %ecx, %ecx
pnloop:
    mov %ebx, %eax
    xor %edx, %edx
    mov $10, %ebx
    div %ebx
    push %edx
    inc %ecx
    mov %eax, %ebx
    test %eax, %eax
    jnz pnloop
pnout:
    pop %edx
    add $48, %dl
    mov %dl, (%edi)
    inc %edi
    dec %ecx
    jnz pnout
pndone:
    movb $10, (%edi)
    inc %edi
    lea (numbuf-pic_base)(%esi), %ebx
    mov %edi, %ecx
    sub %ebx, %ecx
    mov $1, %eax
    xor %edx, %edx
    int $0x80
    pop %edx
    pop %ecx
    pop %ebx
    pop %edi
    ret
got:
    .ascii "got "
pa:
    .ascii "A\n"
pb:
    .ascii "B\n"
numbuf:
    .space 16
