/* Freestanding C4Plus runtime: no libc headers at all. */
#include "c4rt_fs.h"

/* MinGW stack probe: our kernel stack (0x90000 down) has ample room
 * and no guard pages, so probing is a no-op. Needed because we link
 * -nostdlib (no libgcc) and gcc emits probes for large frames. */
void __chkstk_ms(void) {
}
void __chkstk(void) {
}

static unsigned char c4_pool[256 * 1024];
static c4_size_t c4_pool_used = 0;

static void *xmalloc(c4_size_t n) {
    if (n == 0)
        n = 1;
    n = (n + 7) & ~(c4_size_t)7;
    if (c4_pool_used + n > sizeof c4_pool)
        c4_halt();
    void *p = c4_pool + c4_pool_used;
    c4_pool_used += n;
    return p;
}

static c4_size_t c4_strlen(const char *s) {
    c4_size_t n = 0;
    while (s[n])
        n++;
    return n;
}
static int c4_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}
static void c4_memcpy(char *d, const char *s, c4_size_t n) {
    for (c4_size_t i = 0; i < n; i++)
        d[i] = s[i];
}
static void c4_memset(char *d, int c, c4_size_t n) {
    for (c4_size_t i = 0; i < n; i++)
        d[i] = (char)c;
}
static double c4_fabs(double x) {
    return x < 0 ? -x : x;
}
static double c4_ifloor(double x) {
    long long i = (long long)x;
    if ((double)i > x)
        i--;
    return (double)i;
}
static double c4_trunc(double x) {
    long long i = (long long)x;
    if (x < 0 && (double)i != x)
        i++;
    return (double)i;
}
static int c4_starts(const char *hay, const char *at, const char *nd, c4_size_t nl);
static double c4_tonum(C4Val v);

static void c4_outb_raw(unsigned short port, unsigned char v) {
    __asm__ volatile("outb %0, %1" ::"a"(v), "Nd"(port));
}

__attribute__((weak)) void c4_write(const char *s, unsigned n) {
    for (unsigned i = 0; i < n; i++)
        c4_outb_raw(0xE9, (unsigned char)s[i]);
}
void c4_halt(void) {
    for (;;) {
        __asm__ volatile("hlt");
    }
}
void c4_err(const char *name) {
    c4_write("error: ", 7);
    c4_write(name, (unsigned)c4_strlen(name));
    c4_write("\n", 1);
    c4_halt();
}
void c4_fail(const char *msg) {
    c4_write("fail: ", 6);
    if (msg)
        c4_write(msg, (unsigned)c4_strlen(msg));
    c4_write("\n", 1);
    c4_halt();
}
void c4_exit(C4Val code) {
    unsigned char c = 0;
    if (code.t == C4_NUM && code.num >= 0 && code.num <= 255)
        c = (unsigned char)code.num;
    c4_outb_raw(0xF4, c);
    c4_halt();
}

static volatile unsigned long c4_tick_count = 0;
void c4_irq0(void) {
    c4_tick_count++;
}
/* ---- 0.3.8: preemptive scheduler (round-robin, mailbox IPC) ----
 * Each task (and the kernel idle loop) owns a private kernel stack so a
 * timer/syscall frame from one task can never clobber another task's saved
 * frame. c4_schedule reloads TSS.esp0 on every switch: esp0 always
 * describes the currently-running task, so the next privilege transition
 * lands on the right stack. Layout (all supervisor pages below 4MB):
 *   0x90000  kernel/idle stack top (16KB down to 0x8C000)
 *   0x8C000  task 1 stack top (8KB)
 *   0x8A000  task 2 stack top (8KB)
 *   0x88000  task 3 stack top (8KB)
 * Page tables end at 0x84000, so 0x84000..0x86000 stays a guard gap. */
#define MAX_TASKS 4
#define TS_EMPTY 0
#define TS_READY 1
#define TS_RUNNING 2
typedef struct {
    int state;
    unsigned esp;
    int has_msg;
    long msg;
} TCB;
static TCB tcbs[MAX_TASKS];
static int cur_task = 0;
static int last_task = 0;
static int tasks_inited = 0;
static const unsigned kstack_tops[MAX_TASKS] = {0x90000, 0x8C000, 0x8A000, 0x88000};
static void tss_set_esp0(unsigned top);

static void sched_init(void) {
    if (tasks_inited)
        return;
    tasks_inited = 1;
    for (int i = 0; i < MAX_TASKS; i++) {
        tcbs[i].state = TS_EMPTY;
        tcbs[i].esp = 0;
        tcbs[i].has_msg = 0;
        tcbs[i].msg = 0;
    }
    tcbs[0].state = TS_RUNNING;
    cur_task = 0;
    last_task = 0;
}

static int sched_log_n = 0;

static void sched_hex(unsigned v) {
    for (int s = 7; s >= 0; s--) {
        unsigned d = (v >> (s * 4)) & 15;
        char c = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        c4_write(&c, 1);
    }
}

static int sched_valid_esp(unsigned ne) {
    if ((ne & 3) != 0)
        return 0;
    if (ne >= 0x86000UL && ne < 0x90000UL)
        return 1;
    if (ne >= 0x700000UL && ne < 0x800000UL)
        return 1;
    return 0;
}

static void sched_states(char *out) {
    for (int q = 0; q < MAX_TASKS; q++)
        out[q] = (char)('0' + tcbs[q].state);
}

unsigned c4_schedule(unsigned esp) {
    sched_init();
    c4_tick_count++;
    if (sched_log_n < 40) {
        sched_log_n++;
        c4_write("sw", 2);
        char c = (char)('0' + cur_task);
        c4_write(&c, 1);
        c4_write(":", 1);
        sched_hex(esp);
        c4_write("->L", 3);
        c = (char)('0' + last_task);
        c4_write(&c, 1);
        c4_write(" s0=", 4);
        char st[4];
        sched_states(st);
        c4_write(st, 4);
        c4_write(" ", 1);
    }
    tcbs[cur_task].esp = esp;
    if (tcbs[cur_task].state == TS_RUNNING)
        tcbs[cur_task].state = TS_READY;
    for (int k = 1; k < MAX_TASKS; k++) {
        int i = (last_task + k) % MAX_TASKS;
        if (i == 0)
            continue;
        if (tcbs[i].state == TS_READY) {
            tcbs[i].state = TS_RUNNING;
            last_task = i;
            cur_task = i;
            if (sched_log_n <= 24) {
                char c = (char)('0' + i);
                c4_write(&c, 1);
                c4_write(":", 1);
                sched_hex(tcbs[i].esp);
                c4_write(" T", 2);
                sched_hex(kstack_tops[i]);
                c4_write(" s1=", 4);
                char st[4];
                sched_states(st);
                c4_write(st, 4);
                c4_write("\n", 1);
            }
            {
                unsigned ne = tcbs[i].esp;
                if (!sched_valid_esp(ne)) {
                    c4_write("BADESP t=", 9);
                    char b[4];
                    b[0] = (char)('0' + i);
                    b[1] = ' ';
                    c4_write(b, 2);
                    sched_hex(ne);
                    c4_write("\n", 1);
                    c4_halt();
                }
            }
            tss_set_esp0(kstack_tops[i]);
            return tcbs[i].esp;
        }
    }
    if (tcbs[cur_task].state == TS_READY) {
        tcbs[cur_task].state = TS_RUNNING;
        last_task = cur_task;
        if (sched_log_n <= 24) {
            char c = (char)('0' + cur_task);
            c4_write(&c, 1);
            c4_write(":", 1);
            sched_hex(tcbs[cur_task].esp);
            c4_write(" T", 2);
            sched_hex(kstack_tops[cur_task]);
            c4_write(" s1=", 4);
            char st[4];
            sched_states(st);
            c4_write(st, 4);
            c4_write("\n", 1);
        }
        tss_set_esp0(kstack_tops[cur_task]);
        return tcbs[cur_task].esp;
    }
    if (sched_log_n <= 24) {
        c4_write("=0:IDLE\n", 8);
    }
    tcbs[0].state = TS_RUNNING;
    cur_task = 0;
    tss_set_esp0(kstack_tops[0]);
    return tcbs[0].esp;
}

