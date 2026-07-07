

# Claude Usage Stats

A tiny macOS menu-bar app that shows your Claude Code usage at a glance — the
same numbers as the `claude /usage` command, always visible.

- **Top line** — current **session** usage %
- **Bottom line** — current **week (all models)** usage %
- **Click** — a detail panel with all three windows (session, week all-models,
  and your active model's weekly limit), each with a progress bar and a reset
  line showing the local time and how long until reset.

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

The app fetches your usage limits directly from the local `claude` CLI tool:

1. Runs the command `claude -p "/usage" < /dev/null` in a login shell (`/bin/zsh -lc`).
2. Parses the plain-text CLI output to extract percentages, limit names, and reset times.
3. Renders the extracted info and updates automatically.

No Keychain access is required. The app doesn't touch your credentials.

**First launch:** The app works out of the box with no extra permissions, as long as `claude` is installed on your machine and you are logged in.

**Command Not Found:** If the `claude` command is not available, the app displays a warning panel suggesting to install it.

## Build from source

```bash
./make_icon.sh    # generates AppIcon.icns + icon.png
./build.sh        # compiles ClaudeUsageStats.app
open ClaudeUsageStats.app
```

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

Refresh runs every 120s and whenever you open the menu. The panel footer shows
when the data was last updated.
