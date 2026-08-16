//! Boris-owned FFI wrapper over bitcoin-core/secp256k1 (BIP-340).
//!
//! This is the only module in Boris that touches a secret key or a signature
//! primitive. It is a thin, deliberately narrow boundary: marshal secret
//! bytes to a keypair, sign a 32-byte message with the BIP-340 nonce function,
//! verify. No key storage, no derivation schemes, no protocol logic.
//!
//! ## Dependency record (#492, settled 2026-08-15)
//!
//! - Implementation: bitcoin-core/secp256k1, tag `v0.8.0` (released
//!   2026-08-03; PGP-signed annotated tag object
//!   `18f07c42218765cd46148d74d9fe575795f56dce`), commit
//!   `6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d`; source archive sha256
//!   `eb52b0e9239dff7dc26be5f9623567141b8720ec47da29eb3c1e0a660d17c8bb`.
//! - License: MIT. Pinned in `build.zig.zon` via the `git+` URL (commit
//!   pin); Zig verifies the dependency tree through the recorded `.hash`.
//! - Build: compiled from source by the Zig build (`link_libc`, schnorrsig +
//!   extrakeys modules, precomputed tables ship in-tree — no configure or
//!   generator step). See `build.zig` / `src/secp256k1_bindings.h`.
//! - Nonce derivation is the **BIP-340 nonce function** (tagged
//!   `BIP0340/nonce`); RFC6979 is libsecp256k1's ECDSA nonce derivation and
//!   is not used on this path.
//! - The 32-byte NIP-01 event id is signed with
//!   `secp256k1_schnorrsig_sign32`, which takes `aux_rand32` directly;
//!   `secp256k1_schnorrsig_sign_custom` is used only if investigation
//!   demonstrates a concrete need.
//! - **Auxiliary-randomness policy**: production signing must pass fresh
//!   32-byte CSPRNG aux randomness and fails closed if it cannot be
//!   obtained; conformance/vector tests inject fixed aux bytes so expected
//!   signatures are reproducible. Context randomization
//!   (`secp256k1_context_randomize`) adds side-channel hardening; it never
//!   changes signature output.

const std = @import("std");
const c = @import("secp256k1");

/// A 32-byte secp256k1 secret key.
pub const SecretKey = [32]u8;
/// A 32-byte x-only public key (the NIP-01 `pubkey`).
pub const PublicKey = [32]u8;
/// A 64-byte BIP-340 Schnorr signature (the NIP-01 `sig`).
pub const Signature = [64]u8;

pub const Error = error{
    /// Context creation failed (libsecp256k1 did not return a context).
    ContextCreationFailed,
    /// The 32-byte secret key is not a valid secp256k1 secret (out of range
    /// or otherwise unusable).
    InvalidSecretKey,
    /// Signing failed at the C boundary.
    SigningFailed,
    /// The context could not be randomized with fresh entropy.
    ContextRandomizationFailed,
};

pub const KeyPair = struct {
    secret_key: SecretKey,
    public_key: PublicKey,
};

