/* C4Plus freestanding IRQ0 stub: saves state, calls c4_irq0, sends EOI, returns.
 * Assembled with MinGW `as --32`, linked into the kernel (see 52_timer).
 * Note: MinGW 32-bit C symbols carry a leading underscore. */
    .code32
    .text
    .global _irq0_stub
_irq0_stub:
    pusha
    push %ds
    push %es
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %esp, %eax
    push %eax
    call _c4_schedule
    mov %eax, %esp
    pop %es
    pop %ds
    popa
    mov $0x20, %al
    out %al, $0x20
    iret
    .global _irq1_stub
_irq1_stub:
    pusha
    push %ds
    push %es
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    call _c4_irq1
    mov $0x20, %al
    out %al, $0x20
    pop %es
    pop %ds
    popa
    iret
    .global _syscall_stub
_syscall_stub:
    pusha
    push %ds
    push %es
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %esp, %eax
    push %eax
    call _c4_syscall_dispatch
    add $4, %esp
    pop %es
    pop %ds
    popa
    iret
    .global _enter_user_stub
_enter_user_stub:
    mov 4(%esp), %edx
    mov 8(%esp), %ecx
    mov $0x23, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    push $0x23
    push %ecx
    pushf
    pop %eax
    or $0x200, %eax
    push %eax
    push $0x1B
    push %edx
    iret
    .global _fault_stubs
_fault_stubs:
    .set _fv, 0
    .rept 32
    .balign 8
    push $_fv
    jmp _fault_common
    .set _fv, _fv + 1
    .endr
_fault_common:
    pusha
    push %ds
    push %es
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    # stack: es,ds,edi,esi,ebp,esp,ebx,edx,ecx,eax, vec, eip,cs,eflags
    mov 40(%esp), %eax
    push %eax
    mov %cr2, %eax
    push %eax
    call _c4_fault2
    add $8, %esp
    pop %es
    pop %ds
    popa
    add $4, %esp
    cli
_fault_hang:
    hlt
    jmp _fault_hang
