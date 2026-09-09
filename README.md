# OpenWork-Swift

<p align="center">
  <strong>Native macOS Autonomous AI Agent Platform & Knowledge Workbench</strong><br>
  Built in Swift & SwiftUI for Apple Silicon. No Electron runtime.
</p>

---

## Overview

**OpenWork-Swift** is a standalone native macOS app for autonomous AI agents, multi-agent collaboration, scheduled automations, and local/cloud LLM orchestration.

It compiles to a native macOS application and uses system frameworks (`Accelerate`, `Vision`, `PDFKit`, `WebKit`, `Speech`, `Security` / Keychain) for low-overhead UI and tooling. End users who install a built `.app` do **not** need Swift or Xcode installed.

Agent tooling is designed for **Radiant-style** reliability: official MCP Swift SDK sessions, namespaced first-class MCP tools, native function calling on local MLX and cloud providers, and a multi-turn tool loop that keeps going until the job is done (with sensible guards for local models).

---

## Key Features

### Autonomous agents
- Multi-turn ReAct execution loop with **native tool / function calling** (OpenAI, Ollama, in-process MLX) and markdown / XML tool-call fallbacks
- Built-in tools include:
  - Filesystem: `file_read`, `file_write`, `edit_file`, `file_list`, `file_copy`, `file_move`, `file_delete`
  - Shell: `terminal_command` / `run_command`
  - Network: `fetch_url`, `web_search`
  - Interaction: `ask_user`, `exit_plan_mode`, `todo_write`
  - Utilities: `calculator`, `get_current_date`, `document_extract`
  - Optional Google integrations: `gmail_*`, `google_calendar_*`
- Full JSON parameter schemas via `ToolSchemaCatalog` (required for reliable local-model tool use)
- Context compaction, folding of old tool results, turn token budget halt, identical-tool stuck breaker
- Plan mode (read-only tool filter + `exit_plan_mode`)
- Approval gates for destructive / MCP write actions; read-only MCP tools auto-run
- Sub-agent spawning, isolated streams, and inter-agent messaging in the Side Inspector
- Chat notices, halt + **Continue**, live tool cards, and session export (Markdown / JSON / HTML)

### Local Apple Silicon (MLX) & providers
- **Local Models** tab (On Device / Catalog) for MLX model discovery and selection
- Built-in Apple Silicon path (`NativeMLXService` / `LocalMLXEngine`) with `ToolSpec` + `streamDetails` tool calls (no fake stub tools)
- Optional external servers: oMLX, mlx_lm, Osaurus, Ollama, LM Studio
- Cloud & remote: OpenAI-compatible, Anthropic, Groq, OpenRouter, DeepSeek, Mistral, Gemini, custom endpoints
- Provider probing, model listing, and Keychain-backed API keys

### MCP (Model Context Protocol)
- Official **MCP Swift SDK** stdio client (`MCPSDKSession`) with hand-rolled pipe fallback
- Tools discovered via `tools/list` and injected as first-class namespaced tools:  
  `mcp__{serverId}__{toolName}`
- Concurrent server warm-up with per-server timeouts; intent-aware priority (e.g. MacUse first for mail prompts)
- Nested JSON-string arguments coerced to real objects (local models often emit `"arguments": "{}"`)
- **MacUse** (low-context) workflow for mail / calendar-style apps:
  1. `get_tool_definitions` (e.g. `mail_*`)
  2. `call_tool_by_name` → `mail_list_accounts`
  3. `call_tool_by_name` → `mail_search_messages`
  4. Deterministic inbox summary in chat  
  Auto-follow is **read-only** (never auto reply / forward / mark-read)
- Configurable servers under Tools / Settings; CodeGraph and other stdio servers supported

### Schedules & automations
- Schedules UI with adaptive multi-column cards: status badge, next run, errors, footer stats
- Create / **edit** schedules (tap card or `⋯` → Edit), Run Now, History, Export, Pause/Resume, Delete
- Watch folders with filesystem triggers and artifact synthesis
- Visual agent flow builder for multi-agent pipelines

### Workspace, skills & UX
- Workspace switcher on the main chat header (synced with sidebar Core Workspaces)
- Skills injected into the agent system prompt when enabled
- Extensions, prompt templates, slash commands (`/clear`, `/agent`, `/model`, …)
- Local RAG (Accelerate), PDF/Vision document extract, live canvas, diffs, terminal, voice STT/TTS
- Advanced settings: Plan Mode, Max Turn Tokens, auto context compaction

---

## Architecture

