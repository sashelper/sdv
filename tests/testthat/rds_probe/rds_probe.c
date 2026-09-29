/*
 * rds_probe: parse an .rds file with librdata exactly the way StatDataViewer's
 * R reader does and print what the viewer would display. Used by tests/testthat/test-librdata-compat.R.
 *
 * Output (one item per line):
 *   STATUS OK | STATUS ERROR <message>
 *   DIM <rows> <cols>
 *   COL <i> <type> <name>\t<label>
 *   VALUE_LABELS <n>
 *   CELL <row> <col> <text>          (first N rows; text escaped: \\ \n \t \r)
 * Exit codes: 0 ok, 1 usage, 2 parse error, 3 inconsistent column data.
 *
 * Mirrors the viewer on purpose, including reading Date/Timestamp columns through
 * a double pointer: an integer-stored Date makes that read overrun its buffer,
 * which AddressSanitizer reports.
 */
#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rdata.h"

typedef struct {
    int is_str;
    double d;
    char *s;
} cell_t;

typedef struct {
    int obs_count;
    int var_count;
    int typed_columns;
    int value_labels;
    rdata_type_t *types;
    char **names;
    char **labels;
    int cap_cols;
    cell_t *values;
    size_t nvalues;
    size_t cap_values;
} probe_t;

static const char *type_text[] = {"String", "Integer", "Real", "Logical", "Timestamp", "Date"};
static const char *months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

static char *xstrdup(const char *s) {
    size_t n = strlen(s);
    char *out = malloc(n + 1);
    memcpy(out, s, n + 1);
    return out;
}

static char *trimmed(const char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    size_t n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1])) n--;
    char *out = malloc(n + 1);
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

static void ensure_cols(probe_t *p, int n) {
    if (n <= p->cap_cols) return;
    int cap = p->cap_cols ? p->cap_cols * 2 : 16;
    while (cap < n) cap *= 2;
    p->types = realloc(p->types, sizeof(*p->types) * cap);
    p->names = realloc(p->names, sizeof(*p->names) * cap);
    p->labels = realloc(p->labels, sizeof(*p->labels) * cap);
    for (int i = p->cap_cols; i < cap; i++) {
        p->names[i] = NULL;
        p->labels[i] = NULL;
    }
    p->cap_cols = cap;
}

static void push_value(probe_t *p, cell_t c) {
    if (p->nvalues == p->cap_values) {
        p->cap_values = p->cap_values ? p->cap_values * 2 : 1024;
        p->values = realloc(p->values, sizeof(cell_t) * p->cap_values);
    }
    p->values[p->nvalues++] = c;
}

static void reset(probe_t *p) {
    p->obs_count = p->var_count = p->typed_columns = p->value_labels = 0;
    p->nvalues = 0;
}

static int handle_table(const char *name, void *ctx) {
    (void)name;
    reset((probe_t *)ctx);
    return 0;
}

static int handle_column(const char *name, rdata_type_t type, void *data, long count, void *ctx) {
    (void)name;
    probe_t *p = ctx;
    if (count < 0 || count > INT_MAX) return 1;
    p->obs_count = (int)count;
    ensure_cols(p, p->typed_columns + 1);
    p->types[p->typed_columns++] = type;
    if (type == RDATA_TYPE_STRING) return 0;
    if (data == NULL && count > 0) return 1;
    switch (type) {
    case RDATA_TYPE_REAL:
    case RDATA_TYPE_TIMESTAMP:
    case RDATA_TYPE_DATE: {
        const double *dp = data; /* same as the viewer's column handler */
        for (long i = 0; i < count; i++) push_value(p, (cell_t){0, dp[i], NULL});
        break;
    }
    case RDATA_TYPE_INT32:
    case RDATA_TYPE_LOGICAL: {
        const int *ip = data;
        for (long i = 0; i < count; i++) push_value(p, (cell_t){0, (double)ip[i], NULL});
        break;
    }
    default:
        break;
    }
    return 0;
}

static int handle_column_name(const char *name, int index, void *ctx) {
    (void)index;
    probe_t *p = ctx;
    ensure_cols(p, p->var_count + 1);
    p->names[p->var_count] = xstrdup(name ? name : "");
    p->var_count++;
    return 0;
}

static int handle_text_value(const char *value, int index, void *ctx) {
    (void)index;
    probe_t *p = ctx;
    push_value(p, (cell_t){1, 0, value ? trimmed(value) : xstrdup("<NA>")});
    return 0;
}

static int handle_value_label(const char *value, int index, void *ctx) {
    (void)value;
    (void)index;
    ((probe_t *)ctx)->value_labels++;
    return 0;
}

