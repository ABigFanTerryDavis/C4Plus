const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const Error = error{
    ProcUnavailable,
    BadCommand,
    SpawnFailed,
    BadHandle,
    Timeout,
};

pub const ExecResult = struct {
    code: i32,
    out: []u8,
    err: []u8,
    timed_out: bool,
};

const Proc = struct {
    used: bool = false,
    process: ?HANDLE = null,
    thread: ?HANDLE = null,
    out_read: ?HANDLE = null,
    err_read: ?HANDLE = null,
    done: bool = false,
    code: i32 = 0,
};

var g_procs: [32]Proc = .{Proc{}} ** 32;

fn findSlot() ?usize {
    for (g_procs, 0..) |p, i| {
        if (!p.used) return i;
    }
    return null;
}

pub fn procById(id: u32) ?*Proc {
    if (id == 0 or id > g_procs.len) return null;
    const p = &g_procs[id - 1];
    if (!p.used) return null;
    return p;
}

pub fn buildCommandLine(alloc: std.mem.Allocator, args: []const []const u8, shell: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (shell) {
        out.appendSlice(alloc, "cmd.exe /C ") catch return Error.BadCommand;
        out.appendSlice(alloc, args[0]) catch return Error.BadCommand;
        return out.toOwnedSlice(alloc) catch return Error.BadCommand;
    }
    for (args, 0..) |a, i| {
        if (i > 0) out.append(alloc, ' ') catch return Error.BadCommand;
        quoteArg(alloc, &out, a) catch return Error.BadCommand;
    }
    return out.toOwnedSlice(alloc) catch return Error.BadCommand;
}

fn quoteArg(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len == 0) {
        try out.appendSlice(alloc, "\"\"");
        return;
    }
    var need = false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '\r') {
            need = true;
            break;
        }
    }
    if (!need) {
        try out.appendSlice(alloc, s);
        return;
    }
    try out.append(alloc, '"');
    var bs: usize = 0;
    for (s) |c| {
        if (c == '\\') {
            bs += 1;
            continue;
        }
        if (c == '"') {
            var k: usize = 0;
            while (k < 2 * bs + 1) : (k += 1) try out.append(alloc, '\\');
            try out.append(alloc, '"');
            bs = 0;
            continue;
        }
        var k: usize = 0;
        while (k < bs) : (k += 1) try out.append(alloc, '\\');
        bs = 0;
        try out.append(alloc, c);
    }
    var k: usize = 0;
    while (k < 2 * bs) : (k += 1) try out.append(alloc, '\\');
    try out.append(alloc, '"');
}

const PipePair = struct { read: HANDLE, write: HANDLE };

fn makePipe() Error!PipePair {
    return makePipeDir(false);
}

fn makePipeDir(child_reads: bool) Error!PipePair {
    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };
    var rd: ?HANDLE = null;
    var wr: ?HANDLE = null;
    if (CreatePipe(&rd, &wr, &sa, 0) == 0) return Error.SpawnFailed;
    if (rd == null or wr == null) return Error.SpawnFailed;
    if (child_reads) {
        _ = SetHandleInformation(wr.?, HANDLE_FLAG_INHERIT, 0);
    } else {
        _ = SetHandleInformation(rd.?, HANDLE_FLAG_INHERIT, 0);
    }
    return .{ .read = rd.?, .write = wr.? };
}

fn startChild(alloc: std.mem.Allocator, cmdline: []const u8, out_w: HANDLE, err_w: HANDLE, in_r: ?HANDLE) Error!struct { process: HANDLE, thread: HANDLE } {
    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r orelse GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = out_w;
    si.hStdError = err_w;
    var pi = std.mem.zeroes(PROCESS_INFORMATION);
    const wide = utf16(alloc, cmdline) catch return Error.BadCommand;
    const wz: [*:0]u16 = @ptrCast(wide.ptr);
    if (CreateProcessW(null, wz, null, null, 1, 0, null, null, &si, &pi) == 0) {
        return Error.SpawnFailed;
    }
    return .{ .process = pi.hProcess, .thread = pi.hThread };
}

fn drain(pipe: HANDLE, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    while (true) {
        var avail: u32 = 0;
        if (PeekNamedPipe(pipe, null, 0, null, &avail, null) == 0) return;
        if (avail == 0) return;
        const want = @min(avail, 65536);
        const buf = alloc.alloc(u8, want) catch return;
        var got: u32 = 0;
        if (ReadFile(pipe, buf.ptr, want, &got, null) == 0 or got == 0) return;
        out.appendSlice(alloc, buf[0..got]) catch return;
    }
}

