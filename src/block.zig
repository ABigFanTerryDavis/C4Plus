const std = @import("std");

// block module backend: sector devices (ramdisk + file images) with
// read/write/copy/fill over 512-byte sectors. Sectors cross the language
// boundary as lists of 512 byte-numbers (native C strings are
// NUL-terminated, so raw strings would truncate); read_text/write_text
// cover the NUL-free text case.

pub const max_devices = 32;
pub const sector_size = 512;
pub const max_sectors = 131072; // 64MB

pub const BlockError = error{
    BadHandle,
    TooBig,
    OutOfMemory,
    OutOfRange,
    BadSize,
    FileError,
    Closed,
};

const Device = struct {
    used: bool = false,
    is_file: bool = false,
    buf: []u8 = &.{},
    file: ?std.Io.File = null,
    sectors: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
};

var devices: [max_devices]Device = [_]Device{.{}} ** max_devices;

fn takeDevice() ?u32 {
    for (&devices, 0..) |*d, i| {
        if (!d.used) {
            d.used = true;
            return @intCast(i + 1);
        }
    }
    return null;
}

fn getDevice(id: u32) BlockError!*Device {
    if (id == 0 or id > max_devices) return BlockError.BadHandle;
    const d = &devices[id - 1];
    if (!d.used) return BlockError.BadHandle;
    return d;
}

pub const Stats = struct {
    sectors: usize,
    reads: usize,
    writes: usize,
};

pub fn blockRamdisk(alloc: std.mem.Allocator, sectors: usize) BlockError!u32 {
    if (sectors == 0 or sectors > max_sectors) return BlockError.TooBig;
    const id = takeDevice() orelse return BlockError.OutOfMemory;
    const d = &devices[id - 1];
    d.* = .{};
    d.used = true;
    d.buf = alloc.alloc(u8, sectors * sector_size) catch return BlockError.OutOfMemory;
    @memset(d.buf, 0);
    d.sectors = sectors;
    return id;
}

pub fn blockFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, sectors: usize) BlockError!u32 {
    const id = takeDevice() orelse return BlockError.OutOfMemory;
    const d = &devices[id - 1];
    d.* = .{};
    const cwd = std.Io.Dir.cwd();
    const abs = std.fs.path.isAbsolute(path);
    const f = if (abs)
        std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| blk: {
            if (err != error.FileNotFound) return BlockError.FileError;
            if (sectors == 0 or sectors > max_sectors) return BlockError.TooBig;
            const nf = std.Io.Dir.createFileAbsolute(io, path, .{ .read = true }) catch return BlockError.FileError;
            nf.setLength(io, sectors * sector_size) catch {
                nf.close(io);
                return BlockError.FileError;
            };
            break :blk nf;
        }
    else
        cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| blk: {
            if (err != error.FileNotFound) return BlockError.FileError;
            if (sectors == 0 or sectors > max_sectors) return BlockError.TooBig;
            const nf = cwd.createFile(io, path, .{ .read = true }) catch return BlockError.FileError;
            nf.setLength(io, sectors * sector_size) catch {
                nf.close(io);
                return BlockError.FileError;
            };
            break :blk nf;
        };
    const end = f.length(io) catch {
        f.close(io);
        return BlockError.FileError;
    };
    if (end % sector_size != 0 or end == 0) {
        f.close(io);
        return BlockError.FileError;
    }
    d.used = true;
    d.is_file = true;
    d.file = f;
    d.sectors = end / sector_size;
    _ = alloc;
    return id;
}

fn checkLba(d: *Device, lba: usize, n: usize) BlockError!void {
    if (n > d.sectors or lba > d.sectors - n) return BlockError.OutOfRange;
}

pub fn blockSectors(id: u32) BlockError!usize {
    const d = try getDevice(id);
    return d.sectors;
}

pub fn blockRead(alloc: std.mem.Allocator, io: std.Io, id: u32, lba: usize) BlockError![]u8 {
    const d = try getDevice(id);
    try checkLba(d, lba, 1);
    const out = alloc.alloc(u8, sector_size) catch return BlockError.OutOfMemory;
    if (d.is_file) {
        const n = d.file.?.readPositionalAll(io, out, lba * sector_size) catch return BlockError.FileError;
        if (n != sector_size) {
            alloc.free(out);
            return BlockError.FileError;
        }
    } else {
        @memcpy(out, d.buf[lba * sector_size ..][0..sector_size]);
    }
    d.reads += 1;
    return out;
}

pub fn blockWrite(io: std.Io, id: u32, lba: usize, data: []const u8) BlockError!void {
    const d = try getDevice(id);
    if (data.len != sector_size) return BlockError.BadSize;
    try checkLba(d, lba, 1);
    if (d.is_file) {
        d.file.?.writePositionalAll(io, data, lba * sector_size) catch return BlockError.FileError;
    } else {
        @memcpy(d.buf[lba * sector_size ..][0..sector_size], data);
    }
    d.writes += 1;
}

pub fn blockCopy(io: std.Io, id: u32, dst: usize, src: usize, n: usize) BlockError!void {
    const d = try getDevice(id);
    try checkLba(d, dst, n);
    try checkLba(d, src, n);
    if (d.is_file) {
        var tmp: [sector_size * 8]u8 = undefined;
        var i: usize = 0;
        while (i < n) {
            const chunk: usize = @min(n - i, 8);
            const rn = d.file.?.readPositionalAll(io, tmp[0 .. chunk * sector_size], (src + i) * sector_size) catch return BlockError.FileError;
            if (rn != chunk * sector_size) return BlockError.FileError;
            d.file.?.writePositionalAll(io, tmp[0 .. chunk * sector_size], (dst + i) * sector_size) catch return BlockError.FileError;
            i += chunk;
        }
    } else {
        const db = d.buf[dst * sector_size ..][0 .. n * sector_size];
        const sb = d.buf[src * sector_size ..][0 .. n * sector_size];
        if (dst <= src) {
            std.mem.copyForwards(u8, db, sb);
        } else {
            std.mem.copyBackwards(u8, db, sb);
        }
    }
    d.reads += n;
    d.writes += n;
}

pub fn blockFill(io: std.Io, id: u32, lba: usize, n: usize, byte: u8) BlockError!void {
    const d = try getDevice(id);
    try checkLba(d, lba, n);
    if (d.is_file) {
        var tmp: [sector_size * 8]u8 = undefined;
        @memset(&tmp, byte);
        var i: usize = 0;
        while (i < n) {
            const chunk: usize = @min(n - i, 8);
            d.file.?.writePositionalAll(io, tmp[0 .. chunk * sector_size], (lba + i) * sector_size) catch return BlockError.FileError;
            i += chunk;
        }
    } else {
        @memset(d.buf[lba * sector_size ..][0 .. n * sector_size], byte);
    }
    d.writes += n;
}

pub fn blockFlush(io: std.Io, id: u32) BlockError!void {
    const d = try getDevice(id);
    if (d.is_file) {
        d.file.?.sync(io) catch return BlockError.FileError;
    }
}

pub fn blockClose(alloc: std.mem.Allocator, io: std.Io, id: u32) BlockError!void {
    const d = try getDevice(id);
    if (d.is_file) {
        d.file.?.close(io);
    } else {
        alloc.free(d.buf);
    }
    d.* = .{};
}

pub fn blockStats(id: u32) BlockError!Stats {
    const d = try getDevice(id);
    return .{ .sectors = d.sectors, .reads = d.reads, .writes = d.writes };
}
