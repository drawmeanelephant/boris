---
title: "`src/llms.zig` evidence and cases"
id: docs/boris/src/llms/evidence-and-cases
parent: docs/boris/src/llms
status: draft
tags: [boris, zig, source-reference, evidence, llms]
---

# `src/llms.zig` evidence and cases

## Inline test

```zig
test "summary uses first body paragraph and falls back to title" {
    const gpa = std.testing.allocator;
    const got = try summary(gpa, "---\nid: x\n---\n\n# Heading\n\nFirst useful sentence.", "Fallback");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("First useful sentence.", got);
    const fallback = try summary(gpa, "---\nid: x\n---\n\n# Heading\n", "Fallback");
    defer gpa.free(fallback);
    try std.testing.expectEqualStrings("Fallback", fallback);
}
```

**Exercised:** Two cases of `summary`. No other function is tested here.

**Evidence strength:** Directly demonstrated for the two specified inputs plus the 240-byte UTF-8-boundary truncation cases and the byte-identical repeated-generation run. Does not test multi-line paragraph joining, documents without frontmatter, or documents with only blank lines after the heading.

***

## Control flow

```text
run(io, gpa, opts)
    guard: absolute path check → error.AbsolutePath
    pipeline.compile(io, gpa, pipeline_opts)
        → content discovery + frontmatter parse + graph validate
        → returns pipeline.Result (arena-owned pages)
    early return if !result.compile.ok
    open content_dir = cwd / opts.content_root
    alloc sources[N] on gpa
    for each page: readFileAlloc(io, content_dir, page.source_path, arena)
    render(gpa, &result.compile, sources)
        buf.appendSlice(header)
        for root pages: renderPage(gpa, buf, pages, sources, visited, i, 0)
            visited[i] = true
            ```
            buf: "- [<title>](<url>): <summary text>\n"
            ```
            findChildren → recurse renderPage for each child
        fallback pass: renderPage for any !visited[i]
        buf.toOwnedSlice → []u8
    publish(io, gpa, opts.out_path, output)
        ensureParent(stage path)
        write output → stage path
        rename path → prev (ignore error)
        rename stage → path
            on error: rename prev → path (restore)
        delete prev (ignore error)
    result.published = true
    log if !quiet
    return result
```


***
