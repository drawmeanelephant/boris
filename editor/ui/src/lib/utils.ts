// editor/ui/src/lib/utils.ts
// Pure helpers extracted from App.svelte. No fetch, no DOM, no closure.
// Each function is a deliberate pure extraction so it can be unit-tested
// outside Playwright and reused by future scoped components.

import type {
  AnalysisFinding,
  AuthoringPayload,
  CommandMode,
  CompletionKind,
  FailureClass,
  GraphDocument,
  GraphEndpoint,
  GraphLink,
  GraphNav,
  GraphNode,
  JsonSchemaProperty,
  PaletteItem,
  Problem,
  ProblemGroup,
  RecipeQuantity,
  RecipeScaleQuantity,
  Suggestion,
  ValidateState,
} from './types';
import { visibleFileLimit } from './types';

export function commandLabel(mode: CommandMode): string {
  return (
    {
      validate: 'Validate project',
      ir_build: 'Build diagnostics',
      html_build: 'Build HTML',
      check: 'Check graph',
      impact: 'Run impact',
      plan: 'Run publication plan',
      recipe_scale: 'Scale recipe',
    } satisfies Record<CommandMode, string>
  )[mode];
}

export function versionLabel(version: { compiler_id: string; supported?: { ir?: string[] } }): string {
  const ir = version.supported?.ir;
  const range = ir && ir.length > 0 ? `; IR ${ir[0]}${ir.length > 1 ? `–${ir[ir.length - 1]}` : ''}` : '';
  return `Compiler: ${version.compiler_id}${range}`;
}

export function failureLabel(failure: FailureClass, exitCode: number | null): string {
  const labels: Record<FailureClass, string> = {
    success: 'Success',
    content: 'Content or graph failure',
    usage: 'Usage or configuration failure',
    io: 'I/O or system failure',
    terminated: 'Process terminated',
  };
  return exitCode === null ? labels[failure] : `${labels[failure]} (exit ${exitCode})`;
}

export function groupProblems(problems: Problem[]): ProblemGroup[] {
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

export function projectPathForProblem(sourcePath: string): string {
  if (sourcePath === 'boris.json' || sourcePath.startsWith('content/') || sourcePath.startsWith('themes/'))
    return sourcePath;
  return `content/${sourcePath}`;
}

export function projectPathForGraphSource(sourcePath: string): string {
  return projectPathForProblem(sourcePath);
}

export function nodeForPath(graph: GraphDocument | null, path: string): GraphNode | null {
  if (!graph || !path) return null;
  return graph.nodes.find((node) => projectPathForGraphSource(node.sourcePath) === path) ?? null;
}

export function nodeForId(graph: GraphDocument | null, id: string): GraphNode | null {
  if (!graph) return null;
  return graph.nodes.find((node) => node.id === id) ?? null;
}

export function navForNode(graph: GraphDocument | null, node: GraphNode | null): GraphNav | null {
  if (!graph || !node) return null;
  return graph.nav.find((entry) => entry.id === node.id) ?? null;
}

export function graphLinksForIndices(graph: GraphDocument | null, indices: number[]): GraphLink[] {
  if (!graph) return [];
  return indices.flatMap((index) => {
    const node = graph.nodes.find((entry) => entry.index === index);
    if (!node) return [];
    return [
      {
        label: node.title ? `${node.id} · ${node.title}` : node.id,
        path: projectPathForGraphSource(node.sourcePath),
        kind: 'page',
      },
    ];
  });
}

export function endpointPath(graph: GraphDocument | null, endpoint: GraphEndpoint): string | null {
  if (endpoint.type === 'page') {
    const node = nodeForId(graph, endpoint.value);
    return node ? projectPathForGraphSource(node.sourcePath) : null;
  }
  return projectPathForGraphSource(endpoint.value);
}

export function outgoingGraphLinks(graph: GraphDocument | null, node: GraphNode | null): GraphLink[] {
  if (!graph || !node) return [];
  return graph.edges.flatMap((edge) => {
    if (edge.from.type !== 'page' || edge.from.value !== node.id || edge.kind === 'parent') return [];
    const path = endpointPath(graph, edge.to);
    if (!path) return [];
    return [{ label: `${edge.kind} → ${edge.to.value}`, path, kind: edge.kind }];
  });
}

export function incomingGraphLinks(graph: GraphDocument | null, node: GraphNode | null): GraphLink[] {
  if (!graph || !node) return [];
  const incoming = graph.reverseIndex.find((entry) => entry.target.type === 'page' && entry.target.value === node.id);
  if (!incoming) return [];
  return incoming.incomingEdges.flatMap((index) => {
    const edge = graph.edges[index];
    if (!edge) return [];
    const path = endpointPath(graph, edge.from);
    if (!path) return [];
    return [{ label: `${edge.kind} ← ${edge.from.value}`, path, kind: edge.kind }];
  });
}

export function wikiLinksInSource(source: string): string[] {
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

export function quantityLabel(quantity: RecipeQuantity): string {
  return [quantity.amount, quantity.unit].filter((part) => part.trim() !== '').join(' ');
}

export function displayQuantity(
  authored: RecipeQuantity,
  scaled: RecipeScaleQuantity | undefined,
  timer: boolean,
): string {
  const original = quantityLabel(authored);
  if (timer || !scaled || scaled.amount.scaled === scaled.amount.original) return original || '—';
  const scaledLabel = [scaled.amount.scaled, scaled.unit].filter((part) => part.trim() !== '').join(' ');
  if (!original) return scaledLabel || '—';
  return `${original} → ${scaledLabel}`;
}

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character] ?? character));
}

