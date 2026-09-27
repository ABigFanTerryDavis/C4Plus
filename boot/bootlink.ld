/* Boot sector link only: 512 bytes at 0x7C00. */
OUTPUT_FORMAT("pei-i386")
ENTRY(_bootmain)
SECTIONS {
    . = 0x7C00;
    .boot : {
        *(.boot)
    }
    /DISCARD/ : {
        *(.reloc*)
    }
}
