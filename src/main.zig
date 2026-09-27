const std = @import("std");
const Io = std.Io;
const tool = @import("build_options");
const emit = @import("emit");
const gui = @import("gui");
const proc = @import("proc");

const ErrInfo = struct {
    file: ?[]const u8 = null,
    line: usize = 1,
    src: ?[]const u8 = null,
    exit_code: i32 = 0,
    fail_msg: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    // deep recursion (call depth 1000) needs more than the 1MB main-thread stack
    const t = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, cliMain, .{init});
    return t.join();
}

fn cliMain(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const raw_args = try init.minimal.args.toSlice(arena);
    // -silent may appear anywhere; strip it (programs needing the literal can use --silent)
    var silent = false;
    var trace = false;
    var argbuf: std.ArrayList([]const u8) = .empty;
    try argbuf.append(arena, raw_args[0]);
    for (raw_args[1..]) |a| {
        if (std.mem.eql(u8, a, "-silent")) {
            silent = true;
        } else if (std.mem.eql(u8, a, "-trace")) {
            trace = true;
        } else {
            try argbuf.append(arena, a);
        }
    }
    const args = try argbuf.toOwnedSlice(arena);
    if (args.len == 1) {
        try replMain(io, arena, init.environ_map, silent);
        return;
    }
    var cmd: []const u8 = "run";
    var path: ?[]const u8 = null;
    var fmt_write = false;
    var emit_out: ?[]const u8 = null;
    var freestanding = false;
    var ok_msg: ?[]const u8 = null;
    var script_args: []const []const u8 = &.{};
    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "assoc")) {
            cmd = "assoc";
            path = args[1];
        } else {
            path = args[1];
        }
    } else if (args.len >= 3 and (std.mem.eql(u8, args[1], "run") or std.mem.eql(u8, args[1], "check") or std.mem.eql(u8, args[1], "trace"))) {
        if (std.mem.eql(u8, args[1], "trace")) {
            trace = true;
            cmd = "run";
        } else {
            cmd = args[1];
        }
        path = args[2];
        script_args = args[3..];
    } else if (args.len >= 3 and !std.mem.eql(u8, args[1], "fmt") and std.mem.endsWith(u8, args[1], ".c4p")) {
        // bare run with script args: c4c prog.c4p a b c
        path = args[1];
        script_args = args[2..];
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "fmt")) {
        cmd = "fmt";
        if (args.len == 3) {
            path = args[2];
        } else if (args.len == 4 and std.mem.eql(u8, args[2], "--write")) {
            fmt_write = true;
            path = args[3];
        } else {
            path = null;
        }
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "--emit-c")) {
        cmd = "emit-c";
        // forms: --emit-c file | --emit-c file -o out | --emit-c file --freestanding | combos
        if (args.len >= 3) {
            path = args[2];
            var i: usize = 3;
            while (i < args.len) {
                if (std.mem.eql(u8, args[i], "--freestanding")) {
                    freestanding = true;
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "-o")) {
                    if (i + 1 >= args.len) {
                        path = null;
                        break;
                    }
                    emit_out = args[i + 1];
                    i += 2;
                } else {
                    path = null;
                    break;
                }
            }
        } else {
            path = null;
        }
    } else if (args.len >= 2 and std.mem.eql(u8, args[1], "assoc")) {
        // (len==2 handled above; this covers `assoc --remove`)
        cmd = "assoc";
        path = args[1]; // placeholder; handled before generic flow
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "exec")) {        cmd = "exec";
        path = args[2];
        // trailing: script args + optional --ok "msg"
        var sargs: std.ArrayList([]const u8) = .empty;
        var i: usize = 3;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--ok")) {
                if (i + 1 >= args.len) {
                    path = null;
                    break;
                }
                ok_msg = args[i + 1];
                i += 2;
            } else {
                sargs.append(arena, args[i]) catch {
                    path = null;
                    break;
                };
                i += 1;
            }
        }
        script_args = sargs.items;
    }
    if (std.mem.eql(u8, cmd, "assoc")) {
        const remove = args.len == 3 and std.mem.eql(u8, args[2], "--remove");
        if (args.len > 3 or (args.len == 3 and !remove)) {
            std.debug.print("usage: {s} assoc [--remove]\n", .{tool.exe_name});
            std.process.exit(1);
        }
        assocMain(io, arena, remove) catch |err| {
            std.debug.print("error: assoc failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, args[1], "new")) {
        if (args.len < 3) {
            std.debug.print("usage: {s} new <name> [--gui]\n", .{tool.exe_name});
            std.process.exit(1);
        }
        const want_gui = args.len == 3 and std.mem.eql(u8, args[2], "--gui");
        const name = if (want_gui) args[2] else args[2];
        newProjectMain(io, arena, name) catch |err| {
            std.debug.print("error: new failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, args[1], "build")) {
        if (args.len < 2) {
            std.debug.print("usage: {s} build [project.c4proj] [--native]\n", .{tool.exe_name});
            std.process.exit(1);
        }
        const proj: ?[]const u8 = if (args.len >= 3 and std.mem.endsWith(u8, args[2], ".c4proj")) args[2] else null;
        var native = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--native")) native = true;
        }
        buildProjectMain(io, arena, proj, native) catch |err| {
            std.debug.print("error: build failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (path == null) {
        std.debug.print("{s} - C4Plus compiler v{s}\nusage:\n  {s} run <file.c4p> [args...] [-silent]\n  {s} check <file.c4p> [-silent]\n  {s} trace <file.c4p> [args...]\n  {s} fmt [--write] <file.c4p> [-silent]\n  {s} --emit-c <file.c4p> [-o out.c] [-silent]\n  {s} exec \"<code>\" [args...] [--ok \"msg\"] [-silent]\n  {s} new <name>\n  {s} build [project.c4proj] [--native]\n  {s} assoc [--remove]\n  {s} <file.c4p> [args...] [-silent]\n(-silent/-trace anywhere)\n", .{ tool.exe_name, tool.exe_version, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name, tool.exe_name });
        std.process.exit(1);
    }
    const dry = std.mem.eql(u8, cmd, "check");

    if (std.mem.eql(u8, cmd, "fmt")) {
        if (!std.mem.endsWith(u8, path.?, ".c4p") and !std.mem.endsWith(u8, path.?, ".c4h") and !std.mem.endsWith(u8, path.?, ".c4asm") and !std.mem.endsWith(u8, path.?, ".c4bht")) {
            std.debug.print("error: fmt expects .c4p/.c4h/.c4asm/.c4bht file, got '{s}'\n", .{path.?});
            std.process.exit(1);
        }
    } else if (!std.mem.eql(u8, cmd, "exec") and !std.mem.endsWith(u8, path.?, ".c4p") and !std.mem.endsWith(u8, path.?, ".c4bht")) {
        std.debug.print("error: expected .c4p file, got '{s}'\n", .{path.?});
        std.process.exit(1);
    }

    var source: []const u8 = undefined;
    var disp_path: []const u8 = path.?;
    if (std.mem.eql(u8, cmd, "exec")) {
        // echo mode: bare expressions print their value (REPL rule)
        var code = path.?;
        if (replIsBareExpr(code)) {
            var te = code.len;
            while (te > 0 and (code[te - 1] == ' ' or code[te - 1] == '\t' or code[te - 1] == '\r' or code[te - 1] == '\n' or code[te - 1] == ';')) : (te -= 1) {}
            code = std.mem.concat(arena, u8, &.{ "print(", code[0..te], ")" }) catch {
                std.process.exit(1);
            };
        }
        source = code;
        disp_path = "<exec>";
    } else {
        source = std.Io.Dir.cwd().readFileAlloc(io, path.?, arena, .limited(4 * 1024 * 1024)) catch {
            std.debug.print("error: cannot read '{s}'\n", .{path.?});
            std.process.exit(1);
        };
    }
    const is_bht = std.mem.endsWith(u8, path.?, ".c4bht");
    var bht_head = BhtHead{ .title = null, .pause = null };
    if (is_bht and !std.mem.eql(u8, cmd, "exec")) {
        bht_head = parseBhtHead(arena, source) catch {
            std.process.exit(1);
        };
    }

    if (std.mem.eql(u8, cmd, "emit-c")) {
        var buf: std.ArrayList(u8) = .empty;
        emit.emitProgram(arena, io, path.?, source, &buf, freestanding) catch |err| {
            if (err == emit.EmitError.Unsupported) std.process.exit(1);
            std.debug.print("error: emit failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        const out = buf.items;
        if (emit_out) |op| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = out }) catch {
                std.debug.print("error: cannot write '{s}'\n", .{op});
                std.process.exit(1);
            };
        } else {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
            stdout_fw.interface.writeAll(out) catch {};
            stdout_fw.interface.flush() catch {};
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "fmt")) {
        const out = fmtSource(arena, source) catch {
            std.debug.print("error: fmt failed (out of memory)\n", .{});
            std.process.exit(1);
        };
        if (fmt_write) {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path.?, .data = out }) catch {
                std.debug.print("error: cannot write '{s}'\n", .{path.?});
                std.process.exit(1);
            };
        } else {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
            stdout_fw.interface.writeAll(out) catch {};
            stdout_fw.interface.flush() catch {};
        }
        return;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    var funcs_map = std.StringHashMap(Function).init(arena);
    const vars_map = std.StringHashMap(Value).init(arena);
    const top_scope = arena.create(Scope) catch {
        std.process.exit(1);
    };
    top_scope.* = .{ .vars = vars_map, .parent = null };
    var structs_map = std.StringHashMap(StructDef).init(arena);
    var imported_files = std.StringHashMap(bool).init(arena);
    try imported_files.put(try arena.dupe(u8, disp_path), true);
    var err_info = ErrInfo{};
    var stdin_buf: [8192]u8 = undefined;
    var stdin_fr = Io.File.stdin().reader(io, &stdin_buf);
    const cli_list = try arena.create(ListObj);
    cli_list.* = .{ .items = .empty };
    for (script_args) |a| {
        try cli_list.items.append(arena, Value{ .string = try arena.dupe(u8, a) });
    }
    var p = Parser{
        .src = source,
        .alloc = arena,
        .stdout = stdout,
        .funcs = &funcs_map,
        .structs = &structs_map,
        .scope = top_scope,
        .io = io,
        .stdin = &stdin_fr.interface,
        .file = disp_path,
        .base_dir = std.Io.Dir.cwd(),
        .imported_files = &imported_files,
        .err = &err_info,
        .dry = dry,
        .silent_run = silent and !dry,
        .trace = trace and !dry,
        .trace_out = stdout,
        .cli_args = cli_list,
        .envmap = init.environ_map,
    };
    p.run() catch |err| {
        stdout.flush() catch {};
        if (err == ParseError.ExitSignal) {
            if (dry) {
                std.debug.print("{s}: OK\n", .{disp_path});
                return;
            }
            std.process.exit(@intCast(err_info.exit_code));
        }
        if (err == ParseError.ReturnSignal) {
            std.debug.print("{s}: 'return' outside function\n", .{disp_path});
        } else if (err == ParseError.BreakSignal) {
            std.debug.print("{s}: 'break' outside loop\n", .{disp_path});
        } else if (err == ParseError.ContinueSignal) {
            std.debug.print("{s}: 'continue' outside loop\n", .{disp_path});
        } else if (err == ParseError.FailSignal) {
            if (err_info.fail_msg) |m| {
                std.debug.print("fail: {s}\n", .{m});
            } else {
                std.debug.print("fail\n", .{});
            }
        } else {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        printSpan(disp_path, &err_info);
        if (!dry) maybePauseBht(io, &stdin_fr.interface, stdout, bht_head, is_bht, silent) catch {};
        std.process.exit(1);
    };
    if (dry) {
        if (silent) {
            std.debug.print("ok\n", .{});
        } else {
            std.debug.print("{s}: OK\n", .{disp_path});
        }
    } else if (silent) {
        try stdout.writeAll("ok\n");
    } else if (ok_msg) |m| {
        try stdout.writeAll(m);
        try stdout.writeAll("\n");
    }
    try stdout.flush();
    if (!dry) maybePauseBht(io, &stdin_fr.interface, stdout, bht_head, is_bht, silent) catch {};
    gui.shutdownAll();
}

fn projEscape(s: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try out.append(alloc, '\\');
                try out.append(alloc, c);
            },
            else => try out.append(alloc, c),
        }
    }
    return out.items;
}

fn newProjectMain(io: Io, arena: std.mem.Allocator, name: []const u8) !void {
    const safe = blk: {
        var buf: std.ArrayList(u8) = .empty;
        for (name) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                try buf.append(arena, c);
            } else {
                try buf.append(arena, '_');
            }
        }
        if (buf.items.len == 0) break :blk "myapp";
        break :blk buf.items;
    };
    const dir = try std.fmt.allocPrint(arena, "{s}", .{safe});
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.debug.print("error: cannot create '{s}': {s}\n", .{ dir, @errorName(err) });
        std.process.exit(1);
    };
    const proj = try std.fmt.allocPrint(arena, "{s}/{s}.c4proj", .{ dir, safe });
    const proj_body = try std.fmt.allocPrint(arena,
        \\{{
        \\  "name": "{s}",
        \\  "main": "src/main.c4p",
        \\  "sources": ["src/*.c4p"],
        \\  "mode": "script"
        \\}}
        \\
    , .{safe});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = proj, .data = proj_body });
    const src_dir = try std.fmt.allocPrint(arena, "{s}/src", .{dir});
    std.Io.Dir.cwd().createDirPath(io, src_dir) catch {};
    const main_path = try std.fmt.allocPrint(arena, "{s}/src/main.c4p", .{dir});
    const main_body =
        \\# {s} - created by c4c new
        \\# run:   c4c build {s}/{s}.c4proj
        \\# go:    c4c run {s}/src/main.c4p
        \\print "hello from {s}"
        \\let n = 3
        \\print "3 squared is " + str(n * n)
        \\
    ;
    const filled = try std.fmt.allocPrint(arena, main_body, .{ safe, dir, safe, dir, safe });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = filled });
    std.debug.print("created {s} ({s})\n", .{ dir, proj });
    std.debug.print("  next: c4c run {s}\n", .{main_path});
}

fn projReadString(src: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, src, needle) orelse return null;
    var i = at + needle.len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\n' or src[i] == '\r' or src[i] == '\t')) i += 1;
    if (i >= src.len or src[i] != ':') return null;
    i += 1;
    while (i < src.len and (src[i] == ' ' or src[i] == '\n' or src[i] == '\r' or src[i] == '\t')) i += 1;
    if (i >= src.len or src[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < src.len and src[i] != '"') i += 1;
    return src[start..i];
}

fn projGlobList(alloc: std.mem.Allocator, src: []const u8, key: []const u8) ![][]const u8 {
    const needle = try std.fmt.allocPrint(alloc, "\"{s}\"", .{key});
    const at = std.mem.indexOf(u8, src, needle) orelse return &.{};
    const open = std.mem.indexOfScalarPos(u8, src, at, '[') orelse return &.{};
    const close = std.mem.indexOfScalarPos(u8, src, open, ']') orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var i = open + 1;
    while (i < close) {
        const q1 = std.mem.indexOfScalarPos(u8, src, i, '"') orelse break;
        const q2 = std.mem.indexOfScalarPos(u8, src, q1 + 1, '"') orelse break;
        try out.append(alloc, src[q1 + 1 .. q2]);
        i = q2 + 1;
    }
    return out.items;
}

fn buildProjectMain(io: Io, arena: std.mem.Allocator, proj_opt: ?[]const u8, native: bool) !void {
    const proj_path = proj_opt orelse "app.c4proj";
    const base = std.fs.path.dirname(proj_path) orelse ".";
    const proj_src = std.Io.Dir.cwd().readFileAlloc(io, proj_path, arena, .limited(1024 * 1024)) catch {
        std.debug.print("error: cannot read '{s}' (create one with: c4c new <name>)\n", .{proj_path});
        std.process.exit(1);
    };
    const name = projReadString(proj_src, "name") orelse "app";
    const main_rel = projReadString(proj_src, "main") orelse "src/main.c4p";
    const mode = projReadString(proj_src, "mode") orelse "script";
    const sources = try projGlobList(arena, proj_src, "sources");
    std.debug.print("project {s} ({s} mode)\n", .{ name, mode });

    var checked: usize = 0;
    var failed: usize = 0;
    var main_abs: ?[]const u8 = null;
    for (sources) |pat| {
        if (std.mem.endsWith(u8, pat, "*.c4p")) {
            const dir_raw = pat[0 .. pat.len - "*.c4p".len];
            const dir_rel = std.mem.trim(u8, dir_raw, "/\\");
            const dir_abs = if (dir_rel.len == 0) base else try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, std.fs.path.sep_str, dir_rel });
            var dir = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch {
                std.debug.print("  skip {s} (no dir)\n", .{dir_abs});
                continue;
            };
            defer dir.close(io);
            var walker = try dir.walk(arena);
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".c4p")) continue;
                const rel = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ dir_rel, if (dir_rel.len == 0) "" else "/", entry.basename });
                const full = if (std.mem.eql(u8, base, ".")) rel else try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, std.fs.path.sep_str, rel });
                if (!checkOne(io, arena, full)) failed += 1;
                checked += 1;
                if (std.mem.eql(u8, rel, main_rel)) main_abs = full;
            }
        } else {
            const full = if (std.mem.eql(u8, base, ".")) pat else try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, std.fs.path.sep_str, pat });
            if (!checkOne(io, arena, full)) failed += 1;
            checked += 1;
            if (std.mem.endsWith(u8, pat, main_rel)) main_abs = full;
        }
    }
    if (checked == 0) {
        std.debug.print("error: no sources matched\n", .{});
        std.process.exit(1);
    }
    if (failed > 0) {
        std.debug.print("build failed: {d} file(s) with errors\n", .{failed});
        std.process.exit(1);
    }
    std.debug.print("checked {d} file(s): OK\n", .{checked});
    if (std.mem.eql(u8, mode, "native") or native) {
        const main_file = main_abs orelse {
            std.debug.print("error: native mode needs a 'main' entry in the project file\n", .{});
            std.process.exit(1);
        };
        const exe_rel = try std.fmt.allocPrint(arena, "{s}.exe", .{name});
        const exe_abs = if (std.mem.eql(u8, base, ".")) exe_rel else try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, std.fs.path.sep_str, exe_rel });
        buildNative(io, arena, main_file, exe_abs) catch {
            std.debug.print("error: native build failed (is gcc on PATH?)\n", .{});
            std.process.exit(1);
        };
        std.debug.print("built {s}\n", .{exe_abs});
    }
}

fn dryCheck(io: Io, arena: std.mem.Allocator, path: []const u8) bool {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return false;
    var funcs_map = std.StringHashMap(Function).init(arena);
    const vars_map = std.StringHashMap(Value).init(arena);
    const top_scope = arena.create(Scope) catch {
        std.process.exit(1);
    };
    top_scope.* = .{ .vars = vars_map, .parent = null };
    var structs_map = std.StringHashMap(StructDef).init(arena);
    var imported_files = std.StringHashMap(bool).init(arena);
    imported_files.put(path, true) catch return false;
    const cli_list = arena.create(ListObj) catch return false;
    cli_list.* = .{ .items = .empty };
    var stdin_buf: [256]u8 = undefined;
    var stdin_fr = Io.File.stdin().reader(io, &stdin_buf);
    var sink_buf: [256]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&sink_buf);
    var p = Parser{
        .src = src,
        .alloc = arena,
        .stdout = &sink.writer,
        .funcs = &funcs_map,
        .structs = &structs_map,
        .scope = top_scope,
        .io = io,
        .stdin = &stdin_fr.interface,
        .file = path,
        .base_dir = std.Io.Dir.cwd(),
        .imported_files = &imported_files,
        .dry = true,
        .mute = true,
        .cli_args = cli_list,
    };
    p.run() catch return false;
    return true;
}

fn checkOne(io: Io, arena: std.mem.Allocator, path: []const u8) bool {
    if (dryCheck(io, arena, path)) {
        std.debug.print("  ok   {s}\n", .{path});
        return true;
    }
    std.debug.print("  FAIL {s}\n", .{path});
    return false;
}

fn buildNative(io: Io, arena: std.mem.Allocator, main_file: []const u8, exe_path: []const u8) !void {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, main_file, arena, .limited(4 * 1024 * 1024));
    var buf: std.ArrayList(u8) = .empty;
    try emit.emitProgram(arena, io, main_file, src, &buf, false);
    const c_path = try std.fmt.allocPrint(arena, "{s}.c", .{exe_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = c_path, .data = buf.items });
    const result = try std.process.run(arena, io, .{
        .argv = &.{
            "gcc",           "-std=c99", "-w", "-I", "rt",
            "-o",            exe_path,
            c_path,          "rt/c4rt.c",
            "-lm",
        },
    });
    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.CompileFailed;
        },
        else => return error.CompileFailed,
    }
}

fn replMain(io: Io, arena: std.mem.Allocator, envmap: ?*const std.process.Environ.Map, silent: bool) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stdin_buf: [8192]u8 = undefined;
    var stdin_fr = Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_fr.interface;

    var funcs_map = std.StringHashMap(Function).init(arena);
    const vars_map = std.StringHashMap(Value).init(arena);
    const top_scope = arena.create(Scope) catch {
        std.process.exit(1);
    };
    top_scope.* = .{ .vars = vars_map, .parent = null };
    var structs_map = std.StringHashMap(StructDef).init(arena);
    var imported_files = std.StringHashMap(bool).init(arena);
    var err_info = ErrInfo{};
    const cli_list = try arena.create(ListObj);
    cli_list.* = .{ .items = .empty };

    if (!silent) {
        try stdout.writeAll("c4plus repl — type exit() to quit\n");
        try stdout.flush();
    }    var acc: std.ArrayList(u8) = .empty;
    var line_no: usize = 1;
    while (true) {
        if (acc.items.len == 0) {
            try stdout.writeAll("c4p> ");
        } else {
            try stdout.writeAll(".... ");
        }
        try stdout.flush();
        const maybe_line = stdin.takeDelimiter('\n') catch break;
        const raw_line = maybe_line orelse break; // EOF
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try acc.appendSlice(arena, line);
        try acc.append(arena, '\n');
        if (replDepth(acc.items) > 0) continue;
        const chunk = try acc.toOwnedSlice(arena);
        line_no += std.mem.count(u8, chunk, "\n");
        if (replBlank(chunk)) continue;
        var trim_end = chunk.len;
        while (trim_end > 0 and (chunk[trim_end - 1] == ' ' or chunk[trim_end - 1] == '\t' or chunk[trim_end - 1] == '\r' or chunk[trim_end - 1] == '\n' or chunk[trim_end - 1] == ';')) : (trim_end -= 1) {}
        const run_src = if (replIsBareExpr(chunk)) try std.mem.concat(arena, u8, &.{ "print(", chunk[0..trim_end], ")" }) else chunk;
        var sub = Parser{
            .src = run_src,
            .pos = 0,
            .line = line_no - std.mem.count(u8, chunk, "\n"),
            .alloc = arena,
            .stdout = stdout,
            .funcs = &funcs_map,
            .structs = &structs_map,
            .scope = top_scope,
            .io = io,
            .stdin = stdin,
            .file = "<repl>",
            .base_dir = std.Io.Dir.cwd(),
            .imported_files = &imported_files,
            .err = &err_info,
            .dry = false,
            .mute = false,
            .cli_args = cli_list,
            .envmap = envmap,
            .depth = 0,
        };
        // carry session imports into the chunk
        sub.imported_os = repl_os;
        sub.imported_physics = repl_physics;
        sub.imported_json = repl_json;
        sub.imported_time = repl_time;
        sub.run() catch |err| {
            stdout.flush() catch {};
            if (err == ParseError.ExitSignal) {
                stdout.flush() catch {};
                std.process.exit(@intCast(err_info.exit_code));
            }
            if (err == ParseError.ReturnSignal) {
                std.debug.print("<repl>: 'return' outside function\n", .{});
            } else if (err == ParseError.BreakSignal) {
                std.debug.print("<repl>: 'break' outside loop\n", .{});
            } else if (err == ParseError.ContinueSignal) {
                std.debug.print("<repl>: 'continue' outside loop\n", .{});
            } else if (err == ParseError.FailSignal) {
                if (err_info.fail_msg) |m| std.debug.print("fail: {s}\n", .{m});
            } else {
                std.debug.print("error: {s}\n", .{@errorName(err)});
            }
            printSpan("<repl>", &err_info);
            err_info = ErrInfo{};
        };
        repl_os = sub.imported_os;
        repl_physics = sub.imported_physics;
        repl_json = sub.imported_json;
        repl_time = sub.imported_time;
        try stdout.flush();
    }
    try stdout.flush();
}

var repl_os: bool = false;
var repl_physics: bool = false;
var repl_json: bool = false;
var repl_time: bool = false;

fn replBlank(chunk: []const u8) bool {
    var i: usize = 0;
    while (i < chunk.len) {
        const c = chunk[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '#') return true;
        if (c == '/' and i + 1 < chunk.len and chunk[i + 1] == '/') return true;
        return false;
    }
    return true;
}

fn replDepth(src: []const u8) i64 {
    var depth: i64 = 0;
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (in_str != 0) {
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '{' or c == '(' or c == '[') depth += 1;
        if (c == '}' or c == ')' or c == ']') depth -= 1;
        i += 1;
    }
    return depth;
}

fn replIsBareExpr(chunk: []const u8) bool {
    var i: usize = 0;
    while (i < chunk.len and (chunk[i] == ' ' or chunk[i] == '\t' or chunk[i] == '\r' or chunk[i] == '\n')) : (i += 1) {}
    if (i >= chunk.len) return false;
    const c = chunk[i];
    if (!std.ascii.isAlphabetic(c) and c != '_') return true; // 1+1, "hi", (x), ...
    const start = i;
    while (i < chunk.len and (std.ascii.isAlphanumeric(chunk[i]) or chunk[i] == '_')) : (i += 1) {}
    const word = chunk[start..i];
    const kws = [_][]const u8{ "let", "print", "pt", "fn", "struct", "if", "while", "for", "switch", "try", "return", "break", "continue", "import" };
    for (kws) |k| {
        if (std.mem.eql(u8, word, k)) return false;
    }
    var j = i;
    while (j < chunk.len and (chunk[j] == ' ' or chunk[j] == '\t')) : (j += 1) {}
    if (j >= chunk.len) return true; // lone name -> echo it
    const d = chunk[j];
    if (d == '(') return true; // call -> echo result
    if (d == '=') {
        // == is a comparison (echo it); single = is assignment (silent)
        if (j + 1 < chunk.len and chunk[j + 1] == '=') return true;
        return false;
    }
    if (d == '[' or d == '.') return false; // index/field path -> statement
    return true; // anything else (operators etc.) -> echo as expression
}

fn assocMain(io: Io, arena: std.mem.Allocator, remove: bool) !void {
    if (@import("builtin").os.tag != .windows) {
        std.debug.print("error: assoc is Windows-only\n", .{});
        std.process.exit(1);
    }
    if (remove) {
        try regRun(arena, io, &.{ "reg", "delete", "HKCU\\Software\\Classes\\C4Plus.Batch", "/f" });
        try regRun(arena, io, &.{ "reg", "delete", "HKCU\\Software\\Classes\\.c4bht", "/f" });
        std.debug.print("association removed\n", .{});
        return;
    }
    const exe = try std.process.executablePathAlloc(io, arena);
    const open_cmd = try std.fmt.allocPrint(arena, "\"{s}\" run \"%1\"", .{exe});
    try regRun(arena, io, &.{ "reg", "add", "HKCU\\Software\\Classes\\.c4bht", "/ve", "/d", "C4Plus.Batch", "/f" });
    try regRun(arena, io, &.{ "reg", "add", "HKCU\\Software\\Classes\\C4Plus.Batch", "/ve", "/d", "C4Plus Batch", "/f" });
    try regRun(arena, io, &.{ "reg", "add", "HKCU\\Software\\Classes\\C4Plus.Batch\\shell\\open\\command", "/ve", "/d", open_cmd, "/f" });
    const icon = try std.fmt.allocPrint(arena, "{s},0", .{exe});
    try regRun(arena, io, &.{ "reg", "add", "HKCU\\Software\\Classes\\C4Plus.Batch\\DefaultIcon", "/ve", "/d", icon, "/f" });
    std.debug.print("associated .c4bht with {s}\n", .{exe});
}

fn regRun(arena: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const res = try std.process.run(arena, io, .{ .argv = argv });
    defer arena.free(res.stdout);
    defer arena.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.RegFailed;
}

const BhtHead = struct { title: ?[]const u8, pause: ?bool };

fn parseBhtHead(alloc: std.mem.Allocator, source: []const u8) !BhtHead {
    var head = BhtHead{ .title = null, .pause = null };
    const eol = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    var first = source[0..eol];
    if (first.len > 0 and first[first.len - 1] == '\r') first = first[0 .. first.len - 1];
    if (!std.mem.startsWith(u8, first, "#c4bht")) {
        std.debug.print("error: .c4bht needs '#c4bht ...' first line\n", .{});
        return ParseError.UnexpectedEof;
    }
    var rest = first["#c4bht".len..];
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) : (rest = rest[1..]) {}
        if (rest.len == 0) break;
        if (std.mem.startsWith(u8, rest, "title=\"")) {
            rest = rest["title=\"".len..];
            const q = std.mem.indexOfScalar(u8, rest, '"') orelse {
                std.debug.print("error: bad title= (missing quote)\n", .{});
                return ParseError.UnexpectedEof;
            };
            head.title = try alloc.dupe(u8, rest[0..q]);
            rest = rest[q + 1 ..];
        } else if (std.mem.startsWith(u8, rest, "pause") and (rest.len == 5 or rest[5] == ' ' or rest[5] == '\t')) {
            head.pause = true;
            rest = rest[5..];
        } else if (std.mem.startsWith(u8, rest, "nopause") and (rest.len == 7 or rest[7] == ' ' or rest[7] == '\t')) {
            head.pause = false;
            rest = rest[7..];
        } else {
            std.debug.print("error: bad .c4bht flag (want title=\"..\"/pause/nopause)\n", .{});
            return ParseError.UnexpectedEof;
        }
    }
    return head;
}

fn maybePauseBht(io: Io, stdin: *Io.Reader, stdout: *Io.Writer, head: BhtHead, is_bht: bool, silent: bool) !void {
    _ = io;
    if (!is_bht or silent) return;
    if (head.pause == false) return;
    if (head.title) |t| {
        try stdout.writeAll("--- ");
        try stdout.writeAll(t);
        try stdout.writeAll(" ---\n");
    }
    try stdout.writeAll("press enter to close...\n");
    try stdout.flush();
    _ = stdin.takeDelimiter('\n') catch null;
}

fn printSpan(top_path: []const u8, err: *ErrInfo) void {    const f = err.file orelse return;
    const src = err.src orelse return;
    if (err.line == 0) return;
    // find line bounds
    var cur: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < src.len and cur < err.line) : (i += 1) {
        if (src[i] == '\n') cur += 1;
    }
    start = i;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    var end = i;
    if (end > start and src[end - 1] == '\r') end -= 1;
    const maxlen: usize = 120;
    var line = src[start..end];
    if (line.len > maxlen) line = line[0..maxlen];
    _ = top_path;
    std.debug.print("--> {s}:{d}\n    | {s}\n", .{ f, err.line, line });
}

