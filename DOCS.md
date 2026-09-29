# C4Plus — Complete Docs (v0.3.9)

C4Plus (`.c4p`) is a small scripting language with headers (`.c4h`),
assembly sidecars (`.c4asm`), batch files (`.c4bht`), projects
(`.c4proj`), an interpreter, a C transpiler, a REPL, a step tracer,
a formatter, and a Windows GUI module — all in one `c4c` binary
(`c4pp` is the same engine under the extended-tool name).

## 1. Build & install

Needs Zig 0.16.0. For native output (`--emit-c`), gcc.

```
zig build                       # -> zig-out/bin/c4c.exe + c4pp.exe
```

Put `zig-out/bin` on PATH, or copy the two exes somewhere on PATH
(e.g. `~/.c4plus/bin`). Check with `c4c exec "1 + 1"` (prints `2`).

## 2. Commands

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

`-silent` and `-trace` work in **any** position: `c4c run p.c4p
-silent`, `c4c -silent check p.c4p`, `c4c run p.c4p -trace`.
`run -silent` prints only `ok` on success. Errors, spans and exit
codes are never silenced (a program needing a literal `-silent` arg
can use `--silent`... actually it can't — `-silent` is always
consumed; plan flags accordingly).

Exit codes: `0` success, `1` error, or whatever `exit(n)` passes.

## 3. Files

| ext | meaning | runs with |
| --- | ------- | --------- |
| `.c4p` | program | run/check/trace/fmt/emit |
| `.c4h` | reusable header, `import "lib.c4h"` (once-guard, shared globals) | imported |
| `.c4asm` | assembly: `#target sim` or `#target x86-64` | imported |
| `.c4bht` | batch: `#c4bht title=".." pause/nopause` + code | run/check/fmt/emit |
| `.c4proj` | project: name/main/sources/mode (see §10) | `c4c build` |

## 4. Language tour

```c4p
print ("hello")      # all three print forms work
print "hello"
pt "hello"

let x = 2 + 3 * 4    # no types, no semicolons, no main()
x = x + 1            # reassign (needs let first)

# numbers, strings, + - * / % with precedence, parens
print ((2 + 3) * 4)  # 20

# indexing: strings, lists (negatives ok)
print "hello"[1]     # e
let xs = [1, 2, 3]
print xs[-1]         # 3
xs[0] = 99           # write any depth: m["k"][0] = 1
s = "hi"
s[1] = "o"           # strings are writable (copy-on-write)

# lists
xs = xs + [4, 5]     # concat
push(xs, 6)          # append, returns new length
print len(xs)        # len: strings/lists/dicts

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

# comparisons: == != < > <= >=  (+ and/or/not)
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
for i in 1..5 { print i }   # ranges, inclusive; 5..1 counts down

fn add(a, b) { return a + b }
print add(2, 3)      # recursion allowed (depth cap 1000)

# functions are values (callbacks) — interpreter mode
fn on_click(n) { return n * 2 }
let cb = on_click  # cb is a function value
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

switch day {
  1, 7 { print "weekend" }  # comma-separated cases
  else { print "weekday" }
}

try {
  risky()
} catch e {
  print ("caught: " + e)    # e is the message string
}
fail("boom")         # raise with message

print nil            # nil: falsy, == only itself
print type(x)        # number/string/list/dict/nil/function/StructName
```

Comments: `#` and `//`. A line may end with `;` (optional).

### 4.1 Gotchas for C programmers

* `+` concatenates when either side is a string: `"n: " + 5`.
* `/` always divides (floats); `%` is float fmod.
* `and`/`or` evaluate **both** sides, return `1`/`0`.
* `..` ranges are inclusive on both ends.
* Dict key order is hash order — never rely on it.
* Variables must be `let`-declared before assign (searched
  outward through enclosing scopes); functions can be called
  before their definition line (prototypes are collected).
  Assignments write to the nearest enclosing binding — inner
  functions see and update outer variables (closures).
* `=` is assignment; `==` is comparison (a lone `a == b` is not
  a statement).

