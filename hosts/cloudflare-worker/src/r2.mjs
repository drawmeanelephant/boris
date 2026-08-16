//! Upload successful artifacts to an R2-shaped binding. Host transport only.

/**
 * @param {{put: Function}} bucket
 * @param {string} prefix
 * @param {Array<{path: string, media_type: string, bytes: Uint8Array}>} artifacts
 */
export async function uploadArtifacts(bucket, prefix, artifacts) {
  const keys = [];
  const root = prefix.replace(/\/+$/, "");
  for (const art of artifacts) {
    const key = `${root}/${art.path}`;
    await bucket.put(key, art.bytes, {
      httpMetadata: { contentType: art.media_type },
    });
    keys.push(key);
  }
  return { prefix: root, keys };
}

export function compilePrefix(now = Date.now()) {
  return `compile/${now}`;
}