// c4c fmt: whitespace-only formatter (never joins/splits code lines).
fn fmtSource(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= src.len) {
        if (i == src.len or src[i] == '\n') {
            var line = src[start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try lines.append(alloc, line);
            start = i + 1;
        }
        i += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    var depth: i64 = 0;
    var blank_run: usize = 0;
    var emitted_any = false;
    for (lines.items) |raw| {
        var blank = true;
        for (raw) |ch| {
            if (ch != ' ' and ch != '\t') {
                blank = false;
                break;
            }
        }
        if (blank) {
            blank_run += 1;
            if (emitted_any and blank_run <= 1) try out.append(alloc, '\n');
            continue;
        }
        blank_run = 0;
        emitted_any = true;
        const info = fmtScanLine(raw);
        var indent: i64 = depth;
        if (info.starts_close) indent -= 1;
        if (indent < 0) indent = 0;
        var k: i64 = 0;
        while (k < indent * 2) : (k += 1) try out.append(alloc, ' ');
        const norm = try fmtNormLine(alloc, raw);
        try out.appendSlice(alloc, norm);
        try out.append(alloc, '\n');
        depth += info.delta;
        if (depth < 0) depth = 0;
    }
    return try out.toOwnedSlice(alloc);
}

const FmtLineInfo = struct { starts_close: bool, delta: i64 };

fn fmtScanLine(line: []const u8) FmtLineInfo {
    var in_str: u8 = 0;
    var i: usize = 0;
    const n = line.len;
    var delta: i64 = 0;
    var starts_close = false;
    var seen_code = false;
    while (i < n) {
        const c = line[i];
        if (in_str != 0) {
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == in_str) in_str = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            i += 1;
            continue;
        }
        if (c == '#') break;
        if (c == '/' and i + 1 < n and line[i + 1] == '/') break;
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (!seen_code) {
            seen_code = true;
            if (c == '}') starts_close = true;
        }
        if (c == '{') delta += 1;
        if (c == '}') delta -= 1;
        i += 1;
    }
    return .{ .starts_close = starts_close, .delta = delta };
}

fn fmtIsWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn fmtForceSp(out: *std.ArrayList(u8), alloc: std.mem.Allocator, emitted: bool) !void {
    if (!emitted) return;
    if (out.items.len == 0) return;
    const last = out.items[out.items.len - 1];
    if (last != ' ' and last != '(' and last != '[') try out.append(alloc, ' ');
}

fn fmtSkipWs(line: []const u8, i: *usize) void {
    while (i.* < line.len and (line[i.*] == ' ' or line[i.*] == '\t')) : (i.* += 1) {}
}

fn fmtNormLine(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    // #target and #c4bht lines are significant verbatim
    var ti: usize = 0;
    while (ti < line.len and (line[ti] == ' ' or line[ti] == '\t')) : (ti += 1) {}
    if (std.mem.startsWith(u8, line[ti..], "#target ") or std.mem.startsWith(u8, line[ti..], "#c4bht")) {
        var e = line.len;
        while (e > ti and (line[e - 1] == ' ' or line[e - 1] == '\t')) : (e -= 1) {}
        return try alloc.dupe(u8, line[ti..e]);
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const n = line.len;
    while (i < n and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var pending = false;
    var prev_sig: u8 = 0;
    var emitted = false;
    const emitSp = struct {
        fn f(o: *std.ArrayList(u8), a: std.mem.Allocator, pend: *bool, em: bool) !void {
            if (pend.* and em) try o.append(a, ' ');
            pend.* = false;
        }
    }.f;
    while (i < n) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            pending = true;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            if (pending and emitted and prev_sig != '(' and prev_sig != '[') try out.append(alloc, ' ');
            pending = false;
            const q = c;
            try out.append(alloc, q);
            i += 1;
            while (i < n) {
                const d = line[i];
                try out.append(alloc, d);
                i += 1;
                if (d == '\\' and i < n) {
                    try out.append(alloc, line[i]);
                    i += 1;
                    continue;
                }
                if (d == q) break;
            }
            prev_sig = q;
            emitted = true;
            continue;
        }
        if (c == '#') {
            if (emitted and pending) try out.append(alloc, ' ');
            try out.append(alloc, '#');
            i += 1;
            if (i < n and line[i] != ' ' and line[i] != '\t') try out.append(alloc, ' ');
            while (i < n) : (i += 1) try out.append(alloc, line[i]);
            break;
        }
        if (c == '/' and i + 1 < n and line[i + 1] == '/') {
            if (emitted and pending) try out.append(alloc, ' ');
            try out.appendSlice(alloc, "//");
            i += 2;
            if (i < n and line[i] != ' ' and line[i] != '\t') try out.append(alloc, ' ');
            while (i < n) : (i += 1) try out.append(alloc, line[i]);
            break;
        }
        if (c == ',') {
            try out.append(alloc, ',');
            pending = true;
            i += 1;
            prev_sig = ',';
            emitted = true;
            continue;
        }
        if (c == '(') {
            if (pending and emitted and !(prev_sig != 0 and (fmtIsWordChar(prev_sig) or prev_sig == ')' or prev_sig == ']' or prev_sig == '"' or prev_sig == '\''))) {
                try out.append(alloc, ' ');
            }
            pending = false;
            try out.append(alloc, '(');
            i += 1;
            fmtSkipWs(line, &i);
            prev_sig = '(';
            emitted = true;
            continue;
        }
        if (c == ')' or c == ']' or c == ';') {
            pending = false;
            try out.append(alloc, c);
            i += 1;
            if (c == ';') pending = true;
            prev_sig = c;
            emitted = true;
            continue;
        }
        if (c == '[') {
            if (pending and emitted and !(prev_sig != 0 and (fmtIsWordChar(prev_sig) or prev_sig == ')' or prev_sig == ']' or prev_sig == '"' or prev_sig == '\''))) {
                try out.append(alloc, ' ');
            }
            pending = false;
            try out.append(alloc, '[');
            i += 1;
            fmtSkipWs(line, &i);
            prev_sig = '[';
            emitted = true;
            continue;
        }
        if (c == '{') {
            if (emitted) try out.append(alloc, ' ');
            pending = false;
            try out.append(alloc, '{');
            i += 1;
            prev_sig = '{';
            emitted = true;
            continue;
        }
        if (c == '}') {
            if (emitted) {
                // trim a pending/extra space before }
                if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
                try out.append(alloc, ' ');
            }
            pending = false;
            try out.append(alloc, '}');
            i += 1;
            pending = true;
            prev_sig = '}';
            emitted = true;
            continue;
        }
        if (c == ':' and !(i + 1 < n and line[i + 1] == ':')) {
            pending = false;
            try out.append(alloc, ':');
            i += 1;
            pending = true;
            prev_sig = ':';
            emitted = true;
            continue;
        }
        // two-char operators
        if (i + 1 < n and ((c == '=' and line[i + 1] == '=') or (c == '!' and line[i + 1] == '=') or (c == '<' and line[i + 1] == '=') or (c == '>' and line[i + 1] == '=') or (c == '<' and line[i + 1] == '<') or (c == '>' and line[i + 1] == '>'))) {
            try fmtForceSp(&out, alloc, emitted);
            pending = false;
            try out.appendSlice(alloc, line[i .. i + 2]);
            i += 2;
            pending = true;
            prev_sig = line[i - 1];
            emitted = true;
            continue;
        }
        if (c == '=' or c == '<' or c == '>' or c == '&' or c == '|' or c == '^') {
            try fmtForceSp(&out, alloc, emitted);
            pending = false;
            try out.append(alloc, c);
            i += 1;
            pending = true;
            prev_sig = c;
            emitted = true;
            continue;
        }
        if (c == '~') {
            pending = false;
            try out.append(alloc, c);
            i += 1;
            prev_sig = c;
            emitted = true;
            continue;
        }
        if (c == '+' or c == '-') {
            const unary = !emitted or prev_sig == '(' or prev_sig == '[' or prev_sig == '{' or prev_sig == ',' or prev_sig == '=' or prev_sig == '<' or prev_sig == '>' or prev_sig == '!' or prev_sig == '+' or prev_sig == '-' or prev_sig == '*' or prev_sig == '/' or prev_sig == '%' or prev_sig == ':' or prev_sig == ';' or prev_sig == '~' or prev_sig == '&' or prev_sig == '|' or prev_sig == '^';
            if (unary) {
                pending = false;
                try out.append(alloc, c);
                i += 1;
                prev_sig = c;
                emitted = true;
                continue;
            }
            try fmtForceSp(&out, alloc, emitted);
            pending = false;
            try out.append(alloc, c);
            i += 1;
            pending = true;
            prev_sig = c;
            emitted = true;
            continue;
        }
        if (c == '*' or c == '/' or c == '%') {
            try fmtForceSp(&out, alloc, emitted);
            pending = false;
            try out.append(alloc, c);
            i += 1;
            pending = true;
            prev_sig = c;
            emitted = true;
            continue;
        }
        try emitSp(&out, alloc, &pending, emitted);
        try out.append(alloc, c);
        i += 1;
        prev_sig = c;
        emitted = true;
    }
    // trim trailing space
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return try out.toOwnedSlice(alloc);
}

const ListObj = struct {
    items: std.ArrayList(Value),
};
const DictObj = struct {
    map: std.StringHashMap(Value),
};

const StructDef = struct {
    name: []const u8,
    fields: [][]const u8,
};

const StructObj = struct {
    type_name: []const u8,
    fields: [][]const u8,
    values: std.ArrayList(Value),
};

const Value = union(enum) {
    number: f64,
    string: []const u8,
    list: *ListObj,
    dict: *DictObj,
    instance: *StructObj,
    function: FnVal,
    nil: void,
};

const FnVal = struct {
    name: []const u8,
    scope: ?*Scope,
};

const Scope = struct {
    vars: std.StringHashMap(Value),
    parent: ?*Scope,
};

const hexDigits = "0123456789abcdef";

fn hexPair(alloc: std.mem.Allocator, b: u8) ![]const u8 {
    const out = try alloc.alloc(u8, 2);
    out[0] = hexDigits[@as(usize, b >> 4)];
    out[1] = hexDigits[@as(usize, b & 0xF)];
    return out;
}

fn crc32Byte(crc: u32, b: u8) u32 {
    var c = crc ^ @as(u32, b);
    var i: u5 = 0;
    while (i < 8) : (i += 1) {
        const mask: u32 = 0 -% (c & 1);
        c = (c >> 1) ^ (0xEDB88320 & mask);
    }
    return c;
}

var g_start_ms: ?i64 = null;
var g_rng: u64 = 0x853C49E6748FEA9B;

fn seedFrom(v: i64) u64 {
    var x: u64 = @bitCast(v);
    if (x == 0) x = 0x9E3779B97F4A7C15;
    x ^= x >> 30;
    x *%= 0xBF58476D1CE4E5B9;
    x ^= x >> 27;
    x *%= 0x94D049BB133111EB;
    x ^= x >> 31;
    return x;
}

fn numToI64(v: f64) i64 {
    const c = @max(-9.0e15, @min(9.0e15, v));
    return @intFromFloat(c);
}

fn nextRand() u64 {
    var x = g_rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    g_rng = x;
    return x *% 0x2545F4914F6CDD1D;
}

const Function = struct {
    name: []const u8,
    params: [][]const u8,
    body: []const u8,
    def_line: usize,
    scope: ?*Scope,
};

