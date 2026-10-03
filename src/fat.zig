const std = @import("std");
const blockmod = @import("block");

// fat module backend: read-only-compatible FAT12 with a write path,
// layered on block devices. Stateless: every call re-reads BPB/FAT/root
// from the device. Geometry mirrors user/mkfat.py exactly (512-sector
// volume, 2 FATs of 2 sectors, 16 root entries, data at rel sector 6).
// Names are 11 raw bytes (8.3, space-padded, uppercased by the caller).

pub const FatError = error{
    BadFS,
    NotFound,
    NoSpace,
    DirFull,
    Io,
    OutOfMemory,
};

pub const sectors_total = 512;
pub const fat_sectors = 2;
pub const root_entries = 16;
pub const root_lba: usize = 1 + 2 * fat_sectors;
pub const data_lba: usize = root_lba + 1;
pub const max_clusters: usize = sectors_total - data_lba + 2;

fn rd16(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}

fn wr16(b: []u8, off: usize, v: u16) void {
    b[off] = @intCast(v & 0xFF);
    b[off + 1] = @intCast((v >> 8) & 0xFF);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    b[off] = @intCast(v & 0xFF);
    b[off + 1] = @intCast((v >> 8) & 0xFF);
    b[off + 2] = @intCast((v >> 16) & 0xFF);
    b[off + 3] = @intCast((v >> 24) & 0xFF);
}

fn fat12get(fat: []const u8, cl: usize) u16 {
    const off = cl + cl / 2;
    if (cl % 2 == 0) {
        return @as(u16, fat[off]) | ((@as(u16, fat[off + 1]) & 0x0F) << 8);
    }
    return ((@as(u16, fat[off]) & 0xF0) >> 4) | (@as(u16, fat[off + 1]) << 4);
}

fn fat12set(fat: []u8, cl: usize, val: u16) void {
    const off = cl + cl / 2;
    if (cl % 2 == 0) {
        fat[off] = @intCast(val & 0xFF);
        fat[off + 1] = (fat[off + 1] & 0xF0) | @as(u8, @intCast((val >> 8) & 0x0F));
    } else {
        fat[off] = (fat[off] & 0x0F) | @as(u8, @intCast((val << 4) & 0xF0));
        fat[off + 1] = @intCast((val >> 4) & 0xFF);
    }
}

fn readSec(alloc: std.mem.Allocator, io: std.Io, bid: u32, lba: usize) FatError![]u8 {
    return blockmod.blockRead(alloc, io, bid, lba) catch FatError.Io;
}

fn writeSec(io: std.Io, bid: u32, lba: usize, data: []const u8) FatError!void {
    if (data.len != 512) return FatError.Io;
    blockmod.blockWrite(io, bid, lba, data) catch return FatError.Io;
}

fn checkFs(alloc: std.mem.Allocator, io: std.Io, bid: u32) FatError!void {
    const n = blockmod.blockSectors(bid) catch return FatError.Io;
    if (n != sectors_total) return FatError.BadFS;
    const boot = try readSec(alloc, io, bid, 0);
    defer alloc.free(boot);
    if (boot[510] != 0x55 or boot[511] != 0xAA) return FatError.BadFS;
    if (rd16(boot, 11) != 512) return FatError.BadFS;
}

fn readFat(alloc: std.mem.Allocator, io: std.Io, bid: u32) FatError![]u8 {
    const out = alloc.alloc(u8, fat_sectors * 512) catch return FatError.OutOfMemory;
    for (0..fat_sectors) |k| {
        const s = try readSec(alloc, io, bid, 1 + k);
        defer alloc.free(s);
        @memcpy(out[k * 512 ..][0..512], s);
    }
    return out;
}

fn writeFat(io: std.Io, bid: u32, fat: []const u8) FatError!void {
    for (0..fat_sectors) |k| {
        try writeSec(io, bid, 1 + k, fat[k * 512 ..][0..512]);
        try writeSec(io, bid, 1 + fat_sectors + k, fat[k * 512 ..][0..512]);
    }
}

