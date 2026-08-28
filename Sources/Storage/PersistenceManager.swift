import Foundation

public final class PersistenceManager: @unchecked Sendable {
    public static let shared = PersistenceManager()

    private let storage = StorageService.shared

    private init() {}

    // MARK: - Workspaces
    public var defaultWorkspaces: [Workspace] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseWs = (home as NSString).appendingPathComponent("Documents/OpenWork/Workspaces")
        return [
            Workspace(
                id: "default-workspace",
                name: "Main Workspace",
                icon: "briefcase.fill",
                color: "#6366F1",
                folderPath: (baseWs as NSString).appendingPathComponent("Main"),
                category: .general,
                assignedAgentId: "lead-assistant",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "ai-research",
                name: "AI & Agent Research",
                icon: "brain.head.profile",
                color: "#EC4899",
                folderPath: (baseWs as NSString).appendingPathComponent("AI-Research"),
                category: .research,
                assignedAgentId: "research-agent",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "personal-workspace",
                name: "Personal Projects",
                icon: "folder.fill",
                color: "#10B981",
                folderPath: (baseWs as NSString).appendingPathComponent("Personal-Projects"),
                category: .project,
                assignedAgentId: nil,
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "coder-workspace",
                name: "Software Engineer Workspace",
                icon: "chevron.left.forwardslash.chevron.right",
                color: "#3B82F6",
                folderPath: (baseWs as NSString).appendingPathComponent("Software-Engineer"),
                category: .agent,
                assignedAgentId: "coder-agent",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "reviewer-workspace",
                name: "Code Review & QA Workspace",
                icon: "checkmark.shield.fill",
                color: "#F59E0B",
                folderPath: (baseWs as NSString).appendingPathComponent("Code-Review"),
                category: .agent,
                assignedAgentId: "reviewer-agent",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "data-workspace",
                name: "Data & Analytics Workspace",
                icon: "chart.bar.xaxis",
                color: "#06B6D4",
                folderPath: (baseWs as NSString).appendingPathComponent("Data-Analytics"),
                category: .agent,
                assignedAgentId: "data-analyst",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            )
        ]
    }

    public func loadWorkspaces() -> [Workspace] {
        var items: [Workspace] = []
        if let loaded = storage.load([Workspace].self, from: "workspaces.json"), !loaded.isEmpty {
            items = loaded
        } else {
            items = defaultWorkspaces
            saveWorkspaces(items)
        }

        // Merge any new default workspace presets that don't exist yet
        var modified = false
        for def in defaultWorkspaces {
            if !items.contains(where: { $0.id == def.id }) {
                items.append(def)
                modified = true
            }
        }
        if modified {
            saveWorkspaces(items)
        }
        return items
    }

    public func saveWorkspaces(_ workspaces: [Workspace]) {
        storage.save(workspaces, to: "workspaces.json")
    }

    // MARK: - Settings
    public func loadSettings() -> AppSettings {
        if let settings = storage.load(AppSettings.self, from: "settings.json") {
            return settings
        }
        let `default` = AppSettings.default
        saveSettings(`default`)
        return `default`
    }

    public func saveSettings(_ settings: AppSettings) {
        storage.save(settings, to: "settings.json")
    }

    // MARK: - Providers
    public var defaultProviders: [ModelProvider] {
        [
            ModelProvider(
                id: "ollama-local",
                name: "Ollama (Local)",
                type: .local,
                kind: .ollama,
                baseUrl: "http://127.0.0.1:11434",
                apiKey: "",
                isEnabled: true,
                isDefault: true,
                models: [
                    ModelInfo(id: "llama3:latest", name: "Llama 3 (8B)", providerId: "ollama-local", contextWindow: 8192, supportsVision: false, supportsReasoning: false, isDefault: true, speedTier: "Fast"),
                    ModelInfo(id: "llama3.3:latest", name: "Llama 3.3 (70B)", providerId: "ollama-local", contextWindow: 131072, supportsVision: false, supportsReasoning: false, speedTier: "Powerful"),
                    ModelInfo(id: "mistral:latest", name: "Mistral 7B", providerId: "ollama-local", contextWindow: 32768, supportsVision: false, supportsReasoning: false, speedTier: "Fast"),
                    ModelInfo(id: "deepseek-r1:8b", name: "DeepSeek R1 (8B Reasoning)", providerId: "ollama-local", contextWindow: 65536, supportsVision: false, supportsReasoning: true, speedTier: "Balanced"),
                    ModelInfo(id: "qwen2.5-coder:7b", name: "Qwen 2.5 Coder (7B)", providerId: "ollama-local", contextWindow: 32768, supportsVision: false, supportsReasoning: false, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "omlx-local",
                name: "oMLX (Apple Silicon)",
                type: .local,
                kind: .omlx,
                baseUrl: "http://127.0.0.1:8000/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", name: "Qwen 2.5 Coder 32B (MLX 4-bit)", providerId: "omlx-local", contextWindow: 65536, supportsTools: true, isDefault: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit", name: "DeepSeek R1 Distill 14B (MLX)", providerId: "omlx-local", contextWindow: 65536, supportsReasoning: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/Llama-3.3-70B-Instruct-4bit", name: "Llama 3.3 70B (MLX 4-bit)", providerId: "omlx-local", contextWindow: 131072, speedTier: "Balanced")
                ]
            ),
            ModelProvider(
                id: "vmlx-local",
                name: "vMLX (Vision & Multi-Modal)",
                type: .local,
                kind: .vmlx,
                baseUrl: "http://127.0.0.1:8080/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "mlx-community/Qwen2-VL-7B-Instruct-4bit", name: "Qwen2 VL 7B (Vision MLX)", providerId: "vmlx-local", contextWindow: 32768, supportsVision: true, isDefault: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit", name: "Llama 3.2 Vision 11B (MLX)", providerId: "vmlx-local", contextWindow: 128000, supportsVision: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/pixtral-12b-4bit", name: "Pixtral 12B Vision (MLX)", providerId: "vmlx-local", contextWindow: 128000, supportsVision: true, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "lmstudio-local",
                name: "LM Studio (Local)",
                type: .local,
                kind: .lmstudio,
                baseUrl: "http://127.0.0.1:1234/v1",
                apiKey: "",
                isEnabled: false,
                models: [
                    ModelInfo(id: "local-model", name: "Active LM Studio Model", providerId: "lmstudio-local", contextWindow: 32768, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "openai-cloud",
                name: "OpenAI",
                type: .cloud,
                kind: .openai,
                baseUrl: "https://api.openai.com/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "gpt-4o", name: "GPT-4o (Omni)", providerId: "openai-cloud", contextWindow: 128000, supportsVision: true, supportsReasoning: false, isDefault: true, speedTier: "Fast", costPer1kPrompt: 0.005, costPer1kCompletion: 0.015),
                    ModelInfo(id: "gpt-4o-mini", name: "GPT-4o Mini", providerId: "openai-cloud", contextWindow: 128000, supportsVision: true, supportsReasoning: false, speedTier: "Fast", costPer1kPrompt: 0.00015, costPer1kCompletion: 0.0006),
                    ModelInfo(id: "o1", name: "o1 Reasoning", providerId: "openai-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: true, speedTier: "Powerful", costPer1kPrompt: 0.015, costPer1kCompletion: 0.06),
                    ModelInfo(id: "o3-mini", name: "o3-mini", providerId: "openai-cloud", contextWindow: 200000, supportsVision: false, supportsReasoning: true, speedTier: "Fast", costPer1kPrompt: 0.0011, costPer1kCompletion: 0.0044)
                ]
            ),
            ModelProvider(
                id: "anthropic-cloud",
                name: "Anthropic Claude",
                type: .cloud,
                kind: .anthropic,
                baseUrl: "https://api.anthropic.com/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "claude-3-7-sonnet-20250219", name: "Claude 3.7 Sonnet (Hybrid Reasoning)", providerId: "anthropic-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: true, isDefault: true, speedTier: "Powerful", costPer1kPrompt: 0.003, costPer1kCompletion: 0.015),
                    ModelInfo(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", providerId: "anthropic-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: false, speedTier: "Powerful", costPer1kPrompt: 0.003, costPer1kCompletion: 0.015),
                    ModelInfo(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", providerId: "anthropic-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: false, speedTier: "Fast", costPer1kPrompt: 0.0008, costPer1kCompletion: 0.004)
                ]
            ),
            ModelProvider(
                id: "groq-cloud",
                name: "Groq",
                type: .cloud,
                kind: .groq,
                baseUrl: "https://api.groq.com/openai/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B Versatile", providerId: "groq-cloud", contextWindow: 128000, speedTier: "Fast"),
                    ModelInfo(id: "deepseek-r1-distill-llama-70b", name: "DeepSeek R1 Distill 70B", providerId: "groq-cloud", contextWindow: 128000, supportsReasoning: true, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "openrouter-cloud",
                name: "OpenRouter",
                type: .cloud,
                kind: .openrouter,
                baseUrl: "https://openrouter.ai/api/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet (via OpenRouter)", providerId: "openrouter-cloud", contextWindow: 200000, supportsReasoning: true, speedTier: "Powerful"),
                    ModelInfo(id: "meta-llama/llama-3.3-70b-instruct", name: "Llama 3.3 70B Instruct", providerId: "openrouter-cloud", contextWindow: 131072, speedTier: "Fast"),
                    ModelInfo(id: "deepseek/deepseek-r1", name: "DeepSeek R1", providerId: "openrouter-cloud", contextWindow: 65536, supportsReasoning: true, speedTier: "Powerful")
                ]
            ),
            ModelProvider(
                id: "deepseek-cloud",
                name: "DeepSeek",
                type: .cloud,
                kind: .deepseek,
                baseUrl: "https://api.deepseek.com/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "deepseek-chat", name: "DeepSeek-V3", providerId: "deepseek-cloud", contextWindow: 64000, speedTier: "Fast"),
                    ModelInfo(id: "deepseek-reasoner", name: "DeepSeek-R1 (Reasoning)", providerId: "deepseek-cloud", contextWindow: 64000, supportsReasoning: true, speedTier: "Powerful")
                ]
            ),
            ModelProvider(
                id: "custom-openai",
                name: "Custom OpenAI-Compatible",
                type: .cloud,
                kind: .custom,
                baseUrl: "https://api.example.com/v1",
                apiKey: "",
                isEnabled: false,
                models: [
                    ModelInfo(id: "custom-model", name: "Custom Endpoint Model", providerId: "custom-openai", contextWindow: 32768, speedTier: "Balanced")
                ]
            )
        ]
    }

    public func loadProviders() -> [ModelProvider] {
        var loaded: [ModelProvider] = []
        if let items = storage.load([ModelProvider].self, from: "providers.json"), !items.isEmpty {
            loaded = items
        } else {
            loaded = defaultProviders
            saveProviders(loaded)
        }

        // Hydrate API keys securely from macOS Keychain if available
        for i in 0..<loaded.count {
            if let secret = KeychainManager.shared.getSecret(forKey: "provider_key_\(loaded[i].id)"), !secret.isEmpty {
                loaded[i].apiKey = secret
            }
        }
        return loaded
    }

    public func saveProviders(_ providers: [ModelProvider]) {
        // Save sensitive API keys to Keychain securely and sanitize for JSON backup
        let sanitized = providers
        for i in 0..<sanitized.count {
            let key = sanitized[i].apiKey
            if !key.isEmpty {
                KeychainManager.shared.saveSecret(key, forKey: "provider_key_\(sanitized[i].id)")
            }
        }
        storage.save(sanitized, to: "providers.json")
    }

    // MARK: - Agents
    public func loadAgents() -> [Agent] {
        if let items = storage.load([Agent].self, from: "agents.json"), !items.isEmpty {
            return items
        }
        let defaults: [Agent] = [
            Agent(
                id: "lead-assistant",
                name: "OpenWork Lead Agent",
                description: "Primary orchestrator agent capable of answering questions, decomposing complex goals, and spawning specialized sub-agents.",
                avatar: "person.crop.circle.badge.sparkables",
                color: "#8B5CF6",
                role: "Lead General Orchestrator",
                systemPrompt: """
                You are OpenWork Lead Agent, a robust, highly capable autonomous software engineering and research assistant.
                You can answer queries directly, or orchestrate specialized sub-agents (Coder, Researcher, Critic, Architect) for complex tasks.
                When a task has multiple independent steps, plan methodically, communicate clearly, and leverage tools and sub-agents.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.7,
                maxTokens: 4096,
                topP: 1.0,
                reasoningEffort: .medium,
                parentAgentId: nil,
                subAgentIds: ["coder-agent", "research-agent", "reviewer-agent"],
                canSpawnSubAgents: true,
                maxSubAgentDepth: 3,
                autoDelegate: true,
                canCommunicateWithOthers: true,
                tags: ["General", "Orchestrator", "Lead"],
                isBuiltIn: true,
                isLeadAgent: true
            ),
            Agent(
                id: "coder-agent",
                name: "Software Engineer Agent",
                description: "Specialized in architecture, clean code, debugging, refactoring, and test writing across Swift, Python, TypeScript, Rust, and more.",
                avatar: "chevron.left.forwardslash.chevron.right",
                color: "#3B82F6",
                role: "Senior Software Engineer",
                systemPrompt: """
                You are an expert Senior Software Engineer agent.
                You write clean, idiomatic, robust, and well-tested code.
                Focus on modern paradigms, performance, security, and edge-case handling.
                """,
                providerId: "ollama-local",
                modelId: "qwen2.5-coder:7b",
                temperature: 0.2,
                maxTokens: 8192,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: true,
                maxSubAgentDepth: 2,
                autoDelegate: false,
                canCommunicateWithOthers: true,
                tags: ["Coding", "Architecture", "Engineering"],
                isBuiltIn: true
            ),
            Agent(
                id: "research-agent",
                name: "Deep Research Agent",
                description: "Synthesizes documentation, explores codebases, analyzes repositories, and produces comprehensive factual summaries.",
                avatar: "magnifyingglass.circle.fill",
                color: "#10B981",
                role: "Research & Knowledge Specialist",
                systemPrompt: """
                You are a Deep Research and Technical Analysis agent.
                Your job is to thoroughly investigate questions, find patterns, analyze specifications, and summarize complex information into actionable insights.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.4,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Research", "Analysis", "Documentation"],
                isBuiltIn: true
            ),
            Agent(
                id: "reviewer-agent",
                name: "Code Review & Quality Critic",
                description: "Performs rigorous code review, checks for edge cases, security vulnerabilities, performance regressions, and architectural purity.",
                avatar: "checkmark.shield.fill",
                color: "#F59E0B",
                role: "Quality Assurance & Security Reviewer",
                systemPrompt: """
                You are a meticulous Code Reviewer and Quality Assurance agent.
                Critique designs and implementations constructively, point out defects, race conditions, memory leaks, security holes, and suggest concrete fixes.
                """,
                providerId: "ollama-local",
                modelId: "deepseek-r1:8b",
                temperature: 0.1,
                maxTokens: 4096,
                reasoningEffort: .high,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Review", "Security", "Quality"],
                isBuiltIn: true
            ),
            Agent(
                id: "architect-agent",
                name: "Systems Architect Agent",
                description: "Designs system topology, data flow, API contracts, and high-level structural blueprints.",
                avatar: "square.3.layers.3d.down.right.fill",
                color: "#EC4899",
                role: "Principal Systems Architect",
                systemPrompt: """
                You are a Principal Systems Architect.
                You design scalable software architectures, modular abstractions, data storage strategies, and clean API contracts.
                """,
                providerId: "ollama-local",
                modelId: "llama3.3:latest",
                temperature: 0.5,
                maxTokens: 4096,
                parentAgentId: nil,
                subAgentIds: ["coder-agent"],
                canSpawnSubAgents: true,
                maxSubAgentDepth: 2,
                autoDelegate: true,
                canCommunicateWithOthers: true,
                tags: ["Architecture", "System Design"],
                isBuiltIn: true
            ),
            // Knowledge Worker Agents (Claude Cowork Suite)
            Agent(
                id: "admin-finance-agent",
                name: "Administrative & Invoicing Specialist",
                description: "Automates quotes, professional invoices, payment reminders (R1-R3), and multi-supplier price comparisons.",
                avatar: "doc.text.fill",
                color: "#10B981",
                role: "Finance & Admin Specialist",
                systemPrompt: """
                You are a Knowledge Worker specialized in Business Administration and Invoicing.
                You transform quotes into formal invoices, audit Excel formulas, verify compliance checklists, and write polite, effective payment follow-ups.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.3,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Admin", "Invoices", "Finance", "Cowork"],
                isBuiltIn: true
            ),
            Agent(
                id: "sales-marketing-agent",
                name: "Sales Operations & Marketing Specialist",
                description: "Performs company prospect research, competitor pricing analysis, slide deck drafting, and HTML newsletter creation.",
                avatar: "chart.line.uptrend.xyaxis",
                color: "#F59E0B",
                role: "Sales & Marketing Strategist",
                systemPrompt: """
                You are an expert Sales and Growth Marketing Specialist.
                You research prospect decision-makers, synthesize competitor strengths and reviews, and craft compelling, conversion-focused copy.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.6,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Sales", "Marketing", "Prospecting", "Cowork"],
                isBuiltIn: true
            ),
            Agent(
                id: "operations-pm-agent",
                name: "Operations & Project Planner",
                description: "Builds Gantt milestones, inventory replenishment schedules, standardized SOP quality checklists, and work logs.",
                avatar: "list.bullet.clipboard.fill",
                color: "#6366F1",
                role: "Operations & Project Manager",
                systemPrompt: """
                You are an Operations Manager and Project Planner.
                You turn complex initiatives into clear milestone schedules, track dependencies, build inventory restock alerts, and document quality checklists.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.4,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Operations", "Planning", "Gantt", "Cowork"],
                isBuiltIn: true
            ),
            Agent(
                id: "comms-organizer-agent",
                name: "Communications & Organizer Assistant",
                description: "Sorts input/output files, transcribes receipts via OCR, summarizes meetings, and drafts cross-channel communications.",
                avatar: "tray.full.fill",
                color: "#06B6D4",
                role: "Communications & Workspace Organizer",
                systemPrompt: """
                You are an Executive Communications and File Organization assistant.
                You categorize documents in the input/ folder, extract receipt data into spreadsheets, prepare meeting briefings, and maintain structured cross-session memory.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.5,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Organization", "OCR", "Email", "Cowork"],
                isBuiltIn: true
            )
        ]
        saveAgents(defaults)
        return defaults
    }

    public func saveAgents(_ agents: [Agent]) {
        storage.save(agents, to: "agents.json")
    }

    // MARK: - Sessions
    public func loadSessions() -> [Session] {
        if let items = storage.load([Session].self, from: "sessions.json"), !items.isEmpty {
            return items
        }
        let initial = [
            Session(
                id: "welcome-session",
                workspaceId: "default-workspace",
                title: "Welcome to OpenWork-Swift",
                agentId: "lead-assistant",
                providerId: "ollama-local",
                modelId: "llama3:latest",
                isPinned: true,
                messages: [
                    ChatMessage(
                        sessionId: "welcome-session",
                        role: .assistant,
                        content: """
                        # Welcome to OpenWork-Swift 🚀
                        
                        OpenWork-Swift is your native macOS autonomous AI workspace powered by SwiftUI.
                        
                        ### Key Features:
                        - **Local & Cloud Model Providers**: Run locally with **Ollama**, **LM Studio**, or connect to **OpenAI**, **Anthropic Claude 3.7**, **Groq**, **DeepSeek**, and **OpenRouter**.
                        - **Autonomous Multi-Agent Hierarchy**: Lead agents can spawn sub-agents (Coders, Researchers, Reviewers) and communicate in real time.
                        - **Built-in Tool Execution**: Safe file reading/writing, shell commands, web search, and calculation.
                        - **Side Inspector**: Track live sub-agent trees, inter-agent messages, artifacts, and tools.
                        - **100% Standalone & Private**: Full local persistence in Application Support with zero external CLI runtime dependencies.
                        
                        Ask any question below or type `/help` to see available slash commands!
                        """,
                        agentId: "lead-assistant",
                        agentName: "OpenWork Lead Agent",
                        agentAvatar: "person.crop.circle.badge.sparkables",
                        agentColor: "#8B5CF6",
                        modelId: "llama3:latest"
                    )
                ]
            )
        ]
        saveSessions(initial)
        return initial
    }

    public func saveSessions(_ sessions: [Session]) {
        storage.save(sessions, to: "sessions.json")
    }

    // MARK: - Tools
    public func loadTools() -> [Tool] {
        if let items = storage.load([Tool].self, from: "tools.json"), !items.isEmpty {
            return items
        }
        let defaults: [Tool] = [
            Tool(id: "file_read", name: "file_read", displayName: "Read File", description: "Reads text content from a file path in authorized workspace directories", category: .files),
            Tool(id: "file_write", name: "file_write", displayName: "Write File", description: "Creates or overwrites a file with content", category: .files, requiresApproval: false),
            Tool(id: "file_list", name: "file_list", displayName: "List Directory", description: "Lists files and subdirectories in a given folder", category: .files),
            Tool(id: "terminal_command", name: "terminal_command", displayName: "Execute Shell Command", description: "Executes a shell command in macOS bash/zsh", category: .terminal, requiresApproval: false),
            Tool(id: "web_search", name: "web_search", displayName: "Web Search", description: "Searches the web for documentation, APIs, and real-time knowledge", category: .web),
            Tool(id: "calculator", name: "calculator", displayName: "Math Calculator", description: "Evaluates mathematical expressions and formulas", category: .system),
            Tool(id: "document_extract", name: "document_extract", displayName: "PDF & Vision OCR Extractor", description: "Extracts text from PDF documents via PDFKit or scanned images/receipts via Apple Vision framework OCR", category: .files),
            Tool(id: "workspace_semantic_search", name: "workspace_semantic_search", displayName: "Workspace Semantic Search (RAG)", description: "Performs local semantic chunk search across all source files in the active workspace", category: .files),
            Tool(id: "agent_spawn", name: "agent_spawn", displayName: "Spawn Sub-Agent", description: "Launches a specialized child sub-agent to execute a sub-task autonomously", category: .agents),
            Tool(id: "agent_message", name: "agent_message", displayName: "Message Agent", description: "Sends an inter-agent message or query to another agent in the network", category: .agents),
            Tool(id: "memory_store", name: "memory_store", displayName: "Save to Memory", description: "Saves a persistent fact, preference, or context item to the workspace memory", category: .system),
            Tool(id: "memory_recall", name: "memory_recall", displayName: "Recall Memory", description: "Retrieves stored memories by search term or category", category: .system)
        ]
        saveTools(defaults)
        return defaults
    }

    public func saveTools(_ tools: [Tool]) {
        storage.save(tools, to: "tools.json")
    }

    // MARK: - Memory
    public func loadMemories() -> [MemoryItem] {
        if let items = storage.load([MemoryItem].self, from: "memories.json"), !items.isEmpty {
            return items
        }
        let defaults: [MemoryItem] = [
            MemoryItem(
                workspaceId: "default-workspace",
                key: "coding_preference",
                content: "User prefers modern Swift 6 paradigms, clean SwiftUI architectures, strong type safety, and async/await.",
                category: .preference,
                tags: ["Swift", "SwiftUI", "Style"]
            ),
            MemoryItem(
                workspaceId: "default-workspace",
                key: "architecture_rule",
                content: "OpenWork-Swift is an autonomous, standalone desktop app. It does not rely on external node CLI daemons.",
                category: .instruction,
                tags: ["Architecture", "Rules"]
            )
        ]
        saveMemories(defaults)
        return defaults
    }

    public func saveMemories(_ memories: [MemoryItem]) {
        storage.save(memories, to: "memories.json")
    }

    // MARK: - Automations
    public func loadAutomations() -> [Automation] {
        if let items = storage.load([Automation].self, from: "automations.json"), !items.isEmpty {
            return items
        }
        let defaults: [Automation] = [
            Automation(
                workspaceId: "default-workspace",
                name: "Daily Project Status Summary",
                description: "Analyzes workspace files and generates a morning development report.",
                triggerType: .scheduled,
                cronSchedule: "Daily at 9:00 AM",
                targetAgentId: "lead-assistant",
                promptTemplate: "Scan my current workspace files and produce a structured bulleted summary of recent changes and recommended next steps."
            ),
            Automation(
                workspaceId: "default-workspace",
                name: "Automated Code Review on File Save",
                description: "Invokes reviewer agent whenever modified files are saved in the project.",
                triggerType: .fileWatch,
                cronSchedule: "On File Change",
                targetAgentId: "reviewer-agent",
                promptTemplate: "Review newly changed source code for security vulnerabilities, style inconsistencies, and performance regressions."
            )
        ]
        saveAutomations(defaults)
        return defaults
    }

    public func saveAutomations(_ automations: [Automation]) {
        storage.save(automations, to: "automations.json")
    }

    // MARK: - Skills
    public func loadSkills() -> [Skill] {
        if let items = storage.load([Skill].self, from: "skills.json"), !items.isEmpty {
            return items
        }
        let defaults: [Skill] = [
            Skill(
                id: "code-reviewer-skill",
                name: "Code Review & Static Analysis",
                description: "Deep inspection for memory safety, concurrency races, type safety, and architectural modularity.",
                category: "Engineering",
                content: """
                # Code Review Skill
                When reviewing code:
                1. Check for data races and concurrency invariants.
                2. Validate error handling and resource cleanup.
                3. Verify edge cases and bounds checks.
                4. Suggest clean refactorings with minimal cognitive complexity.
                """,
                source: .builtIn
            ),
            Skill(
                id: "security-auditor-skill",
                name: "Security & Vulnerability Audit",
                description: "Audits code for injection, secret leakage, OWASP Top 10, and unsafe deserialization.",
                category: "Security",
                content: """
                # Security Audit Skill
                When auditing systems:
                1. Look for unescaped user inputs and SQL/command injection vulnerabilities.
                2. Ensure secrets and tokens are never hardcoded or leaked into logs.
                3. Validate authentication and authorization checks.
                """,
                source: .builtIn
            ),
            Skill(
                id: "git-expert-skill",
                name: "Git Workflow & PR Generator",
                description: "Generates atomic commit messages, branch strategies, and comprehensive pull request summaries.",
                category: "DevOps",
                content: """
                # Git & PR Skill
                Format concise commit messages following conventional commits:
                - `feat:`, `fix:`, `refactor:`, `test:`, `docs:`
                - Include clear summary and test plan.
                """,
                source: .builtIn
            )
        ]
        saveSkills(defaults)
        return defaults
    }

    public func saveSkills(_ skills: [Skill]) {
        storage.save(skills, to: "skills.json")
    }

    // MARK: - Extensions & Plugins
    public var defaultPlugins: [AppExtensionPlugin] {
        return [
            AppExtensionPlugin(
                id: "plugin-mcp-filesystem",
                name: "Filesystem MCP Engine",
                description: "Model Context Protocol server for deep local file reading, chunk search, and directory operations.",
                version: "1.2.0",
                author: "Model Context Protocol",
                pluginType: .mcpServer,
                source: .builtIn,
                isEnabled: true,
                command: "npx -y @modelcontextprotocol/server-filesystem",
                permissions: ["filesystem:read", "filesystem:write"]
            ),
            AppExtensionPlugin(
                id: "plugin-mcp-fetch",
                name: "Web Fetch & Scraper MCP",
                description: "Fetches and transforms web pages, documentation, and REST endpoints into clean markdown.",
                version: "1.0.4",
                author: "Model Context Protocol",
                pluginType: .mcpServer,
                source: .mcpRegistry,
                isEnabled: true,
                command: "npx -y @modelcontextprotocol/server-fetch",
                permissions: ["network:outbound"]
            ),
            AppExtensionPlugin(
                id: "plugin-voice-whisper",
                name: "macOS Native Voice & Speech",
                description: "System speech synthesis (AVSpeechSynthesizer) and speech-to-text voice recognition.",
                version: "2.1.0",
                author: "Apple Silicon Core",
                pluginType: .voiceAudio,
                source: .builtIn,
                isEnabled: true,
                permissions: ["audio:microphone", "audio:speaker"]
            ),
            AppExtensionPlugin(
                id: "plugin-vision-ocr",
                name: "Vision OCR & Document Extractor",
                description: "PDFKit text parsing and Apple Vision optical character recognition for scans and diagrams.",
                version: "1.5.0",
                author: "Apple Vision Framework",
                pluginType: .mediaVision,
                source: .builtIn,
                isEnabled: true,
                permissions: ["system:vision"]
            ),
            AppExtensionPlugin(
                id: "plugin-script-git",
                name: "Git Automated Diff & Staging Hook",
                description: "Shell script plugin to analyze git dirty trees, commit history, and automated branch workflows.",
                version: "1.0.0",
                author: "OpenWork Community",
                pluginType: .customScript,
                source: .custom,
                isEnabled: true,
                command: "git status --porcelain",
                permissions: ["shell:exec"]
            )
        ]
    }

    public func loadPlugins() -> [AppExtensionPlugin] {
        if let items = storage.load([AppExtensionPlugin].self, from: "plugins.json"), !items.isEmpty {
            return items
        }
        let defaults = defaultPlugins
        savePlugins(defaults)
        return defaults
    }

    public func savePlugins(_ plugins: [AppExtensionPlugin]) {
        storage.save(plugins, to: "plugins.json")
    }
}
