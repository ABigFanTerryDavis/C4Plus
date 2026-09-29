const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const Error = error{
    GuiUnavailable,
    BadWindow,
    BadControl,
    Win32Failed,
    BadArgument,
};

pub const Color = u32;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Image = struct {
    bmp: *anyopaque,
    dc: ?Hdc = null,
    old: ?*anyopaque = null,
    px: []u8,
    w: i32,
    h: i32,
    path: []const u8,
};

pub const Kind = enum {
    label,
    button,
    checkbox,
    slider,
    progress,
    textbox,
    editbox,
    list,
    vbox,
    hbox,
    panel,
    groupbox,
    tabs,
    radio,
    combo,
    picture,
};

pub const Control = struct {
    id: u32,
    kind: Kind,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    text: []const u8 = "",
    value: f64 = 0,
    vmin: f64 = 0,
    vmax: f64 = 100,
    sel: i32 = -1,
    checked: bool = false,
    enabled: bool = true,
    visible: bool = true,
    focused: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    scroll: i32 = 0,
    caret: i32 = 0,
    caret_on: bool = true,
    password: bool = false,
    tint: ?Color = null,
    cb: i32 = -1,
    parent: u32 = 0,
    page: i32 = -1,
    gap: i32 = 8,
    flow: i32 = 0,
    auto_size: bool = true,
    group: []const u8 = "",
    open: bool = false,
    active: i32 = 0,
    pages: std.ArrayList([]const u8) = .empty,
    pic: ?*Image = null,
    items: std.ArrayList([]const u8) = .empty,
    linenums: bool = false,
    curline: bool = false,
    curline_color: Color = 0x22FFFFFF,
    marks: std.ArrayList(Mark) = .empty,
};

pub const Mark = struct {
    line: i32,
    col: i32,
    len: i32,
    color: Color,
};

pub fn isContainer(kind: Kind) bool {
    return switch (kind) {
        .vbox, .hbox, .panel, .groupbox, .tabs => true,
        else => false,
    };
}

pub fn tabBarHeight(kind: Kind, font_size: i32) i32 {
    return if (kind == .tabs) font_size + 16 else 0;
}

var g_images: std.StringHashMap(*Image) = .init(std.heap.page_allocator);
var g_wic_ready = false;

var g_gdip_token: usize = 0;
var g_gdip_ready = false;

fn gdip() bool {
    if (g_gdip_ready) return true;
    const startup_input = GdiplusStartupInput{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = 0,
        .SuppressExternalCodecs = 0,
    };
    if (GdiplusStartup(&g_gdip_token, &startup_input, null) != 0) return false;
    g_gdip_ready = true;
    return true;
}

fn wicFactory() ?*anyopaque {
    if (!gdip()) {
        std.debug.print("gui: gdiplus failed to start\n", .{});
        return null;
    }
    return @ptrFromInt(@as(usize, 0x1000));
}

pub fn loadImage(alloc: std.mem.Allocator, path: []const u8) ?*Image {
    if (g_images.get(path)) |cached| return cached;
    if (!gdip()) return null;
    const wide_path = utf16(alloc, path) catch return null;
    var bmp: ?*anyopaque = null;
    const st = GdipCreateBitmapFromFile(wide(wide_path), &bmp);
    if (st != 0 or bmp == null) return null;
    var w: u32 = 0;
    var h: u32 = 0;
    if (GdipGetImageWidth(bmp.?, &w) != 0) return null;
    if (GdipGetImageHeight(bmp.?, &h) != 0) return null;
    if (w == 0 or h == 0 or w > 8192 or h > 8192) return null;
    var rc = GpRect{ .x = 0, .y = 0, .width = @intCast(w), .height = @intCast(h) };
    var data: BitmapData = std.mem.zeroes(BitmapData);
    if (GdipBitmapLockBits(bmp.?, &rc, 1, 0x26200A, &data) != 0) return null;
    const src_ptr: [*]u8 = @ptrCast(@alignCast(data.scan0 orelse return null));
    const buf = alloc.alloc(u8, w * h * 4) catch return null;
    const row = @as(usize, @intCast(w * 4));
    const src_stride = @as(usize, @intCast(if (data.stride < 0) -data.stride else data.stride));
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src = src_ptr + src_stride * y;
        const dst = buf.ptr + row * y;
        @memcpy(dst[0..row], src[0..row]);
    }
    _ = GdipBitmapUnlockBits(bmp.?, &data);
    _ = GdipDisposeImage(bmp.?);
    const bmp_h = createStripedBitmap(alloc, @intCast(w), @intCast(h), buf) orelse return null;
    const img = alloc.create(Image) catch return null;
    img.* = .{ .bmp = bmp_h, .px = buf, .w = @intCast(w), .h = @intCast(h), .path = path };
    g_images.put(path, img) catch {};
    return img;
}

pub fn imageSize(path: []const u8) ?[2]i32 {
    const probe = std.heap.page_allocator;
    const img = loadImage(probe, path) orelse return null;
    return .{ img.w, img.h };
}

fn createStripedBitmap(alloc: std.mem.Allocator, w: i32, h: i32, px: []const u8) ?*anyopaque {
    const screen = GetDC(null) orelse return null;
    defer _ = ReleaseDC(null, screen);
    var bi: BITMAPINFO = std.mem.zeroes(BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    var bits: ?*anyopaque = null;
    const hbmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    const dst: [*]u8 = @ptrCast(@alignCast(bits orelse return null));
    @memcpy(dst[0 .. px.len], px);
    _ = alloc;
    return hbmp;
}

pub fn drawImage(hdc: Hdc, img: *Image, x: i32, y: i32, w: i32, h: i32) void {
    if (img.dc == null) {
        img.dc = CreateCompatibleDC(hdc);
        img.old = if (img.dc) |d| SelectObject(d, img.bmp) else null;
    }
    const d = img.dc orelse return;
    _ = SetStretchBltMode(d, HALFTONE);
    _ = StretchBlt(hdc, sc(x), sc(y), sc(w), sc(h), d, 0, 0, img.w, img.h, SRCCOPY);
}

pub fn tabPageRect(c: *const Control) Rect {
    const bh = if (c.kind == .tabs) @max(20, @divTrunc(c.h, 8)) else 0;
    return .{ .x = c.x, .y = c.y + bh, .w = c.w, .h = c.h - bh };
}

pub const EventKind = enum {
    none,
    click,
    toggle,
    drag,
    change,
    key,
    close,
    resize,
    move,
    wheel,
    tick,
};

pub const Event = struct {
    kind: EventKind = .none,
    id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    key: []const u8 = "",
    ch: []const u8 = "",
    wheel: i32 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    cb: i32 = -1,
};

pub const Theme = struct {
    bg: Color = 0xFF1E1F26,
    panel: Color = 0xFF2A2C36,
    text: Color = 0xFFF2F3F7,
    dim: Color = 0xFF8A8FA3,
    accent: Color = 0xFF4C8DFF,
    accent_dim: Color = 0xFF2F5FB0,
    border: Color = 0xFF3A3D4B,
    field: Color = 0xFF16171D,
    hover: Color = 0xFF3A3D4B,
    press: Color = 0xFF23252E,
    danger: Color = 0xFFE5484D,
    ok: Color = 0xFF30A46C,
};

const DrawCmd = union(enum) {
    rect: struct { x: i32, y: i32, w: i32, h: i32, color: Color, outline: bool, radius: i32 },
    text: struct { x: i32, y: i32, s: []const u16, color: Color, size: i32 },
    line: struct { x1: i32, y1: i32, x2: i32, y2: i32, color: Color, width: i32 },
    image: struct { path: []const u8, x: i32, y: i32, w: i32, h: i32 },
    disc: struct { cx: i32, cy: i32, r: i32, color: Color },
    ring: struct { cx: i32, cy: i32, r: i32, color: Color, width: i32 },
    poly: struct { pts: []const i32, color: Color, fill: bool },
    arc: struct { cx: i32, cy: i32, r: i32, start: f64, sweep: f64, color: Color, width: i32 },
    grad: struct { x: i32, y: i32, w: i32, h: i32, c1: Color, c2: Color, vertical: bool },
};

pub const Window = struct {
    alloc: std.mem.Allocator,
    slot: usize = 0,
    hwnd: ?Hwnd = null,
    title: []const u8 = "",
    cw: i32 = 640,
    ch: i32 = 480,
    alive: bool = true,
    controls: std.ArrayList(Control) = .empty,
    events: std.ArrayList(Event) = .empty,
    immed: std.ArrayList(DrawCmd) = .empty,
    next_id: u32 = 1,
    next_y: i32 = 12,
    gap: i32 = 8,
    theme: Theme = .{},
    font: ?Hfont = null,
    font_size: i32 = 16,
    font_bold: bool = false,
    mx: i32 = 0,
    my: i32 = 0,
    drag_id: u32 = 0,
    pressed_id: u32 = 0,
    cur_container: u32 = 0,
};

var g_windows: [64]?*Window = .{null} ** 64;
var g_dry: ?Window = null;
var g_dry_ctl: ?Control = null;
var g_class_ready = false;
var g_dpi_set = false;
var g_dpi: u32 = 96;
var g_scale: f64 = 1.0;

fn sc(v: i32) i32 {
    return @intFromFloat(@as(f64, @floatFromInt(v)) * g_scale);
}

fn scf(v: f64) f64 {
    return v * g_scale;
}

fn uns(v: i32) i32 {
    if (g_scale <= 0.001) return v;
    return @intFromFloat(@as(f64, @floatFromInt(v)) / g_scale);
}

pub fn dryWindow() *Window {
    if (g_dry == null) g_dry = .{ .alloc = std.heap.page_allocator, .slot = 0 };
    return &g_dry.?;
}

pub fn dryControl() *Control {
    if (g_dry_ctl == null) g_dry_ctl = .{ .id = 1, .kind = .label };
    return &g_dry_ctl.?;
}

pub fn shutdownAll() void {
    for (g_windows) |maybe| {
        if (maybe) |win| {
            if (win.alive) {
                win.alive = false;
                if (win.hwnd) |h| _ = DestroyWindow(h);
            }
            g_windows[win.slot] = null;
        }
    }
}

pub fn windowBySlot(slot: usize) ?*Window {
    if (slot >= g_windows.len) return null;
    return g_windows[slot];
}

pub fn findControl(win: *Window, id: u32) ?*Control {
    for (win.controls.items) |*c| {
        if (c.id == id) return c;
    }
    return null;
}

pub fn isAlive(win: *Window) bool {
    return win.alive;
}

pub fn queueEvent(win: *Window, ev: Event) void {
    win.events.append(win.alloc, ev) catch {};
}

fn findSlot() ?usize {
    for (g_windows, 0..) |maybe, i| {
        if (maybe == null) return i;
    }
    return null;
}

pub fn defaultHeight(kind: Kind, font_size: i32) i32 {
    return switch (kind) {
        .label => font_size + 10,
        .button => font_size + 16,
        .checkbox => font_size + 12,
        .slider => 28,
        .progress => 20,
        .textbox => font_size + 14,
        .editbox => 120,
        .list => 140,
        .vbox, .hbox, .panel => 40,
        .groupbox => 60,
        .tabs => 160,
        .radio => font_size + 12,
        .combo => font_size + 14,
        .picture => 120,
    };
}

pub fn createWindow(alloc: std.mem.Allocator, title: []const u8, w: i32, h: i32) Error!*Window {
    if (!supported) return Error.GuiUnavailable;
    const slot = findSlot() orelse return Error.Win32Failed;
    const win = alloc.create(Window) catch return Error.Win32Failed;
    win.* = .{ .alloc = alloc, .slot = slot, .title = title, .cw = w, .ch = h };
    g_windows[slot] = win;
    const hwnd = createWindowEx(title, w, h, win) catch {
        g_windows[slot] = null;
        return Error.Win32Failed;
    };
    win.hwnd = hwnd;
    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);
    return win;
}

pub fn addControl(win: *Window, c: Control) Error!u32 {
    var ctrl = c;
    ctrl.id = win.next_id;
    win.next_id += 1;
    if (ctrl.w <= 0) ctrl.w = 160;
    if (ctrl.h <= 0) ctrl.h = defaultHeight(ctrl.kind, win.font_size);
    if (win.cur_container != 0) {
        if (findControl(win, win.cur_container)) |box| {
            ctrl.parent = box.id;
            if (box.kind == .tabs) ctrl.page = box.active;
            if (ctrl.x < 0 or ctrl.y < 0) {
                switch (box.kind) {
                    .hbox => {
                        ctrl.x = box.x + box.flow + 8;
                        ctrl.y = box.y + 8;
                    },
                    .tabs => {
                        ctrl.x = box.x + 8;
                        ctrl.y = box.y + @max(20, @divTrunc(box.h, 8)) + box.flow + 8;
                    },
                    else => {
                        ctrl.x = box.x + 8;
                        ctrl.y = box.y + box.flow + 8;
                    },
                }
            }
            const pad: i32 = 8;
            switch (box.kind) {
                .hbox => {
                    box.flow += ctrl.w + box.gap;
                    if (box.auto_size) box.w = @max(box.w, box.flow - box.gap + pad);
                },
                else => {
                    box.flow += ctrl.h + box.gap;
                    if (box.auto_size) {
                        const extra = if (box.kind == .tabs) tabBarHeight(.tabs, win.font_size) else 0;
                        box.h = @max(box.h, box.flow - box.gap + pad + extra);
                    }
                },
            }
        }
    } else {
        if (ctrl.x < 0 or ctrl.y < 0) {
            ctrl.x = 12;
            ctrl.y = win.next_y;
            win.next_y += ctrl.h + win.gap;
        }
    }
    win.controls.append(win.alloc, ctrl) catch return Error.Win32Failed;
    redraw(win);
    return ctrl.id;
}

