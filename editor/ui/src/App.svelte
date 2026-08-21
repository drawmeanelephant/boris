<script lang="ts">
  import { tick } from 'svelte';
  import { token, launchOpenPath, api, elapsedLabel, hostErrorLabel, isLaunchOpenSafe } from './lib/api';
  import type {
    Health,
    Version,
    ValidateState,
    FileEntry,
    FileList,
    BufferResponse,
    ProbeResponse,
    RecoverySnapshot,
    RecoveryList,
    ErrorResponse,
    CommandMode,
    FailureClass,
    PendingResolution,
    PaletteItem,
    Problem,
    AnalysisFinding,
    ImpactEndpoint,
    PublicationSite,
    PublicationIdentity,
    PublicationTarget,
    PublicationPlan,
    PublicationProfile,
    PublicationProof,
    PublicationPayload,
    CommandResult,
    ProblemGroup,
    JsonSchemaProperty,
    CompletionEntity,
    CompletionIndex,
    AuthoringPayload,
    CompletionKind,
    Suggestion,
    PreviewState,
    GraphEndpoint,
    RecipeQuantity,
    RecipeIngredient,
    RecipeItem,
    RecipeFacet,
    RecipeScaleAmount,
    RecipeScaleQuantity,
    RecipeScaleView,
    GraphNode,
    GraphEdge,
    GraphNav,
    GraphDocument,
    GraphPayload,
    GraphLink
  } from './lib/types';
  import { visibleFileLimit, unfilteredPaletteEntryLimit } from './lib/types';
  import {
    commandLabel,
    versionLabel,
    failureLabel,
    groupProblems,
    projectPathForProblem,
    projectPathForGraphSource,
    nodeForPath,
    nodeForId,
    navForNode,
    graphLinksForIndices,
    endpointPath,
    outgoingGraphLinks,
    incomingGraphLinks,
    wikiLinksInSource,
    quantityLabel,
    displayQuantity,
    escapeHtml,
    sourceOffset,
    packetCopyKey,
    packetCopyLabel,
    problemLocationLabel,
    schemaHint,
    completionSuggestions,
    validationStatusLabel,
    reportAgeLabel,
    validationCycleLabel,
    fileTreeAnnouncement
  } from './lib/utils';
  import Header from './components/Header.svelte';
  import SectionNav from './components/SectionNav.svelte';
  import RecoveryBanner from './components/RecoveryBanner.svelte';
  import ProjectPane from './components/ProjectPane.svelte';
  import SourcePane from './components/SourcePane.svelte';

  let connection = 'Connecting to the local host…';
  let compiler = 'Checking Boris version…';
  let project = 'Checking project conventions…';
  let editorStatus = 'Choose a project file to begin editing.';
  let commandStatus = 'No Boris command has run yet.';
  let previewState = 'Preview is not running.';
  let previewData: PreviewState | null = null;
  let files: FileEntry[] = [];
  let fileQuery = '';
  let snapshots: RecoverySnapshot[] = [];
  let activePath = '';
  let content = '';
  let baseline = '';
  let fingerprint = '';
  let readOnly = false;
  let undoStack: string[] = [];
  let redoStack: string[] = [];
  let recoveryTimer: ReturnType<typeof setInterval> | undefined;
  let hostTimer: ReturnType<typeof setInterval> | undefined;
  let diskTimer: ReturnType<typeof setInterval> | undefined;
  let probeInFlight = false;
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
  let saveInFlight = false;
  let commandResult: CommandResult | null = null;
  let impactId = '';
  let authoring: AuthoringPayload | null = null;
  let authoringStatus = 'Loading Boris authoring vocabulary…';
  let completionKind: CompletionKind = 'frontmatter_key';
  let completionQuery = '';
  let selectedSuggestion = 0;
  let completionOpen = false;
  let copiedPacketKey = '';
  let copiedPacketTimer: ReturnType<typeof setTimeout> | undefined;
  let paletteQuery = '';
  let paletteSelection = 0;
  let lastDialogTrigger: HTMLElement | null = null;
  let skipFocusRestore = false;
  let graphPayload: GraphPayload | null = null;
  let graphStatus = 'Loading the Boris graph…';
  let inputMode: NonNullable<Health['project']['input_mode']> = 'empty';
  let previewWidth: 'full' | '375' | '768' | '1440' = 'full';
  let validateDaemon = false;
  let validateState: ValidateState | null = null;
  let lastValidateCycle = -1;
  let validateStateTimer: ReturnType<typeof setInterval> | undefined;
  let publicationPayload: PublicationPayload | null = null;
  let publicationStatus = 'Loading publication profiles…';
  let selectedProfile = '';
  let lastPublicationPlan: PublicationPlan | null = null;
  let scaleFactor = '';
  let scaleView: RecipeScaleView | null = null;

  $: dirty = activePath !== '' && content !== baseline;
  $: problemGroups = groupProblems(commandResult?.problems ?? []);
  // Honest empty-pane naming (#658): distinguish "the tree was never
  // validated" from "the newest report has zero problems". The notice is
  // derived purely from state the host already sends (validate-state for the
  // daemon path, commandResult presence for the one-shot path) and only
  // renders when the pane has nothing to list and the last command was
  // validate (or none) — so it can never contradict a different command's
  // problem list. `clean` marks a claim about a completed report, which is
  // what earns the dirty-buffer caveat.
  $: problemsNotice = (() => {
    const problems = commandResult?.problems ?? [];
    if (problems.length > 0) return { text: '', clean: false };
    if (commandResult && commandResult.mode !== 'validate') return { text: '', clean: false };
    if (validateDaemon) {
      if (!validateState) return { text: '', clean: false };
      switch (validateState.state) {
        case 'idle':
          return { text: 'No validation report yet. Run Validate project to start the daemon.', clean: false };
        case 'running':
          return { text: 'Waiting for the first validation cycle…', clean: false };
        case 'success':
          if ((validateState.problems_count ?? 0) > 0) return { text: '', clean: false };
          return { text: `No problems in the newest report (cycle ${validateState.cycle ?? 0}).`, clean: true };
        default:
          return { text: '', clean: false };
      }
    }
    if (commandResult == null) {
      return { text: 'No validation report yet. Run Validate project to check the tree.', clean: false };
    }
    return { text: '', clean: false };
  })();
  $: activeProblems = (commandResult?.problems ?? []).filter(problem =>
    problem.source_path !== null && projectPathForProblem(problem.source_path) === activePath
  );
  // Per-problem staleness (#660, #662): a problem is possibly stale when the
  // open buffer changed the problem's own source region since the last report
  // and the caret currently sits inside that region. Lines are compared
  // against `baseline` (the last loaded/saved buffer, i.e. the report-time
  // snapshot); edits on other lines and problems in other files never mark
  // anything. The #662 drift extension also marks when the buffer's line count
  // changed and the first divergence from `baseline` sits strictly above the
  // problem's line: the reported line number may address moved text even when
  // the text at that line happens to match (e.g. adjacent identical lines).
  // That is the documented approximation from #662 — it errs toward honesty,
  // and the mark clears on caret move or save; identical-line insertion above
  // stays ambiguous from text alone.
  $: staleProblems = (() => {
    const set = new Set<Problem>();
    if (!dirty || !activePath || content === baseline) return set;
    const savedLines = baseline.split('\n');
    const bufferLines = content.split('\n');
    const changed = new Set<number>();
    let firstDiff = -1;
    for (let index = 0; index < Math.max(savedLines.length, bufferLines.length); index += 1) {
      if (savedLines[index] !== bufferLines[index]) {
        changed.add(index + 1);
        if (firstDiff < 0) firstDiff = index;
      }
    }
    if (changed.size === 0) return set;
    const lineCountChanged = savedLines.length !== bufferLines.length;
    for (const problem of activeProblems) {
      if (!problem.source_path || problem.line == null) continue;
      if (problem.position_confidence === 'none') continue;
      if (problem.line !== cursor.line) continue;
      if (problem.column != null && cursor.column < problem.column) continue;
      if (changed.has(problem.line)) {
        set.add(problem);
        continue;
      }
      if (lineCountChanged && firstDiff >= 0 && firstDiff < problem.line - 1) set.add(problem);
    }
    return set;
  })();
  $: suggestions = completionSuggestions(authoring, completionKind, completionQuery);
  $: if (selectedSuggestion >= suggestions.length) selectedSuggestion = Math.max(0, suggestions.length - 1);
  $: activeNode = nodeForPath(graphPayload?.graph ?? null, activePath);
  $: visibleScaleView = scaleView && activeNode && scaleView.page === activeNode.id ? scaleView : null;
  $: parentNode = activeNode?.parent ? nodeForId(graphPayload?.graph ?? null, activeNode.parent) : null;
  $: graphChildren = graphLinksForIndices(graphPayload?.graph ?? null, navForNode(graphPayload?.graph ?? null, activeNode)?.children ?? []);
  $: graphSiblings = graphLinksForIndices(graphPayload?.graph ?? null, navForNode(graphPayload?.graph ?? null, activeNode)?.siblings ?? []);
  $: graphOutgoing = outgoingGraphLinks(graphPayload?.graph ?? null, activeNode);
  $: graphBacklinks = incomingGraphLinks(graphPayload?.graph ?? null, activeNode);
  $: graphRelations = (authoring?.completion?.entities ?? []).find(entity => entity.id === activeNode?.id)?.relations ?? [];
  $: bufferWikiLinks = wikiLinksInSource(content).map(id => ({
    id, node: nodeForId(graphPayload?.graph ?? null, id)
  }));
  $: themeLayoutOpen = activePath.startsWith('themes/') && activePath.endsWith('.html');
  $: closedLayoutSlots = authoring?.completion?.layout_slots ?? [];
  $: layoutSlotsInBuffer = closedLayoutSlots.filter(slot => content.includes(`{{${slot}}}`));
  $: layoutSlotsMissing = closedLayoutSlots.filter(slot => !content.includes(`{{${slot}}}`));
  $: themeAssets = files.filter(file => file.path.startsWith('themes/') && file.path.includes('/assets/'));
  $: layoutSelections = (commandResult?.problems ?? []).filter(problem => problem.code === 'ILAYOUTSELECTED');
  $: resolutionPrompt = (() => {
    const pending = pendingResolution;
    if (!pending) return '';
    if (pending.action === 'open') return `Save or discard the changes before opening ${pending.target}?`;
    if (pending.action === 'command') return `Boris commands read repository files from disk. Save or discard the changes before running ${commandLabel(pending.mode)}?`;
    if (pending.action === 'restore') return `Save or discard the changes before restoring ${pending.snapshot.path}?`;
    return 'Save or discard the changes before rebuilding the preview?';
  })();
  $: resolutionVerb = pendingResolution?.action === 'open' ? 'switch' : pendingResolution?.action === 'command' ? 'run' : pendingResolution?.action === 'restore' ? 'restore' : 'rebuild';
  $: matchingFiles = (() => {
    const needle = fileQuery.trim().toLocaleLowerCase();
    return needle ? files.filter(file => file.path.toLocaleLowerCase().includes(needle)) : files;
  })();
  $: visibleFiles = (() => {
    const capped = matchingFiles.slice(0, visibleFileLimit);
    if (activePath && !capped.some(file => file.path === activePath)) {
      const active = files.find(file => file.path === activePath);
      if (active) return [active, ...capped];
    }
    return capped;
  })();
  $: fileTreeStatus = fileTreeAnnouncement(files.length, matchingFiles.length, visibleFiles.length, fileQuery);
  $: paletteItems = (() => {
    const needle = paletteQuery.trim().toLocaleLowerCase();
    const items: PaletteItem[] = [];
    const commands: PaletteItem[] = [
      { kind: 'create' }, { kind: 'rename' }, { kind: 'delete' },
      { kind: 'save' },
      { kind: 'command', mode: 'validate' },
      { kind: 'command', mode: 'ir_build' },
      { kind: 'command', mode: 'html_build' },
      { kind: 'command', mode: 'check' },
      { kind: 'command', mode: 'impact' },
      { kind: 'command', mode: 'plan' },
      { kind: 'preview' },
      { kind: 'source' },
      { kind: 'parent' },
      { kind: 'impact-here' }
    ];
    for (const item of commands) {
      if (paletteItemMatches(item, needle)) items.push(item);
    }
    const entryCap = needle ? visibleFileLimit : unfilteredPaletteEntryLimit;
    let entities = 0;
    for (const node of graphPayload?.graph?.nodes ?? []) {
      const item: PaletteItem = { kind: 'entity', id: node.id };
      if (!paletteItemMatches(item, needle)) continue;
      items.push(item);
      entities += 1;
      if (entities >= entryCap) break;
    }
    let opens = 0;
    for (const file of files) {
      const item: PaletteItem = { kind: 'open', path: file.path };
      if (!paletteItemMatches(item, needle)) continue;
      items.push(item);
      opens += 1;
      if (opens >= entryCap) break;
    }
    return items;
  })();
  $: paletteEnabled = new Map<string, boolean>(
    paletteItems.map(item => {
      if (item.kind === 'open' || item.kind === 'source' || item.kind === 'entity') return [paletteItemKey(item), true] as const;
      if (item.kind === 'parent') return [paletteItemKey(item), parentNode !== null] as const;
      if (item.kind === 'impact-here') return [paletteItemKey(item), activeNode !== null && !commandRunning] as const;
      if (item.kind === 'save') return [paletteItemKey(item), dirty && !readOnly && !saveInFlight] as const;
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

  async function connect() {
    if (!token) {
      connection = 'Session token missing. Launch the editor from boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
      return;
    }
    const started = Date.now();
    try {
      const [healthResult, versionResult, filesResult, authoringResult, graphResult, previewResult, publicationResult] = await Promise.all([
        api<Health>('/api/health'),
        api<Version>('/api/version'),
        api<FileList>('/api/files'),
        api<AuthoringPayload>('/api/authoring'),
        api<GraphPayload>('/api/graph'),
        api<PreviewState>('/api/preview/state'),
        api<PublicationPayload>('/api/publication')
      ]);
      if (![healthResult, versionResult, filesResult].every(result => result.response.ok)) {
        throw new Error('host request failed');
      }
      const health = healthResult.data;
      connection = `Connected to ${health.editor_id}. Opened project in ${elapsedLabel(started)}.`;
      compiler = versionLabel(versionResult.data);
      validateDaemon = versionResult.data.supported?.validate_watch ?? false;
      inputMode = health.project.input_mode ?? 'empty';
      project = health.project.content
        ? `Project found${health.project.publication_profile ? ' with boris.json' : ''}${inputMode === 'cooklang' ? '; Cooklang tree (--cooklang)' : inputMode === 'textile' ? '; Textile tree (--textile)' : ''}.`
        : 'This folder is not a Boris project.';
      createPath = defaultCreatePath();
      files = filesResult.data.files;
      if (authoringResult.response.ok) setAuthoring(authoringResult.data);
      else authoringStatus = 'Boris authoring vocabulary is unavailable.';
      if (graphResult.response.ok) setGraph(graphResult.data);
      else graphStatus = 'Boris graph is unavailable.';
      if (publicationResult.response.ok) setPublication(publicationResult.data);
      else publicationStatus = 'Publication profiles are unavailable.';
      if (previewResult.response.ok) setPreview(previewResult.data);
      const recoveryResult = await api<RecoveryList>('/api/recovery');
      if (recoveryResult.response.ok) {
        snapshots = recoveryResult.data.snapshots;
        if ((recoveryResult.data.skipped ?? 0) > 0) {
          editorStatus = `${recoveryResult.data.skipped} recovery snapshot${recoveryResult.data.skipped === 1 ? ' was' : 's were'} unreadable and ignored.`;
        }
      } else {
        editorStatus = 'Project files are available, but recovery snapshots could not be loaded.';
      }
      if (launchOpenPath) {
        if (isLaunchOpenSafe(launchOpenPath)) {
          void openFile(launchOpenPath);
        } else {
          editorStatus = `Launch open path ignored: ${launchOpenPath} is not an author-owned project file.`;
        }
      }
      startHostWatch();
      startDiskWatch();
      if (validateDaemon) startValidateWatch();
    } catch {
      noteHostUnavailable();
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
    cursor = { line: 1, column: 1 };
    editorStatus = status;
  }

  // Mirrors editor/src/file_api.zig `validatePath` (the authoritative rule):
  // a launch target must be an author-owned project file. This pre-check keeps
  // an unsafe `open=` fragment from even reaching the host; the host still
  // re-validates every open request.

  async function openFile(path: string): Promise<boolean> {
    if (path === activePath) return true;
    if (dirty) {
      await requestResolution({ action: 'open', target: path });
      return false;
    }
    const started = Date.now();
    editorStatus = `Opening ${path}…`;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path })
    });
    if (result.response.ok) {
      const buffer = result.data as BufferResponse;
      const wait = elapsedLabel(started);
      loadBuffer(buffer, buffer.read_only ? `Opened ${path} read-only. (${wait})` : `Opened ${path}. (${wait})`);
      return true;
    } else {
      editorStatus = `Could not open ${path}: ${hostErrorLabel((result.data as ErrorResponse).error)}.`;
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
    if (mode === 'plan' && !selectedProfile.trim()) {
      commandStatus = 'Choose a publication profile before running the plan.';
      return;
    }
    if (mode === 'recipe_scale' && !activeNode) {
      commandStatus = 'Open a recipe page before scaling.';
      return;
    }
    if (mode === 'recipe_scale' && !scaleFactor.trim()) {
      commandStatus = 'Enter a scale factor before scaling the recipe.';
      return;
    }
    commandRunning = true;
    const started = Date.now();
    commandStatus = `Running ${commandLabel(mode)}…`;
    const body = mode === 'impact'
      ? { mode, impact_id: impactId.trim() }
      : mode === 'plan'
        ? { mode, profile: selectedProfile.trim() }
        : mode === 'recipe_scale'
          ? { mode, recipe_scale_id: activeNode!.id, recipe_scale_factor: scaleFactor.trim() }
        : { mode };
    const result = await api<CommandResult | ErrorResponse>('/api/commands/run', {
      method: 'POST', body: JSON.stringify(body)
    });
    commandRunning = false;
    if (!result.response.ok) {
      commandStatus = `Could not run ${commandLabel(mode)}: ${hostErrorLabel((result.data as ErrorResponse).error)}.`;
      return;
    }
    commandResult = result.data as CommandResult;
    commandStatus = `${commandLabel(mode)} finished: ${failureLabel(commandResult.failure_class, commandResult.exit_code)}. (${elapsedLabel(started)})`;
    if (commandResult.failure_class === 'terminated') {
      commandStatus += ' Run the same command again when Boris is ready.';
    }
    if (mode === 'html_build') {
      previewState = commandResult.failure_class === 'success'
        ? 'The last HTML build succeeded. Live preview serving arrives in the preview slice.'
        : 'The HTML build failed. Existing dist output, if any, is previous and stale.';
    }
    if (mode === 'ir_build' && commandResult.failure_class === 'success') {
      await refreshAuthoring();
      await refreshGraph();
    }
    if (commandResult.publication_plan) lastPublicationPlan = commandResult.publication_plan;
    if (mode === 'recipe_scale' && commandResult.failure_class === 'success' && commandResult.recipe_scale_view) {
      scaleView = commandResult.recipe_scale_view;
    }
    if (mode === 'html_build' || mode === 'plan') await refreshPublication();
  }


  function setAuthoring(payload: AuthoringPayload) {
    authoring = payload;
    if (payload.completion_status === 'unsupported') {
      authoringStatus = 'completion.json is stale or unsupported. Build diagnostics to replace it. Frontmatter schema remains available.';
      return;
    }
    authoringStatus = payload.completion
      ? `Boris completion index ready from ${payload.completion.compiler_id}.`
      : 'Frontmatter schema ready. Build diagnostics to create graph completion data.';
  }

  async function refreshAuthoring() {
    authoringStatus = 'Refreshing Boris completion…';
    const result = await api<AuthoringPayload>('/api/authoring');
    if (result.response.ok) setAuthoring(result.data);
    else authoringStatus = 'The Boris build succeeded, but completion.json could not be adapted.';
  }

  function setGraph(payload: GraphPayload) {
    graphPayload = payload;
    if (payload.graph_status === 'unsupported') {
      graphStatus = 'graph.json is stale or unsupported. Build diagnostics to replace it.';
      return;
    }
    graphStatus = payload.graph
      ? `Boris graph ready (${payload.graph.nodes.length} pages).`
      : 'Build diagnostics to create the Boris graph.';
  }

  async function refreshGraph() {
    graphStatus = 'Refreshing the Boris graph…';
    const result = await api<GraphPayload>('/api/graph');
    if (result.response.ok) setGraph(result.data);
    else graphStatus = 'The Boris build succeeded, but graph.json could not be adapted.';
  }

  function setPublication(payload: PublicationPayload) {
    publicationPayload = payload;
    if (payload.profiles.length === 0) {
      publicationStatus = 'No publication profile found at the project root.';
      selectedProfile = '';
      return;
    }
    if (!payload.profiles.some(profile => profile.path === selectedProfile)) {
      selectedProfile = payload.profiles[0].path;
    }
    if (payload.proof_status === 'unsupported') {
      publicationStatus = 'Local Proof Pack is stale or unsupported. Build HTML to replace it.';
      return;
    }
    publicationStatus = payload.proof
      ? `Local Proof Pack present for target ${payload.proof.target} (${payload.proof.overall_presentation_status}).`
      : `Ready to plan with ${payload.profiles.length === 1 ? payload.profiles[0].path : `${payload.profiles.length} profiles`}.`;
  }

  async function refreshPublication() {
    const result = await api<PublicationPayload>('/api/publication');
    if (result.response.ok) setPublication(result.data);
    else publicationStatus = 'Publication profiles could not be loaded.';
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
    const started = Date.now();
    previewState = reason === 'save' ? 'Saved. Boris preview build is running…' : 'Boris preview build is running…';
    const result = await api<PreviewState | ErrorResponse>('/api/preview/rebuild', { method: 'POST', body: '{}' });
    if (result.response.ok) {
      setPreview(result.data as PreviewState);
      previewState = `${previewState} (${elapsedLabel(started)})`;
    } else previewState = `Preview host failed: ${(result.data as ErrorResponse).error ?? 'request failed'}. Existing output is not current.`;
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



  function resetScale() {
    scaleView = null;
    commandStatus = 'Showing authored recipe quantities.';
  }

  function printRecipe() {
    if (!activeNode?.recipe) return;
    const recipe = activeNode.recipe;
    const title = activeNode.title ?? activeNode.id;
    const rows = (items: Array<{ name: string; extra?: string; qty: string }>) =>
      items.map(item => `<tr><td>${escapeHtml(item.name)}</td><td>${escapeHtml(item.qty)}</td><td>${escapeHtml(item.extra ?? '')}</td></tr>`).join('');
    const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(title)}</title>
<style>body{font:16px/1.45 ui-serif,Georgia,serif;margin:1.5rem;color:#17201d}h1{font-size:1.6rem}table{width:100%;border-collapse:collapse;margin:0 0 1.25rem}th,td{text-align:left;padding:.35rem .4rem;border-bottom:1px solid #ccd6cf}p.note{color:#53625c;font-size:.9rem}</style>
</head><body>
<h1>${escapeHtml(title)}</h1>
<p class="note">Read-only Boris recipe facet. Quantities are author strings. Scale recipe asks Boris; it does not rewrite the .cook file.</p>
<h2>Ingredients</h2>
<table><thead><tr><th>Name</th><th>Quantity</th><th>Preparation / recipe</th></tr></thead><tbody>
${rows(recipe.ingredients.map(item => ({ name: item.name, qty: quantityLabel(item.quantity), extra: item.recipeRef ? `recipe ${item.recipeRef}` : item.preparation })))}
</tbody></table>
<h2>Cookware</h2>
<table><thead><tr><th>Name</th><th>Quantity</th><th></th></tr></thead><tbody>
${rows(recipe.cookware.map(item => ({ name: item.name, qty: quantityLabel(item.quantity) })))}
</tbody></table>
<h2>Timers</h2>
<table><thead><tr><th>Name</th><th>Quantity</th><th></th></tr></thead><tbody>
${rows(recipe.timers.map(item => ({ name: item.name || 'timer', qty: quantityLabel(item.quantity) })))}
</tbody></table>
</body></html>`;
    const printer = window.open('', 'boris-recipe-print');
    if (!printer) {
      editorStatus = 'Could not open the recipe print view. Allow pop-ups for this local editor.';
      return;
    }
    printer.document.open();
    printer.document.write(html);
    printer.document.close();
    printer.focus();
    printer.print();
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
    trackCursor();
    editor.scrollTop = Math.max(0, editor.scrollHeight * (offset / Math.max(1, content.length)) - editor.clientHeight / 2);
    editorStatus = problem.line
      ? `Moved to ${path}, line ${problem.line}${problem.column ? `, column ${problem.column}` : ''}.`
      : `Opened ${path} for this Boris finding.`;
  }




  async function copyDiagnosticPacket(problem: Problem) {
    try {
      await navigator.clipboard.writeText(problem.packet);
      commandStatus = `Copied diagnostic packet for ${problem.code ?? 'unstructured Boris output'}.`;
      copiedPacketKey = packetCopyKey(problem);
      if (copiedPacketTimer !== undefined) clearTimeout(copiedPacketTimer);
      copiedPacketTimer = setTimeout(() => {
        copiedPacketKey = '';
        copiedPacketTimer = undefined;
      }, 1500);
    } catch {
      commandStatus = 'Could not copy the diagnostic packet. Clipboard access was denied.';
    }
  }

  async function changeCompletionKind() {
    completionQuery = '';
    selectedSuggestion = 0;
    completionOpen = true;
    await tick();
    document.getElementById('completion-query')?.focus();
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
    if (!recoveryTimer) {
      // Snapshot on first dirty so a host or tab death before the 3s tick
      // is not silent loss. Later edits stay periodic until pagehide.
      void snapshotBuffer();
      recoveryTimer = setInterval(() => void snapshotBuffer(), 3000);
    }
  }

  function stopRecoveryTimer() {
    if (recoveryTimer) clearInterval(recoveryTimer);
    recoveryTimer = undefined;
  }

  function startHostWatch() {
    if (hostTimer) return;
    hostTimer = setInterval(() => void watchHost(), 5000);
  }

  function startDiskWatch() {
    if (diskTimer) return;
    diskTimer = setInterval(() => void probeDisk(), 3000);
  }

  // With a `validate --watch` daemon the host rewrites the report on its own
  // debounced cycle after every save; this poller watches the cycle counter
  // and pulls the newest problems only when a cycle actually completes.
  function startValidateWatch() {
    if (validateStateTimer) return;
    validateStateTimer = setInterval(() => void watchValidateState(), 1000);
  }

  async function watchValidateState() {
    if (!validateDaemon) return;
    const result = await api<ValidateState | ErrorResponse>('/api/validate-state');
    if (!result.response.ok) return;
    const state = result.data as ValidateState;
    validateState = state;
    if (state.cycle === undefined || state.cycle === lastValidateCycle) return;
    lastValidateCycle = state.cycle;
    await refreshValidate();
  }

  let cursor = { line: 1, column: 1 };

  // Caret -> 1-based line/column, mirroring the problem position convention
  // (`sourceOffset` walks lines then columns the same way).
  function trackCursor() {
    const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
    if (!editor) return;
    const offset = editor.selectionStart;
    const before = content.slice(0, offset);
    const lines = before.split('\n');
    cursor = { line: lines.length, column: lines[lines.length - 1].length + 1 };
  }

  let saveRefreshTimer: ReturnType<typeof setTimeout> | undefined;

  // A successful save is the highest-signal moment for validation feedback:
  // fire the existing cycle-aware refresh on a short trailing debounce so
  // rapid saves coalesce, instead of waiting for the next 1 s poll tick (#656).
  function scheduleValidateRefresh() {
    if (saveRefreshTimer) clearTimeout(saveRefreshTimer);
    saveRefreshTimer = setTimeout(() => {
      saveRefreshTimer = undefined;
      void refreshValidate();
    }, 300);
  }

  // Honest state naming for the problems surface (#654): the daemon reports
  // idle/running/success/failed/stale, and the shell names exactly what the
  // validate-state payload says — never a fabricated mid-cycle state.



  async function refreshValidate() {
    const started = Date.now();
    const result = await api<CommandResult | ErrorResponse>('/api/commands/run', {
      method: 'POST', body: JSON.stringify({ mode: 'validate' })
    });
    if (!result.response.ok) return;
    commandResult = result.data as CommandResult;
    commandStatus = `Validation updated from the daemon: ${failureLabel(commandResult.failure_class, commandResult.exit_code)}. (${elapsedLabel(started)})`;
  }

  async function watchHost() {
    const result = await api<Health>('/api/health');
    if (!result.response.ok) noteHostUnavailable();
  }

  function noteHostUnavailable() {
    const next = 'Local host unavailable. Restart boris-editor.';
    if (connection === next) return;
    connection = next;
    editorStatus = 'The editor host stopped. Restart boris-editor and open the new launch URL. Unsaved work is kept only if a recovery snapshot was written.';
  }

  async function snapshotBuffer(options: RequestInit = {}) {
    if (!activePath || content === baseline) return;
    const result = await api<ErrorResponse>('/api/recovery/snapshot', {
      method: 'POST',
      body: JSON.stringify({ path: activePath, content, fingerprint }),
      ...options
    });
    if ((result.data as ErrorResponse).error === 'host_unavailable') {
      noteHostUnavailable();
      return;
    }
    if (!result.response.ok) editorStatus = `Unsaved changes in ${activePath}; recovery snapshot failed.`;
  }

  function flushRecovery() {
    void snapshotBuffer({ keepalive: true });
  }

  function handleVisibility() {
    if (document.visibilityState === 'hidden') flushRecovery();
    else void probeDisk();
  }

  async function probeDisk() {
    if (!activePath || !fingerprint || saveInFlight || probeInFlight) return;
    if (document.querySelector('dialog[open]')) return;
    probeInFlight = true;
    try {
      const result = await api<ProbeResponse | ErrorResponse>('/api/files/probe', {
        method: 'POST',
        body: JSON.stringify({ path: activePath, fingerprint })
      });
      if (!result.response.ok) {
        if ((result.data as ErrorResponse).error === 'host_unavailable') noteHostUnavailable();
        return;
      }
      const probe = result.data as ProbeResponse;
      if (probe.status === 'transient') return;
      if (probe.status === 'unchanged') {
        if (probe.read_only !== undefined && probe.read_only !== readOnly) {
          readOnly = probe.read_only;
          editorStatus = probe.read_only
            ? `${activePath} is now read-only on disk.`
            : `${activePath} is writable again.`;
        }
        return;
      }
      await refreshFiles();
      if (probe.status === 'deleted') {
        if (dirty) {
          conflict = null;
          deletedConflict = true;
          editorStatus = `${activePath} was deleted outside the editor.`;
          await tick();
          openModal(conflictDialog);
          conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
        } else {
          const gone = activePath;
          stopRecoveryTimer();
          activePath = '';
          content = '';
          baseline = '';
          fingerprint = '';
          undoStack = [];
          redoStack = [];
          editorStatus = `${gone} was deleted outside the editor.`;
        }
        return;
      }
      if (probe.status !== 'changed' || probe.content === undefined || !probe.fingerprint || !probe.path) return;
      const disk: BufferResponse = {
        status: 'conflict',
        path: probe.path,
        content: probe.content,
        fingerprint: probe.fingerprint,
        read_only: probe.read_only ?? false
      };
      if (dirty) {
        conflict = disk;
        deletedConflict = false;
        editorStatus = `External changes detected in ${activePath}. Nothing was overwritten.`;
        await tick();
        openModal(conflictDialog);
        conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
      } else {
        loadBuffer(disk, `Loaded external changes to ${probe.path}.`);
      }
    } finally {
      probeInFlight = false;
    }
  }

  async function saveFile(recreate = false, replacementFingerprint = fingerprint): Promise<boolean> {
    if (!activePath || readOnly || !dirty || saveInFlight) return false;
    // Capture before saveInFlight disables Save file; otherwise the conflict
    // dialog would remember <body> and Esc could not restore the trigger (#462).
    const trigger = document.activeElement;
    const started = Date.now();
    saveInFlight = true;
    editorStatus = `Saving ${activePath}…`;
    try {
      const result = await api<BufferResponse | ErrorResponse>('/api/files/save', {
        method: 'POST',
        body: JSON.stringify({ path: activePath, content, fingerprint: replacementFingerprint, recreate })
      });
      if (result.response.ok) {
        const buffer = result.data as BufferResponse;
        loadBuffer(buffer, `Saved ${activePath}. (${elapsedLabel(started)})`);
        snapshots = snapshots.filter(snapshot => snapshot.path !== activePath);
        conflict = null;
        deletedConflict = false;
        skipFocusRestore = true;
        conflictDialog?.close();
        await refreshFiles();
        await rebuildPreview('save');
        if (validateDaemon) scheduleValidateRefresh();
        return true;
      }
      const error = result.data as ErrorResponse;
      if (result.response.status === 409 && error.status === 'conflict') {
        conflict = result.data as BufferResponse;
        deletedConflict = false;
        editorStatus = `External changes detected in ${activePath}. Nothing was overwritten.`;
        await tick();
        openModal(conflictDialog, trigger);
        conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
      } else if (result.response.status === 409 && error.status === 'deleted') {
        conflict = null;
        deletedConflict = true;
        editorStatus = `${activePath} was deleted outside the editor. Nothing was written.`;
        await tick();
        openModal(conflictDialog, trigger);
        conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
      } else if (error.error === 'read_only') {
        readOnly = true;
        editorStatus = `${activePath} is read-only. Nothing was written.`;
      } else {
        if (error.error === 'host_unavailable') noteHostUnavailable();
        editorStatus = `Save failed for ${activePath}: ${hostErrorLabel(error.error)}. Your buffer remains unsaved.`;
      }
      return false;
    } finally {
      saveInFlight = false;
    }
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
      editorStatus = `Could not create ${path}: ${hostErrorLabel((result.data as ErrorResponse).error)}.`;
    }
  }

  function defaultCreatePath(): string {
    if (inputMode === 'cooklang') return 'content/new-recipe.cook';
    if (inputMode === 'textile') return 'content/new-page.textile';
    return 'content/new-page.md';
  }

  function openCreateDialog() {
    createPath = defaultCreatePath();
    openModal(createDialog);
  }

  function openRenameDialog() {
    renamePath = activePath;
    openModal(renameDialog);
  }

  function openDeleteDialog() {
    openModal(deleteDialog);
    deleteDialog.querySelector<HTMLButtonElement>('.dialog-actions .danger')?.focus();
  }


  function paletteItemMatches(item: PaletteItem, needle: string): boolean {
    if (!needle) return true;
    return paletteItemLabel(item).toLocaleLowerCase().includes(needle)
      || paletteItemDetail(item).toLocaleLowerCase().includes(needle);
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
    if (item.kind === 'save') return dirty && !readOnly && !saveInFlight;
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
      createPath = defaultCreatePath();
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
      editorStatus = `Could not rename ${oldPath}: ${hostErrorLabel(result.data.error)}.`;
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
      editorStatus = `Could not delete ${path}: ${hostErrorLabel(result.data.error)}.`;
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

  function rememberDialogTrigger(source: EventTarget | null = document.activeElement) {
    lastDialogTrigger = source instanceof HTMLElement ? source : null;
    skipFocusRestore = false;
  }

  function openModal(dialog: HTMLDialogElement, trigger?: EventTarget | null) {
    rememberDialogTrigger(trigger === undefined ? document.activeElement : trigger);
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

<svelte:window
  onkeydown={handleShortcut}
  onbeforeunload={warnUnsaved}
  onpagehide={flushRecovery}
  onvisibilitychange={handleVisibility}
  onfocus={() => void probeDisk()}
/>

<Header {connection} />

<SectionNav />

<RecoveryBanner {snapshots} onRestore={restoreSnapshot} onDiscard={clearRecovery} />

<main id="workspace" tabindex="-1">
  <ProjectPane
    {files}
    {activePath}
    {dirty}
    {fileQuery}
    {visibleFiles}
    {fileTreeStatus}
    {project}
    {compiler}
    onOpen={openFile}
    onCreate={openCreateDialog}
    onRename={openRenameDialog}
    onDelete={openDeleteDialog}
    onQuery={(v) => fileQuery = v}
  />

  <SourcePane
    {activePath}
    {content}
    {readOnly}
    {undoStack}
    {redoStack}
    {dirty}
    {saveInFlight}
    {authoring}
    {authoringStatus}
    {completionKind}
    {completionQuery}
    {suggestions}
    {selectedSuggestion}
    {completionOpen}
    {activeProblems}
    {staleProblems}
    {editorStatus}
    {graphPayload}
    {graphStatus}
    {activeNode}
    {parentNode}
    {graphChildren}
    {graphSiblings}
    {graphOutgoing}
    {graphBacklinks}
    {graphRelations}
    {bufferWikiLinks}
    {commandRunning}
    {scaleFactor}
    {scaleView}
    {visibleScaleView}
    {themeLayoutOpen}
    {closedLayoutSlots}
    {layoutSlotsInBuffer}
    {layoutSlotsMissing}
    {themeAssets}
    {layoutSelections}
    {publicationPayload}
    {publicationStatus}
    {selectedProfile}
    {lastPublicationPlan}
    onInput={editSource}
    onSave={() => saveFile()}
    onUndo={undo}
    onRedo={redo}
    onSelect={(i) => selectedSuggestion = i}
    onInsert={insertSuggestion}
    onKindChange={(k) => { completionKind = k; void changeCompletionKind(); }}
    onQueryChange={(q) => { completionQuery = q; completionOpen = true; }}
    onRefresh={refreshAuthoring}
    onCompletionKeydown={completionKeydown}
    onCompletionOpen={(open) => completionOpen = open}
    onTrackCursor={trackCursor}
    onNavigate={navigateToProblem}
    onOpenGraphPath={openGraphPath}
    onOpenGraphNode={openGraphNode}
    onImpact={runImpactOnCurrent}
    onScaleFactorChange={(v) => scaleFactor = v}
    onScale={() => runCommand('recipe_scale')}
    onReset={resetScale}
    onPrint={printRecipe}
    onOpenFile={openFile}
    onSelectProfile={(v) => selectedProfile = v}
    onRunPlan={() => runCommand('plan')}
  />

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
    {#if validateDaemon}
      <div class="validation-state-line">
        <p class="validation-state" role="status" aria-label="Validation state" aria-live="polite">{validationStatusLabel(validateState)}</p>
        <span class="validation-meta" aria-label="Validation cycle and report age">{validationCycleLabel(validateState)}</span>
      </div>
    {/if}
    {#if problemsNotice.text}
      <p class="problems-notice" role="status" aria-label="Problems notice" aria-live="polite">{problemsNotice.text}</p>
    {/if}
    {#if dirty && ((commandResult?.problems.length ?? 0) > 0 || problemsNotice.clean)}
      <p class="warning-text">Problems reflect saved files; the open buffer has unsaved changes.</p>
    {/if}
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

    {#if commandResult && commandResult.problems.length === 0 && !problemsNotice.text}
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
                {#if staleProblems.has(problem)}
                  <p class="warning-text">Possibly stale — the open buffer changed this region since the report.</p>
                {/if}
                {#if problem.remediation}<p><strong>Remediation:</strong> {problem.remediation}</p>{/if}
                <p class="confidence">
                  {problem.position_confidence === 'exact'
                    ? 'Exact compiler-reported source position'
                    : problem.position_confidence === 'best_effort'
                      ? (problem.source_path?.endsWith('.cook') && problem.code !== 'ECOOKLANG'
                        ? 'Position approximate: graph diagnostic on adapted Markdown, not the .cook line'
                        : 'Best-effort source position')
                      : 'No source position reported'}
                </p>
                <div class="problem-actions">
                  {#if problem.source_path}
                    <button type="button" onclick={() => navigateToProblem(problem)}>Go to {problemLocationLabel(problem)}</button>
                  {/if}
                  <button type="button" aria-label={packetCopyLabel(problem)} onclick={() => copyDiagnosticPacket(problem)}>
                    {copiedPacketKey === packetCopyKey(problem) ? 'Copied!' : packetCopyLabel(problem)}
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
    <fieldset class="preview-viewports" aria-label="Preview width">
      <legend>Preview width</legend>
      <label><input type="radio" name="preview-width" value="full" bind:group={previewWidth} /> Full pane</label>
      <label><input type="radio" name="preview-width" value="375" bind:group={previewWidth} /> 375px</label>
      <label><input type="radio" name="preview-width" value="768" bind:group={previewWidth} /> 768px</label>
      <label><input type="radio" name="preview-width" value="1440" bind:group={previewWidth} /> 1440px</label>
    </fieldset>
    <details class="preview-a11y">
      <summary>Accessibility review aid</summary>
      <p>This list does not replace Voice Control, VoiceOver, or a real audit.</p>
      <ul>
        <li>Open the preview in a new tab and run Voice Control “Show names”.</li>
        <li>Tab through the compiled page without a pointer.</li>
        <li>Check that status is not color-only.</li>
      </ul>
    </details>
    <p class="preview-state" class:current={previewData?.phase === 'success'} class:failure={previewData?.phase === 'failed' || previewData?.phase === 'stale'}>
      <strong>{previewData?.phase ?? 'idle'}:</strong> {previewState}
    </p>
    {#if previewData?.used_stderr_fallback}
      <p class="fallback-notice">Rich HTML diagnostics are unavailable; this failure message comes from bounded Boris stderr.</p>
    {/if}
    {#if previewData && (previewData.phase === 'success' || previewData.phase === 'stale')}
      <div class="preview-frame" class:constrained={previewWidth !== 'full'} style={previewWidth === 'full' ? undefined : `width:${previewWidth}px`}>
        <iframe
          title="Boris site preview"
          src={`${previewData.preview_url}&generation=${previewData.generation}`}
          sandbox="allow-same-origin"
        ></iframe>
      </div>
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

<dialog bind:this={createDialog} onkeydown={handleDialogKeydown} onclose={() => { createPath = defaultCreatePath(); restoreDialogFocus(); }} aria-labelledby="create-heading">
  <h2 id="create-heading">Create file</h2>
  <p>Use a project-relative path under content/ or themes/, or boris.json. Markdown (<code>.md</code>), Textile (<code>.textile</code>), and Cooklang (<code>.cook</code>) pages are valid.</p>
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