pub fn exec(alloc: std.mem.Allocator, args: []const []const u8, shell: bool, timeout_ms: ?u64, input: ?[]const u8) Error!ExecResult {
    if (!supported) return Error.ProcUnavailable;
    if (args.len == 0) return Error.BadCommand;
    const cmdline = try buildCommandLine(alloc, args, shell);
    const po = try makePipe();
    const pe = try makePipe();
    var pi: ?HANDLE = null;
    var pi_w: ?HANDLE = null;
    if (input) |inp| {
        const p = try makePipeDir(true);
        pi = p.read;
        pi_w = p.write;
        var off: usize = 0;
        while (off < inp.len) {
            var wrote: u32 = 0;
            const chunk: u32 = @intCast(@min(inp.len - off, 65536));
            if (WriteFile(p.write, inp.ptr + off, chunk, &wrote, null) == 0 or wrote == 0) break;
            off += wrote;
        }
        _ = CloseHandle(p.write);
        pi_w = null;
    }
    const child = startChild(alloc, cmdline, po.write, pe.write, pi) catch {
        _ = CloseHandle(po.read);
        _ = CloseHandle(po.write);
        _ = CloseHandle(pe.read);
        _ = CloseHandle(pe.write);
        if (pi) |h| _ = CloseHandle(h);
        return Error.SpawnFailed;
    };
    _ = CloseHandle(po.write);
    _ = CloseHandle(pe.write);
    _ = CloseHandle(child.thread);
    if (pi) |h| _ = CloseHandle(h);
    var out_list: std.ArrayList(u8) = .empty;
    var err_list: std.ArrayList(u8) = .empty;
    var timed_out = false;
    if (timeout_ms) |limit| {
        var elapsed: u64 = 0;
        while (true) {
            drain(po.read, alloc, &out_list);
            drain(pe.read, alloc, &err_list);
            if (WaitForSingleObject(child.process, 20) == WAIT_OBJECT_0) break;
            elapsed += 20;
            if (elapsed >= limit) {
                timed_out = true;
                _ = TerminateProcess(child.process, 1);
                _ = WaitForSingleObject(child.process, 2000);
                break;
            }
        }
    } else {
        while (true) {
            drain(po.read, alloc, &out_list);
            drain(pe.read, alloc, &err_list);
            if (WaitForSingleObject(child.process, 20) == WAIT_OBJECT_0) break;
        }
    }
    drain(po.read, alloc, &out_list);
    drain(pe.read, alloc, &err_list);
    var code: u32 = 0;
    _ = GetExitCodeProcess(child.process, &code);
    _ = CloseHandle(child.process);
    _ = CloseHandle(po.read);
    _ = CloseHandle(pe.read);
    return .{
        .code = @bitCast(code),
        .out = toUtf8(alloc, out_list.items),
        .err = toUtf8(alloc, err_list.items),
        .timed_out = timed_out,
    };
}

pub fn spawn(alloc: std.mem.Allocator, args: []const []const u8, shell: bool, input: ?[]const u8) Error!u32 {
    if (!supported) return Error.ProcUnavailable;
    if (args.len == 0) return Error.BadCommand;
    const slot = findSlot() orelse return Error.SpawnFailed;
    const cmdline = try buildCommandLine(alloc, args, shell);
    const po = try makePipe();
    const pe = try makePipe();
    var pi: ?HANDLE = null;
    if (input) |inp| {
        const p = try makePipeDir(true);
        pi = p.read;
        var off: usize = 0;
        while (off < inp.len) {
            var wrote: u32 = 0;
            const chunk: u32 = @intCast(@min(inp.len - off, 65536));
            if (WriteFile(p.write, inp.ptr + off, chunk, &wrote, null) == 0 or wrote == 0) break;
            off += wrote;
        }
        _ = CloseHandle(p.write);
    }
    const child = startChild(alloc, cmdline, po.write, pe.write, pi) catch {
        _ = CloseHandle(po.read);
        _ = CloseHandle(po.write);
        _ = CloseHandle(pe.read);
        _ = CloseHandle(pe.write);
        if (pi) |h| _ = CloseHandle(h);
        return Error.SpawnFailed;
    };
    _ = CloseHandle(po.write);
    _ = CloseHandle(pe.write);
    _ = CloseHandle(child.thread);
    if (pi) |h| _ = CloseHandle(h);
    g_procs[slot] = .{
        .used = true,
        .process = child.process,
        .thread = null,
        .out_read = po.read,
        .err_read = pe.read,
        .done = false,
        .code = 0,
    };
    return @intCast(slot + 1);
}

