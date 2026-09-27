/* Kernel-only link at 0x10000 (kmain first via .text.kmain).
 * Boot sector links separately (bootlink.ld); concat: boot.bin + kernel.bin.
 * 0x10000 is clear of the boot sector (0x7C00), stack, and DAP. */
OUTPUT_FORMAT("pei-i386")
ENTRY(_kmain)
SECTIONS {
    . = 0x10000;
    .text : {
        *(.text.kmain)
        *(.text*)
    }
    .rodata : {
        *(.rodata*)
        *(.rdata*)
    }
    .data : {
        *(.data*)
    }
    .bss 0x200000 : {
        *(.bss*)
        *(COMMON)
    }
    /DISCARD/ : {
        *(.eh_frame*)
        *(.comment*)
        *(.note*)
        *(.reloc*)
    }
}
