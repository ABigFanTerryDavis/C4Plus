#define _CRT_SECURE_NO_WARNINGS
#include "c4rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <time.h>
#include <setjmp.h>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <windows.h>
#define c4_mkdir(p) _mkdir(p)
#define c4_access(p) _access(p, 0)
#else
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#define c4_mkdir(p) mkdir(p, 0755)
#define c4_access(p) access(p, F_OK)
#endif

int c4_argc = 0;
char **c4_argv = NULL;
void c4_args_init(int argc, char **argv) {
    c4_argc = argc - 1;
    c4_argv = argv + 1;
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) {
        fprintf(stderr, "error: OutOfMemory\n");
        exit(1);
    }
    return p;
}
static char *xdup(const char *s) {
    size_t n = strlen(s);
    char *p = xmalloc(n + 1);
    memcpy(p, s, n + 1);
    return p;
}
static char *xdupn(const char *s, size_t n) {
    char *p = xmalloc(n + 1);
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}

void c4_err(const char *name);
void c4_fail(const char *msg);

#define C4_TRY_MAX 16
static jmp_buf c4_try_stack[C4_TRY_MAX];
static int c4_try_depth = 0;
static char c4_try_msg[256];

jmp_buf *c4_try_push(void) {
    if (c4_try_depth >= C4_TRY_MAX) {
        fprintf(stderr, "error: TryDepthExceeded\n");
        exit(1);
    }
    return &c4_try_stack[c4_try_depth++];
}
void c4_try_pop(void) {
    if (c4_try_depth > 0) c4_try_depth--;
}
const char *c4_catch_msg(void) {
    return c4_try_msg;
}

void c4_err(const char *name) {
    if (c4_try_depth > 0) {
        strncpy(c4_try_msg, name, sizeof(c4_try_msg) - 1);
        c4_try_msg[sizeof(c4_try_msg) - 1] = 0;
        longjmp(c4_try_stack[c4_try_depth - 1], 1);
    }
    fprintf(stderr, "error: %s\n", name);
    exit(1);
}
void c4_fail(const char *msg) {
    if (c4_try_depth > 0) {
        strncpy(c4_try_msg, msg ? msg : "", sizeof(c4_try_msg) - 1);
        c4_try_msg[sizeof(c4_try_msg) - 1] = 0;
        longjmp(c4_try_stack[c4_try_depth - 1], 2);
    }
    fprintf(stderr, "fail: %s\n", msg ? msg : "");
    exit(1);
}

C4Val c4_num(double n) {
    C4Val v;
    v.t = C4_NUM;
    v.num = n;
    return v;
}
C4Val c4_str(const char *s) {
    C4Val v;
    v.t = C4_STR;
    v.str = xdup(s);
    return v;
}
C4Val c4_strn(const char *s, size_t n) {
    C4Val v;
    v.t = C4_STR;
    v.str = xdupn(s, n);
    return v;
}
C4Val c4_list(void) {
    C4Val v;
    v.t = C4_LIST;
    v.list = xmalloc(sizeof(C4List));
    v.list->items = NULL;
    v.list->len = v.list->cap = 0;
    return v;
}
C4Val c4_dict(void) {
    C4Val v;
    v.t = C4_DICT;
    v.dict = xmalloc(sizeof(C4Dict));
    v.dict->keys = NULL;
    v.dict->vals = NULL;
    v.dict->len = v.dict->cap = 0;
    return v;
}
C4Val c4_struct(const char *tname, const char **fields, C4Val *vals, size_t n) {
    C4Val v;
    v.t = C4_STRUCT;
    v.st = xmalloc(sizeof(C4Struct));
    v.st->tname = tname;
    v.st->fields = xmalloc(sizeof(char *) * (n ? n : 1));
    v.st->vals = xmalloc(sizeof(C4Val) * (n ? n : 1));
    for (size_t i = 0; i < n; i++) {
        v.st->fields[i] = fields[i];
        v.st->vals[i] = vals[i];
    }
    v.st->n = n;
    return v;
}
C4Val c4_nil(void) {
    C4Val v;
    v.t = C4_NIL;
    v.num = 0;
    return v;
}

static void list_grow(C4List *l) {
    if (l->len >= l->cap) {
        l->cap = l->cap ? l->cap * 2 : 8;
        l->items = realloc(l->items, sizeof(C4Val) * l->cap);
        if (!l->items) c4_err("OutOfMemory");
    }
}
static void list_push(C4List *l, C4Val v) {
    list_grow(l);
    l->items[l->len++] = v;
}
static void dict_put(C4Dict *d, const char *k, C4Val v) {
    for (size_t i = 0; i < d->len; i++) {
        if (strcmp(d->keys[i], k) == 0) {
            d->vals[i] = v;
            return;
        }
    }
    if (d->len >= d->cap) {
        d->cap = d->cap ? d->cap * 2 : 8;
        d->keys = realloc(d->keys, sizeof(char *) * d->cap);
        d->vals = realloc(d->vals, sizeof(C4Val) * d->cap);
        if (!d->keys || !d->vals) c4_err("OutOfMemory");
    }
    d->keys[d->len] = xdup(k);
    d->vals[d->len] = v;
    d->len++;
}

