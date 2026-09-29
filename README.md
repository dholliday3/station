# Station

The ADE (agentic development environment) for your Mac: Stoplight's menu bar (your PRs' checks as three dots, notifications, a widget) and Onramp's review windows (the diff, comments synced with GitHub, your agents) in one app.

Work in progress: stage 1 of the merge. Both apps' code builds and runs as one app, unchanged; the `station` names, the Transfer icon and one Settings window come next.

## Build

```bash
brew install xcodegen
scripts/build-core.sh          # Onramp's Rust core → Review/Frameworks (needs rustup + the two Apple targets)
xcodegen generate
open Station.xcodeproj         # or build from the command line:
xcodebuild -scheme Station -configuration Release -derivedDataPath build/rel build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
scripts/sign-adhoc.sh build/rel/Build/Products/Release/Station.app
```

Tests: `cd StoplightCore && swift test` (menu bar logic), `cd core && cargo test` (review core).

## Layout

- `Station/`: the app. Stoplight's menu bar, panel and Settings; `main.swift` hands the launch to Onramp.
- `StationWidget/`: the widget.
- `StoplightCore/`: menu bar models, GitHub provider, rules (Swift package).
- `Review/`: Onramp's review windows, CLI and MCP server (Swift package, module `onramp`).
- `core/`: Onramp's Rust core (diff, comments, git), bridged with UniFFI.
- `integrations/`: the Claude Code plugin.
- `design/station/`: the app icon (dark and light) and the script that draws it.
