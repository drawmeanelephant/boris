//! Upload successful artifacts to an R2-shaped binding. Host transport only.

/**
 * @param {{put: Function}} bucket
 * @param {string} prefix
 * @param {Array<{path: string, media_type: string, bytes: Uint8Array}>} artifacts
 */
export async function uploadArtifacts(bucket, prefix, artifacts) {
  // Parallel puts: sequential uploads of a typical artifact set cost hundreds
  // of ms of wall time each. Promise.all preserves key order (matches the
  // artifact order), and R2 puts are independent.
  const root = prefix.replace(/\/+$/, "");
  const keys = await Promise.all(
    artifacts.map(async (art) => {
      const key = `${root}/${art.path}`;
      await bucket.put(key, art.bytes, {
        httpMetadata: { contentType: art.media_type },
      });
      return key;
    }),
  );
  return { prefix: root, keys };
}

export function compilePrefix(now = Date.now()) {
  return `compile/${now}`;
}
