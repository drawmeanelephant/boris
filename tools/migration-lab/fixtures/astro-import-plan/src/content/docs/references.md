---
title: Reference inventory
---

[Inline](./guide.md "Guide title")
![Inline image](/images/logo.svg)
[Nested](./guide_(old).md)
[Encoded](./with%20space.md)
[Protocol relative](//cdn.example.test/x)
[HTTP](http://example.test/a)
[HTTPS](https://example.test/b)
[Mail](mailto:docs@example.test)
[FTP](ftp://example.test/file)
[Other scheme](tel:+15551212)
[Data](data:image/png;base64,AAAA)
[Fragment](#part)
[Reference link][guide-ref]
![Reference image][logo-ref]
[Repeated](./guide.md)
[Repeated](./guide.md)

[guide-ref]: ../guide.md "Guide"
[logo-ref]: https://cdn.example.test/logo.svg

<https://example.test/autolink>
<mailto:help@example.test>

`[Code link](./not-real.md)` and ``![Code image](/not-real.png)``.
\[Escaped link](./not-real-escaped.md)

```md
[Fenced link](./not-real-either.md)
![Fenced image](/not-real-either.png)
```

[Malformed](with raw space.md)
