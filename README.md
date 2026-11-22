# InvestAI

> A locally runnable reconstruction of the Claude Code source snapshot.

InvestAI packages the exposed Claude Code `src/` snapshot together with the
build scaffolding that the published artifact did not include, so the CLI can
be started with Bun for architecture study, experimentation, and defensive
security research.

The repository was previously named `claude-code`; the rename does not change
the provenance of the source snapshot described at the bottom of this file.

---

## Status

| Check | Result |
|---|---|
| `--version` | `2.1.330 (Claude Code)` |
| `--help` | Full option and subcommand list |
| `mcp list` | Works |
| `-p` streaming query | Works against a local Messages API mock |
| Tool loop | Bash `tool_use` executes and returns its result |
| Interactive REPL | Not yet verified on a real TTY |

The end-to-end checks use [scripts/mock-anthropic.ts](scripts/mock-anthropic.ts),
so they do not call an external API.

---

## Quick start

```bash
bun install

bun run start -- --version      # fast path
bun run start -- --help
bun run start -- -p "你好"       # non-interactive
bun run start                   # interactive REPL
```

`start` runs:

```bash
bun run --preload ./compat/preload.ts ./src/entrypoints/cli.tsx
```

### Model configuration

Model provider settings live in the project-local `.env`, which Bun loads
automatically from the repository root. Copy the template once and fill in
your credentials:

```bash
cp .env.example .env
```

Keys are namespaced with `INVEST_` (e.g. `INVEST_ANTHROPIC_BASE_URL`) so they
cannot collide with variables exported by a shell or another Claude Code
install. [compat/preload.ts](compat/preload.ts) translates them to the
upstream `ANTHROPIC_*` / `CLAUDE_CODE_*` names before the CLI starts, and does
so unconditionally — the project `.env` therefore wins over stale
`ANTHROPIC_*` values inherited from a parent process.

`.env` is gitignored; only `.env.example` is committed, so credentials are
never stored in this repository. The template sets
`INVEST_CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1`, which makes the CLI ignore
the provider-routing `env` block in `~/.claude/settings.json` — this project
is self-contained and does not depend on your global Claude Code
configuration. Remove that line if you want the global settings to apply
again.

Notes:

- Bun does not override `INVEST_*` variables already exported in your shell;
  export one to override a single value for a run.
- `scripts/test.ps1` keeps its offline checks isolated by passing
  `--setting-sources=` and overriding the endpoint with a local mock.

See [RECONSTRUCTION.md](RECONSTRUCTION.md) for the full reconstruction notes
and known gaps.

---

## Repository layout

```text
src/                 Claude Code source snapshot (~1,900 files, 512k+ lines)
compat/              Runtime replacements for build-time and private modules
scripts/             Codemods, stub generator, offline API mock
RECONSTRUCTION.md    What was added, how it works, what is still stubbed
package.json         Dependencies and start scripts
tsconfig.json        Path aliases and JSX configuration
python/              Deprecated ts2py output; unused, not part of the runtime
```

### `src/` at a glance

```text
src/
├── main.tsx           CLI parser and React/Ink renderer bootstrap
├── commands.ts        Slash command registry
├── tools.ts           Agent tool registry
├── QueryEngine.ts     LLM query engine (streaming, tools, retries)
├── commands/          Slash command implementations (~50)
├── tools/             Agent tool implementations (~40)
├── components/        Ink UI components (~140)
├── services/          API, MCP, OAuth, LSP, analytics, compaction
├── bridge/            IDE and remote-control bridge
├── coordinator/       Multi-agent coordination
├── plugins/           Plugin system
├── skills/            Skill system
├── entrypoints/       Initialization and CLI entrypoints
├── ink/               Ink renderer wrapper
└── utils/             Shared utilities
```

---

## How the reconstruction works

The published npm artifact was bundled, so the snapshot was missing the
project file, dependencies, some refactored-out modules, and the build-time
constants. Four mechanisms close that gap:

1. **Runtime feature flags.** Bun only provides `bun:bundle` inside
   `bun build`, so 196 imports were rewritten to
   [compat/feature.ts](compat/feature.ts). Enable flags with
   `CC_FEATURES=KAIROS,VOICE_MODE` or `CC_FEATURE_KAIROS=1`.
2. **Build-time macros.** [compat/preload.ts](compat/preload.ts) defines the
   `MACRO` object (`VERSION`, `PACKAGE_URL`, etc.) that `bun build --define`
   normally injects.
3. **Missing modules.** 120 missing runtime modules and 33 text resources are
   generated as clearly marked placeholders by
   [scripts/generate-missing-stubs.py](scripts/generate-missing-stubs.py).
4. **Private and native packages.** `color-diff-napi` uses the snapshot's own
   TypeScript port; image processing falls back to `sharp`; audio, computer-use,
   browser, deep-link, and macOS modifier helpers are stubs.

Two small source patches are required: the Commander option `-d2e` is not a
valid short flag in current Commander, and `bootstrap/state.ts` was missing the
`isReplBridgeActive()` export that other modules import.

---

## Tech stack

| Category | Technology |
|---|---|
| Runtime | Bun |
| Language | TypeScript |
| Terminal UI | React + Ink |
| CLI parsing | Commander.js (extra-typings) |
| Schema validation | Zod v4 |
| Protocols | MCP SDK, LSP |
| API | Anthropic SDK |
| Telemetry | OpenTelemetry + gRPC |
| Feature flags | GrowthBook |

Notable design points: parallel startup prefetch (MDM, keychain, settings),
lazy loading of heavy subsystems, an agent/tool registry with per-tool
permission models, and multi-agent swarms coordinated through `coordinator/`.

---

## Known limitations

- The interactive Ink UI has not been exercised on a real terminal yet.
- Modules absent from the snapshot are universal Proxy placeholders. Disabled
  feature flags normally keep execution out of those branches; enabling a flag
  that needs one of them requires a real implementation.
- Bundled skill documentation (claude-api, verify) is placeholder text.
- Private/native integrations (voice, Computer Use, browser tools, deep links,
  macOS modifiers) are unavailable.
- The dependency list was pruned to runtime-referenced packages. Type-only
  packages (`type-fest`, `vscode-languageserver-*`) were removed, so `tsc` and
  editors will report unresolved type modules even though runtime is unaffected.

---

## Provenance and disclaimer

This repository contains a mirrored `src/` snapshot of Claude Code that became
publicly accessible on **2026-03-31** through a source map exposed in the npm
distribution. It is maintained for educational, defensive security, and
supply-chain analysis purposes.

- The original Claude Code source remains the property of **Anthropic**.
- This repository is **not affiliated with, endorsed by, or maintained by
  Anthropic**.
- The `InvestAI` name refers to this local reconstruction project, not to an
  Anthropic product.