char *c4_tostring(C4Val v) {
    char buf[64];
    switch (v.t) {
    case C4_NUM: {
        double n = v.num;
        if (n == trunc(n) && fabs(n) < 9007199254740991.0) {
            snprintf(buf, sizeof buf, "%lld", (long long)n);
            return xdup(buf);
        } else {
            /* shortest round-trip, like the interpreter */
            char b2[40];
            for (int p = 1; p <= 17; p++) {
                snprintf(b2, sizeof b2, "%.*g", p, n);
                if (strtod(b2, NULL) == n) {
                    snprintf(buf, sizeof buf, "%s", b2);
                    return xdup(buf);
                }
            }
            snprintf(buf, sizeof buf, "%.17g", n);
            return xdup(buf);
        }
    }
    case C4_STR:
        return xdup(v.str);
    case C4_FN: {
        char buf[256];
        snprintf(buf, sizeof buf, "<fn %s>", v.str ? v.str : "?");
        return xdup(buf);
    }
    case C4_NIL:
        return xdup("nil");
    case C4_LIST: {
        size_t cap = 64, len = 0;
        char *o = xmalloc(cap);
        o[len++] = '[';
        for (size_t i = 0; i < v.list->len; i++) {
            char *s = c4_tostring(v.list->items[i]);
            size_t sl = strlen(s);
            if (i > 0) {
                if (len + 2 >= cap) {
                    cap *= 2;
                    o = realloc(o, cap);
                }
                o[len++] = ',';
                o[len++] = ' ';
            }
            while (len + sl + 2 >= cap) {
                cap *= 2;
                o = realloc(o, cap);
            }
            memcpy(o + len, s, sl);
            len += sl;
            free(s);
        }
        o[len++] = ']';
        o[len] = 0;
        return o;
    }
    case C4_DICT: {
        size_t cap = 64, len = 0;
        char *o = xmalloc(cap);
        o[len++] = '{';
        for (size_t i = 0; i < v.dict->len; i++) {
            char *ks = v.dict->keys[i];
            char *vs = c4_tostring(v.dict->vals[i]);
            size_t need = strlen(ks) + strlen(vs) + 8;
            while (len + need >= cap) {
                cap *= 2;
                o = realloc(o, cap);
            }
            if (i > 0) {
                o[len++] = ',';
                o[len++] = ' ';
            }
            o[len++] = '"';
            size_t kl = strlen(ks);
            memcpy(o + len, ks, kl);
            len += kl;
            o[len++] = '"';
            o[len++] = ':';
            o[len++] = ' ';
            size_t vl = strlen(vs);
            memcpy(o + len, vs, vl);
            len += vl;
            free(vs);
        }
        o[len++] = '}';
        o[len] = 0;
        return o;
    }
    case C4_STRUCT: {
        size_t cap = 64, len = 0;
        char *o = xmalloc(cap);
        size_t tl = strlen(v.st->tname);
        while (len + tl + 4 >= cap) {
            cap *= 2;
            o = realloc(o, cap);
        }
        memcpy(o + len, v.st->tname, tl);
        len += tl;
        o[len++] = '{';
        for (size_t i = 0; i < v.st->n; i++) {
            char *vs = c4_tostring(v.st->vals[i]);
            size_t need = strlen(v.st->fields[i]) + strlen(vs) + 6;
            while (len + need >= cap) {
                cap *= 2;
                o = realloc(o, cap);
            }
            if (i > 0) {
                o[len++] = ',';
                o[len++] = ' ';
            }
            size_t fl = strlen(v.st->fields[i]);
            memcpy(o + len, v.st->fields[i], fl);
            len += fl;
            o[len++] = ':';
            o[len++] = ' ';
            size_t vl = strlen(vs);
            memcpy(o + len, vs, vl);
            len += vl;
            free(vs);
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
    printf("%s\n", s);
    free(s);
}
int c4_truthy(C4Val v) {
    switch (v.t) {
    case C4_NUM:
        return v.num != 0;
    case C4_STR:
        return v.str[0] != 0;
    case C4_LIST:
        return v.list->len > 0;
    case C4_DICT:
        return v.dict->len > 0;
    case C4_STRUCT:
        return 1;
    case C4_FN:
        return 1;
    case C4_NIL:
        return 0;
    }
    return 0;
}
static void need_num(C4Val v, const char *op) {
    if (v.t != C4_NUM) {
        (void)op;
        c4_err("TypeError");
    }
}
C4Val c4_add(C4Val a, C4Val b) {
    if (a.t == C4_LIST && b.t == C4_LIST) {
        C4Val o = c4_list();
        for (size_t i = 0; i < a.list->len; i++)
            list_push(o.list, a.list->items[i]);
        for (size_t i = 0; i < b.list->len; i++)
            list_push(o.list, b.list->items[i]);
        return o;
    }
    if (a.t == C4_STR || b.t == C4_STR) {
        char *x = c4_tostring(a), *y = c4_tostring(b);
        size_t n = strlen(x) + strlen(y);
        char *o = xmalloc(n + 1);
        memcpy(o, x, strlen(x));
        memcpy(o + strlen(x), y, strlen(y) + 1);
        free(x);
        free(y);
        C4Val v;
        v.t = C4_STR;
        v.str = o;
        return v;
    }
    if (a.t == C4_DICT || b.t == C4_DICT || a.t == C4_STRUCT || b.t == C4_STRUCT || a.t == C4_NIL || b.t == C4_NIL) {
        if ((a.t == C4_LIST || b.t == C4_LIST) || (a.t == C4_DICT || b.t == C4_DICT) || (a.t == C4_STRUCT || b.t == C4_STRUCT) || (a.t == C4_NIL || b.t == C4_NIL))
            c4_err("TypeError");
    }
    need_num(a, "+");
    need_num(b, "+");
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
    if (b.num == 0) c4_err("DivisionByZero");
    return c4_num(a.num / b.num);
}
C4Val c4_mod(C4Val a, C4Val b) {
    need_num(a, "%");
    need_num(b, "%");
    if (b.num == 0) c4_err("DivisionByZero");
    return c4_num(fmod(a.num, b.num));
}
int c4_eq(C4Val a, C4Val b) {
    if (a.t == C4_NUM && b.t == C4_NUM)
        return a.num == b.num;
    if (a.t == C4_STR && b.t == C4_STR)
        return strcmp(a.str, b.str) == 0;
    if (a.t == C4_LIST && b.t == C4_LIST) {
        if (a.list->len != b.list->len)
            return 0;
        for (size_t i = 0; i < a.list->len; i++)
            if (!c4_eq(a.list->items[i], b.list->items[i]))
                return 0;
        return 1;
    }
    if (a.t == C4_DICT && b.t == C4_DICT) {
        if (a.dict->len != b.dict->len)
            return 0;
        for (size_t i = 0; i < a.dict->len; i++) {
            int found = 0;
            for (size_t j = 0; j < b.dict->len; j++) {
                if (strcmp(a.dict->keys[i], b.dict->keys[j]) == 0) {
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
    if (a.t == C4_STRUCT && b.t == C4_STRUCT) {
        if (strcmp(a.st->tname, b.st->tname) != 0 || a.st->n != b.st->n)
            return 0;
        for (size_t i = 0; i < a.st->n; i++) {
            if (strcmp(a.st->fields[i], b.st->fields[i]) != 0)
                return 0;
            if (!c4_eq(a.st->vals[i], b.st->vals[i]))
                return 0;
        }
        return 1;
    }
    if (a.t == C4_FN && b.t == C4_FN)
        return a.num == b.num;
    if (a.t == C4_NIL && b.t == C4_NIL)
        return 1;
    if (a.t == C4_NIL || b.t == C4_NIL)
        return 0;
    {
        char *x = c4_tostring(a), *y = c4_tostring(b);
        int r = strcmp(x, y) == 0;
        free(x);
        free(y);
        return r;
    }
}
int c4_lt(C4Val a, C4Val b) {
    if ((a.t != C4_NUM || b.t != C4_NUM) && (a.t != C4_STR || b.t != C4_STR)) {
        if (a.t == C4_NUM && b.t == C4_NUM) {
        } else if (a.t == C4_STR && b.t == C4_STR) {
        } else
            c4_err("TypeError");
    }
    if (a.t == C4_NUM)
        return a.num < b.num;
    return strcmp(a.str, b.str) < 0;
}
static long c4_index_of(C4Val l, C4Val ix) {
    if (ix.t != C4_NUM || ix.num != trunc(ix.num))
        c4_err("TypeError");
    long i = (long)ix.num;
    long n = (long)l.list->len;
    if (i < 0)
        i += n;
    if (i < 0 || i >= n)
        c4_err("IndexOutOfBounds");
    return i;
}
C4Val c4_index(C4Val base, C4Val ix) {
    if (base.t == C4_LIST)
        return base.list->items[c4_index_of(base, ix)];
    if (base.t == C4_STR) {
        if (ix.t != C4_NUM || ix.num != trunc(ix.num))
            c4_err("TypeError");
        long i = (long)ix.num, n = (long)strlen(base.str);
        if (i < 0)
            i += n;
        if (i < 0 || i >= n)
            c4_err("IndexOutOfBounds");
        return c4_strn(base.str + i, 1);
    }
    if (base.t == C4_DICT) {
        char *k = c4_tostring(ix);
        for (size_t i = 0; i < base.dict->len; i++)
            if (strcmp(base.dict->keys[i], k) == 0) {
                free(k);
                return base.dict->vals[i];
            }
        free(k);
        c4_err("KeyMissing");
    }
    if (base.t == C4_STR)
        c4_err("TypeError");
    c4_err("NotIndexable");
    return c4_nil();
}
C4Val c4_index_set(C4Val base, C4Val ix, C4Val v) {
    if (base.t == C4_LIST) {
        base.list->items[c4_index_of(base, ix)] = v;
        return base;
    }
    if (base.t == C4_STR) {
        if (ix.t != C4_NUM || ix.num != trunc(ix.num))
            c4_err("TypeError");
        long i = (long)ix.num, n = (long)strlen(base.str);
        if (i < 0)
            i += n;
        if (i < 0 || i >= n)
            c4_err("IndexOutOfBounds");
        if (v.t != C4_STR || strlen(v.str) != 1)
            c4_err("TypeError");
        char *o = xdup(base.str);
        o[i] = v.str[0];
        C4Val nv;
        nv.t = C4_STR;
        nv.str = o;
        return nv;
    }
    if (base.t == C4_DICT) {
        char *k = c4_tostring(ix);
        dict_put(base.dict, k, v);
        free(k);
        return base;
    }
    c4_err("NotIndexable");
    return base;
}
C4Val c4_field(C4Val base, const char *f) {
    if (base.t != C4_STRUCT)
        c4_err("TypeError");
    for (size_t i = 0; i < base.st->n; i++)
        if (strcmp(base.st->fields[i], f) == 0)
            return base.st->vals[i];
    (void)f;
    c4_err("TypeError");
    return c4_nil();
}
C4Val c4_field_set(C4Val base, const char *f, C4Val v) {
    if (base.t != C4_STRUCT)
        c4_err("TypeError");
    for (size_t i = 0; i < base.st->n; i++)
        if (strcmp(base.st->fields[i], f) == 0) {
            base.st->vals[i] = v;
            return base;
        }
    (void)f;
    c4_err("TypeError");
    return base;
}
C4Val c4_range(C4Val a, C4Val b) {
    need_num(a, "..");
    need_num(b, "..");
    if (a.num != trunc(a.num) || b.num != trunc(b.num))
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
    case C4_STR:
        return c4_num((double)strlen(v.str));
    case C4_LIST:
        return c4_num((double)v.list->len);
    case C4_DICT:
        return c4_num((double)v.dict->len);
    default:
        c4_err("TypeError");
    }
    return c4_nil();
}
C4Val c4_push(C4Val l, C4Val v) {
    if (l.t != C4_LIST)
        c4_err("TypeError");
    list_push(l.list, v);
    return c4_num((double)l.list->len);
}
C4Val c4_type(C4Val v) {
    switch (v.t) {
    case C4_NUM:
        return c4_str("number");
    case C4_STR:
        return c4_str("string");
    case C4_LIST:
        return c4_str("list");
    case C4_DICT:
        return c4_str("dict");
    case C4_FN:
        return c4_str("function");
    case C4_NIL:
        return c4_str("nil");
    case C4_STRUCT:
        return c4_str(v.st->tname);
    }
    return c4_str("?");
}
C4Val c4_str_b(C4Val v) {
    char *s = c4_tostring(v);
    C4Val o;
    o.t = C4_STR;
    o.str = s;
    return o;
}
C4Val c4_int(C4Val v) {
    if (v.t == C4_NUM)
        return c4_num(trunc(v.num));
    if (v.t == C4_STR) {
        char *e;
        double n = strtod(v.str, &e);
        if (e == v.str)
            c4_err("BadNumber");
        return c4_num(trunc(n));
    }
    c4_err("TypeError");
    return c4_nil();
}
C4Val c4_split(C4Val s, C4Val sep) {
    if (s.t != C4_STR || sep.t != C4_STR)
        c4_err("TypeError");
    C4Val o = c4_list();
    if (sep.str[0] == 0) {
        for (const unsigned char *p = (unsigned char *)s.str; *p; p++) {
            char tmp[2] = {(char)*p, 0};
            list_push(o.list, c4_str(tmp));
        }
        return o;
    }
    const char *rest = s.str;
    size_t sl = strlen(sep.str);
    const char *f;
    while ((f = strstr(rest, sep.str)) != NULL) {
        list_push(o.list, c4_strn(rest, (size_t)(f - rest)));
        rest = f + sl;
    }
    list_push(o.list, c4_str(rest));
    return o;
}
C4Val c4_join(C4Val l, C4Val sep) {
    if (l.t != C4_LIST)
        c4_err("TypeError");
    char *s = c4_tostring(sep);
    size_t cap = 64, len = 0;
    char *o = xmalloc(cap);
    o[0] = 0;
    for (size_t i = 0; i < l.list->len; i++) {
        char *p = c4_tostring(l.list->items[i]);
        size_t need = len + strlen(p) + strlen(s) + 2;
        while (need >= cap) {
            cap *= 2;
            o = realloc(o, cap);
        }
        if (i > 0) {
            memcpy(o + len, s, strlen(s));
            len += strlen(s);
        }
        memcpy(o + len, p, strlen(p));
        len += strlen(p);
        o[len] = 0;
        free(p);
    }
    free(s);
    C4Val v;
    v.t = C4_STR;
    v.str = o;
    return v;
}
static void csv_push_field(C4Val row, char *buf, size_t len) {
    char *s = xmalloc(len + 1);
    memcpy(s, buf, len);
    s[len] = 0;
    C4Val f;
    f.t = C4_STR;
    f.str = s;
    list_push(row.list, f);
}
C4Val c4_csv_parse(C4Val s, C4Val sep) {
    if (s.t != C4_STR || sep.t != C4_STR || strlen(sep.str) != 1)
        c4_err("TypeError");
    char d = sep.str[0];
    C4Val rows = c4_list();
    C4Val cur = c4_list();
    size_t cap = 64, len = 0;
    char *buf = xmalloc(cap);
    int inq = 0, started = 0;
    size_t rowlen = 0;
    const char *p = s.str;
    for (;;) {
        int at_end = *p == 0;
        char ch = *p;
        if (!at_end && inq) {
            if (ch == '"') {
                if (p[1] == '"') {
                    if (len + 1 >= cap) {
                        cap *= 2;
                        buf = realloc(buf, cap);
                    }
                    buf[len++] = '"';
                    p += 2;
                    continue;
                }
                inq = 0;
                p++;
                continue;
            }
            if (len + 1 >= cap) {
                cap *= 2;
                buf = realloc(buf, cap);
            }
            buf[len++] = ch;
            p++;
            continue;
        }
        if (!at_end && ch == '"') {
            inq = 1;
            started = 1;
            p++;
            continue;
        }
        if (!at_end && ch == d) {
            csv_push_field(cur, buf, len);
            len = 0;
            rowlen++;
            started = 0;
            p++;
            continue;
        }
        if (!at_end && (ch == '\n' || ch == '\r')) {
            csv_push_field(cur, buf, len);
            len = 0;
            rowlen++;
            started = 0;
            list_push(rows.list, cur);
            cur = c4_list();
            rowlen = 0;
            if (ch == '\r' && p[1] == '\n')
                p++;
            p++;
            continue;
        }
        if (at_end) {
            if (len > 0 || rowlen > 0 || started) {
                csv_push_field(cur, buf, len);
                list_push(rows.list, cur);
            }
            break;
        }
        if (len + 1 >= cap) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
        buf[len++] = ch;
        started = 1;
        p++;
    }
    free(buf);
    return rows;
}
C4Val c4_csv_stringify(C4Val rows, C4Val sep) {
    if (rows.t != C4_LIST || sep.t != C4_STR || strlen(sep.str) != 1)
        c4_err("TypeError");
    char d = sep.str[0];
    size_t cap = 64, len = 0;
    char *o = xmalloc(cap);
    for (size_t ri = 0; ri < rows.list->len; ri++) {
        C4Val row = rows.list->items[ri];
        if (row.t != C4_LIST)
            c4_err("TypeError");
        if (ri > 0) {
            if (len + 1 >= cap) {
                cap *= 2;
                o = realloc(o, cap);
            }
            o[len++] = '\n';
        }
        for (size_t fi = 0; fi < row.list->len; fi++) {
            char *s = c4_tostring(row.list->items[fi]);
            size_t sl = strlen(s);
            int need = 0;
            for (size_t k = 0; k < sl; k++) {
                if (s[k] == d || s[k] == '"' || s[k] == '\n' || s[k] == '\r') {
                    need = 1;
                    break;
                }
            }
            size_t extra = need ? 2 : 0;
            for (size_t k = 0; k < sl; k++)
                if (s[k] == '"')
                    extra++;
            while (len + sl + extra + 2 >= cap) {
                cap *= 2;
                o = realloc(o, cap);
            }
            if (fi > 0)
                o[len++] = d;
            if (need)
                o[len++] = '"';
            for (size_t k = 0; k < sl; k++) {
                if (s[k] == '"')
                    o[len++] = '"';
                o[len++] = s[k];
            }
            if (need)
                o[len++] = '"';
            free(s);
        }
    }
    o[len] = 0;
    C4Val v;
    v.t = C4_STR;
    v.str = o;
    return v;
}
C4Val c4_substr(C4Val s, C4Val a, C4Val b) {
    if (s.t != C4_STR || a.t != C4_NUM || b.t != C4_NUM)
        c4_err("TypeError");
    long n = (long)strlen(s.str);
    long st = (long)a.num, co = (long)b.num;
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
    return c4_strn(s.str + st, (size_t)(en - st));
}
C4Val c4_trim(C4Val s) {
    if (s.t != C4_STR)
        c4_err("TypeError");
    const char *a = s.str, *b = s.str + strlen(s.str);
    while (a < b && (*a == ' ' || *a == '\t' || *a == '\r' || *a == '\n'))
        a++;
    while (b > a && (b[-1] == ' ' || b[-1] == '\t' || b[-1] == '\r' || b[-1] == '\n'))
        b--;
    return c4_strn(a, (size_t)(b - a));
}
static C4Val c4_case(C4Val s, int up) {
    if (s.t != C4_STR)
        c4_err("TypeError");
    char *o = xdup(s.str);
    for (char *p = o; *p; p++)
        *p = up ? (char)toupper((unsigned char)*p) : (char)tolower((unsigned char)*p);
    C4Val v;
    v.t = C4_STR;
    v.str = o;
    return v;
}
C4Val c4_upper(C4Val s) {
    return c4_case(s, 1);
}
C4Val c4_lower(C4Val s) {
    return c4_case(s, 0);
}
C4Val c4_replace(C4Val s, C4Val o, C4Val nw) {
    if (s.t != C4_STR || o.t != C4_STR || nw.t != C4_STR)
        c4_err("TypeError");
    if (o.str[0] == 0)
        return c4_str(s.str);
    size_t cap = strlen(s.str) + 1, len = 0;
    char *out = xmalloc(cap);
    const char *rest = s.str;
    size_t ol = strlen(o.str), nl = strlen(nw.str);
    const char *f;
    while ((f = strstr(rest, o.str)) != NULL) {
        size_t pre = (size_t)(f - rest);
        while (len + pre + nl + 1 >= cap) {
            cap *= 2;
            out = realloc(out, cap);
        }
        memcpy(out + len, rest, pre);
        len += pre;
        memcpy(out + len, nw.str, nl);
        len += nl;
        rest = f + ol;
    }
    size_t rl = strlen(rest);
    while (len + rl + 1 >= cap) {
        cap *= 2;
        out = realloc(out, cap);
    }
    memcpy(out + len, rest, rl + 1);
    C4Val v;
    v.t = C4_STR;
    v.str = out;
    return v;
}
C4Val c4_contains(C4Val h, C4Val n) {
    char *x = c4_tostring(h), *y = c4_tostring(n);
    int r = strstr(x, y) != NULL;
    free(x);
    free(y);
    return c4_num(r);
}
C4Val c4_abs(C4Val v) {
    need_num(v, "abs");
    return c4_num(fabs(v.num));
}
C4Val c4_min(C4Val a, C4Val b) {
    need_num(a, "min");
    need_num(b, "min");
    return c4_num(a.num < b.num ? a.num : b.num);
}
C4Val c4_max(C4Val a, C4Val b) {
    need_num(a, "max");
    need_num(b, "max");
    return c4_num(a.num > b.num ? a.num : b.num);
}
C4Val c4_sqrt(C4Val v) {
    need_num(v, "sqrt");
    if (v.num < 0)
        c4_err("MathError");
    return c4_num(sqrt(v.num));
}
C4Val c4_floor(C4Val v) {
    need_num(v, "floor");
    return c4_num(floor(v.num));
}
C4Val c4_ceil(C4Val v) {
    need_num(v, "ceil");
    return c4_num(ceil(v.num));
}
C4Val c4_round(C4Val v) {
    need_num(v, "round");
    return c4_num(round(v.num));
}
C4Val c4_pow(C4Val a, C4Val b) {
    need_num(a, "pow");
    need_num(b, "pow");
    return c4_num(pow(a.num, b.num));
}
void c4_list_push(C4Val l, C4Val v) {
    if (l.t != C4_LIST)
        c4_err("TypeError");
    list_push(l.list, v);
}
void c4_dict_put(C4Val d, const char *k, C4Val v) {
    if (d.t != C4_DICT)
        c4_err("TypeError");
    dict_put(d.dict, k, v);
}
static long long c4_int64(C4Val v) {
    if (v.t != C4_NUM || v.num != trunc(v.num) || fabs(v.num) >= 9223372036854775808.0)
        c4_err("TypeError");
    return (long long)v.num;
}
C4Val c4_band(C4Val a, C4Val b) {
    return c4_num((double)(long long)((unsigned long long)c4_int64(a) & (unsigned long long)c4_int64(b)));
}
C4Val c4_bor(C4Val a, C4Val b) {
    return c4_num((double)(long long)((unsigned long long)c4_int64(a) | (unsigned long long)c4_int64(b)));
}
C4Val c4_bxor(C4Val a, C4Val b) {
    return c4_num((double)(long long)((unsigned long long)c4_int64(a) ^ (unsigned long long)c4_int64(b)));
}
C4Val c4_bnot(C4Val v) {
    return c4_num((double)(long long)(~(unsigned long long)c4_int64(v)));
}
C4Val c4_shl(C4Val a, C4Val b) {
    long long x = c4_int64(a), s = c4_int64(b);
    if (s < 0 || s > 63)
        c4_err("TypeError");
    return c4_num((double)(long long)(((unsigned long long)x << (unsigned)s) & 0xFFFFFFFFFFFFFFFFULL));
}
C4Val c4_shr(C4Val a, C4Val b) {
    long long x = c4_int64(a), s = c4_int64(b);
    if (s < 0 || s > 63)
        c4_err("TypeError");
    return c4_num((double)(x >> s));
}
C4Val c4_bits(C4Val v, C4Val hi, C4Val lo) {
    long long x = c4_int64(v), h = c4_int64(hi), l = c4_int64(lo);
    if (h < 0 || h > 63 || l < 0 || l > 63 || h < l)
        c4_err("TypeError");
    unsigned long long u = (unsigned long long)x;
    unsigned long long w = (unsigned long long)(h - l);
    u >>= (unsigned)l;
    if (w < 63)
        u &= ((1ULL << (w + 1)) - 1);
    return c4_num((double)(long long)u);
}
C4Val c4_setbits(C4Val v, C4Val hi, C4Val lo, C4Val f) {
    long long x = c4_int64(v), h = c4_int64(hi), l = c4_int64(lo), fv = c4_int64(f);
    if (h < 0 || h > 63 || l < 0 || l > 63 || h < l)
        c4_err("TypeError");
    unsigned long long w = (unsigned long long)(h - l) + 1;
    unsigned long long m = w >= 64 ? ~0ULL : (((1ULL << w) - 1) << (unsigned)l);
    if (w < 64 && ((unsigned long long)fv >= (1ULL << w)))
        c4_err("TypeError");
    unsigned long long u = (unsigned long long)x;
    u = (u & ~m) | (((unsigned long long)fv << (unsigned)l) & m);
    return c4_num((double)(long long)u);
}
C4Val c4_flag(C4Val v, C4Val n) {
    long long x = c4_int64(v), b = c4_int64(n);
    if (b < 0 || b > 63)
        c4_err("TypeError");
    return c4_num((((unsigned long long)x >> (unsigned)b) & 1) ? 1 : 0);
}
C4Val c4_bytes(C4Val n) {
    need_num(n, "bytes");
    if (n.num != trunc(n.num) || n.num < 0 || n.num > 16 * 1024 * 1024)
        c4_err("TypeError");
    C4Val o = c4_list();
    for (long i = 0; i < (long)n.num; i++)
        list_push(o.list, c4_num(0));
    return o;
}
static long c4_byte_index(C4Val l, C4Val ix) {
    if (l.t != C4_LIST)
        c4_err("TypeError");
    if (ix.t != C4_NUM || ix.num != trunc(ix.num))
        c4_err("TypeError");
    long i = (long)ix.num, n = (long)l.list->len;
    if (i < 0)
        i += n;
    if (i < 0 || i >= n)
        c4_err("IndexOutOfBounds");
    return i;
}
C4Val c4_peek(C4Val l, C4Val i) {
    return l.list->items[c4_byte_index(l, i)];
}
C4Val c4_poke(C4Val l, C4Val i, C4Val v) {
    long idx = c4_byte_index(l, i);
    need_num(v, "poke");
    if (v.num != trunc(v.num) || v.num < 0 || v.num > 255)
        c4_err("TypeError");
    l.list->items[idx] = v;
    return v;
}
static int c4_fmt_size(const char *f) {
    int n = 0;
    for (; *f; f++) {
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
    return n;
}
static double c4_wrap(double v, int bits, int sg) {
    if (v != trunc(v) || fabs(v) >= 9007199254740992.0)
        c4_err("TypeError");
    double m = ldexp(1.0, bits);
    double r = fmod(v, m);
    if (r < 0)
        r += m;
    if (sg && r >= m / 2.0)
        r -= m;
    return r;
}
C4Val c4_pack(C4Val fmt, C4Val vals) {
    if (fmt.t != C4_STR || vals.t != C4_LIST)
        c4_err("TypeError");
    int little = 1, vi = 0;
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
            if (vi >= (int)vals.list->len)
                c4_err("ArityMismatch");
            int bits = (*f == 'B' || *f == 'b') ? 8 : (*f == 'H' || *f == 'h') ? 16 : 32;
            int sg = (*f == 'b' || *f == 'h' || *f == 'i');
            double w = c4_wrap(vals.list->items[vi++].num, bits, sg);
            double m = ldexp(1.0, bits);
            double u = fmod(w, m);
            if (u < 0)
                u += m;
            int nb = bits / 8;
            for (int k = 0; k < nb; k++) {
                int sh = little ? k * 8 : (nb - 1 - k) * 8;
                list_push(o.list, c4_num(fmod(floor(u / ldexp(1.0, sh)), 256.0)));
            }
        } else
            c4_err("TypeError");
    }
    if (vi != (int)vals.list->len)
        c4_err("ArityMismatch");
    return o;
}
C4Val c4_unpack(C4Val fmt, C4Val data) {
    if (fmt.t != C4_STR || data.t != C4_LIST)
        c4_err("TypeError");
    size_t n = data.list->len;
    unsigned char *raw = xmalloc(n ? n : 1);
    for (size_t i = 0; i < n; i++) {
        C4Val b = data.list->items[i];
        if (b.t != C4_NUM || b.num != trunc(b.num) || b.num < 0 || b.num > 255)
            c4_err("TypeError");
        raw[i] = (unsigned char)b.num;
    }
    int little = 1;
    size_t pos = 0;
    C4Val o = c4_list();
    for (const char *f = fmt.str; *f; f++) {
        if (*f == '<') {
            little = 1;
        } else if (*f == '>') {
            little = 0;
        } else if (*f == ' ') {
        } else if (*f == 'x') {
            if (pos >= n)
                c4_err("UnexpectedEof");
            pos++;
        } else if (*f == 'B' || *f == 'H' || *f == 'I' || *f == 'b' || *f == 'h' || *f == 'i') {
            int bits = (*f == 'B' || *f == 'b') ? 8 : (*f == 'H' || *f == 'h') ? 16 : 32;
            int nb = bits / 8;
            if (pos + (size_t)nb > n)
                c4_err("UnexpectedEof");
            unsigned long long u = 0;
            for (int k = 0; k < nb; k++) {
                int sh = little ? k * 8 : (nb - 1 - k) * 8;
                u |= (unsigned long long)raw[pos + (size_t)k] << sh;
            }
            pos += (size_t)nb;
            if (*f == 'b' || *f == 'h' || *f == 'i') {
                unsigned long long half = 1ULL << (bits - 1);
                if (u >= half)
                    list_push(o.list, c4_num((double)u - ldexp(1.0, bits)));
                else
                    list_push(o.list, c4_num((double)u));
            } else {
                list_push(o.list, c4_num((double)u));
            }
        } else
            c4_err("TypeError");
    }
    free(raw);
    if (pos != n)
        c4_err("UnexpectedEof");
    return o;
}
C4Val c4_sizeof(C4Val fmt) {
    if (fmt.t != C4_STR)
        c4_err("TypeError");
    return c4_num(c4_fmt_size(fmt.str));
}
C4Val c4_u8(C4Val v) {
    need_num(v, "u8");
    return c4_num(c4_wrap(v.num, 8, 0));
}
C4Val c4_u16(C4Val v) {
    need_num(v, "u16");
    return c4_num(c4_wrap(v.num, 16, 0));
}
C4Val c4_u32(C4Val v) {
    need_num(v, "u32");
    return c4_num(c4_wrap(v.num, 32, 0));
}
C4Val c4_i8(C4Val v) {
    need_num(v, "i8");
    return c4_num(c4_wrap(v.num, 8, 1));
}
C4Val c4_i16(C4Val v) {
    need_num(v, "i16");
    return c4_num(c4_wrap(v.num, 16, 1));
}
C4Val c4_i32(C4Val v) {
    need_num(v, "i32");
    return c4_num(c4_wrap(v.num, 32, 1));
}
C4Val c4_keys(C4Val d) {
    if (d.t != C4_DICT)
        c4_err("TypeError");
    C4Val o = c4_list();
    for (size_t i = 0; i < d.dict->len; i++)
        list_push(o.list, c4_str(d.dict->keys[i]));
    return o;
}
C4Val c4_del(C4Val d, C4Val k) {    if (d.t != C4_DICT)
        c4_err("TypeError");
    char *key = c4_tostring(k);
    for (size_t i = 0; i < d.dict->len; i++) {
        if (strcmp(d.dict->keys[i], key) == 0) {
            free(d.dict->keys[i]);
            for (size_t j = i + 1; j < d.dict->len; j++) {
                d.dict->keys[j - 1] = d.dict->keys[j];
                d.dict->vals[j - 1] = d.dict->vals[j];
            }
            d.dict->len--;
            free(key);
            return c4_num(1);
        }
    }
    free(key);
    return c4_num(0);
}

static C4Val c4_cpu_field(C4Val m, const char *f) {
    if (m.t != C4_DICT)
        c4_err("TypeError");
    for (size_t i = 0; i < m.dict->len; i++)
        if (strcmp(m.dict->keys[i], f) == 0)
            return m.dict->vals[i];
    c4_err("TypeError");
    return c4_nil();
}
static void c4_cpu_set(C4Val m, const char *f, C4Val v) {
    dict_put(m.dict, f, v);
}
static long c4_cpu_regno(C4Val r) {
    if (r.t != C4_NUM || r.num != trunc(r.num) || r.num < 0 || r.num > 7)
        c4_err("TypeError");
    return (long)r.num;
}
static long c4_cpu_addr(C4Val mem, C4Val a) {
    if (a.t != C4_NUM || a.num != trunc(a.num) || a.num < 0)
        c4_err("TypeError");
    long x = (long)a.num;
    if (x + 4 > (long)mem.list->len)
        c4_err("IndexOutOfBounds");
    return x;
}
static unsigned long long c4_cpu_u32(C4Val v) {
    if (v.t != C4_NUM || v.num != trunc(v.num))
        c4_err("TypeError");
    double m = ldexp(1.0, 32);
    double r = fmod(v.num, m);
    if (r < 0)
        r += m;
    return (unsigned long long)r;
}
static long c4_cpu_exec(C4Val m, const char *op, double ra, double rb, C4Val rbv, long pc) {
    C4Val regs = c4_cpu_field(m, "regs");
    C4Val mem = c4_cpu_field(m, "mem");
    long next = pc + 1;
    if (strcmp(op, "halt") == 0) {
        c4_cpu_set(m, "running", c4_num(0));
    } else if (strcmp(op, "nop") == 0) {
    } else if (strcmp(op, "li") == 0) {
        long rd = c4_cpu_regno(c4_num(ra));
        regs.list->items[rd] = c4_num(c4_cpu_u32(rbv));
    } else if (strcmp(op, "add") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        double w = regs.list->items[rd].num + regs.list->items[rs].num;
        regs.list->items[rd] = c4_num(c4_cpu_u32(c4_num(w)));
    } else if (strcmp(op, "sub") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        double w = regs.list->items[rd].num - regs.list->items[rs].num;
        regs.list->items[rd] = c4_num(c4_cpu_u32(c4_num(w)));
    } else if (strcmp(op, "and") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        regs.list->items[rd] = c4_band(regs.list->items[rd], regs.list->items[rs]);
    } else if (strcmp(op, "or") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        regs.list->items[rd] = c4_bor(regs.list->items[rd], regs.list->items[rs]);
    } else if (strcmp(op, "xor") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        regs.list->items[rd] = c4_bxor(regs.list->items[rd], regs.list->items[rs]);
    } else if (strcmp(op, "shl") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        regs.list->items[rd] = c4_shl(regs.list->items[rd], regs.list->items[rs]);
    } else if (strcmp(op, "shr") == 0) {
        long rd = c4_cpu_regno(c4_num(ra)), rs = c4_cpu_regno(c4_num(rb));
        regs.list->items[rd] = c4_shr(regs.list->items[rd], regs.list->items[rs]);
    } else if (strcmp(op, "lw") == 0) {
        long rd = c4_cpu_regno(c4_num(ra));
        long a = c4_cpu_addr(mem, rbv);
        unsigned long long u = 0;
        for (int k = 0; k < 4; k++)
            u |= (unsigned long long)(unsigned char)mem.list->items[a + k].num << (k * 8);
        regs.list->items[rd] = c4_num((double)u);
    } else if (strcmp(op, "sw") == 0) {
        long rs = c4_cpu_regno(c4_num(ra));
        long a = c4_cpu_addr(mem, rbv);
        unsigned long long u = c4_cpu_u32(regs.list->items[rs]);
        for (int k = 0; k < 4; k++)
            mem.list->items[a + k] = c4_num((double)((u >> (k * 8)) & 0xFF));
    } else if (strcmp(op, "jmp") == 0) {
        if (ra != trunc(ra) || ra < 0)
            c4_err("TypeError");
        next = (long)ra;
    } else if (strcmp(op, "jz") == 0) {
        long rs = c4_cpu_regno(c4_num(ra));
        if (rb != trunc(rb) || rb < 0)
            c4_err("TypeError");
        if (regs.list->items[rs].num == 0)
            next = (long)rb;
    } else {
        c4_err("TypeError");
    }
    return next;
}
C4Val c4_fnval(const char *name, double id) {
    C4Val v;
    v.t = C4_FN;
    v.num = id;
    v.str = xdup(name);
    return v;
}

C4Val c4_fname(C4Val v) {
    if (v.t != C4_FN) c4_err("TypeError");
    return c4_str(v.str ? v.str : "?");
}

C4Val c4_cpu_new(C4Val n) {
    need_num(n, "cpu.new");
    if (n.num != trunc(n.num) || n.num < 0 || n.num > 16 * 1024 * 1024)
        c4_err("TypeError");
    C4Val m = c4_dict();
    C4Val regs = c4_list(), mem = c4_list();
    for (int i = 0; i < 8; i++)
        list_push(regs.list, c4_num(0));
    for (long i = 0; i < (long)n.num; i++)
        list_push(mem.list, c4_num(0));
    dict_put(m.dict, "regs", regs);
    dict_put(m.dict, "mem", mem);
    dict_put(m.dict, "pc", c4_num(0));
    dict_put(m.dict, "running", c4_num(1));
    dict_put(m.dict, "steps", c4_num(0));
    return m;
}
C4Val c4_cpu_reg(C4Val m, C4Val r) {
    C4Val regs = c4_cpu_field(m, "regs");
    return regs.list->items[c4_cpu_regno(r)];
}
C4Val c4_cpu_setreg(C4Val m, C4Val r, C4Val v) {
    C4Val regs = c4_cpu_field(m, "regs");
    regs.list->items[c4_cpu_regno(r)] = c4_num(c4_cpu_u32(v));
    return c4_num(1);
}
C4Val c4_cpu_load(C4Val m, C4Val a) {
    C4Val mem = c4_cpu_field(m, "mem");
    long x = c4_cpu_addr(mem, a);
    unsigned long long u = 0;
    for (int k = 0; k < 4; k++)
        u |= (unsigned long long)(unsigned char)mem.list->items[x + k].num << (k * 8);
    return c4_num((double)u);
}
C4Val c4_cpu_store(C4Val m, C4Val a, C4Val v) {
    C4Val mem = c4_cpu_field(m, "mem");
    long x = c4_cpu_addr(mem, a);
    unsigned long long u = c4_cpu_u32(v);
    for (int k = 0; k < 4; k++)
        mem.list->items[x + k] = c4_num((double)((u >> (k * 8)) & 0xFF));
    return c4_num(1);
}
C4Val c4_cpu_step(C4Val m, C4Val op, C4Val a, C4Val b) {
    if (op.t != C4_STR || a.t != C4_NUM || b.t != C4_NUM)
        c4_err("TypeError");
    if (c4_cpu_field(m, "running").num != 1)
        return c4_num(0);
    long pc = (long)c4_cpu_field(m, "pc").num;
    long npc = c4_cpu_exec(m, op.str, a.num, b.num, b, pc);
    c4_cpu_set(m, "pc", c4_num((double)npc));
    c4_cpu_set(m, "steps", c4_num(c4_cpu_field(m, "steps").num + 1));
    return c4_cpu_field(m, "running");
}
C4Val c4_cpu_run(C4Val m, C4Val prog) {
    if (prog.t != C4_DICT)
        c4_err("TypeError");
    C4Val c = c4_nil();
    for (size_t i = 0; i < prog.dict->len; i++)
        if (strcmp(prog.dict->keys[i], "code") == 0)
            c = prog.dict->vals[i];
    if (c.t != C4_LIST)
        c4_err("TypeError");
    C4Val e = c4_num(0);
    for (size_t i = 0; i < prog.dict->len; i++)
        if (strcmp(prog.dict->keys[i], "entry") == 0)
            e = prog.dict->vals[i];
    c4_cpu_set(m, "pc", e);
    c4_cpu_set(m, "running", c4_num(1));
    long steps = 0;
    while (1) {
        if (c4_cpu_field(m, "running").num != 1)
            break;
        long pc = (long)c4_cpu_field(m, "pc").num;
        if (pc < 0 || pc >= (long)c.list->len)
            break;
        C4Val ins = c.list->items[pc];
        if (ins.t != C4_LIST || ins.list->len != 3 || ins.list->items[0].t != C4_STR || ins.list->items[1].t != C4_NUM || ins.list->items[2].t != C4_NUM)
            c4_err("TypeError");
        long npc = c4_cpu_exec(m, ins.list->items[0].str, ins.list->items[1].num, ins.list->items[2].num, ins.list->items[2], pc);
        c4_cpu_set(m, "pc", c4_num((double)npc));
        c4_cpu_set(m, "steps", c4_num(c4_cpu_field(m, "steps").num + 1));
        if (++steps > 1000000)
            c4_err("LoopLimitExceeded");
    }
    return c4_num((double)steps);
}
C4Val c4_input(C4Val prompt, int has_prompt) {
    if (has_prompt) {
        char *p = c4_tostring(prompt);
        printf("%s", p);
        free(p);
        fflush(stdout);
    }
    size_t cap = 128, len = 0;
    char *o = xmalloc(cap);
    int c;
    while ((c = getchar()) != EOF && c != '\n') {
        if (len + 1 >= cap) {
            cap *= 2;
            o = realloc(o, cap);
        }
        o[len++] = (char)c;
    }
    if (len > 0 && o[len - 1] == '\r')
        len--;
    o[len] = 0;
    C4Val v;
    v.t = C4_STR;
    v.str = o;
    return v;
}
C4Val c4_args(void) {
    C4Val o = c4_list();
    for (int i = 0; i < c4_argc; i++)
        list_push(o.list, c4_str(c4_argv[i]));
    return o;
}
void c4_exit(C4Val code) {
    int c = 0;
    if (code.t == C4_NUM)
        c = (int)code.num;
    exit(c);
}

static char *c4_read_all(const char *path, size_t *out_n, int binary) {
    FILE *f = fopen(path, binary ? "rb" : "r");
    if (!f)
        return NULL;
    size_t cap = 4096, len = 0;
    char *o = xmalloc(cap);
    size_t r;
    while ((r = fread(o + len, 1, cap - len, f)) > 0) {
        len += r;
        if (len == cap) {
            cap *= 2;
            o = realloc(o, cap);
        }
    }
    fclose(f);
    if (!binary) {
        while (len > 0 && (o[len - 1] == '\n' || o[len - 1] == '\r'))
            len--;
    }
    *out_n = len;
    return o;
}
C4Val c4_os_create(C4Val p, C4Val d) {
    char *path = c4_tostring(p), *data = c4_tostring(d);
    FILE *f = fopen(path, "w");
    if (!f)
        c4_err("WriteFailed");
    fputs(data, f);
    fclose(f);
    free(path);
    free(data);
    return c4_num(1);
}
C4Val c4_os_read(C4Val p) {
    char *path = c4_tostring(p);
    size_t n;
    char *data = c4_read_all(path, &n, 0);
    free(path);
    if (!data)
        c4_err("UnexpectedEof");
    data = realloc(data, n + 1);
    data[n] = 0;
    C4Val v;
    v.t = C4_STR;
    v.str = data;
    return v;
}
C4Val c4_os_append(C4Val p, C4Val d) {
    char *path = c4_tostring(p), *data = c4_tostring(d);
    FILE *f = fopen(path, "a");
    if (!f)
        c4_err("WriteFailed");
    fputs(data, f);
    fclose(f);
    free(path);
    free(data);
    return c4_num(1);
}
C4Val c4_os_exists(C4Val p) {
    char *path = c4_tostring(p);
    int r = c4_access(path) == 0;
    free(path);
    return c4_num(r);
}
C4Val c4_os_remove(C4Val p) {
    char *path = c4_tostring(p);
    int r = remove(path);
    free(path);
    if (r != 0)
        c4_err("UnexpectedEof");
    return c4_num(1);
}
C4Val c4_os_edit(C4Val p, C4Val o, C4Val nw) {
    char *path = c4_tostring(p), *olds = c4_tostring(o), *news = c4_tostring(nw);
    size_t n;
    char *data = c4_read_all(path, &n, 0);
    if (!data)
        c4_err("UnexpectedEof");
    data = realloc(data, n + 1);
    data[n] = 0;
    size_t ol = strlen(olds), nl = strlen(news);
    size_t cap = n + 1, len = 0;
    char *out = xmalloc(cap);
    const char *rest = data;
    const char *f;
    if (ol > 0) {
        while ((f = strstr(rest, olds)) != NULL) {
            size_t pre = (size_t)(f - rest);
            while (len + pre + nl + 1 >= cap) {
                cap *= 2;
                out = realloc(out, cap);
            }
            memcpy(out + len, rest, pre);
            len += pre;
            memcpy(out + len, news, nl);
            len += nl;
            rest = f + ol;
        }
    }
    size_t rl = strlen(rest);
    while (len + rl + 1 >= cap) {
        cap *= 2;
        out = realloc(out, cap);
    }
    memcpy(out + len, rest, rl + 1);
    free(data);
    FILE *wf = fopen(path, "w");
    if (!wf)
        c4_err("WriteFailed");
    fputs(out, wf);
    fclose(wf);
    free(path);
    free(olds);
    free(news);
    free(out);
    return c4_num(1);
}
C4Val c4_os_readbytes(C4Val p) {
    char *path = c4_tostring(p);
    size_t n;
    char *data = c4_read_all(path, &n, 1);
    free(path);
    if (!data)
        c4_err("UnexpectedEof");
    C4Val o = c4_list();
    for (size_t i = 0; i < n; i++)
        list_push(o.list, c4_num((unsigned char)data[i]));
    free(data);
    return o;
}
C4Val c4_os_writebytes(C4Val p, C4Val l) {
    char *path = c4_tostring(p);
    if (l.t != C4_LIST)
        c4_err("TypeError");
    FILE *f = fopen(path, "wb");
    if (!f)
        c4_err("WriteFailed");
    for (size_t i = 0; i < l.list->len; i++) {
        C4Val b = l.list->items[i];
        if (b.t != C4_NUM || b.num != trunc(b.num) || b.num < 0 || b.num > 255)
            c4_err("TypeError");
        fputc((int)b.num, f);
    }
    fclose(f);
    free(path);
    return c4_num(1);
}
C4Val c4_os_cwd(void) {
#ifdef _WIN32
    char *p = _getcwd(NULL, 0);
#else
    char *p = getcwd(NULL, 0);
#endif
    if (!p)
        c4_err("UnexpectedEof");
    C4Val v = c4_str(p);
    free(p);
    return v;
}
C4Val c4_os_env(C4Val k) {
    char *key = c4_tostring(k);
    const char *v = getenv(key);
    free(key);
    return c4_str(v ? v : "");
}
C4Val c4_os_listdir(C4Val p) {
    char *path = c4_tostring(p);
    C4Val o = c4_list();
#ifdef _WIN32
    {
        size_t n = strlen(path);
        char *pat = xmalloc(n + 4);
        memcpy(pat, path, n);
        memcpy(pat + n, "\\*", 3);
        struct _finddata_t fd;
        intptr_t h = _findfirst(pat, &fd);
        free(pat);
        if (h == -1)
            c4_err("UnexpectedEof");
        do {
            if (strcmp(fd.name, ".") != 0 && strcmp(fd.name, "..") != 0)
                list_push(o.list, c4_str(fd.name));
        } while (_findnext(h, &fd) == 0);
        _findclose(h);
    }
#else
    {
        DIR *d = opendir(path);
        if (!d)
            c4_err("UnexpectedEof");
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0)
                list_push(o.list, c4_str(e->d_name));
        }
        closedir(d);
    }
#endif
    free(path);
    return o;
}
C4Val c4_os_mkdir(C4Val p) {
    char *path = c4_tostring(p);
    if (c4_access(path) == 0) {
        free(path);
        return c4_num(1);
    }
#ifdef _WIN32
    int r = _mkdir(path);
#else
    int r = mkdir(path, 0755);
#endif
    free(path);
    if (r != 0)
        c4_err("WriteFailed");
    return c4_num(1);
}

C4Val c4_ph_g(void) {
    return c4_num(9.81);
}
C4Val c4_ph_fall(C4Val d) {
    need_num(d, "fall");
    if (d.num < 0)
        c4_err("MathError");
    return c4_num(sqrt(2.0 * d.num / 9.81));
}
C4Val c4_ph_range(C4Val v, C4Val deg) {
    need_num(v, "range");
    need_num(deg, "range");
    double th = deg.num * 3.141592653589793 / 180.0;
    return c4_num(v.num * v.num * sin(2.0 * th) / 9.81);
}
C4Val c4_ph_height(C4Val v, C4Val deg) {
    need_num(v, "height");
    need_num(deg, "height");
    double vy = v.num * sin(deg.num * 3.141592653589793 / 180.0);
    return c4_num(vy * vy / (2.0 * 9.81));
}
C4Val c4_ph_dist(C4Val a, C4Val b, C4Val c, C4Val d) {
    need_num(a, "dist");
    need_num(b, "dist");
    need_num(c, "dist");
    need_num(d, "dist");
    double dx = c.num - a.num, dy = d.num - b.num;
    return c4_num(sqrt(dx * dx + dy * dy));
}
C4Val c4_ph_speed(C4Val d, C4Val t) {
    need_num(d, "speed");
    need_num(t, "speed");
    if (t.num == 0)
        c4_err("DivisionByZero");
    return c4_num(d.num / t.num);
}
C4Val c4_ph_energy(C4Val m, C4Val v) {
    need_num(m, "energy");
    need_num(v, "energy");
    return c4_num(0.5 * m.num * v.num * v.num);
}

C4Val c4_tm_now(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return c4_num((double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0);
}
C4Val c4_tm_stamp(void) {
    time_t t = time(NULL);
    struct tm *g = gmtime(&t);
    char buf[64];
    snprintf(buf, sizeof buf, "%04d-%02d-%02d %02d:%02d:%02d", g->tm_year + 1900, g->tm_mon + 1, g->tm_mday, g->tm_hour, g->tm_min, g->tm_sec);
    return c4_str(buf);
}
C4Val c4_tm_sleep(C4Val s) {
    need_num(s, "sleep");
    if (s.num < 0)
        c4_err("MathError");
#ifdef _WIN32
    Sleep((unsigned)(s.num * 1000.0));
#else
    {
        struct timespec ts;
        ts.tv_sec = (time_t)s.num;
        ts.tv_nsec = (long)((s.num - floor(s.num)) * 1e9);
        nanosleep(&ts, NULL);
    }
#endif
    return c4_num(1);
}

C4Val c4_ord(C4Val s) {
    if (s.t != C4_STR || s.str[0] == 0)
        c4_err("TypeError");
    return c4_num((unsigned char)s.str[0]);
}
C4Val c4_chr(C4Val n) {
    need_num(n, "chr");
    if (n.num != trunc(n.num) || n.num < 0 || n.num > 0x10FFFF)
        c4_err("TypeError");
    unsigned c = (unsigned)n.num;
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
    return c4_strn(buf, (size_t)m);
}
C4Val c4_sin(C4Val v) {
    need_num(v, "sin");
    return c4_num(sin(v.num));
}
C4Val c4_cos(C4Val v) {
    need_num(v, "cos");
    return c4_num(cos(v.num));
}
C4Val c4_tan(C4Val v) {
    need_num(v, "tan");
    return c4_num(tan(v.num));
}
C4Val c4_asin(C4Val v) {
    need_num(v, "asin");
    if (v.num < -1 || v.num > 1)
        c4_err("MathError");
    return c4_num(asin(v.num));
}
C4Val c4_acos(C4Val v) {
    need_num(v, "acos");
    if (v.num < -1 || v.num > 1)
        c4_err("MathError");
    return c4_num(acos(v.num));
}
C4Val c4_atan(C4Val v) {
    need_num(v, "atan");
    return c4_num(atan(v.num));
}
C4Val c4_log(C4Val v) {
    need_num(v, "log");
    if (v.num <= 0)
        c4_err("MathError");
    return c4_num(log(v.num));
}
C4Val c4_log10(C4Val v) {
    need_num(v, "log10");
    if (v.num <= 0)
        c4_err("MathError");
    return c4_num(log10(v.num));
}
C4Val c4_exp(C4Val v) {
    need_num(v, "exp");
    return c4_num(exp(v.num));
}
C4Val c4_deg(C4Val v) {
    need_num(v, "deg");
    return c4_num(v.num * 180.0 / 3.141592653589793);
}
C4Val c4_rad(C4Val v) {
    need_num(v, "rad");
    return c4_num(v.num * 3.141592653589793 / 180.0);
}
C4Val c4_pi(void) {
    return c4_num(3.141592653589793);
}
C4Val c4_e(void) {
    return c4_num(2.718281828459045);
}
static C4Val c4_heap_h(C4Val h) {
    if (h.t != C4_DICT)
        c4_err("TypeError");
    return h;
}
static void c4_heap_parts(C4Val h, C4Val *mem, C4Val *frl, C4Val *allocs) {
    *mem = c4_nil();
    *frl = c4_nil();
    *allocs = c4_nil();
    for (size_t i = 0; i < h.dict->len; i++) {
        if (strcmp(h.dict->keys[i], "mem") == 0)
            *mem = h.dict->vals[i];
        if (strcmp(h.dict->keys[i], "free") == 0)
            *frl = h.dict->vals[i];
        if (strcmp(h.dict->keys[i], "allocs") == 0)
            *allocs = h.dict->vals[i];
    }
    if (mem->t != C4_LIST || frl->t != C4_LIST || allocs->t != C4_DICT)
        c4_err("TypeError");
}
static void c4_heap_coalesce(C4Val frl) {
    size_t n = frl.list->len;
    for (size_t i = 1; i < n; i++) {
        size_t j = i;
        while (j > 0 && frl.list->items[j].list->items[0].num < frl.list->items[j - 1].list->items[0].num) {
            C4Val t = frl.list->items[j];
            frl.list->items[j] = frl.list->items[j - 1];
            frl.list->items[j - 1] = t;
            j--;
        }
    }
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        long s = (long)frl.list->items[i].list->items[0].num;
        long sz = (long)frl.list->items[i].list->items[1].num;
        if (w > 0) {
            long ps = (long)frl.list->items[w - 1].list->items[0].num;
            long pz = (long)frl.list->items[w - 1].list->items[1].num;
            if (ps + pz == s) {
                frl.list->items[w - 1].list->items[1] = c4_num((double)(pz + sz));
                continue;
            }
        }
        frl.list->items[w++] = frl.list->items[i];
    }
    frl.list->len = w;
}
static long c4_heap_claim(C4Val frl, C4Val allocs, long need) {
    for (size_t si = 0; si < frl.list->len; si++) {
        long s = (long)frl.list->items[si].list->items[0].num;
        long sz = (long)frl.list->items[si].list->items[1].num;
        if (sz >= need) {
            char key[32];
            snprintf(key, sizeof key, "%ld", s);
            dict_put(allocs.dict, key, c4_num((double)need));
            if (sz == need) {
                for (size_t j = si + 1; j < frl.list->len; j++)
                    frl.list->items[j - 1] = frl.list->items[j];
                frl.list->len--;
            } else {
                frl.list->items[si].list->items[0] = c4_num((double)(s + need));
                frl.list->items[si].list->items[1] = c4_num((double)(sz - need));
            }
            return s;
        }
    }
    return -1;
}
C4Val c4_heap_new(C4Val n) {
    need_num(n, "heap.new");
    if (n.num != trunc(n.num) || n.num < 0 || n.num > 16 * 1024 * 1024)
        c4_err("TypeError");
    C4Val h = c4_dict();
    C4Val mem = c4_list(), frl = c4_list(), allocs = c4_dict();
    for (long i = 0; i < (long)n.num; i++)
        list_push(mem.list, c4_num(0));
    if (n.num > 0) {
        C4Val span = c4_list();
        list_push(span.list, c4_num(0));
        list_push(span.list, c4_num(n.num));
        list_push(frl.list, span);
    }
    dict_put(h.dict, "mem", mem);
    dict_put(h.dict, "free", frl);
    dict_put(h.dict, "allocs", allocs);
    return h;
}
C4Val c4_heap_malloc(C4Val h, C4Val n) {
    c4_heap_h(h);
    need_num(n, "malloc");
    if (n.num != trunc(n.num) || n.num <= 0)
        c4_err("TypeError");
    C4Val mem, frl, allocs;
    c4_heap_parts(h, &mem, &frl, &allocs);
    (void)mem;
    return c4_num((double)c4_heap_claim(frl, allocs, (long)n.num));
}
C4Val c4_heap_free(C4Val h, C4Val a) {
    c4_heap_h(h);
    need_num(a, "free");
    if (a.num != trunc(a.num) || a.num < 0)
        c4_err("TypeError");
    C4Val mem, frl, allocs;
    c4_heap_parts(h, &mem, &frl, &allocs);
    (void)mem;
    char key[32];
    snprintf(key, sizeof key, "%ld", (long)a.num);
    long sz = -1;
    for (size_t i = 0; i < allocs.dict->len; i++)
        if (strcmp(allocs.dict->keys[i], key) == 0)
            sz = (long)allocs.dict->vals[i].num;
    if (sz < 0)
        return c4_num(0);
    for (size_t i = 0; i < allocs.dict->len; i++)
        if (strcmp(allocs.dict->keys[i], key) == 0) {
            free(allocs.dict->keys[i]);
            for (size_t j = i + 1; j < allocs.dict->len; j++) {
                allocs.dict->keys[j - 1] = allocs.dict->keys[j];
                allocs.dict->vals[j - 1] = allocs.dict->vals[j];
            }
            allocs.dict->len--;
            break;
        }
    C4Val span = c4_list();
    list_push(span.list, c4_num(a.num));
    list_push(span.list, c4_num((double)sz));
    list_push(frl.list, span);
    c4_heap_coalesce(frl);
    return c4_num(1);
}
C4Val c4_heap_stats(C4Val h) {
    c4_heap_h(h);
    C4Val mem, frl, allocs;
    c4_heap_parts(h, &mem, &frl, &allocs);
    (void)allocs;
    long total = (long)mem.list->len, fr = 0;
    for (size_t i = 0; i < frl.list->len; i++)
        fr += (long)frl.list->items[i].list->items[1].num;
    C4Val st = c4_dict();
    dict_put(st.dict, "total", c4_num((double)total));
    dict_put(st.dict, "free", c4_num((double)fr));
    dict_put(st.dict, "used", c4_num((double)(total - fr)));
    dict_put(st.dict, "blocks", c4_num((double)frl.list->len));
    return st;
}
C4Val c4_heap_calloc(C4Val h, C4Val n) {
    c4_heap_h(h);
    need_num(n, "calloc");
    if (n.num != trunc(n.num) || n.num <= 0)
        c4_err("TypeError");
    long need = (long)n.num;
    C4Val frl = c4_nil(), allocs = c4_nil(), mem = c4_nil();
    for (size_t i = 0; i < h.dict->len; i++) {
        if (strcmp(h.dict->keys[i], "free") == 0)
            frl = h.dict->vals[i];
        if (strcmp(h.dict->keys[i], "allocs") == 0)
            allocs = h.dict->vals[i];
        if (strcmp(h.dict->keys[i], "mem") == 0)
            mem = h.dict->vals[i];
    }
    if (frl.t != C4_LIST || allocs.t != C4_DICT || mem.t != C4_LIST)
        c4_err("TypeError");
    for (size_t si = 0; si < frl.list->len; si++) {
        C4Val sp = frl.list->items[si];
        long s = (long)sp.list->items[0].num, sz = (long)sp.list->items[1].num;
        if (sz >= need) {
            char key[32];
            snprintf(key, sizeof key, "%ld", s);
            dict_put(allocs.dict, key, c4_num((double)need));
            for (long k = 0; k < need; k++)
                mem.list->items[s + k] = c4_num(0);
            if (sz == need) {
                for (size_t j = si + 1; j < frl.list->len; j++)
                    frl.list->items[j - 1] = frl.list->items[j];
                frl.list->len--;
            } else {
                sp.list->items[0] = c4_num((double)(s + need));
                sp.list->items[1] = c4_num((double)(sz - need));
            }
            return c4_num((double)s);
        }
    }
    return c4_num(-1);
}
C4Val c4_heap_realloc(C4Val h, C4Val a, C4Val n) {
    c4_heap_h(h);
    need_num(a, "realloc");
    need_num(n, "realloc");
    if (n.num != trunc(n.num) || n.num <= 0)
        c4_err("TypeError");
    long addr = (long)a.num, need = (long)n.num;
    C4Val frl = c4_nil(), allocs = c4_nil(), mem = c4_nil();
    for (size_t i = 0; i < h.dict->len; i++) {
        if (strcmp(h.dict->keys[i], "free") == 0)
            frl = h.dict->vals[i];
        if (strcmp(h.dict->keys[i], "allocs") == 0)
            allocs = h.dict->vals[i];
        if (strcmp(h.dict->keys[i], "mem") == 0)
            mem = h.dict->vals[i];
    }
    char oldkey[32];
    snprintf(oldkey, sizeof oldkey, "%ld", addr);
    long oldsz = -1;
    for (size_t i = 0; i < allocs.dict->len; i++)
        if (strcmp(allocs.dict->keys[i], oldkey) == 0)
            oldsz = (long)allocs.dict->vals[i].num;
    if (oldsz < 0)
        return c4_num(0);
    long at = -1;
    for (size_t si = 0; si < frl.list->len; si++) {
        long s = (long)frl.list->items[si].list->items[0].num;
        long sz = (long)frl.list->items[si].list->items[1].num;
        if (sz >= need) {
            at = s;
            char key[32];
            snprintf(key, sizeof key, "%ld", s);
            dict_put(allocs.dict, key, c4_num((double)need));
            if (sz == need) {
                for (size_t j = si + 1; j < frl.list->len; j++)
                    frl.list->items[j - 1] = frl.list->items[j];
                frl.list->len--;
            } else {
                frl.list->items[si].list->items[0] = c4_num((double)(s + need));
                frl.list->items[si].list->items[1] = c4_num((double)(sz - need));
            }
            break;
        }
    }
    if (at < 0)
        return c4_num(-1);
    long ncopy = oldsz < need ? oldsz : need;
    for (long k = 0; k < ncopy; k++)
        mem.list->items[at + k] = mem.list->items[addr + k];
    for (size_t i = 0; i < allocs.dict->len; i++)
        if (strcmp(allocs.dict->keys[i], oldkey) == 0) {
            free(allocs.dict->keys[i]);
            for (size_t j = i + 1; j < allocs.dict->len; j++) {
                allocs.dict->keys[j - 1] = allocs.dict->keys[j];
                allocs.dict->vals[j - 1] = allocs.dict->vals[j];
            }
            allocs.dict->len--;
            break;
        }
    {
        C4Val sp = c4_list();
        list_push(sp.list, c4_num((double)addr));
        list_push(sp.list, c4_num((double)oldsz));
        list_push(frl.list, sp);
        /* coalesce: insertion sort by start then merge */
        for (size_t i = 1; i < frl.list->len; i++) {
            size_t j = i;
            while (j > 0 && frl.list->items[j].list->items[0].num < frl.list->items[j - 1].list->items[0].num) {
                C4Val t = frl.list->items[j];
                frl.list->items[j] = frl.list->items[j - 1];
                frl.list->items[j - 1] = t;
                j--;
            }
        }
        size_t w = 0;
        for (size_t i = 0; i < frl.list->len; i++) {
            long s = (long)frl.list->items[i].list->items[0].num;
            long sz = (long)frl.list->items[i].list->items[1].num;
            if (w > 0) {
                long ps = (long)frl.list->items[w - 1].list->items[0].num;
                long pz = (long)frl.list->items[w - 1].list->items[1].num;
                if (ps + pz == s) {
                    frl.list->items[w - 1].list->items[1] = c4_num((double)(pz + sz));
                    continue;
                }
            }
            frl.list->items[w++] = frl.list->items[i];
        }
        frl.list->len = w;
    }
    return c4_num((double)at);
}
C4Val c4_heap_dump(C4Val h) {
    c4_heap_h(h);
    C4Val allocs = c4_nil();
    for (size_t i = 0; i < h.dict->len; i++)
        if (strcmp(h.dict->keys[i], "allocs") == 0)
            allocs = h.dict->vals[i];
    C4Val o = c4_list();
    /* insertion sort keys numerically */
    size_t n = allocs.dict->len;
    long *ks = xmalloc(sizeof(long) * (n ? n : 1));
    for (size_t i = 0; i < n; i++)
        ks[i] = atol(allocs.dict->keys[i]);
    for (size_t i = 1; i < n; i++) {
        size_t j = i;
        while (j > 0 && ks[j] < ks[j - 1]) {
            long t = ks[j];
            ks[j] = ks[j - 1];
            ks[j - 1] = t;
            j--;
        }
    }
    for (size_t i = 0; i < n; i++) {
        char key[32];
        snprintf(key, sizeof key, "%ld", ks[i]);
        C4Val pair = c4_list();
        list_push(pair.list, c4_num((double)ks[i]));
        for (size_t j = 0; j < allocs.dict->len; j++)
            if (strcmp(allocs.dict->keys[j], key) == 0)
                list_push(pair.list, allocs.dict->vals[j]);
        list_push(o.list, pair);
    }
    free(ks);
    return o;
}

/* ======== mem module (0.4.2): arena bump + slab pools over byte regions.
   Handles are 1-based ints into a static table. Errors that the interpreter
   reports as catchable FailSignal go through c4_fail with identical text;
   programming errors (bad handle/type) go through c4_err("TypeError"). ======== */

#define C4_MEM_MAX 32
#define C4_MEM_MAXBYTES ((size_t)16 * 1024 * 1024)

typedef struct {
    int used, is_pool;
    unsigned char *buf;
    size_t len, bump, peak, allocs;
    size_t objsz, count, live, free_top;
    unsigned *stack;
} C4MemReg;

static C4MemReg c4_mem_regs[C4_MEM_MAX];

static void c4_mem_fail(const char *op, const char *msg) {
    char b[128];
    snprintf(b, sizeof b, "mem %s %s", op, msg);
    c4_fail(b);
}

static long c4_mem_int(C4Val v) {
    if (v.t != C4_NUM || v.num != trunc(v.num) || v.num < 0 || v.num > 9007199254740991.0)
        c4_err("TypeError");
    return (long)v.num;
}

static C4MemReg *c4_mem_reg(C4Val h, const char *op) {
    long id = c4_mem_int(h);
    if (id < 1 || id > C4_MEM_MAX || !c4_mem_regs[id - 1].used)
        c4_err("TypeError");
    (void)op;
    return &c4_mem_regs[id - 1];
}

static void c4_mem_range(C4MemReg *r, size_t off, size_t n, const char *op) {
    if (n > r->len || off > r->len - n)
        c4_mem_fail(op, "out of bounds");
}

C4Val c4_mem_arena(C4Val n) {
    long size = c4_mem_int(n);
    if ((unsigned long)size > C4_MEM_MAXBYTES)
        c4_mem_fail("arena", "too big (max 16M)");
    int id = -1;
    for (int i = 0; i < C4_MEM_MAX; i++)
        if (!c4_mem_regs[i].used) {
            id = i;
            break;
        }
    if (id < 0)
        c4_mem_fail("arena", "out of memory");
    C4MemReg *r = &c4_mem_regs[id];
    memset(r, 0, sizeof *r);
    r->used = 1;
    r->len = (size_t)size;
    r->buf = r->len ? calloc(1, r->len) : NULL;
    if (r->len && !r->buf)
        c4_mem_fail("arena", "out of memory");
    return c4_num((double)(id + 1));
}

C4Val c4_mem_pool(C4Val o, C4Val c) {
    long objsz = c4_mem_int(o), count = c4_mem_int(c);
    if (objsz <= 0 || count <= 0)
        c4_err("TypeError");
    if ((unsigned long)objsz > C4_MEM_MAXBYTES / (unsigned long)count)
        c4_mem_fail("pool", "too big (max 16M)");
    int id = -1;
    for (int i = 0; i < C4_MEM_MAX; i++)
        if (!c4_mem_regs[i].used) {
            id = i;
            break;
        }
    if (id < 0)
        c4_mem_fail("pool", "out of memory");
    C4MemReg *r = &c4_mem_regs[id];
    memset(r, 0, sizeof *r);
    r->used = 1;
    r->is_pool = 1;
    r->objsz = (size_t)objsz;
    r->count = (size_t)count;
    r->len = r->objsz * r->count;
    r->buf = calloc(1, r->len);
    r->stack = malloc(sizeof(unsigned) * r->count);
    if (!r->buf || !r->stack) {
        free(r->buf);
        free(r->stack);
        memset(r, 0, sizeof *r);
        c4_mem_fail("pool", "out of memory");
    }
    for (size_t i = 0; i < r->count; i++)
        r->stack[i] = (unsigned)(r->count - 1 - i);
    r->free_top = r->count;
    return c4_num((double)(id + 1));
}

C4Val c4_mem_alloc(C4Val h, C4Val n) {
    C4MemReg *r = c4_mem_reg(h, "alloc");
    if (r->is_pool)
        c4_mem_fail("alloc", "needs arena");
    long nn = c4_mem_int(n);
    if (nn <= 0)
        c4_err("TypeError");
    size_t aligned = (r->bump + 3) & ~(size_t)3;
    if ((unsigned long)nn > C4_MEM_MAXBYTES || aligned > r->len || (size_t)nn > r->len - aligned)
        return c4_num(-1);
    r->bump = aligned + (size_t)nn;
    r->allocs++;
    if (r->bump > r->peak)
        r->peak = r->bump;
    return c4_num((double)aligned);
}

C4Val c4_mem_acquire(C4Val h) {
    C4MemReg *r = c4_mem_reg(h, "acquire");
    if (!r->is_pool)
        c4_mem_fail("acquire", "needs pool");
    if (r->free_top == 0)
        return c4_num(-1);
    r->free_top--;
    r->live++;
    if (r->live * r->objsz > r->peak)
        r->peak = r->live * r->objsz;
    return c4_num((double)r->stack[r->free_top]);
}

C4Val c4_mem_release(C4Val h, C4Val i) {
    C4MemReg *r = c4_mem_reg(h, "release");
    if (!r->is_pool)
        c4_mem_fail("release", "needs pool");
    long idx = c4_mem_int(i);
    if (idx < 0 || (unsigned long)idx >= r->count)
        c4_mem_fail("release", "bad slot");
    for (size_t k = 0; k < r->free_top; k++)
        if ((long)r->stack[k] == idx)
            return c4_num(0);
    r->stack[r->free_top++] = (unsigned)idx;
    r->live--;
    return c4_num(1);
}

static C4Val c4_mem_read(C4Val h, C4Val o, unsigned width) {
    C4MemReg *r = c4_mem_reg(h, "read");
    long off = c4_mem_int(o);
    if (off < 0 || (unsigned long)off > C4_MEM_MAXBYTES)
        c4_mem_fail("read", "out of bounds");
    c4_mem_range(r, (size_t)off, width, "read");
    unsigned long v = 0;
    for (unsigned k = 0; k < width; k++)
        v |= (unsigned long)r->buf[(size_t)off + k] << (8 * k);
    return c4_num((double)v);
}

C4Val c4_mem_read_u8(C4Val h, C4Val o) {
    return c4_mem_read(h, o, 1);
}
C4Val c4_mem_read_u16(C4Val h, C4Val o) {
    return c4_mem_read(h, o, 2);
}
C4Val c4_mem_read_u32(C4Val h, C4Val o) {
    return c4_mem_read(h, o, 4);
}

static void c4_mem_write(C4Val h, C4Val o, C4Val v, unsigned width, unsigned long cap) {
    C4MemReg *r = c4_mem_reg(h, "write");
    long off = c4_mem_int(o);
    if (off < 0 || (unsigned long)off > C4_MEM_MAXBYTES)
        c4_mem_fail("write", "out of bounds");
    if (v.t != C4_NUM || v.num != trunc(v.num) || v.num < 0 || v.num > (double)cap)
        c4_err("TypeError");
    c4_mem_range(r, (size_t)off, width, "write");
    unsigned long val = (unsigned long)v.num;
    for (unsigned k = 0; k < width; k++)
        r->buf[(size_t)off + k] = (unsigned char)((val >> (8 * k)) & 0xFF);
}

C4Val c4_mem_write_u8(C4Val h, C4Val o, C4Val v) {
    c4_mem_write(h, o, v, 1, 255);
    return c4_nil();
}
C4Val c4_mem_write_u16(C4Val h, C4Val o, C4Val v) {
    c4_mem_write(h, o, v, 2, 65535);
    return c4_nil();
}
C4Val c4_mem_write_u32(C4Val h, C4Val o, C4Val v) {
    c4_mem_write(h, o, v, 4, 4294967295UL);
    return c4_nil();
}

C4Val c4_mem_fill(C4Val h, C4Val o, C4Val n, C4Val b) {
    C4MemReg *r = c4_mem_reg(h, "fill");
    long off = c4_mem_int(o), nn = c4_mem_int(n);
    if (b.t != C4_NUM || b.num != trunc(b.num) || b.num < 0 || b.num > 255)
        c4_err("TypeError");
    if (off < 0 || nn < 0 || (unsigned long)off > C4_MEM_MAXBYTES || (unsigned long)nn > C4_MEM_MAXBYTES)
        c4_mem_fail("fill", "out of bounds");
    c4_mem_range(r, (size_t)off, (size_t)nn, "fill");
    memset(r->buf + off, (int)b.num, (size_t)nn);
    return c4_nil();
}

C4Val c4_mem_copy(C4Val h, C4Val d, C4Val s, C4Val n) {
    C4MemReg *r = c4_mem_reg(h, "copy");
    long dst = c4_mem_int(d), src = c4_mem_int(s), nn = c4_mem_int(n);
    if (dst < 0 || src < 0 || nn < 0 || (unsigned long)dst > C4_MEM_MAXBYTES || (unsigned long)src > C4_MEM_MAXBYTES || (unsigned long)nn > C4_MEM_MAXBYTES)
        c4_mem_fail("copy", "out of bounds");
    c4_mem_range(r, (size_t)dst, (size_t)nn, "copy");
    c4_mem_range(r, (size_t)src, (size_t)nn, "copy");
    memmove(r->buf + dst, r->buf + src, (size_t)nn);
    return c4_nil();
}

C4Val c4_mem_usage(C4Val h) {
    C4MemReg *r = c4_mem_reg(h, "usage");
    size_t used = r->is_pool ? r->live * r->objsz : r->bump;
    size_t units = r->is_pool ? r->live : r->allocs;
    C4Val st = c4_dict();
    dict_put(st.dict, "size", c4_num((double)r->len));
    dict_put(st.dict, "used", c4_num((double)used));
    dict_put(st.dict, "peak", c4_num((double)r->peak));
    dict_put(st.dict, "units", c4_num((double)units));
    return st;
}

C4Val c4_mem_reset(C4Val h) {
    C4MemReg *r = c4_mem_reg(h, "reset");
    if (r->is_pool) {
        for (size_t i = 0; i < r->count; i++)
            r->stack[i] = (unsigned)(r->count - 1 - i);
        r->free_top = r->count;
        r->live = 0;
    } else {
        r->bump = 0;
        r->allocs = 0;
    }
    if (r->len)
        memset(r->buf, 0, r->len);
    return c4_nil();
}

/* ======== block module (0.4.2): sector devices (ramdisk + file images).
   Sectors cross as lists of 512 byte-numbers (C strings can't hold NULs);
   read_text/write_text cut at the first zero byte on both sides. ======== */

#define C4_BLOCK_MAX 32
#define C4_BLOCK_SECTOR 512
#define C4_BLOCK_MAXSECTORS 131072

typedef struct {
    int used, is_file;
    unsigned char *buf;
    FILE *f;
    size_t sectors, reads, writes;
} C4BlockDev;

static C4BlockDev c4_block_devs[C4_BLOCK_MAX];

static void c4_block_fail(const char *op, const char *msg) {
    char b[128];
    snprintf(b, sizeof b, "block %s %s", op, msg);
    c4_fail(b);
}

static C4BlockDev *c4_block_dev(C4Val h) {
    long id = c4_mem_int(h);
    if (id < 1 || id > C4_BLOCK_MAX || !c4_block_devs[id - 1].used)
        c4_err("TypeError");
    return &c4_block_devs[id - 1];
}

static void c4_block_range(C4BlockDev *d, long lba, long n, const char *op) {
    if (lba < 0 || n < 0 || (unsigned long)lba > 2000000000UL || (unsigned long)n > 2000000000UL || (unsigned long)n > d->sectors || (unsigned long)lba > d->sectors - (unsigned long)n)
        c4_block_fail(op, "out of range");
}

C4Val c4_block_ramdisk(C4Val n) {
    long sectors = c4_mem_int(n);
    if (sectors <= 0)
        c4_err("TypeError");
    if ((unsigned long)sectors > C4_BLOCK_MAXSECTORS)
        c4_block_fail("ramdisk", "too big");
    int id = -1;
    for (int i = 0; i < C4_BLOCK_MAX; i++)
        if (!c4_block_devs[i].used) {
            id = i;
            break;
        }
    if (id < 0)
        c4_block_fail("ramdisk", "out of memory");
    C4BlockDev *d = &c4_block_devs[id];
    memset(d, 0, sizeof *d);
    d->used = 1;
    d->sectors = (size_t)sectors;
    d->buf = calloc(d->sectors, C4_BLOCK_SECTOR);
    if (!d->buf) {
        memset(d, 0, sizeof *d);
        c4_block_fail("ramdisk", "out of memory");
    }
    return c4_num((double)(id + 1));
}

C4Val c4_block_file(C4Val p, C4Val n) {
    if (p.t != C4_STR)
        c4_err("TypeError");
    long sectors = c4_mem_int(n);
    int id = -1;
    for (int i = 0; i < C4_BLOCK_MAX; i++)
        if (!c4_block_devs[i].used) {
            id = i;
            break;
        }
    if (id < 0)
        c4_block_fail("file", "out of memory");
    FILE *f = fopen(p.str, "r+b");
    size_t actual = 0;
    if (!f) {
        if (sectors <= 0)
            c4_err("TypeError");
        if ((unsigned long)sectors > C4_BLOCK_MAXSECTORS)
            c4_block_fail("file", "too big");
        f = fopen(p.str, "w+b");
        if (!f)
            c4_block_fail("file", "file failed");
        static unsigned char zero[4096];
        memset(zero, 0, sizeof zero);
        size_t want = (size_t)sectors * C4_BLOCK_SECTOR, done = 0;
        while (done < want) {
            size_t chunk = want - done > sizeof zero ? sizeof zero : want - done;
            if (fwrite(zero, 1, chunk, f) != chunk) {
                fclose(f);
                c4_block_fail("file", "file failed");
            }
            done += chunk;
        }
        fflush(f);
        actual = (size_t)sectors;
    } else {
        if (fseek(f, 0, SEEK_END) != 0) {
            fclose(f);
            c4_block_fail("file", "file failed");
        }
        long sz = ftell(f);
        if (sz <= 0 || sz % C4_BLOCK_SECTOR != 0) {
            fclose(f);
            c4_block_fail("file", "file failed");
        }
        actual = (size_t)sz / C4_BLOCK_SECTOR;
    }
    C4BlockDev *d = &c4_block_devs[id];
    memset(d, 0, sizeof *d);
    d->used = 1;
    d->is_file = 1;
    d->f = f;
    d->sectors = actual;
    return c4_num((double)(id + 1));
}

C4Val c4_block_sectors(C4Val h) {
    return c4_num((double)c4_block_dev(h)->sectors);
}

static void c4_block_get(C4BlockDev *d, unsigned char out[C4_BLOCK_SECTOR], long lba, const char *op) {
    if (d->is_file) {
        if (fseek(d->f, lba * C4_BLOCK_SECTOR, SEEK_SET) != 0)
            c4_block_fail(op, "file failed");
        if (fread(out, 1, C4_BLOCK_SECTOR, d->f) != C4_BLOCK_SECTOR)
            c4_block_fail(op, "file failed");
    } else {
        memcpy(out, d->buf + (size_t)lba * C4_BLOCK_SECTOR, C4_BLOCK_SECTOR);
    }
    d->reads++;
}

static void c4_block_put(C4BlockDev *d, const unsigned char in[C4_BLOCK_SECTOR], long lba, const char *op) {
    if (d->is_file) {
        if (fseek(d->f, lba * C4_BLOCK_SECTOR, SEEK_SET) != 0)
            c4_block_fail(op, "file failed");
        if (fwrite(in, 1, C4_BLOCK_SECTOR, d->f) != C4_BLOCK_SECTOR)
            c4_block_fail(op, "file failed");
    } else {
        memcpy(d->buf + (size_t)lba * C4_BLOCK_SECTOR, in, C4_BLOCK_SECTOR);
    }
    d->writes++;
}

C4Val c4_block_read(C4Val h, C4Val l) {
    C4BlockDev *d = c4_block_dev(h);
    long lba = c4_mem_int(l);
    c4_block_range(d, lba, 1, "read");
    unsigned char sec[C4_BLOCK_SECTOR];
    c4_block_get(d, sec, lba, "read");
    C4Val o = c4_list();
    for (int i = 0; i < C4_BLOCK_SECTOR; i++)
        list_push(o.list, c4_num((double)sec[i]));
    return o;
}

static void c4_block_list_bytes(C4Val l, unsigned char out[C4_BLOCK_SECTOR], const char *op) {
    if (l.t != C4_LIST || l.list->len != C4_BLOCK_SECTOR)
        c4_err("TypeError");
    for (size_t i = 0; i < C4_BLOCK_SECTOR; i++) {
        C4Val v = l.list->items[i];
        if (v.t != C4_NUM || v.num != trunc(v.num) || v.num < 0 || v.num > 255)
            c4_err("TypeError");
        out[i] = (unsigned char)v.num;
    }
    (void)op;
}

C4Val c4_block_write(C4Val h, C4Val l, C4Val data) {
    C4BlockDev *d = c4_block_dev(h);
    long lba = c4_mem_int(l);
    c4_block_range(d, lba, 1, "write");
    unsigned char sec[C4_BLOCK_SECTOR];
    c4_block_list_bytes(data, sec, "write");
    c4_block_put(d, sec, lba, "write");
    return c4_nil();
}

C4Val c4_block_read_text(C4Val h, C4Val l) {
    C4BlockDev *d = c4_block_dev(h);
    long lba = c4_mem_int(l);
    c4_block_range(d, lba, 1, "read_text");
    unsigned char sec[C4_BLOCK_SECTOR];
    c4_block_get(d, sec, lba, "read_text");
    size_t end = 0;
    while (end < C4_BLOCK_SECTOR && sec[end] != 0)
        end++;
    return c4_strn((const char *)sec, end);
}

C4Val c4_block_write_text(C4Val h, C4Val l, C4Val t) {
    C4BlockDev *d = c4_block_dev(h);
    long lba = c4_mem_int(l);
    if (t.t != C4_STR)
        c4_err("TypeError");
    if (strlen(t.str) > C4_BLOCK_SECTOR)
        c4_err("TypeError");
    c4_block_range(d, lba, 1, "write_text");
    unsigned char sec[C4_BLOCK_SECTOR];
    memset(sec, 0, sizeof sec);
    memcpy(sec, t.str, strlen(t.str));
    c4_block_put(d, sec, lba, "write_text");
    return c4_nil();
}

C4Val c4_block_copy(C4Val h, C4Val d_, C4Val s_, C4Val n_) {
    C4BlockDev *d = c4_block_dev(h);
    long dst = c4_mem_int(d_), src = c4_mem_int(s_), n = c4_mem_int(n_);
    c4_block_range(d, dst, n, "copy");
    c4_block_range(d, src, n, "copy");
    if (d->is_file) {
        unsigned char tmp[C4_BLOCK_SECTOR * 8];
        long i = 0;
        while (i < n) {
            long chunk = n - i > 8 ? 8 : n - i;
            for (long k = 0; k < chunk; k++)
                c4_block_get(d, tmp + (size_t)k * C4_BLOCK_SECTOR, src + i + k, "copy");
            for (long k = 0; k < chunk; k++)
                c4_block_put(d, tmp + (size_t)k * C4_BLOCK_SECTOR, dst + i + k, "copy");
            i += chunk;
        }
    } else {
        memmove(d->buf + (size_t)dst * C4_BLOCK_SECTOR, d->buf + (size_t)src * C4_BLOCK_SECTOR, (size_t)n * C4_BLOCK_SECTOR);
    }
    d->reads += (size_t)n;
    d->writes += (size_t)n;
    return c4_nil();
}

C4Val c4_block_fill(C4Val h, C4Val l, C4Val n_, C4Val b) {
    C4BlockDev *d = c4_block_dev(h);
    long lba = c4_mem_int(l), n = c4_mem_int(n_);
    if (b.t != C4_NUM || b.num != trunc(b.num) || b.num < 0 || b.num > 255)
        c4_err("TypeError");
    c4_block_range(d, lba, n, "fill");
    if (d->is_file) {
        unsigned char tmp[C4_BLOCK_SECTOR * 8];
        memset(tmp, (int)b.num, sizeof tmp);
        long i = 0;
        while (i < n) {
            long chunk = n - i > 8 ? 8 : n - i;
            if (fseek(d->f, (lba + i) * C4_BLOCK_SECTOR, SEEK_SET) != 0)
                c4_block_fail("fill", "file failed");
            if (fwrite(tmp, 1, (size_t)chunk * C4_BLOCK_SECTOR, d->f) != (size_t)chunk * C4_BLOCK_SECTOR)
                c4_block_fail("fill", "file failed");
            i += chunk;
        }
    } else {
        memset(d->buf + (size_t)lba * C4_BLOCK_SECTOR, (int)b.num, (size_t)n * C4_BLOCK_SECTOR);
    }
    d->writes += (size_t)n;
    return c4_nil();
}

C4Val c4_block_flush(C4Val h) {
    C4BlockDev *d = c4_block_dev(h);
    if (d->is_file && fflush(d->f) != 0)
        c4_block_fail("flush", "file failed");
    return c4_nil();
}

C4Val c4_block_close(C4Val h) {
    C4BlockDev *d = c4_block_dev(h);
    if (d->is_file)
        fclose(d->f);
    else
        free(d->buf);
    memset(d, 0, sizeof *d);
    return c4_nil();
}

C4Val c4_block_stats(C4Val h) {
    C4BlockDev *d = c4_block_dev(h);
    C4Val st = c4_dict();
    dict_put(st.dict, "sectors", c4_num((double)d->sectors));
    dict_put(st.dict, "reads", c4_num((double)d->reads));
    dict_put(st.dict, "writes", c4_num((double)d->writes));
    return st;
}

/* ======== fat module (0.4.3): FAT12 with a write path on block devices.
   Stateless: BPB/FAT/root re-read per call. Geometry mirrors user/mkfat.py
   (512 sectors, 2x2-sector FATs, 16 root entries, data at rel sector 6).
   Catchable failures use c4_fail with the interpreter's exact strings. ======== */

#define C4_FAT_SECTORS 512
#define C4_FAT_NFATS 2
#define C4_FAT_ROOTN 16
#define C4_FAT_ROOTLBA (1 + 2 * C4_FAT_NFATS)
#define C4_FAT_DATALBA (C4_FAT_ROOTLBA + 1)

static void c4_fat_fail(const char *op, const char *msg) {
    char b[128];
    snprintf(b, sizeof b, "fat %s %s", op, msg);
    c4_fail(b);
}

static unsigned c4_fat_rd16(const unsigned char *b, size_t off) {
    return (unsigned)b[off] | ((unsigned)b[off + 1] << 8);
}

static void c4_fat_wr16(unsigned char *b, size_t off, unsigned v) {
    b[off] = (unsigned char)(v & 0xFF);
    b[off + 1] = (unsigned char)((v >> 8) & 0xFF);
}

static void c4_fat_wr32(unsigned char *b, size_t off, unsigned long v) {
    b[off] = (unsigned char)(v & 0xFF);
    b[off + 1] = (unsigned char)((v >> 8) & 0xFF);
    b[off + 2] = (unsigned char)((v >> 16) & 0xFF);
    b[off + 3] = (unsigned char)((v >> 24) & 0xFF);
}

static unsigned c4_fat_get12(const unsigned char *fat, unsigned cl) {
    size_t off = cl + cl / 2;
    if (cl % 2 == 0)
        return (unsigned)fat[off] | (((unsigned)fat[off + 1] & 0x0F) << 8);
    return (((unsigned)fat[off] & 0xF0) >> 4) | ((unsigned)fat[off + 1] << 4);
}

static void c4_fat_set12(unsigned char *fat, unsigned cl, unsigned val) {
    size_t off = cl + cl / 2;
    if (cl % 2 == 0) {
        fat[off] = (unsigned char)(val & 0xFF);
        fat[off + 1] = (unsigned char)((fat[off + 1] & 0xF0) | ((val >> 8) & 0x0F));
    } else {
        fat[off] = (unsigned char)((fat[off] & 0x0F) | ((val << 4) & 0xF0));
        fat[off + 1] = (unsigned char)((val >> 4) & 0xFF);
    }
}

static C4BlockDev *c4_fat_dev(C4Val h, const char *op) {
    C4BlockDev *d = c4_block_dev(h);
    unsigned char boot[512];
    if (d->sectors != C4_FAT_SECTORS)
        c4_fat_fail(op, "bad filesystem");
    c4_block_get(d, boot, 0, op);
    if (boot[510] != 0x55 || boot[511] != 0xAA || c4_fat_rd16(boot, 11) != 512)
        c4_fat_fail(op, "bad filesystem");
    return d;
}

static void c4_fat_getfat(C4BlockDev *d, unsigned char *fat, const char *op) {
    for (int k = 0; k < C4_FAT_NFATS; k++)
        c4_block_get(d, fat + (size_t)k * 512, 1 + k, op);
}

static void c4_fat_putfat(C4BlockDev *d, const unsigned char *fat, const char *op) {
    for (int k = 0; k < C4_FAT_NFATS; k++) {
        c4_block_put(d, fat + (size_t)k * 512, 1 + k, op);
        c4_block_put(d, fat + (size_t)k * 512, 1 + C4_FAT_NFATS + k, op);
    }
}

/* name83: split at first dot, 1-8 + 0-3 chars, uppercase, space-pad. */
static int c4_fat_name(const char *s, unsigned char out[11], const char *op) {
    (void)op;
    size_t len = strlen(s);
    if (len == 0 || len > 12)
        return -1;
    const char *dot = strchr(s, '.');
    if (dot && strchr(dot + 1, '.'))
        return -1;
    size_t ni = dot ? (size_t)(dot - s) : len;
    size_t ei = dot ? (size_t)(dot + 1 - s) : len;
    if (ni == 0 || ni > 8 || len - ei > 3)
        return -1;
    for (int i = 0; i < 11; i++)
        out[i] = ' ';
    for (size_t i = 0; i < ni; i++)
        out[i] = (unsigned char)toupper((unsigned char)s[i]);
    for (size_t i = ei; i < len; i++)
        out[8 + i - ei] = (unsigned char)toupper((unsigned char)s[i]);
    return 0;
}

static int c4_fat_find(C4BlockDev *d, const unsigned char nm[11], int *is_new, const char *op) {
    unsigned char root[512];
    c4_block_get(d, root, C4_FAT_ROOTLBA, op);
    int first_empty = -1;
    for (int i = 0; i < C4_FAT_ROOTN; i++) {
        const unsigned char *e = root + (size_t)i * 32;
        if (e[0] == 0x00) {
            *is_new = 1;
            return first_empty >= 0 ? first_empty : i;
        }
        if (e[0] == 0xE5) {
            if (first_empty < 0)
                first_empty = i;
            continue;
        }
        if (memcmp(e, nm, 11) == 0) {
            *is_new = 0;
            return i;
        }
    }
    if (first_empty >= 0) {
        *is_new = 1;
        return first_empty;
    }
    return -1;
}

C4Val c4_fat_format(C4Val h) {
    C4BlockDev *d = c4_block_dev(h);
    if (d->sectors != C4_FAT_SECTORS)
        c4_fat_fail("format", "bad filesystem");
    unsigned char bs[512];
    memset(bs, 0, sizeof bs);
    bs[0] = 0xEB;
    bs[1] = 0x3C;
    bs[2] = 0x90;
    memcpy(bs + 3, "C4PLUS  ", 8);
    c4_fat_wr16(bs, 11, 512);
    bs[13] = 1;
    c4_fat_wr16(bs, 14, 1);
    bs[16] = 2;
    c4_fat_wr16(bs, 17, C4_FAT_ROOTN);
    c4_fat_wr16(bs, 19, C4_FAT_SECTORS);
    bs[21] = 0xF0;
    c4_fat_wr16(bs, 22, C4_FAT_NFATS);
    c4_fat_wr16(bs, 24, 18);
    c4_fat_wr16(bs, 26, 2);
    bs[510] = 0x55;
    bs[511] = 0xAA;
    c4_block_put(d, bs, 0, "format");
    unsigned char fat[C4_FAT_NFATS * 512];
    memset(fat, 0, sizeof fat);
    fat[0] = 0xF0;
    fat[1] = 0xFF;
    fat[2] = 0xFF;
    c4_fat_putfat(d, fat, "format");
    unsigned char z[512];
    memset(z, 0, sizeof z);
    c4_block_put(d, z, C4_FAT_ROOTLBA, "format");
    for (size_t lba = C4_FAT_DATALBA; lba < C4_FAT_SECTORS; lba++)
        c4_block_put(d, z, (long)lba, "format");
    return c4_nil();
}

C4Val c4_fat_ls(C4Val h) {
    C4BlockDev *d = c4_fat_dev(h, "ls");
    unsigned char root[512];
    c4_block_get(d, root, C4_FAT_ROOTLBA, "ls");
    C4Val o = c4_list();
    for (int i = 0; i < C4_FAT_ROOTN; i++) {
        const unsigned char *e = root + (size_t)i * 32;
        if (e[0] == 0x00)
            break;
        if (e[0] == 0xE5 || (e[11] & 0x08))
            continue;
        char nm[13];
        size_t ni = 8;
        while (ni > 0 && e[ni - 1] == ' ')
            ni--;
        size_t ei = 3;
        while (ei > 0 && e[8 + ei - 1] == ' ')
            ei--;
        memcpy(nm, e, ni);
        size_t ln = ni;
        if (ei > 0) {
            nm[ln++] = '.';
            memcpy(nm + ln, e + 8, ei);
            ln += ei;
        }
        nm[ln] = 0;
        list_push(o.list, c4_strn(nm, ln));
    }
    return o;
}

static unsigned long c4_fat_size(const unsigned char *e) {
    return (unsigned long)e[28] | ((unsigned long)e[29] << 8) | ((unsigned long)e[30] << 16) | ((unsigned long)e[31] << 24);
}

static C4Val c4_fat_doread(C4Val h, C4Val n, const char *op) {
    if (n.t != C4_STR)
        c4_err("TypeError");
    unsigned char nm[11];
    if (c4_fat_name(n.str, nm, op))
        c4_err("TypeError");
    C4BlockDev *d = c4_fat_dev(h, op);
    unsigned char root[512];
    c4_block_get(d, root, C4_FAT_ROOTLBA, op);
    for (int i = 0; i < C4_FAT_ROOTN; i++) {
        const unsigned char *e = root + (size_t)i * 32;
        if (e[0] == 0x00)
            break;
        if (e[0] == 0xE5 || memcmp(e, nm, 11) != 0)
            continue;
        unsigned long size = c4_fat_size(e);
        unsigned cl = c4_fat_rd16(e, 26);
        C4Val o = c4_list();
        if (cl == 0) {
            if (size != 0)
                c4_fat_fail(op, "bad filesystem");
            return o;
        }
        unsigned char fat[C4_FAT_NFATS * 512];
        c4_fat_getfat(d, fat, op);
        unsigned long left = size;
        while (1) {
            if (cl < 2 || cl - 2 >= (unsigned)(C4_FAT_SECTORS - C4_FAT_DATALBA))
                c4_fat_fail(op, "bad filesystem");
            unsigned char sec[512];
            c4_block_get(d, sec, C4_FAT_DATALBA + cl - 2, op);
            size_t take = left > 512 ? 512 : (size_t)left;
            for (size_t k = 0; k < take; k++)
                list_push(o.list, c4_num((double)sec[k]));
            left -= take;
            if (left == 0)
                break;
            unsigned nx = c4_fat_get12(fat, cl);
            if (nx < 2 || nx >= 0xFF8)
                c4_fat_fail(op, "bad filesystem");
            cl = nx;
        }
        return o;
    }
    c4_fat_fail(op, "not found");
    return c4_nil();
}

C4Val c4_fat_read(C4Val h, C4Val n) {
    return c4_fat_doread(h, n, "read");
}

C4Val c4_fat_read_text(C4Val h, C4Val n) {
    C4Val l = c4_fat_doread(h, n, "read_text");
    size_t end = 0;
    while (end < l.list->len && l.list->items[end].num != 0)
        end++;
    char *buf = xmalloc(end + 1);
    for (size_t i = 0; i < end; i++)
        buf[i] = (char)l.list->items[i].num;
    buf[end] = 0;
    C4Val v;
    v.t = C4_STR;
    v.str = buf;
    return v;
}

static void c4_fat_freechain(unsigned char *fat, unsigned cl, const char *op) {
    while (cl >= 2 && cl < 0xFF8) {
        if (cl - 2 >= C4_FAT_SECTORS - C4_FAT_DATALBA)
            c4_fat_fail(op, "bad filesystem");
        unsigned nx = c4_fat_get12(fat, cl);
        c4_fat_set12(fat, cl, 0);
        if (nx >= 0xFF8)
            break;
        cl = nx;
    }
}

static C4Val c4_fat_dowrite(C4Val h, C4Val n, C4Val data, const char *op) {
    if (n.t != C4_STR)
        c4_err("TypeError");
    unsigned char nm[11];
    if (c4_fat_name(n.str, nm, op))
        c4_err("TypeError");
    if (data.t != C4_LIST)
        c4_err("TypeError");
    for (size_t i = 0; i < data.list->len; i++) {
        C4Val v = data.list->items[i];
        if (v.t != C4_NUM || v.num != trunc(v.num) || v.num < 0 || v.num > 255)
            c4_err("TypeError");
    }
    C4BlockDev *d = c4_fat_dev(h, op);
    int is_new = 1;
    int slot = c4_fat_find(d, nm, &is_new, op);
    if (slot < 0)
        c4_fat_fail(op, "dir full");
    unsigned char root[512];
    c4_block_get(d, root, C4_FAT_ROOTLBA, op);
    unsigned char fat[C4_FAT_NFATS * 512];
    c4_fat_getfat(d, fat, op);
    if (!is_new) {
        unsigned oc = c4_fat_rd16(root + (size_t)slot * 32, 26);
        if (oc != 0)
            c4_fat_freechain(fat, oc, op);
    }
    size_t len = data.list->len, need = (len + 511) / 512;
    unsigned maxcl = C4_FAT_SECTORS - C4_FAT_DATALBA + 2;
    unsigned chain[512];
    size_t got = 0;
    for (unsigned c = 2; got < need && c < maxcl; c++)
        if (c4_fat_get12(fat, c) == 0)
            chain[got++] = c;
    if (got < need)
        c4_fat_fail(op, "no space");
    for (size_t k = 0; k < need; k++) {
        unsigned nx = k + 1 < need ? chain[k + 1] : 0xFFF;
        c4_fat_set12(fat, chain[k], nx);
        unsigned char sec[512];
        memset(sec, 0, sizeof sec);
        size_t off = k * 512, chunk = len - off > 512 ? 512 : len - off;
        for (size_t i = 0; i < chunk; i++)
            sec[i] = (unsigned char)data.list->items[off + i].num;
        c4_block_put(d, sec, C4_FAT_DATALBA + chain[k] - 2, op);
    }
    c4_fat_putfat(d, fat, op);
    unsigned char *e = root + (size_t)slot * 32;
    memcpy(e, nm, 11);
    e[11] = 0x20;
    memset(e + 12, 0, 14);
    c4_fat_wr16(e, 26, need == 0 ? 0 : chain[0]);
    c4_fat_wr32(e, 28, (unsigned long)len);
    c4_block_put(d, root, C4_FAT_ROOTLBA, op);
    return c4_nil();
}

C4Val c4_fat_write(C4Val h, C4Val n, C4Val data) {
    return c4_fat_dowrite(h, n, data, "write");
}

C4Val c4_fat_write_text(C4Val h, C4Val n, C4Val t) {
    if (t.t != C4_STR)
        c4_err("TypeError");
    size_t len = strlen(t.str);
    C4Val l = c4_list();
    for (size_t i = 0; i < len; i++)
        list_push(l.list, c4_num((double)(unsigned char)t.str[i]));
    return c4_fat_dowrite(h, n, l, "write_text");
}

C4Val c4_fat_delete(C4Val h, C4Val n) {
    if (n.t != C4_STR)
        c4_err("TypeError");
    unsigned char nm[11];
    if (c4_fat_name(n.str, nm, "delete"))
        c4_err("TypeError");
    C4BlockDev *d = c4_fat_dev(h, "delete");
    int is_new = 1;
    int slot = c4_fat_find(d, nm, &is_new, "delete");
    if (slot < 0 || is_new)
        return c4_num(0);
    unsigned char root[512];
    c4_block_get(d, root, C4_FAT_ROOTLBA, "delete");
    unsigned char *e = root + (size_t)slot * 32;
    unsigned oc = c4_fat_rd16(e, 26);
    if (oc != 0) {
        unsigned char fat[C4_FAT_NFATS * 512];
        c4_fat_getfat(d, fat, "delete");
        c4_fat_freechain(fat, oc, "delete");
        c4_fat_putfat(d, fat, "delete");
    }
    e[0] = 0xE5;
    c4_block_put(d, root, C4_FAT_ROOTLBA, "delete");
    return c4_num(1);
}

/* ======== emit parity additions (0.3.5): json, hex, random, crc32,
   collections, strings extras, time extras. All errors route through
   c4_err so try/catch catches them like the interpreter. ======== */

static const char c4_hexdigits[] = "0123456789abcdef";

static int c4_hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void c4_need_str(C4Val v) {
    if (v.t != C4_STR) c4_err("TypeError");
}

static void c4_need_list(C4Val v) {
    if (v.t != C4_LIST) c4_err("TypeError");
}

static void c4_need_num(C4Val v) {
    if (v.t != C4_NUM) c4_err("TypeError");
}

/* ---------- json ---------- */
typedef struct {
    const char *s;
    size_t n;
    size_t pos;
} C4Jp;

static void c4_jp_skip(C4Jp *p) {
    while (p->pos < p->n) {
        char c = p->s[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->pos++;
        else break;
    }
}

static C4Val c4_jp_value(C4Jp *p);

static void c4_jp_put(C4Jp *p, char **buf, size_t *len, size_t *cap, unsigned cp) {
    (void)p;
    char tmp[4];
    int n = 0;
    if (cp < 0x80) {
        tmp[n++] = (char)cp;
    } else if (cp < 0x800) {
        tmp[n++] = (char)(0xC0 | (cp >> 6));
        tmp[n++] = (char)(0x80 | (cp & 63));
    } else if (cp < 0x10000) {
        tmp[n++] = (char)(0xE0 | (cp >> 12));
        tmp[n++] = (char)(0x80 | ((cp >> 6) & 63));
        tmp[n++] = (char)(0x80 | (cp & 63));
    } else {
        tmp[n++] = (char)(0xF0 | (cp >> 18));
        tmp[n++] = (char)(0x80 | ((cp >> 12) & 63));
        tmp[n++] = (char)(0x80 | ((cp >> 6) & 63));
        tmp[n++] = (char)(0x80 | (cp & 63));
    }
    if (*len + (size_t)n + 1 >= *cap) {
        *cap = *cap ? *cap * 2 : 16;
        while (*len + (size_t)n + 1 >= *cap) *cap *= 2;
        *buf = realloc(*buf ? *buf : xmalloc(1), *cap);
        if (!*buf) c4_err("OutOfMemory");
    }
    memcpy(*buf + *len, tmp, (size_t)n);
    *len += (size_t)n;
}

static unsigned c4_jp_hex4(C4Jp *p) {
    unsigned cp = 0;
    for (int k = 0; k < 4; k++) {
        if (p->pos >= p->n) c4_err("JsonError");
        int d = c4_hexval(p->s[p->pos++]);
        if (d < 0) c4_err("JsonError");
        cp = cp * 16 + (unsigned)d;
    }
    return cp;
}

static C4Val c4_jp_string(C4Jp *p) {
    char q = p->s[p->pos++];
    char *buf = NULL;
    size_t len = 0, cap = 0;
    while (p->pos < p->n) {
        char c = p->s[p->pos++];
        if (c == q) break;
        if (c == '\\' && p->pos < p->n) {
            char e = p->s[p->pos++];
            if (e == 'u') {
                unsigned cp = c4_jp_hex4(p);
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    if (p->pos + 1 < p->n && p->s[p->pos] == '\\' && p->s[p->pos + 1] == 'u') {
                        p->pos += 2;
                        unsigned lo = c4_jp_hex4(p);
                        if (lo >= 0xDC00 && lo <= 0xDFFF) {
                            cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                        } else {
                            cp = 0xFFFD;
                        }
                    } else {
                        cp = 0xFFFD;
                    }
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    cp = 0xFFFD;
                }
                c4_jp_put(p, &buf, &len, &cap, cp);
                continue;
            }
            char o = e;
            if (e == 'n') o = '\n';
            else if (e == 'r') o = '\r';
            else if (e == 't') o = '\t';
            else if (e == 'b') o = 8;
            else if (e == 'f') o = 12;
            c = o;
        }
        if (len + 1 >= cap) {
            cap = cap ? cap * 2 : 16;
            buf = realloc(buf ? buf : xmalloc(1), cap);
            if (!buf) c4_err("OutOfMemory");
        }
        buf[len++] = c;
    }
    if (len + 1 >= cap) {
        cap = len + 1;
        buf = realloc(buf ? buf : xmalloc(1), cap);
        if (!buf) c4_err("OutOfMemory");
    }
    buf[len] = 0;
    C4Val v = c4_str(buf);
    free(buf);
    return v;
}

static C4Val c4_jp_number(C4Jp *p) {
    size_t start = p->pos;
    if (p->pos < p->n && p->s[p->pos] == '-') p->pos++;
    while (p->pos < p->n && isdigit((unsigned char)p->s[p->pos])) p->pos++;
    if (p->pos < p->n && p->s[p->pos] == '.') {
        p->pos++;
        while (p->pos < p->n && isdigit((unsigned char)p->s[p->pos])) p->pos++;
    }
    if (p->pos < p->n && (p->s[p->pos] == 'e' || p->s[p->pos] == 'E')) {
        p->pos++;
        if (p->pos < p->n && (p->s[p->pos] == '+' || p->s[p->pos] == '-')) p->pos++;
        while (p->pos < p->n && isdigit((unsigned char)p->s[p->pos])) p->pos++;
    }
    char tmp[64];
    size_t L = p->pos - start;
    if (L >= sizeof tmp) c4_err("JsonError");
    memcpy(tmp, p->s + start, L);
    tmp[L] = 0;
    return c4_num(strtod(tmp, NULL));
}

static C4Val c4_jp_array(C4Jp *p) {
    p->pos++;
    C4Val o = c4_list();
    c4_jp_skip(p);
    if (p->pos < p->n && p->s[p->pos] == ']') {
        p->pos++;
        return o;
    }
    while (1) {
        c4_jp_skip(p);
        list_push(o.list, c4_jp_value(p));
        c4_jp_skip(p);
        if (p->pos >= p->n) c4_err("JsonError");
        if (p->s[p->pos] == ']') {
            p->pos++;
            return o;
        }
        if (p->s[p->pos] != ',') c4_err("JsonError");
        p->pos++;
    }
}

static C4Val c4_jp_object(C4Jp *p) {
    p->pos++;
    C4Val o = c4_dict();
    c4_jp_skip(p);
    if (p->pos < p->n && p->s[p->pos] == '}') {
        p->pos++;
        return o;
    }
    while (1) {
        c4_jp_skip(p);
        if (p->pos >= p->n || (p->s[p->pos] != '"' && p->s[p->pos] != '\'')) c4_err("JsonError");
        C4Val k = c4_jp_string(p);
        c4_jp_skip(p);
        if (p->pos >= p->n || p->s[p->pos] != ':') c4_err("JsonError");
        p->pos++;
        C4Val v = c4_jp_value(p);
        dict_put(o.dict, k.str, v);
        c4_jp_skip(p);
        if (p->pos >= p->n) c4_err("JsonError");
        if (p->s[p->pos] == '}') {
            p->pos++;
            return o;
        }
        if (p->s[p->pos] != ',') c4_err("JsonError");
        p->pos++;
    }
}

static C4Val c4_jp_value(C4Jp *p) {
    c4_jp_skip(p);
    if (p->pos >= p->n) c4_err("JsonError");
    char c = p->s[p->pos];
    if (c == '"' || c == '\'') return c4_jp_string(p);
    if (c == '[') return c4_jp_array(p);
    if (c == '{') return c4_jp_object(p);
    if (c == '-' || isdigit((unsigned char)c)) return c4_jp_number(p);
    if (p->n - p->pos >= 4 && memcmp(p->s + p->pos, "true", 4) == 0) {
        p->pos += 4;
        return c4_num(1);
    }
    if (p->n - p->pos >= 5 && memcmp(p->s + p->pos, "false", 5) == 0) {
        p->pos += 5;
        return c4_num(0);
    }
    if (p->n - p->pos >= 4 && memcmp(p->s + p->pos, "null", 4) == 0) {
        p->pos += 4;
        return c4_nil();
    }
    c4_err("JsonError");
    return c4_nil();
}

C4Val c4_json_parse(C4Val s) {
    c4_need_str(s);
    C4Jp p = { s.str, strlen(s.str), 0 };
    C4Val v = c4_jp_value(&p);
    c4_jp_skip(&p);
    if (p.pos != p.n) c4_err("JsonError");
    return v;
}

static void c4_js_append(char **buf, size_t *len, size_t *cap, const char *s, size_t n) {
    while (*len + n + 1 > *cap) {
        *cap = *cap ? *cap * 2 : 64;
        *buf = realloc(*buf ? *buf : xmalloc(1), *cap);
        if (!*buf) c4_err("OutOfMemory");
    }
    memcpy(*buf + *len, s, n);
    *len += n;
    (*buf)[*len] = 0;
}

static void c4_js_esc(char **buf, size_t *len, size_t *cap, const char *s) {
    c4_js_append(buf, len, cap, "\"", 1);
    for (; *s; s++) {
        switch (*s) {
        case '"': c4_js_append(buf, len, cap, "\\\"", 2); break;
        case '\\': c4_js_append(buf, len, cap, "\\\\", 2); break;
        case '\n': c4_js_append(buf, len, cap, "\\n", 2); break;
        case '\r': c4_js_append(buf, len, cap, "\\r", 2); break;
        case '\t': c4_js_append(buf, len, cap, "\\t", 2); break;
        default: c4_js_append(buf, len, cap, s, 1); break;
        }
    }
    c4_js_append(buf, len, cap, "\"", 1);
}

static void c4_js_val(C4Val v, char **buf, size_t *len, size_t *cap) {
    char tmp[64];
    switch (v.t) {
    case C4_NUM: {
        if (v.num == trunc(v.num) && fabs(v.num) < 9007199254740991.0) {
            snprintf(tmp, sizeof tmp, "%lld", (long long)v.num);
        } else {
            snprintf(tmp, sizeof tmp, "%.17g", v.num);
        }
        c4_js_append(buf, len, cap, tmp, strlen(tmp));
        break;
    }
    case C4_STR:
        c4_js_esc(buf, len, cap, v.str);
        break;
    case C4_NIL:
        c4_js_append(buf, len, cap, "null", 4);
        break;
    case C4_LIST:
        c4_js_append(buf, len, cap, "[", 1);
        for (size_t i = 0; i < v.list->len; i++) {
            if (i) c4_js_append(buf, len, cap, ",", 1);
            c4_js_val(v.list->items[i], buf, len, cap);
        }
        c4_js_append(buf, len, cap, "]", 1);
        break;
    case C4_DICT:
        c4_js_append(buf, len, cap, "{", 1);
        for (size_t i = 0; i < v.dict->len; i++) {
            if (i) c4_js_append(buf, len, cap, ",", 1);
            c4_js_esc(buf, len, cap, v.dict->keys[i]);
            c4_js_append(buf, len, cap, ":", 1);
            c4_js_val(v.dict->vals[i], buf, len, cap);
        }
        c4_js_append(buf, len, cap, "}", 1);
        break;
    default:
        c4_err("TypeError");
    }
}

C4Val c4_json_stringify(C4Val v) {
    char *buf = NULL;
    size_t len = 0, cap = 0;
    c4_js_val(v, &buf, &len, &cap);
    C4Val o = c4_str(buf ? buf : "");
    free(buf);
    return o;
}

/* ---------- hex ---------- */
C4Val c4_hex_encode(C4Val v) {
    const unsigned char *bytes;
    size_t n;
    unsigned char *tmp = NULL;
    if (v.t == C4_STR) {
        bytes = (const unsigned char *)v.str;
        n = strlen(v.str);
    } else if (v.t == C4_LIST) {
        n = v.list->len;
        tmp = xmalloc(n ? n : 1);
        for (size_t i = 0; i < n; i++) {
            if (v.list->items[i].t != C4_NUM) c4_err("TypeError");
            double x = v.list->items[i].num;
            if (x != trunc(x) || x < 0 || x > 255) c4_err("TypeError");
            tmp[i] = (unsigned char)x;
        }
        bytes = tmp;
    } else {
        c4_err("TypeError");
        return c4_nil();
    }
    char *out = xmalloc(n * 2 + 1);
    for (size_t i = 0; i < n; i++) {
        out[i * 2] = c4_hexdigits[bytes[i] >> 4];
        out[i * 2 + 1] = c4_hexdigits[bytes[i] & 15];
    }
    out[n * 2] = 0;
    if (tmp) free(tmp);
    C4Val o = c4_str(out);
    free(out);
    return o;
}

C4Val c4_hex_dump(C4Val v) {
    const unsigned char *bytes;
    size_t n;
    unsigned char *tmp = NULL;
    if (v.t == C4_STR) {
        bytes = (const unsigned char *)v.str;
        n = strlen(v.str);
    } else if (v.t == C4_LIST) {
        n = v.list->len;
        tmp = xmalloc(n ? n : 1);
        for (size_t i = 0; i < n; i++) {
            if (v.list->items[i].t != C4_NUM) c4_err("TypeError");
            double x = v.list->items[i].num;
            if (x != trunc(x) || x < 0 || x > 255) c4_err("TypeError");
            tmp[i] = (unsigned char)x;
        }
        bytes = tmp;
    } else {
        c4_err("TypeError");
        return c4_nil();
    }
    char *out = xmalloc(n ? n * 3 : 1);
    for (size_t i = 0; i < n; i++) {
        if (i) out[i * 3 - 1] = ' ';
        out[i * 3] = c4_hexdigits[bytes[i] >> 4];
        out[i * 3 + 1] = c4_hexdigits[bytes[i] & 15];
    }
    if (n) out[n * 3 - 1] = 0;
    else out[0] = 0;
    if (tmp) free(tmp);
    C4Val o = c4_str(out);
    free(out);
    return o;
}

C4Val c4_hex_decode(C4Val s) {
    c4_need_str(s);
    const char *p = s.str;
    C4Val o = c4_list();
    while (*p) {
        while (*p == ' ' || *p == ',' || *p == ':' || *p == '_' || *p == '\n' || *p == '\r' || *p == '\t') p++;
        if (!*p) break;
        if (!p[1]) c4_err("BadNumber");
        int hi = c4_hexval(p[0]);
        int lo = c4_hexval(p[1]);
        if (hi < 0 || lo < 0) c4_err("BadNumber");
        list_push(o.list, c4_num((double)(hi * 16 + lo)));
        p += 2;
    }
    return o;
}

C4Val c4_hex_word(C4Val n) {
    c4_need_num(n);
    if (n.num != trunc(n.num) || n.num < 0) c4_err("TypeError");
    unsigned long long v = (unsigned long long)n.num;
    char out[17];
    for (int i = 7; i >= 0; i--) {
        out[i] = c4_hexdigits[v & 15];
        v >>= 4;
    }
    out[8] = 0;
    return c4_str(out);
}

C4Val c4_hex_parse(C4Val s) {
    c4_need_str(s);
    const char *p = s.str;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == '_') p++;
    int neg = 0;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        p += 2;
    } else if (p[0] == '-') {
        neg = 1;
        p++;
    }
    if (!*p) return c4_num(0);
    unsigned long long acc = 0;
    int digits = 0;
    while (*p) {
        int d = c4_hexval(*p);
        if (d < 0) c4_err("BadNumber");
        acc = acc * 16 + (unsigned)d;
        digits++;
        if (digits > 16) c4_err("BadNumber");
        p++;
    }
    double r = (double)acc;
    return c4_num(neg ? -r : r);
}

/* ---------- random (xorshift64*, deterministic) ---------- */
static unsigned long long c4_rng = 0x853C49E6748FEA9BULL;

static unsigned long long c4_seedmix(unsigned long long x) {
    if (x == 0) x = 0x9E3779B97F4A7C15ULL;
    x ^= x >> 30;
    x *= 0xBF58476D1CE4E5B9ULL;
    x ^= x >> 27;
    x *= 0x94D049BB133111EBULL;
    x ^= x >> 31;
    return x;
}

static unsigned long long c4_nextrand(void) {
    unsigned long long x = c4_rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    c4_rng = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static double c4_randunit(void) {
    return (double)(c4_nextrand() >> 11) / 9007199254740992.0;
}

C4Val c4_random_seed(C4Val v) {
    if (v.t == C4_NIL) {
        struct timespec ts;
        timespec_get(&ts, TIME_UTC);
        c4_rng = c4_seedmix((unsigned long long)ts.tv_nsec ^ ((unsigned long long)ts.tv_sec << 32));
    } else {
        c4_need_num(v);
        double c = v.num;
        if (c < -9e15) c = -9e15;
        if (c > 9e15) c = 9e15;
        c4_rng = c4_seedmix((unsigned long long)(long long)c);
    }
    if (c4_rng == 0) c4_rng = 0x9E3779B97F4A7C15ULL;
    return c4_nil();
}

C4Val c4_random_int(C4Val n) {
    c4_need_num(n);
    long hi = (long)n.num;
    if (hi <= 0) c4_err("MathError");
    return c4_num((double)(c4_nextrand() % (unsigned long long)hi));
}

C4Val c4_random_int2(C4Val a, C4Val b) {
    c4_need_num(a);
    c4_need_num(b);
    long lo = (long)a.num, hi = (long)b.num;
    if (hi < lo) c4_err("MathError");
    unsigned long long span = (unsigned long long)(hi - lo) + 1;
    return c4_num((double)(lo + (long)(c4_nextrand() % span)));
}

C4Val c4_random_float(void) {
    return c4_num(c4_randunit());
}

C4Val c4_random_float2(C4Val a, C4Val b) {
    c4_need_num(a);
    c4_need_num(b);
    return c4_num(a.num + (b.num - a.num) * c4_randunit());
}

C4Val c4_random_chance(C4Val p) {
    c4_need_num(p);
    double q = p.num;
    if (q < 0) q = 0;
    if (q > 1) q = 1;
    return c4_num(c4_randunit() < q ? 1 : 0);
}

C4Val c4_random_pick(C4Val v) {
    if (v.t == C4_STR) {
        size_t n = strlen(v.str);
        if (n == 0) c4_err("IndexOutOfBounds");
        size_t i = (size_t)(c4_nextrand() % n);
        return c4_strn(v.str + i, 1);
    }
    c4_need_list(v);
    if (v.list->len == 0) c4_err("IndexOutOfBounds");
    return v.list->items[c4_nextrand() % v.list->len];
}

C4Val c4_random_shuffle(C4Val l) {
    c4_need_list(l);
    C4Val o = c4_list();
    for (size_t i = 0; i < l.list->len; i++)
        list_push(o.list, l.list->items[i]);
    size_t i = o.list->len;
    while (i > 1) {
        i--;
        size_t j = (size_t)(c4_nextrand() % (i + 1));
        C4Val t = o.list->items[i];
        o.list->items[i] = o.list->items[j];
        o.list->items[j] = t;
    }
    return o;
}

/* ---------- crc32 ---------- */
static unsigned c4_crc32_byte(unsigned crc, unsigned char b) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
        unsigned mask = 0u - (crc & 1u);
        crc = (crc >> 1) ^ (0xEDB88320u & mask);
    }
    return crc;
}

