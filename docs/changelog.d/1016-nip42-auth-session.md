### Added

- Implement the opt-in NIP-42 signing supervisor and proactive article gate, with schema-2 negotiation and hostile two-process loopback tests, including startup custody, forged controls, blocked-operation teardown and entropy/signing failure injection. Invalid/overlong session keys retain content-refusal exit 1. The capability remains unreleased pending review and required CI; macOS is the only supported session launcher, and ordinary schema-1 plan/sign/publish bytes remain unchanged. See [the Nostr evidence and limits](/docs/contracts/nostr-publication.md#phase-2-implementation-notes-and-release-evidence-boundary).

### Fixed

- Reserve concurrent execution for WebSocket deadline races so worker-pool saturation cannot run a blocking operation or timer inline. Keep the full loopback write-fuzz coverage and checked allocation while avoiding per-frame allocator stack unwinding. CI prints test commands and timing summaries without raising its timeout. See [the transport evidence](/docs/contracts/nostr-publication.md#conformance-matrix).