const ParseError = error{
    UnexpectedEof,
    ExpectedString,
    UnterminatedString,
    ExpectedRParen,
    ExpectedRBracket,
    ExpectedRBrace,
    ExpectedLBrace,
    ExpectedLParen,
    UnknownKeyword,
    UnknownVariable,
    UnknownFunction,
    ArityMismatch,
    ExpectedNewline,
    ExpectedEquals,
    ExpectedCatch,
    ExpectedIdent,
    ExpectedIn,
    TypeError,
    DivisionByZero,
    BadNumber,
    ReturnSignal,
    BreakSignal,
    ContinueSignal,
    ExitSignal,
    FailSignal,
    MathError,
    JsonError,
    CallDepthExceeded,
    LoopLimitExceeded,
    IndexOutOfBounds,
    NotIndexable,
    KeyMissing,
    BadArgument,
    OutOfMemory,
    WriteFailed,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    alloc: std.mem.Allocator,
    stdout: *Io.Writer,
    funcs: *std.StringHashMap(Function),
    structs: *std.StringHashMap(StructDef),
    scope: *Scope,
    io: Io,
    stdin: *Io.Reader,
    imported_os: bool = false,
    imported_physics: bool = false,
    imported_json: bool = false,
    imported_time: bool = false,
    imported_heap: bool = false,
    imported_cpu: bool = false,
    imported_gui: bool = false,
    imported_hex: bool = false,
    imported_random: bool = false,
    imported_strings: bool = false,
    gui_cbs: ?*std.ArrayList(Value) = null,
    envmap: ?*const std.process.Environ.Map = null,
    cli_args: *ListObj,
    file: []const u8 = "<input>",
    base_dir: std.Io.Dir,
    imported_files: ?*std.StringHashMap(bool) = null,
    err: ?*ErrInfo = null,
    dry: bool = false,
    mute: bool = false,
    silent_run: bool = false,
    trace: bool = false,
    trace_indent: usize = 0,
    trace_out: ?*Io.Writer = null,
    return_value: ?Value = null,
    depth: usize = 0,

    fn scopeGet(self: *Parser, name: []const u8) ?Value {
        var s: ?*Scope = self.scope;
        while (s) |sc| {
            if (sc.vars.get(name)) |v| return v;
            s = sc.parent;
        }
        return null;
    }

    fn scopeOwner(self: *Parser, name: []const u8) ?*Scope {
        var s: ?*Scope = self.scope;
        while (s) |sc| {
            if (sc.vars.contains(name)) return sc;
            s = sc.parent;
        }
        return null;
    }

    fn noteErr(self: *Parser) void {
        if (self.err) |e| {
            if (e.file == null) {
                e.file = self.file;
                e.line = self.line;
                e.src = self.src;
            }
        }
    }

    fn run(self: *Parser) anyerror!void {
        while (true) {
            self.skipNewlines();
            if (self.pos >= self.src.len) break;
            if (self.eatComment()) continue;
            self.parseStatement() catch |err| {
                self.noteErr();
                return err;
            };
        }
    }

    fn runBodyShared(self: *Parser, body: []const u8, body_line: usize) anyerror!void {
        var sub = Parser{
            .src = body,
            .pos = 0,
            .line = body_line,
            .alloc = self.alloc,
            .stdout = self.stdout,
            .funcs = self.funcs,
            .structs = self.structs,
            .scope = self.scope,
            .io = self.io,
            .stdin = self.stdin,
            .imported_os = self.imported_os,
            .imported_physics = self.imported_physics,
            .imported_heap = self.imported_heap,
            .imported_gui = self.imported_gui,
            .imported_hex = self.imported_hex,
            .imported_random = self.imported_random,
            .imported_strings = self.imported_strings,
            .gui_cbs = self.gui_cbs,
            .imported_cpu = self.imported_cpu,
            .envmap = self.envmap,
            .imported_json = self.imported_json,
            .imported_time = self.imported_time,
            .cli_args = self.cli_args,
            .file = self.file,
            .base_dir = self.base_dir,
            .imported_files = self.imported_files,
            .err = self.err,
            .dry = self.dry,
            .mute = self.mute,
            .silent_run = self.silent_run,
            .trace = self.trace,
            .trace_indent = self.trace_indent,
            .trace_out = self.trace_out,
            .depth = self.depth,
        };
        sub.run() catch |err| {
            if (err == ParseError.ReturnSignal) {
                self.return_value = sub.return_value;
                return ParseError.ReturnSignal;
            }
            self.line = sub.line;
            return err;
        };
        self.line = sub.line;
    }

    fn evalCondSrc(self: *Parser, cond_src: []const u8) anyerror!Value {
        var tmp = Parser{
            .src = cond_src,
            .pos = 0,
            .line = self.line,
            .alloc = self.alloc,
            .stdout = self.stdout,
            .funcs = self.funcs,
            .structs = self.structs,
            .scope = self.scope,
            .io = self.io,
            .stdin = self.stdin,
            .imported_os = self.imported_os,
            .imported_physics = self.imported_physics,
            .imported_heap = self.imported_heap,
            .imported_gui = self.imported_gui,
            .imported_hex = self.imported_hex,
            .imported_random = self.imported_random,
            .imported_strings = self.imported_strings,
            .gui_cbs = self.gui_cbs,
            .imported_cpu = self.imported_cpu,
            .envmap = self.envmap,
            .imported_json = self.imported_json,
            .imported_time = self.imported_time,
            .cli_args = self.cli_args,
            .file = self.file,
            .base_dir = self.base_dir,
            .imported_files = self.imported_files,
            .err = self.err,
            .dry = self.dry,
            .mute = self.mute,
            .silent_run = self.silent_run,
            .trace = self.trace,
            .trace_indent = self.trace_indent,
            .trace_out = self.trace_out,
            .depth = self.depth + 1,
        };
        const v = try tmp.parseExpr();
        return v;
    }

    fn traceLine(self: *Parser, line: usize, from_src: []const u8) !void {
        var text = from_src;
        if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text = text[0..nl];
        if (std.mem.indexOfScalar(u8, text, '\r')) |cr| text = text[0..cr];
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return;
        if (trimmed[0] == '#') return;
        var indent_buf: [64]u8 = undefined;
        const n = @min(self.depth, 31);
        @memset(indent_buf[0..n * 2], ' ');
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.alloc, indent_buf[0 .. n * 2]);
        try out.appendSlice(self.alloc, if (self.trace_indent > 0) "  " else "");
        var buf: [32]u8 = undefined;
        const num = std.fmt.bufPrint(&buf, "{d: >4} | ", .{line}) catch "     | ";
        try out.appendSlice(self.alloc, num);
        var lim = trimmed;
        if (lim.len > 96) lim = lim[0..96];
        try out.appendSlice(self.alloc, lim);
        try out.append(self.alloc, '\n');
        const w = self.trace_out orelse return;
        try w.writeAll(out.items);
        try w.flush();
    }

    fn traceCall(self: *Parser, name: []const u8, entering: bool, value: ?Value) !void {
        var out: std.ArrayList(u8) = .empty;
        var indent_buf: [80]u8 = undefined;
        const n = @min(self.depth * 2, 39);
        @memset(indent_buf[0..n], ' ');
        try out.appendSlice(self.alloc, indent_buf[0..n]);
        if (entering) {
            try out.appendSlice(self.alloc, "-> call ");
            try out.appendSlice(self.alloc, name);
        } else {
            try out.appendSlice(self.alloc, "<- ");
            try out.appendSlice(self.alloc, name);
            if (value) |v| {
                try out.appendSlice(self.alloc, " = ");
                const s = try self.valueToString(v);
                try out.appendSlice(self.alloc, s);
            }
        }
        try out.append(self.alloc, '\n');
        const w = self.trace_out orelse return;
        try w.writeAll(out.items);
        try w.flush();
    }

    fn parseStatement(self: *Parser) anyerror!void {
        const stmt_line = self.line;
        const stmt_pos = self.pos;
        if (self.trace) try self.traceLine(stmt_line, self.src[stmt_pos..]);
        const kw_start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
        if (kw_start == self.pos) {
            if (!self.mute) std.debug.print("error on line {d}: expected statement\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        const kw = self.src[kw_start..self.pos];

        if (std.mem.eql(u8, kw, "fn")) {
            try self.parseFnDef();
            return;
        }
        if (std.mem.eql(u8, kw, "struct")) {
            try self.parseStructDef();
            return;
        }
        if (std.mem.eql(u8, kw, "switch")) {
            try self.parseSwitch();
            return;
        }
        if (std.mem.eql(u8, kw, "try")) {
            try self.parseTry();
            return;
        }
        if (std.mem.eql(u8, kw, "asm")) {
            // inline asm: runs as no-op in script mode, real code via --emit-c
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '(') {
                self.pos += 1;
                _ = try self.parseStringAlloc();
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return ParseError.ExpectedRParen;
                self.pos += 1;
            } else {
                _ = try self.parseStringAlloc();
            }
            try self.expectEndOfStatement();
            return;
        }
        if (std.mem.eql(u8, kw, "if")) {
            try self.parseIf();
            return;
        }
        if (std.mem.eql(u8, kw, "while")) {
            try self.parseWhile();
            return;
        }
        if (std.mem.eql(u8, kw, "for")) {
            try self.parseFor();
            return;
        }
        if (std.mem.eql(u8, kw, "import")) {
            self.skipSpaces();
            if (self.pos < self.src.len and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
                const rel = try self.parseStringAlloc();
                try self.expectEndOfStatement();
                try self.importFile(rel);
            } else {
                const mod = try self.parseIdent();
                try self.expectEndOfStatement();
                if (std.mem.eql(u8, mod, "os")) {
                    self.imported_os = true;
                } else if (std.mem.eql(u8, mod, "physics")) {
                    self.imported_physics = true;
                } else if (std.mem.eql(u8, mod, "json")) {
                    self.imported_json = true;
                } else if (std.mem.eql(u8, mod, "time")) {
                    self.imported_time = true;
                } else if (std.mem.eql(u8, mod, "heap")) {
                    self.imported_heap = true;
                } else if (std.mem.eql(u8, mod, "cpu")) {
                    self.imported_cpu = true;
                } else if (std.mem.eql(u8, mod, "strings")) {
                    self.imported_strings = true;
                } else if (std.mem.eql(u8, mod, "random")) {
                    self.imported_random = true;
                } else if (std.mem.eql(u8, mod, "hex")) {
                    self.imported_hex = true;
                } else if (std.mem.eql(u8, mod, "gui")) {
                    self.imported_gui = true;
                    if (self.gui_cbs == null) {
                        self.gui_cbs = self.alloc.create(std.ArrayList(Value)) catch return ParseError.OutOfMemory;
                        self.gui_cbs.?.* = .empty;
                    }
                } else {
                    if (!self.mute)                     std.debug.print("{s}:{d}: unknown module '{s}' (only 'os'/'physics'/'json'/'time'/'heap'/'cpu'/'hex'/'random'/'strings'/'gui' or \"file.c4h\")\n", .{ self.file, self.line, mod });
                    return ParseError.UnknownKeyword;
                }
            }
            return;
        }
        if (std.mem.eql(u8, kw, "else")) {
            if (!self.mute) std.debug.print("error on line {d}: 'else' without 'if'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, kw, "elif")) {
            if (!self.mute) std.debug.print("error on line {d}: 'elif' without 'if'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, kw, "break")) {
            try self.expectEndOfStatement();
            return ParseError.BreakSignal;
        }
        if (std.mem.eql(u8, kw, "continue")) {
            try self.expectEndOfStatement();
            return ParseError.ContinueSignal;
        }
        if (std.mem.eql(u8, kw, "return")) {
            self.skipSpaces();
            const v = try self.parseExpr();
            try self.expectEndOfStatement();
            self.return_value = v;
            return ParseError.ReturnSignal;
        }
        if (std.mem.eql(u8, kw, "let")) {
            self.skipSpaces();
            const name = try self.parseIdent();
            self.skipSpaces();
            if (self.pos >= self.src.len or self.src[self.pos] != '=') {
                if (!self.mute) std.debug.print("error on line {d}: expected '=' after let {s}\n", .{ self.line, name });
                return ParseError.ExpectedEquals;
            }
            self.pos += 1;
            const v = try self.parseExpr();
            try self.expectEndOfStatement();
            try self.scope.vars.put(try self.alloc.dupe(u8, name), v);
        } else if (std.mem.eql(u8, kw, "print") or std.mem.eql(u8, kw, "pt")) {
            self.skipSpaces();
            var v: Value = undefined;
            if (self.pos < self.src.len and self.src[self.pos] == '(') {
                self.pos += 1;
                v = try self.parseExpr();
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') {
                    if (!self.mute) std.debug.print("error on line {d}: expected ')'\n", .{self.line});
                    return ParseError.ExpectedRParen;
                }
                self.pos += 1;
            } else {
                v = try self.parseExpr();
            }
            try self.expectEndOfStatement();
            if (!self.dry and !self.silent_run) {
                try self.printValue(v);
                try self.stdout.writeAll("\n");
            }
        } else {
            // call stmt: name(...) / os.create(...)  OR  assign: name = expr,
            // name[i] = expr, name.field = expr (mixed chains ok)
            const name = kw;
            const save = self.pos;
            self.skipSpaces();
            const Seg = union(enum) { index: Value, field: []const u8 };
            var segs: std.ArrayList(Seg) = .empty;
            while (self.pos < self.src.len) {
                if (self.src[self.pos] == '[') {
                    self.pos += 1;
                    const ix = try self.parseExpr();
                    self.skipSpaces();
                    if (self.pos >= self.src.len or self.src[self.pos] != ']') return ParseError.ExpectedRBracket;
                    self.pos += 1;
                    try segs.append(self.alloc, .{ .index = ix });
                    self.skipSpaces();
                } else if (self.src[self.pos] == '.' and self.pos + 1 < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos + 1]) or self.src[self.pos + 1] == '_')) {
                    self.pos += 1;
                    const f = try self.parseIdent();
                    try segs.append(self.alloc, .{ .field = f });
                    self.skipSpaces();
                } else break;
            }
            if (self.pos < self.src.len and self.src[self.pos] == '(') {
                // bare call as statement (e.g. push(xs, 5)) — result discarded
                // rewind to start of name so parseExpr sees the full call
                self.pos = kw_start;
                _ = try self.parseExpr();
                try self.expectEndOfStatement();
                return;
            }
            if (self.pos < self.src.len and self.src[self.pos] == '=') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                    self.pos = save;
                    if (!self.mute) std.debug.print("error on line {d}: unknown keyword '{s}'\n", .{ self.line, kw });
                    return ParseError.UnknownKeyword;
                }
                self.pos += 1;
                const v = try self.parseExpr();
                try self.expectEndOfStatement();
                if (segs.items.len == 0) {
                    if (self.scopeOwner(name)) |owner| {
                        try owner.vars.put(try self.alloc.dupe(u8, name), v);
                    } else {
                        if (!self.mute) std.debug.print("error on line {d}: unknown variable '{s}' (use let first)\n", .{ self.line, name });
                        return ParseError.UnknownVariable;
                    }
                } else {
                    try self.assignPath(name, segs.items, v);
                }
            } else {
                self.pos = save;
                if (!self.mute) std.debug.print("error on line {d}: unknown keyword '{s}'\n", .{ self.line, kw });
                return ParseError.UnknownKeyword;
            }
        }
    }

    fn structFieldIndex(type_name: []const u8, fields: [][]const u8, field: []const u8) ?usize {
        _ = type_name;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f, field)) return i;
        }
        return null;
    }

    fn assignPath(self: *Parser, name: []const u8, segs: anytype, v: Value) !void {
        var root = self.scopeGet(name) orelse {
            if (!self.mute) std.debug.print("error on line {d}: unknown variable '{s}'\n", .{ self.line, name });
            return ParseError.UnknownVariable;
        };
        root = try self.assignInto(root, name, segs, 0, v);
        const owner = self.scopeOwner(name) orelse {
            if (!self.mute) std.debug.print("error on line {d}: unknown variable '{s}'\n", .{ self.line, name });
            return ParseError.UnknownVariable;
        };
        try owner.vars.put(try self.alloc.dupe(u8, name), root);
    }

    // recursive write-back assign; returns the (possibly new) container value
    fn assignInto(self: *Parser, cur: Value, name: []const u8, segs: anytype, si: usize, v: Value) !Value {
        const seg = segs[si];
        const last = si + 1 == segs.len;
        switch (seg) {
            .index => |ix| {
                if (cur == .list) {
                    if (last) {
                        const i = try self.normalizeIndex(cur.list.items.items.len, ix);
                        cur.list.items.items[i] = v;
                        return cur;
                    }
                    const i = try self.normalizeIndex(cur.list.items.items.len, ix);
                    const nv = try self.assignInto(cur.list.items.items[i], name, segs, si + 1, v);
                    cur.list.items.items[i] = nv;
                    return cur;
                } else if (cur == .dict) {
                    const key = try self.valueToString(ix);
                    if (last) {
                        try cur.dict.map.put(try self.alloc.dupe(u8, key), v);
                        return cur;
                    }
                    const child = cur.dict.map.get(key) orelse {
                        if (!self.mute) std.debug.print("error on line {d}: key '{s}' missing\n", .{ self.line, key });
                        return ParseError.KeyMissing;
                    };
                    const nv = try self.assignInto(child, name, segs, si + 1, v);
                    try cur.dict.map.put(try self.alloc.dupe(u8, key), nv);
                    return cur;
                } else if (cur == .string) {
                    const i = try self.normalizeIndex(cur.string.len, ix);
                    if (v != .string or v.string.len != 1) {
                        if (!self.mute) std.debug.print("error on line {d}: string assign needs 1 char\n", .{self.line});
                        return ParseError.TypeError;
                    }
                    const out = try self.alloc.dupe(u8, cur.string);
                    if (last) {
                        out[i] = v.string[0];
                        return Value{ .string = out };
                    }
                    const nv = try self.assignInto(Value{ .string = out[i .. i + 1] }, name, segs, si + 1, v);
                    if (nv != .string or nv.string.len != 1) return ParseError.TypeError;
                    out[i] = nv.string[0];
                    return Value{ .string = out };
                } else if (cur == .instance) {
                    if (!self.mute) std.debug.print("error on line {d}: cannot index a struct (use .field)\n", .{self.line});
                    return ParseError.NotIndexable;
                } else {
                    if (!self.mute) std.debug.print("error on line {d}: '{s}' is not indexable\n", .{ self.line, name });
                    return ParseError.NotIndexable;
                }
            },
            .field => |f| {
                if (cur != .instance) {
                    if (!self.mute) std.debug.print("error on line {d}: '{s}' has no fields\n", .{ self.line, name });
                    return ParseError.TypeError;
                }
                const fi = structFieldIndex(cur.instance.type_name, cur.instance.fields, f) orelse {
                    if (!self.mute) std.debug.print("error on line {d}: no field '{s}'\n", .{ self.line, f });
                    return ParseError.UnknownVariable;
                };
                if (last) {
                    cur.instance.values.items[fi] = v;
                    return cur;
                }
                const nv = try self.assignInto(cur.instance.values.items[fi], name, segs, si + 1, v);
                cur.instance.values.items[fi] = nv;
                return cur;
            },
        }
    }

    fn assignIndexed(self: *Parser, name: []const u8, indices: []const Value, v: Value) !void {
        var base = self.scopeGet(name) orelse {
            if (!self.mute) std.debug.print("error on line {d}: unknown variable '{s}'\n", .{ self.line, name });
            return ParseError.UnknownVariable;
        };
        // walk to parent of target
        for (indices[0 .. indices.len - 1]) |ix| {
            if (base == .list) {
                const i = try self.normalizeIndex(base.list.items.items.len, ix);
                base = base.list.items.items[i];
            } else if (base == .dict) {
                const key = try self.valueToString(ix);
                base = base.dict.map.get(key) orelse {
                    if (!self.mute) std.debug.print("error on line {d}: key '{s}' missing\n", .{ self.line, key });
                    return ParseError.KeyMissing;
                };
            } else return ParseError.NotIndexable;
        }
        if (base == .list) {
            const last = try self.normalizeIndex(base.list.items.items.len, indices[indices.len - 1]);
            base.list.items.items[last] = v;
        } else if (base == .dict) {
            const key = try self.valueToString(indices[indices.len - 1]);
            try base.dict.map.put(try self.alloc.dupe(u8, key), v);
        } else {
            if (!self.mute) std.debug.print("error on line {d}: '{s}' is not indexable\n", .{ self.line, name });
            return ParseError.NotIndexable;
        }
    }

    fn normalizeIndex(self: *Parser, len: usize, ix: Value) !usize {
        if (ix != .number) {
            if (!self.mute) std.debug.print("error on line {d}: index must be a number\n", .{self.line});
            return ParseError.TypeError;
        }
        const n = ix.number;
        if (@trunc(n) != n) {
            if (!self.mute) std.debug.print("error on line {d}: index must be an integer\n", .{self.line});
            return ParseError.TypeError;
        }
        var i: i64 = @intFromFloat(n);
        if (i < 0) i += @intCast(len); // negative = from end
        if (i < 0 or i >= @as(i64, @intCast(len))) {
            if (!self.mute) std.debug.print("error on line {d}: index {d} out of bounds (len {d})\n", .{ self.line, @as(i64, @intFromFloat(n)), len });
            return ParseError.IndexOutOfBounds;
        }
        return @intCast(i);
    }

    fn parseIf(self: *Parser) anyerror!void {
        self.skipSpaces();
        const first_start = self.pos;
        _ = try self.parseExpr();
        const first_end = self.pos;
        const first_src = self.src[first_start..first_end];
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after if condition\n", .{self.line});
            return ParseError.ExpectedLBrace;
        }
        const body_line = self.line;
        const then_body = try self.captureBlock();
        // elif chain (lazy conds so side effects only run for reached branches)
        var elif_srcs: std.ArrayList([]const u8) = .empty;
        var elif_bodies: std.ArrayList([]const u8) = .empty;
        var elif_lines: std.ArrayList(usize) = .empty;
        while (true) {
            var tmp_pos = self.pos;
            var tmp_line = self.line;
            while (tmp_pos < self.src.len and (self.src[tmp_pos] == ' ' or self.src[tmp_pos] == '\t' or self.src[tmp_pos] == '\r' or self.src[tmp_pos] == '\n')) {
                if (self.src[tmp_pos] == '\n') tmp_line += 1;
                tmp_pos += 1;
            }
            if (tmp_pos < self.src.len and self.matchWordAt(tmp_pos, "elif")) {
                self.pos = tmp_pos + 4;
                self.line = tmp_line;
                self.skipSpaces();
                const cs = self.pos;
                _ = try self.parseExpr();
                const ce = self.pos;
                try elif_srcs.append(self.alloc, self.src[cs..ce]);
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != '{') {
                    if (!self.mute) std.debug.print("error on line {d}: expected '{{' after elif condition\n", .{self.line});
                    return ParseError.ExpectedLBrace;
                }
                const bl = self.line;
                const bb = try self.captureBlock();
                try elif_bodies.append(self.alloc, bb);
                try elif_lines.append(self.alloc, bl);
            } else break;
        }
        const after_then = self.pos;
        const after_line = self.line;
        self.skipSpaces();
        var tmp_pos = self.pos;
        var tmp_line = self.line;
        while (tmp_pos < self.src.len and (self.src[tmp_pos] == ' ' or self.src[tmp_pos] == '\t' or self.src[tmp_pos] == '\r' or self.src[tmp_pos] == '\n')) {
            if (self.src[tmp_pos] == '\n') tmp_line += 1;
            tmp_pos += 1;
        }
        var has_else = false;
        var else_body: []const u8 = "";
        var else_line: usize = tmp_line;
        if (tmp_pos < self.src.len and self.matchWordAt(tmp_pos, "else")) {
            self.pos = tmp_pos + 4;
            self.line = tmp_line;
            self.skipSpaces();
            if (self.pos >= self.src.len or self.src[self.pos] != '{') {
                if (!self.mute) std.debug.print("error on line {d}: expected '{{' after else\n", .{self.line});
                return ParseError.ExpectedLBrace;
            }
            else_line = self.line;
            else_body = try self.captureBlock();
            has_else = true;
        } else {
            self.pos = after_then;
            self.line = after_line;
        }
        try self.expectEndOfStatement();
        if (isTruthy(try self.evalCondSrc(first_src))) {
            try self.runBodyShared(then_body, body_line);
            return;
        }
        for (elif_srcs.items, 0..) |esrc, i| {
            if (isTruthy(try self.evalCondSrc(esrc))) {
                try self.runBodyShared(elif_bodies.items[i], elif_lines.items[i]);
                return;
            }
        }
        if (has_else) {
            try self.runBodyShared(else_body, else_line);
        }
    }

    fn parseWhile(self: *Parser) anyerror!void {
        self.skipSpaces();
        const cond_start = self.pos;
        const first = try self.parseExpr();
        _ = first;
        const cond_end = self.pos;
        const cond_src = self.src[cond_start..cond_end];
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after while condition\n", .{self.line});
            return ParseError.ExpectedLBrace;
        }
        const body_line = self.line;
        const body = try self.captureBlock();
        try self.expectEndOfStatement();
        var iters: usize = 0;
        while (true) {
            const c = try self.evalCondSrc(cond_src);
            if (!isTruthy(c)) break;
            self.runBodyShared(body, body_line) catch |err| {
                if (err == ParseError.BreakSignal) break;
                if (err == ParseError.ContinueSignal) {
                    iters += 1;
                    if (iters > 1000000) return ParseError.LoopLimitExceeded;
                    continue;
                }
                return err;
            };
            iters += 1;
            if (iters > 1000000) return ParseError.LoopLimitExceeded;
        }
    }

    fn parseFor(self: *Parser) anyerror!void {
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
        if (!self.matchWordAt(self.pos, "in")) {
            if (!self.mute) std.debug.print("error on line {d}: expected 'in' after for {s}\n", .{ self.line, loopvar });
            return ParseError.ExpectedIn;
        }
        self.pos += 2;
        self.skipSpaces();
        const coll = try self.parseExpr();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after for\n", .{self.line});
            return ParseError.ExpectedLBrace;
        }
        const body_line = self.line;
        const body = try self.captureBlock();
        try self.expectEndOfStatement();
        const var1 = try self.alloc.dupe(u8, loopvar);
        const var2 = if (loopvar2) |lv| try self.alloc.dupe(u8, lv) else null;
        switch (coll) {
            .list => |l| {
                const items = l.items.items;
                const n = items.len;
                var k: usize = 0;
                while (k < n) {
                    if (var2) |v2| {
                        try self.scope.vars.put(var1, Value{ .number = @floatFromInt(k) });
                        try self.scope.vars.put(v2, items[k]);
                    } else {
                        try self.scope.vars.put(var1, items[k]);
                    }
                    self.runBodyShared(body, body_line) catch |err| {
                        if (err == ParseError.BreakSignal) break;
                        if (err == ParseError.ContinueSignal) {
                            k += 1;
                            continue;
                        }
                        return err;
                    };
                    k += 1;
                }
            },
            .dict => |d| {
                var keylist: std.ArrayList([]const u8) = .empty;
                var kit = d.map.iterator();
                while (kit.next()) |e| {
                    try keylist.append(self.alloc, e.key_ptr.*);
                }
                for (keylist.items) |key| {
                    if (var2) |v2| {
                        try self.scope.vars.put(v2, d.map.get(key) orelse Value{ .nil = {} });
                        try self.scope.vars.put(var1, Value{ .string = key });
                    } else {
                        try self.scope.vars.put(var1, Value{ .string = key });
                    }
                    self.runBodyShared(body, body_line) catch |err| {
                        if (err == ParseError.BreakSignal) break;
                        if (err == ParseError.ContinueSignal) continue;
                        return err;
                    };
                }
            },
            .string => |s| {
                var k: usize = 0;
                while (k < s.len) {
                    const ch = try self.alloc.dupe(u8, s[k .. k + 1]);
                    if (var2) |v2| {
                        try self.scope.vars.put(var1, Value{ .number = @floatFromInt(k) });
                        try self.scope.vars.put(v2, Value{ .string = ch });
                    } else {
                        try self.scope.vars.put(var1, Value{ .string = ch });
                    }
                    self.runBodyShared(body, body_line) catch |err| {
                        if (err == ParseError.BreakSignal) break;
                        if (err == ParseError.ContinueSignal) {
                            k += 1;
                            continue;
                        }
                        return err;
                    };
                    k += 1;
                }
            },
            else => {
                if (!self.mute) std.debug.print("error on line {d}: 'for' needs a list/dict/string\n", .{self.line});
                return ParseError.TypeError;
            },
        }
    }

    fn asmStem(rel: []const u8) []const u8 {
        var s = rel;
        var i = s.len;
        while (i > 0 and s[i - 1] != '/' and s[i - 1] != '\\') : (i -= 1) {}
        s = s[i..];
        if (std.mem.endsWith(u8, s, ".c4asm")) s = s[0 .. s.len - 6];
        return s;
    }

    const AsmProg = struct {
        sim: bool,
        code: *ListObj,
        labels: std.StringHashMap(usize),
        entry: usize,
        raw: [][]const u8,
    };

    fn asmFail(self: *Parser, file: []const u8, line: usize, comptime fmt: []const u8, args: anytype) ParseError {
        _ = self;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "asm error";
        std.debug.print("{s}:{d}: asm: {s}\n", .{ file, line, msg });
        return ParseError.UnexpectedEof;
    }

    fn asmInt(tok: []const u8) !i64 {
        if (tok.len == 0) return ParseError.BadNumber;
        var neg = false;
        var t = tok;
        if (t[0] == '-') {
            neg = true;
            t = t[1..];
            if (t.len == 0) return ParseError.BadNumber;
        }
        var v: i64 = 0;
        if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
            if (t.len == 2) return ParseError.BadNumber;
            for (t[2..]) |ch| {
                var d: i64 = -1;
                if (ch >= '0' and ch <= '9') d = ch - '0';
                if (ch >= 'a' and ch <= 'f') d = ch - 'a' + 10;
                if (ch >= 'A' and ch <= 'F') d = ch - 'A' + 10;
                if (d < 0) return ParseError.BadNumber;
                v = v * 16 + d;
            }
        } else {
            for (t) |ch| {
                if (ch < '0' or ch > '9') return ParseError.BadNumber;
                v = v * 10 + (ch - '0');
            }
        }
        if (neg) v = -v;
        return v;
    }

    fn asmReg(tok: []const u8) ?f64 {
        if (tok.len == 2 and tok[0] == 'r' and tok[1] >= '0' and tok[1] <= '7') {
            return @floatFromInt(tok[1] - '0');
        }
        return null;
    }

    fn parseAsm(self: *Parser, src: []const u8, file: []const u8) !AsmProg {
        var lineno: usize = 0;
        var target: ?bool = null;
        const code = try self.alloc.create(ListObj);
        code.* = .{ .items = .empty };
        var labels = std.StringHashMap(usize).init(self.alloc);
        var raw: std.ArrayList([]const u8) = .empty;
        var entry_name: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, src, '\n');
        var items: std.ArrayList(struct { line: usize, text: []const u8 }) = .empty;
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
                return self.asmFail(file, lineno, "first line must be '#target sim' or '#target x86-64'", .{});
            }
            if (line[0] == '#') continue;
            try items.append(self.alloc, .{ .line = lineno, .text = line });
        }
        if (target == null) return self.asmFail(file, 1, "missing '#target' line", .{});
        const sim = target.?;
        var addr: usize = 0;
        var prog_lines: std.ArrayList(struct { line: usize, text: []const u8 }) = .empty;
        for (items.items) |it2| {
            var text = it2.text;
            if (std.mem.indexOfScalar(u8, text, ':')) |ci| {
                const lbl = text[0..ci];
                var ok = lbl.len > 0;
                for (lbl) |ch| {
                    if (!std.ascii.isAlphanumeric(ch) and ch != '_') ok = false;
                }
                if (ok) {
                    if (labels.contains(lbl)) return self.asmFail(file, it2.line, "dup label '{s}'", .{lbl});
                    if (!sim and std.mem.eql(u8, lbl, "main")) return self.asmFail(file, it2.line, "label 'main' is reserved", .{});
                    try labels.put(try self.alloc.dupe(u8, lbl), addr);
                    text = text[ci + 1 ..];
                    var s2: usize = 0;
                    while (s2 < text.len and (text[s2] == ' ' or text[s2] == '\t')) : (s2 += 1) {}
                    text = text[s2..];
                    if (text.len == 0) continue;
                }
            }
            if (std.mem.eql(u8, text, ".entry")) return self.asmFail(file, it2.line, ".entry needs a label", .{});
            if (std.mem.startsWith(u8, text, ".entry ")) {
                var rest = text[".entry ".len..];
                while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) : (rest = rest[1..]) {}
                entry_name = rest;
                continue;
            }
            try prog_lines.append(self.alloc, .{ .line = it2.line, .text = text });
            addr += 1;
            if (!sim) {
                var mw: usize = 0;
                while (mw < text.len and text[mw] != ' ' and text[mw] != '\t') : (mw += 1) {}
                const mnem = text[0..mw];
                if (std.mem.eql(u8, mnem, "ret") or std.mem.eql(u8, mnem, "retq") or std.mem.eql(u8, mnem, "retn")) {
                    return self.asmFail(file, it2.line, "ret not allowed in x86-64 .c4asm (wrapper returns)", .{});
                }
                try raw.append(self.alloc, text);
            }
        }
        var entry: usize = 0;
        if (entry_name) |en| {
            entry = labels.get(en) orelse return self.asmFail(file, lineno, "unknown .entry '{s}'", .{en});
        }
        if (!sim) {
            return .{ .sim = false, .code = code, .labels = labels, .entry = entry, .raw = try raw.toOwnedSlice(self.alloc) };
        }
        for (prog_lines.items) |pl| {
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
            var a: f64 = 0;
            var b: f64 = 0;
            const expect: usize = if (std.mem.eql(u8, op, "halt") or std.mem.eql(u8, op, "nop")) 0 else if (std.mem.eql(u8, op, "jmp")) 1 else 2;
            if (ops.len != expect) return self.asmFail(file, pl.line, "'{s}' needs {d} operands", .{ op, expect });
            if (std.mem.eql(u8, op, "jmp")) {
                if (labels.get(ops[0])) |ad| {
                    a = @floatFromInt(ad);
                } else {
                    const iv = asmInt(ops[0]) catch return self.asmFail(file, pl.line, "bad target '{s}'", .{ops[0]});
                    a = @floatFromInt(iv);
                }
            } else if (std.mem.eql(u8, op, "jz")) {
                if (asmReg(ops[0])) |r| {
                    a = r;
                } else return self.asmFail(file, pl.line, "bad reg '{s}'", .{ops[0]});
                if (labels.get(ops[1])) |ad| {
                    b = @floatFromInt(ad);
                } else {
                    const iv = asmInt(ops[1]) catch return self.asmFail(file, pl.line, "bad target '{s}'", .{ops[1]});
                    b = @floatFromInt(iv);
                }
            } else if (expect == 2) {
                if (asmReg(ops[0])) |r| {
                    a = r;
                } else return self.asmFail(file, pl.line, "bad reg '{s}'", .{ops[0]});
                if (std.mem.eql(u8, op, "li")) {
                    const iv = asmInt(ops[1]) catch return self.asmFail(file, pl.line, "bad imm '{s}'", .{ops[1]});
                    b = @floatFromInt(iv);
                } else if (std.mem.eql(u8, op, "lw") or std.mem.eql(u8, op, "sw")) {
                    const iv = asmInt(ops[1]) catch return self.asmFail(file, pl.line, "bad addr '{s}'", .{ops[1]});
                    b = @floatFromInt(iv);
                } else if (std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "or") or std.mem.eql(u8, op, "xor") or std.mem.eql(u8, op, "shl") or std.mem.eql(u8, op, "shr")) {
                    if (asmReg(ops[1])) |r| {
                        b = r;
                    } else return self.asmFail(file, pl.line, "bad reg '{s}'", .{ops[1]});
                } else return self.asmFail(file, pl.line, "bad sim op '{s}'", .{op});
            } else if (!(std.mem.eql(u8, op, "halt") or std.mem.eql(u8, op, "nop"))) {
                return self.asmFail(file, pl.line, "bad sim op '{s}'", .{op});
            }
            const ins = try self.alloc.create(ListObj);
            ins.* = .{ .items = .empty };
            try ins.items.append(self.alloc, Value{ .string = try self.alloc.dupe(u8, op) });
            try ins.items.append(self.alloc, Value{ .number = a });
            try ins.items.append(self.alloc, Value{ .number = b });
            try code.items.append(self.alloc, Value{ .list = ins });
        }
        return .{ .sim = true, .code = code, .labels = labels, .entry = entry, .raw = &.{} };
    }

    fn importAsm(self: *Parser, rel: []const u8) !void {
        const registry = self.imported_files orelse return;
        const key = try std.mem.concat(self.alloc, u8, &.{ self.file, "|", rel });
        if (registry.contains(key)) return;
        const src = self.base_dir.readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch
            std.Io.Dir.cwd().readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch {
            if (!self.mute) std.debug.print("{s}:{d}: cannot import '{s}'\n", .{ self.file, self.line, rel });
            return ParseError.UnexpectedEof;
        };
        const prog = try self.parseAsm(src, rel);
        try registry.put(key, true);
        const stem = try self.alloc.dupe(u8, asmStem(rel));
        if (!prog.sim) {
            if (self.dry) {
                // validate only: stub callable so check passes
                const noparams = try self.alloc.alloc([]const u8, 0);
                try self.funcs.put(stem, Function{ .name = stem, .params = noparams, .body = "", .def_line = self.line, .scope = null });
                return;
            }
            if (!self.mute) std.debug.print("{s}:{d}: x86-64 asm '{s}' needs --emit-c\n", .{ self.file, self.line, rel });
            return ParseError.UnknownKeyword;
        }
        const lmap = try self.alloc.create(DictObj);
        lmap.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
        var lit = prog.labels.iterator();
        while (lit.next()) |e| {
            try lmap.map.put(e.key_ptr.*, Value{ .number = @floatFromInt(e.value_ptr.*) });
        }
        const pd = try self.alloc.create(DictObj);
        pd.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
        try pd.map.put(try self.alloc.dupe(u8, "code"), Value{ .list = prog.code });
        try pd.map.put(try self.alloc.dupe(u8, "labels"), Value{ .dict = lmap });
        try pd.map.put(try self.alloc.dupe(u8, "entry"), Value{ .number = @floatFromInt(prog.entry) });
        try self.scope.vars.put(stem, Value{ .dict = pd });
    }


    fn importFile(self: *Parser, rel: []const u8) !void {
        if (std.mem.endsWith(u8, rel, ".c4asm")) {
            try self.importAsm(rel);
            return;
        }        const registry = self.imported_files orelse return;
        // normalize key: base + rel (display path for errors)
        const key = try std.mem.concat(self.alloc, u8, &.{ self.file, "|", rel });
        if (registry.contains(key)) return; // once-guard
        // resolve: try importing file's dir first, then cwd
        var src: []u8 = undefined;
        if (self.base_dir.readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024))) |s| {
            src = s;
        } else |_| {
            src = std.Io.Dir.cwd().readFileAlloc(self.io, rel, self.alloc, .limited(4 * 1024 * 1024)) catch {
                if (!self.mute) std.debug.print("{s}:{d}: cannot import '{s}'\n", .{ self.file, self.line, rel });
                return ParseError.UnexpectedEof;
            };
        }
        try registry.put(key, true);
        const was_os = self.imported_os;
        const was_physics = self.imported_physics;
        var sub = Parser{
            .src = src,
            .pos = 0,
            .line = 1,
            .alloc = self.alloc,
            .stdout = self.stdout,
            .funcs = self.funcs,
            .structs = self.structs,
            .scope = self.scope,
            .io = self.io,
            .stdin = self.stdin,
            .imported_os = self.imported_os,
            .imported_physics = self.imported_physics,
            .imported_heap = self.imported_heap,
            .imported_gui = self.imported_gui,
            .imported_hex = self.imported_hex,
            .imported_random = self.imported_random,
            .imported_strings = self.imported_strings,
            .gui_cbs = self.gui_cbs,
            .imported_cpu = self.imported_cpu,
            .envmap = self.envmap,
            .imported_json = self.imported_json,
            .imported_time = self.imported_time,
            .cli_args = self.cli_args,
            .file = rel,
            .base_dir = self.base_dir,
            .imported_files = self.imported_files,
            .err = self.err,
            .dry = self.dry,
            .mute = self.mute,
            .silent_run = self.silent_run,
            .trace = self.trace,
            .trace_indent = self.trace_indent,
            .trace_out = self.trace_out,
            .depth = self.depth + 1,
        };
        sub.run() catch |err| {
            if (err == ParseError.ReturnSignal) {
                if (!self.mute) std.debug.print("{s}: 'return' at header top level\n", .{rel});
                return err;
            }
            return err;
        };
        if (sub.imported_os) self.imported_os = was_os or sub.imported_os;
        if (sub.imported_physics) self.imported_physics = was_physics or sub.imported_physics;
        if (sub.imported_heap) self.imported_heap = sub.imported_heap or self.imported_heap;
        if (sub.imported_cpu) self.imported_cpu = sub.imported_cpu or self.imported_cpu;
        if (sub.imported_json) self.imported_json = sub.imported_json or self.imported_json;
        if (sub.imported_time) self.imported_time = sub.imported_time or self.imported_time;
        if (sub.imported_gui) self.imported_gui = sub.imported_gui or self.imported_gui;
        if (sub.imported_hex) self.imported_hex = sub.imported_hex or self.imported_hex;
        if (sub.imported_random) self.imported_random = sub.imported_random or self.imported_random;
        if (sub.imported_strings) self.imported_strings = sub.imported_strings or self.imported_strings;
    }

    fn parseStructDef(self: *Parser) anyerror!void {
        self.skipSpaces();
        const name = try self.parseIdent();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after struct {s}\n", .{ self.line, name });
            return ParseError.ExpectedLBrace;
        }
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
                continue; // newline separates fields; loop top skips it
            } else {
                if (!self.mute) std.debug.print("error on line {d}: expected ',' or '}}' in struct\n", .{self.line});
                return ParseError.ExpectedRBrace;
            }
        }
        try self.expectEndOfStatement();
        const owned = try fields.toOwnedSlice(self.alloc);
        const name_dup = try self.alloc.dupe(u8, name);
        try self.structs.put(name_dup, StructDef{ .name = name_dup, .fields = owned });
    }

    fn parseTry(self: *Parser) anyerror!void {
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after try\n", .{self.line});
            return ParseError.ExpectedLBrace;
        }
        const try_line = self.line;
        const try_body = try self.captureBlock();
        var tmp_pos = self.pos;
        var tmp_line = self.line;
        while (tmp_pos < self.src.len and (self.src[tmp_pos] == ' ' or self.src[tmp_pos] == '\t' or self.src[tmp_pos] == '\r' or self.src[tmp_pos] == '\n')) {
            if (self.src[tmp_pos] == '\n') tmp_line += 1;
            tmp_pos += 1;
        }
        if (tmp_pos >= self.src.len or !self.matchWordAt(tmp_pos, "catch")) {
            if (!self.mute) std.debug.print("error on line {d}: expected 'catch e' after try block\n", .{self.line});
            return ParseError.ExpectedCatch;
        }
        self.pos = tmp_pos + 5;
        self.line = tmp_line;
        self.skipSpaces();
        const bindvar = try self.parseIdent();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after catch {s}\n", .{ self.line, bindvar });
            return ParseError.ExpectedLBrace;
        }
        const catch_line = self.line;
        const catch_body = try self.captureBlock();
        try self.expectEndOfStatement();
        const was_mute = self.mute;
        self.mute = true;
        self.runBodyShared(try_body, try_line) catch |err| {
            self.mute = was_mute;
            if (err == ParseError.ReturnSignal or err == ParseError.BreakSignal or err == ParseError.ContinueSignal or err == ParseError.ExitSignal) {
                return err;
            }
            if (err == error.OutOfMemory) return err;
            var msg: []const u8 = undefined;
            if (err == ParseError.FailSignal) {
                if (self.err) |e| {
                    msg = e.fail_msg orelse "fail";
                    e.fail_msg = null;
                } else msg = "fail";
            } else {
                msg = @errorName(err);
            }
            try self.scope.vars.put(try self.alloc.dupe(u8, bindvar), Value{ .string = try self.alloc.dupe(u8, msg) });
            try self.runBodyShared(catch_body, catch_line);
            return;
        };
        self.mute = was_mute;
    }

    fn parseSwitch(self: *Parser) anyerror!void {
        self.skipSpaces();
        const subj = try self.parseExpr();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' after switch value\n", .{self.line});
            return ParseError.ExpectedLBrace;
        }
        const body_line = self.line;
        const body = try self.captureBlock();
        try self.expectEndOfStatement();
        // run arms in a shared-scope sub-parser over a small program we
        // interpret here: parse arms lazily from the captured body
        var arms = Parser{
            .src = body,
            .pos = 0,
            .line = body_line,
            .alloc = self.alloc,
            .stdout = self.stdout,
            .funcs = self.funcs,
            .structs = self.structs,
            .scope = self.scope,
            .io = self.io,
            .stdin = self.stdin,
            .imported_os = self.imported_os,
            .imported_physics = self.imported_physics,
            .imported_heap = self.imported_heap,
            .imported_gui = self.imported_gui,
            .imported_hex = self.imported_hex,
            .imported_random = self.imported_random,
            .imported_strings = self.imported_strings,
            .gui_cbs = self.gui_cbs,
            .imported_cpu = self.imported_cpu,
            .envmap = self.envmap,
            .imported_json = self.imported_json,
            .imported_time = self.imported_time,
            .cli_args = self.cli_args,
            .file = self.file,
            .base_dir = self.base_dir,
            .imported_files = self.imported_files,
            .err = self.err,
            .dry = self.dry,
            .mute = self.mute,
            .silent_run = self.silent_run,
            .trace = self.trace,
            .trace_indent = self.trace_indent,
            .trace_out = self.trace_out,
            .depth = self.depth + 1,
        };
        var matched = false;
        while (true) {
            arms.skipListWs();
            if (arms.pos >= arms.src.len) break;
            if (arms.matchWordAt(arms.pos, "else")) {
                arms.pos += 4;
                arms.skipSpaces();
                if (arms.pos >= arms.src.len or arms.src[arms.pos] != '{') return ParseError.ExpectedLBrace;
            const bl = arms.line;
            const bb = try arms.captureBlock();
            if (!matched) try self.runBodyShared(bb, bl);
            break;
            }
            // case values: expr (, expr)* then block (evaluated once, in order)
            var case_vals: std.ArrayList(Value) = .empty;
            while (true) {
                arms.skipSpaces();
                const cv = try arms.parseExpr();
                try case_vals.append(self.alloc, cv);
                arms.skipSpaces();
                if (arms.pos < arms.src.len and arms.src[arms.pos] == ',') {
                    arms.pos += 1;
                    continue;
                } else break;
            }
            arms.skipSpaces();
            if (arms.pos >= arms.src.len or arms.src[arms.pos] != '{') {
                if (!self.mute) std.debug.print("error on line {d}: expected '{{' for switch case\n", .{arms.line});
                return ParseError.ExpectedLBrace;
            }
            const bl = arms.line;
            const bb = try arms.captureBlock();
            if (!matched) {
                for (case_vals.items) |cv| {
                    if (try self.valuesEqual(subj, cv)) {
                        matched = true;
                        break;
                    }
                }
                if (matched) try self.runBodyShared(bb, bl);
            }
        }
        if (arms.imported_os) self.imported_os = arms.imported_os;
    }

    fn parseFnDef(self: *Parser) anyerror!void {
        self.skipSpaces();
        const name = try self.parseIdent();
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '(') {
            if (!self.mute) std.debug.print("error on line {d}: expected '(' after fn {s}\n", .{ self.line, name });
            return ParseError.ExpectedLParen;
        }
        self.pos += 1;
        var params_list: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            const p = try self.parseIdent();
            try params_list.append(self.alloc, p);
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            } else {
                if (!self.mute) std.debug.print("error on line {d}: expected ',' or ')' in param list\n", .{self.line});
                return ParseError.ExpectedRParen;
            }
        }
        self.skipSpaces();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') {
            if (!self.mute) std.debug.print("error on line {d}: expected '{{' for fn body\n", .{self.line});
            return ParseError.ExpectedLBrace;
        }
        const def_line = self.line;
        const body = try self.captureBlock();
        try self.expectEndOfStatement();
        const params = try params_list.toOwnedSlice(self.alloc);
        const name_dup = try self.alloc.dupe(u8, name);
        try self.funcs.put(name_dup, Function{ .name = name_dup, .params = params, .body = body, .def_line = def_line, .scope = self.scope });
    }

    fn captureBlock(self: *Parser) ![]const u8 {
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
                    const body = self.src[start..i];
                    self.pos = i + 1;
                    return body;
                }
            }
            if (c == '\n') self.line += 1;
            i += 1;
        }
        if (!self.mute) std.debug.print("error: unterminated '{{' for block\n", .{});
        return ParseError.ExpectedRBrace;
    }

    fn callModuleMethod(self: *Parser, module: []const u8, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (std.mem.eql(u8, module, "physics")) {
            return try self.callPhysicsMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "json")) {
            return try self.callJsonMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "time")) {
            return try self.callTimeMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "heap")) {
            return try self.callHeapMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "cpu")) {
            return try self.callCpuMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "gui")) {
            return try self.callGuiMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "hex")) {
            return try self.callHexMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "random")) {
            return try self.callRandomMethod(method, arg_vals);
        }
        if (std.mem.eql(u8, module, "strings")) {
            return try self.callStringsMethod(method, arg_vals);
        }
        if (!std.mem.eql(u8, module, "os")) {
            if (!self.mute) std.debug.print("error on line {d}: unknown module '{s}'\n", .{ self.line, module });
            return ParseError.UnknownKeyword;
        }
        if (!self.imported_os) {
            if (!self.mute) std.debug.print("error on line {d}: 'os' used without 'import os'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "create")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const path = try self.valueToString(arg_vals[0]);
            const data = try self.valueToString(arg_vals[1]);
            if (self.dry) return Value{ .number = 1 };
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.create failed for '{s}'\n", .{ self.line, path });
                return ParseError.WriteFailed;
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "read")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, "") };
            const path = try self.valueToString(arg_vals[0]);
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(8 * 1024 * 1024)) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.read failed for '{s}'\n", .{ self.line, path });
                return ParseError.UnexpectedEof;
            };
            return Value{ .string = data };
        }
        if (std.mem.eql(u8, method, "append")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 1 };
            const path = try self.valueToString(arg_vals[0]);
            const data = try self.valueToString(arg_vals[1]);
            const old = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(8 * 1024 * 1024)) catch "";
            const out = try std.mem.concat(self.alloc, u8, &.{ old, data });
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out }) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.append failed for '{s}'\n", .{ self.line, path });
                return ParseError.WriteFailed;
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "exists")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 1 };
            const path = try self.valueToString(arg_vals[0]);
            _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch {
                return Value{ .number = 0 };
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "remove")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 1 };
            const path = try self.valueToString(arg_vals[0]);
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.remove failed for '{s}'\n", .{ self.line, path });
                return ParseError.UnexpectedEof;
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "edit")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 1 };
            const path = try self.valueToString(arg_vals[0]);
            const old_s = try self.valueToString(arg_vals[1]);
            const new_s = try self.valueToString(arg_vals[2]);
            const content = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(8 * 1024 * 1024)) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.edit failed to read '{s}'\n", .{ self.line, path });
                return ParseError.UnexpectedEof;
            };
            var buf: std.ArrayList(u8) = .empty;
            if (old_s.len == 0) {
                try buf.appendSlice(self.alloc, content);
            } else {
                var rest = content;
                while (std.mem.indexOf(u8, rest, old_s)) |idx| {
                    try buf.appendSlice(self.alloc, rest[0..idx]);
                    try buf.appendSlice(self.alloc, new_s);
                    rest = rest[idx + old_s.len ..];
                }
                try buf.appendSlice(self.alloc, rest);
            }
            const out = try buf.toOwnedSlice(self.alloc);
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out }) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.edit failed to write '{s}'\n", .{ self.line, path });
                return ParseError.WriteFailed;
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "readbytes")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (self.dry) {
                const empty = try self.alloc.create(ListObj);
                empty.* = .{ .items = .empty };
                return Value{ .list = empty };
            }
            const path = try self.valueToString(arg_vals[0]);
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(8 * 1024 * 1024)) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.readbytes failed for '{s}'\n", .{ self.line, path });
                return ParseError.UnexpectedEof;
            };
            const obj = try self.alloc.create(ListObj);
            obj.* = .{ .items = .empty };
            for (data) |b| {
                try obj.items.append(self.alloc, Value{ .number = @floatFromInt(b) });
            }
            return Value{ .list = obj };
        }
        if (std.mem.eql(u8, method, "writebytes")) {            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 1 };
            const path = try self.valueToString(arg_vals[0]);
            if (arg_vals[1] != .list) return ParseError.TypeError;
            var buf: std.ArrayList(u8) = .empty;
            for (arg_vals[1].list.items.items) |item| {
                if (item != .number or @trunc(item.number) != item.number or item.number < 0 or item.number > 255) {
                    if (!self.mute) std.debug.print("error on line {d}: writebytes needs bytes 0..255\n", .{self.line});
                    return ParseError.TypeError;
                }
                try buf.append(self.alloc, @intFromFloat(item.number));
            }
            const out = try buf.toOwnedSlice(self.alloc);
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out }) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.writebytes failed for '{s}'\n", .{ self.line, path });
                return ParseError.WriteFailed;
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "cwd")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, ".") };
            const p = std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.alloc) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.cwd() failed\n", .{self.line});
                return ParseError.UnexpectedEof;
            };
            return Value{ .string = p };
        }
        if (std.mem.eql(u8, method, "env")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const key = try self.valueToString(arg_vals[0]);
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, "") };
            if (self.envmap) |em| {
                if (em.get(key)) |val| return Value{ .string = try self.alloc.dupe(u8, val) };
            }
            return Value{ .string = try self.alloc.dupe(u8, "") };
        }
        if (std.mem.eql(u8, method, "listdir")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const path = try self.valueToString(arg_vals[0]);
            if (self.dry) {
                const empty = try self.alloc.create(ListObj);
                empty.* = .{ .items = .empty };
                return Value{ .list = empty };
            }
            var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.listdir failed for '{s}'\n", .{ self.line, path });
                return ParseError.UnexpectedEof;
            };
            var it = dir.iterate();
            const obj = try self.alloc.create(ListObj);
            obj.* = .{ .items = .empty };
            while (it.next(self.io) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.listdir failed for '{s}'\n", .{ self.line, path });
                return ParseError.UnexpectedEof;
            }) |entry| {
                try obj.items.append(self.alloc, Value{ .string = try self.alloc.dupe(u8, entry.name) });
            }
            return Value{ .list = obj };
        }
        if (std.mem.eql(u8, method, "mkdir")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const path = try self.valueToString(arg_vals[0]);
            if (self.dry) return Value{ .number = 1 };
            std.Io.Dir.cwd().createDirPath(self.io, path) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.mkdir failed for '{s}'\n", .{ self.line, path });
                return ParseError.WriteFailed;
            };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "exec")) {
            if (arg_vals.len < 1 or arg_vals.len > 3) return ParseError.ArityMismatch;
            if (!proc.supported) {
                if (!self.mute) std.debug.print("error on line {d}: os.exec needs Windows for now\n", .{self.line});
                return ParseError.UnknownKeyword;
            }
            const cmd = try self.procArgv(arg_vals[0]);
            const shell = arg_vals[0] == .string;
            var timeout: ?u64 = null;
            var input: ?[]const u8 = null;
            for (arg_vals[1..]) |a| {
                if (a == .number) {
                    if (a.number < 0) return ParseError.TypeError;
                    timeout = @intFromFloat(@max(0, @min(3600000, a.number)));
                } else if (a == .string) {
                    input = try self.valueToString(a);
                } else {
                    return ParseError.TypeError;
                }
            }
            if (self.dry) {
                const d = try self.alloc.create(DictObj);
                d.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
                try d.map.put(try self.alloc.dupe(u8, "code"), Value{ .number = 0 });
                try d.map.put(try self.alloc.dupe(u8, "out"), Value{ .string = try self.alloc.dupe(u8, "") });
                try d.map.put(try self.alloc.dupe(u8, "err"), Value{ .string = try self.alloc.dupe(u8, "") });
                try d.map.put(try self.alloc.dupe(u8, "timeout"), Value{ .number = 0 });
                return Value{ .dict = d };
            }
            const r = proc.exec(self.alloc, cmd, shell, timeout, input) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.exec failed to start\n", .{self.line});
                return ParseError.UnknownFunction;
            };
            const d = try self.alloc.create(DictObj);
            d.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
            try d.map.put(try self.alloc.dupe(u8, "code"), Value{ .number = @floatFromInt(r.code) });
            try d.map.put(try self.alloc.dupe(u8, "out"), Value{ .string = r.out });
            try d.map.put(try self.alloc.dupe(u8, "err"), Value{ .string = r.err });
            try d.map.put(try self.alloc.dupe(u8, "timeout"), Value{ .number = @intFromBool(r.timed_out) });
            return Value{ .dict = d };
        }
        if (std.mem.eql(u8, method, "spawn")) {
            if (arg_vals.len < 1 or arg_vals.len > 2) return ParseError.ArityMismatch;
            if (!proc.supported) {
                if (!self.mute) std.debug.print("error on line {d}: os.spawn needs Windows for now\n", .{self.line});
                return ParseError.UnknownKeyword;
            }
            const cmd = try self.procArgv(arg_vals[0]);
            var input: ?[]const u8 = null;
            if (arg_vals.len == 2) {
                if (arg_vals[1] != .string) return ParseError.TypeError;
                input = try self.valueToString(arg_vals[1]);
            }
            if (self.dry) return Value{ .number = 1 };
            const id = proc.spawn(self.alloc, cmd, arg_vals[0] == .string, input) catch {
                if (!self.mute) std.debug.print("error on line {d}: os.spawn failed to start\n", .{self.line});
                return ParseError.UnknownFunction;
            };
            return Value{ .number = @floatFromInt(id) };
        }
        if (std.mem.eql(u8, method, "pipe") or std.mem.eql(u8, method, "pipe_err")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const id: u32 = @intFromFloat(@max(0, arg_vals[0].number));
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, "") };
            const s = if (std.mem.eql(u8, method, "pipe"))
                proc.readOut(self.alloc, id)
            else
                proc.readErr(self.alloc, id);
            return Value{ .string = s orelse {
                if (!self.mute) std.debug.print("error on line {d}: no such process\n", .{self.line});
                return ParseError.TypeError;
            } };
        }
        if (std.mem.eql(u8, method, "poll")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const id: u32 = @intFromFloat(@max(0, arg_vals[0].number));
            if (self.dry) return Value{ .nil = {} };
            if (proc.poll(id)) |code| return Value{ .number = @floatFromInt(code) };
            const p = proc.procById(id) orelse {
                if (!self.mute) std.debug.print("error on line {d}: no such process\n", .{self.line});
                return ParseError.TypeError;
            };
            _ = p;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "kill")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const id: u32 = @intFromFloat(@max(0, arg_vals[0].number));
            if (self.dry) return Value{ .number = 1 };
            if (proc.procById(id) == null) {
                if (!self.mute) std.debug.print("error on line {d}: no such process\n", .{self.line});
                return ParseError.TypeError;
            }
            return Value{ .number = @intFromBool(proc.kill(id)) };
        }
        if (std.mem.eql(u8, method, "close")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const id: u32 = @intFromFloat(@max(0, arg_vals[0].number));
            if (self.dry) return Value{ .number = 1 };
            if (!proc.close(id)) {
                if (!self.mute) std.debug.print("error on line {d}: no such process\n", .{self.line});
                return ParseError.TypeError;
            }
            return Value{ .nil = {} };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown os.{s} (have create/read/append/exists/remove/edit/readbytes/writebytes/cwd/env/listdir/mkdir/exec/spawn/pipe/pipe_err/poll/kill/close)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn procArgv(self: *Parser, v: Value) ![][]const u8 {
        if (v == .string) {
            const out = try self.alloc.alloc([]const u8, 1);
            out[0] = try self.valueToString(v);
            return out;
        }
        if (v != .list) {
            if (!self.mute) std.debug.print("error on line {d}: os.exec/spawn needs a string or list of strings\n", .{self.line});
            return ParseError.TypeError;
        }
        const items = v.list.items.items;
        if (items.len == 0) {
            if (!self.mute) std.debug.print("error on line {d}: os.exec/spawn needs a non-empty command\n", .{self.line});
            return ParseError.TypeError;
        }
        const out = try self.alloc.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            if (item != .string) {
                if (!self.mute) std.debug.print("error on line {d}: os.exec/spawn needs a string or list of strings\n", .{self.line});
                return ParseError.TypeError;
            }
            out[i] = try self.valueToString(item);
        }
        return out;
    }

    const phys_g = 9.81;

    fn physNum(self: *Parser, arg_vals: []const Value, i: usize) !f64 {
        if (i >= arg_vals.len or arg_vals[i] != .number) {
            if (!self.mute) std.debug.print("error on line {d}: physics needs numbers\n", .{self.line});
            return ParseError.TypeError;
        }
        return arg_vals[i].number;
    }

    fn heapSpanStart(span_v: Value) usize {
        return @intFromFloat(span_v.list.items.items[0].number);
    }

    fn heapSpanSize(span_v: Value) usize {
        return @intFromFloat(span_v.list.items.items[1].number);
    }

    fn callHeapMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_heap) {
            if (!self.mute) std.debug.print("error on line {d}: 'heap' used without 'import heap'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "new")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] != .number or @trunc(arg_vals[0].number) != arg_vals[0].number or arg_vals[0].number < 0) return ParseError.TypeError;
            const n: usize = @intFromFloat(arg_vals[0].number);
            if (n > 16 * 1024 * 1024) {
                if (!self.mute) std.debug.print("error on line {d}: heap.new() max 16M\n", .{self.line});
                return ParseError.LoopLimitExceeded;
            }
            const mem = try self.alloc.create(ListObj);
            mem.* = .{ .items = .empty };
            try mem.items.appendNTimes(self.alloc, Value{ .number = 0 }, n);
            const free = try self.alloc.create(ListObj);
            free.* = .{ .items = .empty };
            if (n > 0) {
                const span = try self.alloc.create(ListObj);
                span.* = .{ .items = .empty };
                try span.items.append(self.alloc, Value{ .number = 0 });
                try span.items.append(self.alloc, Value{ .number = @floatFromInt(n) });
                try free.items.append(self.alloc, Value{ .list = span });
            }
            const allocs = try self.alloc.create(DictObj);
            allocs.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
            const h = try self.alloc.create(DictObj);
            h.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
            try h.map.put(try self.alloc.dupe(u8, "mem"), Value{ .list = mem });
            try h.map.put(try self.alloc.dupe(u8, "free"), Value{ .list = free });
            try h.map.put(try self.alloc.dupe(u8, "allocs"), Value{ .dict = allocs });
            return Value{ .dict = h };
        }
        if (std.mem.eql(u8, method, "malloc")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const h = try self.heapParts(arg_vals[0]);
            if (arg_vals[1] != .number or @trunc(arg_vals[1].number) != arg_vals[1].number or arg_vals[1].number <= 0) return ParseError.TypeError;
            const need: usize = @intFromFloat(arg_vals[1].number);
            for (h.free.items.items, 0..) |span_v, si| {
                const s = heapSpanStart(span_v);
                const sz = heapSpanSize(span_v);
                if (sz >= need) {
                    const key = try std.fmt.allocPrint(self.alloc, "{d}", .{s});
                    try h.allocs.map.put(key, Value{ .number = @floatFromInt(need) });
                    if (sz == need) {
                        _ = h.free.items.orderedRemove(si);
                    } else {
                        span_v.list.items.items[0] = Value{ .number = @floatFromInt(s + need) };
                        span_v.list.items.items[1] = Value{ .number = @floatFromInt(sz - need) };
                    }
                    return Value{ .number = @floatFromInt(s) };
                }
            }
            return Value{ .number = -1 };
        }
        if (std.mem.eql(u8, method, "free")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const h = try self.heapParts(arg_vals[0]);
            if (arg_vals[1] != .number or @trunc(arg_vals[1].number) != arg_vals[1].number or arg_vals[1].number < 0) return ParseError.TypeError;
            const addr: usize = @intFromFloat(arg_vals[1].number);
            const key = try std.fmt.allocPrint(self.alloc, "{d}", .{addr});
            const szv = h.allocs.map.get(key) orelse return Value{ .number = 0 };
            const sz: usize = @intFromFloat(szv.number);
            _ = h.allocs.map.remove(key);
            const span = try self.alloc.create(ListObj);
            span.* = .{ .items = .empty };
            try span.items.append(self.alloc, Value{ .number = @floatFromInt(addr) });
            try span.items.append(self.alloc, Value{ .number = @floatFromInt(sz) });
            try h.free.items.append(self.alloc, Value{ .list = span });
            try self.heapCoalesce(h.free);
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "stats")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const h = try self.heapParts(arg_vals[0]);
            const total = h.mem.items.items.len;
            var free_n: usize = 0;
            for (h.free.items.items) |span_v| {
                free_n += heapSpanSize(span_v);
            }
            const st = try self.alloc.create(DictObj);
            st.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
            try st.map.put(try self.alloc.dupe(u8, "total"), Value{ .number = @floatFromInt(total) });
            try st.map.put(try self.alloc.dupe(u8, "free"), Value{ .number = @floatFromInt(free_n) });
            try st.map.put(try self.alloc.dupe(u8, "used"), Value{ .number = @floatFromInt(total - free_n) });
            try st.map.put(try self.alloc.dupe(u8, "blocks"), Value{ .number = @floatFromInt(h.free.items.items.len) });
            return Value{ .dict = st };
        }
        if (std.mem.eql(u8, method, "calloc")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const h = try self.heapParts(arg_vals[0]);
            if (arg_vals[1] != .number or @trunc(arg_vals[1].number) != arg_vals[1].number or arg_vals[1].number <= 0) return ParseError.TypeError;
            const need: usize = @intFromFloat(arg_vals[1].number);
            for (h.free.items.items, 0..) |span_v, si| {
                const s = heapSpanStart(span_v);
                const sz = heapSpanSize(span_v);
                if (sz >= need) {
                    const key = try std.fmt.allocPrint(self.alloc, "{d}", .{s});
                    try h.allocs.map.put(key, Value{ .number = @floatFromInt(need) });
                    var k: usize = 0;
                    while (k < need) : (k += 1) {
                        h.mem.items.items[s + k] = Value{ .number = 0 };
                    }
                    if (sz == need) {
                        _ = h.free.items.orderedRemove(si);
                    } else {
                        span_v.list.items.items[0] = Value{ .number = @floatFromInt(s + need) };
                        span_v.list.items.items[1] = Value{ .number = @floatFromInt(sz - need) };
                    }
                    return Value{ .number = @floatFromInt(s) };
                }
            }
            return Value{ .number = -1 };
        }
        if (std.mem.eql(u8, method, "realloc")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const h = try self.heapParts(arg_vals[0]);
            if (arg_vals[1] != .number or @trunc(arg_vals[1].number) != arg_vals[1].number or arg_vals[1].number < 0) return ParseError.TypeError;
            if (arg_vals[2] != .number or @trunc(arg_vals[2].number) != arg_vals[2].number or arg_vals[2].number <= 0) return ParseError.TypeError;
            const addr: usize = @intFromFloat(arg_vals[1].number);
            const need: usize = @intFromFloat(arg_vals[2].number);
            const oldkey = try std.fmt.allocPrint(self.alloc, "{d}", .{addr});
            const oldszv = h.allocs.map.get(oldkey) orelse return Value{ .number = 0 };
            const oldsz: usize = @intFromFloat(oldszv.number);
            // malloc new
            var found: ?usize = null;
            var found_si: usize = 0;
            for (h.free.items.items, 0..) |span_v, si| {
                if (heapSpanSize(span_v) >= need) {
                    found = heapSpanStart(span_v);
                    found_si = si;
                    break;
                }
            }
            const ns = found orelse return Value{ .number = -1 };
            const span_v = h.free.items.items[found_si];
            const sz = heapSpanSize(span_v);
            const key = try std.fmt.allocPrint(self.alloc, "{d}", .{ns});
            try h.allocs.map.put(key, Value{ .number = @floatFromInt(need) });
            if (sz == need) {
                _ = h.free.items.orderedRemove(found_si);
            } else {
                span_v.list.items.items[0] = Value{ .number = @floatFromInt(ns + need) };
                span_v.list.items.items[1] = Value{ .number = @floatFromInt(sz - need) };
            }
            // copy + free old
            const ncopy = @min(oldsz, need);
            var k: usize = 0;
            while (k < ncopy) : (k += 1) {
                h.mem.items.items[ns + k] = h.mem.items.items[addr + k];
            }
            _ = h.allocs.map.remove(oldkey);
            const span2 = try self.alloc.create(ListObj);
            span2.* = .{ .items = .empty };
            try span2.items.append(self.alloc, Value{ .number = @floatFromInt(addr) });
            try span2.items.append(self.alloc, Value{ .number = @floatFromInt(oldsz) });
            try h.free.items.append(self.alloc, Value{ .list = span2 });
            try self.heapCoalesce(h.free);
            return Value{ .number = @floatFromInt(ns) };
        }
        if (std.mem.eql(u8, method, "dump")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const h = try self.heapParts(arg_vals[0]);
            const out = try self.alloc.create(ListObj);
            out.* = .{ .items = .empty };
            var keys: std.ArrayList([]const u8) = .empty;
            var kit = h.allocs.map.iterator();
            while (kit.next()) |e| {
                try keys.append(self.alloc, e.key_ptr.*);
            }
            // sort numeric ascending
            var i: usize = 1;
            while (i < keys.items.len) : (i += 1) {
                var j = i;
                while (j > 0 and std.fmt.parseInt(usize, keys.items[j], 10) catch 0 < std.fmt.parseInt(usize, keys.items[j - 1], 10) catch 0) {
                    const t = keys.items[j];
                    keys.items[j] = keys.items[j - 1];
                    keys.items[j - 1] = t;
                    j -= 1;
                }
            }
            for (keys.items) |k| {
                const pair = try self.alloc.create(ListObj);
                pair.* = .{ .items = .empty };
                const av: usize = std.fmt.parseInt(usize, k, 10) catch 0;
                try pair.items.append(self.alloc, Value{ .number = @floatFromInt(av) });
                try pair.items.append(self.alloc, h.allocs.map.get(k).?);
                try out.items.append(self.alloc, Value{ .list = pair });
            }
            return Value{ .list = out };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown heap.{s} (have new/malloc/calloc/realloc/free/stats/dump)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    const HeapParts = struct { mem: *ListObj, free: *ListObj, allocs: *DictObj };

    fn heapParts(self: *Parser, v: Value) !HeapParts {
        if (v != .dict) {
            if (!self.mute) std.debug.print("error on line {d}: heap handle needs heap.new()\n", .{self.line});
            return ParseError.TypeError;
        }
        const mem = v.dict.map.get("mem") orelse return ParseError.TypeError;
        const free = v.dict.map.get("free") orelse return ParseError.TypeError;
        const allocs = v.dict.map.get("allocs") orelse return ParseError.TypeError;
        if (mem != .list or free != .list or allocs != .dict) return ParseError.TypeError;
        return .{ .mem = mem.list, .free = free.list, .allocs = allocs.dict };
    }

    fn heapCoalesce(self: *Parser, free: *ListObj) !void {
        const items = free.items.items;
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            var j = i;
            while (j > 0 and heapSpanStart(items[j]) < heapSpanStart(items[j - 1])) {
                const t = items[j];
                items[j] = items[j - 1];
                items[j - 1] = t;
                j -= 1;
            }
        }
        var w: usize = 0;
        for (items) |span_v| {
            const s = heapSpanStart(span_v);
            const sz = heapSpanSize(span_v);
            if (w > 0) {
                const pend = free.items.items[w - 1];
                const pe = heapSpanStart(pend) + heapSpanSize(pend);
                if (pe == s) {
                    pend.list.items.items[1] = Value{ .number = @floatFromInt(pe + sz - heapSpanStart(pend)) };
                    continue;
                }
            }
            free.items.items[w] = span_v;
            w += 1;
        }
        try free.items.resize(self.alloc, w);
    }

    fn callCpuMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_cpu) {
            if (!self.mute) std.debug.print("error on line {d}: 'cpu' used without 'import cpu'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "new")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] != .number or @trunc(arg_vals[0].number) != arg_vals[0].number or arg_vals[0].number < 0) return ParseError.TypeError;
            const n: usize = @intFromFloat(arg_vals[0].number);
            if (n > 16 * 1024 * 1024) {
                if (!self.mute) std.debug.print("error on line {d}: cpu.new() max 16M\n", .{self.line});
                return ParseError.LoopLimitExceeded;
            }
            const regs = try self.alloc.create(ListObj);
            regs.* = .{ .items = .empty };
            try regs.items.appendNTimes(self.alloc, Value{ .number = 0 }, 8);
            const mem = try self.alloc.create(ListObj);
            mem.* = .{ .items = .empty };
            try mem.items.appendNTimes(self.alloc, Value{ .number = 0 }, n);
            const m = try self.alloc.create(DictObj);
            m.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
            try m.map.put(try self.alloc.dupe(u8, "regs"), Value{ .list = regs });
            try m.map.put(try self.alloc.dupe(u8, "mem"), Value{ .list = mem });
            try m.map.put(try self.alloc.dupe(u8, "pc"), Value{ .number = 0 });
            try m.map.put(try self.alloc.dupe(u8, "running"), Value{ .number = 1 });
            try m.map.put(try self.alloc.dupe(u8, "steps"), Value{ .number = 0 });
            return Value{ .dict = m };
        }
        if (std.mem.eql(u8, method, "reg")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const cp = try self.cpuParts(arg_vals[0]);
            const r = try self.cpuReg(arg_vals[1]);
            return cp.regs.items.items[r];
        }
        if (std.mem.eql(u8, method, "setreg")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const cp = try self.cpuParts(arg_vals[0]);
            const r = try self.cpuReg(arg_vals[1]);
            cp.regs.items.items[r] = Value{ .number = try self.wrapInt(arg_vals[2], 32, false) };
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "load")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const cp = try self.cpuParts(arg_vals[0]);
            const a = try self.cpuAddr(cp.mem, arg_vals[1]);
            const bytes = cp.mem.items.items;
            var u: u64 = 0;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                u |= @as(u64, @intFromFloat(bytes[a + k].number)) << @as(u6, @intCast(k * 8));
            }
            return Value{ .number = @floatFromInt(u) };
        }
        if (std.mem.eql(u8, method, "store")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const cp = try self.cpuParts(arg_vals[0]);
            const a = try self.cpuAddr(cp.mem, arg_vals[1]);
            const w = try self.wrapInt(arg_vals[2], 32, false);
            const u: u64 = @intFromFloat(w);
            const bytes = cp.mem.items.items;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                bytes[a + k] = Value{ .number = @floatFromInt((u >> @as(u6, @intCast(k * 8))) & 0xFF) };
            }
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "step")) {
            if (arg_vals.len != 4 or arg_vals[1] != .string) return ParseError.TypeError;
            const cp = try self.cpuParts(arg_vals[0]);
            const op = arg_vals[1].string;
            const ra = try self.cpuArgNum(arg_vals[2]);
            const rb = try self.cpuArgNum(arg_vals[3]);
            if (cp.running != 1) return Value{ .number = 0 };
            const next_pc = try self.cpuExecOp(cp, op, ra, rb, arg_vals[3], cp.pc);
            try self.cpuSetNum(cp.dict, "pc", @floatFromInt(next_pc));
            const st = try self.cpuGetNum(cp.dict, "steps");
            try self.cpuSetNum(cp.dict, "steps", st + 1);
            return Value{ .number = try self.cpuGetNum(cp.dict, "running") };
        }
        if (std.mem.eql(u8, method, "run")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const cp = try self.cpuParts(arg_vals[0]);
            if (arg_vals[1] != .dict) {
                if (!self.mute) std.debug.print("error on line {d}: cpu.run needs an assembled program\n", .{self.line});
                return ParseError.TypeError;
            }
            const code = arg_vals[1].dict.map.get("code") orelse return ParseError.TypeError;
            const entry = arg_vals[1].dict.map.get("entry") orelse return ParseError.TypeError;
            if (code != .list or entry != .number) return ParseError.TypeError;
            try self.cpuSetNum(cp.dict, "pc", entry.number);
            try self.cpuSetNum(cp.dict, "running", 1);
            var steps: usize = 0;
            while (true) {
                const pc_now = try self.cpuGetNum(cp.dict, "pc");
                const running_now = try self.cpuGetNum(cp.dict, "running");
                if (running_now != 1) break;
                if (pc_now < 0 or @as(usize, @intFromFloat(pc_now)) >= code.list.items.items.len) break;
                const ins = code.list.items.items[@intFromFloat(pc_now)];
                if (ins != .list or ins.list.items.items.len != 3) return ParseError.TypeError;
                const items = ins.list.items.items;
                if (items[0] != .string or items[1] != .number or items[2] != .number) return ParseError.TypeError;
                const cp2 = try self.cpuParts(Value{ .dict = cp.dict });
                const next_pc = try self.cpuExecOp(cp2, items[0].string, items[1].number, items[2].number, items[2], @intFromFloat(pc_now));
                try self.cpuSetNum(cp.dict, "pc", @floatFromInt(next_pc));
                const st = try self.cpuGetNum(cp.dict, "steps");
                try self.cpuSetNum(cp.dict, "steps", st + 1);
                steps += 1;
                if (steps > 1000000) {
                    if (!self.mute) std.debug.print("error on line {d}: cpu.run step limit\n", .{self.line});
                    return ParseError.LoopLimitExceeded;
                }
            }
            return Value{ .number = @floatFromInt(steps) };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown cpu.{s} (have new/reg/setreg/load/store/step/run)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    // shared fetch-decode-execute core for cpu.step and cpu.run
    fn cpuExecOp(self: *Parser, cp: CpuParts, op: []const u8, ra: f64, rb: f64, rbv: Value, pc: usize) !usize {
        const regs = cp.regs.items.items;
        var next_pc = pc + 1;
        if (std.mem.eql(u8, op, "halt")) {
            try self.cpuSetNum(cp.dict, "running", 0);
        } else if (std.mem.eql(u8, op, "nop")) {
        } else if (std.mem.eql(u8, op, "li")) {
            regs[try self.cpuRegN(ra)] = Value{ .number = try self.wrapInt(rbv, 32, false) };
        } else if (std.mem.eql(u8, op, "add")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            regs[rd] = Value{ .number = try self.wrapInt(Value{ .number = regs[rd].number + regs[rs].number }, 32, false) };
        } else if (std.mem.eql(u8, op, "sub")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            regs[rd] = Value{ .number = try self.wrapInt(Value{ .number = regs[rd].number - regs[rs].number }, 32, false) };
        } else if (std.mem.eql(u8, op, "and")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            const a = try self.bitU64(regs[rd]);
            regs[rd] = numU64(a & try self.bitU64(regs[rs]));
        } else if (std.mem.eql(u8, op, "or")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            const a = try self.bitU64(regs[rd]);
            regs[rd] = numU64(a | try self.bitU64(regs[rs]));
        } else if (std.mem.eql(u8, op, "xor")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            const a = try self.bitU64(regs[rd]);
            regs[rd] = numU64(a ^ try self.bitU64(regs[rs]));
        } else if (std.mem.eql(u8, op, "shl")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            const a = try self.bitU64(regs[rd]);
            const b = try self.bitU64(regs[rs]);
            if (b > 63) return ParseError.TypeError;
            const ov = @shlWithOverflow(a, @as(u6, @intCast(b)));
            regs[rd] = numU64(ov[0] & 0xFFFFFFFF);
        } else if (std.mem.eql(u8, op, "shr")) {
            const rd = try self.cpuRegN(ra);
            const rs = try self.cpuRegN(rb);
            const a = try self.bitU64(regs[rd]);
            const b = try self.bitU64(regs[rs]);
            if (b > 63) return ParseError.TypeError;
            regs[rd] = numU64((a & 0xFFFFFFFF) >> @as(u6, @intCast(b)));
        } else if (std.mem.eql(u8, op, "lw")) {
            const rd = try self.cpuRegN(ra);
            const a = try self.cpuAddr(cp.mem, rbv);
            const bytes = cp.mem.items.items;
            var u: u64 = 0;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                u |= @as(u64, @intFromFloat(bytes[a + k].number)) << @as(u6, @intCast(k * 8));
            }
            regs[rd] = Value{ .number = @floatFromInt(u) };
        } else if (std.mem.eql(u8, op, "sw")) {
            const rs = try self.cpuRegN(ra);
            const a = try self.cpuAddr(cp.mem, rbv);
            const w = try self.wrapInt(regs[rs], 32, false);
            const u: u64 = @intFromFloat(w);
            const bytes = cp.mem.items.items;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                bytes[a + k] = Value{ .number = @floatFromInt((u >> @as(u6, @intCast(k * 8))) & 0xFF) };
            }
        } else if (std.mem.eql(u8, op, "jmp")) {
            if (@trunc(ra) != ra or ra < 0) return ParseError.TypeError;
            next_pc = @intFromFloat(ra);
        } else if (std.mem.eql(u8, op, "jz")) {
            const rs = try self.cpuRegN(ra);
            const target: i64 = @intFromFloat(rb);
            if (@trunc(rb) != rb or target < 0) return ParseError.TypeError;
            if (regs[rs].number == 0) next_pc = @intCast(target);
        } else {
            if (!self.mute) std.debug.print("error on line {d}: bad cpu op '{s}'\n", .{ self.line, op });
            return ParseError.TypeError;
        }
        return next_pc;
    }

    const CpuParts = struct { dict: *DictObj, regs: *ListObj, mem: *ListObj, pc: usize, running: f64 };

    fn cpuParts(self: *Parser, v: Value) !CpuParts {
        if (v != .dict) {
            if (!self.mute) std.debug.print("error on line {d}: cpu machine needs cpu.new()\n", .{self.line});
            return ParseError.TypeError;
        }
        const regs = v.dict.map.get("regs") orelse return ParseError.TypeError;
        const mem = v.dict.map.get("mem") orelse return ParseError.TypeError;
        const pcv = v.dict.map.get("pc") orelse return ParseError.TypeError;
        const runv = v.dict.map.get("running") orelse return ParseError.TypeError;
        if (regs != .list or mem != .list or pcv != .number or runv != .number) return ParseError.TypeError;
        if (regs.list.items.items.len != 8 or @trunc(pcv.number) != pcv.number or pcv.number < 0) return ParseError.TypeError;
        return .{ .dict = v.dict, .regs = regs.list, .mem = mem.list, .pc = @intFromFloat(pcv.number), .running = runv.number };
    }

    fn cpuReg(self: *Parser, v: Value) !usize {
        if (v != .number or @trunc(v.number) != v.number or v.number < 0 or v.number > 7) {
            if (!self.mute) std.debug.print("error on line {d}: cpu reg needs 0..7\n", .{self.line});
            return ParseError.TypeError;
        }
        return @intFromFloat(v.number);
    }

    fn cpuRegN(self: *Parser, f: f64) !usize {
        if (@trunc(f) != f or f < 0 or f > 7) {
            if (!self.mute) std.debug.print("error on line {d}: cpu reg needs 0..7\n", .{self.line});
            return ParseError.TypeError;
        }
        return @intFromFloat(f);
    }

    fn cpuArgNum(self: *Parser, v: Value) !f64 {
        if (v != .number) {
            if (!self.mute) std.debug.print("error on line {d}: cpu args need numbers\n", .{self.line});
            return ParseError.TypeError;
        }
        return v.number;
    }

    fn cpuAddr(self: *Parser, mem: *ListObj, v: Value) !usize {
        if (v != .number or @trunc(v.number) != v.number or v.number < 0) {
            if (!self.mute) std.debug.print("error on line {d}: cpu addr needs >= 0\n", .{self.line});
            return ParseError.TypeError;
        }
        const a: usize = @intFromFloat(v.number);
        if (a + 4 > mem.items.items.len) {
            if (!self.mute) std.debug.print("error on line {d}: cpu addr out of RAM\n", .{self.line});
            return ParseError.IndexOutOfBounds;
        }
        return a;
    }

    fn cpuGetNum(self: *Parser, dict: *DictObj, key: []const u8) !f64 {
        _ = self;
        const v = dict.map.get(key) orelse return ParseError.TypeError;
        if (v != .number) return ParseError.TypeError;
        return v.number;
    }

    fn cpuSetNum(self: *Parser, dict: *DictObj, key: []const u8, n: f64) !void {
        _ = self;
        const slot = dict.map.getPtr(key) orelse return ParseError.TypeError;
        slot.* = Value{ .number = n };
    }

    fn callPhysicsMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_physics) {
            if (!self.mute) std.debug.print("error on line {d}: 'physics' used without 'import physics'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "g")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            return Value{ .number = phys_g };
        }
        if (std.mem.eql(u8, method, "fall")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const d = try self.physNum(arg_vals, 0);
            if (d < 0) {
                if (!self.mute) std.debug.print("error on line {d}: fall() needs d >= 0\n", .{self.line});
                return ParseError.MathError;
            }
            return Value{ .number = @sqrt(2.0 * d / phys_g) };
        }
        if (std.mem.eql(u8, method, "range")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const v = try self.physNum(arg_vals, 0);
            const deg = try self.physNum(arg_vals, 1);
            const th = deg * std.math.pi / 180.0;
            return Value{ .number = v * v * @sin(2.0 * th) / phys_g };
        }
        if (std.mem.eql(u8, method, "height")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const v = try self.physNum(arg_vals, 0);
            const deg = try self.physNum(arg_vals, 1);
            const vy = v * @sin(deg * std.math.pi / 180.0);
            return Value{ .number = vy * vy / (2.0 * phys_g) };
        }
        if (std.mem.eql(u8, method, "dist")) {
            if (arg_vals.len != 4) return ParseError.ArityMismatch;
            const ax = try self.physNum(arg_vals, 0);
            const ay = try self.physNum(arg_vals, 1);
            const bx = try self.physNum(arg_vals, 2);
            const by = try self.physNum(arg_vals, 3);
            const dx = bx - ax;
            const dy = by - ay;
            return Value{ .number = @sqrt(dx * dx + dy * dy) };
        }
        if (std.mem.eql(u8, method, "speed")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const d = try self.physNum(arg_vals, 0);
            const t = try self.physNum(arg_vals, 1);
            if (t == 0) return ParseError.DivisionByZero;
            return Value{ .number = d / t };
        }
        if (std.mem.eql(u8, method, "energy")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const m = try self.physNum(arg_vals, 0);
            const v = try self.physNum(arg_vals, 1);
            return Value{ .number = 0.5 * m * v * v };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown physics.{s} (have g/fall/range/height/dist/speed/energy)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn guiNum(args: []const Value, i: usize) ?f64 {
        if (i >= args.len) return null;
        if (args[i] != .number) return null;
        return args[i].number;
    }

    fn guiInt(args: []const Value, i: usize) ?i32 {
        const n = guiNum(args, i) orelse return null;
        if (@trunc(n) != n) return null;
        if (n > 2147483000 or n < -2147483000) return null;
        return @intFromFloat(n);
    }

    fn guiWin(self: *Parser, v: Value) !*gui.Window {
        if (self.dry) return gui.dryWindow();
        if (v != .number) {
            if (!self.mute) std.debug.print("error on line {d}: gui needs a window handle (from gui.window)\n", .{self.line});
            return ParseError.TypeError;
        }
        if (v.number < 1) {
            if (!self.mute) std.debug.print("error on line {d}: no such gui window\n", .{self.line});
            return ParseError.TypeError;
        }
        const slot: usize = @intFromFloat(v.number - 1);
        const win = gui.windowBySlot(slot) orelse {
            if (!self.mute) std.debug.print("error on line {d}: no such gui window\n", .{self.line});
            return ParseError.TypeError;
        };
        return win;
    }

    fn guiCtl(self: *Parser, win: *gui.Window, v: Value) !*gui.Control {
        if (self.dry) return gui.dryControl();
        if (v != .number) return ParseError.TypeError;
        const id: u32 = @intFromFloat(v.number);
        return gui.findControl(win, id) orelse {
            if (!self.mute) std.debug.print("error on line {d}: no such gui control\n", .{self.line});
            return ParseError.TypeError;
        };
    }

    fn guiColorOf(self: *Parser, v: Value) !gui.Color {
        if (v != .number) {
            if (v == .string) {
                const s = try self.valueToString(v);
                if (gui.namedColor(s)) |c| return c;
                if (!self.mute) std.debug.print("error on line {d}: unknown color name '{s}'\n", .{ self.line, s });
                return ParseError.BadArgument;
            }
            return ParseError.TypeError;
        }
        return @as(gui.Color, @truncate(@as(u64, @intFromFloat(@max(0.0, v.number)))));
    }

    fn guiToken(self: *Parser, v: Value) !i32 {
        if (v != .function) {
            if (!self.mute) std.debug.print("error on line {d}: gui callback must be a function (try: my_handler)\n", .{self.line});
            return ParseError.TypeError;
        }
        if (self.gui_cbs) |list| {
            const tok: i32 = @intCast(list.items.len);
            try list.append(self.alloc, v);
            return tok;
        }
        if (!self.mute) std.debug.print("error on line {d}: gui needs 'import gui' first\n", .{self.line});
        return ParseError.UnknownKeyword;
    }

    fn guiEventDict(self: *Parser, ev: gui.Event) !Value {
        const d = try self.alloc.create(DictObj);
        d.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
        const put = struct {
            fn f(p: *Parser, dd: *DictObj, k: []const u8, v: Value) !void {
                try dd.map.put(try p.alloc.dupe(u8, k), v);
            }
        }.f;
        try put(self, d, "type", Value{ .string = try self.alloc.dupe(u8, gui.eventName(ev.kind)) });
        try put(self, d, "id", Value{ .number = @floatFromInt(ev.id) });
        try put(self, d, "x", Value{ .number = @floatFromInt(ev.x) });
        try put(self, d, "y", Value{ .number = @floatFromInt(ev.y) });
        try put(self, d, "w", Value{ .number = @floatFromInt(ev.w) });
        try put(self, d, "h", Value{ .number = @floatFromInt(ev.h) });
        try put(self, d, "key", Value{ .string = try self.alloc.dupe(u8, ev.key) });
        try put(self, d, "ch", Value{ .string = try self.alloc.dupe(u8, ev.ch) });
        try put(self, d, "wheel", Value{ .number = @floatFromInt(ev.wheel) });
        try put(self, d, "ctrl", Value{ .number = @intFromBool(ev.ctrl) });
        try put(self, d, "shift", Value{ .number = @intFromBool(ev.shift) });
        try put(self, d, "alt", Value{ .number = @intFromBool(ev.alt) });
        return Value{ .dict = d };
    }

    fn guiDispatch(self: *Parser, ev: gui.Event, dict: Value) !void {
        if (ev.cb < 0) return;
        const list = self.gui_cbs orelse return;
        const idx: usize = @intCast(ev.cb);
        if (idx >= list.items.len) return;
        const fv = list.items[idx];
        if (fv != .function) return;
        const target = self.funcs.get(fv.function.name) orelse return;
        const args = try self.alloc.alloc(Value, 1);
        args[0] = dict;
        _ = try self.invokeScoped(target, fv.function.scope orelse self.scope, args);
    }

    fn guiTake(self: *Parser, win: *gui.Window, blocking: bool) !Value {
        var maybe: ?gui.Event = null;
        if (blocking) {
            maybe = gui.wait(win);
        } else {
            maybe = gui.poll(win);
        }
        const ev = maybe orelse return Value{ .nil = {} };
        const dict = try self.guiEventDict(ev);
        if (!self.dry) try self.guiDispatch(ev, dict);
        return dict;
    }

    fn guiWidget(self: *Parser, method: []const u8, arg_vals: []const Value) !Value {
        const win = try self.guiWin(arg_vals[0]);
        const kind: gui.Kind = if (std.mem.eql(u8, method, "label"))
            .label
        else if (std.mem.eql(u8, method, "button"))
            .button
        else if (std.mem.eql(u8, method, "checkbox"))
            .checkbox
        else if (std.mem.eql(u8, method, "slider"))
            .slider
        else if (std.mem.eql(u8, method, "progress"))
            .progress
        else if (std.mem.eql(u8, method, "textbox"))
            .textbox
        else if (std.mem.eql(u8, method, "editbox"))
            .editbox
        else
            .list;
        var ctrl = gui.Control{ .id = 0, .kind = kind, .x = -1, .y = -1, .w = -1, .h = -1 };
        var argi: usize = 1;
        if (arg_vals.len == 0) return ParseError.ArityMismatch;
        switch (kind) {
            .label, .checkbox, .textbox, .editbox => {
                if (arg_vals.len > 1) ctrl.text = try self.valueToString(arg_vals[1]);
            },
            .button => {
                if (arg_vals.len > 1) ctrl.text = try self.valueToString(arg_vals[1]);
                if (arg_vals.len > 2) ctrl.cb = try self.guiToken(arg_vals[2]);
            },
            .list, .slider, .progress, .vbox, .hbox, .panel, .groupbox, .tabs, .radio, .combo, .picture => {},
        }
        if (kind == .slider) {
            if (arg_vals.len >= 8) {
                ctrl.x = guiInt(arg_vals, 1) orelse -1;
                ctrl.y = guiInt(arg_vals, 2) orelse -1;
                ctrl.w = guiInt(arg_vals, 3) orelse 220;
                ctrl.h = guiInt(arg_vals, 4) orelse 28;
                ctrl.vmin = guiNum(arg_vals, 5) orelse 0;
                ctrl.vmax = guiNum(arg_vals, 6) orelse 100;
                ctrl.value = guiNum(arg_vals, 7) orelse ctrl.vmin;
                argi = 8;
            } else {
                ctrl.vmin = guiNum(arg_vals, 1) orelse 0;
                ctrl.vmax = guiNum(arg_vals, 2) orelse 100;
                ctrl.value = guiNum(arg_vals, 3) orelse ctrl.vmin;
                ctrl.w = 220;
                argi = 4;
            }
            if (ctrl.vmax < ctrl.vmin) ctrl.vmax = ctrl.vmin;
            if (ctrl.value < ctrl.vmin) ctrl.value = ctrl.vmin;
            if (ctrl.value > ctrl.vmax) ctrl.value = ctrl.vmax;
        }
        if (kind == .progress) {
            ctrl.vmax = 100;
            if (arg_vals.len >= 6) {
                ctrl.value = guiNum(arg_vals, 1) orelse 0;
                ctrl.x = guiInt(arg_vals, 2) orelse -1;
                ctrl.y = guiInt(arg_vals, 3) orelse -1;
                ctrl.w = guiInt(arg_vals, 4) orelse 220;
                ctrl.h = guiInt(arg_vals, 5) orelse 20;
                argi = 6;
            } else if (arg_vals.len >= 5) {
                ctrl.x = guiInt(arg_vals, 1) orelse -1;
                ctrl.y = guiInt(arg_vals, 2) orelse -1;
                ctrl.w = guiInt(arg_vals, 3) orelse 220;
                ctrl.h = guiInt(arg_vals, 4) orelse 20;
                argi = 5;
            } else {
                ctrl.value = guiNum(arg_vals, 1) orelse 0;
                argi = 2;
            }
        }
        if (arg_vals.len > argi and arg_vals[argi] == .function) {
            ctrl.cb = try self.guiToken(arg_vals[argi]);
            argi += 1;
        }
        argi = switch (kind) {
            .button => if (ctrl.cb >= 0) 3 else 2,
            .label, .checkbox, .textbox, .editbox, .groupbox => 2,
            .list => if (arg_vals.len > 1 and arg_vals[1] == .string) 2 else 1,
            .slider, .progress, .vbox, .hbox, .panel, .tabs, .radio, .combo, .picture => argi,
        };
        while (arg_vals.len > argi) {
            switch (arg_vals[argi]) {
                .number => {
                    if (ctrl.x < 0) {
                        ctrl.x = guiInt(arg_vals, argi).?;
                    } else if (ctrl.y < 0) {
                        ctrl.y = guiInt(arg_vals, argi).?;
                    } else if (ctrl.w < 0) {
                        ctrl.w = guiInt(arg_vals, argi).?;
                    } else if (ctrl.h < 0) {
                        ctrl.h = guiInt(arg_vals, argi).?;
                    } else return ParseError.ArityMismatch;
                    argi += 1;
                },
                else => return ParseError.TypeError,
            }
        }
        if (ctrl.w < 0) {
            ctrl.w = switch (kind) {
                .button => @max(80, gui.textWidth(win, ctrl.text) + 28),
                .label => @max(40, gui.textWidth(win, ctrl.text) + 2),
                .checkbox => @max(60, gui.textWidth(win, ctrl.text) + 40),
                else => 220,
            };
        }
        const id = try gui.addControl(win, ctrl);
        return Value{ .number = @floatFromInt(id) };
    }

    fn callGuiMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_gui) {
            if (!self.mute) std.debug.print("error on line {d}: 'gui' used without 'import gui'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (!gui.supported) {
            if (!self.mute) std.debug.print("error on line {d}: the gui module needs Windows (this build is {s})\n", .{ self.line, @tagName(@import("builtin").os.tag) });
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "window")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const title = try self.valueToString(arg_vals[0]);
            const w = guiInt(arg_vals, 1) orelse 640;
            const h = guiInt(arg_vals, 2) orelse 480;
            if (self.dry) return Value{ .number = 1 };
            const win = gui.createWindow(self.alloc, title, w, h) catch {
                if (!self.mute) std.debug.print("error on line {d}: could not create window (Win32 failed)\n", .{self.line});
                return ParseError.UnknownFunction;
            };
            return Value{ .number = @floatFromInt(win.slot + 1) };
        }
        if (std.mem.eql(u8, method, "alive")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            return Value{ .number = @intFromBool(gui.isAlive(win)) };
        }
        if (std.mem.eql(u8, method, "label") or std.mem.eql(u8, method, "button") or
            std.mem.eql(u8, method, "checkbox") or std.mem.eql(u8, method, "slider") or
            std.mem.eql(u8, method, "progress") or std.mem.eql(u8, method, "textbox") or
            std.mem.eql(u8, method, "editbox") or std.mem.eql(u8, method, "list"))
        {
            if (arg_vals.len == 0) return ParseError.ArityMismatch;
            return try self.guiWidget(method, arg_vals);
        }
        if (std.mem.eql(u8, method, "poll") or std.mem.eql(u8, method, "wait")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (self.dry) return Value{ .nil = {} };
            return try self.guiTake(win, std.mem.eql(u8, method, "wait"));
        }
        if (std.mem.eql(u8, method, "quit") or std.mem.eql(u8, method, "close")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.close(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "title")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.setTitle(win, try self.valueToString(arg_vals[1]));
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "size")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.setSize(win, guiInt(arg_vals, 1) orelse 640, guiInt(arg_vals, 2) orelse 480);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "bgcolor") or std.mem.eql(u8, method, "accent")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiColorOf(arg_vals[1]);
            if (!self.dry) {
                if (std.mem.eql(u8, method, "bgcolor")) gui.setBg(win, c) else gui.setAccent(win, c);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "theme")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.setTheme(win, try self.valueToString(arg_vals[1]));
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "font")) {
            if (arg_vals.len < 2 or arg_vals.len > 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const size = guiInt(arg_vals, 1) orelse 16;
            const bold = if (arg_vals.len == 3) (guiNum(arg_vals, 2) orelse 0) != 0 else false;
            if (!self.dry) gui.setFont(win, size, bold);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "redraw")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.redraw(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "tick")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.setTick(win, @as(u32, @truncate(@as(u64, @intFromFloat(@max(0.0, guiNum(arg_vals, 1) orelse 0))))));
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "show")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.show(win, (guiNum(arg_vals, 1) orelse 1) != 0);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "layout")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.resetLayout(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "gap")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.setLayoutGap(win, guiInt(arg_vals, 1) orelse 8);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "on")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            c.cb = try self.guiToken(arg_vals[2]);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "get") or std.mem.eql(u8, method, "set")) {
            const is_set = std.mem.eql(u8, method, "set");
            if (arg_vals.len != (if (is_set) @as(usize, 3) else @as(usize, 2))) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (is_set) {
                if (arg_vals[2] == .number) {
                    if (c.kind == .checkbox or c.kind == .radio) {
                        c.checked = (arg_vals[2].number != 0);
                        if (c.kind == .radio and c.checked) gui.radioExclusive(win, c);
                    } else {
                        c.value = arg_vals[2].number;
                    }
                } else {
                    c.text = try self.valueToString(arg_vals[2]);
                }
                gui.redraw(win);
                return Value{ .nil = {} };
            }
            return switch (c.kind) {
                .checkbox, .radio => Value{ .number = @intFromBool(c.checked) },
                .label, .textbox, .editbox => Value{ .string = try self.alloc.dupe(u8, c.text) },
                .tabs => Value{ .number = @floatFromInt(c.active) },
                .combo => if (c.sel >= 0) Value{ .number = @floatFromInt(c.sel) } else Value{ .nil = {} },
                else => Value{ .number = c.value },
            };
        }
        if (std.mem.eql(u8, method, "get_text") or std.mem.eql(u8, method, "set_text")) {
            const is_set = std.mem.eql(u8, method, "set_text");
            if (arg_vals.len != (if (is_set) @as(usize, 3) else @as(usize, 2))) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (is_set) {
                c.text = try self.valueToString(arg_vals[2]);
                gui.redraw(win);
                return Value{ .nil = {} };
            }
            return Value{ .string = try self.alloc.dupe(u8, c.text) };
        }
        if (std.mem.eql(u8, method, "enable")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            c.enabled = (guiNum(arg_vals, 2) orelse 1) != 0;
            if (!c.enabled) {
                c.pressed = false;
                c.hovered = false;
                if (win.drag_id == c.id) win.drag_id = 0;
                if (win.pressed_id == c.id) win.pressed_id = 0;
            }
            gui.redraw(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "show_control")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            c.visible = (guiNum(arg_vals, 2) orelse 1) != 0;
            gui.redraw(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "tint")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            c.tint = try self.guiColorOf(arg_vals[2]);
            gui.redraw(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "list_add")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            const s = try self.valueToString(arg_vals[2]);
            if (!self.dry) gui.listAdd(win, c.id, s) catch return ParseError.UnknownFunction;
            return Value{ .number = @floatFromInt(gui.listLen(win, c.id)) };
        }
        if (std.mem.eql(u8, method, "list_insert")) {
            if (arg_vals.len != 4) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            const idx: usize = @intFromFloat(guiNum(arg_vals, 2) orelse 0);
            const s = try self.valueToString(arg_vals[3]);
            if (!self.dry) gui.listInsert(win, c.id, idx, s) catch return ParseError.UnknownFunction;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "list_remove")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            const idx: usize = @intFromFloat(guiNum(arg_vals, 2) orelse 0);
            if (!self.dry) gui.listRemove(win, c.id, idx) catch return ParseError.UnknownFunction;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "list_clear")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (!self.dry) gui.listClear(win, c.id) catch return ParseError.UnknownFunction;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "list_get")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            const idx: usize = @intFromFloat(guiNum(arg_vals, 2) orelse 0);
            const s = gui.listGet(win, c.id, idx) orelse return ParseError.IndexOutOfBounds;
            return Value{ .string = try self.alloc.dupe(u8, s) };
        }
        if (std.mem.eql(u8, method, "list_set")) {
            if (arg_vals.len != 4) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            const idx: usize = @intFromFloat(guiNum(arg_vals, 2) orelse 0);
            const s = try self.valueToString(arg_vals[3]);
            if (!self.dry) gui.listSet(win, c.id, idx, s) catch return ParseError.UnknownFunction;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "list_len")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            return Value{ .number = @floatFromInt(gui.listLen(win, c.id)) };
        }
        if (std.mem.eql(u8, method, "list_sel") or std.mem.eql(u8, method, "list_select")) {
            const is_set = std.mem.eql(u8, method, "list_select");
            if (arg_vals.len != (if (is_set) @as(usize, 3) else @as(usize, 2))) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (is_set) {
                const idx = guiInt(arg_vals, 2) orelse -1;
                if (!self.dry) gui.listSelect(win, c.id, idx) catch return ParseError.BadArgument;
                return Value{ .nil = {} };
            }
            return Value{ .number = @floatFromInt(gui.listSel(win, c.id)) };
        }
        if (std.mem.eql(u8, method, "fill") or std.mem.eql(u8, method, "outline")) {
            if (arg_vals.len != 6) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) {
                gui.pushRect(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 0, guiInt(arg_vals, 4) orelse 0, try self.guiColorOf(arg_vals[5]), std.mem.eql(u8, method, "outline"), 0);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "round")) {
            if (arg_vals.len != 7) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) {
                gui.pushRect(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 0, guiInt(arg_vals, 4) orelse 0, try self.guiColorOf(arg_vals[5]), false, guiInt(arg_vals, 6) orelse 6);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "text")) {
            if (arg_vals.len < 3 or arg_vals.len > 5) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            var s: []const u8 = "";
            var x: i32 = 0;
            var y: i32 = 0;
            if (arg_vals.len >= 4) {
                x = guiInt(arg_vals, 1) orelse 0;
                y = guiInt(arg_vals, 2) orelse 0;
                s = try self.valueToString(arg_vals[3]);
            } else {
                s = try self.valueToString(arg_vals[1]);
                y = guiInt(arg_vals, 2) orelse 0;
            }
            const c = if (arg_vals.len == 5) try self.guiColorOf(arg_vals[4]) else win.theme.text;
            if (!self.dry) gui.pushText(win, x, y, s, c, win.font_size);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "line")) {
            if (arg_vals.len != 6) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) {
                gui.pushLine(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 0, guiInt(arg_vals, 4) orelse 0, try self.guiColorOf(arg_vals[5]), 1);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "color")) {
            if (arg_vals.len == 1) {
                const c = try self.guiColorOf(arg_vals[0]);
                return Value{ .number = @floatFromInt(c) };
            }
            if (arg_vals.len == 3) {
                const r: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 0) orelse 0)));
                const g: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 1) orelse 0)));
                const b: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 2) orelse 0)));
                return Value{ .number = @floatFromInt(0xFF000000 | (r << 16) | (g << 8) | b) };
            }
            if (arg_vals.len == 4) {
                const a: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 0) orelse 255)));
                const r: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 1) orelse 0)));
                const g: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 2) orelse 0)));
                const b: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 3) orelse 0)));
                return Value{ .number = @floatFromInt((a << 24) | (r << 16) | (g << 8) | b) };
            }
            return ParseError.ArityMismatch;
        }
        if (std.mem.eql(u8, method, "vbox") or std.mem.eql(u8, method, "hbox") or
            std.mem.eql(u8, method, "panel") or std.mem.eql(u8, method, "groupbox") or
            std.mem.eql(u8, method, "tabs"))
        {
            if (arg_vals.len < 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const kind: gui.Kind = if (std.mem.eql(u8, method, "vbox"))
                .vbox
            else if (std.mem.eql(u8, method, "hbox"))
                .hbox
            else if (std.mem.eql(u8, method, "panel"))
                .panel
            else if (std.mem.eql(u8, method, "groupbox"))
                .groupbox
            else
                .tabs;
            var ctrl = gui.Control{
                .id = 0,
                .kind = kind,
                .x = guiInt(arg_vals, 1) orelse -1,
                .y = guiInt(arg_vals, 2) orelse -1,
                .w = guiInt(arg_vals, 3) orelse 200,
                .h = guiInt(arg_vals, 4) orelse 0,
                .gap = guiInt(arg_vals, 5) orelse 8,
            };
            if (ctrl.w <= 0) ctrl.w = 200;
            if (kind == .groupbox and arg_vals.len > 1) ctrl.text = try self.valueToString(arg_vals[1]);
            if (kind == .groupbox) {
                ctrl.x = guiInt(arg_vals, 2) orelse -1;
                ctrl.y = guiInt(arg_vals, 3) orelse -1;
                ctrl.w = guiInt(arg_vals, 4) orelse 200;
                ctrl.h = guiInt(arg_vals, 5) orelse 0;
                ctrl.gap = guiInt(arg_vals, 6) orelse 8;
            }
            if (kind == .tabs) ctrl.h = @max(120, ctrl.h);
            const id = try gui.addControl(win, ctrl);
            return Value{ .number = @floatFromInt(id) };
        }
        if (std.mem.eql(u8, method, "begin")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (arg_vals[1] != .number) return ParseError.TypeError;
            if (!self.dry) gui.begin(win, @intFromFloat(arg_vals[1].number)) catch return ParseError.TypeError;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "end")) {
            if (arg_vals.len > 1) return ParseError.ArityMismatch;
            if (arg_vals.len == 1) {
                const win = try self.guiWin(arg_vals[0]);
                if (!self.dry) gui.endFlow(win);
            } else if (!self.dry) {
                for (0..64) |i| {
                    if (gui.windowBySlot(i)) |win| gui.endFlow(win);
                }
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "tab_add")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            c.pages.append(self.alloc, try self.valueToString(arg_vals[2])) catch return ParseError.OutOfMemory;
            gui.redraw(win);
            return Value{ .number = @floatFromInt(c.pages.items.len - 1) };
        }
        if (std.mem.eql(u8, method, "tab_select")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            const idx = guiInt(arg_vals, 2) orelse 0;
            if (idx < 0 or idx >= @as(i32, @intCast(c.pages.items.len))) return ParseError.IndexOutOfBounds;
            c.active = idx;
            c.flow = 0;
            gui.redraw(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "radio")) {
            if (arg_vals.len < 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            var ctrl = gui.Control{
                .id = 0,
                .kind = .radio,
                .x = guiInt(arg_vals, 3) orelse -1,
                .y = guiInt(arg_vals, 4) orelse -1,
                .w = guiInt(arg_vals, 5) orelse -1,
                .h = guiInt(arg_vals, 6) orelse -1,
                .group = try self.valueToString(arg_vals[1]),
                .text = try self.valueToString(arg_vals[2]),
            };
            if (ctrl.w <= 0) ctrl.w = 120;
            const id = try gui.addControl(win, ctrl);
            return Value{ .number = @floatFromInt(id) };
        }
        if (std.mem.eql(u8, method, "dropdown")) {
            if (arg_vals.len < 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            var ctrl = gui.Control{
                .id = 0,
                .kind = .combo,
                .x = guiInt(arg_vals, 2) orelse -1,
                .y = guiInt(arg_vals, 3) orelse -1,
                .w = guiInt(arg_vals, 4) orelse 180,
                .h = guiInt(arg_vals, 5) orelse -1,
                .text = try self.valueToString(arg_vals[1]),
            };
            if (arg_vals.len > 2 and arg_vals[2] == .function) {
                ctrl.cb = try self.guiToken(arg_vals[2]);
            }
            const id = try gui.addControl(win, ctrl);
            return Value{ .number = @floatFromInt(id) };
        }
        if (std.mem.eql(u8, method, "picture")) {
            if (arg_vals.len < 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const path = try self.valueToString(arg_vals[1]);
            var ctrl = gui.Control{
                .id = 0,
                .kind = .picture,
                .x = guiInt(arg_vals, 2) orelse -1,
                .y = guiInt(arg_vals, 3) orelse -1,
                .w = guiInt(arg_vals, 4) orelse 160,
                .h = guiInt(arg_vals, 5) orelse 120,
            };
            if (ctrl.w <= 0) ctrl.w = 160;
            if (ctrl.h <= 0) ctrl.h = 120;
            ctrl.pic = if (self.dry) gui.dryControl().pic else gui.loadImage(self.alloc, path);
            const id = try gui.addControl(win, ctrl);
            return Value{ .number = @floatFromInt(id) };
        }
        if (std.mem.eql(u8, method, "image")) {
            if (arg_vals.len < 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const path = try self.valueToString(arg_vals[1]);
            const x = guiInt(arg_vals, 2) orelse 0;
            const y = guiInt(arg_vals, 3) orelse 0;
            const dw = guiInt(arg_vals, 4) orelse 0;
            const dh = guiInt(arg_vals, 5) orelse 0;
            if (!self.dry) gui.queueImage(win, path, x, y, dw, dh);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "image_size")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const path = try self.valueToString(arg_vals[0]);
            const list = try self.alloc.create(ListObj);
            list.* = .{ .items = .empty };
            if (self.dry or gui.imageSize(path) == null) {
                try list.items.append(self.alloc, Value{ .number = 0 });
                try list.items.append(self.alloc, Value{ .number = 0 });
            } else {
                const sz = gui.imageSize(path).?;
                try list.items.append(self.alloc, Value{ .number = @floatFromInt(sz[0]) });
                try list.items.append(self.alloc, Value{ .number = @floatFromInt(sz[1]) });
            }
            return Value{ .list = list };
        }
        if (std.mem.eql(u8, method, "radio_group")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.radioGroupSelect(win, try self.valueToString(arg_vals[1]), guiInt(arg_vals, 2) orelse 0);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "circle")) {
            if (arg_vals.len != 5) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) {
                gui.pushRing(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 10, try self.guiColorOf(arg_vals[4]), 1);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "circle_fill") or std.mem.eql(u8, method, "disc")) {
            if (arg_vals.len != 5) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) {
                gui.pushDisc(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 10, try self.guiColorOf(arg_vals[4]));
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "arc")) {
            if (arg_vals.len != 7 and arg_vals.len != 8) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const width = if (arg_vals.len == 8) (guiInt(arg_vals, 7) orelse 2) else 2;
            if (!self.dry) {
                gui.pushArc(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 20, guiNum(arg_vals, 4) orelse 0, guiNum(arg_vals, 5) orelse 90, try self.guiColorOf(arg_vals[6]), width);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "polygon")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (arg_vals[1] != .list) return ParseError.TypeError;
            const src = arg_vals[1].list.items.items;
            if (src.len < 6 or src.len > 128) return ParseError.BadArgument;
            const pts = try self.alloc.alloc(i32, src.len);
            for (src, 0..) |item, i| {
                if (item != .number) return ParseError.TypeError;
                pts[i] = @intFromFloat(item.number);
            }
            if (!self.dry) gui.pushPoly(win, pts, try self.guiColorOf(arg_vals[2]), true);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "gradient")) {
            if (arg_vals.len != 7 and arg_vals.len != 8) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const vertical = if (arg_vals.len == 8) (guiNum(arg_vals, 7) orelse 1) != 0 else true;
            if (!self.dry) {
                gui.pushGradient(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 0, guiInt(arg_vals, 4) orelse 0, try self.guiColorOf(arg_vals[5]), try self.guiColorOf(arg_vals[6]), vertical);
            }
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "fade")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const c = try self.guiColorOf(arg_vals[0]);
            const a: u32 = @intFromFloat(@max(0, @min(255, guiNum(arg_vals, 1) orelse 255)));
            return Value{ .number = @floatFromInt((a << 24) | (c & 0x00FFFFFF)) };
        }
        if (std.mem.eql(u8, method, "open_file") or std.mem.eql(u8, method, "save_file")) {
            const is_save = std.mem.eql(u8, method, "save_file");
            if (arg_vals.len > 4) return ParseError.ArityMismatch;
            var i: usize = 0;
            var owner: ?*anyopaque = null;
            if (arg_vals.len > 0 and arg_vals[0] == .number) {
                const win = try self.guiWin(arg_vals[0]);
                owner = win.hwnd;
                i = 1;
            }
            var title: ?[]const u8 = null;
            var second: ?[]const u8 = null;
            var filter: ?[]const u8 = null;
            if (arg_vals.len > i) {
                if (arg_vals[i] != .string) return ParseError.TypeError;
                title = try self.valueToString(arg_vals[i]);
                i += 1;
            }
            if (arg_vals.len > i) {
                if (arg_vals[i] != .string) return ParseError.TypeError;
                second = try self.valueToString(arg_vals[i]);
                i += 1;
            }
            if (arg_vals.len > i) {
                if (arg_vals[i] != .string) return ParseError.TypeError;
                filter = try self.valueToString(arg_vals[i]);
            }
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, "") };
            const def_name = if (is_save) second else null;
            const flt = if (is_save) filter else second;
            const path = gui.fileDialog(self.alloc, owner, is_save, title, def_name, flt);
            return Value{ .string = try self.alloc.dupe(u8, path) };
        }
        if (std.mem.eql(u8, method, "line_count")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (c.kind != .editbox) return ParseError.TypeError;
            return Value{ .number = @floatFromInt(gui.editLineCount(c.text)) };
        }
        if (std.mem.eql(u8, method, "get_line")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (c.kind != .editbox) return ParseError.TypeError;
            const idx = guiInt(arg_vals, 2) orelse 0;
            const line = gui.editLineText(self.alloc, c.text, idx) catch return ParseError.OutOfMemory;
            return Value{ .string = line };
        }
        if (std.mem.eql(u8, method, "goto_line")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const c = try self.guiCtl(win, arg_vals[1]);
            if (c.kind != .editbox) return ParseError.TypeError;
            const idx = guiInt(arg_vals, 2) orelse 0;
            const total = gui.editLineCount(c.text);
            const li = @max(0, @min(total - 1, idx));
            c.caret = gui.editOffsetFor(win, c, li, 0);
            gui.editEnsureVisible(win, c);
            gui.redraw(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "mark_add")) {
            if (arg_vals.len != 6) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const id: u32 = @intFromFloat(@max(0, guiNum(arg_vals, 1) orelse 0));
            const line = guiInt(arg_vals, 2) orelse 0;
            const col = guiInt(arg_vals, 3) orelse 0;
            const len = guiInt(arg_vals, 4) orelse 0;
            const color = try self.guiColorOf(arg_vals[5]);
            if (!self.dry) gui.editMarkAdd(win, id, line, col, len, color) catch {
                if (!self.mute) std.debug.print("error on line {d}: mark_add needs an editbox\n", .{self.line});
                return ParseError.TypeError;
            };
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "marks_clear")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const id: u32 = @intFromFloat(@max(0, guiNum(arg_vals, 1) orelse 0));
            if (!self.dry) gui.editMarksClear(win, id) catch {
                if (!self.mute) std.debug.print("error on line {d}: marks_clear needs an editbox\n", .{self.line});
                return ParseError.TypeError;
            };
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "linenums")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const id: u32 = @intFromFloat(@max(0, guiNum(arg_vals, 1) orelse 0));
            const on = (guiNum(arg_vals, 2) orelse 1) != 0;
            if (!self.dry) gui.editLinenums(win, id, on) catch {
                if (!self.mute) std.debug.print("error on line {d}: linenums needs an editbox\n", .{self.line});
                return ParseError.TypeError;
            };
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "curline")) {
            if (arg_vals.len != 3 and arg_vals.len != 4) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const id: u32 = @intFromFloat(@max(0, guiNum(arg_vals, 1) orelse 0));
            const on = (guiNum(arg_vals, 2) orelse 1) != 0;
            const color = if (arg_vals.len == 4) try self.guiColorOf(arg_vals[3]) else @as(u32, 0x22FFFFFF);
            if (!self.dry) gui.editCurline(win, id, on, color) catch {
                if (!self.mute) std.debug.print("error on line {d}: curline needs an editbox\n", .{self.line});
                return ParseError.TypeError;
            };
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "click")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.postClick(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "key_press")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.postKey(win, try self.valueToString(arg_vals[1]));
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "type_text")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.postType(win, try self.valueToString(arg_vals[1]));
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "wheel")) {
            if (arg_vals.len != 4) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.postWheel(win, guiInt(arg_vals, 1) orelse 0, guiInt(arg_vals, 2) orelse 0, guiInt(arg_vals, 3) orelse 0);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "post_close")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            if (!self.dry) gui.postClose(win);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "mouse")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const win = try self.guiWin(arg_vals[0]);
            const p = gui.mousePos(win);
            const list = try self.alloc.create(ListObj);
            list.* = .{ .items = .empty };
            try list.items.append(self.alloc, Value{ .number = @floatFromInt(p[0]) });
            try list.items.append(self.alloc, Value{ .number = @floatFromInt(p[1]) });
            return Value{ .list = list };
        }
        if (std.mem.eql(u8, method, "key")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = @intFromBool(gui.keyDown(try self.valueToString(arg_vals[0]))) };
        }
        if (std.mem.eql(u8, method, "mods")) {
            const m = gui.mods();
            const list = try self.alloc.create(ListObj);
            list.* = .{ .items = .empty };
            try list.items.append(self.alloc, Value{ .number = @intFromBool(m[0]) });
            try list.items.append(self.alloc, Value{ .number = @intFromBool(m[1]) });
            try list.items.append(self.alloc, Value{ .number = @intFromBool(m[2]) });
            return Value{ .list = list };
        }
        if (std.mem.eql(u8, method, "msgbox")) {
            if (arg_vals.len < 1 or arg_vals.len > 2) return ParseError.ArityMismatch;
            const text = try self.valueToString(arg_vals[0]);
            const title = if (arg_vals.len == 2) try self.valueToString(arg_vals[1]) else null;
            if (!self.dry) gui.msgbox(self.alloc, text, title);
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "clip_set")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (!self.dry) gui.clipSet(self.alloc, try self.valueToString(arg_vals[0]));
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "clip_get")) {
            if (!self.dry) return Value{ .string = try self.alloc.dupe(u8, gui.clipGet(self.alloc)) };
            return Value{ .string = try self.alloc.dupe(u8, "") };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown gui.{s}\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn callJsonMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_json) {
            if (!self.mute) std.debug.print("error on line {d}: 'json' used without 'import json'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "parse")) {
            if (arg_vals.len != 1 or arg_vals[0] != .string) return ParseError.TypeError;
            var jp = JsonParser{ .src = arg_vals[0].string, .alloc = self.alloc, .line = self.line, .mute = self.mute };
            const v = try jp.parseValue();
            jp.skipWs();
            if (jp.pos != jp.src.len) {
                if (!self.mute) std.debug.print("error on line {d}: trailing JSON\n", .{self.line});
                return ParseError.JsonError;
            }
            return v;
        }
        if (std.mem.eql(u8, method, "stringify")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .string = try self.jsonStringify(arg_vals[0]) };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown json.{s} (have parse/stringify)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn jsonStringify(self: *Parser, v: Value) anyerror![]const u8 {
        switch (v) {
            .number => |n| return try self.valueToString(Value{ .number = n }),
            .string => |s| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '"');
                for (s) |ch| {
                    switch (ch) {
                        '"' => try buf.appendSlice(self.alloc, "\\\""),
                        '\\' => try buf.appendSlice(self.alloc, "\\\\"),
                        '\n' => try buf.appendSlice(self.alloc, "\\n"),
                        '\r' => try buf.appendSlice(self.alloc, "\\r"),
                        '\t' => try buf.appendSlice(self.alloc, "\\t"),
                        0x08 => try buf.appendSlice(self.alloc, "\\b"),
                        0x0C => try buf.appendSlice(self.alloc, "\\f"),
                        else => {
                            if (ch < 0x20) {
                                const hex = "0123456789abcdef";
                                try buf.appendSlice(self.alloc, "\\u00");
                                try buf.append(self.alloc, hex[ch >> 4]);
                                try buf.append(self.alloc, hex[ch & 15]);
                            } else try buf.append(self.alloc, ch);
                        },
                    }
                }
                try buf.append(self.alloc, '"');
                return try buf.toOwnedSlice(self.alloc);
            },
            .nil => return try self.alloc.dupe(u8, "null"),
            .list => |l| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '[');
                for (l.items.items, 0..) |item, i| {
                    if (i > 0) try buf.append(self.alloc, ',');
                    try buf.appendSlice(self.alloc, try self.jsonStringify(item));
                }
                try buf.append(self.alloc, ']');
                return try buf.toOwnedSlice(self.alloc);
            },
            .dict => |d| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '{');
                var it = d.map.iterator();
                var first = true;
                while (it.next()) |e| {
                    if (!first) try buf.append(self.alloc, ',');
                    first = false;
                    try buf.appendSlice(self.alloc, try self.jsonStringify(Value{ .string = e.key_ptr.* }));
                    try buf.append(self.alloc, ':');
                    try buf.appendSlice(self.alloc, try self.jsonStringify(e.value_ptr.*));
                }
                try buf.append(self.alloc, '}');
                return try buf.toOwnedSlice(self.alloc);
            },
            .instance => {
                if (!self.mute) std.debug.print("error on line {d}: cannot stringify structs\n", .{self.line});
                return ParseError.TypeError;
            },
            .function => {
                if (!self.mute) std.debug.print("error on line {d}: cannot stringify function values\n", .{self.line});
                return ParseError.TypeError;
            },
        }
    }

    fn callRandomMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_random) {
            if (!self.mute) std.debug.print("error on line {d}: 'random' used without 'import random'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "seed")) {
            if (arg_vals.len > 1) return ParseError.ArityMismatch;
            if (arg_vals.len == 1) {
                if (arg_vals[0] != .number) return ParseError.TypeError;
                g_rng = seedFrom(numToI64(arg_vals[0].number));
            } else {
                g_rng = seedFrom(numToI64(@as(f64, @floatFromInt(Io.Timestamp.now(self.io, .real).toMilliseconds()))));
            }
            if (g_rng == 0) g_rng = 0x9E3779B97F4A7C15;
            return Value{ .nil = {} };
        }
        if (std.mem.eql(u8, method, "int")) {
            if (arg_vals.len != 1 and arg_vals.len != 2) return ParseError.ArityMismatch;
            var lo: i64 = 0;
            var hi: i64 = 0;
            var span: u64 = 0;
            if (arg_vals.len == 1) {
                if (arg_vals[0] != .number) return ParseError.TypeError;
                hi = numToI64(arg_vals[0].number);
                if (hi <= 0) return ParseError.MathError;
                lo = 0;
                span = @as(u64, @intCast(hi));
            } else {
                if (arg_vals[0] != .number or arg_vals[1] != .number) return ParseError.TypeError;
                lo = numToI64(arg_vals[0].number);
                hi = numToI64(arg_vals[1].number);
                if (hi < lo) return ParseError.MathError;
                span = @as(u64, @intCast(hi - lo)) + 1;
            }
            const v = lo + @as(i64, @intCast(nextRand() % span));
            return Value{ .number = @floatFromInt(v) };
        }
        if (std.mem.eql(u8, method, "float")) {
            if (arg_vals.len != 0 and arg_vals.len != 2) return ParseError.ArityMismatch;
            const unit = @as(f64, @floatFromInt(nextRand() >> 11)) / 9007199254740992.0;
            if (arg_vals.len == 0) return Value{ .number = unit };
            if (arg_vals[0] != .number or arg_vals[1] != .number) return ParseError.TypeError;
            const a = arg_vals[0].number;
            const b = arg_vals[1].number;
            return Value{ .number = a + (b - a) * unit };
        }
        if (std.mem.eql(u8, method, "chance")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const p = @max(0.0, @min(1.0, arg_vals[0].number));
            const unit = @as(f64, @floatFromInt(nextRand() >> 11)) / 9007199254740992.0;
            return Value{ .number = @intFromBool(unit < p) };
        }
        if (std.mem.eql(u8, method, "pick")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] == .string) {
                const s = arg_vals[0].string;
                if (s.len == 0) return ParseError.IndexOutOfBounds;
                const i: usize = @intCast(nextRand() % s.len);
                return Value{ .string = try self.alloc.dupe(u8, s[i .. i + 1]) };
            }
            if (arg_vals[0] != .list) return ParseError.TypeError;
            const items = arg_vals[0].list.items.items;
            if (items.len == 0) return ParseError.IndexOutOfBounds;
            return items[@intCast(nextRand() % items.len)];
        }
        if (std.mem.eql(u8, method, "shuffle")) {
            if (arg_vals.len != 1 or arg_vals[0] != .list) return ParseError.TypeError;
            const items = arg_vals[0].list.items.items;
            const out = try self.alloc.create(ListObj);
            out.* = .{ .items = .empty };
            try out.items.appendSlice(self.alloc, items);
            var i = out.items.items.len;
            while (i > 1) {
                i -= 1;
                const j: usize = @intCast(nextRand() % (i + 1));
                const tmp = out.items.items[i];
                out.items.items[i] = out.items.items[j];
                out.items.items[j] = tmp;
            }
            return Value{ .list = out };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown random.{s} (have seed/int/float/pick/shuffle/chance)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn callStringsMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_strings) {
            if (!self.mute) std.debug.print("error on line {d}: 'strings' used without 'import strings'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "starts_with") or std.mem.eql(u8, method, "ends_with")) {
            if (arg_vals.len != 2 or arg_vals[0] != .string or arg_vals[1] != .string) return ParseError.TypeError;
            const s = arg_vals[0].string;
            const sub = arg_vals[1].string;
            const hit = if (std.mem.eql(u8, method, "starts_with"))
                std.mem.startsWith(u8, s, sub)
            else
                std.mem.endsWith(u8, s, sub);
            return Value{ .number = @intFromBool(hit) };
        }
        if (std.mem.eql(u8, method, "find")) {
            if (arg_vals.len != 2 or arg_vals[0] != .string or arg_vals[1] != .string) return ParseError.TypeError;
            if (std.mem.indexOf(u8, arg_vals[0].string, arg_vals[1].string)) |idx| {
                return Value{ .number = @floatFromInt(idx) };
            }
            return Value{ .number = -1 };
        }
        if (std.mem.eql(u8, method, "pad_left") or std.mem.eql(u8, method, "pad_right")) {
            if (arg_vals.len < 2 or arg_vals.len > 3) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string or arg_vals[1] != .number) return ParseError.TypeError;
            const s = arg_vals[0].string;
            const width: usize = @intFromFloat(@max(0, arg_vals[1].number));
            var ch: u8 = ' ';
            if (arg_vals.len == 3) {
                const cs = try self.valueToString(arg_vals[2]);
                if (cs.len == 0) return ParseError.TypeError;
                ch = cs[0];
            }
            if (s.len >= width) return Value{ .string = try self.alloc.dupe(u8, s) };
            const out = try self.alloc.alloc(u8, width);
            const pad = width - s.len;
            if (std.mem.eql(u8, method, "pad_left")) {
                @memset(out[0..pad], ch);
                @memcpy(out[pad..], s);
            } else {
                @memcpy(out[0..s.len], s);
                @memset(out[s.len..], ch);
            }
            return Value{ .string = out };
        }
        if (std.mem.eql(u8, method, "repeat")) {
            if (arg_vals.len != 2 or arg_vals[0] != .string or arg_vals[1] != .number) return ParseError.TypeError;
            const s = arg_vals[0].string;
            const n: usize = @intFromFloat(@max(0, @min(1000000, arg_vals[1].number)));
            const out = try self.alloc.alloc(u8, s.len * n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                @memcpy(out[i * s.len .. (i + 1) * s.len], s);
            }
            return Value{ .string = out };
        }
        if (std.mem.eql(u8, method, "replace_all")) {
            if (arg_vals.len != 3 or arg_vals[0] != .string or arg_vals[1] != .string or arg_vals[2] != .string) return ParseError.TypeError;
            const src = arg_vals[0].string;
            const old = arg_vals[1].string;
            const new = arg_vals[2].string;
            if (old.len == 0) return Value{ .string = try self.alloc.dupe(u8, src) };
            var buf: std.ArrayList(u8) = .empty;
            var rest = src;
            while (std.mem.indexOf(u8, rest, old)) |idx| {
                try buf.appendSlice(self.alloc, rest[0..idx]);
                try buf.appendSlice(self.alloc, new);
                rest = rest[idx + old.len ..];
            }
            try buf.appendSlice(self.alloc, rest);
            return Value{ .string = try buf.toOwnedSlice(self.alloc) };
        }
        if (std.mem.eql(u8, method, "lines")) {
            if (arg_vals.len != 1 or arg_vals[0] != .string) return ParseError.TypeError;
            const list = try self.alloc.create(ListObj);
            list.* = .{ .items = .empty };
            var it = std.mem.splitScalar(u8, arg_vals[0].string, '\n');
            while (it.next()) |line| {
                const clean = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                try list.items.append(self.alloc, Value{ .string = try self.alloc.dupe(u8, clean) });
            }
            return Value{ .list = list };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown strings.{s} (have starts_with/ends_with/find/pad_left/pad_right/repeat/replace_all/lines)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn callHexMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_hex) {
            if (!self.mute) std.debug.print("error on line {d}: 'hex' used without 'import hex'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "encode") or std.mem.eql(u8, method, "dump")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const spaced = std.mem.eql(u8, method, "dump");
            var buf: std.ArrayList(u8) = .empty;
            if (arg_vals[0] == .list) {
                for (arg_vals[0].list.items.items) |item| {
                    if (item != .number) return ParseError.TypeError;
                    const n: i32 = @intFromFloat(@max(0, @min(255, item.number)));
                    if (spaced and buf.items.len > 0) try buf.append(self.alloc, ' ');
                    try buf.appendSlice(self.alloc, try hexPair(self.alloc, @intCast(n)));
                }
            } else if (arg_vals[0] == .string) {
                const s = arg_vals[0].string;
                var i: usize = 0;
                while (i < s.len) {
                    const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                    const end = @min(i + seq, s.len);
                    const cp = std.unicode.utf8Decode(s[i..end]) catch 0xFFFD;
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &tmp) catch 1;
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        if (spaced and buf.items.len > 0) try buf.append(self.alloc, ' ');
                        try buf.appendSlice(self.alloc, try hexPair(self.alloc, tmp[k]));
                    }
                    i = end;
                }
            } else {
                return ParseError.TypeError;
            }
            return Value{ .string = try buf.toOwnedSlice(self.alloc) };
        }
        if (std.mem.eql(u8, method, "decode")) {
            if (arg_vals.len != 1 or arg_vals[0] != .string) return ParseError.TypeError;
            const src = arg_vals[0].string;
            const list = try self.alloc.create(ListObj);
            list.* = .{ .items = .empty };
            var i: usize = 0;
            while (i < src.len) {
                const c = src[i];
                if (c == ' ' or c == ',' or c == ':' or c == '_' or c == '\n' or c == '\r' or c == '\t') {
                    i += 1;
                    continue;
                }
                if (i + 1 >= src.len) {
                    if (!self.mute) std.debug.print("error on line {d}: hex.decode() needs two digits per byte\n", .{self.line});
                    return ParseError.BadNumber;
                }
                const hi = std.fmt.charToDigit(c, 16) catch {
                    if (!self.mute) std.debug.print("error on line {d}: hex.decode() bad digit '{c}'\n", .{ self.line, c });
                    return ParseError.BadNumber;
                };
                const lo = std.fmt.charToDigit(src[i + 1], 16) catch {
                    if (!self.mute) std.debug.print("error on line {d}: hex.decode() bad digit '{c}'\n", .{ self.line, src[i + 1] });
                    return ParseError.BadNumber;
                };
                try list.items.append(self.alloc, Value{ .number = @floatFromInt(hi * 16 + lo) });
                i += 2;
            }
            return Value{ .list = list };
        }
        if (std.mem.eql(u8, method, "word")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const v: u64 = @intFromFloat(@max(0, arg_vals[0].number));
            var buf: [8]u8 = undefined;
            var i: usize = 8;
            var n = v;
            while (i > 0) {
                i -= 1;
                buf[i] = hexDigits[@as(usize, @intCast(n & 0xF))];
                n >>= 4;
            }
            return Value{ .string = try self.alloc.dupe(u8, &buf) };
        }
        if (std.mem.eql(u8, method, "parse")) {
            if (arg_vals.len != 1 or arg_vals[0] != .string) return ParseError.TypeError;
            const src = std.mem.trim(u8, arg_vals[0].string, " \t\r\n_");
            if (src.len == 0) return Value{ .number = 0 };
            var body = src;
            var neg = false;
            if (body.len > 1 and (body[0] == '0') and (body[1] == 'x' or body[1] == 'X')) {
                body = body[2..];
            } else if (body[0] == '-') {
                neg = true;
                body = body[1..];
            }
            if (body.len > 16) {
                if (!self.mute) std.debug.print("error on line {d}: hex.parse() max 16 digits\n", .{self.line});
                return ParseError.BadNumber;
            }
            var acc: u64 = 0;
            for (body) |c| {
                const d = std.fmt.charToDigit(c, 16) catch {
                    if (!self.mute) std.debug.print("error on line {d}: hex.parse() bad digit '{c}'\n", .{ self.line, c });
                    return ParseError.BadNumber;
                };
                acc = acc * 16 + d;
            }
            if (neg) return Value{ .number = -@as(f64, @floatFromInt(acc)) };
            return Value{ .number = @floatFromInt(acc) };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown hex.{s} (have encode/decode/dump/word/parse)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn callTimeMethod(self: *Parser, method: []const u8, arg_vals: []const Value) anyerror!Value {
        if (!self.imported_time) {
            if (!self.mute) std.debug.print("error on line {d}: 'time' used without 'import time'\n", .{self.line});
            return ParseError.UnknownKeyword;
        }
        if (std.mem.eql(u8, method, "now")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 0 };
            const ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
            return Value{ .number = @floatFromInt(ms) };
        }
        if (std.mem.eql(u8, method, "stamp")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, "1970-01-01 00:00:00") };
            const ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
            return Value{ .string = try self.utcStamp(@divFloor(ms, 1000)) };
        }
        if (std.mem.eql(u8, method, "sleep")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            const sec = arg_vals[0].number;
            if (sec < 0) {
                if (!self.mute) std.debug.print("error on line {d}: sleep() needs sec >= 0\n", .{self.line});
                return ParseError.MathError;
            }
            if (!self.dry) {
                const ms_f = sec * 1000.0;
                const ms: i64 = if (ms_f > 9.0e18) 9_000_000_000_000_000_000 else @intFromFloat(ms_f);
                Io.sleep(self.io, Io.Duration.fromMilliseconds(ms), .real) catch {};
            }
            return Value{ .number = 1 };
        }
        if (std.mem.eql(u8, method, "ms")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 0 };
            if (g_start_ms == null) g_start_ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
            const now_ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
            return Value{ .number = @floatFromInt(now_ms - g_start_ms.?) };
        }
        if (std.mem.eql(u8, method, "epoch_ms")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 0 };
            return Value{ .number = @floatFromInt(Io.Timestamp.now(self.io, .real).toMilliseconds()) };
        }
        if (std.mem.eql(u8, method, "clock")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .number = 0 };
            const ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
            const secs = @divFloor(ms, 1000);
            const day_ms: i64 = 86_400_000;
            const tod = @mod(secs, @divFloor(day_ms, 1000));
            return Value{ .number = @floatFromInt(tod) };
        }
        if (!self.mute) std.debug.print("error on line {d}: unknown time.{s} (have now/stamp/sleep/ms/epoch_ms/clock)\n", .{ self.line, method });
        return ParseError.UnknownFunction;
    }

    fn utcStamp(self: *Parser, secs: i64) ![]const u8 {
        const days = @divFloor(secs, 86400);
        const sod = @mod(secs, 86400);
        // Howard Hinnant days-to-civil, all floor division
        const z = days + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        var y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        var mo = mp + 3 - 12 * @divFloor(mp, 10);
        if (mo <= 0) mo = 1;
        y += @intFromBool(mo <= 2);
        const hh = @divFloor(sod, 3600);
        const mm = @divFloor(@mod(sod, 3600), 60);
        const ss = @mod(sod, 60);
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}-", .{y}));
        const md: [2]i64 = .{ mo, d };
        for (md, 0..) |part, i| {
            if (i > 0) try buf.append(self.alloc, '-');
            if (part < 10) try buf.append(self.alloc, '0');
            try buf.appendSlice(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{part}));
        }
        try buf.append(self.alloc, ' ');
        const hms: [3]i64 = .{ hh, mm, ss };
        for (hms, 0..) |part, i| {
            if (i > 0) try buf.append(self.alloc, ':');
            if (part < 10) try buf.append(self.alloc, '0');
            try buf.appendSlice(self.alloc, try std.fmt.allocPrint(self.alloc, "{d}", .{part}));
        }
        return try buf.toOwnedSlice(self.alloc);
    }

