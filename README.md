# Agent HUD

Mission control for your Claude Code sessions. An always-on-top widget that expands into a full
dashboard: what every agent is doing right now, the shape of the turn it is in, what it is burning,
and which ones are stuck in a loop.

![The Agent HUD dashboard](docs/images/dashboard.png)

It reads `~/.claude/sessions/*.json`, `~/.claude/projects/**/*.jsonl` and the plan usage Claude Code
keeps in `~/.claude.json`, and nothing else. **Strictly
local, read-only, no network, no API keys** — the app makes no outbound connections of any kind and
never writes into `~/.claude`. Its only output is a cache of its own in Application Support. The one
thing it does outside itself is bring a session's terminal to the front when you ask it to.

What sessions said is only held in memory, and only while the session is running. None of it is
written to disk, and it's dropped when the session ends. [What it keeps](#what-it-keeps) lists
everything the app stores and for how long.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 16+ (for the Swift 6 toolchain) — `xcode-select --install` is not enough, the full Xcode is needed
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- Claude Code, having run at least once (the HUD has nothing to show otherwise)

## Install

```bash
git clone https://github.com/easavin/agent-hud.git
cd agent-hud
xcodegen generate
xcodebuild -project AgentHUD.xcodeproj -scheme AgentHUD -derivedDataPath build build
open build/Build/Products/Debug/AgentHUD.app
```

That is the whole install. It builds ad-hoc signed, so no Apple Developer account is involved.

To keep it around, drag `build/Build/Products/Debug/AgentHUD.app` into `/Applications` — but move it
rather than copying. Two bundles with the same identifier both register with LaunchServices, and then
a Dock click can launch the stale one and you get two widgets on screen.

### First launch

Two things will ask for your permission, both expected:

- **"AgentHUD" is from an unidentified developer.** Ad-hoc signing, not notarization. Right-click the
  app → **Open** → **Open**, once.
- **Access to Documents / Desktop / Downloads.** The Files tab draws each session's working directory,
  so macOS gates the folder your repos live in. Denying it only blanks that one tab.

Ad-hoc signatures change on every build, so macOS treats each rebuild as a new app and re-asks for the
folder access. If you rebuild often, sign with your own Apple Development certificate instead: create
`Signing.local.xcconfig` (gitignored) next to `Signing.xcconfig` with

```
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = YOURTEAMID
```

and the grant sticks across rebuilds. Your team ID is in the Membership tab of your Apple Developer
account, or from `security find-identity -v -p codesigning`.

### Try it without any sessions

```bash
./build/Build/Products/Debug/AgentHUD.app/Contents/MacOS/AgentHUD --demo busy
```

`--demo` takes `busy`, `idle` or `alert` and shows a sample fleet instead of your real sessions —
useful for seeing the whole interface at once. (The flags need the executable inside the bundle;
`open` does not forward arguments.)

The same binary takes `--snapshot <dir> [--demo …]`, which renders every frame to PNG and quits, with
no screen-recording permission needed. **Without `--demo` those PNGs contain your real prompts, file
paths and repo names**, so `snapshots/` and `shots/` are gitignored; keep it that way.

## Using it

![The compact widget](docs/images/widget.png)

The app lives in three sizes. The **widget** (320×320) floats above everything; the **mini** widget
(160×160) is the same thing shrunk to a pulse and a token rate; the **dashboard** (1280×800, freely
resizable) is the full view. It is a regular Dock app, and the Dock icon itself is live — a block-bar
history plus current tok/min.

| | |
|---|---|
| Open the dashboard | Click the Dock icon, the widget's green light, or double-click the widget |
| Switch size | **⌘1** dashboard · **⌘2** widget · **⌘3** mini, or the widget's yellow light |
| Hide the widget | Its red light. The menu bar icon brings it back |
| Quit | **⌘Q**. Closing the dashboard alone leaves the widget running |

Inside the dashboard: `↑ ↓` select a session · `t` brings its terminal to the front · `f` `b` `l` `s`
`r` switch the hero tab · `p` blurs the thought stream for screen-sharing · `1` `2` `7` set the
token-burn range · `/` or **⌘F** search. None of these fire while you're typing in the search box. The
terminal icon on a session card, or right-click → Show in Terminal, does the same as `t`. Clicking a
node in the flow graph opens its detail popover. The session list scrolls.

Every border between panes is draggable — the rail, the stats column, the flow/lanes split, the
thought stream — and the sizes persist. The window resizes freely with no locked aspect ratio:
nothing scales, the layout reflows.

### Search

The search box in the header finds live sessions by folder, name, title or branch, and by anything you
or Claude said in them. `/` or **⌘F** puts the cursor in it.

- Every word you type has to match. The last one also matches as the start of a word, since you're
  probably still typing it. The others match whole words and their other forms, so "signing key"
  finds "signed" but not "significant".
- Sessions whose folder, name, title or branch match come first, most recently active first. After
  them come sessions where only something said matched, best match first.
