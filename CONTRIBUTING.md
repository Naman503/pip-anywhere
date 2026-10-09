# Contributing

Thanks for your interest! Issues and pull requests are welcome.

## Setup

```bash
cd app && swift build && swift test            # macOS app
cd extension && npm install && npm run build   # extension → load extension/dist unpacked
```

## Before opening a pull request

- `swift test` passes in `app/`.
- `npm run typecheck && npm run build` passes in `extension/`.
- **Changes to how the window behaves** (levels, Spaces, full screen): run `spikes/FullscreenProbe.swift` and `spikes/SpaceSwitchProbe.swift` against a copy started with `--test-pattern`.
- **Changes to capture or streaming:** run `node tests/e2e.mjs pipeline`, and if possible `node tests/e2e.mjs youtube`.
- **Changes to the wire protocol:** update `docs/protocol.md` and both sides (`app/Sources/PiPCore/Protocol.swift`, `extension/src/protocol.ts`). Keep new fields optional so older builds still decode.

## Conventions

- **Pure logic belongs in `PiPCore`, with a unit test.** That covers geometry and protocol parsing. The executable target holds AppKit and SwiftUI glue only.
- **Load private macOS APIs at runtime with `dlsym`, and make them degrade gracefully.** See `StickySpace.swift`.
- **The extension has no runtime dependencies.** Keep it that way.
- **Comments explain *why*, not *what*.**

## Reporting bugs

Please include:
- the macOS version;
- the browser and its version;
- the site;
- the menu bar → **Streaming** line, which shows resolution and fps.
