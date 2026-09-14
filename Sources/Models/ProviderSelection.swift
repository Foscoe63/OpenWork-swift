import Foundation

/// Which provider a session should actually talk to.
///
/// A provider the user switched off must not be used just because settings still name it. The
/// model picker only ever offers enabled providers, so a disabled one can only be selected
/// through stale configuration — and the result is a turn that fails against a server the user
/// deliberately turned off, with no indication why.
public enum ProviderSelection {

    /// The provider to use, and whether the caller's choice had to be overridden.
    public struct Resolution: Equatable, Sendable {
        public var provider: ModelProvider
        /// Set when `selectedId` named a provider that exists but is disabled, so the UI can say
        /// so rather than silently answering from somewhere else.
        public var overrodeDisabled: String?
    }

    /// Prefer the selected provider when it is enabled; otherwise the first enabled one.
    ///
    /// Falls back to the selected-but-disabled provider only when nothing is enabled at all —
    /// returning something the caller can name beats returning an unrelated placeholder.
    public static func resolve(
        providers: [ModelProvider],
        selectedId: String
    ) -> Resolution? {
        let selected = providers.first { $0.id == selectedId }
        if let selected, selected.isEnabled {
            return Resolution(provider: selected, overrodeDisabled: nil)
        }
        if let enabled = providers.first(where: { $0.isEnabled }) {
            return Resolution(
                provider: enabled,
                // Only an override if the selection actually existed and was off.
                overrodeDisabled: selected.map(\.name)
            )
        }
        if let selected {
            return Resolution(provider: selected, overrodeDisabled: nil)
        }
        guard let first = providers.first else { return nil }
        return Resolution(provider: first, overrodeDisabled: nil)
    }

    /// The id a stale selection should be corrected to at startup.
    public static func correctedSelectionId(
        providers: [ModelProvider],
        selectedId: String,
        fallback: String = "ollama-local"
    ) -> String {
        if providers.contains(where: { $0.id == selectedId && $0.isEnabled }) {
            return selectedId
        }
        return providers.first(where: { $0.isEnabled })?.id ?? providers.first?.id ?? fallback
    }
}