## 5. Builtins (plain calls)

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
`substr(s, start, count)` (negative start counts from end),
`trim(s)`, `upper(s)`, `lower(s)`, `replace(s, old, new)`,
`contains(s, sub)` → 1/0, `ord("A")` → 65, `chr(65)` → "A".
Functions: `call(f, a, b, ...)` (call a function value),
`fname(f)` (its name). `type(f)` is `"function"`.
`crc32(bytes_or_string)` → IEEE 802.3 CRC-32 (same value as
Python's `zlib.crc32`), handy for boot images and file checks.

Math: `abs/min/max/sqrt/floor/ceil/round/pow`,
`sin/cos/tan/asin/acos/atan/log/log10/exp/deg/rad`, `pi()`, `e()`.
Domain errors (`sqrt(-1)`, `log(0)`) raise catchable errors.

Lists: `len/push`. Dicts: `len/keys/del`.
Collections: `sort(list)` (new list, numbers or strings, never
mutates the original), `reverse(list_or_string)`, `sum(list)`,
`min_of(list)`, `max_of(list)`, `index_of(list_or_string, value)`
(-1 if missing), `count(list_or_string, value)`, `any(list)`,
`all(list)`, `unique(list)`. `contains` also works on lists.

Bits & bytes: `& | ^ ~ << >>` (64-bit ints, C-like precedence),
`bits(v,hi,lo)`, `setbits(v,hi,lo,f)`, `flag(v,n)`,
`bytes(n)` (zeroed list, 16M cap), `peek(buf,addr)`,
`poke(buf,addr,v)` (strict 0-255, returns v),
`pack(fmt,vals)` / `unpack(fmt,data)` / `sizeof(fmt)` with
`<` little (default) / `>` big and codes `B H I b h i` + `x` pad
(C-style wrapping), `u8/u16/u32/i8/i16/i32` converters.

## 6. Modules (`import x` — always required first)

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
print r["code"]            # status, e.g. 200 (404 is data, not an error)
print r["headers"]["content-type"]  # lowercase names, last wins
let p = http.post(url, "a=1", {"Content-Type": "application/x-www-form-urlencoded"})
http.put(url, body)        # also patch/delete(url[, body[, headers]])
http.head(url)             # -> {code, headers} (no body)
http.options(url)          # full response like get
http.request("get", url[, body[, headers]])  # generic (any case)
http.download(url, "f.zip")  # -> {code, bytes, path} (streams to disk)
http.redirects()           # current max (default 3)
http.redirects(0)          # 0 = return 3xx as-is with location header
# bodies cap at 8MB; GET/HEAD/DELETE/OPTIONS with a body is a catchable
# error; DNS/connect/TLS failures are catchable with try/catch
```

## 7. Assembly side by side (`.c4asm`)

First line picks the backend: `#target sim` or `#target x86-64`.
Labels (`main:` or `main: instr`), `.entry label`, `#`/`;` comments,
decimal + `0x` immediates.

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

`#target x86-64` files validate in script/check mode and compile via
`--emit-c` into a callable (`prog()`). Rules: no `ret` (the wrapper
returns for you — early `ret` crashes MinGW), no `main` label (link
collision). Script mode refuses to run them with a clear error.

## 8. GUI apps (`import gui`, Windows)

Real windows, real callbacks. `gui` is **script-only** (the compiler
itself calls Win32), so GUI programs run with `c4c app.c4p` — never
through `--emit-c`. Everything is in logical units, so it looks right
on 125%/150% displays.

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
`gui.editbox(w, text, x, y, w, h)` (multiline code editor: Enter
splits lines, Tab inserts 2 spaces, up/down/home/end/pgup/pgdn,
wheel scrolls) + `gui.line_count`, `gui.get_line`,
`gui.goto_line`,
`gui.list`, `gui.dropdown(w, text, ...)` (items via the `list_*`
family), `gui.picture(w, path, x, y, w, h)` (PNG/JPEG/BMP),
`gui.tabs(w, x, y, w, h)` + `gui.tab_add` / `gui.tab_select`.

Containers (children clip to the inside):
`gui.vbox/hbox/panel/groupbox(w, title, x, y, w, h, gap?)` +
`gui.begin(w, box)` … `gui.end()`. Widgets created between
`begin/end` auto-flow inside (and auto-grow the box). A `tabs`
container is also a clip area: children added while it is active
belong to that page (`gui.begin(w, tabs)` + `gui.tab_select`).

Window: `window, alive, quit/close, title, size, theme, font,
bgcolor, accent, show, tick(ms), redraw, poll, wait, mouse, key(name),
mods, msgbox, clip_set, clip_get, layout, gap, post_close`,
`open_file([w,] [title,] [filter])` / `save_file([w,] [title,]
[default,] [filter])` → path or `""` (native dialogs; filter like
`"C4Plus|*.c4p|All|*.*"`).

Widget state: `gui.get(w,id)` (checkbox/radio → 0/1, tabs →
active page, combo → selection or nil, else value), `gui.set(w,id,v)`
(checkbox/radio set checked), `gui.get_text`,
`gui.set_text`, `gui.on(w,id,fn)` (attach/replace a callback),
`gui.enable`, `gui.show_control`, `gui.tint`, `gui.password(w,id,on)` (mask a
textbox with `*`, real text kept for `get_text`, 1/0 if applied),
`gui.focus(w,id)` (move keyboard focus, 1/0), list ops
(`list_add/list_insert/list_remove/list_clear/list_get/list_set/
list_len/list_sel/list_select`).

Images: `gui.image(w, path, x, y, w?, h?)` (draws, cached),
`gui.image_size(path)` → `[w, h]`.

Drawing (immediate, under the widgets): `gui.fill`, `gui.outline`,
`gui.round`, `gui.line`, `gui.text`, plus `gui.circle`,
`gui.disc` (filled), `gui.arc(w,cx,cy,r,start,sweep,color,width?)`,
`gui.polygon(w,[x,y,...],color)`, `gui.gradient(w,x,y,w,h,c1,c2,
vertical?)`. Colors via `gui.color(r,g,b)` / `gui.color("steelblue")` /
`gui.color(a,r,g,b)` / `gui.fade(color, alpha)` — anything with
alpha < 255 blends into the back buffer.

Events (dicts): `type` = click, toggle, drag, change, key, close,
resize, move, wheel, tick — plus `id, x, y, w, h, key, wheel, ctrl,
shift, alt`. A widget callback is called automatically with the event
dict. Callbacks fire only while the script pumps events
(`gui.wait` / `gui.poll`).

Shared state: closures capture outer variables by reference, so
a counter, an app table, or any outer `let` just works inside
callbacks (`app["n"] = app["n"] + 1` also still works — dicts are
reference values and update in place).

Editor kit (on `editbox`): `gui.linenums(w,id,on)` (gutter),
`gui.mark_add(w,id,line,col,len,color)` /
`gui.marks_clear(w,id)` (highlight spans, e.g. syntax colors),
`gui.curline(w,id,on[,color])` (caret-line bar).

Synthetic input (UI tests, demos): `gui.click(w,x,y)`,
`gui.key_press(w,"enter")`, `gui.type_text(w,"hi")`,
`gui.wheel(w,x,y,delta)`, `gui.post_close(w)`.

## 9. Tracer (`c4c trace` / `-trace`)

Run with `c4c trace app.c4p` (or add `-trace` to any `run`) to see
the program think: every statement prints as `line | source text`,
nested blocks indent two spaces per call depth, and calls print
`-> call name` / `<- name = value` with the return value:

```
   7 | let xs = [3, 1, 2]
  14 | print fib(6)
-> call fib
     5 | return fib(n - 1) + fib(n - 2)
<- fib = 8
```

Program output and trace lines interleave on stdout. `check` ignores
tracing (it never runs code).

## 10. Projects (`c4c new` / `c4c build`)

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

Build checks every `*.c4p` glob source plus the `main` entry; anything
using script-only features still "builds" (they run under c4c), while
native-compatible files also transpile. `--native` (or `"mode":
"native"`) compiles `main` with gcc into `<name>.exe`.

## 11. Native compilation (`--emit-c`)

```
c4c --emit-c prog.c4p -o prog.c
gcc -std=c99 -I rt -o prog prog.c rt/c4rt.c -lm
```

**Script-only features** (clean error in emit v1, use interpreter
or native-mode for these):

* the `gui` module (Windows GUI — run it as a script)
* `os.exec/spawn/pipe/poll/kill/close` (process spawn — script-only)
* `http` (network — script-only)
* closures capturing locals (top-level function values compile and
  call fine; only captured-variable capture stays script-side)
* `#target sim` needs the `cpu` module... no wait, `cpu` compiles.
  `#target x86-64` asm blocks still compile.

`and/or` evaluate both sides (same values as script mode). Floats
may differ in the last printed digit (same double, different
printer). Dict key order is hash order in both modes (never rely
on it). `asm("...")` passes through to `__asm__ volatile`
(no-op in script mode).

## 12. Freestanding / kernels (`--freestanding`)

```
c4c --emit-c kernel.c4p --freestanding -o kernel.c
```

Uses `rt/c4rt_fs.h` (no libc): bump allocator, debug output on port
`0xE9`, `exit(n)` hits the QEMU debug-exit port. Compiles the core
subset: values, math (no pow/log/exp/trig), strings, lists, dicts,
structs, flow, functions (direct calls only), bits, bytes, pack.
No input/args/files/modules/try/function-values — clean errors.
Entry point is `kmain`, not `main`.

`boot/` has a stage-1 sector (`boot.s`), linker scripts and a
QEMU-tested recipe — see `templates/44_kmain.c4p`. Kernel meter:
65% — stage-1 loads 128 sectors to 0x10000, enters pmode, runs
`kmain`, exits via the debug port (QEMU exit `(code<<1)|1`); PIT
timer IRQ at 100Hz (`52_timer`); PS/2 keyboard driver with line
input (`54_keyboard`); paging with a 4MB identity map + kernel
heap with free-list reuse (`55_paging`); `int 0x80` syscalls
write/exit/ticks (`56_syscall`); GDT/IDT descriptors via
pack/unpack (`43_gdt`); ring-3 user mode via TSS + full GDT, ELF
loader + `enter_user`, user pages (4–12MB), DPL3 syscall gate and
fault gates 0–31 (`58_usermode` — prints `hello from ring3`);
preemptive round-robin scheduler with mailbox IPC over the PIT
(`59_sched` — two tasks ping-pong 1..5 through rendezvous
send/blocking recv, five `got N` lines, `all tasks done`, clean
exit; per-task kernel stacks, switch tracer, ESP validation).

Freestanding extras for kernel code (`--emit-c --freestanding`
only — clean errors elsewhere): `outb(port, val)`, `inb(port)`, `inw(port)` (16-bit),
`sti()`, `cli()`, `ticks()` (PIT-driven counter, see below),
`key()` (PS/2 scancode driver: next char code, or -1 if empty),
`irq_addr()` / `irq1_addr()` (addresses of the IRQ stubs in
`rt/irq.s`), `idt_set(vec, off, sel, attr)`, `idt_load()`.
`templates/52_timer.c4p` remaps the PIC, programs the PIT to 100Hz,
installs IRQ0 and counts ticks (link `rt/irq.s` into the kernel).
`templates/54_keyboard.c4p` adds IRQ1, reads typed lines via `key()`
(unmask with `outb(33, 252)`). User-mode extras: `gdt_set/gdt_load`,
`tss(esp0)`, `syscall_addr/fault_addr`, `elf_load`, `user_base/user_len`,
`user2_base`, `enter_user(entry, esp)`, `task_create(entry, esp_top)`,
`tasks()`, `idle()` — see `templates/58_usermode.c4p` and
`templates/59_sched.c4p` (link `rt/irq.s` + `rt/userblob.c`).

## 13. REPL

Bare `c4c`: persistent session, `c4p>` / `....` prompts, multi-line
brace blocks, bare expressions echo their value, `exit()` quits.

## 14. Batch files (`.c4bht`)

```
#c4bht title="Hello" pause
print "hi"
```

`c4c assoc` registers double-click execution (HKCU only, reversible
with `c4c assoc --remove`). Default pauses at the end (even on
errors, so the window doesn't vanish); `nopause` / `-silent` skip
it; `check` never pauses; `exit()` never pauses. `title` shows in
the pause prompt.

## 15. Errors

Runtime errors print `file:line: message` plus a source span
(`--> file:line` + the line). Catchable with `try/catch`
(`return`/`break`/`continue`/`exit` inside always propagate).
Common ones: `UnknownVariable`, `KeyMissing`, `IndexOutOfBounds`,
`TypeError`, `DivisionByZero`, `ArityMismatch`, `MathError`,
`JsonError`, `LoopLimitExceeded` (>1M loop/range iterations),
`CallDepthExceeded` (function-call depth cap 1000 — enough for
deep recursion; the interpreter runs on a 64MB stack so 1000
levels are real frames, not a fake limit).

## 16. `c4c fmt` style

2-space brace indent, spaces around operators, trailing whitespace
trimmed, max one blank line, `#target` / `#c4bht` lines verbatim.
Whitespace-only: formatting never changes what code does (verified
by re-running the whole suite formatted).
