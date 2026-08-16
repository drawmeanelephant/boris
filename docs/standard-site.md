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
| Browser OAuth login | Implemented, but **bsky.social does not grant** `site.standard.authFull`. Authorization succeeds in the browser and Boris fails closed with exit 6. Do not start here. |

App passwords grant broad account write, not just Standard.site. Use a
**dedicated, non-personal test identity**. Never put the password on argv,
in the profile, in the environment, in git, or in evidence.

A recorded passing smoke against bsky.social lives at
[`contracts/fixtures/standard-site-live-smoke/`](contracts/fixtures/standard-site-live-smoke/README.md).

## First-tester path (bsky.social)

```text
# 1. Inspect the Atmosphere projection with no network (no HTML required)
boris standard-site plan    --profile profiles/standard-site.json
boris standard-site records --profile profiles/standard-site.json

# 2. Build the HTML site. Verification surfaces (head links + well-known)
#    are not yet wired on the production `boris` HTML path — `verify`
#    against this dist will fail closed until that emit lands. Plan and
#    publish do not wait on it.
boris --quiet

# 3. Log in once with an app password (stdin; echo off on a TTY)
boris standard-site login --app-password --handle YOU.test.bsky.social
# paste the app password, then Enter

# 4. Optional interop proof (writes two namespaced records, reads them back, deletes them)
boris standard-site smoke --handle YOU.test.bsky.social --out smoke.json

# 5. Publish the real site
boris standard-site publish --profile profiles/standard-site.json --did did:plc:…

# 6. Forget the local session (does not revoke the app password at the PDS)
boris standard-site logout --did did:plc:…
```

`boris standard-site` with no subcommand prints the family list. Create the
app password under Bluesky **Settings → Privacy and security → App passwords**.
Revoke it when the test is done.

## Profile

A Standard.site profile is a `boris-publication-profile` whose
`publication.target` is `"standard-site"`. Fixture:

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

`boris init` writes a GitHub-Pages-oriented starter profile, not a
Standard.site one. Copy the fixture and replace the example DID and URLs.
Pages become documents only when they have `published_at` and status
`published` or `archived`; drafts and the usual trunk `index` are excluded
unless they carry a date.

## Sessions

Login stores a `0600` document under
`$HOME/.local/share/boris/sessions` (override with `--session-root`).
`sessions` prints DIDs only. `logout --did` erases the local document; it
does not revoke the app password or the PDS session. Storing an app-password
session for a DID replaces any OAuth session for that DID, and the reverse.

Publish and smoke reuse a stored session (OAuth first, then app-password)
and only open a browser if nothing is stored. Against bsky.social that
browser path will fail closed on the missing scope — log in with
`--app-password` first.

## Honesty board

- **OAuth on bsky.social is not a tester path.** The implementation is real;
  the provider does not grant the Standard.site permission set.
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
boris standard-site logout  --did DID
boris standard-site publish --profile PATH [--plan PATH] [--out PATH] [--prune]
boris standard-site smoke   (--did DID | --handle HANDLE) [--namespace NAME] [--out PATH]
```
