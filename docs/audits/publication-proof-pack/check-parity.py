#!/usr/bin/env python3
"""HTML-to-JSON parity check for the Publication Proof Pack examples.

Every displayed fact in each HTML example must match its paired
proof-pack.json model exactly: target, overall status, summary totals,
artifact paths/statuses/bytes/digests, check status/coverage/counts, finding
IDs/codes/severities/subjects, claim IDs/statements/statuses, limitation
IDs/statements/sources, relationship node IDs, and relationship edge tuples.

Repository-compatible tooling: Python standard library only, no runtime
dependency. Run from the repository root:

    python3 docs/audits/publication-proof-pack/check-parity.py

Exit status: 0 when every pair is in parity; 1 otherwise.
"""
import hashlib
import json
import re
import sys
from html.parser import HTMLParser

EXAMPLES = "docs/audits/publication-proof-pack/examples"

PAIRS = [
    ("clean.json", "index-clean.html"),
    ("attention-required.json", "index-attention-required.html"),
]


def norm(s):
    return " ".join(s.split())


class Extract(HTMLParser):
    """Collect the structured facts rendered in one example page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.section = None          # current h2 heading text
        self.sub = None              # current h3 heading text
        self.tables = []             # [(section, sub, rows)] rows: list of cell lists
        self.lists = []              # [(section, sub, items)]
        self.headings = []           # [(section, sub)] for every h3 heading
        self.meta_text = ""
        self.banner_text = ""
        self.in_meta = False
        self.in_banner = False
        self.in_cell = False
        self.cell = []
        self.row = None
        self.rows = None
        self.in_li = False
        self.li = []
        self.items = None
        self.cur_ul = None
        self.heading_buf = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("h1", "h2", "h3"):
            self.heading_buf = []
        elif tag == "p" and "meta" in attrs.get("class", "").split():
            self.in_meta = True
            self.meta_text = []
        elif tag == "div" and "banner" in attrs.get("class", "").split():
            self.in_banner = True
            self.banner_text = []
        elif tag == "table":
            self.rows = []
        elif tag == "tr" and self.rows is not None:
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.in_cell = True
            self.cell = []
        elif tag == "ul":
            self.items = []
            self.cur_ul = self.items
        elif tag == "li" and self.cur_ul is not None:
            self.in_li = True
            self.li = []

    def handle_endtag(self, tag):
        if tag in ("h1", "h2", "h3") and self.heading_buf is not None:
            text = norm("".join(self.heading_buf))
            self.heading_buf = None
            if tag == "h2":
                self.section = text
            else:
                self.sub = text
                self.headings.append((self.section, text))
        elif tag == "p" and self.in_meta:
            self.meta_text = norm("".join(self.meta_text))
            self.in_meta = False
        elif tag == "div" and self.in_banner:
            self.banner_text = norm("".join(self.banner_text))
            self.in_banner = False
        elif tag == "table" and self.rows is not None:
            self.tables.append((self.section, self.sub, self.rows))
            self.rows = None
            self.row = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None
        elif tag in ("td", "th") and self.in_cell:
            self.row.append(norm("".join(self.cell)))
            self.cell = None
            self.in_cell = False
        elif tag == "ul" and self.cur_ul is not None:
            self.lists.append((self.section, self.sub, self.items))
            self.cur_ul = None
            self.items = None
        elif tag == "li" and self.in_li:
            self.items.append(norm("".join(self.li)))
            self.li = None
            self.in_li = False

    def handle_data(self, data):
        if self.heading_buf is not None:
            self.heading_buf.append(data)
        elif self.in_meta:
            self.meta_text.append(data)
        elif self.in_banner:
            self.banner_text.append(data)
        elif self.in_cell:
            self.cell.append(data)
        elif self.in_li:
            self.li.append(data)


def parse_html(path):
    text = open(path, encoding="utf-8").read()
    ex = Extract()
    ex.feed(text)
    return ex


def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def fail(msg):
    print("  FAIL " + msg)
    return False


def check(pair_name, model, ex):
    ok = True

    # Target (rendered in the meta paragraph)
    if not re.search(r"target\s+public", ex.meta_text):
        ok = fail(f"target 'public' not in meta text: {ex.meta_text!r}")
    if ex.meta_text and "boris-publication-proof-pack" not in ex.meta_text:
        ok = fail("format const not in meta text")

    # Overall status (banner) == JSON summary + presentation
    expected = model["summary"]["overall_presentation_status"]
    if expected not in ex.banner_text:
        ok = fail(f"banner missing overall status {expected!r}: {ex.banner_text!r}")
    if model["presentation"]["overall_status"] != expected:
        ok = fail("presentation.overall_status != summary.overall_presentation_status")

    # Embedded model digest
    html_path = f"{EXAMPLES}/{pair_name[1]}"
    html_text = open(html_path, encoding="utf-8").read()
    dm = re.search(r'name="proof-pack-sha256" content="([0-9a-f]{64})"', html_text)
    if not dm:
        ok = fail("HTML missing embedded proof-pack-sha256 meta")
    else:
        want = digest(f"{EXAMPLES}/{pair_name[0]}")
        if dm.group(1) != want:
            ok = fail(f"embedded model digest {dm.group(1)} != JSON sha256 {want}")

    # Summary totals
    summary = model["summary"]
    summary_rows = {}
    for section, sub, rows in ex.tables:
        if section == "Summary":
            for row in rows:
                if len(row) >= 2:
                    summary_rows[row[0]] = row[1]
    check_summary = True
    arts = summary["artifacts"]
    if f"{arts['total']} total" not in summary_rows.get("Artifacts", ""):
        check_summary = fail("summary artifacts total mismatch")
    for k, v in arts["by_status"].items():
        if f"{k} {v}" not in summary_rows.get("Artifacts", ""):
            check_summary = fail(f"summary artifacts by_status {k}={v} missing")
    for k, v in arts["by_kind"].items():
        if f"{k} {v}" not in summary_rows.get("Artifacts", ""):
            check_summary = fail(f"summary artifacts by_kind {k}={v} missing")
    chk = summary["checks"]
    if f"{chk['total']} total" not in summary_rows.get("Checks", ""):
        check_summary = fail("summary checks total mismatch")
    for k, v in chk["by_status"].items():
        if f"{k} {v}" not in summary_rows.get("Checks", ""):
            check_summary = fail(f"summary checks by_status {k}={v} missing")
    for k, v in chk["by_coverage"].items():
        if f"coverage {k} {v}" not in summary_rows.get("Checks", ""):
            check_summary = fail(f"summary checks by_coverage {k}={v} missing")
    fd = summary["findings"]
    if f"{fd['total']} total" not in summary_rows.get("Findings", ""):
        check_summary = fail("summary findings total mismatch")
    for k, v in fd["by_severity"].items():
        if f"{k} {v}" not in summary_rows.get("Findings", ""):
            check_summary = fail(f"summary findings by_severity {k}={v} missing")
    cl = summary["claims"]
    if f"{cl['total']} total" not in summary_rows.get("Claims", ""):
        check_summary = fail("summary claims total mismatch")
    for k, v in cl["by_status"].items():
        if f"{k} {v}" not in summary_rows.get("Claims", ""):
            check_summary = fail(f"summary claims by_status {k}={v} missing")
    if str(summary["limitation_count"]) not in summary_rows.get("Limitations", ""):
        check_summary = fail("summary limitation_count mismatch")
    if f"{summary['relationship_node_count']} nodes" not in summary_rows.get("Relationship graph", "") \
       or f"{summary['relationship_edge_count']} edges" not in summary_rows.get("Relationship graph", ""):
        check_summary = fail("summary relationship node/edge counts mismatch")
    if summary_rows.get("Overall presentation status", "") != expected:
        check_summary = fail("summary overall presentation status mismatch")
    ok = check_summary and ok

    # Artifact rows
    art_rows = {}
    for section, sub, rows in ex.tables:
        if section == "Artifacts":
            for row in rows:
                if row and row[0].isdigit():
                    art_rows[int(row[0])] = row
    model_arts = model["artifacts"]
    if len(art_rows) != len(model_arts):
        ok = fail(f"artifact row count {len(art_rows)} != model {len(model_arts)}")
    for i, a in enumerate(model_arts):
        row = art_rows.get(i)
        if row is None:
            ok = fail(f"missing artifact row {i}")
            continue
        # [idx, path, kind, status, required, bytes, sha256, related checks, related claims]
        if len(row) < 5:
            ok = fail(f"artifact row {i} too short: {row}")
            continue
        if row[1] != a["path"]:
            ok = fail(f"artifact {i} path {row[1]!r} != {a['path']!r}")
        if row[2] != a["kind"]:
            ok = fail(f"artifact {i} kind {row[2]!r} != {a['kind']!r}")
        if row[3] != a["status"]:
            ok = fail(f"artifact {i} status {row[3]!r} != {a['status']!r}")
        want_req = "yes" if a["required"] else "no"
        if row[4] != want_req:
            ok = fail(f"artifact {i} required {row[4]!r} != {want_req!r}")
        if a["status"] == "committed":
            if str(a["bytes"]) != row[5]:
                ok = fail(f"artifact {i} bytes {row[5]!r} != {a['bytes']}")
            if a["sha256"] != row[6]:
                ok = fail(f"artifact {i} sha256 mismatch")
            got_checks = [] if row[7] in ("—", "") else [x.strip() for x in row[7].split(",")]
            got_claims = [] if row[8] in ("—", "") else [x.strip() for x in row[8].split(",")]
            if got_checks != a["related_check_ids"]:
                ok = fail(f"artifact {i} related_check_ids mismatch")
            if got_claims != a["related_claim_ids"]:
                ok = fail(f"artifact {i} related_claim_ids mismatch")
        else:
            # non-committed: bytes/sha256 must be absent from the model
            if "bytes" in a or "sha256" in a:
                ok = fail(f"artifact {i} non-committed must omit bytes/sha256")
            if len(row) < 6 or "no committed bytes" not in row[5]:
                ok = fail(f"artifact {i} must render 'no committed bytes'")
            got_checks = [] if row[-2] in ("—", "") else [x.strip() for x in row[-2].split(",")]
            got_claims = [] if row[-1] in ("—", "") else [x.strip() for x in row[-1].split(",")]
            if got_checks != a["related_check_ids"]:
                ok = fail(f"artifact {i} related_check_ids mismatch (non-committed)")
            if got_claims != a["related_claim_ids"]:
                ok = fail(f"artifact {i} related_claim_ids mismatch (non-committed)")

    # Check rows
    chk_rows = {}
    for section, sub, rows in ex.tables:
        if section == "Checks":
            for row in rows:
                if row and row[0].isdigit():
                    chk_rows[int(row[0])] = row
    model_checks = model["checks"]
    if len(chk_rows) != len(model_checks):
        ok = fail(f"check row count {len(chk_rows)} != model {len(model_checks)}")
    for i, c in enumerate(model_checks):
        row = chk_rows.get(i)
        if row is None:
            ok = fail(f"missing check row {i}")
            continue
        # [idx, check, status, coverage, eligible, ran, counts, subject, supporting, supported]
        if row[1] != c["check_id"]:
            ok = fail(f"check {i} id {row[1]!r} != {c['check_id']!r}")
        if row[2] != c["status"]:
            ok = fail(f"check {i} status {row[2]!r} != {c['status']!r}")
        if row[3] != c["coverage"]:
            ok = fail(f"check {i} coverage {row[3]!r} != {c['coverage']!r}")
        if (row[4] == "yes") != c["eligible"]:
            ok = fail(f"check {i} eligible mismatch")
        if (row[5] == "yes") != c["ran"]:
            ok = fail(f"check {i} ran mismatch")
        counts = c["counts"]
        if row[6] != f"{counts['eligible']} / {counts['checked']} / {counts['findings']}":
            ok = fail(f"check {i} counts {row[6]!r} != {counts}")
        got_subj = [] if row[7] == "—" else [x.strip() for x in row[7].split(",")]
        got_supp = [] if row[8] == "—" else [x.strip() for x in row[8].split(",")]
        got_supc = [] if row[9] == "—" else [x.strip() for x in row[9].split(",")]
        if got_subj != c["subject_artifact_ids"]:
            ok = fail(f"check {i} subject_artifact_ids mismatch")
        if got_supp != c["supporting_artifact_ids"]:
            ok = fail(f"check {i} supporting_artifact_ids mismatch")
        if got_supc != c["supported_claim_ids"]:
            ok = fail(f"check {i} supported_claim_ids mismatch")
        # finding_ids range must equal the model finding rows for this check
        model_findings = [f for f in model["findings"] if f["check_id"] == c["check_id"]]
        if [f["finding_id"] for f in model_findings] != c["finding_ids"]:
            ok = fail(f"check {i} finding_ids != model finding rows")

    # Finding rows
    find_rows = []
    for section, sub, rows in ex.tables:
        if section == "Findings":
            for row in rows:
                if row and row[0].isdigit():
                    find_rows.append(row)
    model_findings = model["findings"]
    if len(find_rows) != len(model_findings):
        ok = fail(f"finding row count {len(find_rows)} != model {len(model_findings)}")
    for i, f in enumerate(model_findings):
        row = find_rows[i] if i < len(find_rows) else None
        if row is None:
            ok = fail(f"missing finding row {i}")
            continue
        # [idx, finding, check, code, severity, subject]
        if row[1] != f["finding_id"]:
            ok = fail(f"finding {i} id {row[1]!r} != {f['finding_id']!r}")
        if row[2] != f["check_id"]:
            ok = fail(f"finding {i} check {row[2]!r} != {f['check_id']!r}")
        if row[3] != f["code"]:
            ok = fail(f"finding {i} code {row[3]!r} != {f['code']!r}")
        if row[4] != f["severity"]:
            ok = fail(f"finding {i} severity {row[4]!r} != {f['severity']!r}")
        # subject rendered as "kind id (target public)"
        want_subj = f"{f['subject']['kind']} {f['subject']['id']} (target {f['subject']['target']})"
        if norm(row[5]) != want_subj:
            ok = fail(f"finding {i} subject {row[5]!r} != {want_subj!r}")

    # Claim rows
    claim_rows = {}
    for section, sub, rows in ex.tables:
        if section == "Claims":
            for row in rows:
                if row and row[0].isdigit():
                    claim_rows[int(row[0])] = row
    model_claims = model["claims"]
    if len(claim_rows) != len(model_claims):
        ok = fail(f"claim row count {len(claim_rows)} != model {len(model_claims)}")
    for i, c in enumerate(model_claims):
        row = claim_rows.get(i)
        if row is None:
            ok = fail(f"missing claim row {i}")
            continue
        # [idx, claim, status, evidence check, statement, limitations]
        if row[1] != c["claim_id"]:
            ok = fail(f"claim {i} id {row[1]!r} != {c['claim_id']!r}")
        if row[2] != c["status"]:
            ok = fail(f"claim {i} status {row[2]!r} != {c['status']!r}")
        if row[3] != c["evidence_check_id"]:
            ok = fail(f"claim {i} evidence_check_id {row[3]!r} != {c['evidence_check_id']!r}")
        if norm(row[4]) != norm(c["statement"]):
            ok = fail(f"claim {i} statement mismatch")
        if row[5] != str(len(c["limitation_ids"])):
            ok = fail(f"claim {i} limitation count {row[5]!r} != {len(c['limitation_ids'])}")

    # Limitation rows (list items: "id — statement source: X")
    lim_items = []
    for section, sub, items in ex.lists:
        if section == "Limitations":
            lim_items = items
    model_lims = model["limitations"]
    if len(lim_items) != len(model_lims):
        ok = fail(f"limitation item count {len(lim_items)} != model {len(model_lims)}")
    for i, l in enumerate(model_lims):
        item = lim_items[i] if i < len(lim_items) else ""
        m = re.match(r"^([\w-]+) — (.*?) source: (\S+)$", item)
        if not m:
            ok = fail(f"limitation {i} item unparsable: {item!r}")
            continue
        lid, statement, source = m.group(1), m.group(2), m.group(3)
        if lid != l["limitation_id"]:
            ok = fail(f"limitation {i} id {lid!r} != {l['limitation_id']!r}")
        if norm(statement) != norm(l["statement"]):
            ok = fail(f"limitation {i} statement mismatch")
        if source != l["source"]:
            ok = fail(f"limitation {i} source {source!r} != {l['source']!r}")

    # Relationships: node ids list and edge groups
    rel_nodes = []
    rel_groups = {}
    rel_heads = []
    for section, sub, items in ex.lists:
        if section != "Relationships":
            continue
        if sub and sub.startswith("Nodes"):
            rel_nodes = items
        elif sub:
            m = re.match(r"^([\w-]+) \((\d+)\)$", sub)
            if m:
                rel_groups[m.group(1)] = items
    rel_heads = [sub for section, sub in ex.headings if section == "Relationships"]
    rel = model["relationships"]
    if rel_nodes != rel["node_ids"]:
        ok = fail(f"relationship node_ids mismatch ({len(rel_nodes)} vs {len(rel['node_ids'])})")
    got_edges = []
    for g in rel["groups"]:
        head = f"{g['edge_kind']} ({len(g['edges'])})"
        if head not in rel_heads:
            ok = fail(f"relationship group heading missing: {head}")
            continue
        edges = rel_groups.get(g["edge_kind"])
        if not g["edges"]:
            # Empty model group: heading-only rendering (a note, no list) is acceptable.
            if edges not in (None, []):
                ok = fail(f"relationship group {g['edge_kind']} renders edges for an empty model group")
            continue
        if edges is None:
            ok = fail(f"relationship group missing: {g['edge_kind']}")
            continue
        want_edges = [f"{e['from']} → {e['to']}" for e in g["edges"]]
        if edges != want_edges:
            ok = fail(f"relationship group {g['edge_kind']} edges mismatch")
        got_edges.extend(edges)
    total_edges = sum(len(g["edges"]) for g in rel["groups"])
    if len(got_edges) != total_edges:
        ok = fail(f"relationship edge count {len(got_edges)} != model {total_edges}")

    return ok


def main():
    failures = []
    for model_name, html_name in PAIRS:
        model = json.load(open(f"{EXAMPLES}/{model_name}"))
        ex = parse_html(f"{EXAMPLES}/{html_name}")
        print(f"checking {model_name} ↔ {html_name}")
        ok = check((model_name, html_name), model, ex)
        if not ok:
            failures.append((model_name, html_name))
    if failures:
        print("\nPARITY FAILED for: " + ", ".join(f"{a} ↔ {b}" for a, b in failures))
        return 1
    print("\nPARITY OK: all displayed facts match the JSON models")
    return 0


if __name__ == "__main__":
    sys.exit(main())
