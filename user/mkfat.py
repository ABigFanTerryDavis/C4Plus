"""Build a tiny FAT12 volume (512 sectors) to embed in a C4Plus disk image."""
import struct
import sys

BASE_LBA = 193
SECTORS = 512
FAT_SECTORS = 2
ROOT_ENTRIES = 16
RESERVED = 1
DATA_START = RESERVED + 2 * FAT_SECTORS + 1  # rel sector 6


def u16(b, off):
    return b[off] | (b[off + 1] << 8)


def make_fat(chains):
    # chains: list of cluster lists, one per file
    fat = bytearray(FAT_SECTORS * 512)
    fat[0], fat[1], fat[2] = 0xF0, 0xFF, 0xFF
    items = {}

    def set12(cl, val):
        off = cl + cl // 2
        if cl % 2 == 0:
            items[off] = val & 0xFF
            items[off + 1] = (items.get(off + 1, 0) & 0xF0) | ((val >> 8) & 0x0F)
        else:
            items[off] = (items.get(off, 0) & 0x0F) | ((val << 4) & 0xF0)
            items[off + 1] = (val >> 4) & 0xFF

    for chain in chains:
        for i, cl in enumerate(chain):
            set12(cl, 0xFFF if i == len(chain) - 1 else chain[i + 1])
    for off, v in items.items():
        fat[off] = v
    return bytes(fat)


def dirent(name83, attr, cluster, size):
    e = bytearray(32)
    e[0:11] = name83.encode("ascii")
    e[11] = attr
    e[26:28] = struct.pack("<H", cluster)
    e[28:32] = struct.pack("<I", size)
    return bytes(e)


def main():
    out_path = sys.argv[1]
    files = []  # (name83, bytes)
    with open(sys.argv[2], "rb") as f:
        hello = f.read()
    files.append(("HELLO   TXT", hello))
    big = (b"The quick brown fox jumps over the lazy dog. " * 30)[:1300]
    files.append(("WORDS   TXT", big))
    with open(sys.argv[3], "rb") as f:
        elf = f.read()
    files.append(("PONG    ELF", elf))

    vol = bytearray(SECTORS * 512)
    # BPB boot sector
    bs = bytearray(512)
    bs[0:3] = b"\xeb\x3c\x90"
    bs[3:11] = b"C4PLUS  "
    struct.pack_into("<H", bs, 11, 512)
    bs[13] = 1
    struct.pack_into("<H", bs, 14, RESERVED)
    bs[16] = 2
    struct.pack_into("<H", bs, 17, ROOT_ENTRIES)
    struct.pack_into("<H", bs, 19, SECTORS)
    bs[21] = 0xF0
    struct.pack_into("<H", bs, 22, FAT_SECTORS)
    struct.pack_into("<H", bs, 24, 18)
    struct.pack_into("<H", bs, 26, 2)
    bs[510], bs[511] = 0x55, 0xAA
    vol[0:512] = bs

    # allocate clusters (1 sector each)
    chains = []
    next_cl = 2
    blobs = []
    for _, data in files:
        nsec = (len(data) + 511) // 512
        chain = list(range(next_cl, next_cl + nsec))
        next_cl += nsec
        chains.append(chain)
        blobs.append(data)
    fat = make_fat(chains)
    vol[512:512 + len(fat)] = fat
    vol[512 + len(fat):512 + 2 * len(fat)] = fat
    root_off = (RESERVED + 2 * FAT_SECTORS) * 512
    for i, ((n83, data), chain) in enumerate(zip(files, chains)):
        vol[root_off + i * 32:root_off + (i + 1) * 32] = dirent(n83, 0x20, chain[0], len(data))
        for j, cl in enumerate(chain):
            chunk = data[j * 512:(j + 1) * 512]
            off = (DATA_START + cl - 2) * 512
            vol[off:off + len(chunk)] = chunk
    with open(out_path, "wb") as f:
        f.write(bytes(vol))
    print("fat12:", SECTORS, "sectors at base", BASE_LBA, [n for n, _ in files])


if __name__ == "__main__":
    main()
