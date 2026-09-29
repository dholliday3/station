# Station

The ADE (agentic development environment) for your Mac. The menu bar shows your pull requests' checks as three dots, with notifications and a widget. The windows are where you review: the diff, comments synced with GitHub, and your agents answering them.

## Use it

- **Menu bar:** red, yellow, green dots, lit when any PR is failing, running or passing. Click for the panel; right-click for your agents, recent projects and settings.
- **Review:** `station` in any git repo (Station → Install Command Line Tool… puts it in `~/.local/bin`), a PR's Review button in the panel, or ⌘K in a window.
- **Agents:** `station mcp` is an MCP server. In Claude Code: `claude mcp add station -- station mcp`, or Agent → Connect in a review window. `station --help` lists the plain CLI.
- **Settings:** the Settings window, or `~/.config/station/settings.json` (edits apply as you save).
- **Raycast:** `raycast/` is a Raycast extension on the same snapshot: every PR with its own light and Comments · Review · CI · Merge · Queue at a glance; ↵ for details, ⌘↵ to review in Station. See [raycast/README.md](raycast/README.md).

Diagnostics while it runs: `curl -s http://127.0.0.1:47400/status.json`.

## Build

```bash
brew install xcodegen
scripts/build-core.sh          # the Rust core → Review/Frameworks (needs rustup + aarch64/x86_64-apple-darwin)
xcodegen generate
xcodebuild -scheme Station -configuration Release -derivedDataPath build/rel build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
scripts/sign-adhoc.sh build/rel/Build/Products/Release/Station.app
```

Tests: `cd StoplightCore && swift test`, `cd core && cargo test`.

Release: `scripts/release.sh` (Developer ID, notarized with the `station` notarytool profile) → `dist/Station.zip` for the updater and a DMG.

## Layout

- `Station/`: the app target: menu bar, panel, Settings; `main.swift` hands the launch to the review module.
- `StationWidget/`: the widget.
- `StoplightCore/`: menu bar models, the GitHub provider, notification rules (Swift package).
- `Review/`: review windows, CLI and MCP server (Swift package, module `StationKit`).
- `core/`: the review core in Rust (diff, comments, git), bridged with UniFFI.
- `integrations/`: the Claude Code plugin.
- `design/station/`: the app icon (dark and light) and the script that draws it; `scripts/make-app-icon.swift` turns it into the app's icons.
