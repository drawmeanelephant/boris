/**
 * Hostile Apex test double — same ABI as apex.h, deliberately violates
 * "clean outputs on error" so Zig hosts can prove they check status first.
 *
 * Linked only into the `test-apex-hostile` binary (never the product build).
 *
 * Behaviors (selected by first-line control tags in the markdown input):
 *   @HOSTILE_OOM          → APEX_ERR_OOM with dirty out_html/out_len
 *   @HOSTILE_ARGS         → APEX_ERR_ARGS with dirty out_html/out_len
 *   @HOSTILE_NULL_LEN     → APEX_OK but out_html=NULL, out_len>0
 *   @HOSTILE_UNKNOWN_ERR  → status 99 with dirty outputs
 *   (anything else)       → APEX_OK with a small static-looking HTML buffer
 *                           allocated via the custom allocator (or malloc)
 */

#include "apex.h"
#include <stdlib.h>
#include <string.h>

static int starts_with(const char *md, size_t md_len, const char *tag) {
    size_t n = strlen(tag);
    if (md_len < n) return 0;
    return memcmp(md, tag, n) == 0;
}

static void *host_alloc(const ApexAllocator *allocator, size_t size) {
    if (allocator && allocator->alloc) {
        return allocator->alloc(allocator->ctx, size);
    }
    return malloc(size);
}

int apex_render(
    const char *md,
    size_t md_len,
    char **out_html,
    size_t *out_len,
    const ApexAllocator *allocator)
{
    /* Pre-zero like a well-behaved engine — then intentionally dirty on errors. */
    if (out_html) *out_html = NULL;
    if (out_len) *out_len = 0;

    if (!md || !out_html || !out_len) {
        return APEX_ERR_ARGS;
    }
    if (allocator && !allocator->alloc) {
        return APEX_ERR_ARGS;
    }

    /* Empty input: success with empty buffer. */
    if (md_len == 0) {
        *out_html = NULL;
        *out_len = 0;
        return APEX_OK;
    }

    if (starts_with(md, md_len, "@HOSTILE_OOM")) {
        /* Dirty outputs that must be ignored by the host. */
        *out_html = (char *)(uintptr_t)0xDEADBEEF;
        *out_len = 0xBEEF;
        return APEX_ERR_OOM;
    }
    if (starts_with(md, md_len, "@HOSTILE_ARGS")) {
        *out_html = (char *)(uintptr_t)0xCAFEBABE;
        *out_len = 42;
        return APEX_ERR_ARGS;
    }
    if (starts_with(md, md_len, "@HOSTILE_NULL_LEN")) {
        *out_html = NULL;
        *out_len = 17;
        return APEX_OK; /* ABI violation: success + null + nonzero len */
    }
    if (starts_with(md, md_len, "@HOSTILE_UNKNOWN_ERR")) {
        *out_html = (char *)(uintptr_t)0xFEEDFACE;
        *out_len = 99;
        return 99;
    }

    /* Benign success path: echo a tiny HTML wrapper around a fixed string. */
    const char *prefix = "<p>hostile-ok</p>";
    size_t plen = strlen(prefix);
    char *buf = (char *)host_alloc(allocator, plen);
    if (!buf) return APEX_ERR_OOM;
    memcpy(buf, prefix, plen);
    *out_html = buf;
    *out_len = plen;
    return APEX_OK;
}

void apex_free(char *html, size_t len) {
    (void)len;
    free(html);
}

const char *apex_version(void) {
    return "hostile-0.1.0";
}
