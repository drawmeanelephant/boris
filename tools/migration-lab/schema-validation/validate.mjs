import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

const here = dirname(fileURLToPath(import.meta.url));
const contracts = join(here, "../../../docs/contracts/schemas");
const validDir = join(here, "fixtures/valid");

async function json(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

const schemaFiles = {
  snapshot: join(contracts, "astro-source-snapshot-1.schema.json"),
  plan: join(contracts, "astro-import-plan-1.schema.json"),
  manifest: join(contracts, "astro-import-manifest-1.schema.json"),
};
const validFiles = {
  snapshot: join(validDir, "source_snapshot.json"),
  plan: join(validDir, "import_plan.json"),
  manifest: join(validDir, "previous_manifest.json"),
};
const policyFile = join(contracts, "../astro-import-plan-policy-v1.json");

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validators = {};
const validArtifacts = {};
for (const kind of Object.keys(schemaFiles)) {
  const schema = await json(schemaFiles[kind]);
  validators[kind] = ajv.compile(schema);
  validArtifacts[kind] = await json(validFiles[kind]);
  assert.equal(
    validators[kind](validArtifacts[kind]),
    true,
    `${kind} valid artifact failed: ${ajv.errorsText(validators[kind].errors)}`,
  );
}

const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const compactSnapshot = JSON.stringify(validArtifacts.snapshot);
const compactDigestInput = JSON.stringify(validArtifacts.plan.digest_input);
const policyBytes = await readFile(policyFile);
assert.equal(validArtifacts.snapshot.policy_hash, sha256(policyBytes), "policy digest mismatch");
assert.equal(validArtifacts.plan.digest_input.importer_policy_digest, sha256(policyBytes), "plan policy digest mismatch");
assert.equal(validArtifacts.plan.digest_input.source_snapshot_digest, sha256(compactSnapshot), "snapshot digest mismatch");
assert.equal(validArtifacts.plan.plan_digest, sha256(compactDigestInput), "plan digest mismatch");
assert.equal(validArtifacts.plan.digest_input.previous_manifest_digest, null, "fixture unexpectedly carries a previous manifest digest");

let treeStream = "boris-astro-source-tree-v1\n";
for (const record of validArtifacts.snapshot.records) {
  const pathBytes = Buffer.byteLength(record.source_path, "utf8");
  const kindBytes = Buffer.byteLength(record.source_kind, "utf8");
  treeStream += `path:${pathBytes}:${record.source_path}\n`;
  treeStream += `kind:${kindBytes}:${record.source_kind}\n`;
  treeStream += `sha256:${record.exact_byte_hash ?? "null"}\n`;
  treeStream += record.symlink_target === null
    ? "symlink_target:null\n"
    : `symlink_target:${Buffer.byteLength(record.symlink_target, "utf8")}:${record.symlink_target}\n`;
}
assert.equal(validArtifacts.snapshot.source_tree_fingerprint, sha256(treeStream), "source-tree fingerprint mismatch");

const clone = (value) => structuredClone(value);
const cases = [
  ["snapshot", "unknown top-level field", "additionalProperties", (v) => { v.extra = true; }],
  ["snapshot", "uppercase hash", "pattern", (v) => { v.policy_hash = "A".repeat(64); }],
  ["snapshot", "backslash source path", "pattern", (v) => { v.records[0].source_path = "bad\\path.md"; }],
  ["snapshot", "empty source path", "minLength", (v) => { v.records[0].source_path = ""; }],
  ["snapshot", "regular file without exact hash", "type", (v) => { v.records[0].exact_byte_hash = null; }],
  ["snapshot", "symlink carrying regular hashes", "type", (v) => {
    v.records[0].source_kind = "symlink";
    v.records[0].symlink_target = "../target";
  }],
  ["snapshot", "unsupported classification", "enum", (v) => { v.records[0].classification = "apply"; }],
  ["snapshot", "malformed reference classification", "enum", (v) => { v.records[0].references[0].classification = "remote"; }],
  ["snapshot", "unknown asset field", "additionalProperties", (v) => { v.records[0].potential_asset_references[0].copied = true; }],

  ["plan", "unknown top-level field", "additionalProperties", (v) => { v.extra = true; }],
  ["plan", "uppercase digest", "pattern", (v) => { v.plan_digest = "F".repeat(64); }],
  ["plan", "unknown action field", "additionalProperties", (v) => { v.digest_input.proposed_actions[0].apply = true; }],
  ["plan", "unsupported action class", "enum", (v) => { v.digest_input.proposed_actions[0].class = "delete"; }],
  ["plan", "escaping proposed source path", "pattern", (v) => { v.digest_input.proposed_actions[0].proposed_boris_source_path = "content/../escape.md"; }],
  ["plan", "backslash source path", "pattern", (v) => { v.digest_input.proposed_actions[0].source_path = "bad\\path.md"; }],
  ["plan", "empty proposed entity", "minLength", (v) => { v.digest_input.proposed_actions[0].proposed_entity_id = ""; }],
  ["plan", "empty route", "minLength", (v) => { v.digest_input.proposed_actions[0].proposed_boris_route = ""; }],
  ["plan", "create without source hash", "type", (v) => { v.digest_input.proposed_actions[0].source_hash = null; }],
  ["plan", "create with invalid loss classification", "const", (v) => { v.digest_input.proposed_actions[0].loss_classification = "not_convertible"; }],
  ["plan", "create without preconditions", "minItems", (v) => { v.digest_input.proposed_actions[0].preconditions = []; }],
  ["plan", "closed frontmatter unknown field", "additionalProperties", (v) => { v.digest_input.proposed_actions[0].proposed_closed_frontmatter.parent = "root"; }],
  ["plan", "empty finding reason", "minLength", (v) => {
    v.digest_input.findings = [{ class: "conflict", reason: "", source_paths: ["a.md", "b.md"] }];
  }],
  ["plan", "conflict finding with one path", "minItems", (v) => {
    v.digest_input.findings = [{ class: "conflict", reason: "duplicate_proposed_entity_id", source_paths: ["a.md"] }];
  }],

  ["manifest", "unknown top-level field", "additionalProperties", (v) => { v.extra = true; }],
  ["manifest", "backslash source path", "pattern", (v) => { v.records[0].source_path = "bad\\path.md"; }],
  ["manifest", "malformed import record id", "pattern", (v) => { v.records[0].import_record_id = "air_BAD"; }],
  ["manifest", "unknown record field", "additionalProperties", (v) => { v.records[0].extra = true; }],
];

for (const [kind, name, keyword, mutate] of cases) {
  const mutant = clone(validArtifacts[kind]);
  mutate(mutant);
  const accepted = validators[kind](mutant);
  assert.equal(accepted, false, `${kind}/${name} was unexpectedly accepted`);
  assert(
    validators[kind].errors.some((error) => error.keyword === keyword),
    `${kind}/${name} failed without expected ${keyword}: ${ajv.errorsText(validators[kind].errors)}`,
  );
}

console.log(`astro-import-schema-validation: 3 valid artifacts passed; ${cases.length} malformed mutants rejected`);
