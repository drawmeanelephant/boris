/**
 * Standalone smoke tests for apex.c under ASan/UBSan (via zig cc).
 *
 * Built by: zig build test-apex-sanitize
 * Not linked into the Boris monolith — exercises the C ABI in isolation.
 *
 * Covers: empty md, small render, OOM via failing allocator, null-arg errors,
 * and that failed calls leave out_html/out_len cleared.
 */
#include "apex.h"

#include <stdio.h>
#include <string.h>

static int g_fail_alloc = 0;
static int g_alloc_calls = 0;

static void *failing_alloc(void *ctx, size_t size) {
    (void)ctx;
    (void)size;
    g_alloc_calls++;
    if (g_fail_alloc) return NULL;
    /* Should not reach success path when g_fail_alloc is set for OOM tests. */
    return NULL;
}

static void noop_free(void *ctx, void *ptr, size_t size) {
    (void)ctx;
    (void)ptr;
    (void)size;
}

static int expect_eq_int(const char *name, int got, int want) {
    if (got != want) {
        fprintf(stderr, "FAIL %s: got %d want %d\n", name, got, want);
        return 1;
    }
    return 0;
}

static int expect_true(const char *name, int cond) {
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", name);
        return 1;
    }
    return 0;
}

int main(void) {
    int fails = 0;
    char *out = (char *)0x1; /* poison */
    size_t out_len = 99;
    const char empty[] = "";
    const char md[] = "# Hi\n\n**x**\n";

    /* --- null out params --- */
    fails += expect_eq_int(
        "null outs",
        apex_render(md, sizeof(md) - 1, NULL, NULL, NULL),
        APEX_ERR_ARGS);

    /* --- null md --- */
    out = (char *)0x1;
    out_len = 99;
    fails += expect_eq_int(
        "null md",
        apex_render(NULL, 0, &out, &out_len, NULL),
        APEX_ERR_ARGS);
    fails += expect_true("null md clears out", out == NULL && out_len == 0);

    /* --- empty document (libc path) --- */
    out = (char *)0x1;
    out_len = 99;
    fails += expect_eq_int(
        "empty ok",
        apex_render(empty, 0, &out, &out_len, NULL),
        APEX_OK);
    fails += expect_true("empty len", out_len == 0);
    /* out may be NULL for empty */
    apex_free(out, out_len);

    /* --- small render (libc path) --- */
    out = NULL;
    out_len = 0;
    fails += expect_eq_int(
        "small ok",
        apex_render(md, sizeof(md) - 1, &out, &out_len, NULL),
        APEX_OK);
    fails += expect_true("small non-empty", out != NULL && out_len > 0);
    fails += expect_true("has h1", out && strstr(out, "<h1>") != NULL);
    apex_free(out, out_len);

    /* --- custom allocator OOM --- */
    g_fail_alloc = 1;
    g_alloc_calls = 0;
    ApexAllocator bad = { failing_alloc, noop_free, NULL };
    out = (char *)0x1;
    out_len = 42;
    fails += expect_eq_int(
        "oom",
        apex_render(md, sizeof(md) - 1, &out, &out_len, &bad),
        APEX_ERR_OOM);
    fails += expect_true("oom clears out", out == NULL && out_len == 0);
    fails += expect_true("oom called alloc", g_alloc_calls > 0);

    /* --- incomplete custom allocator --- */
    ApexAllocator incomplete = { NULL, noop_free, NULL };
    out = (char *)0x1;
    out_len = 7;
    fails += expect_eq_int(
        "no alloc fn",
        apex_render(md, sizeof(md) - 1, &out, &out_len, &incomplete),
        APEX_ERR_ARGS);
    fails += expect_true("no alloc clears", out == NULL && out_len == 0);

    if (fails) {
        fprintf(stderr, "apex_sanitize_smoke: %d failure(s)\n", fails);
        return 1;
    }
    printf("apex_sanitize_smoke: ok\n");
    return 0;
}
