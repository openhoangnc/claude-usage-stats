# CLAUDE.md — Claude Usage Stats

A macOS menu-bar app (Swift) showing Claude Code usage — session %, weekly %, and a detail
panel per limit window. Repo: `openhoangnc/claude-usage-stats`. Default branch `main`.

> **Scope note.** This file currently documents **the release pipeline only** — it was created on
> 2026-08-29 when that pipeline changed, and nobody has audited the rest of the codebase into it
> yet. Treat the absence of a section as "not written down", not as "nothing to know". Add sections
> as you learn the repo; don't assume this is a complete constitution.

## Releasing — a push to `main` no longer builds or releases (2026-08-29)

`.github/workflows/release.yml` used to run on **every** push to `main`. It auto-bumps the latest
`v*` tag, builds the app, **pushes the new git tag, and publishes a public GitHub Release with the
zip attached** — so every push to `main` cut a release, on a `macos-latest` runner (billed at 10×
the Linux rate on private repos).

It is now gated on a commit marker:

| Trigger | Runs when |
|---|---|
| push to `main` | a commit message in the push contains **`[deploy-prod]`** |
| push to any other branch | a commit message contains **`[deploy]`** |
| push of a `v*` **tag** | **always** — ungated |
| `workflow_dispatch` | **always** — ungated (takes the `bump_type` input) |

```bash
git commit -m "fix: whatever it was [deploy-prod]"   # cut a release
gh workflow run release.yml --ref main               # or do it by hand
git push origin v1.4.0                               # or tag it explicitly
```

⚠️ **Tag pushes are ungated on purpose, and must stay that way.** A tag push carries an **empty
`commits` payload**, so there is no message to read a marker out of — gating `refs/tags/v*` would
make `git push --tags` silently do nothing. `startsWith(github.ref, 'refs/tags/')` short-circuits
ahead of the marker test for exactly this reason.

⚠️ **A skipped run is GREEN AND EMPTY.** An unmarked push still shows a run in the Actions tab; the
job is skipped by its `if:`, allocates no runner, and does not read as a skip until you open it.
**Never take a green Actions tab as "it released"** — check the Releases page. If a release "did
nothing", look at the job's `if:` before debugging the version calculation or the build.

The workflow's own tag push uses `secrets.GITHUB_TOKEN`, and GitHub does not re-trigger workflows
from that token — so the tag it creates does *not* start a second run. That was true before this
change too; it is noted here only so nobody "fixes" a recursion that does not exist.

**Why two different markers** rather than `[deploy]` everywhere: the sibling repos on this account
fast-forward `main` from `dev` with byte-identical commits, so a shared token re-fires production on
every promotion. The condition is kept identical across all eleven repos in `~/priv` so there is one
rule to remember. Full reasoning: `~/priv/shopify-order-printer/docs/implementation-log.md` D-208
and D-210.
