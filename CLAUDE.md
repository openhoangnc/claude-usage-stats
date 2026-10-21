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

## In-app updater (`Updater.swift`, 2026-10-14)

The app updates itself from GitHub Releases: daily it reads `releases/latest`, compares the tag
with `CFBundleShortVersionString`, downloads the **`ClaudeUsageStats.zip`** asset, checks it
against the asset's GitHub `digest` (sha256), unpacks it with `ditto`, verifies bundle id, version
and `codesign --verify`, swaps the bundle with `FileManager.replaceItemAt`, and hands over to the
new bundle. It waits for any in-flight `claude` fetch to finish before quitting (same OAuth-race
reason as the fetch single-flighting).

**The handover (2026-10-21).** The old copy starts the swapped bundle as a second instance
(`NSWorkspace.openApplication`, `createsNewApplicationInstance`, args `--replacing <old pid>`) and
quits only once that copy reports `isFinishedLaunching`. The new copy holds its icon until the old
pid exits, and its single-instance guard ignores that pid. Before this, the app quit first and a
shell ran `open` afterwards. The first launch of a swapped bundle goes through
CoreServicesUIAgent and a Gatekeeper scan, which took **30s** on a busy Mac, and for all that time
the menu bar showed nothing ("it quit and didn't restart"). A copy that's already been launched
once starts in ~1s, so testing with a binary that has already run hides the gap: test the
handover with a freshly compiled build.

- **Every release must keep honouring `--replacing`.** A version without it would see the old copy
  through its single-instance guard and quit. The old copy then notices the new one stopped, keeps
  running, and asks the user to reopen the app (`handOverFailed`). Nothing breaks, but the update
  doesn't take until the next launch.
- 1.0.18 and 1.0.19 still use the old quit-then-`open` relaunch, so updating *from* them can
  still show the 30s gap once.

The release pipeline is part of this contract:

- **The asset name `ClaudeUsageStats.zip` and the `v<semver>` tag format are load-bearing** —
  rename either and every installed copy stops updating, silently.
- **`CUSReleaseBuild` (bool, added to Info.plist by `release.yml`) is what turns automatic checks
  on.** Local `./build.sh` builds stamp version 1.0.0 and lack the key, so they never replace
  themselves with the release. "Check for Updates…" still works on them and asks first.
- A release whose zip doesn't contain a `ClaudeUsageStats.app` at the top level, or whose
  Info.plist version differs from the tag, is refused by the updater.
- **Releases must stay universal.** `build.sh` builds the host architecture only, unless
  `UNIVERSAL=1` (set by `release.yml`), which requires both slices and fails the build otherwise.
  The updater doesn't check architectures, so an arm64-only release would install itself on
  Intel Macs and then fail to launch. Command Line Tools can't link the x86_64 slice for macOS 11
  (their Swift compatibility libraries are arm64-only), so `UNIVERSAL=1` needs Xcode locally.

## Detecting install and sign-in (2026-10-21)

Neither "is `claude` installed" nor "is it signed in" is held for long:

- `PathResolver` caches a located `claude` for 10 minutes, then asks the interactive shell again,
  so a reinstall elsewhere (npm → native installer, new nvm version) is picked up. A failed lookup
  is never cached.
- While the last fetch failed with `.claudeCliNotInstalled` or `.noCredentials`, `AppDelegate`
  runs `UsageClient.checkSetup` every 60s (PATH lookup + `claude auth status --json`) and fetches
  at once when the cause is gone, instead of waiting out the 15–30 min failure back-off.
- When a fetch reads no usage bars, `auth status` decides the error: `loggedIn: false` (or a CLI
  too old to answer) → `.noCredentials`; `loggedIn: true` → `.sessionExpired`. That one isn't
  watched, because a fresh `/login` doesn't change what `auth status` says.

⚠️ **Never call `claude auth status` on a healthy poll.** It can refresh the OAuth token (CLI
2.1.289 and 2.1.301 both fixed sign-outs it caused), which is the race the fetch single-flighting
exists to avoid. It runs only after a fetch has failed, or while there's no token to refresh.
CLIs older than 2.1.41 have no `auth` command; they reject `--json` as an unknown option rather
than taking `auth status` as a prompt, and the check reads that as "can't say".
