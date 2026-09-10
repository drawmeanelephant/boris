### Fixed

- A disabled `nostr` profile section no longer requires `pubkey`, `articles`, or `relays`: those are requirements of an *enabled* section per the contract, so a staged-but-disabled surface may be `{"enabled": false}` alone. Supplied values are still validated and fail closed. Links: [Nostr publication contract](/docs/contracts/nostr-publication.md), [#894](https://github.com/drawmeanelephant/boris/issues/894).
