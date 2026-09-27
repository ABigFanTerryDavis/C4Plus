import struct
import sys

code_path, elf_path, vaddr = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
code = open(code_path, "rb").read()

e_ident = bytes([0x7F]) + b"ELF" + bytes([1, 1, 1, 0] + [0] * 9)
ehdr = struct.pack(
    "<16sHHIIIIIHHHHHH",
    e_ident,
    2,
    3,
    1,
    vaddr,
    52,
    0,
    0,
    52,
    32,
    1,
    0,
    0,
    0,
)
phdr = struct.pack("<IIIIIIII", 1, 84, vaddr, vaddr, len(code), len(code), 5, 0x1000)
open(elf_path, "wb").write(ehdr + phdr + code)
print("elf:", len(code), "bytes at", hex(vaddr))
