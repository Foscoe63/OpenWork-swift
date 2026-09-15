<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="112" alt="OpenWork-Swift icon" />
</p>

<h1 align="center">OpenWork-Swift</h1>

<p align="center">
  <strong>Native macOS autonomous AI workbench</strong><br/>
  Swift · SwiftUI · Apple Silicon — no Electron
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple&logoColor=white" />
  <img alt="Swift 5.9 language mode" src="https://img.shields.io/badge/Swift-5.9%20language%20mode-F05138?style=flat-square&logo=swift&logoColor=white" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-MLX-5AC8FA?style=flat-square&logo=apple&logoColor=white" />
  <img alt="MCP" src="https://img.shields.io/badge/MCP-Swift%20SDK-412991?style=flat-square" />
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-green?style=flat-square" />
</p>

<p align="center">
  <a href="#-features">Features</a> ·
  <a href="#-mcp-servers">MCP</a> ·
  <a href="#-architecture">Architecture</a> ·
  <a href="#-requirements">Requirements</a> ·
  <a href="#-build--run">Build</a> ·
  <a href="#-configuration">Config</a> ·
  <a href="#-privacy">Privacy</a>
</p>

---

## Overview

**OpenWork-Swift** is a standalone native macOS app for autonomous agents, multi-agent collaboration, scheduled automations, and local/cloud LLM orchestration.

It ships as a real `.app` — UI and tooling sit on system frameworks (`Accelerate`, `Vision`, `PDFKit`, `WebKit`, `Speech`, Keychain). End users who install a build do **not** need Xcode or Swift installed.

Agent tooling aims for **Radiant-class** reliability: official MCP Swift SDK sessions, namespaced first-class MCP tools, native function calling on local MLX and cloud providers, and a multi-turn tool loop that keeps going until the job is done (with sensible guards for local models).

---

## Features

### Autonomous agents

