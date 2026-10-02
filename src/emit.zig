// --emit-c backend: C4Plus -> C99 (gcc). v1 subset documented in 36_emit template.
//
// Expressions are single-pass text builders (no re-parsing): each emit*Text
// parses once and returns C source text. Temps for literals go to a shared
// prelude buffer; every statement flushes its prelude slice before itself.
const std = @import("std");
const Io = std.Io;

pub const EmitError = error{
    Unsupported,
    OutOfMemory,
};

const FnInfo = struct { params: [][]const u8 };
const StructInfo = struct { fields: [][]const u8 };

pub const Emitter = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pre: *std.ArrayList(u8),
    fns: *std.ArrayList(u8),
    file: []const u8,
    base_dir: std.Io.Dir,
    io: Io,
    imported: *std.StringHashMap(bool),
    fns_table: *std.StringHashMap(FnInfo),
    structs_table: *std.StringHashMap(StructInfo),
    mods: *std.StringHashMap(bool),
    tmpc: usize = 0,
    indent: usize = 0,
    fn_depth: usize = 0,
    loop_depth: usize = 0,
    try_depth: usize = 0,
    loop_try: [64]usize = [_]usize{0} ** 64,
    loop_try_len: usize = 0,
    fn_ids: *std.StringHashMap(usize),
    valnames: *std.StringHashMap(bool),
    fs: bool = false,

    fn w(self: *Emitter, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }
    fn emitIndent(self: *Emitter) !void {
        var i: usize = 0;
        while (i < self.indent * 4) : (i += 1) try self.out.append(self.alloc, ' ');
    }
    fn fail(self: *Emitter, comptime fmt: []const u8, args: anytype) EmitError {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "emit error";
        std.debug.print("{s}:{d}: emit v1: {s}\n", .{ self.file, self.line, msg });
        return EmitError.Unsupported;
    }
    fn tmp(self: *Emitter) ![]const u8 {
        const n = self.tmpc;
        self.tmpc += 1;
        return try std.fmt.allocPrint(self.alloc, "__c4_t{d}", .{n});
    }
    fn subFor(self: *Emitter, src: []const u8, out: *std.ArrayList(u8)) Emitter {
        return Emitter{
            .src = src,
            .alloc = self.alloc,
            .out = out,
            .pre = self.pre,
            .fns = self.fns,
            .file = self.file,
            .base_dir = self.base_dir,
            .io = self.io,
            .imported = self.imported,
            .fns_table = self.fns_table,
            .structs_table = self.structs_table,
            .mods = self.mods,
            .fs = self.fs,
            .tmpc = self.tmpc,
            .indent = self.indent,
            .fn_depth = self.fn_depth,
            .loop_depth = self.loop_depth,
            .try_depth = self.try_depth,
            .loop_try = self.loop_try,
            .loop_try_len = self.loop_try_len,
            .fn_ids = self.fn_ids,
            .valnames = self.valnames,
        };
    }

    // ---------- lex helpers ----------
    fn skipSpaces(self: *Emitter) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) : (self.pos += 1) {}
    }
    fn skipNewlines(self: *Emitter) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (c == '\n') self.line += 1;
                self.pos += 1;
            } else break;
        }
    }
    fn eatComment(self: *Emitter) bool {
        if (self.pos < self.src.len and self.src[self.pos] == '#') {
            while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            return true;
        }
        if (self.pos + 1 < self.src.len and self.src[self.pos] == '/' and self.src[self.pos + 1] == '/') {
            while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            return true;
        }
        return false;
    }
    fn skipListWs(self: *Emitter) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (c == '\n') self.line += 1;
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else break;
        }
    }
    fn parseIdent(self: *Emitter) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
        if (start == self.pos) return self.fail("expected identifier", .{});
        return self.src[start..self.pos];
    }
    fn matchWordAt(self: *Emitter, at: usize, word: []const u8) bool {
        if (at + word.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[at .. at + word.len], word)) return false;
        if (at + word.len < self.src.len) {
            const c = self.src[at + word.len];
            if (std.ascii.isAlphanumeric(c) or c == '_') return false;
        }
        return true;
    }
    fn emitCLitBuf(alloc: std.mem.Allocator, raw: []const u8, buf: *std.ArrayList(u8)) !void {
        try buf.append(alloc, '"');
        for (raw) |c| {
            switch (c) {
                '"' => try buf.appendSlice(alloc, "\\\""),
                '\\' => try buf.appendSlice(alloc, "\\\\"),
                '\n' => try buf.appendSlice(alloc, "\\n"),
                '\r' => try buf.appendSlice(alloc, "\\r"),
                '\t' => try buf.appendSlice(alloc, "\\t"),
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        try buf.appendSlice(alloc, "\\x");
                        try buf.append(alloc, hex[c >> 4]);
                        try buf.append(alloc, hex[c & 15]);
                    } else try buf.append(alloc, c);
                },
            }
        }
        try buf.append(alloc, '"');
    }
    fn parseStringBytes(self: *Emitter) ![]const u8 {        if (self.pos >= self.src.len or (self.src[self.pos] != '"' and self.src[self.pos] != '\'')) return self.fail("expected string", .{});
        const quote = self.src[self.pos];
        self.pos += 1;
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return self.fail("unterminated string", .{});
            const c = self.src[self.pos];
            if (c == quote) {
                self.pos += 1;
                return try buf.toOwnedSlice(self.alloc);
            }
            if (c == '\n') return self.fail("unterminated string", .{});
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const e = self.src[self.pos + 1];
                try buf.append(self.alloc, switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '"' => '"',
                    '\'' => '\'',
                    '\\' => '\\',
                    else => e,
                });
                self.pos += 2;
                continue;
            }
            try buf.append(self.alloc, c);
            self.pos += 1;
        }
    }
    fn parseNumberText(self: *Emitter) ![]const u8 {
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        var seen_digit = false;
        var seen_dot = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c)) {
                seen_digit = true;
                self.pos += 1;
            } else if (c == '.' and !seen_dot and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                seen_dot = true;
                self.pos += 1;
            } else break;
        }
        if (!seen_digit) return self.fail("bad number", .{});
        return self.src[start..self.pos];
    }
    fn expectEnd(self: *Emitter) !void {
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == ';') self.pos += 1;
        self.skipSpaces();
        if (self.pos >= self.src.len) return;
        const c = self.src[self.pos];
        if (c == '\n' or c == '\r' or c == '#' or c == '}') return;
        if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') return;
        return self.fail("expected newline after statement", .{});
    }
    fn cname(prefix: []const u8, name: []const u8, alloc: std.mem.Allocator) ![]const u8 {
        return try std.mem.concat(alloc, u8, &.{ prefix, name });
    }
    fn captureBody(self: *Emitter) ![]const u8 {
        self.pos += 1;
        const start = self.pos;
        var depth: usize = 1;
        var in_str: u8 = 0;
        var i = self.pos;
        while (i < self.src.len) {
            const c = self.src[i];
            if (in_str != 0) {
                if (c == '\\' and i + 1 < self.src.len) {
                    i += 2;
                    continue;
                }
                if (c == in_str) in_str = 0;
                if (c == '\n') self.line += 1;
                i += 1;
                continue;
            }
            if (c == '"' or c == '\'') {
                in_str = c;
                i += 1;
                continue;
            }
            if (c == '#') {
                while (i < self.src.len and self.src[i] != '\n') : (i += 1) {}
                continue;
            }
            if (c == '/' and i + 1 < self.src.len and self.src[i + 1] == '/') {
                while (i < self.src.len and self.src[i] != '\n') : (i += 1) {}
                continue;
            }
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    self.pos = i + 1;
                    return self.src[start..i];
                }
            }
            if (c == '\n') self.line += 1;
            i += 1;
        }
        return self.fail("unterminated block", .{});
    }
    // run body source sharing scope; propagates temps/indent/mods back
    fn emitBodySrc(self: *Emitter, body: []const u8, body_line: usize) anyerror!void {
        var sub = Emitter{
            .src = body,
            .pos = 0,
            .line = body_line,
            .alloc = self.alloc,
            .out = self.out,
            .pre = self.pre,
            .fns = self.fns,
            .file = self.file,
            .base_dir = self.base_dir,
            .io = self.io,
            .imported = self.imported,
            .fns_table = self.fns_table,
            .structs_table = self.structs_table,
            .mods = self.mods,
            .fs = self.fs,
            .tmpc = self.tmpc,
            .indent = self.indent,
            .fn_depth = self.fn_depth,
            .loop_depth = self.loop_depth,
            .try_depth = self.try_depth,
            .loop_try = self.loop_try,
            .loop_try_len = self.loop_try_len,
            .fn_ids = self.fn_ids,
            .valnames = self.valnames,
        };
        try sub.run();
        self.tmpc = sub.tmpc;
        self.line = sub.line;
        var mit = sub.mods.iterator();
        while (mit.next()) |e| {
            if (!self.mods.contains(e.key_ptr.*)) {
                try self.mods.put(try self.alloc.dupe(u8, e.key_ptr.*), true);
            }
        }
    }
    // prelude text helper for expressions
    fn emitPrelude(self: *Emitter, s: []const u8) !void {
        try self.pre.appendSlice(self.alloc, s);
    }

    // ---------- statements (each flushes its prelude slice first) ----------
    pub fn run(self: *Emitter) anyerror!void {
        while (true) {
            self.skipNewlines();
            if (self.pos >= self.src.len) break;
            if (self.eatComment()) continue;
            try self.emitStmt();
        }
    }

    fn emitStmt(self: *Emitter) anyerror!void {
        const mark = self.pre.items.len;
        var sbuf: std.ArrayList(u8) = .empty;
        const saved_out = self.out;
        const saved_indent = self.indent;
        self.out = &sbuf;
        try self.emitStmtInner();
        self.out = saved_out;
        self.indent = saved_indent;
        try saved_out.appendSlice(self.alloc, self.pre.items[mark..]);
        self.pre.shrinkRetainingCapacity(mark);
        try saved_out.appendSlice(self.alloc, sbuf.items);
    }

    fn emitStmtInner(self: *Emitter) anyerror!void {
        const kw_start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
        if (kw_start == self.pos) return self.fail("expected statement", .{});
        const kw = self.src[kw_start..self.pos];
        if (std.mem.eql(u8, kw, "let")) {
            self.skipSpaces();
            const name = try self.parseIdent();
            self.skipSpaces();
            if (self.pos >= self.src.len or self.src[self.pos] != '=') return self.fail("expected '=' after let", .{});
            self.pos += 1;
            const e = try self.emitExprText();
            try self.expectEnd();
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(try cname("v_", name, self.alloc));
            try self.w(" = ");
            try self.w(e);
            try self.w(";\n");
            try self.valnames.put(try self.alloc.dupe(u8, name), true);
            return;
        }
        if (std.mem.eql(u8, kw, "print") or std.mem.eql(u8, kw, "pt")) {
            self.skipSpaces();
            var e: []const u8 = undefined;
            if (self.pos < self.src.len and self.src[self.pos] == '(') {
                self.pos += 1;
                e = try self.emitExprText();
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return self.fail("expected ')'", .{});
                self.pos += 1;
            } else {
                e = try self.emitExprText();
            }
            try self.expectEnd();
            try self.emitIndent();
            try self.w("c4_print(");
            try self.w(e);
            try self.w(");\n");
            return;
        }
        if (std.mem.eql(u8, kw, "fn")) {
            if (self.fn_depth > 0) return self.fail("nested fn not in emit v1", .{});
            try self.emitFnDef();
            return;
        }
        if (std.mem.eql(u8, kw, "struct")) {
            if (self.fn_depth > 0) return self.fail("nested struct not in emit v1", .{});
            try self.emitStructDef();
            return;
        }
        if (std.mem.eql(u8, kw, "if")) {
            try self.emitIf();
            return;
        }
        if (std.mem.eql(u8, kw, "while")) {
            try self.emitWhile();
            return;
        }
        if (std.mem.eql(u8, kw, "for")) {
            try self.emitFor();
            return;
        }
        if (std.mem.eql(u8, kw, "switch")) {
            try self.emitSwitch();
            return;
        }
        if (std.mem.eql(u8, kw, "try")) {
            if (self.fs) return self.fail("try/catch not in freestanding emit", .{});
            try self.emitTry();
            return;
        }
        if (std.mem.eql(u8, kw, "return")) {
            if (self.fn_depth == 0) return self.fail("'return' outside function", .{});
            self.skipSpaces();
            const e = try self.emitExprText();
            try self.expectEnd();
            try self.emitIndent();
            try self.emitTryUnwind(self.try_depth);
            try self.w("return ");
            try self.w(e);
            try self.w(";\n");
            return;
        }
        if (std.mem.eql(u8, kw, "break")) {
            if (self.loop_depth == 0) return self.fail("'break' outside loop", .{});
            try self.expectEnd();
            try self.emitIndent();
            if (self.loop_try_len > 0) try self.emitTryUnwind(self.try_depth - self.loop_try[self.loop_try_len - 1]);
            try self.w("break;\n");
            return;
        }
        if (std.mem.eql(u8, kw, "continue")) {
            if (self.loop_depth == 0) return self.fail("'continue' outside loop", .{});
            try self.expectEnd();
            try self.emitIndent();
            if (self.loop_try_len > 0) try self.emitTryUnwind(self.try_depth - self.loop_try[self.loop_try_len - 1]);
            try self.w("continue;\n");
            return;
        }
        if (std.mem.eql(u8, kw, "import")) {
            try self.emitImport();
            return;
        }
        if (std.mem.eql(u8, kw, "asm")) {
            self.skipSpaces();
            var code: []const u8 = undefined;
            if (self.pos < self.src.len and self.src[self.pos] == '(') {
                self.pos += 1;
                self.skipSpaces();
                code = try self.parseStringBytes();
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return self.fail("expected ')'", .{});
                self.pos += 1;
            } else {
                code = try self.parseStringBytes();
            }
            try self.expectEnd();
            try self.emitIndent();
            try self.w("__asm__ volatile (");
            var clb: std.ArrayList(u8) = .empty;
            try emitCLitBuf(self.alloc, code, &clb);
            try self.w(clb.items);
            try self.w(");\n");
            return;
        }
        if (std.mem.eql(u8, kw, "else") or std.mem.eql(u8, kw, "elif")) {
            return self.fail("dangling else/elif", .{});
        }
        self.pos = kw_start;
        try self.emitAssignOrCallStmt();
    }

    fn emitAssignOrCallStmt(self: *Emitter) !void {
        const start = self.pos;
        const name = try self.parseIdent();
        var p = self.pos;
        while (p < self.src.len and (self.src[p] == ' ' or self.src[p] == '\t')) : (p += 1) {}
        var is_call = false;
        if (p < self.src.len and self.src[p] == '(') {
            is_call = true;
        } else {
            var q = p;
            var done = false;
            while (!done) {
                while (q < self.src.len and (self.src[q] == ' ' or self.src[q] == '\t')) : (q += 1) {}
                if (q < self.src.len and self.src[q] == '.') {
                    var r = q + 1;
                    while (r < self.src.len and (self.src[r] == ' ' or self.src[r] == '\t')) : (r += 1) {}
                    if (r < self.src.len and (std.ascii.isAlphabetic(self.src[r]) or self.src[r] == '_')) {
                        while (r < self.src.len and (std.ascii.isAlphanumeric(self.src[r]) or self.src[r] == '_')) : (r += 1) {}
                        while (r < self.src.len and (self.src[r] == ' ' or self.src[r] == '\t')) : (r += 1) {}
                        if (r < self.src.len and self.src[r] == '(') {
                            is_call = true;
                            done = true;
                        } else {
                            q = r;
                        }
                    } else {
                        done = true;
                    }
                } else if (q < self.src.len and self.src[q] == '[') {
                    var depth: usize = 1;
                    q += 1;
                    var instr: u8 = 0;
                    while (q < self.src.len and depth > 0) {
                        const c = self.src[q];
                        if (instr != 0) {
                            if (c == '\\') {
                                q += 2;
                                continue;
                            }
                            if (c == instr) instr = 0;
                            q += 1;
                            continue;
                        }
                        if (c == '"' or c == '\'') {
                            instr = c;
                            q += 1;
                            continue;
                        }
                        if (c == '[') depth += 1;
                        if (c == ']') depth -= 1;
                        q += 1;
                    }
                } else {
                    done = true;
                }
            }
            if (q < self.src.len and self.src[q] == '(') is_call = true;
        }
        if (is_call) {
            self.pos = start;
            var np = start;
            while (np < self.src.len and (std.ascii.isAlphanumeric(self.src[np]) or self.src[np] == '_')) : (np += 1) {}
            if (std.mem.eql(u8, self.src[start..np], "exit")) {
                self.pos = start + 4;
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != '(') return self.fail("expected '(' after exit", .{});
                self.pos += 1;
                self.skipSpaces();
                try self.emitIndent();
                try self.w("c4_exit(");
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                    try self.w("c4_num(0)");
                } else {
                    const a = try self.emitExprText();
                    try self.w(a);
                    self.skipSpaces();
                    if (self.pos >= self.src.len or self.src[self.pos] != ')') return self.fail("expected ')'", .{});
                    self.pos += 1;
                }
                try self.w(");\n");
                try self.expectEnd();
                return;
            }
            const e = try self.emitCallOrVarText();
            try self.expectEnd();
            try self.emitIndent();
            try self.w(e);
            try self.w(";\n");
            return;
        }
        // assignment
        self.pos = start + name.len;
        const vbase = try cname("v_", name, self.alloc);
        var segkinds: std.ArrayList(u8) = .empty;
        var segtexts: std.ArrayList([]const u8) = .empty;
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '[') {
                self.pos += 1;
                const es = self.pos;
                var depth: usize = 1;
                var instr: u8 = 0;
                var q = self.pos;
                while (q < self.src.len and depth > 0) {
                    const c = self.src[q];
                    if (instr != 0) {
                        if (c == '\\') {
                            q += 2;
                            continue;
                        }
                        if (c == instr) instr = 0;
                        q += 1;
                        continue;
                    }
                    if (c == '"' or c == '\'') {
                        instr = c;
                        q += 1;
                        continue;
                    }
                    if (c == '[') depth += 1;
                    if (c == ']') depth -= 1;
                    q += 1;
                }
                if (depth != 0) return self.fail("expected ']'", .{});
                self.pos = q;
                try segkinds.append(self.alloc, 0);
                try segtexts.append(self.alloc, self.src[es .. q - 1]);
            } else if (self.pos < self.src.len and self.src[self.pos] == '.' and self.pos + 1 < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos + 1]) or self.src[self.pos + 1] == '_')) {
                self.pos += 1;
                const f = try self.parseIdent();
                try segkinds.append(self.alloc, 1);
                try segtexts.append(self.alloc, f);
            } else {
                self.pos = sp;
                break;
            }
        }
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '=' or (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=')) {
            return self.fail("expected '=' in assignment", .{});
        }
        self.pos += 1;
        if (segkinds.items.len == 0) {
            const e = try self.emitExprText();
            try self.expectEnd();
            try self.emitIndent();
            try self.w(vbase);
            try self.w(" = ");
            try self.w(e);
            try self.w(";\n");
            return;
        }
        // resolve index/field sub-expressions first (may append prelude)
        var idxtexts: std.ArrayList([]const u8) = .empty;
        for (segkinds.items, 0..) |kind, si| {
            if (kind == 0) {
                var sub = self.subFor(segtexts.items[si], self.out);
                sub.tmpc = self.tmpc;
                sub.indent = self.indent;
                const t = try sub.emitExprText();
                self.tmpc = sub.tmpc;
                try idxtexts.append(self.alloc, t);
            } else {
                try idxtexts.append(self.alloc, segtexts.items[si]);
            }
        }
        const rhs = try self.emitExprText();
        try self.expectEnd();
        // navigate with temps (each index expr evaluated once)
        var navs: std.ArrayList([]const u8) = .empty;
        try navs.append(self.alloc, vbase);
        for (segkinds.items[0 .. segkinds.items.len - 1], 0..) |kind, si| {
            const nt = try self.tmp();
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(nt);
            try self.w(" = ");
            if (kind == 0) {
                try self.w("c4_index(");
                try self.w(navs.items[si]);
                try self.w(", ");
                try self.w(idxtexts.items[si]);
                try self.w(")");
            } else {
                try self.w("c4_field(");
                try self.w(navs.items[si]);
                try self.w(", \"");
                try self.w(idxtexts.items[si]);
                try self.w("\")");
            }
            try self.w(";\n");
            try navs.append(self.alloc, nt);
        }
        // write back outward so strings/nesting update the root var
        var cur = rhs;
        var j: usize = segkinds.items.len;
        while (j > 0) {
            j -= 1;
            const nt = try self.tmp();
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(nt);
            try self.w(" = ");
            if (segkinds.items[j] == 0) {
                try self.w("c4_index_set(");
            } else {
                try self.w("c4_field_set(");
            }
            try self.w(navs.items[j]);
            try self.w(", ");
            if (segkinds.items[j] == 0) {
                try self.w(idxtexts.items[j]);
            } else {
                try self.w("\"");
                try self.w(idxtexts.items[j]);
                try self.w("\"");
            }
            try self.w(", ");
            try self.w(cur);
            try self.w(");\n");
            cur = nt;
        }
        try self.emitIndent();
        try self.w(vbase);
        try self.w(" = ");
        try self.w(cur);
        try self.w(";\n");
    }

    fn emitFnDef(self: *Emitter) anyerror!void {
        self.skipSpaces();
        const name = try self.parseIdent();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '(') return self.fail("expected '(' after fn", .{});
        self.pos += 1;
        var params: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            const prm = try self.parseIdent();
            try params.append(self.alloc, prm);
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            } else return self.fail("expected ',' or ')'", .{});
        }
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{}}' for fn body", .{});
        const body = try self.captureBody();
        const body_line = self.line;
        try self.expectEnd();
        const fname = try cname("f_", name, self.alloc);
        const saved_out = self.out;
        self.out = self.fns;
        try self.w("static C4Val ");
        try self.w(fname);
        try self.w("(");
        if (params.items.len == 0) {
            try self.w("void");
        } else {
            for (params.items, 0..) |pr, i| {
                if (i > 0) try self.w(", ");
                try self.w("C4Val ");
                try self.w(try cname("v_", pr, self.alloc));
            }
        }
        try self.w(") {\n");
        self.indent += 1;
        self.fn_depth += 1;
        const saved_loop = self.loop_depth;
        const saved_try = self.try_depth;
        const saved_try_len = self.loop_try_len;
        const saved_vals = self.valnames;
        self.loop_depth = 0;
        self.try_depth = 0;
        self.loop_try_len = 0;
        var fn_vals = std.StringHashMap(bool).init(self.alloc);
        for (params.items) |pr| {
            try fn_vals.put(try self.alloc.dupe(u8, pr), true);
        }
        self.valnames = &fn_vals;
        try self.emitBodySrc(body, body_line);
        self.loop_depth = saved_loop;
        self.try_depth = saved_try;
        self.loop_try_len = saved_try_len;
        self.valnames = saved_vals;
        self.fn_depth -= 1;
        self.indent -= 1;
        try self.w("}\n");
        self.out = saved_out;
    }

    fn emitStructDef(self: *Emitter) !void {
        self.skipSpaces();
        const name = try self.parseIdent();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{}}' after struct", .{});
        self.pos += 1;
        var fields: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipListWs();
            if (self.pos < self.src.len and self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            const f = try self.parseIdent();
            try fields.append(self.alloc, f);
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            } else if (self.pos < self.src.len and self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            } else if (self.pos < self.src.len and (self.src[self.pos] == '\n' or self.src[self.pos] == '\r')) {
                continue;
            } else return self.fail("expected ',' or '}}' in struct", .{});
        }
        try self.expectEnd();
        const owned = try fields.toOwnedSlice(self.alloc);
        const ndup = try self.alloc.dupe(u8, name);
        try self.structs_table.put(ndup, .{ .fields = owned });
        // tables are emitted once from prescan results in emitProgram
    }

    fn emitIf(self: *Emitter) !void {
        self.skipSpaces();
        const cond = try self.emitExprText();
        self.skipSpaces();
        try self.emitIndent();
        try self.w("if (c4_truthy(");
        try self.w(cond);
        try self.w(")) {\n");
        self.indent += 1;
        try self.emitBracedStmts();
        self.indent -= 1;
        try self.emitIndent();
        try self.w("}\n");
        while (true) {
            var tp = self.pos;
            var tl = self.line;
            while (tp < self.src.len and (self.src[tp] == ' ' or self.src[tp] == '\t' or self.src[tp] == '\r' or self.src[tp] == '\n')) {
                if (self.src[tp] == '\n') tl += 1;
                tp += 1;
            }
            if (tp < self.src.len and self.matchWordAt(tp, "elif")) {
                self.pos = tp + 4;
                self.line = tl;
                self.skipSpaces();
                const ec = try self.emitExprText();
                self.skipSpaces();
                try self.emitIndent();
                try self.w("else if (c4_truthy(");
                try self.w(ec);
                try self.w(")) {\n");
                self.indent += 1;
                try self.emitBracedStmts();
                self.indent -= 1;
                try self.emitIndent();
                try self.w("}\n");
            } else break;
        }
        {
            var tp = self.pos;
            var tl = self.line;
            while (tp < self.src.len and (self.src[tp] == ' ' or self.src[tp] == '\t' or self.src[tp] == '\r' or self.src[tp] == '\n')) {
                if (self.src[tp] == '\n') tl += 1;
                tp += 1;
            }
            if (tp < self.src.len and self.matchWordAt(tp, "else")) {
                self.pos = tp + 4;
                self.line = tl;
                self.skipSpaces();
                try self.emitIndent();
                try self.w("else {\n");
                self.indent += 1;
                try self.emitBracedStmts();
                self.indent -= 1;
                try self.emitIndent();
                try self.w("}\n");
            }
        }
        try self.expectEnd();
    }

    fn emitBracedStmts(self: *Emitter) !void {
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{'", .{});
        const body = try self.captureBody();
        const bl = self.line;
        self.indent += 1;
        try self.emitBodySrc(body, bl);
        self.indent -= 1;
    }

    fn emitTryUnwind(self: *Emitter, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.w("c4_try_pop(); ");
        }
    }

    fn emitTryLoopPush(self: *Emitter) !void {
        if (self.loop_try_len >= self.loop_try.len) return self.fail("loop nesting too deep in emit", .{});
        self.loop_try[self.loop_try_len] = self.try_depth;
        self.loop_try_len += 1;
    }

    fn emitTryLoopPop(self: *Emitter) void {
        if (self.loop_try_len > 0) self.loop_try_len -= 1;
    }

    fn emitTry(self: *Emitter) !void {
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{' after try", .{});
        const try_body = try self.captureBody();
        const try_line = self.line;
        var tp = self.pos;
        var tl = self.line;
        while (tp < self.src.len and (self.src[tp] == ' ' or self.src[tp] == '\t' or self.src[tp] == '\r' or self.src[tp] == '\n')) {
            if (self.src[tp] == '\n') tl += 1;
            tp += 1;
        }
        if (!self.matchWordAt(tp, "catch")) return self.fail("expected 'catch e' after try block", .{});
        self.pos = tp + 5;
        self.line = tl;
        self.skipSpaces();
        const bindvar = try self.parseIdent();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{' after catch", .{});
        const catch_body = try self.captureBody();
        const catch_line = self.line;
        try self.expectEnd();
        const jb = try self.tmp();
        try self.emitIndent();
        try self.w("{ jmp_buf *");
        try self.w(jb);
        try self.w(" = c4_try_push(); if (setjmp(*");
        try self.w(jb);
        try self.w(") == 0) {\n");
        self.indent += 1;
        self.try_depth += 1;
        try self.emitBodySrc(try_body, try_line);
        try self.emitIndent();
        try self.w("c4_try_pop();\n");
        self.indent -= 1;
        self.try_depth -= 1;
        try self.emitIndent();
        try self.w("} else {\n");
        self.indent += 1;
        try self.emitIndent();
        try self.w("c4_try_pop();\n");
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(try cname("v_", bindvar, self.alloc));
        try self.w(" = c4_str(c4_catch_msg());\n");
        self.try_depth += 1;
        try self.emitBodySrc(catch_body, catch_line);
        self.try_depth -= 1;
        self.indent -= 1;
        try self.emitIndent();
        try self.w("} }\n");
    }

    fn emitWhile(self: *Emitter) !void {
        self.skipSpaces();
        const cond = try self.emitExprText();
        self.skipSpaces();
        try self.emitIndent();
        try self.w("while (c4_truthy(");
        try self.w(cond);
        try self.w(")) {\n");
        self.indent += 1;
        self.loop_depth += 1;
        try self.emitTryLoopPush();
        try self.emitBracedStmts();
        self.emitTryLoopPop();
        self.loop_depth -= 1;
        self.indent -= 1;
        try self.emitIndent();
        try self.w("}\n");
        try self.expectEnd();
    }

    fn emitFor(self: *Emitter) !void {
        self.skipSpaces();
        const loopvar = try self.parseIdent();
        self.skipSpaces();
        var loopvar2: ?[]const u8 = null;
        if (self.pos < self.src.len and self.src[self.pos] == ',') {
            self.pos += 1;
            self.skipSpaces();
            loopvar2 = try self.parseIdent();
            self.skipSpaces();
        }
        if (!self.matchWordAt(self.pos, "in")) return self.fail("expected 'in' after for", .{});
        self.pos += 2;
        self.skipSpaces();
        const coll = try self.emitExprText();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{}}' after for", .{});
        const body = try self.captureBody();
        const body_line = self.line;
        try self.expectEnd();
        const lv1 = try cname("v_", loopvar, self.alloc);
        const lv2 = if (loopvar2) |l2| try cname("v_", l2, self.alloc) else null;
        try self.valnames.put(try self.alloc.dupe(u8, loopvar), true);
        if (loopvar2) |l2| try self.valnames.put(try self.alloc.dupe(u8, l2), true);
        const tc = try self.tmp();
        const tk = try self.tmp();
        const ti = try self.tmp();
        try self.emitIndent();
        try self.w("{\n");
        self.indent += 1;
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(tc);
        try self.w(" = ");
        try self.w(coll);
        try self.w(";\n");
        try self.emitIndent();
        try self.w("if (");
        try self.w(tc);
        try self.w(".t == C4_DICT) {\n");
        self.indent += 1;
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(tk);
        try self.w(" = c4_keys(");
        try self.w(tc);
        try self.w(");\n");
        try self.emitIndent();
        try self.w("for (");
        try self.w(if (self.fs) "c4_size_t " else "size_t ");
        try self.w(ti);
        try self.w(" = 0; ");
        try self.w(ti);
        try self.w(" < ");
        try self.w(tk);
        try self.w(".list->len; ");
        try self.w(ti);
        try self.w("++) {\n");
        self.indent += 1;
        if (lv2) |l2| {
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(lv1);
            try self.w(" = ");
            try self.w(tk);
            try self.w(".list->items[");
            try self.w(ti);
            try self.w("];\n");
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(l2);
            try self.w(" = c4_index(");
            try self.w(tc);
            try self.w(", ");
            try self.w(lv1);
            try self.w(");\n");
        } else {
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(lv1);
            try self.w(" = ");
            try self.w(tk);
            try self.w(".list->items[");
            try self.w(ti);
            try self.w("];\n");
        }
        self.loop_depth += 1;
        try self.emitTryLoopPush();
        try self.emitBodySrc(body, body_line);
        self.emitTryLoopPop();
        self.loop_depth -= 1;
        try self.emitIndent();
        try self.w("}\n");
        self.indent -= 1;
        try self.emitIndent();
        try self.w("} else if (");
        try self.w(tc);
        try self.w(".t == C4_STR) {\n");
        self.indent += 1;
        try self.emitIndent();
        try self.w("for (");
        try self.w(if (self.fs) "c4_size_t " else "size_t ");
        try self.w(ti);
        try self.w(" = 0; ");
        try self.w(ti);
        try self.w(if (self.fs) " < c4_slen(" else " < strlen(");
        try self.w(tc);
        try self.w(".str); ");
        try self.w(ti);
        try self.w("++) {\n");
        self.indent += 1;
        try self.emitIndent();
        try self.w("char __c4_ch[2] = {(char)");
        try self.w(tc);
        try self.w(".str[");
        try self.w(ti);
        try self.w("], 0};\n");
        if (lv2) |l2| {
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(lv1);
            try self.w(" = c4_num((double)");
            try self.w(ti);
            try self.w(");\n");
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(l2);
            try self.w(" = c4_str(__c4_ch);\n");
        } else {
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(lv1);
            try self.w(" = c4_str(__c4_ch);\n");
        }
        self.loop_depth += 1;
        try self.emitTryLoopPush();
        try self.emitBodySrc(body, body_line);
        self.emitTryLoopPop();
        self.loop_depth -= 1;
        self.indent -= 1;
        try self.emitIndent();
        try self.w("}\n");
        self.indent -= 1;
        try self.emitIndent();
        try self.w("} else {\n");
        self.indent += 1;
        try self.emitIndent();
        try self.w("for (");
        try self.w(if (self.fs) "c4_size_t " else "size_t ");
        try self.w(ti);
        try self.w(" = 0, __c4_n = (");
        try self.w(if (self.fs) "c4_size_t" else "size_t");
        try self.w(")c4_len(");
        try self.w(tc);
        try self.w(").num; ");
        try self.w(ti);
        try self.w(" < __c4_n; ");
        try self.w(ti);
        try self.w("++) {\n");
        self.indent += 1;
        if (lv2) |l2| {
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(lv1);
            try self.w(" = c4_num((double)");
            try self.w(ti);
            try self.w(");\n");
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(l2);
            try self.w(" = c4_index(");
            try self.w(tc);
            try self.w(", ");
            try self.w(lv1);
            try self.w(");\n");
        } else {
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(lv1);
            try self.w(" = c4_index(");
            try self.w(tc);
            try self.w(", c4_num((double)");
            try self.w(ti);
            try self.w("));\n");
        }
        self.loop_depth += 1;
        try self.emitTryLoopPush();
        try self.emitBodySrc(body, body_line);
        self.emitTryLoopPop();
        self.loop_depth -= 1;
        self.indent -= 1;
        try self.emitIndent();
        try self.w("}\n");
        self.indent -= 1;
        try self.emitIndent();
        try self.w("}\n");
        self.indent -= 1;
        try self.emitIndent();
        try self.w("}\n");
    }

    fn emitSwitch(self: *Emitter) !void {
        self.skipSpaces();
        const subj = try self.emitExprText();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return self.fail("expected '{{}}' after switch", .{});
        self.pos += 1;
        const st = try self.tmp();
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(st);
        try self.w(" = ");
        try self.w(subj);
        try self.w(";\n");
        var first = true;
        while (true) {
            self.skipListWs();
            if (self.pos >= self.src.len) return self.fail("unterminated switch", .{});
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            if (self.matchWordAt(self.pos, "else")) {
                self.pos += 4;
                self.skipSpaces();
                try self.emitIndent();
                if (!first) try self.w("else ");
                try self.w("{\n");
                first = false;
                self.indent += 1;
                try self.emitBracedStmts();
                self.indent -= 1;
                try self.emitIndent();
                try self.w("}\n");
                self.skipListWs();
                if (self.pos < self.src.len and self.src[self.pos] == '}') {
                    self.pos += 1;
                    break;
                }
                break;
            }
            var conds: std.ArrayList([]const u8) = .empty;
            while (true) {
                self.skipSpaces();
                const c = try self.emitExprText();
                try conds.append(self.alloc, c);
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                } else break;
            }
            self.skipSpaces();
            try self.emitIndent();
            if (!first) try self.w("else ");
            try self.w("if (");
            for (conds.items, 0..) |c, i| {
                if (i > 0) try self.w(" || ");
                try self.w("c4_eq(");
                try self.w(st);
                try self.w(", ");
                try self.w(c);
                try self.w(")");
            }
            try self.w(") {\n");
            first = false;
            self.indent += 1;
            try self.emitBracedStmts();
            self.indent -= 1;
            try self.emitIndent();
            try self.w("}\n");
        }
        try self.expectEnd();
    }

    const AsmIns = struct { op: []const u8, a: f64, b: f64 };
    const AsmParsed = struct {
        sim: bool,
        code: std.ArrayList(AsmIns),
        labels: std.StringHashMap(usize),
        entry: usize,
        raw_lines: std.ArrayList([]const u8),
    };

    fn asmStem(rel: []const u8) []const u8 {
        var s = rel;
        var i = s.len;
        while (i > 0 and s[i - 1] != '/' and s[i - 1] != '\\') : (i -= 1) {}
        s = s[i..];
        if (std.mem.endsWith(u8, s, ".c4asm")) s = s[0 .. s.len - 6];
        return s;
    }

    fn emitImportAsm(self: *Emitter, rel: []const u8) !void {
        const key = try std.mem.concat(self.alloc, u8, &.{ self.file, "|", rel });
        if (self.imported.contains(key)) return;
        const src = self.base_dir.readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch
            std.Io.Dir.cwd().readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch return self.fail("cannot import '{s}'", .{rel});
        try self.imported.put(key, true);
        var aprog = try self.parseAsmEmit(rel, src);
        var stem_buf: std.ArrayList(u8) = .empty;
        for (asmStem(rel)) |ch| {
            try stem_buf.append(self.alloc, if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_');
        }
        const stem = try stem_buf.toOwnedSlice(self.alloc);
        if (!aprog.sim) {
            const saved_out = self.out;
            self.out = self.fns;
            try self.w("static void c4asm_");
            try self.w(stem);
            try self.w("(void) {\n    __asm__ volatile (\n");
            for (aprog.raw_lines.items, 0..) |ln, i| {
                try self.w("        \"");
                try self.emitAsmLine(ln);
                if (i + 1 < aprog.raw_lines.items.len) try self.w("\\n\"\n") else try self.w("\");\n");
            }
            try self.w("}\n");
            try self.w("static C4Val f_");
            try self.w(stem);
            try self.w("(void) {\n    c4asm_");
            try self.w(stem);
            try self.w("();\n    return c4_num(0);\n}\n");
            self.out = saved_out;
            try self.fns_table.put(try self.alloc.dupe(u8, stem), .{ .params = &.{} });
            return;
        }
        // sim: build {code, labels, entry} dict at runtime; bind <stem>
        const pt = try self.tmp();
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(pt);
        try self.w(" = c4_dict();\n");
        const ct = try self.tmp();
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(ct);
        try self.w(" = c4_list();\n");
        for (aprog.code.items) |ins| {
            const it = try self.tmp();
            try self.emitIndent();
            try self.w("C4Val ");
            try self.w(it);
            try self.w(" = c4_list();\n");
            try self.emitIndent();
            try self.w("c4_list_push(");
            try self.w(it);
            try self.w(", c4_str(\"");
            try self.w(ins.op);
            try self.w("\"));\n");
            try self.emitIndent();
            try self.w("c4_list_push(");
            try self.w(it);
            try self.w(", c4_num(");
            try self.w(try std.fmt.allocPrint(self.alloc, "{d}", .{ins.a}));
            try self.w("));\n");
            try self.emitIndent();
            try self.w("c4_list_push(");
            try self.w(it);
            try self.w(", c4_num(");
            try self.w(try std.fmt.allocPrint(self.alloc, "{d}", .{ins.b}));
            try self.w("));\n");
            try self.emitIndent();
            try self.w("c4_list_push(");
            try self.w(ct);
            try self.w(", ");
            try self.w(it);
            try self.w(");\n");
        }
        const lt = try self.tmp();
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(lt);
        try self.w(" = c4_dict();\n");
        var lit = aprog.labels.iterator();
        while (lit.next()) |e| {
            try self.emitIndent();
            try self.w("c4_dict_put(");
            try self.w(lt);
            try self.w(", \"");
            try self.w(e.key_ptr.*);
            try self.w("\", c4_num(");
            try self.w(try std.fmt.allocPrint(self.alloc, "{d}", .{e.value_ptr.*}));
            try self.w("));\n");
        }
        try self.emitIndent();
        try self.w("c4_dict_put(");
        try self.w(pt);
        try self.w(", \"code\", ");
        try self.w(ct);
        try self.w(");\n");
        try self.emitIndent();
        try self.w("c4_dict_put(");
        try self.w(pt);
        try self.w(", \"labels\", ");
        try self.w(lt);
        try self.w(");\n");
        try self.emitIndent();
        try self.w("c4_dict_put(");
        try self.w(pt);
        try self.w(", \"entry\", c4_num(");
        try self.w(try std.fmt.allocPrint(self.alloc, "{d}", .{aprog.entry}));
        try self.w("));\n");
        try self.emitIndent();
        try self.w("C4Val ");
        try self.w(try cname("v_", stem, self.alloc));
        try self.w(" = ");
        try self.w(pt);
        try self.w(";\n");
    }

    fn emitAsmLine(self: *Emitter, ln: []const u8) !void {
        for (ln) |c| {
            switch (c) {
                '"' => try self.w("\\\""),
                '\\' => try self.w("\\\\"),
                else => try self.out.append(self.alloc, c),
            }
        }
    }

    fn parseAsmEmit(self: *Emitter, file: []const u8, src: []const u8) !AsmParsed {
        var ap = AsmParsed{
            .sim = true,
            .code = .empty,
            .labels = std.StringHashMap(usize).init(self.alloc),
            .entry = 0,
            .raw_lines = .empty,
        };
        var lineno: usize = 0;
        var target: ?bool = null;
        var items: std.ArrayList(struct { line: usize, text: []const u8 }) = .empty;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |rawline| {
            lineno += 1;
            var line = rawline;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (std.mem.indexOfScalar(u8, line, ';')) |si| line = line[0..si];
            var a: usize = 0;
            while (a < line.len and (line[a] == ' ' or line[a] == '\t')) : (a += 1) {}
            var b = line.len;
            while (b > a and (line[b - 1] == ' ' or line[b - 1] == '\t')) : (b -= 1) {}
            line = line[a..b];
            if (line.len == 0) continue;
            if (target == null) {
                if (std.mem.eql(u8, line, "#target sim") or std.mem.eql(u8, line, "#target x86-64")) {
                    target = std.mem.eql(u8, line, "#target sim");
                    continue;
                }
                if (std.mem.startsWith(u8, line, "#")) continue;
                return self.fail("first line must be '#target sim' or '#target x86-64'", .{});
            }
            if (line[0] == '#') continue;
            try items.append(self.alloc, .{ .line = lineno, .text = line });
        }
        if (target == null) return self.fail("missing '#target' line in '{s}'", .{file});
        ap.sim = target.?;
        var entry_name: ?[]const u8 = null;
        var addr: usize = 0;
        var prog: std.ArrayList(struct { line: usize, text: []const u8 }) = .empty;
        for (items.items) |it2| {
            var text = it2.text;
            if (std.mem.indexOfScalar(u8, text, ':')) |ci| {
                const lbl = text[0..ci];
                var ok = lbl.len > 0;
                for (lbl) |ch| {
                    if (!std.ascii.isAlphanumeric(ch) and ch != '_') ok = false;
                }
                if (ok) {
                    if (ap.labels.contains(lbl)) return self.fail("dup label '{s}'", .{lbl});
                    try ap.labels.put(try self.alloc.dupe(u8, lbl), addr);
                    if (!ap.sim) {
                        if (std.mem.eql(u8, lbl, "main")) return self.fail("label 'main' is reserved", .{});
                        try ap.raw_lines.append(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}:", .{lbl}));
                    }
                    text = text[ci + 1 ..];
                    var s2: usize = 0;
                    while (s2 < text.len and (text[s2] == ' ' or text[s2] == '\t')) : (s2 += 1) {}
                    text = text[s2..];
                    if (text.len == 0) continue;
                }
            }
            if (std.mem.eql(u8, text, ".entry")) return self.fail(".entry needs a label", .{});
            if (std.mem.startsWith(u8, text, ".entry ")) {
                var rest = text[".entry ".len..];
                while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) : (rest = rest[1..]) {}
                entry_name = rest;
                continue;
            }
            try prog.append(self.alloc, .{ .line = it2.line, .text = text });
            addr += 1;
            if (!ap.sim) {
                // ban bare ret (wrapper returns for you; early ret crashes MinGW)
                var mw: usize = 0;
                while (mw < text.len and text[mw] != ' ' and text[mw] != '\t') : (mw += 1) {}
                const mnem = text[0..mw];
                if (std.mem.eql(u8, mnem, "ret") or std.mem.eql(u8, mnem, "retq") or std.mem.eql(u8, mnem, "retn")) {
                    return self.fail("ret not allowed in x86-64 .c4asm (wrapper returns)", .{});
                }
                try ap.raw_lines.append(self.alloc, text);
            }
        }
        if (entry_name) |en| {
            ap.entry = ap.labels.get(en) orelse return self.fail("unknown .entry '{s}'", .{en});
        }
        if (!ap.sim) return ap;
        for (prog.items) |pl| {
            var toks: std.ArrayList([]const u8) = .empty;
            var pp: usize = 0;
            const t = pl.text;
            while (pp < t.len) {
                while (pp < t.len and (t[pp] == ' ' or t[pp] == '\t' or t[pp] == ',')) : (pp += 1) {}
                if (pp >= t.len) break;
                const s = pp;
                while (pp < t.len and t[pp] != ' ' and t[pp] != '\t' and t[pp] != ',') : (pp += 1) {}
                try toks.append(self.alloc, t[s..pp]);
            }
            if (toks.items.len == 0) continue;
            const op = toks.items[0];
            const ops = toks.items[1..];
            const expect: usize = if (std.mem.eql(u8, op, "halt") or std.mem.eql(u8, op, "nop")) 0 else if (std.mem.eql(u8, op, "jmp")) 1 else 2;
            if (ops.len != expect) return self.fail("'{s}' needs {d} operands", .{ op, expect });
            var a: f64 = 0;
            var bb: f64 = 0;
            if (std.mem.eql(u8, op, "jmp")) {
                if (ap.labels.get(ops[0])) |ad| {
                    a = @floatFromInt(ad);
                } else {
                    a = @floatFromInt(try self.asmIntEmit(ops[0]));
                }
            } else if (std.mem.eql(u8, op, "jz")) {
                a = @floatFromInt(try self.asmRegEmit(ops[0]));
                if (ap.labels.get(ops[1])) |ad| {
                    bb = @floatFromInt(ad);
                } else {
                    bb = @floatFromInt(try self.asmIntEmit(ops[1]));
                }
            } else if (expect == 2) {
                a = @floatFromInt(try self.asmRegEmit(ops[0]));
                if (std.mem.eql(u8, op, "li") or std.mem.eql(u8, op, "lw") or std.mem.eql(u8, op, "sw")) {
                    bb = @floatFromInt(try self.asmIntEmit(ops[1]));
                } else if (std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "or") or std.mem.eql(u8, op, "xor") or std.mem.eql(u8, op, "shl") or std.mem.eql(u8, op, "shr")) {
                    bb = @floatFromInt(try self.asmRegEmit(ops[1]));
                } else return self.fail("bad sim op '{s}'", .{op});
            } else if (!(std.mem.eql(u8, op, "halt") or std.mem.eql(u8, op, "nop"))) {
                return self.fail("bad sim op '{s}'", .{op});
            }
            try ap.code.append(self.alloc, .{ .op = op, .a = a, .b = bb });
        }
        return ap;
    }

    fn asmIntEmit(self: *Emitter, tok: []const u8) !i64 {
        _ = self;
        if (tok.len == 0) return error.BadNumber;
        var neg = false;
        var t = tok;
        if (t[0] == '-') {
            neg = true;
            t = t[1..];
            if (t.len == 0) return error.BadNumber;
        }
        var v: i64 = 0;
        if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
            if (t.len == 2) return error.BadNumber;
            for (t[2..]) |ch| {
                var d: i64 = -1;
                if (ch >= '0' and ch <= '9') d = ch - '0';
                if (ch >= 'a' and ch <= 'f') d = ch - 'a' + 10;
                if (ch >= 'A' and ch <= 'F') d = ch - 'A' + 10;
                if (d < 0) return error.BadNumber;
                v = v * 16 + d;
            }
        } else {
            for (t) |ch| {
                if (ch < '0' or ch > '9') return error.BadNumber;
                v = v * 10 + (ch - '0');
            }
        }
        if (neg) v = -v;
        return v;
    }

    fn asmRegEmit(self: *Emitter, tok: []const u8) !i64 {
        if (tok.len == 2 and tok[0] == 'r' and tok[1] >= '0' and tok[1] <= '7') {
            return tok[1] - '0';
        }
        return self.fail("bad reg '{s}'", .{tok});
    }


    fn emitImport(self: *Emitter) !void {
        self.skipSpaces();
        if (self.pos < self.src.len and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
            const rel = try self.parseStringBytes();
            try self.expectEnd();
            if (self.fn_depth > 0) return self.fail("import inside function not in emit v1", .{});
            if (std.mem.endsWith(u8, rel, ".c4asm")) {
                try self.emitImportAsm(rel);
                return;
            }
            const key = try std.mem.concat(self.alloc, u8, &.{ self.file, "|", rel });
            if (self.imported.contains(key)) return;
            const src = self.base_dir.readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch
                std.Io.Dir.cwd().readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch return self.fail("cannot import '{s}'", .{rel});
            try self.imported.put(key, true);
            var sub = Emitter{
                .src = src,
                .alloc = self.alloc,
                .out = self.out,
                .pre = self.pre,
                .fns = self.fns,
                .file = rel,
                .base_dir = self.base_dir,
                .io = self.io,
                .imported = self.imported,
                .fns_table = self.fns_table,
                .structs_table = self.structs_table,
                .mods = self.mods,
                .fs = self.fs,
                .tmpc = self.tmpc,
                .indent = self.indent,
                .fn_ids = self.fn_ids,
                .valnames = self.valnames,
            };
            try sub.run();
            self.indent = sub.indent;
            self.tmpc = sub.tmpc;
            return;
        }
        const mod = try self.parseIdent();
        try self.expectEnd();
        if (self.fs) return self.fail("import {s} not in freestanding emit", .{mod});
        if (std.mem.eql(u8, mod, "os") or std.mem.eql(u8, mod, "physics") or std.mem.eql(u8, mod, "time") or std.mem.eql(u8, mod, "cpu") or std.mem.eql(u8, mod, "heap") or std.mem.eql(u8, mod, "json") or std.mem.eql(u8, mod, "hex") or std.mem.eql(u8, mod, "random") or std.mem.eql(u8, mod, "strings") or std.mem.eql(u8, mod, "csv")) {
            try self.mods.put(try self.alloc.dupe(u8, mod), true);
            return;
        }
        if (std.mem.eql(u8, mod, "gui")) {
            return self.fail("'gui' is script-only (Windows GUI); run it with c4c, not --emit-c", .{});
        }
        if (std.mem.eql(u8, mod, "http")) {
            return self.fail("'http' is script-only (network); run it with c4c, not --emit-c", .{});
        }
        if (std.mem.eql(u8, mod, "socket")) {
            return self.fail("'socket' is script-only (network); run it with c4c, not --emit-c", .{});
        }
        if (std.mem.eql(u8, mod, "vgatogui")) {
            return self.fail("'vgatogui' is script-only (VGA emulator window); run it with c4c, not --emit-c", .{});
        }
        if (std.mem.eql(u8, mod, "vga")) {
            return self.fail("'vga' module is script-only (needs vgatogui); kernels use bare vga_* builtins with --emit-c --freestanding", .{});
        }
        if (std.mem.eql(u8, mod, "proc") or std.mem.eql(u8, mod, "os_exec")) {
            return self.fail("process spawn is script-only; run it with c4c, not --emit-c", .{});
        }
        return self.fail("unknown module '{s}' in emit v1 (script-only: gui)", .{mod});
    }

    // ---------- expressions: single pass, return C text ----------
    fn emitExprText(self: *Emitter) anyerror![]const u8 {
        return try self.emitOrText();
    }
    fn emitOrText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitAndText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.matchWordAt(self.pos, "or")) {
                self.pos += 2;
                const r = try self.emitAndText();
                // exact semantics: both sides evaluated
                const t = try self.tmp();
                try self.emitPrelude(try std.fmt.allocPrint(self.alloc, "C4Val {s} = {s};\n", .{ t, l }));
                const t2 = try self.tmp();
                try self.emitPrelude(try std.fmt.allocPrint(self.alloc, "C4Val {s} = {s};\n", .{ t2, r }));
                l = try std.fmt.allocPrint(self.alloc, "(c4_truthy({s}) || c4_truthy({s}) ? c4_num(1) : c4_num(0))", .{ t, t2 });
            } else {
                self.pos = sp;
                break;
            }
        }
        return l;
    }
    fn emitAndText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitNotText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.matchWordAt(self.pos, "and")) {
                self.pos += 3;
                const r = try self.emitNotText();
                const t = try self.tmp();
                try self.emitPrelude(try std.fmt.allocPrint(self.alloc, "C4Val {s} = {s};\n", .{ t, l }));
                const t2 = try self.tmp();
                try self.emitPrelude(try std.fmt.allocPrint(self.alloc, "C4Val {s} = {s};\n", .{ t2, r }));
                l = try std.fmt.allocPrint(self.alloc, "(c4_truthy({s}) && c4_truthy({s}) ? c4_num(1) : c4_num(0))", .{ t, t2 });
            } else {
                self.pos = sp;
                break;
            }
        }
        return l;
    }
    fn emitNotText(self: *Emitter) anyerror![]const u8 {
        const sp = self.pos;
        self.skipSpaces();
        if (self.matchWordAt(self.pos, "not")) {
            self.pos += 3;
            const v = try self.emitNotText();
            return try std.fmt.allocPrint(self.alloc, "(c4_truthy({s}) ? c4_num(0) : c4_num(1))", .{v});
        }
        self.pos = sp;
        return try self.emitCmpText();
    }
    fn emitCmpText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitBitOrText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            var op: u8 = 0;
            var oplen: usize = 0;
            if (self.pos + 1 < self.src.len) {
                if (self.src[self.pos] == '=' and self.src[self.pos + 1] == '=') {
                    op = 1;
                    oplen = 2;
                } else if (self.src[self.pos] == '!' and self.src[self.pos + 1] == '=') {
                    op = 2;
                    oplen = 2;
                } else if (self.src[self.pos] == '<' and self.src[self.pos + 1] == '=') {
                    op = 5;
                    oplen = 2;
                } else if (self.src[self.pos] == '>' and self.src[self.pos + 1] == '=') {
                    op = 6;
                    oplen = 2;
                }
            }
            if (op == 0 and self.pos < self.src.len and (self.src[self.pos] == '<' or self.src[self.pos] == '>')) {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == self.src[self.pos]) {
                    self.pos = sp;
                    break;
                }
                op = if (self.src[self.pos] == '<') 3 else 4;
                oplen = 1;
            }
            if (op == 0) {
                self.pos = sp;
                break;
            }
            self.pos += oplen;
            const r = try self.emitBitOrText();
            l = switch (op) {
                1 => try std.fmt.allocPrint(self.alloc, "(c4_eq({s}, {s}) ? c4_num(1) : c4_num(0))", .{ l, r }),
                2 => try std.fmt.allocPrint(self.alloc, "(!c4_eq({s}, {s}) ? c4_num(1) : c4_num(0))", .{ l, r }),
                3 => try std.fmt.allocPrint(self.alloc, "(c4_lt({s}, {s}) ? c4_num(1) : c4_num(0))", .{ l, r }),
                4 => try std.fmt.allocPrint(self.alloc, "(c4_lt({s}, {s}) ? c4_num(1) : c4_num(0))", .{ r, l }),
                5 => try std.fmt.allocPrint(self.alloc, "(!c4_lt({s}, {s}) ? c4_num(1) : c4_num(0))", .{ r, l }),
                else => try std.fmt.allocPrint(self.alloc, "(!c4_lt({s}, {s}) ? c4_num(1) : c4_num(0))", .{ l, r }),
            };
        }
        return l;
    }
    fn emitBitOrText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitBitXorText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '|') {
                self.pos += 1;
                const r = try self.emitBitXorText();
                l = try std.fmt.allocPrint(self.alloc, "c4_bor({s}, {s})", .{ l, r });
            } else {
                self.pos = sp;
                break;
            }
        }
        return l;
    }
    fn emitBitXorText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitBitAndText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '^') {
                self.pos += 1;
                const r = try self.emitBitAndText();
                l = try std.fmt.allocPrint(self.alloc, "c4_bxor({s}, {s})", .{ l, r });
            } else {
                self.pos = sp;
                break;
            }
        }
        return l;
    }
    fn emitBitAndText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitShiftText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '&') {
                self.pos += 1;
                const r = try self.emitShiftText();
                l = try std.fmt.allocPrint(self.alloc, "c4_band({s}, {s})", .{ l, r });
            } else {
                self.pos = sp;
                break;
            }
        }
        return l;
    }
    fn emitShiftText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitRangeText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            var op: u8 = 0;
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '<' and self.src[self.pos + 1] == '<') {
                op = '<';
            } else if (self.pos + 1 < self.src.len and self.src[self.pos] == '>' and self.src[self.pos + 1] == '>') {
                op = '>';
            }
            if (op == 0) {
                self.pos = sp;
                break;
            }
            self.pos += 2;
            const r = try self.emitRangeText();
            l = if (op == '<') try std.fmt.allocPrint(self.alloc, "c4_shl({s}, {s})", .{ l, r }) else try std.fmt.allocPrint(self.alloc, "c4_shr({s}, {s})", .{ l, r });
        }
        return l;
    }
    fn emitRangeText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitAddText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '.' and self.src[self.pos + 1] == '.') {
                self.pos += 2;
                self.skipSpaces();
                const r = try self.emitAddText();
                l = try std.fmt.allocPrint(self.alloc, "c4_range({s}, {s})", .{ l, r });
            } else {
                self.pos = sp;
                break;
            }
        }
        return l;
    }
    fn emitAddText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitMulText();
        while (true) {
            self.skipSpaces();
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                const op = self.src[self.pos];
                self.pos += 1;
                const r = try self.emitMulText();
                l = if (op == '+') try std.fmt.allocPrint(self.alloc, "c4_add({s}, {s})", .{ l, r }) else try std.fmt.allocPrint(self.alloc, "c4_sub({s}, {s})", .{ l, r });
            } else break;
        }
        return l;
    }
    fn emitMulText(self: *Emitter) anyerror![]const u8 {
        var l = try self.emitFactorText();
        while (true) {
            self.skipSpaces();
            if (self.pos < self.src.len and (self.src[self.pos] == '*' or self.src[self.pos] == '/' or self.src[self.pos] == '%')) {
                const op = self.src[self.pos];
                self.pos += 1;
                const r = try self.emitFactorText();
                l = switch (op) {
                    '*' => try std.fmt.allocPrint(self.alloc, "c4_mul({s}, {s})", .{ l, r }),
                    '/' => try std.fmt.allocPrint(self.alloc, "c4_div({s}, {s})", .{ l, r }),
                    else => try std.fmt.allocPrint(self.alloc, "c4_mod({s}, {s})", .{ l, r }),
                };
            } else break;
        }
        return l;
    }
    fn emitFactorText(self: *Emitter) anyerror![]const u8 {
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == '~') {
            self.pos += 1;
            const v = try self.emitFactorText();
            return try std.fmt.allocPrint(self.alloc, "c4_bnot({s})", .{v});
        }
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            var tp = self.pos + 1;
            while (tp < self.src.len and (self.src[tp] == ' ' or self.src[tp] == '\t')) : (tp += 1) {}
            if (tp < self.src.len and (std.ascii.isDigit(self.src[tp]) or self.src[tp] == '.')) {
                const t = try self.parseNumberText();
                return try std.fmt.allocPrint(self.alloc, "c4_num(-{s})", .{t[1..]});
            }
            if (tp < self.src.len and self.src[tp] == '(') {
                self.pos += 1;
                const v = try self.emitFactorText();
                return try std.fmt.allocPrint(self.alloc, "(c4_sub(c4_num(0), {s}))", .{v});
            }
        }
        var base = try self.emitPrimaryText();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '[') {
                self.pos += 1;
                const ix = try self.emitExprText();
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != ']') return self.fail("expected ']'", .{});
                self.pos += 1;
                base = try std.fmt.allocPrint(self.alloc, "c4_index({s}, {s})", .{ base, ix });
            } else if (self.pos < self.src.len and self.src[self.pos] == '.' and self.pos + 1 < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos + 1]) or self.src[self.pos + 1] == '_')) {
                self.pos += 1;
                const f = try self.parseIdent();
                base = try std.fmt.allocPrint(self.alloc, "c4_field({s}, \"{s}\")", .{ base, f });
            } else if (self.pos < self.src.len and self.src[self.pos] == '(') {
                self.pos += 1;
                var call_args: std.ArrayList([]const u8) = .empty;
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                } else {
                    while (true) {
                        const a = try self.emitExprText();
                        try call_args.append(self.alloc, a);
                        self.skipSpaces();
                        if (self.pos < self.src.len and self.src[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                            self.pos += 1;
                            break;
                        } else return self.fail("expected ')'", .{});
                    }
                }
                if (call_args.items.len > 8) return self.fail("calling a function value takes max 8 args in emit", .{});
                var cb: std.ArrayList(u8) = .empty;
                const ch = try std.fmt.allocPrint(self.alloc, "c4_call{d}({s}", .{ call_args.items.len, base });
                try cb.appendSlice(self.alloc, ch);
                for (call_args.items) |a| {
                    try cb.appendSlice(self.alloc, ", ");
                    try cb.appendSlice(self.alloc, a);
                }
                try cb.append(self.alloc, ')');
                base = try cb.toOwnedSlice(self.alloc);
            } else {
                self.pos = sp;
                break;
            }
        }
        return base;
    }
    fn emitPrimaryText(self: *Emitter) anyerror![]const u8 {
        self.skipSpaces();
        if (self.pos >= self.src.len) return self.fail("unexpected end of expression", .{});
        const c = self.src[self.pos];
        if (c == '(') {
            self.pos += 1;
            const v = try self.emitExprText();
            self.skipSpaces();
            if (self.pos >= self.src.len or self.src[self.pos] != ')') return self.fail("expected ')'", .{});
            self.pos += 1;
            return try std.fmt.allocPrint(self.alloc, "({s})", .{v});
        }
        if (c == '[') {
            return try self.emitListText();
        }
        if (c == '{') {
            return try self.emitDictText();
        }
        if (c == '"' or c == '\'') {
            const raw = try self.parseStringBytes();
            var buf: std.ArrayList(u8) = .empty;
            try emitCLitBuf(self.alloc, raw, &buf);
            return try std.fmt.allocPrint(self.alloc, "c4_str({s})", .{buf.items});
        }
        if (c == '-' or std.ascii.isDigit(c) or c == '.') {
            const t = try self.parseNumberText();
            if (t[0] == '-') return self.fail("bad number", .{});
            return try std.fmt.allocPrint(self.alloc, "c4_num({s})", .{t});
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            return try self.emitCallOrVarText();
        }
        return self.fail("unexpected character in expression", .{});
    }

    fn emitCallOrVarText(self: *Emitter) ![]const u8 {
        const name = try self.parseIdent();
        if (std.mem.eql(u8, name, "true")) return try self.alloc.dupe(u8, "c4_num(1)");
        if (std.mem.eql(u8, name, "false")) return try self.alloc.dupe(u8, "c4_num(0)");
        if (std.mem.eql(u8, name, "nil")) return try self.alloc.dupe(u8, "c4_nil()");
        const after = self.pos;
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            self.skipSpaces();
            if (self.pos < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos]) or self.src[self.pos] == '_')) {
                const ms = self.pos;
                while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
                const method = self.src[ms..self.pos];
                var tp = self.pos;
                while (tp < self.src.len and (self.src[tp] == ' ' or self.src[tp] == '\t')) : (tp += 1) {}
                if (tp < self.src.len and self.src[tp] == '(') {
                    self.pos = tp;
                    return try self.emitModuleCallText(name, method);
                }
            }
            self.pos = after;
            return try cname("v_", name, self.alloc);
        }
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            return try self.emitPlainCallText(name);
        }
        self.pos = after;
        if (self.fns_table.get(name)) |_| {
            if (self.fn_ids.get(name)) |id| {
                var eb: [32]u8 = undefined;
                const lit = std.fmt.bufPrint(&eb, "\"{s}\"", .{name}) catch "\"?\"";
                return try std.fmt.allocPrint(self.alloc, "c4_fnval({s}, {d})", .{ lit, id });
            }
            return self.fail("function references ('{s}') are interpreter-only in emit v1 — use a direct call", .{name});
        }
        if (std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "fname")) {
            return self.fail("'{s}()' is interpreter-only in emit v1", .{name});
        }
        return try cname("v_", name, self.alloc);
    }

    fn emitPlainCallText(self: *Emitter, name: []const u8) ![]const u8 {
        self.pos += 1;
        var args: std.ArrayList([]const u8) = .empty;
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == ')') {
            self.pos += 1;
        } else {
            while (true) {
                const a = try self.emitExprText();
                try args.append(self.alloc, a);
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                    break;
                } else return self.fail("expected ')'", .{});
            }
        }
        return try self.emitCallText(name, args.items);
    }

    // shared by statements and expressions
    fn emitCallExpr(self: *Emitter) !void {
        const t = try self.emitCallOrVarText();
        try self.w(t);
    }

    fn emitCallText(self: *Emitter, name: []const u8, args: []const []const u8) ![]const u8 {
        if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "pt")) return self.fail("print is a statement", .{});
        if (std.mem.eql(u8, name, "exit")) return self.fail("exit() is a statement in emit v1", .{});
        if (std.mem.eql(u8, name, "fail")) {
            if (args.len != 1) return self.fail("fail(msg) takes 1 arg", .{});
            return try std.fmt.allocPrint(self.alloc, "c4_fail(c4_tostring({s}))", .{args[0]});
        }
        if (std.mem.eql(u8, name, "call")) {
            if (self.fs) return self.fail("'call' not in freestanding emit", .{});
            if (args.len < 1) return self.fail("call(f, ...) needs a function", .{});
            if (args.len - 1 > 8) return self.fail("call() max 8 args in emit", .{});
            var buf: std.ArrayList(u8) = .empty;
            const h = try std.fmt.allocPrint(self.alloc, "c4_call{d}({s}", .{ args.len - 1, args[0] });
            try buf.appendSlice(self.alloc, h);
            for (args[1..]) |a| {
                try buf.appendSlice(self.alloc, ", ");
                try buf.appendSlice(self.alloc, a);
            }
            try buf.append(self.alloc, ')');
            return try buf.toOwnedSlice(self.alloc);
        }
        if (std.mem.eql(u8, name, "fname")) {
            if (self.fs) return self.fail("'fname' not in freestanding emit", .{});
            if (args.len != 1) return self.fail("fname(f) takes 1 arg", .{});
            return try std.fmt.allocPrint(self.alloc, "c4_fname({s})", .{args[0]});
        }
        if (self.fs) {
            const nofs = [_][]const u8{ "pow", "log", "log10", "exp", "sin", "cos", "tan", "asin", "acos", "atan", "input", "args" };
            for (nofs) |b| {
                if (std.mem.eql(u8, name, b)) return self.fail("'{s}' not in freestanding emit", .{name});
            }
            if (std.mem.eql(u8, name, "outb")) {
                if (args.len != 2) return self.fail("outb(port, val) takes 2 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_outb({s}, {s})", .{ args[0], args[1] });
            }
            if (std.mem.eql(u8, name, "inb")) {
                if (args.len != 1) return self.fail("inb(port) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_inb({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "inw")) {
                if (args.len != 1) return self.fail("inw(port) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_inw({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "sti") or std.mem.eql(u8, name, "cli")) {
                if (args.len != 0) return self.fail("'{s}' takes no args", .{name});
                return try std.fmt.allocPrint(self.alloc, "c4_{s}()", .{name});
            }
            if (std.mem.eql(u8, name, "ticks") or std.mem.eql(u8, name, "irq_addr")) {
                if (args.len != 0) return self.fail("'{s}' takes no args", .{name});
                if (std.mem.eql(u8, name, "irq_addr")) return try self.alloc.dupe(u8, "c4_irq0_addr()");
                return try std.fmt.allocPrint(self.alloc, "c4_{s}()", .{name});
            }
            if (std.mem.eql(u8, name, "key") or std.mem.eql(u8, name, "irq1_addr")) {
                if (args.len != 0) return self.fail("'{s}' takes no args", .{name});
                if (std.mem.eql(u8, name, "irq1_addr")) return try self.alloc.dupe(u8, "c4_irq1_addr()");
                return try self.alloc.dupe(u8, "c4_key()");
            }
            if (std.mem.eql(u8, name, "idt_set")) {
                if (args.len != 4) return self.fail("idt_set(vec, off, sel, attr) takes 4 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_idt_set({s}, {s}, {s}, {s})", .{ args[0], args[1], args[2], args[3] });
            }
            if (std.mem.eql(u8, name, "idt_load")) {
                if (args.len != 0) return self.fail("'idt_load' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_idt_load()");
            }
            if (std.mem.eql(u8, name, "poke32")) {
                if (args.len != 2) return self.fail("poke32(addr, val) takes 2 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_poke32({s}, {s})", .{ args[0], args[1] });
            }
            if (std.mem.eql(u8, name, "peek32")) {
                if (args.len != 1) return self.fail("peek32(addr) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_peek32({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "vga_clear")) {
                if (args.len != 1) return self.fail("vga_clear(attr) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_vga_clear({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "vga_put")) {
                if (args.len != 4) return self.fail("vga_put(r, c, ch, attr) takes 4 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_vga_put({s}, {s}, {s}, {s})", .{ args[0], args[1], args[2], args[3] });
            }
            if (std.mem.eql(u8, name, "vga_get")) {
                if (args.len != 2) return self.fail("vga_get(r, c) takes 2 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_vga_get({s}, {s})", .{ args[0], args[1] });
            }
            if (std.mem.eql(u8, name, "vga_text")) {
                if (args.len != 4) return self.fail("vga_text(r, c, s, attr) takes 4 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_vga_text({s}, {s}, {s}, {s})", .{ args[0], args[1], args[2], args[3] });
            }
            if (std.mem.eql(u8, name, "vga_scroll")) {
                if (args.len != 0) return self.fail("'vga_scroll' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_vga_scroll()");
            }
            if (std.mem.eql(u8, name, "vga_move")) {
                if (args.len != 2) return self.fail("vga_move(r, c) takes 2 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_vga_move({s}, {s})", .{ args[0], args[1] });
            }
            if (std.mem.eql(u8, name, "vga_size")) {
                if (args.len != 0) return self.fail("'vga_size' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_vga_size()");
            }
            if (std.mem.eql(u8, name, "cr3")) {
                if (args.len != 1) return self.fail("cr3(addr) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_cr3({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "pg_on")) {
                if (args.len != 0) return self.fail("'pg_on' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_pg_on()");
            }
            if (std.mem.eql(u8, name, "kmalloc")) {
                if (args.len != 1) return self.fail("kmalloc(n) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_kmalloc({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "kfree")) {
                if (args.len != 1) return self.fail("kfree(addr) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_kfree({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "syscall")) {
                if (args.len != 4) return self.fail("syscall(num, a, b, c) takes 4 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_syscall({s}, {s}, {s}, {s})", .{ args[0], args[1], args[2], args[3] });
            }
            if (std.mem.eql(u8, name, "syscall_addr")) {
                if (args.len != 0) return self.fail("'syscall_addr' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_syscall_addr()");
            }
            if (std.mem.eql(u8, name, "addr")) {
                if (args.len != 1) return self.fail("addr(x) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_addr({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "gdt_set")) {
                if (args.len != 5) return self.fail("gdt_set(idx, base, limit, access, gran) takes 5 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_gdt_set({s}, {s}, {s}, {s}, {s})", .{ args[0], args[1], args[2], args[3], args[4] });
            }
            if (std.mem.eql(u8, name, "gdt_load")) {
                if (args.len != 0) return self.fail("'gdt_load' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_gdt_load()");
            }
            if (std.mem.eql(u8, name, "tss")) {
                if (args.len != 1) return self.fail("tss(esp0) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_tss_init({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "enter_user")) {
                if (args.len != 2) return self.fail("enter_user(entry, esp) takes 2 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_enter_user({s}, {s})", .{ args[0], args[1] });
            }
            if (std.mem.eql(u8, name, "elf_load")) {
                if (args.len != 1) return self.fail("elf_load(base) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_elf_load({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "user_base")) {
                if (args.len != 0) return self.fail("'user_base' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_user_base()");
            }
            if (std.mem.eql(u8, name, "user_len")) {
                if (args.len != 0) return self.fail("'user_len' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_user_len()");
            }
            if (std.mem.eql(u8, name, "user2_base")) {
                if (args.len != 0) return self.fail("'user2_base' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_user2_base()");
            }
            if (std.mem.eql(u8, name, "user2_len")) {
                if (args.len != 0) return self.fail("'user2_len' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_user2_len()");
            }
            if (std.mem.eql(u8, name, "fault_addr")) {
                if (args.len != 1) return self.fail("fault_addr(vec) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_fault_addr({s})", .{args[0]});
            }
            if (std.mem.eql(u8, name, "task_create")) {
                if (args.len != 2) return self.fail("task_create(entry, esp) takes 2 args", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_task_create({s}, {s})", .{ args[0], args[1] });
            }
            if (std.mem.eql(u8, name, "tasks")) {
                if (args.len != 0) return self.fail("'tasks' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_tasks()");
            }
            if (std.mem.eql(u8, name, "idle")) {
                if (args.len != 0) return self.fail("'idle' takes no args", .{});
                return try self.alloc.dupe(u8, "c4_idle()");
            }
            if (std.mem.eql(u8, name, "flat")) {
                if (args.len != 1) return self.fail("flat(list) takes 1 arg", .{});
                return try std.fmt.allocPrint(self.alloc, "c4_flat({s})", .{args[0]});
            }
        } else {
            const fsonly = [_][]const u8{ "outb", "inb", "inw", "sti", "cli", "ticks", "irq_addr", "idt_set", "idt_load", "key", "irq1_addr", "poke32", "peek32", "vga_clear", "vga_put", "vga_get", "vga_text", "vga_scroll", "vga_move", "vga_size", "cr3", "pg_on", "kmalloc", "kfree", "syscall", "syscall_addr", "addr", "gdt_set", "gdt_load", "tss", "enter_user", "elf_load", "user_base", "user_len", "user2_base", "user2_len", "fault_addr", "task_create", "tasks", "idle", "flat" };
            for (fsonly) |b| {
                if (std.mem.eql(u8, name, b)) return self.fail("'{s}' is freestanding-only (kernel code via --emit-c --freestanding)", .{name});
            }
        }
        const plain = [_][]const u8{ "len", "push", "type", "str", "int", "split", "join", "substr", "trim", "upper", "lower", "replace", "contains", "abs", "min", "max", "sqrt", "floor", "ceil", "round", "pow", "bits", "setbits", "flag", "bytes", "peek", "poke", "pack", "unpack", "sizeof", "u8", "u16", "u32", "i8", "i16", "i32", "keys", "del", "input", "args", "ord", "chr", "sin", "cos", "tan", "asin", "acos", "atan", "log", "log10", "exp", "deg", "rad", "pi", "e", "crc32", "sort", "reverse", "sum", "min_of", "max_of", "count", "any", "all", "unique" };
        const renamed = [_][2][]const u8{ .{ "index_of", "indexof" } };
        for (renamed) |pair| {
            if (std.mem.eql(u8, name, pair[0])) {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(self.alloc, "c4_");
                try buf.appendSlice(self.alloc, pair[1]);
                try buf.append(self.alloc, '(');
                for (args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    try buf.appendSlice(self.alloc, a);
                }
                try buf.append(self.alloc, ')');
                return try buf.toOwnedSlice(self.alloc);
            }
        }
        for (plain) |b| {
            if (std.mem.eql(u8, name, b)) {
                if (std.mem.eql(u8, name, "input")) {
                    if (args.len == 0) return try self.alloc.dupe(u8, "c4_input(c4_nil(), 0)");
                    if (args.len == 1) return try std.fmt.allocPrint(self.alloc, "c4_input({s}, 1)", .{args[0]});
                    return self.fail("input() takes 0-1 args", .{});
                }
                if (std.mem.eql(u8, name, "args")) {
                    if (args.len != 0) return self.fail("args() takes no args", .{});
                    return try self.alloc.dupe(u8, "c4_args()");
                }
                var buf: std.ArrayList(u8) = .empty;
                if (std.mem.eql(u8, name, "str")) {
                    try buf.appendSlice(self.alloc, "c4_str_b(");
                } else {
                    try buf.appendSlice(self.alloc, "c4_");
                    try buf.appendSlice(self.alloc, name);
                    try buf.append(self.alloc, '(');
                }
                for (args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    try buf.appendSlice(self.alloc, a);
                }
                try buf.append(self.alloc, ')');
                return try buf.toOwnedSlice(self.alloc);
            }
        }
        if (self.structs_table.get(name)) |info| {
            if (args.len != info.fields.len) return self.fail("struct '{s}' needs {d} args", .{ name, info.fields.len });
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(self.alloc, "c4_struct(\"");
            try buf.appendSlice(self.alloc, name);
            try buf.appendSlice(self.alloc, "\", st_");
            try buf.appendSlice(self.alloc, name);
            try buf.appendSlice(self.alloc, ", (C4Val[]){");
            for (args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(self.alloc, ", ");
                try buf.appendSlice(self.alloc, a);
            }
            const tail = try std.fmt.allocPrint(self.alloc, "}}, {d})", .{args.len});
            try buf.appendSlice(self.alloc, tail);
            return try buf.toOwnedSlice(self.alloc);
        }
        if (self.fns_table.get(name)) |fi| {
            if (args.len != fi.params.len) return self.fail("'{s}' expects {d} args", .{ name, fi.params.len });
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(self.alloc, "f_");
            try buf.appendSlice(self.alloc, name);
            try buf.append(self.alloc, '(');
            for (args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(self.alloc, ", ");
                try buf.appendSlice(self.alloc, a);
            }
            try buf.append(self.alloc, ')');
            return try buf.toOwnedSlice(self.alloc);
        }
        if (self.valnames.get(name) != null) {
            if (args.len > 8) return self.fail("calling a function value takes max 8 args in emit", .{});
            var buf: std.ArrayList(u8) = .empty;
            const h = try std.fmt.allocPrint(self.alloc, "c4_call{d}({s}", .{ args.len, try cname("v_", name, self.alloc) });
            try buf.appendSlice(self.alloc, h);
            for (args) |a| {
                try buf.appendSlice(self.alloc, ", ");
                try buf.appendSlice(self.alloc, a);
            }
            try buf.append(self.alloc, ')');
            return try buf.toOwnedSlice(self.alloc);
        }
        return self.fail("unknown function '{s}'", .{name});
    }

    fn emitModuleCallText(self: *Emitter, module: []const u8, method: []const u8) ![]const u8 {
        self.pos += 1;
        var args: std.ArrayList([]const u8) = .empty;
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == ')') {
            self.pos += 1;
        } else {
            while (true) {
                const a = try self.emitExprText();
                try args.append(self.alloc, a);
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                    break;
                } else return self.fail("expected ')'", .{});
            }
        }
        return try self.emitModuleCall(module, method, args.items);
    }

    fn emitModuleCall(self: *Emitter, module: []const u8, method: []const u8, args: []const []const u8) ![]const u8 {
        if (self.fs) {
            return self.fail("import {s} not in freestanding emit", .{module});
        }
        const known_os = [_][]const u8{ "create", "read", "append", "exists", "remove", "edit", "readbytes", "writebytes", "cwd", "env", "listdir", "mkdir" };
        const known_ph = [_][]const u8{ "g", "fall", "range", "height", "dist", "speed", "energy" };
        const known_tm = [_][]const u8{ "now", "stamp", "sleep", "ms", "epoch_ms", "clock" };
        const known_json = [_][]const u8{ "parse", "stringify" };
        const known_hex = [_][]const u8{ "encode", "decode", "dump", "word", "parse" };
        const known_strings = [_][]const u8{ "starts_with", "ends_with", "find", "pad_left", "pad_right", "repeat", "replace_all", "lines" };
        var cfn: ?[]const u8 = null;
        if (std.mem.eql(u8, module, "os")) {
            if (!self.mods.contains("os")) return self.fail("'os' used without 'import os'", .{});
            for (known_os) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_os_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown os.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "physics")) {
            if (!self.mods.contains("physics")) return self.fail("'physics' used without import", .{});
            for (known_ph) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_ph_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown physics.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "time")) {
            if (!self.mods.contains("time")) return self.fail("time used without import", .{});
            for (known_tm) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_tm_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown time.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "heap")) {
            if (!self.mods.contains("heap")) return self.fail("'heap' used without 'import heap'", .{});
            const known_heap = [_][]const u8{ "new", "malloc", "calloc", "realloc", "free", "stats", "dump" };
            for (known_heap) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_heap_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown heap.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "json")) {
            if (!self.mods.contains("json")) return self.fail("'json' used without 'import json'", .{});
            for (known_json) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_json_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown json.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "hex")) {
            if (!self.mods.contains("hex")) return self.fail("'hex' used without 'import hex'", .{});
            for (known_hex) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_hex_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown hex.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "random")) {
            if (!self.mods.contains("random")) return self.fail("'random' used without 'import random'", .{});
            if (std.mem.eql(u8, method, "seed")) {
                if (args.len == 0) {
                    cfn = try self.alloc.dupe(u8, "c4_random_seed(c4_nil())");
                } else if (args.len == 1) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_random_seed({s})", .{args[0]});
                } else {
                    return self.fail("random.seed takes 0-1 args", .{});
                }
                return cfn.?;
            }
            if (std.mem.eql(u8, method, "int")) {
                if (args.len == 1) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_random_int({s})", .{args[0]});
                } else if (args.len == 2) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_random_int2({s}, {s})", .{ args[0], args[1] });
                } else {
                    return self.fail("random.int takes 1-2 args", .{});
                }
                return cfn.?;
            }
            if (std.mem.eql(u8, method, "float")) {
                if (args.len == 0) {
                    cfn = try self.alloc.dupe(u8, "c4_random_float()");
                } else if (args.len == 2) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_random_float2({s}, {s})", .{ args[0], args[1] });
                } else {
                    return self.fail("random.float takes 0 or 2 args", .{});
                }
                return cfn.?;
            }
            if (std.mem.eql(u8, method, "pick") or std.mem.eql(u8, method, "shuffle") or std.mem.eql(u8, method, "chance")) {
                if (args.len != 1) return self.fail("random.{s} takes 1 arg", .{method});
                cfn = try std.fmt.allocPrint(self.alloc, "c4_random_{s}({s})", .{ method, args[0] });
                return cfn.?;
            }
            return self.fail("unknown random.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "strings")) {
            if (!self.mods.contains("strings")) return self.fail("'strings' used without 'import strings'", .{});
            if (std.mem.eql(u8, method, "pad_left") or std.mem.eql(u8, method, "pad_right")) {
                if (args.len == 2) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_strings_{s}({s}, {s}, c4_nil())", .{ method, args[0], args[1] });
                } else if (args.len == 3) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_strings_{s}({s}, {s}, {s})", .{ method, args[0], args[1], args[2] });
                } else {
                    return self.fail("strings.{s} takes 2-3 args", .{method});
                }
                return cfn.?;
            }
            for (known_strings) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_strings_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown strings.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "csv")) {
            if (!self.mods.contains("csv")) return self.fail("'csv' used without 'import csv'", .{});
            if (std.mem.eql(u8, method, "parse")) {
                if (args.len == 1) {
                    return try std.fmt.allocPrint(self.alloc, "c4_csv_parse({s}, c4_str(\",\"))", .{args[0]});
                } else if (args.len == 2) {
                    return try std.fmt.allocPrint(self.alloc, "c4_csv_parse({s}, {s})", .{ args[0], args[1] });
                }
                return self.fail("csv.parse takes 1-2 args", .{});
            }
            if (std.mem.eql(u8, method, "stringify")) {
                if (args.len == 1) {
                    return try std.fmt.allocPrint(self.alloc, "c4_csv_stringify({s}, c4_str(\",\"))", .{args[0]});
                } else if (args.len == 2) {
                    return try std.fmt.allocPrint(self.alloc, "c4_csv_stringify({s}, {s})", .{ args[0], args[1] });
                }
                return self.fail("csv.stringify takes 1-2 args", .{});
            }
            return self.fail("unknown csv.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "cpu")) {
            if (!self.mods.contains("cpu")) return self.fail("'cpu' used without 'import cpu'", .{});
            const known_cpu = [_][]const u8{ "new", "reg", "setreg", "load", "store", "step", "run" };
            for (known_cpu) |k| {
                if (std.mem.eql(u8, method, k)) {
                    cfn = try std.fmt.allocPrint(self.alloc, "c4_cpu_{s}", .{method});
                    break;
                }
            }
            if (cfn == null) return self.fail("unknown cpu.{s} in emit v1", .{method});
        } else if (std.mem.eql(u8, module, "http")) {
            return self.fail("'http' is script-only (network); run it with c4c, not --emit-c", .{});
        } else if (std.mem.eql(u8, module, "socket")) {
            return self.fail("'socket' is script-only (network); run it with c4c, not --emit-c", .{});
        } else if (std.mem.eql(u8, module, "vgatogui")) {
            return self.fail("'vgatogui' is script-only (VGA emulator window); run it with c4c, not --emit-c", .{});
        } else if (std.mem.eql(u8, module, "vga")) {
            return self.fail("'vga' module is script-only (needs vgatogui); kernels use bare vga_* builtins with --emit-c --freestanding", .{});
        } else {
            return self.fail("unknown module '{s}'", .{module});
        }
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.alloc, cfn.?);
        try buf.append(self.alloc, '(');
        for (args, 0..) |a, i| {
            if (i > 0) try buf.appendSlice(self.alloc, ", ");
            try buf.appendSlice(self.alloc, a);
        }
        try buf.append(self.alloc, ')');
        return try buf.toOwnedSlice(self.alloc);
    }

    fn emitListText(self: *Emitter) ![]const u8 {
        self.pos += 1;
        var items: std.ArrayList([]const u8) = .empty;
        self.skipListWs();
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
        } else {
            while (true) {
                const it = try self.emitExprText();
                try items.append(self.alloc, it);
                self.skipListWs();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                } else if (self.pos < self.src.len and self.src[self.pos] == ']') {
                    self.pos += 1;
                    break;
                } else return self.fail("expected ',' or ']' in list", .{});
            }
        }
        const t = try self.tmp();
        var pre: std.ArrayList(u8) = .empty;
        try pre.appendSlice(self.alloc, "C4Val ");
        try pre.appendSlice(self.alloc, t);
        try pre.appendSlice(self.alloc, " = c4_list(); ");
        for (items.items) |it| {
            try pre.appendSlice(self.alloc, "c4_list_push(");
            try pre.appendSlice(self.alloc, t);
            try pre.appendSlice(self.alloc, ", ");
            try pre.appendSlice(self.alloc, it);
            try pre.appendSlice(self.alloc, "); ");
        }
        try self.emitPrelude(pre.items);
        return t;
    }

    fn emitDictText(self: *Emitter) ![]const u8 {
        self.pos += 1;
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList([]const u8) = .empty;
        self.skipListWs();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
        } else {
            while (true) {
                self.skipListWs();
                var key: []const u8 = undefined;
                if (self.pos < self.src.len and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
                    const raw = try self.parseStringBytes();
                    var cb: std.ArrayList(u8) = .empty;
                    try emitCLitBuf(self.alloc, raw, &cb);
                    key = try cb.toOwnedSlice(self.alloc);
                } else if (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '-')) {
                    const nt = try self.parseNumberText();
                    key = try std.fmt.allocPrint(self.alloc, "\"{s}\"", .{nt});
                } else {
                    const id = try self.parseIdent();
                    key = try std.fmt.allocPrint(self.alloc, "\"{s}\"", .{id});
                }
                self.skipListWs();
                if (self.pos >= self.src.len or self.src[self.pos] != ':') return self.fail("expected ':' in dict", .{});
                self.pos += 1;
                const vv = try self.emitExprText();
                try keys.append(self.alloc, key);
                try vals.append(self.alloc, vv);
                self.skipListWs();
                if (self.pos < self.src.len and self.src[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                } else if (self.pos < self.src.len and self.src[self.pos] == '}') {
                    self.pos += 1;
                    break;
                } else return self.fail("expected ',' or '}}' in dict", .{});
            }
        }
        const t = try self.tmp();
        var pre: std.ArrayList(u8) = .empty;
        try pre.appendSlice(self.alloc, "C4Val ");
        try pre.appendSlice(self.alloc, t);
        try pre.appendSlice(self.alloc, " = c4_dict(); ");
        for (keys.items, 0..) |k, i| {
            try pre.appendSlice(self.alloc, "c4_dict_put(");
            try pre.appendSlice(self.alloc, t);
            try pre.appendSlice(self.alloc, ", ");
            try pre.appendSlice(self.alloc, k);
            try pre.appendSlice(self.alloc, ", ");
            try pre.appendSlice(self.alloc, vals.items[i]);
            try pre.appendSlice(self.alloc, "); ");
        }
        try self.emitPrelude(pre.items);
        return t;
    }
};

