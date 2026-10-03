#ifndef C4RT_H
#define C4RT_H

#include <stddef.h>

typedef enum { C4_NUM, C4_STR, C4_LIST, C4_DICT, C4_STRUCT, C4_NIL, C4_FN } C4Type;

typedef struct C4Val C4Val;
typedef struct {
    C4Val *items;
    size_t len, cap;
} C4List;
typedef struct {
    char **keys;
    C4Val *vals;
    size_t len, cap;
} C4Dict;
typedef struct {
    const char *tname;
    const char **fields;
    C4Val *vals;
    size_t n;
} C4Struct;
struct C4Val {
    C4Type t;
    double num;
    char *str;
    C4List *list;
    C4Dict *dict;
    C4Struct *st;
};

extern int c4_argc;
extern char **c4_argv;
void c4_args_init(int argc, char **argv);

/* errors (stderr + exit 1, or longjmp when inside try) */
void c4_err(const char *name);
void c4_fail(const char *msg);

/* try/catch machinery (emitted code manages push/pop around setjmp) */
#include <setjmp.h>
jmp_buf *c4_try_push(void);
void c4_try_pop(void);
const char *c4_catch_msg(void);

/* constructors */
C4Val c4_num(double n);
C4Val c4_str(const char *s);
C4Val c4_strn(const char *s, size_t n);
C4Val c4_list(void);
C4Val c4_dict(void);
C4Val c4_struct(const char *tname, const char **fields, C4Val *vals, size_t n);
C4Val c4_nil(void);

/* core */
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

/* builtins */
C4Val c4_len(C4Val v);
C4Val c4_push(C4Val l, C4Val v);
C4Val c4_type(C4Val v);
C4Val c4_str_b(C4Val v);
C4Val c4_int(C4Val v);
C4Val c4_split(C4Val s, C4Val sep);
C4Val c4_join(C4Val l, C4Val sep);
C4Val c4_csv_parse(C4Val s, C4Val sep);
C4Val c4_csv_stringify(C4Val rows, C4Val sep);
C4Val c4_substr(C4Val s, C4Val start, C4Val count);
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
C4Val c4_pow(C4Val a, C4Val b);
C4Val c4_bits(C4Val v, C4Val hi, C4Val lo);
C4Val c4_setbits(C4Val v, C4Val hi, C4Val lo, C4Val f);
C4Val c4_flag(C4Val v, C4Val n);
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
C4Val c4_sin(C4Val v);
C4Val c4_cos(C4Val v);
C4Val c4_tan(C4Val v);
C4Val c4_asin(C4Val v);
C4Val c4_acos(C4Val v);
C4Val c4_atan(C4Val v);
C4Val c4_log(C4Val v);
C4Val c4_log10(C4Val v);
C4Val c4_exp(C4Val v);
C4Val c4_deg(C4Val v);
C4Val c4_rad(C4Val v);
C4Val c4_pi(void);
C4Val c4_e(void);
C4Val c4_heap_calloc(C4Val h, C4Val n);
C4Val c4_heap_realloc(C4Val h, C4Val a, C4Val n);
C4Val c4_heap_dump(C4Val h);
C4Val c4_heap_new(C4Val n);
C4Val c4_heap_malloc(C4Val h, C4Val n);
C4Val c4_heap_free(C4Val h, C4Val a);
C4Val c4_heap_stats(C4Val h);
C4Val c4_mem_arena(C4Val n);
C4Val c4_mem_pool(C4Val o, C4Val c);
C4Val c4_mem_alloc(C4Val h, C4Val n);
C4Val c4_mem_acquire(C4Val h);
C4Val c4_mem_release(C4Val h, C4Val i);
C4Val c4_mem_read_u8(C4Val h, C4Val o);
C4Val c4_mem_read_u16(C4Val h, C4Val o);
C4Val c4_mem_read_u32(C4Val h, C4Val o);
C4Val c4_mem_write_u8(C4Val h, C4Val o, C4Val v);
C4Val c4_mem_write_u16(C4Val h, C4Val o, C4Val v);
C4Val c4_mem_write_u32(C4Val h, C4Val o, C4Val v);
C4Val c4_mem_fill(C4Val h, C4Val o, C4Val n, C4Val b);
C4Val c4_mem_copy(C4Val h, C4Val d, C4Val s, C4Val n);
C4Val c4_mem_usage(C4Val h);
C4Val c4_mem_reset(C4Val h);
C4Val c4_block_ramdisk(C4Val n);
C4Val c4_block_file(C4Val p, C4Val n);
C4Val c4_block_read(C4Val h, C4Val l);
C4Val c4_block_write(C4Val h, C4Val l, C4Val data);
C4Val c4_block_read_text(C4Val h, C4Val l);
C4Val c4_block_write_text(C4Val h, C4Val l, C4Val t);
C4Val c4_block_sectors(C4Val h);
C4Val c4_block_flush(C4Val h);
C4Val c4_block_close(C4Val h);
C4Val c4_block_copy(C4Val h, C4Val d, C4Val s, C4Val n);
C4Val c4_block_fill(C4Val h, C4Val l, C4Val n, C4Val b);
C4Val c4_block_stats(C4Val h);
C4Val c4_fat_format(C4Val h);
C4Val c4_fat_ls(C4Val h);
C4Val c4_fat_read(C4Val h, C4Val n);
C4Val c4_fat_read_text(C4Val h, C4Val n);
C4Val c4_fat_write(C4Val h, C4Val n, C4Val data);
C4Val c4_fat_write_text(C4Val h, C4Val n, C4Val t);
C4Val c4_fat_delete(C4Val h, C4Val n);
C4Val c4_args_flag(C4Val n);
C4Val c4_args_opt(C4Val n, C4Val d);
C4Val c4_args_rest(void);
C4Val c4_path_join(C4Val l);
C4Val c4_path_split(C4Val p);
C4Val c4_path_dir(C4Val p);
C4Val c4_path_base(C4Val p);
C4Val c4_path_ext(C4Val p);
C4Val c4_path_stem(C4Val p);
C4Val c4_path_isabs(C4Val p);
C4Val c4_path_norm(C4Val p);
C4Val c4_path_short(C4Val n);
C4Val c4_path_is83(C4Val n);
void c4_list_push(C4Val l, C4Val v);
void c4_dict_put(C4Val d, const char *k, C4Val v);
C4Val c4_band(C4Val a, C4Val b);
C4Val c4_bor(C4Val a, C4Val b);
C4Val c4_bxor(C4Val a, C4Val b);
C4Val c4_bnot(C4Val v);
C4Val c4_shl(C4Val a, C4Val b);
C4Val c4_shr(C4Val a, C4Val b);
C4Val c4_range(C4Val a, C4Val b);
C4Val c4_input(C4Val prompt, int has_prompt);
C4Val c4_args(void);
void c4_exit(C4Val code);

