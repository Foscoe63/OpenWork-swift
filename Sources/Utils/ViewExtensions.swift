import SwiftUI

extension View {
    /// Run `action` when `value` changes.
    ///
    /// Wraps SwiftUI's zero-parameter `onChange`, which replaced the two-parameter form deprecated
    /// in macOS 14. This existed as an availability shim with a pre-14 fallback, but the app's
    /// deployment target *is* macOS 14 — so that branch could never run, and call sites that
    /// wanted a non-Int value reached for the deprecated API directly instead.
    public func onValueChanged<Value: Equatable>(
        of value: Value,
        perform action: @escaping () -> Void
    ) -> some View {
        onChange(of: value) {
            action()
        }
    }

    /// Kept for the two call sites that watch a count.
    public func onMessageCountChanged(count: Int, action: @escaping () -> Void) -> some View {
        onValueChanged(of: count, perform: action)
    }
}
