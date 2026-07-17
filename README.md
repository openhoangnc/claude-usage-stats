**English** · [日本語](README.ja.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

# Claude Usage Stats

A tiny macOS menu-bar app that shows your Claude Code usage at a glance — the
same numbers as the `claude /usage` command, always visible.

- **Top line** — current **session** usage %
- **Bottom line** — current **week (all models)** usage %
- **Click** — a detail panel with all three windows (session, week all-models,
  and your active model's weekly limit), each with a progress bar and a reset
  line showing the local time and how long until reset.

Each progress bar carries a **pace marker** — a small tick at the point the
window's clock has reached. Fill behind the tick means you're spending slower
than the window elapses; fill past it means you're on track to run out early.
(A window that hasn't been used yet has no reset time, so it shows neither a
marker nor a reset line.)

![Claude Usage Stats screenshot](screenshot.png)

The two percentages are **auto-colored by usage range**, using colors verified
to meet **WCAG AAA** (≥7:1 contrast) against both light and dark menu bars:

| Range | < 50 | 50–69 | 70–84 | 85–94 | ≥ 95 |
|-------|------|-------|-------|-------|------|
| Tier  | green | lime | gold | orange | red |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/install.sh | bash
```

Downloads the latest prebuilt release, installs it to `/Applications`, and
launches it — no Xcode needed. (If no release is available yet, it falls back to
building from source, which needs the Xcode command-line tools.) Enable **Launch
at Login** from the menu (click the indicator → Launch at Login).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/uninstall.sh | bash
```

## How it works

The app fetches your usage limits from the local `claude` CLI tool, cheapest
source first:

1. Locates `claude` on your interactive login-shell `PATH` (`/bin/zsh -ilc`, so
   nvm/fnm/volta and custom prefixes resolve).
2. Runs `claude -p /usage` (headless). If that output already contains the limit
   bars, it's parsed and rendered — done.
3. Otherwise (current CLI versions dropped the bars from headless output) it
   falls back to driving the interactive `/usage` view under a pseudo-terminal,
   scrapes the rendered bars, and quits before any conversation turn — so
   nothing is saved to disk and your usage stats aren't affected.

Fetches are single-flighted (never two `claude` processes at once) and a
throttled usage endpoint is treated as a transient back-off, not an error.

No Keychain access is required. The app doesn't touch your credentials.

**First launch:** The app works out of the box with no extra permissions, as long as `claude` is installed on your machine and you are logged in.

**Command Not Found:** If the `claude` command is not available, the app displays a warning panel suggesting to install it.

## Build & install from source

Prefer to build it yourself? Clone the repo and run the installer. From a local
checkout, `install.sh` compiles your current sources into a universal binary,
installs the app to `/Applications`, and launches it — nothing is downloaded, so
you run exactly the code in front of you.

```bash
git clone https://github.com/openhoangnc/claude-usage-stats.git
cd claude-usage-stats
./install.sh
```

Once it's up, enable **Launch at Login** from the menu (click the indicator →
Launch at Login).

## Requirements

- macOS 11+
- Claude CLI (`claude`) installed on this machine and logged in
- Xcode command-line tools (`swiftc`) to build

## Debugging

```bash
# Print what the menu bar / panel would show, without the GUI.
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --selftest

# Re-render the README screenshot from the real views.
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --screenshot screenshot.png
```

Refresh runs every 5 minutes and whenever you open the menu, backing off on
repeated errors. The panel footer shows when the data was last updated.
