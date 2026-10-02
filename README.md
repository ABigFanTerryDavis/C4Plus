# C4Plus

C4Plus (`.c4p`) is a small, batteries-included scripting language with headers (`.c4h`),
assembly sidecars (`.c4asm`), batch files (`.c4bht`) and projects (`.c4proj`) — all driven by
one binary, `c4c` (shipped under a second name, `c4pp`, as the same engine with the
extended-tool name).

Out of the box you get an **interpreter**, a **C transpiler**, a **REPL**, a **step tracer**,
a **formatter**, a **Windows GUI module**, and a **freestanding kernel path** that boots real
x86 hardware (or QEMU) from a stage-1 boot sector all the way up to ring-3 user programs,
an ELF loader and a preemptive scheduler.

```c4p
print "hello"

let x = 2 + 3 * 4
fn add(a, b) { return a + b }
print add(2, 3)          # 9... no. 5. (the language is honest, even if this comment isn't)

for i in 1..5 { print i }
```

- [Why C4Plus](#why-c4plus)
- [Install](#install)
- [60-second tour](#60-second-tour)
- [Commands](#commands)
- [Language guide](#language-guide)
  - [Values and variables](#values-and-variables)
  - [Strings, lists, dicts, structs](#strings-lists-dicts-structs)
  - [Flow control](#flow-control)
  - [Functions, function values, closures](#functions-function-values-closures)
  - [Errors](#errors)
- [Builtins](#builtins)
- [Modules](#modules)
- [Assembly sidecars](#assembly-sidecars)
- [GUI apps](#gui-apps)
- [Tracer, formatter, batch files, projects](#tracer-formatter-batch-files-projects)
- [Native compilation](#native-compilation)
- [Freestanding kernels](#freestanding-kernels)
  - [Kernel recipe](#kernel-recipe)
  - [User mode and multitasking](#user-mode-and-multitasking)
  - [Kernel meter](#kernel-meter)
- [Repository layout](#repository-layout)
- [Versioning](#versioning)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why C4Plus

Most small languages stop at "runs scripts". C4Plus keeps going in both directions:

- **Up toward apps:** a real Windows GUI toolkit (windows, buttons, sliders, list views,
  tabs, an edit box with syntax-highlight support, immediate-mode drawing, clipboard,
  native file dialogs, synthetic input for UI tests) callable straight from script.
- **Down toward metal:** the same language compiles to freestanding C99 with no libc, so
  `.c4p` files become kernels: GDT/IDT/TSS setup, PIC + PIT programming, paging, a kernel
  heap, `int 0x80` syscalls, an ELF loader, ring-3 entry and timer-preempted multitasking.

One syntax, one toolchain, scripts to kernels. That is the whole pitch.

---

## Install

You need **Zig 0.16.0**. For native output (`--emit-c` compiled with `gcc`) you also need a
C compiler; for the kernel templates you need a 32-bit toolchain (`gcc -m32`, `as --32`,
`ld`, `objcopy`), `python` (for `user/mkelf.py`) and `qemu-system-i386` for testing.

```powershell
zig build                       # -> zig-out/bin/c4c.exe + c4pp.exe
```

Put `zig-out/bin` on `PATH`, or copy the two exes somewhere already on `PATH`
(e.g. `~/.c4plus/bin`). Check with:

```powershell
c4c exec "1 + 1"                # prints 2
```

---

## 60-second tour

```c4p
# hello.c4p
print "hello"

let name = "world"
print ("hello, " + name)

let xs = [3, 1, 2]
print xs[-1]                    # 2 — negatives index from the end

fn fib(n) {
  if n < 2 { return n }
  return fib(n - 1) + fib(n - 2)
}
print fib(10)                   # 55

for i, v in xs { print (str(i) + ":" + str(v)) }

let m = {"a": 1}
m["b"] = 2
print keys(m)
```

```powershell
c4c hello.c4p
c4c check hello.c4p             # validate only, prints path: OK
c4c trace hello.c4p             # run + print every statement/call
```

---

## Commands

```
c4c <file.c4p> [args...] [-silent]      run a program
c4c run <file.c4p> [args...] [-silent]  same, explicit
c4c check <file.c4p> [-silent]          validate only (prints path: OK)
c4c trace <file.c4p> [args...]          run + print every statement/call
c4c fmt [--write] <file> [-silent]      format .c4p/.c4h/.c4asm
c4c --emit-c <file.c4p> [-o out.c] [--freestanding] [-silent]
                                        transpile to C99
c4c exec "<code>" [args...] [--ok "msg"] [-silent]
                                        run a one-liner; bare exprs echo
c4c new <name>                          scaffold name/name.c4proj + src/main.c4p
c4c build [project.c4proj] [--native]   validate all sources (or emit+gcc main)
c4c assoc [--remove]                    register .c4bht double-click (Windows)
c4c                                     REPL (persistent session)
```

`-silent` and `-trace` work in **any** position: `c4c run p.c4p -silent`,
`c4c -silent check p.c4p`, `c4c run p.c4p -trace`. `run -silent` prints only `ok` on
success. Errors, spans and exit codes are never silenced (a program needing a literal
`-silent` arg should plan flags accordingly).

Exit codes: `0` success, `1` error, or whatever `exit(n)` passes.

File types:

| ext      | meaning                                                         | runs with              |
| -------- | --------------------------------------------------------------- | ---------------------- |
| `.c4p`   | program                                                         | run/check/trace/fmt/emit |
| `.c4h`   | reusable header, `import "lib.c4h"` (once-guard, shared globals) | imported              |
| `.c4asm` | assembly: `#target sim` or `#target x86-64`                     | imported              |
| `.c4bht` | batch: `#c4bht title=".." pause/nopause` + code                 | run/check/fmt/emit    |
| `.c4proj`| project: name/main/sources/mode                                 | `c4c build`           |

---

## Language guide

Comments are `#` and `//`. A line may end with `;` (optional). No types, no semicolons,
no `main()`.

### Values and variables

```c4p
let x = 2 + 3 * 4    # 14 — precedence works, parens work
x = x + 1            # reassign (needs let first)

print ((2 + 3) * 4)  # 20
print nil            # nil: falsy, == only itself
print type(x)        # number/string/list/dict/nil/function/StructName
```

Numbers, strings, `+ - * / %` with precedence. `/` always divides (floats); `%` is float
fmod. `+` concatenates when either side is a string: `"n: " + 5`.

`and`/`or` evaluate **both** sides and return `1`/`0`. `..` ranges are inclusive on both
ends (`1..5` is 1,2,3,4,5; `5..1` counts down). Dict key order is hash order — never rely
on it. Variables must be `let`-declared before assignment (searched outward through
enclosing scopes); functions can be called before their definition line (prototypes are
collected). Assignments write to the nearest enclosing binding — inner functions see and
update outer variables (closures). `=` is assignment; `==` is comparison (a lone `a == b`
is not a statement).

### Strings, lists, dicts, structs

```c4p
# indexing works on strings and lists; negatives count from the end
print "hello"[1]     # e
let xs = [1, 2, 3]
print xs[-1]         # 3
xs[0] = 99           # write any depth: m["k"][0] = 1
let s = "hi"
s[1] = "o"           # strings are writable (copy-on-write)

# lists
xs = xs + [4, 5]     # concat
push(xs, 6)          # append, returns new length
print len(xs)

# dicts
let m = {"a": 1}
m["b"] = 2
print m["a"]
print keys(m)        # list of keys (hash order!)
print len(m)
del(m, "a")          # 1 if removed, else 0

# structs
struct Point { x, y }
let p = Point(3, 4)
print p.x
p.x = 10
print p              # Point{x: 10, y: 4}
```

### Flow control

```c4p
# comparisons: == != < > <= >= (+ and/or/not)
# truthy: everything except 0, "", [], {}, nil
if x > 3 {
  print "big"
} elif x == 3 {
  print "three"
} else {
  print "small"
}

let i = 0
while i < 3 {
  print i
  i = i + 1
}
while true {
  break              # break/continue work in while + for
}

for v in xs { print v }
for i, v in xs { print (str(i) + ":" + str(v)) }
for k in m { print k }
for k, v in m { print k }
for ch in "hey" { print ch }
for i in 1..5 { print i }

switch day {
  1, 7 { print "weekend" }  # comma-separated cases
  else { print "weekday" }
}
```

### Functions, function values, closures

```c4p
fn add(a, b) { return a + b }
print add(2, 3)      # recursion allowed (depth cap 1000)

# functions are values (callbacks) — interpreter mode
fn on_click(n) { return n * 2 }
let cb = on_click   # cb is a function value
print cb            # <fn on_click>
print cb(10)        # 20 — call through the value
fn apply(f, x) { return f(x) }
print apply(on_click, 10)   # 20
print call(cb, 5)           # 10 — call(f, ...) builtin
print type(cb)              # "function"
print fname(cb)             # "on_click"
let handlers = {"click": on_click}
print handlers["click"](3)  # 6
print (cb == on_click)      # 1 (same function)

# closures: nested functions capture outer variables by reference.
# each call gets its own private copy of the captured scope.
fn counter() {
  let n = 0
  fn inc() {
    n = n + 1
    return n
  }
  return inc
}
let a = counter()
print a()   # 1
print a()   # 2 (a remembers n; b gets its own)
```

### Errors

```c4p
try {
  risky()
} catch e {
  print ("caught: " + e)    # e is the message string
}
fail("boom")         # raise with message
```

Runtime errors print `file:line: message` plus a source span (`--> file:line` + the line).
Catchable with `try/catch` (`return`/`break`/`continue`/`exit` inside always propagate).
Common ones: `UnknownVariable`, `KeyMissing`, `IndexOutOfBounds`, `TypeError`,
`DivisionByZero`, `ArityMismatch`, `MathError`, `JsonError`, `LoopLimitExceeded` (>1M
loop/range iterations), `CallDepthExceeded` (function-call depth cap 1000 — enough for deep
recursion; the interpreter runs on a 64MB stack so 1000 levels are real frames, not a fake
limit).

---

## Builtins

Plain calls, always available:

```
len(x)               strings/lists/dicts -> number
push(xs, v)          append, returns new length
type(x)              "number"/"string"/"list"/"dict"/"nil"/StructName
str(x)               anything -> string
int(x)               string/number -> truncated number
input()/input(p)     stdin line (prompt optional)
args()               CLI words after the script path
exit(n)              terminate with code n (default 0)
```

Strings: `split(s, sep)` (empty sep splits chars), `join(list, sep)`,
`substr(s, start, count)` (negative start counts from end), `trim(s)`, `upper(s)`,
`lower(s)`, `replace(s, old, new)`, `contains(s, sub)` → 1/0, `ord("A")` → 65,
`chr(65)` → `"A"`. Functions: `call(f, a, b, ...)` (call a function value), `fname(f)`
(its name). `crc32(bytes_or_string)` → IEEE 802.3 CRC-32 (same value as Python's
`zlib.crc32`), handy for boot images and file checks.

Math: `abs/min/max/sqrt/floor/ceil/round/pow`, `sin/cos/tan/asin/acos/atan/log/log10/exp/deg/rad`,
`pi()`, `e()`. Domain errors (`sqrt(-1)`, `log(0)`) raise catchable errors.

Lists: `len/push`. Dicts: `len/keys/del`. Collections: `sort(list)` (new list, numbers or
strings, never mutates the original), `reverse(list_or_string)`, `sum(list)`,
`min_of(list)`, `max_of(list)`, `index_of(list_or_string, value)` (-1 if missing),
`count(list_or_string, value)`, `any(list)`, `all(list)`, `unique(list)`. `contains` also
works on lists.

Bits & bytes: `& | ^ ~ << >>` (64-bit ints, C-like precedence), `bits(v,hi,lo)`,
`setbits(v,hi,lo,f)`, `flag(v,n)`, `bytes(n)` (zeroed list, 16M cap), `peek(buf,addr)`,
`poke(buf,addr,v)` (strict 0-255, returns v), `pack(fmt,vals)` / `unpack(fmt,data)` /
`sizeof(fmt)` with `<` little (default) / `>` big and codes `B H I b h i` + `x` pad
(C-style wrapping), `u8/u16/u32/i8/i16/i32` converters.

---

## Modules

`import x` — always required first.

```c4p
import os
os.create("f.txt", "hi")   # -> 1
os.read("f.txt")           # whole file as string
os.append("f.txt", "!")    # creates if missing
os.exists("f.txt")         # 1/0
os.remove("f.txt")         # errors if missing
os.edit("f.txt", "hi", "yo")  # replace-all
os.readbytes("f.bin")      # -> list of 0..255
os.writebytes("f.bin", [72, 105])
os.cwd()                   # current dir string
os.env("PATH")             # "" if missing
os.listdir(".")            # list of names
os.mkdir("dir")            # parents too, ok if exists

# processes (Windows; script-only like gui)
os.exec("echo hi")         # -> {code, out, err, timeout} (blocking)
os.exec(["cmd", "/C", "echo hi"])  # argv form, no shell
os.exec("ping -n 9 127.0.0.1", 300)  # timeout_ms: kills + timeout=1
os.spawn("ping -n 30 127.0.0.1")     # -> handle (streaming)
os.pipe(h)                 # stdout chunk since last read ("" if none)
os.pipe_err(h)             # stderr chunk
os.poll(h)                 # exit code, or nil while running
os.kill(h)                 # 1 if stopped, 0 if already done
os.close(h)                # free the handle (nil return)
# out/err come back as UTF-8 (converted from the console code page)

import physics             # g/fall/range/height/dist/speed/energy
print physics.range(10, 45)

import json                # parse/stringify
let m = json.parse("{\"a\": 1}")
# true/false -> 1/0, null -> nil, duplicate keys: last wins

import time                # now/stamp/sleep/ms/epoch_ms/clock
print time.stamp()         # UTC YYYY-MM-DD HH:MM:SS
print time.ms()            # ms since the first time.ms() call
print time.clock()         # seconds since midnight

import hex                 # encode/decode/dump/word/parse
print hex.encode("hi")     # 6869
print hex.dump([72, 105])  # 48 69
print hex.word(255)        # 000000ff
print hex.parse("0xFF")    # 255

import heap                # first-fit allocator over bytes()
let h = heap.new(64)
let a = heap.malloc(h, 16) # addr or -1
heap.calloc(h, 8)          # scrubbed zeros
heap.realloc(h, a, 32)     # copy-preserving, old freed
heap.free(h, a)            # 1/0
heap.stats(h)              # {total,free,used,blocks}
heap.dump(h)               # sorted [[addr,size],...]

import cpu                 # 8-reg + RAM sim machine
let m = cpu.new(256)
cpu.step(m, "li", 0, 10)   # li/add/sub/and/or/xor/shl/shr/lw/sw/jmp/jz/halt/nop
cpu.step(m, "add", 0, 1)
cpu.reg(m, 0)              # read reg
cpu.setreg(m, 0, 5)
cpu.load(m, 16)            # u32 LE
cpu.store(m, 16, 99)
cpu.run(m, prog)           # run assembled program dict

import random              # deterministic xorshift PRNG
random.seed(42)            # same seed = same sequence (tests)
random.int(6)              # 0..5
random.int(1, 6)           # 1..6 inclusive
random.float()             # 0..1
random.float(10, 20)       # 10..20
random.pick(list_or_string)
random.shuffle(list)       # new list, original untouched
random.chance(0.25)        # 1 with 25% odds

import strings             # starts_with/ends_with/find/pad_left/pad_right/repeat/replace_all/lines
strings.starts_with("boot.s", "boot")   # 1
strings.pad_left("42", 5)               # "   42"
strings.repeat("ab", 3)                 # "ababab"
strings.lines("a\nb\r\nc")              # ["a", "b", "c"]

import http                # real HTTP(S), script-only like gui
let r = http.get("https://example.com")  # -> {code, body, headers}
http.post(url, body, headers)  # also put/patch/delete/head/options/request/download/redirects

import vga                 # 80x25 text cells; script needs vgatogui window
import vgatogui            # script-only VGA emulator window
let w = vgatogui.window("vga demo", 640, 400)
vga.clear(7)
vga.text(0, 0, "hi vga", 15)   # also put(r,c,ch,attr)/get/move/scroll/size
vga_put(2, 3, 66, 12)          # bare form too (this is what kernels use)
# kernels use bare vga_* builtins with --emit-c --freestanding (same calls,
# real 0xB8000; see templates/66_vga.c4p). No vgatogui needed on hardware.

import csv                 # parse/stringify tables (compiles to native too)
let t = csv.parse("a,b\n1,2")  # -> list of lists
print csv.stringify(t)     # quoting handled; sep arg optional (";"...)
# lenient: unterminated quotes read to end; empty text -> []

import socket              # TCP, script-only like http
let c = socket.connect("127.0.0.1", 80)  # -> handle
socket.send(c, "hi\n")     # -> bytes sent
socket.recv(c, 64)         # up to 64 bytes (blocks; frame it yourself)
socket.recv_line(c)        # one \n-line (chat/HTTP headers)
socket.close(c)
socket.listen(8080)        # -> server handle (127.0.0.1 default)
socket.accept(s)           # blocks until a client arrives -> handle
# DNS/connect/refused/reset failures are catchable with try/catch
```

---

## Assembly sidecars

`.c4asm` files pick a backend on the first line: `#target sim` or `#target x86-64`.
Labels (`main:` or `main: instr`), `.entry label`, `#`/`;` comments, decimal + `0x`
immediates.

```c4asm
#target sim
.entry main
main:
  li r0, 5
  li r1, 1
loop:
  sub r0, r1
  jz r0, done
  jmp loop
done:
  halt
```

```c4p
import cpu
import "prog.c4asm"        # binds {code, labels, entry} as `prog`
let m = cpu.new(64)
print cpu.run(m, prog)     # steps executed
print cpu.reg(m, 0)
```

`#target x86-64` files validate in script/check mode and compile via `--emit-c` into a
callable (`prog()`). Rules: no `ret` (the wrapper returns for you — early `ret` crashes
MinGW), no `main` label (link collision). Script mode refuses to run them with a clear
error.

---

## GUI apps

`import gui`, Windows only. Real windows, real callbacks. `gui` is **script-only** (the
compiler itself calls Win32), so GUI programs run with `c4c app.c4p` — never through
`--emit-c`. Everything is in logical units, so it looks right on 125%/150% displays.

```c4p
import gui
fn on_click(ev) {
  gui.set_text(w, out, "clicked! id=" + str(ev["id"]))
}
let w = gui.window("My app", 560, 420)     # -> window handle
gui.theme(w, "midnight")                  # dark | light | midnight
let out = gui.label(w, "ready", 16, 12)
let b = gui.button(w, "Press me", on_click)  # fnval callback
while gui.alive(w) {                      # event loop
  let ev = gui.wait(w)                    # blocks until an event
}
print "closed"
```

Widgets (skip `x, y, wid, hei` to auto-stack them vertically):
`gui.label`, `gui.button` (text, callback, …), `gui.checkbox`,
`gui.radio(w, group, text, ...)` (mutually exclusive per group,
`gui.radio_group(w, group, idx)` to set), `gui.slider`
(`min, max, value` or `x, y, w, h, min, max, value`),
`gui.progress` (value, or `x, y, w, h`), `gui.textbox`,
`gui.editbox(w, text, x, y, w, h)` (multiline code editor: Enter splits lines, Tab inserts
2 spaces, up/down/home/end/pgup/pgdn, wheel scrolls) + `gui.line_count`, `gui.get_line`,
`gui.goto_line`, `gui.list`, `gui.dropdown(w, text, ...)` (items via the `list_*` family),
`gui.picture(w, path, x, y, w, h)` (PNG/JPEG/BMP),
`gui.tabs(w, x, y, w, h)` + `gui.tab_add` / `gui.tab_select`.

Containers (children clip to the inside):
`gui.vbox/hbox/panel/groupbox(w, title, x, y, w, h, gap?)` + `gui.begin(w, box)` …
`gui.end()`. Widgets created between `begin/end` auto-flow inside (and auto-grow the box).
A `tabs` container is also a clip area: children added while it is active belong to that
page (`gui.begin(w, tabs)` + `gui.tab_select`).

Window: `window, alive, quit/close, title, size, theme, font, bgcolor, accent, show,
tick(ms), redraw, poll, wait, mouse, key(name), mods, msgbox, clip_set, clip_get, layout,
gap, post_close`, `open_file([w,] [title,] [filter])` / `save_file([w,] [title,]
[default,] [filter])` → path or `""` (native dialogs; filter like
`"C4Plus|*.c4p|All|*.*"`).

Widget state: `gui.get(w,id)` (checkbox/radio → 0/1, tabs → active page, combo → selection
or nil, else value), `gui.set(w,id,v)` (checkbox/radio set checked), `gui.get_text`,
`gui.set_text`, `gui.on(w,id,fn)` (attach/replace a callback), `gui.enable`,
`gui.show_control`, `gui.tint`, `gui.password(w,id,on)` (mask a textbox, 1/0),
`gui.focus(w,id)` (keyboard focus, 1/0), list ops
(`list_add/list_insert/list_remove/list_clear/list_get/list_set/list_len/list_sel/list_select`).

Images: `gui.image(w, path, x, y, w?, h?)` (draws, cached), `gui.image_size(path)` → `[w, h]`.

Drawing (immediate, under the widgets): `gui.fill`, `gui.outline`, `gui.round`, `gui.line`,
`gui.text`, plus `gui.circle`, `gui.disc` (filled), `gui.arc(w,cx,cy,r,start,sweep,color,width?)`,
`gui.polygon(w,[x,y,...],color)`, `gui.gradient(w,x,y,w,h,c1,c2,vertical?)`. Colors via
`gui.color(r,g,b)` / `gui.color("steelblue")` / `gui.color(a,r,g,b)` / `gui.fade(color,
alpha)` — anything with alpha < 255 blends into the back buffer.

Events (dicts): `type` = click, toggle, drag, change, key, close, resize, move, wheel,
tick — plus `id, x, y, w, h, key, wheel, ctrl, shift, alt`. A widget callback is called
automatically with the event dict. Callbacks fire only while the script pumps events
(`gui.wait` / `gui.poll`).

Shared state: closures capture outer variables by reference, so a counter, an app table, or
any outer `let` just works inside callbacks (`app["n"] = app["n"] + 1` also still works —
dicts are reference values and update in place).

Editor kit (on `editbox`): `gui.linenums(w,id,on)` (gutter), `gui.mark_add(w,id,line,col,len,color)` /
`gui.marks_clear(w,id)` (highlight spans, e.g. syntax colors), `gui.curline(w,id,on[,color])`
(caret-line bar).

Synthetic input (UI tests, demos): `gui.click(w,x,y)`, `gui.key_press(w,"enter")`,
`gui.type_text(w,"hi")`, `gui.wheel(w,x,y,delta)`, `gui.post_close(w)`.

---

## Tracer, formatter, batch files, projects

**Tracer** (`c4c trace` / `-trace`): run with `c4c trace app.c4p` (or add `-trace` to any
`run`) to see the program think: every statement prints as `line | source text`, nested
blocks indent two spaces per call depth, and calls print `-> call name` / `<- name = value`
with the return value:

```
   7 | let xs = [3, 1, 2]
  14 | print fib(6)
-> call fib
     5 | return fib(n - 1) + fib(n - 2)
<- fib = 8
```

Program output and trace lines interleave on stdout. `check` ignores tracing (it never runs
code).

**Formatter** (`c4c fmt`): 2-space brace indent, spaces around operators, trailing
whitespace trimmed, max one blank line, `#target` / `#c4bht` lines verbatim.
Whitespace-only: formatting never changes what code does (verified by re-running the whole
suite formatted).

**Batch files** (`.c4bht`):

```
#c4bht title="Hello" pause
print "hi"
```

`c4c assoc` registers double-click execution (HKCU only, reversible with
`c4c assoc --remove`). Default pauses at the end (even on errors, so the window doesn't
vanish); `nopause` / `-silent` skip it; `check` never pauses; `exit()` never pauses.
`title` shows in the pause prompt.

**Projects** (`c4c new` / `c4c build`):

```
c4c new myapp               # scaffolds myapp/myapp.c4proj + src/main.c4p
c4c build myapp/myapp.c4proj          # validate every source (script mode)
c4c build myapp/myapp.c4proj --native # also emit+gcc main into myapp.exe
```

The project file is plain text:

```
{
  "name": "myapp",
  "main": "src/main.c4p",
  "sources": ["src/*.c4p"],
  "mode": "script"
}
```

Build checks every `*.c4p` glob source plus the `main` entry; anything using script-only
features still "builds" (they run under c4c), while native-compatible files also
transpile. `--native` (or `"mode": "native"`) compiles `main` with gcc into `<name>.exe`.

**REPL:** bare `c4c`: persistent session, `c4p>` / `....` prompts, multi-line brace
blocks, bare expressions echo their value, `exit()` quits.

---

## Native compilation

```
c4c --emit-c prog.c4p -o prog.c
gcc -std=c99 -I rt -o prog prog.c rt/c4rt.c -lm
```

**Script-only features** (clean error in emit v1, use interpreter or native-mode for
these):

* the `gui` module (Windows GUI — run it as a script)
* `os.exec/spawn/pipe/poll/kill/close` (process spawn — script-only)
* closures capturing locals (top-level function values compile and call fine; only
  captured-variable capture stays script-side)
* `#target sim` needs the `cpu` module... no wait, `cpu` compiles. `#target x86-64` asm
  blocks still compile.

`and/or` evaluate both sides (same values as script mode). Floats may differ in the last
printed digit (same double, different printer). Dict key order is hash order in both modes
(never rely on it). `asm("...")` passes through to `__asm__ volatile` (no-op in script
mode).

---

## Freestanding kernels

```
c4c --emit-c kernel.c4p --freestanding -o kernel.c
```

Uses `rt/c4rt_fs.h` (no libc): bump allocator, debug output on port `0xE9`, `exit(n)` hits
the QEMU debug-exit port. Compiles the core subset: values, math (no pow/log/exp/trig),
strings, lists, dicts, structs, flow, functions (direct calls only), bits, bytes, pack. No
input/args/files/modules/try/function-values — clean errors. Entry point is `kmain`, not
`main`.

### Kernel recipe

Every kernel template follows the same shape. anx `52_timer` (PIT interrupts) end to end:

```powershell
c4c --emit-c 52_timer.c4p --freestanding -o timer.c
gcc -m32 -ffreestanding -nostdlib -c -o timer.o timer.c -I rt
gcc -m32 -ffreestanding -nostdlib -c -o fs.o rt/c4rt_fs.c
as --32 rt/irq.s -o irq.o
as --32 boot/boot.s -o boot.o
ld -m i386pe -T boot/linkflat.ld -o timer.pe timer.o fs.o irq.o
objcopy -O binary timer.pe timer.bin
ld -m i386pe -T boot/bootlink.ld -o boot.pe boot.o
objcopy -O binary -j .boot boot.pe boot.bin
cat boot.bin timer.bin > tdisk.img   # pad kernel area to 96K
qemu-system-i386 -drive format=raw,file=tdisk.img -display none `
  -debugcon file:t.log -device isa-debug-exit,iobase=0xf4,iosize=0x04
# Expect tick prints; qemu exit = (code<<1)|1.
```

The moving parts:

| file               | role                                                              |
| ------------------ | ----------------------------------------------------------------- |
| `boot/boot.s`      | stage-1 sector: loads 192 sectors to `0x10000`, enters pmode, calls `kmain` |
| `boot/bootlink.ld` | boot-sector link script                                           |
| `boot/linkflat.ld` | kernel link: `.text.kmain` first at `0x10000`, BSS at `0x200000`  |
| `boot/link.ld`     | alternate kernel link                                             |
| `rt/c4rt_fs.c/h`   | freestanding runtime: values, heap, IDT/GDT/TSS, paging, syscalls, scheduler |
| `rt/irq.s`         | IRQ0/IRQ1/syscall/fault/enter-user stubs                          |
| `rt/userblob.c`    | links embedded user ELFs into user-mode kernels                   |
| `user/`            | ring-3 programs (`hello.s`, `pong.s`) + `mkelf.py` ELF wrapper    |

Freestanding extras for kernel code (`--emit-c --freestanding` only — clean errors
elsewhere): `outb(port, val)`, `inb(port)`, `sti()`, `cli()`, `ticks()` (PIT-driven
counter), `key()` (PS/2 scancode driver: next char code, or -1 if empty),
`irq_addr()` / `irq1_addr()` (addresses of the IRQ stubs in `rt/irq.s`),
`idt_set(vec, off, sel, attr)`, `idt_load()`. `templates/52_timer.c4p` remaps the PIC,
programs the PIT to 100Hz, installs IRQ0 and counts ticks (link `rt/irq.s` into the
kernel). `templates/54_keyboard.c4p` adds IRQ1, reads typed lines via `key()` (unmask with
`outb(33, 252)`).

User-mode extras: `gdt_set/gdt_load`, `tss(esp0)`, `syscall_addr/fault_addr`,
`elf_load`, `user_base/user_len`, `user2_base`, `enter_user(entry, esp)`,
`task_create(entry, esp_top)`, `tasks()`, `idle()` — see `templates/58_usermode.c4p` and
`templates/59_sched.c4p` (link `rt/irq.s` + `rt/userblob.c`).

### User mode and multitasking

`58_usermode` is the hello-world of privilege separation: a full GDT
(null/kcode/kdata/ucode/udata/TSS), paging with user pages (code at `0x400000`, stack at
`0x800000`), a DPL3 `int 0x80` gate, fault gates 0–31 (crashes print `FAULT n` instead of
silently rebooting), an embedded ELF built from `user/hello.s` via `user/mkelf.py`, and a
jump to ring 3. Expect `user hello`, a ring-3 proof, and exit 99 through the syscall.

`59_sched` goes one further: two ring-3 tasks from the same ELF with stacks 256KB apart,
a 100Hz PIT slice, round-robin context switches in `c4_schedule`, and mailbox IPC
(send/recv syscalls). The ping-pong pair in `user/pong.s` (tid 1 sends 1..5 to tid 2, tid
2 prints each receipt) exercises preemption, blocking receive and exit.

Then storage and interaction: ATA PIO disk reads (`61_ata`, new `inw` builtin), a
read-only FAT12 filesystem built by `user/mkfat.py` (`62_fat` — BPB, root dir, 12-bit
cluster chains, multi-cluster files), a VGA text console at `0xB8000` with scroll and
hardware cursor (`63_vga`), an interactive shell with `ls`/`cat`/`help`/`ver`/`poweroff`
over keyboard line input (`64_shell`), and `run FILE` executing ELFs straight off disk
into ring-3 tasks (`65_exec` — `flat()` flattens a file list for the ELF loader).
Script-side networking and data: a TCP echo server + chat client (`67_socket` →
`68_chat` — `connect/listen/accept/send/recv/recv_line/close`, errors catchable)
and CSV tables (`csv.parse/stringify` with quoting + custom separators, native-compiled).

### Kernel meter

**80%** — everything above, plus: stage-1 loads 192 sectors to `0x10000`, per-task
kernel stacks with eager FPU switching, switch tracer and ESP validation, rendezvous
send + atomic receive, 1MB kernel pool. The remaining ~20% is, roughly: writable
filesystem, more drivers (serial disk DMA, sound, network), and a fuller shell.

---

## Repository layout

```
src/            c4c/c4pp implementation (Zig): main.zig, emit.zig, gui.zig, proc.zig
rt/             runtimes: c4rt.c/h (hosted), c4rt_fs.c/h (freestanding), irq.s, userblob.c
boot/           stage-1 boot sector + linker scripts
user/           ring-3 programs (hello.s, pong.s) + mkelf.py ELF wrapper
examples/       small programs per feature (also used as tests)
templates/      numbered walkthroughs 01_hello .. 68_chat (+ .c4asm sidecars)
build.zig       build definition (version lives here)
build.zig.zon   package manifest (version mirrored here)
DOCS.md         full language + kernel reference
zip/            local release snapshots (kept out of git; use GitHub releases)
```

`templates/` is the guided tour: start at `01_hello.c4p` for the language, `43_gdt` →
`44_kmain` → `52_timer` → `54_keyboard` → `55_paging` → `56_syscall` → `58_usermode` →
`59_sched` → `61_ata` → `62_fat` → `63_vga` → `64_shell` → `65_exec` → `66_vga` for the
kernel path, then `67_socket` → `68_chat` for TCP. Every kernel template header documents its exact build recipe.

---

## Versioning

The version lives in two places — `build.zig` (`const version = "0.4.0"`) and
`build.zig.zon` (`.version = "0.4.0"`) — and each release is snapshotted as
`zip/c4plus-<version>-src.zip` (older snapshots are kept). `zip/` is local history and
stays out of git; public releases go through GitHub releases.

---

## Roadmap

- **0.3.7:** the `http` module (get/post/put/patch/delete/head/options/request/
  download/redirects, response headers, catchable errors) + 10 new examples.
- **0.3.8 (this):** working `59_sched` switch (the `add $4` off-by-one is gone, per-task
  kernel stacks, rendezvous send, five `got N` lines + `all tasks done`), REPL import
  persistence for every module, GUI `password` + `focus`.
- **0.3.9:** stabilization — full interp-vs-native suite green (94 files),
  task-exit mailbox hygiene, no new features. Closes the 0.3.x line.
- **0.4.0:** the big one — ATA PIO (`inw`), FAT12 (`user/mkfat.py`),
  VGA console, interactive shell, `run FILE` disk exec into ring-3 tasks,
  plus the display story (`vga_*` kernel builtins, `import vga` +
  `import vgatogui` emulator). Kernel meter 65% → 80%.
- **0.4.1 (this):** `socket` (TCP client+server, `connect/listen/accept/send/
  recv/recv_line/close`, catchable errors, templates `67_socket`+`68_chat`) and
  `csv` (`parse/stringify`, quoted fields, custom separators, native-compiled).
- After that: writable filesystem, more drivers, fuller shell.

---

## License

MPL 2.0 (Mozilla Public License 2.0) — see [LICENSE](LICENSE).

Why MPL and not GPL: copyleft in MPL 2.0 applies per file, not to the whole combined
work. Programs *you* write in C4Plus are yours — combine them with the toolchain, sell
them, keep them proprietary. Only changes to C4Plus's own source files themselves stay
under the MPL.