| | Capability |
|:---:|---|
| 🔁 | Multi-turn ReAct with **native tool / function calling** (OpenAI, Ollama, in-process MLX) plus markdown / XML fallbacks |
| 📁 | Filesystem — `file_read` (paginated, numbered), `file_write`, `edit_file`, `multi_edit` (several edits, all or nothing), `file_list`, `file_copy`, `file_move`, `file_delete` |
| 🔎 | Code search — `grep` (regex → `path:line: text`), `glob` (`**/*.swift`), `find_symbol` (declarations only), `search_workspace` (BM25 index) |
| 🔨 | Build & test — `build_project`, `run_tests` — failures come back as `file:line: message`, and `run_tests(only_failing: true)` re-runs just the ones that failed |
| 🌿 | Git — `git_status`, `git_diff`, `git_log`. Committing stays yours *on your checkout*; the agent may commit only inside a worktree of its own, where history is additive and cannot rewrite yours |
| ↩️ | Undo — `changed_files`, `revert_changes` restore everything a turn touched |
| 💻 | Shell — `terminal_command` / `run_command` |
| 🌐 | Network — `fetch_url`, `web_search` |
| 💬 | Interaction — `ask_user`, `exit_plan_mode`, `todo_write` |
| 👁️ | **Perception** — `screenshot_window` (see any running app's window), `accessibility_tree` (read it as text — cheap, and works with text-only models), `run_app` (launch it and report what happened) |
| 🌿 | Isolation — `worktree_create`, `worktree_list`, `worktree_remove`, `git_commit` (confined to agent worktrees) |
| 🧮 | Utilities — `calculator`, `get_current_date`, `document_extract` |
| 📧 | Optional Google — `gmail_*`, `google_calendar_*` |

- Full JSON parameter schemas via `ToolSchemaCatalog` (critical for local-model tool use)
- **Workspace context** in the system prompt — path, project type, layout, git branch and dirty count
- **Per-repo instructions** — `OPENWORK.md` / `AGENTS.md` / `CLAUDE.md` at the workspace root
- **Turn-change review** — a footer appears when a turn touched files; per-file diffs, revert one or all. A session-wide view lists everything the session touched, with git's diff — read-only, because undo covers the current turn only
- **Fork a conversation** from any message — right-click it. The branch is the conversation only: files the discarded turns changed are still on disk, and the fork says which
- Context compaction keeps a factual digest of what dropped turns did (files edited, commands run, failures), so a long session does not forget its own work. It fires at *milestones* — a green test run, a clean tree — as well as on token pressure, so it trades detail for room when history is most disposable
- **Shortcuts & Siri** — "Ask OpenWork" and "Run Automation" App Intents run the same agent loop. Approvals are refused rather than awaited when nothing is on screen to grant them, and the result reports what it skipped
- **Plan mode** (read-only tools + `exit_plan_mode`)
- Approval gates for destructive / MCP write actions. MCP read/write classification is **fail-closed**: a tool is a read only when a known server advertises it and it is absent from that server's write list, so unknown servers ask. Expect more prompts than a name-prefix heuristic would produce — that is the point
- Sub-agent spawning and inter-agent messaging in the Side Inspector
- Clean chat UX: leaked model thinking moves to **Reasoning**, approvals sit **below** the answer, routine MCP status chips stay out of the way

### Local Apple Silicon (MLX) & providers

- **Local Models** tab (On Device / Catalog) for MLX discovery and selection
- Built-in Apple Silicon path (`NativeMLXService` / `LocalMLXEngine`) with real `ToolSpec` + `streamDetails` tool calls
- **KV cache reuse** — a continued conversation is appended to the live `ChatSession` rather than re-prefilled. Measured on a 48B model, time-to-first-token goes from 1.5s at three messages and climbing ~0.67s per exchange, to a flat 0.9s. Any rewrite of earlier history (compaction, a fork) rebuilds instead, because a cache describing text no longer in the conversation would keep steering the model invisibly
- Optional servers: oMLX, mlx_lm, Osaurus, Ollama, LM Studio
- Cloud & remote: OpenAI-compatible, Anthropic, Groq, OpenRouter, DeepSeek, Mistral, Gemini, custom endpoints
- Provider probing, model listing, Keychain-backed API keys

### Schedules & automations

- Schedules UI with status badges, next run, errors, and footer stats
- Create / edit / Run Now / History / Export / Pause / Resume / Delete
- Watch folders with filesystem triggers and artifact synthesis
- Visual agent flow builder for multi-agent pipelines

### Workspace, skills & desktop UX

- Workspace switcher on the chat header (synced with the sidebar)
- Enabled **Skills** injected into the agent system prompt
- Extensions, prompt templates, slash commands (`/clear`, `/agent`, `/model`, …)
- Local RAG (Accelerate), PDF/Vision extract, live canvas, diffs, terminal, voice STT/TTS
- **Window state persistence** — frame, sidebar & inspector widths, open/closed inspector, navigation destination, settings tab, last workspace & session survive quit/relaunch

---

## MCP servers

OpenWork-Swift speaks the [Model Context Protocol](https://modelcontextprotocol.io) with a Radiant-inspired client that prefers **failing soft** over freezing chat.

| | Behavior |
|:---:|---|
| 🔌 | Official MCP Swift SDK stdio client (`MCPSDKSession`) + hand-rolled pipe fallback |
| 🏷️ | Live tools injected as `mcp__{serverId}__{toolName}` |
| ⚡ | Cache-first discovery; background warm-up — chat is **not** blocked on every `npx` cold start |
| ⏱️ | Real deadlines that kill hung connects (structured cancel alone is not enough) |
| 🧭 | Server/tool routing refuses ambiguity — a name two enabled servers could answer is an error naming both, never a guess |
| 🧱 | Failed calls come back classified, with a recovery hint. Transient failures retry once; a rejected token or protocol mismatch does not |
| 🎚️ | Per-tool switches under each server, so you can enable a server without enabling everything on it |
| 📋 | “What MCP servers are available?” answers from config + live status — **no tool thrash** |
| 🩺 | Settings → Skills & MCP shows connected / error / tool counts; **Test** probes a server |
| 🔒 | Stock servers ship **disabled** — enable only what you trust |
| 🌍 | Remote HTTP MCP with clearer 401 messaging and optional bearer token (`MCP_TOKEN` / headers) |

### Dispatcher servers and catalog promotion

Some servers — [MacUse.app](https://macuse.app) among them — advertise only two meta-tools,
`get_tool_definitions` and `call_tool_by_name`, with the real work hidden behind them. Asking a
model to hand-nest every call through a dispatcher is exactly what local models get wrong.

So the catalog is **promoted**. When a listing comes back, its entries become directly callable
tools with real schemas for the rest of the turn, and the model is told they are available:

```
macuse.get_tool_definitions   →  64 tools harvested, 13 of them mail_*
macuse.mail_list_accounts     →  called directly, not wrapped
```

No sequence is hardcoded and no workflow is special-cased — the model picks the tool. Write
actions still route through the same approval gate as anything else, classified by the *nested*
target rather than the dispatcher's name, because `call_tool_by_name` is a read when it lists
mailboxes and a write when it sends mail.

> Tip: keep MacUse.app installed and grant Accessibility / Automation when you need write tools.
> For mail reads, Mail.app can stay closed if MacUse uses its local DB path.

---

## Architecture

```text
OpenWork-Swift/
├── Package.swift / Package.resolved   # SPM deps
├── project.yml                        # XcodeGen
├── OpenWorkSwift.xcodeproj
├── Resources/                         # App icon & assets
├── Tests/
└── Sources/
    ├── App/                 # Entry + window frame persistence
    ├── Models/              # Agent, Workspace, Session, Settings, ProviderSelection
    ├── State/               # AppState
    ├── Storage/             # Persistence, Keychain, WindowLayoutStore
    ├── Utils/               # AsyncDeadline (timeouts for uncancellable work),
    │                        # AppLog (verbose logging, gated by the setting),
    │                        # LaunchAtLogin (SMAppService)
    ├── Engine/
    │   ├── Agents/          # AgentRunner, approvals, ContextCompactor
    │   ├── Providers/       # OpenAI, Anthropic, Ollama, NativeMLX, LocalMLXEngine
    │   ├── Tools/           # Execution, schemas, CodeSearch, GitTools,
    │   │                    # BuildDiagnostics, FileCheckpointStore,
    │   │                    # WorkspaceContext, ProjectInstructions
    │   ├── MCP/             # Client, routing, effect catalog, tool gate,
    │   │                    # catalog promotion, failure classifier
    │   ├── Integrations/    # Google (Gmail / Calendar)
    │   ├── RAG/             # CodeIndex (BM25 over the workspace)
    │   └── Terminal/ · Voice/ · Watch/
    └── UI/
        ├── Navigation/      # Sidebar, Spotlight
        ├── Theme/ · Components/
        └── Views/           # Chat, LocalModels, Agents, Automations,
                             # Settings, Inspector, Dashboard, …
```

### Sidebar destinations

| | Destination |
|:---:|---|
| 💬 | Chat & Sessions |
| 🧊 | Local Models |
| 👥 | AI Agents |
| 🖥️ | Model Providers |
| ⚡ | Automations (Schedules) |
| 👁️ | Watch Folders |
| 📂 | Artifacts & Files |
| 🧠 | Memory & Knowledge |
| 🛠️ | Tools & MCP |
| 📊 | Dashboard & Metrics |
| ⚙️ | Settings |

---

## Requirements

| Use case | Need |
|---|---|
| **Run a built `.app`** | macOS 14+ (Sonoma or later); Apple Silicon recommended for MLX |
| **Build from source** | **Xcode 26.6+ (Swift 6.3)**, macOS 14+ SDK — `mlx-swift` declares `swift-tools-version: 6.3`, so the package graph will not resolve on an older toolchain whatever this project's own 5.9 language mode says |
| **…and its Metal toolchain** | A separate download as of Xcode 26: `xcodebuild -downloadComponent MetalToolchain`. Without it `mlx-swift` fails at `CompileMetalFile` |
| **Optional local servers** | Ollama, LM Studio, oMLX / `mlx-lm`, or Osaurus — only if you use those backends |
| **Optional MacUse MCP** | [MacUse.app](https://macuse.app); Accessibility / Automation for write actions |

Swift / Xcode are **not** required on machines that only install and run a prebuilt app.

---

## Build & run

### Xcode (recommended)

```bash
# Regenerate the project if Sources/ changed
brew install xcodegen   # once
xcodegen generate

open OpenWorkSwift.xcodeproj
```

Select the **OpenWorkSwift** scheme → Build / Run.

> The app target compiles `Sources/` directly and links SPM products from `project.yml` (Yams, MCP, NIO, mlx-swift-lm, Hugging Face, Tokenizers).

### Swift Package Manager

SwiftPM has to be pointed at the **Xcode** toolchain. If `xcode-select -p` reports
`/Library/Developer/CommandLineTools`, the Command Line Tools toolchain is used instead and the
build dies early with `unknown argument: '-target-arch-variant'` — misleading, because nothing
is wrong with the package.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build
swift run OpenWorkSwift
swift test                      # 402 tests
```

To fix it for good rather than per-shell (needs your password):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

> If a build fails with `unable to spawn process '.../Metal.xctoolchain/usr/bin/metal'` while
> `xcrun -f metal` resolves fine, the Metal toolchain is a cryptex whose mount path changes on
> reboot and XCBuild has cached the old one. Clear `.build/out/Intermediates.noindex/XCBuildData`.

### Install a Debug build (optional)

The product is named **`OpenWork.app`**, not `OpenWork-Swift.app` — `PRODUCT_NAME` is
`OpenWork` while the Swift module and scheme stay `OpenWorkSwift`.

```bash
# After a successful Debug build:
cp -R ~/Library/Developer/Xcode/DerivedData/OpenWorkSwift-*/Build/Products/Debug/OpenWork.app \
  /Applications/OpenWork.app
```

Quit any running OpenWork instance before replacing the bundle.

---

## Configuration

| | Area | Where / tip |
|:---:|---|---|
| 🔑 | **Providers** | Settings → AI Providers — cloud keys in Keychain; local base URLs for Ollama / LM Studio / MLX servers |
| 🧊 | **Local Models** | Local Models tab — pick an on-device MLX model |
| 🔌 | **MCP** | Settings → Skills & MCP — enable servers, **Refresh Status** / **Test**, restore defaults (disabled) |
| 📬 | **Dispatcher MCP servers** | e.g. `use the macuse mcp-server and check the mail on this computer` — the catalog is promoted on first listing |
| 📄 | **Per-repo rules** | Drop `OPENWORK.md` or `AGENTS.md` at the workspace root — build commands, house style, what not to touch |
| 🤖 | **Agents & skills** | Per-agent tools; enabled skills land in the system prompt |
| 🎛️ | **Advanced** | Plan Mode, Max Turn Tokens, sub-agent depth, collaboration room |
| 🧠 | **Context** | Settings → Preferences — auto-compaction and the token threshold that triggers it |
| 🎚️ | **GPU budget** | Settings → Apple Silicon MLX — the budget ratio caps MLX's buffer cache *and* decides which models are badged as fitting |
| 🗣️ | **Voice** | Settings → Extensions — dictation and read-aloud each have a switch, plus a picker for the spoken voice |
| 🗓️ | **Schedules** | Automations — Morning Brief–style prompts, frequency text (`Daily at 6:00 AM`), Run Now |
| 🗂️ | **Workspaces** | Chat header or sidebar — stays synced with the current session |
| 🪟 | **Layout** | Drag splits / move the window — restored automatically next launch |

---

## Privacy

**The agent can see what it built.** A screenshot of any running app — not just a browser tab,
because this is a native macOS app — reaches a vision model directly, and
`accessibility_tree` gives the same window as text, which is cheaper and works with a
text-only local model. Screen Recording and Accessibility are asked for only when a
perception tool is first used, and refusing them disables those two tools and nothing else.

OpenWork-Swift is **local-first**. It talks only to LLM endpoints and MCP servers **you** configure. No bundled third-party analytics or telemetry.

**A local turn never silently becomes a cloud one.** When the selected provider runs on this
Mac and is switched off, OpenWork will substitute another *local* provider — and if there is
none, it stops and says so rather than answering from whatever cloud endpoint happens to be
enabled. This is not hypothetical: provider selection used to fall through to the first enabled
provider in list order, and a cloud provider commonly sits earlier in that list than the
built-in engine. A disabled *cloud* provider still falls back normally; the rule is about not
leaving the machine.

The built-in Apple Silicon provider means **in-process MLX and nothing else**. It never probes
for a local server to answer on its behalf, so a turn you sent to it either ran here or failed
with the reason.

---

## License

MIT © 2026 OpenWork-Swift
