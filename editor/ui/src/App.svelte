<script lang="ts">
  type Health = {
    status: string;
    editor_id: string;
    project: { content: boolean; default_layout: boolean; publication_profile: boolean };
  };

  type Version = { compiler_id: string };

  let connection = 'Connecting to the local host…';
  let compiler = 'Checking Boris version…';
  let project = 'Checking project conventions…';

  const token = new URLSearchParams(window.location.hash.slice(1)).get('token') ?? '';

  async function request<T>(path: string): Promise<T> {
    const response = await fetch(path, { headers: { 'X-Boris-Editor-Token': token } });
    if (!response.ok) throw new Error(`${response.status}`);
    return response.json() as Promise<T>;
  }

  async function connect() {
    if (!token) {
      connection = 'Session token missing. Launch the editor from boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
      return;
    }
    try {
      const [health, version] = await Promise.all([
        request<Health>('/api/health'),
        request<Version>('/api/version')
      ]);
      connection = `Connected to ${health.editor_id}.`;
      compiler = `Compiler: ${version.compiler_id}`;
      project = health.project.content
        ? `Project found${health.project.publication_profile ? ' with boris.json' : ''}.`
        : 'This folder is not a Boris project.';
    } catch {
      connection = 'Local host unavailable. Restart boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
    }
  }

  connect();
</script>

<svelte:head>
  <meta name="description" content="Local, compiler-backed Boris authoring environment" />
</svelte:head>

<header>
  <a class="skip-link" href="#workspace">Skip to workspace</a>
  <div>
    <p class="eyebrow">Local authoring environment</p>
    <h1>Boris Editor</h1>
  </div>
  <p class="connection" role="status" aria-live="polite">{connection}</p>
</header>

<nav aria-label="Editor sections">
  <a href="#project">Project</a>
  <a href="#source">Source</a>
  <a href="#problems">Problems</a>
  <a href="#preview">Preview</a>
</nav>

<main id="workspace" tabindex="-1">
  <section id="project" aria-labelledby="project-heading">
    <h2 id="project-heading">Project</h2>
    <p>{project}</p>
    <p>{compiler}</p>
  </section>

  <section id="source" aria-labelledby="source-heading">
    <h2 id="source-heading">Source</h2>
    <p>File editing arrives in the safe-editing slice.</p>
  </section>

  <section id="problems" aria-labelledby="problems-heading">
    <h2 id="problems-heading">Problems</h2>
    <p>Boris diagnostics are not enabled in this scaffold.</p>
  </section>

  <section id="preview" aria-labelledby="preview-heading">
    <h2 id="preview-heading">Preview</h2>
    <p>Compiler-produced preview is not enabled in this scaffold.</p>
  </section>
</main>

<footer>
  <p>Boris owns meaning. Oliver owns markup semantics. The editor owns interaction.</p>
</footer>
