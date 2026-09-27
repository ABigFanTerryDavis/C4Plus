/* C4Plus freestanding link: multiboot header first, kernel at 1M. */
ENTRY(_start)
SECTIONS {
    . = 1M;
    .multiboot : {
        KEEP(*(.multiboot))
    }
    .text : {
        *(.text)
    }
    .rodata : {
        *(.rodata*)
    }
    .data : {
        *(.data*)
    }
    .bss : {
        *(.bss*)
        *(COMMON)
    }
}
