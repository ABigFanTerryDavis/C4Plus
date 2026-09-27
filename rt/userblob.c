/* Linked only into user-mode kernels. Expects the user ELF converted via:
   objcopy -I binary -O elf32-i386 -B i386 zig-out/user.elf zig-out/user_data.o
   (symbol: _binary_zig_out_user_elf_start). */
#include "c4rt_fs.h"

__attribute__((weak)) extern char binary_zig_out_user_elf_start[];
__attribute__((weak)) extern char binary_zig_out_user_elf_end[];
__attribute__((weak)) extern char binary_zig_out_user2_elf_start[];
__attribute__((weak)) extern char binary_zig_out_user2_elf_end[];

C4Val c4_user_base(void) {
    return c4_num((double)(unsigned long)binary_zig_out_user_elf_start);
}

C4Val c4_user_len(void) {
    return c4_num((double)(unsigned long)(binary_zig_out_user_elf_end - binary_zig_out_user_elf_start));
}

C4Val c4_user2_base(void) {
    return c4_num((double)(unsigned long)binary_zig_out_user2_elf_start);
}

C4Val c4_user2_len(void) {
    return c4_num((double)(unsigned long)(binary_zig_out_user2_elf_end - binary_zig_out_user2_elf_start));
}
