# hostile-instagram fixture

Adversarial **Instagram data-download** tree: every record here is something a
corrupt or malicious export can contain. Companion to `mini-instagram` (which is
the well-formed case). Nothing in this tree may escape the dump root on read or
the output root on write.

```text
hostile-instagram/
  your_instagram_activity/content/posts_1.json
  media/posts/202401/ok_1111111111111111111.jpg   # the one legitimate asset
```

| # | Record | Expected handling |
|---|--------|-------------------|
| 0 | benign control | converts normally; proves the guards are not over-broad |
| 1 | `../../../ESCAPED.txt` | uri rejected, `human_review`, never read, never copied |
| 2 | `/etc/hosts` | uri rejected (absolute paths bypass the dir fd) |
| 3 | `..\..\ESCAPED.txt` | uri rejected (Windows separator) |
| 4 | `C:/Windows/win.ini` | uri rejected (drive prefix) |
| 5 | caption containing ```` ``` ```` + `<script>` | fence widened so the caption cannot escape into live Markdown |
| 6 | mixed escaped + genuine Unicode | repair declines; `encoding: suspected-mojibake-unrepaired` |
| 7 | doubly encoded caption | one pass is insufficient; flagged, not stamped clean |

Rows 1–4 matter because the media uri is attacker-controlled text that reaches
both `readFileAlloc` (source) and `writeFile` (destination). Row 5 matters
because the product host deliberately renders raw HTML for trusted authors, so
lab output must not smuggle untrusted HTML into that pipeline.