/* os */
C4Val c4_os_create(C4Val p, C4Val d);
C4Val c4_os_read(C4Val p);
C4Val c4_os_append(C4Val p, C4Val d);
C4Val c4_os_exists(C4Val p);
C4Val c4_os_remove(C4Val p);
C4Val c4_os_edit(C4Val p, C4Val o, C4Val n);
C4Val c4_os_readbytes(C4Val p);
C4Val c4_os_writebytes(C4Val p, C4Val l);
C4Val c4_os_cwd(void);
C4Val c4_os_env(C4Val k);
C4Val c4_os_listdir(C4Val p);
C4Val c4_os_mkdir(C4Val p);

/* physics */
C4Val c4_ph_g(void);
C4Val c4_ph_fall(C4Val d);
C4Val c4_ph_range(C4Val v, C4Val deg);
C4Val c4_ph_height(C4Val v, C4Val deg);
C4Val c4_ph_dist(C4Val a, C4Val b, C4Val c, C4Val d);
C4Val c4_ph_speed(C4Val d, C4Val t);
C4Val c4_ph_energy(C4Val m, C4Val v);

/* time */
C4Val c4_tm_now(void);
C4Val c4_tm_stamp(void);
C4Val c4_tm_sleep(C4Val s);

/* json */
C4Val c4_json_parse(C4Val s);
C4Val c4_json_stringify(C4Val v);

/* hex */
C4Val c4_hex_encode(C4Val v);
C4Val c4_hex_decode(C4Val s);
C4Val c4_hex_dump(C4Val v);
C4Val c4_hex_word(C4Val n);
C4Val c4_hex_parse(C4Val s);

/* random */
C4Val c4_random_seed(C4Val v);
C4Val c4_random_int(C4Val n);
C4Val c4_random_int2(C4Val a, C4Val b);
C4Val c4_random_float(void);
C4Val c4_random_float2(C4Val a, C4Val b);
C4Val c4_random_chance(C4Val p);
C4Val c4_random_pick(C4Val v);
C4Val c4_random_shuffle(C4Val l);

/* misc */
C4Val c4_crc32(C4Val v);
C4Val c4_sort(C4Val l);
C4Val c4_reverse(C4Val v);
C4Val c4_sum(C4Val l);
C4Val c4_min_of(C4Val l);
C4Val c4_max_of(C4Val l);
C4Val c4_indexof(C4Val h, C4Val n);
C4Val c4_count(C4Val h, C4Val n);
C4Val c4_any(C4Val l);
C4Val c4_all(C4Val l);
C4Val c4_unique(C4Val l);
C4Val c4_fname(C4Val v);

/* strings extras */
C4Val c4_strings_starts_with(C4Val s, C4Val p);
C4Val c4_strings_ends_with(C4Val s, C4Val p);
C4Val c4_strings_find(C4Val s, C4Val p);
C4Val c4_strings_pad_left(C4Val s, C4Val w, C4Val ch);
C4Val c4_strings_pad_right(C4Val s, C4Val w, C4Val ch);
C4Val c4_strings_repeat(C4Val s, C4Val n);
C4Val c4_strings_replace_all(C4Val s, C4Val o, C4Val nw);
C4Val c4_strings_lines(C4Val s);

/* time extras */
C4Val c4_tm_ms(void);
C4Val c4_tm_epoch_ms(void);
C4Val c4_tm_clock(void);

/* function values (compiled): id in num, name in str.
   c4_callN dispatchers are generated per-program by --emit-c. */
C4Val c4_fnval(const char *name, double id);
C4Val c4_fname(C4Val v);

/* sim cpu machine */
C4Val c4_cpu_new(C4Val n);
C4Val c4_cpu_reg(C4Val m, C4Val r);
C4Val c4_cpu_setreg(C4Val m, C4Val r, C4Val v);
C4Val c4_cpu_load(C4Val m, C4Val a);
C4Val c4_cpu_store(C4Val m, C4Val a, C4Val v);
C4Val c4_cpu_step(C4Val m, C4Val op, C4Val a, C4Val b);
C4Val c4_cpu_run(C4Val m, C4Val prog);

#endif
