export type Health = {
  status: string;
  editor_id: string;
  project: {
    content: boolean;
    default_layout: boolean;
    publication_profile: boolean;
    input_mode?: 'markdown' | 'cooklang' | 'textile' | 'mixed' | 'empty';
  };
};

export type Version = {
  compiler_id: string;
  supported?: {
    completion?: number[];
    ir?: string[];
    publication_plan?: number[];
    frontmatter?: number[];
    validate_watch?: boolean;
  };
};

export type ValidateState = {
  supported?: boolean;
  state?: 'idle' | 'running' | 'success' | 'failed' | 'stale';
  cycle?: number;
  failure_class?: FailureClass | null;
  problems_count?: number;
  report_age_ms?: number | null;
};

export type FileEntry = { path: string };
export type FileList = { files: FileEntry[] };

export const visibleFileLimit = 200;
export const unfilteredPaletteEntryLimit = 50;

export type BufferResponse = {
  status: 'opened' | 'saved' | 'created' | 'conflict';
  path: string;
  content: string;
  fingerprint: string;
  read_only: boolean;
};

export type ProbeResponse = {
  status: 'unchanged' | 'changed' | 'deleted' | 'transient';
  path?: string;
  content?: string;
  fingerprint?: string;
  read_only?: boolean;
};

export type RecoverySnapshot = { path: string; content: string; fingerprint: string };
export type RecoveryList = { snapshots: RecoverySnapshot[]; skipped?: number };
export type ErrorResponse = { error?: string; status?: string };
export type CommandMode = 'validate' | 'ir_build' | 'html_build' | 'check' | 'impact' | 'plan' | 'recipe_scale';
export type FailureClass = 'success' | 'content' | 'usage' | 'io' | 'terminated';

export type PendingResolution =
  | { action: 'open'; target: string }
  | { action: 'command'; mode: CommandMode }
  | { action: 'preview'; reason: 'save' | 'manual' }
  | { action: 'restore'; snapshot: RecoverySnapshot };

export type PaletteItem =
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

export type Problem = {
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

export type AnalysisFinding = {
  code: string;
  endpoint_type: 'page' | 'source';
  value: string;
  count: number;
  source_path: string | null;
  line: number | null;
  column: number | null;
};

export type ImpactEndpoint = { endpoint_type: 'page' | 'source'; value: string };

export type PublicationSite = { url?: string | null; title?: string | null; description?: string | null };

export type PublicationIdentity = {
  target?: string | null;
  base_url?: string | null;
  origin?: string | null;
  base_path?: string | null;
  site_kind?: string | null;
};

export type PublicationTarget = {
  name: string;
  output: string;
  public?: boolean | null;
  theme?: string | null;
  layout?: string | null;
};

export type PublicationPlan = {
  format: string;
  schema_version: number;
  input: string;
  input_format: string;
  site?: PublicationSite | null;
  publication?: PublicationIdentity | null;
  targets: PublicationTarget[];
  editions?: { ir?: unknown; rag?: unknown; context?: unknown };
};

export type PublicationProfile = { path: string };

export type PublicationProof = {
  path: string;
  html_path: string | null;
  target: string;
  schema_version: string;
  overall_presentation_status: string;
  artifacts_total: number;
  checks_total: number;
  findings_total: number;
  claims_total: number;
};

export type PublicationPayload = {
  profiles: PublicationProfile[];
  proof: PublicationProof | null;
  proof_status?: 'ready' | 'absent' | 'unsupported';
};

export type CommandResult = {
  mode: CommandMode;
  exit_code: number | null;
  failure_class: FailureClass;
  compiler_id: string;
  report_version: string | null;
  used_stderr_fallback: boolean;
  problems: Problem[];
  findings: AnalysisFinding[];
  impact: ImpactEndpoint[];
  publication_plan?: PublicationPlan | null;
  recipe_scale_view?: RecipeScaleView | null;
};

export type ProblemGroup = { key: string; label: string; problems: Problem[] };

export type JsonSchemaProperty = {
  type?: string | string[];
  enum?: Array<string | null>;
  maxLength?: number;
  maxItems?: number;
  pattern?: string;
  items?: JsonSchemaProperty;
};

export type CompletionEntity = {
  id: string;
  title: string | null;
  parent: string | null;
  role: string;
  status: string | null;
  tags: string[];
  relations: Array<{ kind: string; target: string }>;
};

export type CompletionIndex = {
  format: string;
  schema_version: number;
  compiler_id: string;
  frozen: boolean;
  entities: CompletionEntity[];
  relation_kinds: string[];
  parent_targets: string[];
  layout_slots: string[];
};

export type AuthoringPayload = {
  frontmatter_schema: { title: string; properties: Record<string, JsonSchemaProperty> };
  completion: CompletionIndex | null;
  completion_status: 'ready' | 'build_required' | 'unsupported';
};

export type CompletionKind =
  | 'frontmatter_key'
  | 'status'
  | 'entity'
  | 'wiki_link'
  | 'parent'
  | 'relation_kind'
  | 'relation_target'
  | 'layout_slot';

export type Suggestion = { value: string; insert: string; detail: string };

export type PreviewState = {
  phase: 'idle' | 'running' | 'success' | 'failed' | 'stale';
  generation: number;
  exit_code: number | null;
  used_stderr_fallback: boolean;
  message: string;
  preview_url: string;
};

export type GraphEndpoint = { type: 'page' | 'source'; value: string };
export type RecipeQuantity = { amount: string; unit: string };
export type RecipeIngredient = { name: string; quantity: RecipeQuantity; preparation: string; recipeRef: string | null };
export type RecipeItem = { name: string; quantity: RecipeQuantity };
export type RecipeFacet = { ingredients: RecipeIngredient[]; cookware: RecipeItem[]; timers: RecipeItem[] };
export type RecipeScaleAmount = { class: 'empty' | 'scalable' | 'fixed'; original: string; scaled: string };
export type RecipeScaleQuantity = { amount: RecipeScaleAmount; unit: string };

export type RecipeScaleView = {
  format: string;
  schemaVersion: string;
  compiler: string;
  factor: { num: number; den: number };
  page: string;
  ingredients: Array<{
    name: string;
    quantity: RecipeScaleQuantity;
    preparation: string;
    recipeRef: string | null;
  }>;
  cookware: Array<{ name: string; quantity: RecipeScaleQuantity }>;
  timers: Array<{ name: string; quantity: RecipeScaleQuantity }>;
};

export type GraphNode = {
  index: number;
  id: string;
  sourcePath: string;
  role: string;
  parent: string | null;
  parentIndex: number | null;
  title: string | null;
  status: string | null;
  tags: string[];
  bodyOffset: number;
  recipe?: RecipeFacet | null;
};

export type GraphEdge = { from: GraphEndpoint; to: GraphEndpoint; kind: 'parent' | 'include' | 'reference' };
export type GraphNav = { index: number; id: string; breadcrumb: number[]; children: number[]; siblings: number[] };

export type GraphDocument = {
  schemaVersion: string;
  frozen: boolean;
  nodes: GraphNode[];
  edges: GraphEdge[];
  reverseIndex: Array<{ target: GraphEndpoint; incomingEdges: number[] }>;
  nav: GraphNav[];
};

export type GraphPayload = { graph: GraphDocument | null; graph_status: 'ready' | 'build_required' | 'unsupported' };
export type GraphLink = { label: string; path: string; kind: string };