C4Val c4_task_create(C4Val entry, C4Val esp_top) {
    sched_init();
    __asm__ volatile("cli");
    int id = -1;
    for (int i = 1; i < MAX_TASKS; i++) {
        if (tcbs[i].state == TS_EMPTY) {
            id = i;
            break;
        }
    }
    if (id < 0) {
        __asm__ volatile("sti");
        return c4_num(-1);
    }
    unsigned top = (unsigned)c4_tonum(esp_top);
    unsigned base = top - 64;
    unsigned *f = (unsigned *)base;
    /* f[0] is padding: the scheduler saves the frame base ([es]) and the
     * irq0 stub restores straight from it (no skip), so E = base + 4. */
    f[0] = 0;
    f[1] = 0x23;
    f[2] = 0x23;
    f[3] = 0;
    f[4] = 0;
    f[5] = 0;
    f[6] = 0;
    f[7] = 0;
    f[8] = 0;
    f[9] = 0;
    f[10] = 0;
    f[11] = (unsigned)c4_tonum(entry);
    f[12] = 0x1B;
    f[13] = 0x202;
    f[14] = top - 64;
    f[15] = 0x23;
    tcbs[id].esp = base + 4;
    tcbs[id].state = TS_READY;
    tcbs[id].has_msg = 0;
    __asm__ volatile("sti");
    return c4_num((double)id);
}

C4Val c4_tasks(void) {
    sched_init();
    int n = 0;
    for (int i = 1; i < MAX_TASKS; i++) {
        if (tcbs[i].state != TS_EMPTY)
            n++;
    }
    return c4_num((double)n);
}

C4Val c4_idle(void) {
    __asm__ volatile("sti");
    __asm__ volatile("hlt");
    return c4_nil();
}

static int task_send(int tid, long msg) {
    if (tid < 1 || tid >= MAX_TASKS)
        return -1;
    if (tcbs[tid].state == TS_EMPTY)
        return -1;
    /* rendezvous: wait until the receiver took the previous message so
     * rapid sends never overwrite (single-slot mailbox, no loss). */
    __asm__ volatile("sti");
    while (tcbs[tid].has_msg && tcbs[tid].state != TS_EMPTY)
        __asm__ volatile("hlt");
    __asm__ volatile("cli");
    if (tcbs[tid].state == TS_EMPTY) {
        __asm__ volatile("sti");
        return -1;
    }
    tcbs[tid].msg = msg;
    tcbs[tid].has_msg = 1;
    __asm__ volatile("sti");
    return 0;
}

void c4_syscall_dispatch(unsigned *regs) {
    unsigned n = regs[9];
    if (n == 1) {
        const char *s = (const char *)regs[6];
        unsigned len = regs[8];
        c4_write(s, len);
        regs[9] = 0;
    } else if (n == 2) {
        if (cur_task != 0) {
            tcbs[cur_task].state = TS_EMPTY;
            __asm__ volatile("sti");
            for (;;)
                __asm__ volatile("hlt");
        }
        unsigned char c = (unsigned char)(regs[6] & 0xFF);
        c4_outb_raw(0xF4, c);
        c4_halt();
    } else if (n == 3) {
        regs[9] = (unsigned)c4_tick_count;
    } else if (n == 5) {
        int tid = (int)regs[6];
        long msg = (long)regs[8];
        int r = task_send(tid, msg);
        regs[9] = (unsigned)r;
    } else if (n == 6) {
        __asm__ volatile("cli");
        while (!tcbs[cur_task].has_msg) {
            __asm__ volatile("sti");
            __asm__ volatile("hlt");
            __asm__ volatile("cli");
        }
        regs[9] = (unsigned)tcbs[cur_task].msg;
        tcbs[cur_task].has_msg = 0;
        __asm__ volatile("sti");
    } else if (n == 7) {
        regs[9] = (unsigned)cur_task;
    } else {
        regs[9] = 0xFFFFFFFFu;
    }
}

static volatile unsigned char kbd_head = 0;
static volatile unsigned char kbd_tail = 0;
static volatile unsigned char kbd_buf[256];
static volatile unsigned char kbd_shift = 0;
static volatile unsigned char kbd_e0 = 0;

static const char kbd_map[128] = {
    0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8,
    '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n',
    0, 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
    0, '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0,
    '*', 0, ' ', 0,
};
static const char kbd_shift_map[128] = {
    0, 27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8,
    '\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n',
    0, 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~',
    0, '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0,
    '*', 0, ' ', 0,
};

static unsigned char c4_inb_raw(unsigned short port) {
    unsigned char v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
    return v;
}

