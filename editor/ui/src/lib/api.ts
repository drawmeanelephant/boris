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
  if (code === 'path_not_author_owned') return 'paths must be boris.json or under content/ or themes/';
  if (code === 'invalid_path') return 'that path is not a valid project-relative file path';
  if (code === 'path_already_exists') return 'a file already exists at that path';
  if (code === 'file_not_found') return 'that file was not found';
  if (code === 'read_only') return 'that file is read-only on disk';
  if (code === 'invalid_utf8') return 'the file is not valid UTF-8';
  if (code === 'io_error') return 'the editor host could not complete the file operation';
  return code ?? 'request failed';
}

// Classifies a project-relative path the same way as editor/src/file_api.zig
// `validatePath` (syntax first, then author-owned roots). Used to pre-check
// Create/Rename before POST and to keep an unsafe `open=` fragment from
// reaching the host.
export function authorPathIssue(path: string): 'invalid_path' | 'path_not_author_owned' | undefined {
  if (!path || path.length > 4096) return 'invalid_path';
  if (path.startsWith('/') || path.includes('\\') || path.includes('\u0000')) return 'invalid_path';
  if (path.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) return 'invalid_path';
  if (path === 'boris.json' || path.startsWith('content/') || path.startsWith('themes/')) return undefined;
  return 'path_not_author_owned';
}

export function isLaunchOpenSafe(path: string): boolean {
  return authorPathIssue(path) === undefined;
}