pub fn begin(win: *Window, container: u32) Error!void {
    if (findControl(win, container) == null) return Error.BadControl;
    win.cur_container = container;
    if (findControl(win, container)) |c| c.flow = 0;
}

pub fn endFlow(win: *Window) void {
    win.cur_container = 0;
}

pub fn setTitle(win: *Window, title: []const u8) void {
    win.title = title;
    const tw = utf16(win.alloc, title) catch return;
    if (win.hwnd) |h| _ = SetWindowTextW(h, wide(tw));
}

pub fn setSize(win: *Window, w: i32, h: i32) void {
    win.cw = w;
    win.ch = h;
    if (win.hwnd) |hw| _ = MoveWindow(hw, 0, 0, sc(w), sc(h), 1);
    queueEvent(win, .{ .kind = .resize, .w = w, .h = h });
    redraw(win);
}

pub fn setBg(win: *Window, c: Color) void {
    win.theme.bg = c;
    redraw(win);
}

pub fn setAccent(win: *Window, c: Color) void {
    win.theme.accent = c;
    win.theme.accent_dim = mix(c, 0xFF000000, 0.3);
    redraw(win);
}

pub fn setFont(win: *Window, size_in: i32, bold: bool) void {
    var size = size_in;
    if (size < 6) size = 6;
    if (size > 96) size = 96;
    win.font_size = size;
    win.font_bold = bold;
    dropFont(win);
    redraw(win);
}

pub fn setTheme(win: *Window, name: []const u8) void {
    if (std.mem.eql(u8, name, "light")) {
        win.theme = .{
            .bg = 0xFFF4F5F7,
            .panel = 0xFFFFFFFF,
            .text = 0xFF16171D,
            .dim = 0xFF6B7080,
            .accent = 0xFF2F6FED,
            .accent_dim = 0xFF1F4FB0,
            .border = 0xFFD3D6DE,
            .field = 0xFFFFFFFF,
            .hover = 0xFFE7E9EF,
            .press = 0xFFD8DBE3,
            .danger = 0xFFD13438,
            .ok = 0xFF1F9254,
        };
    } else if (std.mem.eql(u8, name, "midnight")) {
        win.theme = .{
            .bg = 0xFF0B0E14,
            .panel = 0xFF151A23,
            .text = 0xFFDCE3F0,
            .dim = 0xFF6E7891,
            .accent = 0xFF7C5CFF,
            .accent_dim = 0xFF4B36B8,
            .border = 0xFF232B38,
            .field = 0xFF0F131B,
            .hover = 0xFF232B38,
            .press = 0xFF1A202B,
            .danger = 0xFFFF5C5C,
            .ok = 0xFF3DD68C,
        };
    } else {
        win.theme = .{};
    }
    redraw(win);
}

pub fn resetLayout(win: *Window) void {
    win.next_y = 12;
}

pub fn setLayoutGap(win: *Window, gap: i32) void {
    win.gap = gap;
}

pub fn textWidth(win: *Window, s: []const u8) i32 {
    if (!supported) return @intCast(s.len * win.font_size / 2);
    const hdc = GetDC(win.hwnd) orelse return 0;
    defer _ = ReleaseDC(win.hwnd, hdc);
    const f = ensureFont(win) orelse return 0;
    const old = SelectObject(hdc, f);
    defer if (old) |o| { _ = SelectObject(hdc, o); };
    const tw = utf16(win.alloc, s) catch return 0;
    var out: SIZE = .{ .cx = 0, .cy = 0 };
    _ = GetTextExtentPoint32W(hdc, wide(tw), @intCast(tw.len), &out);
    return uns(out.cx);
}

pub fn redraw(win: *Window) void {
    if (win.hwnd) |h| {
        var rc: RECT = undefined;
        _ = GetClientRect(h, &rc);
        _ = InvalidateRect(h, &rc, 0);
    }
}

pub fn close(win: *Window) void {
    if (!win.alive) return;
    win.alive = false;
    queueEvent(win, .{ .kind = .close });
    if (win.hwnd) |h| _ = DestroyWindow(h);
}

pub fn show(win: *Window, visible: bool) void {
    if (win.hwnd) |h| _ = ShowWindow(h, if (visible) SW_SHOW else SW_HIDE);
}

pub fn poll(win: *Window) ?Event {
    pump(win);
    if (win.events.items.len == 0) return null;
    return win.events.orderedRemove(0);
}

pub fn wait(win: *Window) ?Event {
    while (true) {
        pump(win);
        if (win.events.items.len > 0) return win.events.orderedRemove(0);
        if (!win.alive) return null;
        var msg: MSG = undefined;
        const r = GetMessageW(&msg, null, 0, 0);
        if (r <= 0) {
            win.alive = false;
            return null;
        }
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

pub fn setTick(win: *Window, ms: u32) void {
    if (win.hwnd) |h| {
        _ = KillTimer(h, 1);
        if (ms > 0) _ = SetTimer(h, 1, ms, null);
    }
}

pub fn keyDown(name: []const u8) bool {
    if (!supported) return false;
    const vk = vkFor(name) orelse return false;
    return (GetKeyState(vk) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
}

pub fn mods() [3]bool {
    if (!supported) return .{ false, false, false };
    return .{
        (GetKeyState(VK_CONTROL) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0,
        (GetKeyState(VK_SHIFT) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0,
        (GetKeyState(VK_MENU) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0,
    };
}

pub fn mousePos(win: *Window) [2]i32 {
    return .{ win.mx, win.my };
}

pub fn eventName(kind: EventKind) []const u8 {
    return switch (kind) {
        .none => "none",
        .click => "click",
        .toggle => "toggle",
        .drag => "drag",
        .change => "change",
        .key => "key",
        .close => "close",
        .resize => "resize",
        .move => "move",
        .wheel => "wheel",
        .tick => "tick",
    };
}

pub fn keyName(vk: u8) []const u8 {
    return switch (vk) {
        VK_UP => "up",
        VK_DOWN => "down",
        VK_LEFT => "left",
        VK_RIGHT => "right",
        VK_RETURN => "enter",
        VK_ESCAPE => "esc",
        VK_TAB => "tab",
        VK_SPACE => "space",
        VK_BACK => "back",
        VK_DELETE => "delete",
        VK_HOME => "home",
        VK_END => "end",
        VK_PRIOR => "pageup",
        VK_NEXT => "pagedown",
        0x70...0x7B => "f" ++ [_]u8{ '0' + (vk - 0x70 + 1) },
        else => if (vk >= 0x30 and vk <= 0x39)
            &[_]u8{std.ascii.toLower(@as(u8, vk))}
        else if (vk >= 0x41 and vk <= 0x5A)
            &[_]u8{std.ascii.toLower(@as(u8, vk))}
        else
            "",
    };
}

pub fn vkFor(name: []const u8) ?i32 {
    if (name.len == 0) return null;
    if (name.len == 1) {
        const ch = std.ascii.toLower(name[0]);
        if ((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9')) return ch;
        return switch (ch) {
            ' ' => VK_SPACE,
            '\n' => VK_RETURN,
            '\t' => VK_TAB,
            else => null,
        };
    }
    if (name.len == 2 and (name[0] == 'f' or name[0] == 'F') and name[1] >= '1' and name[1] <= '9') {
        return 0x70 + (name[1] - '1');
    }
    if (std.mem.eql(u8, name, "up")) return VK_UP;
    if (std.mem.eql(u8, name, "down")) return VK_DOWN;
    if (std.mem.eql(u8, name, "left")) return VK_LEFT;
    if (std.mem.eql(u8, name, "right")) return VK_RIGHT;
    if (std.mem.eql(u8, name, "enter")) return VK_RETURN;
    if (std.mem.eql(u8, name, "esc")) return VK_ESCAPE;
    if (std.mem.eql(u8, name, "tab")) return VK_TAB;
    if (std.mem.eql(u8, name, "space")) return VK_SPACE;
    if (std.mem.eql(u8, name, "back")) return VK_BACK;
    if (std.mem.eql(u8, name, "delete")) return VK_DELETE;
    if (std.mem.eql(u8, name, "home")) return VK_HOME;
    if (std.mem.eql(u8, name, "end")) return VK_END;
    if (std.mem.eql(u8, name, "pageup")) return VK_PRIOR;
    if (std.mem.eql(u8, name, "pagedown")) return VK_NEXT;
    return null;
}

pub fn namedColor(name: []const u8) ?Color {
    const Named = struct { name: []const u8, color: Color };
    const table = [_]Named{
        .{ .name = "red", .color = 0xFFE5484D },
        .{ .name = "green", .color = 0xFF30A46C },
        .{ .name = "blue", .color = 0xFF4C8DFF },
        .{ .name = "yellow", .color = 0xFFFFD43B },
        .{ .name = "orange", .color = 0xFFFF922B },
        .{ .name = "purple", .color = 0xFFB197FC },
        .{ .name = "pink", .color = 0xFFFF8FA3 },
        .{ .name = "cyan", .color = 0xFF63E6E2 },
        .{ .name = "white", .color = 0xFFFFFFFF },
        .{ .name = "black", .color = 0xFF000000 },
        .{ .name = "gray", .color = 0xFF8A8FA3 },
        .{ .name = "grey", .color = 0xFF8A8FA3 },
        .{ .name = "silver", .color = 0xFFC0C4CC },
        .{ .name = "navy", .color = 0xFF1B2A4A },
        .{ .name = "teal", .color = 0xFF0CA678 },
        .{ .name = "lime", .color = 0xFF8CE99A },
        .{ .name = "gold", .color = 0xFFF2C14E },
        .{ .name = "coral", .color = 0xFFFF7A6B },
        .{ .name = "steelblue", .color = 0xFF4A6FA5 },
        .{ .name = "tomato", .color = 0xFFFF6347 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.color;
    }
    return null;
}

pub fn pushRect(win: *Window, x: i32, y: i32, w: i32, h: i32, color: Color, outline: bool, radius: i32) void {
    win.immed.append(win.alloc, .{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color, .outline = outline, .radius = radius } }) catch {};
}

pub fn pushText(win: *Window, x: i32, y: i32, s: []const u8, color: Color, size: i32) void {
    const tw = utf16(win.alloc, s) catch return;
    win.immed.append(win.alloc, .{ .text = .{ .x = x, .y = y, .s = tw, .color = color, .size = size } }) catch {};
}

pub fn pushLine(win: *Window, x1: i32, y1: i32, x2: i32, y2: i32, color: Color, width: i32) void {
    win.immed.append(win.alloc, .{ .line = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color, .width = width } }) catch {};
}

pub fn queueImage(win: *Window, path: []const u8, x: i32, y: i32, w: i32, h: i32) void {
    win.immed.append(win.alloc, .{ .image = .{ .path = path, .x = x, .y = y, .w = w, .h = h } }) catch {};
}

pub fn pushDisc(win: *Window, cx: i32, cy: i32, r: i32, color: Color) void {
    win.immed.append(win.alloc, .{ .disc = .{ .cx = cx, .cy = cy, .r = r, .color = color } }) catch {};
}

pub fn pushRing(win: *Window, cx: i32, cy: i32, r: i32, color: Color, width: i32) void {
    win.immed.append(win.alloc, .{ .ring = .{ .cx = cx, .cy = cy, .r = r, .color = color, .width = width } }) catch {};
}

pub fn pushPoly(win: *Window, pts: []const i32, color: Color, fill: bool) void {
    win.immed.append(win.alloc, .{ .poly = .{ .pts = pts, .color = color, .fill = fill } }) catch {};
}

pub fn pushArc(win: *Window, cx: i32, cy: i32, r: i32, start_deg: f64, sweep_deg: f64, color: Color, width: i32) void {
    win.immed.append(win.alloc, .{ .arc = .{ .cx = cx, .cy = cy, .r = r, .start = start_deg, .sweep = sweep_deg, .color = color, .width = width } }) catch {};
}

pub fn pushGradient(win: *Window, x: i32, y: i32, w: i32, h: i32, c1: Color, c2: Color, vertical: bool) void {
    win.immed.append(win.alloc, .{ .grad = .{ .x = x, .y = y, .w = w, .h = h, .c1 = c1, .c2 = c2, .vertical = vertical } }) catch {};
}

pub fn radioGroupSelect(win: *Window, group: []const u8, idx: i32) void {
    var n: i32 = 0;
    for (win.controls.items) |*c| {
        if (c.kind != .radio) continue;
        if (!std.mem.eql(u8, c.group, group)) continue;
        c.checked = (n == idx);
        n += 1;
    }
    redraw(win);
}

pub fn radioExclusive(win: *Window, self: *Control) void {
    for (win.controls.items) |*c| {
        if (c == self) continue;
        if (c.kind != .radio) continue;
        if (!std.mem.eql(u8, c.group, self.group)) continue;
        c.checked = false;
    }
}

pub fn editMarkAdd(win: *Window, id: u32, line: i32, col: i32, len: i32, color: Color) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (c.kind != .editbox) return Error.BadArgument;
    if (line < 0 or col < 0 or len <= 0) return Error.BadArgument;
    if (c.marks.items.len >= 512) return Error.BadArgument;
    c.marks.append(win.alloc, .{ .line = line, .col = col, .len = len, .color = color }) catch return Error.Win32Failed;
    redraw(win);
}

pub fn editMarksClear(win: *Window, id: u32) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (c.kind != .editbox) return Error.BadArgument;
    c.marks.clearRetainingCapacity();
    redraw(win);
}

pub fn editLinenums(win: *Window, id: u32, on: bool) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (c.kind != .editbox) return Error.BadArgument;
    c.linenums = on;
    redraw(win);
}

pub fn editCurline(win: *Window, id: u32, on: bool, color: Color) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (c.kind != .editbox) return Error.BadArgument;
    c.curline = on;
    c.curline_color = color;
    redraw(win);
}

pub fn listAdd(win: *Window, id: u32, item: []const u8) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    c.items.append(win.alloc, item) catch return Error.Win32Failed;
    redraw(win);
}

pub fn listInsert(win: *Window, id: u32, idx: usize, item: []const u8) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    const at = @min(idx, c.items.items.len);
    c.items.insert(win.alloc, at, item) catch return Error.Win32Failed;
    redraw(win);
}

pub fn listRemove(win: *Window, id: u32, idx: usize) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (idx >= c.items.items.len) return Error.BadArgument;
    _ = c.items.orderedRemove(idx);
    if (c.sel >= @as(i32, @intCast(c.items.items.len))) c.sel = @as(i32, @intCast(c.items.items.len)) - 1;
    redraw(win);
}