export function sourceOffset(source: string, line: number | null, column: number | null): number {
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

export function packetCopyKey(problem: Problem): string {
  return `${problem.code ?? ''}\0${problem.source_path ?? ''}\0${problem.line ?? ''}\0${problem.column ?? ''}\0${problem.packet}`;
}

export function packetCopyLabel(problem: Problem): string {
  return `Copy packet for ${problem.code ?? 'unstructured Boris output'} at ${problem.source_path ?? 'project'}`;
}

export function problemLocationLabel(problem: Problem | AnalysisFinding): string {
  if (!problem.source_path) return 'project';
  if (!problem.line) return problem.source_path;
  return `${problem.source_path} line ${problem.line}${problem.column ? ` column ${problem.column}` : ''}`;
}

export function schemaHint(property: JsonSchemaProperty): string {
  const type = Array.isArray(property.type)
    ? property.type.filter((value) => value !== 'null').join(' or ')
    : (property.type ?? 'value');
  const bounds = property.maxLength
    ? ` · at most ${property.maxLength} characters`
    : property.maxItems
      ? ` · at most ${property.maxItems} items`
      : '';
  return `${type}${bounds}`;
}

export function completionSuggestions(
  payload: AuthoringPayload | null,
  kind: CompletionKind,
  query: string,
): Suggestion[] {
  if (!payload) return [];
  const schema = payload.frontmatter_schema.properties;
  const index = payload.completion;
  let values: Suggestion[] = [];
  if (kind === 'frontmatter_key')
    values = Object.entries(schema).map(([name, property]) => ({
      value: name,
      insert: `${name}: `,
      detail: schemaHint(property),
    }));
  if (kind === 'status')
    values = (schema.status?.enum ?? [])
      .filter((value): value is string => typeof value === 'string')
      .map((value) => ({ value, insert: value, detail: 'Closed enum from Boris frontmatter schema' }));
  if (kind === 'entity' || kind === 'relation_target')
    values = (index?.entities ?? []).map((entity) => ({
      value: entity.id,
      insert: entity.id,
      detail: `${entity.role}${entity.title ? ` · ${entity.title}` : ''}`,
    }));
  if (kind === 'wiki_link')
    values = (index?.entities ?? []).map((entity) => ({
      value: entity.id,
      insert: `[[${entity.id}]]`,
      detail: entity.title ?? entity.role,
    }));
  if (kind === 'parent')
    values = (index?.parent_targets ?? []).map((value) => ({
      value,
      insert: value,
      detail: 'Observed parent target from completion.json',
    }));
  if (kind === 'relation_kind')
    values = (index?.relation_kinds ?? []).map((value) => ({
      value,
      insert: `${value}=`,
      detail: 'Relation kind from completion.json',
    }));
  if (kind === 'layout_slot')
    values = (index?.layout_slots ?? []).map((value) => ({
      value,
      insert: `{{${value}}}`,
      detail: 'Closed layout slot from completion.json',
    }));
  const needle = query.trim().toLocaleLowerCase();
  return values.filter((item) => !needle || item.value.toLocaleLowerCase().startsWith(needle)).slice(0, 50);
}

// --- validation helpers (honest state naming #654) ---

export function validationStatusLabel(state: ValidateState | null): string {
  if (!state) return '';
  const cycle = state.cycle ?? 0;
  const count = state.problems_count ?? 0;
  switch (state.state) {
    case 'idle':
      return 'Validation is idle. Run Validate project to start the daemon.';
    case 'running':
      return 'Validation is running the first cycle…';
    case 'success':
      return `Validation passed (cycle ${cycle}).`;
    case 'failed':
      return `Validation failed — ${count} problem${count === 1 ? '' : 's'} (cycle ${cycle}).`;
    case 'stale':
      return 'Validation daemon is restarting with backoff.';
    default:
      return '';
  }
}

export function reportAgeLabel(ageMs: number | null | undefined): string {
  if (ageMs == null) return 'Report age: —';
  if (ageMs < 1000) return 'Report age: <1s';
  if (ageMs < 60_000) return `Report age: ${Math.floor(ageMs / 1000)}s`;
  const minutes = Math.floor(ageMs / 60_000);
  const seconds = Math.floor((ageMs % 60_000) / 1000);
  return `Report age: ${minutes}m ${seconds}s`;
}

export function validationCycleLabel(state: ValidateState | null): string {
  if (!state || state.cycle === undefined) return 'Cycle: — · Report age: —';
  return `Cycle ${state.cycle} · ${reportAgeLabel(state.report_age_ms)}`;
}

// --- palette helpers ---

export function paletteItemMatches(item: PaletteItem, needle: string): boolean {
  if (!needle) return true;
  return (
    paletteItemLabel(item).toLocaleLowerCase().includes(needle) ||
    paletteItemDetailPure(item, null).toLocaleLowerCase().includes(needle)
  );
}

// Pure label (no closure).
export function paletteItemLabel(item: PaletteItem): string {
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

// Pure detail that takes resolved context explicitly so components can remain
// prop-drilled without calling fetch. The App orchestrator will supply the
// App-closed values (activePath, parentNode, activeNode, graph) via wrapper.
export function paletteItemDetailPure(
  item: PaletteItem,
  ctx: {
    activePath?: string;
    parentNode?: { id: string; title: string | null } | null;
    activeNode?: { id: string } | null;
    graphPayload?: { graph: GraphDocument | null } | null;
  } | null,
): string {
  if (item.kind === 'create') return 'New project-relative path';
  if (item.kind === 'rename' || item.kind === 'delete' || item.kind === 'save') return ctx?.activePath ?? '';
  if (item.kind === 'command') return 'Boris command';
  if (item.kind === 'preview') return 'Rebuild the published output';
  if (item.kind === 'source') return 'Jump to the editor';
  if (item.kind === 'parent')
    return ctx?.parentNode ? `${ctx.parentNode.id}${ctx.parentNode.title ? ` · ${ctx.parentNode.title}` : ''}` : 'No parent in the Boris graph';
  if (item.kind === 'impact-here') return ctx?.activeNode ? ctx.activeNode.id : 'No graph page is open';
  if (item.kind === 'entity') {
    const node = ctx?.graphPayload?.graph ? nodeForId(ctx.graphPayload.graph, item.id) : null;
    return node?.title ?? 'Boris graph entity';
  }
  return item.path;
}

// Back-compat wrapper used by App.svelte until it is fully prop-drilled.
// Keeps dir-ty closure signatures stable for slice 1 (zero template change).
// App.svelte's local paletteItemDetail will delegate here.
export function paletteItemDetailWrapper(
  item: PaletteItem,
  activePath: string,
  parentNode: { id: string; title: string | null } | null,
  activeNode: { id: string } | null,
  graphPayload: { graph: GraphDocument | null } | null,
): string {
  return paletteItemDetailPure(item, { activePath, parentNode, activeNode, graphPayload });
}

export function paletteItemKey(item: PaletteItem): string {
  if (item.kind === 'open') return `open:${item.path}`;
  if (item.kind === 'entity') return `entity:${item.id}`;
  if (item.kind === 'command') return `command:${item.mode}`;
  return item.kind;
}

export function paletteItemEnabledPure(
  item: PaletteItem,
  ctx: {
    commandRunning: boolean;
    dirty: boolean;
    readOnly: boolean;
    saveInFlight: boolean;
    activePath: string;
    activeNode: unknown | null;
    parentNode: unknown | null;
    previewPhase?: string;
  },
): boolean {
  if (item.kind === 'open' || item.kind === 'source' || item.kind === 'entity') return true;
  if (item.kind === 'parent') return ctx.parentNode !== null;
  if (item.kind === 'impact-here') return ctx.activeNode !== null && !ctx.commandRunning;
  if (item.kind === 'save') return ctx.dirty && !ctx.readOnly && !ctx.saveInFlight;
  if (item.kind === 'preview') return ctx.previewPhase !== 'running';
  if (item.kind === 'command') return !ctx.commandRunning;
  if (ctx.dirty) return false;
  return item.kind === 'create' || ctx.activePath !== '';
}

export function fileTreeAnnouncement(total: number, matched: number, shown: number, query: string): string {
  if (total === 0) return '';
  const needle = query.trim();
  if (needle) {
    if (matched === 0) return `No project files match “${needle}”.`;
    if (matched > shown)
      return `Showing ${shown} of ${matched} project files matching “${needle}”. Filter further to find the rest.`;
    return `${matched} project file${matched === 1 ? ' matches' : 's match'} “${needle}”.`;
  }
  if (matched > visibleFileLimit) return `Showing ${shown} of ${total} project files. Filter to find the rest.`;
  return '';
}

export function defaultCreatePath(inputMode: string): string {
  if (inputMode === 'cooklang') return 'content/new-recipe.cook';
  if (inputMode === 'textile') return 'content/new-page.textile';
  return 'content/new-page.md';
}
