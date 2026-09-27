/* C4Plus stage-1 boot sector: loads kernel to 0x10000, enters pmode, jumps in.
 * Assembled with MinGW `as` (PE-safe directives only), linked flat. */
    .code16
    .section .boot, "ax"
    .global _bootmain
_bootmain:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7C00, %sp
    sti
    mov $0x41, %al
    out %al, $0xE9
    /* load 96 sectors via int13 EDD (LBA 1..96) to 0x10000; DL = BIOS drive.
       0x10000 (seg 0x1000) is clear of the boot sector, stack, and DAP.
       96 sectors = 48KB, room for kernel + embedded user ELF. */
    mov %dl, boot_drive
    movw $0, counter
load_loop:
    cmpw $0x60, counter
    jge loaded
    /* BIOS may clobber DS/ES/DL and the stack: reload them every iteration,
       keep the counter in memory (never on the stack) */
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov boot_drive, %dl
    movzwl counter, %esi
    mov %esi, %eax
    add $1, %eax
    mov %eax, 0x7E00 + 8
    movl $0, 0x7E00 + 12
    mov %esi, %eax
    shl $9, %eax
    mov %ax, 0x7E00 + 4
    movw $0x1000, 0x7E00 + 6
    movw $0x0010, 0x7E00
    movw $1, 0x7E00 + 2
    mov $0x42, %ah
    mov $0x7E00, %si
    int $0x13
    /* int13 clobbers DS/ES: reload before touching any memory */
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    jc disk_error
    incw counter
    jmp load_loop
loaded:
    mov $0x42, %al
    out %al, $0xE9
    lgdt gdt_desc
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    ljmp $0x08, $pm_entry
disk_error:
    mov $0x45, %al
    out %al, $0xE9
    hlt
    jmp disk_error
    .code32
pm_entry:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    cli /* no IDT yet: stay interrupt-free until drivers exist */
    cld
    mov %cr4, %eax
    or $0x200, %eax
    mov %eax, %cr4
    mov %cr0, %eax
    and $0xFFFFFFFB, %eax
    mov %eax, %cr0
    mov $0x90000, %esp
    /* zero kernel BSS: 0x200000..0x250000 (pool 256K + slack; matches linkflat.ld) */
    mov $0x200000, %edi
    mov $0x50000, %ecx
    xor %eax, %eax
    rep stosb
    mov $0x44, %al
    out %al, $0xE9
    mov $0x10000, %eax
    call *%eax
    cli
halt_loop:
    hlt
    jmp halt_loop
    .align 8
gdt_start:
    .long 0, 0
    .long 0x0000FFFF, 0x00CF9A00
    .long 0x0000FFFF, 0x00CF9200
gdt_desc:
    .word gdt_desc - gdt_start - 1
    .long gdt_start
boot_drive:
    .byte 0
counter:
    .word 0
    .fill 510 - (. - _bootmain), 1, 0
    .word 0xAA55