pub fn listClear(win: *Window, id: u32) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    c.items.clearRetainingCapacity();
    c.sel = -1;
    redraw(win);
}

pub fn listLen(win: *Window, id: u32) usize {
    const c = findControl(win, id) orelse return 0;
    return c.items.items.len;
}

pub fn listGet(win: *Window, id: u32, idx: usize) ?[]const u8 {
    const c = findControl(win, id) orelse return null;
    if (idx >= c.items.items.len) return null;
    return c.items.items[idx];
}

pub fn listSet(win: *Window, id: u32, idx: usize, item: []const u8) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (idx >= c.items.items.len) return Error.BadArgument;
    c.items.items[idx] = item;
    redraw(win);
}

pub fn listSelect(win: *Window, id: u32, idx: i32) Error!void {
    const c = findControl(win, id) orelse return Error.BadControl;
    if (idx < -1 or idx >= @as(i32, @intCast(c.items.items.len))) return Error.BadArgument;
    c.sel = idx;
    redraw(win);
}

pub fn listSel(win: *Window, id: u32) i32 {
    const c = findControl(win, id) orelse return -1;
    return c.sel;
}

pub fn setPassword(win: *Window, id: u32, on: bool) bool {
    const c = findControl(win, id) orelse return false;
    if (c.kind != .textbox) return false;
    c.password = on;
    redraw(win);
    return true;
}

pub fn focusControl(win: *Window, id: u32) bool {
    const t = findControl(win, id) orelse return false;
    if (!t.enabled or !t.visible or !focusable(t.kind)) return false;
    for (win.controls.items) |*c| c.focused = false;
    t.focused = true;
    redraw(win);
    return true;
}

fn packXY(x: i32, y: i32) LPARAM {
    const ux: u32 = @bitCast(sc(x));
    const uy: u32 = @bitCast(sc(y));
    const lp: u64 = (@as(u64, uy) << 16) | ux;
    return @bitCast(lp);
}

pub fn postClick(win: *Window, x: i32, y: i32) void {
    const h = win.hwnd orelse return;
    const lp = packXY(x, y);
    _ = PostMessageW(h, WM_MOUSEMOVE, 0, lp);
    _ = PostMessageW(h, WM_LBUTTONDOWN, 1, lp);
    _ = PostMessageW(h, WM_LBUTTONUP, 0, lp);
}

pub fn postKey(win: *Window, name: []const u8) void {
    const h = win.hwnd orelse return;
    const vk = vkFor(name) orelse return;
    const w: WPARAM = @intCast(vk & 0xFFFF);
    _ = PostMessageW(h, WM_KEYDOWN, w, 0);
    if (name.len == 1) _ = PostMessageW(h, WM_CHAR, @as(WPARAM, name[0]), 0);
    _ = PostMessageW(h, WM_KEYUP, w, 0);
}

pub fn postType(win: *Window, s: []const u8) void {
    const h = win.hwnd orelse return;
    for (s) |ch| {
        if (ch < 32) continue;
        const lp: LPARAM = @intCast(ch);
        _ = PostMessageW(h, WM_CHAR, @as(WPARAM, ch), lp);
    }
}

pub fn postClose(win: *Window) void {
    if (win.hwnd) |h| _ = PostMessageW(h, WM_CLOSE, 0, 0);
}

pub fn postWheel(win: *Window, x: i32, y: i32, delta: i32) void {
    const h = win.hwnd orelse return;
    const w: WPARAM = @as(u32, @bitCast(delta)) << 16;
    _ = PostMessageW(h, WM_MOUSEWHEEL, w, packXY(x, y));
}

pub fn fileDialog(alloc: std.mem.Allocator, owner: ?Hwnd, save: bool, title: ?[]const u8, def_name: ?[]const u8, filter: ?[]const u8) []const u8 {
    if (!supported) return "";
    var file_buf = alloc.alloc(u16, 32768) catch return "";
    @memset(file_buf, 0);
    if (def_name) |dn| {
        const dw = utf16(alloc, dn) catch return "";
        const n = @min(dw.len - 1, file_buf.len - 1);
        @memcpy(file_buf[0..n], dw[0..n]);
    }
    var filter_buf: ?[]u16 = null;
    if (filter) |f| {
        filter_buf = alloc.alloc(u16, f.len * 2 + 4) catch return "";
        var j: usize = 0;
        for (f) |c| {
            if (c == '|') {
                filter_buf.?[j] = 0;
            } else {
                filter_buf.?[j] = c;
            }
            j += 1;
        }
        filter_buf.?[j] = 0;
        filter_buf.?[j + 1] = 0;
    } else {
        filter_buf = alloc.alloc(u16, 32) catch return "";
        const def = "All files\x00*.*\x00\x00";
        var j: usize = 0;
        for (def) |c| {
            filter_buf.?[j] = c;
            j += 1;
        }
    }
    var title_buf: ?[]u16 = null;
    if (title) |t| title_buf = utf16(alloc, t) catch return "";
    var ofn = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = if (filter_buf) |fb| @ptrCast(fb.ptr) else null;
    ofn.lpstrFile = @ptrCast(file_buf.ptr);
    ofn.nMaxFile = @intCast(file_buf.len);
    ofn.lpstrTitle = if (title_buf) |tb| @ptrCast(tb.ptr) else null;
    ofn.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | (if (save) OFN_OVERWRITEPROMPT else OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST);
    const ok = if (save) GetSaveFileNameW(&ofn) else GetOpenFileNameW(&ofn);
    if (ok == 0) return "";
    var len: usize = 0;
    while (len < file_buf.len and file_buf[len] != 0) len += 1;
    return utf16Owned(alloc, file_buf[0..len]) catch return "";
}

pub fn msgbox(alloc: std.mem.Allocator, text: []const u8, title: ?[]const u8) void {
    if (!supported) return;
    const tw = utf16(alloc, text) catch return;
    const title_w = if (title) |t| (utf16(alloc, t) catch return) else utf16(alloc, "C4Plus") catch return;
    _ = MessageBoxW(null, wide(tw), wide(title_w), MB_OK);
}

pub fn clipSet(alloc: std.mem.Allocator, text: []const u8) void {
    if (!supported) return;
    if (OpenClipboard(null) == 0) return;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    const tw = utf16(alloc, text) catch return;
    const bytes = (tw.len) * 2;
    const handle = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return;
    const ptr = GlobalLock(handle) orelse return;
    const dst: [*]u16 = @ptrCast(@alignCast(ptr));
    var i: usize = 0;
    while (i < tw.len) : (i += 1) dst[i] = tw[i];
    _ = GlobalUnlock(handle);
    _ = SetClipboardData(CF_UNICODETEXT, handle);
}

pub fn clipGet(alloc: std.mem.Allocator) []const u8 {
    if (!supported) return "";
    if (OpenClipboard(null) == 0) return "";
    defer _ = CloseClipboard();
    const handle = GetClipboardData(CF_UNICODETEXT) orelse return "";
    const ptr = GlobalLock(handle) orelse return "";
    const src: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (src[len] != 0) len += 1;
    const buf = alloc.alloc(u16, len + 1) catch return "";
    var i: usize = 0;
    while (i < len) : (i += 1) buf[i] = src[i];
    buf[len] = 0;
    _ = GlobalUnlock(handle);
    const out = utf16Owned(alloc, buf[0..len]) catch return "";
    return out;
}

pub fn utf16(alloc: std.mem.Allocator, s: []const u8) ![]u16 {
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

pub fn utf16Owned(alloc: std.mem.Allocator, s: []u16) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.ensureTotalCapacity(alloc, s.len * 2 + 1);
    var i: usize = 0;
    while (i < s.len) {
        const u = s[i];
        var cp: u21 = undefined;
        if (u >= 0xD800 and u < 0xDC00 and i + 1 < s.len and s[i + 1] >= 0xDC00 and s[i + 1] < 0xE000) {
            cp = 0x10000 + ((@as(u21, u - 0xD800) << 10) | @as(u21, s[i + 1] - 0xDC00));
            i += 2;
        } else {
            cp = u;
            i += 1;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try list.appendSlice(alloc, buf[0..n]);
    }
    return try list.toOwnedSlice(alloc);
}

pub fn utf8Before(text: []const u8, caret: i32) []const u8 {
    if (caret <= 0) return "";
    var units: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + seq > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq]) catch break;
        const w: i32 = if (cp >= 0x10000) 2 else 1;
        if (units + w > caret) break;
        units += w;
        i += seq;
    }
    return text[0..i];
}

pub fn utf16Units(text: []const u8, alloc: std.mem.Allocator) i32 {
    const tw = utf16(alloc, text) catch return 0;
    return @intCast(tw.len - 1);
}

pub fn mix(a: Color, b: Color, t: f64) Color {
    const f = @max(0.0, @min(1.0, t));
    const av = [4]f64{
        @floatFromInt((a >> 24) & 0xFF),
        @floatFromInt((a >> 16) & 0xFF),
        @floatFromInt((a >> 8) & 0xFF),
        @floatFromInt(a & 0xFF),
    };
    const bv = [4]f64{
        @floatFromInt((b >> 24) & 0xFF),
        @floatFromInt((b >> 16) & 0xFF),
        @floatFromInt((b >> 8) & 0xFF),
        @floatFromInt(b & 0xFF),
    };
    var out: u32 = 0;
    inline for ([_]u6{ 24, 16, 8, 0 }) |shift| {
        const idx: usize = @intCast(shift / 8);
        const v: u32 = @intFromFloat(av[idx] + (bv[idx] - av[idx]) * f);
        out |= v << shift;
    }
    return out;
}

const Hwnd = *anyopaque;
const Hdc = *anyopaque;
const Hfont = *anyopaque;
const Hbrush = *anyopaque;
const Hcursor = *anyopaque;
const Hinstance = *anyopaque;
const BOOL = i32;
const UINT = u32;
const DWORD = u32;
const COLORREF = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const SW_SHOW: i32 = 5;
const SW_HIDE: i32 = 0;
const WM_CLOSE: UINT = 0x0010;
const WM_QUIT: UINT = 0x0012;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_PAINT: UINT = 0x000F;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_TIMER: UINT = 0x0113;
const WM_SIZE: UINT = 0x0005;
const WM_MOVE: UINT = 0x0003;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_GETDLGCODE: UINT = 0x0087;
const DLGC_WANTALLKEYS: LRESULT = 0x0004;
const TRANSPARENT: i32 = 1;
const PS_SOLID: i32 = 0;
const SRCCOPY: DWORD = 0x00CC0020;
const DEFAULT_CHARSET: UINT = 1;
const OUT_DEFAULT_PRECIS: UINT = 0;
const CLIP_DEFAULT_PRECIS: UINT = 0;
const CLEARTYPE_QUALITY: UINT = 5;
const FF_DONTCARE: DWORD = 0;
const FW_NORMAL: i32 = 400;
const FW_BOLD: i32 = 700;
const MB_OK: UINT = 0x00000000;
const IDC_ARROW: usize = 32512;
const IDC_HAND: usize = 32649;
const IDC_IBEAM: usize = 32513;
const NULL_BRUSH: UINT = 5;
const DT_LEFT: UINT = 0x00000000;
const DT_CENTER: UINT = 0x00000001;
const DT_RIGHT: UINT = 0x00000002;
const DT_TOP: UINT = 0x00000000;
const DT_VCENTER: UINT = 0x00000004;
const DT_SINGLELINE: UINT = 0x00000020;
const DT_NOPREFIX: UINT = 0x00000800;
const DT_END_ELLIPSIS: UINT = 0x00008000;
const TA_LEFT: UINT = 0;
const PM_REMOVE: UINT = 0x0001;
const GWLP_USERDATA: i32 = -21;
const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

const VK_BACK: u8 = 0x08;
const VK_TAB: u8 = 0x09;
const VK_RETURN: u8 = 0x0D;
const VK_SHIFT: u8 = 0x10;
const VK_CONTROL: u8 = 0x11;
const VK_MENU: u8 = 0x12;
const VK_ESCAPE: u8 = 0x1B;
const VK_SPACE: u8 = 0x20;
const VK_END: u8 = 0x23;
const VK_HOME: u8 = 0x24;
const VK_LEFT: u8 = 0x25;
const VK_UP: u8 = 0x26;
const VK_RIGHT: u8 = 0x27;
const VK_DOWN: u8 = 0x28;
const VK_DELETE: u8 = 0x2E;
const VK_PRIOR: u8 = 0x21;
const VK_NEXT: u8 = 0x22;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (Hwnd, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: Hinstance,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque,
};