// ---------- driver ----------
pub fn prescan(
    alloc: std.mem.Allocator,
    io: Io,
    src: []const u8,
    file: []const u8,
    base_dir: std.Io.Dir,
    fns: *std.StringHashMap(FnInfo),
    structs: *std.StringHashMap(StructInfo),
    visited: *std.StringHashMap(bool),
) !void {
    const key = try std.mem.concat(alloc, u8, &.{ file, "|prescan" });
    if (visited.contains(key)) return;
    try visited.put(key, true);
    var pos: usize = 0;
    var depth: usize = 0;
    var in_str: u8 = 0;
    const n = src.len;
    while (pos < n) {
        const c = src[pos];
        if (in_str != 0) {
            if (c == '\\') {
                pos += 2;
                continue;
            }
            if (c == in_str) in_str = 0;
            pos += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            pos += 1;
            continue;
        }
        if (c == '#') {
            while (pos < n and src[pos] != '\n') : (pos += 1) {}
            continue;
        }
        if (c == '/' and pos + 1 < n and src[pos + 1] == '/') {
            while (pos < n and src[pos] != '\n') : (pos += 1) {}
            continue;
        }
        if (c == '{') {
            depth += 1;
            pos += 1;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            pos += 1;
            continue;
        }
        if (depth == 0 and (std.ascii.isAlphabetic(c) or c == '_')) {
            const word_is_fn = std.mem.startsWith(u8, src[pos..], "fn") and (pos + 2 >= n or (!std.ascii.isAlphanumeric(src[pos + 2]) and src[pos + 2] != '_'));
            const word_is_struct = std.mem.startsWith(u8, src[pos..], "struct") and (pos + 6 >= n or (!std.ascii.isAlphanumeric(src[pos + 6]) and src[pos + 6] != '_'));
            const word_is_import = std.mem.startsWith(u8, src[pos..], "import") and (pos + 6 >= n or (!std.ascii.isAlphanumeric(src[pos + 6]) and src[pos + 6] != '_'));
            if (word_is_fn or word_is_struct) {
                const is_fn = word_is_fn;
                pos += if (is_fn) @as(usize, 2) else @as(usize, 6);
                while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
                const ns = pos;
                while (pos < n and (std.ascii.isAlphanumeric(src[pos]) or src[pos] == '_')) : (pos += 1) {}
                if (ns == pos) continue;
                const name = src[ns..pos];
                while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
                if (is_fn) {
                    if (pos >= n or src[pos] != '(') continue;
                    pos += 1;
                    var params: std.ArrayList([]const u8) = .empty;
                    while (true) {
                        while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
                        if (pos < n and src[pos] == ')') {
                            pos += 1;
                            break;
                        }
                        const ps = pos;
                        while (pos < n and (std.ascii.isAlphanumeric(src[pos]) or src[pos] == '_')) : (pos += 1) {}
                        if (ps == pos) break;
                        params.append(alloc, src[ps..pos]) catch break;
                        while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
                        if (pos < n and src[pos] == ',') {
                            pos += 1;
                            continue;
                        }
                        if (pos < n and src[pos] == ')') {
                            pos += 1;
                            break;
                        }
                        break;
                    }
                    const owned = params.toOwnedSlice(alloc) catch continue;
                    fns.put(alloc.dupe(u8, name) catch continue, .{ .params = owned }) catch {};
                } else {
                    if (pos >= n or src[pos] != '{') continue;
                    pos += 1;
                    var fields: std.ArrayList([]const u8) = .empty;
                    while (true) {
                        while (pos < n and (src[pos] == ' ' or src[pos] == '\t' or src[pos] == '\r' or src[pos] == '\n')) : (pos += 1) {}
                        if (pos < n and src[pos] == '}') {
                            pos += 1;
                            break;
                        }
                        const fs = pos;
                        while (pos < n and (std.ascii.isAlphanumeric(src[pos]) or src[pos] == '_')) : (pos += 1) {}
                        if (fs == pos) break;
                        fields.append(alloc, src[fs..pos]) catch break;
                        while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
                        if (pos < n and src[pos] == ',') {
                            pos += 1;
                            continue;
                        }
                        if (pos < n and (src[pos] == '\n' or src[pos] == '\r' or src[pos] == '}')) {
                            continue;
                        }
                        break;
                    }
                    const owned = fields.toOwnedSlice(alloc) catch continue;
                    structs.put(alloc.dupe(u8, name) catch continue, .{ .fields = owned }) catch {};
                }
                continue;
            }
            if (word_is_import) {
                pos += 6;
                while (pos < n and (src[pos] == ' ' or src[pos] == '\t')) : (pos += 1) {}
                if (pos < n and (src[pos] == '"' or src[pos] == '\'')) {
                    const q = src[pos];
                    pos += 1;
                    const rs = pos;
                    while (pos < n and src[pos] != q) : (pos += 1) {}
                    const rel = src[rs..pos];
                    if (pos < n) pos += 1;
                    if (!std.mem.endsWith(u8, rel, ".c4asm")) {
                        const sub = base_dir.readFileAlloc(io, rel, alloc, .limited(4 * 1024 * 1024)) catch
                            std.Io.Dir.cwd().readFileAlloc(io, rel, alloc, .limited(4 * 1024 * 1024)) catch continue;
                        prescan(alloc, io, sub, rel, base_dir, fns, structs, visited) catch {};
                    }
                }
                continue;
            }
            while (pos < n and (std.ascii.isAlphanumeric(src[pos]) or src[pos] == '_')) : (pos += 1) {}
            continue;
        }
        pos += 1;
    }
}

