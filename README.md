# Spaceworthy

A small native macOS app that shows where your disk space goes and tells you
what to do about it. It focuses on the folders that are famously safe to
clean (caches, temp, logs, build artifacts, package manager stores, Claude
Code worktrees) and keeps your real content read-only so you cannot remove
something you need by accident.

<p align="center"><img src="Resources/icon-1024.png" width="160" alt="Spaceworthy icon"></p>

## What it does

**Overview**

- Disk bar with used, purgeable and free space, and a headline of how much is
  safely reclaimable.
- Ranked recommendations with concrete next actions: a downloaded but
  uninstalled macOS update, a cache worth clearing, a Docker image to prune,
  Time Machine local snapshots, old Downloads to review.
- **Safe to clean**: user caches, temp folders, logs, Homebrew, npm, Bun, pip,
  Gradle, Go, Xcode DerivedData, simulators, VS Code, Chrome, Slack, Spotify,
  Mail downloads, iOS backups. Each row shows size, a proportional bar and the
  largest children when expanded.
- **Claude Code**: every git worktree Claude created under your projects,
  grouped per repository, with branch, age, size and a verdict (safe to
  remove, probably safe, or has unsaved work), plus job data, transcripts and
  the desktop app's own caches.
- **Your content**: Documents, Desktop, Downloads, Pictures, Movies, Music,
  iCloud Drive, Mail, Messages, Applications and projects. Read-only; the only
  button is Reveal in Finder.
- **System**: unified logs, system caches, staged macOS updates, local
  snapshots and the current `softwareupdate` status.

**Explore**

A size-sorted drill-down of any folder, biggest first, starting at your home
folder or the disk root. Every row carries a label: Safe to clean, Your
content, System / app data, or Unknown. Only Safe to clean rows get a Clean
button.

## Safety model

- **Clean** moves items to the Trash. Nothing is deleted permanently until you
  empty the Trash yourself; only the explicit **Empty Trash** action does that.
- **Claude worktrees** are removed with `git worktree remove` and
  `git worktree prune` after a confirmation sheet. Worktrees with uncommitted
  or unpushed changes are excluded unless you tick them individually.
  Deleting the worktree's branch is a separate option that is off by default.
- Content and system rows never get a destructive button.

## Build and run

Requires macOS 14 or later and the Command Line Tools. Xcode is not needed.

```bash
xcode-select --install   # once, if you don't have the Command Line Tools
./build.sh run
```

`build.sh` compiles the Swift package in release mode, assembles
`build/Spaceworthy.app`, generates the icon from `Tools/make-icon.swift` if it
is missing, and signs the bundle with a stable ad-hoc signature so macOS does
not re-ask for folder permissions after every rebuild.

### Permissions

On first launch macOS asks for access to Desktop, Documents and Downloads.
Sizes for Mail, Messages, Trash and other apps' containers need Full Disk
Access: System Settings > Privacy & Security > Full Disk Access > add
Spaceworthy. Rows the app cannot read show "no access".

## Project layout

| Path | Purpose |
|---|---|
| `Sources/Spaceworthy/Locations.swift` | Catalog of known locations, categories and clean hints |
| `Sources/Spaceworthy/Scanner.swift` | Concurrent directory sizing with time caps |
| `Sources/Spaceworthy/Recommendations.swift` | Rules that turn scan results into ranked actions |
| `Sources/Spaceworthy/Explore.swift` | Lazy size-sorted tree for the Explore tab |
| `Sources/Spaceworthy/Views/` | SwiftUI views |
| `Tools/make-icon.swift` | Draws the app icon with CoreGraphics |
| `Resources/` | Info.plist, icon master and generated `.icns` |
| `build.sh` | Build, bundle, sign |

### Headless snapshot

For screenshots without a display session, the app can render itself to a
PNG and quit:

```bash
SPACEWORTHY_SNAPSHOT=/tmp/overview.png SPACEWORTHY_QUIT=1 build/Spaceworthy.app/Contents/MacOS/Spaceworthy
```

Related variables: `SPACEWORTHY_TAB=explore` to capture the Explore tab,
`SPACEWORTHY_EXPAND=1` (or a comma-separated list of row ids) to pre-expand
Overview rows, `SPACEWORTHY_EXPLORE_EXPAND=path,path` to open Explore folders,
`SPACEWORTHY_SNAPSHOT_TIMEOUT` in seconds. Native buttons render as
placeholders in this mode.

## Adding a location

Add one `add(...)` line in `Locations.swift` with an id, title, path,
category, action kind (`.trash`, `.revealOnly`, `.command`, `.systemInfo`),
SF Symbol, description and a one-sentence hint about what deleting it does.
Locations whose path does not exist are hidden automatically.

## License

MIT, see [LICENSE](LICENSE).
