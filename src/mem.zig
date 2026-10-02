const std = @import("std");

// mem module backend: kernel-style allocators over byte regions.
// Arenas bump-allocate (like the 0.4.0 1MB kernel pool); pools hand out
// fixed-size slots (slab style). Handles are small ints so the C emitter
// shares exact semantics with the interpreter.

pub const max_regions = 32;
pub const max_bytes = 16 * 1024 * 1024;

pub const MemError = error{
    BadHandle,
    TooBig,
    OutOfMemory,
    OutOfBounds,
    NotArena,
    NotPool,
    BadSlot,
    BadArgs,
};

const Region = struct {
    used: bool = false,
    is_pool: bool = false,
    buf: []u8 = &.{},
    // arena state
    bump: usize = 0,
    peak: usize = 0,
    allocs: usize = 0,
    // pool state
    objsz: usize = 0,
    count: usize = 0,
    live: usize = 0,
    stack: []u32 = &.{},
    free_top: usize = 0,
};

var regions: [max_regions]Region = [_]Region{.{}} ** max_regions;

fn takeRegion() ?u32 {
    for (&regions, 0..) |*r, i| {
        if (!r.used) {
            r.used = true;
            return @intCast(i + 1);
        }
    }
    return null;
}

fn getRegion(id: u32) MemError!*Region {
    if (id == 0 or id > max_regions) return MemError.BadHandle;
    const r = &regions[id - 1];
    if (!r.used) return MemError.BadHandle;
    return r;
}

pub const Usage = struct {
    size: usize,
    used: usize,
    peak: usize,
    units: usize,
};

pub fn memArena(alloc: std.mem.Allocator, size: usize) MemError!u32 {
    if (size > max_bytes) return MemError.TooBig;
    const id = takeRegion() orelse return MemError.OutOfMemory;
    const r = &regions[id - 1];
    r.* = .{};
    r.used = true;
    r.is_pool = false;
    r.buf = alloc.alloc(u8, size) catch return MemError.OutOfMemory;
    @memset(r.buf, 0);
    return id;
}

pub fn memPool(alloc: std.mem.Allocator, objsz: usize, count: usize) MemError!u32 {
    if (objsz == 0 or count == 0) return MemError.BadArgs;
    const total = std.math.mul(usize, objsz, count) catch return MemError.TooBig;
    if (total > max_bytes) return MemError.TooBig;
    const id = takeRegion() orelse return MemError.OutOfMemory;
    const r = &regions[id - 1];
    r.* = .{};
    r.used = true;
    r.is_pool = true;
    r.buf = alloc.alloc(u8, total) catch return MemError.OutOfMemory;
    @memset(r.buf, 0);
    r.stack = alloc.alloc(u32, count) catch {
        alloc.free(r.buf);
        r.* = .{};
        return MemError.OutOfMemory;
    };
    r.objsz = objsz;
    r.count = count;
    for (0..count) |i| r.stack[i] = @intCast(count - 1 - i);
    r.free_top = count;
    return id;
}

// Arena bump alloc, 4-aligned. Returns offset, or -1 when full.
pub fn memAlloc(id: u32, n: usize) MemError!i64 {
    const r = try getRegion(id);
    if (r.is_pool) return MemError.NotArena;
    if (n == 0) return MemError.BadArgs;
    const aligned = (r.bump + 3) & ~@as(usize, 3);
    const end = std.math.add(usize, aligned, n) catch return -1;
    if (end > r.buf.len) return -1;
    r.bump = end;
    r.allocs += 1;
    if (end > r.peak) r.peak = end;
    return @intCast(aligned);
}

// Pool acquire: returns slot index, or -1 when empty.
pub fn memAcquire(id: u32) MemError!i64 {
    const r = try getRegion(id);
    if (!r.is_pool) return MemError.NotPool;
    if (r.free_top == 0) return -1;
    r.free_top -= 1;
    r.live += 1;
    const used = r.live * r.objsz;
    if (used > r.peak) r.peak = used;
    return r.stack[r.free_top];
}

pub fn memRelease(id: u32, idx: usize) MemError!bool {
    const r = try getRegion(id);
    if (!r.is_pool) return MemError.NotPool;
    if (idx >= r.count) return MemError.BadSlot;
    for (r.stack[0..r.free_top]) |v| {
        if (v == idx) return false; // double free
    }
    r.stack[r.free_top] = @intCast(idx);
    r.free_top += 1;
    r.live -= 1;
    return true;
}

fn checkRange(r: *Region, off: usize, n: usize) MemError!void {
    const end = std.math.add(usize, off, n) catch return MemError.OutOfBounds;
    if (end > r.buf.len) return MemError.OutOfBounds;
}

pub fn memRead(id: u32, off: usize, width: usize) MemError!u32 {
    const r = try getRegion(id);
    try checkRange(r, off, width);
    var v: u32 = 0;
    for (0..width) |i| v |= @as(u32, r.buf[off + i]) << @intCast(8 * i);
    return v;
}

pub fn memWrite(id: u32, off: usize, width: usize, val: u32) MemError!void {
    const r = try getRegion(id);
    try checkRange(r, off, width);
    for (0..width) |i| r.buf[off + i] = @intCast((val >> @intCast(8 * i)) & 0xFF);
}

pub fn memFill(id: u32, off: usize, n: usize, byte: u8) MemError!void {
    const r = try getRegion(id);
    try checkRange(r, off, n);
    @memset(r.buf[off..][0..n], byte);
}

pub fn memCopy(id: u32, dst: usize, src: usize, n: usize) MemError!void {
    const r = try getRegion(id);
    try checkRange(r, dst, n);
    try checkRange(r, src, n);
    if (dst <= src) {
        std.mem.copyForwards(u8, r.buf[dst..][0..n], r.buf[src..][0..n]);
    } else {
        std.mem.copyBackwards(u8, r.buf[dst..][0..n], r.buf[src..][0..n]);
    }
}

pub fn memReset(id: u32) MemError!void {
    const r = try getRegion(id);
    if (r.is_pool) {
        for (0..r.count) |i| r.stack[i] = @intCast(r.count - 1 - i);
        r.free_top = r.count;
        r.live = 0;
    } else {
        r.bump = 0;
        r.allocs = 0;
    }
    @memset(r.buf, 0);
}

pub fn memUsage(id: u32) MemError!Usage {
    const r = try getRegion(id);
    if (r.is_pool) {
        const used = r.live * r.objsz;
        return .{ .size = r.buf.len, .used = used, .peak = r.peak, .units = r.live };
    }
    return .{ .size = r.buf.len, .used = r.bump, .peak = r.peak, .units = r.allocs };
}