const MSG = extern struct {
    hwnd: ?Hwnd,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const POINT = extern struct { x: i32, y: i32 };
const SIZE = extern struct { cx: i32, cy: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const PAINTSTRUCT = extern struct {
    hdc: Hdc,
    fErase: RECT,
    fRestore: RECT,
    fIncUpdate: RECT,
    rgbReserved: [32]u8,
};

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) ?Hinstance;
extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?Hwnd, hMenu: ?*anyopaque, hInstance: ?Hinstance, lpParam: ?*anyopaque) ?Hwnd;
extern "user32" fn DefWindowProcW(hWnd: Hwnd, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: Hwnd) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hWnd: Hwnd, nCmdShow: i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: Hwnd) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hWnd: Hwnd, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn MoveWindow(hWnd: Hwnd, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: Hwnd, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: Hwnd, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hWnd: Hwnd, lpPs: *PAINTSTRUCT) ?Hdc;
extern "user32" fn EndPaint(hWnd: Hwnd, lpPs: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetDC(hWnd: ?Hwnd) ?Hdc;
extern "user32" fn ReleaseDC(hWnd: ?Hwnd, hDC: Hdc) callconv(.winapi) i32;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?Hwnd, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?Hwnd, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn SetTimer(hWnd: ?Hwnd, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*const anyopaque) usize;
extern "user32" fn KillTimer(hWnd: ?Hwnd, nIDEvent: usize) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hWnd: Hwnd) ?Hwnd;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?Hinstance, lpCursorName: [*:0]const u16) ?Hcursor;
extern "user32" fn SetCursor(hCursor: ?Hcursor) ?Hcursor;
extern "user32" fn PostMessageW(hWnd: ?Hwnd, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn MessageBoxW(hWnd: ?Hwnd, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: UINT) callconv(.winapi) i32;
extern "user32" fn SetProcessDpiAwarenessContext(value: *anyopaque) callconv(.winapi) BOOL;
extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
extern "user32" fn GetKeyState(vKey: i32) callconv(.winapi) i16;
extern "user32" fn SetWindowLongPtrW(hWnd: Hwnd, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: Hwnd, nIndex: i32) callconv(.winapi) isize;
extern "user32" fn OpenClipboard(hWndNewOwner: ?Hwnd) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) HANDLE;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) HANDLE;
extern "kernel32" fn GlobalLock(hMem: HANDLE) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleDC(hdc: Hdc) ?Hdc;
extern "gdi32" fn CreateCompatibleBitmap(hdc: Hdc, cx: i32, cy: i32) ?*anyopaque;
extern "gdi32" fn SelectObject(hdc: Hdc, hgdiObj: *anyopaque) ?*anyopaque;
extern "gdi32" fn DeleteObject(hObject: *anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn DeleteDC(hdc: Hdc) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(hdc: Hdc, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: Hdc, x1: i32, y1: i32, rop: DWORD) callconv(.winapi) BOOL;
extern "gdi32" fn CreateSolidBrush(color: COLORREF) ?Hbrush;
extern "gdi32" fn CreateFontW(nHeight: i32, nWidth: i32, nEscapement: i32, nOrientation: i32, fnWeight: i32, fdwItalic: DWORD, fdwUnderline: DWORD, fdwStrikeOut: DWORD, fdwCharSet: UINT, fdwOutputPrecision: UINT, fdwClipPrecision: UINT, fdwQuality: UINT, fdwPitchAndFamily: DWORD, lpszFace: [*:0]const u16) ?Hfont;
extern "gdi32" fn SetBkMode(hdc: Hdc, iMode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(hdc: Hdc, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn DrawTextW(hdc: Hdc, lpchText: [*:0]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;
extern "gdi32" fn GetTextExtentPoint32W(hdc: Hdc, lpString: [*:0]const u16, c: i32, psz: *SIZE) callconv(.winapi) BOOL;
extern "gdi32" fn MoveToEx(hdc: Hdc, x: i32, y: i32, lpPoint: ?*POINT) callconv(.winapi) BOOL;
extern "gdi32" fn LineTo(hdc: Hdc, x: i32, y: i32) callconv(.winapi) BOOL;
extern "gdi32" fn CreatePen(iStyle: i32, nWidth: i32, color: COLORREF) ?*anyopaque;
extern "gdi32" fn RoundRect(hdc: Hdc, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(.winapi) BOOL;
extern "gdi32" fn Ellipse(hdc: Hdc, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) BOOL;
extern "gdi32" fn GetStockObject(i: UINT) ?*anyopaque;
extern "gdi32" fn SetTextAlign(hdc: Hdc, iMode: UINT) callconv(.winapi) UINT;
extern "gdi32" fn FillRect(hdc: Hdc, lprc: *const RECT, hrgn: Hbrush) callconv(.winapi) i32;
extern "gdi32" fn SaveDC(hdc: Hdc) callconv(.winapi) i32;
extern "gdi32" fn RestoreDC(hdc: Hdc, nSavedDC: i32) callconv(.winapi) BOOL;
extern "gdi32" fn IntersectClipRect(hdc: Hdc, left: i32, top: i32, right: i32, bottom: i32) callconv(.winapi) i32;
extern "gdi32" fn Polygon(hdc: Hdc, lpPoints: *const POINT, nPoints: i32) callconv(.winapi) BOOL;
extern "gdi32" fn CreateDIBSection(hdc: Hdc, pbmi: *const BITMAPINFO, usage: UINT, ppvBits: *?*anyopaque, hSection: HANDLE, offset: u32) ?*anyopaque;
extern "gdi32" fn SetStretchBltMode(hdc: Hdc, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn StretchBlt(hdc: Hdc, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: Hdc, x1: i32, y1: i32, cx2: i32, cy2: i32, rop: DWORD) callconv(.winapi) BOOL;
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) i32;

const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32,
};

const WICSize = extern struct { cx: u32, cy: u32 };

const DIB_RGB_COLORS: UINT = 0;
const BI_RGB: u32 = 0;
const HALFTONE: i32 = 4;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const CLSCTX_INPROC_SERVER: DWORD = 0x1;
const GENERIC_READ: DWORD = 0x80000000;
const WICDecodeMetadataCacheOnLoad: DWORD = 0;
const WICBitmapDitherTypeNone: DWORD = 0;
const WICBitmapPaletteTypeCustom: DWORD = 0;

const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32,
    DebugEventCallback: ?*anyopaque,
    SuppressBackgroundThread: i32,
    SuppressExternalCodecs: i32,
};

const GpRect = extern struct { x: i32, y: i32, width: i32, height: i32 };

const BitmapData = extern struct {
    width: u32,
    height: u32,
    stride: i32,
    format: i32,
    scan0: ?*anyopaque,
    reserved: usize,
};

extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreateBitmapFromFile(filename: [*:0]const u16, bitmap: *?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipGetImageWidth(image: *anyopaque, width: *u32) callconv(.winapi) i32;
extern "gdiplus" fn GdipGetImageHeight(image: *anyopaque, height: *u32) callconv(.winapi) i32;
extern "gdiplus" fn GdipBitmapLockBits(bitmap: *anyopaque, rect: *GpRect, flags: u32, format: i32, locked: *BitmapData) callconv(.winapi) i32;
extern "gdiplus" fn GdipBitmapUnlockBits(bitmap: *anyopaque, locked: *BitmapData) callconv(.winapi) i32;
extern "gdiplus" fn GdipDisposeImage(image: *anyopaque) callconv(.winapi) i32;
extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?Hwnd,
    hInstance: ?Hinstance,
    lpstrFilter: ?[*:0]const u16,
    lpstrCustomFilter: ?[*:0]u16,
    nMaxCustFilter: u32,
    nFilterIndex: u32,
    lpstrFile: [*:0]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*:0]u16,
    nMaxFileTitle: u32,
    lpstrInitialDir: ?[*:0]const u16,
    lpstrTitle: ?[*:0]const u16,
    Flags: u32,
    nFileOffset: u16,
    nFileExtension: u16,
    lpstrDefExt: ?[*:0]const u16,
    lCustData: usize,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?[*:0]const u16,
    pvReserved: ?*anyopaque,
    dwReserved: u32,
    FlagsEx: u32,
};

const OFN_FILEMUSTEXIST: u32 = 0x00001000;
const OFN_PATHMUSTEXIST: u32 = 0x00000800;
const OFN_OVERWRITEPROMPT: u32 = 0x00000002;
const OFN_NOCHANGEDIR: u32 = 0x00000008;
const OFN_EXPLORER: u32 = 0x00080000;

const HANDLE = ?*anyopaque;

fn wide(s: []const u16) [*:0]const u16 {
    return @ptrCast(s.ptr);
}

fn lowWord(v: LPARAM) i32 {
    const x: u64 = @bitCast(v);
    const w: u16 = @truncate(x);
    return @as(i32, w);
}

fn highWord(v: LPARAM) i32 {
    const x: u64 = @bitCast(v);
    const w: u16 = @truncate(x >> 16);
    return @as(i32, w);
}

fn highWord16(v: WPARAM) i32 {
    const w: u16 = @truncate(v >> 16);
    return @as(i32, w);
}

fn rgb(color: Color) COLORREF {
    const r: u32 = (color >> 16) & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;
    return r | (g << 8) | (b << 16);
}

fn dropFont(win: *Window) void {
    if (win.font) |f| {
        _ = DeleteObject(f);
        win.font = null;
    }
}

fn ensureFont(win: *Window) ?Hfont {
    if (win.font) |f| return f;
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    const f = CreateFontW(
        -sc(win.font_size),
        0,
        0,
        0,
        if (win.font_bold) FW_BOLD else FW_NORMAL,
        0,
        0,
        0,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY,
        FF_DONTCARE,
        face.ptr,
    ) orelse return null;
    win.font = f;
    return f;
}

fn createWindowEx(title: []const u8, w: i32, h: i32, win: *Window) !Hwnd {
    setupDpi();
    const hinst = GetModuleHandleW(null) orelse return error.NoInstance;
    const class_w = std.unicode.utf8ToUtf16LeStringLiteral("C4PlusGui");
    if (!g_class_ready) {
        g_class_ready = true;
        const arrow = std.unicode.utf8ToUtf16LeStringLiteral("IDC_ARROW");
        const wc = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = CS_HREDRAW | CS_VREDRAW,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinst,
            .hIcon = null,
            .hCursor = LoadCursorW(null, wide(arrow)),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_w.ptr,
            .hIconSm = null,
        };
        if (RegisterClassExW(&wc) == 0) return error.NoClass;
    }
    const tw = try utf16(win.alloc, title);
    const hwnd = CreateWindowExW(
        0,
        class_w.ptr,
        wide(tw),
        WS_OVERLAPPEDWINDOW,
        @as(i32, @bitCast(@as(u32, 0x80000000))),
        @as(i32, @bitCast(@as(u32, 0x80000000))),
        sc(w),
        sc(h),
        null,
        null,
        hinst,
        null,
    ) orelse return error.NoWindow;
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(win)));
    _ = SetTimer(hwnd, 2, 500, null);
    return hwnd;
}

fn setupDpi() void {
    if (g_dpi_set) return;
    g_dpi_set = true;
    const v2: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
    const v1: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
    const sys: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    if (SetProcessDpiAwarenessContext(v2) == 0) {
        if (SetProcessDpiAwarenessContext(v1) == 0) {
            if (SetProcessDpiAwarenessContext(sys) == 0) {
                _ = SetProcessDPIAware();
            }
        }
    }
    const d = GetDpiForSystem();
    if (d >= 48 and d <= 480) g_dpi = d;
    g_scale = @as(f64, @floatFromInt(g_dpi)) / 96.0;
}

fn winFor(hwnd: Hwnd) ?*Window {
    const p = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (p == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(p)));
}

fn pump(win: *Window) void {
    if (!win.alive) return;
    var msg: MSG = undefined;
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        if (msg.message == WM_QUIT) {
            win.alive = false;
            queueClose(win);
            return;
        }
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn queueClose(win: *Window) void {
    if (win.alive) return;
    for (win.events.items) |ev| {
        if (ev.kind == .close) return;
    }
    win.events.append(win.alloc, .{ .kind = .close }) catch {};
}

fn fillRectR(hdc: Hdc, x: i32, y: i32, w: i32, h: i32, color: Color) void {
    if (w <= 0 or h <= 0) return;
    const brush = CreateSolidBrush(rgb(color)) orelse return;
    defer _ = DeleteObject(brush);
    const l = sc(x);
    const t = sc(y);
    var rc = RECT{ .left = l, .top = t, .right = l + sc(w), .bottom = t + sc(h) };
    _ = FillRect(hdc, &rc, brush);
}

fn roundRectR(hdc: Hdc, x: i32, y: i32, w: i32, h: i32, radius: i32, fill: ?Color, border: ?Color) void {
    if (w <= 0 or h <= 0) return;
    const owned_brush: ?Hbrush = if (fill) |c| CreateSolidBrush(rgb(c)) else null;
    const brush: *anyopaque = if (owned_brush) |b| b else (GetStockObject(NULL_BRUSH) orelse return);
    const pen = CreatePen(PS_SOLID, 1, rgb(border orelse fill orelse 0xFF000000)) orelse return;
    const old_brush = SelectObject(hdc, brush);
    const old_pen = SelectObject(hdc, pen);
    const l = sc(x);
    const t = sc(y);
    const rw = sc(w);
    const rh = sc(h);
    const rr = sc(radius);
    _ = RoundRect(hdc, l, t, l + rw, t + rh, rr * 2, rr * 2);
    if (old_brush) |ob| _ = SelectObject(hdc, ob);
    if (old_pen) |op| _ = SelectObject(hdc, op);
    if (owned_brush) |b| _ = DeleteObject(b);
    _ = DeleteObject(pen);
}

fn circleR(hdc: Hdc, cx: i32, cy: i32, r: i32, color: Color) void {
    if (r <= 0) return;
    const brush = CreateSolidBrush(rgb(color)) orelse return;
    const pen = CreatePen(PS_SOLID, 1, rgb(color)) orelse return;
    const old_brush = SelectObject(hdc, brush);
    const old_pen = SelectObject(hdc, pen);
    const l = sc(cx - r);
    const t = sc(cy - r);
    const d = sc(r) * 2;
    _ = Ellipse(hdc, l, t, l + d, t + d);
    if (old_brush) |ob| _ = SelectObject(hdc, ob);
    if (old_pen) |op| _ = SelectObject(hdc, op);
    _ = DeleteObject(brush);
    _ = DeleteObject(pen);
}

fn lineR(hdc: Hdc, x1: i32, y1: i32, x2: i32, y2: i32, color: Color, width: i32) void {
    const pen = CreatePen(PS_SOLID, @max(1, sc(width)), rgb(color)) orelse return;
    const old_pen = SelectObject(hdc, pen);
    _ = MoveToEx(hdc, sc(x1), sc(y1), null);
    _ = LineTo(hdc, sc(x2), sc(y2));
    if (old_pen) |op| _ = SelectObject(hdc, op);
    _ = DeleteObject(pen);
}

fn textR(hdc: Hdc, x: i32, y: i32, w: i32, h: i32, s: []const u16, color: Color, flags: UINT) void {
    if (s.len == 0 or w <= 0 or h <= 0) return;
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, rgb(color));
    _ = SetTextAlign(hdc, TA_LEFT);
    const l = sc(x);
    const t = sc(y);
    var rc = RECT{ .left = l, .top = t, .right = l + sc(w), .bottom = t + sc(h) };
    _ = DrawTextW(hdc, wide(s), @intCast(s.len), &rc, flags);
}

