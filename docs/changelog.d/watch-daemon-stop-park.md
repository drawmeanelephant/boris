### Fixed

- The managed watch daemon no longer lets trailing spool events resurrect a
  parked daemon: an explicit stop now parks the state `idle` for good, even
  when the dying compiler's final bytes carry a `build-started` (or other
  build boundary) event that races the teardown. Late events are still
  recorded in the event log as factual history (seq, cycle, ring buffer)
  but no longer flip the lifecycle state; the next explicit start clears
  the parked flag and events apply normally again.