C4Val c4_crc32(C4Val v) {
    unsigned crc = 0xFFFFFFFFu;
    if (v.t == C4_STR) {
        const unsigned char *s = (const unsigned char *)v.str;
        while (*s)
            crc = c4_crc32_byte(crc, *s++);
    } else if (v.t == C4_LIST) {
        for (size_t i = 0; i < v.list->len; i++) {
            C4Val it = v.list->items[i];
            if (it.t != C4_NUM) c4_err("TypeError");
            double x = it.num;
            if (x != trunc(x) || x < 0 || x > 255) c4_err("TypeError");
            crc = c4_crc32_byte(crc, (unsigned char)x);
        }
    } else {
        c4_err("TypeError");
    }
    return c4_num((double)(crc ^ 0xFFFFFFFFu));
}

/* ---------- collections ---------- */
static int c4_sort_less(C4Val a, C4Val b) {
    if (a.t == C4_NUM && b.t == C4_NUM) return a.num < b.num;
    if (a.t == C4_STR && b.t == C4_STR) return strcmp(a.str, b.str) < 0;
    c4_err("TypeError");
    return 0;
}

static int c4_qsort_cmp(const void *pa, const void *pb) {
    C4Val a = *(const C4Val *)pa, b = *(const C4Val *)pb;
    if (c4_sort_less(a, b)) return -1;
    if (c4_sort_less(b, a)) return 1;
    return 0;
}

