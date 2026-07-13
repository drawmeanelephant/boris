/**
 * Apex — C-ABI markdown rendering engine for Boris (in-process only).
 *
 * Designed for static linking into the host binary. Boris must never spawn an
 * external process to render markdown; call these functions through memory
 * pointers only.
 *
 * =============================================================================
 * Lifetime / allocator contracts (normative — host and engine)
 * =============================================================================
 *
 * Synchronous:
 *   - `apex_render` is fully synchronous. It must not schedule deferred work
 *     that re-enters `allocator` after it returns (no background threads, no
 *     lazy tables that touch the allocator later).
 *
 * Stack / call lifetime of host objects:
 *   - The host may place `ApexAllocator` (and its `ctx`) on the stack for the
 *     duration of `apex_render`, or on a longer-lived document arena. Either
 *     is valid **only** because Apex is synchronous.
 *   - Apex MUST NOT retain `allocator`, `allocator->ctx`, `md`, `out_html`, or
 *     any pointer obtained from `alloc` after `apex_render` returns.
 *   - Apex MUST NOT store those pointers in globals, caches, interning tables,
 *     or thread-locals for use on a later call.
 *
 * Custom allocator (`allocator != NULL`):
 *   - All output and scratch allocations go through `allocator->alloc`.
 *   - `allocator->free` may be called for intermediate resizes; the host may
 *     implement free as a no-op (Boris Whiteboard arena does this).
 *   - Apex MUST NOT call libc `free` / `realloc` on memory obtained from the
 *     custom allocator.
 *   - Do NOT call `apex_free` on the returned buffer. The host reclaims via
 *     its own mechanism (e.g. `ArenaAllocator.reset(.free_all)`).
 *
 * Libc path (`allocator == NULL`):
 *   - Apex uses malloc; the caller must free the result with `apex_free` only.
 *
 * Output parameters on error:
 *   - On any non-zero return, Apex leaves `*out_html == NULL` and
 *     `*out_len == 0` (or restores them to that state before returning).
 *   - Hosts must still check the status code **before** reading outputs.
 *
 * =============================================================================
 * Status codes
 * =============================================================================
 *
 *   APEX_OK       (0)  success; out_html/out_len describe the buffer
 *   APEX_ERR_ARGS (1)  invalid arguments (null md/out pointers, bad allocator)
 *   APEX_ERR_OOM  (2)  allocation failure (ordinary error, never UB)
 *
 * Other non-zero values are reserved; hosts should treat any non-zero as failure.
 */
#ifndef APEX_H
#define APEX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Success. */
#define APEX_OK 0
/** Invalid arguments (null required pointers, incomplete allocator, etc.). */
#define APEX_ERR_ARGS 1
/** Allocation failure through the active allocator. */
#define APEX_ERR_OOM 2

/**
 * Optional allocator hook so callers can place Apex output in a Zig arena.
 *
 * When `allocator` is non-NULL:
 *   - `alloc` must be non-NULL.
 *   - `free` may be NULL (treated as a no-op free — arena bulk reclaim).
 *   - `ctx` is an opaque host pointer passed back to alloc/free.
 *
 * When `allocator` is NULL, Apex uses malloc/free (caller must call apex_free).
 */
typedef void *(*apex_alloc_fn)(void *ctx, size_t size);
typedef void (*apex_free_fn)(void *ctx, void *ptr, size_t size);

typedef struct ApexAllocator {
    apex_alloc_fn alloc;
    apex_free_fn free;
    void *ctx;
} ApexAllocator;

/**
 * Render markdown into a newly allocated HTML buffer.
 *
 * Before returning success, sets `*out_html` / `*out_len`. On entry this
 * function zeros both outputs so a failed call never leaves stale pointers.
 *
 * @param md        Pointer to markdown bytes (need not be NUL-terminated).
 *                  Must be non-NULL even when `md_len == 0` (empty document).
 * @param md_len    Length of markdown payload in bytes (not a C string length).
 * @param out_html  On success: allocated HTML bytes (not always NUL-terminated;
 *                  use *out_len). Owned by the allocator used for this call.
 *                  On error: NULL.
 * @param out_len   On success: HTML byte length. On error: 0.
 * @param allocator Optional custom allocator. Pass NULL to use libc malloc.
 * @return          APEX_OK (0) on success, non-zero on error (see status codes).
 *
 * Synchronous only: must not schedule work that uses `allocator` after return.
 * Input is read only within the bounds `[md, md + md_len)`; never via strlen.
 */
int apex_render(
    const char *md,
    size_t md_len,
    char **out_html,
    size_t *out_len,
    const ApexAllocator *allocator);

/**
 * Free a buffer previously returned by apex_render **only when** that call
 * used libc malloc (`allocator == NULL`).
 *
 * No-op if html is NULL.
 *
 * FORBIDDEN when a custom ApexAllocator was used (e.g. Boris document arena):
 * calling free() on arena memory is undefined behavior / heap corruption.
 * Hosts using a custom allocator must reclaim via their own mechanism and
 * must not call this function.
 */
void apex_free(char *html, size_t len);

/**
 * Human-readable version string (static storage; never freed).
 */
const char *apex_version(void);

#ifdef __cplusplus
}
#endif

#endif /* APEX_H */