pub fn fatFormat(alloc: std.mem.Allocator, io: std.Io, bid: u32) FatError!void {
    const n = blockmod.blockSectors(bid) catch return FatError.Io;
    if (n != sectors_total) return FatError.BadFS;
    var bs: [512]u8 = [_]u8{0} ** 512;
    bs[0] = 0xEB;
    bs[1] = 0x3C;
    bs[2] = 0x90;
    @memcpy(bs[3..11], "C4PLUS  ");
    wr16(&bs, 11, 512);
    bs[13] = 1;
    wr16(&bs, 14, 1);
    bs[16] = 2;
    wr16(&bs, 17, root_entries);
    wr16(&bs, 19, sectors_total);
    bs[21] = 0xF0;
    wr16(&bs, 22, fat_sectors);
    wr16(&bs, 24, 18);
    wr16(&bs, 26, 2);
    bs[510] = 0x55;
    bs[511] = 0xAA;
    try writeSec(io, bid, 0, &bs);
    var fat: [fat_sectors * 512]u8 = [_]u8{0} ** (fat_sectors * 512);
    fat[0] = 0xF0;
    fat[1] = 0xFF;
    fat[2] = 0xFF;
    try writeFat(io, bid, &fat);
    var root: [512]u8 = [_]u8{0} ** 512;
    try writeSec(io, bid, root_lba, &root);
    var z: [512]u8 = [_]u8{0} ** 512;
    var lba: usize = data_lba;
    while (lba < sectors_total) : (lba += 1) {
        try writeSec(io, bid, lba, &z);
    }
    _ = alloc;
}

const DirSlot = struct { index: usize, empty: bool };

fn findName(alloc: std.mem.Allocator, io: std.Io, bid: u32, name83: [11]u8) FatError!?DirSlot {
    try checkFs(alloc, io, bid);
    const root = try readSec(alloc, io, bid, root_lba);
    defer alloc.free(root);
    var first_empty: ?usize = null;
    var i: usize = 0;
    while (i < root_entries) : (i += 1) {
        const e = root[i * 32 ..][0..32];
        if (e[0] == 0x00) {
            return .{ .index = first_empty orelse i, .empty = true };
        }
        if (e[0] == 0xE5) {
            if (first_empty == null) first_empty = i;
            continue;
        }
        if (std.mem.eql(u8, e[0..11], &name83)) {
            return .{ .index = i, .empty = false };
        }
    }
    if (first_empty) |fe| return .{ .index = fe, .empty = true };
    return null;
}

fn entryCluster(e: []const u8) u16 {
    return rd16(e, 26);
}

fn entrySize(e: []const u8) u32 {
    return @as(u32, e[28]) | (@as(u32, e[29]) << 8) | (@as(u32, e[30]) << 16) | (@as(u32, e[31]) << 24);
}

pub fn fatLs(alloc: std.mem.Allocator, io: std.Io, bid: u32, out: *std.ArrayList([11]u8)) FatError!void {
    try checkFs(alloc, io, bid);
    const root = try readSec(alloc, io, bid, root_lba);
    defer alloc.free(root);
    var i: usize = 0;
    while (i < root_entries) : (i += 1) {
        const e = root[i * 32 ..][0..32];
        if (e[0] == 0x00) break;
        if (e[0] == 0xE5) continue;
        if (e[11] & 0x08 != 0) continue;
        var nm: [11]u8 = undefined;
        @memcpy(&nm, e[0..11]);
        out.append(alloc, nm) catch return FatError.OutOfMemory;
    }
}