pub fn readOut(alloc: std.mem.Allocator, id: u32) ?[]u8 {
    const p = procById(id) orelse return null;
    const h = p.out_read orelse return alloc.dupe(u8, "") catch return null;
    var list: std.ArrayList(u8) = .empty;
    drain(h, alloc, &list);
    return toUtf8(alloc, list.items);
}

pub fn readErr(alloc: std.mem.Allocator, id: u32) ?[]u8 {
    const p = procById(id) orelse return null;
    const h = p.err_read orelse return alloc.dupe(u8, "") catch return null;
    var list: std.ArrayList(u8) = .empty;
    drain(h, alloc, &list);
    return toUtf8(alloc, list.items);
}

pub fn poll(id: u32) ?i32 {
    const p = procById(id) orelse return null;
    if (p.done) return p.code;
    const h = p.process orelse return null;
    if (WaitForSingleObject(h, 0) != WAIT_OBJECT_0) return null;
    var code: u32 = 0;
    const ph = p.process orelse return null;
    _ = GetExitCodeProcess(ph, &code);
    p.done = true;
    p.code = @bitCast(code);
    return p.code;
}

pub fn kill(id: u32) bool {
    const p = procById(id) orelse return false;
    if (p.done) return false;
    const h = p.process orelse return false;
    if (TerminateProcess(h, 1) == 0) {
        if (WaitForSingleObject(h, 0) != WAIT_OBJECT_0) return false;
    }
    p.done = true;
    p.code = 1;
    return true;
}

pub fn close(id: u32) bool {
    const p = procById(id) orelse return false;
    if (p.process) |h| _ = CloseHandle(h);
    if (p.out_read) |h| _ = CloseHandle(h);
    if (p.err_read) |h| _ = CloseHandle(h);
    p.* = .{};
    return true;
}

fn toUtf8(alloc: std.mem.Allocator, bytes: []const u8) []u8 {
    if (bytes.len == 0) return alloc.dupe(u8, "") catch return &.{};
    const cp = GetConsoleOutputCP();
    if (cp == 65001) return alloc.dupe(u8, bytes) catch return &.{};
    const wlen = MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), null, 0);
    if (wlen <= 0) return alloc.dupe(u8, bytes) catch return &.{};
    const wbuf = alloc.alloc(u16, @intCast(wlen)) catch return alloc.dupe(u8, bytes) catch return &.{};
    if (MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), wbuf.ptr, wlen) <= 0) {
        return alloc.dupe(u8, bytes) catch return &.{};
    }
    const ulen = WideCharToMultiByte(65001, 0, wbuf.ptr, wlen, null, 0, null, null);
    if (ulen <= 0) return alloc.dupe(u8, bytes) catch return &.{};
    const out = alloc.alloc(u8, @intCast(ulen)) catch return alloc.dupe(u8, bytes) catch return &.{};
    if (WideCharToMultiByte(65001, 0, wbuf.ptr, wlen, out.ptr, ulen, null, null) <= 0) {
        return alloc.dupe(u8, bytes) catch return &.{};
    }
    return out;
}

fn utf16(alloc: std.mem.Allocator, s: []const u8) ![]u16 {
    var list: std.ArrayList(u16) = .empty;
    try list.ensureTotalCapacity(alloc, s.len + 1);
    var i: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + seq, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch 0xFFFD;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try list.append(alloc, @intCast(0xD800 + (v >> 10)));
            try list.append(alloc, @intCast(0xDC00 + (v & 0x3FF)));
        } else {
            try list.append(alloc, @intCast(cp));
        }
        i = end;
    }
    try list.append(alloc, 0);
    return list.items;
}

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: i32,
};

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const INFINITE: DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: DWORD = 0x00000000;
const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6;

extern "kernel32" fn CreatePipe(hReadPipe: *?HANDLE, hWritePipe: *?HANDLE, lpPipeAttributes: *SECURITY_ATTRIBUTES, nSize: u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: [*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
extern "kernel32" fn MultiByteToWideChar(CodePage: UINT, dwFlags: DWORD, lpMultiByteStr: [*]const u8, cbMultiByte: i32, lpWideCharStr: ?[*]u16, cchWideChar: i32) callconv(.winapi) i32;
extern "kernel32" fn WideCharToMultiByte(CodePage: UINT, dwFlags: DWORD, lpWideCharStr: [*]const u16, cchWideChar: i32, lpMultiByteStr: ?[*]u8, cbMultiByte: i32, lpDefaultChar: ?[*]const u8, lpUsedDefaultChar: ?*BOOL) callconv(.winapi) i32;
