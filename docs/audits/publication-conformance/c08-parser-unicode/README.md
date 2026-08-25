# C08 parser and Unicode fixture notes

The checked-in `content/` tree is the successful Unicode case. The malformed
case keeps Unicode bytes while exercising the closed-key diagnostic. BOM and
invalid/truncated UTF-8 vectors are retained by the parser tests and the
repository invalid-UTF-8 fixture; the audit report records their exact byte
construction and observed diagnostics.
