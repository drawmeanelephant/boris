# lab sample site

Small specimen for the shipped [`themes/lab`](../../themes/lab/) theme:
three color modes, the graph panel, and the dropdown rendered-search
consumer.

```bash
./zig-out/bin/boris \
  --input examples/lab-site/content \
  --theme themes/lab \
  --html-dir test-output/lab \
  --quiet
```

Open `test-output/lab/index.html` and try the mode toggle, `/` search, and
the relations / children / backlinks panel.