pub fn fatRead(alloc: std.mem.Allocator, io: std.Io, bid: u32, name83: [11]u8) FatError![]u8 {
    try checkFs(alloc, io, bid);
    const root = try readSec(alloc, io, bid, root_lba);
    defer alloc.free(root);
    var i: usize = 0;
    while (i < root_entries) : (i += 1) {
        const e = root[i * 32 ..][0..32];
        if (e[0] == 0x00) break;
        if (e[0] == 0xE5) continue;
        if (!std.mem.eql(u8, e[0..11], &name83)) continue;
        const size = entrySize(e);
        var cl = entryCluster(e);
        var out: std.ArrayList(u8) = .empty;
        var left: usize = size;
        if (cl == 0) {
            if (size != 0) return FatError.BadFS;
            return out.toOwnedSlice(alloc) catch FatError.OutOfMemory;
        }
        const fat = try readFat(alloc, io, bid);
        defer alloc.free(fat);
        while (true) {
            if (cl < 2 or cl >= max_clusters) {
                out.deinit(alloc);
                return FatError.BadFS;
            }
            const s = try readSec(alloc, io, bid, data_lba + (cl - 2));
            defer alloc.free(s);
            const take: usize = @min(left, 512);
            out.appendSlice(alloc, s[0..take]) catch {
                out.deinit(alloc);
                return FatError.OutOfMemory;
            };
            left -= take;
            if (left == 0) break;
            const nx = fat12get(fat, cl);
            if (nx < 2 or nx >= 0xFF8) {
                out.deinit(alloc);
                return FatError.BadFS;
            }
            cl = nx;
        }
        return out.toOwnedSlice(alloc) catch FatError.OutOfMemory;
    }
    return FatError.NotFound;
}

fn freeChain(fat: []u8, cl: u16) FatError!void {
    var c = cl;
    while (c >= 2 and c < 0xFF8) {
        if (c >= max_clusters) return FatError.BadFS;
        const nx = fat12get(fat, c);
        fat12set(fat, c, 0);
        if (nx >= 0xFF8) break;
        c = nx;
    }
}

pub fn fatWrite(alloc: std.mem.Allocator, io: std.Io, bid: u32, name83: [11]u8, data: []const u8) FatError!void {
    try checkFs(alloc, io, bid);
    const slot = (try findName(alloc, io, bid, name83)) orelse return FatError.DirFull;
    const root = try readSec(alloc, io, bid, root_lba);
    defer alloc.free(root);
    if (!slot.empty) {
        const old = root[slot.index * 32 ..][0..32];
        const fat0 = try readFat(alloc, io, bid);
        defer alloc.free(fat0);
        const oc = entryCluster(old);
        if (oc != 0) {
            try freeChain(fat0, oc);
            try writeFat(io, bid, fat0);
        }
    }
    const need = (data.len + 511) / 512;
    const fat = try readFat(alloc, io, bid);
    defer alloc.free(fat);
    var chain: [max_clusters]u16 = undefined;
    var got: usize = 0;
    var c: usize = 2;
    while (got < need and c < max_clusters) : (c += 1) {
        if (fat12get(fat, c) == 0) {
            chain[got] = @intCast(c);
            got += 1;
        }
    }
    if (got < need) return FatError.NoSpace;
    var k: usize = 0;
    while (k < need) : (k += 1) {
        const nx: u16 = if (k + 1 < need) chain[k + 1] else 0xFFF;
        fat12set(fat, chain[k], nx);
        var sec: [512]u8 = [_]u8{0} ** 512;
        const chunk = @min(data.len - k * 512, 512);
        @memcpy(sec[0..chunk], data[k * 512 ..][0..chunk]);
        try writeSec(io, bid, data_lba + (chain[k] - 2), &sec);
    }
    try writeFat(io, bid, fat);
    const e = root[slot.index * 32 ..][0..32];
    @memcpy(e[0..11], &name83);
    e[11] = 0x20;
    @memset(e[12..26], 0);
    wr16(e, 26, if (need == 0) 0 else chain[0]);
    wr32(e, 28, @intCast(data.len));
    try writeSec(io, bid, root_lba, root);
}

pub fn fatDelete(alloc: std.mem.Allocator, io: std.Io, bid: u32, name83: [11]u8) FatError!bool {
    try checkFs(alloc, io, bid);
    const slot = (try findName(alloc, io, bid, name83)) orelse return false;
    if (slot.empty) return false;
    const root = try readSec(alloc, io, bid, root_lba);
    defer alloc.free(root);
    const e = root[slot.index * 32 ..][0..32];
    const oc = entryCluster(e);
    if (oc != 0) {
        const fat = try readFat(alloc, io, bid);
        defer alloc.free(fat);
        try freeChain(fat, oc);
        try writeFat(io, bid, fat);
    }
    e[0] = 0xE5;
    try writeSec(io, bid, root_lba, root);
    return true;
}
