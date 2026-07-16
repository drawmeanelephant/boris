<Aside kind="tip">

Share repeated authoring notes with include directives. Paths are relative to
the **content root**, use only safe segments (`A–Z a–z 0–9 . _ -` plus `/`),
and must not contain `..`. The content-root `includes/` directory is never
discovered as pages.

Example (keep examples in fenced code on pages so they stay literal):

```markdown
{{include includes/shared-callout.md}}
```

</Aside>
