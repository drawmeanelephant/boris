Checks: run the key-hint conformance lint as its own fast CI lane (plain
Node, no installs) so hint/handler drift fails within seconds instead of
after the multi-minute editor-test lane; the strict `ci` aggregate
requires the lane to succeed.