const JsonParser = struct {
    src: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,
    line: usize = 1,
    mute: bool = false,

    fn fail(self: *JsonParser) ParseError {
        if (!self.mute) std.debug.print("error on line {d}: malformed JSON\n", .{self.line});
        return ParseError.JsonError;
    }

    fn skipWs(self: *JsonParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (c == '\n') self.line += 1;
                self.pos += 1;
            } else break;
        }
    }

    fn parseValue(self: *JsonParser) anyerror!Value {
        self.skipWs();
        if (self.pos >= self.src.len) return self.fail();
        const c = self.src[self.pos];
        if (c == '{') return Value{ .dict = try self.parseObject() };
        if (c == '[') return Value{ .list = try self.parseArray() };
        if (c == '"') return Value{ .string = try self.parseString() };
        if (c == 't') {
            if (std.mem.startsWith(u8, self.src[self.pos..], "true")) {
                self.pos += 4;
                return Value{ .number = 1 };
            }
            return self.fail();
        }
        if (c == 'f') {
            if (std.mem.startsWith(u8, self.src[self.pos..], "false")) {
                self.pos += 5;
                return Value{ .number = 0 };
            }
            return self.fail();
        }
        if (c == 'n') {
            if (std.mem.startsWith(u8, self.src[self.pos..], "null")) {
                self.pos += 4;
                return Value{ .nil = {} };
            }
            return self.fail();
        }
        if (c == '-' or std.ascii.isDigit(c)) return Value{ .number = try self.parseNumber() };
        return self.fail();
    }

    fn parseObject(self: *JsonParser) anyerror!*DictObj {
        self.pos += 1; // {
        const obj = try self.alloc.create(DictObj);
        obj.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            return obj;
        }
        while (true) {
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != '"') return self.fail();
            const key = try self.parseString();
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ':') return self.fail();
            self.pos += 1;
            const v = try self.parseValue();
            try obj.map.put(try self.alloc.dupe(u8, key), v);
            self.skipWs();
            if (self.pos >= self.src.len) return self.fail();
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                return obj;
            }
            return self.fail();
        }
    }

    fn parseArray(self: *JsonParser) anyerror!*ListObj {
        self.pos += 1; // [
        const obj = try self.alloc.create(ListObj);
        obj.* = .{ .items = .empty };
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
            return obj;
        }
        while (true) {
            const v = try self.parseValue();
            try obj.items.append(self.alloc, v);
            self.skipWs();
            if (self.pos >= self.src.len) return self.fail();
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == ']') {
                self.pos += 1;
                return obj;
            }
            return self.fail();
        }
    }

    fn hexVal(c: u8) ?u21 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return null;
    }

    fn appendUtf8(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) !void {
        if (cp < 0x80) {
            try buf.append(alloc, @intCast(cp));
        } else if (cp < 0x800) {
            try buf.append(alloc, @intCast(0xC0 | (cp >> 6)));
            try buf.append(alloc, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            try buf.append(alloc, @intCast(0xE0 | (cp >> 12)));
            try buf.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(alloc, @intCast(0x80 | (cp & 0x3F)));
        } else {
            try buf.append(alloc, @intCast(0xF0 | (cp >> 18)));
            try buf.append(alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try buf.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(alloc, @intCast(0x80 | (cp & 0x3F)));
        }
    }

    fn parseHex4(self: *JsonParser) !u21 {
        if (self.pos + 4 > self.src.len) return self.fail();
        var cp: u21 = 0;
        for (0..4) |k| {
            const h = hexVal(self.src[self.pos + k]) orelse return self.fail();
            cp = cp * 16 + h;
        }
        self.pos += 4;
        return cp;
    }

    fn parseString(self: *JsonParser) anyerror![]const u8 {
        self.pos += 1; // opening "
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return self.fail();
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                return try buf.toOwnedSlice(self.alloc);
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return self.fail();
                const e = self.src[self.pos];
                switch (e) {
                    '"', '\\', '/' => {
                        try buf.append(self.alloc, e);
                        self.pos += 1;
                    },
                    'b' => {
                        try buf.append(self.alloc, 0x08);
                        self.pos += 1;
                    },
                    'f' => {
                        try buf.append(self.alloc, 0x0C);
                        self.pos += 1;
                    },
                    'n' => {
                        try buf.append(self.alloc, '\n');
                        self.pos += 1;
                    },
                    'r' => {
                        try buf.append(self.alloc, '\r');
                        self.pos += 1;
                    },
                    't' => {
                        try buf.append(self.alloc, '\t');
                        self.pos += 1;
                    },
                    'u' => {
                        self.pos += 1;
                        var cp = try self.parseHex4();
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            // surrogate pair?
                            if (self.pos + 1 < self.src.len and self.src[self.pos] == '\\' and self.src[self.pos + 1] == 'u') {
                                self.pos += 2;
                                const lo = try self.parseHex4();
                                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                } else {
                                    cp = 0xFFFD;
                                }
                            } else {
                                cp = 0xFFFD;
                            }
                        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                            cp = 0xFFFD;
                        }
                        try appendUtf8(&buf, self.alloc, cp);
                    },
                    else => return self.fail(),
                }
                continue;
            }
            if (c < 0x20) return self.fail();
            if (c == '\n') self.line += 1;
            try buf.append(self.alloc, c);
            self.pos += 1;
        }
    }

    fn parseNumber(self: *JsonParser) !f64 {
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        if (self.pos < self.src.len and self.src[self.pos] == '0') {
            self.pos += 1;
        } else {
            const ds = self.pos;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            if (ds == self.pos) return self.fail();
        }
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            const ds = self.pos;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            if (ds == self.pos) return self.fail();
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            const ds = self.pos;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
            if (ds == self.pos) return self.fail();
        }
        return std.fmt.parseFloat(f64, self.src[start..self.pos]) catch return self.fail();
    }
};

    fn callFunction(self: *Parser, name: []const u8, arg_vals: []const Value) anyerror!Value {
        // builtins (easier-than-C stdlib for 0.0.5)
        if (std.mem.eql(u8, name, "len")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            switch (arg_vals[0]) {
                .string => |s| return Value{ .number = @floatFromInt(s.len) },
                .list => |l| return Value{ .number = @floatFromInt(l.items.items.len) },
                .dict => |d| return Value{ .number = @floatFromInt(d.map.count()) },
                .number => return ParseError.TypeError,
                .instance => return ParseError.TypeError,
                .function => return ParseError.TypeError,
                .nil => return ParseError.TypeError,
            }
        }
        if (std.mem.eql(u8, name, "keys")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] != .dict) {
                if (!self.mute) std.debug.print("error on line {d}: keys() needs a dict\n", .{self.line});
                return ParseError.TypeError;
            }
            const obj = try self.alloc.create(ListObj);
            obj.* = .{ .items = .empty };
            var it = arg_vals[0].dict.map.iterator();
            while (it.next()) |e| {
                try obj.items.append(self.alloc, Value{ .string = e.key_ptr.* });
            }
            return Value{ .list = obj };
        }
        if (std.mem.eql(u8, name, "del")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (arg_vals[0] != .dict) {
                if (!self.mute) std.debug.print("error on line {d}: del() needs a dict\n", .{self.line});
                return ParseError.TypeError;
            }
            const key = try self.valueToString(arg_vals[1]);
            return Value{ .number = if (arg_vals[0].dict.map.remove(key)) 1 else 0 };
        }
        if (std.mem.eql(u8, name, "push")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (arg_vals[0] != .list) {
                if (!self.mute) std.debug.print("error on line {d}: push() needs a list\n", .{self.line});
                return ParseError.TypeError;
            }
            try arg_vals[0].list.items.append(self.alloc, arg_vals[1]);
            return Value{ .number = @floatFromInt(arg_vals[0].list.items.items.len) };
        }
        if (std.mem.eql(u8, name, "input")) {
            if (arg_vals.len > 1) return ParseError.ArityMismatch;
            if (self.dry) return Value{ .string = try self.alloc.dupe(u8, "") };
            if (arg_vals.len == 1 and !self.silent_run) {
                const prompt = try self.valueToString(arg_vals[0]);
                try self.stdout.writeAll(prompt);
                try self.stdout.flush();
            }
            const line = try self.readStdinLine();
            return Value{ .string = line };
        }
        if (std.mem.eql(u8, name, "args")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            return Value{ .list = self.cli_args };
        }
        if (std.mem.eql(u8, name, "exit")) {
            var code: i32 = 0;
            if (arg_vals.len == 1) {
                if (arg_vals[0] != .number or @trunc(arg_vals[0].number) != arg_vals[0].number) return ParseError.TypeError;
                code = @intFromFloat(arg_vals[0].number);
            } else if (arg_vals.len != 0) return ParseError.ArityMismatch;
            if (self.err) |e| e.exit_code = code;
            try self.stdout.flush();
            return ParseError.ExitSignal;
        }
        if (std.mem.eql(u8, name, "fail")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const msg = try self.valueToString(arg_vals[0]);
            if (self.err) |e| e.fail_msg = try self.alloc.dupe(u8, msg);
            return ParseError.FailSignal;
        }
        if (std.mem.eql(u8, name, "int")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            switch (arg_vals[0]) {
                .number => |n| return Value{ .number = @trunc(n) },
                .string => |s| {
                    const t = std.mem.trim(u8, s, " \t\r\n");
                    const n = std.fmt.parseFloat(f64, t) catch {
                        if (!self.mute) std.debug.print("error on line {d}: int() cannot parse '{s}'\n", .{ self.line, s });
                        return ParseError.BadNumber;
                    };
                    return Value{ .number = @trunc(n) };
                },
                .list => return ParseError.TypeError,
                .dict => return ParseError.TypeError,
                .instance => return ParseError.TypeError,
                .function => return ParseError.TypeError,
                .nil => return ParseError.TypeError,
            }
        }
        if (std.mem.eql(u8, name, "str")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .string = try self.valueToString(arg_vals[0]) };
        }
        if (std.mem.eql(u8, name, "split")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string or arg_vals[1] != .string) return ParseError.TypeError;
            const s = arg_vals[0].string;
            const sep = arg_vals[1].string;
            const obj = try self.alloc.create(ListObj);
            obj.* = .{ .items = .empty };
            if (sep.len == 0) {
                for (s, 0..) |ch, i| {
                    _ = ch;
                    try obj.items.append(self.alloc, Value{ .string = try self.alloc.dupe(u8, s[i .. i + 1]) });
                }
            } else {
                var it = std.mem.splitSequence(u8, s, sep);
                while (it.next()) |part| {
                    try obj.items.append(self.alloc, Value{ .string = try self.alloc.dupe(u8, part) });
                }
            }
            return Value{ .list = obj };
        }
        if (std.mem.eql(u8, name, "join")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (arg_vals[0] != .list) {
                if (!self.mute) std.debug.print("error on line {d}: join() needs a list\n", .{self.line});
                return ParseError.TypeError;
            }
            const sep = try self.valueToString(arg_vals[1]);
            var buf: std.ArrayList(u8) = .empty;
            for (arg_vals[0].list.items.items, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(self.alloc, sep);
                try buf.appendSlice(self.alloc, try self.valueToString(item));
            }
            return Value{ .string = try buf.toOwnedSlice(self.alloc) };
        }
        if (std.mem.eql(u8, name, "substr")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string or arg_vals[1] != .number or arg_vals[2] != .number) return ParseError.TypeError;
            const s = arg_vals[0].string;
            var start: i64 = @intFromFloat(@trunc(arg_vals[1].number));
            var count: i64 = @intFromFloat(@trunc(arg_vals[2].number));
            if (start < 0) start += @intCast(s.len);
            if (count < 0) count = 0;
            if (start < 0) start = 0;
            if (start > @as(i64, @intCast(s.len))) start = @intCast(s.len);
            var end = start + count;
            if (end > @as(i64, @intCast(s.len))) end = @intCast(s.len);
            return Value{ .string = try self.alloc.dupe(u8, s[@intCast(start)..@intCast(end)]) };
        }
        if (std.mem.eql(u8, name, "trim")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string) return ParseError.TypeError;
            return Value{ .string = try self.alloc.dupe(u8, std.mem.trim(u8, arg_vals[0].string, " \t\r\n")) };
        }
        if (std.mem.eql(u8, name, "upper")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string) return ParseError.TypeError;
            const out = try self.alloc.dupe(u8, arg_vals[0].string);
            for (out) |*ch| ch.* = std.ascii.toUpper(ch.*);
            return Value{ .string = out };
        }
        if (std.mem.eql(u8, name, "lower")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string) return ParseError.TypeError;
            const out = try self.alloc.dupe(u8, arg_vals[0].string);
            for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
            return Value{ .string = out };
        }
        if (std.mem.eql(u8, name, "replace")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            if (arg_vals[0] != .string or arg_vals[1] != .string or arg_vals[2] != .string) return ParseError.TypeError;
            const s = arg_vals[0].string;
            const old = arg_vals[1].string;
            const new = arg_vals[2].string;
            if (old.len == 0) return Value{ .string = try self.alloc.dupe(u8, s) };
            var buf: std.ArrayList(u8) = .empty;
            var rest = s;
            while (std.mem.indexOf(u8, rest, old)) |idx| {
                try buf.appendSlice(self.alloc, rest[0..idx]);
                try buf.appendSlice(self.alloc, new);
                rest = rest[idx + old.len ..];
            }
            try buf.appendSlice(self.alloc, rest);
            return Value{ .string = try buf.toOwnedSlice(self.alloc) };
        }
        if (std.mem.eql(u8, name, "contains")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (arg_vals[0] == .dict) {
                const key = try self.valueToString(arg_vals[1]);
                return Value{ .number = if (arg_vals[0].dict.map.contains(key)) 1 else 0 };
            }
            if (arg_vals[0] == .list) {
                for (arg_vals[0].list.items.items) |item| {
                    if (try self.valuesEqual(item, arg_vals[1])) return Value{ .number = 1 };
                }
                return Value{ .number = 0 };
            }
            const hay = try self.valueToString(arg_vals[0]);
            const needle = try self.valueToString(arg_vals[1]);
            return Value{ .number = if (std.mem.indexOf(u8, hay, needle) != null) 1 else 0 };
        }
        if (std.mem.eql(u8, name, "type")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            const t: []const u8 = switch (arg_vals[0]) {
                .number => "number",
                .string => "string",
                .list => "list",
                .dict => "dict",
                .nil => "nil",
                .function => "function",
                .instance => |o| o.type_name,
            };
            return Value{ .string = try self.alloc.dupe(u8, t) };
        }
        if (std.mem.eql(u8, name, "sort")) {
            if (arg_vals.len != 1 or arg_vals[0] != .list) return ParseError.TypeError;
            const src = arg_vals[0].list.items.items;
            var has_num = false;
            var has_str = false;
            for (src) |item| {
                if (item == .number) {
                    has_num = true;
                } else if (item == .string) {
                    has_str = true;
                } else {
                    return ParseError.TypeError;
                }
            }
            if (has_num and has_str) {
                if (!self.mute) std.debug.print("error on line {d}: sort() needs all numbers or all strings\n", .{self.line});
                return ParseError.TypeError;
            }
            const out = try self.alloc.create(ListObj);
            out.* = .{ .items = .empty };
            try out.items.appendSlice(self.alloc, src);
            std.sort.block(Value, out.items.items, {}, struct {
                fn less(_: void, a: Value, b: Value) bool {
                    if (a == .number) return a.number < b.number;
                    return std.mem.lessThan(u8, a.string, b.string);
                }
            }.less);
            return Value{ .list = out };
        }
        if (std.mem.eql(u8, name, "reverse")) {
            if (arg_vals.len != 1) return ParseError.TypeError;
            if (arg_vals[0] == .list) {
                const src = arg_vals[0].list.items.items;
                const out = try self.alloc.create(ListObj);
                out.* = .{ .items = .empty };
                try out.items.ensureTotalCapacity(self.alloc, src.len);
                var i = src.len;
                while (i > 0) {
                    i -= 1;
                    try out.items.append(self.alloc, src[i]);
                }
                return Value{ .list = out };
            }
            if (arg_vals[0] == .string) {
                const s = arg_vals[0].string;
                const out = try self.alloc.alloc(u8, s.len);
                var i = s.len;
                while (i > 0) {
                    i -= 1;
                    out[i] = s[s.len - 1 - i];
                }
                return Value{ .string = out };
            }
            return ParseError.TypeError;
        }
        if (std.mem.eql(u8, name, "sum")) {
            if (arg_vals.len != 1 or arg_vals[0] != .list) return ParseError.TypeError;
            var acc: f64 = 0;
            for (arg_vals[0].list.items.items) |item| {
                if (item != .number) return ParseError.TypeError;
                acc += item.number;
            }
            return Value{ .number = acc };
        }
        if (std.mem.eql(u8, name, "min_of") or std.mem.eql(u8, name, "max_of")) {
            if (arg_vals.len != 1 or arg_vals[0] != .list) return ParseError.TypeError;
            const items = arg_vals[0].list.items.items;
            if (items.len == 0) {
                if (!self.mute) std.debug.print("error on line {d}: {s}() needs a non-empty list\n", .{ self.line, name });
                return ParseError.IndexOutOfBounds;
            }
            var best = items[0];
            if (best != .number) return ParseError.TypeError;
            for (items) |item| {
                if (item != .number) return ParseError.TypeError;
                if ((std.mem.eql(u8, name, "min_of") and item.number < best.number) or
                    (std.mem.eql(u8, name, "max_of") and item.number > best.number)) best = item;
            }
            return best;
        }
        if (std.mem.eql(u8, name, "index_of")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            if (arg_vals[0] == .list) {
                const items = arg_vals[0].list.items.items;
                for (items, 0..) |item, idx| {
                    if (try self.valuesEqual(item, arg_vals[1])) return Value{ .number = @floatFromInt(idx) };
                }
                return Value{ .number = -1 };
            }
            if (arg_vals[0] == .string and arg_vals[1] == .string) {
                if (std.mem.indexOf(u8, arg_vals[0].string, arg_vals[1].string)) |idx| {
                    return Value{ .number = @floatFromInt(idx) };
                }
                return Value{ .number = -1 };
            }
            return ParseError.TypeError;
        }
        if (std.mem.eql(u8, name, "count")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            var n: f64 = 0;
            if (arg_vals[0] == .list) {
                for (arg_vals[0].list.items.items) |item| {
                    if (try self.valuesEqual(item, arg_vals[1])) n += 1;
                }
            } else if (arg_vals[0] == .string and arg_vals[1] == .string) {
                const hay = arg_vals[0].string;
                const needle = arg_vals[1].string;
                if (needle.len > 0) {
                    var i: usize = 0;
                    while (std.mem.indexOfPos(u8, hay, i, needle)) |idx| {
                        n += 1;
                        i = idx + needle.len;
                    }
                }
            } else {
                return ParseError.TypeError;
            }
            return Value{ .number = n };
        }
        if (std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "all")) {
            if (arg_vals.len != 1 or arg_vals[0] != .list) return ParseError.TypeError;
            const want_all = std.mem.eql(u8, name, "all");
            for (arg_vals[0].list.items.items) |item| {
                if (isTruthy(item) != want_all) return Value{ .number = @intFromBool(!want_all) };
            }
            return Value{ .number = @intFromBool(want_all) };
        }
        if (std.mem.eql(u8, name, "unique")) {
            if (arg_vals.len != 1 or arg_vals[0] != .list) return ParseError.TypeError;
            const items = arg_vals[0].list.items.items;
            const out = try self.alloc.create(ListObj);
            out.* = .{ .items = .empty };
            for (items) |item| {
                var seen = false;
                for (out.items.items) |kept| {
                    if (try self.valuesEqual(kept, item)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try out.items.append(self.alloc, item);
            }
            return Value{ .list = out };
        }
        if (std.mem.eql(u8, name, "crc32")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            var crc: u32 = 0xFFFFFFFF;
            if (arg_vals[0] == .string) {
                for (arg_vals[0].string) |b| crc = crc32Byte(crc, b);
            } else if (arg_vals[0] == .list) {
                for (arg_vals[0].list.items.items) |item| {
                    if (item != .number) return ParseError.TypeError;
                    const b: u8 = @truncate(@as(u64, @intFromFloat(@max(0, @min(255, item.number)))));
                    crc = crc32Byte(crc, b);
                }
            } else {
                return ParseError.TypeError;
            }
            return Value{ .number = @floatFromInt(crc ^ 0xFFFFFFFF) };
        }
        if (std.mem.eql(u8, name, "fname")) {
            if (arg_vals.len != 1 or arg_vals[0] != .function) return ParseError.TypeError;
            return Value{ .string = arg_vals[0].function.name };
        }
        if (std.mem.eql(u8, name, "call")) {
            if (arg_vals.len < 1 or arg_vals[0] != .function) return ParseError.TypeError;
            const fname = arg_vals[0].function.name;
            const fscope = arg_vals[0].function.scope;
            const target = self.funcs.get(fname) orelse {
                if (!self.mute) std.debug.print("error on line {d}: unknown function '{s}'\n", .{ self.line, fname });
                return ParseError.UnknownFunction;
            };
            return self.invokeScoped(target, fscope orelse self.scope, arg_vals[1..]);
        }
        if (std.mem.eql(u8, name, "abs")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @abs(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "min")) {
            if (arg_vals.len != 2 or arg_vals[0] != .number or arg_vals[1] != .number) return ParseError.TypeError;
            return Value{ .number = @min(arg_vals[0].number, arg_vals[1].number) };
        }
        if (std.mem.eql(u8, name, "max")) {
            if (arg_vals.len != 2 or arg_vals[0] != .number or arg_vals[1] != .number) return ParseError.TypeError;
            return Value{ .number = @max(arg_vals[0].number, arg_vals[1].number) };
        }
        if (std.mem.eql(u8, name, "sqrt")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            if (arg_vals[0].number < 0) {
                if (!self.mute) std.debug.print("error on line {d}: sqrt() of negative\n", .{self.line});
                return ParseError.MathError;
            }
            return Value{ .number = @sqrt(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "floor")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @floor(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "ceil")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @ceil(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "round")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @round(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "pow")) {
            if (arg_vals.len != 2 or arg_vals[0] != .number or arg_vals[1] != .number) return ParseError.TypeError;
            return Value{ .number = std.math.pow(f64, arg_vals[0].number, arg_vals[1].number) };
        }
        if (std.mem.eql(u8, name, "ord")) {
            if (arg_vals.len != 1 or arg_vals[0] != .string or arg_vals[0].string.len == 0) return ParseError.TypeError;
            return Value{ .number = @floatFromInt(arg_vals[0].string[0]) };
        }
        if (std.mem.eql(u8, name, "chr")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number or @trunc(arg_vals[0].number) != arg_vals[0].number or arg_vals[0].number < 0 or arg_vals[0].number > 0x10FFFF) return ParseError.TypeError;
            const cp: u21 = @intFromFloat(arg_vals[0].number);
            if (cp >= 0xD800 and cp <= 0xDFFF) return ParseError.TypeError;
            var buf: [4]u8 = undefined;
            if (cp < 0x80) {
                buf[0] = @intCast(cp);
                return Value{ .string = try self.alloc.dupe(u8, buf[0..1]) };
            } else if (cp < 0x800) {
                buf[0] = @intCast(0xC0 | (cp >> 6));
                buf[1] = @intCast(0x80 | (cp & 0x3F));
                return Value{ .string = try self.alloc.dupe(u8, buf[0..2]) };
            } else if (cp < 0x10000) {
                buf[0] = @intCast(0xE0 | (cp >> 12));
                buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                buf[2] = @intCast(0x80 | (cp & 0x3F));
                return Value{ .string = try self.alloc.dupe(u8, buf[0..3]) };
            } else {
                buf[0] = @intCast(0xF0 | (cp >> 18));
                buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                buf[3] = @intCast(0x80 | (cp & 0x3F));
                return Value{ .string = try self.alloc.dupe(u8, buf[0..4]) };
            }
        }
        if (std.mem.eql(u8, name, "sin")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @sin(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "cos")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @cos(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "tan")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @tan(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "asin")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number or arg_vals[0].number < -1 or arg_vals[0].number > 1) {
                if (arg_vals.len == 1 and arg_vals[0] == .number) {
                    if (!self.mute) std.debug.print("error on line {d}: asin() domain -1..1\n", .{self.line});
                    return ParseError.MathError;
                }
                return ParseError.TypeError;
            }
            return Value{ .number = std.math.asin(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "acos")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number or arg_vals[0].number < -1 or arg_vals[0].number > 1) {
                if (arg_vals.len == 1 and arg_vals[0] == .number) {
                    if (!self.mute) std.debug.print("error on line {d}: acos() domain -1..1\n", .{self.line});
                    return ParseError.MathError;
                }
                return ParseError.TypeError;
            }
            return Value{ .number = std.math.acos(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "atan")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = std.math.atan(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "log")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            if (arg_vals[0].number <= 0) {
                if (!self.mute) std.debug.print("error on line {d}: log() needs > 0\n", .{self.line});
                return ParseError.MathError;
            }
            return Value{ .number = @log(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "log10")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            if (arg_vals[0].number <= 0) {
                if (!self.mute) std.debug.print("error on line {d}: log10() needs > 0\n", .{self.line});
                return ParseError.MathError;
            }
            return Value{ .number = @log10(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "exp")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = @exp(arg_vals[0].number) };
        }
        if (std.mem.eql(u8, name, "deg")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = arg_vals[0].number * 180.0 / std.math.pi };
        }
        if (std.mem.eql(u8, name, "rad")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number) return ParseError.TypeError;
            return Value{ .number = arg_vals[0].number * std.math.pi / 180.0 };
        }
        if (std.mem.eql(u8, name, "pi")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            return Value{ .number = std.math.pi };
        }
        if (std.mem.eql(u8, name, "e")) {
            if (arg_vals.len != 0) return ParseError.ArityMismatch;
            return Value{ .number = std.math.e };
        }
        if (std.mem.eql(u8, name, "bytes")) {
            if (arg_vals.len != 1 or arg_vals[0] != .number or @trunc(arg_vals[0].number) != arg_vals[0].number or arg_vals[0].number < 0) return ParseError.TypeError;
            const n: usize = @intFromFloat(arg_vals[0].number);
            if (n > 16 * 1024 * 1024) {
                if (!self.mute) std.debug.print("error on line {d}: bytes() max 16M\n", .{self.line});
                return ParseError.LoopLimitExceeded;
            }
            const obj = try self.alloc.create(ListObj);
            obj.* = .{ .items = .empty };
            try obj.items.appendNTimes(self.alloc, Value{ .number = 0 }, n);
            return Value{ .list = obj };
        }
        if (std.mem.eql(u8, name, "peek")) {
            if (arg_vals.len != 2 or arg_vals[0] != .list) return ParseError.TypeError;
            const i = try self.normalizeIndex(arg_vals[0].list.items.items.len, arg_vals[1]);
            return arg_vals[0].list.items.items[i];
        }
        if (std.mem.eql(u8, name, "poke")) {
            if (arg_vals.len != 3 or arg_vals[0] != .list) return ParseError.TypeError;
            const i = try self.normalizeIndex(arg_vals[0].list.items.items.len, arg_vals[1]);
            if (arg_vals[2] != .number or @trunc(arg_vals[2].number) != arg_vals[2].number or arg_vals[2].number < 0 or arg_vals[2].number > 255) {
                if (!self.mute) std.debug.print("error on line {d}: poke() needs byte 0..255\n", .{self.line});
                return ParseError.TypeError;
            }
            arg_vals[0].list.items.items[i] = arg_vals[2];
            return arg_vals[2];
        }
        if (std.mem.eql(u8, name, "u8")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = try self.wrapInt(arg_vals[0], 8, false) };
        }
        if (std.mem.eql(u8, name, "u16")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = try self.wrapInt(arg_vals[0], 16, false) };
        }
        if (std.mem.eql(u8, name, "u32")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = try self.wrapInt(arg_vals[0], 32, false) };
        }
        if (std.mem.eql(u8, name, "i8")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = try self.wrapInt(arg_vals[0], 8, true) };
        }
        if (std.mem.eql(u8, name, "i16")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = try self.wrapInt(arg_vals[0], 16, true) };
        }
        if (std.mem.eql(u8, name, "i32")) {
            if (arg_vals.len != 1) return ParseError.ArityMismatch;
            return Value{ .number = try self.wrapInt(arg_vals[0], 32, true) };
        }
        if (std.mem.eql(u8, name, "pack")) {
            if (arg_vals.len != 2 or arg_vals[0] != .string or arg_vals[1] != .list) return ParseError.TypeError;
            return Value{ .list = try self.packValues(arg_vals[0].string, arg_vals[1].list.items.items) };
        }
        if (std.mem.eql(u8, name, "unpack")) {
            if (arg_vals.len != 2 or arg_vals[0] != .string or arg_vals[1] != .list) return ParseError.TypeError;
            return Value{ .list = try self.unpackValues(arg_vals[0].string, arg_vals[1].list.items.items) };
        }
        if (std.mem.eql(u8, name, "sizeof")) {
            if (arg_vals.len != 1 or arg_vals[0] != .string) return ParseError.TypeError;
            return Value{ .number = @floatFromInt(try self.fmtSize(arg_vals[0].string)) };
        }
        if (std.mem.eql(u8, name, "bits")) {
            if (arg_vals.len != 3) return ParseError.ArityMismatch;
            const v = try self.bitU64(arg_vals[0]);
            const hi = try self.bitSmall(arg_vals[1]);
            const lo = try self.bitSmall(arg_vals[2]);
            if (hi < lo) {
                if (!self.mute) std.debug.print("error on line {d}: bits() needs hi >= lo\n", .{self.line});
                return ParseError.TypeError;
            }
            const width: u6 = @intCast(hi - lo);
            var w: u64 = v >> @as(u6, @intCast(lo));
            if (width < 63) w &= (@as(u64, 1) << (width + 1)) - 1;
            return numU64(w);
        }
        if (std.mem.eql(u8, name, "setbits")) {
            if (arg_vals.len != 4) return ParseError.ArityMismatch;
            const v = try self.bitU64(arg_vals[0]);
            const hi = try self.bitSmall(arg_vals[1]);
            const lo = try self.bitSmall(arg_vals[2]);
            const f = try self.bitU64(arg_vals[3]);
            if (hi < lo) {
                if (!self.mute) std.debug.print("error on line {d}: setbits() needs hi >= lo\n", .{self.line});
                return ParseError.TypeError;
            }
            const width: u64 = @as(u64, hi) - @as(u64, lo) + 1;
            if (width < 64 and f >= (@as(u64, 1) << @as(u6, @intCast(width)))) {
                if (!self.mute) std.debug.print("error on line {d}: setbits() field too wide\n", .{self.line});
                return ParseError.TypeError;
            }
            var m2: u64 = 0;
            if (width < 64) {
                m2 = (((@as(u64, 1) << @as(u6, @intCast(width))) - 1) << @as(u6, @intCast(lo)));
            } else {
                m2 = std.math.maxInt(u64);
            }
            const out = (v & ~m2) | ((f << @as(u6, @intCast(lo))) & m2);
            return numU64(out);
        }
        if (std.mem.eql(u8, name, "flag")) {
            if (arg_vals.len != 2) return ParseError.ArityMismatch;
            const v = try self.bitU64(arg_vals[0]);
            const n = try self.bitSmall(arg_vals[1]);
            return Value{ .number = if ((v >> @as(u6, @intCast(n))) & 1 == 1) 1 else 0 };
        }
        if (std.mem.eql(u8, name, "outb") or std.mem.eql(u8, name, "inb") or
            std.mem.eql(u8, name, "sti") or std.mem.eql(u8, name, "cli") or
            std.mem.eql(u8, name, "ticks") or std.mem.eql(u8, name, "irq_addr") or
            std.mem.eql(u8, name, "idt_set") or std.mem.eql(u8, name, "idt_load") or
            std.mem.eql(u8, name, "key") or std.mem.eql(u8, name, "irq1_addr") or
            std.mem.eql(u8, name, "poke32") or std.mem.eql(u8, name, "peek32") or
            std.mem.eql(u8, name, "cr3") or std.mem.eql(u8, name, "pg_on") or
            std.mem.eql(u8, name, "kmalloc") or std.mem.eql(u8, name, "kfree") or
            std.mem.eql(u8, name, "syscall") or std.mem.eql(u8, name, "syscall_addr") or
            std.mem.eql(u8, name, "addr") or std.mem.eql(u8, name, "gdt_set") or
            std.mem.eql(u8, name, "gdt_load") or std.mem.eql(u8, name, "tss") or
            std.mem.eql(u8, name, "enter_user") or std.mem.eql(u8, name, "elf_load") or
            std.mem.eql(u8, name, "user_base") or std.mem.eql(u8, name, "user_len") or
            std.mem.eql(u8, name, "user2_base") or std.mem.eql(u8, name, "user2_len") or
            std.mem.eql(u8, name, "fault_addr") or std.mem.eql(u8, name, "task_create") or
            std.mem.eql(u8, name, "tasks") or std.mem.eql(u8, name, "idle"))
        {
            if (!self.mute) std.debug.print("error on line {d}: '{s}()' only works in freestanding kernels (--emit-c --freestanding)\n", .{ self.line, name });
            return ParseError.UnknownFunction;
        }
        const f = self.funcs.get(name) orelse {
            // maybe a struct constructor: Point(3, 4)
            if (self.structs.getPtr(name)) |def| {
                if (arg_vals.len != def.fields.len) {
                    if (!self.mute) std.debug.print("error on line {d}: '{s}' needs {d} fields, got {d}\n", .{ self.line, name, def.fields.len, arg_vals.len });
                    return ParseError.ArityMismatch;
                }
                const obj = try self.alloc.create(StructObj);
                obj.* = .{ .type_name = def.name, .fields = def.fields, .values = .empty };
                try obj.values.appendSlice(self.alloc, arg_vals);
                return Value{ .instance = obj };
            }
            if (!self.mute) std.debug.print("error on line {d}: unknown function '{s}'\n", .{ self.line, name });
            return ParseError.UnknownFunction;
        };
        return self.invokeFunction(f, arg_vals);
    }

    fn invokeFunction(self: *Parser, f: Function, arg_vals: []const Value) anyerror!Value {
        return self.invokeScoped(f, f.scope orelse self.scope, arg_vals);
    }

    fn invokeScoped(self: *Parser, f: Function, parent: *Scope, arg_vals: []const Value) anyerror!Value {
        if (arg_vals.len != f.params.len) {
            if (!self.mute) std.debug.print("error on line {d}: '{s}' expects {d} args, got {d}\n", .{ self.line, f.name, f.params.len, arg_vals.len });
            return ParseError.ArityMismatch;
        }
        if (self.depth >= 1000) {
            if (!self.mute) std.debug.print("error on line {d}: call depth exceeded 1000 in '{s}'\n", .{ self.line, f.name });
            return ParseError.CallDepthExceeded;
        }
        if (self.trace) try self.traceCall(f.name, true, null);
        const frame = try self.alloc.create(Scope);
        frame.* = .{ .vars = std.StringHashMap(Value).init(self.alloc), .parent = parent };
        for (f.params, 0..) |pname, idx| {
            try frame.vars.put(try self.alloc.dupe(u8, pname), arg_vals[idx]);
        }
        var child = Parser{
            .src = f.body,
            .pos = 0,
            .line = f.def_line,
            .alloc = self.alloc,
            .stdout = self.stdout,
            .funcs = self.funcs,
            .structs = self.structs,
            .scope = frame,
            .io = self.io,
            .stdin = self.stdin,
            .imported_os = self.imported_os,
            .imported_physics = self.imported_physics,
            .imported_heap = self.imported_heap,
            .imported_gui = self.imported_gui,
            .imported_hex = self.imported_hex,
            .imported_random = self.imported_random,
            .imported_strings = self.imported_strings,
            .gui_cbs = self.gui_cbs,
            .imported_cpu = self.imported_cpu,
            .envmap = self.envmap,
            .imported_json = self.imported_json,
            .imported_time = self.imported_time,
            .cli_args = self.cli_args,
            .file = self.file,
            .base_dir = self.base_dir,
            .imported_files = self.imported_files,
            .err = self.err,
            .dry = self.dry,
            .mute = self.mute,
            .silent_run = self.silent_run,
            .trace = self.trace,
            .trace_indent = self.trace_indent,
            .trace_out = self.trace_out,
            .depth = self.depth + 1,
        };
        child.run() catch |err| {
            if (err == ParseError.ReturnSignal) {
                const ret = child.return_value orelse Value{ .number = 0 };
                if (self.trace) try self.traceCall(f.name, false, ret);
                return ret;
            }
            return err;
        };
        const result = child.return_value orelse Value{ .number = 0 };
        if (self.trace) try self.traceCall(f.name, false, result);
        return result;
    }

    fn expectEndOfStatement(self: *Parser) !void {
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == ';') self.pos += 1;
        self.skipSpaces();
        if (self.pos >= self.src.len) return;
        const c = self.src[self.pos];
        if (c == '\n' or c == '\r') return;
        if (c == '#') return;
        if (c == '}') return;
        if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') return;
        if (!self.mute) std.debug.print("error on line {d}: expected newline after statement\n", .{self.line});
        return ParseError.ExpectedNewline;
    }

    fn parseExpr(self: *Parser) anyerror!Value {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) anyerror!Value {
        var left = try self.parseAnd();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.matchWordAt(self.pos, "or")) {
                self.pos += 2;
                const right = try self.parseAnd();
                left = Value{ .number = if (isTruthy(left) or isTruthy(right)) 1 else 0 };
            } else {
                self.pos = sp;
                break;
            }
        }
        return left;
    }

    fn parseAnd(self: *Parser) anyerror!Value {
        var left = try self.parseNot();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.matchWordAt(self.pos, "and")) {
                self.pos += 3;
                const right = try self.parseNot();
                left = Value{ .number = if (isTruthy(left) and isTruthy(right)) 1 else 0 };
            } else {
                self.pos = sp;
                break;
            }
        }
        return left;
    }

    fn parseNot(self: *Parser) anyerror!Value {
        const sp = self.pos;
        self.skipSpaces();
        if (self.matchWordAt(self.pos, "not")) {
            self.pos += 3;
            const v = try self.parseNot();
            return Value{ .number = if (isTruthy(v)) 0 else 1 };
        }
        self.pos = sp;
        return self.parseCmp();
    }

    fn parseCmp(self: *Parser) anyerror!Value {
        var left = try self.parseBitOr();
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
                op = if (self.src[self.pos] == '<') 3 else 4;
                oplen = 1;
            }
            if (op == 0) {
                self.pos = sp;
                break;
            }
            self.pos += oplen;
            const right = try self.parseAdd();
            left = try self.applyCmp(left, right, op);
        }
        return left;
    }

    fn applyCmp(self: *Parser, l: Value, r: Value, op: u8) !Value {
        if (l == .list or r == .list or l == .dict or r == .dict or l == .instance or r == .instance or l == .nil or r == .nil) {
            if (op == 1 or op == 2) {
                const eq = try self.valuesEqual(l, r);
                return Value{ .number = if ((op == 1 and eq) or (op == 2 and !eq)) 1 else 0 };
            }
            if (!self.mute) std.debug.print("error on line {d}: cannot order lists\n", .{self.line});
            return ParseError.TypeError;
        }
        var eq = false;
        var lt = false;
        if (l == .number and r == .number) {
            eq = l.number == r.number;
            lt = l.number < r.number;
        } else {
            const ls = try self.valueToString(l);
            const rs = try self.valueToString(r);
            const ord = std.mem.order(u8, ls, rs);
            eq = ord == .eq;
            lt = ord == .lt;
        }
        const res = switch (op) {
            1 => eq,
            2 => !eq,
            3 => lt,
            4 => (!eq and !lt),
            5 => (lt or eq),
            6 => (!lt),
            else => false,
        };
        return Value{ .number = if (res) 1 else 0 };
    }

    fn valuesEqual(self: *Parser, l: Value, r: Value) !bool {
        if (l == .number and r == .number) return l.number == r.number;
        if (l == .string and r == .string) return std.mem.eql(u8, l.string, r.string);
        if (l == .list and r == .list) {
            const a = l.list.items.items;
            const b = r.list.items.items;
            if (a.len != b.len) return false;
            for (a, 0..) |av, i| {
                if (!try self.valuesEqual(av, b[i])) return false;
            }
            return true;
        }
        if (l == .dict and r == .dict) {
            if (l.dict.map.count() != r.dict.map.count()) return false;
            var it = l.dict.map.iterator();
            while (it.next()) |e| {
                const other = r.dict.map.get(e.key_ptr.*) orelse return false;
                if (!try self.valuesEqual(e.value_ptr.*, other)) return false;
            }
            return true;
        }
        if (l == .instance and r == .instance) {
            if (!std.mem.eql(u8, l.instance.type_name, r.instance.type_name)) return false;
            if (l.instance.fields.len != r.instance.fields.len) return false;
            for (l.instance.fields, 0..) |f, i| {
                if (!std.mem.eql(u8, f, r.instance.fields[i])) return false;
                if (!try self.valuesEqual(l.instance.values.items[i], r.instance.values.items[i])) return false;
            }
            return true;
        }
        if (l == .function and r == .function) return std.mem.eql(u8, l.function.name, r.function.name);
        // number vs string etc: compare stringified
        const ls = try self.valueToString(l);
        const rs = try self.valueToString(r);
        return std.mem.eql(u8, ls, rs);
    }

    fn parseBitOr(self: *Parser) anyerror!Value {
        var left = try self.parseBitXor();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '|') {
                self.pos += 1;
                const right = try self.parseBitXor();
                left = try self.applyBitwise(left, right, '|');
            } else {
                self.pos = sp;
                break;
            }
        }
        return left;
    }

    fn parseBitXor(self: *Parser) anyerror!Value {
        var left = try self.parseBitAnd();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '^') {
                self.pos += 1;
                const right = try self.parseBitAnd();
                left = try self.applyBitwise(left, right, '^');
            } else {
                self.pos = sp;
                break;
            }
        }
        return left;
    }

    fn parseBitAnd(self: *Parser) anyerror!Value {
        var left = try self.parseShift();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '&') {
                self.pos += 1;
                const right = try self.parseShift();
                left = try self.applyBitwise(left, right, '&');
            } else {
                self.pos = sp;
                break;
            }
        }
        return left;
    }

    fn parseShift(self: *Parser) anyerror!Value {
        var left = try self.parseRange();
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
            const right = try self.parseRange();
            left = try self.applyShift(left, right, op);
        }
        return left;
    }

    fn bitU64(self: *Parser, v: Value) !u64 {
        if (v != .number or @trunc(v.number) != v.number or v.number < -9.223372036854776e18 or v.number > 9.223372036854776e18) {
            if (!self.mute) std.debug.print("error on line {d}: bitwise needs 64-bit integers\n", .{self.line});
            return ParseError.TypeError;
        }
        const i: i64 = @intFromFloat(v.number);
        return @bitCast(i);
    }

    fn numU64(u: u64) Value {
        const i: i64 = @bitCast(u);
        return Value{ .number = @floatFromInt(i) };
    }

    fn bitSmall(self: *Parser, v: Value) !u8 {
        if (v != .number or @trunc(v.number) != v.number or v.number < 0 or v.number > 63) {
            if (!self.mute) std.debug.print("error on line {d}: bit index needs 0..63\n", .{self.line});
            return ParseError.TypeError;
        }
        return @intFromFloat(v.number);
    }

    // C-style wrapping convert to bits-wide (un)signed int
    fn wrapInt(self: *Parser, v: Value, bits: u6, signed: bool) !f64 {
        if (v != .number or @trunc(v.number) != v.number or @abs(v.number) >= 9007199254740992.0) {
            if (!self.mute) std.debug.print("error on line {d}: sized int needs an integer\n", .{self.line});
            return ParseError.TypeError;
        }
        const m: f64 = @floatFromInt(@as(u64, 1) << bits);
        var r = @mod(v.number, m);
        if (signed and r >= m / 2.0) r -= m;
        return r;
    }

    // pack format: optional < (little, default) or > (big), codes B H I b h i, x = pad
    fn fmtSize(self: *Parser, fmt: []const u8) !usize {
        var size: usize = 0;
        for (fmt) |c| {
            switch (c) {
                'B', 'b', 'x' => size += 1,
                'H', 'h' => size += 2,
                'I', 'i' => size += 4,
                '<', '>', ' ' => {},
                else => {
                    if (!self.mute) std.debug.print("error on line {d}: bad pack code '{c}'\n", .{ self.line, c });
                    return ParseError.TypeError;
                },
            }
        }
        return size;
    }

    fn packValues(self: *Parser, fmt: []const u8, vals: []const Value) !*ListObj {
        var little = true;
        var vi: usize = 0;
        const obj = try self.alloc.create(ListObj);
        obj.* = .{ .items = .empty };
        for (fmt) |c| {
            switch (c) {
                '<' => little = true,
                '>' => little = false,
                ' ' => {},
                'x' => try obj.items.append(self.alloc, Value{ .number = 0 }),
                'B', 'H', 'I', 'b', 'h', 'i' => {
                    if (vi >= vals.len) {
                        if (!self.mute) std.debug.print("error on line {d}: pack() needs more values\n", .{self.line});
                        return ParseError.ArityMismatch;
                    }
                    const bits: u6 = switch (c) {
                        'B', 'b' => 8,
                        'H', 'h' => 16,
                        else => 32,
                    };
                    const signed = c == 'b' or c == 'h' or c == 'i';
                    const w = try self.wrapInt(vals[vi], bits, signed);
                    vi += 1;
                    // to unsigned pattern of `bits` width
                    const m: f64 = @floatFromInt(@as(u64, 1) << bits);
                    var u = @mod(w, m);
                    if (u < 0) u += m;
                    var k: usize = 0;
                    const nbytes: usize = bits / 8;
                    while (k < nbytes) : (k += 1) {
                        const shift: u6 = @intCast(if (little) k * 8 else (nbytes - 1 - k) * 8);
                        const byte: u64 = (@as(u64, @intFromFloat(u)) >> shift) & 0xFF;
                        try obj.items.append(self.alloc, Value{ .number = @floatFromInt(byte) });
                    }
                },
                else => {
                    if (!self.mute) std.debug.print("error on line {d}: bad pack code '{c}'\n", .{ self.line, c });
                    return ParseError.TypeError;
                },
            }
        }
        if (vi != vals.len) {
            if (!self.mute) std.debug.print("error on line {d}: pack() got extra values\n", .{self.line});
            return ParseError.ArityMismatch;
        }
        return obj;
    }

    fn unpackValues(self: *Parser, fmt: []const u8, data: []const Value) !*ListObj {
        var bytes: std.ArrayList(u8) = .empty;
        for (data) |item| {
            if (item != .number or @trunc(item.number) != item.number or item.number < 0 or item.number > 255) {
                if (!self.mute) std.debug.print("error on line {d}: unpack() needs bytes 0..255\n", .{self.line});
                return ParseError.TypeError;
            }
            try bytes.append(self.alloc, @intFromFloat(item.number));
        }
        const raw = bytes.items;
        var little = true;
        var pos: usize = 0;
        const obj = try self.alloc.create(ListObj);
        obj.* = .{ .items = .empty };
        for (fmt) |c| {
            switch (c) {
                '<' => little = true,
                '>' => little = false,
                ' ' => {},
                'x' => {
                    if (pos >= raw.len) {
                        if (!self.mute) std.debug.print("error on line {d}: unpack() short data\n", .{self.line});
                        return ParseError.UnexpectedEof;
                    }
                    pos += 1;
                },
                'B', 'H', 'I', 'b', 'h', 'i' => {
                    const bits: u6 = switch (c) {
                        'B', 'b' => 8,
                        'H', 'h' => 16,
                        else => 32,
                    };
                    const nbytes: usize = bits / 8;
                    if (pos + nbytes > raw.len) {
                        if (!self.mute) std.debug.print("error on line {d}: unpack() short data\n", .{self.line});
                        return ParseError.UnexpectedEof;
                    }
                    var u: u64 = 0;
                    var k: usize = 0;
                    while (k < nbytes) : (k += 1) {
                        const shift: u6 = @intCast(if (little) k * 8 else (nbytes - 1 - k) * 8);
                        u |= @as(u64, raw[pos + k]) << shift;
                    }
                    pos += nbytes;
                    const signed = c == 'b' or c == 'h' or c == 'i';
                    if (signed) {
                        const half: u64 = @as(u64, 1) << (bits - 1);
                        if (u >= half) {
                            const full: f64 = @floatFromInt(@as(u64, 1) << bits);
                            const uf: f64 = @floatFromInt(u);
                            try obj.items.append(self.alloc, Value{ .number = uf - full });
                        } else {
                            try obj.items.append(self.alloc, Value{ .number = @floatFromInt(u) });
                        }
                    } else {
                        try obj.items.append(self.alloc, Value{ .number = @floatFromInt(u) });
                    }
                },
                else => {
                    if (!self.mute) std.debug.print("error on line {d}: bad pack code '{c}'\n", .{ self.line, c });
                    return ParseError.TypeError;
                },
            }
        }
        if (pos != raw.len) {
            if (!self.mute) std.debug.print("error on line {d}: unpack() trailing bytes\n", .{self.line});
            return ParseError.UnexpectedEof;
        }
        return obj;
    }

    fn applyBitwise(self: *Parser, l: Value, r: Value, op: u8) !Value {
        const a = try self.bitU64(l);
        const b = try self.bitU64(r);
        return numU64(switch (op) {
            '&' => a & b,
            '|' => a | b,
            else => a ^ b,
        });
    }

    fn applyShift(self: *Parser, l: Value, r: Value, op: u8) !Value {
        const a = try self.bitU64(l);
        if (r != .number or @trunc(r.number) != r.number or r.number < 0 or r.number > 63) {
            if (!self.mute) std.debug.print("error on line {d}: shift needs 0..63\n", .{self.line});
            return ParseError.TypeError;
        }
        const b: u6 = @intCast(@as(i64, @intFromFloat(r.number)));
        if (op == '<') {
            const ov = @shlWithOverflow(a, b);
            return numU64(ov[0]);
        } else {
            const ia: i64 = @bitCast(a);
            return Value{ .number = @floatFromInt(ia >> b) };
        }
    }

    fn parseRange(self: *Parser) anyerror!Value {
        var left = try self.parseAdd();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '.' and self.src[self.pos + 1] == '.') {
                self.pos += 2;
                self.skipSpaces();
                const right = try self.parseAdd();
                left = try self.makeRange(left, right);
            } else {
                self.pos = sp;
                break;
            }
        }
        return left;
    }

    fn makeRange(self: *Parser, l: Value, r: Value) !Value {
        if (l != .number or r != .number or @trunc(l.number) != l.number or @trunc(r.number) != r.number) {
            if (!self.mute) std.debug.print("error on line {d}: ranges need integers (a..b)\n", .{self.line});
            return ParseError.TypeError;
        }
        const a: i64 = @intFromFloat(l.number);
        const b: i64 = @intFromFloat(r.number);
        const step: i64 = if (b >= a) 1 else -1;
        var count: u64 = 0;
        var t = a;
        while (true) {
            count += 1;
            if (count > 1000000) {
                if (!self.mute) std.debug.print("error on line {d}: range too large (max 1M)\n", .{self.line});
                return ParseError.LoopLimitExceeded;
            }
            if (t == b) break;
            t += step;
        }
        const obj = try self.alloc.create(ListObj);
        obj.* = .{ .items = .empty };
        t = a;
        while (true) {
            try obj.items.append(self.alloc, Value{ .number = @floatFromInt(t) });
            if (t == b) break;
            t += step;
        }
        return Value{ .list = obj };
    }

    fn parseAdd(self: *Parser) anyerror!Value {
        var left = try self.parseMul();
        while (true) {
            self.skipSpaces();
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                const op = self.src[self.pos];
                self.pos += 1;
                const right = try self.parseMul();
                left = try self.applyAddSub(left, right, op);
            } else break;
        }
        return left;
    }

    fn parseMul(self: *Parser) anyerror!Value {
        var left = try self.parseFactor();
        while (true) {
            self.skipSpaces();
            if (self.pos < self.src.len and (self.src[self.pos] == '*' or self.src[self.pos] == '/' or self.src[self.pos] == '%')) {
                const op = self.src[self.pos];
                self.pos += 1;
                const right = try self.parseFactor();
                left = try self.applyMulDivMod(left, right, op);
            } else break;
        }
        return left;
    }

    fn parseFactor(self: *Parser) anyerror!Value {
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == '~') {
            self.pos += 1;
            const v = try self.parseFactor();
            const a = try self.bitU64(v);
            return numU64(~a);
        }
        var base = try self.parsePrimary();
        while (true) {
            const sp = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '[') {
                self.pos += 1;
                const ix = try self.parseExpr();
                self.skipSpaces();
                if (self.pos >= self.src.len or self.src[self.pos] != ']') return ParseError.ExpectedRBracket;
                self.pos += 1;
                if (base == .list) {
                    const i = try self.normalizeIndex(base.list.items.items.len, ix);
                    base = base.list.items.items[i];
                } else if (base == .string) {
                    const i = try self.normalizeIndex(base.string.len, ix);
                    base = Value{ .string = base.string[i .. i + 1] };
                } else if (base == .dict) {
                    const key = try self.valueToString(ix);
                    base = base.dict.map.get(key) orelse {
                        if (!self.mute) std.debug.print("error on line {d}: key '{s}' missing\n", .{ self.line, key });
                        return ParseError.KeyMissing;
                    };
                } else {
                    if (!self.mute) std.debug.print("error on line {d}: not indexable (only lists/dicts/strings)\n", .{self.line});
                    return ParseError.NotIndexable;
                }
            } else if (self.pos < self.src.len and self.src[self.pos] == '.' and self.pos + 1 < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos + 1]) or self.src[self.pos + 1] == '_')) {
                // field read: p.x (never consumes '..' ranges)
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
                const field = self.src[start..self.pos];
                if (base != .instance) {
                    if (!self.mute) std.debug.print("error on line {d}: no field '{s}' here\n", .{ self.line, field });
                    return ParseError.TypeError;
                }
                const fi = structFieldIndex(base.instance.type_name, base.instance.fields, field) orelse {
                    if (!self.mute) std.debug.print("error on line {d}: no field '{s}'\n", .{ self.line, field });
                    return ParseError.UnknownVariable;
                };
                base = base.instance.values.items[fi];
            } else if (base == .function and self.pos < self.src.len and self.src[self.pos] == '(') {
                // call through a function value: cb(x) / handlers[i](x)
                self.pos += 1;
                var arg_list: std.ArrayList(Value) = .empty;
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                } else {
                    while (true) {
                        const av = try self.parseExpr();
                        try arg_list.append(self.alloc, av);
                        self.skipSpaces();
                        if (self.pos < self.src.len and self.src[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                            self.pos += 1;
                            break;
                        } else {
                            return ParseError.ExpectedRParen;
                        }
                    }
                }
                const arg_slice = try arg_list.toOwnedSlice(self.alloc);
                const fv = base.function;
                const target = self.funcs.get(fv.name) orelse {
                    if (!self.mute) std.debug.print("error on line {d}: unknown function '{s}'\n", .{ self.line, fv.name });
                    return ParseError.UnknownFunction;
                };
                base = try self.invokeScoped(target, fv.scope orelse self.scope, arg_slice);
            } else {
                self.pos = sp;
                break;
            }
        }
        return base;
    }

    fn parsePrimary(self: *Parser) anyerror!Value {
        self.skipSpaces();
        if (self.pos >= self.src.len) return ParseError.UnexpectedEof;
        const c = self.src[self.pos];
        if (c == '(') {
            self.pos += 1;
            const v = try self.parseExpr();
            self.skipSpaces();
            if (self.pos >= self.src.len or self.src[self.pos] != ')') return ParseError.ExpectedRParen;
            self.pos += 1;
            return v;
        }
        if (c == '[') {
            return Value{ .list = try self.parseListLiteral() };
        }
        if (c == '{') {
            return Value{ .dict = try self.parseDictLiteral() };
        }
        if (c == '"' or c == '\'') {
            const s = try self.parseStringAlloc();
            return Value{ .string = s };
        }
        if (c == '-' and self.pos + 1 < self.src.len and (std.ascii.isDigit(self.src[self.pos + 1]) or self.src[self.pos + 1] == '.' or self.src[self.pos + 1] == '(')) {
            const look = self.pos + 1;
            if (self.src[look] == '(') {
                self.pos += 1;
                const v = try self.parseFactor();
                if (v != .number) return ParseError.TypeError;
                return Value{ .number = -v.number };
            }
        }
        if (c == '-' or std.ascii.isDigit(c) or c == '.') {
            const num = try self.parseNumber();
            return Value{ .number = num };
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const name = try self.parseIdent();
            if (std.mem.eql(u8, name, "true")) return Value{ .number = 1 };
            if (std.mem.eql(u8, name, "false")) return Value{ .number = 0 };
            if (std.mem.eql(u8, name, "nil")) return Value{ .nil = {} };
            const after_ident = self.pos;
            self.skipSpaces();
            if (self.pos < self.src.len and self.src[self.pos] == '.') {
                // module call os.read(...) — but p.x is a field read;
                // only commit to call syntax if '(' follows the method name
                self.pos += 1;
                self.skipSpaces();
                // method must be ident-start, else not a call (e.g. range residue)
                if (self.pos < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos]) or self.src[self.pos] == '_')) {
                    const mstart = self.pos;
                    while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
                    const method = self.src[mstart..self.pos];
                    var tmp = self.pos;
                    while (tmp < self.src.len and (self.src[tmp] == ' ' or self.src[tmp] == '\t')) : (tmp += 1) {}
                    if (tmp < self.src.len and self.src[tmp] == '(') {
                        self.pos = tmp + 1;
                        var arg_list: std.ArrayList(Value) = .empty;
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                } else {
                    while (true) {
                        const av = try self.parseExpr();
                        try arg_list.append(self.alloc, av);
                        self.skipSpaces();
                        if (self.pos < self.src.len and self.src[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                            self.pos += 1;
                            break;
                        } else {
                            return ParseError.ExpectedRParen;
                        }
                    }
                }
                const arg_slice = try arg_list.toOwnedSlice(self.alloc);
                return try self.callModuleMethod(name, method, arg_slice);
                    }
                }
                // not a module call — rewind; postfix handles .field reads
                self.pos = after_ident;
            }
            if (self.pos < self.src.len and self.src[self.pos] == '(') {
                self.pos += 1;
                var arg_list: std.ArrayList(Value) = .empty;
                self.skipSpaces();
                if (self.pos < self.src.len and self.src[self.pos] == ')') {
                    self.pos += 1;
                } else {
                    while (true) {
                        const av = try self.parseExpr();
                        try arg_list.append(self.alloc, av);
                        self.skipSpaces();
                        if (self.pos < self.src.len and self.src[self.pos] == ',') {
                            self.pos += 1;
                            continue;
                        } else if (self.pos < self.src.len and self.src[self.pos] == ')') {
                            self.pos += 1;
                            break;
                        } else {
                            return ParseError.ExpectedRParen;
                        }
                    }
                }
                const arg_slice = try arg_list.toOwnedSlice(self.alloc);
                if (self.scopeGet(name)) |bv| {
                    if (bv == .function) {
                        const target = self.funcs.get(bv.function.name) orelse {
                            if (!self.mute) std.debug.print("error on line {d}: unknown function '{s}'\n", .{ self.line, bv.function.name });
                            return ParseError.UnknownFunction;
                        };
                        return self.invokeScoped(target, bv.function.scope orelse self.scope, arg_slice);
                    }
                }
                return try self.callFunction(name, arg_slice);
            } else {
                self.pos = after_ident;
                if (self.scopeGet(name)) |v| return v;
                if (self.funcs.get(name)) |fdef| return Value{ .function = .{ .name = name, .scope = fdef.scope } };
                if (!self.mute) std.debug.print("error on line {d}: unknown variable '{s}'\n", .{ self.line, name });
                return ParseError.UnknownVariable;
            }
        }
        if (!self.mute) std.debug.print("error on line {d}: unexpected character '{c}'\n", .{ self.line, c });
        return ParseError.UnexpectedEof;
    }

    fn parseListLiteral(self: *Parser) anyerror!*ListObj {
        // at '['
        self.pos += 1;
        const obj = try self.alloc.create(ListObj);
        obj.* = .{ .items = .empty };
        while (true) {
            self.skipListWs();
            if (self.pos < self.src.len and self.src[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            const v = try self.parseExpr();
            try obj.items.append(self.alloc, v);
            self.skipListWs();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            } else if (self.pos < self.src.len and self.src[self.pos] == ']') {
                self.pos += 1;
                break;
            } else {
                if (!self.mute) std.debug.print("error on line {d}: expected ',' or ']' in list\n", .{self.line});
                return ParseError.ExpectedRBracket;
            }
        }
        return obj;
    }

    fn parseDictLiteral(self: *Parser) anyerror!*DictObj {
        // at '{' — keys are "strings", numbers, or bare idents (literal names)
        self.pos += 1;
        const obj = try self.alloc.create(DictObj);
        obj.* = .{ .map = std.StringHashMap(Value).init(self.alloc) };
        while (true) {
            self.skipListWs();
            if (self.pos < self.src.len and self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            var key: []const u8 = undefined;
            if (self.pos < self.src.len and (self.src[self.pos] == '"' or self.src[self.pos] == '\'')) {
                key = try self.parseStringAlloc();
            } else if (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '-')) {
                const num = try self.parseNumber();
                key = try self.valueToString(Value{ .number = num });
            } else {
                key = try self.parseIdent();
            }
            self.skipListWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ':') {
                if (!self.mute) std.debug.print("error on line {d}: expected ':' after dict key\n", .{self.line});
                return ParseError.ExpectedEquals;
            }
            self.pos += 1;
            const v = try self.parseExpr();
            try obj.map.put(try self.alloc.dupe(u8, key), v);
            self.skipListWs();
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            } else if (self.pos < self.src.len and self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            } else {
                if (!self.mute) std.debug.print("error on line {d}: expected ',' or '}}' in dict\n", .{self.line});
                return ParseError.ExpectedRBrace;
            }
        }
        return obj;
    }

    fn skipListWs(self: *Parser) void {
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

    fn matchWordAt(self: *Parser, at: usize, word: []const u8) bool {
        if (at + word.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[at .. at + word.len], word)) return false;
        if (at + word.len < self.src.len) {
            const c = self.src[at + word.len];
            if (std.ascii.isAlphanumeric(c) or c == '_') return false;
        }
        return true;
    }

    fn applyAddSub(self: *Parser, l: Value, r: Value, op: u8) !Value {
        if (op == '+') {
            if (l == .list and r == .list) {
                const obj = try self.alloc.create(ListObj);
                obj.* = .{ .items = .empty };
                try obj.items.appendSlice(self.alloc, l.list.items.items);
                try obj.items.appendSlice(self.alloc, r.list.items.items);
                return Value{ .list = obj };
            }
            if (l == .string or r == .string) {
                const ls = try self.valueToString(l);
                const rs = try self.valueToString(r);
                const out = try std.mem.concat(self.alloc, u8, &.{ ls, rs });
                return Value{ .string = out };
            }
            if (l == .list or r == .list) {
                if (!self.mute) std.debug.print("error on line {d}: '+' needs two lists (or numbers/strings)\n", .{self.line});
                return ParseError.TypeError;
            }
            if (l == .dict or r == .dict) {
                if (!self.mute) std.debug.print("error on line {d}: '+' cannot merge dicts\n", .{self.line});
                return ParseError.TypeError;
            }
            if (l == .instance or r == .instance or l == .nil or r == .nil) {
                if (!self.mute) std.debug.print("error on line {d}: '+' needs numbers/strings/lists\n", .{self.line});
                return ParseError.TypeError;
            }
            return Value{ .number = l.number + r.number };
        } else {
            if (l != .number or r != .number) {
                if (!self.mute) std.debug.print("error on line {d}: '-' needs numbers\n", .{self.line});
                return ParseError.TypeError;
            }
            return Value{ .number = l.number - r.number };
        }
    }

    fn applyMulDivMod(self: *Parser, l: Value, r: Value, op: u8) !Value {
        if (l != .number or r != .number) {
            if (!self.mute) std.debug.print("error on line {d}: arithmetic needs numbers\n", .{self.line});
            return ParseError.TypeError;
        }
        switch (op) {
            '*' => return Value{ .number = l.number * r.number },
            '/' => {
                if (r.number == 0) return ParseError.DivisionByZero;
                return Value{ .number = l.number / r.number };
            },
            '%' => {
                if (r.number == 0) return ParseError.DivisionByZero;
                return Value{ .number = @mod(l.number, r.number) };
            },
            else => return ParseError.UnexpectedEof,
        }
    }

    fn printValue(self: *Parser, v: Value) !void {
        const s = try self.valueToString(v);
        try self.stdout.writeAll(s);
    }

    fn valueToString(self: *Parser, v: Value) ![]const u8 {
        switch (v) {
            .string => |s| return s,
            .number => |n| {
                if (@trunc(n) == n and @abs(n) < 9007199254740991.0) {
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{@as(i64, @intFromFloat(n))});
                } else {
                    return try std.fmt.allocPrint(self.alloc, "{d}", .{n});
                }
            },
            .list => |l| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '[');
                for (l.items.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    const s = try self.valueToString(item);
                    try buf.appendSlice(self.alloc, s);
                }
                try buf.append(self.alloc, ']');
                return try buf.toOwnedSlice(self.alloc);
            },
            .dict => |d| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '{');
                var it = d.map.iterator();
                var first = true;
                while (it.next()) |e| {
                    if (!first) try buf.appendSlice(self.alloc, ", ");
                    first = false;
                    try buf.append(self.alloc, '"');
                    try buf.appendSlice(self.alloc, e.key_ptr.*);
                    try buf.appendSlice(self.alloc, "\": ");
                    try buf.appendSlice(self.alloc, try self.valueToString(e.value_ptr.*));
                }
                try buf.append(self.alloc, '}');
                return try buf.toOwnedSlice(self.alloc);
            },
            .instance => |o| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(self.alloc, o.type_name);
                try buf.append(self.alloc, '{');
                for (o.fields, 0..) |f, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    try buf.appendSlice(self.alloc, f);
                    try buf.appendSlice(self.alloc, ": ");
                    try buf.appendSlice(self.alloc, try self.valueToString(o.values.items[i]));
                }
                try buf.append(self.alloc, '}');
                return try buf.toOwnedSlice(self.alloc);
            },
            .nil => return try self.alloc.dupe(u8, "nil"),
            .function => |fv| return try std.fmt.allocPrint(self.alloc, "<fn {s}>", .{fv.name}),
        }
    }

    fn readStdinLine(self: *Parser) ![]const u8 {
        const raw_opt = self.stdin.takeDelimiter('\n') catch |err| {
            if (err == error.EndOfStream) return try self.alloc.dupe(u8, "");
            return err;
        };
        const raw = raw_opt orelse return try self.alloc.dupe(u8, "");
        var s = raw;
        if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
        return try self.alloc.dupe(u8, s);
    }

    fn parseIdent(self: *Parser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
        if (start == self.pos) return ParseError.ExpectedIdent;
        return self.src[start..self.pos];
    }

    fn parseNumber(self: *Parser) !f64 {
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
        if (!seen_digit) return ParseError.BadNumber;
        const tok = self.src[start..self.pos];
        return std.fmt.parseFloat(f64, tok) catch return ParseError.BadNumber;
    }

    fn parseStringAlloc(self: *Parser) ![]const u8 {
        const quote = self.src[self.pos];
        self.pos += 1;
        var out_len: usize = 0;
        var j = self.pos;
        var closed = false;
        while (j < self.src.len) {
            const c = self.src[j];
            if (c == '\\' and j + 1 < self.src.len) {
                out_len += 1;
                j += 2;
                continue;
            }
            if (c == quote) {
                closed = true;
                break;
            }
            if (c == '\n') break;
            out_len += 1;
            j += 1;
        }
        if (!closed) {
            if (!self.mute) std.debug.print("error on line {d}: unterminated string\n", .{self.line});
            return ParseError.UnterminatedString;
        }
        var out = try self.alloc.alloc(u8, out_len);
        var k: usize = 0;
        while (self.pos < j) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const e = self.src[self.pos + 1];
                out[k] = switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '"' => '"',
                    '\'' => '\'',
                    '\\' => '\\',
                    else => e,
                };
                k += 1;
                self.pos += 2;
            } else {
                out[k] = c;
                k += 1;
                self.pos += 1;
            }
        }
        self.pos = j + 1;
        return out[0..k];
    }

    fn skipNewlines(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (c == '\n') self.line += 1;
                self.pos += 1;
            } else break;
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) : (self.pos += 1) {}
    }

    fn eatComment(self: *Parser) bool {
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
};

fn isTruthy(v: Value) bool {
    switch (v) {
        .number => |n| return n != 0,
        .string => |s| return s.len > 0,
        .list => |l| return l.items.items.len > 0,
        .dict => |d| return d.map.count() > 0,
        .instance => return true,
        .function => return true,
        .nil => return false,
    }
}