void c4_irq1(void) {
    unsigned char sc = c4_inb_raw(0x60);
    if (sc == 0xE0) {
        kbd_e0 = 1;
        return;
    }
    if (kbd_e0) {
        kbd_e0 = 0;
        return;
    }
    if (sc == 0x2A || sc == 0x36) {
        kbd_shift = 1;
        return;
    }
    if (sc == 0xAA || sc == 0xB6) {
        kbd_shift = 0;
        return;
    }
    if (sc & 0x80)
        return;
    if (sc >= 128)
        return;
    char ch = kbd_shift ? kbd_shift_map[sc] : kbd_map[sc];
    if (ch == 0)
        return;
    unsigned char next = (unsigned char)(kbd_head + 1);
    if (next == kbd_tail)
        return;
    kbd_buf[kbd_head] = (unsigned char)ch;
    kbd_head = next;
}
C4Val c4_key(void) {
    if (kbd_head == kbd_tail)
        return c4_num(-1);
    unsigned char ch = kbd_buf[kbd_tail];
    kbd_tail = (unsigned char)(kbd_tail + 1);
    return c4_num((double)ch);
}
extern void irq1_stub(void);
C4Val c4_irq1_addr(void) {
    return c4_num((double)(unsigned long)irq1_stub);
}
C4Val c4_ticks(void) {
    return c4_num((double)c4_tick_count);
}
extern void irq0_stub(void);
C4Val c4_irq0_addr(void) {
    return c4_num((double)(unsigned long)irq0_stub);
}
C4Val c4_sti(void) {
    __asm__ volatile("sti");
    return c4_nil();
}
C4Val c4_cli(void) {
    __asm__ volatile("cli");
    return c4_nil();
}
C4Val c4_outb(C4Val port, C4Val val) {
    c4_outb_raw((unsigned short)c4_tonum(port), (unsigned char)c4_tonum(val));
    return c4_nil();
}
C4Val c4_inb(C4Val port) {
    unsigned char v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"((unsigned short)c4_tonum(port)));
    return c4_num((double)v);
}
/* ---- 0.3.5: paging, kernel heap, syscalls ---- */
C4Val c4_poke32(C4Val addr, C4Val val) {
    unsigned long a = (unsigned long)c4_tonum(addr);
    unsigned long v = (unsigned long)c4_tonum(val);
    *(volatile unsigned long *)a = v;
    return c4_nil();
}
C4Val c4_peek32(C4Val addr) {
    unsigned long a = (unsigned long)c4_tonum(addr);
    return c4_num((double)*(volatile unsigned long *)a);
}
C4Val c4_cr3(C4Val addr) {
    unsigned long a = (unsigned long)c4_tonum(addr);
    __asm__ volatile("mov %0, %%cr3" ::"r"(a) : "memory");
    return c4_nil();
}
C4Val c4_pg_on(void) {
    unsigned long cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    cr0 |= 0x80000000UL;
    __asm__ volatile("mov %0, %%cr0" ::"r"(cr0) : "memory");
}
static unsigned char c4_kheap[1024 * 1024];
typedef struct KBlock {
    unsigned long size;
    struct KBlock *next;
} KBlock;
static KBlock *kheap_free_list = 0;
static unsigned long kheap_bump = 0;
C4Val c4_kmalloc(C4Val n) {
    unsigned long size = (unsigned long)c4_tonum(n);
    if ((long)size <= 0)
        c4_err("TypeError");
    size = (size + 7) & ~7UL;
    KBlock **prev = &kheap_free_list;
    KBlock *cur = kheap_free_list;
    while (cur) {
        if (cur->size >= size) {
            *prev = cur->next;
            return c4_num((double)(unsigned long)((char *)cur + sizeof(KBlock)));
        }
        prev = &cur->next;
        cur = cur->next;
    }
    if (kheap_bump + size + sizeof(KBlock) > sizeof c4_kheap)
        c4_err("OutOfMemory");
    KBlock *b = (KBlock *)(c4_kheap + kheap_bump);
    kheap_bump += size + sizeof(KBlock);
    b->size = size;
    return c4_num((double)(unsigned long)((char *)b + sizeof(KBlock)));
}
C4Val c4_kfree(C4Val addr) {
    unsigned long a = (unsigned long)c4_tonum(addr);
    if (a == 0)
        return c4_nil();
    KBlock *b = (KBlock *)((char *)a - sizeof(KBlock));
    if ((char *)b < (char *)c4_kheap || (char *)b >= (char *)c4_kheap + sizeof c4_kheap)
        c4_err("TypeError");
    b->next = kheap_free_list;
    kheap_free_list = b;
    return c4_nil();
}
extern void syscall_stub(void);
C4Val c4_syscall_addr(void) {
    return c4_num((double)(unsigned long)syscall_stub);
}
C4Val c4_syscall(C4Val num, C4Val a, C4Val b, C4Val c) {
    unsigned n = (unsigned)c4_tonum(num);
    unsigned aa = (unsigned)c4_tonum(a);
    unsigned bb = (unsigned)c4_tonum(b);
    unsigned cc = (unsigned)c4_tonum(c);
    unsigned ret;
    __asm__ volatile("int $0x80" : "=a"(ret) : "a"(n), "b"(aa), "c"(bb), "d"(cc) : "memory");
    return c4_num((double)ret);
}
C4Val c4_addr(C4Val v) {
    if (v.t == 1)
        return c4_num((double)(unsigned long)v.str);
    if (v.t == 2)
        return c4_num((double)(unsigned long)v.list->items);
    c4_err("TypeError");
    return c4_num(0);
}
/* ---- 0.3.6: user mode (GDT/TSS/enter), ELF loader ---- */
static unsigned long long c4_ugdt[6];
C4Val c4_gdt_set(C4Val idx, C4Val base, C4Val limit, C4Val access, C4Val gran) {
    unsigned i = (unsigned)c4_tonum(idx);
    if (i > 5)
        c4_err("TypeError");
    unsigned long b = (unsigned long)c4_tonum(base);
    unsigned long l = (unsigned long)c4_tonum(limit);
    unsigned a = (unsigned)c4_tonum(access);
    unsigned g = (unsigned)c4_tonum(gran);
    c4_ugdt[i] = ((unsigned long long)(l & 0xFFFF))
        | ((unsigned long long)(b & 0xFFFF) << 16)
        | ((unsigned long long)((b >> 16) & 0xFF) << 32)
        | ((unsigned long long)(a & 0xFF) << 40)
        | ((unsigned long long)((l >> 16) & 0x0F) << 48)
        | ((unsigned long long)(g & 0xF0) << 48)
        | ((unsigned long long)((b >> 24) & 0xFF) << 56);
    return c4_nil();
}
C4Val c4_gdt_load(void) {
    struct {
        unsigned short limit;
        unsigned addr;
    } __attribute__((packed)) d;
    d.limit = sizeof c4_ugdt - 1;
    d.addr = (unsigned)c4_ugdt;
    __asm__ volatile("lgdt %0" ::"m"(d));
    __asm__ volatile(
        "mov $0x10, %%ax\n"
        "mov %%ax, %%ds\n"
        "mov %%ax, %%es\n"
        "mov %%ax, %%fs\n"
        "mov %%ax, %%gs\n"
        "mov %%ax, %%ss\n"
        ::: "ax", "memory");
    return c4_nil();
}
static unsigned char c4_tss[104];
static void tss_set_esp0(unsigned top) {
    *(volatile unsigned *)(c4_tss + 4) = top;
}
C4Val c4_tss_init(C4Val esp0) {
    for (int i = 0; i < 104; i++)
        c4_tss[i] = 0;
    *(unsigned *)(c4_tss + 4) = (unsigned)c4_tonum(esp0);
    *(unsigned *)(c4_tss + 8) = 0x10;
    *(unsigned short *)(c4_tss + 102) = 104;
    {
        unsigned long b = (unsigned long)c4_tss;
        c4_ugdt[5] = ((unsigned long long)(103 & 0xFFFF))
            | ((unsigned long long)(b & 0xFFFF) << 16)
            | ((unsigned long long)((b >> 16) & 0xFF) << 32)
            | ((unsigned long long)0x89 << 40)
            | ((unsigned long long)0x00 << 48)
            | ((unsigned long long)((b >> 24) & 0xFF) << 56);
    }
    __asm__ volatile("ltr %%ax" ::"a"(0x28));
    return c4_nil();
}
extern void enter_user_stub(unsigned entry, unsigned esp);
C4Val c4_enter_user(C4Val entry, C4Val esp) {
    enter_user_stub((unsigned)c4_tonum(entry), (unsigned)c4_tonum(esp));
    c4_halt();
    return c4_nil();
}
extern void fault_stubs(void);
void c4_fault2(unsigned cr2, unsigned vec);
void c4_fault(unsigned vec) {
    c4_fault2(0, vec);
}
void c4_fault2(unsigned cr2, unsigned vec) {
    c4_write("FAULT ", 6);
    char buf[12];
    unsigned v = vec;
    int i = 0;
    if (v == 0) {
        buf[i++] = '0';
    } else {
        char rev[12];
        int j = 0;
        while (v > 0) {
            rev[j++] = (char)('0' + v % 10);
            v /= 10;
        }
        while (j > 0)
            buf[i++] = rev[--j];
    }
    buf[i++] = ' ';
    v = cr2;
    if (v == 0) {
        buf[i++] = '0';
    } else {
        char rev[12];
        int j = 0;
        while (v > 0) {
            unsigned d = v % 16;
            rev[j++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
            v /= 16;
        }
        while (j > 0)
            buf[i++] = rev[--j];
    }
    buf[i++] = '\n';
    c4_write(buf, (unsigned)i);
    c4_halt();
}
C4Val c4_fault_addr(C4Val vec) {
    unsigned v = (unsigned)c4_tonum(vec);
    if (v > 31)
        c4_err("TypeError");
    return c4_num((double)(unsigned long)((char *)fault_stubs + v * 8));
}
C4Val c4_elf_load(C4Val base) {
    unsigned char *b = (unsigned char *)(unsigned long)c4_tonum(base);
    if (b[0] != 0x7F || b[1] != 'E' || b[2] != 'L' || b[3] != 'F')
        return c4_num(0);
    if (b[4] != 1 || b[5] != 1)
        return c4_num(0);
    if (*(unsigned short *)(b + 16) != 2)
        return c4_num(0);
    if (*(unsigned short *)(b + 18) != 3)
        return c4_num(0);
    unsigned entry = *(unsigned *)(b + 24);
    unsigned phoff = *(unsigned *)(b + 28);
    unsigned phnum = *(unsigned short *)(b + 44);
    for (unsigned i = 0; i < phnum && i < 16; i++) {
        unsigned char *ph = b + phoff + i * 32;
        unsigned type = *(unsigned *)(ph + 0);
        if (type != 1)
            continue;
        unsigned off = *(unsigned *)(ph + 4);
        unsigned vaddr = *(unsigned *)(ph + 8);
        unsigned filesz = *(unsigned *)(ph + 16);
        unsigned memsz = *(unsigned *)(ph + 20);
        if (vaddr < 0x400000 || vaddr >= 0x800000)
            return c4_num(0);
        if (vaddr + memsz < vaddr || vaddr + memsz >= 0x800000)
            return c4_num(0);
        unsigned char *dst = (unsigned char *)vaddr;
        for (unsigned k = 0; k < filesz; k++)
            dst[k] = b[off + k];
        for (unsigned k = filesz; k < memsz; k++)
            dst[k] = 0;
    }
    return c4_num((double)entry);
}
static unsigned char c4_idt[256][8];
C4Val c4_idt_set(C4Val vec, C4Val off, C4Val sel, C4Val attr) {
    unsigned v = (unsigned)c4_tonum(vec);
    if (v > 255)
        c4_err("TypeError");
    unsigned long o = (unsigned long)c4_tonum(off);
    unsigned s = (unsigned)c4_tonum(sel);
    unsigned a = (unsigned)c4_tonum(attr);
    unsigned char *g = c4_idt[v];
    g[0] = (unsigned char)(o & 0xFF);
    g[1] = (unsigned char)((o >> 8) & 0xFF);
    g[2] = (unsigned char)(s & 0xFF);
    g[3] = (unsigned char)((s >> 8) & 0xFF);
    g[4] = 0;
    g[5] = (unsigned char)(a & 0xFF);
    g[6] = (unsigned char)((o >> 16) & 0xFF);
    g[7] = (unsigned char)((o >> 24) & 0xFF);
    return c4_nil();
}
C4Val c4_idt_load(void) {
    struct {
        unsigned short limit;
        unsigned addr;
    } __attribute__((packed)) d;
    d.limit = sizeof c4_idt - 1;
    d.addr = (unsigned)c4_idt;
    __asm__ volatile("lidt %0" ::"m"(d));
    return c4_nil();
}

static char *xdup(const char *s) {
    c4_size_t n = c4_strlen(s);
    char *p = xmalloc(n + 1);
    c4_memcpy(p, s, n + 1);
    return p;
}
static char *xdupn(const char *s, c4_size_t n) {
    char *p = xmalloc(n + 1);
    c4_memcpy(p, s, n);
    p[n] = 0;
    return p;
}

C4Val c4_num(double n) {
    C4Val v;
    v.t = 0; /* C4_NUM */
    v.num = n;
    return v;
}
C4Val c4_str(const char *s) {
    C4Val v;
    v.t = 1; /* C4_STR */
    v.str = xdup(s);
    return v;
}
C4Val c4_list(void) {
    C4Val v;
    v.t = 2;
    v.list = xmalloc(sizeof(C4List));
    v.list->items = 0;
    v.list->len = v.list->cap = 0;
    return v;
}
C4Val c4_dict(void) {
    C4Val v;
    v.t = 3;
    v.dict = xmalloc(sizeof(C4Dict));
    v.dict->keys = 0;
    v.dict->vals = 0;
    v.dict->len = v.dict->cap = 0;
    return v;
}
C4Val c4_struct(const char *tname, const char **fields, C4Val *vals, c4_size_t n) {
    C4Val v;
    v.t = 4;
    v.st = xmalloc(sizeof(C4Struct));
    v.st->tname = tname;
    v.st->fields = xmalloc(sizeof(char *) * (n ? n : 1));
    v.st->vals = xmalloc(sizeof(C4Val) * (n ? n : 1));
    for (c4_size_t i = 0; i < n; i++) {
        v.st->fields[i] = fields[i];
        v.st->vals[i] = vals[i];
    }
    v.st->n = n;
    return v;
}
C4Val c4_nil(void) {
    C4Val v;
    v.t = 5;
    v.num = 0;
    return v;
}

static void list_grow(C4List *l) {
    if (l->len >= l->cap) {
        c4_size_t nc = l->cap ? l->cap * 2 : 8;
        C4Val *ni = xmalloc(sizeof(C4Val) * nc);
        for (c4_size_t i = 0; i < l->len; i++)
            ni[i] = l->items[i];
        l->items = ni;
        l->cap = nc;
    }
}
static void list_push(C4List *l, C4Val v) {
    list_grow(l);
    l->items[l->len++] = v;
}
static void dict_put(C4Dict *d, const char *k, C4Val v) {
    for (c4_size_t i = 0; i < d->len; i++) {
        if (c4_strcmp(d->keys[i], k) == 0) {
            d->vals[i] = v;
            return;
        }
    }
    if (d->len >= d->cap) {
        c4_size_t nc = d->cap ? d->cap * 2 : 8;
        char **nk = xmalloc(sizeof(char *) * nc);
        C4Val *nv = xmalloc(sizeof(C4Val) * nc);
        for (c4_size_t i = 0; i < d->len; i++) {
            nk[i] = d->keys[i];
            nv[i] = d->vals[i];
        }
        d->keys = nk;
        d->vals = nv;
        d->cap = nc;
    }
    d->keys[d->len] = xdup(k);
    d->vals[d->len] = v;
    d->len++;
}

/* decimal digits of v (0 <= v < 2^53, integer), written backward from *pp */
static void c4_putuint(char **pp, double v) {
    if (v < 1) {
        *--(*pp) = '0';
        return;
    }
    while (v >= 1) {
        double q = c4_trunc(v / 10);
        int dig = (int)(v - q * 10);
        if (dig < 0)
            dig = 0;
        if (dig > 9)
            dig = 9;
        *--(*pp) = (char)('0' + dig);
        v = q;
    }
}
/* shortest-ish decimal: integers exact, else 6 decimals */
char *c4_tostring(C4Val v) {
    char tmp[64];
    switch (v.t) {
    case 0: {
        double n = v.num;
        if (n == c4_trunc(n) && c4_fabs(n) < 9007199254740991.0) {
            int neg = n < 0;
            double a = neg ? -n : n;
            char *p = tmp + sizeof tmp;
            *--p = 0;
            c4_putuint(&p, a);
            if (neg)
                *--p = '-';
            c4_size_t L = (c4_size_t)(tmp + sizeof tmp - 1 - p);
            char *o = xmalloc(L + 1);
            c4_memcpy(o, p, L + 1);
            return o;
        }
        {
            int neg = n < 0;
            double a = neg ? -n : n;
            double fpi = c4_trunc(a);
            double fp = (a - fpi) * 1000000.0 + 0.5;
            double frd = c4_trunc(fp);
            double ipd = fpi;
            if (frd >= 1000000) {
                ipd += 1;
                frd -= 1000000;
            }
            char *p = tmp + sizeof tmp;
            *--p = 0;
            {
                long fr = (long)frd;
                for (int i = 0; i < 6; i++) {
                    int dig = fr - (fr / 10) * 10;
                    *--p = (char)('0' + dig);
                    fr /= 10;
                }
            }
            *--p = '.';
            c4_putuint(&p, ipd);
            if (neg)
                *--p = '-';
            c4_size_t L = (c4_size_t)(tmp + sizeof tmp - 1 - p);
            char *o = xmalloc(L + 1);
            c4_memcpy(o, p, L + 1);
            return o;
        }
    }
    case 1:
        return xdup(v.str);
    case 5:
        return xdup("nil");
    case 2: {
        c4_size_t cap = 64, len = 0;
        char *o = xmalloc(cap);
        o[len++] = '[';
        for (c4_size_t i = 0; i < v.list->len; i++) {
            char *s = c4_tostring(v.list->items[i]);
            c4_size_t sl = c4_strlen(s);
            if (i > 0) {
                if (len + 2 >= cap) {
                    cap *= 2;
                    char *no = xmalloc(cap);
                    c4_memcpy(no, o, len);
                    o = no;
                }
                o[len++] = ',';
                o[len++] = ' ';
            }
            while (len + sl + 2 >= cap) {
                cap *= 2;
                char *no = xmalloc(cap);
                c4_memcpy(no, o, len);
                o = no;
            }
            c4_memcpy(o + len, s, sl);
            len += sl;
        }
        o[len++] = ']';
        o[len] = 0;
        return o;
    }
    case 3: {
        c4_size_t cap = 64, len = 0;
        char *o = xmalloc(cap);
        o[len++] = '{';
        for (c4_size_t i = 0; i < v.dict->len; i++) {
            char *vs = c4_tostring(v.dict->vals[i]);
            c4_size_t kl = c4_strlen(v.dict->keys[i]), vl = c4_strlen(vs);
            while (len + kl + vl + 8 >= cap) {
                cap *= 2;
                char *no = xmalloc(cap);
                c4_memcpy(no, o, len);
                o = no;
            }
            if (i > 0) {
                o[len++] = ',';
                o[len++] = ' ';
            }
            o[len++] = '"';
            c4_memcpy(o + len, v.dict->keys[i], kl);
            len += kl;
            o[len++] = '"';
            o[len++] = ':';
            o[len++] = ' ';
            c4_memcpy(o + len, vs, vl);
            len += vl;
        }
        o[len++] = '}';
        o[len] = 0;
        return o;
    }
    case 4: {
        c4_size_t cap = 64, len = 0;
        char *o = xmalloc(cap);
        c4_size_t tl = c4_strlen(v.st->tname);
        while (len + tl + 4 >= cap) {
            cap *= 2;
            char *no = xmalloc(cap);
            c4_memcpy(no, o, len);
            o = no;
        }
        c4_memcpy(o + len, v.st->tname, tl);
        len += tl;
        o[len++] = '{';
        for (c4_size_t i = 0; i < v.st->n; i++) {
            char *vs = c4_tostring(v.st->vals[i]);
            c4_size_t fl = c4_strlen(v.st->fields[i]), vl = c4_strlen(vs);
            while (len + fl + vl + 6 >= cap) {
                cap *= 2;
                char *no = xmalloc(cap);
                c4_memcpy(no, o, len);
                o = no;
            }
            if (i > 0) {
                o[len++] = ',';
                o[len++] = ' ';
            }
            c4_memcpy(o + len, v.st->fields[i], fl);
            len += fl;
            o[len++] = ':';
            o[len++] = ' ';
            c4_memcpy(o + len, vs, vl);
            len += vl;
        }
        o[len++] = '}';
        o[len] = 0;
        return o;
    }
    }
    return xdup("");
}
void c4_print(C4Val v) {
    char *s = c4_tostring(v);
    c4_write(s, (unsigned)c4_strlen(s));
    c4_write("\n", 1);
}
int c4_truthy(C4Val v) {
    switch (v.t) {
    case 0:
        return v.num != 0;
    case 1:
        return v.str[0] != 0;
    case 2:
        return v.list->len > 0;
    case 3:
        return v.dict->len > 0;
    case 4:
        return 1;
    case 5:
        return 0;
    }
    return 0;
}
static void need_num(C4Val v, const char *op) {
    (void)op;
    if (v.t != 0)
        c4_err("TypeError");
}
C4Val c4_add(C4Val a, C4Val b) {
    if (a.t == 2 && b.t == 2) {
        C4Val o = c4_list();
        for (c4_size_t i = 0; i < a.list->len; i++)
            list_push(o.list, a.list->items[i]);
        for (c4_size_t i = 0; i < b.list->len; i++)
            list_push(o.list, b.list->items[i]);
        return o;
    }
    if (a.t == 1 || b.t == 1) {
        char *x = c4_tostring(a), *y = c4_tostring(b);
        c4_size_t xl = c4_strlen(x), yl = c4_strlen(y);
        char *o = xmalloc(xl + yl + 1);
        c4_memcpy(o, x, xl);
        c4_memcpy(o + xl, y, yl + 1);
        C4Val v;
        v.t = 1;
        v.str = o;
        return v;
    }
    if (a.t != 0 || b.t != 0)
        c4_err("TypeError");
    return c4_num(a.num + b.num);
}
C4Val c4_sub(C4Val a, C4Val b) {
    need_num(a, "-");
    need_num(b, "-");
    return c4_num(a.num - b.num);
}
C4Val c4_mul(C4Val a, C4Val b) {
    need_num(a, "*");
    need_num(b, "*");
    return c4_num(a.num * b.num);
}
C4Val c4_div(C4Val a, C4Val b) {
    need_num(a, "/");
    need_num(b, "/");
    if (b.num == 0)
        c4_err("DivisionByZero");
    return c4_num(a.num / b.num);
}
C4Val c4_mod(C4Val a, C4Val b) {
    need_num(a, "%");
    need_num(b, "%");
    if (b.num == 0)
        c4_err("DivisionByZero");
    double q = c4_trunc(a.num / b.num);
    return c4_num(a.num - q * b.num);
}
int c4_eq(C4Val a, C4Val b) {
    if (a.t == 0 && b.t == 0)
        return a.num == b.num;
    if (a.t == 1 && b.t == 1)
        return c4_strcmp(a.str, b.str) == 0;
    if (a.t == 2 && b.t == 2) {
        if (a.list->len != b.list->len)
            return 0;
        for (c4_size_t i = 0; i < a.list->len; i++)
            if (!c4_eq(a.list->items[i], b.list->items[i]))
                return 0;
        return 1;
    }
    if (a.t == 3 && b.t == 3) {
        if (a.dict->len != b.dict->len)
            return 0;
        for (c4_size_t i = 0; i < a.dict->len; i++) {
            int found = 0;
            for (c4_size_t j = 0; j < b.dict->len; j++) {
                if (c4_strcmp(a.dict->keys[i], b.dict->keys[j]) == 0) {
                    if (!c4_eq(a.dict->vals[i], b.dict->vals[j]))
                        return 0;
                    found = 1;
                    break;
                }
            }
            if (!found)
                return 0;
        }
        return 1;
    }
    if (a.t == 4 && b.t == 4) {
        if (c4_strcmp(a.st->tname, b.st->tname) != 0 || a.st->n != b.st->n)
            return 0;
        for (c4_size_t i = 0; i < a.st->n; i++) {
            if (c4_strcmp(a.st->fields[i], b.st->fields[i]) != 0)
                return 0;
            if (!c4_eq(a.st->vals[i], b.st->vals[i]))
                return 0;
        }
        return 1;
    }
    if (a.t == 5 && b.t == 5)
        return 1;
    if (a.t == 5 || b.t == 5)
        return 0;
    {
        char *x = c4_tostring(a), *y = c4_tostring(b);
        int r = c4_strcmp(x, y) == 0;
        return r;
    }
}
int c4_lt(C4Val a, C4Val b) {
    if (a.t == 0 && b.t == 0)
        return a.num < b.num;
    if (a.t == 1 && b.t == 1)
        return c4_strcmp(a.str, b.str) < 0;
    c4_err("TypeError");
    return 0;
}
static long c4_index_of(C4Val l, C4Val ix) {
    if (ix.t != 0 || ix.num != c4_trunc(ix.num))
        c4_err("TypeError");
    long i = (long)ix.num, n = (long)l.list->len;
    if (i < 0)
        i += n;
    if (i < 0 || i >= n)
        c4_err("IndexOutOfBounds");
    return i;
}
C4Val c4_index(C4Val base, C4Val ix) {
    if (base.t == 2)
        return base.list->items[c4_index_of(base, ix)];
    if (base.t == 1) {
        if (ix.t != 0 || ix.num != c4_trunc(ix.num))
            c4_err("TypeError");
        long i = (long)ix.num, n = (long)c4_strlen(base.str);
        if (i < 0)
            i += n;
        if (i < 0 || i >= n)
            c4_err("IndexOutOfBounds");
        char tmp[2] = {base.str[i], 0};
        return c4_str(tmp);
    }
    if (base.t == 3) {
        char *k = c4_tostring(ix);
        for (c4_size_t i = 0; i < base.dict->len; i++)
            if (c4_strcmp(base.dict->keys[i], k) == 0)
                return base.dict->vals[i];
        c4_err("KeyMissing");
    }
    c4_err("NotIndexable");
    return c4_nil();
}
C4Val c4_index_set(C4Val base, C4Val ix, C4Val v) {
    if (base.t == 2) {
        base.list->items[c4_index_of(base, ix)] = v;
        return base;
    }
    if (base.t == 1) {
        if (ix.t != 0 || ix.num != c4_trunc(ix.num))
            c4_err("TypeError");
        long i = (long)ix.num, n = (long)c4_strlen(base.str);
        if (i < 0)
            i += n;
        if (i < 0 || i >= n)
            c4_err("IndexOutOfBounds");
        if (v.t != 1 || c4_strlen(v.str) != 1)
            c4_err("TypeError");
        char *o = xdup(base.str);
        o[i] = v.str[0];
        C4Val nv;
        nv.t = 1;
        nv.str = o;
        return nv;
    }
    if (base.t == 3) {
        char *k = c4_tostring(ix);
        dict_put(base.dict, k, v);
        return base;
    }
    c4_err("NotIndexable");
    return base;
}
C4Val c4_field(C4Val base, const char *f) {
    if (base.t != 4)
        c4_err("TypeError");
    for (c4_size_t i = 0; i < base.st->n; i++)
        if (c4_strcmp(base.st->fields[i], f) == 0)
            return base.st->vals[i];
    c4_err("UnknownVariable");
    return c4_nil();
}
C4Val c4_field_set(C4Val base, const char *f, C4Val v) {
    if (base.t != 4)
        c4_err("TypeError");
    for (c4_size_t i = 0; i < base.st->n; i++)
        if (c4_strcmp(base.st->fields[i], f) == 0) {
            base.st->vals[i] = v;
            return base;
        }
    c4_err("UnknownVariable");
    return base;
}
C4Val c4_range(C4Val a, C4Val b) {
    need_num(a, "..");
    need_num(b, "..");
    if (a.num != c4_trunc(a.num) || b.num != c4_trunc(b.num))
        c4_err("TypeError");
    long x = (long)a.num, y = (long)b.num;
    long step = y >= x ? 1 : -1;
    long count = 0;
    for (long t = x;; t += step) {
        count++;
        if (count > 1000000)
            c4_err("LoopLimitExceeded");
        if (t == y)
            break;
    }
    C4Val o = c4_list();
    for (long t = x;; t += step) {
        list_push(o.list, c4_num((double)t));
        if (t == y)
            break;
    }
    return o;
}
C4Val c4_len(C4Val v) {
    switch (v.t) {
    case 1:
        return c4_num((double)c4_strlen(v.str));
    case 2:
        return c4_num((double)v.list->len);
    case 3:
        return c4_num((double)v.dict->len);
    default:
        c4_err("TypeError");
    }
    return c4_nil();
}
C4Val c4_push(C4Val l, C4Val v) {
    if (l.t != 2)
        c4_err("TypeError");
    list_push(l.list, v);
    return c4_num((double)l.list->len);
}
C4Val c4_type(C4Val v) {
    switch (v.t) {
    case 0:
        return c4_str("number");
    case 1:
        return c4_str("string");
    case 2:
        return c4_str("list");
    case 3:
        return c4_str("dict");
    case 5:
        return c4_str("nil");
    case 4:
        return c4_str(v.st->tname);
    }
    return c4_str("?");
}
C4Val c4_str_b(C4Val v) {
    char *s = c4_tostring(v);
    C4Val o;
    o.t = 1;
    o.str = s;
    return o;
}
static double c4_tonum(C4Val v) {
    if (v.t != 0)
        c4_err("TypeError");
    return v.num;
}
C4Val c4_int(C4Val v) {
    if (v.t == 0)
        return c4_num(c4_trunc(v.num));
    if (v.t == 1) {
        /* minimal strtod */
        const char *s = v.str;
        while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')
            s++;
        int neg = 0;
        if (*s == '-') {
            neg = 1;
            s++;
        } else if (*s == '+') {
            s++;
        }
        if (*s < '0' || *s > '9')
            c4_err("BadNumber");
        double n = 0;
        while (*s >= '0' && *s <= '9') {
            n = n * 10 + (*s - '0');
            s++;
        }
        if (*s == '.') {
            s++;
            double f = 0, d = 10;
            int any = 0;
            while (*s >= '0' && *s <= '9') {
                f += (*s - '0') / d;
                d *= 10;
                s++;
                any = 1;
            }
            if (!any)
                c4_err("BadNumber");
            n += f;
        }
        if (neg)
            n = -n;
        return c4_num(c4_trunc(n));
    }
    c4_err("TypeError");
    return c4_nil();
}
static int c4_is_str(C4Val v) {
    if (v.t != 1)
        c4_err("TypeError");
    return 1;
}
C4Val c4_split(C4Val s, C4Val sep) {
    c4_is_str(s);
    c4_is_str(sep);
    (void)0;
    C4Val o = c4_list();
    if (sep.str[0] == 0) {
        for (const char *p = s.str; *p; p++) {
            char tmp[2] = {*p, 0};
            list_push(o.list, c4_str(tmp));
        }
        return o;
    }
    const char *rest = s.str;
    c4_size_t sl = c4_strlen(sep.str);
    while (1) {
        const char *f = rest;
        while (*f && !c4_starts(rest, f, sep.str, sl))
            f++;
        {
            c4_size_t n = (c4_size_t)(f - rest);
            char *part = xmalloc(n + 1);
            c4_memcpy(part, rest, n);
            part[n] = 0;
            C4Val pv;
            pv.t = 1;
            pv.str = part;
            list_push(o.list, pv);
        }
        if (!*f)
            break;
        rest = f + sl;
    }
    return o;
}
static int c4_starts(const char *hay, const char *at, const char *nd, c4_size_t nl) {
    (void)hay;
    for (c4_size_t i = 0; i < nl; i++)
        if (at[i] != nd[i])
            return 0;
    return 1;
}
C4Val c4_join(C4Val l, C4Val sep) {
    if (l.t != 2)
        c4_err("TypeError");
    char *sp = c4_tostring(sep);
    c4_size_t cap = 64, len = 0;
    char *o = xmalloc(cap);
    o[0] = 0;
    for (c4_size_t i = 0; i < l.list->len; i++) {
        char *pp = c4_tostring(l.list->items[i]);
        c4_size_t pl = c4_strlen(pp), sl = c4_strlen(sp);
        while (len + pl + sl + 2 >= cap) {
            cap *= 2;
            char *no = xmalloc(cap);
            c4_memcpy(no, o, len + 1);
            o = no;
        }
        if (i > 0) {
            c4_memcpy(o + len, sp, sl);
            len += sl;
        }
        c4_memcpy(o + len, pp, pl + 1);
        len += pl;
    }
    return c4_str(o);
}
C4Val c4_substr(C4Val s, C4Val a, C4Val b) {
    c4_is_str(s);
    double an = c4_tonum(a), bn = c4_tonum(b);
    long n = (long)c4_strlen(s.str);
    long st = (long)an, co = (long)bn;
    if (st < 0)
        st += n;
    if (co < 0)
        co = 0;
    if (st < 0)
        st = 0;
    if (st > n)
        st = n;
    long en = st + co;
    if (en > n)
        en = n;
    C4Val v;
    v.t = 1;
    char *o = xmalloc((c4_size_t)(en - st) + 1);
    c4_memcpy(o, s.str + st, (c4_size_t)(en - st));
    o[en - st] = 0;
    v.str = o;
    return v;
}
C4Val c4_trim(C4Val s) {
    c4_is_str(s);
    const char *a = s.str, *b = s.str + c4_strlen(s.str);
    while (a < b && (*a == ' ' || *a == '\t' || *a == '\r' || *a == '\n'))
        a++;
    while (b > a && (b[-1] == ' ' || b[-1] == '\t' || b[-1] == '\r' || b[-1] == '\n'))
        b--;
    C4Val v;
    v.t = 1;
    char *o = xmalloc((c4_size_t)(b - a) + 1);
    c4_memcpy(o, a, (c4_size_t)(b - a));
    o[b - a] = 0;
    v.str = o;
    return v;
}
static C4Val c4_case(C4Val s, int up) {
    c4_is_str(s);
    char *o = xdup(s.str);
    for (char *p = o; *p; p++) {
        if (up && *p >= 'a' && *p <= 'z')
            *p -= 32;
        if (!up && *p >= 'A' && *p <= 'Z')
            *p += 32;
    }
    C4Val v;
    v.t = 1;
    v.str = o;
    return v;
}
C4Val c4_upper(C4Val s) {
    return c4_case(s, 1);
}
C4Val c4_lower(C4Val s) {
    return c4_case(s, 0);
}
static const char *c4_find(const char *h, const char *n, c4_size_t nl) {
    if (nl == 0)
        return h;
    for (const char *p = h; *p; p++) {
        c4_size_t i = 0;
        while (i < nl && p[i] == n[i])
            i++;
        if (i == nl)
            return p;
    }
    return 0;
}
C4Val c4_replace(C4Val s, C4Val o, C4Val nw) {
    c4_is_str(s);
    c4_is_str(o);
    c4_is_str(nw);
    if (o.str[0] == 0)
        return c4_str(s.str);
    c4_size_t ol = c4_strlen(o.str), nl = c4_strlen(nw.str);
    c4_size_t cap = c4_strlen(s.str) + 1, len = 0;
    char *out = xmalloc(cap);
    const char *rest = s.str;
    const char *f;
    while ((f = c4_find(rest, o.str, ol)) != 0) {
        c4_size_t pre = (c4_size_t)(f - rest);
        while (len + pre + nl + 1 >= cap) {
            cap *= 2;
            char *no = xmalloc(cap);
            c4_memcpy(no, out, len);
            out = no;
        }
        c4_memcpy(out + len, rest, pre);
        len += pre;
        c4_memcpy(out + len, nw.str, nl);
        len += nl;
        rest = f + ol;
    }
    c4_size_t rl = c4_strlen(rest);
    while (len + rl + 1 >= cap) {
        cap *= 2;
        char *no = xmalloc(cap);
        c4_memcpy(no, out, len);
        out = no;
    }
    c4_memcpy(out + len, rest, rl + 1);
    C4Val v;
    v.t = 1;
    v.str = out;
    return v;
}
C4Val c4_contains(C4Val h, C4Val n) {
    char *x = c4_tostring(h), *y = c4_tostring(n);
    int r = c4_find(x, y, c4_strlen(y)) != 0;
    return c4_num(r);
}
C4Val c4_abs(C4Val v) {
    return c4_num(c4_fabs(c4_tonum(v)));
}
C4Val c4_min(C4Val a, C4Val b) {
    double x = c4_tonum(a), y = c4_tonum(b);
    return c4_num(x < y ? x : y);
}
C4Val c4_max(C4Val a, C4Val b) {
    double x = c4_tonum(a), y = c4_tonum(b);
    return c4_num(x > y ? x : y);
}
C4Val c4_sqrt(C4Val v) {
    double x = c4_tonum(v);
    if (x < 0)
        c4_err("MathError");
    if (x == 0)
        return c4_num(0);
    double g = x / 2;
    if (g == 0)
        g = 1;
    for (int i = 0; i < 25; i++)
        g = (g + x / g) / 2;
    return c4_num(g);
}
C4Val c4_floor(C4Val v) {
    double x = c4_tonum(v);
    long i = (long)x;
    if ((double)i > x)
        i--;
    return c4_num((double)i);
}
C4Val c4_ceil(C4Val v) {
    double x = c4_tonum(v);
    long i = (long)x;
    if ((double)i < x)
        i++;
    return c4_num((double)i);
}
C4Val c4_round(C4Val v) {
    double x = c4_tonum(v);
    if (x >= 0)
        return c4_num(c4_floor(c4_num(x + 0.5)).num);
    return c4_num(-c4_floor(c4_num(-x + 0.5)).num);
}
static unsigned long long c4_u64(C4Val v) {
    if (v.t != 0 || v.num != c4_trunc(v.num) || c4_fabs(v.num) >= 9223372036854775808.0)
        c4_err("TypeError");
    long long i = (long long)v.num;
    unsigned long long u;
    c4_memcpy((char *)&u, (char *)&i, 8);
    return u;
}
static C4Val c4_fromu64(unsigned long long u) {
    long long i;
    c4_memcpy((char *)&i, (char *)&u, 8);
    return c4_num((double)i);
}
C4Val c4_band(C4Val a, C4Val b) {
    return c4_fromu64(c4_u64(a) & c4_u64(b));
}
C4Val c4_bor(C4Val a, C4Val b) {
    return c4_fromu64(c4_u64(a) | c4_u64(b));
}
C4Val c4_bxor(C4Val a, C4Val b) {
    return c4_fromu64(c4_u64(a) ^ c4_u64(b));
}
C4Val c4_bnot(C4Val v) {
    return c4_fromu64(~c4_u64(v));
}
C4Val c4_shl(C4Val a, C4Val b) {
    unsigned long long x = c4_u64(a), s = c4_u64(b);
    if (s > 63)
        c4_err("TypeError");
    return c4_fromu64(x << (unsigned)s);
}
C4Val c4_shr(C4Val a, C4Val b) {
    unsigned long long x = c4_u64(a), s = c4_u64(b);
    if (s > 63)
        c4_err("TypeError");
    long long xs;
    c4_memcpy((char *)&xs, (char *)&x, 8);
    return c4_num((double)(xs >> s));
}
C4Val c4_bytes(C4Val n) {
    double x = c4_tonum(n);
    if (x != c4_trunc(x) || x < 0 || x > 16 * 1024 * 1024)
        c4_err("TypeError");
    C4Val o = c4_list();
    for (long i = 0; i < (long)x; i++)
        list_push(o.list, c4_num(0));
    return o;
}
static long c4_bidx(C4Val l, C4Val ix) {
    if (l.t != 2)
        c4_err("TypeError");
    if (ix.t != 0 || ix.num != c4_trunc(ix.num))
        c4_err("TypeError");
    long i = (long)ix.num, n2 = (long)l.list->len;
    if (i < 0)
        i += n2;
    if (i < 0 || i >= n2)
        c4_err("IndexOutOfBounds");
    return i;
}
C4Val c4_peek(C4Val l, C4Val i) {
    return l.list->items[c4_bidx(l, i)];
}
C4Val c4_poke(C4Val l, C4Val i, C4Val v) {
    long idx = c4_bidx(l, i);
    double x = c4_tonum(v);
    if (x != c4_trunc(x) || x < 0 || x > 255)
        c4_err("TypeError");
    l.list->items[idx] = v;
    return v;
}
static double c4_wrapn(double v, int bits, int sg) {
    if (v != c4_trunc(v) || c4_fabs(v) >= 9007199254740992.0)
        c4_err("TypeError");
    double m = 1.0;
    for (int i = 0; i < bits; i++)
        m *= 2;
    double r = v - c4_trunc(v / m) * m;
    if (r < 0)
        r += m;
    if (sg && r * 2.0 >= m)
        r -= m;
    return r;
}
C4Val c4_pack(C4Val fmt, C4Val vals) {
    if (fmt.t != 1 || vals.t != 2)
        c4_err("TypeError");
    int little = 1;
    c4_size_t vi = 0;
    C4Val o = c4_list();
    for (const char *f = fmt.str; *f; f++) {
        if (*f == '<') {
            little = 1;
        } else if (*f == '>') {
            little = 0;
        } else if (*f == ' ') {
        } else if (*f == 'x') {
            list_push(o.list, c4_num(0));
        } else if (*f == 'B' || *f == 'H' || *f == 'I' || *f == 'b' || *f == 'h' || *f == 'i') {
            if (vi >= vals.list->len)
                c4_err("ArityMismatch");
            int bits = (*f == 'B' || *f == 'b') ? 8 : (*f == 'H' || *f == 'h') ? 16 : 32;
            int sg = (*f == 'b' || *f == 'h' || *f == 'i');
            double w = c4_wrapn(vals.list->items[vi++].num, bits, sg);
            double m = 1.0;
            for (int i = 0; i < bits; i++)
                m *= 2;
            double u = w - c4_trunc(w / m) * m;
            if (u < 0)
                u += m;
            int nb = bits / 8;
            for (int k = 0; k < nb; k++) {
                int sh = little ? k * 8 : (nb - 1 - k) * 8;
                double d = 1.0;
                for (int i = 0; i < sh; i++)
                    d *= 2;
                double byte = c4_trunc(u / d);
                while (byte >= 256)
                    byte -= 256 * c4_trunc(byte / 256);
                list_push(o.list, c4_num(byte));
            }
        } else
            c4_err("TypeError");
    }
    if (vi != vals.list->len)
        c4_err("ArityMismatch");
    return o;
}
C4Val c4_unpack(C4Val fmt, C4Val data) {
    if (fmt.t != 1 || data.t != 2)
        c4_err("TypeError");
    for (c4_size_t i = 0; i < data.list->len; i++) {
        double b = c4_tonum(data.list->items[i]);
        if (b != c4_trunc(b) || b < 0 || b > 255)
            c4_err("TypeError");
    }
    int little = 1;
    c4_size_t pos = 0;
    C4Val o = c4_list();
    for (const char *f = fmt.str; *f; f++) {
        if (*f == '<') {
            little = 1;
        } else if (*f == '>') {
            little = 0;
        } else if (*f == ' ') {
        } else if (*f == 'x') {
            if (pos >= data.list->len)
                c4_err("UnexpectedEof");
            pos++;
        } else if (*f == 'B' || *f == 'H' || *f == 'I' || *f == 'b' || *f == 'h' || *f == 'i') {
            int bits = (*f == 'B' || *f == 'b') ? 8 : (*f == 'H' || *f == 'h') ? 16 : 32;
            int nb = bits / 8;
            if (pos + (c4_size_t)nb > data.list->len)
                c4_err("UnexpectedEof");
            unsigned long long u = 0;
            for (int k = 0; k < nb; k++) {
                int sh = little ? k * 8 : (nb - 1 - k) * 8;
                unsigned long long bv = (unsigned long long)data.list->items[pos + (c4_size_t)k].num;
                u |= bv << sh;
            }
            pos += (c4_size_t)nb;
            if (*f == 'b' || *f == 'h' || *f == 'i') {
                unsigned long long half = 1ULL << (bits - 1);
                if (u >= half) {
                    double full = 1.0;
                    for (int i = 0; i < bits; i++)
                        full *= 2;
                    list_push(o.list, c4_num((double)u - full));
                } else {
                    list_push(o.list, c4_num((double)u));
                }
            } else {
                list_push(o.list, c4_num((double)u));
            }
        } else
            c4_err("TypeError");
    }
    if (pos != data.list->len)
        c4_err("UnexpectedEof");
    return o;
}
C4Val c4_sizeof(C4Val fmt) {
    if (fmt.t != 1)
        c4_err("TypeError");
    c4_size_t n = 0;
    for (const char *f = fmt.str; *f; f++) {
        if (*f == 'B' || *f == 'b' || *f == 'x')
            n += 1;
        else if (*f == 'H' || *f == 'h')
            n += 2;
        else if (*f == 'I' || *f == 'i')
            n += 4;
        else if (*f == '<' || *f == '>' || *f == ' ')
            ;
        else
            c4_err("TypeError");
    }
    return c4_num((double)n);
}
C4Val c4_u8(C4Val v) {
    return c4_num(c4_wrapn(c4_tonum(v), 8, 0));
}
C4Val c4_u16(C4Val v) {
    return c4_num(c4_wrapn(c4_tonum(v), 16, 0));
}
C4Val c4_u32(C4Val v) {
    return c4_num(c4_wrapn(c4_tonum(v), 32, 0));
}
C4Val c4_i8(C4Val v) {
    return c4_num(c4_wrapn(c4_tonum(v), 8, 1));
}
C4Val c4_i16(C4Val v) {
    return c4_num(c4_wrapn(c4_tonum(v), 16, 1));
}
C4Val c4_i32(C4Val v) {
    return c4_num(c4_wrapn(c4_tonum(v), 32, 1));
}
C4Val c4_keys(C4Val d) {
    if (d.t != 3)
        c4_err("TypeError");
    C4Val o = c4_list();
    for (c4_size_t i = 0; i < d.dict->len; i++)
        list_push(o.list, c4_str(d.dict->keys[i]));
    return o;
}
C4Val c4_del(C4Val d, C4Val k) {
    if (d.t != 3)
        c4_err("TypeError");
    char *key = c4_tostring(k);
    for (c4_size_t i = 0; i < d.dict->len; i++) {
        if (c4_strcmp(d.dict->keys[i], key) == 0) {
            for (c4_size_t j = i + 1; j < d.dict->len; j++) {
                d.dict->keys[j - 1] = d.dict->keys[j];
                d.dict->vals[j - 1] = d.dict->vals[j];
            }
            d.dict->len--;
            return c4_num(1);
        }
    }
    return c4_num(0);
}
C4Val c4_ord(C4Val s) {
    if (s.t != 1 || s.str[0] == 0)
        c4_err("TypeError");
    return c4_num((unsigned char)s.str[0]);
}
C4Val c4_chr(C4Val n) {
    double x = c4_tonum(n);
    if (x != c4_trunc(x) || x < 0 || x > 0x10FFFF)
        c4_err("TypeError");
    unsigned c = (unsigned)x;
    if (c >= 0xD800 && c <= 0xDFFF)
        c4_err("TypeError");
    char buf[5];
    int m = 0;
    if (c < 0x80) {
        buf[0] = (char)c;
        m = 1;
    } else if (c < 0x800) {
        buf[0] = (char)(0xC0 | (c >> 6));
        buf[1] = (char)(0x80 | (c & 0x3F));
        m = 2;
    } else if (c < 0x10000) {
        buf[0] = (char)(0xE0 | (c >> 12));
        buf[1] = (char)(0x80 | ((c >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (c & 0x3F));
        m = 3;
    } else {
        buf[0] = (char)(0xF0 | (c >> 18));
        buf[1] = (char)(0x80 | ((c >> 12) & 0x3F));
        buf[2] = (char)(0x80 | ((c >> 6) & 0x3F));
        buf[3] = (char)(0x80 | (c & 0x3F));
        m = 4;
    }
    buf[m] = 0;
    return c4_str(buf);
}