C4Val c4_sort(C4Val l) {
    c4_need_list(l);
    for (size_t i = 0; i < l.list->len; i++) {
        if (l.list->items[i].t != C4_NUM && l.list->items[i].t != C4_STR) c4_err("TypeError");
        if (i > 0) {
            int an = l.list->items[i].t == C4_NUM;
            int bn = l.list->items[0].t == C4_NUM;
            if (an != bn) c4_err("TypeError");
        }
    }
    C4Val o = c4_list();
    for (size_t i = 0; i < l.list->len; i++)
        list_push(o.list, l.list->items[i]);
    qsort(o.list->items, o.list->len, sizeof(C4Val), c4_qsort_cmp);
    return o;
}

C4Val c4_reverse(C4Val v) {
    if (v.t == C4_LIST) {
        C4Val o = c4_list();
        for (size_t i = v.list->len; i > 0; i--)
            list_push(o.list, v.list->items[i - 1]);
        return o;
    }
    if (v.t == C4_STR) {
        size_t n = strlen(v.str);
        char *out = xmalloc(n + 1);
        for (size_t i = 0; i < n; i++)
            out[i] = v.str[n - 1 - i];
        out[n] = 0;
        C4Val o = c4_str(out);
        free(out);
        return o;
    }
    c4_err("TypeError");
    return c4_nil();
}