const BackBuffer = struct { px: []u8, w: i32, h: i32 };

var g_back: ?BackBuffer = null;

fn blendPixel(px: i32, py: i32, color: Color) void {
    if (g_back == null) return;
    const buf = &g_back.?;
    const x = sc(px);
    const y = sc(py);
    if (x < 0 or y < 0 or x >= buf.w or y >= buf.h) return;
    const alpha = (color >> 24) & 0xFF;
    if (alpha == 0) return;
    const off = (@as(usize, @intCast(y)) * @as(usize, @intCast(buf.w)) + @as(usize, @intCast(x))) * 4;
    const dst = buf.px.ptr + off;
    const r: u32 = (color >> 16) & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;
    if (alpha == 255) {
        dst[0] = @truncate(b);
        dst[1] = @truncate(g);
        dst[2] = @truncate(r);
        dst[3] = 255;
        return;
    }
    const a = @as(f64, @floatFromInt(alpha)) / 255.0;
    const dr: f64 = @floatFromInt(dst[2]);
    const dg: f64 = @floatFromInt(dst[1]);
    const db: f64 = @floatFromInt(dst[0]);
    dst[0] = @truncate(@as(u8, @intFromFloat(db + (@as(f64, @floatFromInt(b)) - db) * a)));
    dst[1] = @truncate(@as(u8, @intFromFloat(dg + (@as(f64, @floatFromInt(g)) - dg) * a)));
    dst[2] = @truncate(@as(u8, @intFromFloat(dr + (@as(f64, @floatFromInt(r)) - dr) * a)));
    dst[3] = 255;
}

fn softDisc(cx: i32, cy: i32, r: i32, color: Color) void {
    if ((color >> 24) & 0xFF == 255) return;
    const l = sc(cx - r);
    const t = sc(cy - r);
    const d = sc(r) * 2;
    const rr = @divTrunc(d, 2);
    var y: i32 = 0;
    while (y <= d) : (y += 1) {
        var x: i32 = 0;
        while (x <= d) : (x += 1) {
            const dx = x - rr;
            const dy = y - rr;
            if (dx * dx + dy * dy <= rr * rr) blendPixel(l + x, t + y, color);
        }
    }
}

fn stampDisc(cx: i32, cy: i32, r: i32, color: Color) void {
    const l = cx - r;
    const t = cy - r;
    const d = r * 2;
    const rr = @divTrunc(d, 2);
    var y: i32 = 0;
    while (y <= d) : (y += 1) {
        var x: i32 = 0;
        while (x <= d) : (x += 1) {
            const dx = x - rr;
            const dy = y - rr;
            if (dx * dx + dy * dy <= rr * rr) blendPixel(l + x, t + y, color);
        }
    }
}

fn stampDot(x: i32, y: i32, w: i32, color: Color) void {
    var oy: i32 = -w;
    while (oy <= w) : (oy += 1) {
        var ox: i32 = -w;
        while (ox <= w) : (ox += 1) {
            if (ox * ox + oy * oy <= w * w) blendPixel(x + ox, y + oy, color);
        }
    }
}

fn softLine(x1: i32, y1: i32, x2: i32, y2: i32, color: Color, width: i32) void {
    if ((color >> 24) & 0xFF == 255) return;
    var x = x1;
    var y = y1;
    const dx: i32 = @intCast(@abs(x2 - x1));
    const dy: i32 = -@as(i32, @intCast(@abs(y2 - y1)));
    const sx: i32 = if (x1 < x2) 1 else -1;
    const sy: i32 = if (y1 < y2) 1 else -1;
    var err = dx + dy;
    const w: i32 = @max(1, @divTrunc(width, 2));
    var guard: u32 = 0;
    while (guard < 100000) : (guard += 1) {
        stampDot(x, y, w, color);
        if (x == x2 and y == y2) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

fn softPoly(alloc: std.mem.Allocator, pts: []const i32, color: Color, fill: bool) void {
    if (pts.len < 6) return;
    if (fill) {
        var min_y: i32 = pts[1];
        var max_y: i32 = pts[1];
        var i: usize = 0;
        while (i < pts.len) : (i += 2) {
            if (pts[i + 1] < min_y) min_y = pts[i + 1];
            if (pts[i + 1] > max_y) max_y = pts[i + 1];
        }
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var xs: std.ArrayList(i32) = .empty;
            var j: usize = 0;
            while (j + 3 < pts.len) : (j += 2) {
                const ax = pts[j];
                const ay = pts[j + 1];
                const bx = pts[j + 2];
                const by = pts[j + 3];
                if ((ay <= y and by > y) or (by <= y and ay > y)) {
                    const t = @as(f64, @floatFromInt(y - ay)) / @as(f64, @floatFromInt(by - ay));
                    xs.append(alloc, ax + @as(i32, @intFromFloat(t * @as(f64, @floatFromInt(bx - ax))))) catch return;
                }
            }
            std.mem.sort(i32, xs.items, {}, std.sort.asc(i32));
            var k: usize = 0;
            while (k + 1 < xs.items.len) : (k += 2) {
                var x = xs.items[k];
                while (x <= xs.items[k + 1]) : (x += 1) blendPixel(x, y, color);
            }
        }
        return;
    }
    var j: usize = 0;
    while (j + 3 < pts.len) : (j += 2) softLine(pts[j], pts[j + 1], pts[j + 2], pts[j + 3], color, 1);
}

fn softArc(cx: i32, cy: i32, r: i32, start: f64, sweep: f64, color: Color, width: i32) void {
    if ((color >> 24) & 0xFF == 255) return;
    var deg = start;
    const end = start + @max(-360.0, @min(360.0, sweep));
    const w: i32 = @max(1, @divTrunc(width, 2));
    while (deg <= end) : (deg += 1) {
        const a = deg * 3.14159265358979 / 180;
        const rr: f64 = @floatFromInt(r);
        stampDot(cx + @as(i32, @intFromFloat(rr * @cos(a))), cy + @as(i32, @intFromFloat(rr * @sin(a))), w, color);
    }
}

fn softGradient(r: struct { x: i32, y: i32, w: i32, h: i32, c1: Color, c2: Color, vertical: bool }) void {
    if (r.w <= 0 or r.h <= 0) return;
    var y: i32 = 0;
    while (y < r.h) : (y += 1) {
        var x: i32 = 0;
        while (x < r.w) : (x += 1) {
            const t: f64 = if (r.vertical)
                @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(r.h))
            else
                @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(r.w));
            blendPixel(r.x + x, r.y + y, mix(r.c1, r.c2, t));
        }
    }
}

fn paint(win: *Window, hdc: Hdc) void {
    const w = sc(win.cw);
    const h = sc(win.ch);
    if (w <= 0 or h <= 0) return;
    const mem = CreateCompatibleDC(hdc) orelse return;
    defer _ = DeleteDC(mem);
    var bi: BITMAPINFO = std.mem.zeroes(BITMAPINFO);
    bi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    var bits: ?*anyopaque = null;
    const bmp = CreateDIBSection(hdc, &bi, DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = DeleteObject(bmp);
    const old_bmp = SelectObject(mem, bmp);
    _ = SetBkMode(mem, TRANSPARENT);
    const raw: [*]u8 = @ptrCast(@alignCast(bits orelse return));
    g_back = .{ .px = raw[0 .. @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4], .w = w, .h = h };
    defer g_back = null;

    fillRectR(mem, 0, 0, win.cw, win.ch, win.theme.bg);

    for (win.immed.items) |cmd| {
        switch (cmd) {
            .rect => |r| {
                if (r.outline) {
                    roundRectR(mem, r.x, r.y, r.w, r.h, r.radius, null, r.color);
                } else {
                    roundRectR(mem, r.x, r.y, r.w, r.h, r.radius, r.color, null);
                }
            },
            .line => |l| {
                lineR(mem, l.x1, l.y1, l.x2, l.y2, l.color, l.width);
                softLine(l.x1, l.y1, l.x2, l.y2, l.color, l.width);
            },
            .text => |t| {
                const f = ensureFont(win);
                const prev = if (f) |ff| SelectObject(mem, ff) else null;
                textR(mem, t.x, t.y, win.cw - t.x, t.size + 10, t.s, t.color, DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX);
                if (prev) |p| _ = SelectObject(mem, p);
            },
            .image => |im| {
                if (loadImage(win.alloc, im.path)) |img| {
                    const dw = if (im.w > 0) im.w else img.w;
                    const dh = if (im.h > 0) im.h else img.h;
                    drawImage(mem, img, im.x, im.y, dw, dh);
                }
            },
            .disc => |d| {
                circleR(mem, d.cx, d.cy, d.r, d.color);
                softDisc(d.cx, d.cy, d.r, d.color);
            },
            .ring => |r| {
                var deg: f64 = 0;
                while (deg < 360) : (deg += 0.75) {
                    const a = deg * 3.14159265358979 / 180;
                    const rr: f64 = @floatFromInt(r.r);
                    const px = r.cx + @as(i32, @intFromFloat(rr * @cos(a)));
                    const py = r.cy + @as(i32, @intFromFloat(rr * @sin(a)));
                    lineR(mem, px, py, px, py + 1, r.color, @max(1, r.width));
                }
                softArc(r.cx, r.cy, r.r, 0, 360, r.color, r.width);
            },
            .poly => |p| {
                if (p.pts.len >= 6) {
                    var pts: [64]POINT = undefined;
                    const n = @min(p.pts.len / 2, 32);
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        pts[i] = .{ .x = sc(p.pts[i * 2]), .y = sc(p.pts[i * 2 + 1]) };
                    }
                    const brush = CreateSolidBrush(rgb(p.color)) orelse return;
                    const old_brush = SelectObject(mem, brush);
                    _ = Polygon(mem, @ptrCast(&pts), @intCast(n));
                    if (old_brush) |ob| _ = SelectObject(mem, ob);
                    _ = DeleteObject(brush);
                }
                softPoly(win.alloc, p.pts, p.color, p.fill);
            },
            .arc => |a| {
                var deg = a.start;
                const end = a.start + @max(-360.0, @min(360.0, a.sweep));
                while (deg <= end) : (deg += 1) {
                    const ang = deg * 3.14159265358979 / 180;
                    const rr: f64 = @floatFromInt(a.r);
                    const px = a.cx + @as(i32, @intFromFloat(rr * @cos(ang)));
                    const py = a.cy + @as(i32, @intFromFloat(rr * @sin(ang)));
                    const px2 = a.cx + @as(i32, @intFromFloat((rr - @as(f64, @floatFromInt(a.width))) * @cos(ang)));
                    const py2 = a.cy + @as(i32, @intFromFloat((rr - @as(f64, @floatFromInt(a.width))) * @sin(ang)));
                    lineR(mem, px, py, px2, py2, a.color, 1);
                }
                softArc(a.cx, a.cy, a.r, a.start, a.sweep, a.color, a.width);
            },
            .grad => |g| {
                softGradient(.{ .x = g.x, .y = g.y, .w = g.w, .h = g.h, .c1 = g.c1, .c2 = g.c2, .vertical = g.vertical });
            },
        }
    }
    win.immed.clearRetainingCapacity();

    const f = ensureFont(win);
    const prev = if (f) |ff| SelectObject(mem, ff) else null;
    for (win.controls.items) |*c| {
        if (!c.visible) continue;
        if (!controlActive(win, c)) continue;
        if (c.parent != 0) {
            if (clipChild(mem, win, c)) |state| {
                paintControl(win, mem, c);
                _ = RestoreDC(mem, state);
            }
        } else {
            paintControl(win, mem, c);
        }
    }
    if (prev) |p| _ = SelectObject(mem, p);

    _ = BitBlt(hdc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
    if (old_bmp) |ob| {
        _ = SelectObject(mem, ob);
    }
}

pub fn controlActive(win: *Window, c: *Control) bool {
    if (c.page < 0) return true;
    if (c.parent == 0) return true;
    const box = findControl(win, c.parent) orelse return true;
    if (box.kind == .tabs) return box.active == c.page;
    return true;
}

fn clipChild(hdc: Hdc, win: *Window, c: *Control) ?i32 {
    const box = findControl(win, c.parent) orelse return null;
    const r = if (box.kind == .tabs) tabPageRect(box) else Rect{ .x = box.x, .y = box.y, .w = box.w, .h = box.h };
    if (r.w <= 0 or r.h <= 0) return null;
    const state = SaveDC(hdc);
    if (state == 0) return null;
    const clip = IntersectClipRect(hdc, sc(r.x), sc(r.y), sc(r.x + r.w), sc(r.y + r.h));
    if (clip == 0) {
        _ = RestoreDC(hdc, state);
        return null;
    }
    return state;
}

pub fn editLineHeight(win: *Window) i32 {
    return win.font_size + 6;
}

pub fn editLineStart(text: []const u8, caret: i32) i32 {
    if (caret <= 0) return 0;
    var units: i32 = 0;
    var i: usize = 0;
    var line_start: i32 = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        const w: i32 = if (cp >= 0x10000) 2 else 1;
        if (units + w > caret) break;
        units += w;
        if (cp == '\n') line_start = units;
        i = end;
    }
    return line_start;
}

