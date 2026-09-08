# OpenWork-Swift

<p align="center">
  <strong>Native macOS Autonomous AI Agent Platform & Knowledge Workbench</strong><br>
  Built in Swift & SwiftUI for Apple Silicon. No Electron runtime.
</p>

---

## Overview

**OpenWork-Swift** is a standalone native macOS app for autonomous AI agents, multi-agent collaboration, scheduled automations, and local/cloud LLM orchestration.

It compiles to a native macOS application and uses system frameworks (`Accelerate`, `Vision`, `PDFKit`, `WebKit`, `Speech`, `Security` / Keychain) for low-overhead UI and tooling. End users who install a built `.app` do **not** need Swift or Xcode installed.

---

## Key Features

### Autonomous agents
- Multi-turn ReAct execution loop with native tool calling and markdown / XML tool-call fallbacks
- Built-in tools: filesystem (`file_read`, `file_write`, `file_list`, `file_copy`, `file_move`, `file_delete`), terminal, web search, calculator, date, document extract
- Loop detection, presence/frequency penalties, and plan-approval cards for sensitive actions
- Sub-agent spawning, isolated streams, and inter-agent messaging in the Side Inspector

### Local Apple Silicon (MLX) & providers
- **Local Models** tab (On Device / Catalog) for MLX model discovery and selection
- Built-in Apple Silicon provider path (`NativeMLXService` / `LocalMLXEngine`) with optional external servers (oMLX, mlx_lm, Osaurus, Ollama, LM Studio)
- Cloud & remote: OpenAI-compatible, Anthropic, Groq, OpenRouter, DeepSeek, Mistral, Gemini, custom endpoints
- Provider probing, model listing, and Keychain-backed API keys

### Schedules & automations
- Schedules UI with adaptive multi-column cards (Osaurus-style): status badge, next run, errors, footer stats
- Create / **edit** schedules (tap card or `⋯` → Edit), Run Now, History, Export, Pause/Resume, Delete
- Watch folders with filesystem triggers and artifact synthesis
- Visual agent flow builder for multi-agent pipelines

### MCP, tools & workspace
- Model Context Protocol (stdio / SSE) with configurable servers and agent tool allow-lists
- Extensions, skills, prompt templates, slash commands (`/clear`, `/agent`, `/model`, …)
- Local RAG (Accelerate), PDF/Vision document extract, live canvas, diffs, terminal, voice STT/TTS
- Session export to Markdown, JSON, or HTML

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
    ├── Models/                   # Agent, Workspace, Session, Automation, LocalMLXModel, …
    ├── State/                    # AppState
    ├── Storage/                  # PersistenceManager, KeychainManager
    ├── Engine/
    │   ├── Agents/               # AgentRunner, CommunicationHub
    │   ├── Providers/            # OpenAI, Anthropic, Ollama, NativeMLX, LocalMLXEngine, Router
    │   ├── Tools/                # ToolExecutionEngine, DocumentExtraction
    │   ├── MCP/
    │   ├── RAG/
    │   ├── Terminal/
    │   ├── Voice/
    │   └── Watch/
    └── UI/
        ├── Navigation/           # Sidebar, Spotlight
        ├── Theme/
        └── Views/
            ├── Chat/
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
            └── Settings/
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

---

## Configuration tips

- **Providers:** Settings / Model Providers — cloud API keys in Keychain; local base URLs for Ollama / LM Studio / MLX servers
- **Local Models:** pick an on-device MLX model; the app prefers built-in Apple Silicon routing over exposing ports in the UI
- **MCP:** enable servers under Tools / Settings; allow tools per agent in the Agents editor
- **Schedules:** Automations tab — create or edit Morning Brief–style prompts, set frequency text (e.g. `Daily at 6:00 AM`), assign an agent, Run Now to test

---

## Privacy

OpenWork-Swift is local-first. It talks only to LLM endpoints and MCP servers you configure. No bundled third-party analytics or telemetry.

---

## License

MIT
