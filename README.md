# OpenWork-Swift

<p align="center">
  <strong>Native macOS Autonomous AI Agent Platform & Knowledge Workbench</strong><br>
  Engineered in 100% pure Swift & SwiftUI for Apple Silicon. Zero Electron overhead.
</p>

---

## 🌟 Overview

**OpenWork-Swift** is a high-performance, standalone native macOS application for autonomous AI agents, multi-agent collaboration, and local/cloud LLM orchestration. 

Unlike conventional Electron- or web-wrapped AI tools that consume gigabytes of RAM and hundreds of megabytes of disk space, OpenWork-Swift is compiled directly to native ARM64 machine code (~8.5 MB footprint), leveraging macOS system frameworks (`Accelerate`, `Vision`, `PDFKit`, `WebKit`, `Speech`, and `Security Keychain`) for instantaneous startup, low latency, and efficient memory usage.

---

## 🚀 Key Capabilities & Features

### 1. Autonomous Agent Execution Loop (Claude Code & Cursor Parity)
- **Native Structured Tool Calling**: Full JSON Schema tool-calling support across OpenAI, Anthropic Claude, and Ollama APIs.
- **Deep Multi-Turn ReAct Cycles**: Configurable autonomous execution loop (up to 50 iterations per turn) allowing agents to plan, invoke tools, inspect terminal/file outputs, self-correct, and complete complex workflows.
- **Robust Markdown Fallback**: Dual-mode engine capable of seamlessly parsing markdown ReAct tool blocks when connected to models without native tool endpoints.
- **Interactive Plan Approval Cards**: Visual approval gates for sensitive tool executions (e.g. file writes, shell commands).

### 2. Multi-Agent Orchestration & Real Sub-Agent Streams
- **Autonomous Sub-Agent Spawning**: Parent agents can decompose complex tasks and delegate sub-tasks to specialized child agents (Coder, Reviewer, Researcher, Data Specialist).
- **Isolated LLM Streams**: Sub-agents evaluate tasks in isolated background streams using their assigned system prompts and parameters.
- **Inter-Agent Communication Hub**: Structured message passing and broadcast logs visible in real time via the Side Inspector.
- **Visual Agent Flow Builder**: Canvas-based node editor for designing multi-agent round-robin pipelines.

### 3. Model Provider Management (Local & Cloud)
- **Local Inference Support**: Direct integration with **Ollama**, **oMLX**, **vMLX**, **LM Studio**, and **llama.cpp**.
- **Dynamic Model Discovery**: Flexible multi-endpoint probing for local servers, model listing, and configurable API key authorization.
- **Cloud Providers**: Native streaming support for Anthropic Claude (with extended thinking/reasoning), OpenAI (GPT-4o, o1, o3-mini), OpenRouter, Groq, DeepSeek, Mistral, and custom endpoints.
- **Token & Cost Tracking**: Live dashboard monitoring token consumption, per-model prompt/completion costs, and request latency.

### 4. Interactive Live Canvas & Visual Tools
- **Embedded Web Workbench**: Live `WKWebView` canvas for rendering AI-generated HTML5, Tailwind CSS, SVG diagrams, and React artifacts in real time.
- **Visual Side-by-Side Diff Inspector**: Color-coded syntax-highlighted diffing for file modifications with instant review and apply capabilities.
- **Integrated Terminal Streamer**: Real interactive shell session in the sidebar powered by native POSIX pseudo-terminals and process pipes.
- **Global Spotlight Search (`⌘K`)**: Instant search across workspaces, agents, sessions, prompt templates, and tools.

### 5. Local RAG & Document Intelligence
- **Apple Accelerate Vector Engine**: Local semantic chunk search accelerated via SIMD `vDSP_dotpr` vector operations for fast retrieval.
- **PDFKit & Vision OCR Extractor**: Extract structured text from PDFs or run optical character recognition on scanned images and diagrams via Apple's Neural Engine.
- **Staged Pipeline Workspaces**: Automated workspace staging folders (`input/` and `output/`) for batch file processing.