- Each session appears once, with its best snippet and how many of its messages match. The right of
  the panel shows the messages either side of that snippet.
- `↑ ↓` move through the results, `↩` or a click opens the session at its Recap tab, and `esc` clears
  the search and gives the keyboard back to the dashboard.
- Blur thoughts blurs the snippets and the preview. Folder and session names stay readable.

Only your prompts and Claude's replies go in. Thinking, tool calls, tool output, subagent transcripts
and text Claude Code adds itself (skill instructions, compaction summaries) are left out. Ended
sessions can't be searched: see [What it keeps](#what-it-keeps).

It uses SQLite's full-text search (FTS5), which ships with macOS, so there's nothing extra to install.
Indexing happens as transcripts are read and searching runs off the main thread, so neither holds up
the window. To see what it would find for your live sessions, run:

```bash
swift run hudctl search <words>
```

### What the tabs show

- **Flow** — the current turn as a graph: prompt, thinking blocks, tool calls, results, subagents
  (dashed teal, carrying the agent type and the model that actually ran). A retry loop compresses to
  the latest iteration with a red `×N` on the edge; a turn longer than the canvas drops middle
  columns and says so.
- **Brain** — the context window by layer: what is filling it and how close to full.
- **Loops** — a radar of repeated failures, with the iteration that keeps coming back.
- **Files** — the session's working directory as a graph rather than a list. Folders branch left to
  right on curved links and every file lines up in one column: its dot is sized by edit count, its
  link and diff bar by lines changed, and a dashed ring marks a change made by a shell command
  rather than an Edit call.
- **Recap** — what the session is about, for telling apart sessions that share a terminal name or a
  folder: Claude Code's own title for it (or the name you gave it with `/rename`), the prompt it
  started with, your latest prompt and its last reply, plus where it runs, what it has edited and any
  PRs it opened. Skill instructions, messages from other sessions and compaction summaries are not
  counted as prompts.

![The Files tab](docs/images/files.png)

### Things worth knowing

- At launch every live session's transcript is read from the start, which takes a few seconds when
  they are long. Sessions appear as they are read, newest first, and the list, header and widget
  say how many are left ("Reading 7 of 23 sessions…") rather than claiming there are none.
- Finished sessions stay in the list, greyed out, and can't be opened. [What it keeps](#what-it-keeps)
  explains why. The widget, Dock tile and counters only ever count live sessions.
- **tok/min** is *output* tokens over the trailing minute; it reads zero for idle agents.
- **Plan usage**, in the header and at the top of the stats column, is Claude Code's own figure for
  your limits: the 5-hour session, the weekly limit and any per-model weekly limit that applies, each
  with how much is used, how much is left and when it resets. The weekly bar is split by product
  (Claude Code, Cowork, Chats). The header shows whichever limit you'll reach first. The figures come
  from the copy Claude Code keeps in `~/.claude.json`, which it refreshes now and then rather than
  constantly, so the card says when they were fetched and the header does too once they're over 15
  minutes old. There's no estimated cost any more: what a session would cost at API list prices says
  nothing about how much of your plan is left.
- **Show in Terminal** finds the session's terminal from its process tree. In Terminal.app and iTerm2
  it selects the exact tab; inside tmux it also selects the pane and switches the most recently used
  client to that session (a detached tmux session has no window to show, so you get a beep). Any
  other terminal, or an editor's built-in one, is just brought forward. The first time, macOS asks
  whether Agent HUD may control Terminal or iTerm2; without that it still brings the app forward but
  can't pick the tab.
- There is no **Interrupt** button, though the design handoff drew one: the app is read-only and has
  no business killing someone's session.

## What it keeps

The app only keeps data it needs to draw the dashboard, and drops it when it stops needing it.

| What | Where | How long |
|---|---|---|
| Live sessions: what they're doing, recent prompts and replies, steps, plan and files touched | Memory | While the session runs |
| Search index: the prompts and replies of live sessions | Memory only, never on disk | While the session runs. One that ends is dropped on the next poll, within about a second |
| Ended sessions: folder, branch, model, token and context numbers, activity lanes | Memory | 3 days. The list shows the newest 8 |
| History index: tokens per model per day, tool and error counts, folder names with their token totals, how far each transcript has been read | `~/Library/Application Support/AgentHUD/index.json` | Daily totals for 100 days, 2-minute token buckets for 8 days, read positions until the transcript is deleted. No prompt or reply text |
| Window positions, which windows were open, pane sizes, widget size, Blur thoughts | `UserDefaults` | Until you change them |
| Plan usage: each limit's percentage and reset time, and the week's split by product | Memory | Replaced whenever Claude Code updates its copy |
| Search queries | Nowhere | Not kept |
| `--snapshot` PNGs | The folder you give it | Until you delete them. Without `--demo` they show real prompts |