/// Owns one libsecp256k1 context. Not thread-safe for concurrent signing on
/// the same instance; the signing slice uses one context per process.
pub const Context = struct {
    ctx: *c.secp256k1_context,

    pub fn init() Error!Context {
        return .{ .ctx = c.secp256k1_context_create(c.SECP256K1_CONTEXT_NONE) orelse
            return error.ContextCreationFailed };
    }

    /// Like `init`, but blinds the context with fresh randomness to harden
    /// against side channels (recommended for production signing). Randomization
    /// does not change signature output.
    pub fn initRandomized(io: std.Io) Error!Context {
        var self = try init();
        errdefer self.deinit();
        var seed: [32]u8 = undefined;
        io.randomSecure(&seed) catch return error.ContextRandomizationFailed;
        if (c.secp256k1_context_randomize(self.ctx, &seed) != 1) {
            return error.ContextRandomizationFailed;
        }
        return self;
    }

    pub fn deinit(self: *Context) void {
        c.secp256k1_context_destroy(self.ctx);
        self.* = undefined;
    }

    /// Derive the keypair (secret key + x-only public key) for a 32-byte
    /// secret key. Returns `InvalidSecretKey` if the key is out of range.
    pub fn keyPairFromSecretKey(self: Context, secret_key: SecretKey) Error!KeyPair {
        var kp: c.secp256k1_keypair = undefined;
        if (c.secp256k1_keypair_create(self.ctx, &kp, &secret_key) != 1) {
            return error.InvalidSecretKey;
        }
        var xonly: c.secp256k1_xonly_pubkey = undefined;
        if (c.secp256k1_keypair_xonly_pub(self.ctx, &xonly, null, &kp) != 1) {
            return error.InvalidSecretKey;
        }
        var public_key: PublicKey = undefined;
        _ = c.secp256k1_xonly_pubkey_serialize(self.ctx, &public_key, &xonly);
        return .{ .secret_key = secret_key, .public_key = public_key };
    }

    /// The x-only public key for a secret key (NIP-01 `pubkey`).
    pub fn publicKeyFromSecretKey(self: Context, secret_key: SecretKey) Error!PublicKey {
        return (try self.keyPairFromSecretKey(secret_key)).public_key;
    }

    /// Sign a 32-byte message per BIP-340 using the BIP-340 nonce function
    /// (`BIP0340/nonce`). `aux_rand`, when provided, is 32 bytes of fresh
    /// randomness (recommended for production); `null` yields deterministic
    /// signing with zero auxiliary data, which remains BIP-340-valid. Nostr
    /// signs the 32-byte event id.
    pub fn signId(self: Context, id: [32]u8, keypair: KeyPair, aux_rand: ?[32]u8) Error!Signature {
        var kp: c.secp256k1_keypair = undefined;
        if (c.secp256k1_keypair_create(self.ctx, &kp, &keypair.secret_key) != 1) {
            return error.InvalidSecretKey;
        }
        var sig: Signature = undefined;
        const aux: ?[*]const u8 = if (aux_rand) |*a| a else null;
        if (c.secp256k1_schnorrsig_sign32(self.ctx, &sig, &id, &kp, aux) != 1) {
            return error.SigningFailed;
        }
        return sig;
    }

    /// Verify a BIP-340 signature over a 32-byte message against an x-only
    /// public key. Returns `false` (never errors) for any invalid input,
    /// including a public key that is not a valid curve point.
    pub fn verify(self: Context, sig: Signature, id: [32]u8, public_key: PublicKey) bool {
        var xonly: c.secp256k1_xonly_pubkey = undefined;
        if (c.secp256k1_xonly_pubkey_parse(self.ctx, &xonly, &public_key) != 1) {
            return false;
        }
        return c.secp256k1_schnorrsig_verify(self.ctx, &sig, &id, 32, &xonly) == 1;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Official BIP-340 test-vector rows (bitcoin/bips bip-0340/test-vectors.csv).
/// These sign the 32-byte message directly with the given auxiliary
/// randomness — exactly the `secp256k1_schnorrsig_sign32` path.
const Vector = struct {
    secret: [32]u8,
    pubkey: [32]u8,
    aux: [32]u8,
    message: [32]u8,
    signature: [64]u8,
};

fn hex64(comptime s: *const [64:0]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn hex128(comptime s: *const [128:0]u8) [64]u8 {
    var out: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

const vector_0 = Vector{
    .secret = hex64("0000000000000000000000000000000000000000000000000000000000000003"),
    .pubkey = hex64("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9"),
    .aux = hex64("0000000000000000000000000000000000000000000000000000000000000000"),
    .message = hex64("0000000000000000000000000000000000000000000000000000000000000000"),
    .signature = hex128("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"),
};

const vector_1 = Vector{
    .secret = hex64("B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF"),
    .pubkey = hex64("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"),
    .aux = hex64("0000000000000000000000000000000000000000000000000000000000000001"),
    .message = hex64("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"),
    .signature = hex128("6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"),
};

const vector_3 = Vector{
    .secret = hex64("0B432B2677937381AEF05BB02A66ECD012773062CF3FA2549E44F58ED2401710"),
    .pubkey = hex64("25D1DFF95105F5253C4022F628A996AD3A0D95FBF21D468A1B33F8C160D8F517"),
    .aux = hex64("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"),
    .message = hex64("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"),
    .signature = hex128("7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3"),
};

fn expectVector(v: Vector) !void {
    var ctx = try Context.init();
    defer ctx.deinit();
    const kp = try ctx.keyPairFromSecretKey(v.secret);
    try testing.expectEqual(v.pubkey, kp.public_key);
    const sig = try ctx.signId(v.message, kp, v.aux);
    try testing.expectEqual(v.signature, sig);
    try testing.expect(ctx.verify(sig, v.message, v.pubkey));
}

test "bip340: official vectors sign and verify (sign32 path)" {
    try expectVector(vector_0);
    try expectVector(vector_1);
    try expectVector(vector_3);
}

test "bip340: a flipped signature bit fails verification" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var bad = vector_1.signature;
    bad[0] ^= 0x01;
    try testing.expect(!ctx.verify(bad, vector_1.message, vector_1.pubkey));
}

test "bip340: the wrong public key fails verification" {
    var ctx = try Context.init();
    defer ctx.deinit();
    try testing.expect(!ctx.verify(vector_1.signature, vector_1.message, vector_0.pubkey));
}

test "bip340: a public key that is not a curve point fails verification" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const not_a_point = hex64("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
    try testing.expect(!ctx.verify(vector_1.signature, vector_1.message, not_a_point));
}

test "bip340: signing with aux randomness matches signing without (BIP-340 validity)" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const kp = try ctx.keyPairFromSecretKey(vector_1.secret);
    const aux = vector_1.aux;
    // aux bytes must not change signature validity; both sign the same id.
    const sig_a = try ctx.signId(vector_1.message, kp, null);
    const sig_b = try ctx.signId(vector_1.message, kp, aux);
    try testing.expect(ctx.verify(sig_a, vector_1.message, vector_1.pubkey));
    try testing.expect(ctx.verify(sig_b, vector_1.message, vector_1.pubkey));
}

test "bip340: an out-of-range secret key is refused" {
    var ctx = try Context.init();
    defer ctx.deinit();
    // n and above are invalid secp256k1 secrets.
    const out_of_range = hex64("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
    try testing.expectError(error.InvalidSecretKey, ctx.keyPairFromSecretKey(out_of_range));
    const zero = [_]u8{0} ** 32;
    try testing.expectError(error.InvalidSecretKey, ctx.keyPairFromSecretKey(zero));
}