### 6. Watch Folders & Real-Time Ingestion Triggers (Claude Co-Work Style)
- **Directory & File Watchers**: Real-time macOS `DispatchSource` filesystem event monitors on workspace folders, staging directories, or external storage drives.
- **Automated Morning Briefs & Daily Updates**: Autonomously synthesizes executive Morning Briefs, Daily Project Updates, and Code Review digests as files are modified or dropped in.
- **Dedicated Watch Folders Hub**: Left sidebar navigation tab with active listener statuses, one-click manual scan triggers, and generated artifact drawers.
- **Settings Watch Hub**: Global and workspace configuration for watch paths, file debouncing intervals, and assigned briefing agents.

### 7. Extensions, MCP & Skill Ecosystem
- **Model Context Protocol (MCP)**: Built-in JSON-RPC 2.0 client engine supporting `stdio` and `SSE` transport modes.
- **Extensions & Plugins Hub**: Install, configure, and manage MCP servers, custom scripts, agent skills, and system extensions with custom environment variables.
- **Prompt Template Catalog & Autocomplete**: Over 70 business and technical prompt presets with `/` slash-command autocomplete in the message composer.
- **Native Voice & Speech**: Speech-to-Text (STT) prompt dictation and Text-to-Speech (TTS) audio playback.

### 7. Security & Persistence
- **macOS Keychain Storage**: Hardware-backed credential store for API keys and sensitive tokens.
- **Flexible Workspace Paths**: Support for external SSDs, local repositories, and custom project directories.
- **Session Export**: Export chat sessions to Markdown, JSON, or standalone styled HTML documents.

---

## 🏗️ Architecture & Module Organization

```
OpenWork-Swift/
├── Package.swift                     # Swift Package Manager Manifest
├── project.yml                       # XcodeGen Project Definition
├── Resources/                        # App Icons, Asset Catalog & Resources
└── Sources/
    ├── App/                          # Application lifecycle & AppDelegate
    ├── Models/                       # Domain models (Agent, Workspace, Tool, Plugin, Session)
    ├── State/                        # AppState centralized ObservableObject
    ├── Storage/                      # KeychainManager & PersistenceManager
    ├── Engine/
    │   ├── Agents/                   # AgentRunner, Multi-turn ReAct loop & Communication Hub
    │   ├── Providers/                # LLM clients (OpenAI, Anthropic, Ollama, Mock)
    │   ├── Tools/                    # ToolExecutionEngine & DocumentExtractionEngine
    │   ├── MCP/                      # JSON-RPC Protocol & MCPClientManager
    │   ├── RAG/                      # LocalWorkspaceRAGEngine (Apple Accelerate SIMD)
    │   ├── Terminal/                 # WorkspaceTerminalSession (Interactive shell)
    │   └── Voice/                    # VoiceSpeechEngine (STT & TTS)
    └── UI/
        ├── Navigation/               # AppSidebar & SpotlightSearchView
        ├── Views/
        │   ├── Chat/                 # ChatView, Composer, MessageBubble, PlanApproval
        │   ├── Artifacts/            # LiveCanvasView & VisualDiffInspectorView
        │   ├── Agents/               # AgentsView & Collaboration Hub
        │   ├── Automations/          # AutomationsView & VisualAgentFlowBuilderView
        │   ├── Providers/            # ProvidersView & Model Config
        │   ├── Tools/                # ToolsView & Extensions Inventory
        │   ├── Inspector/            # SideInspector, SubAgentTree, TerminalView
        │   ├── Dashboard/            # Metrics, Token Usage & Cost Analytics
        │   └── Settings/             # SettingsView, Modals & Plugin Management
        └── Theme/                    # ThemeColors & Design Tokens
```

---

## 🛠️ Building & Running

### Requirements
- macOS 13.0 (Ventura) or later (macOS 14+ Sonoma / macOS 15+ Sequoia recommended)
- Xcode 15.0+ with Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for regenerating `.xcodeproj`)

### Swift Package Manager (CLI)
```bash
# Build the project
swift build

# Run the application
swift run OpenWorkSwift
```

### Xcode Project
```bash
# Generate the Xcode project file
xcodegen generate

# Open and build in Xcode
open OpenWorkSwift.xcodeproj
```

---

## 🔒 Privacy & Local-First Philosophy

OpenWork-Swift operates entirely locally on your Mac. It communicates exclusively with the LLM endpoints and MCP servers you explicitly configure. No telemetry, third-party analytics, or background tracking services are bundled in the application.

---

## 📄 License

This project is licensed under the MIT License.
