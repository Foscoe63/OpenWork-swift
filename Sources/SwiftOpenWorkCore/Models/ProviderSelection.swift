import Foundation

/// Which provider a session should actually talk to.
///
/// A provider the user switched off must not be used just because settings still name it. The
/// model picker only ever offers enabled providers, so a disabled one can only be selected
/// through stale configuration — and the result is a turn that fails against a server the user
/// deliberately turned off, with no indication why.
public enum ProviderSelection {

    /// What resolution did, beyond naming a provider.
    public enum Outcome: Equatable, Sendable {
        /// The selection was usable as-is.
        case selected
        /// The selection was unusable and another provider was substituted. Carries the name of
        /// the provider that was overridden, so the UI can say so.
        case substituted(for: String)
        /// The selection was a *local* provider that is switched off, and no other local provider
        /// is available. The turn must fail rather than reach the network.
        ///
        /// Substituting here is what made the old `defaultProviderId` bug dangerous rather than
        /// merely wrong: `openrouter-cloud` sits earlier in the provider array than
        /// `omlx-local`, so "first enabled in array order" sent turns the user believed were
        /// local to a cloud endpoint. Fixing the default stopped it firing on a fresh install; it
        /// stayed one toggle away for anyone who disabled the built-in engine.
        case refusedToLeaveLocal(selected: String)
    }

    /// The provider to use, and what resolution had to do to get there.
    public struct Resolution: Equatable, Sendable {
        public var provider: ModelProvider
        public var outcome: Outcome

        public init(provider: ModelProvider, outcome: Outcome) {
            self.provider = provider
            self.outcome = outcome
        }

        /// The name of a selected-but-disabled provider that was overridden, if any.
        public var overrodeDisabled: String? {
            if case let .substituted(name) = outcome { return name }
            return nil
        }

        /// Whether the caller must refuse the turn instead of running it.
        public var mustRefuse: Bool {
            if case .refusedToLeaveLocal = outcome { return true }
            return false
        }

        /// What to tell the user when the turn is refused.
        public var refusalMessage: String? {
            guard case let .refusedToLeaveLocal(name) = outcome else { return nil }
            return """
            \(name) is switched off, and it runs locally.

            Rather than send this turn to a cloud provider you did not choose, SwiftOpenWork stopped. \
            Turn \(name) back on in Model Providers, or pick a different provider for this session.
            """
        }
    }

    /// Prefer the selected provider when it is enabled.
    ///
    /// When it is not, a substitute is found — but never a cloud provider standing in for a local
    /// one. "Prefer local, never silently reach the network" is the rule; see
    /// `Outcome.refusedToLeaveLocal`.
    public static func resolve(
        providers: [ModelProvider],
        selectedId: String
    ) -> Resolution? {
        let selected = providers.first { $0.id == selectedId }
        if let selected, selected.isEnabled {
            return Resolution(provider: selected, outcome: .selected)
        }

        // A local selection may only be replaced by another local provider.
        if let selected, selected.type == .local {
            if let localAlternative = providers.first(where: { $0.isEnabled && $0.type == .local }) {
                return Resolution(provider: localAlternative, outcome: .substituted(for: selected.name))
            }
            return Resolution(provider: selected, outcome: .refusedToLeaveLocal(selected: selected.name))
        }

        if let enabled = providers.first(where: { $0.isEnabled }) {
            return Resolution(
                provider: enabled,
                // Only an override if the selection actually existed and was off.
                outcome: selected.map { .substituted(for: $0.name) } ?? .selected
            )
        }
        if let selected {
            return Resolution(provider: selected, outcome: .selected)
        }
        guard let first = providers.first else { return nil }
        return Resolution(provider: first, outcome: .selected)
    }

    /// The id a stale selection should be corrected to at startup.
    ///
    /// Same rule as `resolve`: a disabled local selection is corrected to another local provider
    /// or left alone, never quietly moved to a cloud one.
    public static func correctedSelectionId(
        providers: [ModelProvider],
        selectedId: String,
        fallback: String = "builtin-mlx-local"
    ) -> String {
        if providers.contains(where: { $0.id == selectedId && $0.isEnabled }) {
            return selectedId
        }
        if let selected = providers.first(where: { $0.id == selectedId }), selected.type == .local {
            return providers.first(where: { $0.isEnabled && $0.type == .local })?.id ?? selectedId
        }
        return providers.first(where: { $0.isEnabled })?.id ?? providers.first?.id ?? fallback
    }
}