C4Val c4_sum(C4Val l) {
    c4_need_list(l);
    double acc = 0;
    for (size_t i = 0; i < l.list->len; i++) {
        if (l.list->items[i].t != C4_NUM) c4_err("TypeError");
        acc += l.list->items[i].num;
    }
    return c4_num(acc);
}

C4Val c4_min_of(C4Val l) {
    c4_need_list(l);
    if (l.list->len == 0) c4_err("IndexOutOfBounds");
    double best = 0;
    for (size_t i = 0; i < l.list->len; i++) {
        if (l.list->items[i].t != C4_NUM) c4_err("TypeError");
        if (i == 0 || l.list->items[i].num < best) best = l.list->items[i].num;
    }
    return c4_num(best);
}

C4Val c4_max_of(C4Val l) {
    c4_need_list(l);
    if (l.list->len == 0) c4_err("IndexOutOfBounds");
    double best = 0;
    for (size_t i = 0; i < l.list->len; i++) {
        if (l.list->items[i].t != C4_NUM) c4_err("TypeError");
        if (i == 0 || l.list->items[i].num > best) best = l.list->items[i].num;
    }
    return c4_num(best);
}

C4Val c4_indexof(C4Val h, C4Val n) {
    if (h.t == C4_LIST) {
        for (size_t i = 0; i < h.list->len; i++) {
            if (c4_eq(h.list->items[i], n)) return c4_num((double)i);
        }
        return c4_num(-1);
    }
    if (h.t == C4_STR && n.t == C4_STR) {
        const char *f = strstr(h.str, n.str);
        if (!f) return c4_num(-1);
        return c4_num((double)(f - h.str));
    }
    c4_err("TypeError");
    return c4_nil();
}

