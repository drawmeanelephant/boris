// editor/ui/src/lib/api.ts
// Sole place that knows the session token and sets X-Boris-Editor-Token.
// Mirrors App.svelte:414-440 on afterparty e027482.
// Security boundary: editor/src/security.zig Host/Origin/token stays here.

const launchFragment = new URLSearchParams(window.location.hash.slice(1));
export const token: string = launchFragment.get('token') ?? '';
export const launchOpenPath: string = launchFragment.get('open') ?? '';

export async function api<T>(path: string, options: RequestInit = {}): Promise<{ response: Response; data: T }> {
  const headers = new Headers(options.headers);
  headers.set('X-Boris-Editor-Token', token);
  if (options.body) headers.set('Content-Type', 'application/json');
  let response: Response;
  try {
    response = await fetch(path, { ...options, headers });
  } catch {
    return {
      response: new Response('{"error":"host_unavailable"}', {
        status: 503,
        headers: { 'Content-Type': 'application/json' },
      }),
      data: { error: 'host_unavailable' } as T,
    };
  }
  let data: T;
  try {
    data = (await response.json()) as T;
  } catch {
    data = {} as T;
  }
  return { response, data };
}

export function elapsedLabel(started: number): string {
  return `${((Date.now() - started) / 1000).toFixed(1)}s`;
}

export function hostErrorLabel(code: string | undefined): string {
  if (code === 'payload_too_large') return 'the file exceeds the 8 MiB editor bound';
  if (code === 'too_many_files') return 'the project has more than 50,000 author-owned files';
  if (code === 'host_unavailable') return 'the editor host stopped; restart boris-editor';
  if (code === 'boris_unavailable') return 'the Boris binary is not available; restart the editor';
  if (code === 'invalid_boris_version') return 'the Boris version string is not usable';
  if (code === 'unsupported_boris_artifact') return 'a generated Boris artifact is stale or unsupported; rebuild it';
  return code ?? 'request failed';
}

// Mirrors editor/src/file_api.zig `validatePath` (authoritative rule).
// Pre-check keeps an unsafe `open=` fragment from even reaching the host.
export function isLaunchOpenSafe(path: string): boolean {
  if (!path || path.length > 4096) return false;
  if (path.startsWith('/') || path.includes('\\') || path.includes('\u0000')) return false;
  if (path.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) return false;
  return path === 'boris.json' || path.startsWith('content/') || path.startsWith('themes/');
}
