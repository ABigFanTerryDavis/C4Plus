const std = @import("std");

pub const max_sockets = 16;
pub const recv_cap = 8 * 1024 * 1024;

const Slot = struct {
    used: bool = false,
    server: bool = false,
    stream: std.Io.net.Stream = undefined,
    srv: std.Io.net.Server = undefined,
};

var slots: [max_sockets]Slot = [_]Slot{.{}} ** max_sockets;

fn takeSlot() ?u32 {
    for (&slots, 0..) |*s, i| {
        if (!s.used) {
            s.used = true;
            return @intCast(i + 1);
        }
    }
    return null;
}

fn getSlot(id: u32) ?*Slot {
    if (id == 0 or id > max_sockets) return null;
    const s = &slots[id - 1];
    if (!s.used) return null;
    return s;
}

pub fn sockConnect(alloc: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !u32 {
    _ = alloc;
    var addr = try std.Io.net.IpAddress.resolve(io, host, port);
    const stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    const id = takeSlot() orelse {
        stream.close(io);
        return error.TooManySockets;
    };
    slots[id - 1].server = false;
    slots[id - 1].stream = stream;
    return id;
}

pub fn sockListen(alloc: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !u32 {
    _ = alloc;
    var addr = try std.Io.net.IpAddress.resolve(io, host, port);
    var srv = try std.Io.net.IpAddress.listen(&addr, io, .{});
    errdefer srv.deinit(io);
    const id = takeSlot() orelse return error.TooManySockets;
    slots[id - 1].server = true;
    slots[id - 1].srv = srv;
    return id;
}

pub fn sockAccept(alloc: std.mem.Allocator, io: std.Io, id: u32) !u32 {
    _ = alloc;
    const s = getSlot(id) orelse return error.BadHandle;
    if (!s.server) return error.NotAServer;
    const stream = try s.srv.accept(io);
    const nid = takeSlot() orelse {
        stream.close(io);
        return error.TooManySockets;
    };
    slots[nid - 1].server = false;
    slots[nid - 1].stream = stream;
    return nid;
}

pub fn sockSend(alloc: std.mem.Allocator, io: std.Io, id: u32, data: []const u8) !usize {
    _ = alloc;
    const s = getSlot(id) orelse return error.BadHandle;
    if (s.server) return error.NotAStream;
    var wbuf: [8192]u8 = undefined;
    var writer = s.stream.writer(io, &wbuf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    return data.len;
}

pub fn sockRecvLine(alloc: std.mem.Allocator, io: std.Io, id: u32) ![]u8 {
    const s = getSlot(id) orelse return error.BadHandle;
    if (s.server) return error.NotAStream;
    var out: std.ArrayList(u8) = .empty;
    var rbuf: [256]u8 = undefined;
    var reader = s.stream.reader(io, &rbuf);
    var one: [1]u8 = undefined;
    while (out.items.len < 1024 * 1024) {
        const n = reader.interface.readSliceShort(&one) catch |err| switch (err) {
            error.ReadFailed => break,
            else => |e| return e,
        };
        if (n == 0) break;
        if (one[0] == '\n') break;
        if (one[0] != '\r') try out.append(alloc, one[0]);
    }
    return try out.toOwnedSlice(alloc);
}

pub fn sockRecv(alloc: std.mem.Allocator, io: std.Io, id: u32, max: usize) ![]u8 {
    const s = getSlot(id) orelse return error.BadHandle;
    if (s.server) return error.NotAStream;
    const cap = @min(max, recv_cap);
    const bufsize = @min(cap, 65536);
    if (bufsize == 0) return error.TooBig;
    const out = try alloc.alloc(u8, bufsize);
    var rbuf: [8192]u8 = undefined;
    var reader = s.stream.reader(io, &rbuf);
    const n = reader.interface.readSliceShort(out) catch |err| switch (err) {
        error.ReadFailed => return error.ConnectionLost,
        else => |e| return e,
    };
    return out[0..n];
}

pub fn sockClose(io: std.Io, id: u32) bool {
    const s = getSlot(id) orelse return false;
    if (s.server) {
        s.srv.deinit(io);
    } else {
        s.stream.close(io);
    }
    s.* = .{};
    return true;
}

pub const Error = error{
    BadHandle,
    NotAServer,
    NotAStream,
    TooManySockets,
    TooBig,
    ConnectionLost,
};
