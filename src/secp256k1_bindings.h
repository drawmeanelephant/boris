/*
 * Boris-owned translate-c umbrella over bitcoin-core/secp256k1.
 *
 * Only the two modules the signing slice needs are exposed: extrakeys
 * (keypair + x-only public keys) and schnorrsig (BIP-340). The dependency is
 * pinned in build.zig.zon; the dependency record (tag v0.8.0, commit, source
 * digest, license, random-source boundary) lives in
 * docs/contracts/nostr-publication.md (signing section).
 */
#include "secp256k1.h"
#include "secp256k1_extrakeys.h"
#include "secp256k1_schnorrsig.h"