```
OpenWork-Swift/
├── Package.swift                 # SPM deps (Yams, MCP, NIO, mlx-swift-lm, HF, …)
├── Package.resolved
├── project.yml                   # XcodeGen definition
├── OpenWorkSwift.xcodeproj       # App target (Compile Sources)
├── Resources/                    # App icon & asset catalog
├── Tests/
└── Sources/
    ├── App/                      # App entry
    ├── Models/                   # Agent, Workspace, Session, Automation, Settings, …
    ├── State/                    # AppState
    ├── Storage/                  # PersistenceManager, KeychainManager
    ├── Engine/
    │   ├── Agents/               # AgentRunner, ContextCompactor, UserChoiceManager,
    │   │                         # ToolApprovalManager, CommunicationHub
    │   ├── Providers/            # OpenAI, Anthropic, Ollama, NativeMLX, LocalMLXEngine, Router
    │   ├── Tools/                # ToolExecutionEngine, ToolSchemaCatalog, ToolBounds,
    │   │                         # DocumentExtraction
    │   ├── MCP/                  # MCPProtocol (manager), MCPSDKSession (official SDK)
    │   ├── Integrations/         # Google (Gmail / Calendar)
    │   ├── RAG/
    │   ├── Terminal/
    │   ├── Voice/
    │   └── Watch/
    └── UI/
        ├── Components/           # WorkspaceSwitcherMenu, …
        ├── Navigation/           # Sidebar, Spotlight
        ├── Theme/
        └── Views/
            ├── Chat/             # Chat, Composer, MessageBubble, tool cards, halt UI
            ├── LocalModels/      # MLX On Device / Catalog
            ├── Agents/
            ├── Providers/
            ├── Automations/      # Schedules cards + editor
            ├── WatchFolders/
            ├── Artifacts/
            ├── Memory/
            ├── Tools/
            ├── Inspector/
            ├── Dashboard/
            └── Settings/         # Includes Advanced: Plan Mode, turn budget
```

### Sidebar destinations
Chat · Local Models · Agents · Model Providers · Automations (Schedules) · Watch Folders · Artifacts · Memory · Tools & MCP · Dashboard · Settings

---

## Requirements

| Use case | Need |
|---|---|
| **Run a built `.app`** | macOS 14+ (Sonoma or later); Apple Silicon recommended for MLX |
| **Build from source** | Xcode 15+, Swift 5.9+, macOS 14+ SDK |
| **Optional local servers** | Ollama, LM Studio, oMLX / `mlx-lm`, or Osaurus — only if you use those backends |
| **Optional MacUse MCP** | [MacUse.app](https://macuse.app) installed; grant Accessibility / Automation as prompted for write actions |

Swift / Xcode are **not** required on machines that only install and run a prebuilt app.

---

## Building & Running

### Xcode (app target)

```bash
open OpenWorkSwift.xcodeproj
```

Select the **OpenWorkSwift** scheme, then Build / Run.

> **Note:** The Xcode app target currently compiles `Sources/` directly. Package Dependencies in Xcode may appear empty even though `Package.swift` lists MLX and other libraries. For full in-process MLX modules when building via Xcode, link those SPM products to the app target (or open/build via SwiftPM as below). `NativeMLXService` uses `#if canImport(...)` so the app still builds when MLX products are not linked.

Regenerate the project from XcodeGen if needed:

```bash
brew install xcodegen   # if needed
xcodegen generate
open OpenWorkSwift.xcodeproj
```

### Swift Package Manager

```bash
swift build
swift run OpenWorkSwift
swift test
```

SPM resolves dependencies from `Package.swift` (Yams, MCP Swift SDK, SwiftNIO, mlx-swift-lm, Hugging Face, Tokenizers, Jinja).

### Install a Debug build to `/Applications` (optional)

```bash
# After a successful Xcode / xcodebuild Debug build:
cp -R ~/Library/Developer/Xcode/DerivedData/OpenWorkSwift-*/Build/Products/Debug/OpenWork.app \
  /Applications/OpenWork.app
```

Quit any running OpenWork instance before replacing the bundle.

---

## Configuration tips

- **Providers:** Settings / Model Providers — cloud API keys in Keychain; local base URLs for Ollama / LM Studio / MLX servers
- **Local Models:** pick an on-device MLX model; the app prefers built-in Apple Silicon routing over exposing ports in the UI
- **MCP:** enable servers under Tools / Settings (e.g. Filesystem, Fetch, Memory, Git, MacUse, CodeGraph, search). Servers are warmed with timeouts; MacUse is prioritized when the prompt mentions mail / MacUse
- **MacUse mail:** prompt like `use the macuse mcp-server and check the mail on this computer`. Expect tool cards for definitions → list accounts → search, then an inbox summary. Keep Mail.app running if you need write actions (reply / send); reads use MacUse’s local DB path
- **Agents:** allow tools per agent; skills enabled in Skills are injected into the system prompt
- **Advanced:** Plan Mode, Max Turn Tokens, auto context compaction threshold
- **Schedules:** Automations tab — create or edit Morning Brief–style prompts, set frequency text (e.g. `Daily at 6:00 AM`), assign an agent, Run Now to test
- **Workspaces:** switch from the chat header or sidebar; the active workspace stays in sync with the current session

---

## Privacy

OpenWork-Swift is local-first. It talks only to LLM endpoints and MCP servers you configure. No bundled third-party analytics or telemetry.

---

## License

MIT