pub fn editLineIndex(text: []const u8, caret: i32) i32 {
    var line: i32 = 0;
    var units: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        const w: i32 = if (cp >= 0x10000) 2 else 1;
        if (units + w > caret) break;
        units += w;
        if (cp == '\n') line += 1;
        i = end;
    }
    return line;
}

pub fn editLineCount(text: []const u8) i32 {
    if (text.len == 0) return 1;
    var n: i32 = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

pub fn editLineText(alloc: std.mem.Allocator, text: []const u8, idx: i32) ![]const u8 {
    var line: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) {
        const is_end = i == text.len or text[i] == '\n';
        if (is_end) {
            if (line == idx) return try alloc.dupe(u8, text[start..i]);
            line += 1;
            start = i + 1;
        }
        i += 1;
    }
    return try alloc.dupe(u8, "");
}

pub fn editOffsetFor(win: *Window, c: *Control, line_idx: i32, col: i32) i32 {
    const total_lines = editLineCount(c.text);
    const li = @max(0, @min(total_lines - 1, line_idx));
    const line = editLineText(win.alloc, c.text, li) catch "";
    const units = utf16Units(line, win.alloc);
    const cc = @max(0, @min(units, col));
    var base: i32 = 0;
    var l: i32 = 0;
    var units_acc: i32 = 0;
    var i: usize = 0;
    while (i < c.text.len and l < li) {
        const seq = std.unicode.utf8ByteSequenceLength(c.text[i]) catch 1;
        const end = @min(i + seq, c.text.len);
        const cp = std.unicode.utf8Decode(c.text[i..end]) catch 0xFFFD;
        const w: i32 = if (cp >= 0x10000) 2 else 1;
        units_acc += w;
        if (cp == '\n') l += 1;
        i = end;
    }
    base = units_acc;
    return base + cc;
}

pub fn editEnsureVisible(win: *Window, c: *Control) void {
    const line = editLineIndex(c.text, c.caret);
    const lh = editLineHeight(win);
    const rows: i32 = @max(1, @divTrunc(c.h - 12, lh));
    if (line < c.scroll) c.scroll = line;
    if (line >= c.scroll + rows) c.scroll = line - rows + 1;
    if (c.scroll < 0) c.scroll = 0;
}

pub fn editInsertNewline(win: *Window, c: *Control) void {
    insertText(win, c, "\n");
    editEnsureVisible(win, c);
}

pub fn insertText(win: *Window, c: *Control, ins: []const u8) void {
    const at = utf8Before(c.text, c.caret);
    var list: std.ArrayList(u8) = .empty;
    list.appendSlice(win.alloc, c.text[0..at.len]) catch return;
    list.appendSlice(win.alloc, ins) catch return;
    list.appendSlice(win.alloc, c.text[at.len..]) catch return;
    c.text = list.toOwnedSlice(win.alloc) catch return;
    c.caret += utf16Units(ins, win.alloc);
    c.caret_on = true;
    editEnsureVisible(win, c);
    redraw(win);
}