static int handle_column_label(const char *label, int index, void *ctx) {
    probe_t *p = ctx;
    if (index < 0) return 0;
    ensure_cols(p, index + 1);
    free(p->labels[index]);
    p->labels[index] = xstrdup(label ? label : "");
    return 0;
}

/* Howard Hinnant's days -> civil algorithm (what date.h uses). */
static void civil_from_days(long z, long *y, unsigned *m, unsigned *d) {
    z += 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long yy = (long)yoe + era * 400;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    *d = doy - (153 * mp + 2) / 5 + 1;
    *m = mp < 10 ? mp + 3 : mp - 9;
    *y = yy + (*m <= 2);
}

static void format_cell(const probe_t *p, int row, int col, char *buf, size_t n) {
    const cell_t *c = &p->values[(size_t)col * p->obs_count + row];
    rdata_type_t type = p->types[col];
    if (type == RDATA_TYPE_STRING) {
        snprintf(buf, n, "%s", c->is_str ? c->s : "?");
        return;
    }
    double v = c->d;
    switch (type) {
    case RDATA_TYPE_REAL:
        if (isnan(v)) snprintf(buf, n, "NA");
        else snprintf(buf, n, "%.17g", v);
        break;
    case RDATA_TYPE_INT32:
        if (v == (double)INT_MIN) snprintf(buf, n, "NA");
        else snprintf(buf, n, "%.0f", v);
        break;
    case RDATA_TYPE_LOGICAL: {
        int t = (int)v;
        snprintf(buf, n, "%s", t == 1 ? "TRUE" : t == 0 ? "FALSE" : "NA");
        break;
    }
    case RDATA_TYPE_DATE: {
        if (isnan(v)) { snprintf(buf, n, "NA"); break; }
        long y; unsigned m, d;
        civil_from_days((long)(int)v, &y, &m, &d);
        snprintf(buf, n, "%02u%s%04ld", d, months[m - 1], y);
        break;
    }
    case RDATA_TYPE_TIMESTAMP: {
        if (isnan(v)) { snprintf(buf, n, "NA"); break; }
        long secs = (long)v;
        long days = secs >= 0 ? secs / 86400 : -((-secs + 86399) / 86400);
        long sod = secs - days * 86400;
        long y; unsigned m, d;
        civil_from_days(days, &y, &m, &d);
        snprintf(buf, n, "%02u%s%04ld:%02ld:%02ld:%02ld", d, months[m - 1], y,
                 sod / 3600, (sod / 60) % 60, sod % 60);
        break;
    }
    default:
        snprintf(buf, n, "?");
    }
}

static void print_escaped(const char *s) {
    for (; *s; s++) {
        switch (*s) {
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        default: fputc(*s, stdout);
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: rds_probe file.rds [max_rows]\n");
        return 1;
    }
    int max_rows = argc > 2 ? atoi(argv[2]) : 20;
    probe_t p;
    memset(&p, 0, sizeof(p));

    rdata_parser_t *parser = rdata_parser_init();
    rdata_set_table_handler(parser, &handle_table);
    rdata_set_column_handler(parser, &handle_column);
    rdata_set_column_name_handler(parser, &handle_column_name);
    rdata_set_text_value_handler(parser, &handle_text_value);
    rdata_set_value_label_handler(parser, &handle_value_label);
    rdata_set_column_label_handler(parser, &handle_column_label);
    rdata_error_t err = rdata_parse(parser, argv[1], &p);
    rdata_parser_free(parser);

    if (err != RDATA_OK) {
        printf("STATUS ERROR %s\n", rdata_error_message(err));
        return 2;
    }
    printf("STATUS OK\n");
    printf("DIM %d %d\n", p.obs_count, p.var_count);
    if (p.typed_columns != p.var_count || p.nvalues != (size_t)p.obs_count * p.var_count) {
        printf("INCONSISTENT typed_columns=%d names=%d values=%zu\n",
               p.typed_columns, p.var_count, p.nvalues);
        return 3;
    }
    for (int i = 0; i < p.var_count; i++) {
        printf("COL %d %s ", i + 1, type_text[p.types[i]]);
        print_escaped(p.names[i]);
        fputc('\t', stdout);
        print_escaped(p.labels[i] ? p.labels[i] : "");
        fputc('\n', stdout);
    }
    printf("VALUE_LABELS %d\n", p.value_labels);
    char buf[4096];
    int rows = p.obs_count < max_rows ? p.obs_count : max_rows;
    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < p.var_count; c++) {
            format_cell(&p, r, c, buf, sizeof(buf));
            printf("CELL %d %d ", r + 1, c + 1);
            print_escaped(buf);
            fputc('\n', stdout);
        }
    }
    return 0;
}