C4Val c4_count(C4Val h, C4Val n) {
    double c = 0;
    if (h.t == C4_LIST) {
        for (size_t i = 0; i < h.list->len; i++) {
            if (c4_eq(h.list->items[i], n)) c++;
        }
        return c4_num(c);
    }
    if (h.t == C4_STR && n.t == C4_STR) {
        size_t nl = strlen(n.str);
        if (nl == 0) return c4_num(0);
        const char *p = h.str;
        while ((p = strstr(p, n.str)) != NULL) {
            c++;
            p += nl;
        }
        return c4_num(c);
    }
    c4_err("TypeError");
    return c4_nil();
}

C4Val c4_any(C4Val l) {
    c4_need_list(l);
    for (size_t i = 0; i < l.list->len; i++) {
        if (c4_truthy(l.list->items[i])) return c4_num(1);
    }
    return c4_num(0);
}

C4Val c4_all(C4Val l) {
    c4_need_list(l);
    for (size_t i = 0; i < l.list->len; i++) {
        if (!c4_truthy(l.list->items[i])) return c4_num(0);
    }
    return c4_num(1);
}

C4Val c4_unique(C4Val l) {
    c4_need_list(l);
    C4Val o = c4_list();
    for (size_t i = 0; i < l.list->len; i++) {
        int seen = 0;
        for (size_t j = 0; j < o.list->len; j++) {
            if (c4_eq(o.list->items[j], l.list->items[i])) {
                seen = 1;
                break;
            }
        }
        if (!seen) list_push(o.list, l.list->items[i]);
    }
    return o;
}

