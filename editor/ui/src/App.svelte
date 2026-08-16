<script lang="ts">
  import { tick } from 'svelte';

  type Health = {
    status: string;
    editor_id: string;
    project: { content: boolean; default_layout: boolean; publication_profile: boolean };
  };
  type Version = { compiler_id: string };
  type FileEntry = { path: string };
  type FileList = { files: FileEntry[] };
  type BufferResponse = {
    status: 'opened' | 'saved' | 'created' | 'conflict';
    path: string;
    content: string;
    fingerprint: string;
    read_only: boolean;
  };
  type RecoverySnapshot = { path: string; content: string; fingerprint: string };
  type RecoveryList = { snapshots: RecoverySnapshot[] };
  type ErrorResponse = { error?: string; status?: string };
  type CommandMode = 'validate' | 'ir_build' | 'html_build' | 'check' | 'impact';
  type FailureClass = 'success' | 'content' | 'usage' | 'io' | 'terminated';
  type PendingResolution =
    | { action: 'open'; target: string }
    | { action: 'command'; mode: CommandMode }
    | { action: 'preview'; reason: 'save' | 'manual' }
    | { action: 'restore'; snapshot: RecoverySnapshot };
  type PaletteItem =
    | { kind: 'create' }
    | { kind: 'rename' }
    | { kind: 'delete' }
    | { kind: 'save' }
    | { kind: 'command'; mode: CommandMode }
    | { kind: 'preview' }
    | { kind: 'source' }
    | { kind: 'parent' }
    | { kind: 'impact-here' }
    | { kind: 'entity'; id: string }
    | { kind: 'open'; path: string };
  type Problem = {
    severity: 'error' | 'warning' | 'info';
    code: string | null;
    message: string;
    remediation: string;
    source_path: string | null;
    line: number | null;
    column: number | null;
    id: string | null;
    origin: 'build_report' | 'analysis_report' | 'stderr' | 'process';
    position_confidence: 'exact' | 'best_effort' | 'none';
    packet: string;
  };
  type AnalysisFinding = {
    code: string;
    endpoint_type: 'page' | 'source';
    value: string;
    count: number;
    source_path: string | null;
    line: number | null;
    column: number | null;
  };
  type ImpactEndpoint = { endpoint_type: 'page' | 'source'; value: string };
  type CommandResult = {
    mode: CommandMode;
    exit_code: number | null;
    failure_class: FailureClass;
    compiler_id: string;
    report_version: string | null;
    used_stderr_fallback: boolean;
    problems: Problem[];
    findings: AnalysisFinding[];
    impact: ImpactEndpoint[];
  };
  type ProblemGroup = { key: string; label: string; problems: Problem[] };
  type JsonSchemaProperty = { type?: string | string[]; enum?: Array<string | null>; maxLength?: number; maxItems?: number; pattern?: string; items?: JsonSchemaProperty };
  type CompletionEntity = { id: string; title: string | null; parent: string | null; role: string; status: string | null; tags: string[]; relations: Array<{ kind: string; target: string }> };
  type CompletionIndex = { format: string; schema_version: number; compiler_id: string; frozen: boolean; entities: CompletionEntity[]; relation_kinds: string[]; parent_targets: string[]; layout_slots: string[] };
  type AuthoringPayload = { frontmatter_schema: { title: string; properties: Record<string, JsonSchemaProperty> }; completion: CompletionIndex | null; completion_status: 'ready' | 'build_required' };
  type CompletionKind = 'frontmatter_key' | 'status' | 'entity' | 'wiki_link' | 'parent' | 'relation_kind' | 'relation_target' | 'layout_slot';
  type Suggestion = { value: string; insert: string; detail: string };
  type PreviewState = { phase: 'idle' | 'running' | 'success' | 'failed' | 'stale'; generation: number; exit_code: number | null; used_stderr_fallback: boolean; message: string; preview_url: string };
  type GraphEndpoint = { type: 'page' | 'source'; value: string };
  type GraphNode = {
    index: number; id: string; sourcePath: string; role: string; parent: string | null;
    parentIndex: number | null; title: string | null; status: string | null; tags: string[]; bodyOffset: number;
  };
  type GraphEdge = { from: GraphEndpoint; to: GraphEndpoint; kind: 'parent' | 'include' | 'reference' };
  type GraphNav = { index: number; id: string; breadcrumb: number[]; children: number[]; siblings: number[] };
  type GraphDocument = {
    schemaVersion: string; frozen: boolean; nodes: GraphNode[]; edges: GraphEdge[];
    reverseIndex: Array<{ target: GraphEndpoint; incomingEdges: number[] }>; nav: GraphNav[];
  };
  type GraphPayload = { graph: GraphDocument | null; graph_status: 'ready' | 'build_required' };
  type GraphLink = { label: string; path: string; kind: string };

  let connection = 'Connecting to the local host…';
  let compiler = 'Checking Boris version…';
  let project = 'Checking project conventions…';
  let editorStatus = 'Choose a project file to begin editing.';
  let commandStatus = 'No Boris command has run yet.';
  let previewState = 'Preview is not running.';
  let previewData: PreviewState | null = null;
  let files: FileEntry[] = [];
  let snapshots: RecoverySnapshot[] = [];
  let activePath = '';
  let content = '';
  let baseline = '';
  let fingerprint = '';
  let readOnly = false;
  let undoStack: string[] = [];
  let redoStack: string[] = [];
  let recoveryTimer: ReturnType<typeof setInterval> | undefined;
  let conflict: BufferResponse | null = null;
  let deletedConflict = false;
  let conflictDialog: HTMLDialogElement;
  let resolutionDialog: HTMLDialogElement;
  let createDialog: HTMLDialogElement;
  let renameDialog: HTMLDialogElement;
  let deleteDialog: HTMLDialogElement;
  let paletteDialog: HTMLDialogElement;
  let createPath = 'content/new-page.md';
  let renamePath = '';
  let pendingResolution: PendingResolution | null = null;
  let commandRunning = false;
  let commandResult: CommandResult | null = null;
  let impactId = '';
  let authoring: AuthoringPayload | null = null;
  let authoringStatus = 'Loading Boris authoring vocabulary…';
  let completionKind: CompletionKind = 'frontmatter_key';
  let completionQuery = '';
  let selectedSuggestion = 0;
  let completionOpen = false;
  let paletteQuery = '';
  let paletteSelection = 0;
  let lastDialogTrigger: HTMLElement | null = null;
  let skipFocusRestore = false;
  let graphPayload: GraphPayload | null = null;
  let graphStatus = 'Loading the Boris graph…';

  $: dirty = activePath !== '' && content !== baseline;
  $: problemGroups = groupProblems(commandResult?.problems ?? []);
  $: activeProblems = (commandResult?.problems ?? []).filter(problem =>
    problem.source_path !== null && projectPathForProblem(problem.source_path) === activePath
  );
  $: suggestions = completionSuggestions(authoring, completionKind, completionQuery);
  $: if (selectedSuggestion >= suggestions.length) selectedSuggestion = Math.max(0, suggestions.length - 1);
  $: activeNode = nodeForPath(graphPayload?.graph ?? null, activePath);
  $: parentNode = activeNode?.parent ? nodeForId(graphPayload?.graph ?? null, activeNode.parent) : null;
  $: graphChildren = graphLinksForIndices(graphPayload?.graph ?? null, navForNode(graphPayload?.graph ?? null, activeNode)?.children ?? []);
  $: graphSiblings = graphLinksForIndices(graphPayload?.graph ?? null, navForNode(graphPayload?.graph ?? null, activeNode)?.siblings ?? []);
  $: graphOutgoing = outgoingGraphLinks(graphPayload?.graph ?? null, activeNode);
  $: graphBacklinks = incomingGraphLinks(graphPayload?.graph ?? null, activeNode);
  $: graphRelations = (authoring?.completion?.entities ?? []).find(entity => entity.id === activeNode?.id)?.relations ?? [];
  $: bufferWikiLinks = wikiLinksInSource(content).map(id => ({
    id, node: nodeForId(graphPayload?.graph ?? null, id)
  }));
  $: resolutionPrompt = (() => {
    const pending = pendingResolution;
    if (!pending) return '';
    if (pending.action === 'open') return `Save or discard the changes before opening ${pending.target}?`;
    if (pending.action === 'command') return `Boris commands read repository files from disk. Save or discard the changes before running ${commandLabel(pending.mode)}?`;
    if (pending.action === 'restore') return `Save or discard the changes before restoring ${pending.snapshot.path}?`;
    return 'Save or discard the changes before rebuilding the preview?';
  })();
  $: resolutionVerb = pendingResolution?.action === 'open' ? 'switch' : pendingResolution?.action === 'command' ? 'run' : pendingResolution?.action === 'restore' ? 'restore' : 'rebuild';
  $: paletteItems = (() => {
    const items: PaletteItem[] = [
      { kind: 'create' }, { kind: 'rename' }, { kind: 'delete' },
      { kind: 'save' },
      { kind: 'command', mode: 'validate' },
      { kind: 'command', mode: 'ir_build' },
      { kind: 'command', mode: 'html_build' },
      { kind: 'command', mode: 'check' },
      { kind: 'command', mode: 'impact' },
      { kind: 'preview' },
      { kind: 'source' },
      { kind: 'parent' },
      { kind: 'impact-here' }
    ];
    for (const node of graphPayload?.graph?.nodes ?? []) items.push({ kind: 'entity', id: node.id });
    for (const file of files) items.push({ kind: 'open', path: file.path });
    const needle = paletteQuery.trim().toLocaleLowerCase();
    return needle
      ? items.filter(item =>
        paletteItemLabel(item).toLocaleLowerCase().includes(needle) ||
        paletteItemDetail(item).toLocaleLowerCase().includes(needle)
      )
      : items;
  })();
  $: paletteEnabled = new Map<string, boolean>(
    paletteItems.map(item => {
      if (item.kind === 'open' || item.kind === 'source' || item.kind === 'entity') return [paletteItemKey(item), true] as const;
      if (item.kind === 'parent') return [paletteItemKey(item), parentNode !== null] as const;
      if (item.kind === 'impact-here') return [paletteItemKey(item), activeNode !== null && !commandRunning] as const;
      if (item.kind === 'save') return [paletteItemKey(item), dirty && !readOnly] as const;
      if (item.kind === 'preview') return [paletteItemKey(item), previewData?.phase !== 'running'] as const;
      if (item.kind === 'command') return [paletteItemKey(item), !commandRunning] as const;
      if (dirty) return [paletteItemKey(item), false] as const;
      return [paletteItemKey(item), item.kind === 'create' || activePath !== ''] as const;
    })
  );
  $: if (paletteEnabled.size > 0) {
    const current = paletteItems[paletteSelection];
    const currentEnabled = current ? paletteEnabled.get(paletteItemKey(current)) : undefined;
    if (!currentEnabled) {
      const first = paletteItems.findIndex(item => paletteEnabled.get(paletteItemKey(item)));
      paletteSelection = first >= 0 ? first : 0;
    }
  }

  const token = new URLSearchParams(window.location.hash.slice(1)).get('token') ?? '';

  async function api<T>(path: string, options: RequestInit = {}): Promise<{ response: Response; data: T }> {
    const headers = new Headers(options.headers);
    headers.set('X-Boris-Editor-Token', token);
    if (options.body) headers.set('Content-Type', 'application/json');
    let response: Response;
    try {
      response = await fetch(path, { ...options, headers });
    } catch {
      return {
        response: new Response('{"error":"host_unavailable"}', {
          status: 503, headers: { 'Content-Type': 'application/json' }
        }),
        data: { error: 'host_unavailable' } as T
      };
    }
    let data: T;
    try {
      data = await response.json() as T;
    } catch {
      data = {} as T;
    }
    return { response, data };
  }

  async function connect() {
    if (!token) {
      connection = 'Session token missing. Launch the editor from boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
      return;
    }
    try {
      const [healthResult, versionResult, filesResult, authoringResult, graphResult, previewResult] = await Promise.all([
        api<Health>('/api/health'),
        api<Version>('/api/version'),
        api<FileList>('/api/files'),
        api<AuthoringPayload>('/api/authoring'),
        api<GraphPayload>('/api/graph'),
        api<PreviewState>('/api/preview/state')
      ]);
      if (![healthResult, versionResult, filesResult].every(result => result.response.ok)) {
        throw new Error('host request failed');
      }
      const health = healthResult.data;
      connection = `Connected to ${health.editor_id}.`;
      compiler = `Compiler: ${versionResult.data.compiler_id}`;
      project = health.project.content
        ? `Project found${health.project.publication_profile ? ' with boris.json' : ''}.`
        : 'This folder is not a Boris project.';
      files = filesResult.data.files;
      if (authoringResult.response.ok) setAuthoring(authoringResult.data);
      else authoringStatus = 'Boris authoring vocabulary is unavailable.';
      if (graphResult.response.ok) setGraph(graphResult.data);
      else graphStatus = 'Boris graph is unavailable.';
      if (previewResult.response.ok) setPreview(previewResult.data);
      const recoveryResult = await api<RecoveryList>('/api/recovery');
      if (recoveryResult.response.ok) {
        snapshots = recoveryResult.data.snapshots;
      } else {
        editorStatus = 'Project files are available, but recovery snapshots could not be loaded.';
      }
    } catch {
      connection = 'Local host unavailable. Restart boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
    }
  }

  async function refreshFiles() {
    const result = await api<FileList>('/api/files');
    if (result.response.ok) files = result.data.files;
  }

  function loadBuffer(buffer: BufferResponse, status: string) {
    stopRecoveryTimer();
    activePath = buffer.path;
    content = buffer.content;
    baseline = buffer.content;
    fingerprint = buffer.fingerprint;
    readOnly = buffer.read_only;
    undoStack = [];
    redoStack = [];
    editorStatus = status;
  }

  async function openFile(path: string): Promise<boolean> {
    if (path === activePath) return true;
    if (dirty) {
      await requestResolution({ action: 'open', target: path });
      return false;
    }
    const result = await api<BufferResponse | ErrorResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path })
    });
    if (result.response.ok) {
      const buffer = result.data as BufferResponse;
      loadBuffer(buffer, buffer.read_only ? `Opened ${path} read-only.` : `Opened ${path}.`);
      return true;
    } else {
      editorStatus = `Could not open ${path}.`;
      return false;
    }
  }

  async function runCommand(mode: CommandMode) {
    if (dirty) {
      await requestResolution({ action: 'command', mode });
      return;
    }
    if (mode === 'impact' && !impactId.trim()) {
      commandStatus = 'Enter an entity or source endpoint before running impact.';
      return;
    }
    commandRunning = true;
    commandStatus = `Running ${commandLabel(mode)}…`;
    const body = mode === 'impact' ? { mode, impact_id: impactId.trim() } : { mode };
    const result = await api<CommandResult | ErrorResponse>('/api/commands/run', {
      method: 'POST', body: JSON.stringify(body)
    });
    commandRunning = false;
    if (!result.response.ok) {
      commandStatus = `Could not run ${commandLabel(mode)}: ${(result.data as ErrorResponse).error ?? 'request failed'}.`;
      return;
    }
    commandResult = result.data as CommandResult;
    commandStatus = `${commandLabel(mode)} finished: ${failureLabel(commandResult.failure_class, commandResult.exit_code)}.`;
    if (mode === 'html_build') {
      previewState = commandResult.failure_class === 'success'
        ? 'The last HTML build succeeded. Live preview serving arrives in the preview slice.'
        : 'The HTML build failed. Existing dist output, if any, is previous and stale.';
    }
    if (mode === 'ir_build' && commandResult.failure_class === 'success') {
      await refreshAuthoring();
      await refreshGraph();
    }
  }

  function setAuthoring(payload: AuthoringPayload) {
    authoring = payload;
    authoringStatus = payload.completion
      ? `Boris completion index ready from ${payload.completion.compiler_id}.`
      : 'Frontmatter schema ready. Build diagnostics to create graph completion data.';
  }

  async function refreshAuthoring() {
    const result = await api<AuthoringPayload>('/api/authoring');
    if (result.response.ok) setAuthoring(result.data);
    else authoringStatus = 'The Boris build succeeded, but completion.json could not be adapted.';
  }

  function setGraph(payload: GraphPayload) {
    graphPayload = payload;
    graphStatus = payload.graph
      ? `Boris graph ready (${payload.graph.nodes.length} pages).`
      : 'Build diagnostics to create the Boris graph.';
  }

  async function refreshGraph() {
    const result = await api<GraphPayload>('/api/graph');
    if (result.response.ok) setGraph(result.data);
    else graphStatus = 'The Boris build succeeded, but graph.json could not be adapted.';
  }

  function setPreview(state: PreviewState) {
    previewData = state;
    previewState = state.message;
  }

  async function rebuildPreview(reason: 'save' | 'manual' = 'manual') {
    if (dirty) {
      await requestResolution({ action: 'preview', reason });
      return;
    }
    if (previewData) previewData = { ...previewData, phase: 'running' };
    previewState = reason === 'save' ? 'Saved. Boris preview build is running…' : 'Boris preview build is running…';
    const result = await api<PreviewState | ErrorResponse>('/api/preview/rebuild', { method: 'POST', body: '{}' });
    if (result.response.ok) setPreview(result.data as PreviewState);
    else previewState = `Preview host failed: ${(result.data as ErrorResponse).error ?? 'request failed'}. Existing output is not current.`;
  }

  function completionSuggestions(payload: AuthoringPayload | null, kind: CompletionKind, query: string): Suggestion[] {
    if (!payload) return [];
    const schema = payload.frontmatter_schema.properties;
    const index = payload.completion;
    let values: Suggestion[] = [];
    if (kind === 'frontmatter_key') values = Object.entries(schema).map(([name, property]) => ({ value: name, insert: `${name}: `, detail: schemaHint(property) }));
    if (kind === 'status') values = (schema.status?.enum ?? []).filter((value): value is string => typeof value === 'string').map(value => ({ value, insert: value, detail: 'Closed enum from Boris frontmatter schema' }));
    if (kind === 'entity' || kind === 'relation_target') values = (index?.entities ?? []).map(entity => ({ value: entity.id, insert: entity.id, detail: `${entity.role}${entity.title ? ` · ${entity.title}` : ''}` }));
    if (kind === 'wiki_link') values = (index?.entities ?? []).map(entity => ({ value: entity.id, insert: `[[${entity.id}]]`, detail: entity.title ?? entity.role }));
    if (kind === 'parent') values = (index?.parent_targets ?? []).map(value => ({ value, insert: value, detail: 'Observed parent target from completion.json' }));
    if (kind === 'relation_kind') values = (index?.relation_kinds ?? []).map(value => ({ value, insert: `${value}=`, detail: 'Relation kind from completion.json' }));
    if (kind === 'layout_slot') values = (index?.layout_slots ?? []).map(value => ({ value, insert: `{{${value}}}`, detail: 'Closed layout slot from completion.json' }));
    const needle = query.trim().toLocaleLowerCase();
    return values.filter(item => !needle || item.value.toLocaleLowerCase().startsWith(needle)).slice(0, 50);
  }

  function schemaHint(property: JsonSchemaProperty): string {
    const type = Array.isArray(property.type) ? property.type.filter(value => value !== 'null').join(' or ') : (property.type ?? 'value');
    const bounds = property.maxLength ? ` · at most ${property.maxLength} characters` : property.maxItems ? ` · at most ${property.maxItems} items` : '';
    return `${type}${bounds}`;
  }

  function completionKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      completionOpen = false;
      return;
    }
    if (!suggestions.length || !completionOpen) return;
    if (event.key === 'ArrowDown') { event.preventDefault(); selectedSuggestion = (selectedSuggestion + 1) % suggestions.length; }
    if (event.key === 'ArrowUp') { event.preventDefault(); selectedSuggestion = (selectedSuggestion + suggestions.length - 1) % suggestions.length; }
    if (event.key === 'Enter') { event.preventDefault(); void insertSuggestion(suggestions[selectedSuggestion]); }
  }

  async function insertSuggestion(suggestion: Suggestion | undefined) {
    if (!suggestion || !activePath || readOnly) return;
    const editor = document.querySelector<HTMLTextAreaElement>('#source-editor');
    if (!editor) return;
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    undoStack = [...undoStack.slice(-99), content];
    redoStack = [];
    content = `${content.slice(0, start)}${suggestion.insert}${content.slice(end)}`;
    editorStatus = `Inserted ${suggestion.value} from Boris authoring vocabulary.`;
    scheduleRecovery();
    await tick();
    editor.focus();
    editor.setSelectionRange(start + suggestion.insert.length, start + suggestion.insert.length);
  }

  function commandLabel(mode: CommandMode): string {
    return ({
      validate: 'Validate project',
      ir_build: 'Build diagnostics',
      html_build: 'Build HTML',
      check: 'Check graph',
      impact: 'Run impact'
    } satisfies Record<CommandMode, string>)[mode];
  }

  function failureLabel(failure: FailureClass, exitCode: number | null): string {
    const labels: Record<FailureClass, string> = {
      success: 'Success',
      content: 'Content or graph failure',
      usage: 'Usage or configuration failure',
      io: 'I/O or system failure',
      terminated: 'Process terminated'
    };
    return exitCode === null ? labels[failure] : `${labels[failure]} (exit ${exitCode})`;
  }

  function groupProblems(problems: Problem[]): ProblemGroup[] {
    const groups = new Map<string, ProblemGroup>();
    for (const problem of problems) {
      const source = problem.source_path ?? 'Project';
      const code = problem.code ?? 'Unstructured Boris output';
      const key = `${source}\u0000${problem.severity}\u0000${code}`;
      const existing = groups.get(key);
      if (existing) {
        existing.problems.push(problem);
      } else {
        groups.set(key, { key, label: `${source} · ${problem.severity} · ${code}`, problems: [problem] });
      }
    }
    const severityOrder = { error: 0, warning: 1, info: 2 };
    return [...groups.values()].sort((left, right) => {
      const source = (left.problems[0].source_path ?? '\uffff').localeCompare(right.problems[0].source_path ?? '\uffff');
      if (source !== 0) return source;
      const severity = severityOrder[left.problems[0].severity] - severityOrder[right.problems[0].severity];
      return severity !== 0 ? severity : left.label.localeCompare(right.label);
    });
  }

  function projectPathForProblem(sourcePath: string): string {
    if (sourcePath === 'boris.json' || sourcePath.startsWith('content/') || sourcePath.startsWith('themes/')) return sourcePath;
    return `content/${sourcePath}`;
  }

  function projectPathForGraphSource(sourcePath: string): string {
    return projectPathForProblem(sourcePath);
  }

  function nodeForPath(graph: GraphDocument | null, path: string): GraphNode | null {
    if (!graph || !path) return null;
    return graph.nodes.find(node => projectPathForGraphSource(node.sourcePath) === path) ?? null;
  }

  function nodeForId(graph: GraphDocument | null, id: string): GraphNode | null {
    if (!graph) return null;
    return graph.nodes.find(node => node.id === id) ?? null;
  }

  function navForNode(graph: GraphDocument | null, node: GraphNode | null): GraphNav | null {
    if (!graph || !node) return null;
    return graph.nav.find(entry => entry.id === node.id) ?? null;
  }

  function graphLinksForIndices(graph: GraphDocument | null, indices: number[]): GraphLink[] {
    if (!graph) return [];
    return indices.flatMap(index => {
      const node = graph.nodes.find(entry => entry.index === index);
      if (!node) return [];
      return [{ label: node.title ? `${node.id} · ${node.title}` : node.id, path: projectPathForGraphSource(node.sourcePath), kind: 'page' }];
    });
  }

  function endpointPath(graph: GraphDocument | null, endpoint: GraphEndpoint): string | null {
    if (endpoint.type === 'page') {
      const node = nodeForId(graph, endpoint.value);
      return node ? projectPathForGraphSource(node.sourcePath) : null;
    }
    return projectPathForGraphSource(endpoint.value);
  }

  function outgoingGraphLinks(graph: GraphDocument | null, node: GraphNode | null): GraphLink[] {
    if (!graph || !node) return [];
    return graph.edges.flatMap(edge => {
      if (edge.from.type !== 'page' || edge.from.value !== node.id || edge.kind === 'parent') return [];
      const path = endpointPath(graph, edge.to);
      if (!path) return [];
      return [{ label: `${edge.kind} → ${edge.to.value}`, path, kind: edge.kind }];
    });
  }

  function incomingGraphLinks(graph: GraphDocument | null, node: GraphNode | null): GraphLink[] {
    if (!graph || !node) return [];
    const incoming = graph.reverseIndex.find(entry => entry.target.type === 'page' && entry.target.value === node.id);
    if (!incoming) return [];
    return incoming.incomingEdges.flatMap(index => {
      const edge = graph.edges[index];
      if (!edge) return [];
      const path = endpointPath(graph, edge.from);
      if (!path) return [];
      return [{ label: `${edge.kind} ← ${edge.from.value}`, path, kind: edge.kind }];
    });
  }

  function wikiLinksInSource(source: string): string[] {
    const ids: string[] = [];
    const seen = new Set<string>();
    const pattern = /\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]/g;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(source))) {
      const id = match[1].trim();
      if (!id || seen.has(id)) continue;
      seen.add(id);
      ids.push(id);
    }
    return ids;
  }

  async function openGraphPath(path: string) {
    await openFile(path);
  }

  async function openGraphNode(node: GraphNode | null) {
    if (!node) return;
    await openGraphPath(projectPathForGraphSource(node.sourcePath));
  }

  async function runImpactOnCurrent() {
    if (!activeNode) return;
    impactId = activeNode.id;
    await runCommand('impact');
  }

  async function navigateToProblem(problem: Problem | AnalysisFinding) {
    if (!problem.source_path) return;
    const path = projectPathForProblem(problem.source_path);
    if (!await openFile(path)) return;
    await tick();
    const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
    if (!editor) return;
    const offset = sourceOffset(content, problem.line, problem.column);
    editor.focus();
    editor.setSelectionRange(offset, offset);
    editor.scrollTop = Math.max(0, editor.scrollHeight * (offset / Math.max(1, content.length)) - editor.clientHeight / 2);
    editorStatus = problem.line
      ? `Moved to ${path}, line ${problem.line}${problem.column ? `, column ${problem.column}` : ''}.`
      : `Opened ${path} for this Boris finding.`;
  }

  function sourceOffset(source: string, line: number | null, column: number | null): number {
    if (!line || line < 1) return 0;
    let lineStart = 0;
    for (let currentLine = 1; currentLine < line; currentLine += 1) {
      const newline = source.indexOf('\n', lineStart);
      if (newline < 0) return source.length;
      lineStart = newline + 1;
    }
    if (!column || column <= 1) return lineStart;
    const lineEnd = source.indexOf('\n', lineStart);
    const text = source.slice(lineStart, lineEnd < 0 ? source.length : lineEnd);
    const wantedBytes = column - 1;
    let consumedBytes = 0;
    let codeUnits = 0;
    const encoder = new TextEncoder();
    for (const character of text) {
      const bytes = encoder.encode(character).length;
      if (consumedBytes + bytes > wantedBytes) break;
      consumedBytes += bytes;
      codeUnits += character.length;
    }
    return lineStart + codeUnits;
  }

  async function copyDiagnosticPacket(problem: Problem) {
    try {
      await navigator.clipboard.writeText(problem.packet);
      commandStatus = `Copied diagnostic packet for ${problem.code ?? 'unstructured Boris output'}.`;
    } catch {
      commandStatus = 'Could not copy the diagnostic packet. Clipboard access was denied.';
    }
  }

  function problemLocationLabel(problem: Problem | AnalysisFinding): string {
    if (!problem.source_path) return 'project';
    if (!problem.line) return problem.source_path;
    return `${problem.source_path} line ${problem.line}${problem.column ? ` column ${problem.column}` : ''}`;
  }

  function editSource(event: Event) {
    const next = (event.currentTarget as HTMLTextAreaElement).value;
    if (next === content) return;
    undoStack = [...undoStack.slice(-99), content];
    redoStack = [];
    content = next;
    editorStatus = `Unsaved changes in ${activePath}.`;
    scheduleRecovery();
  }

  function undo() {
    if (undoStack.length === 0 || readOnly) return;
    const previous = undoStack[undoStack.length - 1];
    undoStack = undoStack.slice(0, -1);
    redoStack = [...redoStack.slice(-99), content];
    content = previous;
    editorStatus = `Undid change in ${activePath}.`;
    scheduleRecovery();
  }

  function redo() {
    if (redoStack.length === 0 || readOnly) return;
    const next = redoStack[redoStack.length - 1];
    redoStack = redoStack.slice(0, -1);
    undoStack = [...undoStack.slice(-99), content];
    content = next;
    editorStatus = `Redid change in ${activePath}.`;
    scheduleRecovery();
  }

  function scheduleRecovery() {
    if (!activePath || content === baseline) {
      stopRecoveryTimer();
      if (activePath) void clearRecovery(activePath);
      return;
    }
    if (!recoveryTimer) recoveryTimer = setInterval(() => void snapshotBuffer(), 3000);
  }

  function stopRecoveryTimer() {
    if (recoveryTimer) clearInterval(recoveryTimer);
    recoveryTimer = undefined;
  }

  async function snapshotBuffer() {
    if (!activePath || content === baseline) return;
    const result = await api<ErrorResponse>('/api/recovery/snapshot', {
      method: 'POST', body: JSON.stringify({ path: activePath, content, fingerprint })
    });
    if (!result.response.ok) editorStatus = `Unsaved changes in ${activePath}; recovery snapshot failed.`;
  }

  async function saveFile(recreate = false, replacementFingerprint = fingerprint): Promise<boolean> {
    if (!activePath || readOnly || !dirty) return false;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/save', {
      method: 'POST',
      body: JSON.stringify({ path: activePath, content, fingerprint: replacementFingerprint, recreate })
    });
    if (result.response.ok) {
      const buffer = result.data as BufferResponse;
      loadBuffer(buffer, `Saved ${activePath}.`);
      snapshots = snapshots.filter(snapshot => snapshot.path !== activePath);
      conflict = null;
      deletedConflict = false;
      skipFocusRestore = true;
      conflictDialog?.close();
      await refreshFiles();
      await rebuildPreview('save');
      return true;
    }
    const error = result.data as ErrorResponse;
    if (result.response.status === 409 && error.status === 'conflict') {
      conflict = result.data as BufferResponse;
      deletedConflict = false;
      editorStatus = `External changes detected in ${activePath}. Nothing was overwritten.`;
      await tick();
      openModal(conflictDialog);
      conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
    } else if (result.response.status === 409 && error.status === 'deleted') {
      conflict = null;
      deletedConflict = true;
      editorStatus = `${activePath} was deleted outside the editor. Nothing was written.`;
      await tick();
      openModal(conflictDialog);
      conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
    } else if (error.error === 'read_only') {
      readOnly = true;
      editorStatus = `${activePath} is read-only. Nothing was written.`;
    } else {
      editorStatus = `Save failed for ${activePath}. Your buffer remains unsaved.`;
    }
    return false;
  }

  async function requestResolution(pending: PendingResolution) {
    pendingResolution = pending;
    await tick();
    openModal(resolutionDialog);
  }

  async function resolvePendingSave() {
    const pending = pendingResolution;
    if (!pending) return;
    pendingResolution = null;
    skipFocusRestore = true;
    resolutionDialog.close();
    if (await saveFile()) {
      await proceedAfterResolution(pending);
    } else if (readOnly) {
      editorStatus = `${activePath} is read-only, so it was not saved. Discard the unsaved buffer to continue.`;
    }
  }

  async function resolvePendingDiscard() {
    const pending = pendingResolution;
    if (!pending) return;
    pendingResolution = null;
    skipFocusRestore = true;
    resolutionDialog.close();
    await discardBuffer();
    await proceedAfterResolution(pending);
  }

  async function proceedAfterResolution(pending: PendingResolution) {
    if (pending.action === 'open') {
      await openFile(pending.target);
    } else if (pending.action === 'command') {
      await runCommand(pending.mode);
    } else if (pending.action === 'restore') {
      await restoreSnapshot(pending.snapshot);
    } else {
      await rebuildPreview(pending.reason);
    }
  }

  async function discardBuffer() {
    if (!activePath) return;
    const discardedPath = activePath;
    await clearRecovery(discardedPath);
    stopRecoveryTimer();
    content = baseline;
    undoStack = [];
    redoStack = [];
    editorStatus = `Discarded unsaved changes in ${discardedPath}.`;
  }

  async function loadDiskVersion() {
    if (!conflict) return;
    loadBuffer(conflict, `Loaded the current disk version of ${activePath}.`);
    await clearRecovery(activePath);
    conflict = null;
    skipFocusRestore = true;
    conflictDialog.close();
  }

  async function discardDeletedBuffer() {
    const discardedPath = activePath;
    await clearRecovery(discardedPath);
    stopRecoveryTimer();
    activePath = '';
    content = '';
    baseline = '';
    fingerprint = '';
    undoStack = [];
    redoStack = [];
    deletedConflict = false;
    skipFocusRestore = true;
    conflictDialog.close();
    editorStatus = `Discarded unsaved changes for deleted file ${discardedPath}.`;
    await refreshFiles();
  }

  async function clearRecovery(path: string) {
    const result = await api<ErrorResponse>('/api/recovery/clear', { method: 'POST', body: JSON.stringify({ path }) });
    if (result.response.ok) {
      snapshots = snapshots.filter(snapshot => snapshot.path !== path);
    } else {
      editorStatus = `Could not discard recovery for ${path}.`;
    }
  }

  async function restoreSnapshot(snapshot: RecoverySnapshot) {
    if (dirty) {
      await requestResolution({ action: 'restore', snapshot });
      return;
    }
    const opened = await api<BufferResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path: snapshot.path })
    });
    if (opened.response.ok) {
      loadBuffer(opened.data, `Recovered unsaved work for ${snapshot.path}.`);
      content = snapshot.content;
    } else if (opened.response.status === 404) {
      activePath = snapshot.path;
      content = snapshot.content;
      baseline = '';
      fingerprint = snapshot.fingerprint;
      readOnly = false;
      undoStack = [];
      redoStack = [];
      editorStatus = `Recovered unsaved work for deleted file ${snapshot.path}.`;
    } else {
      editorStatus = `Could not restore recovered work for ${snapshot.path}.`;
    }
  }

  async function createFile() {
    const path = createPath.trim();
    if (!path) return;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/create', {
      method: 'POST', body: JSON.stringify({ path, content: '' })
    });
    if (result.response.ok) {
      skipFocusRestore = true;
      createDialog.close();
      await refreshFiles();
      loadBuffer(result.data as BufferResponse, `Created ${path}.`);
    } else {
      editorStatus = `Could not create ${path}: ${(result.data as ErrorResponse).error ?? 'request failed'}.`;
    }
  }

  function openRenameDialog() {
    renamePath = activePath;
    openModal(renameDialog);
  }

  function openDeleteDialog() {
    openModal(deleteDialog);
    deleteDialog.querySelector<HTMLButtonElement>('.dialog-actions .danger')?.focus();
  }

  function paletteItemLabel(item: PaletteItem): string {
    if (item.kind === 'create') return 'Create file';
    if (item.kind === 'rename') return 'Rename file';
    if (item.kind === 'delete') return 'Delete file';
    if (item.kind === 'save') return 'Save file';
    if (item.kind === 'command') return commandLabel(item.mode);
    if (item.kind === 'preview') return 'Rebuild preview';
    if (item.kind === 'source') return 'Focus source pane';
    if (item.kind === 'parent') return 'Go to parent';
    if (item.kind === 'impact-here') return 'Run impact on this page';
    if (item.kind === 'entity') return `Go to ${item.id}`;
    return 'Open file';
  }

  function paletteItemDetail(item: PaletteItem): string {
    if (item.kind === 'create') return 'New project-relative path';
    if (item.kind === 'rename' || item.kind === 'delete' || item.kind === 'save') return activePath;
    if (item.kind === 'command') return 'Boris command';
    if (item.kind === 'preview') return 'Rebuild the published output';
    if (item.kind === 'source') return 'Jump to the editor';
    if (item.kind === 'parent') return parentNode ? `${parentNode.id}${parentNode.title ? ` · ${parentNode.title}` : ''}` : 'No parent in the Boris graph';
    if (item.kind === 'impact-here') return activeNode ? activeNode.id : 'No graph page is open';
    if (item.kind === 'entity') {
      const node = nodeForId(graphPayload?.graph ?? null, item.id);
      return node?.title ?? 'Boris graph entity';
    }
    return item.path;
  }

  function paletteItemEnabled(item: PaletteItem): boolean {
    if (item.kind === 'open' || item.kind === 'source' || item.kind === 'entity') return true;
    if (item.kind === 'parent') return parentNode !== null;
    if (item.kind === 'impact-here') return activeNode !== null && !commandRunning;
    if (item.kind === 'save') return dirty && !readOnly;
    if (item.kind === 'preview') return previewData?.phase !== 'running';
    if (item.kind === 'command') return !commandRunning;
    if (dirty) return false;
    return item.kind === 'create' || activePath !== '';
  }

  function paletteItemKey(item: PaletteItem): string {
    if (item.kind === 'open') return `open:${item.path}`;
    if (item.kind === 'entity') return `entity:${item.id}`;
    if (item.kind === 'command') return `command:${item.mode}`;
    return item.kind;
  }

  function paletteEnabledIndices(): number[] {
    return paletteItems
      .map((item, index) => paletteItemEnabled(item) ? index : -1)
      .filter((index): index is number => index >= 0);
  }

  function openPalette() {
    if (document.querySelector('dialog[open]')) return;
    paletteQuery = '';
    paletteSelection = 0;
    openModal(paletteDialog);
  }

  function paletteKeydown(event: KeyboardEvent) {
    handleDialogKeydown(event);
    if (event.defaultPrevented) return;
    const enabled = paletteEnabledIndices();
    if (enabled.length === 0) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      const current = enabled.indexOf(paletteSelection);
      const base = current >= 0 ? current : -1;
      paletteSelection = enabled[(base + 1 + enabled.length) % enabled.length];
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      const current = enabled.indexOf(paletteSelection);
      const base = current >= 0 ? current : enabled.length;
      paletteSelection = enabled[(base - 1 + enabled.length) % enabled.length];
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const item = paletteItems[paletteSelection];
      if (item && paletteItemEnabled(item)) executePaletteItem(item);
    }
  }

  function executePaletteItem(item: PaletteItem) {
    skipFocusRestore = true;
    paletteDialog.close();
    if (item.kind === 'create') {
      createDialog.showModal();
    } else if (item.kind === 'rename') {
      renamePath = activePath;
      renameDialog.showModal();
    } else if (item.kind === 'delete') {
      deleteDialog.showModal();
      deleteDialog.querySelector<HTMLButtonElement>('.dialog-actions .danger')?.focus();
    } else if (item.kind === 'save') void saveFile();
    else if (item.kind === 'command') void runCommand(item.mode);
    else if (item.kind === 'preview') void rebuildPreview('manual');
    else if (item.kind === 'source') focusSourcePane();
    else if (item.kind === 'parent') void openGraphNode(parentNode);
    else if (item.kind === 'impact-here') void runImpactOnCurrent();
    else if (item.kind === 'entity') void openGraphNode(nodeForId(graphPayload?.graph ?? null, item.id));
    else void openFile(item.path);
  }

  function focusSourcePane() {
    const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
    if (editor) {
      editor.focus();
      return;
    }
    document.getElementById('source')?.focus();
  }

  async function renameFile() {
    const newPath = renamePath.trim();
    if (!activePath || !newPath) return;
    const oldPath = activePath;
    const result = await api<ErrorResponse>('/api/files/rename', {
      method: 'POST', body: JSON.stringify({ path: oldPath, new_path: newPath })
    });
    if (result.response.ok) {
      activePath = newPath;
      skipFocusRestore = true;
      renameDialog.close();
      await refreshFiles();
      editorStatus = `Renamed ${oldPath} to ${newPath}.`;
    } else {
      editorStatus = `Could not rename ${oldPath}: ${result.data.error ?? 'request failed'}.`;
    }
  }

  async function deleteFile() {
    if (!activePath) return;
    const path = activePath;
    const result = await api<ErrorResponse>('/api/files/delete', {
      method: 'POST', body: JSON.stringify({ path, confirmed: true })
    });
    if (result.response.ok) {
      skipFocusRestore = true;
      deleteDialog.close();
      activePath = '';
      content = '';
      baseline = '';
      fingerprint = '';
      undoStack = [];
      redoStack = [];
      await refreshFiles();
      editorStatus = `Deleted ${path}.`;
    } else {
      editorStatus = `Could not delete ${path}: ${result.data.error ?? 'request failed'}.`;
    }
  }

  function handleShortcut(event: KeyboardEvent) {
    const command = event.metaKey || event.ctrlKey;
    if (!command || event.altKey) return;
    if (event.key.toLowerCase() === 's') {
      event.preventDefault();
      if (document.querySelector('dialog[open]')) return;
      void saveFile();
    } else if (event.key.toLowerCase() === 'k') {
      event.preventDefault();
      openPalette();
    } else if (event.key.toLowerCase() === 'z' && event.shiftKey) {
      if ((event.target as HTMLElement | null)?.id !== 'source-editor') return;
      event.preventDefault();
      redo();
    } else if (event.key.toLowerCase() === 'z') {
      if ((event.target as HTMLElement | null)?.id !== 'source-editor') return;
      event.preventDefault();
      undo();
    }
  }

  function rememberDialogTrigger() {
    const active = document.activeElement;
    lastDialogTrigger = active instanceof HTMLElement ? active : null;
    skipFocusRestore = false;
  }

  function openModal(dialog: HTMLDialogElement) {
    rememberDialogTrigger();
    dialog.showModal();
  }

  function restoreDialogFocus() {
    if (skipFocusRestore) {
      skipFocusRestore = false;
      return;
    }
    const trigger = lastDialogTrigger;
    lastDialogTrigger = null;
    if (!trigger || !document.contains(trigger) || document.querySelector('dialog[open]')) return;
    trigger.focus();
  }

  function handlePaletteBackdrop(event: MouseEvent) {
    if (event.target === paletteDialog) paletteDialog.close();
  }

  function handleConflictKeydown(event: KeyboardEvent) {
    handleDialogKeydown(event);
    if (event.defaultPrevented) return;
    if (!event.altKey || event.metaKey || event.ctrlKey) return;
    if (event.key.toLowerCase() === 'l' && conflict) {
      event.preventDefault();
      void loadDiskVersion();
    } else if (event.key.toLowerCase() === 'd' && deletedConflict) {
      event.preventDefault();
      void discardDeletedBuffer();
    }
  }

  function handleDialogKeydown(event: KeyboardEvent) {
    if (event.key !== 'Tab') return;
    const dialog = event.currentTarget as HTMLDialogElement;
    if (!dialog.open) return;
    const focusable = [...dialog.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )];
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    const active = document.activeElement;
    if (event.shiftKey) {
      if (active === first || active === dialog || !dialog.contains(active)) {
        event.preventDefault();
        last.focus();
      }
    } else if (active === last || !dialog.contains(active)) {
      event.preventDefault();
      first.focus();
    }
  }

  function handleResolutionKeydown(event: KeyboardEvent) {
    handleDialogKeydown(event);
    if (event.defaultPrevented) return;
    if (!event.altKey || event.metaKey || event.ctrlKey) return;
    if (event.key.toLowerCase() === 's') {
      event.preventDefault();
      void resolvePendingSave();
    } else if (event.key.toLowerCase() === 'd') {
      event.preventDefault();
      void resolvePendingDiscard();
    }
  }

  function warnUnsaved(event: BeforeUnloadEvent) {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = '';
  }

  connect();
