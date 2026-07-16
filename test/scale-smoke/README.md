# Incremental scale smoke

Run with `zig build test-scale-smoke`. The test creates a disposable 200-page
Markdown site (20 Trunks, each with 9 Satellites) below `test-output/`.

It proves a cold incremental HTML build publishes every page, an unchanged
incremental pass publishes none, and one Satellite title/body edit republishes
that Satellite and its Trunk while unrelated Trunks remain cached. The current
transitive reverse walk also republishes the edited Trunk's Satellite cohort.
It repeats the changed state with four bounded page workers and compares the
published HTML trees byte-for-byte.

It does not publish a performance benchmark, assert elapsed-time thresholds,
prove the narrowest possible dirty set, stress arbitrary graph shapes, or
replace the ordinary unit and hostile gates.