/* ---------- strings extras ---------- */
C4Val c4_strings_starts_with(C4Val s, C4Val p) {
    c4_need_str(s);
    c4_need_str(p);
    size_t pl = strlen(p.str);
    return c4_num(strncmp(s.str, p.str, pl) == 0 ? 1 : 0);
}

C4Val c4_strings_ends_with(C4Val s, C4Val p) {
    c4_need_str(s);
    c4_need_str(p);
    size_t sl = strlen(s.str), pl = strlen(p.str);
    if (pl > sl) return c4_num(0);
    return c4_num(strcmp(s.str + sl - pl, p.str) == 0 ? 1 : 0);
}

C4Val c4_strings_find(C4Val s, C4Val p) {
    c4_need_str(s);
    c4_need_str(p);
    const char *f = strstr(s.str, p.str);
    if (!f) return c4_num(-1);
    return c4_num((double)(f - s.str));
}

C4Val c4_strings_pad_left(C4Val s, C4Val w, C4Val ch) {
    c4_need_str(s);
    c4_need_num(w);
    long width = (long)w.num;
    if (width < 0) width = 0;
    size_t sl = strlen(s.str);
    if ((long)sl >= width) return c4_str(s.str);
    char c = ' ';
    if (ch.t == C4_STR && ch.str[0]) c = ch.str[0];
    else if (ch.t != C4_NIL) c4_err("TypeError");
    char *out = xmalloc((size_t)width + 1);
    size_t pad = (size_t)width - sl;
    memset(out, c, pad);
    memcpy(out + pad, s.str, sl + 1);
    C4Val o = c4_str(out);
    free(out);
    return o;
}