fn paintControl(win: *Window, hdc: Hdc, c: *Control) void {
    const th = win.theme;
    const dim = !c.enabled;
    const fg = if (c.tint) |t| t else if (dim) th.dim else th.text;
    switch (c.kind) {
        .label => {
            const tw = utf16(win.alloc, c.text) catch return;
            textR(hdc, c.x, c.y, c.w, c.h, tw, fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
        },
        .button => {
            const base = if (dim) th.press else if (c.pressed) th.accent_dim else if (c.hovered) mix(th.accent, th.text, 0.18) else th.accent;
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, base, if (dim) th.border else th.accent_dim);
            const tw = utf16(win.alloc, c.text) catch return;
            textR(hdc, c.x, c.y, c.w, c.h, tw, if (dim) th.dim else 0xFFFFFFFF, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        },
        .checkbox => {
            const box: i32 = @min(c.h - 6, 20);
            const by = c.y + @divTrunc(c.h - box, 2);
            roundRectR(hdc, c.x, by, box, box, 5, if (c.checked) th.accent else th.field, if (c.checked) th.accent_dim else th.border);
            if (c.checked) {
                const col: Color = if (dim) th.dim else 0xFFFFFFFF;
                lineR(hdc, c.x + 5, by + @divTrunc(box, 2), c.x + @divTrunc(box, 2) - 1, by + box - 6, col, 2);
                lineR(hdc, c.x + @divTrunc(box, 2) - 1, by + box - 6, c.x + box - 4, by + 5, col, 2);
            }
            const tw = utf16(win.alloc, c.text) catch return;
            textR(hdc, c.x + box + 10, c.y, c.w - box - 10, c.h, tw, fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        },
        .slider => {
            const cy = c.y + @divTrunc(c.h, 2);
            const track: i32 = 6;
            roundRectR(hdc, c.x, cy - @divTrunc(track, 2), c.w, track, 3, th.press, null);
            const frac = sliderFrac(c);
            const knob_x = c.x + @as(i32, @intFromFloat(frac * @as(f64, @floatFromInt(c.w))));
            if (c.enabled and knob_x > c.x) {
                roundRectR(hdc, c.x, cy - @divTrunc(track, 2), knob_x - c.x, track, 3, th.accent, null);
            }
            const r: i32 = if (c.pressed or c.hovered) 9 else 8;
            const shell: Color = if (dim) th.dim else if (c.focused) mix(th.accent, 0xFFFFFFFF, 0.45) else 0xFFFFFFFF;
            circleR(hdc, knob_x, cy, r, shell);
            circleR(hdc, knob_x, cy, r - 3, th.accent);
        },
        .progress => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, @divTrunc(c.h, 2), th.press, null);
            const fw = @as(i32, @intFromFloat(sliderFrac(c) * @as(f64, @floatFromInt(c.w))));
            if (fw > 2) roundRectR(hdc, c.x, c.y, fw, c.h, @divTrunc(c.h, 2), th.accent, null);
        },
        .textbox => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, th.field, if (c.focused) th.accent else th.border);
            const pad: i32 = 9;
            if (c.password) {
                var nchars: usize = 0;
                for (c.text) |b| {
                    if ((b & 0xC0) != 0x80) nchars += 1;
                }
                const masked = win.alloc.alloc(u8, nchars) catch return;
                @memset(masked, '*');
                const tw = utf16(win.alloc, masked) catch return;
                const pre = utf8Before(c.text, c.caret);
                var npre: usize = 0;
                for (pre) |b| {
                    if ((b & 0xC0) != 0x80) npre += 1;
                }
                const start: usize = if (npre > 0) visibleStart(tw, @intCast(npre)) else 0;
                textR(hdc, c.x + pad, c.y, c.w - pad * 2, c.h, tw[start..], fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
                if (c.focused and c.caret_on) {
                    const starw = measure(win, hdc, "*");
                    const cx = c.x + pad + starw * @as(i32, @intCast(npre));
                    lineR(hdc, cx, c.y + 6, cx, c.y + c.h - 6, th.accent, 1);
                }
                return;
            }
            const tw = utf16(win.alloc, c.text) catch return;
            const start: usize = if (c.caret > 0) visibleStart(tw, c.caret) else 0;
            textR(hdc, c.x + pad, c.y, c.w - pad * 2, c.h, tw[start..], fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            if (c.focused and c.caret_on) {
                const pre = utf8Before(c.text, c.caret);
                const cw = if (pre.len == 0) 0 else measure(win, hdc, pre);
                lineR(hdc, c.x + pad + cw, c.y + 6, c.x + pad + cw, c.y + c.h - 6, th.accent, 1);
            }
        },
        .editbox => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, th.field, if (c.focused) th.accent else th.border);
            const pad: i32 = 9;
            const lh = editLineHeight(win);
            const rows: i32 = @max(1, @divTrunc(c.h - pad * 2, lh));
            const total = editLineCount(c.text);
            if (c.scroll > total - 1) c.scroll = @max(0, total - 1);
            var gutter: i32 = 0;
            if (c.linenums) {
                var digits: i32 = 1;
                var t = total;
                while (t >= 10) {
                    digits += 1;
                    t = @divTrunc(t, 10);
                }
                gutter = digits * 8 + 14;
                fillRectR(hdc, c.x + 2, c.y + 2, gutter, c.h - 4, th.press);
            }
            const tx0 = c.x + pad + gutter;
            const caret_line = editLineIndex(c.text, c.caret);
            var i: i32 = 0;
            while (i < rows) : (i += 1) {
                const li = c.scroll + i;
                if (li >= total) break;
                const ry = c.y + pad + i * lh;
                if (c.curline and li == caret_line) {
                    fillRectR(hdc, c.x + 3, ry, c.w - 6, lh, c.curline_color);
                }
                for (c.marks.items) |m| {
                    if (m.line != li) continue;
                    const line_s = editLineText(win.alloc, c.text, li) catch continue;
                    const units = utf16Units(line_s, win.alloc);
                    const c0 = @max(0, @min(units, m.col));
                    const c1 = @max(0, @min(units, m.col + m.len));
                    if (c1 <= c0) continue;
                    const x0 = tx0 + measurePrefix(win, hdc, line_s, c0);
                    const x1 = tx0 + measurePrefix(win, hdc, line_s, c1);
                    fillRectR(hdc, x0, ry, x1 - x0, lh, m.color);
                }
                if (c.linenums) {
                    var nb: [16]u8 = undefined;
                    const ns = std.fmt.bufPrint(&nb, "{d}", .{li + 1}) catch "?";
                    const nw = utf16(win.alloc, ns) catch continue;
                    textR(hdc, c.x + 6, ry, gutter - 8, lh, nw, th.dim, DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
                }
                const line = editLineText(win.alloc, c.text, li) catch continue;
                const lw = utf16(win.alloc, line) catch continue;
                textR(hdc, tx0, ry, c.w - pad * 2 - gutter, lh, lw, fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            }
            if (c.focused and c.caret_on) {
                const line = editLineIndex(c.text, c.caret);
                const ls = editLineStart(c.text, c.caret);
                const line_s = editLineText(win.alloc, c.text, line) catch "";
                const col_units = c.caret - ls;
                var upto: i32 = 0;
                var ui: usize = 0;
                var acc: i32 = 0;
                while (ui < line_s.len and acc < col_units) {
                    const seq = std.unicode.utf8ByteSequenceLength(line_s[ui]) catch 1;
                    const end = @min(ui + seq, line_s.len);
                    const cp = std.unicode.utf8Decode(line_s[ui..end]) catch 0xFFFD;
                    const w: i32 = if (cp >= 0x10000) 2 else 1;
                    if (acc + w > col_units) break;
                    acc += w;
                    upto = @intCast(end);
                    ui = end;
                }
                const cw = measure(win, hdc, line_s[0..@intCast(@max(0, upto))]);
                const vline = line - c.scroll;
                if (vline >= 0 and vline < rows) {
                    const ry = c.y + pad + vline * lh;
                    lineR(hdc, tx0 + cw, ry + 2, tx0 + cw, ry + lh - 2, th.accent, 1);
                }
            }
            if (total > rows) {
                const track_x = c.x + c.w - 6;
                fillRectR(hdc, track_x, c.y + pad, 3, c.h - pad * 2, th.press);
                const frac_total = @as(f64, @floatFromInt(rows)) / @as(f64, @floatFromInt(total));
                const thumb = @max(16.0, @as(f64, @floatFromInt(c.h - pad * 2)) * frac_total);
                const denom: i32 = total - rows;
                const scroll_frac: f64 = if (denom == 0) 0 else @as(f64, @floatFromInt(@max(0, c.scroll))) / @as(f64, @floatFromInt(denom));
                const thumb_y = c.y + pad + @as(i32, @intFromFloat(scroll_frac * (@as(f64, @floatFromInt(c.h - pad * 2)) - thumb)));
                fillRectR(hdc, track_x, thumb_y, 3, @intFromFloat(thumb), th.dim);
            }
        },
        .list => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, th.field, if (c.focused) th.accent else th.border);
            const row: i32 = 22;
            const pad: i32 = 6;
            const rows: i32 = @max(1, @divTrunc(c.h - pad * 2, row));
            if (c.sel >= @as(i32, @intCast(c.items.items.len))) c.sel = @as(i32, @intCast(c.items.items.len)) - 1;
            var i: i32 = 0;
            while (i < rows) : (i += 1) {
                const idx = c.scroll + i;
                if (idx < 0) continue;
                if (idx >= @as(i32, @intCast(c.items.items.len))) break;
                const ry = c.y + pad + i * row;
                if (c.sel == idx) fillRectR(hdc, c.x + 3, ry, c.w - 6, row, th.accent_dim);
                const iw = utf16(win.alloc, c.items.items[@intCast(idx)]) catch continue;
                textR(hdc, c.x + pad + 6, ry, c.w - pad * 2, row, iw, if (c.sel == idx) 0xFFFFFFFF else fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            }
            if (c.items.items.len > @as(usize, @intCast(rows))) {
                const track_x = c.x + c.w - 6;
                fillRectR(hdc, track_x, c.y + pad, 3, c.h - pad * 2, th.press);
                const total: f64 = @floatFromInt(c.items.items.len);
                const visible: f64 = @floatFromInt(rows);
                const track_h: f64 = @floatFromInt(c.h - pad * 2);
                const thumb_h: i32 = @intFromFloat(@max(16.0, track_h * (visible / total)));
                const denom = c.items.items.len - @as(usize, @intCast(rows));
                const scroll_frac: f64 = if (denom == 0) 0 else @as(f64, @floatFromInt(@max(0, c.scroll))) / @as(f64, @floatFromInt(denom));
                const thumb_y = c.y + pad + @as(i32, @intFromFloat(scroll_frac * (track_h - @as(f64, @floatFromInt(thumb_h)))));
                fillRectR(hdc, track_x, thumb_y, 3, thumb_h, th.dim);
            }
        },
        .vbox, .hbox, .panel => {},
        .groupbox => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, null, th.border);
            if (c.text.len > 0) {
                const tw = utf16(win.alloc, c.text) catch return;
                const tw_w = measure(win, hdc, c.text) + 10;
                fillRectR(hdc, c.x + 10, c.y - 8, tw_w, 16, th.bg);
                textR(hdc, c.x + 15, c.y - 8, tw_w, 16, tw, th.dim, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            }
        },
        .tabs => {
            const bar = @max(20, @divTrunc(c.h, 8));
            var tx = c.x;
            for (c.pages.items, 0..) |title, i| {
                const tw16 = utf16(win.alloc, title) catch continue;
                const tw_w = measure(win, hdc, title) + 24;
                const active = @as(i32, @intCast(i)) == c.active;
                if (active) roundRectR(hdc, tx, c.y, tw_w, bar + 6, 6, th.panel, null);
                textR(hdc, tx, c.y, tw_w, bar, tw16, if (active) th.text else th.dim, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
                tx += tw_w + 2;
            }
            const page = tabPageRect(c);
            roundRectR(hdc, page.x, page.y, page.w, page.h, 0, th.panel, th.border);
        },
        .radio => {
            const box: i32 = @min(c.h - 6, 20);
            const by = c.y + @divTrunc(c.h - box, 2);
            const on = c.checked;
            roundRectR(hdc, c.x, by, box, box, box, null, if (on) th.accent else th.border);
            if (on) circleR(hdc, c.x + @divTrunc(box, 2), by + @divTrunc(box, 2), @divTrunc(box, 4), th.accent);
            const tw = utf16(win.alloc, c.text) catch return;
            textR(hdc, c.x + box + 10, c.y, c.w - box - 10, c.h, tw, fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        },
        .combo => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, th.field, if (c.focused) th.accent else th.border);
            var label = c.text;
            if (c.sel >= 0 and @as(usize, @intCast(c.sel)) < c.items.items.len) label = c.items.items[@intCast(c.sel)];
            const tw = utf16(win.alloc, label) catch return;
            textR(hdc, c.x + 9, c.y, c.w - 30, c.h, tw, fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
            const ax = c.x + c.w - 20;
            const ay = c.y + @divTrunc(c.h, 2);
            lineR(hdc, ax - 4, ay - 2, ax, ay + 2, fg, 1);
            lineR(hdc, ax, ay + 2, ax + 4, ay - 2, fg, 1);
            if (c.open and c.items.items.len > 0) {
                const row: i32 = 22;
                const ph = @as(i32, @intCast(c.items.items.len)) * row + 8;
                fillRectR(hdc, c.x, c.y + c.h, c.w, ph, th.panel);
                roundRectR(hdc, c.x, c.y + c.h, c.w, ph, 6, null, th.border);
                var i: i32 = 0;
                for (c.items.items) |item| {
                    const ry = c.y + c.h + 4 + i * row;
                    if (c.sel == i) fillRectR(hdc, c.x + 3, ry, c.w - 6, row, th.accent_dim);
                    const iw = utf16(win.alloc, item) catch continue;
                    textR(hdc, c.x + 9, ry, c.w - 18, row, iw, if (c.sel == i) 0xFFFFFFFF else fg, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
                    i += 1;
                }
            }
        },
        .picture => {
            roundRectR(hdc, c.x, c.y, c.w, c.h, 6, th.field, th.border);
            if (c.pic) |img| {
                drawImage(hdc, img, c.x + 2, c.y + 2, c.w - 4, c.h - 4);
            } else {
                const tw = utf16(win.alloc, "no image") catch return;
                textR(hdc, c.x, c.y, c.w, c.h, tw, th.dim, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            }
        },
    }
}

fn sliderFrac(c: *Control) f64 {
    const span = c.vmax - c.vmin;
    if (span == 0) return 0;
    return @max(0.0, @min(1.0, (c.value - c.vmin) / span));
}

fn measurePrefix(win: *Window, hdc: Hdc, line_s: []const u8, units: i32) i32 {
    var acc: i32 = 0;
    var i: usize = 0;
    while (i < line_s.len and acc < units) {
        const seq = std.unicode.utf8ByteSequenceLength(line_s[i]) catch 1;
        const end = @min(i + seq, line_s.len);
        const cp = std.unicode.utf8Decode(line_s[i..end]) catch 0xFFFD;
        const w: i32 = if (cp >= 0x10000) 2 else 1;
        if (acc + w > units) break;
        acc += w;
        i = end;
    }
    if (i == 0) return 0;
    return measure(win, hdc, line_s[0..i]);
}

fn editGutter(c: *Control, total: i32) i32 {
    if (!c.linenums) return 0;
    var digits: i32 = 1;
    var t = total;
    while (t >= 10) {
        digits += 1;
        t = @divTrunc(t, 10);
    }
    return digits * 8 + 14;
}

fn measure(win: *Window, hdc: Hdc, s: []const u8) i32 {
    const tw = utf16(win.alloc, s) catch return 0;
    var out: SIZE = .{ .cx = 0, .cy = 0 };
    _ = GetTextExtentPoint32W(hdc, wide(tw), @intCast(tw.len), &out);
    return uns(out.cx);
}

fn visibleStart(tw: []const u16, caret: i32) usize {
    var units: i32 = 0;
    var i: usize = 0;
    while (i < tw.len) {
        const step: i32 = if (tw[i] >= 0x10000) 2 else 1;
        if (units + step > caret) break;
        units += step;
        i += @intCast(step);
    }
    return i;
}

fn wndProc(hwnd: Hwnd, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const win = winFor(hwnd) orelse return DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            if (BeginPaint(hwnd, &ps)) |hdc| {
                paint(win, hdc);
                _ = EndPaint(hwnd, &ps);
            }
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_GETDLGCODE => return DLGC_WANTALLKEYS,
        WM_CLOSE => {
            win.alive = false;
            queueClose(win);
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_SIZE => {
            win.cw = uns(lowWord(lparam));
            win.ch = uns(highWord(lparam));
            queueEvent(win, .{ .kind = .resize, .w = win.cw, .h = win.ch });
            return 0;
        },
        WM_MOVE => {
            queueEvent(win, .{
                .kind = .move,
                .x = uns(lowWord(lparam)),
                .y = uns(highWord(lparam)),
            });
            return 0;
        },
        WM_TIMER => {
            if (wparam == 1) {
                queueEvent(win, .{ .kind = .tick });
                return 0;
            }
            if (wparam == 2) {
                for (win.controls.items) |*c| {
                    if (c.kind == .textbox) c.caret_on = !c.caret_on;
                }
                redraw(win);
                return 0;
            }
            return 0;
        },
        WM_MOUSEMOVE => {
            const x = uns(lowWord(lparam));
            const y = uns(highWord(lparam));
            win.mx = x;
            win.my = y;
            var cursor: ?Hcursor = null;
            for (win.controls.items) |*c| {
                const was = c.hovered;
                c.hovered = c.visible and c.enabled and hitTest(c, x, y);
                if (c.hovered and !was) cursor = cursorFor(c.kind);
                if (!c.hovered and was) cursor = cursorFor(.label);
            }
            if (win.drag_id != 0) {
                if (findControl(win, win.drag_id)) |c| {
                    if (c.kind == .slider) {
                        c.value = valueAtX(c, x);
                        queueEvent(win, .{ .kind = .drag, .id = c.id, .x = x, .y = y, .cb = c.cb });
                    }
                }
            }
            if (cursor) |cu| _ = SetCursor(cu);
            redraw(win);
            return 0;
        },
        WM_LBUTTONDOWN => {
            const x = uns(lowWord(lparam));
            const y = uns(highWord(lparam));
            win.mx = x;
            win.my = y;
            for (win.controls.items) |*c| c.focused = false;
            if (hitTop(win, x, y)) |c| {
                c.focused = focusable(c.kind);
                if (c.kind == .editbox and c.enabled) {
                    const hdc = GetDC(hwnd) orelse null;
                    if (hdc) |d| {
                        const f = ensureFont(win);
                        const prev = if (f) |ff| SelectObject(d, ff) else null;
                        editClickPos(win, d, c, x, y);
                        if (prev) |p| _ = SelectObject(d, p);
                        _ = ReleaseDC(hwnd, d);
                    }
                }
                if (c.enabled) {
                    c.pressed = true;
                    win.pressed_id = c.id;
                    if (c.kind == .slider) {
                        win.drag_id = c.id;
                        c.value = valueAtX(c, x);
                        queueEvent(win, .{ .kind = .drag, .id = c.id, .x = x, .y = y, .cb = c.cb });
                    }
                    if (c.kind == .list) {
                        const row: i32 = 22;
                        const pad: i32 = 6;
                        const idx = c.scroll + @divTrunc(y - (c.y + pad), row);
                        if (idx >= 0 and idx < @as(i32, @intCast(c.items.items.len))) {
                            c.sel = idx;
                            scrollIntoView(c);
                            queueEvent(win, .{ .kind = .change, .id = c.id, .x = x, .y = y, .cb = c.cb });
                        }
                    }
                }
                _ = SetCapture(hwnd);
            }
            redraw(win);
            return 0;
        },
        WM_LBUTTONUP => {
            const x = uns(lowWord(lparam));
            const y = uns(highWord(lparam));
            win.mx = x;
            win.my = y;
            _ = ReleaseCapture();
            if (win.drag_id != 0) {
                if (findControl(win, win.drag_id)) |c| {
                    queueEvent(win, .{ .kind = .change, .id = c.id, .x = x, .y = y, .cb = c.cb });
                }
                win.drag_id = 0;
            }
            if (win.pressed_id != 0) {
                if (findControl(win, win.pressed_id)) |c| {
                    c.pressed = false;
                    if (hitTest(c, x, y)) {
                        if (c.kind == .checkbox) {
                            c.checked = !c.checked;
                            queueEvent(win, .{ .kind = .toggle, .id = c.id, .x = x, .y = y, .cb = c.cb });
                        } else if (c.kind == .radio) {
                            radioSelect(win, c);
                            queueEvent(win, .{ .kind = .toggle, .id = c.id, .x = x, .y = y, .cb = c.cb });
                        } else if (c.kind == .combo) {
                            c.open = !c.open;
                            queueEvent(win, .{ .kind = .change, .id = c.id, .x = x, .y = y, .cb = c.cb });
                        } else if (c.kind == .slider) {
                            queueEvent(win, .{ .kind = .change, .id = c.id, .x = x, .y = y, .cb = c.cb });
                        } else if (c.kind != .tabs) {
                            queueEvent(win, .{ .kind = .click, .id = c.id, .x = x, .y = y, .cb = c.cb });
                        }
                    }
                }
                win.pressed_id = 0;
            }
            redraw(win);
            return 0;
        },
        WM_MOUSEWHEEL => {
            const delta: i32 = highWord16(wparam);
            const x = lowWord(lparam);
            const y = highWord(lparam);
            if (hitTop(win, x, y)) |c| {
                if (c.kind == .list) {
                    c.scroll -= @divTrunc(delta, 120);
                    const max_scroll: i32 = @as(i32, @intCast(c.items.items.len)) - 1;
                    if (c.scroll > max_scroll) c.scroll = max_scroll;
                    if (c.scroll < 0) c.scroll = 0;
                } else if (c.kind == .editbox) {
                    const lh = editLineHeight(win);
                    const rows: i32 = @max(1, @divTrunc(c.h - 18, lh));
                    c.scroll -= @divTrunc(delta, 120) * @max(1, @divTrunc(rows, 2));
                    const max_scroll: i32 = editLineCount(c.text) - 1;
                    if (c.scroll > max_scroll) c.scroll = max_scroll;
                    if (c.scroll < 0) c.scroll = 0;
                } else {
                    queueEvent(win, .{ .kind = .wheel, .id = c.id, .x = x, .y = y, .wheel = delta, .cb = c.cb });
                }
            } else {
                queueEvent(win, .{ .kind = .wheel, .id = 0, .x = x, .y = y, .wheel = delta });
            }
            redraw(win);
            return 0;
        },
        WM_CHAR => {
            if (win.pressed_id == 0) {
                if (focusedControl(win)) |c| {
                    if ((c.kind == .textbox or c.kind == .editbox) and c.enabled) {
                        const code: u32 = @truncate(wparam);
                        if (code >= 32 and code != 127) {
                            if (!mods()[0]) insertChar(win, c, code);
                        }
                    }
                }
            }
            return 0;
        },
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            const vk: u8 = @truncate(wparam);
            if (focusedControl(win)) |c| {
                if (c.enabled) handleKeyFor(win, c, vk);
            }
            var cb: i32 = -1;
            if (focusedControl(win)) |c| cb = c.cb;
            const m = mods();
            queueEvent(win, .{
                .kind = .key,
                .id = if (focusedControl(win)) |c| c.id else 0,
                .key = keyName(vk),
                .ctrl = m[0],
                .shift = m[1],
                .alt = m[2],
                .cb = cb,
            });
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

var g_hand: ?Hcursor = null;
var g_ibeam: ?Hcursor = null;

fn cursorFor(kind: Kind) ?Hcursor {
    switch (kind) {
        .button, .checkbox, .slider => {
            if (g_hand == null) g_hand = LoadCursorW(null, wide(std.unicode.utf8ToUtf16LeStringLiteral("IDC_HAND")));
            return g_hand;
        },
        .textbox => {
            if (g_ibeam == null) g_ibeam = LoadCursorW(null, wide(std.unicode.utf8ToUtf16LeStringLiteral("IDC_IBEAM")));
            return g_ibeam;
        },
        else => return null,
    }
}

fn focusable(kind: Kind) bool {
    return kind == .textbox or kind == .editbox or kind == .slider or kind == .list;
}

fn editClickPos(win: *Window, hdc: Hdc, c: *Control, x: i32, y: i32) void {
    const pad: i32 = 9;
    const lh = editLineHeight(win);
    const total = editLineCount(c.text);
    const tx0 = c.x + pad + editGutter(c, total);
    var line = c.scroll + @divTrunc(y - (c.y + pad), lh);
    if (line < 0) line = 0;
    if (line >= total) line = total - 1;
    const line_s = editLineText(win.alloc, c.text, line) catch "";
    var best: i32 = 0;
    var units: i32 = 0;
    var i: usize = 0;
    if (tx0 <= x) {
        while (i < line_s.len) {
            const seq = std.unicode.utf8ByteSequenceLength(line_s[i]) catch 1;
            const end = @min(i + seq, line_s.len);
            const cp = std.unicode.utf8Decode(line_s[i..end]) catch 0xFFFD;
            const w: i32 = if (cp >= 0x10000) 2 else 1;
            units += w;
            if (tx0 + measure(win, hdc, line_s[0..end]) > x) {
                units -= w;
                break;
            }
            best = units;
            i = end;
        }
    }
    c.caret = editOffsetFor(win, c, line, best);
    editEnsureVisible(win, c);
}

fn hitTest(c: *Control, x: i32, y: i32) bool {
    if (!c.visible) return false;
    return x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + c.h;
}

fn hitTop(win: *Window, x: i32, y: i32) ?*Control {
    var i = win.controls.items.len;
    while (i > 0) {
        i -= 1;
        const c = &win.controls.items[i];
        if (!controlActive(win, c)) continue;
        if (c.kind == .tabs) {
            if (y >= c.y and y < c.y + @max(20, @divTrunc(c.h, 8))) {
                if (tabHit(c, x)) |idx| {
                    if (c.active != idx) {
                        c.active = idx;
                        c.flow = 0;
                        queueEvent(win, .{ .kind = .change, .id = c.id, .x = x, .y = y, .cb = c.cb });
                    }
                }
                return c;
            }
        }
        if (isContainer(c.kind)) continue;
        if (c.kind == .combo and c.open) {
            if (comboPopupRect(c, x, y)) {
                if (comboHitRow(c, x, y)) |row| {
                    c.sel = row;
                    c.open = false;
                    queueEvent(win, .{ .kind = .change, .id = c.id, .x = x, .y = y, .cb = c.cb });
                }
                return c;
            }
        }
        if (hitTest(c, x, y)) {
            if (c.parent != 0) {
                const box = findControl(win, c.parent) orelse return c;
                const r = if (box.kind == .tabs) tabPageRect(box) else Rect{ .x = box.x, .y = box.y, .w = box.w, .h = box.h };
                if (x < r.x or x >= r.x + r.w or y < r.y or y >= r.y + r.h) continue;
            }
            return c;
        }
    }
    return null;
}

fn tabHit(c: *Control, x: i32) ?i32 {
    var tx: i32 = c.x;
    for (c.pages.items, 0..) |title, i| {
        const tw: i32 = @as(i32, @intCast(title.len)) * 7 + 24;
        if (x >= tx and x < tx + tw) return @intCast(i);
        tx += tw + 2;
    }
    return null;
}

fn comboPopupRect(c: *Control, x: i32, y: i32) bool {
    const row: i32 = 22;
    const h = @as(i32, @intCast(c.items.items.len)) * row + 8;
    return x >= c.x and x < c.x + c.w and y >= c.y + c.h and y < c.y + c.h + h;
}

fn comboHitRow(c: *Control, x: i32, y: i32) ?i32 {
    _ = x;
    const row: i32 = 22;
    const idx = @divTrunc(y - (c.y + c.h) - 4, row);
    if (idx < 0 or idx >= @as(i32, @intCast(c.items.items.len))) return null;
    return idx;
}

fn radioSelect(win: *Window, c: *Control) void {
    for (win.controls.items) |*other| {
        if (other == c) continue;
        if (other.kind != .radio) continue;
        if (!std.mem.eql(u8, other.group, c.group)) continue;
        other.checked = false;
    }
    c.checked = true;
}

fn focusedControl(win: *Window) ?*Control {
    for (win.controls.items) |*c| {
        if (c.focused) return c;
    }
    return null;
}

fn valueAtX(c: *Control, x: i32) f64 {
    const w = @as(f64, @floatFromInt(c.w));
    if (w <= 0) return c.vmin;
    const frac = @max(0.0, @min(1.0, @as(f64, @floatFromInt(x - c.x)) / w));
    return c.vmin + frac * (c.vmax - c.vmin);
}

fn scrollIntoView(c: *Control) void {
    const row: i32 = 22;
    const pad: i32 = 6;
    const rows: i32 = @max(1, @divTrunc(c.h - pad * 2, row));
    if (c.sel < c.scroll) c.scroll = c.sel;
    if (c.sel >= c.scroll + rows) c.scroll = c.sel - rows + 1;
    if (c.scroll < 0) c.scroll = 0;
}

fn handleKeyFor(win: *Window, c: *Control, vk: u8) void {
    switch (c.kind) {
        .textbox => {
            switch (vk) {
                VK_BACK => deleteBeforeCaret(win, c),
                VK_DELETE => deleteAtCaret(win, c),
                VK_LEFT => {
                    if (c.caret > 0) c.caret -= 1;
                    redraw(win);
                },
                VK_RIGHT => {
                    const total = utf16Units(c.text, win.alloc);
                    if (c.caret < total) c.caret += 1;
                    redraw(win);
                },
                VK_HOME => {
                    c.caret = 0;
                    redraw(win);
                },
                VK_END => {
                    c.caret = utf16Units(c.text, win.alloc);
                    redraw(win);
                },
                VK_RETURN => queueEvent(win, .{ .kind = .change, .id = c.id, .cb = c.cb }),
                else => {},
            }
        },
        .editbox => {
            switch (vk) {
                VK_BACK => deleteBeforeCaret(win, c),
                VK_DELETE => deleteAtCaret(win, c),
                VK_LEFT => {
                    if (c.caret > 0) c.caret -= 1;
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_RIGHT => {
                    const total = utf16Units(c.text, win.alloc);
                    if (c.caret < total) c.caret += 1;
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_UP => {
                    const line = editLineIndex(c.text, c.caret);
                    if (line > 0) {
                        const col = c.caret - editLineStart(c.text, c.caret);
                        c.caret = editOffsetFor(win, c, line - 1, col);
                        editEnsureVisible(win, c);
                        redraw(win);
                    }
                },
                VK_DOWN => {
                    const line = editLineIndex(c.text, c.caret);
                    const col = c.caret - editLineStart(c.text, c.caret);
                    c.caret = editOffsetFor(win, c, line + 1, col);
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_HOME => {
                    c.caret = editLineStart(c.text, c.caret);
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_END => {
                    const ls = editLineStart(c.text, c.caret);
                    const line = editLineIndex(c.text, c.caret);
                    const line_s = editLineText(win.alloc, c.text, line) catch "";
                    c.caret = ls + utf16Units(line_s, win.alloc);
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_PRIOR => {
                    const lh = editLineHeight(win);
                    const rows: i32 = @max(1, @divTrunc(c.h - 12, lh));
                    const line = editLineIndex(c.text, c.caret);
                    const col = c.caret - editLineStart(c.text, c.caret);
                    c.caret = editOffsetFor(win, c, line - rows, col);
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_NEXT => {
                    const lh = editLineHeight(win);
                    const rows: i32 = @max(1, @divTrunc(c.h - 12, lh));
                    const line = editLineIndex(c.text, c.caret);
                    const col = c.caret - editLineStart(c.text, c.caret);
                    c.caret = editOffsetFor(win, c, line + rows, col);
                    editEnsureVisible(win, c);
                    redraw(win);
                },
                VK_TAB => {
                    insertText(win, c, "  ");
                },
                VK_RETURN => {
                    editInsertNewline(win, c);
                    queueEvent(win, .{ .kind = .change, .id = c.id, .cb = c.cb });
                },
                else => {},
            }
        },
        .slider => {
            const span = c.vmax - c.vmin;
            const stepv = if (span > 100) 1 else span / 100;
            const step: f64 = if (stepv == 0) 1 else stepv;
            var moved = false;
            if (vk == VK_LEFT or vk == VK_DOWN) {
                c.value -= step;
                moved = true;
            }
            if (vk == VK_RIGHT or vk == VK_UP) {
                c.value += step;
                moved = true;
            }
            if (moved) {
                if (c.value < c.vmin) c.value = c.vmin;
                if (c.value > c.vmax) c.value = c.vmax;
                queueEvent(win, .{ .kind = .change, .id = c.id, .cb = c.cb });
                redraw(win);
            }
        },
        .list => {
            var moved = false;
            if (vk == VK_UP) {
                c.sel -= 1;
                moved = true;
            }
            if (vk == VK_DOWN) {
                c.sel += 1;
                moved = true;
            }
            if (vk == VK_HOME) {
                c.sel = 0;
                moved = true;
            }
            if (vk == VK_END) {
                c.sel = @as(i32, @intCast(c.items.items.len)) - 1;
                moved = true;
            }
            if (moved) {
                if (c.sel < 0) c.sel = 0;
                if (c.sel >= @as(i32, @intCast(c.items.items.len))) c.sel = @as(i32, @intCast(c.items.items.len)) - 1;
                scrollIntoView(c);
                queueEvent(win, .{ .kind = .change, .id = c.id, .cb = c.cb });
                redraw(win);
            }
        },
        .combo => {
            if (vk == VK_UP) {
                if (c.sel > 0) c.sel -= 1;
            }
            if (vk == VK_DOWN) {
                if (c.sel + 1 < @as(i32, @intCast(c.items.items.len))) c.sel += 1;
            }
            if (vk == VK_RETURN) {
                c.open = !c.open;
                queueEvent(win, .{ .kind = .change, .id = c.id, .cb = c.cb });
            }
            redraw(win);
        },
        else => {},
    }
}

fn insertChar(win: *Window, c: *Control, code: u32) void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(code), &buf) catch return;
    const at = utf8Before(c.text, c.caret);
    var list: std.ArrayList(u8) = .empty;
    list.appendSlice(win.alloc, c.text[0..at.len]) catch return;
    list.appendSlice(win.alloc, buf[0..n]) catch return;
    list.appendSlice(win.alloc, c.text[at.len..]) catch return;
    c.text = list.toOwnedSlice(win.alloc) catch return;
    c.caret += if (code >= 0x10000) @as(i32, 2) else @as(i32, 1);
    c.caret_on = true;
    redraw(win);
}

fn deleteBeforeCaret(win: *Window, c: *Control) void {
    if (c.caret <= 0) return;
    const pre = utf8Before(c.text, c.caret);
    if (pre.len == 0) return;
    var start = pre.len - 1;
    while (start > 0 and (c.text[start] & 0xC0) == 0x80) start -= 1;
    const removed = utf16Units(c.text[start..pre.len], win.alloc);
    var list: std.ArrayList(u8) = .empty;
    list.appendSlice(win.alloc, c.text[0..start]) catch return;
    list.appendSlice(win.alloc, c.text[pre.len..]) catch return;
    c.text = list.toOwnedSlice(win.alloc) catch return;
    c.caret -= removed;
    redraw(win);
}

fn deleteAtCaret(win: *Window, c: *Control) void {
    const total = utf16Units(c.text, win.alloc);
    if (c.caret >= total) return;
    const at = utf8Before(c.text, c.caret);
    const post_full = utf8Before(c.text, c.caret + 1);
    var end = post_full.len;
    if (end <= at.len) {
        end = @min(at.len + 1, c.text.len);
        while (end < c.text.len and (c.text[end] & 0xC0) == 0x80) end += 1;
    }
    var list: std.ArrayList(u8) = .empty;
    list.appendSlice(win.alloc, c.text[0..at.len]) catch return;
    list.appendSlice(win.alloc, c.text[end..]) catch return;
    c.text = list.toOwnedSlice(win.alloc) catch return;
    redraw(win);
}



