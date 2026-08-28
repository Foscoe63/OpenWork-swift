import Foundation

public struct PromptTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let command: String
    public let category: PromptCategory
    public let prompt: String
    public let description: String

    public enum PromptCategory: String, Codable, CaseIterable, Sendable {
        case administrative = "Administrative & Finance"
        case salesMarketing = "Sales & Marketing"
        case operations = "Operations & Projects"
        case organizationFiles = "Organization & File OCR"
        case engineering = "Software Engineering"

        public var icon: String {
            switch self {
            case .administrative: return "doc.text.fill"
            case .salesMarketing: return "chart.line.uptrend.xyaxis"
            case .operations: return "list.bullet.clipboard.fill"
            case .organizationFiles: return "tray.2.fill"
            case .engineering: return "curlybraces"
            }
        }
    }

    public init(id: String, title: String, command: String, category: PromptCategory, description: String, prompt: String) {
        self.id = id
        self.title = title
        self.command = command
        self.category = category
        self.description = description
        self.prompt = prompt
    }
}

public struct PromptCatalog {
    public static let sharedTemplates: [PromptTemplate] = [
        // --- ADMINISTRATIVE & FINANCE ---
        PromptTemplate(
            id: "invoice-gen",
            title: "Generate Professional Invoice",
            command: "/invoice",
            category: .administrative,
            description: "Creates a compliant itemized invoice from raw inputs",
            prompt: "Please generate a professional invoice with invoice number, date, itemized line items, subtotal, tax rate, and total balance due based on the following details:\n\n"
        ),
        PromptTemplate(
            id: "quote-to-invoice",
            title: "Convert Quote to Invoice",
            command: "/quote2invoice",
            category: .administrative,
            description: "Transforms a signed quote into an invoice",
            prompt: "Please convert this accepted quotation into a finalized invoice, maintaining terms, line item rates, and customer billing references:\n\n"
        ),
        PromptTemplate(
            id: "payment-reminder",
            title: "Draft Polite Payment Reminder (R1/R2)",
            command: "/reminder",
            category: .administrative,
            description: "Generates polite or firm invoice payment follow-up letters",
            prompt: "Draft a professional, courteous payment reminder email for overdue Invoice #[Number], referencing the original due date and attached copy."
        ),
        PromptTemplate(
            id: "supplier-comparison",
            title: "Supplier Price Comparison Table",
            command: "/pricecompare",
            category: .administrative,
            description: "Compares quotes across multiple vendors with scoring",
            prompt: "Create a structured markdown comparison matrix evaluating the following 3 supplier proposals across price, delivery turnaround, payment terms, and support quality:\n\n"
        ),
        PromptTemplate(
            id: "financial-audit",
            title: "Audit Financial Model / Spreadsheet",
            command: "/auditmodel",
            category: .administrative,
            description: "Checks formulas and logic assumptions for errors",
            prompt: "Review the following financial model figures and formula logic, highlighting potential discrepancies, circular dependencies, or unstated assumptions:\n\n"
        ),

        // --- SALES & MARKETING ---
        PromptTemplate(
            id: "prospect-research",
            title: "Company & Decision-Maker Research",
            command: "/prospect",
            category: .salesMarketing,
            description: "Deep research on prospective B2B clients and executives",
            prompt: "Synthesize background research on [Target Company], including key business focus, recent leadership changes, product offerings, and potential pain points."
        ),
        PromptTemplate(
            id: "competitor-analysis",
            title: "Competitor Strengths & Pricing Matrix",
            command: "/competitor",
            category: .salesMarketing,
            description: "Audits competing offers, tier features, and customer sentiment",
            prompt: "Perform a competitive landscape analysis comparing our offering against [Competitor A] and [Competitor B], highlighting differentiators, pricing models, and customer review themes."
        ),
        PromptTemplate(
            id: "slide-deck-outline",
            title: "Draft Presentation Slide Outline",
            command: "/slides",
            category: .salesMarketing,
            description: "Builds a 10-slide high-impact presentation structure",
            prompt: "Create a 10-slide presentation outline for [Topic/Product Pitch], including slide title, visual layout concept, key bullet points, and speaker talking notes."
        ),
        PromptTemplate(
            id: "html-newsletter",
            title: "Responsive HTML Newsletter Draft",
            command: "/newsletter",
            category: .salesMarketing,
            description: "Writes a modern email newsletter with responsive layout",
            prompt: "Write a high-converting email newsletter announcing [Feature/Event], structured with header, main story, 3 bulleted highlights, customer quote, and clear Call-To-Action button."
        ),

        // --- OPERATIONS & PROJECTS ---
        PromptTemplate(
            id: "gantt-planner",
            title: "Gantt Milestone & Project Breakdown",
            command: "/gantt",
            category: .operations,
            description: "Breaks initiative into sequential milestones with dependencies",
            prompt: "Decompose this project goal into a 6-week phased timeline with distinct milestones, critical path dependencies, estimated days, and assigned owners:\n\n"
        ),
        PromptTemplate(
            id: "sop-checklist",
            title: "Standard Operating Procedure (SOP) Checklist",
            command: "/sop",
            category: .operations,
            description: "Standardizes quality processes into verifiable checklists",
            prompt: "Create a comprehensive, step-by-step Standard Operating Procedure (SOP) and verification checklist for [Process Name]."
        ),
        PromptTemplate(
            id: "inventory-tracker",
            title: "Inventory Restock & Safety Stock Alert",
            command: "/inventory",
            category: .operations,
            description: "Calculates reorder triggers and safety stock levels",
            prompt: "Analyze the current stock levels, average daily burn rate, and supplier lead times below to calculate required reorder quantities and safety thresholds:\n\n"
        ),

        // --- ORGANIZATION & FILE OCR ---
        PromptTemplate(
            id: "organize-files",
            title: "Organize input/ Folder Files by Type",
            command: "/organize",
            category: .organizationFiles,
            description: "Sorts messy staging files into structured directories",
            prompt: "Examine the files in my workspace input/ directory, classify them by document type (invoices, contracts, receipts, technical docs), and recommend standard renaming conventions."
        ),
        PromptTemplate(
            id: "receipt-ocr",
            title: "Extract Receipt & Expense Table (OCR)",
            command: "/receiptocr",
            category: .organizationFiles,
            description: "Extracts vendor, date, line items, and tax from receipt images",
            prompt: "Use document extraction / Vision OCR on the uploaded receipt to construct a clean CSV table with columns: Date, Merchant, Category, Currency, Net Amount, Tax, Total."
        ),
        PromptTemplate(
            id: "meeting-brief",
            title: "Executive Meeting Briefing Note",
            command: "/brief",
            category: .organizationFiles,
            description: "Synthesizes attendee context, past decisions, and agenda",
            prompt: "Generate a concise 1-page executive briefing document for an upcoming meeting with [Stakeholder], covering historical context, core objectives, and 3 key discussion questions."
        ),

        // --- SOFTWARE ENGINEERING ---
        PromptTemplate(
            id: "code-review",
            title: "Rigorous Code & Architecture Review",
            command: "/review",
            category: .engineering,
            description: "Checks code diff for defects, race conditions, and clean style",
            prompt: "Perform a thorough code review on the following implementation, identifying potential concurrency bugs, memory retain cycles, edge case failures, and performance optimizations:\n\n"
        ),
        PromptTemplate(
            id: "generate-tests",
            title: "Generate Comprehensive Unit Tests",
            command: "/test",
            category: .engineering,
            description: "Generates thorough unit tests with mocks and edge cases",
            prompt: "Write complete, idiomatic unit tests for the following Swift/TypeScript component, covering happy paths, error states, and boundary conditions:\n\n"
        )
    ]
}