</script>

<svelte:head>
  <meta name="description" content="Local, compiler-backed Boris authoring environment" />
</svelte:head>

<svelte:window onkeydown={handleShortcut} onbeforeunload={warnUnsaved} />

<header>
  <a class="skip-link" href="#workspace" onclick={(event) => {
    event.preventDefault();
    document.getElementById('workspace')?.focus();
  }}>Skip to workspace</a>
  <div>
    <p class="eyebrow">Local authoring environment</p>
    <h1>Boris Editor</h1>
  </div>
  <p class="connection" role="status" aria-label="Connection status" aria-live="polite">{connection}</p>
</header>

<nav class="section-nav" aria-label="Editor sections">
  <a href="#project">Project</a>
  <a href="#source">Source</a>
  <a href="#graph">Graph</a>
  <a href="#problems">Problems</a>
  <a href="#preview">Preview</a>
</nav>

{#if snapshots.length > 0}
  <aside class="recovery-banner" aria-labelledby="recovery-heading">
    <div>
      <h2 id="recovery-heading">Recovered unsaved work</h2>
      <p>Recovery copies never replace project files without an explicit save.</p>
      <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
    </div>
    <ul>
      {#each snapshots as snapshot (snapshot.path)}
        <li>
          <span>{snapshot.path}</span>
          <button type="button" onclick={() => restoreSnapshot(snapshot)}>Restore {snapshot.path}</button>
          <button type="button" onclick={() => clearRecovery(snapshot.path)}>Discard recovery for {snapshot.path}</button>
        </li>
      {/each}
    </ul>
  </aside>
{/if}

<main id="workspace" tabindex="-1">
  <section id="project" class="project-pane" aria-labelledby="project-heading">
    <div>
      <h2 id="project-heading">Project</h2>
      <p>{project}</p>
      <p>{compiler}</p>
    </div>
    <div class="file-actions" aria-label="File actions">
      <button type="button" disabled={dirty} onclick={() => openModal(createDialog)}>Create file</button>
      <button type="button" disabled={!activePath || dirty} onclick={openRenameDialog}>Rename file</button>
      <button type="button" class="danger" disabled={!activePath || dirty} onclick={openDeleteDialog}>Delete file</button>
    </div>
    <nav class="file-tree" aria-label="Project files">
      {#if files.length === 0}
        <p>No author-owned project files found.</p>
      {:else}
        <ul>
          {#each files as file (file.path)}
            <li>
              <button
                type="button"
                class:active={file.path === activePath}
                aria-current={file.path === activePath ? 'page' : undefined}
                onclick={() => openFile(file.path)}
              >{file.path}</button>
            </li>
          {/each}
        </ul>
      {/if}
    </nav>
  </section>

  <section id="source" class="source-pane" tabindex="-1" aria-labelledby="source-heading">
    <div class="source-heading">
      <div>
        <h2 id="source-heading">Source</h2>
        <p class="path">{activePath || 'No file selected'}</p>
      </div>
      <div class="source-actions" aria-label="Editing actions">
        <button type="button" disabled={undoStack.length === 0 || readOnly} onclick={undo}>Undo</button>
        <button type="button" disabled={redoStack.length === 0 || readOnly} onclick={redo}>Redo</button>
        <button type="button" class="primary" disabled={!dirty || readOnly} onclick={() => saveFile()}>Save file</button>
      </div>
    </div>
    {#if activePath}
      <label for="source-editor">Source for {activePath}</label>
      <textarea
        id="source-editor"
        value={content}
        readonly={readOnly}
        spellcheck="false"
        oninput={editSource}
      ></textarea>
      <aside class="authoring-tools" aria-labelledby="authoring-heading">
        <div class="authoring-heading">
          <div>
            <h3 id="authoring-heading">Boris authoring hints</h3>
            <p>{authoringStatus}</p>
          </div>
          <button type="button" onclick={refreshAuthoring}>Refresh Boris suggestions</button>
        </div>
        <div class="completion-controls">
          <div>
            <label for="completion-kind">Completion category</label>
            <select id="completion-kind" bind:value={completionKind} onchange={() => { completionQuery = ''; selectedSuggestion = 0; completionOpen = true; }}>
              <option value="frontmatter_key">Frontmatter key</option>
              <option value="status">Status value</option>
              <option value="entity">Entity id</option>
              <option value="wiki_link">Wiki link</option>
              <option value="parent">Parent target</option>
              <option value="relation_kind">Relation kind</option>
              <option value="relation_target">Relation target</option>
              <option value="layout_slot">Layout slot</option>
            </select>
          </div>
          <div class="combobox-wrap">
            <label for="completion-query">Filter {completionKind.replaceAll('_', ' ')}</label>
            <input
              id="completion-query"
              role="combobox"
              aria-autocomplete="list"
              aria-expanded={completionOpen && suggestions.length > 0}
              aria-controls="completion-options"
              aria-activedescendant={completionOpen && suggestions.length ? `completion-option-${selectedSuggestion}` : undefined}
              bind:value={completionQuery}
              onfocus={() => completionOpen = true}
              oninput={() => completionOpen = true}
              onkeydown={completionKeydown}
            />
            <p class="key-hint"><kbd>↑</kbd><kbd>↓</kbd> navigate · <kbd>Enter</kbd> insert · <kbd>Esc</kbd> close</p>
          </div>
          <button type="button" disabled={!suggestions.length || readOnly} onclick={() => insertSuggestion(suggestions[selectedSuggestion])}>Insert selected completion</button>
        </div>
        {#if completionOpen && suggestions.length > 0}
        <ul id="completion-options" role="listbox" aria-label="Boris completion suggestions">
          {#each suggestions as suggestion, suggestionIndex (`${completionKind}-${suggestion.value}`)}
            <li
              id="completion-option-{suggestionIndex}"
              role="option"
              tabindex="-1"
              aria-selected={suggestionIndex === selectedSuggestion}
              class:selected={suggestionIndex === selectedSuggestion}
              onclick={() => { selectedSuggestion = suggestionIndex; }}
              onkeydown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); void insertSuggestion(suggestion); } }}
            >
              <strong>{suggestion.value}</strong><span>{suggestion.detail}</span>
            </li>
          {/each}
        </ul>
        {/if}
        {#if authoring}
          <details>
            <summary>Frontmatter field bounds from Boris schema</summary>
            <dl>
              {#each Object.entries(authoring.frontmatter_schema.properties) as [field, property]}
                <div><dt>{field}</dt><dd>{schemaHint(property)}</dd></div>
              {/each}
            </dl>
            <p>The schema is a looser pre-check for multibyte lengths and dates. The Boris parser remains authoritative.</p>
          </details>
        {/if}
      </aside>
      <section id="graph" class="graph-pane" aria-labelledby="graph-heading">
        <div class="problems-heading">
          <div>
            <h3 id="graph-heading">Graph</h3>
            <p>Read-only view of Boris <code>graph.json</code> and <code>completion.json</code>.</p>
          </div>
        </div>
        <p role="status" aria-label="Graph status" aria-live="polite">{graphStatus}</p>
        {#if activeNode}
          <p class="graph-current">{activeNode.id}{activeNode.title ? ` · ${activeNode.title}` : ''} · {activeNode.role}{activeNode.status ? ` · ${activeNode.status}` : ''}</p>
          <div class="graph-actions" aria-label="Graph navigation">
            {#if parentNode}
              <button type="button" onclick={() => openGraphNode(parentNode)}>Go to parent {parentNode.id}</button>
            {/if}
            <button type="button" disabled={commandRunning} onclick={runImpactOnCurrent}>Run impact on {activeNode.id}</button>
          </div>
          {#if graphChildren.length > 0}
            <h4>Children</h4>
            <ul class="graph-links">
              {#each graphChildren as link (link.path)}
                <li><button type="button" onclick={() => openGraphPath(link.path)}>Go to child {link.label}</button></li>
              {/each}
            </ul>
          {/if}
          {#if graphSiblings.length > 0}
            <h4>Siblings</h4>
            <ul class="graph-links">
              {#each graphSiblings as link (link.path)}
                <li><button type="button" onclick={() => openGraphPath(link.path)}>Go to sibling {link.label}</button></li>
              {/each}
            </ul>
          {/if}
          {#if graphOutgoing.length > 0}
            <h4>Outgoing references and includes</h4>
            <ul class="graph-links">
              {#each graphOutgoing as link (`${link.kind}:${link.path}`)}
                <li><button type="button" onclick={() => openGraphPath(link.path)}>Go to {link.label}</button></li>
              {/each}
            </ul>
          {/if}
          {#if graphBacklinks.length > 0}
            <h4>Backlinks</h4>
            <ul class="graph-links">
              {#each graphBacklinks as link (`back:${link.kind}:${link.path}`)}
                <li><button type="button" onclick={() => openGraphPath(link.path)}>Go to backlink {link.label}</button></li>
              {/each}
            </ul>
          {/if}
          {#if graphRelations.length > 0}
            <h4>Relations from completion.json</h4>
            <ul class="graph-links">
              {#each graphRelations as relation (`${relation.kind}:${relation.target}`)}
                <li>
                  {#if nodeForId(graphPayload?.graph ?? null, relation.target)}
                    <button type="button" onclick={() => openGraphNode(nodeForId(graphPayload?.graph ?? null, relation.target))}>
                      Go to {relation.kind} {relation.target}
                    </button>
                  {:else}
                    <span>{relation.kind} {relation.target}</span>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
          {#if bufferWikiLinks.length > 0}
            <h4>Wiki links in this buffer</h4>
            <ul class="graph-links">
              {#each bufferWikiLinks as link (link.id)}
                <li>
                  {#if link.node}
                    <button type="button" onclick={() => openGraphNode(link.node)}>Go to wiki link {link.id}</button>
                  {:else}
                    <span>Unresolved wiki link {link.id}</span>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        {:else if graphPayload?.graph}
          <p>This file is not a page in the Boris graph.</p>
        {/if}
      </section>
      <p class:warning={dirty || readOnly} class="buffer-state">
        {readOnly ? 'Read-only file' : dirty ? 'Unsaved changes' : 'Saved on disk'}
      </p>
      {#if activeProblems.length > 0}
        <aside class="inline-problems" aria-label="Problems in {activePath}">
          <h3>Problems in this file</h3>
          <ul>
            {#each activeProblems as problem}
              <li>
                <button type="button" onclick={() => navigateToProblem(problem)}>
                  Go to {problemLocationLabel(problem)}: {problem.code ?? 'Unstructured Boris output'}
                </button>
              </li>
            {/each}
          </ul>
        </aside>
      {/if}
    {:else}
      <p>Choose a file from Project files. Generated output and editor state are intentionally excluded.</p>
      <section id="graph" class="graph-pane" aria-labelledby="graph-heading-empty">
        <h3 id="graph-heading-empty">Graph</h3>
        <p role="status" aria-label="Graph status" aria-live="polite">{graphStatus}</p>
      </section>
    {/if}
    <p role="status" aria-label="Editing status" aria-live="polite">{editorStatus}</p>
  </section>

  <div class="workspace-rail">
  <section id="problems" class="problems-pane" aria-labelledby="problems-heading">
    <div class="problems-heading">
      <div>
        <h2 id="problems-heading">Problems</h2>
        <p>Every result below comes from the Boris CLI or one of its published artifacts.</p>
      </div>
      {#if commandResult}
        <p class:failure={commandResult.failure_class !== 'success'} class="command-result">
          {failureLabel(commandResult.failure_class, commandResult.exit_code)}
        </p>
      {/if}
    </div>
    <div class="command-bar" aria-label="Boris commands">
      <button type="button" disabled={commandRunning} onclick={() => runCommand('validate')}>Validate project</button>
      <button type="button" disabled={commandRunning} onclick={() => runCommand('ir_build')}>Build diagnostics</button>
      <button type="button" disabled={commandRunning} onclick={() => runCommand('html_build')}>Build HTML</button>
      <button type="button" disabled={commandRunning} onclick={() => runCommand('check')}>Check graph</button>
    </div>
    <div class="impact-command">
      <label for="impact-id">Impact entity or source endpoint</label>
      <div>
        <input id="impact-id" bind:value={impactId} disabled={commandRunning} />
        <button type="button" disabled={commandRunning} onclick={() => runCommand('impact')}>Run impact</button>
      </div>
    </div>
    {#if dirty}
      <p class="warning-text">Boris commands read repository files from disk. Choose Save &amp; run or Discard &amp; run to resolve the unsaved buffer.</p>
    {/if}
    <p role="status" aria-label="Boris command status" aria-live="polite">{commandStatus}</p>

    {#if commandResult?.used_stderr_fallback}
      <p class="fallback-notice">Machine-readable diagnostics were unavailable for this command. Boris stderr was used; reported source positions are labeled best-effort.</p>
    {/if}

    {#if commandResult && commandResult.problems.length === 0}
      <p>No Boris diagnostics were reported by the last command.</p>
    {/if}

    <div class="problem-groups" aria-label="Boris diagnostic groups">
      {#each problemGroups as group, groupIndex (group.key)}
        <section class="problem-group" aria-labelledby="problem-group-{groupIndex}">
          <h3 id="problem-group-{groupIndex}">{group.label}</h3>
          <ul>
            {#each group.problems as problem}
              <li class="problem-card">
                <p>{problem.message}</p>
                {#if problem.remediation}<p><strong>Remediation:</strong> {problem.remediation}</p>{/if}
                <p class="confidence">
                  {problem.position_confidence === 'exact'
                    ? 'Exact compiler-reported source position'
                    : problem.position_confidence === 'best_effort'
                      ? 'Best-effort source position'
                      : 'No source position reported'}
                </p>
                <div class="problem-actions">
                  {#if problem.source_path}
                    <button type="button" onclick={() => navigateToProblem(problem)}>Go to {problemLocationLabel(problem)}</button>
                  {/if}
                  <button type="button" onclick={() => copyDiagnosticPacket(problem)}>
                    Copy packet for {problem.code ?? 'unstructured Boris output'} at {problem.source_path ?? 'project'}
                  </button>
                </div>
              </li>
            {/each}
          </ul>
        </section>
      {/each}
    </div>

    {#if commandResult && commandResult.findings.length > 0}
      <section class="analysis-results" aria-labelledby="analysis-findings-heading">
        <h3 id="analysis-findings-heading">Analysis findings</h3>
        <ul>
          {#each commandResult.findings as finding}
            <li>
              <span>{finding.code} · {finding.endpoint_type} {finding.value} · count {finding.count}</span>
              {#if finding.source_path}
                <button type="button" onclick={() => navigateToProblem(finding)}>Go to {problemLocationLabel(finding)}</button>
              {/if}
            </li>
          {/each}
        </ul>
      </section>
    {/if}

    {#if commandResult?.mode === 'impact' && commandResult.impact.length > 0}
      <section class="analysis-results" aria-labelledby="impact-results-heading">
        <h3 id="impact-results-heading">Impact results</h3>
        <ul>
          {#each commandResult.impact as endpoint}
            <li>{endpoint.endpoint_type}: {endpoint.value}</li>
          {/each}
        </ul>
      </section>
    {/if}
  </section>

  <section id="preview" aria-labelledby="preview-heading">
    <div class="preview-heading">
      <div>
        <h2 id="preview-heading">Preview</h2>
        <p>The frame serves unchanged files from Boris's committed <code>dist/</code> output.</p>
      </div>
      <div class="preview-actions" aria-label="Preview actions">
        <button type="button" disabled={previewData?.phase === 'running'} onclick={() => rebuildPreview('manual')}>Rebuild preview</button>
        {#if previewData && (previewData.phase === 'success' || previewData.phase === 'stale')}
          <a class="button-link" href={previewData.preview_url} target="_blank" rel="noreferrer">Open preview in new tab</a>
        {/if}
      </div>
    </div>
    <p class="preview-state" class:current={previewData?.phase === 'success'} class:failure={previewData?.phase === 'failed' || previewData?.phase === 'stale'}>
      <strong>{previewData?.phase ?? 'idle'}:</strong> {previewState}
    </p>
    {#if previewData?.used_stderr_fallback}
      <p class="fallback-notice">Rich HTML diagnostics are unavailable; this failure message comes from bounded Boris stderr.</p>
    {/if}
    {#if previewData && (previewData.phase === 'success' || previewData.phase === 'stale')}
      <iframe
        title="Boris site preview"
        src={`${previewData.preview_url}&generation=${previewData.generation}`}
        sandbox="allow-same-origin"
      ></iframe>
    {:else}
      <p>No valid Boris preview output is available yet.</p>
    {/if}
  </section>
  </div>
</main>

<dialog bind:this={conflictDialog} onkeydown={handleConflictKeydown} onclose={() => { conflict = null; deletedConflict = false; restoreDialogFocus(); }} aria-labelledby="conflict-heading">
  <h2 id="conflict-heading">{deletedConflict ? 'File deleted outside Boris Editor' : 'External changes detected'}</h2>
  {#if deletedConflict}
    <p>{activePath} no longer exists on disk. Your unsaved version is still in the editor.</p>
    <label for="deleted-version">Your unsaved version</label>
    <textarea id="deleted-version" readonly value={content}></textarea>
    <div class="dialog-actions">
      <button type="button" onclick={() => conflictDialog.close()}>Keep editing<kbd>Esc</kbd></button>
      <button type="button" onclick={discardDeletedBuffer}>Discard changes<kbd>Alt+D</kbd></button>
      <button type="button" class="primary" onclick={() => saveFile(true)}>Re-create file<kbd>Enter</kbd></button>
    </div>
  {:else if conflict}
    <p>{activePath} changed on disk after you opened it. Compare both versions before choosing.</p>
    <div class="comparison">
      <div>
        <label for="unsaved-version">Your unsaved version</label>
        <textarea id="unsaved-version" readonly value={content}></textarea>
      </div>
      <div>
        <label for="disk-version">Current disk version</label>
        <textarea id="disk-version" readonly value={conflict.content}></textarea>
      </div>
    </div>
    <div class="dialog-actions">
      <button type="button" onclick={() => conflictDialog.close()}>Keep editing<kbd>Esc</kbd></button>
      <button type="button" onclick={loadDiskVersion}>Load disk version<kbd>Alt+L</kbd></button>
      <button type="button" class="primary" onclick={() => saveFile(false, conflict!.fingerprint)}>Replace disk version<kbd>Enter</kbd></button>
    </div>
  {/if}
</dialog>

<dialog bind:this={resolutionDialog} onkeydown={handleResolutionKeydown} onclose={() => { pendingResolution = null; restoreDialogFocus(); }} aria-labelledby="resolution-heading">
  <h2 id="resolution-heading">Unsaved changes in {activePath}</h2>
  <p>{resolutionPrompt}</p>
  <div class="dialog-actions">
    <button type="button" onclick={() => resolutionDialog.close()}>Cancel<kbd>Esc</kbd></button>
    <button type="button" onclick={resolvePendingDiscard}>Discard &amp; {resolutionVerb}<kbd>Alt+D</kbd></button>
    <button type="button" class="primary" onclick={resolvePendingSave}>Save &amp; {resolutionVerb}<kbd>Alt+S</kbd></button>
  </div>
</dialog>

<dialog bind:this={createDialog} onkeydown={handleDialogKeydown} onclose={() => { createPath = 'content/new-page.md'; restoreDialogFocus(); }} aria-labelledby="create-heading">
  <h2 id="create-heading">Create file</h2>
  <p>Use a project-relative path under content/ or themes/, or boris.json.</p>
  <form onsubmit={(event) => { event.preventDefault(); void createFile(); }}>
    <label for="create-path">New file path</label>
    <input id="create-path" bind:value={createPath} />
    <div class="dialog-actions">
      <button type="button" onclick={() => createDialog.close()}>Cancel<kbd>Esc</kbd></button>
      <button type="submit" class="primary">Create file<kbd>Enter</kbd></button>
    </div>
  </form>
</dialog>

<dialog bind:this={renameDialog} onkeydown={handleDialogKeydown} onclose={() => { renamePath = ''; restoreDialogFocus(); }} aria-labelledby="rename-heading">
  <h2 id="rename-heading">Rename file</h2>
  <p>Rename {activePath} without replacing an existing file.</p>
  <form onsubmit={(event) => { event.preventDefault(); void renameFile(); }}>
    <label for="rename-path">New file path</label>
    <input id="rename-path" bind:value={renamePath} />
    <div class="dialog-actions">
      <button type="button" onclick={() => renameDialog.close()}>Cancel<kbd>Esc</kbd></button>
      <button type="submit" class="primary">Rename file<kbd>Enter</kbd></button>
    </div>
  </form>
</dialog>

<dialog bind:this={deleteDialog} onkeydown={handleDialogKeydown} onclose={restoreDialogFocus} aria-labelledby="delete-heading">
  <h2 id="delete-heading">Delete file</h2>
  <p>Delete {activePath || 'selected file'}? This changes the project immediately and cannot be undone in Boris Editor.</p>
  <div class="dialog-actions">
    <button type="button" onclick={() => deleteDialog.close()}>Cancel<kbd>Esc</kbd></button>
    <button type="button" class="danger" onclick={deleteFile}>Delete {activePath || 'file'}<kbd>Enter</kbd></button>
  </div>
</dialog>

<dialog
  class="command-palette"
  bind:this={paletteDialog}
  onkeydown={paletteKeydown}
  onclick={handlePaletteBackdrop}
  onclose={restoreDialogFocus}
  aria-labelledby="palette-heading"
>
  <h2 id="palette-heading">Commands</h2>
  <p>Ctrl+K anywhere opens this palette. Esc or a click outside closes it.</p>
  <label for="palette-query">Filter commands</label>
  <input
    id="palette-query"
    role="combobox"
    aria-autocomplete="list"
    aria-expanded={paletteItems.length > 0}
    aria-controls="palette-options"
    aria-activedescendant={paletteItems.length ? `palette-option-${paletteSelection}` : undefined}
    bind:value={paletteQuery}
    onkeydown={paletteKeydown}
  />
  {#if paletteItems.length > 0}
    <ul id="palette-options" role="listbox" aria-label="Boris commands">
      {#each paletteItems as item, itemIndex (paletteItemKey(item))}
        <li
          id="palette-option-{itemIndex}"
          role="option"
          tabindex="-1"
          aria-selected={itemIndex === paletteSelection}
          aria-disabled={paletteEnabled.get(paletteItemKey(item)) ? 'false' : 'true'}
          class:selected={itemIndex === paletteSelection}
          class:disabled={!paletteEnabled.get(paletteItemKey(item))}
          onclick={() => { if (paletteItemEnabled(item)) executePaletteItem(item); }}
          onkeydown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); if (paletteItemEnabled(item)) executePaletteItem(item); } }}
        >
          <strong>{paletteItemLabel(item)}</strong><span>{paletteItemDetail(item)}</span>
        </li>
      {/each}
    </ul>
  {:else}
    <p>No commands match “{paletteQuery}”.</p>
  {/if}
  <div class="dialog-actions">
    <button type="button" onclick={() => paletteDialog.close()}>Cancel<kbd>Esc</kbd></button>
  </div>
</dialog>

<footer>
  <p class="key-hint"><kbd>Ctrl</kbd>+<kbd>K</kbd> opens commands</p>
  <p>Boris owns meaning. Oliver owns markup semantics. The editor owns interaction.</p>
</footer>
