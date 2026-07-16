# Synthetic scale-smoke fixture

This fixture is generated on demand by
[`tools/scale-smoke`](../../../../tools/scale-smoke/). It deliberately stores no
large checked-in content tree and is not part of the release gate.

The generator deterministically creates a valid HTML input tree with an exact
caller-selected page count, Trunk/Satellite parent relationships, nested
includes, wiki-links, and a layout. Its temporary output is owned exclusively
by `tools/scale-smoke/.generated/` and is removed after each run.