When a session ends, the app drops its prompts, replies, titles, steps, plan, file paths and errors from
memory, not just from the screen. Its card keeps only the numbers in the third row above, so there is
nothing behind it to open. Its search rows are deleted with SQLite's `secure_delete` on, which
overwrites the text rather than leaving it in free memory pages, and the full-text index is merged so
the words go too. Resuming the session with `claude --resume` brings it back, read again from the start.

From `~/.claude.json` the app keeps only `cachedUsageUtilization`, Claude Code's copy of your plan
usage. It reads the file again only when Claude Code has rewritten it, and nothing else in it (account
details, per-project settings) is kept.

Quitting the app clears everything held in memory. Deleting `index.json` clears the history and forces
a re-scan, which takes about 7 seconds for 330 MB of transcripts.

## Design

The interface is *light product-analytics*: a warm off-white canvas, flat white cards with 1px
warm-grey borders, dark-ink buttons and segmented controls, and saturated-but-muted semantic colors
that clear 4.5:1 on white. Everything is vector — node graphs, donut, radar, stacked areas,
sparklines, heatmap. No gradients, no glow, no shadows except the flow popover's hard 2px offset.

Motion is calm and scoped. The flow graph splits into a static layer (edges, nodes, labels, redrawn
only when the turn changes) and a motion layer that runs at 15 fps only while a tool is in flight.
Lanes redraw once a second. Reduce Motion drops both to their resting frame and leaves the data
updating.

Type is **IBM Plex Sans** when installed and the system face otherwise; code and the thought stream
use **JetBrains Mono**, falling back to SF Mono. Neither font is bundled.

## Repository layout

- **`Packages/HUDCore`** — all the logic, no UI, unit-tested with `swift test`: transcript parsing,
  incremental tailing, per-session state (activity, turn steps, loops, plan progress, context
  "brain"), the history index, the search index (`SearchIndex.swift`), plan usage (`PlanUsage.swift`) and finding
  the terminal a session runs in. `swift run hudctl [stats | search <words>]` prints what the HUD
  sees, which is the fastest way to check ingest without launching the app.
- **`AgentHUD/Views/Light/`** — the entire interface.
  - `Theme.swift` — design tokens, type, radii. `Components.swift` — `Card`, `CardHeader`,
    `Segmented`, `ToolbarButton`, `ModelBadge`, `BarTrack`, `Sparkline`, `ProgressRing`.
  - `DashboardView.swift` — the frame, header, metrics strip, body grid, thought stream, keyboard.
  - `FlowLayout.swift` turns a turn's steps into positioned nodes and edges (pure geometry, no
    SwiftUI, independently testable); `FlowGraphView.swift` draws them.
  - `HeroTabs.swift` — brain graph and loop radar. `FileTreeLayout.swift` + `FilesView.swift` — the
    working directory graph. `RecapView.swift` — the recap tab.
  - `SearchField.swift` and `SearchPanel.swift`: the header's search box and its results.
  - `AgentCard.swift`, `LanesPanel.swift`, `StatsRail.swift`, `WidgetView.swift`, `DockTileView.swift`.
- **`design_handoff_agent_hud_light/`** — the design handoff this UI is built from (frame `3b`).
  `design_handoff_agent_hud_terminal/` (`3a`) and `design_handoff_agent_hud/` (the original neon
  direction, still the behavior reference for `1e` / `2a`) are the earlier explorations.
  `docs/design-prompt.md` is the prompt behind the first.

Anything with a shape of its own is a `Canvas`: the flow graph, brain graph, loop radar, lanes,
stacked-area burn chart, donut, heatmap. Cards, controls and text stay ordinary SwiftUI so they
hit-test and truncate properly. The dashboard window is **not** movable by its background: AppKit claims a mouse-down on any transparent area to
move the window before SwiftUI sees it, and the splitters are transparent, so every drag moved the window instead
of resizing. The header is the drag area instead (`WindowDragArea`).

Dragging updates `@State` and writes to `UserDefaults` once, on release: `@AppStorage` pushes every frame of a
drag through the defaults system and the whole dashboard re-renders with it. The stats rail picks its one- or
two-column layout from the width it is handed rather than with `ViewThatFits`, which re-measures mid-drag and
flickers, and the splitter holds its cursor for the length of a drag instead of swapping it as the handle slides
out from under the pointer.

Panes window their content rather than scrolling it — `ImageRenderer`
cannot draw a `ScrollView`, so `--snapshot` would come back blank for any pane that used one. The
session rail is the exception: live it is a `ScrollView`, and under `--snapshot` it draws the cards
that fit and a "+N more" line.

## Contributing

`swift test` in `Packages/HUDCore` covers the ingest and derivation layers; anything you add there
should come with a test. UI changes are checked against `--snapshot`, which renders every frame
including `dashboard-narrow-*` (1040×640) and `dashboard-wide-*` (1680×1000) so both ends of the
resize range stay verifiable.

Three invariants, please: the app never writes into `~/.claude`, it never opens a network
connection, and what a session said is never stored on disk or kept after the session ends (the
`--snapshot` PNGs you ask for aside).

## License

MIT — see [LICENSE](LICENSE).