pub fn emitProgram(
    alloc: std.mem.Allocator,
    io: Io,
    path: []const u8,
    source: []const u8,
    out: *std.ArrayList(u8),
    freestanding: bool,
) !void {
    var fns_table = std.StringHashMap(FnInfo).init(alloc);
    var structs_table = std.StringHashMap(StructInfo).init(alloc);
    var visited = std.StringHashMap(bool).init(alloc);
    try prescan(alloc, io, source, path, std.Io.Dir.cwd(), &fns_table, &structs_table, &visited);
    var imported = std.StringHashMap(bool).init(alloc);
    try imported.put(try alloc.dupe(u8, path), true);
    var mods = std.StringHashMap(bool).init(alloc);
    var fns_buf: std.ArrayList(u8) = .empty;
    var main_buf: std.ArrayList(u8) = .empty;
    var pre_buf: std.ArrayList(u8) = .empty;
    var fn_names: std.ArrayList([]const u8) = .empty;
    var fit = fns_table.iterator();
    while (fit.next()) |e| {
        try fn_names.append(alloc, e.key_ptr.*);
    }
    std.mem.sort([]const u8, fn_names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var fn_ids = std.StringHashMap(usize).init(alloc);
    for (fn_names.items, 0..) |nm, i| {
        try fn_ids.put(nm, i);
    }
    var top_vals = std.StringHashMap(bool).init(alloc);
    var em = Emitter{
        .src = source,
        .alloc = alloc,
        .out = &main_buf,
        .pre = &pre_buf,
        .fns = &fns_buf,
        .file = path,
        .base_dir = std.Io.Dir.cwd(),
        .io = io,
        .imported = &imported,
        .fns_table = &fns_table,
        .structs_table = &structs_table,
        .mods = &mods,
        .indent = 1,
        .fs = freestanding,
        .fn_ids = &fn_ids,
        .valnames = &top_vals,
    };
    var head: std.ArrayList(u8) = .empty;
    if (freestanding) {
        try head.appendSlice(alloc, "#include \"c4rt_fs.h\"\n\n");
    } else {
        try head.appendSlice(alloc, "#include \"c4rt.h\"\n#include <string.h>\n#include <setjmp.h>\n\n");
    }
    var fit2 = fns_table.iterator();
    while (fit2.next()) |e| {
        try head.appendSlice(alloc, "static C4Val f_");
        try head.appendSlice(alloc, e.key_ptr.*);
        try head.appendSlice(alloc, "(");
        if (e.value_ptr.params.len == 0) {
            try head.appendSlice(alloc, "void");
        } else {
            for (e.value_ptr.params, 0..) |pr, i| {
                if (i > 0) try head.appendSlice(alloc, ", ");
                try head.appendSlice(alloc, "C4Val v_");
                try head.appendSlice(alloc, pr);
            }
        }
        try head.appendSlice(alloc, ");\n");
    }
    var sit = structs_table.iterator();
    while (sit.next()) |e| {
        try head.appendSlice(alloc, "static const char *st_");
        try head.appendSlice(alloc, e.key_ptr.*);
        try head.appendSlice(alloc, "[] = {");
        for (e.value_ptr.fields, 0..) |f, i| {
            if (i > 0) try head.appendSlice(alloc, ", ");
            try head.appendSlice(alloc, "\"");
            try head.appendSlice(alloc, f);
            try head.appendSlice(alloc, "\"");
        }
        const ns = try std.fmt.allocPrint(alloc, "}};\nstatic const size_t st_{s}_n = {d};\n", .{ e.key_ptr.*, e.value_ptr.fields.len });
        try head.appendSlice(alloc, ns);
    }
    if (!freestanding and fn_names.items.len > 0) {
        try head.appendSlice(alloc, "\n/* fnval dispatcher (sorted ids) */\n");
        for (0..9) |nargs| {
            const h = try std.fmt.allocPrint(alloc, "static C4Val c4_call{d}(C4Val f", .{nargs});
            try head.appendSlice(alloc, h);
            for (0..nargs) |i| {
                const a = try std.fmt.allocPrint(alloc, ", C4Val a{d}", .{i});
                try head.appendSlice(alloc, a);
            }
            try head.appendSlice(alloc, ") {\n    if (f.t != C4_FN) c4_err(\"TypeError\");\n    long id = (long)f.num;\n    switch (id) {\n");
            for (fn_names.items, 0..) |nm, id| {
                const fi = fns_table.get(nm).?;
                if (fi.params.len != nargs) continue;
                const c = try std.fmt.allocPrint(alloc, "    case {d}: return f_{s}(", .{ id, nm });
                try head.appendSlice(alloc, c);
                for (0..nargs) |i| {
                    if (i > 0) try head.appendSlice(alloc, ", ");
                    const a = try std.fmt.allocPrint(alloc, "a{d}", .{i});
                    try head.appendSlice(alloc, a);
                }
                try head.appendSlice(alloc, ");\n");
            }
            try head.appendSlice(alloc, "    default: break;\n    }\n    c4_err(\"ArityMismatch\");\n    return c4_nil();\n}\n");
        }
    }
    em.run() catch |err| {
        if (err == EmitError.Unsupported) std.process.exit(1);
        return err;
    };
    try out.appendSlice(alloc, head.items);
    try out.appendSlice(alloc, "\n");
    try out.appendSlice(alloc, fns_buf.items);
    if (freestanding) {
        try out.appendSlice(alloc, "\n__attribute__((section(\".text.kmain\")))\nvoid kmain(void) {\n");
    } else {
        try out.appendSlice(alloc, "\nint main(int argc, char **argv) {\n    c4_args_init(argc, argv);\n");
    }
    try out.appendSlice(alloc, pre_buf.items);
    try out.appendSlice(alloc, main_buf.items);
    if (freestanding) {
        try out.appendSlice(alloc, "}\n");
    } else {
        try out.appendSlice(alloc, "    return 0;\n}\n");
    }
}
