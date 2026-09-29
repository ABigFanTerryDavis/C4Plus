#ifndef C4RT_FS_H
#define C4RT_FS_H

/* Freestanding C4Plus runtime: no libc. Bump allocator, serial-style
 * byte output via c4_write (override it; default writes port 0xE9),
 * exit via c4_exit (writes QEMU isa-debug-exit port 0xF4). */

typedef unsigned long c4_size_t;

typedef enum { C4_NUM, C4_STR, C4_LIST, C4_DICT, C4_STRUCT, C4_NIL } C4Type;

typedef struct C4Val C4Val;
typedef struct {
    C4Val *items;
    c4_size_t len, cap;
} C4List;
typedef struct {
    char **keys;
    C4Val *vals;
    c4_size_t len, cap;
} C4Dict;
typedef struct {
    const char *tname;
    const char **fields;
    C4Val *vals;
    c4_size_t n;
} C4Struct;
struct C4Val {
    C4Type t;
    double num;
    char *str;
    C4List *list;
    C4Dict *dict;
    C4Struct *st;
};

void c4_write(const char *s, unsigned n);
void c4_halt(void);
void c4_err(const char *name);
void c4_fail(const char *msg);

C4Val c4_num(double n);
C4Val c4_str(const char *s);
C4Val c4_list(void);
C4Val c4_dict(void);
C4Val c4_struct(const char *tname, const char **fields, C4Val *vals, c4_size_t n);
C4Val c4_nil(void);

char *c4_tostring(C4Val v);
void c4_print(C4Val v);
int c4_truthy(C4Val v);
C4Val c4_add(C4Val a, C4Val b);
C4Val c4_sub(C4Val a, C4Val b);
C4Val c4_mul(C4Val a, C4Val b);
C4Val c4_div(C4Val a, C4Val b);
C4Val c4_mod(C4Val a, C4Val b);
int c4_eq(C4Val a, C4Val b);
int c4_lt(C4Val a, C4Val b);
C4Val c4_index(C4Val base, C4Val ix);
C4Val c4_index_set(C4Val base, C4Val ix, C4Val v);
C4Val c4_field(C4Val base, const char *f);
C4Val c4_field_set(C4Val base, const char *f, C4Val v);
C4Val c4_range(C4Val a, C4Val b);
C4Val c4_range(C4Val a, C4Val b);

C4Val c4_len(C4Val v);
C4Val c4_push(C4Val l, C4Val v);
C4Val c4_type(C4Val v);
C4Val c4_str_b(C4Val v);
C4Val c4_int(C4Val v);
C4Val c4_split(C4Val s, C4Val sep);
C4Val c4_join(C4Val l, C4Val sep);
C4Val c4_substr(C4Val s, C4Val a, C4Val b);
C4Val c4_trim(C4Val s);
C4Val c4_upper(C4Val s);
C4Val c4_lower(C4Val s);
C4Val c4_replace(C4Val s, C4Val o, C4Val nw);
C4Val c4_contains(C4Val h, C4Val n);
C4Val c4_abs(C4Val v);
C4Val c4_min(C4Val a, C4Val b);
C4Val c4_max(C4Val a, C4Val b);
C4Val c4_sqrt(C4Val v);
C4Val c4_floor(C4Val v);
C4Val c4_ceil(C4Val v);
C4Val c4_round(C4Val v);
C4Val c4_band(C4Val a, C4Val b);
C4Val c4_bor(C4Val a, C4Val b);
C4Val c4_bxor(C4Val a, C4Val b);
C4Val c4_bnot(C4Val v);
C4Val c4_shl(C4Val a, C4Val b);
C4Val c4_shr(C4Val a, C4Val b);
C4Val c4_bytes(C4Val n);
C4Val c4_peek(C4Val l, C4Val i);
C4Val c4_poke(C4Val l, C4Val i, C4Val v);
C4Val c4_pack(C4Val fmt, C4Val vals);
C4Val c4_unpack(C4Val fmt, C4Val data);
C4Val c4_sizeof(C4Val fmt);
C4Val c4_u8(C4Val v);
C4Val c4_u16(C4Val v);
C4Val c4_u32(C4Val v);
C4Val c4_i8(C4Val v);
C4Val c4_i16(C4Val v);
C4Val c4_i32(C4Val v);
C4Val c4_keys(C4Val d);
C4Val c4_del(C4Val d, C4Val k);
C4Val c4_ord(C4Val s);
C4Val c4_chr(C4Val n);
void c4_exit(C4Val code);
void c4_list_push(C4Val l, C4Val v);
void c4_dict_put(C4Val d, const char *k, C4Val v);
C4Val c4_outb(C4Val port, C4Val val);
C4Val c4_inb(C4Val port);
C4Val c4_inw(C4Val port);
C4Val c4_sti(void);
C4Val c4_cli(void);
C4Val c4_ticks(void);
C4Val c4_irq0_addr(void);
C4Val c4_irq1_addr(void);
C4Val c4_key(void);
C4Val c4_idt_set(C4Val vec, C4Val off, C4Val sel, C4Val attr);
C4Val c4_idt_load(void);
void c4_irq0(void);
void c4_irq1(void);
C4Val c4_poke32(C4Val addr, C4Val val);
C4Val c4_peek32(C4Val addr);
C4Val c4_cr3(C4Val addr);
C4Val c4_pg_on(void);
C4Val c4_kmalloc(C4Val n);
C4Val c4_kfree(C4Val addr);
C4Val c4_syscall_addr(void);
void c4_syscall_dispatch(unsigned *regs);
C4Val c4_syscall(C4Val num, C4Val a, C4Val b, C4Val c);
C4Val c4_addr(C4Val v);
C4Val c4_gdt_set(C4Val idx, C4Val base, C4Val limit, C4Val access, C4Val gran);
C4Val c4_gdt_load(void);
C4Val c4_tss_init(C4Val esp0);
C4Val c4_enter_user(C4Val entry, C4Val esp);
C4Val c4_elf_load(C4Val base);
C4Val c4_user_base(void);
C4Val c4_user_len(void);
C4Val c4_user2_base(void);
C4Val c4_user2_len(void);
void c4_fault(unsigned vec);
C4Val c4_fault_addr(C4Val vec);
unsigned c4_schedule(unsigned esp);
C4Val c4_task_create(C4Val entry, C4Val esp_top);
C4Val c4_tasks(void);
C4Val c4_idle(void);

#endif
