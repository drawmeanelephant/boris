/**
 * Minimal Apex stub: enough markdown surface for Boris integration tests.
 * Real deployments would replace this with a production Apex build that
 * keeps the same ABI contracts in apex.h.
 *
 * Handles: ATX headings (#..######), paragraphs, blank-line splits,
 * **bold**, *italic*, `code`, and passes through raw HTML lines.
 *
 * Safety goals of this translation unit:
 *   - Allocation failure → APEX_ERR_OOM, never null-deref.
 *   - size_t overflow checks before grow / append.
 *   - No libc free/realloc on custom-allocator memory.
 *   - No retention of host pointers after apex_render returns.
 *   - On error: *out_html = NULL, *out_len = 0.
 */
#include "apex.h"

#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* SIZE_MAX is in stdint.h (via apex.h). Guard if a freestanding host omits it. */
#ifndef SIZE_MAX
#define SIZE_MAX ((size_t)-1)
#endif

const char *apex_version(void) {
    return "apex-stub/0.1.0";
}

static void *default_alloc(void *ctx, size_t size) {
    (void)ctx;
    if (size == 0) {
        /* Distinct non-null for zero-size; free-compatible with malloc(0) rules
         * is platform-dependent — avoid zero-size malloc; use a 1-byte block. */
        size = 1;
    }
    return malloc(size);
}

static void default_free(void *ctx, void *ptr, size_t size) {
    (void)ctx;
    (void)size;
    free(ptr);
}

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    const ApexAllocator *a;
} Buf;

/** Invoke host free only through the hook — never libc free on custom mem. */
static void apex_buf_free(Buf *b) {
    if (b->data != NULL && b->a != NULL && b->a->free != NULL) {
        b->a->free(b->a->ctx, b->data, b->cap);
    }
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

/**
 * Grow buffer to at least `need` bytes of capacity.
 * Returns 0 on success, -1 on overflow or allocation failure.
 * Never dereferences a null allocation result.
 */
static int buf_reserve(Buf *b, size_t need) {
    if (need <= b->cap) return 0;

    size_t ncap = b->cap ? b->cap : 256u;
    while (ncap < need) {
        if (ncap > (SIZE_MAX / 2u)) {
            /* Cannot double without wrapping; try exact need if representable. */
            if (need > b->cap) {
                ncap = need;
                break;
            }
            return -1;
        }
        ncap *= 2u;
    }

    if (b->a == NULL || b->a->alloc == NULL) return -1;

    char *nd = (char *)b->a->alloc(b->a->ctx, ncap);
    if (nd == NULL) return -1;

    if (b->data != NULL && b->len > 0) {
        /* b->len <= b->cap < ncap (or need), so copy is in-bounds. */
        memcpy(nd, b->data, b->len);
    }
    if (b->data != NULL) {
        if (b->a->free != NULL) {
            b->a->free(b->a->ctx, b->data, b->cap);
        }
    }
    b->data = nd;
    b->cap = ncap;
    return 0;
}

static int buf_append(Buf *b, const char *s, size_t n) {
    if (n == 0) return 0;
    if (s == NULL) return -1;

    /* Overflow: b->len + n must not wrap size_t. */
    if (b->len > SIZE_MAX - n) return -1;

    if (buf_reserve(b, b->len + n) != 0) return -1;
    /* After successful reserve, data is non-null and cap >= len + n. */
    if (b->data == NULL) return -1;
    memcpy(b->data + b->len, s, n);
    b->len += n;
    return 0;
}

static int buf_append_cstr(Buf *b, const char *s) {
    if (s == NULL) return -1;
    return buf_append(b, s, strlen(s));
}

static int append_escaped(Buf *b, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        switch (c) {
        case '&':
            if (buf_append_cstr(b, "&amp;") != 0) return -1;
            break;
        case '<':
            if (buf_append_cstr(b, "&lt;") != 0) return -1;
            break;
        case '>':
            if (buf_append_cstr(b, "&gt;") != 0) return -1;
            break;
        case '"':
            if (buf_append_cstr(b, "&quot;") != 0) return -1;
            break;
        default:
            if (buf_append(b, &c, 1) != 0) return -1;
            break;
        }
    }
    return 0;
}

/* Inline: **bold**, *italic*, `code` — simple non-nested scan. */
static int render_inline(Buf *b, const char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        if (i + 1 < n && s[i] == '*' && s[i + 1] == '*') {
            size_t j = i + 2;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '*')) j++;
            if (j + 1 < n) {
                if (buf_append_cstr(b, "<strong>") != 0) return -1;
                if (append_escaped(b, s + i + 2, j - (i + 2)) != 0) return -1;
                if (buf_append_cstr(b, "</strong>") != 0) return -1;
                i = j + 2;
                continue;
            }
        }
        if (s[i] == '*' && (i + 1 >= n || s[i + 1] != '*')) {
            size_t j = i + 1;
            while (j < n && s[j] != '*') j++;
            if (j < n) {
                if (buf_append_cstr(b, "<em>") != 0) return -1;
                if (append_escaped(b, s + i + 1, j - (i + 1)) != 0) return -1;
                if (buf_append_cstr(b, "</em>") != 0) return -1;
                i = j + 1;
                continue;
            }
        }
        if (s[i] == '`') {
            size_t j = i + 1;
            while (j < n && s[j] != '`') j++;
            if (j < n) {
                if (buf_append_cstr(b, "<code>") != 0) return -1;
                if (append_escaped(b, s + i + 1, j - (i + 1)) != 0) return -1;
                if (buf_append_cstr(b, "</code>") != 0) return -1;
                i = j + 1;
                continue;
            }
        }
        if (append_escaped(b, s + i, 1) != 0) return -1;
        i++;
    }
    return 0;
}

