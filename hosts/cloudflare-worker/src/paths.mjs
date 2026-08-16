//! Canonical relative paths, matching `identity.canonicalize` enough for the host
//! to reject traversal and duplicates before any bytes enter Wasm.

function isSep(c) {
  return c === "/" || c === "\\";
}

function isDrive(path) {
  return path.length >= 2 && path[1] === ":" && /[A-Za-z]/.test(path[0]);
}

/**
 * @param {string} raw
 * @returns {string}
 */
export function canonicalize(raw) {
  if (typeof raw !== "string" || raw.length === 0) {
    throw invalidPath("empty path");
  }
  if (isSep(raw[0]) || isDrive(raw)) {
    throw invalidPath("absolute path");
  }

  let i = 0;
  if (i + 1 < raw.length && raw[i] === "." && isSep(raw[i + 1])) i += 2;

  const segs = [];
  while (i < raw.length) {
    if (isSep(raw[i])) throw invalidPath("empty path segment");
    const start = i;
    while (i < raw.length && !isSep(raw[i])) i += 1;
    const seg = raw.slice(start, i);
    if (seg.length === 0 || seg === "." || seg === "..") {
      throw invalidPath("illegal path segment");
    }
    if (/[\u0000-\u001f\u007f]/.test(seg)) {
      throw invalidPath("control character in path");
    }
    segs.push(seg);
    if (i < raw.length) {
      i += 1;
      if (i >= raw.length) throw invalidPath("trailing separator");
      if (isSep(raw[i])) throw invalidPath("empty path segment");
    }
  }
  if (segs.length === 0) throw invalidPath("empty path");
  return segs.join("/");
}

function invalidPath(message) {
  const err = new Error(message);
  err.code = "INVALID_PATH";
  return err;
}

/**
 * Validate, canonicalize, and sort files. Rejects duplicates after canonicalization.
 * @param {Array<{path: string, bytes: Uint8Array}>} files
 */
export function canonicalizeFiles(files) {
  const seen = new Map();
  const out = [];
  for (const file of files) {
    const path = canonicalize(file.path);
    if (seen.has(path)) {
      const err = new Error(`duplicate canonical path: ${path}`);
      err.code = "DUPLICATE_PATH";
      throw err;
    }
    seen.set(path, true);
    out.push({ path, bytes: file.bytes });
  }
  out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return out;
}
