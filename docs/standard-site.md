# Standard.site / AT Protocol publication

Boris can publish a site into the Atmosphere as Standard.site records: one
`site.standard.publication` and one `site.standard.document` per eligible
page. The static HTML site stays canonical. Atmosphere publication is an
explicit second step with its own plan, verify, login, publish, and smoke
commands.

This is the operator path for first testers. Normative behavior lives in the
contracts; if this page and a contract disagree, the contract wins.

[Target contract](contracts/standard-site.md) ·
[App-password RFC](contracts/atproto-app-password.md) ·
[Sessions](contracts/atproto-sessions.md) ·
[Live smoke](contracts/atproto-live-smoke.md)

## What works today

| Path | Status |
|---|---|
| Offline plan / records / verify | Works. No network, no credentials. |
| App-password login + publish + smoke | Works against bsky.social. This is the first-tester path. |
| Browser OAuth login | Implemented. Requests granular `repo:` scopes (`repo:site.standard.document`, `repo:site.standard.publication`); the live smoke verifies the provider grants them. |

App passwords grant broad account write, not just Standard.site. Use a
**dedicated, non-personal test identity**. Never put the password on argv,
in the profile, in the environment, in git, or in evidence.

A recorded passing smoke against bsky.social lives at
[`contracts/fixtures/standard-site-live-smoke/`](contracts/fixtures/standard-site-live-smoke/README.md).

## First-tester path (bsky.social)

```text
# 0. If you do not have a profile yet: `boris init` writes
#    standard-site.json with an obviously fake DID and URL.
#    Replace both before publish. Omit pds (publish binds to discovery).

# 1. Inspect the Atmosphere projection with no network (no HTML required)
boris standard-site plan    --profile standard-site.json
boris standard-site records --profile standard-site.json

# 2. Build the HTML site and emit verification surfaces (head links +
#    well-known). Layouts need the compiler-owned {{head}} slot; init's
#    theme and the repo theme both have it.
boris --quiet --profile standard-site.json
boris standard-site verify --profile standard-site.json --dist dist

# 3. Log in once with an app password (stdin; echo off on a TTY)
boris standard-site login --app-password --handle YOU.test.bsky.social
# paste the app password, then Enter

# 4. Optional interop proof (writes two namespaced records, reads them back, deletes them)
boris standard-site smoke --handle YOU.test.bsky.social --out smoke.json

# 5. Publish the real site (the DID and PDS come from the profile)
boris standard-site publish --profile standard-site.json

# 6. Forget the local session (does not revoke the app password at the PDS)
boris standard-site logout --did did:plc:…
```

`boris standard-site` with no subcommand prints the family list. Create the
app password under Bluesky **Settings → Privacy and security → App passwords**.
Revoke it when the test is done.

## Profile

A Standard.site profile is a `boris-publication-profile` whose
`publication.target` is `"standard-site"`. `boris init` writes a starter at
`standard-site.json` with a fake DID (`did:plc:` + 24 `a`s) and
`https://replace-me.example.com/`. Replace those before publish. Contract
fixture (not for testers):

[`contracts/fixtures/publication-plan/standard-site/profile.json`](contracts/fixtures/publication-plan/standard-site/profile.json)

Required publication fields:

| Field | Meaning |
|---|---|
| `did` | Publishing account DID |
| `name` | Site name in the publication record |
| `base_url` / `origin` / `base_path` | Location invariant (same as GitHub Pages) |
| `show_in_discover` | `preferences.showInDiscover` hint |
| `include` / `exclude` | Optional entity-id globs |
| `prune` | Delete remote records absent from the plan (publish still needs `--prune`) |
| `pds` | Optional. Omit it and publish uses the PDS login printed. If you set it, paste that shard origin — never `https://bsky.social`. |

`boris init` still writes a GitHub-Pages `boris.json`. The Atmosphere starter
is the extra `standard-site.json` file. Pages become documents only
when they have `published_at` and status `published` or `archived`; drafts
and the usual trunk `index` are excluded unless they carry a date.

## Sessions

Login stores a `0600` document under
`$HOME/.local/share/boris/sessions` (override with `--session-root`).
`sessions` prints `did flavor pds` (flavor is `oauth` or `app-password`).
`logout --did` or `logout --handle` erases the local document; it does not
revoke the app password or the PDS session. Storing an app-password session
for a DID replaces any OAuth session for that DID, and the reverse.

Publish reuses a stored session (OAuth first, then app-password) and only
opens a browser if nothing is stored. Smoke requires a stored session and
does not launch the browser: if none is stored it tells you to
`login --app-password` first. Against bsky.social the browser path requests the granular scopes and
fails closed if any requested token is not granted.

## Honesty board

- **OAuth on bsky.social is the live-smoke verification target.** The
  implementation is real and requests granular `repo:` scopes; a live smoke
  confirms the provider grants them before OAuth is promoted to a tester path.
- **Indexer lag is not a failure.** `smoke --indexer` reports `lagged` /
  `observed` / `failed` and never changes the verdict.
- **`--surface-url` is optional.** Skip it unless the site is already served
  at that origin with the well-known file.
- **Cleanup is namespace-bound.** Smoke deletes only the two rkeys it
  created. An interrupted run leaves those two records; delete the AT-URIs
  named in the last result, then re-run with a new `--namespace`.
- **Secrets never belong in artifacts.** The smoke result records DID, PDS,
  AT-URIs, and CIDs. If a password or JWT appears in output, that is a bug.

## Commands

```text
boris standard-site                 # family usage (exit 2)
boris standard-site plan    --profile PATH [--out PATH]
boris standard-site records --profile PATH [--out PATH]
boris standard-site verify  --profile PATH [--dist DIR] [--out PATH]
boris standard-site login   --app-password (--did DID | --handle HANDLE)
boris standard-site login   --did DID          # browser OAuth (not bsky.social)
boris standard-site sessions [--session-root PATH]
boris standard-site logout  (--did DID | --handle HANDLE)
boris standard-site publish --profile PATH [--plan PATH] [--out PATH] [--prune]
boris standard-site smoke   (--did DID | --handle HANDLE) [--namespace NAME] [--surface-url URL] [--indexer URL] [--out PATH]
```
