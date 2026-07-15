/**
 * Boris host Apex adapter — bridges frozen host ABI (apex.h) to real
 * ApexMarkdown Unified (vendor/apex-markdown).
 *
 * Product path (Feature 1 Chat 3):
 *   apex_render → apex_markdown_to_html(APEX_MODE_UNIFIED) → copy into host
 *   allocator → apex_free_string. No Apex heap pointers retained after return.
 *
 * Zig continues to @cImport only this host apex.h. Upstream headers are
 * compile-private to this translation unit.
 *
 * SSG safety defaults (Boris boundary):
 *   - fragment HTML (standalone=false)
 *   - file includes off (Boris has its own include graph)
 *   - plugins off
 *   - no external code highlighters
 */
/* Host ABI first (guard BORIS_APEX_HOST_H — not APEX_H). */
#include "apex.h"

/* Upstream ApexMarkdown public API (guard APEX_H). Include paths via build.zig. */
#include <apex/apex.h>

#include <stdlib.h>
#include <string.h>

const char *apex_version(void) {
    return "boris-apex/apex-markdown-1.1.11+unified";
}

static void boris_apex_options(apex_options *opts) {
    *opts = apex_options_default(); /* Unified family defaults */
    opts->mode = APEX_MODE_UNIFIED;
    opts->output_format = APEX_OUTPUT_HTML;
    opts->standalone = false; /* fragment only — Boris layouts wrap pages */
    opts->pretty = false;     /* stable, compact HTML for goldens/cache */
    opts->unsafe = true;      /* trusted author content; raw HTML allowed */
    opts->validate_utf8 = true;

    /* SSG safety / avoid double systems */
    opts->enable_file_includes = false;
    opts->enable_plugins = false;
    opts->code_highlighter = NULL;
    opts->ast_filter_count = 0;
    opts->ast_filter_commands = NULL;
}

/*
 * Ownership:
 *   Upstream apex_markdown_to_html allocates on its own heap. Boris Whiteboard
 *   requires host-allocator HTML and forbids apex_free on that buffer. Always
 *   free the Apex string with apex_free_string and either:
 *     - copy into allocator->alloc (custom / Whiteboard path), or
 *     - malloc-copy so apex_free stays plain free (libc path).
 *
 * Input NUL safety:
 *   Host ABI is ptr+len only. Upstream is given a temporary NUL-terminated
 *   copy of exactly md_len bytes so it cannot read past the slice even if an
 *   internal path uses C-string helpers.
 */
int apex_render(
    const char *md,
    size_t md_len,
    char **out_html,
    size_t *out_len,
    const ApexAllocator *allocator)
{
    if (out_html == NULL || out_len == NULL) return APEX_ERR_ARGS;
    *out_html = NULL;
    *out_len = 0;

    if (md == NULL) return APEX_ERR_ARGS;

    /* Custom allocator with null alloc is incomplete — never fall through. */
    if (allocator != NULL && allocator->alloc == NULL) {
        return APEX_ERR_ARGS;
    }

    char *nul_md = NULL;
    const char *md_for_apex;
    if (md_len == 0) {
        md_for_apex = "";
    } else {
        nul_md = (char *)malloc(md_len + 1);
        if (nul_md == NULL) {
            return APEX_ERR_OOM;
        }
        memcpy(nul_md, md, md_len);
        nul_md[md_len] = '\0';
        md_for_apex = nul_md;
    }

    apex_options opts;
    boris_apex_options(&opts);

    char *html = apex_markdown_to_html(md_for_apex, md_len, &opts);
    free(nul_md);
    nul_md = NULL;

    if (html == NULL) {
        /* Upstream returns NULL for alloc failure and some internal errors.
         * Map to OOM so Zig's status table stays small; rare non-OOM NULLs
         * still surface as failure without dirty outs. */
        return APEX_ERR_OOM;
    }

    size_t len = strlen(html);

    if (len == 0) {
        apex_free_string(html);
        *out_html = NULL;
        *out_len = 0;
        return APEX_OK;
    }

    if (allocator != NULL) {
        char *arena_html = (char *)allocator->alloc(allocator->ctx, len);
        if (arena_html == NULL) {
            apex_free_string(html);
            return APEX_ERR_OOM;
        }
        memcpy(arena_html, html, len);
        apex_free_string(html);
        *out_html = arena_html;
        *out_len = len;
    } else {
        /* libc path: return a buffer that apex_free may free with free(). */
        char *malloc_html = (char *)malloc(len);
        if (malloc_html == NULL) {
            apex_free_string(html);
            return APEX_ERR_OOM;
        }
        memcpy(malloc_html, html, len);
        apex_free_string(html);
        *out_html = malloc_html;
        *out_len = len;
    }

    return APEX_OK;
}

/* Only valid for apex_render(..., allocator=NULL) which used malloc.
 * Callers that passed a custom ApexAllocator must not use this. */
void apex_free(char *html, size_t len) {
    (void)len;
    free(html);
}