C4Val c4_strings_pad_right(C4Val s, C4Val w, C4Val ch) {
    c4_need_str(s);
    c4_need_num(w);
    long width = (long)w.num;
    if (width < 0) width = 0;
    size_t sl = strlen(s.str);
    if ((long)sl >= width) return c4_str(s.str);
    char c = ' ';
    if (ch.t == C4_STR && ch.str[0]) c = ch.str[0];
    else if (ch.t != C4_NIL) c4_err("TypeError");
    char *out = xmalloc((size_t)width + 1);
    memcpy(out, s.str, sl);
    memset(out + sl, c, (size_t)width - sl);
    out[width] = 0;
    C4Val o = c4_str(out);
    free(out);
    return o;
}

C4Val c4_strings_repeat(C4Val s, C4Val n) {
    c4_need_str(s);
    c4_need_num(n);
    long k = (long)n.num;
    if (k < 0) k = 0;
    if (k > 1000000) k = 1000000;
    size_t sl = strlen(s.str);
    char *out = xmalloc(sl * (size_t)k + 1);
    for (long i = 0; i < k; i++)
        memcpy(out + i * sl, s.str, sl);
    out[sl * (size_t)k] = 0;
    C4Val o = c4_str(out);
    free(out);
    return o;
}

C4Val c4_strings_replace_all(C4Val s, C4Val o, C4Val nw) {
    c4_need_str(s);
    c4_need_str(o);
    c4_need_str(nw);
    if (!o.str[0]) return c4_str(s.str);
    char *buf = NULL;
    size_t len = 0, cap = 0;
    const char *rest = s.str;
    size_t ol = strlen(o.str);
    const char *at;
    while ((at = strstr(rest, o.str)) != NULL) {
        c4_js_append(&buf, &len, &cap, rest, (size_t)(at - rest));
        c4_js_append(&buf, &len, &cap, nw.str, strlen(nw.str));
        rest = at + ol;
    }
    c4_js_append(&buf, &len, &cap, rest, strlen(rest));
    C4Val r = c4_str(buf ? buf : "");
    free(buf);
    return r;
}

C4Val c4_strings_lines(C4Val s) {
    c4_need_str(s);
    C4Val o = c4_list();
    const char *p = s.str;
    while (1) {
        const char *nl = strchr(p, '\n');
        size_t n = nl ? (size_t)(nl - p) : strlen(p);
        while (n > 0 && p[n - 1] == '\r') n--;
        list_push(o.list, c4_strn(p, n));
        if (!nl) break;
        p = nl + 1;
    }
    return o;
}

/* ---------- time extras ---------- */
C4Val c4_tm_ms(void) {
    static long long start = 0;
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    long long now = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    if (!start) start = now;
    return c4_num((double)(now - start));
}

C4Val c4_tm_epoch_ms(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return c4_num((double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0);
}

C4Val c4_tm_clock(void) {
    time_t t = time(NULL);
    struct tm *g = gmtime(&t);
    if (!g) c4_err("TypeError");
    return c4_num((double)(g->tm_hour * 3600 + g->tm_min * 60 + g->tm_sec));
}