static int is_blank_line(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (!isspace((unsigned char)s[i])) return 0;
    }
    return 1;
}

static size_t count_heading(const char *line, size_t n, size_t *text_off) {
    size_t level = 0;
    while (level < n && level < 6 && line[level] == '#') level++;
    if (level == 0) return 0;
    if (level < n && line[level] != ' ' && line[level] != '\t') return 0;
    size_t i = level;
    while (i < n && (line[i] == ' ' || line[i] == '\t')) i++;
    *text_off = i;
    return level;
}

int apex_render(
    const char *md,
    size_t md_len,
    char **out_html,
    size_t *out_len,
    const ApexAllocator *allocator)
{
    /* Host must check status before reading outputs; we still sanitize both. */
    if (out_html == NULL || out_len == NULL) return APEX_ERR_ARGS;
    *out_html = NULL;
    *out_len = 0;

    if (md == NULL) return APEX_ERR_ARGS;

    ApexAllocator fallback = { default_alloc, default_free, NULL };
    const ApexAllocator *a;

    if (allocator != NULL) {
        /* Custom path: alloc required; free optional (NULL == no-op). */
        if (allocator->alloc == NULL) return APEX_ERR_ARGS;
        a = allocator;
    } else {
        a = &fallback;
    }

    Buf b;
    b.data = NULL;
    b.len = 0;
    b.cap = 0;
    b.a = a;

    size_t pos = 0;
    while (pos < md_len) {
        size_t line_start = pos;
        while (pos < md_len && md[pos] != '\n') pos++;
        size_t line_len = pos - line_start;
        if (line_len > 0 && md[line_start + line_len - 1] == '\r') line_len--;
        const char *line = md + line_start;
        if (pos < md_len && md[pos] == '\n') pos++;

        if (is_blank_line(line, line_len)) {
            continue;
        }

        /* Raw HTML block line (starts with '<'). */
        if (line_len > 0 && line[0] == '<') {
            if (buf_append(&b, line, line_len) != 0) goto fail;
            if (buf_append_cstr(&b, "\n") != 0) goto fail;
            continue;
        }

        size_t text_off = 0;
        size_t level = count_heading(line, line_len, &text_off);
        if (level > 0) {
            /* text_off <= line_len by count_heading construction. */
            char open[8];
            char close[9];
            open[0] = '<'; open[1] = 'h'; open[2] = (char)('0' + (int)level); open[3] = '>'; open[4] = 0;
            close[0] = '<'; close[1] = '/'; close[2] = 'h'; close[3] = (char)('0' + (int)level);
            close[4] = '>'; close[5] = '\n'; close[6] = 0;
            if (buf_append_cstr(&b, open) != 0) goto fail;
            if (render_inline(&b, line + text_off, line_len - text_off) != 0) goto fail;
            if (buf_append_cstr(&b, close) != 0) goto fail;
            continue;
        }

        /* Paragraph: consume consecutive non-blank lines. */
        if (buf_append_cstr(&b, "<p>") != 0) goto fail;
        if (render_inline(&b, line, line_len) != 0) goto fail;

        while (pos < md_len) {
            size_t peek = pos;
            size_t ls = peek;
            while (peek < md_len && md[peek] != '\n') peek++;
            size_t ll = peek - ls;
            if (ll > 0 && md[ls + ll - 1] == '\r') ll--;
            if (is_blank_line(md + ls, ll)) break;
            if (ll > 0 && md[ls] == '<') break;
            size_t toff = 0;
            if (count_heading(md + ls, ll, &toff) > 0) break;

            if (buf_append_cstr(&b, " ") != 0) goto fail;
            if (render_inline(&b, md + ls, ll) != 0) goto fail;
            pos = peek;
            if (pos < md_len && md[pos] == '\n') pos++;
        }
        if (buf_append_cstr(&b, "</p>\n") != 0) goto fail;
    }

    /* Success: empty document may leave data NULL and len 0. */
    if (b.len > 0 && b.data == NULL) goto fail;
    *out_html = b.data;
    *out_len = b.len;
    /* Intentionally drop local references; no global store of a / md / out. */
    return APEX_OK;

fail:
    apex_buf_free(&b);
    *out_html = NULL;
    *out_len = 0;
    return APEX_ERR_OOM;
}

/* Only valid for apex_render(..., allocator=NULL) which used malloc.
 * Callers that passed a custom ApexAllocator must not use this. */
void apex_free(char *html, size_t len) {
    (void)len;
    free(html);
}
